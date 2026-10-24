"""Class -> inventory scan -> execution preflight on synthetic EEex records.

These tests exercise real module boundaries. They do not simulate native cast
timing, action completion, resource consumption, or rendering.
"""

from pathlib import Path

import pytest

from test_item_abilities import _runtime as inventory_runtime


ROOT = Path(__file__).resolve().parents[1]


def runtime():
    lua = inventory_runtime()
    lua.execute("""
        bit = require('bit')
        BfBot._fields = {
            fb_count='effectCount', fb_opcode='opcode', fb_param1='p1',
            fb_param2='p2', fb_target='target', fb_res='res',
            fb_timing='timing', fb_duration='duration', friendly_flags='flags',
        }
        BfBot.MAX_PRESETS, BfBot.MAX_SPELL_REPEATS = 8, 5
        BfBot._Print = function() end
        BfBot._GetName = function(s) return s.name end
        BfBot._OpenLogAppend = function() end
        BfBot._CloseLog = function() end
        spellHeaders = {}
        local demandItem = EEex_Resource_Demand
        EEex_Resource_Demand = function(resref, kind)
            if kind == 'SPL' then return spellHeaders[resref:upper()] end
            return demandItem(resref, kind)
        end
        function effect(opcode, res, duration, p1, p2)
            return {opcode=opcode, res=res, duration=duration or 60,
                timing=0, p1=p1 or 0, p2=p2 or 0, target=1}
        end
        function ability(effects, level)
            return {effects=effects, effectCount=#effects, actionType=5,
                flags=0, minLevel=level or 1}
        end
        function spell(resref, abilities)
            local h = {abilities=abilities, abilityCount=#abilities, secondaryType=0}
            function h:getAbility(index) return self.abilities[index+1] end
            function h:getAbilityForLevel(level)
                local result
                for _, a in ipairs(self.abilities) do
                    if a.minLevel <= level then result = a end
                end
                return result
            end
            spellHeaders[resref:upper()] = h
            return h
        end
        function itemEffects(resref, index, effects, target)
            local h = headers[resref]
            local a = pointers[h.ptr + h.abilityOffset + index * 56]
            a.effects, a.effectCount, a.actionType, a.flags = effects, #effects, target or 5, 0
            return a
        end
        sprite.name, sprite.m_baseStats, sprite.m_timedEffectList = 'Caster', {m_generalState=0}, {}
        sprite.getCasterLevelForSpell = function() return casterLevel or 1 end
        sprite.getSpellState = function() return true end
        EEex_BAnd = bit.band
        EEex_Sprite_GetInPortrait = function(slot) if slot == 0 then return sprite end end
        EEex_Sprite_GetCharacterIndex = function(s) assert(s == sprite); return 0 end
        EEex_Utility_IterateCPtrList = function(list, callback)
            for _, entry in ipairs(list) do if callback(entry) then break end end
        end
        function active(source, opcode, amount, flags)
            return {m_sourceRes={get=function() return source end},
                m_effectId=opcode or 18, m_effectAmount=amount or 0,
                m_dWFlags=flags or 0}
        end
    """)
    # Replace the inventory fixture's scoring/duration stubs with the actual
    # classifier. Only pointer traversal is replaced by synthetic records.
    for module in ('BfBotCls.lua', 'BfBotLoc.lua', 'BfBotPer.lua', 'BfBotExe.lua'):
        lua.execute((ROOT / 'buffbot' / module).read_text(encoding='utf-8'))
    lua.execute("""
        BfBot.Class._GetFeatureBlock = function(_, a, index) return a.effects[index+1] end
        BfBot.Exec._state = 'running'
    """)
    return lua


@pytest.mark.parametrize('links', [1, 2])
@pytest.mark.parametrize('caster_level,fixed_level,expected_duration', [
    (3, 0, 60), (12, 0, 600), (12, 2, 60), (2, 12, 600),
])
@pytest.mark.parametrize('active_source,expected_usable', [
    ('none', True), ('lEaF', False), ('UNRELATED', True),
])
def test_nested_item_power_survives_scan_and_skip_identity(
    links, caster_level, fixed_level, expected_duration, active_source, expected_usable,
):
    lua = runtime()
    g = lua.globals()
    g.links, g.casterLevel, g.fixedLevel, g.activeSource = links, caster_level, fixed_level, active_source
    facts = lua.execute("""
        spell('LEAF', {
            ability({effect(18, nil, 60), effect(328, nil, 60, 0, 67)}, 1),
            ability({effect(18, nil, 600), effect(328, nil, 600, 0, 67)}, 10),
        })
        spell('MID', {ability({effect(146, 'LEAF', 0)})})
        defineItem('RING', 12, {{}, {}})
        itemEffects('RING', 0, {effect(146, links == 1 and 'LEAF' or 'MID', 0, fixedLevel)})
        itemEffects('RING', 1, {effect(16, nil, 120, 0, 1)})
        local packed = placeItem(21, 'RING', {1, 2})
        local worn = placeItem(4, 'RING', {2, 1})
        local catalog = BfBot.Scan.GetCastableSpells(sprite)
        local row = catalog.RING
        if activeSource ~= 'none' then
            sprite.m_timedEffectList = {active(activeSource, 328, 0, 67)}
        end
        local queue = assert(BfBot.Exec._BuildQueue({{caster=0, spell='RING', target='self'}}, 2))
        local usable = BfBot.Exec._CheckEntry(queue.p0[1], sprite)
        return {buff=row.class.isBuff, duration=row.duration, count=row.count,
            choice=row.requiresChoice, stateCount=#row.class.splstates,
            leaves=#row.leafResrefs, usable=usable, cheat=queue.p0[1].cheat,
            sourceSlot=row.itemSlot, packed=words[packed.ptr+0x1C], worn=words[worn.ptr+0x1C]}
    """)
    assert facts['buff'] and facts['choice'] == 0
    assert facts['duration'] == expected_duration
    assert facts['stateCount'] == 0  # Child markers cannot become root fast negatives.
    assert facts['leaves'] == links
    assert facts['usable'] is expected_usable
    assert facts['count'] == 3 and facts['sourceSlot'] == 4
    assert facts['packed'] == 1 and facts['worn'] == 2
    assert facts['cheat'] is False


@pytest.mark.parametrize('quick_mode', [0, 1, 2])
@pytest.mark.parametrize('accelerated', [False, True])
@pytest.mark.parametrize('second_power', ['available', 'exhausted', 'interactive'])
def test_independent_item_powers_keep_priority_repetitions_and_fresh_guards(
    quick_mode, accelerated, second_power,
):
    lua = runtime()
    g = lua.globals()
    g.quickMode, g.accelerated, g.secondPower = quick_mode, accelerated, second_power
    facts = lua.execute("""
        defineItem('POWERS', 12, {{}, {}})
        itemEffects('POWERS', 0, {effect(0, nil, 120, -2, 1)})
        itemEffects('POWERS', 1, {effect(16, nil, 120, 0, 1)})
        local item = placeItem(4, 'POWERS', {2, 3})
        BfBot.Fast = {run=accelerated and {} or nil}
        local raw = {
            {caster=0,spell='itm:POWERS:1',target='self',rep=2,cheat=1},
            {caster=0,spell='POWERS',target='self',rep=2,cheat=1},
        }
        local queue = assert(BfBot.Exec._BuildQueue(raw, quickMode)).p0
        -- The first power is active; the other power must not inherit its
        -- verdict merely because both effects originate from the same ITM.
        sprite.m_timedEffectList = {active('pOwErS', 0, -2, 1)}
        if secondPower == 'exhausted' then words[item.ptr+0x1E] = 0 end
        if secondPower == 'interactive' then
            itemEffects('POWERS', 1, {effect(214, 'CHOICE')})
            BfBot._cache.class = {}
        end
        local usable, order, native = {}, {}, true
        for i, entry in ipairs(queue) do
            usable[i] = BfBot.Exec._CheckEntry(entry, sprite)
            order[i] = entry.resref
            native = native and not entry.cheat
        end
        return {first=usable[1], repeated=usable[2], active=usable[3], activeAgain=usable[4],
            order=table.concat(order, ','), native=native,
            charges0=words[item.ptr+0x1C], charges1=words[item.ptr+0x1E],
            inputIntact=raw[1].rep==2 and raw[1].cheat==1 and #raw==2}
    """)
    assert facts['order'] == 'itm:POWERS:1,itm:POWERS:1,POWERS,POWERS'
    assert facts['native'] and facts['inputIntact']
    assert facts['first'] is (second_power == 'available')
    assert facts['repeated'] is (second_power == 'available')
    assert facts['active'] is False and facts['activeAgain'] is False
    assert facts['charges0'] == 2
    assert facts['charges1'] == (0 if second_power == 'exhausted' else 3)
