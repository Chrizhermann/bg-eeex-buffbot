"""Removal of the F12 preset innates that earlier BuffBot versions granted.

BuffBot no longer runs presets from F12. Saves made before still carry the
innates (BFBT{slot}{preset}), and upgraded installs keep the generated SPLs in
override, whose opcode 402 effect still calls BFBOTGO.
"""

from __future__ import annotations

from pathlib import Path
import re

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CORE_SOURCE = (ROOT / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")
INNATE_SOURCE = (ROOT / "buffbot/BfBotInn.lua").read_text(encoding="utf-8")
TEST_SOURCE = (ROOT / "buffbot/BfBotTst.lua").read_text(encoding="utf-8")


# A party whose portrait lookups return a fresh wrapper per call, like EEex.
# Opcode 172 removes one known copy per application. io is replaced by a
# recorder, so the innate log can be read back.
PARTY_HARNESS = """
    party = {}
    applied = {}
    warnings = {}
    logLines = {}
    openedFiles = {}

    io = {
        open = function(path, mode)
            openedFiles[#openedFiles + 1] = path .. ":" .. mode
            return {
                write = function(_, text) logLines[#logLines + 1] = text end,
                close = function() end,
            }
        end,
    }
    BfBot._Warn = function(message) warnings[#warnings + 1] = message end

    EEex_Sprite_GetInPortrait = function(slot)
        local member = party[slot]
        if not member then return nil end
        return {
            m_id = member.id,
            member = member,
            getName = function(self) return self.member.name end,
        }
    end
    EEex_Sprite_GetKnownInnateSpellsIterator = function(sprite)
        if sprite.member.unreadable then error("synthetic walk failure") end
        local list = sprite.member.innates
        local index = 0
        return function()
            index = index + 1
            local resref = list[index]
            if resref == nil then return nil end
            return 0, index - 1, resref
        end
    end
    function removeOne(sprite, args)
        if args.effectID ~= 172 then return end
        for index, resref in ipairs(sprite.member.innates) do
            if resref:upper() == args.res then
                table.remove(sprite.member.innates, index)
                return
            end
        end
    end
    EEex_GameObject_ApplyEffect = function(sprite, args)
        applied[#applied + 1] = string.format("%s:%d:%s:%s",
            sprite.member.name, args.effectID, tostring(args.durationType),
            tostring(args.res))
        removeOne(sprite, args)
    end

    function take(list)
        local copy = {}
        for index, value in ipairs(list) do copy[index] = value end
        table.sort(copy)
        for index = #list, 1, -1 do list[index] = nil end
        return table.concat(copy, "|")
    end
"""


@pytest.fixture
def innate_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        io = nil
        Infinity_DisplayString = function(_) end
        BfBot = { MAX_PRESETS = 8 }
        """
    )
    runtime.execute(CORE_SOURCE)
    runtime.execute(INNATE_SOURCE)
    runtime.execute(PARTY_HARNESS)
    return runtime


def test_legacy_copies_counts_only_preset_innates_per_resref(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        party[0] = { id = 101, name = "Ilauna", innates = {
            "BFBT01", "bfbt01", "BFBT58", "BFBT00", "BFBT09", "BFBT61",
            "BFBT011", "BFBTCH", "BFBTCR", "BFBTRM", "SPIN123",
        } }
        local counts, total = BfBot.Innate._LegacyCopies(EEex_Sprite_GetInPortrait(0))
        local keys = {}
        for resref, copies in pairs(counts) do
            keys[#keys + 1] = resref .. "=" .. copies
        end
        table.sort(keys)
        return { counts = table.concat(keys, ","), total = total }
        """
    )

    assert facts["counts"] == "BFBT01=2,BFBT58=1"
    assert facts["total"] == 3


def test_legacy_copies_reports_a_failed_walk(innate_lua: LuaRuntime) -> None:
    facts = innate_lua.execute(
        """
        party[0] = { id = 101, name = "Ilauna", innates = {}, unreadable = true }
        local counts, err = BfBot.Innate._LegacyCopies(EEex_Sprite_GetInPortrait(0))
        return { counts = counts == nil, err = tostring(err) }
        """
    )

    assert facts["counts"]
    assert "synthetic walk failure" in facts["err"]


def test_remove_from_applies_one_permanent_opcode_172_per_copy(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        party[0] = { id = 101, name = "Ilauna", innates = {
            "BFBT01", "SPIN123", "BFBT01", "bfbt01", "BFBT21",
        } }
        local removed, left = BfBot.Innate._RemoveFrom(EEex_Sprite_GetInPortrait(0))
        return {
            removed = removed,
            left = left,
            applied = take(applied),
            kept = table.concat(party[0].innates, ","),
        }
        """
    )

    assert facts["removed"] == 4
    assert facts["left"] == 0
    assert facts["applied"] == "|".join(
        ["Ilauna:172:1:BFBT01"] * 3 + ["Ilauna:172:1:BFBT21"]
    )
    assert facts["kept"] == "SPIN123"


def test_remove_from_leaves_a_clean_member_alone(innate_lua: LuaRuntime) -> None:
    facts = innate_lua.execute(
        """
        party[0] = { id = 101, name = "Ilauna", innates = { "SPIN123", "BFBTCH" } }
        local removed, left = BfBot.Innate._RemoveFrom(EEex_Sprite_GetInPortrait(0))
        return { removed = removed, left = left, applied = take(applied) }
        """
    )

    assert facts["removed"] == 0
    assert facts["left"] == 0
    assert facts["applied"] == ""


def test_remove_legacy_handles_each_member_once_per_game_and_logs_it(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        party[0] = { id = 101, name = "Ilauna", innates = { "BFBT01", "BFBT02" } }
        party[3] = { id = 104, name = "Baern", innates = { "SPIN123" } }
        BfBot.Innate._RemoveLegacy()
        local first = take(applied)

        -- A second pass in the same game walks nobody again.
        party[0].innates = { "BFBT01" }
        BfBot.Innate._RemoveLegacy()
        return {
            first = first,
            again = take(applied),
            log = table.concat(logLines, ""),
            files = table.concat(openedFiles, ","),
            warnings = #warnings,
        }
        """
    )

    assert facts["first"] == "Ilauna:172:1:BFBT01|Ilauna:172:1:BFBT02"
    assert facts["again"] == ""
    assert "Removed 2 leftover F12 preset innate(s) from Ilauna" in facts["log"]
    assert "Baern" not in facts["log"]
    assert facts["files"] == "buffbot_innate.log:a"
    assert facts["warnings"] == 0


def test_remove_legacy_handles_a_member_again_after_rejoining(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        local baern = { id = 102, name = "Baern", innates = {} }
        party[1] = baern
        BfBot.Innate._RemoveLegacy()

        party[1] = nil
        BfBot.Innate._RemoveLegacy()
        local away = BfBot.Innate._cleaned[102] == nil

        baern.innates = { "BFBT11" }
        party[4] = baern
        BfBot.Innate._RemoveLegacy()
        return { away = away, rejoined = take(applied) }
        """
    )

    assert facts["away"]
    assert facts["rejoined"] == "Baern:172:1:BFBT11"


def test_remove_legacy_records_a_member_before_a_failed_removal(
    innate_lua: LuaRuntime,
) -> None:
    # A failure must not repeat every tick, and a member the failed tick did
    # not reach is still handled on the next one.
    facts = innate_lua.execute(
        """
        party[0] = { id = 101, name = "Ilauna", innates = { "BFBT01" } }
        party[1] = { id = 102, name = "Baern", innates = { "BFBT12" } }
        local realApply = EEex_GameObject_ApplyEffect
        EEex_GameObject_ApplyEffect = function()
            error("synthetic apply failure")
        end
        local ok, err = pcall(BfBot.Innate._RemoveLegacy)

        EEex_GameObject_ApplyEffect = realApply
        BfBot.Innate._RemoveLegacy()
        return {
            ok = ok,
            err = tostring(err),
            retried = take(applied),
            ilaunaKept = table.concat(party[0].innates, ","),
        }
        """
    )

    assert not facts["ok"]
    assert "synthetic apply failure" in facts["err"]
    assert facts["retried"] == "Baern:172:1:BFBT12"
    assert facts["ilaunaKept"] == "BFBT01"


def test_remove_legacy_warns_once_when_the_innates_cannot_be_read(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        party[0] = { id = 101, name = "Ilauna", innates = {}, unreadable = true }
        BfBot.Innate._RemoveLegacy()
        BfBot.Innate._RemoveLegacy()
        return { count = #warnings, warning = warnings[1] or "" }
        """
    )

    assert facts["count"] == 1
    assert "Could not read the innates of Ilauna" in facts["warning"]
    assert "synthetic walk failure" in facts["warning"]


def test_remove_legacy_warns_about_copies_the_engine_kept(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        party[0] = { id = 101, name = "Ilauna", innates = { "BFBT01", "BFBT01" } }
        EEex_GameObject_ApplyEffect = function(sprite, args)
            applied[#applied + 1] = args.res
        end
        BfBot.Innate._RemoveLegacy()
        return {
            attempts = #applied,
            warning = warnings[1] or "",
            log = table.concat(logLines, ""),
        }
        """
    )

    assert facts["attempts"] == 2
    assert "2 leftover F12 preset innate(s) remain on Ilauna" in facts["warning"]
    assert "Removed" not in facts["log"]


def test_remove_legacy_skips_members_without_an_object_id(
    innate_lua: LuaRuntime,
) -> None:
    # Without an id the member cannot be recorded, so its walk would repeat
    # every tick.
    facts = innate_lua.execute(
        """
        party[0] = { name = "Ilauna", innates = { "BFBT01" } }
        BfBot.Innate._RemoveLegacy()
        return { applied = take(applied), recorded = next(BfBot.Innate._cleaned) ~= nil }
        """
    )

    assert facts["applied"] == ""
    assert not facts["recorded"]


def test_remove_legacy_needs_no_luajit_io(innate_lua: LuaRuntime) -> None:
    # The removal writes no file, so it also runs where Quick Cast cannot.
    facts = innate_lua.execute(
        """
        BfBot._noIO = 1
        io = nil
        party[0] = { id = 101, name = "Ilauna", innates = { "BFBT01" } }
        BfBot.Innate._RemoveLegacy()
        return { applied = take(applied), kept = #party[0].innates }
        """
    )

    assert facts["applied"] == "Ilauna:172:1:BFBT01"
    assert facts["kept"] == 0


def test_init_registers_the_destroyed_listener_once_across_reload() -> None:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        io = nil
        Infinity_DisplayString = function(_) end
        BfBot = {}
        """
    )
    runtime.execute(CORE_SOURCE)
    runtime.execute(
        """
        destroyedCount = 0
        destroyedCallback = nil
        EEex_GameState_AddDestroyedListener = function(callback)
            destroyedCount = destroyedCount + 1
            destroyedCallback = callback
        end
        """
    )
    runtime.execute(INNATE_SOURCE)
    runtime.execute("BfBot.Innate.Init() BfBot.Innate.Init()")

    # A force reload replaces BfBot.Innate; the listener reaches the new one.
    runtime.execute(INNATE_SOURCE)
    facts = runtime.execute(
        """
        BfBot.Innate.Init()
        BfBot.Innate._cleaned[42] = true
        destroyedCallback()
        return {
            destroyedCount = destroyedCount,
            cleared = next(BfBot.Innate._cleaned) == nil,
        }
        """
    )

    assert facts["destroyedCount"] == 1
    assert facts["cleared"]


def test_init_registers_without_luajit_io() -> None:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        io = nil
        Infinity_DisplayString = function(_) end
        BfBot = { _noIO = 1 }
        """
    )
    runtime.execute(CORE_SOURCE)
    runtime.execute(
        """
        destroyedCount = 0
        EEex_GameState_AddDestroyedListener = function(_)
            destroyedCount = destroyedCount + 1
        end
        """
    )
    runtime.execute(INNATE_SOURCE)

    assert runtime.execute("BfBot.Innate.Init() return destroyedCount") == 1


def test_bfbotgo_stub_runs_nothing_and_survives_a_missing_effect(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        local touched = {}
        local function spy(name)
            return function() touched[#touched + 1] = name end
        end
        EEex_Action_QueueResponseStringOnAIBase = spy("queue")
        EEex_GameObject_Get = spy("lookup")
        BfBot._Display = spy("display")
        BfBot._DisplayOverhead = spy("overhead")
        BfBot.Exec = { Start = spy("start"), GetState = spy("state") }
        BfBot.Persist = {
            BuildQueueForCharacter = spy("build"),
            GetQuickCast = spy("quickcast"),
        }

        local first = pcall(BFBOTGO, { m_effectAmount = 2, m_dWFlags = 3 }, nil, nil)
        local second = pcall(BFBOTGO, nil)
        io = nil
        local third = pcall(BFBOTGO, { m_effectAmount = 0, m_dWFlags = 1 })
        return {
            ok = first and second and third,
            touched = table.concat(touched, ","),
            log = table.concat(logLines, ""),
        }
        """
    )

    assert facts["ok"]
    assert facts["touched"] == ""
    assert "Ignored a leftover F12 preset innate (slot 2, preset 3)" in facts["log"]
    assert "(slot nil, preset nil)" in facts["log"]


def test_runtime_spl_files_no_longer_include_preset_innates_or_their_remover(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        local written = BfBot.Innate._EnsureSPLFiles()
        return {
            written = written,
            files = table.concat(openedFiles, ","),
            presetBuilder = BfBot.Innate._BuildSPL == nil,
            removerBuilder = BfBot.Innate._BuildRemoverSPL == nil,
        }
        """
    )

    assert facts["written"] == 2
    assert facts["files"] == "override/BFBTCH.SPL:wb,override/BFBTCR.SPL:wb"
    assert facts["presetBuilder"]
    assert facts["removerBuilder"]


def test_no_shipped_runtime_module_grants_an_innate() -> None:
    # BfBotTst.lua grants one on purpose to test the removal end-to-end.
    offenders = [
        path.name
        for path in sorted((ROOT / "buffbot").glob("*.lua"))
        if path.name != "BfBotTst.lua"
        and re.search(
            r"AddSpecialAbility|ReallyForceSpellRES\(\"BFBTRM\"",
            path.read_text(encoding="utf-8"),
        )
    ]

    assert offenders == []


def test_in_game_leftover_innate_phase_is_wired_into_run_all() -> None:
    assert "function BfBot.Test.LegacyInnateCleanup()" in TEST_SOURCE
    assert re.search(
        r"local\s+legacyInnateOk\s*=\s*BfBot\.Test\.LegacyInnateCleanup\(\)",
        TEST_SOURCE,
    )
    assert re.search(r"return .*and legacyInnateOk", TEST_SOURCE)
