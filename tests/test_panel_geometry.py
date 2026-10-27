"""The panel's geometry: where the controls actually land.

The suite checked each footer row on its own, at one panel size, inside
hardcoded bounds, and the .menu's static areas separately. A caption that
reaches past its button, a row that grows into its neighbour, or a control
that leaves the panel had nothing to fail on. v1.12.0 moved all 78 captions
onto their own label items and made the footer one centred toolbar, so the
geometry is worth checking rather than eyeballing (reported in game:
controls overlapping and not reacting).

Sizes include the player-reported 1075x621 and the 550x350 minimum.
"""

from __future__ import annotations

import faulthandler
import re
import sys
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime

from test_repeat_ui import repeat_ui_lua  # noqa: F401 - shared fixture

ROOT = Path(__file__).resolve().parents[1]
MENU = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")
UI_SOURCE = (ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8")

PANEL_X, PANEL_Y = 100, 50

# The minimum, the player's own, and sizes between.
SIZES = [(550, 350), (700, 480), (1075, 621), (1400, 900), (1920, 1080)]

# The footer rows, in the order _Layout places them. The variant row shares
# its y with the normal row by design -- only one view is ever enabled -- so
# the two are never compared against each other.
NORMAL_ROWS = [
    ["bbAdd", "bbRmv", "bbRepeat", "bbExp", "bbImp"],
    ["bbTog", "bbTgt", "bbUp", "bbDn", "bbSort", "bbOrder", "bbDel"],
    ["bbCast", "bbCastChar", "bbStop", "bbQC", "bbClose"],
    ["bbStatus", "bbForce"],
]
VARIANT_ROW = [
    "bbVTog", "bbVTgt", "bbVVar", "bbVUp", "bbVDn", "bbVSort", "bbVOrder",
    "bbVDel",
]

LAYOUT_LUA = """
local areas = {}
captionScales = {}
BfBot.Theme.ApplyCaptionScales = function(scales)
    captionScales = {}
    for name, scale in pairs(scales or {}) do captionScales[name] = scale end
end
Infinity_GetScreenSize = function() return 1920, 1080 end
Infinity_SetArea = function(name, x, y, w, h)
    areas[name] = { x, y, w, h }
end
buffbot_charNames = {}
for i = 1, %d do buffbot_charNames[i] = "Character " .. i end
buffbot_presetNames = {}
for i = 1, %d do buffbot_presetNames[i] = "Preset " .. i end
BfBot.UI._panelX = %d
BfBot.UI._panelY = %d
BfBot.UI._panelW = %d
BfBot.UI._panelH = %d
BfBot.UI._Layout()
return areas
"""

# A party and a preset list are rarely full. Each count leaves reserved slots
# that are disabled but still laid out, which is where the tab rows went
# wrong: sized for the tabs that exist, placed for all six or all eight.
COUNTS = [(1, 1), (2, 3), (4, 5), (6, 8)]


def _layout(
    lua: LuaRuntime, width: int, height: int,
    chars: int = 6, presets: int = 8,
) -> dict[str, tuple[int, ...]]:
    """Run _Layout at one panel size and return every area it set."""
    # _Layout uses Lua pcall for the paired overlays; lupa implements that with
    # a Windows SEH signal that faulthandler reports despite a clean result.
    suppress = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress:
        faulthandler.disable()
    try:
        areas = lua.execute(
            LAYOUT_LUA % (chars, presets, PANEL_X, PANEL_Y, width, height)
        )
    finally:
        if suppress:
            faulthandler.enable()
    return {
        name: tuple(int(values[index]) for index in range(1, 5))
        for name, values in areas.items()
    }


def _overlaps(first: tuple[int, ...], second: tuple[int, ...]) -> bool:
    ax, ay, aw, ah = first
    bx, by, bw, bh = second
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah


@pytest.mark.parametrize(("width", "height"), SIZES)
def test_no_two_controls_in_a_row_overlap(repeat_ui_lua, width, height) -> None:
    areas = _layout(repeat_ui_lua, width, height)
    for row in NORMAL_ROWS + [VARIANT_ROW]:
        placed = [(name, areas[name]) for name in row if name in areas]
        for index, (name, rect) in enumerate(placed):
            for other_name, other in placed[index + 1:]:
                assert not _overlaps(rect, other), (
                    f"{width}x{height}: {name} {rect} overlaps "
                    f"{other_name} {other}"
                )


@pytest.mark.parametrize(("width", "height"), SIZES)
def test_the_footer_rows_do_not_grow_into_each_other(
    repeat_ui_lua, width, height
) -> None:
    areas = _layout(repeat_ui_lua, width, height)
    bands = []
    for row in NORMAL_ROWS:
        rects = [areas[name] for name in row if name in areas]
        bands.append(
            (min(rect[1] for rect in rects),
             max(rect[1] + rect[3] for rect in rects))
        )
    for (_, prior_bottom), (next_top, _) in zip(bands, bands[1:]):
        assert prior_bottom <= next_top, (
            f"{width}x{height}: a footer row reaches into the next one "
            f"({prior_bottom} > {next_top})"
        )


@pytest.mark.parametrize(("width", "height"), SIZES)
def test_every_control_stays_inside_the_panel(repeat_ui_lua, width, height) -> None:
    areas = _layout(repeat_ui_lua, width, height)
    for name, (x, y, w, h) in sorted(areas.items()):
        # The click-to-close dimmer and the quick-preset menu are screen-placed
        # on purpose; everything else belongs to the panel.
        if name.startswith("bbQuick") or name == "bbOutside":
            continue
        assert w > 0 and h > 0, f"{width}x{height}: {name} has no size"
        assert PANEL_X <= x and x + w <= PANEL_X + width, (
            f"{width}x{height}: {name} leaves the panel horizontally "
            f"({x}..{x + w} outside {PANEL_X}..{PANEL_X + width})"
        )
        assert PANEL_Y <= y and y + h <= PANEL_Y + height, (
            f"{width}x{height}: {name} leaves the panel vertically "
            f"({y}..{y + h} outside {PANEL_Y}..{PANEL_Y + height})"
        )


@pytest.mark.parametrize(("chars", "presets"), COUNTS)
@pytest.mark.parametrize(("width", "height"), SIZES)
def test_a_half_full_party_or_preset_list_keeps_every_slot_in_the_panel(
    repeat_ui_lua, width, height, chars, presets
) -> None:
    """The tab rows size themselves to the tabs that exist but place all six
    character and all eight preset slots, because an unfilled slot is only
    disabled. Sizing for two and placing eight put the spare slots outside
    the parchment, under the frame and over whatever stands beside the
    panel."""
    areas = _layout(repeat_ui_lua, width, height, chars=chars, presets=presets)
    slots = [f"bbC{index}" for index in range(6)]
    slots += [f"bbP{index}" for index in range(1, 9)]
    slots += [f"bbS{index}" for index in range(6)]
    for name in slots:
        if name not in areas:
            continue
        x, _, w, _ = areas[name]
        assert PANEL_X <= x and x + w <= PANEL_X + width, (
            f"{width}x{height}, {chars} character(s)/{presets} preset(s): "
            f"{name} sits at {x}..{x + w}, outside {PANEL_X}.."
            f"{PANEL_X + width}"
        )


@pytest.mark.parametrize(("chars", "presets"), COUNTS)
def test_the_visible_tabs_never_overlap_their_row_neighbours(
    repeat_ui_lua, chars, presets
) -> None:
    """A visible tab must not grow into the view toggle or into Rename."""
    areas = _layout(repeat_ui_lua, 1075, 621, chars=chars, presets=presets)
    char_row = [f"bbC{index}" for index in range(chars)] + ["bbView"]
    preset_row = [f"bbP{index}" for index in range(1, presets + 1)]
    preset_row += ["bbRen", "bbNew"]
    for row in (char_row, preset_row):
        placed = [(name, areas[name]) for name in row if name in areas]
        for index, (name, rect) in enumerate(placed):
            for other_name, other in placed[index + 1:]:
                assert not _overlaps(rect, other), (
                    f"{chars} character(s)/{presets} preset(s): {name} "
                    f"{rect} overlaps {other_name} {other}"
                )


def _caption_scales(lua: LuaRuntime) -> dict[str, float]:
    return dict(lua.eval("captionScales").items())


def _natural_widths() -> dict[str, int]:
    """The widths written into _Layout's row() calls: each caption's own size
    at the default font, before any row has to give way."""
    widths = {
        name: int(width)
        for name, width in re.findall(r'\{\s*"(bb[A-Za-z0-9_]+)"\s*,\s*(\d+)\s*\}',
                                      UI_SOURCE)
    }
    assert len(widths) > 15, widths
    return widths


@pytest.mark.parametrize(("width", "height"), SIZES)
def test_a_caption_shrinks_by_exactly_what_its_plate_lost(
    repeat_ui_lua, width, height
) -> None:
    """A row that does not fit narrows every plate in it. The captions are
    separate labels drawn at the font's own size, so without this they kept
    their width while the plates shrank -- printing over the plate beside
    them, which is where the click then landed."""
    areas = _layout(repeat_ui_lua, width, height)
    scales = _caption_scales(repeat_ui_lua)
    natural = _natural_widths()
    assert scales, "the layout reported no caption scales at all"
    for name, scale in sorted(scales.items()):
        assert 0 < scale <= 1, (name, scale)
        assert scale == pytest.approx(areas[name][2] / natural[name]), (
            f"{width}x{height}: {name} scaled its caption {scale} while its "
            f"plate went {natural[name]} -> {areas[name][2]}"
        )


def test_the_minimum_panel_actually_squeezes_something(repeat_ui_lua) -> None:
    """Otherwise the check above passes on a layout that never shrinks."""
    _layout(repeat_ui_lua, 550, 350)
    scales = _caption_scales(repeat_ui_lua)
    assert any(scale < 1 for scale in scales.values()), (
        "nothing shrank at the 550px minimum, where the rows do not fit"
    )


def test_a_panel_wide_enough_leaves_the_normal_rows_alone(repeat_ui_lua) -> None:
    """The variant row carries one control more than the normal one and sits
    marginally over the bar's 980px cap even on a large panel, so only the
    rows that do fit are expected at full size."""
    _layout(repeat_ui_lua, 1920, 1080)
    scales = _caption_scales(repeat_ui_lua)
    shrunk = {name: scale for name, scale in scales.items()
              if scale < 1 and not name.startswith("bbV")}
    assert not shrunk, shrunk


def test_every_caption_is_repositioned_with_its_control() -> None:
    """A caption is a separate label drawn over its button, so whatever moves
    the button has to move the caption. _Layout's setArea pairs "<name>_t"
    for everything it places; a direct Infinity_SetArea does not, and the
    caption then stays where the .menu put it while the button travels."""
    captions = {
        name[:-2]
        for name in re.findall(r'^\s*name\s+"([A-Za-z0-9_]+_t)"', MENU, re.M)
    }
    paired = set(re.findall(r'setArea\("([A-Za-z0-9_]+)"', UI_SOURCE))
    paired |= set(re.findall(r'\{\s*"([A-Za-z0-9_]+)"\s*,', UI_SOURCE))
    numbered_pairs = set(re.findall(r'setArea\("([A-Za-z0-9_]+)"\s*\.\.',
                                    UI_SOURCE))
    direct = set(re.findall(r'Infinity_SetArea\("([A-Za-z0-9_]+)"', UI_SOURCE))

    def numbered(base: str, prefixes: set[str]) -> bool:
        return any(base.startswith(prefix) and base[len(prefix):].isdigit()
                   for prefix in prefixes)

    orphans = sorted(
        base for base in captions
        if base not in paired and not numbered(base, numbered_pairs)
        and (base in direct or numbered(base, direct))
    )
    assert not orphans, (
        "these captions are never moved with their control: "
        + ", ".join(name + "_t" for name in orphans)
    )
