"""BuffBot's bitwise helpers must work with and without the LuaJIT loader.

`bit` is LuaJIT's library. EEex's own Lua has no such table, so every `bit.*`
call in the shipped code is what stopped BuffBot loading on an install without
the LuaJIT loader -- not the `goto` statements the installer used to blame,
which are ordinary Lua 5.2 (issue #106).

`BfBotCor.lua` resolves four helpers once at load: to `bit` where it exists,
to EEex's `EEex_BAnd` / `EEex_BOr` / `EEex_BNot` natives where it does not.
Those natives are registered by the loader on every EEex release BuffBot
supports, verified in 1.2.0's and 1.3.1's `InfinityLoaderDLL.dll`. There is no
shift native, so byte-aligned shifts fall back to multiplication.

Other fixtures get the helpers from `tests/bitwise.py`, which only provides
the LuaJIT path. This file is the one that drives the real resolver.
"""

from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime

CORE = (Path(__file__).resolve().parents[1]
        / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")

# Operand sets that exercise the cases the shipped code actually passes:
# single masks, the four-way alignment mask, and a high bit that makes
# LuaJIT's signed 32-bit result negative.
AND_CASES = [
    ((0xFF, 0x0F), 0x0F),
    ((0x1016E, 0xFFFDFFFF), 0x1016E & 0xFFFDFFFF),
    ((0xFFFF, 0xF0F0, 0x0FF0, 0x00F0), 0x00F0),
]
OR_CASES = [
    ((0x01, 0x02), 0x03),
    ((0x01, 0x02, 0x04, 0x08), 0x0F),
    ((0x4000, 0x0080, 0x0002, 0x0001), 0x4083),
]


def _runtime(luajit: bool) -> LuaRuntime:
    """A runtime with the helpers resolved one way or the other.

    With `luajit=False` the `bit` global is removed before the core loads, and
    EEex's natives are supplied the way the loader supplies them -- which is
    the whole point: that path has never run in this test suite before.
    """
    runtime = LuaRuntime(unpack_returned_tuples=True)
    if luajit:
        runtime.execute("bit = require('bit')")
    else:
        runtime.execute("""
            local real = require('bit')
            bit = nil
            -- The loader registers these as prefix + name; they take two
            -- operands, which is why the helpers fold rather than forward.
            EEex_BAnd = function(a, b) return real.band(a, b) end
            EEex_BOr = function(a, b) return real.bor(a, b) end
            EEex_BNot = function(a) return real.bnot(a) end
        """)
    runtime.execute(CORE)
    return runtime


@pytest.mark.parametrize("luajit", [True, False], ids=["luajit", "plain-eeex"])
@pytest.mark.parametrize("operands,expected", AND_CASES)
def test_and_folds_every_operand(luajit, operands, expected):
    lua = _runtime(luajit)
    call = ", ".join(hex(value) for value in operands)
    assert lua.eval(f"BfBot._BAnd({call})") == expected


@pytest.mark.parametrize("luajit", [True, False], ids=["luajit", "plain-eeex"])
@pytest.mark.parametrize("operands,expected", OR_CASES)
def test_or_folds_every_operand(luajit, operands, expected):
    lua = _runtime(luajit)
    call = ", ".join(hex(value) for value in operands)
    assert lua.eval(f"BfBot._BOr({call})") == expected


@pytest.mark.parametrize("luajit", [True, False], ids=["luajit", "plain-eeex"])
def test_a_two_operand_wrapper_would_have_dropped_masks(luajit):
    # The regression this fold exists for: the item usability check ANDs a
    # class, race, ethic and moral mask in one call. A wrapper keeping the
    # first two would let a restricted item through.
    lua = _runtime(luajit)
    assert lua.eval("BfBot._BOr(0x1, 0x2, 0x4, 0x8)") == 0xF
    assert lua.eval("BfBot._BOr(0x1, 0x2)") != 0xF


@pytest.mark.parametrize("luajit", [True, False], ids=["luajit", "plain-eeex"])
def test_not_matches_the_library(luajit):
    lua = _runtime(luajit)
    # bnot(1) is -2 as a signed 32-bit value; clearing a flag bit relies on it.
    assert lua.eval("BfBot._BNot(1)") == -2
    assert lua.eval("BfBot._BAnd(0xFF, BfBot._BNot(1))") == 0xFE


@pytest.mark.parametrize("count", [0, 8, 16, 24])
@pytest.mark.parametrize("value", [0x00, 0x01, 0x7F, 0x80, 0xFF])
def test_the_shift_fallback_matches_luajit_on_byte_aligned_counts(value, count):
    # There is no shift native, so without LuaJIT the helper multiplies. Every
    # shift in the shipped code is a byte read out of memory moved by 8, 16 or
    # 24, so the two must agree exactly across that range.
    reference = _runtime(True).eval(f"BfBot._BLShift({value}, {count})")
    fallback = _runtime(False).eval(f"BfBot._BLShift({value}, {count})")
    # LuaJIT returns a signed 32-bit result; the multiplication does not, so
    # compare the low 32 bits, which is all any caller masks against.
    assert fallback % (2 ** 32) == reference % (2 ** 32)


def test_the_kit_mask_is_assembled_the_same_either_way():
    # The exact expression BfBot.Scan._CanWearItem builds from four ITM bytes,
    # with a high byte so the signed/unsigned difference shows up if it exists.
    expression = ("BfBot._BOr(BfBot._BLShift(0x80, 24), "
                  "BfBot._BLShift(0x40, 16), BfBot._BLShift(0x20, 8), 0x10)")
    with_luajit = _runtime(True).eval(expression)
    without = _runtime(False).eval(expression)
    assert with_luajit % (2 ** 32) == without % (2 ** 32) == 0x80402010


def test_a_loader_offering_neither_reports_it_instead_of_failing_later():
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("bit = nil")
    runtime.execute(CORE)
    # The module still loads -- the scanner and classifier cannot work, but
    # that has to be reportable rather than discovered one nil-call at a time.
    assert runtime.eval("BfBot._BitwiseAvailable()") is False


@pytest.mark.parametrize("luajit", [True, False], ids=["luajit", "plain-eeex"])
def test_available_is_true_on_a_loader_that_offers_either(luajit):
    assert _runtime(luajit).eval("BfBot._BitwiseAvailable()") is True


def test_no_shipped_module_calls_the_luajit_library_directly():
    buffbot = Path(__file__).resolve().parents[1] / "buffbot"
    offenders = []
    for path in sorted(buffbot.glob("*.lua")):
        for number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(), start=1):
            if line.lstrip().startswith("--"):
                continue
            if "bit." in line and path.name != "BfBotCor.lua":
                offenders.append(f"{path.name}:{number}")
    assert not offenders, (
        "these call LuaJIT's bit library directly, which does not exist on an "
        "EEex install without the LuaJIT loader: " + ", ".join(offenders))
