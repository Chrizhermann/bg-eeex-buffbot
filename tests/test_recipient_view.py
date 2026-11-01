"""The recipient view's display layer (issue #81, step 3).

`BfBot.Plan.ByRecipient` answers who receives what; these tests cover what the
panel does with that answer — which rows the table gets, what each cell says,
and when the perspective button is allowed to switch. The projection itself is
covered in `test_plan_model.py`.

The real localization module is loaded, because half of what this layer
produces is formatted text and a stubbed catalog would prove nothing about the
placeholders.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LOC_SOURCE = (ROOT / "buffbot/BfBotLoc.lua").read_text(encoding="utf-8")
UI_SOURCE = (ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8")
# `BfBot.UI._T` is defined by the theme module, which sets up BfBot.UI
# before BfBotUI loads, so a name the menu calls can live in either.
THEME_SOURCE = (ROOT / "buffbot/BfBotThm.lua").read_text(encoding="utf-8")
MODULE_SOURCES = UI_SOURCE + THEME_SOURCE

# The display layer only. Pulling in all of BfBotUI would drag the engine's
# menu globals in with it, and these functions are pure.
EXTRACTED = (
    "_IsCasterPerspective", "_IsRecipientView", "_CanTogglePerspective",
    "_PerspectiveBtnLabel", "_PerspectiveBtnTooltip", "TogglePerspective",
    "_EntryState", "_EntrySourceLabel", "_EntryCountLabel",
    "_BuildRecipientRows", "_RecipientCellName", "_RecipientCellWhat",
    "_RecipientCellSource", "_RecipientCellCount", "_RecipientRow",
    "_RecipientNameColor", "_RecipientWhatColor",
)


@pytest.fixture
def lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute("io = nil")
    runtime.execute(
        """
        BfBot = { UI = {}, Plan = {} }
        -- The panel's own state the display layer reads.
        T_PartyView = true
        T_Refreshes = 0
        T_Cleared = 0
        BfBot.UI._view = "party"
        BfBot.UI._IsPartyView = function() return T_PartyView end
        BfBot.UI._Refresh = function() T_Refreshes = T_Refreshes + 1 end
        BfBot.UI._ClearSpellSelection = function() T_Cleared = T_Cleared + 1 end
        -- Colour names, not colours: a test asserts which tone a row gets,
        -- and the palette is another module's business.
        BfBot.UI._T = function(key) return key end
        """
    )
    runtime.execute(LOC_SOURCE)
    for name in EXTRACTED:
        pattern = re.compile(
            r"^function BfBot\.UI\." + re.escape(name) + r"\(.*?^end$",
            re.S | re.M)
        match = pattern.search(UI_SOURCE)
        assert match, f"{name} not found"
        runtime.execute(match.group(0))
    # Module state the real module sets at load; the extraction skips it.
    runtime.execute('BfBot.UI._perspective = "caster"')
    runtime.execute("buffbot_recipientTable = {}")
    return runtime


def _project(lua: LuaRuntime, recipients: str, snapshot: str = "nil") -> None:
    """Build the table from a literal ByRecipient-shaped result."""
    lua.execute(
        "buffbot_recipientTable = BfBot.UI._BuildRecipientRows(%s, %s)"
        % (recipients, snapshot)
    )


# ---------------------------------------------------------------------------
# Which end of the plan the panel reads from
# ---------------------------------------------------------------------------


def test_the_panel_opens_on_the_caster_reading(lua):
    # Deliberate: the recipient reading becomes the default only once it has
    # been lived with, which is a separate decision.
    assert lua.eval("BfBot.UI._IsCasterPerspective()") is True
    assert lua.eval("BfBot.UI._IsRecipientView()") is False


def test_switching_changes_the_reading_and_nothing_else(lua):
    lua.execute("BfBot.UI.TogglePerspective()")
    assert lua.eval("BfBot.UI._IsRecipientView()") is True
    assert lua.eval("BfBot.UI._IsCasterPerspective()") is False
    # A view change refreshes and drops the selection; it rewrites no request.
    assert lua.eval("T_Refreshes") == 1
    assert lua.eval("T_Cleared") == 1
    lua.execute("BfBot.UI.TogglePerspective()")
    assert lua.eval("BfBot.UI._IsCasterPerspective()") is True


def test_the_summons_view_has_no_recipient_reading(lua):
    """It keeps its own caster list, so there is nothing to group by."""
    lua.execute("BfBot.UI.TogglePerspective(); T_PartyView = false")
    assert lua.eval("BfBot.UI._perspective") == "recipient"
    # Remembered, not applied: switching to summons and back must leave the
    # panel as the player had it.
    assert lua.eval("BfBot.UI._IsRecipientView()") is False
    assert lua.eval("BfBot.UI._CanTogglePerspective()") is False
    lua.execute("T_PartyView = true")
    assert lua.eval("BfBot.UI._IsRecipientView()") is True


def test_the_button_does_nothing_where_it_cannot_apply(lua):
    lua.execute("T_PartyView = false; BfBot.UI.TogglePerspective()")
    assert lua.eval("BfBot.UI._perspective") == "caster"
    assert lua.eval("T_Refreshes") == 0


def test_the_button_names_what_clicking_it_switches_to(lua):
    # The caption is the destination, the tooltip describes where you are.
    assert lua.eval("BfBot.UI._PerspectiveBtnLabel()") == "By recipient"
    assert "what each character will cast" in lua.eval(
        "BfBot.UI._PerspectiveBtnTooltip()")
    lua.execute("BfBot.UI.TogglePerspective()")
    assert lua.eval("BfBot.UI._PerspectiveBtnLabel()") == "By caster"
    assert "what each character receives" in lua.eval(
        "BfBot.UI._PerspectiveBtnTooltip()")


# ---------------------------------------------------------------------------
# What the table gets
# ---------------------------------------------------------------------------


ONE_PLANNED = """{ { key = "imoen", name = "Imoen", slot = 0,
    planned = 1, short = 0, entries = {
        { group = "SPWI001", repeats = 1, planned = 1,
          sources = { { actor = "jan" } }, reasons = {}, duration = 300 } } } }"""


def test_a_recipient_becomes_a_header_row_followed_by_its_entries(lua):
    _project(lua, ONE_PLANNED)
    assert lua.eval("#buffbot_recipientTable") == 2
    assert lua.eval("buffbot_recipientTable[1].kind") == "recipient"
    assert lua.eval("buffbot_recipientTable[2].kind") == "entry"
    # Only the header carries the name, so the names form a readable margin.
    assert lua.eval("BfBot.UI._RecipientCellName(1)") == "Imoen"
    assert lua.eval("BfBot.UI._RecipientCellName(2)") == ""


def test_a_character_with_nothing_planned_still_says_so(lua):
    """An empty stretch of table reads as a panel that failed to load."""
    _project(lua, """{ { key = "minsc", name = "Minsc", slot = 1,
        planned = 0, short = 0, entries = {} } }""")
    assert lua.eval("#buffbot_recipientTable") == 2
    assert lua.eval("buffbot_recipientTable[2].kind") == "empty"
    assert lua.eval("BfBot.UI._RecipientCellWhat(2)") == "Nothing planned"
    assert lua.eval("BfBot.UI._RecipientCellSource(2)") == ""
    assert lua.eval("BfBot.UI._RecipientCellCount(2)") == ""


def test_the_header_says_how_much_of_this_character_is_covered(lua):
    _project(lua, """{ { key = "imoen", name = "Imoen", slot = 0,
        planned = 2, short = 1, entries = {} } }""")
    assert lua.eval("BfBot.UI._RecipientCellWhat(1)") == "2 of 3 covered"


def test_a_buff_is_named_the_way_the_caster_view_names_it(lua):
    # The name comes from the snapshot's own group, which is the scan's, so
    # the two readings of one plan cannot disagree about what a buff is.
    _project(lua, ONE_PLANNED,
             '{ groups = { SPWI001 = { name = "Armor", icon = "ISPWI001" } },'
             '  actors = { jan = { name = "Jan" } } }')
    assert lua.eval("BfBot.UI._RecipientCellWhat(2)") == "Armor"
    assert lua.eval("buffbot_recipientTable[2].icon") == "ISPWI001"


def test_an_unknown_group_falls_back_to_its_resref_rather_than_blank(lua):
    _project(lua, ONE_PLANNED, "{ groups = {}, actors = {} }")
    assert lua.eval("BfBot.UI._RecipientCellWhat(2)") == "SPWI001"


def test_a_personal_cast_names_its_caster(lua):
    _project(lua, ONE_PLANNED,
             '{ groups = {}, actors = { jan = { name = "Jan" } } }')
    assert lua.eval("BfBot.UI._RecipientCellSource(2)") == "from Jan"


def test_without_a_snapshot_a_source_still_reads_as_something(lua):
    # A name is presentation; a missing one must not cost the row.
    _project(lua, ONE_PLANNED)
    assert lua.eval("BfBot.UI._RecipientCellSource(2)") == "from jan"


def test_two_casters_are_both_named(lua):
    _project(lua, """{ { key = "minsc", name = "Minsc", slot = 0,
        planned = 1, short = 0, entries = {
            { group = "g", repeats = 2, planned = 2,
              sources = { { actor = "jan" }, { actor = "aerie" } },
              reasons = {} } } } }""",
             '{ groups = {}, actors = { jan = { name = "Jan" },'
             ' aerie = { name = "Aerie" } } }')
    assert lua.eval("BfBot.UI._RecipientCellSource(2)") == "from Jan, Aerie"


def test_a_party_wide_cast_says_so_instead_of_naming_a_caster(lua):
    """The point is that it covers everybody, not who happened to cast it."""
    _project(lua, """{ { key = "imoen", name = "Imoen", slot = 0,
        planned = 1, short = 0, entries = {
            { group = "chant", partyWide = true, repeats = 1, planned = 1,
              sources = { { actor = "aerie" } }, reasons = {} } } } }""",
             '{ groups = {}, actors = { aerie = { name = "Aerie" } } }')
    assert lua.eval("BfBot.UI._RecipientCellSource(2)") == "whole party"
    assert lua.eval("buffbot_recipientTable[2].partyWide") == 1


def test_an_unplanned_entry_says_there_is_nobody_to_cast_it(lua):
    _project(lua, """{ { key = "imoen", name = "Imoen", slot = 0,
        planned = 0, short = 1, entries = {
            { group = "g", repeats = 1, planned = 0, sources = {},
              reasons = { "no_unreserved_uses" } } } } }""")
    assert lua.eval("BfBot.UI._RecipientCellSource(2)") == "no caster"
    assert lua.eval("buffbot_recipientTable[2].reason") == "no_unreserved_uses"


@pytest.mark.parametrize("planned,repeats,expected", [
    (1, 1, ""),          # a single cast needs no count
    (0, 1, ""),          # not even when it failed: the tone carries that
    (3, 3, "3 of 3"),
    (2, 3, "2 of 3"),
    (0, 3, "0 of 3"),
])
def test_a_count_appears_only_where_it_carries_information(
        lua, planned, repeats, expected):
    _project(lua, """{ { key = "imoen", name = "Imoen", slot = 0,
        planned = 0, short = 0, entries = {
            { group = "g", repeats = %d, planned = %d, sources = {},
              reasons = {} } } } }""" % (repeats, planned))
    assert lua.eval("BfBot.UI._RecipientCellCount(2)") == expected


@pytest.mark.parametrize("planned,repeats,state", [
    (3, 3, "planned"),
    (2, 3, "partial"),
    (0, 3, "missing"),
    (1, 1, "planned"),
    (0, 1, "missing"),
    (0, 0, "missing"),
])
def test_three_states_because_two_would_hide_the_middle_one(
        lua, planned, repeats, state):
    assert lua.eval(
        "BfBot.UI._EntryState({ repeats = %d, planned = %d })"
        % (repeats, planned)) == state


def test_the_partly_planned_row_gets_a_tone_of_its_own(lua):
    """It is the case a player acts on; the other two tones would bury it."""
    _project(lua, """{ { key = "imoen", name = "Imoen", slot = 0,
        planned = 0, short = 1, entries = {
            { group = "a", repeats = 3, planned = 3, sources = {},
              reasons = {} },
            { group = "b", repeats = 3, planned = 2, sources = {},
              reasons = {} },
            { group = "c", repeats = 3, planned = 0, sources = {},
              reasons = {} } } } }""")
    tones = [lua.eval(f"BfBot.UI._RecipientWhatColor({i})") for i in (2, 3, 4)]
    assert tones == ["text", "lockText", "textMuted"]
    assert len(set(tones)) == 3


def test_a_character_missing_something_is_marked_in_the_margin(lua):
    _project(lua, """{ { key = "a", name = "A", slot = 0, planned = 1,
            short = 0, entries = {} },
        { key = "b", name = "B", slot = 1, planned = 0, short = 1,
            entries = {} } }""")
    assert lua.eval("BfBot.UI._RecipientNameColor(1)") == "headerSub"
    assert lua.eval("BfBot.UI._RecipientNameColor(3)") == "lockText"


@pytest.mark.parametrize("row", ["0", "-1", "99", "nil"])
def test_a_row_the_table_does_not_have_draws_nothing(lua, row):
    # The engine draws whatever it is handed, and nil has arrived on screen as
    # the literal text "nil" before.
    _project(lua, ONE_PLANNED)
    for cell in ("Name", "What", "Source", "Count"):
        assert lua.eval(f"BfBot.UI._RecipientCell{cell}({row})") == ""
    assert lua.eval(f"BfBot.UI._RecipientWhatColor({row})") == "text"


def test_the_table_survives_a_missing_projection(lua):
    _project(lua, "nil")
    assert lua.eval("#buffbot_recipientTable") == 0
    assert lua.eval("BfBot.UI._RecipientCellName(1)") == ""


def test_every_recipient_keeps_its_own_rows_in_order(lua):
    _project(lua, """{ { key = "a", name = "A", slot = 0, planned = 1,
            short = 0, entries = {
                { group = "g1", repeats = 1, planned = 1, sources = {},
                  reasons = {} } } },
        { key = "b", name = "B", slot = 1, planned = 1, short = 0, entries = {
                { group = "g2", repeats = 1, planned = 1, sources = {},
                  reasons = {} } } } }""")
    kinds = [lua.eval(f"buffbot_recipientTable[{i}].kind")
             for i in range(1, 5)]
    assert kinds == ["recipient", "entry", "recipient", "entry"]
    assert [lua.eval(f"buffbot_recipientTable[{i}].key")
            for i in range(1, 5)] == ["a", "a", "b", "b"]


def test_the_menu_binds_the_table_and_the_cells_it_declares():
    """Every Lua name the recipient list calls has to exist in the module."""
    menu = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")
    block = re.search(
        r'\tlist\n\t\{(?:[^{}]|\{[^{}]*\}|\{(?:[^{}]|\{[^{}]*\})*\})*'
        r'name    "bbRecipientList".*?\n\t\}', menu, re.S)
    assert block, "the recipient list is not in the menu"
    body = block.group(0)
    assert 'table       "buffbot_recipientTable"' in body
    assert 'enabled     "buffbot_isOpen and BfBot.UI._IsRecipientView()"' in body
    assert 'scrollbar   "BFBSCRL"' in body
    for name in re.findall(r"BfBot\.UI\.(_[A-Za-z]+)\(", body):
        # Both definition forms the module uses.
        assert (f"function BfBot.UI.{name}(" in MODULE_SOURCES
                or f"BfBot.UI.{name} = function(" in MODULE_SOURCES), name


def test_only_one_of_the_two_tables_is_ever_enabled():
    """They share a rect; both enabled would draw one over the other."""
    menu = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")
    assert ('enabled     "buffbot_isOpen and not BfBot.UI._IsRecipientView()"'
            in menu)
    assert ('enabled     "buffbot_isOpen and BfBot.UI._IsRecipientView()"'
            in menu)
    # The same rect, so the claim above is about the same space.
    assert menu.count("area 350 148 520 250") == 2


def test_the_perspective_button_has_a_reserved_slot_of_its_own():
    """#100's lesson: a control placed among live ones ends up under them."""
    assert 'setArea("bbPersp"' in UI_SOURCE
    assert "local perspW" in UI_SOURCE
    # rowW, the tab area, must stop short of BOTH reserved slots.
    assert "local rowW = cw - viewW - perspW - 2 * charGap" in UI_SOURCE
