-- ============================================================
-- BfBotScn.lua — Spell Scanner (BfBot.Scan)
-- Scans party members' spellbooks for castable spells,
-- classifies them, and caches results per-sprite.
-- ============================================================

BfBot.Scan = {}

--- Internal: Build a SpellEntry from button data and SPL header.
local function _buildSpellEntry(sprite, resref, count, icon, nameRef, disabled, header, ability)
    local name = ""
    if nameRef and nameRef ~= 0 and nameRef ~= -1 then
        name = Infinity_FetchString(nameRef)
    end
    if (not name or name == "") and header then
        local ok, fetchedName = pcall(function()
            return Infinity_FetchString(header.genericName)
        end)
        if ok and fetchedName and fetchedName ~= "" then
            name = fetchedName
        end
    end
    if not name or name == "" then
        name = resref
    end

    -- Get spell type from header
    local spellType = 0
    if header then
        spellType = header.itemType or 0
    end

    -- Get icon from ability if not from button data
    if (not icon or icon == "") and ability then
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

    -- Compute duration from ability (per caster level, not from classification cache)
    local duration = 0
    local durCat = "instant"
    if header and ability then
        duration = BfBot.Class.GetDuration(header, ability)
        durCat = BfBot.Class.GetDurationCategory(duration)
    end

    return {
        resref = resref,
        name = name,
        icon = icon or "",
        count = count or 0,
        level = header and header.spellLevel or 0,
        spellType = spellType,
        duration = duration,
        durCat = durCat,
        disabled = (disabled and disabled ~= 0) or false,
        class = classResult,
    }
end

--- Scan all castable spells for a party member.
--- Returns a table keyed by resref and total spell count.
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

    -- Helper: process a button list from GetQuickButtons
    -- metadataOnly: if true, only add entries for spells not already seen
    --               (used for disabled/exhausted spells to capture name+icon)
    local function processButtonList(buttonList, metadataOnly)
        if not buttonList then return end

        -- Wrap iteration in pcall so list is ALWAYS freed even on error
        local iterOk, iterErr = pcall(function()
            EEex_Utility_IterateCPtrList(buttonList, function(bd)
                -- Extract resref
                local resOk, resref = pcall(function()
                    return bd.m_abilityId.m_res:get()
                end)
                if not resOk or not resref or resref == "" then return end

                -- Skip BuffBot's own generated innates
                if resref:sub(1, 4) == "BFBT" then return end

                if metadataOnly then
                    -- Metadata pass: only add spells we haven't seen yet
                    if seen[resref] then return end
                    seen[resref] = true

                    local bdIcon = ""
                    pcall(function() bdIcon = bd.m_icon:get() end)

                    local bdName = 0
                    pcall(function() bdName = bd.m_name end)

                    -- Load SPL header
                    local header = EEex_Resource_Demand(resref, "SPL")
                    if not header then return end

                    local casterLevel = 1
                    local clOk, cl = pcall(function()
                        return sprite:getCasterLevelForSpell(resref, true)
                    end)
                    if clOk and cl and cl > 0 then
                        casterLevel = cl
                    end

                    local ability = header:getAbilityForLevel(casterLevel)
                    if not ability then
                        ability = header:getAbility(0)
                    end
                    if not ability then return end

                    -- Build entry with count=0 and disabled=true (exhausted spell)
                    local entry = _buildSpellEntry(
                        sprite, resref, 0, bdIcon, bdName, 1,
                        header, ability
                    )
                    spells[resref] = entry
                    count = count + 1
                    return
                end

                -- Skip duplicates (same spell from different button entries)
                if seen[resref] then
                    -- Accumulate count for duplicate entries
                    if spells[resref] then
                        local bdCount = 0
                        pcall(function() bdCount = bd.m_count end)
                        if bdCount > 0 then
                            spells[resref].count = spells[resref].count + bdCount
                        else
                            spells[resref].count = spells[resref].count + 1
                        end
                    end
                    return
                end
                seen[resref] = true

                -- Extract button data fields
                local bdCount = 0
                pcall(function() bdCount = bd.m_count end)
                if bdCount <= 0 then bdCount = 1 end -- at least 1 if it's in the list

                local bdIcon = ""
                pcall(function() bdIcon = bd.m_icon:get() end)

                local bdName = 0
                pcall(function() bdName = bd.m_name end)

                local bdDisabled = 0
                pcall(function() bdDisabled = bd.m_bDisabled end)

                -- Load SPL header
                local header = EEex_Resource_Demand(resref, "SPL")
                if not header then
                    BfBot._Warn("Cannot load SPL for " .. resref)
                    return
                end

                -- Get caster level and ability
                local casterLevel = 1
                local clOk, cl = pcall(function()
                    return sprite:getCasterLevelForSpell(resref, true)
                end)
                if clOk and cl and cl > 0 then
                    casterLevel = cl
                end

                local ability = header:getAbilityForLevel(casterLevel)
                if not ability then
                    ability = header:getAbility(0)
                end
                if not ability then
                    BfBot._Warn("No ability for " .. resref .. " at level " .. casterLevel)
                    return
                end

                -- Build entry
                local entry = _buildSpellEntry(
                    sprite, resref, bdCount, bdIcon, bdName, bdDisabled,
                    header, ability
                )
                spells[resref] = entry
                count = count + 1
            end)
        end)

        -- Always free the list, even if iteration errored
        pcall(EEex_Utility_FreeCPtrList, buttonList)

        if not iterOk then
            BfBot._Warn("Button list iteration failed: " .. tostring(iterErr))
        end
    end

    -- Get memorized wizard + priest spells (type 2)
    local spellOk, spellList = pcall(function()
        return sprite:GetQuickButtons(2, false)
    end)
    if spellOk and spellList then
        processButtonList(spellList)
    else
        BfBot._Warn("GetQuickButtons(2) failed: " .. tostring(spellList))
    end

    -- Get innate abilities (type 4)
    local innateOk, innateList = pcall(function()
        return sprite:GetQuickButtons(4, false)
    end)
    if innateOk and innateList then
        processButtonList(innateList)
    else
        BfBot._Warn("GetQuickButtons(4) failed: " .. tostring(innateList))
    end

    -- Secondary pass: scan with disabled=true to capture metadata (name, icon,
    -- classification) for exhausted spells (memorized but 0 slots remaining).
    -- Only adds entries for spells NOT already found in the castable passes above.
    local disSpellOk, disSpellList = pcall(function()
        return sprite:GetQuickButtons(2, true)
    end)
    if disSpellOk and disSpellList then
        processButtonList(disSpellList, true)
    end

    local disInnateOk, disInnateList = pcall(function()
        return sprite:GetQuickButtons(4, true)
    end)
    if disInnateOk and disInnateList then
        processButtonList(disInnateList, true)
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

--- Load display metadata (name, icon, duration) for a spell by resref.
-- Used as fallback when the spell isn't in GetQuickButtons results (exhausted slots).
function BfBot.Scan.GetSpellMetadata(resref, sprite)
    local ok, header = pcall(EEex_Resource_Demand, resref, "SPL")
    if not ok or not header then return nil end

    -- Name: try unidentified name (0x08) first — Spell Revisions puts the real name
    -- there and sets identified name (0x0C) to dummy strref 9999999.
    local name = resref
    local function tryStrref(strref)
        if not strref or strref == 0xFFFFFFFF or strref == -1 or strref == 0 or strref == 9999999 then
            return nil
        end
        local ok, fetched = pcall(Infinity_FetchString, strref)
        if ok and fetched and fetched ~= "" then return fetched end
        return nil
    end
    name = tryStrref(header.genericName) or tryStrref(header.identifiedName) or resref

    -- Get ability for caster level
    local casterLevel = 1
    if sprite then
        local clOk, cl = pcall(function()
            return sprite:getCasterLevelForSpell(resref, true)
        end)
        if clOk and cl and cl > 0 then casterLevel = cl end
    end
    local ability = header:getAbilityForLevel(casterLevel)
    if not ability then ability = header:getAbility(0) end

    -- Icon from ability
    local icon = ""
    if ability then
        local iconOk, abilIcon = pcall(function() return ability.quickSlotIcon:get() end)
        if iconOk and abilIcon and abilIcon ~= "" then icon = abilIcon end
    end

    -- Duration
    local duration = 0
    local durCat = "instant"
    if ability then
        duration = BfBot.Class.GetDuration(header, ability)
        durCat = BfBot.Class.GetDurationCategory(duration)
    end

    return {
        name = name,
        icon = icon,
        duration = duration,
        durCat = durCat,
    }
end

--- Load and classify a single spell by resref.
function BfBot.Scan.GetSpellInfo(resref, sprite)
    -- Check classification cache
    local cached = BfBot._cache.class[resref]

    local header = EEex_Resource_Demand(resref, "SPL")
    if not header then return nil end

    local casterLevel = 10 -- default
    if sprite then
        local ok, cl = pcall(function()
            return sprite:getCasterLevelForSpell(resref, true)
        end)
        if ok and cl and cl > 0 then
            casterLevel = cl
        end
    end

    local ability = header:getAbilityForLevel(casterLevel)
    if not ability then
        ability = header:getAbility(0)
    end
    if not ability then return nil end

    local classResult = BfBot.Class.Classify(resref, header, ability)

    return {
        resref = resref,
        name = Infinity_FetchString(header.genericName) or resref,
        level = header.spellLevel or 0,
        spellType = header.itemType or 0,
        class = classResult,
    }
end
