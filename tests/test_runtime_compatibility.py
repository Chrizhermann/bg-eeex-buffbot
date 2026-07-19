from __future__ import annotations

import faulthandler
from pathlib import Path
import sys

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")


class _OpaqueUserData:
    pass


@pytest.fixture
def lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.globals().python_userdata = _OpaqueUserData()
    runtime.execute(
        """
        assert(type(python_userdata) == "userdata")
        BfBot = {
            MAX_PRESETS = 8,
            Scan = {}, Class = {}, Innate = {}, Mp = {},
            _Warn = function(_) end,
            _StripColorEscape = function(s) return s end,
        }
        """
    )
    runtime.execute(PERSIST_SOURCE)
    return runtime


def test_marshal_safe_copy_converts_nested_boolean_values(lua: LuaRuntime) -> None:
    safe, dropped = lua.execute(
        """
        local source = {
            enabled = true,
            nested = { disabled = false, deeper = { active = true } },
        }
        return BfBot.Persist._MarshalSafeCopy(source)
        """
    )

    assert safe["enabled"] == 1
    assert safe["nested"]["disabled"] == 0
    assert safe["nested"]["deeper"]["active"] == 1
    assert dropped == 0


def test_marshal_safe_copy_preserves_scalars_arrays_and_mixed_keys(
    lua: LuaRuntime,
) -> None:
    safe, dropped = lua.execute(
        """
        local source = {
            [1] = "first",
            [2] = "second",
            [7] = "sparse",
            label = "preserved exactly",
            number = -123,
            nested = { [-2] = "negative", name = "mixed" },
        }
        return BfBot.Persist._MarshalSafeCopy(source)
        """
    )

    assert safe[1] == "first"
    assert safe[2] == "second"
    assert safe[7] == "sparse"
    assert safe["label"] == "preserved exactly"
    assert safe["number"] == -123
    assert safe["nested"][-2] == "negative"
    assert safe["nested"]["name"] == "mixed"
    assert dropped == 0


def test_marshal_safe_copy_preserves_v011_round_trip_safe_numeric_values(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local source = {
            ordinary = 42,
            schemaMinusOne = -1,
            u8Min = 0,
            u8Max = 255,
            u16Min = 256,
            u16Max = 65535,
            u32Min = 65536,
            u32Max = 4294967295,
            u64Min = 4294967296,
            u64LastRepresentable = (2 ^ 64) - 2048,
            i8Min = -128,
            i16Near = -257,
            i16Min = -32768,
            i32Near = -65537,
            i32Min = -(2 ^ 31),
            i64Near = -4294967297,
            i64Min = -(2 ^ 63),
        }
        local safe, dropped = BfBot.Persist._MarshalSafeCopy(source)
        local preserved = true
        local sourceCount, safeCount = 0, 0
        for key, value in pairs(source) do
            sourceCount = sourceCount + 1
            if safe[key] ~= value then preserved = false end
        end
        for _ in pairs(safe) do safeCount = safeCount + 1 end
        return {
            preserved = preserved,
            sameCount = safeCount == sourceCount,
            fresh = safe ~= source,
            dropped = dropped,
        }
        """
    )

    assert facts["preserved"]
    assert facts["sameCount"]
    assert facts["fresh"]
    assert facts["dropped"] == 0


def test_marshal_safe_copy_drops_v011_unsafe_numeric_values(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local source = {
            fraction = 1.5,
            negativeFraction = -1.5,
            nan = 0 / 0,
            positiveInfinity = math.huge,
            negativeInfinity = -math.huge,
            positiveOutside = 2 ^ 64,
            negativeOutside = -(2 ^ 63) - 2048,
            i8GapHigh = -129,
            i8GapLow = -256,
            i16GapHigh = -32769,
            i16GapLow = -65536,
            i32GapHigh = -2147483649,
            i32GapLow = -4294967296,
            keep = 7,
        }
        local safe, dropped = BfBot.Persist._MarshalSafeCopy(source)
        return {
            unsafeDropped = safe.fraction == nil
                and safe.negativeFraction == nil
                and safe.nan == nil
                and safe.positiveInfinity == nil
                and safe.negativeInfinity == nil
                and safe.positiveOutside == nil
                and safe.negativeOutside == nil
                and safe.i8GapHigh == nil and safe.i8GapLow == nil
                and safe.i16GapHigh == nil and safe.i16GapLow == nil
                and safe.i32GapHigh == nil and safe.i32GapLow == nil,
            safePreserved = safe.keep == 7,
            sourceUnchanged = source.fraction == 1.5
                and source.negativeFraction == -1.5
                and source.nan ~= source.nan
                and source.positiveInfinity == math.huge
                and source.negativeInfinity == -math.huge
                and source.keep == 7,
            dropped = dropped,
        }
        """
    )

    assert facts["unsafeDropped"]
    assert facts["safePreserved"]
    assert facts["sourceUnchanged"]
    assert facts["dropped"] == 13


def test_marshal_safe_copy_filters_numeric_keys_by_v011_round_trip_safety(
    lua: LuaRuntime,
) -> None:
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        facts = lua.execute(
            """
            local source = {}
            local entries = {
                { 0, "zero" },
                { 255, "u8 max" },
                { 256, "u16 min" },
                { 65535, "u16 max" },
                { 65536, "u32 min" },
                { 4294967295, "u32 max" },
                { 4294967296, "u64 min" },
                { (2 ^ 64) - 2048, "u64 last representable" },
                { -1, "schema minus one" },
                { -128, "i8 min" },
                { -257, "i16 near" },
                { -32768, "i16 min" },
                { -65537, "i32 near" },
                { -(2 ^ 31), "i32 min" },
                { -4294967297, "i64 near" },
                { -(2 ^ 63), "i64 min" },
                { 1.5, "fraction" },
                { -1.5, "negative fraction" },
                { 0 / 0, "nan" },
                { math.huge, "positive infinity" },
                { -math.huge, "negative infinity" },
                { 2 ^ 64, "positive outside" },
                { -(2 ^ 63) - 2048, "negative outside" },
                { -129, "i8 gap high" },
                { -256, "i8 gap low" },
                { -32769, "i16 gap high" },
                { -65536, "i16 gap low" },
                { -2147483649, "i32 gap high" },
                { -4294967296, "i32 gap low" },
            }
            local originalPairs = pairs
            pairs = function(tbl)
                if tbl ~= source then return originalPairs(tbl) end
                local index = 0
                return function()
                    index = index + 1
                    local entry = entries[index]
                    if entry then return entry[1], entry[2] end
                end
            end
            local copyOk, safe, dropped = pcall(
                BfBot.Persist._MarshalSafeCopy, source)
            pairs = originalPairs
            if not copyOk then
                return { completed = false, error = tostring(safe) }
            end

            local copied = 0
            for _ in originalPairs(safe) do copied = copied + 1 end
            return {
                completed = true,
                validBoundaries = safe[0] == "zero"
                    and safe[255] == "u8 max"
                    and safe[256] == "u16 min"
                    and safe[65535] == "u16 max"
                    and safe[65536] == "u32 min"
                    and safe[4294967295] == "u32 max"
                    and safe[4294967296] == "u64 min"
                    and safe[(2 ^ 64) - 2048] == "u64 last representable"
                    and safe[-1] == "schema minus one"
                    and safe[-128] == "i8 min"
                    and safe[-257] == "i16 near"
                    and safe[-32768] == "i16 min"
                    and safe[-65537] == "i32 near"
                    and safe[-(2 ^ 31)] == "i32 min"
                    and safe[-4294967297] == "i64 near"
                    and safe[-(2 ^ 63)] == "i64 min",
                copied = copied,
                dropped = dropped,
            }
            """
        )
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert facts["completed"], facts["error"]
    assert facts["validBoundaries"]
    assert facts["copied"] == 16
    assert facts["dropped"] == 13


def test_marshal_safe_copy_drops_unsupported_keys_without_key_collisions(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local tableKey = {}
        local functionKey = function() end
        local threadKey = coroutine.create(function() end)
        local source = { [1] = "numeric one", [true] = "boolean true", keep = "ok" }
        source[tableKey] = "table key"
        source[functionKey] = "function key"
        source[threadKey] = "thread key"
        source[python_userdata] = "userdata key"

        local safe, dropped = BfBot.Persist._MarshalSafeCopy(source)
        return {
            numericPreserved = safe[1] == "numeric one",
            booleanDropped = safe[true] == nil,
            tableDropped = safe[tableKey] == nil,
            functionDropped = safe[functionKey] == nil,
            threadDropped = safe[threadKey] == nil,
            userdataDropped = safe[python_userdata] == nil,
            ordinaryPreserved = safe.keep == "ok",
            sourceUnchanged = source[1] == "numeric one"
                and source[true] == "boolean true"
                and source[tableKey] == "table key"
                and source[functionKey] == "function key"
                and source[threadKey] == "thread key"
                and source[python_userdata] == "userdata key",
            dropped = dropped,
        }
        """
    )

    assert facts["numericPreserved"]
    assert facts["booleanDropped"]
    assert facts["tableDropped"]
    assert facts["functionDropped"]
    assert facts["threadDropped"]
    assert facts["userdataDropped"]
    assert facts["ordinaryPreserved"]
    assert facts["sourceUnchanged"]
    assert facts["dropped"] == 5


def test_marshal_safe_copy_drops_unsupported_values_and_cycles(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local fn = function() return "still live" end
        local thread = coroutine.create(function() end)
        local cycle = { keep = "inside cycle" }
        cycle.back = cycle
        local source = {
            fn = fn,
            userdata = python_userdata,
            thread = thread,
            cycle = cycle,
            keep = "safe",
        }

        local safe, dropped = BfBot.Persist._MarshalSafeCopy(source)
        return {
            functionDropped = safe.fn == nil,
            userdataDropped = safe.userdata == nil,
            threadDropped = safe.thread == nil,
            cycleLinkDropped = type(safe.cycle) == "table"
                and safe.cycle.keep == "inside cycle"
                and safe.cycle.back == nil,
            safeScalarPreserved = safe.keep == "safe",
            sourceUnchanged = source.fn == fn
                and source.userdata == python_userdata
                and source.thread == thread
                and source.cycle == cycle
                and cycle.back == cycle,
            dropped = dropped,
        }
        """
    )

    assert facts["functionDropped"]
    assert facts["userdataDropped"]
    assert facts["threadDropped"]
    assert facts["cycleLinkDropped"]
    assert facts["safeScalarPreserved"]
    assert facts["sourceUnchanged"]
    assert facts["dropped"] == 4


def test_marshal_safe_copy_copies_shared_acyclic_children_per_path(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local child = { flag = true, label = "shared" }
        local source = { left = child, right = child }
        local safe, dropped = BfBot.Persist._MarshalSafeCopy(source)
        return {
            leftCopied = safe.left ~= child
                and safe.left.flag == 1 and safe.left.label == "shared",
            rightCopied = safe.right ~= child
                and safe.right.flag == 1 and safe.right.label == "shared",
            branchesIndependent = safe.left ~= safe.right,
            sourceStillShared = source.left == child and source.right == child
                and child.flag == true and type(child.flag) == "boolean",
            dropped = dropped,
        }
        """
    )

    assert facts["leftCopied"]
    assert facts["rightCopied"]
    assert facts["branchesIndependent"]
    assert facts["sourceStillShared"]
    assert facts["dropped"] == 0


def test_marshal_safe_copy_leaves_the_deep_source_unchanged(lua: LuaRuntime) -> None:
    facts = lua.execute(
        """
        local fn = function() return 17 end
        local thread = coroutine.create(function() end)
        local shared = { yes = true, no = false }
        local source = {
            bool = true,
            nested = { value = false, text = "same", number = 42 },
            left = shared,
            right = shared,
            fn = fn,
            userdata = python_userdata,
            thread = thread,
        }
        source.self = source

        local safe = BfBot.Persist._MarshalSafeCopy(source)
        return {
            freshRoot = safe ~= source and safe.nested ~= source.nested,
            booleansUnchanged = source.bool == true
                and source.nested.value == false
                and shared.yes == true and shared.no == false,
            scalarsUnchanged = source.nested.text == "same"
                and source.nested.number == 42,
            referencesUnchanged = source.left == shared and source.right == shared
                and source.fn == fn and source.userdata == python_userdata
                and source.thread == thread and source.self == source,
        }
        """
    )

    assert facts["freshRoot"]
    assert facts["booleansUnchanged"]
    assert facts["scalarsUnchanged"]
    assert facts["referencesUnchanged"]


def test_export_returns_safe_copy_warns_once_and_preserves_live_udaux(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local warnings = {}
        BfBot._Warn = function(message) warnings[#warnings + 1] = message end
        local fn = function() return "live" end
        local live = { nested = { enabled = true }, bad = fn }
        live.self = live
        local aux = { BB = live }
        EEex = { IsMarshallingCopy = function() return false end }
        EEex_GetUDAux = function(sprite)
            assert(sprite == "sprite")
            return aux
        end

        local exported = BfBot.Persist._Export("sprite")
        return {
            fresh = type(exported.cfg) == "table" and exported.cfg ~= live
                and exported.cfg.nested ~= live.nested,
            safe = exported.cfg.nested.enabled == 1
                and exported.cfg.bad == nil and exported.cfg.self == nil,
            liveUnchanged = aux.BB == live and live.nested.enabled == true
                and type(live.nested.enabled) == "boolean"
                and live.bad == fn and live.self == live,
            warningCount = #warnings,
            warning = warnings[1],
        }
        """
    )

    assert facts["fresh"]
    assert facts["safe"]
    assert facts["liveUnchanged"]
    assert facts["warningCount"] == 1
    assert "Persist" in facts["warning"]
    assert "marshal" in facts["warning"].lower()


def test_export_keeps_temporary_marshalling_copies_empty(lua: LuaRuntime) -> None:
    facts = lua.execute(
        """
        EEex = { IsMarshallingCopy = function() return true end }
        local udauxReads = 0
        EEex_GetUDAux = function()
            udauxReads = udauxReads + 1
            return { BB = { value = 7 } }
        end
        local copyResult = BfBot.Persist._Export("sprite")
        return {
            empty = type(copyResult) == "table"
                and next(copyResult) == nil,
            udauxReads = udauxReads,
        }
        """
    )

    assert facts["empty"]
    assert facts["udauxReads"] == 0


def test_export_contains_udaux_errors_and_returns_empty(lua: LuaRuntime) -> None:
    # LuaJIT implements caught Lua errors with Windows SEH. Python's fault
    # handler otherwise prints a misleading fatal-exception stack even though
    # both Lua pcalls succeed, so suppress it only around this intentional fault.
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        facts = lua.execute(
            """
            local warnings = {}
            BfBot._Warn = function(message)
                warnings[#warnings + 1] = message
            end
            EEex = { IsMarshallingCopy = function() return false end }
            EEex_GetUDAux = function() error("synthetic UDAux failure") end
            local exportOk, exported = pcall(BfBot.Persist._Export, "sprite")

            BfBot._Warn = function() error("synthetic warning failure") end
            local warningOk, warningResult = pcall(
                BfBot.Persist._Export, "sprite")
            return {
                contained = exportOk,
                empty = type(exported) == "table" and next(exported) == nil,
                warningCount = #warnings,
                warning = warnings[1],
                warningFailureContained = warningOk
                    and type(warningResult) == "table"
                    and next(warningResult) == nil,
            }
            """
        )
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert facts["contained"]
    assert facts["empty"]
    assert facts["warningCount"] == 1
    assert "synthetic UDAux failure" in facts["warning"]
    assert facts["warningFailureContained"]
