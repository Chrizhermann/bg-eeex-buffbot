"""The panel's chrome: Pecca's button plates, tabs, cast plate and scrollbar.

Step 1 of issue #81 shipped the art but left the panel on the engine's carved
stone. These tests pin the swap: that every button asks a helper which art to
draw rather than naming one, that the helper falls back to the engine art when
the themed art is absent, and that a tab's "I am the open one" frame is chosen
by the art in use rather than hard-coded to either number.

The art itself is four cycles — one per skin, 0 SoD / 1 IWD / 2 BG2 /
3 BG1 — with four state frames inside each.
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

# The art each helper names, and the engine art it falls back to outside
# IWD:EE (the fixture leaves engine_mode unset, as a BG game reads).
THEMED = {"_PlateBam": "BFBPLAT", "_TabBam": "BFBTAB", "_CastBam": "BFBCAST"}
ENGINE_BUTTON = "GUIOSTUL"
# engine.lua's engine_mode: 0 BG:EE, 1 BG2:EE (and EET), 2 IWD:EE, whose
# GUIOSTUL frames are unrelated texture fragments.
ENGINE_BUTTON_BY_MODE = {0: "GUIOSTUL", 1: "GUIOSTUL", 2: "GUIBUTMT"}


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
        (THEME_SOURCE, ("HasChromeArt", "ControlSkin", "ButtonBam")),
        (UI_SOURCE, ("_PlateBam", "_TabBam", "_CastBam", "_ChromeSeq", "_TabFrame", "_IsHeld", "_ChromeFrame")),
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


def test_every_chrome_button_decides_its_own_frame(request):
    """Every plate, tab and cast button asks _ChromeFrame, naming itself.

    Leaving `frame` out used to mean "let the engine run its states", and the
    engine does run them — it just draws Pecca's pressed frame, which is
    nearly the picture the normal one is. The frame is decided in Lua now,
    from the held counter, so every one of these buttons has to declare it.

    The name it passes is its own, because that is the one thing 74 near
    identical declarations get wrong: a copied button that keeps the name it
    was copied from reports its neighbour's press, not its own.
    """
    seen = 0
    for name, body in art_buttons():
        assert "frame lua" in body, f"{name} leaves its frame to the engine"
        call = re.search(r'frame lua "BfBot\.UI\._ChromeFrame\(([^"]*)\)"', body)
        assert call, f"{name} does not ask _ChromeFrame for its frame"
        passed = call.group(1).split(",")[0].strip()
        assert passed == f"'{name}'", (
            f"{name} passes {passed} to _ChromeFrame, not its own name"
        )
        seen += 1
    assert seen > 50, f"only {seen} chrome buttons found; the menu scan is wrong"


def test_a_tab_still_says_which_one_is_open():
    """The open tab outranks a press, so a tab passes its own predicate too.

    Hard-coding frame 1 or 2 here would be right for one art set and wrong
    for the other, which is why the answer stays inside the helper.
    """
    for name, body in art_buttons():
        if name not in TAB_BUTTONS:
            continue
        call = re.search(r'frame lua "BfBot\.UI\._ChromeFrame\(([^"]*)\)"', body)
        assert call, name
        arguments = call.group(1).split(",", 1)
        assert len(arguments) == 2, f"{name} no longer says whether it is open"
        assert "BfBot.UI." in arguments[1], name
        assert "and 1 or 0" not in body, name
        assert "and 2 or 0" not in body, name


def test_a_plate_leaves_the_open_question_to_the_tabs():
    """A footer button is never "the open one", so it passes one argument."""
    for name, body in art_buttons():
        if name in TAB_BUTTONS:
            continue
        call = re.search(r'frame lua "BfBot\.UI\._ChromeFrame\(([^"]*)\)"', body)
        assert call, name
        assert "," not in call.group(1), (
            f"{name} is not a tab but claims it can be the open one"
        )


@pytest.mark.parametrize("art", (True, False))
@pytest.mark.parametrize(
    ("held", "selected", "withArt", "withoutArt"),
    (
        (0, None, 0, 0),      # resting
        (1, None, 2, 1),      # held: the loud frame, or the engine's pressed one
        (99, None, 2, 1),     # still held, many frames later
        (0, True, 2, 1),      # the open tab
        (3, True, 2, 1),      # the open tab, held: it cannot look like less
    ),
)
def test_a_held_button_draws_the_loud_frame(lua, art, held, selected,
                                            withArt, withoutArt) -> None:
    """The whole point of #103: a press has to be visible.

    Pecca's pressed frame differs from its normal one by 62 of 255 at its
    loudest on the default skin, while the selected frame differs by 207 and
    carries the outline. A held button draws the selected frame. Without the
    art the engine's own button BAM is in use, whose pressed frame is its
    second — that one the engine drew properly all along.
    """
    with_art(lua, art)
    lua.execute(
        "EEex_Menu_GetItem = function(name)"
        "  if name ~= 'bbAdd' then return nil end"
        "  return { framesHeld = %d }"
        "end" % held
    )
    frame = lua.eval(
        "BfBot.UI._ChromeFrame('bbAdd', %s)"
        % ("true" if selected else "nil")
    )
    assert frame == (withArt if art else withoutArt)


def test_a_button_the_engine_cannot_answer_for_is_simply_not_held(lua) -> None:
    """Every way of not knowing has to read as "resting", never as an error.

    This runs on every build EEex supports and on a panel that may be closed,
    so the counter can be missing, the name unknown, or the lookup itself
    absent. A frame expression that raises takes the panel's draw with it.
    """
    with_art(lua, True)
    cases = {
        "no lookup at all": "EEex_Menu_GetItem = nil",
        "a name the menu does not have":
            "EEex_Menu_GetItem = function() return nil end",
        "a build without the counter":
            "EEex_Menu_GetItem = function() return {} end",
        "a counter that is not a number":
            "EEex_Menu_GetItem = function() return { framesHeld = 'yes' } end",
        "a lookup that raises":
            "EEex_Menu_GetItem = function() error('boom') end",
        "an item that raises when read":
            "EEex_Menu_GetItem = function()"
            "  return setmetatable({}, { __index = function() error('boom') end })"
            "end",
    }
    for label, stub in cases.items():
        lua.execute(stub)
        assert lua.eval("BfBot.UI._IsHeld('bbAdd')") is False, label
        assert lua.eval("BfBot.UI._ChromeFrame('bbAdd')") == 0, label


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


@pytest.mark.parametrize("helper", sorted(THEMED))
@pytest.mark.parametrize("mode,engine", sorted(ENGINE_BUTTON_BY_MODE.items()))
def test_each_helper_falls_back_to_the_running_games_own_button(
    lua, helper, mode, engine
):
    """IWD:EE's GUIOSTUL would draw texture fragments; its buttons are
    GUIBUTMT. The themed art is the same in every game."""
    lua.execute(f"engine_mode = {mode}")
    with_art(lua, False)
    assert lua.eval(f"BfBot.UI.{helper}()") == engine
    with_art(lua, True)
    assert lua.eval(f"BfBot.UI.{helper}()") == THEMED[helper]


# The art's own order, rendered and measured: skin 0 is deep red marble with
# gold filigree and a round socket, 1 is plain wood, 2 is cold grey steel with
# a square socket, 3 is warm dark stone. Mean colour of each cycle's normal
# frame in BFBPLAT: 0 = (28, 5, 4), 1 = (28, 16, 9), 2 = (36, 37, 35),
# 3 = (62, 53, 39).
#
# Which accent wears which comes from the games' own box and title art, the
# same source the three parchments were cut from: BG1 is brown tooled leather
# with brass hinges, BG2 is blue-teal leather in a gold frame, SoD is red.
#
# Do NOT re-derive this from a UI resource. The in-game side panel GUIWLSP
# runs the other way round -- BG:EE's is blue slate, BG2:EE's is tan -- and
# reading the mapping off engine art shipped it wrong twice before v1.12.3
# (#102). The games' identity is the contract; the sidebar is not.
CONTROL_SKINS = {"sod": 0, "bg2": 2, "bg1": 3}

# True where that skin's art is warm (red > blue above), false where it is
# cold. The palette that selects a skin has to agree: a warm accent on the
# grey plates, or a cold one on the red, is the swap this records.
SKIN_IS_WARM = {0: True, 1: True, 2: False, 3: True}

# The numbered background and border pages, by the look they carry. Measured
# the same way, off assets/themes: the 991x pages and the FR2 atlas are the
# blue-grey parchment (mean r-b -11), 992x and FR3 the red-brown one (+32).
# The unnumbered pair is BG2's warm parchment.
PARCHMENT_IS_WARM = {
    ("BFBOTBG", "BFBOTFR"): True,
    ("BFBOTBG2", "BFBOTFR2"): False,
    ("BFBOTBG3", "BFBOTFR3"): True,
}


def _palettes() -> dict[str, dict[str, str]]:
    """Every palette in BfBotThm's table, as flat key -> value strings."""
    out: dict[str, dict[str, str]] = {}
    for name, body in re.findall(
        r"^    (\w+) = \{\n(.*?)^    \},$", THEME_SOURCE, re.S | re.M
    ):
        # A value is either a quoted string -- "{R, G, B}" carries commas of
        # its own, so it cannot be read up to the first one -- or a bare
        # number.
        out[name] = {
            key: quoted or bare
            for key, quoted, bare in re.findall(
                r'^\s*(\w+)\s*=\s*(?:"([^"]*)"|([^\s,]+))\s*,', body, re.M
            )
        }
    return out


def _warmth(palette: dict[str, str], key: str) -> int:
    """red minus blue for one "{R, G, B}" entry."""
    r, _g, b = (
        int(part) for part in re.findall(r"\d+", palette[key])
    )
    return r - b


def test_every_accent_wears_its_own_game_s_colours() -> None:
    """The three things that make up an accent -- its text colours, the
    parchment and border it names, and the chrome skin it selects -- all have
    to carry the same temperature. Flipping any one of them alone is what
    dressed BG:EE in SoD's red for six releases (#102)."""
    palettes = _palettes()
    assert set(palettes) == {
        f"{accent}_{mode}"
        for accent in CONTROL_SKINS
        for mode in ("light", "dark")
    }, sorted(palettes)

    for accent, skin in CONTROL_SKINS.items():
        warm = SKIN_IS_WARM[skin]
        for mode in ("light", "dark"):
            palette = palettes[f"{accent}_{mode}"]
            pages = (palette["bgResref"], palette["borderResref"])
            assert PARCHMENT_IS_WARM[pages] is warm, (accent, mode, pages)
            # title and grip are the two the panel shows largest; a cold
            # accent must not tint them warm, nor a warm one cold.
            for key in ("title", "grip", "headerSub"):
                hot = _warmth(palette, key) > 0
                assert hot is warm, (accent, mode, key, palette[key])


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


def test_the_in_game_theming_phase_asserts_the_palette_it_names() -> None:
    """The lab phase pins a title colour by value, so it names its palette.

    `BfBot.Test.RunAll()`'s Theming phase swaps one palette in and asserts its
    title both packed and raw. Those literals belong to one palette, and #102
    moved every name onto the art it describes -- the warm title travelled from
    bg2_light to bg1_light and the phase failed in the lab while the whole
    offline suite stayed green. Nothing offline read the in-game suite, so this
    reads it: the palette the phase names must be the one carrying the colour
    it asserts, whatever the names are next time.
    """
    source = (ROOT / "buffbot/BfBotTst.lua").read_text(encoding="utf-8")
    block = re.search(
        r"BfBot\.Theme\._active = BfBot\.Theme\._palettes\.(\w+)\s*\n"
        r".*?_T\(\"title\"\) == \((\d+) \* 0x10000\) \+ \((\d+) \* 0x100\) \+ (\d+)\)"
        r".*?_TRaw\(\"title\"\) == \"(\{[^\"]*\})\"",
        source,
        re.S,
    )
    assert block, "the Theming phase's packing block is no longer recognisable"

    name, blue, green, red, raw = block.groups()
    palettes = _palettes()
    assert name in palettes, f"the Theming phase swaps in {name}, which is gone"
    assert palettes[name]["title"] == raw, (
        f"the phase asserts {raw} for {name}'s title, but the palette now"
        f" carries {palettes[name]['title']}"
    )
    # The packed literals are the same three channels, in the engine's order.
    assert raw == "{%s, %s, %s}" % (red, green, blue), (
        "the packed assertion and the raw one disagree about the colour"
    )


def test_an_install_that_never_chose_a_scheme_opens_on_one_palette() -> None:
    """Both places that decide the default must name the same palette.

    The pointer and the INI fallback are two chances to disagree, and after
    #102 they did: the pointer moved to the warm parchment with its art while
    the fallback still read "bg2_light", which by then meant the blue-teal
    set. A player who had never touched the Color Scheme radio would have
    opened a different panel than the one they had always seen. One name now
    feeds both, and this fails if a second name reappears.
    """
    default = re.search(
        r'BfBot\.Theme\.DEFAULT_PALETTE = "(\w+)"', THEME_SOURCE)
    assert default, "the default palette is no longer named once"
    name = default.group(1)
    assert name in _palettes(), f"the default names {name}, which is not a palette"

    pointer = re.search(
        r"BfBot\.Theme\._active = BfBot\.Theme\._palettes"
        r"\[BfBot\.Theme\.DEFAULT_PALETTE\]", THEME_SOURCE)
    assert pointer, "the active palette no longer starts from DEFAULT_PALETTE"

    loader = THEME_SOURCE.split("function BfBot.Theme._LoadFromINI", 1)[1].split(
        "\nfunction ", 1)[0]
    assert "BfBot.Theme.DEFAULT_PALETTE" in loader, (
        "the INI fallback no longer uses the one default"
    )
    assert not re.search(r'name = "(\w+)"', loader), (
        "the INI fallback names a palette of its own again"
    )

    # The default is the warm parchment, which is the art every install has
    # shown since v1.0 -- its pages, not its name, are what must not move.
    assert _palettes()[name]["bgResref"] == "BFBOTBG", (
        "the default no longer opens on the parchment installs have always had"
    )
