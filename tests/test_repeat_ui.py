from __future__ import annotations

import faulthandler
from pathlib import Path
import re
import sys

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")
UI_SOURCE = (ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8")
MENU_SOURCE = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")


@pytest.fixture
def repeat_ui_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        BfBot = {
            MAX_PRESETS = 8,
            MAX_SPELL_REPEATS = 5,
            Scan = {}, Class = {}, Innate = {}, Mp = {}, Exec = {}, Persist = {},
            _cache = { class = {}, scan = {} },
            _Warn = function(_) end,
            _Print = function(_) end,
            _StripColorEscape = function(s) return s end,
        }
        """
    )
    runtime.execute(PERSIST_SOURCE)
    runtime.execute(UI_SOURCE)
    return runtime


def test_repeat_step_wraps_through_the_shared_cap(
    repeat_ui_lua: LuaRuntime,
) -> None:
    facts = repeat_ui_lua.execute(
        """
        local step = BfBot.UI._StepSpellRepeat
        local result = {
            up = step(1, 1),
            upWrap = step(5, 1),
            downWrap = step(1, -1),
            malformedUp = step("5", 1),
            malformedDown = step(false, -1),
        }
        BfBot.MAX_SPELL_REPEATS = 3
        result.sharedCapWrap = step(3, 1)
        return result
        """
    )

    assert facts["up"] == 2
    assert facts["upWrap"] == 1
    assert facts["downWrap"] == 5
    assert facts["malformedUp"] == 2
    assert facts["malformedDown"] == 5
    assert facts["sharedCapWrap"] == 1


def test_spell_rows_normalize_repeat_text_and_use_theme_colors(
    repeat_ui_lua: LuaRuntime,
) -> None:
    facts = repeat_ui_lua.execute(
        """
        BfBot.UI._T = function(key)
            local colors = {
                text = "{7, 8, 9}",
                textMuted = "{4, 5, 6}",
                textAccent = "{1, 2, 3}",
            }
            return colors[key] or "{0, 0, 0}"
        end
        local preset = {
            spells = {
                DEFAULT = { on = 0, tgt = "p", pri = 1 },
                VALID = { on = 1, tgt = "s", pri = 2, rep = 5 },
                MALFORMED = { on = 0, tgt = "p", pri = 3, rep = "5" },
            },
        }
        local castable = {
            DEFAULT = {
                name = "Default", icon = "A", count = 1,
                duration = 60, durCat = "short",
            },
            VALID = {
                name = "Valid", icon = "B", count = 2,
                duration = 600, durCat = "long",
            },
            MALFORMED = {
                name = "Malformed", icon = "C", count = 0,
                duration = 0, durCat = "instant",
            },
        }
        local rows = BfBot.UI._BuildSpellRows({}, preset, castable, nil)
        buffbot_spellTable = rows
        local normal = BfBot.UI._RepeatColor(1)
        local accent = BfBot.UI._RepeatColor(2)
        local muted = BfBot.UI._RepeatColor(3)
        return {
            defaultRep = rows[1].rep,
            defaultText = rows[1].repeatText,
            validRep = rows[2].rep,
            validText = rows[2].repeatText,
            malformedRep = rows[3].rep,
            malformedText = rows[3].repeatText,
            normalR = normal[1],
            accentR = accent[1],
            mutedR = muted[1],
        }
        """
    )

    assert facts["defaultRep"] == 1
    assert facts["defaultText"] == "R1"
    assert facts["validRep"] == 5
    assert facts["validText"] == "R5"
    assert facts["malformedRep"] == 1
    assert facts["malformedText"] == "R1"
    assert facts["normalR"] == 7
    assert facts["accentR"] == 1
    assert facts["mutedR"] == 4


def test_selected_repeat_routes_party_and_summon_writes_without_refresh(
    repeat_ui_lua: LuaRuntime,
) -> None:
    facts = repeat_ui_lua.execute(
        """
        buffbot_isOpen = true
        buffbot_selectedRow = 1
        buffbot_spellTable = {
            {
                resref = "SPELL",
                rep = 1,
                repeatText = "R1",
                castable = 0,
                count = 0,
            },
        }
        BfBot.UI._presetIdx = 3
        BfBot.UI._GetSelectedSprite = function() return "party-sprite" end
        local partyCalls = 0
        local partyArgs = nil
        local persistedRep = 1
        BfBot.Persist.SetSpellRepeat = function(sprite, presetIdx, resref, value)
            partyCalls = partyCalls + 1
            partyArgs = { sprite, presetIdx, resref, value }
            persistedRep = value
        end
        BfBot.Persist.GetSpellRepeat = function(sprite, presetIdx, resref)
            assert(sprite == "party-sprite" and presetIdx == 3 and resref == "SPELL")
            return persistedRep
        end
        local refreshCalls = 0
        BfBot.UI._Refresh = function() refreshCalls = refreshCalls + 1 end

        BfBot.UI._view = "party"
        BfBot.UI.StepSelectedRepeat(1)
        local partyRep = buffbot_spellTable[1].rep
        local partyText = buffbot_spellTable[1].repeatText
        local partySelection = buffbot_selectedRow

        local summonEntry = { rep = 1 }
        BfBot.UI._SummonSpellEntry = function(resref, create)
            assert(resref == "SPELL" and create == 1)
            return summonEntry
        end
        BfBot.UI._view = "summons"
        buffbot_spellTable[1].rep = 1
        buffbot_spellTable[1].repeatText = "R1"
        BfBot.UI.StepSelectedRepeat(-1)

        return {
            partyCalls = partyCalls,
            partySprite = partyArgs[1],
            partyPreset = partyArgs[2],
            partyResref = partyArgs[3],
            partyValue = partyArgs[4],
            partyRep = partyRep,
            partyText = partyText,
            partySelection = partySelection,
            summonRep = summonEntry.rep,
            summonRowRep = buffbot_spellTable[1].rep,
            summonRowText = buffbot_spellTable[1].repeatText,
            finalSelection = buffbot_selectedRow,
            refreshCalls = refreshCalls,
        }
        """
    )

    assert facts["partyCalls"] == 1
    assert facts["partySprite"] == "party-sprite"
    assert facts["partyPreset"] == 3
    assert facts["partyResref"] == "SPELL"
    assert facts["partyValue"] == 2
    assert facts["partyRep"] == 2
    assert facts["partyText"] == "R2"
    assert facts["partySelection"] == 1
    assert facts["summonRep"] == 5
    assert facts["summonRowRep"] == 5
    assert facts["summonRowText"] == "R5"
    assert facts["finalSelection"] == 1
    assert facts["refreshCalls"] == 0


def test_party_repeat_row_reflects_persisted_readback_after_no_op_setter(
    repeat_ui_lua: LuaRuntime,
) -> None:
    facts = repeat_ui_lua.execute(
        """
        buffbot_selectedRow = 1
        buffbot_spellTable = {
            { resref = "SPELL", rep = 1, repeatText = "R1", castable = 0 },
        }
        BfBot.UI._view = "party"
        BfBot.UI._presetIdx = 2
        BfBot.UI._GetSelectedSprite = function() return "party-sprite" end
        local setterCalls = 0
        local getterCalls = 0
        BfBot.Persist.SetSpellRepeat = function()
            setterCalls = setterCalls + 1
            -- Simulate a missing preset: the real setter returns without writing.
        end
        BfBot.Persist.GetSpellRepeat = function()
            getterCalls = getterCalls + 1
            return 1
        end

        BfBot.UI.StepSelectedRepeat(1)
        return {
            setterCalls = setterCalls,
            getterCalls = getterCalls,
            rowRep = buffbot_spellTable[1].rep,
            rowText = buffbot_spellTable[1].repeatText,
            selection = buffbot_selectedRow,
        }
        """
    )

    assert facts["setterCalls"] == 1
    assert facts["getterCalls"] == 1
    assert facts["rowRep"] == 1
    assert facts["rowText"] == "R1"
    assert facts["selection"] == 1


def test_repeat_footer_text_and_tooltip_follow_the_selected_row(
    repeat_ui_lua: LuaRuntime,
) -> None:
    text, tooltip = repeat_ui_lua.execute(
        """
        buffbot_selectedRow = 2
        buffbot_spellTable = { { rep = 1 }, { rep = 5 } }
        return BfBot.UI._RepeatButtonText(), BfBot.UI._RepeatTooltip()
        """
    )

    assert text == "Repeat: 5"
    assert tooltip == (
        "Cast this spell 5 times per resolved target. Each attempt uses a "
        "spell slot and normal casting rules. Left-click increases; "
        "right-click decreases. Range 1–5."
    )

    dynamic_text, dynamic_tooltip = repeat_ui_lua.execute(
        """
        BfBot.MAX_SPELL_REPEATS = 3
        buffbot_selectedRow = 1
        buffbot_spellTable = { { rep = 3 } }
        return BfBot.UI._RepeatButtonText(), BfBot.UI._RepeatTooltip()
        """
    )
    assert dynamic_text == "Repeat: 3"
    assert dynamic_tooltip.endswith("Range 1–3.")


_MENU_ELEMENT_OPEN = re.compile(
    r"(?m)^[ \t]*(?:list|button|text|label|handle)\s*\{"
)


def _balanced_brace_end(source: str, opening_brace: int) -> int:
    depth = 0
    quote: str | None = None
    escaped = False
    for index in range(opening_brace, len(source)):
        char = source[index]
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in ('"', "'", "`"):
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    raise AssertionError("unbalanced .menu element")


def _menu_element_block(source: str, anchor_pattern: str) -> str:
    anchor = re.search(anchor_pattern, source)
    assert anchor, f"missing .menu anchor: {anchor_pattern}"
    candidates = list(_MENU_ELEMENT_OPEN.finditer(source, 0, anchor.start() + 1))
    for candidate in reversed(candidates):
        opening_brace = source.index("{", candidate.start(), candidate.end())
        end = _balanced_brace_end(source, opening_brace)
        if end >= anchor.end():
            return source[candidate.start():end]
    raise AssertionError(f"no enclosing .menu element for: {anchor_pattern}")


def _spell_list_block() -> str:
    return _menu_element_block(MENU_SOURCE, r"\bname\s+['\"]bbList['\"]")


def _named_item_block(name: str) -> str:
    return _menu_element_block(
        MENU_SOURCE,
        rf"\bname\s+['\"]{re.escape(name)}['\"]",
    )


def test_menu_block_parser_tolerates_spacing_and_quoted_braces() -> None:
    source = """
      button   {
        tooltip lua "return { 1, 2, 3 }"
        name 'sample'
        area 1 2 3 4
      }
    """
    block = _menu_element_block(source, r"\bname\s+['\"]sample['\"]")
    assert "tooltip lua" in block
    assert re.search(r"\barea\s+1\s+2\s+3\s+4\b", block)


def _static_area(name: str) -> tuple[int, int, int, int]:
    block = _named_item_block(name)
    match = re.search(r"\barea\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)", block)
    assert match, f"no static area for {name}"
    return tuple(int(value) for value in match.groups())


def _assert_horizontal_group_is_valid(
    areas: dict[str, tuple[int, int, int, int]],
    names: list[str],
    left: int,
    right: int,
) -> None:
    intervals = []
    for name in names:
        x, _, width, height = areas[name]
        assert width > 0 and height > 0
        assert left <= x and x + width <= right, (name, areas[name])
        intervals.append((x, x + width, name))
    intervals.sort()
    for (_, prior_end, prior_name), (next_start, _, next_name) in zip(
        intervals, intervals[1:]
    ):
        assert prior_end <= next_start, (prior_name, next_name)


def test_spell_list_columns_and_cell_actions_match_the_repeat_design() -> None:
    block = _spell_list_block()
    widths = [int(value) for value in re.findall(r"\bwidth\s+(\d+)", block)]
    actions = re.findall(r"\baction\s+\"([^\"]+)\"", block)

    assert widths == [8, 8, 26, 10, 10, 8, 24, 6]
    assert sum(widths) == 100
    assert "repeatText" in block
    assert "BfBot.UI._RepeatColor(rowNumber)" in block
    assert len(actions) == 1
    action = actions[0]
    assert "rowNumber" not in action
    assert "BfBot.UI.ToggleSpell(buffbot_selectedRow)" in action
    assert "cellNumber == 6" in action
    assert "BfBot.UI.StepSelectedRepeat(1)" in action
    assert "cellNumber == 8" in action
    assert "BfBot.UI.ToggleLock(buffbot_selectedRow)" in action


def test_repeat_footer_binding_is_selection_only_and_supports_both_directions() -> None:
    block = _named_item_block("bbRepeat")

    assert re.search(
        r"\benabled\s+['\"]BfBot\.UI\._HasSelection\(\)['\"]", block
    )
    assert re.search(
        r"\baction\s+['\"]BfBot\.UI\.StepSelectedRepeat\(1\)['\"]", block
    )
    assert re.search(
        r"\bactionAlt\s+['\"]BfBot\.UI\.StepSelectedRepeat\(-1\)['\"]", block
    )
    assert re.search(
        r"\btext\s+lua\s+['\"]BfBot\.UI\._RepeatButtonText\(\)['\"]", block
    )
    assert re.search(
        r"\btooltip\s+lua\s+['\"]BfBot\.UI\._RepeatTooltip\(\)['\"]", block
    )
    assert all(word not in block for word in ("castable", "count", ".on"))
    assert _static_area("bbRepeat")[2:] == (90, 28)


def test_static_minimum_layout_keeps_all_footer_controls_in_bounds() -> None:
    groups = [
        ["bbAdd", "bbRmv", "bbRepeat", "bbExp", "bbImp"],
        ["bbTog", "bbTgt", "bbUp", "bbDn", "bbSort", "bbDel"],
        ["bbVTog", "bbVTgt", "bbVVar", "bbVUp", "bbVDn", "bbVSort", "bbVDel"],
        ["bbCast", "bbCastChar", "bbStop", "bbQC", "bbClose"],
    ]
    areas = {name: _static_area(name) for group in groups for name in group}

    for group in groups:
        _assert_horizontal_group_is_valid(areas, group, 350, 870)

    list_match = re.search(
        r"\barea\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+"
        r"name\s+\"bbList\"",
        _spell_list_block(),
    )
    assert list_match
    list_x, list_y, list_w, list_h = map(int, list_match.groups())
    first_footer_y = areas["bbAdd"][1]
    assert 350 <= list_x and list_x + list_w <= 870
    assert list_y >= 50 and list_y + list_h <= first_footer_y
    for name, (_, y, _, height) in areas.items():
        assert 50 <= y and y + height <= 560, name


def test_dynamic_minimum_layout_keeps_list_and_all_footer_rows_valid(
    repeat_ui_lua: LuaRuntime,
) -> None:
    # BfBot.UI._Layout intentionally uses Lua pcall for optional paired text
    # overlays. Lupa implements protected calls with a Windows SEH signal that
    # pytest's faulthandler reports despite a successful Lua result.
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        lua_areas = repeat_ui_lua.execute(
            """
            local areas = {}
            Infinity_GetScreenSize = function() return 1000, 700 end
            Infinity_SetArea = function(name, x, y, w, h)
                areas[name] = { x, y, w, h }
            end
            BfBot.UI._panelX = 100
            BfBot.UI._panelY = 50
            BfBot.UI._panelW = 550
            BfBot.UI._panelH = 350
            BfBot.UI._Layout()
            return areas
            """
        )
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    groups = [
        ["bbAdd", "bbRmv", "bbRepeat", "bbExp", "bbImp"],
        ["bbTog", "bbTgt", "bbUp", "bbDn", "bbSort", "bbDel"],
        ["bbVTog", "bbVTgt", "bbVVar", "bbVUp", "bbVDn", "bbVSort", "bbVDel"],
        ["bbCast", "bbCastChar", "bbStop", "bbQC", "bbClose"],
    ]

    def area(name: str) -> tuple[int, int, int, int]:
        values = lua_areas[name]
        return tuple(int(values[index]) for index in range(1, 5))

    areas = {name: area(name) for group in groups for name in group}
    assert areas["bbRepeat"][2:] == (90, 28)
    for group in groups:
        _assert_horizontal_group_is_valid(areas, group, 110, 640)

    list_x, list_y, list_w, list_h = area("bbList")
    assert (list_x, list_w) == (110, 530)
    assert list_y >= 50 and list_y + list_h <= areas["bbAdd"][1]
    for name, (_, y, _, height) in areas.items():
        assert 50 <= y and y + height <= 400, name
