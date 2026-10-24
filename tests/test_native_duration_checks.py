"""The native recursion smoke check follows installed links and lifetimes."""

from pathlib import Path

import pytest

from test_item_child_buffs import runtime


TEST_SOURCE = (
    Path(__file__).resolve().parents[1] / "buffbot/BfBotTst.lua"
).read_text(encoding="utf-8")


def _native_duration_runtime(child_duration):
    lua = runtime()
    lua.globals().fixture_duration = child_duration
    lua.execute(
        """
        native_test_output = {}
        BfBot._Print = function(message)
            native_test_output[#native_test_output + 1] = message
        end
        header('PRAYERLEAF', {ability({effect(18, '', 0, 30)})})
        header('SPPR327', {ability({effect(146, 'PRAYERLEAF', 1, 0)})})
        header('SPPR203', {ability({effect(18, '', 0, 60)})})
        header('SPPR201', {ability({effect(18, '', 0, 12)})})
        header('MODCHILD', {ability({effect(18, '', 0, fixture_duration)})})
        header('OHTMPS2', {ability({effect(146, 'MODCHILD', 1, 0)})})
        """
    )
    lua.execute(TEST_SOURCE)
    return lua


@pytest.mark.parametrize("child_duration", [18, 30, 60, 180])
def test_native_duration_check_accepts_actual_child_name_and_lifetime(child_duration):
    lua = _native_duration_runtime(child_duration)

    assert lua.eval("BfBot.Test.DurationRecursion()")
    output = lua.eval("table.concat(native_test_output, '\\n')")
    assert f"actual child MODCHILD ({child_duration}s)" in output
    assert "FAIL:" not in output
    assert "WARN:" not in output


@pytest.mark.parametrize("broken_field", ["duration", "leaves"])
def test_native_duration_check_rejects_broken_parent_composition(broken_field):
    lua = _native_duration_runtime(30)
    lua.globals().broken_field = broken_field
    lua.execute(
        """
        local getDuration = BfBot.Class.GetDuration
        BfBot.Class.GetDuration = function(header, ability, depth, ...)
            local duration, kind, leafs = getDuration(header, ability, depth, ...)
            if header == resources.OHTMPS2 and depth == nil then
                if broken_field == 'duration' then duration = 0 else leafs = {} end
            end
            return duration, kind, leafs
        end
        """
    )

    assert not lua.eval("BfBot.Test.DurationRecursion()")
    output = lua.eval("table.concat(native_test_output, '\\n')")
    assert "FAIL: Chaos of Battle: parent" in output
