"""Every colour the panel asks for has to exist in every palette.

`BfBot.UI._T` answers magenta for a key the active palette does not define —
a deliberate debug signal, and the right behaviour at runtime. Offline it was
invisible: nothing read the keys the menu and the modules actually ask for, so
`_T('textDim')` shipped in the recipient view's source column and drew the
loudest thing on the panel in bright magenta, in all six palettes at once
(#81, caught in the lab).

These read both sides — what is asked for, and what each palette defines —
and meet in the middle.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
THEME = (ROOT / "buffbot/BfBotThm.lua").read_text(encoding="utf-8")
MENU = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")

# The in-game suite probes the fallback on purpose; that key must NOT exist.
PROBED_ON_PURPOSE = {"nonexistent"}

ASKED = re.compile(r"""_T(?:Raw)?\(\s*["']([A-Za-z_][A-Za-z0-9_]*)["']\s*\)""")


def _palettes() -> dict[str, set[str]]:
    """Each palette's key set, read from the table BfBotThm.lua declares."""
    block = re.search(r"BfBot\.Theme\._palettes\s*=\s*\{(.*?)\n\}\n",
                      THEME, re.S)
    assert block, "the palette table moved"
    found: dict[str, set[str]] = {}
    for match in re.finditer(
            r"\n    (\w+)\s*=\s*\{(.*?)\n    \},", block.group(1), re.S):
        name, body = match.group(1), match.group(2)
        found[name] = set(re.findall(r"\n        (\w+)\s*=", body))
    assert len(found) >= 6, f"expected the six palettes, got {sorted(found)}"
    return found


def _asked(source: str) -> set[str]:
    return {key for key in ASKED.findall(source)
            if key not in PROBED_ON_PURPOSE}


def _shipped_lua() -> dict[str, str]:
    return {path.name: path.read_text(encoding="utf-8")
            for path in sorted((ROOT / "buffbot").glob("*.lua"))}


PALETTES = _palettes()


@pytest.mark.parametrize("palette", sorted(PALETTES))
def test_every_colour_the_menu_asks_for_exists_in_every_palette(palette):
    missing = sorted(_asked(MENU) - PALETTES[palette])
    assert not missing, f"{palette} has no {missing}"


@pytest.mark.parametrize("palette", sorted(PALETTES))
def test_every_colour_the_modules_ask_for_exists_in_every_palette(palette):
    for name, source in _shipped_lua().items():
        missing = sorted(_asked(source) - PALETTES[palette])
        assert not missing, f"{name} asks {palette} for {missing}"


def test_the_palettes_all_define_the_same_keys():
    """A key one palette has and another lacks is magenta in that theme."""
    names = sorted(PALETTES)
    reference = PALETTES[names[0]]
    for name in names[1:]:
        assert PALETTES[name] == reference, (
            f"{name} differs from {names[0]}: "
            f"only in {names[0]}: {sorted(reference - PALETTES[name])}, "
            f"only in {name}: {sorted(PALETTES[name] - reference)}")


def test_the_fallback_probe_is_still_a_key_no_palette_defines():
    """The deliberate exception above has to stay deliberate."""
    for key in PROBED_ON_PURPOSE:
        for name, keys in PALETTES.items():
            assert key not in keys, f"{name} now defines {key}"


def test_the_recipient_view_uses_a_colour_that_exists():
    """The one this file was written for."""
    assert "_T('textDim')" not in MENU
    source = (ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8")
    assert "textDim" not in source
