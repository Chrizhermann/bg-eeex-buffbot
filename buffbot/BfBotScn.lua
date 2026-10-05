-- ============================================================
-- BfBotScn.lua — Spell Scanner (BfBot.Scan)
-- Scans party members' spellbooks for known spells,
-- classifies them, and caches results per-sprite.
-- Primary source: EEex known spells iterators (full catalog).
-- Slot counts: GetQuickButtons overlay.
-- ============================================================

BfBot.Scan = {}
BfBot.Scan._stateMarkerCache = {}
BfBot.Scan._variantCache = {}

-- Live CGameSpriteEquipment indices, also used by SLOTS.IDS action arguments.
-- 10 is the fist pseudo-item; 34 is the magical weapon slot, not backpack.
BfBot.Scan._SLOT_EQUIP_MAX = 14
BfBot.Scan._SLOT_QUICK_MIN = 15
BfBot.Scan._SLOT_QUICK_MAX = 17
BfBot.Scan._SLOT_PACK_MIN  = 18
BfBot.Scan._SLOT_PACK_MAX  = 33
BfBot.Scan._SLOT_WEAPON_MIN = 35  -- 35-38 equipped weapon slots (m_selectedWeapon
BfBot.Scan._SLOT_WEAPON_MAX = 38  --   indexes m_items directly; verified: STAF11@35)
BfBot.Scan._ITEM_COUNT_OFF = 0x1C -- CItem: count/charges u16 (no named field)
BfBot.Scan._ABIL_TARGET_OFF = 0xC -- Item_ability_st: target byte (== ability.actionType)
BfBot.Scan._CAT_POTION = 9        -- Item_Header_st.itemType
BfBot.Scan._CAT_SCROLL = 11       -- deferred by issue #21
BfBot.Scan._CAT_WAND = 35         -- deferred by issue #21

--- Get item ability i via manual pointer arithmetic.
-- Item_Header_st:getAbility(i) is BUGGED in EEex (stride uses header sizeof=114
-- instead of ability sizeof=56) — garbage for i >= 1. Verified 2026-07-03 on STAF11.
function BfBot.Scan._GetItemAbility(header, i)
    return EEex_PtrToUD(
        EEex_UDToPtr(header) + header.abilityOffset + Item_ability_st.sizeof * i,
        "Item_ability_st")
end

--- Safe strref lookup — skips invalid/dummy strrefs (0, -1, 0xFFFFFFFF, SR's 9999999).
local function _tryStrref(strref)
    if not strref or strref == 0xFFFFFFFF or strref == -1
       or strref == 0 or strref == 9999999 then
        return nil
    end
    local ok, fetched = pcall(Infinity_FetchString, strref)
    if ok and fetched and fetched ~= "" then return fetched end
    return nil
end

--- Return the ability a spell uses at the caster's current level, falling back
--- to ability 0 for hidden sub-spells / variants that are not in the spellbook.
local function _abilityForLevel(header, casterLevel)
    if not header then return nil end
    local ability = nil
    local ok = pcall(function()
        ability = header:getAbilityForLevel(casterLevel or 1)
    end)
    if ok and ability then return ability end
    local fallbackOk, fallback = pcall(function() return header:getAbility(0) end)
    return fallbackOk and fallback or nil
end

--- Resolve opcode-214 variants for the current ability. Classify() caches by
--- resref, so its variant list can belong to another caster-level ability.
--- Keep a scan-local static cache keyed by resref + caster level.
local function _variantsForLevel(resref, header, ability, casterLevel)
    local cacheKey = resref:upper() .. ":" .. tostring(casterLevel or 1)
    local cached = BfBot.Scan._variantCache[cacheKey]
    if cached ~= nil then
        return cached ~= false and cached or nil, true
    end

    local ok, variants = pcall(BfBot.Class._DetectVariants, header, ability)
    if not ok then return nil, false end
    BfBot.Scan._variantCache[cacheKey] = variants or false
    return variants, true
end

--- Collect the SPLSTATE marker IDs declared by every concrete spell resource
--- that may put effects on the target: the parent, op=146 children, and opcode
--- 214 variants. The map is transient scanner metadata, never persisted.
local function _buildStateMarkerMap(resref, header, ability, casterLevel,
                                    leafResrefs, variants)
    local markersByResref = {}
    local seen = {}

    local function add(actualResref, actualHeader, actualAbility)
        if type(actualResref) ~= "string" or actualResref == ""
            or seen[actualResref] then
            return
        end
        seen[actualResref] = true

        -- Scan.Invalidate() rebuilds slot counts before every cast. Marker
        -- definitions are static resource data, so cache them separately by
        -- resref + caster level instead of re-walking every SPL each time.
        local cacheKey = actualResref:upper() .. ":" .. tostring(casterLevel or 1)
        local cached = BfBot.Scan._stateMarkerCache[cacheKey]
        if cached then
            if #cached > 0 then markersByResref[actualResref] = cached end
            return
        end

        if not actualHeader then
            local hdrOk, demanded = pcall(EEex_Resource_Demand, actualResref, "SPL")
            if not hdrOk or not demanded then return end
            actualHeader = demanded
        end
        actualAbility = actualAbility or _abilityForLevel(actualHeader, casterLevel)
        if not actualAbility then return end

        -- ScoreOpcodes already owns the canonical opcode 282/328 extraction.
        -- Call it directly so manual classifier overrides cannot erase marker
        -- metadata needed by execution's active-buff check.
        local ok, _, extras = pcall(
            BfBot.Class.ScoreOpcodes, actualHeader, actualAbility, actualResref)
        local states = ok and extras and extras.splstates or nil
        if ok and extras then
            states = states or {}
            BfBot.Scan._stateMarkerCache[cacheKey] = states
        end
        if states and #states > 0 then
            markersByResref[actualResref] = states
        end
    end

    add(resref, header, ability)
    for _, leafResref in ipairs(leafResrefs or {}) do
        add(leafResref)
    end
    for _, variant in ipairs(variants or {}) do
        add(variant.resref)
    end

    return markersByResref
end

--- Internal: Build a catalog entry from known spells iterator data + SPL header.
local function _buildCatalogEntry(sprite, resref, header, ability, casterLevel)
    -- Name: try genericName (unidentified, 0x08) first — Spell Revisions
    -- puts the real name there and sets identifiedName (0x0C) to dummy 9999999.
    local name = _tryStrref(header.genericName)
                 or _tryStrref(header.identifiedName)
                 or resref

    -- Spell type from header
    local spellType = header.itemType or 0

    -- Icon from ability
    local icon = ""
    if ability then
        local ok, abilIcon = pcall(function()
            return ability.quickSlotIcon:get()
        end)
        if ok and abilIcon and abilIcon ~= "" then
            icon = abilIcon
        end
    end

    -- Classify
    local classResult = nil
    if header and ability then
        local ok, result = pcall(BfBot.Class.Classify, resref, header, ability)
        if ok then
            classResult = result
        else
            BfBot._Warn("Classification failed for " .. resref .. ": " .. tostring(result))
        end
    end

    -- Duration (per caster level)
    local duration = 0
    local durCat = "instant"
    local durationLeafResrefs = nil
    if header and ability then
        duration, _, durationLeafResrefs = BfBot.Class.GetDuration(header, ability)
        durCat = BfBot.Class.GetDurationCategory(duration)
    end

    -- Targeting flags (0/1 integers — no booleans in scan entries)
    local isAoE = (classResult and classResult.isAoE) and 1 or 0
    local isSelfOnly = (classResult and classResult.isSelfOnly) and 1 or 0

    -- Variant detection (0/1 integer flag + variant array)
    local variants, variantsKnown = _variantsForLevel(
        resref, header, ability, casterLevel)
    if not variantsKnown then
        variants = (classResult and classResult.variants) or nil
    end
    local hasVariants = (variants and #variants > 0) and 1 or 0

    -- Concrete effect-source resrefs used by active-buff detection. GetDuration
    -- returns an empty list for direct-effect spells, so retain the parent as
    -- the fallback in that case.
    local leafResrefs = (durationLeafResrefs and #durationLeafResrefs > 0)
        and durationLeafResrefs or { resref }
    local stateMarkersByResref = _buildStateMarkerMap(
        resref, header, ability, casterLevel, leafResrefs, variants)

    -- Structural Project Image identity (opcode 236, image type 2). Keep the
    -- transient scan shape marshal-safe and consistent with its other flags.
    local isProjectImage = (classResult and classResult.isProjectImage)
        and 1 or 0

    return {
        resref = resref,
        kind = "spl",
        name = name,
        icon = icon,
        count = 0,          -- filled in by count overlay
        level = header.spellLevel or 0,
        spellType = spellType,
        duration = duration,
        durCat = durCat,
        isAoE = isAoE,
        isSelfOnly = isSelfOnly,
        isProjectImage = isProjectImage,
        hasVariants = hasVariants,
        variants = variants,
        class = classResult,
        stateMarkersByResref = stateMarkersByResref,
        -- Invariant: catalog entries ALWAYS carry a non-empty leafResrefs.
        -- GetDuration returns an EMPTY list for direct-effect spells (the
        -- self-fallback is the caller's job) — an empty list here would make
        -- the exec pre-flight loop check nothing and never skip active buffs.
        leafResrefs = leafResrefs,
    }
end

--- Internal: Build {[resref] = count} from GetQuickButtons.
--- type 2 = wizard+priest, type 4 = innate. Also returns the same counts
--- split per button type ({[type] = {[resref] = count}}) for callers that
--- must not sum a resource listed under both buttons (5E wrappers).
local function _buildCountMap(sprite)
    local counts = {}
    local byType = { [2] = {}, [4] = {} }

    local function processButtons(btnType)
        local ok, buttonList = pcall(function()
            return sprite:GetQuickButtons(btnType, false)
        end)
        if not ok or not buttonList then return end

        local iterOk, iterErr = pcall(function()
            EEex_Utility_IterateCPtrList(buttonList, function(bd)
                local resOk, resref = pcall(function()
                    return bd.m_abilityId.m_res:get()
                end)
                if not resOk or not resref or resref == "" then return end

                local bdCount = 0
                pcall(function() bdCount = bd.m_count end)
                if bdCount <= 0 then bdCount = 1 end

                counts[resref] = (counts[resref] or 0) + bdCount
                byType[btnType][resref] = (byType[btnType][resref] or 0) + bdCount
            end)
        end)

        -- Always free the list, even if iteration errored
        pcall(EEex_Utility_FreeCPtrList, buttonList)

        if not iterOk then
            BfBot._Warn("Count map iteration failed: " .. tostring(iterErr))
        end
    end

    processButtons(2)  -- wizard + priest
    processButtons(4)  -- innate

    return counts, byType
end
BfBot.Scan._BuildCountMap = _buildCountMap

--- Internal: catalog entry for one spell resref using the caster-level
--- ability (falling back to the iterator's ability, then ability 0), or nil
--- when the SPL cannot be loaded.
local function _catalogEntryForResref(sprite, resref, iterAbility)
    local hdrOk, header = pcall(EEex_Resource_Demand, resref, "SPL")
    if not hdrOk or not header then return nil end

    local casterLevel = 1
    local clOk, cl = pcall(function()
        return sprite:getCasterLevelForSpell(resref, true)
    end)
    if clOk and cl and cl > 0 then
        casterLevel = cl
    end

    local levelAbility = header:getAbilityForLevel(casterLevel)
    local useAbility = levelAbility or iterAbility
    if not useAbility then
        useAbility = header:getAbility(0)
    end
    if not useAbility then return nil end

    return _buildCatalogEntry(sprite, resref, header, useAbility, casterLevel)
end

--- Stable preset identity. Ability zero retains existing save/export keys;
--- additional powers are independent rows, never silently substituted for it.
function BfBot.Scan._ItemKey(resref, index)
    return index == 0 and resref or ("itm:" .. resref .. ":" .. index)
end

local _itemClassMasks = {
    [1]=0x40000, [2]=0x800, [3]=0x80, [4]=0x400000, [5]=0x40,
    [6]=0x100000, [7]=0x2000, [8]=0x4000, [9]=0x20000,
    [10]=0x10000, [11]=0x40000000, [12]=0x200000, [13]=0x80000,
    [14]=0x100, [15]=0x200, [16]=0x1000, [17]=0x8000, [18]=0x400,
    [19]=0x40000, [20]=0x20000000, [21]=0x40000000,
}
local _itemRaceMasks = {
    [1]=0x08000000, [2]=0x00800000, [3]=0x02000000, [4]=0x01000000,
    [5]=0x04000000, [6]=0x10000000, [7]=0x80000000,
}

-- XEquipItem bypasses the inventory UI's eligibility checks. Cover normal
-- restrictions here; unknown custom conditional usability is not guessed.
function BfBot.Scan._CanWearItem(sprite, header)
    local ok, allowed, reason = pcall(function()
        local ptr = EEex_UDToPtr(header)
        local restrictions = EEex_ReadU32(ptr + 0x1E)
        if restrictions ~= 0 then
            local ai = sprite.m_typeAI
            local cls, race, alignment = ai.m_Class, ai.m_Race, ai.m_Alignment
            local ethic = ({ [1]=0x10, [2]=0x20, [3]=0x01 })[math.floor(alignment / 16)]
            local moral = ({ [1]=0x04, [2]=0x08, [3]=0x02 })[alignment % 16]
            if not _itemClassMasks[cls] or not _itemRaceMasks[race] or not ethic or not moral then
                return false, "unknown item usability"
            end
            if bit.band(restrictions, bit.bor(_itemClassMasks[cls],
                _itemRaceMasks[race], ethic, moral)) ~= 0 then
                return false, "item cannot be worn by this character"
            end
        end
        local kits = bit.bor(bit.lshift(EEex_ReadU8(ptr + 0x29), 24),
            bit.lshift(EEex_ReadU8(ptr + 0x2B), 16),
            bit.lshift(EEex_ReadU8(ptr + 0x2D), 8), EEex_ReadU8(ptr + 0x2F))
        if kits ~= 0 then
            local kit = sprite:getStat(152)
            local table2da = EEex_Resource_Load2DA("KITLIST")
            local idCol, maskCol = table2da:findColumnLabel("KITIDS"),
                table2da:findColumnLabel("UNUSABLE")
            local _, rows = table2da:getDimensions()
            local found = false
            for y = 0, rows - 1 do
                if tonumber(table2da:getAtPoint(idCol, y)) == kit then
                    local mask = tonumber(table2da:getAtPoint(maskCol, y))
                    if not mask or bit.band(kits, mask) ~= 0 then
                        return false, "item kit restriction"
                    end
                    found = true
                    break
                end
            end
            if not found then return false, "unknown item kit restriction" end
        end
        for _, req in ipairs({ {0x26,36,2}, {0x2A,38,1}, {0x2C,40,1},
            {0x2E,39,1}, {0x30,41,1}, {0x32,42,2} }) do
            local value = req[3] == 2 and EEex_ReadU16(ptr + req[1]) or EEex_ReadU8(ptr + req[1])
            if value > 0 and sprite:getStat(req[2]) < value then
                return false, "item minimum ability score"
            end
        end
        local strengthExtra = EEex_ReadU8(ptr + 0x28)
        if strengthExtra > 0 and sprite:getStat(36) <= 18
            and sprite:getStat(37) < strengthExtra then
            return false, "item minimum strength"
        end
        local minimumLevel = EEex_ReadU16(ptr + 0x24)
        if minimumLevel > 0 then
            local total, classes = 0, 0
            for _, stat in ipairs({34,68,69}) do
                local level = sprite:getStat(stat)
                if level > 0 then total, classes = total + level, classes + 1 end
            end
            if classes == 0 or math.ceil(total / classes) < minimumLevel then
                return false, "item minimum level"
            end
        end
        -- Equipping effects can impose mod-defined SPLPROT usability.
        local start, count = EEex_ReadU16(ptr + 0x6E), EEex_ReadU16(ptr + 0x70)
        for i = start, start + count - 1 do
            if EEex_ReadU16(ptr + header.effectsOffset + i * Item_effect_st.sizeof) == 319 then
                return false, "conditional item usability; equip manually"
            end
        end
        return true
    end)
    if not ok then return false, "item usability unavailable" end
    return allowed, reason
end

function BfBot.Scan._ItemEquipSlots(header)
    local itemType = header.itemType
    local mapped
    pcall(function()
        local tda = EEex_Resource_Load2DA("ITEMTYPE")
        mapped = tonumber(tda:getAtPoint(tda:findColumnLabel("SLOT"),
            tda:findRowLabel(tostring(itemType))))
    end)
    -- Chest armor (including robes) is never automatically exchanged.
    if mapped == 1 or itemType == 2 or (itemType >= 60 and itemType <= 68) then return {} end
    if mapped and mapped >= 0 then
        if mapped == 7 or mapped == 8 then return {7,8} end
        if mapped >= 35 and mapped <= 38 then return {35,36,37,38} end
        if mapped <= 9 then return {mapped} end
        return {}
    end
    local slots = { [1]={0}, [3]={2}, [4]={3}, [6]={5}, [7]={6},
        [10]={7,8}, [12]={9}, [32]={4} }
    if slots[itemType] then return slots[itemType] end
    if itemType >= 15 and itemType <= 30 then return {35,36,37,38} end
    return {}
end

function BfBot.Scan._PlanItemSwap(sprite, row)
    local header = EEex_Resource_Demand(row.itemResref, "ITM")
    if not header then return nil, "item unavailable" end
    local destinations = BfBot.Scan._ItemEquipSlots(header)
    if #destinations == 0 then return nil, "item must be equipped manually" end
    local allowed, reason = BfBot.Scan._CanWearItem(sprite, header)
    if not allowed then return nil, reason end
    local arr, copies = sprite.m_equipment.m_items, {}
    for i = 0, 38 do
        local item = arr:get(i)
        if item then
            local r = item.pRes.resref:get()
            copies[r] = (copies[r] or 0) + 1
        end
    end
    if copies[row.itemResref] ~= 1 then return nil, "duplicate equipment; equip the desired copy manually" end
    local source = arr:get(row.itemSlot)
    if not source or source.pRes.resref:get() ~= row.itemResref then return nil, "item moved" end
    local function movable(item, hdr)
        return bit.band(item.m_flags, 8) == 0
            and bit.band(EEex_ReadU32(EEex_UDToPtr(hdr) + 0x18), 0x10) == 0
    end
    if not movable(source, header) then return nil, "cursed or undroppable item" end
    -- Prefer a free ring/weapon slot to disturbing another piece of gear.
    table.sort(destinations, function(a,b)
        local emptyA, emptyB = arr:get(a) == nil, arr:get(b) == nil
        if emptyA ~= emptyB then return emptyA end
        return a < b
    end)
    for _, destination in ipairs(destinations) do
        local old = arr:get(destination)
        local oldResref = old and old.pRes.resref:get() or ""
        local oldHeader = old and EEex_Resource_Demand(oldResref, "ITM")
        if old and (copies[oldResref] ~= 1 or not oldHeader or not movable(old, oldHeader)) then
            goto nextDestination
        end
        -- Do not replace an off-hand while a two-handed weapon is selected,
        -- or select a two-handed backpack weapon while using an off-hand.
        if destination >= 35 and arr:get(9)
            and bit.band(EEex_ReadU32(EEex_UDToPtr(header) + 0x18), 2) ~= 0 then
            goto nextDestination
        end
        if destination == 9 then
            local selected = arr:get(sprite.m_equipment.m_selectedWeapon)
            local selectedHeader = selected and EEex_Resource_Demand(selected.pRes.resref:get(), "ITM")
            if selectedHeader and bit.band(EEex_ReadU32(EEex_UDToPtr(selectedHeader) + 0x18), 2) ~= 0 then
                goto nextDestination
            end
        end
        do return {
            item = row.itemResref, previous = oldResref,
            pack = row.itemSlot, equip = destination,
            weapon = sprite.m_equipment.m_selectedWeapon,
            weaponAbility = sprite.m_equipment.m_selectedWeaponAbility,
        } end
        ::nextDestination::
    end
    return nil, "no safe equipment slot"
end

BfBot.Scan._itemNames = {}
local function _itemAbilityName(resref, index)
    local key = resref .. ":" .. index
    if BfBot.Scan._itemNames[key] ~= nil then
        return BfBot.Scan._itemNames[key] or nil
    end
    local name
    pcall(function()
        local tda = EEex_Resource_Load2DA("TOOLTIP")
        local cols, rows = tda:getDimensions()
        if index >= cols then return end
        for y = 0, rows - 1 do
            if tda:getRowLabel(y):upper() == resref:upper() then
                name = _tryStrref(tonumber(tda:getAtPoint(index, y)))
                break
            end
        end
    end)
    BfBot.Scan._itemNames[key] = name or false
    return name
end

-- Only timed, substantive buff effects are useful evidence that THIS power
-- is active. Two powers may share an ITM source resref (e.g. invisibility and
-- haste), so matching that resref alone would make one suppress the other.
local function _itemEffectSignatures(header, ability)
    local effects = {}
    pcall(function()
        local f = BfBot._fields
        BfBot.Class._IterateFeatureBlocks(header, ability, function(fb)
            local op = fb[f.fb_opcode]
            local score = BfBot.Class._OPCODE_SCORES[op] or 0
            local timing = bit.band(fb[f.fb_timing], 0xFF)
            if score > 0 and op ~= 17 and op ~= 171
                and op ~= 318 and op ~= 324 and op ~= 282 and op ~= 328
                and (timing == 0 or timing == 3 or timing == 4 or timing == 5) then
                effects[#effects + 1] = {
                    opcode = op, amount = fb[f.fb_param1], flags = fb[f.fb_param2],
                }
            end
        end)
    end)
    return effects
end

--- Walk the character's complete carried inventory. Containers remain out of
--- scope. Every F8/quick-item power has its own identity, charges and source
--- slots; weapon attacks and passive equipped effects never become actions.
function BfBot.Scan._BuildItemCatalog(sprite)
    local items = {}

    -- Items are a party-only source in schema v10. Summon discovery and the
    -- summons view reuse GetCastableSpells(), so fail closed here before
    -- touching inventory; otherwise a copied/equipped item could make a
    -- spell-less summon look like a caster or leak into summon presets.
    local partyOk, portrait = pcall(EEex_Sprite_GetPortraitIndex, sprite)
    if not partyOk or type(portrait) ~= "number" or portrait == -1 then
        return items
    end

    local function _consider(resref, item, slot)
        if not resref or resref == "" then return end

        -- Skip BuffBot's own generated resrefs (defensive)
        if resref:sub(1, 4) == "BFBT" then return end

        local hdrOk, header = pcall(EEex_Resource_Demand, resref, "ITM")
        if not hdrOk or not header then return end
        if (header.abilityCount or 0) == 0 then return end  -- passive-only
        local itemType = header.itemType or 0
        -- Scrolls and wands remain explicitly deferred even when placed in a
        -- quickitem slot; issue #21 covers potions and equipped activatables.
        if itemType == BfBot.Scan._CAT_SCROLL
            or itemType == BfBot.Scan._CAT_WAND then
            return
        end
        for index = 0, header.abilityCount - 1 do
        local aOk, ability = pcall(BfBot.Scan._GetItemAbility, header, index)
        if not (aOk and ability) then goto nextAbility end
        local ptr = EEex_UDToPtr(ability)
        -- ITM type=magical and location=item are the actual F8 powers.
        if EEex_ReadU8(ptr) ~= 3 or EEex_ReadU8(ptr + 2) ~= 3 then
            goto nextAbility
        end
        -- target byte (== ability.actionType; raw read verified in-game)
        local target = EEex_ReadU8(ptr + BfBot.Scan._ABIL_TARGET_OFF)
        if target ~= 1 and target ~= 5 and target ~= 7 then goto nextAbility end
        local key = BfBot.Scan._ItemKey(resref, index)
        local chargeIndex = index < 3 and index or 0
        local count = EEex_ReadU16(EEex_UDToPtr(item)
            + BfBot.Scan._ITEM_COUNT_OFF + chargeIndex * 2)
        -- A zero maximum means at-will, not exhausted. Stackable potions
        -- still use their stack size, even if a mod leaves max charges zero.
        if itemType ~= BfBot.Scan._CAT_POTION and EEex_ReadU16(ptr + 0x22) == 0 then
            count = 1
        end
        if items[key] then
            items[key].count = items[key].count + count
            if count > 0 then
                table.insert(items[key].sources, { slot = slot, count = count })
            end
            goto nextAbility
        end
        local cOk, classResult = pcall(
            BfBot.Class.Classify, resref, header, ability, "itm", key)
        if not (cOk and classResult) then goto nextAbility end
        -- Keep a user-excluded buff in the transient catalog so the Add
        -- picker can recover it. Ordinary non-buffs remain out of scope.
        if not classResult.isBuff and not classResult.overridden then goto nextAbility end

        local duration, _, leafs = BfBot.Class.GetDuration(header, ability)
        -- ITM naming: identifiedName FIRST (genericName is the
        -- unidentified "Potion"/"Ring" — reverse of the SR spell rule)
        local name = _tryStrref(header.identifiedName)
                     or _tryStrref(header.genericName)
                     or resref
        if header.abilityCount > 1 then
            local abilityName = _itemAbilityName(resref, index)
            name = name .. (abilityName and (" — " .. abilityName)
                or (" [" .. (index + 1) .. "]"))
        end
        local icon = ""
        pcall(function() icon = ability.quickSlotIcon:get() end)
        items[key] = {
            resref = key,
            kind = "itm",
            itemResref = resref,
            abilityIdx = index,
            itemType = itemType,
            sources = count > 0 and { { slot = slot, count = count } } or {},
            itemEffects = _itemEffectSignatures(header, ability),
            itemMultiAbility = header.abilityCount > 1 and 1 or 0,
            name = name,
            icon = icon,
            count = count,
            level = 0,
            spellType = 0,
            duration = duration or 0,
            durCat = BfBot.Class.GetDurationCategory(duration or 0),
            isAoE = (classResult.isAoE) and 1 or 0,
            isSelfOnly = (classResult.isSelfOnly) and 1 or 0,
            isProjectImage = (classResult.isProjectImage) and 1 or 0,
            hasVariants = 0,
            variants = nil,
            class = classResult,
            leafResrefs = (leafs and #leafs > 0) and leafs or { resref },
        }
        ::nextAbility::
        end
    end

    -- Single walk over the one real inventory array. items:get(i) → CItem|nil.
    local ok = pcall(function()
        local arr = sprite.m_equipment.m_items
        for slot = 0, BfBot.Scan._SLOT_WEAPON_MAX do
            if slot == 10 or slot == 34 then goto nextItem end
            local it = arr:get(slot)
            if it then
                -- Identification belongs to this CItem instance (INVITEM.IDS
                -- bit 0), not the shared ITM header or classifier cache. Hide
                -- unknown copies before reading names or aggregating stacks.
                local flagsOk, flags = pcall(function() return it.m_flags end)
                if not flagsOk or type(flags) ~= "number" then
                    BfBot._Warn("Item identification flags unavailable in slot " .. slot)
                    goto nextItem
                end
                if bit.band(flags, 0x1) == 0 then goto nextItem end

                local resref = nil
                pcall(function() resref = it.pRes.resref:get() end)
                if resref and resref ~= "FIST" then
                    _consider(resref, it, slot)
                end
            end
            ::nextItem::
        end
    end)
    if not ok then
        BfBot._Warn("Item catalog walk failed")
    end

    for _, entry in pairs(items) do
        table.sort(entry.sources, function(a, b)
            local aPack = a.slot >= 18 and a.slot <= 33
            local bPack = b.slot >= 18 and b.slot <= 33
            if aPack ~= bPack then return not aPack end
            return a.slot < b.slot
        end)
        entry.itemSlot = entry.sources[1] and entry.sources[1].slot or nil
    end

    return items
end

--- Scan all known spells for a party member.
--- Returns a table keyed by resref and total spell count.
--- Uses known spells iterators as primary catalog, GetQuickButtons for counts.
function BfBot.Scan.GetCastableSpells(sprite)
    if not sprite then return {}, 0 end

    -- Check scan cache
    local spriteID = nil
    local ok, id = pcall(function() return sprite.m_id end)
    if ok and id then
        spriteID = id
        local cached = BfBot._cache.scan[spriteID]
        if cached then
            return cached.spells, cached.count
        end
    end

    local spells = {}
    local count = 0
    local seen = {}

    -- Phase 1: Build catalog from known spells iterators
    local iterators = {
        { fn = "EEex_Sprite_GetKnownMageSpellsWithAbilityIterator",   name = "mage" },
        { fn = "EEex_Sprite_GetKnownPriestSpellsWithAbilityIterator", name = "priest" },
        { fn = "EEex_Sprite_GetKnownInnateSpellsWithAbilityIterator", name = "innate" },
    }

    for _, iter in ipairs(iterators) do
        local iterFn = _G[iter.fn]
        if not iterFn then
            BfBot._Warn("Iterator not available: " .. iter.fn)
            goto nextIter
        end

        local iterOk, iterErr = pcall(function()
            for lvl, idx, resref, ability in iterFn(sprite) do
                if resref and resref ~= "" and not seen[resref] then
                    -- Skip BuffBot's own generated innates
                    if resref:sub(1, 4) ~= "BFBT" then
                        seen[resref] = true

                        local entry
                        if BfBot.FiveE and BfBot.FiveE.IsWrapper
                            and BfBot.FiveE.IsWrapper(resref) then
                            -- The 5E overlay replaces wrappers with player
                            -- spells. Keep their presence even at zero count,
                            -- without classifying their bookkeeping effects.
                            entry = { resref = resref, kind = "spl", count = 0 }
                        else
                            -- SPL header + caster-level ability -> catalog entry
                            entry = _catalogEntryForResref(sprite, resref, ability)
                        end
                        if entry then
                            spells[resref] = entry
                            count = count + 1
                        end
                    end
                end
            end
        end)

        if not iterOk then
            BfBot._Warn(iter.name .. " iterator failed: " .. tostring(iterErr))
        end

        ::nextIter::
    end

    -- Phase 2: Overlay slot counts from GetQuickButtons
    local countMap, countsByType = _buildCountMap(sprite)
    for resref, slotCount in pairs(countMap) do
        if spells[resref] then
            spells[resref].count = slotCount
        end
        -- Spells in countMap but NOT in known iterators are engine-internal
        -- or temporary — silently ignored (not part of the character's spellbook).
    end

    -- Phase 2b: 5E Spellcasting wrappers (no-op unless its d5zclons.2da is
    -- installed). Runs before the item merge so it only ever sees spells.
    if BfBot.FiveE and BfBot.FiveE.ApplyToCatalog then
        local fiveOk, fiveErr = pcall(BfBot.FiveE.ApplyToCatalog, sprite, spells,
            countsByType, function(resref)
                return _catalogEntryForResref(sprite, resref, nil)
            end)
        if not fiveOk then
            BfBot._Warn("5E Spellcasting overlay failed: " .. tostring(fiveErr))
            -- Never let a broken overlay turn 5E spells into native casts.
            local closedOk, closedErr = pcall(BfBot.FiveE.FailClosed, spells)
            if not closedOk then
                BfBot._Warn("5E Spellcasting fail-closed pass failed: "
                    .. tostring(closedErr))
            end
        end
        -- The overlay may have hidden or added rows, possibly before it
        -- raised: recount instead of trusting incremental bookkeeping.
        count = 0
        for _ in pairs(spells) do count = count + 1 end
    end

    -- Phase 3: Merge item catalog. Spells take precedence on resref collision
    -- (real case: staf11.SPL vs STAF11.ITM). pcall-guarded so an item-scan
    -- failure never breaks the spell scan.
    local itemsOk, itemCatalog = pcall(BfBot.Scan._BuildItemCatalog, sprite)
    if itemsOk and itemCatalog then
        for r, entry in pairs(itemCatalog) do
            if not spells[r] then
                spells[r] = entry
                count = count + 1
            end
        end
    else
        BfBot._Warn("Item catalog merge failed: " .. tostring(itemCatalog))
    end

    -- Cache results
    if spriteID then
        BfBot._cache.scan[spriteID] = {
            spells = spells,
            count = count,
        }
    end

    return spells, count
end

--- Scan all party members.
--- Returns table keyed by slot (0-5), each containing GetCastableSpells result.
function BfBot.Scan.ScanParty()
    local results = {}
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local spells, count = BfBot.Scan.GetCastableSpells(sprite)
            results[slot] = {
                sprite = sprite,
                name = sprite:getName() or ("Slot " .. slot),
                spells = spells,
                count = count,
            }
        end
    end
    return results
end

-- ============================================================
-- Allied-summon detection (issue #19)
-- Structural: alive + not-party + allied EA + has castable
-- spells, swept from the leader's current area. No hardcoded
-- creature lists — works with any mod's summons.
-- ============================================================

-- Allied-summon sweep cache TTL in wall-clock ticks (ms).
BfBot.Scan._SUMMON_CACHE_TTL = 2000

--- PURE identity-key derivation for a summon/clone — no engine calls, so it
--- is unit-testable without live summons. Identity keys the per-summon config
--- (Task 6), so they must be stable across respawns of "the same" summon.
--- desc = { kind, scriptName, creResref, ownerName, name }.
--- Fallback chain:
---   1. clone with a resolved owner -> "clone:<ownerName>" (owner name as key
---      for now; DV-else-name comes with the stale-name fix)
---   2. non-clone with a script name -> scriptname lowered. NEVER for clones:
---      PI and Simulacrum are both scriptname "COPY" (probe-verified), useless
---      as an identity — ownerless clones skip straight past this rule.
---   3. usable CRE resref -> "cre:<resref lowered>". Save-baked creatures come
---      back "*"-prefixed ("*MOEN1", probe-verified) — treated as absent.
---   4. else -> "name:<name lowered>".
function BfBot.Scan._SummonIdentity(desc)
    if type(desc) ~= "table" then return "name:?" end
    if desc.kind == "clone" and type(desc.ownerName) == "string"
            and desc.ownerName ~= "" then
        return "clone:" .. desc.ownerName
    end
    if desc.kind ~= "clone" and type(desc.scriptName) == "string"
            and desc.scriptName ~= "" then
        return desc.scriptName:lower()
    end
    if type(desc.creResref) == "string" and desc.creResref ~= ""
            and desc.creResref:sub(1, 1) ~= "*" then
        return "cre:" .. desc.creResref:lower()
    end
    return "name:" .. tostring(desc.name or "?"):lower()
end

--- Classify one sprite as an allied summon caster. Returns a summon-entry
--- table, or nil if any structural filter rejects it. Shared by the
--- GetAlliedSummons area sweep and the late-join listener (Task 11).
--- Filters, cheap-first: alive -> not-party -> allied EA 2..30 -> castable.
--- (Probe: PI clone / Simulacrum / Planetar are all EA=4 ALLY; party EA=2 is
--- excluded by the portrait filter, not by EA; neutral townsfolk are 128.)
--- Entry shape:
---   { oid = number, sprite = CGameSprite, name = string,
---     kind = "clone"|"summon", identity = string,
---     ownerName = string|nil, cloneType = number|nil }
--- cloneType is derived stat 139 PUPPETMASTERTYPE: 2=Project Image,
--- 3=Simulacrum (probe-verified), 1=Mislead (IESDP, untested).
--- NOTE: `sprite` is for immediate build-time use by the CALLER only — never
--- cache it across frames (issue-#38 freed-pointer discipline). Anything that
--- holds an entry re-resolves via oid+name (BfBot.Exec._ResolveCaster).
--- NOTE: the entry reflects allegiance AS OF classification time — EA and
--- alive-ness can change afterwards (charm, dominate, death). Consumers
--- acting on an entry later must re-validate by re-classifying the freshly
--- resolved sprite, not trust a stored entry (Task 7 queue builders rely on
--- this contract).
function BfBot.Scan.ClassifySummonSprite(sprite)
    if not sprite then return nil end

    -- 1. Alive (0xFC0 = all dead-state bits)
    local okState, state = pcall(function()
        return sprite.m_baseStats.m_generalState
    end)
    if not okState then
        BfBot._Warn("[Scan] ClassifySummonSprite: generalState read failed: "
            .. tostring(state))
        return nil
    end
    if EEex_BAnd(state, 0xFC0) ~= 0 then return nil end

    -- 2. Not a party member
    local okPor, portrait = pcall(EEex_Sprite_GetPortraitIndex, sprite)
    if not okPor then
        BfBot._Warn("[Scan] ClassifySummonSprite: GetPortraitIndex failed: "
            .. tostring(portrait))
        return nil
    end
    if portrait ~= -1 then return nil end

    -- 3. Allied EA band
    local okEa, ea = pcall(function() return sprite.m_typeAI.m_EnemyAlly end)
    if not okEa then
        BfBot._Warn("[Scan] ClassifySummonSprite: m_EnemyAlly read failed: "
            .. tostring(ea))
        return nil
    end
    if type(ea) ~= "number" or ea < 2 or ea > 30 then return nil end

    -- 4. Has castable spells (GetCastableSpells is sprite-generic; its cache
    --    is keyed by m_id, so summon scans never collide with party scans)
    local okCnt, count = pcall(function()
        return select(2, BfBot.Scan.GetCastableSpells(sprite))
    end)
    if not okCnt then
        BfBot._Warn("[Scan] ClassifySummonSprite: GetCastableSpells failed: "
            .. tostring(count))
        return nil
    end
    if type(count) ~= "number" or count <= 0 then return nil end

    -- Passed all filters — build the entry.
    local okId, oid = pcall(function() return sprite.m_id end)
    if not okId or type(oid) ~= "number" then
        BfBot._Warn("[Scan] ClassifySummonSprite: m_id read failed: "
            .. tostring(oid))
        return nil
    end
    local name = BfBot._GetName(sprite)

    -- Clone detection (probe-verified): m_bInCopy / m_nCopyParent ~= -1 mark
    -- "some clone" (scriptname "COPY" for BOTH PI and Sim — never type it by
    -- scriptname); stat 139 distinguishes PI(2) / Sim(3) / Mislead(1).
    local kind, cloneType, ownerName = "summon", nil, nil
    local okCp, copyParent = pcall(function() return sprite.m_nCopyParent end)
    if not okCp then
        BfBot._Warn("[Scan] ClassifySummonSprite: m_nCopyParent read failed: "
            .. tostring(copyParent))
        copyParent = -1  -- treat as non-clone; the entry itself is still valid
    end
    local okIc, inCopy = pcall(function() return sprite.m_bInCopy end)
    if not okIc then
        BfBot._Warn("[Scan] ClassifySummonSprite: m_bInCopy read failed: "
            .. tostring(inCopy))
        inCopy = false
    end
    local hasParent = type(copyParent) == "number" and copyParent ~= -1
    if inCopy == true or inCopy == 1 or hasParent then
        kind = "clone"
        local okCt, ct = pcall(function() return sprite:getStat(139) end)
        if okCt and type(ct) == "number" then
            cloneType = ct
        elseif not okCt then
            BfBot._Warn("[Scan] ClassifySummonSprite: getStat(139) failed: "
                .. tostring(ct))
        end
        -- Owner resolution: m_nCopyParent is the owner's object ID. Owner
        -- gone or unresolvable -> still a valid entry with ownerName = nil
        -- (identity falls through to the non-clone rules).
        if hasParent then
            local okOw, owner = pcall(function()
                local obj = EEex_GameObject_Get(copyParent)
                if obj and EEex_GameObject_IsSprite(obj, false) then
                    return EEex_GameObject_CastUserType(obj)
                end
                return nil
            end)
            if not okOw then
                BfBot._Warn("[Scan] ClassifySummonSprite: owner resolve failed"
                    .. " (id=" .. tostring(copyParent) .. "): " .. tostring(owner))
            elseif owner then
                local on = BfBot._GetName(owner)
                -- _GetName's "?" fallback would key config as "clone:?" —
                -- treat a nameless owner as unresolved instead.
                if on ~= "?" then ownerName = on end
            end
        end
    end

    -- Identity inputs (absent on read failure — the chain degrades gracefully)
    local scriptName = nil
    local okSn, sn = pcall(function() return sprite.m_scriptName:get() end)
    if okSn then
        scriptName = sn
    else
        BfBot._Warn("[Scan] ClassifySummonSprite: m_scriptName read failed: "
            .. tostring(sn))
    end
    local creResref = nil
    local okCr, cr = pcall(function() return sprite.m_resref:get() end)
    if okCr then
        creResref = cr
    else
        BfBot._Warn("[Scan] ClassifySummonSprite: m_resref read failed: "
            .. tostring(cr))
    end

    return {
        oid = oid,
        sprite = sprite,  -- build-time use only — never cache across frames
        name = name,
        kind = kind,
        identity = BfBot.Scan._SummonIdentity({
            kind = kind,
            scriptName = scriptName,
            creResref = creResref,
            ownerName = ownerName,
            name = name,
        }),
        ownerName = ownerName,
        cloneType = cloneType,
    }
end

--- All allied summon casters in the leader's current area.
--- Returns an ARRAY of summon entries (empty when none). Cached for
--- _SUMMON_CACHE_TTL ms; a cache HIT re-resolves every entry's sprite by
--- oid+name via BfBot.Exec._ResolveCaster and drops entries that no longer
--- resolve — so a returned `sprite` field is always live-this-call and the
--- cache can never hand out freed userdata (issue-#38 discipline).
--- NOTE: the returned array AND its entry tables are cache-owned — treat
--- them as READ-ONLY; copy before mutating/sorting (Task 7/10 consumers).
--- NOTE: entries reflect allegiance at sweep time — consumers acting later
--- must re-validate EA / re-classify (see ClassifySummonSprite).
function BfBot.Scan.GetAlliedSummons()
    local now = Infinity_GetClockTicks()
    local cached = BfBot._cache.summons
    if cached and cached.list and (now - cached.at) < BfBot.Scan._SUMMON_CACHE_TTL
            and BfBot.Exec and BfBot.Exec._ResolveCaster then
        local live = {}
        for _, e in ipairs(cached.list) do
            local sprite = BfBot.Exec._ResolveCaster({
                kind = "summon", oid = e.oid, name = e.name })
            if sprite then
                e.sprite = sprite
                live[#live + 1] = e
            else
                -- Gone summon: its spellbook scan is dead weight now — evict
                -- immediately instead of leaking KB-scale scan entries until
                -- the next panel-open InvalidateAll.
                BfBot._cache.scan[e.oid] = nil
            end
        end
        cached.list = live
        return live
    end

    local list = {}
    local leader = EEex_Sprite_GetInPortrait(0)
    if not leader then return list end

    local seen = {}
    local okIter, errIter = pcall(function()
        local area = leader.m_pArea
        if not area then return end
        EEex_Utility_IterateCPtrList(area.m_lVertSort, function(v)
            -- v is a PLAIN LUA NUMBER — the object ID itself, NOT a pointer
            -- (never EEex_PtrToUD it). The list may hold duplicate IDs.
            local okItem, errItem = pcall(function()
                if seen[v] then return end
                seen[v] = true
                local obj = EEex_GameObject_Get(v)
                if not obj or not EEex_GameObject_IsSprite(obj, false) then
                    return
                end
                local entry = BfBot.Scan.ClassifySummonSprite(
                    EEex_GameObject_CastUserType(obj))
                if entry then list[#list + 1] = entry end
            end)
            if not okItem then
                BfBot._Warn("[Scan] GetAlliedSummons: object " .. tostring(v)
                    .. " failed: " .. tostring(errItem))
            end
        end)
    end)
    if not okIter then
        -- Structural failure reading the area list: warn and do NOT cache,
        -- so the next call retries instead of serving a bad result for a TTL.
        BfBot._Warn("[Scan] GetAlliedSummons: area sweep failed: "
            .. tostring(errIter))
        return list
    end

    BfBot._cache.summons = { at = now, list = list }
    return list
end

--- Drop the allied-summon sweep cache (panel open, view switch, listeners).
function BfBot.Scan.InvalidateSummons()
    BfBot._cache.summons = nil
end

--- Invalidate scan cache for one sprite.
function BfBot.Scan.Invalidate(sprite)
    if not sprite then return end
    local ok, id = pcall(function() return sprite.m_id end)
    if ok and id then
        BfBot._cache.scan[id] = nil
    end
end

--- Invalidate all scan caches.
function BfBot.Scan.InvalidateAll()
    BfBot._cache.scan = {}
end
