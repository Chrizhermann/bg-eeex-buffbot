"""Overhead player feedback (bg-eeex-buffbot#76).

BuffBot used to call EEex_Sprite_DisplayStringHead, which no EEex release
defines, inside a pcall, so the combat-stop notice was silently lost. These
tests drive the replacement through a fake EEex surface that follows the real
signatures: EEex_NewUD / EEex_FreeUD, EEex_RunWithStackManager building
CStrings, CMessageDisplayText:Construct(name, text, nameColor, textColor,
marker, caller, target) and the engine message handler.
"""

from __future__ import annotations

import faulthandler
from pathlib import Path
import sys

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CORE_SOURCE = (ROOT / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")
LOC_SOURCE = (ROOT / "buffbot/BfBotLoc.lua").read_text(encoding="utf-8")
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")
EXEC_SOURCE = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")

FAKE_EEEX = r"""
T = { displayed = {}, added = {}, freed = {}, destructed = {}, entries = nil }

Infinity_DisplayString = function(s) T.displayed[#T.displayed + 1] = s end

EngineGlobals = { g_pBaldurChitin = { m_cMessageHandler = {
    AddMessage = function(self, message, bForce)
        T.added[#T.added + 1] = { message = message, bForce = bForce }
    end,
} } }

CVidPalette = { RANGE_COLORS = {
    get = function(self, index) return 0x100 + index end,
} }

local function isCString(value)
    return type(value) == "table" and value.kind == "CString"
end

-- Like the real binding: unknown types fail, Construct checks its argument
-- types before touching the object, and copies both CStrings.
T_KnownTypes = { CMessageDisplayText = true }
EEex_NewUD = function(typeName)
    if not T_KnownTypes[typeName] then
        error("unknown user type: " .. tostring(typeName))
    end
    local message = { typeName = typeName, m_overHead = 0 }
    function message:Construct(name, text, nameColor, textColor, marker, caller, target)
        if not isCString(name) or not isCString(text) then
            error("bad argument to CMessageDisplayText:Construct (CString expected)")
        end
        self.m_name = name.value
        self.m_text = text.value
        self.m_nameColor = nameColor
        self.m_textColor = textColor
        self.m_marker = marker
        self.m_sourceId = caller
        self.m_targetId = target
    end
    return message
end
EEex_FreeUD = function(ud) T.freed[#T.freed + 1] = ud end

-- Like EEex_MemoryManager:runWithStack: construct each entry, run the
-- callback, destruct every entry not marked noDestruct, rethrow errors.
EEex_RunWithStackManager = function(entries, func)
    T.entries = entries
    local uds = {}
    for _, entry in ipairs(entries) do
        assert(entry.struct == "CString", "unexpected struct " .. tostring(entry.struct))
        uds[entry.name] = { kind = "CString", value = entry.constructor.args[1],
                            noDestruct = entry.noDestruct }
    end
    local manager = { getUD = function(self, name) return uds[name] end }
    local ok, err = pcall(func, manager)
    for name, ud in pairs(uds) do
        if not ud.noDestruct then T.destructed[#T.destructed + 1] = name end
    end
    if not ok then error(err, 0) end
end

T_Leader = {
    m_id = 42,
    m_sName = { kind = "CString", value = "Imoen" },
    m_baseStats = { m_colors = { get = function(self, index) return 7 end } },
}
"""


def _run(runtime: LuaRuntime, source: str):
    """Execute Lua; hide Windows' faulthandler noise for errors that pcall
    contains (LuaJIT unwinds them as handled SEH exceptions)."""
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        return runtime.execute(source)
    finally:
        if suppress_fault_handler:
            faulthandler.enable()


@pytest.fixture
def core() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(FAKE_EEEX)
    runtime.execute(CORE_SOURCE)
    return runtime


def _list(table) -> list:
    return [table[i] for i in range(1, len(table) + 1)]


def test_overhead_text_queues_a_display_text_message_over_the_sprite(core) -> None:
    facts = _run(
        core,
        """
        local queued = BfBot._DisplayOverhead(T_Leader, "BuffBot: Kampf erkannt - gestoppt")
        local added = T.added[1]
        local m = added and added.message
        return {
            queued = queued,
            addedCount = #T.added,
            bForce = added and added.bForce,
            typeName = m and m.typeName,
            name = m and m.m_name,
            text = m and m.m_text,
            nameColor = m and m.m_nameColor,
            textColor = m and m.m_textColor,
            marker = m and m.m_marker,
            source = m and m.m_sourceId,
            target = m and m.m_targetId,
            overHead = m and m.m_overHead,
            stackNoDestruct = T.entries[1].noDestruct,
            destructed = table.concat(T.destructed, ","),
            displayed = #T.displayed,
            freed = #T.freed,
        }
        """
    )

    assert facts["queued"] is True
    assert facts["addedCount"] == 1
    assert facts["bForce"] is False
    assert facts["typeName"] == "CMessageDisplayText"
    assert facts["name"] == "Imoen"
    assert facts["text"] == "BuffBot: Kampf erkannt - gestoppt"
    assert facts["nameColor"] == 0x107
    assert facts["textColor"] == 0xBED7D7
    assert facts["marker"] == -1
    assert facts["source"] == 42
    assert facts["target"] == 42
    assert facts["overHead"] == 1
    # Construct copies the text, so the temporary CString must be destroyed.
    assert facts["stackNoDestruct"] is None
    assert facts["destructed"] == "text"
    assert facts["displayed"] == 0
    assert facts["freed"] == 0


def test_utf8_catalog_text_reaches_the_message_unchanged(core) -> None:
    text = "BuffBot: Бой обнаружен — 施法已停止"
    core.globals().T_Text = text
    queued = _run(core, "return BfBot._DisplayOverhead(T_Leader, T_Text)")
    assert queued is True
    assert _run(core, "return T.added[1].message.m_text") == text


def test_missing_binding_falls_back_to_the_log_and_reports_once(core) -> None:
    _run(core, "T_KnownTypes.CMessageDisplayText = nil")
    first = _run(core, "return BfBot._DisplayOverhead(T_Leader, 'Notice one')")
    second = _run(core, "return BfBot._DisplayOverhead(T_Leader, 'Notice two')")

    displayed = _list(_run(core, "return T.displayed"))
    assert first is False
    assert second is False
    assert _run(core, "return #T.added") == 0
    assert len(displayed) == 3
    assert displayed[0].startswith("[BuffBot ERROR] Overhead text failed")
    assert "unknown user type: CMessageDisplayText" in displayed[0]
    assert displayed[1:] == ["Notice one", "Notice two"]


def test_construct_failure_frees_the_message_and_falls_back(core) -> None:
    _run(core, "T_Leader.m_sName = 'not a CString'")
    queued = _run(core, "return BfBot._DisplayOverhead(T_Leader, 'Notice')")

    displayed = _list(_run(core, "return T.displayed"))
    assert queued is False
    assert _run(core, "return #T.added") == 0
    assert _run(core, "return #T.freed") == 1
    assert _run(core, "return T.freed[1].typeName") == "CMessageDisplayText"
    assert _run(core, "return table.concat(T.destructed, ',')") == "text"
    assert "CString expected" in displayed[0]
    assert displayed[-1] == "Notice"


def test_missing_message_handler_reports_before_allocating(core) -> None:
    _run(core, "EngineGlobals = nil")
    queued = _run(core, "return BfBot._DisplayOverhead(T_Leader, 'Notice')")

    displayed = _list(_run(core, "return T.displayed"))
    assert queued is False
    assert _run(core, "return #T.freed") == 0
    assert displayed[0].startswith("[BuffBot ERROR] Overhead text failed")
    assert displayed[-1] == "Notice"


def test_without_a_sprite_the_notice_goes_to_the_log_without_an_error(core) -> None:
    queued = _run(core, "return BfBot._DisplayOverhead(nil, 'Notice')")
    assert queued is False
    assert _list(_run(core, "return T.displayed")) == ["Notice"]
    assert _run(core, "return #T.added") == 0


def test_error_once_deduplicates_identical_messages(core) -> None:
    _run(
        core,
        "BfBot._ErrorOnce('same'); BfBot._ErrorOnce('same'); BfBot._ErrorOnce('other')"
    )
    assert _list(_run(core, "return T.displayed")) == [
        "[BuffBot ERROR] same",
        "[BuffBot ERROR] other",
    ]


@pytest.fixture
def exec_runtime() -> LuaRuntime:
    """Real Cor + Loc + Persist + Exe on the fake EEex surface."""
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(FAKE_EEEX)
    runtime.execute(CORE_SOURCE)
    runtime.execute(
        """
        BfBot.Scan, BfBot.Class, BfBot.Innate, BfBot.Mp = {}, {}, {}, {}
        EEex_BAnd = function() return 0 end
        io = nil
        """
    )
    runtime.execute(LOC_SOURCE)
    runtime.execute(PERSIST_SOURCE)
    runtime.execute(EXEC_SOURCE)
    return runtime


def test_combat_stop_shows_the_localized_notice_over_the_leader(exec_runtime) -> None:
    facts = _run(
        exec_runtime,
        """
        local stops = 0
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return T_Leader end
        end
        BfBot.Exec._ResolveCasterForStep = function() return T_Leader end
        BfBot.Exec._DetectCombat = function() return true end
        BfBot.Exec.Stop = function()
            stops = stops + 1
            BfBot.Exec._state = "stopped"
        end
        BfBot.Exec._state = "running"
        BfBot.Exec._casters = { p0 = {
            ref = { kind = "party", slot = 0 }, queue = {}, index = 1,
            done = false, name = "Imoen",
        } }
        BfBot.Exec._Advance("p0")
        local m = T.added[1] and T.added[1].message
        return {
            stops = stops,
            added = #T.added,
            text = m and m.m_text,
            target = m and m.m_targetId,
            overHead = m and m.m_overHead,
            expected = BfBot.L10N.Get("feedback.combat_stopped"),
            displayed = #T.displayed,
        }
        """
    )

    assert facts["stops"] == 1
    assert facts["added"] == 1
    assert facts["text"] == facts["expected"]
    assert facts["text"] == "BuffBot: Combat detected - casting stopped"
    assert facts["target"] == 42
    assert facts["overHead"] == 1
    assert facts["displayed"] == 0


def test_leader_lookup_failure_still_shows_the_notice_and_reports(exec_runtime) -> None:
    _run(
        exec_runtime,
        """
        EEex_Sprite_GetInPortrait = function() error("portrait lookup broke") end
        BfBot.Exec._NotifyLeader("Notice")
        BfBot.Exec._NotifyLeader("Notice again")
        """
    )
    displayed = _list(_run(exec_runtime, "return T.displayed"))
    assert _run(exec_runtime, "return #T.added") == 0
    assert displayed[0].startswith("[BuffBot ERROR] Party leader lookup failed")
    assert "portrait lookup broke" in displayed[0]
    assert displayed[1:] == ["Notice", "Notice again"]
