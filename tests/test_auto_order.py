"""The per-preset cast order toggle.

Off by default, because "the player's priority is always respected" is a
standing design rule here. On, the preset casts its longest-lasting buffs
first — and never writes that order back, so switching it off returns the
manual order untouched. That last part is the whole reason this is a view
and not a one-shot sort, and it is what these tests mostly check.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
CORE_SOURCE = (ROOT / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")
UI_SOURCE = (ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8")
MENU_SOURCE = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")


@pytest.fixture
def order_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute(CORE_SOURCE)
    runtime.execute(
        """
        BfBot.Scan = {}
        BfBot.Class = {}
        BfBot.Innate = {}
        BfBot.Mp = {}
        """
    )
    runtime.execute(PERSIST_SOURCE)
    return runtime


def _names(rows) -> list[str]:
    return [rows[index] for index in range(1, len(rows) + 1)]


# --------------------------------------------------------------------- core


def test_the_order_puts_the_longest_first_and_the_unknown_last(order_lua) -> None:
    order = order_lua.execute(
        """
        local ordered = BfBot.Persist.OrderByDuration({
            { resref = "SHORT", dur = 30 },
            { resref = "UNKNOWN" },
            { resref = "PERM", dur = -1 },
            { resref = "LONG", dur = 3600 },
        })
        local out = {}
        for i, item in ipairs(ordered) do out[i] = item.resref end
        return out
        """
    )
    assert _names(order) == ["PERM", "LONG", "SHORT", "UNKNOWN"]


def test_a_locked_row_keeps_its_place_and_the_rest_fill_in_around_it(
    order_lua,
) -> None:
    order = order_lua.execute(
        """
        local ordered = BfBot.Persist.OrderByDuration({
            { resref = "SHORT", dur = 30 },
            { resref = "PINNED", dur = 1, lock = 1 },
            { resref = "LONG", dur = 3600 },
        })
        local out = {}
        for i, item in ipairs(ordered) do out[i] = item.resref end
        return out
        """
    )
    # PINNED holds row 2 although it is the shortest; LONG and SHORT sort
    # into the rows left over.
    assert _names(order) == ["LONG", "PINNED", "SHORT"]


def test_equal_durations_keep_the_order_the_player_gave_them(order_lua) -> None:
    order = order_lua.execute(
        """
        local ordered = BfBot.Persist.OrderByDuration({
            { resref = "B", dur = 60 },
            { resref = "A", dur = 60 },
            { resref = "C", dur = 60 },
        })
        local out = {}
        for i, item in ipairs(ordered) do out[i] = item.resref end
        return out
        """
    )
    assert _names(order) == ["B", "A", "C"]


def test_off_is_absence_and_only_the_number_one_turns_it_on(order_lua) -> None:
    facts = order_lua.execute(
        """
        return {
            absent = BfBot.Persist.IsAutoOrder({}) and 1 or 0,
            zero = BfBot.Persist.IsAutoOrder({ ord = 0 }) and 1 or 0,
            one = BfBot.Persist.IsAutoOrder({ ord = 1 }) and 1 or 0,
            text = BfBot.Persist.IsAutoOrder({ ord = "1" }) and 1 or 0,
            two = BfBot.Persist.IsAutoOrder({ ord = 2 }) and 1 or 0,
            notATable = BfBot.Persist.IsAutoOrder(nil) and 1 or 0,
        }
        """
    )
    assert facts["one"] == 1
    assert [facts[key] for key in ("absent", "zero", "text", "two", "notATable")] == [
        0,
        0,
        0,
        0,
        0,
    ]


def test_validation_heals_a_bad_flag_into_off_and_needs_no_migration(
    order_lua,
) -> None:
    facts = order_lua.execute(
        """
        local config = BfBot.Persist.GetDefaultConfig()
        config.presets[1].ord = 7
        config.presets[2].ord = 1
        config.presets[3] = { name = "P3", cat = "custom", spells = {} }
        config = BfBot.Persist._ValidateConfig(config)
        return {
            healed = config.presets[1].ord == nil and 1 or 0,
            kept = config.presets[2].ord,
            untouched = config.presets[3].ord == nil and 1 or 0,
            version = config.v,
        }
        """
    )
    assert facts["healed"] == 1
    assert facts["kept"] == 1
    # A preset that never asked for the flag keeps the shape it had, so a
    # save from before the toggle existed loads without a migration.
    assert facts["untouched"] == 1
    assert facts["version"] == 10


# ------------------------------------------------------------------ ranking


RANK_SETUP = """
local preset = {
    ord = %s,
    spells = {
        AAA = { pri = 1 },
        BBB = { pri = 2 },
        CCC = { pri = 3 },
    },
}
local durations = { AAA = 30, BBB = 3600, CCC = 300 }
local rank = BfBot.Persist.EffectiveOrder(preset, function(resref)
    return durations[resref]
end)
return { AAA = rank.AAA, BBB = rank.BBB, CCC = rank.CCC,
         pri = preset.spells.AAA.pri .. "," .. preset.spells.BBB.pri
               .. "," .. preset.spells.CCC.pri }
"""


def test_with_the_toggle_off_the_rank_is_the_players_own_order(order_lua) -> None:
    facts = order_lua.execute(RANK_SETUP % "nil")
    assert (facts["AAA"], facts["BBB"], facts["CCC"]) == (1, 2, 3)


def test_with_the_toggle_on_the_rank_is_longest_first(order_lua) -> None:
    facts = order_lua.execute(RANK_SETUP % "1")
    assert (facts["BBB"], facts["CCC"], facts["AAA"]) == (1, 2, 3)


def test_ranking_never_writes_the_players_priorities_back(order_lua) -> None:
    """The automatic order is a view. If it wrote through, switching the
    toggle off would hand back a list the player never arranged."""
    facts = order_lua.execute(RANK_SETUP % "1")
    assert facts["pri"] == "1,2,3"


# ------------------------------------------------------------------- queues


def test_the_cast_queue_follows_the_toggle(order_lua) -> None:
    facts = order_lua.execute(
        """
        local caster = {
            m_id = 7,
            getName = function() return "Caster" end,
            m_scriptName = { get = function() return "CASTER_DV" end },
        }
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return caster end
            return nil
        end
        local config = BfBot.Persist.GetDefaultConfig()
        config.presets[1].spells = {
            SHORT = { on = 1, tgt = "s", pri = 1 },
            LONG  = { on = 1, tgt = "s", pri = 2 },
            MID   = { on = 1, tgt = "s", pri = 3 },
        }
        BfBot.Persist.GetConfig = function() return config end
        BfBot.Persist.GetPref = function(key)
            if key == "SummonsJoinCast" then return 0 end
            return BfBot.Persist._INI_DEFAULTS[key]
        end
        BfBot.Persist._CollectLiveCloneDescriptors = function() return {} end
        BfBot.Scan.Invalidate = function() end
        BfBot.Scan.GetCastableSpells = function()
            return {
                SHORT = { count = 1, name = "Short", kind = "spl", duration = 30 },
                LONG  = { count = 1, name = "Long",  kind = "spl", duration = 3600 },
                MID   = { count = 1, name = "Mid",   kind = "spl", duration = 300 },
            }
        end
        BfBot.Exec = { _logFile = "unused.log", _LogEntry = function() end }
        BfBot._OpenLogAppend = function() BfBot._logHandle = {} end
        BfBot._CloseLog = function() BfBot._logHandle = nil end

        local function spells(queue)
            local out = {}
            for index, entry in ipairs(queue or {}) do out[index] = entry.spell end
            return out
        end

        BfBot.Persist.DrainBuildSkips()
        local manual = spells(BfBot.Persist.BuildQueueFromPreset(1))
        config.presets[1].ord = 1
        BfBot.Persist.DrainBuildSkips()
        local automatic = spells(BfBot.Persist.BuildQueueFromPreset(1))
        BfBot.Persist.DrainBuildSkips()
        local character = spells(BfBot.Persist.BuildQueueForCharacter(0, 1))
        BfBot.Persist.DrainBuildSkips()
        return {
            manual = table.concat(manual, ","),
            automatic = table.concat(automatic, ","),
            character = table.concat(character, ","),
            pri = config.presets[1].spells.SHORT.pri,
        }
        """
    )
    assert facts["manual"] == "SHORT,LONG,MID"
    assert facts["automatic"] == "LONG,MID,SHORT"
    # Cast Character builds through its own function and must agree.
    assert facts["character"] == "LONG,MID,SHORT"
    assert facts["pri"] == 1


# -------------------------------------------------------------- party reach


def test_the_toggle_applies_to_everyone_sharing_that_preset_index(
    order_lua,
) -> None:
    """Presets are parallel across the party. A toggle that applied to one
    character would make "Pre-Battle" mean two things in one party."""
    facts = order_lua.execute(
        """
        local configs = {}
        local party = {}
        for slot = 0, 2 do
            party[slot] = { m_id = slot }
            configs[slot] = BfBot.Persist.GetDefaultConfig()
        end
        EEex_Sprite_GetInPortrait = function(slot) return party[slot] end
        BfBot.Persist.GetConfig = function(sprite) return configs[sprite.m_id] end

        BfBot.Persist.SetAutoOrderAll(2, 1)
        local on = {}
        for slot = 0, 2 do on[slot + 1] = configs[slot].presets[2].ord end
        BfBot.Persist.SetAutoOrderAll(2, 0)
        local offIsAbsent = true
        for slot = 0, 2 do
            if configs[slot].presets[2].ord ~= nil then offIsAbsent = false end
        end
        return {
            first = on[1], second = on[2], third = on[3],
            untouchedPreset = configs[0].presets[1].ord == nil and 1 or 0,
            offIsAbsent = offIsAbsent and 1 or 0,
        }
        """
    )
    assert (facts["first"], facts["second"], facts["third"]) == (1, 1, 1)
    assert facts["untouchedPreset"] == 1
    assert facts["offIsAbsent"] == 1


def test_a_new_companion_inherits_the_order_but_never_quick_cast(
    order_lua,
) -> None:
    facts = order_lua.execute(
        """
        local protagonist, companion = { id = "p" }, { id = "c" }
        local source = BfBot.Persist.GetDefaultConfig()
        source.presets[1].ord = 1
        source.presets[1].qc = 2
        source.presets[2].ord = nil
        BfBot.Persist._GetProtagonist = function() return protagonist end
        EEex_Sprite_GetCharacterIndex = function() return 1 end
        EEex_Sprite_GetInPortrait = function() return nil end
        EEex_GetUDAux = function(sprite)
            assert(sprite == protagonist)
            return { BB = source }
        end
        local inherited = BfBot.Persist._GetInheritedPresetStructure(companion)
        return {
            ord = inherited and inherited.presets[1].ord,
            qc = inherited and inherited.presets[1].qc,
            offStaysOff = (inherited
                and inherited.presets[2].ord == nil) and 1 or 0,
        }
        """
    )
    assert facts["ord"] == 1
    assert facts["qc"] == 0
    assert facts["offStaysOff"] == 1


# ---------------------------------------------------------------- the panel


def _item_block(name: str) -> str:
    at = MENU_SOURCE.index('name    "%s"' % name)
    return MENU_SOURCE[MENU_SOURCE.rindex("{", 0, at) : MENU_SOURCE.index("}", at) + 1]


@pytest.mark.parametrize("name", ["bbOrder", "bbVOrder"])
def test_both_footer_rows_carry_the_toggle(name: str) -> None:
    block = _item_block(name)
    assert 'action  "BfBot.UI.ToggleAutoOrder()"' in block
    assert 'text lua "BfBot.UI._AutoOrderLabel()"' in block
    assert 'tooltip lua "BfBot.UI._AutoOrderTooltip()"' in block
    assert 'text color lua "BfBot.UI._AutoOrderColor()"' in block
    # It has to stay a text item: only a text item takes an action together
    # with `text color lua`, and the label changes colour when on.
    assert MENU_SOURCE[: MENU_SOURCE.index(block)].rstrip().endswith("text")
    # The plate underneath follows through _Layout's "_b" pairing.
    assert 'bam lua "BfBot.UI._PlateBam()"' in _item_block(name + "_b")


@pytest.mark.parametrize("name", ["bbOrder", "bbVOrder"])
def test_the_layout_places_the_toggle_with_the_reorder_controls(name: str) -> None:
    layout = re.search(
        r"function BfBot\.UI\._Layout\(\).*?\n^end$", UI_SOURCE, re.S | re.M
    ).group(0)
    row = next(line for line in layout.splitlines() if '"%s"' % name in line)
    assert "Up" in row and "Sort" in row


def test_sorting_by_hand_refuses_while_the_preset_orders_itself() -> None:
    """The menu greys the button, but a menu gate is not a contract: a
    write-through sort during automatic order would destroy the manual one."""
    body = re.search(
        r"function BfBot\.UI\.SortByDuration\(\).*?\n^end$", UI_SOURCE, re.S | re.M
    ).group(0)
    assert "if BfBot.UI._IsAutoOrder() then return end" in body
    # And it uses the shared implementation rather than a second copy.
    assert "BfBot.Persist.OrderByDuration(buffbot_spellTable)" in body
    assert "table.sort" not in body
