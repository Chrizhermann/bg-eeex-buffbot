-- ============================================================
-- BfBotScn.lua — Spell Scanner (BfBot.Scan)
-- Scans party members' spellbooks for known spells,
-- classifies them, and caches results per-sprite.
-- Primary source: EEex known spells iterators (full catalog).
-- Slot counts: GetQuickButtons overlay.
-- ============================================================

BfBot.Scan = {}

-- Inventory access — all verified 2026-07-03 via remote console on BG2EE.
-- See tools/items_probe_findings.md (folded into bg-modding refs in Task 18).
BfBot.Scan._SLOT_EQUIP_MAX = 17   -- 0-17 equipped body slots (10 = FIST pseudo-item)
BfBot.Scan._SLOT_QUICK_MIN = 18   -- 18-20 quickitem slots 1-3
BfBot.Scan._SLOT_QUICK_MAX = 20
BfBot.Scan._SLOT_PACK_MAX  = 36   -- 21-36 backpack
BfBot.Scan._ITEM_COUNT_OFF = 0x1C -- CItem: count/charges u16 (no named field)
BfBot.Scan._ABIL_TARGET_OFF = 0xC -- Item_ability_st: target byte (== ability.actionType)
BfBot.Scan._CAT_POTION = 9        -- Item_Header_st.itemType

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

--- Internal: Build a catalog entry from known spells iterator data + SPL header.
local function _buildCatalogEntry(sprite, resref, header, ability)
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
    if header and ability then
        duration = BfBot.Class.GetDuration(header, ability)
        durCat = BfBot.Class.GetDurationCategory(duration)
    end

    -- Targeting flags (0/1 integers — no booleans in scan entries)
    local isAoE = (classResult and classResult.isAoE) and 1 or 0
    local isSelfOnly = (classResult and classResult.isSelfOnly) and 1 or 0

    -- Variant detection (0/1 integer flag + variant array)
    local hasVariants = (classResult and classResult.hasVariants) and 1 or 0
    local variants = (classResult and classResult.variants) or nil

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
        hasVariants = hasVariants,
        variants = variants,
        class = classResult,
        -- Invariant: catalog entries ALWAYS carry a non-empty leafResrefs.
        -- GetDuration returns an EMPTY list for direct-effect spells (the
        -- self-fallback is the caller's job) — an empty list here would make
        -- the exec pre-flight loop check nothing and never skip active buffs.
        leafResrefs = (classResult and classResult.leafResrefs
                       and #classResult.leafResrefs > 0)
                      and classResult.leafResrefs or { resref },
    }
end

--- Internal: Build {[resref] = count} from GetQuickButtons.
--- type 2 = wizard+priest, type 4 = innate.
local function _buildCountMap(sprite)
    local counts = {}

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

    return counts
end

--- Walk a sprite's inventory (one array: equipped 0-17, quickitems 18-20,
-- backpack 21-36), classify item abilities, return {[resref] = entry}.
-- Slot rules: equipped/quickitem slots admit any usable category; backpack
-- admits ONLY potions (cat 9). The engine would happily UseItem an unequipped
-- ring from the backpack (verified!), so this filter is the game-balance
-- enforcement, not just cosmetics.
function BfBot.Scan._BuildItemCatalog(sprite)
    local items = {}
    local seen = {}

    local function _consider(resref, count, allowAnyCat)
        if not resref or resref == "" then return end
        if seen[resref] then return end
        if count <= 0 then return end
        seen[resref] = true

        -- Skip BuffBot's own generated resrefs (defensive)
        if resref:sub(1, 4) == "BFBT" then return end

        local hdrOk, header = pcall(EEex_Resource_Demand, resref, "ITM")
        if not hdrOk or not header then return end
        if (header.abilityCount or 0) == 0 then return end  -- passive-only
        if not allowAnyCat and (header.itemType or 0) ~= BfBot.Scan._CAT_POTION then
            return  -- backpack: potions only
        end

        for i = 0, header.abilityCount - 1 do
            local aOk, ability = pcall(BfBot.Scan._GetItemAbility, header, i)
            if aOk and ability then
                -- target byte (== ability.actionType; raw read verified in-game)
                local target = EEex_ReadU8(EEex_UDToPtr(ability) + BfBot.Scan._ABIL_TARGET_OFF)
                if target == 1 or target == 5 or target == 7 then
                    local cOk, classResult = pcall(BfBot.Class.Classify, resref, header, ability)
                    if cOk and classResult and classResult.isBuff then
                        -- First buff ability per item wins (RING39-style multi-
                        -- ability items: document limitation, revisit if it bites).
                        local duration, _, leafs = BfBot.Class.GetDuration(header, ability)
                        -- ITM naming: identifiedName FIRST (genericName is the
                        -- unidentified "Potion"/"Ring" — reverse of the SR spell rule)
                        local name = _tryStrref(header.identifiedName)
                                     or _tryStrref(header.genericName)
                                     or resref
                        local icon = ""
                        pcall(function() icon = ability.quickSlotIcon:get() end)
                        items[resref] = {
                            resref = resref,
                            kind = "itm",
                            abilityIdx = i,
                            name = name,
                            icon = icon,
                            count = count,
                            level = 0,
                            spellType = 0,
                            duration = duration or 0,
                            durCat = BfBot.Class.GetDurationCategory(duration or 0),
                            isAoE = (classResult.isAoE) and 1 or 0,
                            isSelfOnly = (classResult.isSelfOnly) and 1 or 0,
                            hasVariants = 0,
                            variants = nil,
                            class = classResult,
                            leafResrefs = (leafs and #leafs > 0) and leafs or { resref },
                        }
                        break  -- first buff ability wins
                    end
                end
            end
        end
    end

    -- Single walk over the one real inventory array. items:get(i) → CItem|nil.
    local ok = pcall(function()
        local arr = sprite.m_equipment.m_items
        for slot = 0, BfBot.Scan._SLOT_PACK_MAX do
            local it = arr:get(slot)
            if it then
                local resref = nil
                pcall(function() resref = it.pRes.resref:get() end)
                if resref and resref ~= "FIST" then
                    local count = EEex_ReadU16(EEex_UDToPtr(it) + BfBot.Scan._ITEM_COUNT_OFF)
                    -- equipped (0-17) + quickitems (18-20): any category;
                    -- backpack (21-36): potions only
                    local allowAnyCat = slot <= BfBot.Scan._SLOT_QUICK_MAX
                    _consider(resref, count, allowAnyCat)
                end
            end
        end
    end)
    if not ok then
        BfBot._Warn("Item catalog walk failed")
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

                        -- Load SPL header for classification + metadata
                        local hdrOk, header = pcall(EEex_Resource_Demand, resref, "SPL")
                        if hdrOk and header then
                            -- Use caster-level-appropriate ability if available
                            local casterLevel = 1
                            local clOk, cl = pcall(function()
                                return sprite:getCasterLevelForSpell(resref, true)
                            end)
                            if clOk and cl and cl > 0 then
                                casterLevel = cl
                            end

                            local levelAbility = header:getAbilityForLevel(casterLevel)
                            -- Fall back to iterator-provided ability, then ability index 0
                            local useAbility = levelAbility or ability
                            if not useAbility then
                                useAbility = header:getAbility(0)
                            end

                            if useAbility then
                                local entry = _buildCatalogEntry(sprite, resref, header, useAbility)
                                spells[resref] = entry
                                count = count + 1
                            end
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
    local countMap = _buildCountMap(sprite)
    for resref, slotCount in pairs(countMap) do
        if spells[resref] then
            spells[resref].count = slotCount
        end
        -- Spells in countMap but NOT in known iterators are engine-internal
        -- or temporary — silently ignored (not part of the character's spellbook).
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
