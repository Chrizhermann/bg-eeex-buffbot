"""Item catalog behavior using engine-layout memory and independent item powers."""

from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


def _runtime() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        BfBot = {
            _cache = { class = {}, scan = {} }, _overrides = {},
            _fields = {}, Scan = {}, Class = {},
        }
        warnings, slots, headers, pointers, bytes, words = {}, {}, {}, {}, {}, {}
        metadataReads, opcodeResources = {}, {}
        BfBot._Warn = function(message) warnings[#warnings + 1] = message end
        Item_ability_st = { sizeof = 56 }
        local nextPtr = 10000
        local function allocate(value)
            value.ptr = nextPtr
            pointers[nextPtr] = value
            nextPtr = nextPtr + 10000
            return value
        end
        function defineItem(resref, itemType, definitions)
            local header = allocate({
                abilityCount = #definitions, abilityOffset = 0x72,
                itemType = itemType, identifiedName = 1, genericName = 2,
                secondaryType = 0,
            })
            headers[resref] = header
            for index, definition in ipairs(definitions) do
                local ptr = header.ptr + header.abilityOffset + (index - 1) * 56
                local ability = {
                    ptr = ptr, buff = definition.buff ~= false,
                    quickSlotIcon = { get = function() return "ICON" end },
                    effectCount = 0,
                }
                pointers[ptr] = ability
                bytes[ptr] = definition.type or 3
                bytes[ptr + 2] = definition.location or 3
                bytes[ptr + 0xC] = definition.target or 5
                words[ptr + 0x22] = definition.maxCharges == nil
                    and 1 or definition.maxCharges
            end
            return header
        end
        function placeItem(slot, resref, usage, flags)
            local item = allocate({
                m_flags = flags == nil and 1 or flags,
                pRes = { resref = { get = function() return resref end } },
            })
            for index = 0, 2 do words[item.ptr + 0x1C + index * 2] = usage[index+1] or 0 end
            slots[slot] = item
            return item
        end
        sprite = {
            m_id = 100, m_equipment = { m_items = {
                get = function(_, slot) return slots[slot] end,
            } },
            GetQuickButtons = function() return nil end,
        }
        EEex_Sprite_GetPortraitIndex = function() return 0 end
        EEex_UDToPtr = function(value) return assert(value.ptr, "missing pointer") end
        EEex_PtrToUD = function(ptr, typeName)
            assert(typeName == "Item_ability_st")
            return assert(pointers[ptr], "incorrect ability address: " .. ptr)
        end
        EEex_ReadU8 = function(address)
            return assert(bytes[address], "unexpected byte read: " .. address)
        end
        EEex_ReadU16 = function(address)
            return assert(words[address], "unexpected word read: " .. address)
        end
        EEex_Resource_Demand = function(resref, kind)
            assert(kind == "ITM")
            metadataReads[resref] = (metadataReads[resref] or 0) + 1
            return assert(headers[resref], "unknown item: " .. resref)
        end
        EEex_Resource_Load2DA = function()
            return { getDimensions = function() return 0, 0 end }
        end
        Infinity_FetchString = function(strref)
            if strref == 1 then return "Identified Item" end
            if strref == 2 then return "Unknown Item" end
            if strref == 101 then return "Invisibility" end
            if strref == 102 then return "Haste" end
            return ""
        end
        local function emptyIterator() return function() return nil end end
        EEex_Sprite_GetKnownMageSpellsWithAbilityIterator = emptyIterator
        EEex_Sprite_GetKnownPriestSpellsWithAbilityIterator = emptyIterator
        EEex_Sprite_GetKnownInnateSpellsWithAbilityIterator = emptyIterator
        """
    )
    lua.execute((ROOT / "buffbot/BfBotCls.lua").read_text(encoding="utf-8"))
    lua.execute((ROOT / "buffbot/BfBotScn.lua").read_text(encoding="utf-8"))
    lua.execute(
        """
        -- Classification verdicts still pass through the production cache and
        -- override logic. The fixture supplies opcode evidence per ability.
        BfBot.Class._IsProjectImage = function() return false end
        BfBot.Class.GetDuration = function() return 30, nil, {} end
        BfBot.Class.ScoreTargeting = function(ability)
            return ability.buff and 3 or -3, ability.buff
        end
        BfBot.Class.ScoreMSECTYPE = function() return 0 end
        BfBot.Class.ScoreOpcodes = function(_, ability, resref)
            opcodeResources[#opcodeResources + 1] = resref
            return 0, {
                splstates = {}, selfReplace = false, isToggle = false,
                hasSubstantive = ability.buff, fbAoE = false,
            }
        end
        BfBot.Class.IsAoE = function() return false end
        BfBot.Class.IsSelfOnly = function() return true end
        BfBot.Class.GetDefaultTarget = function() return "s" end
        BfBot.Class._DetectVariants = function() return nil end
        BfBot.Class._IterateFeatureBlocks = function() end
        """
    )
    return lua


def test_later_f8_power_survives_attack_headers_and_keeps_real_resource() -> None:
    facts = _runtime().execute(
        """
        defineItem("STAFF", 26, {
            { type = 1, location = 1 }, -- deliberately buff-like attack evidence
            { type = 2, location = 2 },
            { type = 3, location = 3 },
        })
        placeItem(35, "STAFF", { 0, 0, 4 })
        local catalog = BfBot.Scan._BuildItemCatalog(sprite)
        local entry = catalog["itm:STAFF:2"]
        return {
            noMelee = catalog.STAFF == nil,
            noRanged = catalog["itm:STAFF:1"] == nil,
            key = entry and entry.resref, resource = entry and entry.itemResref,
            ability = entry and entry.abilityIdx, slot = entry and entry.itemSlot,
            count = entry and entry.count, itemType = entry and entry.itemType,
            name = entry and entry.name,
            analyzed = table.concat(opcodeResources, ","), warnings = #warnings,
        }
        """
    )
    assert facts["noMelee"] and facts["noRanged"]
    assert facts["key"] == "itm:STAFF:2"
    assert facts["resource"] == "STAFF"
    assert facts["ability"] == 2 and facts["slot"] == 35
    assert facts["count"] == 4 and facts["itemType"] == 26
    assert facts["name"] == "Identified Item [3]"
    assert facts["analyzed"] == "STAFF"
    assert facts["warnings"] == 0


def test_each_power_has_its_own_remaining_charges_and_exhaustion() -> None:
    facts = _runtime().execute(
        """
        defineItem("POWERS", 12, { {}, {}, {}, {} })
        local item = placeItem(4, "POWERS", { 2, 0, 7 })
        local initial = BfBot.Scan._BuildItemCatalog(sprite)
        words[item.ptr + 0x1C] = 0
        words[item.ptr + 0x1E] = 3
        local changed = BfBot.Scan._BuildItemCatalog(sprite)
        return {
            first = initial.POWERS and initial.POWERS.count,
            exhaustedSecond = initial["itm:POWERS:1"].count == 0
                and #initial["itm:POWERS:1"].sources == 0
                and initial["itm:POWERS:1"].itemSlot == nil,
            third = initial["itm:POWERS:2"] and initial["itm:POWERS:2"].count,
            fourth = initial["itm:POWERS:3"] and initial["itm:POWERS:3"].count,
            nowExhaustedFirst = changed.POWERS.count == 0
                and #changed.POWERS.sources == 0 and changed.POWERS.itemSlot == nil,
            second = changed["itm:POWERS:1"] and changed["itm:POWERS:1"].count,
            nowExhaustedFourth = changed["itm:POWERS:3"].count == 0
                and #changed["itm:POWERS:3"].sources == 0
                and changed["itm:POWERS:3"].itemSlot == nil,
            warnings = #warnings,
        }
        """
    )
    assert facts["first"] == 2 and facts["third"] == 7
    assert facts["fourth"] == 2  # later headers use the first usage counter
    assert facts["exhaustedSecond"]
    assert facts["nowExhaustedFirst"] and facts["nowExhaustedFourth"]
    assert facts["second"] == 3
    assert facts["warnings"] == 0


@pytest.mark.parametrize("slot", range(39))
def test_equipment_actives_cover_carried_slots_excluding_pseudo_slots(slot: int) -> None:
    lua = _runtime()
    lua.globals().testSlot = slot
    facts = lua.execute(
        """
        defineItem("RING", 12, { {} })
        placeItem(testSlot, "RING", { 1 })
        local entry = BfBot.Scan._BuildItemCatalog(sprite).RING
        return {
            visible = entry ~= nil, slot = entry and entry.itemSlot,
            reads = metadataReads.RING or 0, warnings = #warnings,
        }
        """
    )
    assert facts["visible"] == (slot not in (10, 34))
    assert facts["slot"] == (slot if slot not in (10, 34) else None)
    assert facts["reads"] == (0 if slot in (10, 34) else 1)
    assert facts["warnings"] == 0


def test_slot_refresh_tracks_movement_and_prefers_equipped_duplicate() -> None:
    facts = _runtime().execute(
        """
        defineItem("MOVING", 26, { {} })
        placeItem(21, "MOVING", { 2 })
        placeItem(35, "MOVING", { 3 })
        local initial = BfBot.Scan.GetCastableSpells(sprite).MOVING
        slots[35], slots[29] = nil, slots[35]
        BfBot.Scan.Invalidate(sprite)
        local moved = BfBot.Scan.GetCastableSpells(sprite).MOVING
        return {
            initialSlot = initial.itemSlot, initialCount = initial.count,
            firstSourceSlot = initial.sources[1].slot,
            firstSourceCount = initial.sources[1].count,
            secondSourceSlot = initial.sources[2].slot,
            secondSourceCount = initial.sources[2].count,
            movedSlot = moved.itemSlot, movedCount = moved.count,
            movedSecondSource = moved.sources[2].slot, warnings = #warnings,
        }
        """
    )
    assert facts["initialSlot"] == facts["firstSourceSlot"] == 35
    assert facts["secondSourceSlot"] == 21
    assert facts["firstSourceCount"] == 3 and facts["secondSourceCount"] == 2
    assert facts["initialCount"] == facts["movedCount"] == 5
    assert facts["movedSlot"] == 21 and facts["movedSecondSource"] == 29
    assert facts["warnings"] == 0


@pytest.mark.parametrize("unknown_slot,known_slot", [(21, 35), (35, 21)])
def test_unknown_duplicate_neither_reads_metadata_nor_contributes_power_charges(
    unknown_slot: int, known_slot: int,
) -> None:
    lua = _runtime()
    lua.globals().unknownSlot = unknown_slot
    lua.globals().knownSlot = known_slot
    facts = lua.execute(
        """
        defineItem("DUPLICAT", 12, { {}, {} })
        placeItem(unknownSlot, "DUPLICAT", { 9, 8 }, 0)
        placeItem(knownSlot, "DUPLICAT", { 2, 3 }, 5)
        local catalog = BfBot.Scan._BuildItemCatalog(sprite)
        return {
            firstCount = catalog.DUPLICAT.count,
            secondCount = catalog["itm:DUPLICAT:1"].count,
            sourceCount = #catalog["itm:DUPLICAT:1"].sources,
            slot = catalog["itm:DUPLICAT:1"].itemSlot,
            reads = metadataReads.DUPLICAT, warnings = #warnings,
        }
        """
    )
    assert facts["firstCount"] == 2 and facts["secondCount"] == 3
    assert facts["sourceCount"] == 1 and facts["slot"] == known_slot
    assert facts["reads"] == 1
    assert facts["warnings"] == 0


def test_unlimited_power_remains_available_with_zero_usage_counter() -> None:
    facts = _runtime().execute(
        """
        defineItem("UNLIMIT", 12, { { maxCharges = 0 }, {} })
        placeItem(21, "UNLIMIT", { 0, 0 })
        local catalog = BfBot.Scan._BuildItemCatalog(sprite)
        return {
            count = catalog.UNLIMIT and catalog.UNLIMIT.count,
            chargedExhausted = catalog["itm:UNLIMIT:1"].count == 0
                and #catalog["itm:UNLIMIT:1"].sources == 0
                and catalog["itm:UNLIMIT:1"].itemSlot == nil,
            warnings = #warnings,
        }
        """
    )
    assert facts["count"] == 1
    assert facts["chargedExhausted"]
    assert facts["warnings"] == 0


@pytest.mark.parametrize("ability_type,location,target", [
    (1, 3, 5), (2, 3, 5), (3, 1, 5), (3, 2, 5), (3, 3, 2), (3, 3, 4),
])
def test_override_cannot_admit_non_f8_or_unsupported_target_headers(
    ability_type: int, location: int, target: int,
) -> None:
    lua = _runtime()
    lua.globals().abilityType = ability_type
    lua.globals().location = location
    lua.globals().target = target
    facts = lua.execute(
        """
        defineItem("UNSAFE", 26, {
            { type = abilityType, location = location, target = target },
        })
        placeItem(35, "UNSAFE", { 1 })
        BfBot.Class.SetOverride("UNSAFE", true)
        return { empty = next(BfBot.Scan._BuildItemCatalog(sprite)) == nil,
            classified = #opcodeResources, warnings = #warnings }
        """
    )
    assert facts["empty"] and facts["classified"] == 0
    assert facts["warnings"] == 0


def test_separate_power_classifications_overrides_and_cache_invalidation() -> None:
    facts = _runtime().execute(
        """
        defineItem("MIXED", 12, { { buff = false }, {}, { buff = false } })
        placeItem(21, "MIXED", { 1, 1, 1 })
        local initial = BfBot.Scan._BuildItemCatalog(sprite)
        BfBot.Class.SetOverride("itm:MIXED:1", false)
        BfBot.Class.SetOverride("itm:MIXED:2", true)
        local changed = BfBot.Scan._BuildItemCatalog(sprite)
        BfBot.Class.SetOverride("itm:MIXED:1", nil)
        local restored = BfBot.Scan._BuildItemCatalog(sprite)
        return {
            initialFirstAbsent = initial.MIXED == nil,
            initialSecondBuff = initial["itm:MIXED:1"].class.isBuff,
            initialThirdAbsent = initial["itm:MIXED:2"] == nil,
            excludedRetained = changed["itm:MIXED:1"] ~= nil,
            excludedBuff = changed["itm:MIXED:1"].class.isBuff,
            excludedOverride = changed["itm:MIXED:1"].class.overridden,
            thirdBuff = changed["itm:MIXED:2"].class.isBuff,
            firstStillAbsent = changed.MIXED == nil,
            secondRestored = restored["itm:MIXED:1"].class.isBuff,
            thirdStillIncluded = restored["itm:MIXED:2"].class.overridden,
            warnings = #warnings,
        }
        """
    )
    assert facts["initialFirstAbsent"] and facts["initialThirdAbsent"]
    assert facts["initialSecondBuff"]
    assert facts["excludedRetained"] and facts["excludedOverride"]
    assert not facts["excludedBuff"]
    assert facts["thirdBuff"] and facts["firstStillAbsent"]
    assert facts["secondRestored"] and facts["thirdStillIncluded"]
    assert facts["warnings"] == 0


def test_tooltip_names_distinguish_powers_without_changing_saved_identity() -> None:
    facts = _runtime().execute(
        """
        EEex_Resource_Load2DA = function(resref)
            assert(resref == "TOOLTIP")
            return {
                getDimensions = function() return 3, 1 end,
                getRowLabel = function(_, row) assert(row == 0); return "RING" end,
                getAtPoint = function(_, column, row)
                    assert(row == 0)
                    return ({ [0] = "101", [1] = "102", [2] = "-1" })[column]
                end,
            }
        end
        defineItem("RING", 12, { {}, {}, {} })
        placeItem(4, "RING", { 1, 1, 1 })
        local catalog = BfBot.Scan._BuildItemCatalog(sprite)
        return {
            firstName = catalog.RING.name, firstKey = catalog.RING.resref,
            secondName = catalog["itm:RING:1"].name,
            thirdName = catalog["itm:RING:2"].name, warnings = #warnings,
        }
        """
    )
    assert "Invisibility" in facts["firstName"]
    assert "Haste" in facts["secondName"]
    assert facts["thirdName"] == "Identified Item [3]"
    assert facts["firstKey"] == "RING"
    assert facts["warnings"] == 0
