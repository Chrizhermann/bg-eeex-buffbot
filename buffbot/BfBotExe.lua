-- ============================================================
-- BfBotExe.lua — Execution Engine (BfBot.Exec)
-- Parallel per-caster buff casting with EEex_LuaAction chaining
-- ============================================================

BfBot.Exec = {}

-- State
BfBot.Exec._state = "idle"       -- "idle" | "running" | "done" | "stopped"
BfBot.Exec._casters = {}         -- {[casterKey] = {ref=..., queue={}, index=0, done=false, name=n, cheatBoundary=0, cheatApplied=false}}
                                 -- Keyed by _CasterKey(ref) ("p<slot>" / "s<oid>"). Records hold NO
                                 -- sprite userdata — every step resolves fresh via _ResolveCaster (#19/#38).
BfBot.Exec._activeCasters = 0    -- casters still processing (0 = all done)
BfBot.Exec._log = {}             -- log entries: {type=str, msg=str}
BfBot.Exec._castCount = 0        -- casts issued across all casters
BfBot.Exec._skipCount = 0        -- entries skipped across all casters
BfBot.Exec._totalEntries = 0     -- total entries across all casters
BfBot.Exec._logFile = "buffbot_exec.log"
BfBot.Exec._qcMode = 0              -- quick cast mode (0=off, 1=long, 2=all)
BfBot.Exec._lastSafetyTick = 0  -- clock ticks of last safety check
BfBot.Exec._lastProgressGameTime = nil  -- game-time of last forward progress (watchdog; nil until armed)
BfBot.Exec._runPresetIdx = nil   -- preset driving the current run (late-join summon lookups, issue #19);
                                 -- nil for raw/console-built queues → late-join inert for that run
BfBot.Exec._pendingLateJoin = {} -- [oid] = retries left; sprites recorded by the loaded listener,
                                 -- classified/attached by _ProcessLateJoins once the engine finished
                                 -- initializing them (see _OnSpriteLoaded for the probe rationale)
-- Retry budget for a pending late-join oid: probe-verified that a freshly
-- conjured clone's name/EA/puppet fields are NOT set yet when the loaded
-- listener fires; they are set moments later. 5 tries at the _SafetyTick's
-- ~2s cadence = a ~10s readiness window — far shorter than any summon's
-- lifetime, far longer than the engine needs.
BfBot.Exec._LATEJOIN_MAX_TRIES = 5
-- Watchdog timeout in GAME-TIME ticks (m_gameTime), NOT wall-clock. Game time
-- freezes while the game is paused, so a paused-but-healthy buff run is never
-- force-killed. ~450 ticks ≈ 30s at the engine's default rate (~15 game-ticks/s);
-- this is a safety-net threshold, so the exact real-time it maps to is non-critical.
BfBot.Exec._WATCHDOG_TIMEOUT_GAMETICKS = 450

--- Caster reference <-> canonical string key ("p<slot>" party, "s<objectID>" summon).
function BfBot.Exec._CasterKey(ref)
    if ref.kind == "party" then return "p" .. ref.slot end
    return "s" .. ref.oid
end

--- Parse a canonical caster key back into a ref table, or nil if malformed.
--- NOTE: keys carry no `name`, so a ref rebuilt here lacks the summon
--- anti-recycle name guard — treat keys as map keys only; always resolve
--- from stored full refs, never from re-parsed keys.
function BfBot.Exec._ParseCasterKey(key)
    if type(key) ~= "string" then return nil end
    local slot = key:match("^p(%d)$")
    if slot then return { kind = "party", slot = tonumber(slot) } end
    local oid = key:match("^s(%d+)$")
    if oid then return { kind = "summon", oid = tonumber(oid) } end
    return nil
end

--- Summon-branch body for _ResolveCaster, pcall-wrapped there. Split out so
--- structural failures (API drift, typo'd field) surface as pcall errors
--- instead of being silently swallowed into "caster gone" nils.
local function _resolveSummon(ref)
    local obj = EEex_GameObject_Get(ref.oid)
    if not obj or not EEex_GameObject_IsSprite(obj, false) then return nil end
    local s = EEex_GameObject_CastUserType(obj)
    if ref.name and BfBot._GetName(s) ~= ref.name then return nil end
    return s
end

--- Resolve a caster ref to a LIVE sprite or nil. Never returns cached userdata.
--- Party: portrait re-resolution (issue-#38 discipline). Summon: object-ID lookup
--- + type/name sanity so a recycled ID never masquerades as our caster.
--- A dead/recycled oid resolves nil silently (normal churn); a structural error
--- in the lookup chain is logged via _Warn so a broken resolver can't nil every
--- summon forever behind green tests.
function BfBot.Exec._ResolveCaster(ref)
    if not ref then return nil end
    if ref.kind == "party" then
        return EEex_Sprite_GetInPortrait(ref.slot)
    end
    local ok, res = pcall(_resolveSummon, ref)
    if not ok then
        BfBot._Warn("[Exec] _ResolveCaster(s" .. tostring(ref.oid) .. ") failed: " .. tostring(res))
        return nil
    end
    return res
end

--- Allied EA-band predicate (probe-verified values: party PC = 2, allied
--- summons/clones/Planetar = 4, neutral townsfolk = 128). Same 2..30 band
--- BfBot.Scan.ClassifySummonSprite filters on. Pure — unit-testable.
function BfBot.Exec._IsAlliedEA(ea)
    return type(ea) == "number" and ea >= 2 and ea <= 30
end

--- Re-read a summon caster's allegiance off a freshly-resolved sprite.
--- Allegiance can flip mid-run (charm, dominate) — a summon outside the
--- allied band must be treated as gone, not receive buffs. A read failure
--- counts as gone too: never keep casting through an unverifiable caster.
function BfBot.Exec._SummonStillAllied(sprite)
    local ok, ea = pcall(function() return sprite.m_typeAI.m_EnemyAlly end)
    if not ok then
        BfBot._Warn("[Exec] EA re-read failed: " .. tostring(ea))
        return false
    end
    return BfBot.Exec._IsAlliedEA(ea)
end

--- Resolve a caster record to a live, still-valid sprite for an exec step,
--- or nil when the caster should be treated as gone. Shared by
--- _ProcessCasterEntry, _Advance and the _SafetyTick gone-summon sweep so
--- all three apply identical rules:
---   party:  portrait re-resolve + cached-name guard — a mid-run portrait
---           reshuffle must never route a cast through the wrong character
---           (a rename mid-run also ends the chain early — benign; the
---           stale tick still whole-run-resets).
---   summon: oid+name re-resolve (anti-recycle guard in _ResolveCaster)
---           + EA-band re-read — a summon turning hostile mid-run ends its
---           chain instead of receiving buffs (issue #19).
function BfBot.Exec._ResolveCasterForStep(caster)
    local sprite = BfBot.Exec._ResolveCaster(caster.ref)
    if not sprite then return nil end
    if caster.ref.kind == "party" then
        if caster.name and BfBot._GetName(sprite) ~= caster.name then
            return nil
        end
    else
        if not BfBot.Exec._SummonStillAllied(sprite) then
            BfBot.Exec._LogEntry("INFO",
                tostring(caster.name) .. " no longer allied — treating as gone")
            return nil
        end
    end
    return sprite
end

--- Log an execution event.
function BfBot.Exec._LogEntry(type, msg)
    table.insert(BfBot.Exec._log, { type = type, msg = msg })
    BfBot._Print("[BuffBot] " .. type .. ": " .. msg)
end

--- Current engine game-time in ticks, or nil if unavailable. Game time freezes
--- while the game is paused, so measuring watchdog progress against it (instead
--- of wall-clock Infinity_GetClockTicks) means a paused run is never mistaken for
--- a wedged one. pcall-guarded raw reflection.
function BfBot.Exec._GetGameTime()
    local chitin = rawget(_G, "EEex_EngineGlobal_CBaldurChitin")
        or (rawget(_G, "EngineGlobals") and EngineGlobals.g_pBaldurChitin)
    if not chitin then return nil end
    local ok, gt = pcall(function() return chitin.m_pObjectGame.m_worldTime.m_gameTime end)
    if ok and type(gt) == "number" then return gt end
    return nil
end

--- Mark forward progress for the watchdog. Called whenever a cast is queued or a
--- caster advances, so a healthy (even slow) run never trips the stuck-caster
--- timeout. Records GAME time (frozen on pause). See _SafetyTick for the watchdog.
function BfBot.Exec._NoteProgress()
    BfBot.Exec._lastProgressGameTime = BfBot.Exec._GetGameTime()
end

--- Check if a sprite is alive (not dead/petrified/etc).
function BfBot.Exec._IsAlive(sprite)
    if not sprite then return false end
    local ok, state = pcall(function()
        return sprite.m_baseStats.m_generalState
    end)
    if not ok then return false end
    return EEex_BAnd(state, 0xFC0) == 0
end

--- Check if a sprite has an active timed effect from a given spell resref.
function BfBot.Exec._HasActiveEffect(sprite, resref)
    if not sprite or not resref then return false end
    local found = false
    local ok = pcall(function()
        EEex_Utility_IterateCPtrList(sprite.m_timedEffectList, function(effect)
            local effectRes = effect.m_sourceRes:get()
            if effectRes and effectRes == resref then
                found = true
                return true -- stop iteration
            end
        end)
    end)
    return ok and found
end

--- Programmatically consume one spell slot for a given spell resref.
--- Sets m_flags = 0 on the first available memorized entry matching the resref.
--- Used by the variant spell path to consume the parent spell slot before
--- casting the variant directly via ReallyForceSpellRES.
--- @param sprite userdata: the casting sprite
--- @param resref string: the parent spell resref to consume
--- @return boolean: true if slot consumed, false if no available slot found
function BfBot.Exec._ConsumeSpellSlot(sprite, resref)
    if not sprite or not resref then return false end

    -- Determine spell list field from resref prefix
    local prefix = resref:sub(1, 4):upper()
    local listField
    if prefix == "SPWI" then
        listField = "m_memorizedSpellsMage"
    elseif prefix == "SPPR" then
        listField = "m_memorizedSpellsPriest"
    else
        listField = "m_memorizedSpellsInnate"
    end

    -- Get spell level from SPL header (1-based in header → 0-based index for array)
    local levelIndex = 0
    local hdrOk, header = pcall(EEex_Resource_Demand, resref, "SPL")
    if hdrOk and header then
        levelIndex = (header.spellLevel or 1) - 1
    end
    -- Innates are all at index 0
    if listField == "m_memorizedSpellsInnate" then levelIndex = 0 end

    -- Find and consume the first available slot
    local consumed = false
    local ok = pcall(function()
        local memList = sprite[listField]
        if not memList then return end
        local levelList = memList:getReference(levelIndex)
        if not levelList then return end
        EEex_Utility_IterateCPtrList(levelList, function(spell)
            if consumed then return true end
            local sid = spell.m_spellId:get()
            if sid == resref and spell.m_flags == 1 then
                spell.m_flags = 0
                consumed = true
                return true
            end
        end)
    end)

    return ok and consumed
end

--- Check if hostiles are within combat range of the party leader.
-- Uses the same range (400) and hostility threshold ([ENEMY] = EA >= 200)
-- as the engine's rest prevention check.
-- @return boolean true if enemies detected nearby
function BfBot.Exec._DetectCombat()
    -- Respect INI preference
    if BfBot.Persist.GetPref("CombatInterrupt") ~= 1 then
        return false
    end
    local leader = EEex_Sprite_GetInPortrait(0)
    if not leader then return false end
    local ok, count = pcall(function()
        return leader:countAllOfTypeStringInRange("[ENEMY]", 400)
    end)
    return ok and count and count > 0
end

--- Resolve a user-specified target into expanded queue entries.
function BfBot.Exec._ResolveTargets(target, casterSprite, casterSlot, isAoE)
    local results = {}

    if target == "self" then
        table.insert(results, {
            targetObj = "Myself",
            targetSlot = casterSlot,
            targetSprite = casterSprite,
            targetName = BfBot._GetName(casterSprite),
        })
    elseif type(target) == "number" and target >= 1 and target <= 6 then
        local slot = target - 1
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite and BfBot.Exec._IsAlive(sprite) then
            -- PlayerN uses join order (m_characters), not portrait order.
            -- Map via EEex_Sprite_GetCharacterIndex to get the correct PlayerN.
            local charIdx = EEex_Sprite_GetCharacterIndex(sprite)
            table.insert(results, {
                targetObj = "Player" .. (charIdx + 1),
                targetSlot = slot,
                targetSprite = sprite,
                targetName = BfBot._GetName(sprite),
            })
        end
    elseif target == "all" then
        if isAoE then
            table.insert(results, {
                targetObj = "Myself",
                targetSlot = casterSlot,
                targetSprite = casterSprite,
                targetName = "party (AoE)",
            })
        else
            for i = 0, 5 do
                local sprite = EEex_Sprite_GetInPortrait(i)
                if sprite and BfBot.Exec._IsAlive(sprite) then
                    local charIdx = EEex_Sprite_GetCharacterIndex(sprite)
                    table.insert(results, {
                        targetObj = "Player" .. (charIdx + 1),
                        targetSlot = i,
                        targetSprite = sprite,
                        targetName = BfBot._GetName(sprite),
                    })
                end
            end
        end
    end

    return results
end

--- Build per-caster execution queues from user input.
-- userQueue: array of {caster=0-5, spell="RESREF", target="self"|"all"|1-6}.
-- Entries may alternatively carry a pre-built caster ref instead of a slot:
-- {casterRef={kind="party",slot=N} | {kind="summon",oid=N,name=S}, ...} —
-- the seam the summon queue builders use (issue #19).
-- Returns: {[casterKey] = {entries}} grouped by _CasterKey, or nil + error
function BfBot.Exec._BuildQueue(userQueue, qcMode)
    if not userQueue or #userQueue == 0 then
        return nil, "empty queue"
    end

    local byCaster = {}
    local totalEntries = 0
    local controlCache = {}  -- casterKey -> boolean; MP control is invariant per build

    for i, entry in ipairs(userQueue) do
        -- Resolve the caster reference: either supplied directly (summon
        -- seam) or built from the legacy party-slot field.
        local casterRef = entry.casterRef
        if casterRef ~= nil then
            -- Accept any ref that produces a well-formed caster key. Party
            -- refs must additionally satisfy the same 0-5 slot constraint as
            -- the legacy slot path (the party resolver is not pcall-guarded).
            -- Summon refs must carry a name: it is the resolver's anti-recycle
            -- guard — a name-less ref would resolve ANY sprite occupying a
            -- recycled object ID.
            local okKey, key = pcall(BfBot.Exec._CasterKey, casterRef)
            if not okKey or BfBot.Exec._ParseCasterKey(key) == nil
                or (casterRef.kind == "party"
                    and not (type(casterRef.slot) == "number"
                        and casterRef.slot >= 0 and casterRef.slot <= 5))
                or (casterRef.kind == "summon"
                    and type(casterRef.name) ~= "string") then
                BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": malformed casterRef")
                goto continue
            end
        else
            local casterSlot = entry.caster
            if type(casterSlot) ~= "number" or casterSlot < 0 or casterSlot > 5 then
                BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": invalid caster slot " .. tostring(casterSlot))
                goto continue
            end
            casterRef = { kind = "party", slot = casterSlot }
        end

        local casterKey = BfBot.Exec._CasterKey(casterRef)

        -- Build-time resolution for the scan/spell checks below. Exec-time
        -- code re-resolves fresh each step — never through this userdata.
        -- An unresolvable SUMMON is normal churn (expired/killed between
        -- sweep and build) → SKIP; an empty party slot is a caller bug → ERROR.
        local casterSprite = BfBot.Exec._ResolveCaster(casterRef)
        if not casterSprite then
            if casterRef.kind == "party" then
                BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": no character in slot " .. casterRef.slot)
            else
                BfBot.Exec._LogEntry("SKIP", "Entry " .. i .. ": summon caster gone ("
                    .. tostring(casterRef.name) .. ", " .. casterKey .. ")")
            end
            goto continue
        end

        -- Multiplayer: never queue casts on a caster this machine doesn't
        -- control (last line of defense; the persistence builders filter too).
        -- Memoize per caster key — control is invariant within one build, so
        -- the pcall-guarded reflection runs once per caster, not once per entry.
        if BfBot.Mp and BfBot.Mp.IsLocallyControlled then
            local controlled = controlCache[casterKey]
            if controlled == nil then
                controlled = BfBot.Mp.IsLocallyControlled(casterSprite) and true or false
                controlCache[casterKey] = controlled
            end
            if not controlled then
                local where = casterRef.kind == "party"
                    and ("in slot " .. casterRef.slot) or casterKey
                BfBot.Exec._LogEntry("SKIP", "Entry " .. i .. ": caster "
                    .. where .. " not locally controlled (multiplayer)")
                goto continue
            end
        end

        local casterName = BfBot._GetName(casterSprite)
        local resref = entry.spell
        if type(resref) ~= "string" or resref == "" then
            BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": invalid spell resref")
            goto continue
        end

        -- Look up spell data from scanner
        local spells = BfBot.Scan.GetCastableSpells(casterSprite)
        local spellData = spells and spells[resref]
        if not spellData then
            BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": " .. casterName
                .. " does not have " .. resref .. " available")
            goto continue
        end

        local classResult = spellData.class
        local isAoE = classResult and classResult.isAoE or false
        local splstates = classResult and classResult.splstates or {}
        local spellName = spellData.name or resref

        -- Resolve targets (self-targets record the caster's party slot when
        -- there is one; summon casters have no slot — Lua 0-truthy makes the
        -- `and slot` form safe for slot 0)
        local targets = BfBot.Exec._ResolveTargets(
            entry.target, casterSprite,
            casterRef.kind == "party" and casterRef.slot or nil, isAoE
        )

        if #targets == 0 then
            BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": no valid targets for " .. spellName)
            goto continue
        end

        -- Group by caster key
        byCaster[casterKey] = byCaster[casterKey] or {}

        -- Determine cheat tagging for quick cast mode. A builder-precomputed
        -- entry.cheat (summon queues: the summon preset carries its OWN qc,
        -- issue #19) takes precedence over the run-wide qcMode in BOTH
        -- directions — 1 forces cheat on, 0 forces it off. Party entries
        -- never carry the field, so their behavior is unchanged.
        local isCheat = false
        if entry.cheat ~= nil then
            isCheat = (entry.cheat == 1 or entry.cheat == true)
        elseif qcMode == 2 then
            isCheat = true
        elseif qcMode == 1 then
            local durCat = entry.durCat or "short"
            isCheat = (durCat == "permanent" or durCat == "long")
        end

        for _, tgt in ipairs(targets) do
            -- No casterSprite on the entry: exec-time code must resolve fresh
            -- via _ResolveCaster every step, never through build-time userdata.
            table.insert(byCaster[casterKey], {
                casterRef = casterRef,
                casterName = casterName,
                resref = resref,
                spellName = spellName,
                targetObj = tgt.targetObj,
                targetSlot = tgt.targetSlot,
                targetSprite = tgt.targetSprite,
                targetName = tgt.targetName,
                splstates = splstates,
                isAoE = isAoE,
                cheat = isCheat,
                var = entry.var,
            })
            totalEntries = totalEntries + 1
        end

        ::continue::
    end

    if totalEntries == 0 then
        return nil, "no valid entries after expansion"
    end

    -- Cast order: user-set priority (pri) is always respected — no reordering.
    -- Quick Cast toggles IA on/off per entry based on cheat flag (durCat).

    return byCaster, totalEntries
end

--- Pre-flight checks for a single queue entry.
-- @param entry table: the queue entry
-- @param casterSprite userdata: the caster, freshly resolved by the caller
--     this step (_ProcessCasterEntry) — entries carry no caster userdata.
--     Target-side checks stay on entry.targetSprite (party targets; stale
--     detection covers them).
function BfBot.Exec._CheckEntry(entry, casterSprite)
    if BfBot.Exec._state ~= "running" then
        return false
    end

    local label = entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName

    -- Caster alive
    if not BfBot.Exec._IsAlive(casterSprite) then
        BfBot.Exec._LogEntry("SKIP", label .. " (caster dead)")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        return false
    end

    -- Spell slot available (invalidate cache to get fresh count)
    BfBot.Scan.Invalidate(casterSprite)
    local spells = BfBot.Scan.GetCastableSpells(casterSprite)
    local spellData = spells and spells[entry.resref]
    if not spellData or spellData.count <= 0 then
        BfBot.Exec._LogEntry("SKIP", label .. " (no slot)")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        return false
    end

    -- Target alive (skip for "Myself")
    if entry.targetObj ~= "Myself" then
        if not BfBot.Exec._IsAlive(entry.targetSprite) then
            BfBot.Exec._LogEntry("SKIP", label .. " (target dead)")
            BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
            return false
        end
    end

    -- Buff already active check (always check the actual target sprite —
    -- for AoE entries resolved via "all", targetSprite is already the caster)
    local targetSprite = entry.targetSprite

    local splstatePositive = false

    -- SPLSTATE check (fast negative — trust "none active" as proof spell is absent)
    if entry.splstates and #entry.splstates > 0 then
        for _, stateID in ipairs(entry.splstates) do
            local ok, active = pcall(function()
                return targetSprite:getSpellState(stateID)
            end)
            if ok and active then
                splstatePositive = true
                break
            end
        end
        if not splstatePositive then
            -- No SPLSTATE active → spell definitely not on target, skip effect list walk
            return true
        end
        -- SPLSTATE positive → could be false positive, verify with effect list below
    end

    -- Effect list check (authoritative — runs when SPLSTATEs ambiguous or spell has none)
    -- For variant spells, the variant resref produces the actual buff effects
    local checkResref = entry.var or entry.resref
    if BfBot.Exec._HasActiveEffect(targetSprite, checkResref) then
        BfBot.Exec._LogEntry("SKIP", label .. " (already active)")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        return false
    end

    -- SPLSTATE said active but effect list disagrees — old logic would have falsely skipped
    if splstatePositive then
        BfBot.Exec._LogEntry("INFO", label .. " (splstate false positive caught, checked " .. checkResref .. ")")
    end

    return true
end

--- Finish the chain of a caster whose ref no longer resolves to a live
--- sprite (dead/expired summon, emptied portrait slot). Marks it done,
--- decrements the active count, completes the run when it was the last one.
--- Per-caster and clean by design: a gone summon must never reset the whole
--- run, and can never stall it INDEFINITELY (issue #19) — a summon destroyed
--- mid-cast takes its queued advance with it, so this may only fire via the
--- _SafetyTick gone-summon sweep (~2s) or, worst case, the watchdog.
function BfBot.Exec._FinishGoneCaster(caster)
    if caster.done then return end
    caster.done = true
    BfBot.Exec._activeCasters = BfBot.Exec._activeCasters - 1
    BfBot.Exec._LogEntry("INFO", caster.name .. " gone — finishing chain")
    if BfBot.Exec._activeCasters <= 0 then
        BfBot.Exec._Complete()
    end
end

--- Process a caster's queue entry at the given index.
-- Each caster runs their own chain independently.
-- @param key string: caster key ("p<slot>" / "s<oid>") into _casters
function BfBot.Exec._ProcessCasterEntry(key, index)
    local caster = BfBot.Exec._casters[key]
    if not caster then return end

    -- Fresh-resolve the caster EVERY step — records/entries carry no sprite
    -- userdata (issues #38/#19). A caster that no longer resolves finishes
    -- its chain cleanly instead of dereferencing a stale pointer. Party refs
    -- add a name guard (portrait reshuffle), summon refs an EA-band re-read
    -- (allegiance flip) — see _ResolveCasterForStep.
    local sprite = BfBot.Exec._ResolveCasterForStep(caster)
    if not sprite then
        BfBot.Exec._FinishGoneCaster(caster)
        return
    end

    -- Watchdog: any caster stepping through its queue counts as forward progress.
    BfBot.Exec._NoteProgress()

    -- This caster's queue exhausted
    if index > #caster.queue then
        caster.done = true
        BfBot.Exec._activeCasters = BfBot.Exec._activeCasters - 1
        BfBot.Exec._LogEntry("INFO", caster.name .. " finished")
        if BfBot.Exec._activeCasters <= 0 then
            BfBot.Exec._Complete()
        end
        return
    end

    -- Stopped by user
    if BfBot.Exec._state ~= "running" then
        return
    end

    caster.index = index
    local entry = caster.queue[index]

    -- Pre-flight checks — skip immediately recurses to next
    if not BfBot.Exec._CheckEntry(entry, sprite) then
        BfBot.Exec._ProcessCasterEntry(key, index + 1)
        return
    end

    -- Safety: variant spell with no variant configured — skip
    if not entry.var then
        local scanSpells = BfBot.Scan.GetCastableSpells(sprite)
        local spellScan = scanSpells and scanSpells[entry.resref]
        if spellScan and spellScan.hasVariants == 1 then
            BfBot.Exec._LogEntry("SKIP",
                entry.casterName .. " -> " .. entry.spellName
                .. " (variant spell — no variant configured)")
            BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
            BfBot.Exec._ProcessCasterEntry(key, index + 1)
            return
        end
    end

    -- Quick Cast: toggle IA on/off per entry based on cheat flag.
    -- Preserves user priority order — no reordering by duration category.
    if caster.cheatBoundary > 0 then
        if entry.cheat and not caster.cheatApplied then
            EEex_Action_QueueResponseStringOnAIBase(
                'ReallyForceSpellRES("BFBTCH",Myself)', sprite)
            caster.cheatApplied = true
            BfBot.Exec._LogEntry("INFO", entry.casterName .. " Quick Cast ON")
        elseif not entry.cheat and caster.cheatApplied then
            EEex_Action_QueueResponseStringOnAIBase(
                'ReallyForceSpellRES("BFBTCR",Myself)', sprite)
            caster.cheatApplied = false
            BfBot.Exec._LogEntry("INFO", entry.casterName .. " Quick Cast OFF")
        end
    end

    -- Cast the spell. The advance callback embeds the caster key as a Lua
    -- LONG-BRACKET string literal:
    --   EEex_LuaAction("BfBot.Exec._Advance([[p0]])")
    -- NOT single quotes: the BCS tokenizer strips single quotes inside a
    -- double-quoted action argument (verified live 2026-07-11 — 'p0' arrives
    -- as the nil global p0). Caster keys are alphanumeric by construction
    -- ("^p%d$" / "^s%d+$"), so "]]" can never appear in a key; long brackets
    -- are therefore always safe here.
    local advanceAction = string.format(
        "EEex_LuaAction(\"BfBot.Exec._Advance([[%s]])\")", key)

    if entry.var then
        -- Variant spell path: consume parent spell slot, then cast the variant
        -- directly via ReallyForceSpellRES (variant SPL is not in the spellbook)
        if not BfBot.Exec._ConsumeSpellSlot(sprite, entry.resref) then
            BfBot.Exec._LogEntry("SKIP",
                entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName
                .. " (no slot for variant)")
            BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
            BfBot.Exec._ProcessCasterEntry(key, index + 1)
            return
        end
        local varAction = string.format('ReallyForceSpellRES("%s",%s)', entry.var, entry.targetObj)
        EEex_Action_QueueResponseStringOnAIBase(varAction, sprite)
        EEex_Action_QueueResponseStringOnAIBase(advanceAction, sprite)
        BfBot.Exec._LogEntry("CAST",
            entry.casterName .. " -> " .. entry.spellName .. " [" .. entry.var .. "] -> " .. entry.targetName)
        BfBot.Exec._castCount = BfBot.Exec._castCount + 1
    else
        -- Normal path: queue SpellRES action (engine handles slot consumption)
        local spellAction = string.format('SpellRES("%s",%s)', entry.resref, entry.targetObj)
        EEex_Action_QueueResponseStringOnAIBase(spellAction, sprite)
        EEex_Action_QueueResponseStringOnAIBase(advanceAction, sprite)
        BfBot.Exec._LogEntry("CAST",
            entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName)
        BfBot.Exec._castCount = BfBot.Exec._castCount + 1
    end
end

--- Called by the engine via EEex_LuaAction after a caster's spell completes.
-- @param key string: caster key ("p<slot>" / "s<oid>") into _casters
function BfBot.Exec._Advance(key)
    if BfBot.Exec._state ~= "running" then return end
    local caster = BfBot.Exec._casters[key]
    if not caster or caster.done then return end

    -- Caster vanished between steps (summon expired/killed, slot emptied),
    -- changed occupant (portrait reshuffle — never route the chain through
    -- the wrong character) or flipped allegiance (summon EA re-read): finish
    -- cleanly before touching anything sprite-related. Shared rules in
    -- _ResolveCasterForStep.
    local sprite = BfBot.Exec._ResolveCasterForStep(caster)
    if not sprite then
        BfBot.Exec._FinishGoneCaster(caster)
        return
    end

    -- Combat detection: abort all casters if hostiles detected
    if BfBot.Exec._DetectCombat() then
        BfBot.Exec._LogEntry("INFO", "Combat detected — stopping execution")
        BfBot.Exec.Stop()
        -- Notify player via overhead text on party leader
        pcall(function()
            local leader = EEex_Sprite_GetInPortrait(0)
            if leader then
                EEex_Sprite_DisplayStringHead(leader,
                    "BuffBot: Combat detected - casting stopped")
            end
        end)
        return
    end

    BfBot.Exec._ProcessCasterEntry(key, caster.index + 1)
end

--- Reset all execution state without touching engine memory.
--- Used to recover from save-reload mid-cast (issue #38). Caster records
--- hold plain refs (never sprite userdata), so clearing the table is pure
--- Lua — no engine pointer is ever dereferenced here. Caller is responsible
--- for closing the exec log (see Stop / _Complete recovery branches); this
--- keeps the function side-effect free so the in-game test suite can capture
--- its own output to the log around each subtest.
function BfBot.Exec._HardReset()
    BfBot.Exec._state         = "idle"
    BfBot.Exec._casters       = {}
    BfBot.Exec._activeCasters = 0
    BfBot.Exec._castCount     = 0
    BfBot.Exec._skipCount     = 0
    BfBot.Exec._totalEntries  = 0
    BfBot.Exec._qcMode        = 0
    BfBot.Exec._lastProgressGameTime = nil
    BfBot.Exec._runPresetIdx  = nil
    BfBot.Exec._pendingLateJoin = {}
end

--- Detect stale execution state from a save reload mid-cast.
--- After loading a save while casting, the EEex_LuaAction chains driving
--- _Advance are gone, so _state would stay "running" forever. Sprite
--- identity can't be compared directly — EEex returns a fresh userdata
--- wrapper per call to EEex_Sprite_GetInPortrait, and `==` falls through
--- to a __eq metamethod that does NOT pointer-compare the wrapped
--- CGameSprite (verified empirically with two consecutive calls returning
--- different wrappers and `==` evaluating to false).
---
--- Instead, compare the cached character name (a plain string captured
--- at Start time) against the freshly-fetched portrait sprite's name.
--- The fresh sprite is safe to dereference; the cached string never
--- references engine memory. This catches the "different-party-composition
--- reload" case (e.g. user reloads to before recruiting an NPC). It does
--- NOT catch the "same-save reload" case where party composition is
--- unchanged — cleanup loops always resolve fresh via _ResolveCaster and
--- never hold sprite userdata across steps.
---
--- Only PARTY refs participate: a summon caster's staleness is per-step
--- (_ResolveCaster returning nil finishes that one chain cleanly, see
--- _FinishGoneCaster) and must never reset the whole run.
--- @return boolean: true if state is "running" but at least one party
---     caster's cached name no longer matches the portrait at its slot.
function BfBot.Exec._IsStateStale()
    if BfBot.Exec._state ~= "running" then return false end

    for _, caster in pairs(BfBot.Exec._casters) do
        local ref = caster.ref
        if ref and ref.kind == "party" and caster.name then
            local fresh = EEex_Sprite_GetInPortrait(ref.slot)
            local freshName = fresh and BfBot._GetName(fresh) or nil
            if freshName ~= caster.name then return true end
        end
    end

    return false
end

--- Strip lingering quick-cast (BFBTCH) buffs from every caster. Resolves each
--- sprite fresh via _ResolveCaster rather than holding userdata on the record —
--- cached userdata wraps a freed CGameSprite after a save reload (issue #38),
--- and pcall does NOT catch the engine-level access violation. BFBTCR is a
--- no-op on a target without an active BFBTCH, so this is safe even if a
--- party slot now holds a different character; a summon caster that no longer
--- resolves needs no cleanup (its effects died with it). Shared by _Complete,
--- Stop, and _ForceComplete.
function BfBot.Exec._StripCheatBuffs()
    for _, caster in pairs(BfBot.Exec._casters) do
        if caster.cheatApplied then
            local sprite = BfBot.Exec._ResolveCaster(caster.ref)
            if sprite then
                pcall(function()
                    EEex_Action_QueueResponseStringOnAIBase(
                        'ReallyForceSpellRES("BFBTCR",Myself)', sprite)
                end)
            end
            caster.cheatApplied = false
        end
    end
end

--- Log execution summary and transition to "done" state.
function BfBot.Exec._Complete()
    -- Fast-path recovery from save-reload (issue #38) — see Stop().
    -- Also legitimately reached when a gone PARTY caster (emptied/reshuffled
    -- portrait slot) finished last: no DONE summary then — benign; the orphan
    -- sweep still strips any lingering BFBTCH within ~2-4s.
    if BfBot.Exec._IsStateStale() then
        BfBot.Exec._HardReset()
        BfBot._CloseLog()
        return
    end

    -- Clean up lingering cheat buffs — resolves each caster fresh,
    -- never through cached userdata (see Stop() rationale).
    BfBot.Exec._StripCheatBuffs()

    BfBot.Exec._state = "done"
    local cast = BfBot.Exec._castCount
    local skip = BfBot.Exec._skipCount
    local total = cast + skip
    BfBot.Exec._LogEntry("DONE",
        string.format("Total: %d | Cast: %d | Skipped: %d", total, cast, skip))
    BfBot._Print("[BuffBot] === Execution Complete ===")
    BfBot._CloseLog()
end

--- Force-complete a stuck run (watchdog). Strips lingering cheat buffs the
--- same way _Complete/Stop do — resolving each caster fresh via its ref,
--- never through cached sprite userdata (that would wrap a freed CGameSprite
--- after a save reload; pcall does not catch that access violation).
---
--- Invoked when a caster's _Advance chain never fires. The motivating case is
--- multiplayer: BuffBot queues SpellRES + EEex_LuaAction onto the LOCAL copy of
--- a creature's action list (EEex_Action_QueueResponseStringOnAIBase ->
--- virtual_InsertAction, which is not networked), so a character controlled by
--- another player never executes that chain, _Advance never runs, _activeCasters
--- never reaches 0, and the status would stay stuck on "casting" forever. The
--- proper MP fix is to not queue non-local casters at all; this is the
--- unconditional safety net so the UI can never lock regardless of cause.
--- @param reason string: logged WARN explaining why the run was force-completed
function BfBot.Exec._ForceComplete(reason)
    -- Clean up lingering cheat buffs (see _Complete/Stop for the re-resolve rationale).
    BfBot.Exec._StripCheatBuffs()

    BfBot.Exec._state = "done"
    BfBot.Exec._LogEntry("WARN", reason)
    BfBot.Exec._LogEntry("DONE", string.format(
        "Force-completed | Cast: %d | Skipped: %d",
        BfBot.Exec._castCount, BfBot.Exec._skipCount))
    BfBot._Print("[BuffBot] === Execution Force-Completed ===")
    BfBot._CloseLog()
end

--- Highest 1-based index of an entry carrying the cheat flag in ONE
--- caster's built entry list, 0 when none. Factored out of Start so the
--- rule is testable without a live run. UNCONDITIONAL by design — no
--- _qcMode gate: summon entries carry their identity preset's OWN
--- precomputed cheat flag (issue #19) and must get their BFBTCH toggle
--- even in a run started with qcMode=0 (the default UI path and the
--- standalone summon cast). Party-inert by construction: _BuildQueue only
--- marks party entries cheat=true when qcMode>0, so a qcMode=0 party run
--- still derives boundary 0 everywhere.
function BfBot.Exec._DeriveCheatBoundary(entries)
    local boundary = 0
    for i, e in ipairs(type(entries) == "table" and entries or {}) do
        -- Same cheat-on predicate as _BuildQueue's normalization: only 1 or
        -- true count, never bare truthiness — Lua 0 is TRUTHY, and builder-
        -- level entries carry cheat as 1/0 (marshal convention).
        if e.cheat == 1 or e.cheat == true then boundary = i end
    end
    return boundary
end

--- Attach a caster to the RUNNING run for a summon that spawned mid-run
--- (late-join, issue #19). Expands the builder queue through _BuildQueue
--- (same normalization, checks and logging as Start) and inserts a caster
--- record of the exact shape Start creates. cheatBoundary is derived from
--- the NEW entries at attach time — summon entries carry their identity
--- preset's OWN precomputed cheat flag, so the late-joiner gets its BFBTCH
--- toggle regardless of the run's qcMode (same rule as Start). Bumps
--- _activeCasters (completion accounting) and _totalEntries ("total entries
--- across all casters" stays true; the DONE summary itself counts
--- cast+skip and needs no adjustment), logs the late-join, notes watchdog
--- progress, then kicks the chain at entry 1.
--- Caller (_OnSpriteLoaded) guarantees: state == "running", the key is not
--- yet in _casters, and the MP gate passed.
-- @param summonEntry detection entry (ClassifySummonSprite shape: oid, name)
-- @param queue builder queue (BfBot.Persist.BuildQueueForSummon shape)
-- @return true when attached, false when the queue expanded empty (summon
--     vanished between classify and build — normal churn)
function BfBot.Exec._AttachCaster(summonEntry, queue)
    local byCaster = BfBot.Exec._BuildQueue(queue, BfBot.Exec._qcMode)
    if not byCaster then return false end
    local key = "s" .. summonEntry.oid
    local entries = byCaster[key]
    if not entries or #entries == 0 then return false end

    -- Same record shape as Start: no sprite userdata — every exec step
    -- resolves fresh from the ref (issues #38/#19).
    BfBot.Exec._casters[key] = {
        ref = entries[1].casterRef,
        queue = entries,
        index = 0,
        done = false,
        name = entries[1].casterName,
        cheatBoundary = BfBot.Exec._DeriveCheatBoundary(entries),
        cheatApplied = false,
    }
    BfBot.Exec._activeCasters = BfBot.Exec._activeCasters + 1
    BfBot.Exec._totalEntries = BfBot.Exec._totalEntries + #entries
    BfBot.Exec._LogEntry("INFO", "late-join: "
        .. tostring(entries[1].casterName) .. " (" .. #entries .. " entries)")
    BfBot.Exec._NoteProgress()  -- the watchdog must see the attach
    BfBot.Exec._ProcessCasterEntry(key, 1)
    return true
end

--- Late-join listener body (issue #19): a summon spawning MID-RUN attaches
--- to the running cast as its own caster. Registered in M_BfBot.lua as a
--- thin namespace-resolving wrapper — this factored body is suite-testable
--- and hot-reload swappable. EEex_Sprite_AddLoadedListener also fires for
--- new-game, save load, area transition and party join; the guards below
--- (cheap-first, plan-mandated order) make everything but a mid-run spawn
--- a no-op, and a save-load mid-run additionally hits _IsStateStale / the
--- gone-summon sweep first (verified Task 8 behavior).
---
--- TWO-PHASE by engine necessity (probe-verified live 2026-07-14): the
--- loaded listener fires from OnAfterEffectListUnmarshalled, and for a
--- freshly CONJURED clone that is BEFORE the engine sets its name ("?"),
--- EA (still the owner's verbatim 2, not ALLY 4), script name (still the
--- owner's, not "COPY") and puppet linkage (m_nCopyParent -1, m_bInCopy
--- false, stat 139 = 0) — only the spellbook is already copied. Immediate
--- ClassifySummonSprite here would misidentify a clone as a plain summon
--- with a wrong identity and a nameless ref (which the anti-recycle name
--- guard would later kill mid-chain). So this listener only RECORDS the
--- object id; _ProcessLateJoins (driven by _SafetyTick's ~2s cadence)
--- classifies and attaches once the sprite reports a real name.
---
--- The work runs inside a CHECKED pcall — a structurally broken listener
--- must WARN on every fire, never silently disable late-join forever
--- (silent-pcall landmine).
function BfBot.Exec._OnSpriteLoaded(sprite)
    if BfBot.Exec._state ~= "running" then return end
    if BfBot.Exec._runPresetIdx == nil then return end
    local ok, err = pcall(function()
        if EEex_Sprite_GetPortraitIndex(sprite) ~= -1 then return end
        local oid = sprite.m_id
        if type(oid) ~= "number" then return end
        if BfBot.Exec._casters["s" .. oid] then return end  -- already attached
        -- Record once; never reset an existing entry's retry budget.
        if BfBot.Exec._pendingLateJoin[oid] == nil then
            BfBot.Exec._pendingLateJoin[oid] = BfBot.Exec._LATEJOIN_MAX_TRIES
        end
    end)
    if not ok then
        BfBot._Warn("[Exec] late-join listener: " .. tostring(err))
    end
end

--- Attempt to late-join ONE pending sprite (phase 2, see _OnSpriteLoaded).
--- Canonical sequence, cheap-first: already-attached -> resolve -> not
--- party -> classify -> initialized -> MP gate -> build -> attach.
--- @return true when the sprite is not READY yet (name still unresolved —
---     caller retries within the budget); false/nil when finished with the
---     oid (attached, gone, or filtered out — caller drops it).
function BfBot.Exec._TryLateJoin(oid)
    if BfBot.Exec._casters["s" .. oid] then return false end
    -- Direct object-id resolve — no name guard yet: the trustworthy name is
    -- exactly what initialization has not delivered until classify succeeds
    -- below. The oid was recorded seconds ago; the classify + readiness
    -- checks reject anything that is not an allied castable summon.
    local obj = EEex_GameObject_Get(oid)
    if not obj or not EEex_GameObject_IsSprite(obj, false) then return false end
    local sprite = EEex_GameObject_CastUserType(obj)
    if EEex_Sprite_GetPortraitIndex(sprite) ~= -1 then return false end
    -- Structural filter shared with the area sweep (allied castable summon
    -- or nil) — never a second detection rule.
    local e = BfBot.Scan.ClassifySummonSprite(sprite)
    if not e then return false end
    -- Readiness gate: the engine sets name / EA / puppet linkage together
    -- moments after spawn (probe 2026-07-14); an entry still reporting the
    -- "?" name fallback was classified off a half-initialized sprite —
    -- retry next tick instead of attaching a misidentified caster.
    if e.name == "?" then return true end
    -- ONE canonical MP gate — the same conservative rule the
    -- BuildQueueFromPreset sweep applies (Task-13 seam: defers to
    -- BfBot.Mp.IsSummonLocallyControlled once that exists).
    if not BfBot.Persist._SummonPassesMpRule(e) then return false end
    local q = BfBot.Persist.BuildQueueForSummon(e, BfBot.Exec._runPresetIdx)
    -- The builder queues its SKIP lines for the config panel
    -- (Persist._pendingSkips) and file-logged them at build time. The run
    -- is LIVE here, so surface them straight into ITS in-memory panel log
    -- (same {type, msg} shape as _LogEntry, no second file write — the
    -- UI._SurfaceBuildSkips rationale) instead of letting them leak into
    -- the NEXT panel run's log (MINOR-3 class).
    if BfBot.Persist.DrainBuildSkips then
        for _, msg in ipairs(BfBot.Persist.DrainBuildSkips()) do
            table.insert(BfBot.Exec._log, { type = "SKIP", msg = msg })
        end
    end
    if not q or #q == 0 then return false end
    BfBot.Exec._AttachCaster(e, q)
    return false
end

--- Drain the pending late-join list (called from _SafetyTick's running
--- branch, so rate-limited to its ~2s cadence and only ever active during
--- a run). Each oid gets _LATEJOIN_MAX_TRIES attempts; _TryLateJoin
--- returning true means "not initialized yet, retry", anything else
--- finishes the oid. CHECKED pcall per oid — one broken entry must WARN
--- and be dropped, never wedge the tick or starve the other pending oids.
function BfBot.Exec._ProcessLateJoins()
    local pending = BfBot.Exec._pendingLateJoin
    for oid, tries in pairs(pending) do
        local ok, retry = pcall(BfBot.Exec._TryLateJoin, oid)
        if not ok then
            pending[oid] = nil
            BfBot._Warn("[Exec] late-join (oid " .. tostring(oid) .. "): "
                .. tostring(retry))
        elseif retry == true and tries > 1 then
            pending[oid] = tries - 1
        else
            pending[oid] = nil
        end
    end
end

--- Start executing a buff queue with parallel per-caster casting.
-- @param queue array of {caster=0-5, spell="RESREF", target="self"|"all"|1-6}
-- @param qcMode quick cast mode (0=off, 1=long, 2=all)
-- @param presetIdx OPTIONAL preset index driving this run — recorded as
--     _runPresetIdx so a summon spawning MID-RUN can look up ITS summon
--     preset (late-join listener, issue #19). Raw/console queues pass
--     nothing → nil → late-join stays inert for that run (correct: there
--     is no preset to look a summon's config up under).
-- @return true if started, false + reason string if not
function BfBot.Exec.Start(queue, qcMode, presetIdx)
    if BfBot.Exec._state == "running" then
        BfBot._Print("[BuffBot] Already running. Call BfBot.Exec.Stop() first.")
        return false, "already running"
    end

    -- Open execution log file
    BfBot._OpenLogAppend(BfBot.Exec._logFile)

    -- Reset state
    BfBot.Exec._state = "idle"
    BfBot.Exec._casters = {}
    BfBot.Exec._activeCasters = 0
    BfBot.Exec._log = {}
    BfBot.Exec._castCount = 0
    BfBot.Exec._skipCount = 0
    BfBot.Exec._totalEntries = 0
    BfBot.Exec._qcMode = qcMode or 0
    BfBot.Exec._lastProgressGameTime = nil
    BfBot.Exec._runPresetIdx = (type(presetIdx) == "number") and presetIdx or nil
    BfBot.Exec._pendingLateJoin = {}

    -- Build per-caster queues
    local byCaster, totalEntries = BfBot.Exec._BuildQueue(queue, BfBot.Exec._qcMode)
    if not byCaster then
        BfBot.Exec._LogEntry("ERROR", "Failed to build queue: " .. tostring(totalEntries))
        BfBot._CloseLog()
        return false, totalEntries
    end

    BfBot.Exec._totalEntries = totalEntries

    -- Initialize per-caster state and print plan
    local casterCount = 0
    local qcLabel = BfBot.Exec._qcMode == 2 and " (Quick Cast: All)"
        or BfBot.Exec._qcMode == 1 and " (Quick Cast: Long)" or ""
    BfBot._Print("[BuffBot] === Starting Execution: " .. totalEntries .. " entries" .. qcLabel .. " ===")

    -- Sort caster keys for deterministic display order ("p0".."p5" sort
    -- ahead of "s<oid>" lexicographically — party first, then summons)
    local keys = {}
    for key, _ in pairs(byCaster) do table.insert(keys, key) end
    table.sort(keys)

    for _, key in ipairs(keys) do
        local entries = byCaster[key]
        local name = entries[1].casterName

        -- Quick Cast: cheatBoundary > 0 means this caster has cheat entries.
        -- IA toggles on/off per entry — no reordering by duration. Derived
        -- from the entries' cheat flags unconditionally — a summon whose own
        -- preset carries qc>0 gets its toggle even in a qcMode=0 run (see
        -- _DeriveCheatBoundary for why this is party-inert).
        local cheatBoundary = BfBot.Exec._DeriveCheatBoundary(entries)

        -- No sprite userdata on the record: every exec step resolves fresh
        -- from the ref (issues #38/#19).
        BfBot.Exec._casters[key] = {
            ref = entries[1].casterRef,
            queue = entries,
            index = 0,
            done = false,
            name = name,
            cheatBoundary = cheatBoundary,
            cheatApplied = false,
        }
        BfBot.Exec._activeCasters = BfBot.Exec._activeCasters + 1
        casterCount = casterCount + 1

        -- Log this caster's plan
        BfBot._Print("[BuffBot]   " .. name .. " (" .. #entries .. " spells):")
        for i, e in ipairs(entries) do
            BfBot._Print("[BuffBot]     " .. i .. ". " .. e.spellName .. " -> " .. e.targetName)
        end
    end

    BfBot._Print("[BuffBot] " .. casterCount .. " casters working in parallel")

    -- Go — start ALL casters simultaneously
    BfBot.Exec._state = "running"
    BfBot.Exec._NoteProgress()  -- arm the watchdog timer
    for _, key in ipairs(keys) do
        BfBot.Exec._ProcessCasterEntry(key, 1)
    end

    return true
end

--- Stop execution mid-queue.
function BfBot.Exec.Stop()
    -- Fast-path recovery from save-reload mid-cast with party composition
    -- change (issue #38): hard-reset to idle without entering the cleanup
    -- loop — there's nothing to clean up because the buffs were applied to
    -- the previous save's party.
    if BfBot.Exec._IsStateStale() then
        BfBot._Print("[BuffBot] Stale execution state from save reload — resetting.")
        BfBot.Exec._HardReset()
        BfBot._CloseLog()
        return
    end

    if BfBot.Exec._state ~= "running" then
        BfBot._Print("[BuffBot] Not running.")
        return
    end
    BfBot.Exec._state = "stopped"

    -- Clean up lingering cheat buffs. Casters are resolved fresh from their
    -- refs — records hold no sprite userdata, which after a save reload
    -- mid-cast would wrap a freed CGameSprite pointer (issue #38); pcall
    -- does NOT catch the access violation engine calls would trigger on it.
    -- This fresh resolution is safe even when _IsStateStale missed a same-
    -- party reload: BFBTCR is a no-op on targets without an active BFBTCH.
    BfBot.Exec._StripCheatBuffs()

    BfBot.Exec._LogEntry("INFO", "Stopped by user")
    BfBot._Print("[BuffBot] === Execution Stopped ===")
    BfBot._Print(string.format("[BuffBot]   Cast: %d | Skipped: %d",
        BfBot.Exec._castCount, BfBot.Exec._skipCount))
    BfBot._CloseLog()
end

--- Paranoid safety net: remove orphaned BFBTCH effects from any party member
-- (baseline sweep) plus any summon casters of the current/last run.
-- Called every frame by .menu enabled tick, rate-limited to ~2 seconds.
-- NOT toggleable — this is the hard safety guarantee.
function BfBot.Exec._SafetyTick()
    -- Rate-limit: ~2 seconds between checks
    local now = Infinity_GetClockTicks()
    if now - BfBot.Exec._lastSafetyTick < 2000 then return end
    BfBot.Exec._lastSafetyTick = now

    -- Proactively recover from save-reload mid-cast (issue #38). The
    -- EEex_LuaAction chain that drives _Advance does NOT resume after a
    -- save load, so _state stays "running" forever and the UI gates
    -- Cast/CastChar off. Detect via portrait-set mismatch and reset so the
    -- user sees a clean idle state on next menu open — and so the running
    -- branch below falls through to the BFBTCH cleanup loop.
    if BfBot.Exec._IsStateStale() then
        BfBot.Exec._HardReset()
    end

    -- Watchdog: force-complete a run that has stopped making progress. Known
    -- causes: multiplayer casters controlled by another player (their queued
    -- SpellRES + EEex_LuaAction live only in this machine's local action list
    -- and are not networked, so _Advance never fires), gone-summon edge cases
    -- the sweep below didn't catch, and plain engine stalls. _NoteProgress()
    -- bumps the timer on every queued cast and every advance, so a healthy run
    -- never trips it; only a genuine stall (no progress anywhere for the whole
    -- timeout) force-completes. Targeted fixes (MP caster filter, gone-summon
    -- sweep) come first — this is the hard safety net underneath them all.
    if BfBot.Exec._state == "running" then
        -- Gone-summon sweep (issue #19), BEFORE the watchdog: a summon
        -- destroyed mid-cast takes its queued EEex_LuaAction advance with it,
        -- so the per-step gone path never fires and the run would stall until
        -- the watchdog. Finish summon-kind casters whose ref no longer
        -- resolves (or fails the EA-band re-read) here → clean completion in
        -- ~2s with a correct DONE summary. Summon-kind only — party slots
        -- stay per-step (portraits don't vanish silently; the stale check
        -- covers reloads).
        for _, caster in pairs(BfBot.Exec._casters) do
            if not caster.done and caster.ref and caster.ref.kind == "summon" then
                if not BfBot.Exec._ResolveCasterForStep(caster) then
                    BfBot.Exec._FinishGoneCaster(caster)
                end
            end
        end
        -- The sweep may have finished the LAST caster: _FinishGoneCaster then
        -- ran _Complete and the run is over — nothing left to watchdog.
        if BfBot.Exec._state ~= "running" then return end

        -- Late-join (issue #19): classify-and-attach summons the loaded
        -- listener recorded, now that the engine has had time to finish
        -- initializing them (see _OnSpriteLoaded — fire-time fields are
        -- incomplete). Runs at this tick's ~2s cadence, only while running;
        -- an attach kicks casts and notes progress, so the watchdog below
        -- sees it.
        BfBot.Exec._ProcessLateJoins()

        -- Measure progress in GAME time (frozen while paused) so a paused-but-
        -- healthy buff run is never force-killed. Only trip when the game has
        -- actually advanced _WATCHDOG_TIMEOUT_GAMETICKS with no forward progress.
        local gtNow = BfBot.Exec._GetGameTime()
        local gtLast = BfBot.Exec._lastProgressGameTime
        if gtNow and gtLast and (gtNow - gtLast) >= BfBot.Exec._WATCHDOG_TIMEOUT_GAMETICKS then
            BfBot.Exec._ForceComplete(string.format(
                "Watchdog: no cast progress for %d game-ticks — force-completing. A "
                .. "caster's chain never advanced (multiplayer character controlled "
                .. "by another player, a gone-summon edge case, or an engine stall). "
                .. "Cast again if buffing is incomplete.",
                gtNow - gtLast))
            pcall(function()
                local leader = EEex_Sprite_GetInPortrait(0)
                if leader then
                    EEex_Sprite_DisplayStringHead(leader,
                        "BuffBot: casting timed out - stopped")
                end
            end)
        end
        -- Whether or not it tripped, exec (or the force-complete) owns cheat
        -- management this tick — don't fall through to the orphan cleanup.
        return
    end

    -- Check all party members for orphaned BFBTCH effects
    for i = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(i)
        if sprite then
            BfBot.Exec._SweepOrphanCheat(sprite)
        end
    end

    -- Also sweep summon casters from the current/last run — they are not
    -- covered by the portrait loop above. Fresh-resolve via the ref; a
    -- summon that no longer resolves needs no cleanup (its effects died
    -- with it). Party refs are skipped here (portrait loop covers them).
    for _, caster in pairs(BfBot.Exec._casters) do
        if caster.ref and caster.ref.kind == "summon" then
            local sprite = BfBot.Exec._ResolveCaster(caster.ref)
            if sprite then
                BfBot.Exec._SweepOrphanCheat(sprite)
            end
        end
    end
end

--- Remove an orphaned BFBTCH effect from one sprite, logging a WARN when
--- one was found. Factored out of _SafetyTick so the party-portrait sweep
--- and the summon-caster sweep share the exact same cleanup.
function BfBot.Exec._SweepOrphanCheat(sprite)
    if not BfBot.Exec._HasActiveEffect(sprite, "BFBTCH") then return end
    -- Log honesty: only claim removal when the queue call actually succeeded;
    -- a swallowed pcall failure here would hide a stuck Improved Alacrity.
    local ok, err = pcall(function()
        EEex_Action_QueueResponseStringOnAIBase(
            'ReallyForceSpellRES("BFBTCR",Myself)', sprite)
    end)
    -- Open exec log briefly to persist the warning to disk
    BfBot._OpenLogAppend(BfBot.Exec._logFile)
    if ok then
        BfBot.Exec._LogEntry("WARN",
            "Safety net: removed orphaned BFBTCH from " .. BfBot._GetName(sprite))
    else
        BfBot.Exec._LogEntry("WARN",
            "Safety net: FAILED to queue BFBTCR on " .. BfBot._GetName(sprite)
            .. " (orphaned BFBTCH persists): " .. tostring(err))
    end
    BfBot._CloseLog()
end

--- Get current execution state.
function BfBot.Exec.GetState()
    return BfBot.Exec._state
end

--- Get execution log entries.
function BfBot.Exec.GetLog()
    return BfBot.Exec._log
end
