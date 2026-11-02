"""The party table's display layer (issue #81).

`BfBot.Plan.ByGroup` answers what is cast and who receives it; these tests
cover what the panel does with that answer — which rows the table gets, what
each cell says, which chip slots draw, and when the perspective button is
allowed to switch. The projection itself is covered in `test_plan_model.py`.

The real localization module is loaded, because half of what this layer
produces is formatted text and a stubbed catalog would prove nothing about
the placeholders.
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
MENU = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")

# The display layer only. Pulling in all of BfBotUI would drag the engine's
# menu globals in with it, and these functions are pure.
EXTRACTED = (
    "_IsCasterPerspective", "_IsRecipientView", "_CanTogglePerspective",
    "_PerspectiveBtnLabel", "_PerspectiveBtnTooltip", "TogglePerspective",
    "_SearchName", "_FormatDuration",
    "_PartyRowSub", "_PartyRowUses", "_PartyRowUsesTooltip",
    "_PartyRowDuration", "_PartyRowPassesFilter", "_PartyFilterLabel",
    "CyclePartyFilter", "SetPartyRecipient", "_IsPartyRecipient",
    "_CellsForRecipient", "_LineMentionsRecipient", "_BuildPartyRows",
    "_PartyRow", "_PartyCellIcon", "_PartyCellName", "_PartyCellSub",
    "_PartyCellUses", "_PartyCellUsesTooltip", "_PartyCellDuration",
    "_PartyCellClear",
    "_PartyRowClearable", "_PartyChip", "_PartyChipIsParty",
    "_PartyChipExists", "_PartyChipName", "_PartyChipDuration",
    "_PartyChipBam", "_PartyChipFrame", "_PartyChipColor",
    "_PartyChipDurationColor", "_PartyNameColor",
)


@pytest.fixture
def lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute("io = nil")
    runtime.execute(
        """
        BfBot = { UI = {}, Plan = {}, Theme = {} }
        T_PartyView = true
        T_Refreshes = 0
        T_Cleared = 0
        BfBot.UI._view = "party"
        BfBot.UI._IsPartyView = function() return T_PartyView end
        BfBot.UI._Refresh = function() T_Refreshes = T_Refreshes + 1 end
        BfBot.UI._ClearSpellSelection = function() T_Cleared = T_Cleared + 1 end
        -- Colour names, not colours: a test asserts which tone a cell gets,
        -- and the palette is another module's business.
        BfBot.UI._T = function(key) return key end
        -- The cells ask the plan model which states count as unfinished.
        BfBot.Plan.IsProblem = function(state)
            return state == "partial" or state == "problem"
        end
        BfBot.Plan.IsChosen = function(state)
            return state == "planned" or state == "partial"
                or state == "problem" or state == "locked"
                or state == "covered"
        end
        BfBot.UI._PlateBam = function() return "BFBPLAT" end
        BfBot.Theme.HasChromeArt = function() return true end
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
    # The glyph table, taken from the module rather than restated here.
    glyphs = re.search(r"BfBot\.UI\.CELL_GLYPH = \{.*?\n\}", UI_SOURCE, re.S)
    assert glyphs, "CELL_GLYPH is missing"
    runtime.execute(glyphs.group(0))
    runtime.execute('BfBot.UI.PARTY_FILTERS = '
                    '{ "all", "planned", "open", "problems" }')
    runtime.execute('BfBot.UI._partyFilter = "all"')
    runtime.execute("BfBot.UI._partyRecipient = nil")
    runtime.execute('BfBot.UI._perspective = "caster"')
    runtime.execute("BfBot.UI.MAX_CHIPS = 6")
    runtime.execute("buffbot_partyTable = {}")
    runtime.execute('buffbot_searchText = ""')
    return runtime


# A ByGroup-shaped result: two buffs, one party-wide, one short a caster.
LINES = """{
    { key = "bless", name = "Bless", icon = "SPBLESS", kind = "spl",
      selfOnly = false, uses = { free = 4, total = 7 },
      durationMin = 300, durationMax = 300, planned = 1, short = 0,
      recipients = {
          { party = true, key = "party", duration = 300, state = "planned" } } },
    { key = "shield", name = "Shield", icon = "SPSHIELD", kind = "itm",
      selfOnly = true, uses = { free = 1, total = 3 },
      durationMin = 300, durationMax = 600, planned = 1, short = 1,
      recipients = {
          { key = "a", name = "Minsc", slot = 0, duration = 300,
            state = "planned" },
          { key = "b", name = "Jaheira", slot = 1, state = "problem",
            reason = "no_eligible_source" } } } }"""


def _build(lua: LuaRuntime, lines: str = LINES, query: str = "") -> None:
    lua.execute("buffbot_partyTable = BfBot.UI._BuildPartyRows(%s, [[%s]])"
                % (lines, query))


# ---------------------------------------------------------------------------
# Which end of the plan the panel reads from
# ---------------------------------------------------------------------------


def test_the_panel_opens_on_the_caster_reading(lua):
    # Deliberate: the party table becomes the default only once it has been
    # lived with, which is a separate decision.
    assert lua.eval("BfBot.UI._IsCasterPerspective()") is True
    assert lua.eval("BfBot.UI._IsRecipientView()") is False


def test_switching_changes_the_reading_and_nothing_else(lua):
    lua.execute("BfBot.UI.TogglePerspective()")
    assert lua.eval("BfBot.UI._IsRecipientView()") is True
    assert lua.eval("BfBot.UI._IsCasterPerspective()") is False
    assert lua.eval("T_Refreshes") == 1
    assert lua.eval("T_Cleared") == 1


def test_the_summons_view_remembers_the_reading_without_applying_it(lua):
    """Switching to summons and back must not move the panel under them."""
    lua.execute("BfBot.UI.TogglePerspective()")
    lua.execute("T_PartyView = false")
    assert lua.eval("BfBot.UI._IsRecipientView()") is False
    assert lua.eval("BfBot.UI._CanTogglePerspective()") is False
    lua.execute("BfBot.UI.TogglePerspective()")
    assert lua.eval('BfBot.UI._perspective') == "recipient"
    lua.execute("T_PartyView = true")
    assert lua.eval("BfBot.UI._IsRecipientView()") is True


def test_the_button_says_what_clicking_it_switches_to(lua):
    assert lua.eval("BfBot.UI._PerspectiveBtnLabel()") == "By recipient"
    lua.execute("BfBot.UI.TogglePerspective()")
    assert lua.eval("BfBot.UI._PerspectiveBtnLabel()") == "By caster"


def test_the_tooltip_says_what_the_panel_shows_now(lua):
    assert "each character will cast" in lua.eval(
        "BfBot.UI._PerspectiveBtnTooltip()")
    lua.execute("BfBot.UI.TogglePerspective()")
    assert "receives" in lua.eval("BfBot.UI._PerspectiveBtnTooltip()")


# ---------------------------------------------------------------------------
# One row per buff
# ---------------------------------------------------------------------------


def test_each_buff_is_one_row(lua):
    _build(lua)
    assert lua.eval("#buffbot_partyTable") == 2
    assert lua.eval("BfBot.UI._PartyCellName(1)") == "Bless"
    assert lua.eval("BfBot.UI._PartyCellName(2)") == "Shield"


def test_the_row_carries_the_buffs_own_icon(lua):
    """The caster view draws the same one; the readings must not disagree."""
    _build(lua)
    assert lua.eval("BfBot.UI._PartyCellIcon(1)") == "SPBLESS"


def test_the_sub_line_names_only_what_changes_how_a_buff_behaves(lua):
    _build(lua)
    # A plain spell that anyone can receive earns no second line.
    assert lua.eval("BfBot.UI._PartyCellSub(1)") == ""
    assert lua.eval("BfBot.UI._PartyCellSub(2)") == "Item / Self only"


@pytest.mark.parametrize("kind,self_only,expected", [
    ("spl", "false", ""),
    ("spl", "true", "Self only"),
    ("itm", "false", "Item"),
    ("itm", "true", "Item / Self only"),
])
def test_the_sub_line_covers_the_four_combinations(lua, kind, self_only,
                                                   expected):
    assert lua.eval(
        'BfBot.UI._PartyRowSub({ kind = "%s", selfOnly = %s })'
        % (kind, self_only)) == expected


def test_uses_says_how_many_the_party_has(lua):
    """Not "4 of 7 unspent": a column headed Uses is read as how many
    there are, and the fraction read like charges on a potion with none."""
    _build(lua)
    assert lua.eval("BfBot.UI._PartyCellUses(1)") == "7"


def test_what_the_preset_reserves_goes_in_the_tooltip(lua):
    _build(lua)
    assert lua.eval("BfBot.UI._PartyCellUsesTooltip(1)") == (
        "4 of 7 still unspent by this preset.")


def test_no_tooltip_where_the_preset_reserves_nothing(lua):
    assert lua.eval(
        "BfBot.UI._PartyRowUsesTooltip({ uses = { free = 7, total = 7 } })"
    ) == ""
    assert lua.eval("BfBot.UI._PartyRowUsesTooltip({})") == ""


def test_chip_text_on_a_plate_never_takes_a_parchment_colour(lua):
    """bg1_light is the one palette with a light panel, so its muted tone
    is dark -- and a cell's plate is dark in every theme."""
    _build(lua)
    assert lua.eval("BfBot.UI._PartyChipDurationColor(1, 1)") == "btnTextDim"
    assert lua.eval("BfBot.UI._PartyChipColor(1, 1)") == "btnText"
    source = re.search(r"^function BfBot\.UI\._PartyChip(?:Duration)?Color"
                       r"\(.*?^end$", UI_SOURCE, re.S | re.M).group(0)
    assert '_T("text")' not in source
    assert '_T("textMuted")' not in source


def test_reset_clears_the_frames_corner_piece():
    """The corner boss is 38 wide and sits on the panel's own corner."""
    layout = _layout()
    assert "local cornerW = 38" in layout
    assert 'setArea("bbReset", px + pw - cornerW - 6 - 64, py + 5, 64, 24)'         in layout


def test_a_buff_nothing_supplies_shows_no_use_count(lua):
    """"0/0" would read as spent; there is no pool at all."""
    assert lua.eval(
        "BfBot.UI._PartyRowUses({ uses = { free = 0, total = 0 } })") == ""
    assert lua.eval("BfBot.UI._PartyRowUses({})") == ""


def test_one_duration_where_they_agree_and_a_range_where_they_do_not(lua):
    _build(lua)
    assert lua.eval("BfBot.UI._PartyCellDuration(1)") == "5m"
    # Two casters of different levels: the short end is what must be planned
    # around, so both ends are shown rather than an average true for nobody.
    assert "-" in lua.eval("BfBot.UI._PartyCellDuration(2)")


def test_a_buff_with_no_planned_cast_reports_no_duration(lua):
    assert lua.eval("BfBot.UI._PartyRowDuration({})") == ""


# ---------------------------------------------------------------------------
# The recipient chips
# ---------------------------------------------------------------------------


def test_a_party_wide_cast_is_one_chip_that_says_so(lua):
    """Six identical chips would read as six casts."""
    _build(lua)
    assert lua.eval("BfBot.UI._PartyChipName(1, 1)") == "[x] Party"
    assert lua.eval("BfBot.UI._PartyChipIsParty(1, 1)") is True


def test_a_personal_cast_names_each_character(lua):
    """The glyph and the name are one string: a cell's text is one label."""
    _build(lua)
    assert lua.eval("BfBot.UI._PartyChipName(2, 1)") == "[x] Minsc"
    assert lua.eval("BfBot.UI._PartyChipName(2, 2)") == "[!] Jaheira"
    assert lua.eval("BfBot.UI._PartyChipIsParty(2, 1)") is False


def test_a_chip_with_no_source_says_so_where_its_duration_would_be(lua):
    _build(lua)
    assert lua.eval("BfBot.UI._PartyChipDuration(2, 1)") == "5m"
    assert lua.eval("BfBot.UI._PartyChipDuration(2, 2)") == "no caster"


@pytest.mark.parametrize("state,glyph", [
    ("planned", "[x]"), ("partial", "[~]"), ("problem", "[!]"),
    ("locked", "[#]"), ("covered", "[+]"), ("open", "[ ]"),
    ("impossible", "[-]"),
])
def test_every_state_has_its_own_glyph(lua, state, glyph):
    """The glyph carries the state, because the reasons behind `impossible`
    number twenty-three and one glyph each would be unreadable."""
    lua.execute(
        'buffbot_partyTable = { { chips = { { name = "X", state = "%s" } } } }'
        % state)
    assert lua.eval("BfBot.UI._PartyChipName(1, 1)") == glyph + " X"


def test_an_unchosen_cell_promises_no_duration(lua):
    """A length for a cast nobody asked for would read as a promise."""
    for state in ("open", "impossible"):
        lua.execute(
            'buffbot_partyTable = { { chips = { { name = "X", state = "%s",'
            ' dur = "5m" } } } }' % state)
        assert lua.eval("BfBot.UI._PartyChipDuration(1, 1)") == ""


def test_a_partly_covered_cell_counts_instead_of_timing(lua):
    lua.execute(
        'buffbot_partyTable = { { chips = { { name = "X", state = "partial",'
        ' dur = "5m", planned = 2, repeats = 3 } } } }')
    assert lua.eval("BfBot.UI._PartyChipDuration(1, 1)") == "2 of 3"


def test_an_unused_chip_slot_is_silent_in_every_cell(lua):
    """Six fixed slots; the empty ones must draw nothing at all."""
    _build(lua)
    for slot in (3, 4, 5, 6):
        assert lua.eval(f"BfBot.UI._PartyChipExists(2, {slot})") is False
        assert lua.eval(f"BfBot.UI._PartyChipIsParty(2, {slot})") is False
        assert lua.eval(f"BfBot.UI._PartyChipName(2, {slot})") == ""
        assert lua.eval(f"BfBot.UI._PartyChipDuration(2, {slot})") == ""
        assert lua.eval(f"BfBot.UI._PartyChipBam(2, {slot})") == ""


def test_a_used_chip_slot_draws_its_plate(lua):
    _build(lua)
    assert lua.eval("BfBot.UI._PartyChipBam(2, 1)") == "BFBPLAT"
    # One plate face for every chip: borrowing the pressed face for a chip
    # nobody supplies read as "selected" rather than as a gap.
    assert lua.eval("BfBot.UI._PartyChipFrame(2, 1)") == 0
    assert lua.eval("BfBot.UI._PartyChipFrame(2, 2)") == 0


def test_a_character_who_will_not_get_it_is_amber_not_grey(lua):
    """Grey reads as switched off and therefore fine; this one is a gap."""
    _build(lua)
    assert lua.eval("BfBot.UI._PartyChipColor(2, 1)") == "btnText"
    assert lua.eval("BfBot.UI._PartyChipColor(2, 2)") == "lockText"
    assert lua.eval("BfBot.UI._PartyChipDurationColor(2, 2)") == "lockText"


@pytest.mark.parametrize("state,tone", [
    ("planned", "btnText"),
    ("partial", "lockText"),
    ("problem", "lockText"),
    ("locked", "btnTextDim"),
    ("covered", "btnTextDim"),
    ("open", "btnTextDim"),
    ("impossible", "btnTextDim"),
])
def test_only_the_two_unfinished_states_are_amber(lua, state, tone):
    lua.execute(
        'buffbot_partyTable = { { chips = { { name = "X", state = "%s" } } } }'
        % state)
    assert lua.eval("BfBot.UI._PartyChipColor(1, 1)") == tone


def test_a_cell_nothing_could_fill_leaves_bare_parchment(lua):
    """A plate there would read as a control waiting to be used."""
    lua.execute(
        'buffbot_partyTable = { { chips = { { state = "impossible" },'
        ' { state = "open" } } } }')
    assert lua.eval("BfBot.UI._PartyChipBam(1, 1)") == ""
    assert lua.eval("BfBot.UI._PartyChipBam(1, 2)") == "BFBPLAT"


def test_chip_text_takes_the_colour_of_things_drawn_on_a_plate(lua):
    """`text` is the parchment colour and vanished on the chip in all three
    light palettes."""
    _build(lua)
    assert lua.eval("BfBot.UI._PartyChipColor(1, 1)") == "btnText"
    assert lua.eval("BfBot.UI._PartyChipColor(9, 9)") == "btnTextDim"


def test_a_buff_nobody_can_supply_is_dimmed_whole(lua):
    _build(lua, """{ { key = "g", name = "Gone", kind = "spl",
        planned = 0, short = 2, recipients = {} } }""")
    assert lua.eval("BfBot.UI._PartyNameColor(1)") == "textMuted"


def test_a_buff_with_something_planned_keeps_the_body_colour(lua):
    _build(lua)
    assert lua.eval("BfBot.UI._PartyNameColor(1)") == "text"


# ---------------------------------------------------------------------------
# Clear
# ---------------------------------------------------------------------------


def test_clear_appears_only_where_there_is_something_to_clear(lua):
    _build(lua)
    assert lua.eval("BfBot.UI._PartyCellClear(1)") == "Clear"
    assert lua.eval("BfBot.UI._PartyRowClearable(1)") is True
    _build(lua, """{ { key = "g", name = "Gone", kind = "spl",
        planned = 0, short = 0, recipients = {} } }""")
    assert lua.eval("BfBot.UI._PartyCellClear(1)") == ""
    assert lua.eval("BfBot.UI._PartyRowClearable(1)") is False


def test_clearing_has_to_reach_every_preset_that_holds_the_buff():
    """Clearing only the preset on screen leaves the row half set."""
    source = re.search(r"^function BfBot\.UI\.ClearPartyRow\(.*?^end$",
                       UI_SOURCE, re.S | re.M)
    assert source, "ClearPartyRow is missing"
    body = source.group(0)
    assert "for _, owner in ipairs(row.owners" in body
    assert "SetSpellEnabled" in body
    # Slots, not sprites: the click happens frames after the plan was built.
    assert "EEex_Sprite_GetInPortrait(owner.slot)" in body
    # A character who left in between is reported, not silently skipped.
    assert "skipped" in body and "_Display" in body


# ---------------------------------------------------------------------------
# Rows the table does not have
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("row", ["0", "-1", "99", "nil"])
def test_a_row_the_table_does_not_have_draws_nothing(lua, row):
    _build(lua)
    for cell in ("Icon", "Name", "Sub", "Uses", "Duration", "Clear"):
        assert lua.eval(f"BfBot.UI._PartyCell{cell}({row})") == ""
    assert lua.eval(f"BfBot.UI._PartyChipName({row}, 1)") == ""
    assert lua.eval(f"BfBot.UI._PartyRowClearable({row})") is False


def test_the_table_survives_a_missing_projection(lua):
    _build(lua, "nil")
    assert lua.eval("#buffbot_partyTable") == 0
    assert lua.eval("BfBot.UI._PartyCellName(1)") == ""


# ---------------------------------------------------------------------------
# The search box, in this reading
# ---------------------------------------------------------------------------


def test_an_empty_query_keeps_every_row(lua):
    _build(lua, query="")
    assert lua.eval("#buffbot_partyTable") == 2


def test_a_query_keeps_the_buffs_whose_name_matches(lua):
    _build(lua, query="shield")
    assert lua.eval("#buffbot_partyTable") == 1
    assert lua.eval("BfBot.UI._PartyCellName(1)") == "Shield"


def test_a_query_also_matches_a_recipients_name(lua):
    """"What does Jaheira get" is the other question the box is asked."""
    _build(lua, query="jaheira")
    assert lua.eval("#buffbot_partyTable") == 1
    assert lua.eval("BfBot.UI._PartyCellName(1)") == "Shield"


def test_a_query_matching_the_party_chip_keeps_its_row(lua):
    _build(lua, query="party")
    assert lua.eval("#buffbot_partyTable") == 1
    assert lua.eval("BfBot.UI._PartyCellName(1)") == "Bless"


def test_a_query_that_matches_nothing_leaves_an_empty_table(lua):
    # Not rows with no chips: the empty-state label is what says there was
    # nothing, and it needs the table to be empty.
    _build(lua, query="stoneskin")
    assert lua.eval("#buffbot_partyTable") == 0


def test_the_query_ignores_case(lua):
    _build(lua, query="BLESS")
    assert lua.eval("#buffbot_partyTable") == 1


def test_the_empty_state_asks_whichever_list_is_showing():
    """One label over two tables; pinned to one it lies about the other."""
    source = re.search(r"^function BfBot\.UI\._SearchFoundNothing\(\).*?^end$",
                       UI_SOURCE, re.S | re.M)
    assert source, "_SearchFoundNothing is missing"
    body = source.group(0)
    assert "_IsRecipientView()" in body
    assert "buffbot_partyTable" in body
    assert "buffbot_visibleSpells" in body
    assert 'enabled "BfBot.UI._SearchFoundNothing()"' in MENU
    assert "#buffbot_visibleSpells == 0" not in MENU


def test_a_changed_query_rebuilds_this_reading_too():
    """It is built in _Refresh, so the search tick has to ask for it again."""
    tick = re.search(r"^function BfBot\.UI\._SearchTick\(\).*?^end$",
                     UI_SOURCE, re.S | re.M)
    assert tick, "_SearchTick is missing"
    body = tick.group(0)
    assert "_IsRecipientView()" in body
    assert "_RefreshPartyRows" in body
    assert "bbPartyList" in body


# ---------------------------------------------------------------------------
# What the panel looks like in this reading
# ---------------------------------------------------------------------------


def _layout() -> str:
    match = re.search(r"function BfBot\.UI\._Layout\(\).*?\n^end$",
                      UI_SOURCE, re.S | re.M)
    assert match, "_Layout is missing"
    return match.group(0)


def test_the_party_table_is_given_the_same_rect_as_the_caster_list():
    layout = _layout()
    assert 'setArea("bbList", cx, listY, cw, listH)' in layout
    assert 'setArea("bbPartyList", cx, listY, cw, listH)' in layout


def test_the_row_height_matches_the_menus_and_is_whole_rows():
    """A list measured at the wrong row height spills over the footer."""
    layout = _layout()
    assert "local rowH = recipient and 48 or 36" in layout
    assert "listH = listH - (listH % rowH)" in layout
    assert "rowheight   48" in MENU and "rowheight   36" in MENU


def test_this_reading_drops_the_footer_row_that_edits_a_caster_row():
    layout = _layout()
    assert "local footerRows = recipient and 3 or 4" in layout
    assert "ph - (hdrY - py) - hdrH - footerH" in layout


def test_the_party_footer_keeps_only_what_applies_to_a_preset():
    layout = _layout()
    start = layout.index("if recipient then")
    branch = layout[start:layout.index("\n    else", start)]
    for name in ("bbExp", "bbImp"):
        assert f'"{name}"' in branch, name
    # Delete Preset is not here: it sits in the preset row, which both
    # readings share.
    for name in ("bbAdd", "bbRmv", "bbRepeat", "bbTog", "bbTgt",
                 "bbUp", "bbDn", "bbSort", "bbOrder", "bbDel"):
        assert f'"{name}"' not in branch, name
    layout_text = layout
    assert 'setArea("bbDel", renX + renW + newW + 2 * preGap, preY, delW, preH)'         in layout_text


def test_delete_preset_sits_with_rename_and_new():
    """It acts on the preset, and sat two rows away among the spell controls."""
    layout = _layout()
    assert "local delW = 92" in layout
    assert "cw - renW - newW - delW - 3 * preGap" in layout
    # And it greys out rather than leaving a hole where it was.
    block = re.search(r'name\s+"bbDel"(?:(?!\n\t\}).)*', MENU, re.S).group(0)
    assert 'clickable lua "BfBot.UI._CanDeletePreset()"' in block
    enabled = re.search(r'\benabled\s+"([^"]*)"', block).group(1)
    assert "_CanDeletePreset" not in enabled
    # One Delete now, not one per footer shape.
    assert "bbVDel" not in MENU


def test_the_captions_stand_over_the_columns_they_name():
    """The percentages are the list's own column widths, in order."""
    layout = _layout()
    assert 'header("bbRHWho",    4, 20)' in layout
    assert 'header("bbRHWhat",  24,  5)' in layout
    assert 'header("bbRHFrom",  29,  9)' in layout
    assert 'header("bbRHCount", 38, 54)' in layout
    for name in ("bbRHWho", "bbRHWhat", "bbRHFrom", "bbRHCount"):
        assert f'name "{name}"' in MENU, name


def test_both_header_strips_are_placed_every_layout():
    """A disabled element keeps its last area, so one strip would lag."""
    layout = _layout()
    for name in ("bbHName", "bbHLock", "bbRHWho", "bbRHCount"):
        assert f'header("{name}"' in layout, name


def test_switching_the_reading_relays_the_panel_out():
    layout = _layout()
    assert "recipient = recipient" in layout
    guard = re.search(r"^function BfBot\.UI\._RelayoutIfStale\(\).*?^end$",
                      UI_SOURCE, re.S | re.M)
    assert guard, "_RelayoutIfStale is missing"
    assert "BfBot.UI._IsRecipientView() ~= laid.recipient" in guard.group(0)
    refresh = re.search(r"^function BfBot\.UI\._Refresh\(\).*?^end$",
                        UI_SOURCE, re.S | re.M)
    assert refresh and "_RelayoutIfStale()" in refresh.group(0)


# ---------------------------------------------------------------------------
# The menu
# ---------------------------------------------------------------------------


def _without_comments(block: str) -> str:
    """The declarations alone. A test about what the menu DOES must not be
    answered by a comment saying what it deliberately does not do."""
    return "\n".join(line for line in block.splitlines()
                     if not line.lstrip().startswith("--"))


def _party_list() -> str:
    block = re.search(
        r"\tlist\n\t\{(?:[^{}]|\{[^{}]*\}|\{(?:[^{}]|\{[^{}]*\})*\})*"
        r'name    "bbPartyList".*?\n\t\}', MENU, re.S)
    assert block, "the party list is not in the menu"
    return block.group(0)


def test_the_menu_binds_the_table_and_the_cells_it_declares():
    """Every Lua name the party list calls has to exist in the module."""
    body = _party_list()
    assert 'table       "buffbot_partyTable"' in body
    assert 'enabled     "buffbot_isOpen and BfBot.UI._IsRecipientView()"' in body
    assert 'action      "BfBot.UI._OnPartyRowAction(cellNumber)"' in body
    assert 'scrollbar   "BFBSCRL"' in body
    for name in set(re.findall(r"BfBot\.UI\.(_[A-Za-z]+)\(", body)):
        assert (f"function BfBot.UI.{name}(" in MODULE_SOURCES
                or f"BfBot.UI.{name} = function(" in MODULE_SOURCES), name


def test_only_one_of_the_two_tables_is_ever_enabled():
    """They share a rect; both enabled would draw one over the other."""
    assert ('enabled     "buffbot_isOpen and not BfBot.UI._IsRecipientView()"'
            in MENU)
    assert ('enabled     "buffbot_isOpen and BfBot.UI._IsRecipientView()"'
            in MENU)
    assert MENU.count("area 350 148 520 250") == 2


def test_the_column_widths_total_one_hundred():
    """They are percentages; anything else leaves a column off the panel."""
    widths = [int(w) for w in re.findall(r"\n\t\t\twidth (\d+)",
                                         _party_list())]
    # icon, name, uses, duration, seven recipient cells, clear
    assert len(widths) == 12, widths
    assert sum(widths) == 100, widths


def test_there_is_a_chip_column_for_every_chip_the_rows_can_hold():
    body = _party_list()
    # The Party cell plus a party of six.
    for n in range(1, 8):
        assert f"_PartyChipName(rowNumber, {n})" in body, n
    assert "_PartyChipName(rowNumber, 8)" not in body
    assert "BfBot.UI.MAX_CHIPS = 7" in UI_SOURCE


def test_a_chip_is_a_column_rather_than_a_button_in_a_row():
    """A button inside a list row does not survive the widget's hit test."""
    body = _without_comments(_party_list())
    assert "button" not in body
    assert "cellNumber" in body
    handler = re.search(r"^function BfBot\.UI\._OnPartyRowAction\(.*?^end$",
                        UI_SOURCE, re.S | re.M)
    assert handler, "_OnPartyRowAction is missing"
    assert "PARTY_CLEAR_CELL" in handler.group(0)


def test_the_chip_cells_are_where_the_handler_looks_for_them():
    """The first chip's column index and the clear column's, by count."""
    body = _party_list()
    columns = [m.start() for m in re.finditer(r"\n\t\tcolumn\n", body)]
    first_chip = body.index("_PartyChipName(rowNumber, 1)")
    clear = body.index("_PartyCellClear(rowNumber)")
    chip_index = sum(1 for pos in columns if pos < first_chip)
    clear_index = sum(1 for pos in columns if pos < clear)
    assert f"PARTY_CHIP_CELL = {chip_index}" in UI_SOURCE
    assert f"PARTY_CLEAR_CELL = {clear_index}" in UI_SOURCE


def test_no_cell_draws_a_party_portrait():
    """The engine's portrait control ignores the list's clip rect: the row
    below the last visible one still painted its faces over the footer."""
    assert "portrait" not in _without_comments(_party_list())


CASTER_ONLY = (
    "bbHName", "bbHDur", "bbHUses", "bbHRep", "bbHTgt", "bbHLock",
    "bbAdd", "bbRmv", "bbRepeat", "bbTog", "bbTgt", "bbUp", "bbDn", "bbSort",
    "bbOrder", "bbVTog", "bbVTgt", "bbVVar", "bbVUp", "bbVDn", "bbVSort",
    "bbVOrder",
)


@pytest.mark.parametrize("name", CASTER_ONLY)
def test_everything_that_edits_a_caster_row_steps_aside(name: str) -> None:
    """They act on a selection this reading does not have."""
    for element in (name, name + "_t", name + "_b"):
        block = re.search(
            r'name\s+"' + re.escape(element) + r'"(?:(?!\n\t\}).)*',
            MENU, re.S)
        if not block:
            continue
        body = block.group(0)
        if "enabled" not in body:
            continue
        assert "not BfBot.UI._IsRecipientView()" in body, element


@pytest.mark.parametrize("name", ("bbCast", "bbCastChar", "bbStop", "bbClose",
                                  "bbView", "bbPersp", "bbRen", "bbNew"))
def test_what_still_applies_is_left_alone(name: str) -> None:
    """Casting, the tabs and the switch itself work in both readings."""
    block = re.search(
        r'name\s+"' + re.escape(name) + r'"(?:(?!\n\t\}).)*', MENU, re.S)
    assert block, name
    assert "not BfBot.UI._IsRecipientView()" not in block.group(0), name


def test_the_perspective_button_has_a_reserved_slot_of_its_own():
    """#100's lesson: a control placed among live ones ends up under them."""
    assert 'setArea("bbPersp"' in UI_SOURCE
    assert "local perspW" in UI_SOURCE
    assert "local rowW = cw - viewW - perspW - 2 * charGap" in UI_SOURCE


# ---------------------------------------------------------------------------
# The refresher's contract with the plan model
# ---------------------------------------------------------------------------


def test_the_refresher_asks_for_the_preset_the_panel_is_showing():
    """It takes an index, and the panel's field is _presetIdx.

    Passing `_preset` -- a field no module defines -- migrated nothing, and
    the view reported every character empty for a preset holding ten buffs.
    Nothing offline runs that path, so this pins the name.
    """
    source = re.search(r"^function BfBot\.UI\._RefreshPartyRows\(\).*?^end$",
                       UI_SOURCE, re.S | re.M)
    assert source, "_RefreshPartyRows is missing"
    body = source.group(0)
    assert "BfBot.UI._presetIdx" in body
    assert "BfBot.UI._preset," not in body and "BfBot.UI._preset)" not in body
    assert "if not requests then" in body
    assert "_Warn" in body


def test_the_refresher_asks_the_plan_model_for_everything_it_shows():
    """No second store: the table is a projection, end to end."""
    source = re.search(r"^function BfBot\.UI\._RefreshPartyRows\(\).*?^end$",
                       UI_SOURCE, re.S | re.M).group(0)
    for call in ("Snapshot", "ImportLegacy", "NormalizeRadialRequests",
                 "ExpandRequests", "Assign", "ByGroup"):
        assert f"BfBot.Plan.{call}(" in source, call


def test_the_totals_count_the_whole_plan_not_the_filtered_view():
    """"45 planned / 6 unavailable" has to keep meaning the preset."""
    source = re.search(r"^function BfBot\.UI\._RefreshPartyRows\(\).*?^end$",
                       UI_SOURCE, re.S | re.M).group(0)
    totals = source.index("_partyTotals")
    filtered = source.index("_BuildPartyRows")
    assert totals < filtered, "the totals are counted after the filter"


def test_the_two_view_switches_have_a_colour_nothing_else_uses():
    """They are the only controls that change what the panel is about."""
    source = re.search(r"^function BfBot\.UI\._SwitchCaptionColor\(.*?^end$",
                       UI_SOURCE, re.S | re.M)
    assert source, "_SwitchCaptionColor is missing"
    assert '_T("switchText")' in source.group(0)
    # Both switches, and only those two.
    users = re.findall(r'text color lua "BfBot\.UI\._SwitchCaptionColor\([^"]*\)"',
                       MENU)
    assert len(users) == 2, users
    for name in ("bbPersp_t", "bbView_t"):
        block = re.search(
            r'name\s+"' + name + r'"(?:(?!\n\t\}).)*', MENU, re.S).group(0)
        assert "_SwitchCaptionColor" in block, name
    # And it greys when the switch cannot be used, like every other caption.
    assert '_T("textMuted")' in source.group(0)


# ---------------------------------------------------------------------------
# Which rows the table shows
# ---------------------------------------------------------------------------


FILTER_LINES = """{
    { key = "chosen", name = "Chosen", recipients = {
        { key = "a", state = "planned" }, { key = "b", state = "open" } } },
    { key = "untouched", name = "Untouched", recipients = {
        { key = "a", state = "open" }, { key = "b", state = "impossible" } } },
    { key = "broken", name = "Broken", recipients = {
        { key = "a", state = "problem" }, { key = "b", state = "open" } } },
    { key = "partly", name = "Partly", recipients = {
        { key = "a", state = "partial" } } } }"""


def _names(lua):
    return [lua.eval(f"buffbot_partyTable[{i}].name")
            for i in range(1, lua.eval("#buffbot_partyTable") + 1)]


@pytest.mark.parametrize("filter_name,expected", [
    ("all", ["Chosen", "Untouched", "Broken", "Partly"]),
    ("planned", ["Chosen", "Broken", "Partly"]),
    ("open", ["Untouched"]),
    ("problems", ["Broken", "Partly"]),
])
def test_the_filter_narrows_the_table(lua, filter_name, expected):
    lua.execute(f'BfBot.UI._partyFilter = "{filter_name}"')
    _build(lua, FILTER_LINES)
    assert _names(lua) == expected


def test_planned_and_open_are_opposites_over_the_same_question(lua):
    """A row is in exactly one of them: has anybody been chosen for it."""
    for filter_name in ("planned", "open"):
        lua.execute(f'BfBot.UI._partyFilter = "{filter_name}"')
        _build(lua, FILTER_LINES)
        globals().setdefault("_seen", {})[filter_name] = set(_names(lua))
    assert _seen["planned"].isdisjoint(_seen["open"])
    assert _seen["planned"] | _seen["open"] == {
        "Chosen", "Untouched", "Broken", "Partly"}


def test_the_filter_cycles_through_its_four_positions(lua):
    seen = []
    for _ in range(5):
        seen.append(lua.eval("BfBot.UI._partyFilter"))
        lua.execute("BfBot.UI.CyclePartyFilter()")
    assert seen == ["all", "planned", "open", "problems", "all"]


def test_each_position_says_what_it_shows(lua):
    labels = []
    for _ in range(4):
        labels.append(lua.eval("BfBot.UI._PartyFilterLabel()"))
        lua.execute("BfBot.UI.CyclePartyFilter()")
    assert labels == ["Show: all", "Show: planned", "Show: not chosen",
                      "Show: problems"]


def test_the_search_still_applies_inside_a_filter(lua):
    """They narrow together; one does not override the other."""
    lua.execute('BfBot.UI._partyFilter = "planned"')
    _build(lua, FILTER_LINES, query="broken")
    assert _names(lua) == ["Broken"]
    _build(lua, FILTER_LINES, query="untouched")
    assert _names(lua) == []


def test_the_filter_only_exists_where_there_is_something_to_narrow():
    """It is a control of the party table, not of the caster view."""
    block = re.search(r'name\s+"bbPartyFilter"(?:(?!\n\t\}).)*',
                      MENU, re.S).group(0)
    assert 'enabled "buffbot_isOpen and BfBot.UI._IsRecipientView()"' in block
    layout = _layout()
    assert "local filterW = recipient and 124 or 0" in layout
    assert 'setArea("bbPartyFilter"' in layout


# ---------------------------------------------------------------------------
# The character tabs, in this reading
# ---------------------------------------------------------------------------
#
# Chris's own idea, which the fork does not have: it dropped per-character
# views entirely ("one party dashboard; no character-filter views"). Here a
# tab stops meaning "whose spellbook am I editing" and starts meaning "show
# me what this character receives" -- which is also what fixes the part that
# confused him, the tabs being live and inert at the same time.


RECIPIENT_LINES = """{
    { key = "both", name = "Both", recipients = {
        { key = "party", party = true, state = "open" },
        { key = "a", slot = 0, name = "Minsc", state = "planned" },
        { key = "b", slot = 1, name = "Jaheira", state = "open" } } },
    { key = "onlyb", name = "OnlyB", recipients = {
        { key = "party", party = true, state = "impossible" },
        { key = "a", slot = 0, name = "Minsc", state = "impossible" },
        { key = "b", slot = 1, name = "Jaheira", state = "planned" } } },
    { key = "wide", name = "Wide", recipients = {
        { key = "party", party = true, state = "planned" },
        { key = "a", slot = 0, name = "Minsc", state = "covered" },
        { key = "b", slot = 1, name = "Jaheira", state = "covered" } } } }"""


def test_without_a_tab_the_table_is_the_whole_party(lua):
    _build(lua, RECIPIENT_LINES)
    assert _names(lua) == ["Both", "OnlyB", "Wide"]
    assert lua.eval("#buffbot_partyTable[1].chips") == 3


def test_a_tab_narrows_the_table_to_what_that_character_receives(lua):
    lua.execute("BfBot.UI._partyRecipient = 0")
    _build(lua, RECIPIENT_LINES)
    # OnlyB can never reach Minsc, so it is not part of his answer.
    assert _names(lua) == ["Both", "Wide"]
    # And each row shows the Party cell and his own, nobody else's.
    keys = [lua.eval(f"buffbot_partyTable[1].chips[{i}].name")
            for i in (1, 2)]
    assert keys == ["Party", "Minsc"]
    assert lua.eval("#buffbot_partyTable[1].chips") == 2


def test_the_party_cell_stays_whoever_is_being_looked_at(lua):
    """A cast that covers everybody covers this character too; hiding it
    would make the best-planned kind of row look unplanned."""
    lua.execute("BfBot.UI._partyRecipient = 1")
    _build(lua, RECIPIENT_LINES)
    assert lua.eval("buffbot_partyTable[1].chips[1].party") == 1


def test_a_buff_that_could_reach_them_stays_even_unchosen(lua):
    """"What else could this character get" is the other half of it."""
    lua.execute("BfBot.UI._partyRecipient = 1")
    _build(lua, RECIPIENT_LINES)
    assert "Both" in _names(lua)


def test_clicking_the_same_tab_again_widens_it_back(lua):
    """The way back is the control just used, not a seventh tab to find."""
    lua.execute('BfBot.UI._perspective = "recipient"')
    lua.execute("BfBot.UI.SetPartyRecipient(2)")
    assert lua.eval("BfBot.UI._partyRecipient") == 2
    lua.execute("BfBot.UI.SetPartyRecipient(2)")
    assert lua.eval("BfBot.UI._partyRecipient") is None


def test_a_tab_means_different_things_in_the_two_readings():
    """One place decides, rather than six pairs of menu expressions."""
    source = re.search(r"^function BfBot\.UI\.SetChar\(.*?^end$",
                       UI_SOURCE, re.S | re.M).group(0)
    assert "_IsRecipientView()" in source
    assert "SetPartyRecipient(slot)" in source
    lit = re.search(r"^function BfBot\.UI\._IsCharSelected\(.*?^end$",
                    UI_SOURCE, re.S | re.M).group(0)
    assert "_partyRecipient == slot" in lit


def test_leaving_the_reading_clears_the_narrowing(lua):
    """The caster view uses the tabs for something else."""
    lua.execute('BfBot.UI._perspective = "recipient"')
    lua.execute("BfBot.UI._partyRecipient = 3")
    lua.execute("BfBot.UI.TogglePerspective()")
    assert lua.eval("BfBot.UI._partyRecipient") is None


def test_a_cell_carries_what_a_click_has_to_write(lua):
    """Without this every tick lands in the "nobody could cast this" branch.

    Caught by the in-game phase rather than here, because nothing offline
    reaches Persist -- so this pins the hand-off the projection and the row
    builder make, which is the part that was missing.
    """
    _build(lua, """{ { key = "g", name = "Bless", recipients = {
        { key = "party", party = true, state = "open", writeSlot = 2,
          writeResref = "SPPR103", writeKind = "spl" },
        { key = "a", slot = 0, name = "Minsc", state = "open", writeSlot = 2,
          writeResref = "SPPR103", writeKind = "spl" } } } }""")
    for cell in (1, 2):
        assert lua.eval(f"buffbot_partyTable[1].chips[{cell}].writeSlot") == 2
        assert lua.eval(
            f"buffbot_partyTable[1].chips[{cell}].writeResref") == "SPPR103"
        assert lua.eval(
            f"buffbot_partyTable[1].chips[{cell}].writeKind") == "spl"


def test_the_toggle_refuses_rather_than_writing_nowhere():
    """A cell with no owner says so; it does not silently do nothing."""
    source = re.search(r"^function BfBot\.UI\.ToggleRecipient\(.*?^end$",
                       UI_SOURCE, re.S | re.M).group(0)
    assert "if not chip.writeSlot or not chip.writeResref then" in source
    assert "feedback.cell_no_owner" in source
