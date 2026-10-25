import re
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
THEME_SOURCE = (ROOT / "buffbot/BfBotThm.lua").read_text(encoding="utf-8")
MENU_SOURCE = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")


def _button_bam(engine_mode: int | None) -> str:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("BfBot = {}")
    if engine_mode is not None:
        runtime.execute(f"engine_mode = {engine_mode}")
    runtime.execute(THEME_SOURCE)
    return runtime.eval("BfBot.Theme.ButtonBam()")


# engine.lua's engine_mode: 0 BG:EE, 1 BG2:EE (and EET), 2 IWD:EE. IWD:EE's
# GUIOSTUL frames are unrelated texture fragments; its buttons use GUIBUTMT.
@pytest.mark.parametrize(
    ("engine_mode", "expected"),
    [(0, "GUIOSTUL"), (1, "GUIOSTUL"), (2, "GUIBUTMT"), (None, "GUIOSTUL")],
)
def test_button_bam_follows_the_running_game(
    engine_mode: int | None,
    expected: str,
) -> None:
    assert _button_bam(engine_mode) == expected


def test_menu_draws_engine_buttons_through_the_theme() -> None:
    # Engine art differs per game; only BuffBot's own BAMs may be static.
    static = re.findall(r'^\s*bam\s+"([^"]+)"', MENU_SOURCE, re.M)
    themed = re.findall(
        r'^\s*bam\s+lua\s+"BfBot\.Theme\.ButtonBam\(\)"', MENU_SOURCE, re.M)

    assert static and all(name.upper().startswith("BFB") for name in static)
    assert themed
    assert "GUIOSTUL" not in MENU_SOURCE
