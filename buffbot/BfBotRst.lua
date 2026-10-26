-- Completed standard party rests only. Runtime observations are never saved:
-- loading a save seeds a baseline and cannot replay a previous rest.
BfBot.Rest = {}
local R = BfBot.Rest

function R.Reset()
    R.previous, R.pending, R.jump, R.lastPoll = nil, nil, nil, nil
end
R.Reset()

-- Pure event recognizer. A normal eight-hour rest advances the engine clock
-- roughly 36,000 ticks before character restoration finishes. Individual Rest() also
-- changes m_lastRested, so timestamp changes alone are not a party-rest signal.
function R.Observe(sample)
    local old = R.previous
    R.previous = sample
    -- The tested engine can report adjacent ticks out of order around rest.
    -- Real save/load resets also arrive through the destroyed listener.
    if not old or sample.owner ~= old.owner or sample.time < old.time - 2 then
        R.pending, R.jump = nil, nil
        return false
    end
    -- Inclusive endpoints and adjacent-tick jitter yielded 35,998/35,999
    -- in the native tests. Allow three ticks around the eight-hour advance.
    if sample.time - old.time >= 36000 - 3 then
        R.jump = { time = sample.time, after = old.time, stamp = old.stamp }
    end
    local jump = R.jump
    if not jump then return false end
    -- Pausing after the movie can delay character restoration indefinitely.
    if sample.time - jump.time > 900 then R.jump = nil; return false end
    -- PartyRested() may already have been consumed by character scripts.
    -- Clock advance alone includes travel; timestamps alone include Rest().
    -- Require BOTH, with the whole living party restored after the jump began.
    if sample.stamp ~= jump.stamp and sample.stamp > jump.after
        and (sample.oldestStamp or sample.stamp) > jump.after
        and sample.stamp <= sample.time + 2 and sample.complete then
        R.jump = nil
        return true
    end
    return false
end

function R.Sample()
    local owner = BfBot.Persist._GetProtagonist()
    if not owner then return nil end
    local time = BfBot.Exec._GetGameTime()
    if type(time) ~= 'number' then return nil end
    local stamp = owner.m_lastRested
    if type(stamp) ~= 'number' then return nil end
    local oldest, alive = stamp, 0
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite and BfBot.Exec._IsAlive(sprite) then
            alive = alive + 1
            oldest = math.min(oldest, sprite.m_lastRested)
        end
    end
    return {owner=owner.m_id, time=time, stamp=stamp, clock=Infinity_GetClockTicks(),
        complete=alive > 0, oldestStamp=oldest}
end

function R.SafeWorld()
    if not e or not worldScreen or e:GetActiveEngine() ~= worldScreen then return false end
    local game = EngineGlobals.g_pBaldurChitin.m_pObjectGame
    -- Same input-mode test as EEex's keyboard scrolling guard: excludes
    -- native cutscene and dialogue modes, including modded menu layouts.
    local input = game.m_gameSave.m_inputMode
    if bit.band(input - 0x1016E, 0xFFFDFFFF) == 0 or bit.band(input, 0x801) == 0 then return false end
    if sidebarsGreyed == 1 then return false end
    for _, menu in ipairs({'BUFFBOT_PARTY','BUFFBOT_MAIN','BUFFBOT_RX',
        'BUFFBOT_RX_POPMENU','BUFFBOT_RX_DIALOG','POPUP_INFO',
        'POPUP_TWOBUTTON','POPUP_THREEBUTTON','POPUP_FOURBUTTON','WORLD_DIALOG','WORLD_DIALOG_CONFIRM'}) do
        if Infinity_IsMenuOnStack(menu) then return false end
    end
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite and BfBot.Exec._IsAlive(sprite)
            and not EEex_Trigger_EvalConditionalStringAsAIBase('ActionListEmpty()',sprite) then return false end
    end
    return true
end

function R.Combat()
    -- Automatic casting never ignores combat even when the manual executor's
    -- CombatInterrupt preference is disabled.
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite and BfBot.Exec._IsAlive(sprite) and
            (sprite:countAllOfTypeStringInRange('[ENEMY]',400) > 0
            or EEex_Trigger_EvalConditionalStringAsAIBase('CombatCounterGT(0)',sprite) == true) then return true end
    end
    return false
end

function R.Notify(message)
    R.status = BfBot.Plan.Text(message)
    BfBot.Exec._NotifyLeader(R.status)
end

function R.Tick()
    if BfBot.Fast then BfBot.Fast.Tick() end
    if BfBot.Share then BfBot.Share.Tick() end
    local now = Infinity_GetClockTicks()
    if R.lastPoll and now >= R.lastPoll and now - R.lastPoll < 250 then return false end
    R.lastPoll = now
    if BfBot.Legacy then BfBot.Legacy.Tick() end
    if BfBot.UI and BfBot.UI._PumpActionbarBtn then BfBot.UI._PumpActionbarBtn() end
    local sample = R.Sample()
    if not sample then R.Reset(); return false end
    local completed = R.Observe(sample)
    local state = BfBot.Plan.GetState()
    if state and BfBot.Visual then BfBot.Visual.skinOverride=state.skin end
    local rest = state and state.rest
    if completed then
        R.pending = rest and rest.on == 1 and {preset=rest.preset, clock=now} or nil
    end
    local pending = R.pending
    if not pending then return false end
    if not rest or rest.on ~= 1 or rest.preset ~= pending.preset
        or now - pending.clock > 120000 then R.pending = nil; return false end
    if BfBot.Mp and BfBot.Mp._IsMpSession() then R.pending = nil; return false end
    if R.Combat() then R.pending = nil; R.Notify('Rest plan skipped: combat'); return false end
    if BfBot.Exec.GetState() == 'running' then R.pending = nil; return false end
    if now - pending.clock < 500 or not R.SafeWorld() then return false end
    R.pending = nil -- consume BEFORE planning/starting, including failures
    local preset = state.presets[pending.preset]
    if not preset or #preset.requests == 0 then return false end
    BfBot.Scan.InvalidateAll()
    local snapshot=BfBot.Plan.Snapshot()
    BfBot.Plan.ApplyOrder(snapshot,preset,BfBot.Plan.EstimateCast)
    local queue,plan = BfBot.Plan.BuildQueue(snapshot,preset.requests)
    BfBot.Plan.ReportSkipped(plan)
    if not queue then R.Notify('Rest plan skipped: no available casts'); return false end
    local ok = BfBot.Exec.Start(queue,state.fast==1 and 4 or 0,nil)
    if ok then R.Notify('Casting rest plan') end
    return false
end

function R.Init()
    if BfBot._restListenersRegistered then return end
    EEex_GameState_AddDestroyedListener(BfBot._SafeCallback('rest.destroyed',function()
        BfBot.Rest.Reset()
    end))
    BfBot._restListenersRegistered = true
end
