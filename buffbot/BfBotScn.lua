-- ============================================================
-- BfBotScn.lua — Spell Scanner (BfBot.Scan)
-- Scans party members' spellbooks for known spells,
-- classifies them, and caches results per-sprite.
-- Primary source: EEex known spells iterators (full catalog).
-- Slot counts: GetQuickButtons overlay.
-- ============================================================

BfBot.Scan = {}

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
