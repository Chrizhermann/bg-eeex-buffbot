-- ============================================================
-- BfBotExe.lua — Execution Engine (BfBot.Exec)
-- Parallel per-caster buff casting with EEex_LuaAction chaining
-- ============================================================

BfBot.Exec = {}

-- Never reset callback counters between runs or module reloads: old native
-- callbacks can remain queued while a replacement execution starts.
local function _nextCallbackToken(name)
    BfBot[name] = (BfBot[name] or 0) + 1
    return BfBot[name]
end

-- A stopped run can leave native actions queued. Each advance belongs to one
-- exact step, so a late callback can never advance a replacement run. Keep the
-- counter on the root namespace: module reloads must not recycle old tokens.
local function _advanceAction(key, caster)
    caster.advanceToken = _nextCallbackToken("_nextExecAdvanceToken")
    return string.format(
        'EEex_LuaAction("BfBot.Exec._Advance([[%s]],%d)")', key, caster.advanceToken)
end

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
BfBot.Exec._forceMode = 0           -- active-buff policy for the current run
                                    -- (0=skip active, 1=refresh low, 2=force all; issue #84)
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

-- ---- Remaining lifetime of an applied effect (issue #84) ----

BfBot.Exec._TICKS_PER_SECOND = 15

-- What a LIVE CGameEffect's m_durationType means. Measured in a BG2:EE
-- 2.7.3.0 + EEex v1.3.1 lab on 2026-10-24 (issue #84) by applying one effect
-- per encoded timing mode and reading the field back:
--
--   encoded 0 (seconds) -> 4096, m_duration = absolute deadline in ticks
--   encoded 10 (ticks)  -> 4096, same
--   encoded 4096        -> 4096, deadline kept as given
--   encoded 1           -> 1, m_duration = 0
--   encoded 9           -> 9, m_duration = 0
--   encoded 3 (delayed) -> 6, m_duration = when the DELAY ends
--   encoded 4 (delayed) -> 7 while delayed, then 1 once it fires
--
-- So only mode 4096 carries a readable remaining lifetime.
--
-- Do NOT mask a live m_durationType with 0xFF. That rule belongs to feature
-- blocks read out of a SPL or ITM; here it would turn 4096 into 0.
--
-- Mode 2 (while equipped) is precaution, not a measured case: the probe never
-- saw it reach m_timedEffectList. An equipped item's effect lives and dies
-- with the item, never on a timer BuffBot could refresh.
local _PERMANENT_TIMING = { [1] = true, [2] = true, [4] = true, [9] = true }

-- Delayed effects that have not fired yet. m_duration is the end of the
-- DELAY, not of the buff, so it must never be read as a remaining lifetime.
-- 6 goes on to a 4096 deadline, 7 to permanent.
local _PENDING_TIMING = { [6] = true, [7] = true }

--- Remaining lifetime of ONE applied effect, in gameplay seconds.
--- @return number: seconds left, or math.huge for permanent/pending/unreadable
--- @return string|nil: "perm", "pending", "unknown", or nil for a real deadline
function BfBot.Exec._EffectRemaining(effect, nowTicks)
    local ok, timing, deadline = pcall(function()
        return effect.m_durationType, effect.m_duration
    end)
    if not ok or type(timing) ~= "number" then return math.huge, "unknown" end
    if _PERMANENT_TIMING[timing] then return math.huge, "perm" end
    if _PENDING_TIMING[timing] then return math.huge, "pending" end
    if timing ~= 4096 or type(deadline) ~= "number"
        or type(nowTicks) ~= "number" then
        return math.huge, "unknown"
    end
    local seconds = (deadline - nowTicks) / BfBot.Exec._TICKS_PER_SECOND
    if seconds ~= seconds then return math.huge, "unknown" end  -- NaN
    -- The engine sweeps expired effects only once per second per actor, so an
    -- effect can sit up to 14 ticks past its deadline. Clamping at 0 keeps the
    -- default threshold (0) behaving exactly like the old boolean check.
    if seconds < 0 then return 0 end
    return seconds
end

--- Human-readable remaining lifetime for a log line. Deliberately English and
--- unlocalized: the exec log is a diagnostic file, not player-facing text.
---
--- Uses the SAME h/m/s staircase as BfBot.UI._FormatDuration, on purpose.
--- Both format the same engine duration seconds, and a log line is read right
--- beside the panel's Dur column and the option's label — when this printed
--- flat minutes, "threshold 60m 0s" next to an option saying "Under 1 hour
--- left" read like two different numbers and misled a reviewer into filing it
--- as a units bug. Sub-minute values keep a decimal, which _FormatDuration
--- has no use for but a near-expiry decision does.
function BfBot.Exec._FormatRemaining(seconds, detail)
    if detail == "perm" then return "permanent" end
    if detail == "pending" then return "delayed, not started" end
    if detail == "unknown" then return "unknown duration" end
    if type(seconds) ~= "number" then return "unknown duration" end
    if seconds == math.huge then return "permanent" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then
        if m > 0 then return string.format("%dh %dm left", h, m) end
        return string.format("%dh left", h)
    end
    if m > 0 then
        return string.format("%dm %ds left", m, math.floor(seconds % 60))
    end
    return string.format("%.1fs left", seconds)
end

--- Clamp a caller-supplied force mode to 0, 1 or 2. Anything else — a string
--- from a console call, a stale value from a hot-reloaded module — falls back
--- to 0, the conservative mode.
function BfBot.Exec._NormalizeForceMode(value)
    if value == 1 or value == 2 then return value end
    return 0
end

--- Remaining-duration threshold for the current run, in gameplay seconds.
--- A buff with at least this much left is skipped; anything below is cast
--- again. Always a finite number of seconds; 0 is the historical behavior.
--- @param forceMode number|nil: 0 skip active (default), 1 refresh low,
---        2 force all. Defaults to the run-scoped mode set by Exec.Start.
function BfBot.Exec._RefreshThreshold(forceMode)
    if forceMode == nil then forceMode = BfBot.Exec._forceMode or 0 end

    local configured = 0
    if BfBot.Persist and BfBot.Persist.GetRefreshBelow then
        local ok, value = pcall(BfBot.Persist.GetRefreshBelow)
        if ok and type(value) == "number" then configured = value end
    end
    -- Refresh Low is the panel's "use a sensible value even though the option
    -- is off" mode. It never overrides a configured threshold.
    if forceMode == 1 and configured <= 0 then
        return BfBot.REFRESH_LOW_SECONDS
    end
    return configured
end

--- Is the active-buff check off entirely for this run?
---
--- Force All is a hard override and deliberately NOT a threshold value
--- (Christopher, 2026-10-24, issue #84: "einfach force als Überschreibung").
--- Three things follow from that, and each is the reason it is its own flag:
---   * it is independent of `RefreshBelow` and works with the option off,
---   * it casts through PERMANENT effects (timing 1/2/4/9), which report no
---     remaining lifetime at all and which no finite threshold can reach,
---   * it needs no sentinel comparison, so the threshold stays a plain number
---     everywhere and a stray math.huge cannot silently re-enable skipping.
--- Wasted spell slots are accepted here by decision: a vanilla Stoneskin runs
--- twelve hours, long buffs routinely survive a rest, and re-casting one or
--- two of them unnecessarily is cheaper than guessing wrong. Do not add a
--- heuristic that weakens this, and do not ask the player to confirm it.
function BfBot.Exec._ForceAll(forceMode)
    if forceMode == nil then forceMode = BfBot.Exec._forceMode or 0 end
    return BfBot.Exec._NormalizeForceMode(forceMode) == 2
end

-- ---- The pending active-buff policy (what the NEXT run will use) ----
--
-- This lives here, not in BfBotUI, because the panel is being rebuilt (#81)
-- and the rebuild should only have to re-place a button, never carry logic or
-- state across. It also makes the policy reachable without a panel at all:
--   BfBot.Exec.SetForceMode(2)   -- from the console or another module
--
-- Not persisted, by design: a game restart returns to Skip, so nobody finds
-- their slots being spent by a setting they forgot they left on.
BfBot.Exec._forceSelection = 0

function BfBot.Exec.GetForceMode()
    return BfBot.Exec._NormalizeForceMode(BfBot.Exec._forceSelection)
end

function BfBot.Exec.SetForceMode(value)
    BfBot.Exec._forceSelection = BfBot.Exec._NormalizeForceMode(value)
    return BfBot.Exec._forceSelection
end

--- Skip active → refresh low → force all → skip active.
function BfBot.Exec.CycleForceMode()
    return BfBot.Exec.SetForceMode((BfBot.Exec.GetForceMode() + 1) % 3)
end

--- Does an active buff with `remaining` seconds left block a cast?
--- @param forceAll boolean|nil: when true nothing blocks, whatever is left.
function BfBot.Exec._ActiveBlocksCast(remaining, threshold, forceAll)
    if forceAll then return false end
    if remaining == nil then return false end
    -- Without a usable threshold, keep the conservative skip.
    if type(remaining) ~= "number" or type(threshold) ~= "number" then
        return true
    end
    return remaining >= threshold
end

--- Fold one more matched effect into a running result for the whole spell.
---
--- Effects with a readable deadline decide, and the LONGEST of them wins: a
--- spell counts as active until its longest-lived real effect is nearly gone,
--- so a short administrative marker never refreshes a buff that is still up.
---
--- Effects WITHOUT a readable deadline are not folded into that maximum, they
--- are only remembered as a fallback. Real spells routinely carry one: live
--- vanilla Armor (`SPWI102`, BG2:EE 2.7.3.0) applies op0/op142/op282 in mode
--- 4096 with a 45-minute deadline plus an op174 stuck in mode 7. Letting that
--- one effect win would report the whole buff as "never refresh" and the
--- threshold would do nothing on real spells. If NO effect has a readable
--- deadline the fallback is returned, which is math.huge and keeps the skip.
local function _foldRemaining(best, seconds, detail)
    local readable = (detail == nil and seconds < math.huge)
    if readable then
        if not best or not best.readable or seconds > best.remaining then
            return { remaining = seconds, detail = nil, readable = true }
        end
        return best
    end
    if best then return best end
    return { remaining = seconds, detail = detail, readable = false }
end

--- Remaining lifetime of a sprite's timed effects from a given spell resref.
--- @return number|nil: seconds left (math.huge = permanent/unreadable), or
---         nil when no effect from that resref is on the sprite
--- @return string|nil: "perm", "pending", "unknown", or nil
function BfBot.Exec._ActiveEffectRemaining(sprite, resref)
    if not sprite or type(resref) ~= "string" or resref == "" then return nil end
    -- Resource identity is case-insensitive, including modded child spells.
    resref = resref:upper()
    local now = BfBot.Exec._GetGameTime()
    local best
    local ok = pcall(function()
        EEex_Utility_IterateCPtrList(sprite.m_timedEffectList, function(effect)
            local effectRes = effect.m_sourceRes:get()
            if type(effectRes) == "string" and effectRes:upper() == resref then
                local seconds, detail = BfBot.Exec._EffectRemaining(effect, now)
                best = _foldRemaining(best, seconds, detail)
            end
        end)
    end)
    if not ok or not best then return nil end
    return best.remaining, best.detail
end

--- Boolean form, for callers that only ask "is anything from this resref on
--- the sprite" — the BFBTCH cheat-buff sweep, not the skip decision.
function BfBot.Exec._HasActiveEffect(sprite, resref)
    return BfBot.Exec._ActiveEffectRemaining(sprite, resref) ~= nil
end

--- Remaining lifetime of an item ability's effects, identified by the full
--- signature set (opcode/amount/flags) the ability applies. All signatures
--- must be present, exactly as the legacy boolean check required.
function BfBot.Exec._ActiveItemEffectRemaining(sprite, resref, signatures)
    if not sprite or type(resref) ~= "string" or resref == "" then return nil end
    if not signatures or #signatures == 0 then return nil end
    resref = resref:upper()
    local now = BfBot.Exec._GetGameTime()
    local matched, missing, best = {}, #signatures, nil
    local ok = pcall(function()
        EEex_Utility_IterateCPtrList(sprite.m_timedEffectList, function(effect)
            local effectRes = effect.m_sourceRes:get()
            if type(effectRes) ~= "string" or effectRes:upper() ~= resref then return end
            for i, sig in ipairs(signatures) do
                if not matched[i] and effect.m_effectId == sig.opcode
                    and effect.m_effectAmount == sig.amount
                    and effect.m_dWFlags == sig.flags then
                    matched[i] = true
                    missing = missing - 1
                    local seconds, detail =
                        BfBot.Exec._EffectRemaining(effect, now)
                    best = _foldRemaining(best, seconds, detail)
                end
            end
        end)
    end)
    if not ok or missing ~= 0 or not best then return nil end
    return best.remaining, best.detail
end

function BfBot.Exec._HasActiveItemEffect(sprite, resref, signatures)
    return BfBot.Exec._ActiveItemEffectRemaining(sprite, resref, signatures)
        ~= nil
end

--- Check whether any of the supplied SPLSTATE IDs is active on a sprite.
--- A positive is only a hint because modded spells may share state IDs.
function BfBot.Exec._HasAnySpellState(sprite, stateIDs)
    if not sprite or not stateIDs then return false end
    for _, stateID in ipairs(stateIDs) do
        local ok, active = pcall(function()
            return sprite:getSpellState(stateID)
        end)
        if ok and active then return true end
    end
    return false
end

--- Remaining lifetime of a spell's own active SPLSTATE marker on the target.
--- Matching source resref alone is deliberately insufficient: other permanent
--- administrative effects from the same spell may outlive the real buff.
--- @return number|nil: seconds left (math.huge = permanent/unreadable), or nil
--- @return string|nil: "perm", "pending", "unknown", or nil
function BfBot.Exec._ActiveStateMarkerRemaining(sprite, resref, stateIDs)
    if not sprite or type(resref) ~= "string" or resref == ""
        or not stateIDs or #stateIDs == 0 then
        return nil
    end
    resref = resref:upper()

    local wanted = {}
    for _, stateID in ipairs(stateIDs) do wanted[stateID] = true end

    local now = BfBot.Exec._GetGameTime()
    local best
    local ok = pcall(function()
        EEex_Utility_IterateCPtrList(sprite.m_timedEffectList, function(effect)
            local effectRes = effect.m_sourceRes:get()
            local opcode = effect.m_effectId
            local stateID = effect.m_dWFlags
            if type(effectRes) == "string" and effectRes:upper() == resref
                and (opcode == 282 or opcode == 328)
                and wanted[stateID] then
                local seconds, detail = BfBot.Exec._EffectRemaining(effect, now)
                best = _foldRemaining(best, seconds, detail)
            end
        end)
    end)
    if not ok or not best then return nil end
    return best.remaining, best.detail
end

function BfBot.Exec._HasActiveStateMarker(sprite, resref, stateIDs)
    return BfBot.Exec._ActiveStateMarkerRemaining(sprite, resref, stateIDs)
        ~= nil
end

--- Programmatically consume one spell slot for a given spell resref.
--- Clears the memorized bit on the first available entry matching the resref.
--- Used by the variant spell path to consume the parent spell slot before
--- casting the unmemorized variant via SpellNoDecRES.
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
            if sid:upper() == resref:upper() and bit.band(spell.m_flags, 1) ~= 0 then
                spell.m_flags = bit.band(spell.m_flags, bit.bnot(1))
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

--- Normalize a raw builder entry's repeat count at the execution boundary.
--- Persist owns the canonical validator; the local strict fallback keeps
--- raw/console queues safe if that module or helper is unavailable.
local function _normalizeSpellRepeat(value)
    if BfBot.Persist
        and type(BfBot.Persist._NormalizeSpellRepeat) == "function" then
        return BfBot.Persist._NormalizeSpellRepeat(value)
    end
    local maxRepeats = BfBot.MAX_SPELL_REPEATS
    if type(value) ~= "number" or value ~= value
        or type(maxRepeats) ~= "number"
        or value == math.huge or value == -math.huge
        or value ~= math.floor(value)
        or value < 1 or value > maxRepeats then
        return 1
    end
    return value
end

--- Build per-caster execution queues from user input.
-- userQueue: array of {caster=0-5, spell="RESREF",
-- target="self"|"all"|1-6, rep=1..BfBot.MAX_SPELL_REPEATS}.
-- Entries may alternatively carry a pre-built caster ref instead of a slot:
-- {casterRef={kind="party",slot=N} | {kind="summon",oid=N,name=S}, ...} —
-- the seam the summon queue builders use (issue #19).
-- Returns: {[casterKey] = {entries}} grouped by _CasterKey, or
-- nil + reasonCode + detail.
function BfBot.Exec._BuildQueue(userQueue, qcMode)
    if not userQueue or #userQueue == 0 then
        return nil, "reason.exec.empty_queue", {}
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
        -- A selected variant is cast directly via ReallyForceSpellRES, so its
        -- own target type — not the opcode-214 wrapper's — decides whether
        -- "all" means one area cast or one cast per party member (#82).
        if entry.var and BfBot.Class and BfBot.Class.FindVariant then
            local variant = BfBot.Class.FindVariant(spellData.variants, entry.var)
            if variant and variant.isAoE ~= nil then
                isAoE = (variant.isAoE == 1)
            end
        end
        local splstates = classResult and classResult.splstates or {}
        local spellName = spellData.name or resref
        local kind = spellData.kind or "spl"

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

        -- Resolve final targets before expanding attempts. This makes the
        -- order target-major (A,A,B,B for two targets at rep=2), while an
        -- AoE "all" target still resolves once and therefore casts exactly
        -- rep times total. Repeat count is deliberately independent of the
        -- scanner's current slot count: every attempt reaches _CheckEntry at
        -- execution time and can skip individually as slots/effects change.
        local repeatCount = _normalizeSpellRepeat(entry.rep)

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
        if kind == "itm" or (BfBot.Fast and BfBot.Fast.run) then
            -- Items and accelerated native runs never use the IA helper.
            -- This also covers summons joining after Fast.Start's queue copy.
            isCheat = false
        end

        for _, tgt in ipairs(targets) do
            for _ = 1, repeatCount do
                -- No casterSprite on the entry: exec-time code must resolve
                -- fresh via _ResolveCaster every step, never through
                -- build-time userdata. The literal creates a distinct
                -- top-level table for every attempt; read-only casterRef,
                -- targetSprite, splstates, and stateMarkersByResref references
                -- may be shared.
                table.insert(byCaster[casterKey], {
                    casterRef = casterRef,
                    casterName = casterName,
                    resref = resref,
                    kind = kind,
                    itemResref = spellData.itemResref,
                    abilityIdx = spellData.abilityIdx,
                    itemEffects = spellData.itemEffects,
                    itemMultiAbility = spellData.itemMultiAbility,
                    leafResrefs = spellData.leafResrefs,
                    spellName = spellName,
                    targetObj = tgt.targetObj,
                    targetSlot = tgt.targetSlot,
                    targetSprite = tgt.targetSprite,
                    targetName = tgt.targetName,
                    splstates = splstates,
                    stateMarkersByResref = kind == "spl"
                        and spellData.stateMarkersByResref or nil,
                    isAoE = isAoE,
                    cheat = isCheat,
                    var = entry.var,
                    -- 5E Spellcasting: build-time marker that this spell is
                    -- cast through an upstream wrapper (read-only, shared).
                    -- The live wrapper is re-read from the fresh scan at
                    -- cast time; this only gates the refresh wait.
                    d5 = kind == "spl" and spellData.d5 or nil,
                })
                totalEntries = totalEntries + 1
            end
        end

        ::continue::
    end

    if totalEntries == 0 then
        return nil, "reason.exec.no_valid_entries", {}
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
        local why = "no slot"
        if spellData and spellData.d5 and BfBot.FiveE
            and BfBot.FiveE.UnavailableReason then
            local okWhy, detail = pcall(
                BfBot.FiveE.UnavailableReason, casterSprite, spellData)
            if okWhy and detail then why = detail end
        end
        BfBot.Exec._LogEntry("SKIP", label .. " (" .. why .. ")")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        return false
    end

    -- Interactive item powers require a player choice. Refuse before any
    -- equip/use action is queued, including manually added classifier misses.
    if entry.kind == "itm" and spellData.requiresChoice == 1 then
        local reason = BfBot.L10N and BfBot.L10N.Get("reason.item.manual_selection")
            or "This item requires manual selection"
        BfBot.Exec._LogEntry("SKIP", label .. " (" .. reason .. ")")
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

    -- Effect list check. Catalog entries always carry non-empty leafResrefs
    -- (see BfBotScn.lua); the fallback covers hand-built Exec.Start queues.
    local markerMap = entry.kind ~= "itm" and entry.stateMarkersByResref or nil
    local checkResrefs = {}
    if entry.var then
        -- Variants always override: the variant resref produces the actual
        -- buff effects, not the selection spell's parent/leaf resources.
        checkResrefs[1] = entry.var
    else
        local seenResrefs = {}
        -- A wrapper may apply a short parent marker before its child begins
        -- producing effects (for example True Seeing). Include that parent
        -- when it declares a marker, then add every concrete child source.
        -- 5E Spellcasting rows keep their spellbook resref (MEM) while the
        -- wrapper delivers CAST, so the parent that can carry a marker is
        -- CAST, not the row's own resref.
        local parent = (entry.d5 and entry.d5.cast) or entry.resref
        if markerMap and markerMap[parent] then
            checkResrefs[#checkResrefs + 1] = parent
            seenResrefs[parent] = true
        end
        for _, r in ipairs(entry.leafResrefs or { entry.resref }) do
            if not seenResrefs[r] then
                checkResrefs[#checkResrefs + 1] = r
                seenResrefs[r] = true
            end
        end
    end

    -- Active-buff policy for this run (issue #84). The threshold is seconds;
    -- 0 is the historical behavior, where every active buff skips whatever is
    -- left of it. forceAll is the hard override and outranks the threshold.
    -- Every other precondition above and below stays in force.
    local threshold = BfBot.Exec._RefreshThreshold()
    local forceAll = BfBot.Exec._ForceAll()

    local foundActive = nil       -- resref whose buff blocks the cast
    local foundRemaining = nil    -- its remaining lifetime, for the log line
    local foundDetail = nil
    local refreshing = nil        -- resref/remaining of a below-threshold buff
    local splstatePositive = false

    -- Items deliberately retain their legacy fast-negative + source-resref
    -- behavior. Their ability semantics differ from SPL delivery, and this
    -- issue's marker hardening is spell-only.
    if entry.kind == "itm" and entry.splstates and #entry.splstates > 0 then
        splstatePositive = BfBot.Exec._HasAnySpellState(
            targetSprite, entry.splstates)
        if not splstatePositive then return true end
    end

    for _, r in ipairs(checkResrefs) do
        local markerStates = markerMap and markerMap[r] or nil

        -- Compatibility for direct hand-built queue entries that predate the
        -- per-resref marker map. Parent markers must never be borrowed by a
        -- wrapper leaf or selected variant.
        if not markerMap and entry.kind ~= "itm" and not entry.var
            and #checkResrefs == 1 and r == entry.resref then
            markerStates = entry.splstates
        end

        local remaining, detail = nil, nil
        if markerStates and #markerStates > 0 then
            local stateActive = BfBot.Exec._HasAnySpellState(
                targetSprite, markerStates)
            if stateActive then
                splstatePositive = true
                remaining, detail = BfBot.Exec._ActiveStateMarkerRemaining(
                    targetSprite, r, markerStates)
            end
            -- No declared state active is a fast negative for this resref.
        elseif entry.kind == "itm" and entry.itemMultiAbility == 1
            and r == entry.itemResref then
            remaining, detail = BfBot.Exec._ActiveItemEffectRemaining(
                targetSprite, r, entry.itemEffects)
        else
            remaining, detail =
                BfBot.Exec._ActiveEffectRemaining(targetSprite, r)
        end

        -- A hot-reloaded older module (or a test stub) can still answer with
        -- a boolean. Fold any non-number answer: truthy means "active, but
        -- its lifetime is unknown", which keeps the conservative skip, and
        -- falsy means not active. `false ~= nil` in Lua, so the falsy case
        -- has to be spelled out.
        if remaining ~= nil and type(remaining) ~= "number" then
            if remaining then
                remaining, detail = math.huge, "unknown"
            else
                remaining, detail = nil, nil
            end
        end

        if remaining ~= nil then
            if BfBot.Exec._ActiveBlocksCast(remaining, threshold, forceAll) then
                -- Longest-lived blocker wins, so the log names the buff that
                -- actually keeps this entry from casting.
                if not foundActive or remaining > foundRemaining then
                    foundActive, foundRemaining, foundDetail = r, remaining, detail
                end
            elseif not refreshing or remaining < refreshing.remaining then
                refreshing = { resref = r, remaining = remaining }
            end
        end
    end

    if foundActive then
        BfBot.Exec._LogEntry("SKIP", label .. " (already active: " .. foundActive
            .. ", " .. BfBot.Exec._FormatRemaining(foundRemaining, foundDetail)
            .. ")")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        return false
    end

    if refreshing then
        local why = forceAll and "force all"
            or ("threshold "
                .. (BfBot.Exec._FormatRemaining(threshold):gsub(" left", "")))
        BfBot.Exec._LogEntry("INFO", label .. " (refreshing: " .. refreshing.resref
            .. ", " .. BfBot.Exec._FormatRemaining(refreshing.remaining)
            .. ", " .. why .. ")")
    end

    -- SPLSTATE said active but effect list disagrees — old logic would have falsely skipped.
    -- `refreshing` means the effect list AGREED and the threshold is what let the
    -- cast through, so claiming a false positive there would be wrong (issue #84).
    if splstatePositive and not refreshing then
        BfBot.Exec._LogEntry("INFO", label .. " (splstate false positive caught, checked " .. table.concat(checkResrefs, ",") .. ")")
    end

    return true
end

-- Item actions use live slots, never stored slots from a preset. XEquipItem
-- EQUIP swaps its source and destination; UNEQUIP only removes effects and
-- must NOT be used to move gear back. Never target backpack slot 18: BG2EE
-- 2.7.3 writes past its quick-item array there and corrupts the sprite's name.
local function _itemAt(sprite, slot)
    local item = sprite.m_equipment.m_items:get(slot)
    return item, item and item.pRes.resref:get() or ""
end

local function _uniqueItem(sprite, resref)
    if resref == "" then return true end
    local count = 0
    for slot = 0, 38 do
        local _, r = _itemAt(sprite, slot)
        if r == resref then count = count + 1 end
    end
    return count == 1
end

local function _itemCallback(sprite, fn, slot, token, attempt)
    EEex_Action_QueueResponseStringOnAIBase(string.format(
        'EEex_LuaAction("BfBot.Exec.%s(%d,%d,%d)")', fn, slot, token, attempt or 0), sprite)
end

local function _swapContext(slot, token)
    local sprite = EEex_Sprite_GetInPortrait(slot)
    if not sprite then return end
    local journal = BfBot.Persist.GetItemSwap(sprite)
    if not journal or journal.token ~= token then return end
    return sprite, journal
end

local function _swapMatches(sprite, journal, restored)
    local _, pack = _itemAt(sprite, journal.pack)
    local _, equip = _itemAt(sprite, journal.equip)
    if restored then
        -- Depleted items can be destroyed by the engine after their last use.
        return (pack == journal.item or pack == "") and equip == journal.previous
    end
    return (equip == journal.item or equip == "") and pack == journal.previous
end

local function _swapCaster(slot, token)
    local key = "p" .. slot
    local caster = BfBot.Exec._casters[key]
    if caster and caster.itemToken == token then return caster, key end
end

function BfBot.Exec._ItemRestored(slot, token)
    local sprite, journal = _swapContext(slot, token)
    if not sprite then return end
    if not _swapMatches(sprite, journal, true) then
        journal.phase = "failed"
        BfBot._Warn("Item equipment could not be restored; leaving recovery record")
        return
    end
    -- Preserve a manual weapon selection made during the run. XEquipItem
    -- itself selects the temporary weapon, or can reset it to fists on return.
    local selectedWeapon = sprite.m_equipment.m_selectedWeapon
    if journal.weapon ~= nil and (selectedWeapon == journal.equip
        or selectedWeapon == journal.weapon or selectedWeapon == 10) then
        EEex_Action_QueueResponseStringOnAIBase(string.format(
            'SelectWeaponAbility(%d,%d)', journal.weapon, journal.weaponAbility), sprite)
    end
    BfBot.Persist.SetItemSwap(sprite, nil)
    local caster, key = _swapCaster(slot, token)
    if caster then
        caster.itemToken = nil
        if BfBot.Exec._state == "running" and not caster.done then
            -- Put the next step after weapon-selection restoration.
            EEex_Action_QueueResponseStringOnAIBase(_advanceAction(key, caster), sprite)
        end
    end
end

-- Called after use, Stop, or recovery after loading a save. It only exchanges
-- slots when both still contain our expected items; a player's manual change
-- never becomes an instruction to move unrelated equipment.
function BfBot.Exec._RestoreItemAtSlot(slot, token)
    local sprite, journal = _swapContext(slot, token)
    if not sprite or journal.phase == "restoring" then return end
    journal.recoveryQueued = nil
    if _swapMatches(sprite, journal, true) then
        return BfBot.Exec._ItemRestored(slot, token)
    end
    if not _swapMatches(sprite, journal, false)
        or not _uniqueItem(sprite, journal.previous) then
        if journal.phase ~= "failed" then
            BfBot._Warn("Equipment changed during item use; automatic restore skipped")
        end
        journal.phase = "failed"
        return
    end
    local _, equip = _itemAt(sprite, journal.equip)
    local move, destination
    if equip == journal.item and not _uniqueItem(sprite, journal.item) then return end
    if journal.previous ~= "" then
        -- Reverse the exchange by equipping the displaced item. This restores
        -- both exact slots without targeting the unsafe first backpack slot.
        move, destination = journal.previous, journal.equip
    elseif equip == journal.item then
        if journal.pack == 18 then
            -- Native XEquipItem's empty-resref form selects the first empty
            -- backpack slot. _swapMatches proved slot 18 empty, so the source
            -- is unambiguous and exchanging it with equip restores both slots.
            move, destination = "", journal.equip
        else
            move, destination = journal.item, journal.pack
        end
    end
    journal.phase = "restoring"
    journal.restoreAttempt = (journal.restoreAttempt or 0) + 1
    if move then
        EEex_Action_QueueResponseStringOnAIBase(string.format(
            'XEquipItem("%s",Myself,%d,1)', move, destination), sprite)
    end
    _itemCallback(sprite, "_ItemRestored", slot, token)
end

-- Two queued boundaries place retries AFTER an outstanding native exchange,
-- including one appended by an earlier Lua callback. An attempt counter makes
-- duplicate checks harmless. This also recovers if movement cleared the queue
-- between the exchange and its completion callback.
function BfBot.Exec._RetryItemRestore(slot, token, attempt)
    local sprite, journal = _swapContext(slot, token)
    if not sprite or journal.phase ~= "restoring"
        or journal.restoreAttempt ~= attempt then return end
    journal.phase = "using"
    BfBot.Exec._RestoreItemAtSlot(slot, token)
end

function BfBot.Exec._CheckItemRecovery(slot, token)
    local sprite, journal = _swapContext(slot, token)
    if not sprite then return end
    journal.recoveryQueued = nil
    if journal.phase == "restoring" then
        _itemCallback(sprite, "_RetryItemRestore", slot, token, journal.restoreAttempt)
    else
        BfBot.Exec._RestoreItemAtSlot(slot, token)
    end
end

function BfBot.Exec._AfterItemEquip(slot, token)
    local sprite, journal = _swapContext(slot, token)
    if not sprite or journal.phase ~= "equipping" then return end
    local caster, key = _swapCaster(slot, token)
    local entry = caster and caster.queue[caster.index]
    local _, equipped = _itemAt(sprite, journal.equip)
    local usable = caster and not caster.done and BfBot.Exec._state == "running"
        and equipped == journal.item and _swapMatches(sprite, journal, false)
    if usable and BfBot.Persist.GetPref("CombatInterrupt") ~= 0
        and BfBot.Exec._DetectCombat() then
        BfBot.Exec.Stop()
        usable = false
    end
    -- Fresh identification, charges, targets and active effects after moving.
    if usable then
        usable = BfBot.Exec._CheckEntry(entry, sprite)
    elseif entry and BfBot.Exec._state == "running" then
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        BfBot.Exec._LogEntry("SKIP", entry.spellName .. " (equipment exchange failed)")
    end
    if usable then
        journal.phase = "using"
        EEex_Action_QueueResponseStringOnAIBase(string.format(
            'UseItemSlotAbility(%s,%d,%d)', entry.targetObj,
            journal.equip, entry.abilityIdx or 0), sprite)
        BfBot.Exec._castCount = BfBot.Exec._castCount + 1
        BfBot.Exec._LogEntry("CAST", entry.casterName .. " -> "
            .. entry.spellName .. " (equipped item) -> " .. entry.targetName)
        _itemCallback(sprite, "_RestoreItemAtSlot", slot, token)
    else
        BfBot.Exec._RestoreItemAtSlot(slot, token)
    end
end

function BfBot.Exec._RecoverItemSwaps()
    if not BfBot.Persist.GetItemSwap then return end
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        local journal = sprite and BfBot.Persist.GetItemSwap(sprite)
        if journal then
            local caster = BfBot.Exec._casters["p" .. slot]
            local active = BfBot.Exec._state == "running" and caster
                and caster.itemToken == journal.token and journal.token ~= nil
            if not active then
                if not journal.token then
                    journal.token = _nextCallbackToken("_nextExecItemToken")
                end
                -- Run the check behind any already queued forward exchange.
                -- Stop can happen before XEquipItem itself has executed.
                if not journal.recoveryQueued
                    or Infinity_GetClockTicks() - journal.recoveryQueued > 4000 then
                    journal.recoveryQueued = Infinity_GetClockTicks()
                    _itemCallback(sprite, "_CheckItemRecovery", slot, journal.token)
                end
            end
        end
    end
end

function BfBot.Exec._QueueItem(key, caster, entry, row, sprite, advanceAction)
    if not row or row.kind ~= "itm" or row.itemSlot == nil then return false end
    if BfBot.Persist.GetItemSwap(sprite) then return false end
    local slot = row.itemSlot
    local mode = BfBot.Persist.GetPref("ItemUseMode")
    if mode == "swap" and slot >= 18 and slot <= 33 and row.itemType ~= 9 then
        local journal, reason = BfBot.Scan._PlanItemSwap(sprite, row)
        journal = BfBot.Persist._ValidateItemSwap(journal)
        if not journal then
            BfBot.Exec._LogEntry("SKIP", entry.spellName .. " (" .. tostring(reason) .. ")")
            return false
        end
        journal.token, journal.phase = _nextCallbackToken("_nextExecItemToken"), "equipping"
        caster.itemToken = journal.token
        BfBot.Persist.SetItemSwap(sprite, journal)
        EEex_Action_QueueResponseStringOnAIBase(string.format(
            'XEquipItem("%s",Myself,%d,1)', journal.item, journal.equip), sprite)
        _itemCallback(sprite, "_AfterItemEquip", caster.ref.slot, journal.token)
        return true
    end
    EEex_Action_QueueResponseStringOnAIBase(string.format(
        'UseItemSlotAbility(%s,%d,%d)', entry.targetObj, slot, row.abilityIdx), sprite)
    EEex_Action_QueueResponseStringOnAIBase(advanceAction, sprite)
    BfBot.Exec._LogEntry("CAST", entry.casterName .. " -> " .. entry.spellName
        .. " (item) -> " .. entry.targetName)
    BfBot.Exec._castCount = BfBot.Exec._castCount + 1
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

    -- 5E Spellcasting: a wrapper cast strips every wrapper and upstream
    -- regrants them after the delay the wrapper itself declares. Wait for
    -- that refresh before the next wrapper-backed attempt — its preflight
    -- would otherwise read the gap as "no slot". The wait re-enters this
    -- same index via _Resume (engine-driven, so no Lua stack growth).
    if entry.d5 and BfBot.FiveE and not caster.d5Refresh and not caster.d5Seeded then
        -- First wrapper-backed entry of this run for this caster: upstream may
        -- still be between a previous cast's strip and its delayed regrant
        -- (that cast can be BuffBot's from an earlier run, or the player's).
        -- The scan marks such rows pending; wait instead of reading the gap
        -- as "no slot". Checked once per caster per run.
        caster.d5Seeded = true
        BfBot.Scan.Invalidate(sprite)
        local fresh = BfBot.Scan.GetCastableSpells(sprite)
        local row = fresh and fresh[entry.resref]
        if row and BfBot.FiveE.AwaitingRefresh and BfBot.FiveE.AwaitingRefresh(row) then
            caster.d5Refresh = BfBot.FiveE.NewRefresh(row.d5)
            caster.d5Refresh.since = BfBot.Exec._GetGameTime()
        end
    end

    if caster.d5Refresh and entry.d5 and BfBot.FiveE then
        local refresh = caster.d5Refresh
        local okWait, waitTicks = pcall(BfBot.FiveE.RefreshWait,
            caster, entry, sprite, BfBot.Exec._GetGameTime())
        if not okWait then
            BfBot._Warn("[Exec] 5E refresh wait failed: " .. tostring(waitTicks))
            caster.d5Refresh = nil
        elseif waitTicks then
            if not refresh.logged then
                refresh.logged = true
                BfBot.Exec._LogEntry("INFO", entry.casterName
                    .. " waiting for 5E spell slots to refresh")
            end
            -- Each scheduled wait has its own token, even when an earlier
            -- run stopped at the same caster and queue index.
            caster.d5WaitToken = _nextCallbackToken("_nextExec5eWaitToken")
            caster.d5WaitIndex = index
            EEex_Action_QueueResponseStringOnAIBase(
                string.format("SmallWait(%d)", waitTicks), sprite)
            EEex_Action_QueueResponseStringOnAIBase(string.format(
                "EEex_LuaAction(\"BfBot.Exec._Resume([[%s]],%d)\")",
                key, caster.d5WaitToken), sprite)
            return
        end
    end

    -- Pre-flight checks — skip immediately recurses to next
    if not BfBot.Exec._CheckEntry(entry, sprite) then
        return BfBot.Exec._ProcessCasterEntry(key, index + 1)
    end

    -- Fresh scan data for this step (cache filled by _CheckEntry's rescan)
    local scanSpells = BfBot.Scan.GetCastableSpells(sprite)
    local spellScan = scanSpells and scanSpells[entry.resref]
    local d5 = entry.kind ~= "itm" and spellScan and spellScan.d5 or nil

    -- Safety: variant spell with no variant configured — skip
    if not entry.var then
        if spellScan and spellScan.hasVariants == 1 then
            BfBot.Exec._LogEntry("SKIP",
                entry.casterName .. " -> " .. entry.spellName
                .. " (variant spell — no variant configured)")
            BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
            return BfBot.Exec._ProcessCasterEntry(key, index + 1)
        end
    end

    -- 5E Spellcasting: only upstream's wrapper may spend a 5E slot. A
    -- selected variant would need the wrapper's debit/refresh without its
    -- own cast (which opens upstream's picker) — unsupported, so skip
    -- rather than force-cast around the shared pool or a native slot.
    if d5 then
        local reason = nil
        if entry.var then
            reason = "5E Spellcasting: variant selection is not supported"
                .. " for converted casters — cast it manually"
        elseif d5.available ~= 1 or type(d5.wrapper) ~= "string" then
            reason = "5E: no castable wrapper"
        end
        if reason then
            BfBot.Exec._LogEntry("SKIP", entry.casterName .. " -> "
                .. entry.spellName .. " -> " .. entry.targetName
                .. " (" .. reason .. ")")
            BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
            return BfBot.Exec._ProcessCasterEntry(key, index + 1)
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

    -- Cast the spell or use the item. The advance callback embeds the caster
    -- key as a Lua
    -- LONG-BRACKET string literal:
    --   EEex_LuaAction("BfBot.Exec._Advance([[p0]],123)")
    -- NOT single quotes: the BCS tokenizer strips single quotes inside a
    -- double-quoted action argument (verified live 2026-07-11 — 'p0' arrives
    -- as the nil global p0). Caster keys are alphanumeric by construction
    -- ("^p%d$" / "^s%d+$"), so "]]" can never appear in a key; long brackets
    -- are therefore always safe here.
    local advanceAction = _advanceAction(key, caster)

    if entry.kind == "itm" then
        if not BfBot.Exec._QueueItem(key, caster, entry, spellScan, sprite, advanceAction) then
            BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
            return BfBot.Exec._ProcessCasterEntry(key, index + 1)
        end

    elseif d5 then
        -- 5E Spellcasting: the upstream wrapper enforces preparation, spends
        -- the shared per-level slot once, casts the real spell, and starts
        -- its own refresh. BuffBot never debits anything itself.
        local spellAction = string.format('SpellRES("%s",%s)', d5.wrapper, entry.targetObj)
        EEex_Action_QueueResponseStringOnAIBase(spellAction, sprite)
        EEex_Action_QueueResponseStringOnAIBase(advanceAction, sprite)
        caster.d5Refresh = BfBot.FiveE.NewRefresh(d5)
        BfBot.Exec._LogEntry("CAST",
            entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName
            .. " (5E " .. d5.wrapper .. ")")
        BfBot.Exec._castCount = BfBot.Exec._castCount + 1

    elseif entry.var then
        -- Consume the parent slot, then cast its unmemorized child through the
        -- normal, interruptible casting/aura path without debiting the child.
        -- ReallyForceSpellRES would bypass both casting time and aura.
        if not BfBot.Exec._ConsumeSpellSlot(sprite, entry.resref) then
            BfBot.Exec._LogEntry("SKIP",
                entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName
                .. " (no slot for variant)")
            BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
            return BfBot.Exec._ProcessCasterEntry(key, index + 1)
        end
        local varAction = string.format('SpellNoDecRES("%s",%s)', entry.var, entry.targetObj)
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

--- Tell the player why a run ended: floating text over the party leader
--- (portrait slot 0), or the message log when that cannot be shown. Runs
--- inside engine callbacks and the .menu safety tick, so it never throws.
-- @param text string: already-localized feedback text
function BfBot.Exec._NotifyLeader(text)
    local ok, leader = pcall(EEex_Sprite_GetInPortrait, 0)
    if not ok then
        BfBot._ErrorOnce("Party leader lookup failed: " .. tostring(leader))
        leader = nil
    end
    BfBot._DisplayOverhead(leader, text)
end

--- Shared guard for engine-driven chain callbacks (_Advance / _Resume):
--- returns the caster record when its chain may continue, else nil after
--- finishing a gone caster or stopping the run on combat.
local function _continueChain(key)
    if BfBot.Exec._state ~= "running" then return nil end
    local caster = BfBot.Exec._casters[key]
    if not caster or caster.done then return nil end

    -- Caster vanished between steps (summon expired/killed, slot emptied),
    -- changed occupant (portrait reshuffle — never route the chain through
    -- the wrong character) or flipped allegiance (summon EA re-read): finish
    -- cleanly before touching anything sprite-related. Shared rules in
    -- _ResolveCasterForStep.
    local sprite = BfBot.Exec._ResolveCasterForStep(caster)
    if not sprite then
        BfBot.Exec._FinishGoneCaster(caster)
        return nil
    end

    -- Combat detection: abort all casters if hostiles detected
    if BfBot.Exec._DetectCombat() then
        BfBot.Exec._LogEntry("INFO", "Combat detected — stopping execution")
        BfBot.Exec.Stop()
        BfBot.Exec._NotifyLeader(BfBot.L10N.Get("feedback.combat_stopped"))
        return nil
    end
    return caster
end

--- Called by the engine via EEex_LuaAction after a 5E refresh wait: re-run
--- the SAME queue index (the wait happened before its preflight).
-- @param key string: caster key ("p<slot>" / "s<oid>") into _casters
-- @param token number: unique identifier of the scheduled wait
function BfBot.Exec._Resume(key, token)
    local caster = BfBot.Exec._casters[key]
    if not caster or token == nil or token ~= caster.d5WaitToken
        or caster.d5WaitIndex ~= caster.index then return end
    caster.d5WaitToken = nil
    caster.d5WaitIndex = nil
    if not _continueChain(key) then return end
    BfBot.Exec._ProcessCasterEntry(key, caster.index)
end

--- Called by the engine via EEex_LuaAction after a caster's spell completes.
-- @param key string: caster key ("p<slot>" / "s<oid>") into _casters
function BfBot.Exec._Advance(key, token)
    if BfBot.Exec._state ~= "running" then return end
    local caster = BfBot.Exec._casters[key]
    if not caster or caster.done then return end
    if token == nil or token ~= caster.advanceToken then return end
    caster.advanceToken = nil

    -- 5E Spellcasting: the wrapper's delayed refresh counts from the moment
    -- its cast finished, which is now.
    if caster.d5Refresh and caster.d5Refresh.since == nil then
        caster.d5Refresh.since = BfBot.Exec._GetGameTime()
    end

    if not _continueChain(key) then return end
    BfBot.Exec._ProcessCasterEntry(key, caster.index + 1)
end

--- Reset execution state without dereferencing cached sprites.
--- Used to recover from save-reload mid-cast (issue #38). Caster records
--- hold plain refs (never sprite userdata), so clearing the table is pure
--- Lua. Fast.Reset independently restores the owned global simulation rate.
--- The caller closes the exec log (see Stop / _Complete recovery branches),
--- allowing the in-game test suite to capture its output around each subtest.
function BfBot.Exec._HardReset()
    if BfBot.Fast then BfBot.Fast.Reset("execution reset") end
    BfBot.Exec._state         = "idle"
    BfBot.Exec._casters       = {}
    BfBot.Exec._activeCasters = 0
    BfBot.Exec._castCount     = 0
    BfBot.Exec._skipCount     = 0
    BfBot.Exec._totalEntries  = 0
    BfBot.Exec._qcMode        = 0
    BfBot.Exec._forceMode     = 0
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
    if BfBot.Fast then BfBot.Fast.CheckDone() end
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
    if BfBot.Fast then BfBot.Fast.Reset("execution timeout") end
    -- Clean up lingering cheat buffs (see _Complete/Stop for the re-resolve rationale).
    BfBot.Exec._StripCheatBuffs()

    BfBot.Exec._state = "done"
    BfBot.Exec._RecoverItemSwaps()
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
--- Caller (_TryLateJoin) guarantees: state == "running", the key is not
--- yet in _casters, and the MP gate passed.
-- @param summonEntry detection entry (ClassifySummonSprite shape: oid, name)
-- @param queue builder queue (BfBot.Persist.BuildQueueForSummon shape)
-- @return true when attached, false when the queue expanded empty (summon
--     vanished between classify and build — normal churn) or the expansion
--     FAILED outright (malformed queue — WARNed with the builder's reason)
function BfBot.Exec._AttachCaster(summonEntry, queue)
    local byCaster, reason = BfBot.Exec._BuildQueue(queue, BfBot.Exec._qcMode)
    if not byCaster then
        -- Expansion failure (nil + reason) is a real problem, unlike the
        -- empty-expansion churn below — never swallow it silently.
        BfBot.Exec._LogEntry("WARN", "late-join: queue expansion failed for "
            .. tostring(summonEntry.name) .. ": " .. tostring(reason))
        return false
    end
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
    -- Robustness note (review 93afd9d): readiness keys on the NAME settling.
    -- If a future engine version settles name BEFORE m_nCopyParent/stat 139,
    -- a clone could classify as a plain summon and miss its clone: config —
    -- revisit this gate then.
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
--- finishes the oid. A retry-budget exhaustion (the sprite NEVER reported
--- a real name) is WARNed — a summon that mysteriously fails to attach
--- must leave a trace. CHECKED pcall per oid — one broken entry must WARN
--- and be dropped, never wedge the tick or starve the other pending oids.
function BfBot.Exec._ProcessLateJoins()
    -- Defensive: only a RUNNING run may attach casters. The _SafetyTick
    -- call site already gates on state — this covers direct/future callers.
    if BfBot.Exec._state ~= "running" then return end
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
            if retry == true then
                -- budget exhausted while still "not initialized" — loud
                -- drop; the silent path is only for FINISHED oids
                BfBot.Exec._LogEntry("WARN", "late-join: summon "
                    .. tostring(oid) .. " never initialized after "
                    .. tostring(BfBot.Exec._LATEJOIN_MAX_TRIES)
                    .. " tries — dropped")
            end
            pending[oid] = nil
        end
    end
end

--- Start executing a buff queue with parallel per-caster casting.
-- @param queue array of {caster=0-5, spell="RESREF",
--     target="self"|"all"|1-6, rep=1..BfBot.MAX_SPELL_REPEATS (optional;
--     defaults to 1)}
-- @param qcMode quick cast mode (0=off, 1=long, 2=all)
-- @param presetIdx OPTIONAL preset index driving this run — recorded as
--     _runPresetIdx so a summon spawning MID-RUN can look up ITS summon
--     preset (late-join listener, issue #19). Raw/console queues pass
--     nothing → nil → late-join stays inert for that run (correct: there
--     is no preset to look a summon's config up under).
-- @param forceMode OPTIONAL run-scoped active-buff policy (issue #84):
--     0/nil = skip active buffs (the RefreshBelow option still applies),
--     1 = refresh buffs below the threshold, 2 = cast everything. Deliberately
--     per RUN, not per preset: nothing about it is written to the save.
--     Every player-facing entry point passes the selection, the F12 innates
--     included. Only a raw console queue passes nothing and therefore runs
--     with the RefreshBelow option alone.
-- @return true + nil + nil if started; false + reasonCode + detail if not
function BfBot.Exec.Start(queue, qcMode, presetIdx, forceMode)
    -- Do not start a Normal/Quick Cast run at a rate whose restoration is
    -- still pending. Fast.Start's initial delegation has no releaseReason.
    if BfBot.Fast and BfBot.Fast.run and BfBot.Fast.run.releaseReason then
        return false, "reason.exec.fast_unavailable",
            { reason = "simulation speed restoration pending" }
    end
    if BfBot.Exec._state == "running" then
        BfBot._Print("[BuffBot] Already running. Call BfBot.Exec.Stop() first.")
        return false, "reason.exec.already_running", {}
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
    BfBot.Exec._forceMode = BfBot.Exec._NormalizeForceMode(forceMode)
    BfBot.Exec._lastProgressGameTime = nil
    BfBot.Exec._runPresetIdx = (type(presetIdx) == "number") and presetIdx or nil
    BfBot.Exec._pendingLateJoin = {}

    -- Build per-caster queues
    local byCaster, totalEntries, buildDetail =
        BfBot.Exec._BuildQueue(queue, BfBot.Exec._qcMode)
    if not byCaster then
        BfBot.Exec._LogEntry("ERROR", "Failed to build queue: " .. tostring(totalEntries))
        BfBot._CloseLog()
        return false, totalEntries, buildDetail
    end

    BfBot.Exec._totalEntries = totalEntries

    -- Initialize per-caster state and print plan
    local casterCount = 0
    local qcLabel = BfBot.Exec._qcMode == 2 and " (Quick Cast: All)"
        or BfBot.Exec._qcMode == 1 and " (Quick Cast: Long)" or ""
    -- Force All outranks the threshold, so the banner names it alone: under
    -- the override the configured threshold has no bearing on the run.
    local forceLabel = ""
    local threshold = BfBot.Exec._RefreshThreshold()
    if BfBot.Exec._ForceAll() then
        forceLabel = " (Force all: active buffs cast again)"
    elseif threshold > 0 then
        forceLabel = " (Refresh below "
            .. (BfBot.Exec._FormatRemaining(threshold):gsub(" left", "")) .. ")"
    end
    BfBot._Print("[BuffBot] === Starting Execution: " .. totalEntries .. " entries"
        .. qcLabel .. forceLabel .. " ===")

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
        BfBot._Print("[BuffBot]   " .. name .. " (" .. #entries .. " attempts):")
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

    return true, nil, nil
end

--- Stop execution mid-queue.
function BfBot.Exec.Stop()
    if BfBot.Fast then BfBot.Fast.Reset("stopped") end
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
    BfBot.Exec._RecoverItemSwaps()

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
    -- Fast-forward guards use wall time and must run before the normal
    -- two-second maintenance throttle, including while the world is paused.
    if BfBot.Fast then BfBot.Fast.Tick() end
    -- Rate-limit: ~2 seconds between checks
    local now = Infinity_GetClockTicks()
    if now - BfBot.Exec._lastSafetyTick < 2000 then return end
    BfBot.Exec._lastSafetyTick = now
    BfBot.Exec._RecoverItemSwaps()

    -- Proactively recover from save-reload mid-cast (issue #38). The
    -- EEex_LuaAction chain that drives _Advance does NOT resume after a
    -- save load, so _state stays "running" forever and the UI gates
    -- Cast/CastChar off. Detect via portrait-set mismatch and reset so the
    -- user sees a clean idle state on next menu open — and so the running
    -- branch below falls through to the BFBTCH cleanup loop.
    if BfBot.Exec._IsStateStale() then
        BfBot.Exec._HardReset()
    end

    -- A stale slot-bound F12 click during an active run cannot reconcile
    -- immediately: BFBTRM/AddSpecialAbility actions would interleave with the
    -- casting chains. Drain the root-level request once execution has settled.
    -- Keep it pending after a Lua failure so the next safety tick retries.
    if BfBot.Exec._state ~= "running" and BfBot._innateRefreshPending then
        BfBot._innateRefreshPending = nil
        local ok, err = pcall(function()
            local refresh = BfBot.Innate and BfBot.Innate.RefreshAll
            if type(refresh) ~= "function" then
                error("BfBot.Innate.RefreshAll is unavailable")
            end
            refresh()
        end)
        if not ok then
            BfBot._innateRefreshPending = true
            BfBot._Warn("[Innate] Deferred stale-slot refresh failed; will retry: "
                .. tostring(err))
        end
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
            BfBot.Exec._NotifyLeader(BfBot.L10N.Get("feedback.cast_timeout"))
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
