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
