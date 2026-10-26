"""The panel's chrome: Pecca's button plates, tabs, cast plate and scrollbar.

Step 1 of issue #81 shipped the art but left the panel on the engine's carved
stone. These tests pin the swap: that every button asks a helper which art to
draw rather than naming one, that the helper falls back to the engine art when
the themed art is absent, and that a tab's "I am the open one" frame is chosen
by the art in use rather than hard-coded to either number.

The art itself is four cycles — one per skin, 0 SoD / 1 IWD / 2 BG1 / 3 BG2 —
with four state frames inside each.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MENU_PATH = ROOT / "buffbot/BuffBot.menu"
MENU = MENU_PATH.read_text(encoding="utf-8")
THEME_SOURCE = (ROOT / "buffbot/BfBotThm.lua").read_text(encoding="utf-8")
UI_SOURCE = (ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8")

TAB_BUTTONS = (
    {f"bbC{i}" for i in range(6)}
    | {f"bbS{i}" for i in range(6)}
    | {f"bbP{i}" for i in range(1, 9)}
    | {"bbView"}
)
CAST_BUTTONS = {"bbCast", "bbCastChar"}
# The HUD toggle lives on the actionbar, not in the panel. It carries
# BuffBot's own actionbar icon (BFBOTAB) and its frame tracks the panel's
# open state, so none of the panel-chrome rules apply to it.
NOT_PANEL_CHROME = {"bbHudButton"}

# The art each helper names, and the engine art it falls back to.
THEMED = {"_PlateBam": "BFBPLAT", "_TabBam": "BFBTAB", "_CastBam": "BFBCAST"}
ENGINE_BUTTON = "GUIOSTUL"


def buttons() -> list[tuple[str, str]]:
    """Every button block in the menu as (name, body)."""
    found = []
    for match in re.finditer(r"\bbutton\s*\n\s*\{(.*?)\n\t*\}", MENU, re.S):
        body = match.group(1)
        name = re.search(r'name\s+"([^"]+)"', body)
        found.append((name.group(1) if name else "", body))
    return found


def art_buttons() -> list[tuple[str, str]]:
    return [(n, b) for n, b in buttons()
            if "bam" in b and n not in NOT_PANEL_CHROME]


@pytest.fixture
def lua() -> LuaRuntime:
    """The real theme and UI helpers over a stubbed resource lookup."""
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute("io = nil")
    runtime.execute(
        """
        BfBot = { Theme = {}, UI = {} }
        -- Which resrefs the "install" has. Tests rewrite this table and clear
        -- the cache to model a partial install.
        TestResources = {}
        TestFetches = 0
        EEex_Resource_Fetch = function(resref, _)
            TestFetches = TestFetches + 1
            return TestResources[resref] == true
        end
        """
    )
    # Only the two functions under test are needed, and pulling in the whole
    # theme and UI modules would drag in the engine's menu globals.
    for source, names in (
        (THEME_SOURCE, ("HasChromeArt", "ControlSkin")),
        (UI_SOURCE, ("_PlateBam", "_TabBam", "_CastBam", "_ChromeSeq", "_TabFrame")),
    ):
        for name in names:
            pattern = re.compile(
                r"^function BfBot\.(?:Theme|UI)\." + name + r"\(.*?^end$",
                re.S | re.M,
            )
            match = pattern.search(source)
            assert match, f"{name} not found"
            runtime.execute(match.group(0))
    # ControlSkin reads the active accent; the real palette lives elsewhere.
    runtime.execute('BfBot.Theme._GetAccentName = function() return "bg2" end')
    return runtime


def with_art(lua: LuaRuntime, present: bool) -> None:
    lua.execute(
        "TestResources = %s; BfBot.Theme._chromeArt = nil"
        % (
            '{ BFBPLAT = true, BFBTAB = true, BFBCAST = true, BFBSCRL = true }'
            if present else "{}"
        )
    )


# ---------------------------------------------------------------------------
# The menu asks, it does not name
# ---------------------------------------------------------------------------


def test_no_button_names_the_engines_stone_art_directly():
    """A hard-coded resref cannot follow the skin and cannot fall back."""
    assert ENGINE_BUTTON not in MENU


def test_the_hud_toggle_keeps_its_own_actionbar_icon():
    """It is excluded from every rule above, so pin what it actually is."""
    body = dict(buttons())["bbHudButton"]
    assert 'bam       "BFBOTAB"' in body
    assert 'frame lua "buffbot_btnFrame"' in body


def test_every_button_with_art_picks_it_through_a_helper():
    missing = [
        name for name, body in art_buttons()
        if not re.search(r'bam lua "BfBot\.UI\._(Plate|Tab|Cast)Bam\(\)"', body)
    ]
    assert missing == [], missing


def test_every_button_with_art_selects_the_skins_cycle():
    """Without a cycle the engine draws cycle 0 — the SoD art under every
    theme, which is the failure that looks like "the theme does nothing"."""
    missing = [
        name for name, body in art_buttons()
        if 'sequence lua "BfBot.UI._ChromeSeq()"' not in body
    ]
    assert missing == [], missing


def test_the_tabs_use_the_tab_plate_and_the_cast_buttons_the_cast_plate():
    for name, body in art_buttons():
        if name in TAB_BUTTONS:
            assert 'BfBot.UI._TabBam()' in body, name
        elif name in CAST_BUTTONS:
            assert 'BfBot.UI._CastBam()' in body, name
        elif name:
            assert 'BfBot.UI._PlateBam()' in body, name


def test_every_tab_marks_the_open_one_through_the_frame_helper():
    """Hard-coding frame 1 or 2 would be right for one art set and wrong for
    the other, and the panel has to work with both."""
    for name, body in art_buttons():
        if name not in TAB_BUTTONS:
            continue
        assert "BfBot.UI._TabFrame(" in body, name
        assert "and 1 or 0" not in body, name
        assert "and 2 or 0" not in body, name


def test_no_other_button_forces_a_frame_so_the_engine_keeps_its_states():
    """A plain button should still light up on hover and sink when pressed —
    the art has frames for that, and forcing one would freeze it."""
    for name, body in art_buttons():
        if name in TAB_BUTTONS:
            continue
        assert "frame lua" not in body, name


def test_every_list_scrolls_with_the_themed_bar():
    """`scrollbar` takes a literal resref — it has no Lua form — so this is
    the one place the art is named directly. The release builder and the
    installer both require BFBSCRL, which is what makes that safe."""
    assert MENU.count('scrollbar') == 4
    assert MENU.count('scrollbar   "BFBSCRL"') == 4
    assert "GUISCRC" not in MENU

    builder = (ROOT / "tools/build-release.sh").read_text(encoding="utf-8")
    assert '"BFBSCRL.BAM"' in builder
    installer = (ROOT / "buffbot/setup-buffbot.tp2").read_text(encoding="utf-8")
    assert "COPY ~buffbot/visual~ ~override~" in installer


# ---------------------------------------------------------------------------
# The helpers
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("helper,themed", sorted(THEMED.items()))
def test_each_helper_names_the_themed_art_and_falls_back_to_the_engine(
    lua, helper, themed
):
    """A partial install keeps a working panel. An invisible but clickable
    button is worse than a stone one."""
    with_art(lua, True)
    assert lua.eval(f"BfBot.UI.{helper}()") == themed
    with_art(lua, False)
    assert lua.eval(f"BfBot.UI.{helper}()") == ENGINE_BUTTON


# The art's own order, read off the rendered BAMs: skin 0 is BG:EE's red
# marble with gold filigree and a round socket, 1 is IWD's plain wood, 2 is
# SoD's cold steel with a square socket, 3 is BG2's dark stone. A mapping
# that drifts from it is not a style choice -- it dresses SoD's panel in
# BG:EE's red and BG:EE's in SoD's steel, which is how this was first
# shipped.
CONTROL_SKINS = {"bg1": 0, "sod": 2, "bg2": 3}


def test_the_skin_index_follows_the_art_and_every_mapped_skin_ships() -> None:
    body = re.search(
        r"function BfBot\.Theme\.ControlSkin\(\).*?^end$", THEME_SOURCE, re.S | re.M
    ).group(0)
    mapped = {
        accent: int(index)
        for accent, index in re.findall(r"(\w+)\s*=\s*(\d+)", body)
    }
    assert mapped == CONTROL_SKINS

    # The default is BG2's skin: the accent name is the palette's, and an
    # unknown one must still render a plate rather than nothing.
    assert re.search(r"\bor\s+3\b", body)

    visual = ROOT / "buffbot" / "visual"
    for skin in CONTROL_SKINS.values():
        assert (visual / f"BFBCHK{skin}.BAM").exists(), skin


def test_the_cycle_follows_the_skin_but_stays_at_zero_on_the_engine_art(lua):
    """The stone button has exactly one cycle, so asking for cycle 3 there
    would draw nothing."""
    with_art(lua, True)
    for accent, skin in CONTROL_SKINS.items():
        lua.execute(
            'BfBot.Theme._GetAccentName = function() return "' + accent + '" end'
        )
        assert lua.eval("BfBot.UI._ChromeSeq()") == skin, accent

    with_art(lua, False)
    assert lua.eval("BfBot.UI._ChromeSeq()") == 0


def test_the_open_tab_uses_the_frame_its_art_marks_selection_with(lua):
    with_art(lua, True)
    assert lua.eval("BfBot.UI._TabFrame(true)") == 2
    assert lua.eval("BfBot.UI._TabFrame(false)") == 0
    with_art(lua, False)
    assert lua.eval("BfBot.UI._TabFrame(true)") == 1
    assert lua.eval("BfBot.UI._TabFrame(false)") == 0
    # Lua treats 0 and "" as true, so only nil and false mean "not selected".
    with_art(lua, True)
    assert lua.eval("BfBot.UI._TabFrame(nil)") == 0


def test_a_missing_piece_of_chrome_turns_the_whole_set_off(lua):
    """Half a set would be worse than none: Pecca's tabs beside stone buttons
    read as a broken install rather than a theme."""
    lua.execute(
        "TestResources = { BFBPLAT = true, BFBTAB = true };"
        " BfBot.Theme._chromeArt = nil"
    )
    assert lua.eval("BfBot.Theme.HasChromeArt()") is False
    assert lua.eval("BfBot.UI._PlateBam()") == ENGINE_BUTTON


def test_the_presence_check_runs_once_per_session(lua):
    """It is read for every rendered button, every frame. A resource cannot
    appear while the game runs, so the answer cannot change."""
    with_art(lua, True)
    for _ in range(50):
        lua.eval("BfBot.UI._PlateBam()")
    assert lua.eval("TestFetches") == 4

    with_art(lua, False)
    lua.execute("TestFetches = 0")
    for _ in range(50):
        lua.eval("BfBot.UI._PlateBam()")
    # A negative answer is cached as firmly as a positive one.
    assert lua.eval("TestFetches") == 1


def test_an_engine_without_the_resource_lookup_falls_back_rather_than_erroring(lua):
    """Older EEex builds have no EEex_Resource_Fetch. The panel still opens."""
    lua.execute("EEex_Resource_Fetch = nil; BfBot.Theme._chromeArt = nil")
    assert lua.eval("BfBot.Theme.HasChromeArt()") is False
    assert lua.eval("BfBot.UI._TabBam()") == ENGINE_BUTTON
    assert lua.eval("BfBot.UI._ChromeSeq()") == 0


def test_a_failing_resource_lookup_is_not_cached_as_an_answer(lua):
    """A throwing fetch means "I could not find out", not "it is missing" —
    caching that would keep the art off for the rest of the session."""
    lua.execute(
        'EEex_Resource_Fetch = function() error("boom") end;'
        " BfBot.Theme._chromeArt = nil"
    )
    assert lua.eval("BfBot.Theme.HasChromeArt()") is False
    assert lua.eval("BfBot.Theme._chromeArt == nil") is True


def test_the_row_art_and_the_chrome_art_are_checked_separately():
    """They are separate installs' worth of files; one missing group must not
    take the other down with it."""
    assert "BfBot.Theme._controlArt" in THEME_SOURCE
    assert "BfBot.Theme._chromeArt" in THEME_SOURCE
    chrome = re.search(
        r"function BfBot\.Theme\.HasChromeArt\(\).*?^end$", THEME_SOURCE, re.S | re.M
    )
    assert chrome and "_controlArt" not in chrome.group(0)


def test_the_menu_still_compiles_its_lua_chunks():
    """Every `lua "..."` expression in the menu has to parse on its own."""
    runtime = LuaRuntime(unpack_returned_tuples=True)
    for expression in re.findall(r'(?:bam|sequence|frame) lua "([^"]+)"', MENU):
        assert runtime.eval(f"loadstring({expression!r})") is not None, expression