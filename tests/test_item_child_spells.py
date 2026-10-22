"""Exercise the real item scanner/classifier across spell-delivery chains."""

from pathlib import Path

import pytest

from tests.test_item_abilities import _runtime


ROOT = Path(__file__).resolve().parents[1]


def _child_runtime():
    lua = _runtime()
    # Replace the existing fixture's scoring stubs with production classification.
    lua.execute((ROOT / "buffbot/BfBotCls.lua").read_text(encoding="utf-8"))
    lua.execute(
        """
        BfBot._fields = {
            fb_opcode = "effectID", fb_count = "effectCount",
            fb_start = "startingEffect", fb_timing = "durationType",
            fb_duration = "duration", fb_param1 = "effectAmount",
            fb_param2 = "dwFlags", fb_target = "targetType",
            fb_res = "res", friendly_flags = "type",
        }
        BfBot.Class._IterateFeatureBlocks = function(_, ability, fn)
            for i, effect in ipairs(ability.effects or {}) do
                if fn(effect, i - 1) then return end
            end
        end
        spells = {}
        local demandItem = EEex_Resource_Demand
        EEex_Resource_Demand = function(resref, kind)
            if kind == "SPL" then return spells[resref:upper()] end
            return demandItem(resref, kind)
        end
        function effect(opcode, resource, timing, duration, target)
            return {
                effectID = opcode, res = resource or "",
                durationType = timing or 0, duration = duration or 0,
                targetType = target or 1, effectAmount = 0, dwFlags = 0,
            }
        end
        function power(resource, index, effects)
            local ability = BfBot.Scan._GetItemAbility(headers[resource], index)
            ability.actionType, ability.type = 5, 0
            ability.effects, ability.effectCount = effects, #effects
            return ability
        end
        function spell(resource, effects)
            local ability = {
                actionType = 5, type = 0, effects = effects,
                effectCount = #effects,
            }
            local header = {
                abilityCount = 1, secondaryType = 0,
                getAbility = function(_, i) if i == 0 then return ability end end,
            }
            spells[resource:upper()] = header
            return header, ability
        end
        """
    )
    return lua


@pytest.mark.parametrize("opcode,duration,charges", [(218, 3600, 2), (16, 90, 1)])
def test_backpack_wrapper_buff_is_discovered_with_real_charges(
    opcode, duration, charges
):
    lua = _child_runtime()
    facts = lua.execute(
        f"""
        defineItem("GEAR", 4, {{ {{}} }})
        power("GEAR", 0, {{ effect(146, "CHILD", 1), effect(61) }})
        spell("CHILD", {{ effect({opcode}, "", 0, {duration}) }})
        placeItem(20, "GEAR", {{ {charges}, 0, 0 }})
        local row = assert(BfBot.Scan._BuildItemCatalog(sprite).GEAR)
        return {{ buff = row.class.isBuff, duration = row.duration,
            charges = row.count, selfOnly = row.isSelfOnly,
            slot = row.itemSlot, leaf = row.leafResrefs[1] }}
        """
    )
    assert facts["buff"]
    assert facts["duration"] == duration
    assert facts["charges"] == charges
    assert facts["selfOnly"] == 1 and facts["slot"] == 20
    assert facts["leaf"] == "CHILD"


def test_secondary_bow_power_follows_two_links_without_using_attack_or_ammo():
    facts = _child_runtime().execute(
        """
        defineItem("BOW", 15, { { type = 4, location = 1 }, {} })
        power("BOW", 1, { effect(146, "HASTE", 9) })
        spell("HASTE", { effect(324, "HASTE"), effect(146, "HASTEA", 1) })
        spell("HASTEA", { effect(16, "", 0, 90) })
        placeItem(35, "BOW", { 0, 1, 0 })
        local rows = BfBot.Scan._BuildItemCatalog(sprite)
        local row = assert(rows["itm:BOW:1"])
        return { buff = row.class.isBuff, attackAbsent = rows.BOW == nil,
            count = row.count, duration = row.duration, ability = row.abilityIdx }
        """
    )
    assert facts["buff"] and facts["attackAbsent"]
    assert facts["count"] == 1 and facts["ability"] == 1
    assert facts["duration"] == 90


@pytest.mark.parametrize("scenario", ["offensive", "missing", "cycle", "deep"])
def test_uncertain_or_offensive_powers_remain_manual_candidates(scenario):
    lua = _child_runtime()
    lua.globals().scenario = scenario
    facts = lua.execute(
        """
        defineItem("GEAR", 4, { {} })
        power("GEAR", 0, { effect(146, "A", 1) })
        if scenario == "offensive" then
            spell("A", { effect(12) })
        elseif scenario == "cycle" then
            spell("A", { effect(218), effect(146, "a", 1) })
        elseif scenario == "deep" then
            spell("A", { effect(146, "B", 1) })
            spell("B", { effect(146, "C", 1) })
            spell("C", { effect(218) })
        end
        placeItem(20, "GEAR", { 1 })
        local row = assert(BfBot.Scan._BuildItemCatalog(sprite).GEAR)
        return { buff = row.class.isBuff, candidate = row.itemCandidate }
        """
    )
    assert not facts["buff"]
    assert facts["candidate"] == 1


def test_child_evidence_keeps_item_targeting_and_power_identity_separate():
    facts = _child_runtime().execute(
        """
        defineItem("GEAR", 4, { {}, {} })
        power("GEAR", 0, { effect(146, "GOOD", 1) })
        power("GEAR", 1, { effect(146, "BAD", 1) })
        spell("GOOD", { effect(218, "", 0, 60, 6) })
        spell("BAD", { effect(12) })
        placeItem(20, "GEAR", { 2, 1 })
        local rows = BfBot.Scan._BuildItemCatalog(sprite)
        return { firstBuff = rows.GEAR.class.isBuff,
            secondBuff = rows["itm:GEAR:1"].class.isBuff,
            selfOnly = rows.GEAR.isSelfOnly, aoe = rows.GEAR.isAoE }
        """
    )
    assert facts["firstBuff"] and not facts["secondBuff"]
    assert facts["selfOnly"] == 1 and facts["aoe"] == 0


def test_repeated_child_links_do_not_multiply_positive_evidence():
    facts = _child_runtime().execute(
        """
        defineItem("GEAR", 4, { {} })
        local ability = power("GEAR", 0, {
            effect(146, "GOOD", 1), effect(146, "good", 1),
            effect(12), effect(12),
        })
        spell("GOOD", { effect(218) })
        return BfBot.Class.Classify("GEAR", headers.GEAR, ability, "itm")
        """
    )
    assert not facts["isBuff"]
    assert facts["opcodeScore"] == -4


def test_child_states_do_not_become_item_wide_skip_markers():
    facts = _child_runtime().execute(
        """
        defineItem("GEAR", 4, { {} })
        local rootMarker = effect(282)
        rootMarker.dwFlags = 11
        local ability = power("GEAR", 0, { rootMarker, effect(146, "A", 1) })
        local childMarker = effect(328)
        childMarker.dwFlags = 22
        spell("A", { effect(218), childMarker })
        local result = BfBot.Class.Classify("GEAR", headers.GEAR, ability, "itm")
        return { buff = result.isBuff, markers = table.concat(result.splstates, ",") }
        """
    )
    assert facts["buff"]
    assert facts["markers"] == "11"


def test_cross_linked_children_are_not_auto_included():
    facts = _child_runtime().execute(
        """
        defineItem("GEAR", 4, { {} })
        local ability = power("GEAR", 0, {
            effect(146, "A", 1), effect(146, "B", 1),
        })
        spell("A", { effect(218), effect(146, "B", 1) })
        spell("B", { effect(146, "A", 1) })
        return BfBot.Class.Classify("GEAR", headers.GEAR, ability, "itm")
        """
    )
    assert not facts["isBuff"] and facts["analysisIncomplete"]


@pytest.mark.parametrize("failure", ["missing", "throws", "no_ability", "delayed"])
def test_partial_buff_evidence_does_not_hide_an_unresolved_branch(failure):
    lua = _child_runtime()
    lua.globals().failure = failure
    facts = lua.execute(
        """
        defineItem("GEAR", 4, { {} })
        local ability = power("GEAR", 0, {
            effect(218), effect(146, "OTHER", failure == "delayed" and 4 or 1),
        })
        if failure == "throws" then
            EEex_Resource_Demand = function() error("unreadable child") end
        elseif failure == "no_ability" then
            spells.OTHER = { getAbility = function() return nil end }
        elseif failure == "delayed" then
            spell("OTHER", { effect(218) })
        end
        return BfBot.Class.Classify("GEAR", headers.GEAR, ability, "itm")
        """
    )
    assert not facts["isBuff"] and facts["analysisIncomplete"]


def test_shortest_path_reaches_child_without_double_scoring():
    facts = _child_runtime().execute(
        """
        defineItem("GEAR", 4, { {} })
        local ability = power("GEAR", 0, {
            effect(146, "A", 1), effect(146, "B", 1),
        })
        spell("A", { effect(146, "B", 1) })
        spell("B", { effect(146, "C", 1) })
        spell("C", { effect(218) })
        return BfBot.Class.Classify("GEAR", headers.GEAR, ability, "itm")
        """
    )
    assert facts["isBuff"] and not facts["analysisIncomplete"]
    assert facts["opcodeScore"] == 2


def test_wide_delivery_graph_is_bounded_and_can_be_explicitly_included():
    facts = _child_runtime().execute(
        """
        defineItem("GEAR", 4, { {} })
        local effects = {}
        for i = 1, 40 do
            effects[i] = effect(146, "CHILD" .. i, 1)
            spell("CHILD" .. i, { effect(218) })
        end
        local ability = power("GEAR", 0, effects)
        local automatic = BfBot.Class.Classify("GEAR", headers.GEAR, ability, "itm")
        BfBot.Class.SetOverride("GEAR", true)
        local manual = BfBot.Class.Classify("GEAR", headers.GEAR, ability, "itm")
        return { automatic = automatic.isBuff,
            incomplete = automatic.analysisIncomplete, manual = manual.isBuff }
        """
    )
    assert not facts["automatic"] and facts["incomplete"]
    assert facts["manual"]


def test_missed_power_can_be_manually_added_without_auto_seeding():
    lua = _child_runtime()
    lua.execute('BfBot.L10N = { Get = function(key) return key end }')
    lua.execute((ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8"))
    facts = lua.execute(
        """
        defineItem("GEAR", 4, { {} })
        power("GEAR", 0, { effect(146, "UNKNOWN", 1) })
        placeItem(20, "GEAR", { 1 })
        local config = { presets = { { spells = {} } }, ovr = {} }
        BfBot.Persist = { GetConfig = function() return config end }
        BfBot.L10N = { Get = function(key) return key end }
        BfBot.UI._GetSelectedSprite = function() return sprite end
        BfBot.UI._presetIdx = 1
        BfBot.UI._BuildPickerList()
        local candidate = buffbot_pickerSpells[2]
        local initiallyBuff = BfBot.Scan.GetCastableSpells(sprite).GEAR.class.isBuff
        BfBot.Persist.SetOverride = function(_, resource, value)
            assert(resource == "GEAR" and value == 1)
            config.ovr[resource] = value
            BfBot.Class.SetOverride(resource, true)
        end
        local refreshed = false
        BfBot.UI._Refresh = function() refreshed = true end
        Infinity_PopMenu = function() end
        buffbot_pickerSelected = 2
        BfBot.UI.AddPickedSpell()
        return { candidate = candidate and candidate.resref,
            initiallyBuff = initiallyBuff, refreshed = refreshed,
            included = BfBot.Scan.GetCastableSpells(sprite).GEAR.class.isBuff }
        """
    )
    assert facts["candidate"] == "GEAR" and not facts["initiallyBuff"]
    assert facts["refreshed"] and facts["included"]


def test_default_presets_only_seed_recognized_buffs_and_leave_items_disabled():
    lua = _child_runtime()
    lua.execute((ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8"))
    facts = lua.execute(
        """
        BfBot.MAX_PRESETS = 8
        local aux = {}
        EEex_GetUDAux = function() return aux end
        defineItem("GOODGEAR", 4, { {} })
        defineItem("UNKNOWN", 4, { {} })
        power("GOODGEAR", 0, { effect(146, "GOOD", 1) })
        power("UNKNOWN", 0, { effect(146, "MISSING", 1) })
        spell("GOOD", { effect(218, "", 0, 3600) })
        placeItem(20, "GOODGEAR", { 1 })
        placeItem(21, "UNKNOWN", { 1 })
        local config = BfBot.Persist._CreateDefaultConfig(sprite)
        local good, unknown, enabled = 0, 0, 0
        for _, preset in pairs(config.presets) do
            for key, entry in pairs(preset.spells) do
                if key == "GOODGEAR" then good = good + 1 end
                if key == "UNKNOWN" then unknown = unknown + 1 end
                enabled = enabled + entry.on
            end
        end
        return { good = good, unknown = unknown, enabled = enabled,
            saved = aux.BB == config }
        """
    )
    assert facts["good"] == 2 and facts["unknown"] == 0
    assert facts["enabled"] == 0 and facts["saved"]


@pytest.mark.parametrize('override',[False,True])
def test_nested_item_selection_menu_is_preserved_as_manual_only(override):
    lua=_child_runtime();lua.globals().override=override
    assert lua.execute('''
      defineItem('GEAR',0,{{}})
      power('GEAR',0,{effect(146,'CHILD',1)})
      spell('CHILD',{effect(214,'PICK',9)})
      if override then BfBot.Class.GetOverride=function()return true end end
      placeItem(20,'GEAR',{3,0,0})
      local row=BfBot.Scan._BuildItemCatalog(sprite).GEAR
      return row.requiresChoice==true and row.count==3
    ''')

@pytest.mark.parametrize('nested',[False,True])
def test_selection_menu_in_higher_level_child_header_is_manual_only(nested):
    lua=_child_runtime();lua.globals().nested=nested
    assert lua.execute('''
      defineItem('GEAR',0,{{}});power('GEAR',0,{effect(146,'CHILD',1)})
      local h,first=spell('CHILD',{effect(218,'',0,3600)})
      local second={effects={nested and effect(146,'PICKER',1)or effect(214,'PICK',9)}}
      h.abilityCount=2;h.getAbility=function(_,i)return i==0 and first or second end
      if nested then spell('PICKER',{effect(214,'PICK',9)})end
      placeItem(20,'GEAR',{3,0,0})
      return BfBot.Scan._BuildItemCatalog(sprite).GEAR.requiresChoice==true
    ''')
