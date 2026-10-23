"""Item wrapper discovery and caster-level duration behavior on synthetic graphs."""

from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime

from test_item_abilities import _runtime as item_runtime


ROOT = Path(__file__).resolve().parents[1]


def runtime() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        bit = require('bit')
        BfBot = {
            Class = {}, _cache = {class = {}}, _overrides = {},
            _Warn = function(message) error(message) end,
            _fields = {
                fb_count='effectCount', fb_opcode='opcode', fb_param1='p1',
                fb_param2='p2', fb_target='target', fb_res='res',
                fb_timing='timing', fb_duration='duration', friendly_flags='flags',
            },
        }
        resources, loads = {}, {}
        function ability(effects, target, level)
            return {effects=effects, effectCount=#effects, actionType=target or 5,
                flags=0, minLevel=level or 1}
        end
        function header(name, abilities)
            local value = {abilities=abilities, abilityCount=#abilities, secondaryType=0}
            function value:getAbility(index) return self.abilities[index+1] end
            function value:getAbilityForLevel(level)
                local result
                for _, a in ipairs(self.abilities) do
                    if a.minLevel <= level then result = a end
                end
                return result
            end
            resources[name:upper()] = value
            return value
        end
        function effect(opcode, res, timing, duration, p1, p2)
            return {opcode=opcode, res=res, timing=timing or 0,
                duration=duration or 60, p1=p1 or 0, p2=p2 or 0}
        end
        EEex_Resource_Demand = function(name, kind)
            assert(kind == 'SPL')
            local key = name:upper()
            loads[key] = (loads[key] or 0) + 1
            return resources[key]
        end
        """
    )
    lua.execute((ROOT / 'buffbot/BfBotCls.lua').read_text(encoding='utf-8'))
    lua.execute(
        """
        BfBot.Class._GetFeatureBlock = function(_, a, index)
            return a.effects[index+1]
        end
        """
    )
    return lua


@pytest.mark.parametrize('links', [1, 2])
def test_immediate_item_wrappers_detect_buffs_without_changing_root_target(links: int):
    lua = runtime()
    lua.globals().links = links
    result = lua.execute(
        """
        header('LEAF', {ability({effect(18)})})
        header('MID', {ability({effect(146, 'LEAF')})})
        local h = header('ROOT', {ability({effect(146, links == 1 and 'LEAF' or 'MID')}, 1)})
        local item = BfBot.Class.Classify('ROOT', h, h:getAbility(0), 'itm')
        local spell = BfBot.Class.Classify('ROOT', h, h:getAbility(0), 'spl')
        return {buff=item.isBuff, substance=item.hasSubstantive,
            selfOnly=item.isSelfOnly, aoe=item.isAoE, spellBuff=spell.isBuff}
        """
    )
    assert result['buff'] and result['substance']
    assert not result['selfOnly'] and not result['aoe']
    assert not result['spellBuff']  # Spell classification intentionally stays nonrecursive.


def test_duplicate_case_aliases_do_not_inflate_score_or_import_child_state_markers():
    result = runtime().execute(
        """
        header('LEAF', {ability({effect(18), effect(328, nil, 0, 60, 0, 67)})})
        local h = header('ROOT', {ability({effect(146, 'leaf'), effect(146, 'LEAF')})})
        local score, extras = BfBot.Class._ScoreItemOpcodes(h, h:getAbility(0), 'ROOT')
        local direct = BfBot.Class.ScoreOpcodes(resources.LEAF, resources.LEAF:getAbility(0), 'LEAF')
        return {score=score, direct=direct, states=#extras.splstates, reads=loads.LEAF}
        """
    )
    assert result['score'] == result['direct']
    assert result['states'] == 0  # Child states must not become item-wide fast negatives.
    assert result['reads'] == 2  # One bounded choice walk and one scoring walk.


@pytest.mark.parametrize('problem', ['missing', 'delayed', 'deep', 'cycle', 'cross_cycle'])
def test_unresolved_item_graphs_require_manual_inclusion(problem: str):
    lua = runtime()
    lua.globals().problem = problem
    result = lua.execute(
        """
        header('LEAF', {ability({effect(18)})})
        header('B', {ability({effect(146, 'LEAF')})})
        header('A', {ability({effect(146, 'B')})})
        local effects = {effect(18), effect(146, 'LEAF')}
        if problem == 'missing' then effects[2].res = 'MISSING'
        elseif problem == 'delayed' then effects[2].timing = 4
        elseif problem == 'deep' then effects[2].res = 'A'
        elseif problem == 'cycle' then
            header('LEAF', {ability({effect(146, 'leaf')})})
        elseif problem == 'cross_cycle' then
            header('A', {ability({effect(146, 'B')})})
            header('B', {ability({effect(146, 'a')})})
            effects = {effect(18), effect(146, 'A'), effect(146, 'B')}
        end
        local h = header('ROOT', {ability(effects)})
        local automatic = BfBot.Class.Classify('ROOT', h, h:getAbility(0), 'itm')
        BfBot.Class.SetOverride('ROOT', true)
        local manual = BfBot.Class.Classify('ROOT', h, h:getAbility(0), 'itm')
        return {buff=automatic.isBuff, incomplete=automatic.analysisIncomplete,
            manual=manual.isBuff, overridden=manual.overridden}
        """
    )
    assert not result['buff'] and result['incomplete']
    assert result['manual'] and result['overridden']


def test_shortest_path_walk_is_not_sensitive_to_sibling_order():
    result = runtime().execute(
        """
        header('LEAF', {ability({effect(18)})})
        header('B', {ability({effect(146, 'LEAF')})})
        header('A', {ability({effect(146, 'B')})})
        local a = header('FIRST', {ability({effect(146, 'A'), effect(146, 'B')})})
        local b = header('SECOND', {ability({effect(146, 'B'), effect(146, 'A')})})
        local x = BfBot.Class.Classify('FIRST', a, a:getAbility(0), 'itm')
        local y = BfBot.Class.Classify('SECOND', b, b:getAbility(0), 'itm')
        return {x=x.isBuff, y=y.isBuff, sx=x.score, sy=y.score}
        """
    )
    assert result['x'] and result['y']
    assert result['sx'] == result['sy']


def test_choice_in_high_level_child_remains_manual_even_after_include_override():
    result = runtime().execute(
        """
        header('CHILD', {ability({effect(18)}, 5, 1),
            ability({effect(214, 'PICKER')}, 5, 10)})
        local h = header('ROOT', {ability({effect(146, 'CHILD')})})
        local initial = BfBot.Class.Classify('ROOT', h, h:getAbility(0), 'itm')
        BfBot.Class.SetOverride('ROOT', true)
        local included = BfBot.Class.Classify('ROOT', h, h:getAbility(0), 'itm')
        return initial.requiresSelection, included.requiresSelection
        """
    )
    assert result == (True, True)


@pytest.mark.parametrize('caster,fixed,expected', [(3, 0, 60), (12, 0, 600), (12, 2, 60), (2, 12, 600)])
def test_subspell_duration_uses_caster_or_explicit_fixed_level(caster, fixed, expected):
    lua = runtime()
    lua.globals().caster = caster
    lua.globals().fixed = fixed
    duration, _, leafs = lua.execute(
        """
        header('CHILD', {ability({effect(18, nil, 0, 60)}, 5, 1),
            ability({effect(18, nil, 0, 600)}, 5, 10)})
        local h = header('ROOT', {ability({effect(146, 'CHILD', 0, 0, fixed)})})
        return BfBot.Class.GetDuration(h, h:getAbility(0), nil, nil, nil, caster)
        """
    )
    assert duration == expected
    assert list(leafs.values()) == ['CHILD']


def test_same_child_at_different_fixed_levels_keeps_longest_duration_and_one_leaf():
    duration, _, leafs = runtime().execute(
        """
        header('CHILD', {ability({effect(18, nil, 0, 60)}, 5, 1),
            ability({effect(18, nil, 0, 600)}, 5, 10)})
        local h = header('ROOT', {ability({effect(146, 'Child', 0, 0, 2),
            effect(146, 'CHILD', 0, 0, 12)})})
        return BfBot.Class.GetDuration(h, h:getAbility(0), nil, nil, nil, 1)
        """
    )
    assert duration == 600
    assert len(leafs) == 1


def test_nested_duration_propagates_level_and_handles_case_cycle():
    duration, _, leafs = runtime().execute(
        """
        header('LEAF', {ability({effect(18, nil, 0, 60)}, 5, 1),
            ability({effect(18, nil, 0, 600), effect(146, 'mid')}, 5, 10)})
        header('MID', {ability({effect(146, 'LEAF')})})
        local h = header('ROOT', {ability({effect(146, 'MID')})})
        return BfBot.Class.GetDuration(h, h:getAbility(0), nil, nil, nil, 12)
        """
    )
    assert duration == 600
    assert list(leafs.values()) == ['MID', 'LEAF']


def test_malformed_child_does_not_call_level_resolver_or_hide_valid_sibling():
    duration, _, leafs = runtime().execute(
        """
        header('VALID', {ability({effect(18, nil, 0, 60)}, 5, 1),
            ability({effect(18, nil, 0, 600)}, 5, 10)})
        local h = header('ROOT', {ability({effect(146), effect(146, ''),
            effect(146, 'VALID')})})
        return BfBot.Class.GetDuration(h, h:getAbility(0), nil, nil, nil,
            function(child)
                assert(child == 'VALID', 'invalid resource passed to level resolver')
                return 12
            end)
        """
    )
    assert duration == 600
    assert list(leafs.values()) == ['VALID']


def test_item_scan_retains_candidates_and_exposes_selection_guard_without_spending():
    result = item_runtime().execute(
        """
        defineItem('CHOICE', 12, {{buff=false}})
        local item = placeItem(21, 'CHOICE', {3, 0, 0})
        BfBot.Class._ItemOpensChoice = function() return true end
        local entry = BfBot.Scan._BuildItemCatalog(sprite).CHOICE
        return {candidate=entry.itemCandidate, choice=entry.requiresChoice,
            buff=entry.class.isBuff, count=entry.count, stored=words[item.ptr+0x1C]}
        """
    )
    assert result['candidate'] == 1 and result['choice'] == 1
    assert not result['buff']
    assert result['count'] == result['stored'] == 3


def test_unrecognized_item_candidate_does_not_seed_default_presets():
    lua = item_runtime()
    lua.execute((ROOT / 'buffbot/BfBotLoc.lua').read_text(encoding='utf-8'))
    lua.execute((ROOT / 'buffbot/BfBotPer.lua').read_text(encoding='utf-8'))
    result = lua.execute(
        """
        BfBot.MAX_PRESETS = 8
        BfBot.Innate = {Refresh=function() end}
        EEex_Sprite_GetInPortrait = function() return sprite end
        BfBot.Persist._GetInheritedPresetStructure = function() return nil end
        local aux = {}
        EEex_GetUDAux = function() return aux end
        defineItem('MISSED', 12, {{buff=false}})
        defineItem('BUFF', 12, {{}})
        placeItem(21, 'MISSED', {1})
        placeItem(22, 'BUFF', {1})
        BfBot.Scan.GetCastableSpells = function()
            return BfBot.Scan._BuildItemCatalog(sprite), 2
        end
        local config = BfBot.Persist._CreateDefaultConfig(sprite)
        for _, preset in pairs(config.presets) do
            assert(preset.spells.MISSED == nil)
            assert(preset.spells.BUFF and preset.spells.BUFF.on == 0)
        end
        return true
        """
    )
    assert result
