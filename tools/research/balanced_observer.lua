-- Observation ledger only: consumes plain snapshots, never calls game APIs.
-- A unique match is a candidate, NOT proof of ownership and never owned=true.
local M = {}
local MAX = 9007199254740991
local function integer(n)
    return type(n)=='number' and n==math.floor(n) and math.abs(n)<=MAX
end
local function text(s) return type(s)=='string' and #s>0 and #s<=200 end
local function array(t, limit)
    if type(t)~='table' or #t>limit then return false end
    local n=0
    for k in pairs(t) do
        if not integer(k) or k<1 or k>#t then return false end
        n=n+1
    end
    return n==#t
end
local function copy(t)
    if type(t)~='table' then return t end
    local out={};for k,v in pairs(t) do out[k]=copy(v) end;return out
end
local fields={'sourceId','opcode','timing','rawDuration','param1','param2','sourceType'}
local function effect(e)
    if type(e)~='table' or not text(e.token) or type(e.sourceRes)~='string'
        or type(e.resource)~='string' or #e.resource>8 or #e.sourceRes>8 then return nil end
    local out={token=e.token,sourceRes=e.sourceRes:upper(),resource=e.resource:upper()}
    for _,k in ipairs(fields) do if not integer(e[k]) then return nil end;out[k]=e[k] end
    return out
end
local function snapshot(input)
    if type(input)~='table' or input.complete~=true or not text(input.epoch)
        or not integer(input.tick) or input.tick<0 or not array(input.actors,6) then
        return nil,'Incomplete or invalid snapshot'
    end
    local out,identities,slots={epoch=input.epoch,tick=input.tick,actors={}},{},{}
    local count=0
    for _,a in ipairs(input.actors) do
        if type(a)~='table' or not integer(a.id) or a.id<0 or identities[a.id]
            or not integer(a.slot) or a.slot<0 or a.slot>5 or slots[a.slot]
            or not text(a.name) or not array(a.effects,4096) then return nil,'Invalid actor snapshot' end
        identities[a.id]=true;slots[a.slot]=true
        local actor={id=a.id,slot=a.slot,name=a.name,effects={}}
        if a.actionId~=nil then
            if not integer(a.actionId) then return nil,'Invalid actor action observation' end
            actor.actionId=a.actionId
        end
        local tokens={}
        for _,e in ipairs(a.effects) do
            count=count+1
            if count>4096 then return nil,'Effect snapshot limit exceeded' end
            local row=effect(e)
            if not row or tokens[row.token] then return nil,'Invalid or duplicate effect observation' end
            tokens[row.token]=true;actor.effects[#actor.effects+1]=row
        end
        out.actors[#out.actors+1]=actor
    end
    out.effectCount=count
    return out
end
local Session={};Session.__index=Session
function Session:_stop(reason)
    self.status='stopped';self.reason=reason
    return nil,reason
end
local function actorMap(s)
    local out={};for _,a in ipairs(s.actors) do out[a.id]=a end;return out
end
local function same(a,b)
    -- Duration may count down or encode expiry. Log it, but do not interpret it
    -- or use its changes alone to assert that an effect is new/replaced.
    for _,k in ipairs({'sourceId','sourceRes','opcode','timing','param1','param2','sourceType','resource'}) do
        if a[k]~=b[k] then return false end
    end
    return true
end
function M.New(runId, baseline)
    if not text(runId) then return nil,'Invalid run identity' end
    local initial,why=snapshot(baseline)
    if not initial then return nil,why end
    return setmetatable({runId=runId,status='observing',epoch=initial.epoch,
        baseline=initial,last=initial,samples={initial},casts={},castOrder={},
        changes={},seen={},reason=nil,retainedEffects=initial.effectCount},Session)
end
function Session:BeginCast(spec)
    if self.status~='observing' then return nil,'Session is stopped' end
    if #self.castOrder>=256 then return self:_stop('Cast observation limit exceeded') end
    if type(spec)~='table' or not text(spec.id) or self.casts[spec.id]
        or not integer(spec.sourceId) or not array(spec.targets,6) or #spec.targets==0
        or not array(spec.resources,32) or #spec.resources==0 or spec.tick~=self.last.tick then
        return nil,'Invalid cast marker or missing same-tick baseline'
    end
    local actors=actorMap(self.last)
    if not actors[spec.sourceId] then return nil,'Caster is not an observed party actor' end
    local cast={id=spec.id,sourceId=spec.sourceId,start=spec.tick,targets={},resources={},phases={}}
    for _,id in ipairs(spec.targets) do
        if not integer(id) or not actors[id] or cast.targets[id] then return nil,'Invalid target identity' end
        cast.targets[id]=true
    end
    for _,res in ipairs(spec.resources) do
        if not text(res) or #res>8 or cast.resources[res:upper()] then return nil,'Invalid resource identity' end
        cast.resources[res:upper()]=true
    end
    -- A marker describes the controller's observation, not an issued spell.
    self.casts[cast.id]=cast;self.castOrder[#self.castOrder+1]=cast.id
    return true
end
function Session:Phase(id, phase, tick)
    if self.status~='observing' then return nil,'Session is stopped' end
    local cast=self.casts[id]
    if not cast or (phase~='release' and phase~='ready' and phase~='closed')
        or not integer(tick) or tick~=self.last.tick or tick<cast.start or cast.phases[phase] then
        return nil,'Invalid phase marker'
    end
    if phase~='release' and not cast.phases.release then return nil,'Release marker required first' end
    if cast.phases.release and tick<cast.phases.release then return nil,'Phase time reversed' end
    cast.phases[phase]=tick
    return true
end
function Session:Sample(input)
    if self.status~='observing' then return nil,'Session is stopped' end
    local s,why=snapshot(input)
    if not s then return self:_stop(why) end
    if s.epoch~=self.epoch then return self:_stop('Load/epoch changed') end
    if s.tick<self.last.tick then return self:_stop('Game clock reversed') end
    if #self.samples>=512 then return self:_stop('Snapshot observation limit exceeded') end
    if self.retainedEffects+s.effectCount>32768 then return self:_stop('Retained effect observation limit exceeded') end
    for _,cast in pairs(self.casts) do
        for _,when in pairs(cast.phases) do
            if s.tick<when then return self:_stop('Sample precedes recorded phase') end
        end
    end
    local old,new=actorMap(self.last),actorMap(s)
    for id,a in pairs(old) do
        local b=new[id]
        if not b or b.slot~=a.slot or b.name~=a.name then return self:_stop('Party identity changed') end
    end
    for id in pairs(new) do if not old[id] then return self:_stop('Party identity changed') end end
    local delta={}
    for _,a in ipairs(s.actors) do
        local before,after={},{}
        for _,e in ipairs(old[a.id].effects) do before[e.token]=e end
        for _,e in ipairs(a.effects) do after[e.token]=e end
        for _,e in ipairs(a.effects) do
            local previous=before[e.token]
            if not previous or not same(previous,e) then
                local kind=previous and 'changed_or_reused' or 'newly_observed'
                local candidates={}
                for _,id in ipairs(self.castOrder) do
                    local c=self.casts[id]
                    -- The effect arrived at an unknown point in this sample
                    -- interval. Retain closed casts if that interval overlaps
                    -- their window; never manufacture certainty by filtering
                    -- only against the interval's final tick.
                    if c.sourceId==e.sourceId and c.targets[a.id] and c.resources[e.sourceRes]
                        and c.start<=s.tick and (not c.phases.closed or c.phases.closed>=self.last.tick) then
                        candidates[#candidates+1]=id
                    end
                end
                local tokenKey=tostring(a.id)..'/'..e.token
                local reused=not previous and self.seen[tokenKey] or previous~=nil
                local reason=kind=='changed_or_reused' and 'Existing instance changed or address reused'
                    or reused and 'Previously observed token reappeared'
                    or #candidates==0 and 'No matching observed cast'
                    or #candidates>1 and 'Overlapping matching cast windows'
                    or 'Unique matching window; ownership still unproved'
                delta[#delta+1]={kind=kind,actorId=a.id,fromTick=self.last.tick,toTick=s.tick,
                    effect=copy(e),candidates=candidates,ambiguous=reused or #candidates~=1,
                    ownership='unproved',reason=reason}
            end
        end
        for _,e in ipairs(old[a.id].effects) do
            self.seen[tostring(a.id)..'/'..e.token]=true
            if not after[e.token] then
                delta[#delta+1]={kind='removed',actorId=a.id,fromTick=self.last.tick,
                    toTick=s.tick,effect=copy(e),candidates={},ambiguous=true,
                    ownership='unproved',reason='Removal is not attributed to a cast'}
            end
        end
    end
    if #self.changes+#delta>2048 then return self:_stop('Effect change observation limit exceeded') end
    for _,row in ipairs(delta) do self.changes[#self.changes+1]=row end
    self.last=s;self.samples[#self.samples+1]=s
    self.retainedEffects=self.retainedEffects+s.effectCount
    return copy(delta)
end
function Session:Stop(reason)
    if self.status~='observing' then return nil,'Session is stopped' end
    if not text(reason) then return nil,'Stop reason required' end
    self.status='stopped';self.reason=reason;return true
end
function Session:Export()
    local casts={};for _,id in ipairs(self.castOrder) do casts[#casts+1]=copy(self.casts[id]) end
    return {schema=1,runId=self.runId,status=self.status,reason=self.reason,
        epoch=self.epoch,baseline=copy(self.baseline),samples=copy(self.samples),
        casts=casts,changes=copy(self.changes),ownershipProven=false,mutationsPerformed=0}
end
return M
