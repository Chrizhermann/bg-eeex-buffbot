-- ============================================================
-- BfBotExe.lua — Execution Engine (BfBot.Exec)
-- Parallel per-caster buff casting with EEex_LuaAction chaining
-- ============================================================

BfBot.Exec = {}

-- State
BfBot.Exec._state = "idle"       -- "idle" | "running" | "done" | "stopped"
BfBot.Exec._casters = {}         -- {[slot] = {queue={}, index=0, done=false, sprite=s, name=n}}
BfBot.Exec._activeCasters = 0    -- casters still processing (0 = all done)
BfBot.Exec._log = {}             -- log entries: {type=str, msg=str}
BfBot.Exec._castCount = 0        -- casts issued across all casters
BfBot.Exec._skipCount = 0        -- entries skipped across all casters
BfBot.Exec._totalEntries = 0     -- total entries across all casters
BfBot.Exec._logFile = "buffbot_exec.log"
BfBot.Exec._qcMode = 0              -- quick cast mode (0=off, 1=long, 2=all)
BfBot.Exec._lastSafetyTick = 0  -- clock ticks of last safety check
BfBot.Exec._lastProgressGameTime = nil  -- game-time of last forward progress (watchdog; nil until armed)
-- Watchdog timeout in GAME-TIME ticks (m_gameTime), NOT wall-clock. Game time
-- freezes while the game is paused, so a paused-but-healthy buff run is never
-- force-killed. ~450 ticks ≈ 30s at the engine's default rate (~15 game-ticks/s);
-- this is a safety-net threshold, so the exact real-time it maps to is non-critical.
BfBot.Exec._WATCHDOG_TIMEOUT_GAMETICKS = 450

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
-- userQueue: array of {caster=0-5, spell="RESREF", target="self"|"all"|1-6}
-- Returns: {[slot] = {entries}} grouped by caster, or nil + error
function BfBot.Exec._BuildQueue(userQueue, qcMode)
    if not userQueue or #userQueue == 0 then
        return nil, "empty queue"
    end

    local byCaster = {}
    local totalEntries = 0
    local controlCache = {}  -- casterSlot -> boolean; MP control is invariant per build

    for i, entry in ipairs(userQueue) do
        local casterSlot = entry.caster
        if type(casterSlot) ~= "number" or casterSlot < 0 or casterSlot > 5 then
            BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": invalid caster slot " .. tostring(casterSlot))
            goto continue
        end

        local casterSprite = EEex_Sprite_GetInPortrait(casterSlot)
        if not casterSprite then
            BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": no character in slot " .. casterSlot)
            goto continue
        end

        -- Multiplayer: never queue casts on a caster this machine doesn't
        -- control (last line of defense; the persistence builders filter too).
        -- Memoize per slot — control is invariant within one build, so the
        -- pcall-guarded reflection runs once per caster, not once per entry.
        if BfBot.Mp and BfBot.Mp.IsLocallyControlled then
            local controlled = controlCache[casterSlot]
            if controlled == nil then
                controlled = BfBot.Mp.IsLocallyControlled(casterSprite) and true or false
                controlCache[casterSlot] = controlled
            end
            if not controlled then
                BfBot.Exec._LogEntry("SKIP", "Entry " .. i .. ": caster in slot "
                    .. casterSlot .. " not locally controlled (multiplayer)")
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
        local kind = spellData.kind or "spl"

        -- Resolve targets
        local targets = BfBot.Exec._ResolveTargets(
            entry.target, casterSprite, casterSlot, isAoE
        )

        if #targets == 0 then
            BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": no valid targets for " .. spellName)
            goto continue
        end

        -- Group by caster slot
        byCaster[casterSlot] = byCaster[casterSlot] or {}

        -- Determine cheat tagging for quick cast mode
        local isCheat = false
        if qcMode == 2 then
            isCheat = true
        elseif qcMode == 1 then
            local durCat = entry.durCat or "short"
            isCheat = (durCat == "permanent" or durCat == "long")
        end
        if kind == "itm" then
            isCheat = false  -- Quick Cast / IA wrapper doesn't apply to UseItem
        end

        for _, tgt in ipairs(targets) do
            table.insert(byCaster[casterSlot], {
                casterSlot = casterSlot,
                casterSprite = casterSprite,
                casterName = casterName,
                resref = resref,
                kind = kind,
                leafResrefs = spellData.leafResrefs,
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
function BfBot.Exec._CheckEntry(entry)
    if BfBot.Exec._state ~= "running" then
        return false
    end

    local label = entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName

    -- Caster alive
    if not BfBot.Exec._IsAlive(entry.casterSprite) then
        BfBot.Exec._LogEntry("SKIP", label .. " (caster dead)")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        return false
    end

    -- Spell slot available (invalidate cache to get fresh count)
    BfBot.Scan.Invalidate(entry.casterSprite)
    local spells = BfBot.Scan.GetCastableSpells(entry.casterSprite)
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
    -- Catalog entries always carry non-empty leafResrefs (see BfBotScn.lua);
    -- the fallback covers hand-built queues from direct Exec.Start callers.
    local checkResrefs = entry.leafResrefs or { entry.var or entry.resref }
    -- Variants always override: the variant resref produces the actual buff effects
    if entry.var then checkResrefs = { entry.var } end

    local foundActive = nil
    for _, r in ipairs(checkResrefs) do
        if BfBot.Exec._HasActiveEffect(targetSprite, r) then
            foundActive = r
            break
        end
    end

    if foundActive then
        BfBot.Exec._LogEntry("SKIP", label .. " (already active: " .. foundActive .. ")")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        return false
    end

    -- SPLSTATE said active but effect list disagrees — old logic would have falsely skipped
    if splstatePositive then
        BfBot.Exec._LogEntry("INFO", label .. " (splstate false positive caught, checked " .. table.concat(checkResrefs, ",") .. ")")
    end

    return true
end

--- Process a caster's queue entry at the given index.
-- Each caster runs their own chain independently.
function BfBot.Exec._ProcessCasterEntry(slot, index)
    local caster = BfBot.Exec._casters[slot]
    if not caster then return end

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
    if not BfBot.Exec._CheckEntry(entry) then
        BfBot.Exec._ProcessCasterEntry(slot, index + 1)
        return
    end

    -- Safety: variant spell with no variant configured — skip
    if not entry.var then
        local scanSpells = BfBot.Scan.GetCastableSpells(entry.casterSprite)
        local spellScan = scanSpells and scanSpells[entry.resref]
        if spellScan and spellScan.hasVariants == 1 then
            BfBot.Exec._LogEntry("SKIP",
                entry.casterName .. " -> " .. entry.spellName
                .. " (variant spell — no variant configured)")
            BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
            BfBot.Exec._ProcessCasterEntry(slot, index + 1)
            return
        end
    end

    -- Quick Cast: toggle IA on/off per entry based on cheat flag.
    -- Preserves user priority order — no reordering by duration category.
    if caster.cheatBoundary > 0 then
        if entry.cheat and not caster.cheatApplied then
            EEex_Action_QueueResponseStringOnAIBase(
                'ReallyForceSpellRES("BFBTCH",Myself)', entry.casterSprite)
            caster.cheatApplied = true
            BfBot.Exec._LogEntry("INFO", entry.casterName .. " Quick Cast ON")
        elseif not entry.cheat and caster.cheatApplied then
            EEex_Action_QueueResponseStringOnAIBase(
                'ReallyForceSpellRES("BFBTCR",Myself)', entry.casterSprite)
            caster.cheatApplied = false
            BfBot.Exec._LogEntry("INFO", entry.casterName .. " Quick Cast OFF")
        end
    end

    -- Cast the spell or use the item
    local advanceAction = string.format('EEex_LuaAction("BfBot.Exec._Advance(%d)")', slot)

    if entry.kind == "itm" then
        -- Items: queue UseItem(resref, target). Engine handles slot lookup,
        -- destruction (potions), and charge decrement (wand-like items).
        local useAction = string.format('UseItem("%s",%s)', entry.resref, entry.targetObj)
        EEex_Action_QueueResponseStringOnAIBase(useAction, entry.casterSprite)
        EEex_Action_QueueResponseStringOnAIBase(advanceAction, entry.casterSprite)
        BfBot.Exec._LogEntry("CAST",
            entry.casterName .. " -> " .. entry.spellName .. " (item) -> " .. entry.targetName)
        BfBot.Exec._castCount = BfBot.Exec._castCount + 1

    elseif entry.var then
        -- Variant spell path: consume parent spell slot, then cast the variant
        -- directly via ReallyForceSpellRES (variant SPL is not in the spellbook)
        if not BfBot.Exec._ConsumeSpellSlot(entry.casterSprite, entry.resref) then
            BfBot.Exec._LogEntry("SKIP",
                entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName
                .. " (no slot for variant)")
            BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
            BfBot.Exec._ProcessCasterEntry(slot, index + 1)
            return
        end
        local varAction = string.format('ReallyForceSpellRES("%s",%s)', entry.var, entry.targetObj)
        EEex_Action_QueueResponseStringOnAIBase(varAction, entry.casterSprite)
        EEex_Action_QueueResponseStringOnAIBase(advanceAction, entry.casterSprite)
        BfBot.Exec._LogEntry("CAST",
            entry.casterName .. " -> " .. entry.spellName .. " [" .. entry.var .. "] -> " .. entry.targetName)
        BfBot.Exec._castCount = BfBot.Exec._castCount + 1
    else
        -- Normal path: queue SpellRES action (engine handles slot consumption)
        local spellAction = string.format('SpellRES("%s",%s)', entry.resref, entry.targetObj)
        EEex_Action_QueueResponseStringOnAIBase(spellAction, entry.casterSprite)
        EEex_Action_QueueResponseStringOnAIBase(advanceAction, entry.casterSprite)
        BfBot.Exec._LogEntry("CAST",
            entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName)
        BfBot.Exec._castCount = BfBot.Exec._castCount + 1
    end
end

--- Called by the engine via EEex_LuaAction after a caster's spell completes.
-- @param slot number: the caster's party slot (0-5)
function BfBot.Exec._Advance(slot)
    if BfBot.Exec._state ~= "running" then return end
    local caster = BfBot.Exec._casters[slot]
    if not caster or caster.done then return end

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

    BfBot.Exec._ProcessCasterEntry(slot, caster.index + 1)
end

--- Reset all execution state without dereferencing cached sprites.
--- Used to recover from save-reload mid-cast (issue #38), where _casters
--- holds freed CGameSprite pointers from the pre-reload party. Calling
--- into the engine on those pointers would segfault — clear the table
--- first, never touch caster.sprite. Caller is responsible for closing
--- the exec log (see Stop / _Complete recovery branches); this keeps the
--- function side-effect free so the in-game test suite can capture its
--- own output to the log around each subtest.
function BfBot.Exec._HardReset()
    BfBot.Exec._state         = "idle"
    BfBot.Exec._casters       = {}
    BfBot.Exec._activeCasters = 0
    BfBot.Exec._castCount     = 0
    BfBot.Exec._skipCount     = 0
    BfBot.Exec._totalEntries  = 0
    BfBot.Exec._qcMode        = 0
    BfBot.Exec._lastProgressGameTime = nil
end

--- Detect stale execution state from a save reload mid-cast.
--- After loading a save while casting, _casters[].sprite still holds
--- freed CGameSprite pointers from the pre-reload party. We can't safely
--- compare sprite identity directly — EEex returns a fresh userdata
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
--- unchanged — Stop's cleanup loop must independently re-resolve sprites
--- from the portrait so it doesn't dereference cached caster.sprite.
--- @return boolean: true if state is "running" but at least one caster's
---     cached name no longer matches the current portrait at that slot.
function BfBot.Exec._IsStateStale()
    if BfBot.Exec._state ~= "running" then return false end

    for slot, caster in pairs(BfBot.Exec._casters) do
        if caster.name then
            local fresh = EEex_Sprite_GetInPortrait(slot)
            local freshName = fresh and BfBot._GetName(fresh) or nil
            if freshName ~= caster.name then return true end
        end
    end

    return false
end

--- Strip lingering quick-cast (BFBTCH) buffs from every caster. Re-resolves each
--- sprite from its portrait slot rather than dereferencing cached caster.sprite —
--- that userdata wraps a freed CGameSprite after a save reload (issue #38), and
--- pcall does NOT catch the engine-level access violation. BFBTCR is a no-op on a
--- target without an active BFBTCH, so this is safe even if the slot now holds a
--- different character. Shared by _Complete, Stop, and _ForceComplete.
function BfBot.Exec._StripCheatBuffs()
    for slot, caster in pairs(BfBot.Exec._casters) do
        if caster.cheatApplied then
            local sprite = EEex_Sprite_GetInPortrait(slot)
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
    if BfBot.Exec._IsStateStale() then
        BfBot.Exec._HardReset()
        BfBot._CloseLog()
        return
    end

    -- Clean up lingering cheat buffs — re-resolve sprite from portrait,
    -- never dereference cached caster.sprite (see Stop() rationale).
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
--- same way _Complete/Stop do — re-resolving each sprite from its portrait slot,
--- never dereferencing cached caster.sprite (it may wrap a freed CGameSprite
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

--- Start executing a buff queue with parallel per-caster casting.
-- @param queue array of {caster=0-5, spell="RESREF", target="self"|"all"|1-6}
-- @return true if started, false + reason string if not
function BfBot.Exec.Start(queue, qcMode)
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

    -- Sort caster slots for deterministic display order
    local slots = {}
    for slot, _ in pairs(byCaster) do table.insert(slots, slot) end
    table.sort(slots)

    for _, slot in ipairs(slots) do
        local entries = byCaster[slot]
        local sprite = entries[1].casterSprite
        local name = entries[1].casterName

        -- Quick Cast: cheatBoundary > 0 means this caster has cheat entries.
        -- IA toggles on/off per entry — no reordering by duration.
        local cheatBoundary = 0
        if BfBot.Exec._qcMode > 0 then
            for i, e in ipairs(entries) do
                if e.cheat then cheatBoundary = i end
            end
        end

        BfBot.Exec._casters[slot] = {
            queue = entries,
            index = 0,
            done = false,
            sprite = sprite,
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
    for _, slot in ipairs(slots) do
        BfBot.Exec._ProcessCasterEntry(slot, 1)
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

    -- Clean up lingering cheat buffs. Re-resolve the sprite from the
    -- current portrait slot rather than using cached caster.sprite — that
    -- userdata wraps a freed CGameSprite pointer if the user reloaded a
    -- save mid-cast (issue #38), and pcall does NOT catch the access
    -- violation that engine calls would trigger on the freed pointer.
    -- This re-resolution is safe even when _IsStateStale missed a same-
    -- party reload: BFBTCR is a no-op on targets without an active BFBTCH.
    BfBot.Exec._StripCheatBuffs()

    BfBot.Exec._LogEntry("INFO", "Stopped by user")
    BfBot._Print("[BuffBot] === Execution Stopped ===")
    BfBot._Print(string.format("[BuffBot]   Cast: %d | Skipped: %d",
        BfBot.Exec._castCount, BfBot.Exec._skipCount))
    BfBot._CloseLog()
end

--- Paranoid safety net: remove orphaned BFBTCH effects from any party member.
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

    -- Watchdog: force-complete a run that has stopped making progress. In
    -- multiplayer, casters controlled by another player never fire their
    -- _Advance callback (the queued SpellRES + EEex_LuaAction live only in this
    -- machine's local action list and are not networked), so _activeCasters
    -- never reaches 0 and the status would stay stuck on "casting" forever.
    -- This also covers any other cause of a wedged caster chain. _NoteProgress()
    -- bumps the timer on every queued cast and every advance, so a healthy run
    -- never trips it; only a genuine stall (no progress anywhere for the whole
    -- timeout) force-completes. The real MP fix is filtering casters to
    -- locally-controlled characters — this is the hard safety net underneath it.
    if BfBot.Exec._state == "running" then
        -- Measure progress in GAME time (frozen while paused) so a paused-but-
        -- healthy buff run is never force-killed. Only trip when the game has
        -- actually advanced _WATCHDOG_TIMEOUT_GAMETICKS with no forward progress.
        local gtNow = BfBot.Exec._GetGameTime()
        local gtLast = BfBot.Exec._lastProgressGameTime
        if gtNow and gtLast and (gtNow - gtLast) >= BfBot.Exec._WATCHDOG_TIMEOUT_GAMETICKS then
            BfBot.Exec._ForceComplete(string.format(
                "Watchdog: no cast progress for %d game-ticks — force-completing. A "
                .. "caster's chain never advanced (e.g. a multiplayer character "
                .. "controlled by another player). Cast again if buffing is incomplete.",
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
            local hasCheat = BfBot.Exec._HasActiveEffect(sprite, "BFBTCH")
            if hasCheat then
                pcall(function()
                    EEex_Action_QueueResponseStringOnAIBase(
                        'ReallyForceSpellRES("BFBTCR",Myself)', sprite)
                end)
                -- Open exec log briefly to persist the warning to disk
                BfBot._OpenLogAppend(BfBot.Exec._logFile)
                BfBot.Exec._LogEntry("WARN",
                    "Safety net: removed orphaned BFBTCH from " .. BfBot._GetName(sprite))
                BfBot._CloseLog()
            end
        end
    end
end

--- Get current execution state.
function BfBot.Exec.GetState()
    return BfBot.Exec._state
end

--- Get execution log entries.
function BfBot.Exec.GetLog()
    return BfBot.Exec._log
end
