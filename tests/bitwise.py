"""BuffBot's bitwise helpers, for fixtures that load a module without the core.

The shipped modules call `BfBot._BAnd` / `_BOr` / `_BNot` / `_BLShift` instead
of `bit.*`, so BuffBot loads on an EEex install without the LuaJIT loader
(issue #106). `BfBotCor.lua` resolves them once at load: to LuaJIT's `bit` when
it exists, to EEex's `EEex_BAnd` / `EEex_BOr` / `EEex_BNot` natives when it does
not, with a multiplication fallback for the byte-aligned shifts.

Most fixtures load one module on its own and never load the core, so they have
to supply the helpers themselves. This snippet gives them the LuaJIT path,
which is what lupa provides -- it deliberately does NOT re-implement the
resolver. `tests/test_bitwise_helpers.py` drives the real one in
`BfBotCor.lua` through both paths, so there is one place that proves the
resolution and one place that keeps every other fixture running.

    from bitwise import BITWISE
    runtime.execute(BITWISE)      # after BfBot exists, before a module loads
"""

BITWISE = """
BfBot = BfBot or {}
do
    local lib = require('bit')
    -- Variadic, like the real helpers: the item usability check ANDs four
    -- masks in one call, and a two-argument stand-in would pass the tests
    -- that matter while dropping two of them.
    function BfBot._BAnd(...) return lib.band(...) end
    function BfBot._BOr(...) return lib.bor(...) end
    function BfBot._BNot(a) return lib.bnot(a) end
    function BfBot._BLShift(value, count) return lib.lshift(value, count) end
    function BfBot._BitwiseAvailable() return true end
end
"""
