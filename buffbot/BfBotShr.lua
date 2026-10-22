-- Purposeful sharing of one unique, loose, rechargeable item at a time.
-- Transfers use engine actions. Items are never reconstructed from resources.
BfBot.Share = {}
local S = BfBot.Share
local function actor(key)
    local found, slot
    for n=0,5 do
        local s=EEex_Sprite_GetInPortrait(n)
        if s and BfBot.Plan.ActorKey(s)==key then
            if found then return nil end
            found,slot=s,n
        end
    end
    return found,slot
end
local function itemAt(sprite,slot)
    return sprite and sprite.m_equipment.m_items:get(slot)
end
local function locate(res)
    res=res:upper()
    local found
    for n=0,5 do
        local s=EEex_Sprite_GetInPortrait(n)
        if s then for slot=0,38 do
            local item=itemAt(s,slot)
            if item and item.pRes.resref:get():upper()==res then
                if found then return nil,'duplicate item resource' end
                found={sprite=s,slot=slot,item=item,key=BfBot.Plan.ActorKey(s)}
            end
        end end
    end
    return found
end
local function freePack(sprite)
    for n=18,33 do if not itemAt(sprite,n) then return n end end
end
local function sameArea(a,b)
    return a and b and a.m_pArea and b.m_pArea
        and EEex_UDToPtr(a.m_pArea)==EEex_UDToPtr(b.m_pArea)
end
local function fingerprint(item)
    return {flags=item.m_flags,wear=item.m_wear,
        counts={item.m_useCount1,item.m_useCount2,item.m_useCount3}}
end
local function matching(item,j)
    if not item or item.m_flags~=j.flags or item.m_wear~=j.wear then return false end
    for n=1,3 do
        local v=({item.m_useCount1,item.m_useCount2,item.m_useCount3})[n]
        if v>j.counts[n] or v<0 then return false end
    end
    return true
end
function S.ValidateJournal(j)
    if type(j)~='table' or type(j.item)~='string' or #j.item==0 or j.item:find('[%c"\\]') or #j.item>8
        or type(j.owner)~='string' or #j.owner==0 or #j.owner>200 or j.owner:find('%c')
        or type(j.borrower)~='string' or #j.borrower==0 or #j.borrower>200 or j.borrower:find('%c')
        or j.owner==j.borrower or type(j.pack)~='number' or j.pack%1~=0 or j.pack<18 or j.pack>33
        or type(j.flags)~='number' or j.flags%1~=0 or j.flags<0 or j.flags>4294967295
        or type(j.wear)~='number' or j.wear%1~=0 or j.wear<0 or j.wear>65535
        or type(j.counts)~='table' then return nil end
    local counts={}
    for n=1,3 do local v=j.counts[n]
        if type(v)~='number' or v%1~=0 or v<0 or v>65535 then return nil end
        counts[n]=v
    end
    return {item=j.item,owner=j.owner,borrower=j.borrower,pack=j.pack,
        flags=j.flags,wear=j.wear,counts=counts}
end
function S.CanBorrow(source,recipient)
    if source.row.requiresChoice or not BfBot.Scan.NativeBackpackMovesAvailable() then return false end
    if type(source.row.itemResref)~='string' or #source.row.itemResref==0 or source.row.itemResref:find('[%c"\\]')
        or #source.row.itemResref>8 then return false end
    if source.row.kind~='itm' or not source.selfOnly or source.aoe
        or not source.itemSlot or source.itemSlot<18 or source.itemSlot>33 then return false end
    if recipient.ambiguous or not recipient.alive or not recipient.controlled then return false end
    local owner=actor(source.actor)
    if not owner or not sameArea(owner,recipient.sprite) or not freePack(recipient.sprite) then return false end
    local h=EEex_Resource_Demand(source.row.itemResref,'ITM')
    local ability=h and BfBot.Scan._GetItemAbility(h,source.row.abilityIdx)
    if not ability then return false end
    local ptr=EEex_UDToPtr(ability)
    -- Daily rechargeable charges; exclude consumables, stacks and at-will gear.
    if EEex_ReadU16(ptr+0x22)<2 or EEex_ReadU16(ptr+0x24)~=3
        or EEex_ReadU16(EEex_UDToPtr(h)+0x38)>1
        or bit.band(EEex_ReadU32(EEex_UDToPtr(h)+0x18),0x14)~=4 then return false end
    local location=locate(source.row.itemResref:upper())
    if not location or location.key~=source.actor or location.slot~=source.itemSlot
        or bit.band(location.item.m_flags,8)~=0 then return false end
    if BfBot.Persist.GetItemSwap(owner) or BfBot.Persist.GetItemSwap(recipient.sprite) then return false end
    return BfBot.Scan._NativeCanWearItem(recipient.sprite,location.item)==true
end
function S.AddSources(snapshot)
    if BfBot.Mp and BfBot.Mp._IsMpSession() then return end
    for _,group in pairs(snapshot.groups) do
        local originals={};for _,source in ipairs(group.sources) do originals[#originals+1]=source end
        for _,source in ipairs(originals) do
            if not source.reason then for _,recipient in ipairs(snapshot.order) do
                if recipient.key~=source.actor and S.CanBorrow(source,recipient) then
                    local alias={};for k,v in pairs(source) do alias[k]=v end
                    alias.id=source.id..'/borrow/'..recipient.key
                    alias.actor,alias.slot,alias.casterName=recipient.key,recipient.slot,recipient.name
                    alias.casterRef=recipient.casterRef or {kind='party',slot=recipient.slot}
                    alias.lane=recipient.poolKey or recipient.key
                    alias.itemOwner,alias.itemOwnerName=source.actor,source.casterName
                    local h=EEex_Resource_Demand(source.row.itemResref,'ITM')
                    local a=BfBot.Scan._GetItemAbility(h,source.row.abilityIdx)
                    alias.duration=BfBot.Class.GetDuration(h,a,nil,nil,nil,function(child)
                        local level=recipient.sprite:getCasterLevelForSpell(child,true)
                        return type(level)=='number' and level>0 and level or 1
                    end)
                    group.sources[#group.sources+1]=alias -- same physical charge pool
                end
            end end
        end
    end
end
function S.NeedsSharing(queue)
    for _,entry in ipairs(queue or {}) do if entry.itemOwner then return true end end
    return false
end
local function give(from,to,res)
    EEex_Action_QueueResponseStringOnAIBase(string.format('GiveItem("%s",Player%d)',res,
        EEex_Sprite_GetCharacterIndex(to)+1),from)
end
local function finish(status)
    local run=S.run;S.run=nil
    if run then
        BfBot.Exec._castCount,BfBot.Exec._skipCount=run.casts,run.skips
        BfBot.Exec._state=status or 'done'
        if BfBot.Fast then BfBot.Fast.CheckDone() end
        BfBot.Exec._NotifyLeader(status=='stopped' and 'Item sharing stopped; check the recovery message'
            or 'Buff plan finished')
    end
end
local function fail(message)
    if S.lastFailure~=message then
        BfBot._Warn('Item sharing: '..message)
        BfBot.Exec._NotifyLeader('Item sharing: '..message)
        S.lastFailure=message
    end
    if S.run then S.run.cancelled=true end
end
function S.Start(queue,qcMode)
    if type(queue)~='table' or #queue==0 then return false,'reason.exec.empty_queue',{} end
    if BfBot.Mp and BfBot.Mp._IsMpSession() then return false,'reason.exec.already_running',{} end
    local state=BfBot.Plan.GetState()
    if S.run or state.transfer then return false,'reason.exec.already_running',{} end
    local entries={}
    for _,entry in ipairs(queue) do local copy={};for k,v in pairs(entry) do copy[k]=v end;entries[#entries+1]=copy end
    S.lastFailure=nil
    S.run={queue=entries,index=1,phase='next',casts=0,skips=0,state=state,qcMode=qcMode or 0}
    S.Tick();return true
end
function S.Stop()
    if not S.run then return end
    S.run.cancelled=true
    if BfBot.Exec._state=='running' then
        S.internalStop=true;BfBot.Exec.Stop();S.internalStop=nil
    end
    S.Tick()
end
local function startEntry(run,entry,location)
    local copies={};run.batchEnd=run.index;run.previousCasters={}
    local function barrier(e)
        return e.itemOwner
    end
    -- Preserve per-caster order and saved dispatch priority. A loan or known
    -- dependency fences the batch; independent caster queues execute in parallel.
    if not location and not barrier(entry) then
        while run.batchEnd<#run.queue and not barrier(run.queue[run.batchEnd+1]) do run.batchEnd=run.batchEnd+1 end
    end
    for i=run.index,run.batchEnd do
        local copy={};for k,v in pairs(run.queue[i]) do copy[k]=v end
        copy.itemOwner=nil
        if location then copy.plannedItemSlot=location.slot end
        copies[#copies+1]=copy
        local ref=copy.casterRef or {kind='party',slot=copy.caster}
        run.previousCasters[BfBot.Exec._CasterKey(ref)]=ref
    end
    S.internal=true
    local ok=BfBot.Exec.Start(copies,0,nil)
    S.internal=nil
    if not ok then run.skips=run.skips+#copies;run.phase='return' else run.phase='cast' end
end

function S.Tick()
    if e and worldScreen and e:GetActiveEngine()~=worldScreen then return end
    if BfBot.Exec.PumpItemAdvances then BfBot.Exec.PumpItemAdvances() end
    local now=Infinity_GetClockTicks()
    if S.lastPoll and now>=S.lastPoll and now-S.lastPoll<100 then return end
    S.lastPoll=now
    local state=BfBot.Plan.GetState();if not state then return end
    local run=S.run
    if run and run.state~=state then
        S.run=nil;run=nil
    end -- save changed: recover saved journal only
    if run and not run.cancelled and BfBot.Rest and BfBot.Rest.Combat() then S.Stop();return end
    local j=state.transfer
    if j then
        local owner=actor(j.owner);local borrower=actor(j.borrower);local location=locate(j.item)
        if not owner or not borrower or not BfBot.Exec._IsAlive(owner) or not BfBot.Exec._IsAlive(borrower)
            or not sameArea(owner,borrower) or not location or not matching(location.item,j) then
            if not S.reportedRecovery then fail('gear changed or character unavailable; automatic return paused');S.reportedRecovery=true end
            if run then finish('stopped') end
            return
        end
        if BfBot.Persist.GetItemSwap(borrower) then return end -- existing equipment recovery finishes first
        if run and run.phase=='cast' then
            if BfBot.Exec._state=='running' then return end
            run.casts=run.casts+BfBot.Exec._castCount;run.skips=run.skips+BfBot.Exec._skipCount
            run.phase='return'
        end
        if run and run.phase=='receiving' and not run.cancelled and location.key==j.borrower then
            local allowed=BfBot.Scan._NativeCanWearItem(borrower,location.item)
            if allowed==true then BfBot.Scan.InvalidateAll();startEntry(run,run.queue[run.index],location);return end
            fail('recipient can no longer wear this item')
        end
        local recovering=not run or run.cancelled or run.phase=='return' or run.phase=='reposition'
        if recovering then
            if location.key==j.owner and location.slot==j.pack then
                -- A cancelled/loaded run may still have its forward GiveItem
                -- queued. Keep the journal until that action has settled.
                if not EEex_Trigger_EvalConditionalStringAsAIBase('ActionListEmpty()',owner)
                    or not EEex_Trigger_EvalConditionalStringAsAIBase('ActionListEmpty()',borrower) then return end
                state.transfer=nil;S.reportedRecovery=nil
                BfBot.Scan.InvalidateAll()
                if run then run.index=(run.batchEnd or run.index)+1;run.batchEnd=nil;run.phase='next' end
            elseif location.key==j.borrower then
                if not freePack(owner) or itemAt(owner,j.pack) then fail('original backpack slot is occupied; return paused');return end
                if not S.returnSent or now-S.returnSent>4000 then give(borrower,owner,j.item);S.returnSent=now end
                if run then run.phase='return' end
                return
            elseif location.key==j.owner then
                if itemAt(owner,j.pack) then fail('original backpack slot is occupied; return paused');return end
                if not S.repositionSent or now-S.repositionSent>4000 then
                    local ok,reason=BfBot.Scan._NativeMoveToBackpack(owner,location.slot,j.pack)
                    if not ok then fail(reason or 'item reposition failed');return end
                    S.repositionSent=now
                end
                if run then run.phase='reposition' end
                return
            else fail('item moved to another character; return paused');return end
        elseif run and run.phase=='receiving' and now-run.since>10000 then
            fail('item transfer timed out');return
        else return end
    end
    if not run then return end
    if run.phase=='cast' and BfBot.Exec._state~='running' then
        if BfBot.Exec._state=='stopped' then run.cancelled=true end
        run.casts=run.casts+BfBot.Exec._castCount;run.skips=run.skips+BfBot.Exec._skipCount
        run.index=(run.batchEnd or run.index)+1;run.batchEnd=nil;run.phase='next'
    end
    if run.cancelled then finish('stopped');return end
    if run.phase=='return' and not state.transfer then run.index=(run.batchEnd or run.index)+1;run.batchEnd=nil;run.phase='next' end
    if run.phase~='next' then return end
    -- Let the previous cast's helper removal/equipment restoration finish before
    -- scanning the next entry. Otherwise the helper looks like a real speed bonus.
    for _,ref in pairs(run.previousCasters or {}) do
        local previous=BfBot.Exec._ResolveCaster(ref)
        if previous and not EEex_Trigger_EvalConditionalStringAsAIBase('ActionListEmpty()',previous) then return end
    end
    local entry=run.queue[run.index]
    if not entry then finish();return end
    if entry.itemOwner then
        local owner=actor(entry.itemOwner);local borrower=actor(entry.plannedActor)
        local location=locate(entry.sharedItem)
        if not owner or not borrower or not location or location.key~=entry.itemOwner or location.slot~=entry.plannedItemSlot
            or not sameArea(owner,borrower) or not freePack(borrower)
            or BfBot.Scan._NativeCanWearItem(borrower,location.item)~=true then
            fail('planned item is no longer safely shareable');finish('stopped');return
        end
        local record=fingerprint(location.item)
        record.item,record.owner,record.borrower,record.pack=entry.sharedItem,entry.itemOwner,entry.plannedActor,location.slot
        state.transfer=assert(S.ValidateJournal(record)) -- save before the first engine action
        S.returnSent,S.repositionSent=nil,nil
        run.phase,run.since='receiving',now
        give(owner,borrower,record.item)
    else startEntry(run,entry) end
end
function S.Reset()
    S.run,S.lastPoll,S.returnSent,S.repositionSent,S.reportedRecovery,S.lastFailure=nil,nil,nil,nil,nil,nil
end
