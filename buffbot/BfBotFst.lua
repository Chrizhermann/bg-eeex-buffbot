-- Temporary simulation acceleration. Spell/item actions remain native; no
-- acceleration helper, clock jumps or effect-expiry corrections are applied.
BfBot.Fast=BfBot.Fast or {}
local F=BfBot.Fast
local function rate() return EEex_CChitin and EEex_CChitin.TIMER_UPDATES_PER_SECOND end
local function setRate(value)
    EEex_CChitin.TIMER_UPDATES_PER_SECOND=value
    return rate()==value
end
local function gameTick()
    return EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_worldTime.m_gameTime
end
local function truth(value) return value~=nil and value~=false and value~=0 end
function F.Safe()
    if BfBot.Mp and BfBot.Mp._IsMpSession() then return false,'multiplayer' end
    if not e or not worldScreen or e:GetActiveEngine()~=worldScreen then return false,'outside world' end
    local input=EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_gameSave.m_inputMode
    if bit.band(input-0x1016E,0xFFFDFFFF)==0 or bit.band(input,0x801)==0
        or sidebarsGreyed==1 then return false,'dialogue or cutscene' end
    for _,menu in ipairs({'WORLD_DIALOG','WORLD_DIALOG_CONFIRM','STORE','LOAD_SCREEN',
        'POPUP_INFO','POPUP_TWOBUTTON','POPUP_THREEBUTTON','POPUP_FOURBUTTON'}) do
        if truth(Infinity_IsMenuOnStack(menu)) then return false,'menu' end
    end
    if not BfBot.Rest or BfBot.Rest.Combat() then return false,'combat' end
    return true
end
function F.Reset(reason)
    local run=F.run
    if not run then return end
    F.run=nil -- release before callbacks; never restore over another owner
    local ok,current=pcall(rate)
    local restored=false
    if ok and current==run.applied then
        local changed,result=pcall(setRate,run.original)
        restored=changed and result==true
        if not restored then
            -- Keep ownership so the next UI tick can retry the failed restore.
            F.run=run;run.releaseReason=reason or 'restore retry'
            BfBot._Warn('Fast forward: could not restore simulation speed; retrying')
            return false
        end
    end
    local renderRestored=false
    if run.render then
        local read,ours=pcall(function()
            return EEex.UncapFPS_FPSLimitEnabled==true and EEex.UncapFPS_FPSLimit==run.render.applied
        end)
        if read and ours then
            local changed=pcall(function()
                EEex.UncapFPS_FPSLimit=run.render.original
                EEex.UncapFPS_FPSLimitEnabled=run.render.enabled
            end)
            renderRestored=changed
        end
    end
    local audit={original=run.original,applied=run.applied,reason=reason or 'reset',
        restored=restored,wallMs=Infinity_GetClockTicks()-run.wall,gameTicks=0,
        renderCap=run.render and run.render.applied or 0,renderRestored=renderRestored}
    local read,tick=pcall(gameTick)
    if read then audit.gameTicks=tick-run.tick end
    F.lastAudit=audit
    if io then
        local file=io.open('buffbot_fast_forward_audit.jsonl','a')
        if file then
            file:write(string.format('{"original":%d,"applied":%d,"wallMs":%d,"gameTicks":%d,"restored":%s,"renderCap":%d,"renderRestored":%s,"reason":"%s"}\n',
                audit.original,audit.applied,audit.wallMs,audit.gameTicks,tostring(restored),
                audit.renderCap,tostring(renderRestored),
                audit.reason:gsub('[%c"\\]',' ')))
            file:close()
        end
    end
    return restored
end
function F.Start(queue,preset)
    if type(queue)~='table' or #queue==0 then return false,'reason.exec.empty_queue',{} end
    if F.run or BfBot.Exec.GetState()=='running' or BfBot.Share and BfBot.Share.run then
        return false,'reason.exec.already_running',{}
    end
    local safe,allowed,why=pcall(F.Safe)
    if not safe or not allowed then
        BfBot.Exec._NotifyLeader('Fast forward unavailable: '..tostring(safe and why or 'engine inspection failed'))
        return false,'reason.exec.empty_queue',{}
    end
    local ok,original=pcall(rate)
    if not ok or type(original)~='number' or original%1~=0 or original<1 or original>=120 then
        BfBot.Exec._NotifyLeader('Fast forward unavailable: unsupported simulation rate')
        return false,'reason.exec.empty_queue',{}
    end
    local state=BfBot.Plan.GetState()
    local multiplier=state and state.fastRate==4 and 4 or 2
    local applied=math.min(120,original*multiplier)
    local run={original=original,applied=applied,wall=Infinity_GetClockTicks(),tick=gameTick()}
    F.run=run
    -- EEex decouples render and simulation rates. Rendering every possible
    -- frame can starve faster logic; 30 FPS retains the native game's visual
    -- cadence without raising a player's existing lower limit. Never persist.
    pcall(function()
        local limit,enabled=EEex.UncapFPS_FPSLimit,EEex.UncapFPS_FPSLimitEnabled
        if type(limit)=='number' and limit>=1 and type(enabled)=='boolean' then
            run.render={original=limit,enabled=enabled,applied=enabled and math.min(limit,30) or 30}
            EEex.UncapFPS_FPSLimit=run.render.applied
            EEex.UncapFPS_FPSLimitEnabled=true
        end
    end)
    local changed,result=pcall(setRate,applied)
    if not changed or not result then F.Reset('start failed');return false,'reason.exec.empty_queue',{} end
    local copy={}
    for i,entry in ipairs(queue or {}) do
        copy[i]={};for k,v in pairs(entry) do copy[i][k]=v end
        copy[i].cheat=0 -- no inherited per-entry Quick Cast override
    end
    local started,a,b,c=pcall(BfBot.Exec.Start,copy,0,preset)
    if not started or not a then
        F.Reset('start failed')
        if not started then error(a) end
        return a,b,c
    end
    F.CheckDone()
    return a,b,c
end
function F.CheckDone()
    if F.run and BfBot.Exec.GetState()~='running' and not (BfBot.Share and BfBot.Share.run) then
        F.Reset('complete')
    end
end
function F.Tick()
    local run=F.run;if not run then return end
    if run.releaseReason then return F.Reset(run.releaseReason) end
    local now=Infinity_GetClockTicks()
    -- The menu callback can run at uncapped rendering FPS. Area-wide combat
    -- checks belong on a short wall-time cadence, not every rendered frame.
    if run.lastGuard and now>=run.lastGuard and now-run.lastGuard<50 then return F.CheckDone() end
    run.lastGuard=now
    local ok,current=pcall(rate)
    local checked,safe,why=pcall(F.Safe)
    local reason
    if not ok or current~=run.applied then reason='external speed change'
    elseif not checked or not safe then reason=checked and why or 'engine inspection failed'
    elseif now-run.wall>120000 then reason='wall timeout' end
    if reason then
        F.Reset(reason)
        BfBot.Exec.Stop() -- normal item recovery continues at the restored rate
        return
    end
    F.CheckDone()
end
function F.Init()
    if BfBot._fastListenersRegistered then return end
    EEex_GameState_AddDestroyedListener(function() BfBot.Fast.Reset('load or exit') end)
    BfBot._fastListenersRegistered=true
end
