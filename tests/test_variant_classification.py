"""Variant discovery must preserve an automatically excluded toggle verdict."""

import pytest

from test_item_child_buffs import runtime


def _selector_runtime(*, toggle: bool, reverse: bool):
    lua = runtime()
    lua.globals().fixture_toggle = toggle
    lua.globals().fixture_reverse = reverse
    lua.execute(
        """
        local function resref(value)
            return { get = function() return value end }
        end
        local rows = {
            { label = 'Enabled', res = 'CHOICEA' },
            { label = 'Disabled', res = 'CHOICEB' },
        }
        EEex_Resource_Load2DA = function(name)
            assert(name == 'CHOICES')
            return {
                getDimensions = function() return 1, #rows end,
                getAtPoint = function(_, x, y)
                    assert(x == 0)
                    return rows[y + 1].res
                end,
                getRowLabel = function(_, y) return rows[y + 1].label end,
            }
        end
        header('CHOICEA', {ability({effect(18)})})
        header('CHOICEB', {ability({effect(321)})})
        local effects = {
            effect(214, resref('CHOICES'), 9, 0),
            effect(139, resref(''), 1, 0), -- unrelated message effect
        }
        if fixture_toggle then
            effects[#effects + 1] = effect(318, resref('selector'), 0, 0)
        end
        if fixture_reverse then
            local reversed = {}
            for i = #effects, 1, -1 do reversed[#reversed + 1] = effects[i] end
            effects = reversed
        end
        selector = header('SELECTOR', {ability(effects, 7)})
        function classifySelector()
            return BfBot.Class.Classify('SELECTOR', selector, selector:getAbility(0))
        end
        """
    )
    return lua


def _assert_variants(result):
    assert result["hasVariants"]
    assert [result["variants"][i]["resref"] for i in (1, 2)] == [
        "CHOICEA", "CHOICEB"
    ]


@pytest.mark.parametrize("reverse", [False, True])
def test_toggle_with_variants_stays_excluded_but_choices_remain_available(reverse):
    lua = _selector_runtime(toggle=True, reverse=reverse)
    result = lua.eval("classifySelector()")

    assert result["isToggle"]
    assert result["score"] == -5
    assert not result["isBuff"]
    assert not result["isAmbiguous"]
    _assert_variants(result)


@pytest.mark.parametrize("reverse", [False, True])
def test_normal_buff_selector_is_still_detected(reverse):
    lua = _selector_runtime(toggle=False, reverse=reverse)
    result = lua.eval("classifySelector()")

    assert result["isBuff"]
    assert not result["isAmbiguous"]
    assert not result["isToggle"]
    _assert_variants(result)


@pytest.mark.parametrize("reverse", [False, True])
@pytest.mark.parametrize("override", [False, True])
def test_user_override_remains_authoritative_for_toggle_selector(reverse, override):
    lua = _selector_runtime(toggle=True, reverse=reverse)
    lua.eval("classifySelector()") # populate the automatic-result cache first
    lua.globals().requested_override = override
    lua.execute("BfBot.Class.SetOverride('SELECTOR', requested_override)")
    result = lua.eval("classifySelector()")

    assert result["overridden"]
    assert result["isBuff"] is override
    assert not result["isAmbiguous"]
    _assert_variants(result)
