-- Temporary simulation acceleration, adapted from Zach Hopkins' BuffBot Redux
-- (BfBotFst.lua, MIT). Native casting, aura, resources and effect timers remain
-- authoritative. No clock jumps, Quick Cast helpers or expiry edits are used.
-- This module owns only the simulation rate it applies, never saved preferences.
BfBot.Fast = BfBot.Fast or {}
local F = BfBot.Fast

local function rate()
    return EEex_CChitin and EEex_CChitin.TIMER_UPDATES_PER_SECOND
end

local function setRate(value)
    EEex_CChitin.TIMER_UPDATES_PER_SECOND = value
    return rate() == value
end

local function chitin()
    return EngineGlobals and EngineGlobals.g_pBaldurChitin
end

local function gameTick()
    return chitin().m_pObjectGame.m_worldTime.m_gameTime
end

local function truth(value)
    return value ~= nil and value ~= false and value ~= 0
end

local function unavailable(reason)
    return false, "reason.exec.fast_unavailable", { reason = reason }
end

-- Non-modal screens that take the world away from the player anyway, matched
-- as name prefixes against the UI's own list rather than spelled out: the
-- exact names differ between BG:EE, BG2:EE and IWD:EE, and the literal
-- "STORE" this guard used to look for is no menu on BG2:EE at all, where the
-- shop screens are STORE_BUYSELL, STORE_CHOOSER, STORE_DONATE and so on.
local BLOCKING_PREFIXES = { "STORE", "WORLD_DIALOG", "LOAD", "SAVE" }

-- The menu names this guard refuses on, derived from the running UI once and
-- held until that UI changes. Rebuilt whenever the engine reports a different
-- number of menus, which is what a UI reload or a mod's injection changes.
F._blocking = nil
F._blockingFor = nil

--- One menu's name, or nil when the binding will not give it up.
-- The field is a string wrapper on every build EEex supports, so :get() is the
-- normal path; a plain string is accepted in case a future binding simplifies.
local function menuName(menu)
    local ok, value = pcall(function()
        local name = menu.name
        if type(name) == "string" then return name end
        return name and name:get() or nil
    end)
    if not ok or type(value) ~= "string" or value == "" then return nil end
    return value
end

--- Every menu the running UI would hide the world behind, by name.
-- Returns nil when the menu list cannot be read, which has to refuse rather
-- than accelerate: an unreadable list is indistinguishable from an empty one.
--
-- The guard used to name eight menus and additionally ask
-- EngineGlobals.popupActive(). Both halves were wrong. A lab walk of BG2:EE's
-- own list found 51 modal menus against those eight, two of which
-- (STORE, LOAD_SCREEN) were no menu's name and so could never match, while
-- the engine's options, character-record, level-up and journal screens -- and
-- EEex's own Options menu, which no release here could have named -- were all
-- missing. popupActive is not the stronger answer either: with the character
-- record open it returned false while this walk found CHARACTER on the stack.
-- It is also unbound before EEex 1.3.1 (#104), which is what stopped
-- fast-forward working on an older install at all.
local function blockingMenus()
    local counted, count = pcall(function() return EngineGlobals.numMenus end)
    if not counted or type(count) ~= "number" or count < 0 then return nil end
    if F._blocking and F._blockingFor == count then return F._blocking end
    local names = {}
    for index = 0, count - 1 do
        local read, menu = pcall(function()
            return EngineGlobals.menus:getReference(index)
        end)
        if not read or not menu then return nil end
        local name = menuName(menu)
        if not name then return nil end
        -- `modal` reads as a wrapper object when the menu declares it and nil
        -- when it does not, so presence is the flag; truth() keeps a future
        -- numeric 0 from reading as "modal" the way Lua would.
        local flagged, modal = pcall(function() return menu.modal end)
        if not flagged then return nil end
        local blocking = truth(modal)
        if not blocking then
            for _, prefix in ipairs(BLOCKING_PREFIXES) do
                if name:sub(1, #prefix) == prefix then
                    blocking = true
                    break
                end
            end
        end
        if blocking then names[#names + 1] = name end
    end
    F._blocking, F._blockingFor = names, count
    return names
end

--- Fail closed if the engine cannot be inspected. Called inside pcall by Start
--- and Tick; no fallback may accelerate an unverified multiplayer/menu state.
function F.Safe()
    local engine = chitin()
    if not engine then return false, "engine unavailable" end
    local connected = engine.cNetwork.m_bConnectionEstablished
    if connected ~= 0 and connected ~= false then
        return false, connected == nil and "network state unavailable" or "multiplayer"
    end
    if not e or not worldScreen or e:GetActiveEngine() ~= worldScreen then
        return false, "outside world"
    end
    -- Where EEex binds it, this engine-wide predicate is asked as well. It is
    -- not the guard -- the menu walk below covers strictly more, and EEex
    -- before 1.3.1 does not bind this at all -- but it can only add refusals,
    -- so a build that offers the second opinion gets to use it.
    if type(EngineGlobals.popupActive) == "function" then
        local popup = EngineGlobals.popupActive()
        if popup == nil then return false, "popup state unavailable" end
        if truth(popup) then return false, "menu" end
    end
    local input = engine.m_pObjectGame.m_gameSave.m_inputMode
    if type(input) ~= "number" then return false, "input state unavailable" end
    -- EEex's keyboard-scroll guard excludes dialogue and cutscene input modes.
    if BfBot._BAnd(input - 0x1016E, 0xFFFDFFFF) == 0
        or BfBot._BAnd(input, 0x801) == 0 or truth(sidebarsGreyed) then
        return false, "dialogue or cutscene"
    end
    local blocking = blockingMenus()
    if not blocking then return false, "menu list unavailable" end
    for _, menu in ipairs(blocking) do
        local asked, up = pcall(Infinity_IsMenuOnStack, menu)
        if not asked then return false, "menu state unavailable" end
        if truth(up) then return false, "menu" end
    end
    local living = 0
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite and BfBot.Exec._IsAlive(sprite) then
            living = living + 1
            -- The manual CombatInterrupt preference cannot disable this guard.
            local count = sprite:countAllOfTypeStringInRange("[ENEMY]", 400)
            if type(count) ~= "number" then return false, "combat state unavailable" end
            local combat = EEex_Trigger_EvalConditionalStringAsAIBase("CombatCounterGT(0)", sprite)
            if combat == nil then return false, "combat state unavailable" end
            if count > 0 or truth(combat) then return false, "combat" end
        end
    end
    if living == 0 then return false, "no living party" end
    return true
end

--- Restore only our rate. If another mod/user has changed it meanwhile, release
--- ownership without overwriting that new value. Failed reads/writes retain the
--- record for a retry on the next UI tick, and prevent a second run starting.
function F.Reset(reason)
    local run = F.run
    if not run then return true end
    run.releaseReason = run.releaseReason or reason or "reset"
    local ok, current = pcall(rate)
    local restored = false
    if ok and type(current) == "number" then
        if current == run.applied then
            local changed, result = pcall(setRate, run.original)
            ok = changed and result == true
            restored = ok
        end
    else
        ok = false
    end
    if not ok then
        if not run.warnedRestore then
            run.warnedRestore = true
            BfBot._Warn("Fast forward: could not restore simulation speed; retrying")
        end
        return false
    end
    F.run = nil
    local wallOk, now = pcall(Infinity_GetClockTicks)
    local tickOk, tick = pcall(gameTick)
    F.lastAudit = {
        original = run.original, applied = run.applied, multiplier = run.multiplier,
        reason = run.releaseReason, restored = restored,
        wallMs = wallOk and type(now) == "number" and now - run.wall or nil,
        gameTicks = tickOk and type(tick) == "number" and tick - run.tick or nil,
    }
    return true
end

--- Lifecycle transitions can remove the world UI callback that normally
--- retries Reset. Make a bounded synchronous effort before that callback goes
--- away. This cannot recover an unavailable binding; retain the original rate
--- and failure record so a later world tick can retry without guessing.
function F.Release(reason)
    for attempt = 1, 3 do
        local run = F.run
        if not run then return true end
        run.releaseAttempts = attempt
        if F.Reset(reason) then return true end
    end
    local run = F.run
    if run then
        run.releaseFailed = true
        if not run.warnedRelease then
            run.warnedRelease = true
            BfBot._Warn("Fast forward: simulation speed restoration remains pending after "
                .. tostring(run.releaseReason) .. "; original=" .. tostring(run.original)
                .. ", applied=" .. tostring(run.applied))
        end
    end
    return false
end

--- Start at an explicit 2x or 4x; choosing normal mode uses Exec.Start directly.
--- No render-rate change: whether a cap helps is installation-specific and must
--- be established in the current-engine lab before changing players' visuals.
--- forceMode is the caller's active-buff policy (issue #84) and is passed
--- straight on: simulation speed must not change what a run skips.
function F.Start(queue, multiplier, presetIdx, forceMode)
    if type(queue) ~= "table" or #queue == 0 then
        return false, "reason.exec.empty_queue", {}
    end
    if F.run or BfBot.Exec.GetState() == "running" then
        return false, "reason.exec.already_running", {}
    end
    if multiplier ~= 2 and multiplier ~= 4 then return unavailable("invalid multiplier") end
    if not BfBot._fastListenersRegistered and not F.Init() then
        return unavailable("load/exit guard unavailable")
    end
    local inspected, safe, why = pcall(F.Safe)
    if not inspected or not safe then
        return unavailable(inspected and why or "engine inspection failed")
    end
    local read, original = pcall(rate)
    -- Preserve the existing baseline; refuse unsupported rates without mutation.
    if not read or type(original) ~= "number" or original % 1 ~= 0
        or original < 1 or original * multiplier > 120 then
        return unavailable("unsupported simulation rate")
    end
    local clockOk, wall = pcall(Infinity_GetClockTicks)
    local tickOk, tick = pcall(gameTick)
    if not clockOk or type(wall) ~= "number" or not tickOk or type(tick) ~= "number" then
        return unavailable("clock unavailable")
    end
    local copy = {}
    for i, entry in ipairs(queue) do
        if type(entry) ~= "table" then return unavailable("invalid queue entry") end
        copy[i] = {}
        for k, v in pairs(entry) do copy[i][k] = v end
        copy[i].cheat = 0
    end
    F.run = { original = original, applied = original * multiplier,
        multiplier = multiplier, wall = wall, tick = tick }
    local changed, result = pcall(setRate, F.run.applied)
    if not changed or not result then
        -- A setter can clamp or write before raising. This synchronous start
        -- transaction still owns that observed value; otherwise Reset would
        -- mistake our failed write for another mod's later speed change.
        local observed, current = pcall(rate)
        if observed and type(current) == "number" then F.run.applied = current end
        F.Reset("start failed")
        return unavailable("simulation rate could not be changed")
    end
    local started, accepted, code, detail = pcall(BfBot.Exec.Start, copy, 0,
        presetIdx, forceMode)
    if not started or not accepted then
        F.Reset("start failed")
        -- If native startup failed after scheduling actions, stop that partial
        -- run too. Stop's own Reset call is safe and retries a failed restore.
        if not started then
            pcall(BfBot.Exec.Stop)
            BfBot._Warn("Fast forward: execution start failed: " .. tostring(accepted))
            return unavailable("execution start failed")
        end
        return accepted, code, detail
    end
    F.CheckDone()
    return accepted, code, detail
end

function F.CheckDone()
    if F.run and BfBot.Exec.GetState() ~= "running" then F.Reset("complete") end
end

--- Must run before Exec's slower watchdog throttle on every world UI tick.
function F.Tick()
    local run = F.run
    if not run then return end
    if run.releaseReason then F.Reset(run.releaseReason); return end
    local clockOk, now = pcall(Infinity_GetClockTicks)
    local reason
    if not clockOk or type(now) ~= "number" then
        reason = "clock unavailable"
    elseif now < run.wall then
        reason = "clock reset"
    elseif run.lastGuard and now >= run.lastGuard and now - run.lastGuard < 50 then
        F.CheckDone()
        return
    else
        run.lastGuard = now
        local read, current = pcall(rate)
        local inspected, safe, why = pcall(F.Safe)
        if not read or current ~= run.applied then reason = "external speed change"
        elseif not inspected or not safe then reason = inspected and why or "engine inspection failed" end
    end
    if reason then
        F.Reset(reason)
        BfBot.Exec.Stop()
        return
    end
    -- The executor's game-time progress watchdog handles stalled casts and
    -- releases our rate through _ForceComplete. A total wall-time deadline
    -- would instead stop healthy long presets and paused games.
    F.CheckDone()
end

function F.Init()
    if BfBot._fastListenersRegistered then return true end
    if type(EEex_GameState_AddDestroyedListener) ~= "function" then return false end
    EEex_GameState_AddDestroyedListener(function()
        BfBot.Fast.Release("load or exit")
        -- The next game may bring a different UI up. The menu-count check
        -- would miss a swap that happens to keep the count, so the cached
        -- list goes with the game it was read from.
        BfBot.Fast._blocking, BfBot.Fast._blockingFor = nil, nil
    end)
    BfBot._fastListenersRegistered = true
    return true
end
