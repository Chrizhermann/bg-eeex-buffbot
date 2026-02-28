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

--- Log an execution event.
function BfBot.Exec._LogEntry(type, msg)
    table.insert(BfBot.Exec._log, { type = type, msg = msg })
    BfBot._Print("[BuffBot] " .. type .. ": " .. msg)
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
            table.insert(results, {
                targetObj = "Player" .. target,
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
                    table.insert(results, {
                        targetObj = "Player" .. (i + 1),
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
            local durCat = classResult and classResult.durCat or "short"
            isCheat = (durCat == "permanent" or durCat == "long")
        end

        for _, tgt in ipairs(targets) do
            table.insert(byCaster[casterSlot], {
                casterSlot = casterSlot,
                casterSprite = casterSprite,
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
            })
            totalEntries = totalEntries + 1
        end

        ::continue::
    end

    if totalEntries == 0 then
        return nil, "no valid entries after expansion"
    end

    -- When qcMode=1 (long only), sort cheat entries before normal entries per caster
    if qcMode == 1 then
        for slot, entries in pairs(byCaster) do
            local cheatEntries = {}
            local normalEntries = {}
            for _, e in ipairs(entries) do
                if e.cheat then
                    table.insert(cheatEntries, e)
                else
                    table.insert(normalEntries, e)
                end
            end
            local merged = {}
            for _, e in ipairs(cheatEntries) do table.insert(merged, e) end
            for _, e in ipairs(normalEntries) do table.insert(merged, e) end
            byCaster[slot] = merged
        end
    end

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
    if BfBot.Exec._HasActiveEffect(targetSprite, entry.resref) then
        BfBot.Exec._LogEntry("SKIP", label .. " (already active)")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        return false
    end

    -- SPLSTATE said active but effect list disagrees — old logic would have falsely skipped
    if splstatePositive then
        BfBot.Exec._LogEntry("INFO", label .. " (splstate false positive caught)")
    end

    return true
end

--- Process a caster's queue entry at the given index.
-- Each caster runs their own chain independently.
function BfBot.Exec._ProcessCasterEntry(slot, index)
    local caster = BfBot.Exec._casters[slot]
    if not caster then return end

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

    -- Quick Cast: apply cheat buff before first cheat entry that passes pre-flight
    if caster.cheatBoundary > 0 and not caster.cheatApplied and entry.cheat then
        EEex_Action_QueueResponseStringOnAIBase(
            'ApplySpellRES("BFBTCH",Myself)', entry.casterSprite)
        caster.cheatApplied = true
        BfBot.Exec._LogEntry("INFO", entry.casterName .. " Quick Cast ON")
    end

    -- Quick Cast: remove cheat buff at cheat/normal boundary
    -- Use > instead of == to handle skipped entries at the boundary
    if index > caster.cheatBoundary and caster.cheatApplied then
        EEex_Action_QueueResponseStringOnAIBase(
            'ApplySpellRES("BFBTCR",Myself)', entry.casterSprite)
        caster.cheatApplied = false
        BfBot.Exec._LogEntry("INFO", entry.casterName .. " Quick Cast OFF")
    end

    -- Build BCS action strings
    local spellAction = string.format('SpellRES("%s",%s)', entry.resref, entry.targetObj)
    local advanceAction = string.format('EEex_LuaAction("BfBot.Exec._Advance(%d)")', slot)

    -- Queue both on the caster: spell first, then our callback
    EEex_Action_QueueResponseStringOnAIBase(spellAction, entry.casterSprite)
    EEex_Action_QueueResponseStringOnAIBase(advanceAction, entry.casterSprite)

    BfBot.Exec._LogEntry("CAST",
        entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName)
    BfBot.Exec._castCount = BfBot.Exec._castCount + 1
end

--- Called by the engine via EEex_LuaAction after a caster's spell completes.
-- @param slot number: the caster's party slot (0-5)
function BfBot.Exec._Advance(slot)
    if BfBot.Exec._state ~= "running" then return end
    local caster = BfBot.Exec._casters[slot]
    if not caster or caster.done then return end
    BfBot.Exec._ProcessCasterEntry(slot, caster.index + 1)
end

--- Log execution summary and transition to "done" state.
function BfBot.Exec._Complete()
    -- Clean up lingering cheat buffs
    for slot, caster in pairs(BfBot.Exec._casters) do
        if caster.cheatApplied and caster.sprite then
            pcall(function()
                EEex_Action_QueueResponseStringOnAIBase(
                    'ApplySpellRES("BFBTCR",Myself)', caster.sprite)
            end)
            caster.cheatApplied = false
        end
    end

    BfBot.Exec._state = "done"
    local cast = BfBot.Exec._castCount
    local skip = BfBot.Exec._skipCount
    local total = cast + skip
    BfBot.Exec._LogEntry("DONE",
        string.format("Total: %d | Cast: %d | Skipped: %d", total, cast, skip))
    BfBot._Print("[BuffBot] === Execution Complete ===")
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
    for _, slot in ipairs(slots) do
        BfBot.Exec._ProcessCasterEntry(slot, 1)
    end

    return true
end

--- Stop execution mid-queue.
function BfBot.Exec.Stop()
    if BfBot.Exec._state ~= "running" then
        BfBot._Print("[BuffBot] Not running.")
        return
    end
    BfBot.Exec._state = "stopped"

    -- Clean up lingering cheat buffs
    for slot, caster in pairs(BfBot.Exec._casters) do
        if caster.cheatApplied and caster.sprite then
            pcall(function()
                EEex_Action_QueueResponseStringOnAIBase(
                    'ApplySpellRES("BFBTCR",Myself)', caster.sprite)
            end)
            caster.cheatApplied = false
        end
    end

    BfBot.Exec._LogEntry("INFO", "Stopped by user")
    BfBot._Print("[BuffBot] === Execution Stopped ===")
    BfBot._Print(string.format("[BuffBot]   Cast: %d | Skipped: %d",
        BfBot.Exec._castCount, BfBot.Exec._skipCount))
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
