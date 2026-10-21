-- Party-wide recipient plans. Persistent requests contain identities, never
-- sprite pointers or reservations; every preview/run plans a fresh snapshot.
BfBot.Plan = {}
local P = BfBot.Plan
P.MAX_REQUESTS = 256

local _textKeys = {
    ["Recipient"] = "party.text103",
    ["Caster"] = "party.text104",
    ["Move"] = "party.text105",
    ["Recipient: "] = "party.text106",

    ["Shared uses: "] = "party.text96",
    ["Sources: "] = "party.text97",
    ["Variants spend the same parent spell uses."] = "party.text98",
    ["Available casters and durations. Select recipients in the main list."] = "party.text99",
    ["Caster: "] = "party.text100",
    ["Uses: "] = "party.text101",
    ["Hide spell and all variants"] = "party.text102",

    ["Sort by longest duration"] = "party.text95",
    ["Actions"] = "party.text93",
    ["Icon"] = "party.text89",
    ["Name"] = "party.text90",
    ["Uses"] = "party.text91",
    ["Duration"] = "party.text92",
    ["Free / total uses"] = "party.text94",

    ["Search"] = "party.text88",
    ["Item"] = "party.text67",
    ["Spell"] = "party.text68",
    ["None"] = "party.text69",
    ["All buffs"] = "party.text70",
    ["Recipients"] = "party.text71",
    ["Everyone"] = "party.text72",
    ["Off"] = "party.text73",
    ["Hide"] = "party.text74",
    ["Buffs"] = "party.text75",
    ["Summary"] = "party.text76",
    ["Coverage"] = "party.text77",
    ["Order"] = "party.text78",
    ["Show ineligible"] = "party.text79",
    ["Clear"] = "party.text80",
    ["Add spell / item"] = "party.text81",
    ["Hidden"] = "party.text82",
    ["Cast"] = "party.text83",
    ["Save"] = "party.text84",
    ["Cancel"] = "party.text85",
    ["New preset"] = "party.text86",
    ["Options"] = "party.text87",
    ["Preferred caster unavailable"] = "party.text01",
    ["Recipient unavailable"] = "party.text02",
    ["Recipient is dead"] = "party.text03",
    ["Ambiguous recipient identity"] = "party.text04",
    ["Self only"] = "party.text05",
    ["Party-wide cast"] = "party.text06",
    ["Choose a recipient"] = "party.text07",
    ["Choose a supported variant"] = "party.text08",
    ["Variant unavailable from this caster"] = "party.text09",
    ["No eligible source"] = "party.text10",
    ["Buff unavailable"] = "party.text11",
    ["Disabled"] = "party.text12",
    ["No unreserved uses"] = "party.text13",
    ["5E sources require the caster editor"] = "party.text14",
    ["Caster class unavailable"] = "party.text15",
    ["Ambiguous character identity"] = "party.text16",
    ["Caster is dead"] = "party.text17",
    ["Caster controlled by another player"] = "party.text18",
    ["Variant metadata unavailable"] = "party.text19",
    ["Long Buffs"] = "party.text20",
    ["Short Buffs"] = "party.text21",
    ["Preset "] = "party.text22",
    ["Plan exceeds 256 requests"] = "party.text23",
    ["Legacy source unavailable: "] = "party.text24",
    ["Legacy recipient unavailable: "] = "party.text25",
    ["Project Image locks a planned caster"] = "party.text26",
    ["Permanent"] = "party.text27",
    ["Instant/unknown"] = "party.text28",
    ["At will"] = "party.text29",
    ["Party"] = "party.text30",
    ["Auto"] = "party.text31",
    ["Source: "] = "party.text32",
    [" / effective caster level "] = "party.text33",
    ["Select a planned buff to change its source or order."] = "party.text34",
    ["Maximum 256 planned casts"] = "party.text35",
    ["Variant: "] = "party.text36",
    ["Select recipients below"] = "party.text37",
    ["Maximum eight presets"] = "party.text38",
    ["Import into an empty preset"] = "party.text39",
    ["Party planning is a single-player beta; use the caster editor"] = "party.text40",
    ["Resolve unavailable casts before casting"] = "party.text41",
    [" planned / "] = "party.text42",
    [" unavailable"] = "party.text43",
    ["Caster editor"] = "party.text44",
    ["Close"] = "party.text45",
    ["Rename"] = "party.text46",
    ["New"] = "party.text47",
    ["Import caster preset"] = "party.text48",
    ["Refresh"] = "party.text49",
    ["Source: next"] = "party.text50",
    ["Up"] = "party.text51",
    ["Down"] = "party.text52",
    ["Remove"] = "party.text53",
    ["Cast plan"] = "party.text54",
    ["Stop"] = "party.text55",
    ["BuffBot - Recipient plans (beta)"] = "party.text56",
    ["Available buffs / duration / unreserved uses"] = "party.text57",
    ["Planned buffs / recipient / caster and duration"] = "party.text58",
    [" / improved invisible"] = "party.text59",
    ["Target has Improved Invisibility; the engine may reject this cast."] = "party.text60",
    ["After rest: off"] = "party.text61",
    ["After rest: "] = "party.text62",
    ["Rest plan skipped: combat"] = "party.text63",
    ["Rest plan is empty"] = "party.text64",
    ["Rest plan skipped: resolve unavailable casts"] = "party.text65",
    ["Casting rest plan"] = "party.text66",
}
function P.Text(english)
    if BfBot.L10N and _textKeys[english] then return BfBot.L10N.Get(_textKeys[english]) end
    return english
end

local function integer(n, lo, hi)
    return type(n) == "number" and n == math.floor(n) and n >= lo and n <= hi
end
local function text(s, limit)
    return type(s) == "string" and #s > 0 and #s <= limit and not s:find("%c")
end
function P.ActorKey(sprite)
    if EEex_Sprite_GetCharacterIndex(sprite) == 0 then return "protagonist" end
    local dv = BfBot._GetDeathVar(sprite)
    if dv ~= "" and dv:upper() ~= "NONE" then return "dv:" .. dv:upper() end
    return "name:" .. BfBot._GetName(sprite)
end
-- Recipient identities remain party-only. Caster identities additionally admit
-- allied spellcasting summons. Never persist the spawn's temporary object ID.
function P.CasterKey(sprite, descriptor)
    if EEex_Sprite_GetPortraitIndex(sprite) ~= -1 then return P.ActorKey(sprite) end
    local e = descriptor or BfBot.Scan.ClassifySummonSprite(sprite)
    if not e then return nil end
    if e.kind == 'clone' then
        local owner = EEex_GameObject_Get(sprite.m_nCopyParent)
        if not owner or not EEex_GameObject_IsSprite(owner, false) then return nil end
        owner = EEex_GameObject_CastUserType(owner)
        if EEex_Sprite_GetPortraitIndex(owner) == -1 then return nil end
        return 'summon:clone:' .. P.ActorKey(owner) .. ':' .. tostring(e.cloneType or 0)
    end
    return 'summon:' .. e.identity
end
function P.CasterActor(snapshot, key)
    return (snapshot.casterActors or snapshot.actors)[key]
end
function P.CloneLabel(kind)
    return ({[1]='Mislead',[2]='Project Image',[3]='Simulacrum'})[kind] or 'Clone'
end
function P.CasterLabel(snapshot, key)
    local actor=P.CasterActor(snapshot,key)
    if actor then return actor.name end
    if type(key)=='string' and key:sub(1,7)=='summon:' then
        local owner,kind=key:match('^summon:clone:(.*):(%d+)$')
        local party=owner and snapshot.actors[owner]
        return party and (party.name..' ('..P.CloneLabel(tonumber(kind))..')') or 'Summon unavailable'
    end
    return key
end
function P.GroupKey(row)
    if row.kind == "itm" then
        return "itm:" .. row.itemResref:upper() .. ":" .. row.abilityIdx
    end
    return "spl:" .. row.resref:upper()
end

-- Pure allocation core. All sources spend one unit from exactly one pool.
-- Augmenting paths avoid wasting a scarce source needed by a later request.
-- Earlier recipients keep the stronger cast unless moving it is necessary
-- to satisfy another request. No mutation of sources, requests, or pool caps.
function P.SourceAllowed(snapshot, s, r)
    if s.reason then return false, s.reason end
    if r.source and r.source ~= s.actor then return false, P.Text("Preferred caster unavailable") end
    if r.target ~= "party" and not snapshot.actors[r.target] then
        return false, P.Text("Recipient unavailable")
    end
    if r.target ~= "party" and snapshot.actors[r.target].alive == false then
        return false, P.Text("Recipient is dead")
    end
    if r.target ~= "party" and snapshot.actors[r.target].ambiguous then
        return false, P.Text("Ambiguous recipient identity")
    end
    if s.selfOnly and r.target ~= s.actor then return false, P.Text("Self only") end
    if s.aoe and r.target ~= "party" then return false, P.Text("Party-wide cast") end
    if not s.aoe and r.target == "party" then return false, P.Text("Choose a recipient") end
    if s.variants and #s.variants > 0 then
        local found = false
        for _, v in ipairs(s.variants) do if v.resref == r.var then found = true end end
        if not found then return false, P.Text("Choose a supported variant") end
    elseif r.var then return false, P.Text("Variant unavailable from this caster") end
    return true
end
function P.SourceDuration(s, r)
    return (r.var and s.variantDurations and s.variantDurations[r.var]) or s.duration or 0
end
function P.BetterSource(a, b, r)
    local ad, bd = P.SourceDuration(a, r), P.SourceDuration(b, r)
    if ad == -1 then ad = math.huge end
    if bd == -1 then bd = math.huge end
    if ad ~= bd then return ad > bd end
    if (a.casterLevel or 0) ~= (b.casterLevel or 0) then
        return (a.casterLevel or 0) > (b.casterLevel or 0)
    end
    return a.id < b.id
end
function P.Assign(snapshot, requests)
    local result = { decisions = {}, used = {}, missing = 0 }
    local candidates, occupants = {}, {}
    local function move(i, visited)
        -- Prefer any free source before displacing an earlier recipient.
        for _, source in ipairs(candidates[i]) do
            local pool = source.pool
            local bucket = occupants[pool] or {}
            if not visited[pool] and #bucket < (snapshot.pools[pool] or 0) then
                occupants[pool] = bucket
                bucket[#bucket + 1] = i
                result.decisions[i].source = source
                return true
            end
        end
        for _, source in ipairs(candidates[i]) do
            local pool = source.pool
            if not visited[pool] then
                visited[pool] = true
                local bucket = occupants[pool] or {}
                occupants[pool] = bucket
                if #bucket < (snapshot.pools[pool] or 0) then
                    bucket[#bucket + 1] = i
                    result.decisions[i].source = source
                    return true
                end
                -- Move the latest prior recipient first, retaining the
                -- strongest source for earlier priorities where possible.
                for j = #bucket, 1, -1 do
                    local old = bucket[j]
                    if move(old, visited) then
                        bucket[j] = i
                        result.decisions[i].source = source
                        return true
                    end
                end
            end
        end
        return false
    end
    for i, request in ipairs(requests) do
        if i > P.MAX_REQUESTS then break end
        local decision = { request = request }
        result.decisions[i], candidates[i] = decision, {}
        local group = snapshot.groups[request.group]
        local reason = group and P.Text("No eligible source") or P.Text("Buff unavailable")
        for _, s in ipairs(group and group.sources or {}) do
            local ok, why = P.SourceAllowed(snapshot, s, request)
            if ok then candidates[i][#candidates[i] + 1] = s else reason = why end
        end
        table.sort(candidates[i], function(a, b) return P.BetterSource(a, b, request) end)
        if request.on == 0 then decision.reason = P.Text("Disabled")
        elseif not move(i, {}) then
            decision.reason = #candidates[i] > 0 and P.Text("No unreserved uses") or reason
            result.missing = result.missing + 1
        end
    end
    for _, d in ipairs(result.decisions) do
        if d.source then
            d.duration = P.SourceDuration(d.source, d.request)
            result.used[d.source.pool] = (result.used[d.source.pool] or 0) + 1
        end
    end
    return result
end

-- Explicit plan-order tools. These never change requests, targets or caster locks.
-- Smart order is a bounded heuristic, scored by the worst retained lifetime
-- fraction after per-caster aura/release simulation, then total retained fraction.
function P.CastAges(jobs)
    local phases,phase={},{}
    for i,job in ipairs(jobs) do
        if job.boundary then phases[#phases+1]=phase;phase={}
        else phase[#phase+1]={index=i,job=job} end
    end
    phases[#phases+1]=phase
    -- First find the earliest feasible finish. Do not delay a fast lane at an
    -- intermediate fence: its aura may be needed by a later phase.
    local finish,ready=0,{}
    for _,entries in ipairs(phases) do
        local phaseStart=finish
        for _,entry in ipairs(entries) do
            local job=entry.job
            local start=math.max(phaseStart,ready[job.caster] or 0)
            finish=math.max(finish,start+job.release)
            ready[job.caster]=start+math.max(job.release,job.aura and 0 or 100)
        end
    end
    -- Then place each cast as late as its successors allow. This implements
    -- JIT without resetting aura at fences or extending the preparation time.
    local deadline,nextStart,ages=finish,{},{}
    for i=#phases,1,-1 do
        local first=deadline
        for j=#phases[i],1,-1 do
            local entry=phases[i][j];local job=entry.job
            local start=deadline-job.release
            if nextStart[job.caster] then
                start=math.min(start,nextStart[job.caster]-math.max(job.release,job.aura and 0 or 100))
            end
            ages[entry.index]=finish-start-job.release
            nextStart[job.caster]=start;first=math.min(first,start)
        end
        deadline=first
    end
    return ages,finish
end

local function orderScore(entries)
    local jobs,positions={},{}
    for i,e in ipairs(entries) do
        if e.barrier then jobs[#jobs+1]={boundary=true} end
        jobs[#jobs+1]=e;positions[i]=#jobs
        if e.barrier then jobs[#jobs+1]={boundary=true} end
    end
    local ages=P.CastAges(jobs);local worst,total=1,0
    for i,e in ipairs(entries) do
        if e.duration>0 then
            local retained=1-ages[positions[i]]/(e.duration*15)
            worst=math.min(worst,retained);total=total+retained
        end
    end
    return worst,total
end
local function improves(a,b,c,d) return a>c+0.0000001 or math.abs(a-c)<0.0000001 and b>d+0.0000001 end
-- Read-only Order estimates; no effect hooks or expiry writes.
function P.CastingSegments(raw,kind,speed)
    -- CDerivedStats::GetCastingTime, BG2EE 2.6.6. Opcode 189 supports
    -- subtractive, absolute and maximum casting times.
    if kind==0 then return math.max(0,raw-speed) end
    if kind==1 then return math.max(0,speed) end
    return math.max(0,math.min(raw,speed))
end
function P.OrderPrerequisite(row,sprite)
    if row.isProjectImage==1 then return true,true end
    local barrier,prerequisite=false,false
    local visited,budget={},128
    local scanSpell
    local function scan(h,start,count,depth)
        for i=start,start+count-1 do
            budget=budget-1;if budget<0 then barrier=true;return end
            local e=EEex_PtrToUD(EEex_UDToPtr(h)+h.effectsOffset+i*Item_effect_st.sizeof,'Item_effect_st')
            if e.effectID==188 or e.effectID==189 then barrier=true;prerequisite=true
            elseif e.effectID==146 or e.effectID==148 or e.effectID==232 or e.effectID==326 then
                local r=e[BfBot._fields and BfBot._fields.fb_res or 'res']
                if type(r)=='table' or type(r)=='userdata' then r=r:get() end
                if type(r)~='string' or r=='' then barrier=true
                else scanSpell(r,depth+1) end
            end
        end
    end
    scanSpell=function(res,depth)
        res=res:upper();if visited[res] then return end
        if depth>8 then barrier=true;return end
        visited[res]=true
        local h=EEex_Resource_Demand(res,'SPL')
        local a=h and h:getAbilityForLevel(row.casterLevel or 1)
        if not a then barrier=true;return end
        scan(h,h.castingStartingEffect,h.castingEffectCount,depth)
        scan(h,a.startingEffect,a.effectCount,depth)
    end
    if row.kind=='itm' then
        local h=EEex_Resource_Demand(row.itemResref,'ITM')
        local a=h and BfBot.Scan._GetItemAbility(h,row.abilityIdx or 0)
        if not a then return true,false end
        scan(h,a.startingEffect,a.effectCount,0)
    else scanSpell(row.resref,0) end
    return barrier,prerequisite
end

-- Inspect only on planning/start, never in an effect callback or world tick.
function P.DeliversInvisibility(row,variant)
    if not EEex_Resource_Demand then return false end
    local seen,budget={},128
    local visitSpell,visitEffect
    local function effects(h,start,count)
        for i=start,start+count-1 do
            budget=budget-1;if budget<0 then return false end
            local e=EEex_PtrToUD(EEex_UDToPtr(h)+h.effectsOffset+i*Item_effect_st.sizeof,'Item_effect_st')
            local r=e[BfBot._fields and BfBot._fields.fb_res or 'res']
            if type(r)=='table' or type(r)=='userdata' then r=r:get() end
            if visitEffect(e.effectID,r) then return true end
        end
        return false
    end
    visitEffect=function(op,res)
        if op==20 then return true end
        if type(res)~='string' or res=='' or budget<=0 then return false end
        if op==146 or op==148 or op==326 or op==232 then return visitSpell(res) end
        if op==177 or op==272 then
            local key='EFF:'..res:upper();if seen[key] then return false end
            seen[key]=true;budget=budget-1
            local e=EEex_Resource_Demand(res,'EFF');if not e then return false end
            local r=e.m_res;if type(r)=='table' or type(r)=='userdata' then r=r:get() end
            return visitEffect(e.m_effectId,r)
        end
        return false
    end
    visitSpell=function(res)
        local key='SPL:'..res:upper();if seen[key] or budget<=0 then return false end
        seen[key]=true;budget=budget-1
        local h=EEex_Resource_Demand(res,'SPL')
        local a=h and h:getAbilityForLevel(row.casterLevel or 1)
        return a and (effects(h,h.castingStartingEffect or 0,h.castingEffectCount or 0)
            or effects(h,a.startingEffect or 0,a.effectCount or 0)) or false
    end
    local ok,found=pcall(function()
        if row.kind=='itm' and not variant then
            local h=EEex_Resource_Demand(row.itemResref,'ITM')
            local a=h and BfBot.Scan._GetItemAbility(h,row.abilityIdx or 0)
            return a and effects(h,a.startingEffect or 0,a.effectCount or 0) or false
        end
        return visitSpell(variant or row.resref)
    end)
    return ok and found==true
end

function P.EstimateCast(source)
    local row=source.row or {}
    local sprite=source.casterRef and BfBot.Exec._ResolveCaster(source.casterRef)
        or source.slot~=nil and EEex_Sprite_GetInPortrait(source.slot)
    local stats=sprite and EEex_Sprite_GetActiveStats(sprite)
    local timing={release=100,aura=stats and stats.m_bAuraCleansing~=0 or false,
        barrier=source.itemOwner~=nil}
    if not sprite then timing.barrier=true;return timing end
    local ok,barrier,prerequisite=pcall(P.OrderPrerequisite,row,sprite)
    timing.prerequisite=ok and prerequisite==true
    timing.ownerPrerequisite=row.isProjectImage==1
    timing.barrier=timing.barrier or not ok or barrier
    if row.kind=='spl' then
        local h=EEex_Resource_Demand(row.resref,'SPL')
        local a=h and h:getAbilityForLevel(row.casterLevel or 1)
        if a and stats then timing.release=P.CastingSegments(a.speedFactor,stats.m_nCastingType,stats.m_nMentalSpeed)*10+4 end
    end
    return timing
end

function P.SortRequests(snapshot,requests,mode,estimate)
    if mode~='smart' and mode~='long' then return requests,false end
    local original=P.Assign(snapshot,requests)
    local ranks={};for i,r in ipairs(requests) do ranks[r]=i end
    local function describe(list,plan)
        local result={}
        for i,r in ipairs(list) do
            local d=plan.decisions[i];local t=d.source and estimate and estimate(d.source) or {}
            result[i]={request=r,index=ranks[r],caster=d.source and (d.source.lane or d.source.actor) or 'missing',
                actor=d.source and d.source.actor,
                duration=d.duration or 0,release=math.max(0,t.release or 64),aura=t.aura==true,
                unavailable=not d.source,barrier=d.source and (d.source.itemOwner~=nil or t.barrier==true),
                prerequisite=t.prerequisite==true,
                affects=t.ownerPrerequisite and d.source.actor or r.target,
                invisible=mode=='smart' and d.source and P.DeliversInvisibility(d.source.row,r.var),
                party=d.source and (d.source.aoe or d.source.row.isAoE==1) or r.target=='party'}
        end
        return result
    end
    local initial=describe(requests,original)
    -- An execution fence is movable. Only proven prerequisites impose relative
    -- order: preserve casts before/after a modifier on the affected caster(s).
    -- Loans carry their own atomic transfer/use/return; helper spells add no edge.
    local edges={}
    for _,e in ipairs(initial) do
        if e.prerequisite then
            for _,other in ipairs(initial) do
                if other~=e and (e.affects=='party' or other.actor==e.affects) then
                    local a,b=e.request,other.request
                    if e.index>other.index then a,b=b,a end
                    edges[a]=edges[a] or {};edges[a][b]=true
                end
            end
        end
    end
    -- Targeted casts from other casters must precede invisibility on their recipient.
    -- Self and party delivery remain legal after invisibility.
    for _,e in ipairs(initial) do if e.invisible then
        for _,other in ipairs(initial) do
            if other~=e and (not other.invisible or other.index<e.index) and not other.party and other.request.target~='party'
                and other.actor~=other.request.target
                and (e.party or other.request.target==e.request.target) then
                edges[other.request]=edges[other.request] or {}
                edges[other.request][e.request]=true
            end
        end
    end end
    local function longer(a,b)
        if a.unavailable~=b.unavailable then return not a.unavailable end
        local ad=a.duration==-1 and math.huge or a.duration
        local bd=b.duration==-1 and math.huge or b.duration
        if ad~=bd then return ad>bd end
        return a.index<b.index
    end
    local function respects(list)
        local positions={};for i,e in ipairs(list) do positions[e.request]=i end
        for a,targets in pairs(edges) do for b in pairs(targets) do
            if positions[a]>=positions[b] then return false end
        end end
        return true
    end
    local incoming={}
    for a,targets in pairs(edges) do for b in pairs(targets) do
        incoming[b]=incoming[b] or {};incoming[b][a]=true
    end end
    local function longFirst(entries)
        local sorted,used={},{}
        for i=1,#entries do
            local best
            for _,e in ipairs(entries) do if not used[e.request] then
                local ready=true
                for a in pairs(incoming[e.request] or {}) do if not used[a] then ready=false;break end end
                if ready and (not best or longer(e,best)) then best=e end
            end end
            if not best then return entries end
            sorted[i]=best;used[best.request]=true
        end
        return sorted
    end
    local function requestList(entries)
        local list={};for i,e in ipairs(entries) do list[i]=e.request end;return list
    end
    -- Auto sources can rebalance when priorities move. Refresh duration keys
    -- after each allocation so Long first reflects the resulting assignments.
    local baseline=initial
    local seen={}
    for pass=1,4 do
        local entries=longFirst(baseline);local list=requestList(entries)
        local signature={};for i,r in ipairs(list) do signature[i]=ranks[r] end
        signature=table.concat(signature,',')
        baseline=describe(list,P.Assign(snapshot,list))
        if seen[signature] then break end;seen[signature]=true
    end
    local entries={};for i,e in ipairs(baseline) do entries[i]=e end
    if mode=='smart' then
        -- Start from Long first, then accept only measured model improvements.
        -- Execution phases remain part of scoring, never immovable row anchors.
        for pass=1,8 do
            local changed=false
            for i=1,#entries-1 do
                local w,t=orderScore(entries)
                entries[i],entries[i+1]=entries[i+1],entries[i]
                local nw,nt=orderScore(entries)
                if respects(entries) and improves(nw,nt,w,t) then changed=true
                else entries[i],entries[i+1]=entries[i+1],entries[i] end
            end
            if not changed then break end
        end
        local list=requestList(entries);local candidate=describe(list,P.Assign(snapshot,list))
        local bw,bt=orderScore(baseline);local nw,nt=orderScore(candidate)
        if not improves(nw,nt,bw,bt) then entries=baseline end
    end
    local sorted=requestList(entries);local nextPlan=P.Assign(snapshot,sorted);local available={}
    for _,d in ipairs(nextPlan.decisions) do if d.source then available[d.request]=true end end
    for _,d in ipairs(original.decisions) do if d.source and not available[d.request] then return requests,false end end
    local changed=false;for i,r in ipairs(sorted) do changed=changed or r~=requests[i] end
    return changed and sorted or requests,changed
end

-- Native pools. Sorcerer/shaman choices at one level share uses; prepared
-- casters and innates spend the specific resource. 5E stays in the legacy
-- editor until its cross-wrapper pool semantics have been verified here.
function P.SpellPool(actor, row)
    if row.d5 then return nil, P.Text("5E sources require the caster editor") end
    if not integer(actor.class, 1, 21) then return nil, P.Text("Caster class unavailable") end
    if (actor.class == 19 and row.spellType == 1)
        or (actor.class == 21 and row.spellType == 2) then
        return (actor.poolKey or actor.key) .. ":level:" .. row.spellType .. ":" .. row.level
    end
    return (actor.poolKey or actor.key) .. ":spell:" .. row.resref:upper()
end
local function putPool(snapshot, key, count)
    count = integer(count, 0, 1000000) and count or 0
    snapshot.pools[key] = math.min(snapshot.pools[key] or count, count)
end
-- Catalog policy is intentionally narrower than the retained classifier's
-- broad discovery score. Offensive spells can accumulate positive scores from
-- stat changes, protections and bookkeeping states. Keep them in actor.rows
-- for manual Add/import, but do not seed the recipient browser from that score
-- alone. Explicit positive overrides and self/friendly abilities retain intent.
-- Item discovery has its own bounded graph policy and is unchanged here.
function P.IsAutomaticBuff(row)
    local c = row and row.class
    if not c or not c.isBuff or row.requiresChoice then return false end
    -- Combat Expertise activation/deactivation is a combat stance, not a prebuff.
    -- Keep it discoverable via manual Add rather than cluttering automatic rows.
    local resource=row.resref and row.resref:upper() or ''
    if resource=='C0FIG02' or resource=='C0FIG02A' or resource=='C0FIG02B' or resource=='C0FIG02C' then return false end
    if row.kind=='itm' and (row.itemType==11 or row.itemType==35) and not c.overridden then return false end
    if row.kind == "itm" or c.overridden or c.isSelfOnly or c.friendlyFlag then return true end
    return c.msectype ~= 4 and c.msectype ~= 10 and c.msectype ~= 11
end
-- Preserve older caster-centered radial requests when their delivery is
-- recognized as Party. Retain the original caster, order, variants and repeats.
function P.NormalizeRadialRequests(snapshot,requests)
    for _,request in ipairs(requests or {})do
        if request.target~='party' and (not request.source or request.source==request.target) then
            local group=snapshot.groups[request.group]
            for _,source in ipairs(group and group.sources or {})do
                if source.actor==request.target and source.row and source.row.radialParty then
                    request.source=request.source or request.target
                    request.target='party';break
                end
            end
        end
    end
end

function P.Snapshot()
    local owner = BfBot.Persist._GetProtagonist and BfBot.Persist._GetProtagonist()
    local preferences = owner and EEex_GetUDAux(owner).BBParty
    -- A saved selection is deliberate user intent, even when the automatic
    -- browser policy becomes stricter. Include requests from the rest preset
    -- and other presets too: they are executed against the same snapshot.
    local requested = {}
    for i = 1, 8 do
        local preset = preferences and preferences.presets and preferences.presets[i]
        for _, request in ipairs(preset and preset.requests or {}) do
            if type(request) == "table" and type(request.group) == "string"
                and request.on ~= 0 then requested[request.group] = true end
        end
    end
    local snap = { actors = {}, order = {}, groups = {}, pools = {}, casterActors = {}, casters = {} }
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local key = P.ActorKey(sprite)
            local okClass, cls = pcall(function() return sprite.m_typeAI.m_Class end)
            local actor = { key = key, name = BfBot._GetName(sprite), slot = slot,
                casterRef = {kind='party',slot=slot},
                class = okClass and cls or nil, alive = BfBot.Exec._IsAlive(sprite),
                controlled = not BfBot.Mp or BfBot.Mp.IsLocallyControlled(sprite),
                sprite = sprite }
            if EEex_Trigger_EvalConditionalStringAsAIBase then
                local ok, invisible = pcall(EEex_Trigger_EvalConditionalStringAsAIBase,
                    "StateCheck(Myself,STATE_IMPROVEDINVISIBILITY)", sprite)
                actor.improvedInvisible = ok and invisible == true
            end
            if snap.actors[key] then
                snap.actors[key].ambiguous, actor.ambiguous = true, true
            end
            snap.actors[key] = actor
            snap.order[#snap.order + 1] = actor
            snap.casterActors[key] = actor
            snap.casters[#snap.casters + 1] = actor
        end
    end
    if BfBot.Scan.GetAlliedSummons then
        for _, entry in ipairs(BfBot.Scan.GetAlliedSummons()) do
            local ref = {kind='summon',oid=entry.oid,name=entry.name}
            local sprite = BfBot.Exec._ResolveCaster(ref)
            local fresh = sprite and BfBot.Scan.ClassifySummonSprite(sprite)
            local key = fresh and P.CasterKey(sprite, fresh)
            if key then
                if fresh.kind=='clone' and fresh.cloneType==2 then
                    local ownerKey=key:match('^summon:clone:(.*):2$')
                    if snap.actors[ownerKey] then snap.actors[ownerKey].projectImageLocked=true end
                end
                local label = fresh.kind=='clone' and P.CloneLabel(fresh.cloneType) or 'Summon'
                local actor = {key=key,name=entry.name .. ' (' .. label .. ')',
                    poolKey=key .. ':spawn:' .. tostring(entry.oid),
                    casterRef=ref, sprite=sprite, class=sprite.m_typeAI.m_Class,
                    alive=BfBot.Exec._IsAlive(sprite), controlled=not BfBot.Mp
                        or BfBot.Mp.IsSummonLocallyControlled(fresh)}
                -- A saved preference selects this summon identity, while each
                -- live copy retains its own resources and guarded runtime ref.
                snap.casterActors[key]=actor
                snap.casters[#snap.casters+1]=actor
            end
        end
    end
    for _, actor in ipairs(snap.casters) do
        local rows = BfBot.Scan.GetCastableSpells(actor.sprite)
        actor.rows = rows
        for _, row in pairs(rows) do
            -- Register every known native spell, including non-buffs, so
            -- a spontaneous level pool is never the sum of its spell rows.
            local pool, poolReason
            if row.kind ~= "itm" then
                pool, poolReason = P.SpellPool(actor, row)
                if pool then putPool(snap, pool, row.count) end
            end
            local manual = preferences and preferences.include
                and preferences.include[P.GroupKey(row)] == 1
            local summonSelf=actor.casterRef.kind=='summon' and row.isSelfOnly==1 and row.isAoE~=1
            if not summonSelf and row.class and (P.IsAutomaticBuff(row) or manual
                or row.class.isBuff and requested[P.GroupKey(row)]) then
                local key = P.GroupKey(row)
                local group = snap.groups[key]
                if not group then
                    group = { key = key, name = row.name, kind = row.kind,
                        icon = row.icon, sources = {} }
                    snap.groups[key] = group
                end
                local reason = actor.ambiguous and P.Text("Ambiguous character identity")
                    or actor.projectImageLocked and P.Text("Project Image locks a planned caster")
                    or not actor.alive and P.Text("Caster is dead")
                    or not actor.controlled and P.Text("Caster controlled by another player")
                    or row.requiresChoice and P.Text("Choose this item's power manually")
                    or poolReason
                local function add(sourcePool, itemSlot, count)
                    if sourcePool then putPool(snap, sourcePool, count) end
                    local source = { id = (actor.poolKey or actor.key) .. "/" .. key .. "/" .. tostring(itemSlot or "spell"),
                        actor = actor.key, casterName = actor.name, slot = actor.slot,
                        casterRef = actor.casterRef,
                        lane = actor.poolKey or actor.key,
                        row = row, pool = sourcePool or (actor.key .. ":unavailable"),
                        reason = reason, duration = row.duration, casterLevel = row.casterLevel,
                        selfOnly = row.isSelfOnly == 1, aoe = row.isAoE == 1,
                        variants = row.variants, variantDurations = {}, itemSlot = itemSlot }
                    if row.hasVariants == 1 and (not row.variants or #row.variants == 0) then
                        source.reason = P.Text("Variant metadata unavailable")
                    end
                    if row.kind == "itm" and BfBot.Persist.GetPref("ItemUseMode") == "swap"
                        and itemSlot >= 18 and itemSlot <= 33 and row.itemType ~= 9 then
                        if actor.casterRef.kind=='summon' then
                            source.reason=P.Text("Summon item must already be equipped")
                        else
                            local copy = {}
                            for k, v in pairs(row) do copy[k] = v end
                            copy.itemSlot = itemSlot
                            local swap, why = BfBot.Scan._PlanItemSwap(actor.sprite, copy)
                            if not swap then source.reason = why end
                        end
                    end
                    for _, v in ipairs(row.variants or {}) do
                        local ok, d = pcall(function()
                            local h = EEex_Resource_Demand(v.resref, "SPL")
                            local a = h and h:getAbilityForLevel(row.casterLevel or 1)
                            if not a then return 0 end
                            return BfBot.Class.GetDuration(h, a, nil, nil, nil, row.casterLevel)
                        end)
                        source.variantDurations[v.resref] = ok and d or 0
                    end
                    group.sources[#group.sources + 1] = source
                end
                if row.kind == "itm" then
                    for _, item in ipairs(row.sources or {}) do
                        local counter = row.abilityIdx < 3 and row.abilityIdx or 0
                        local itemPool = actor.key .. ":item:" .. item.slot .. ":"
                            .. row.itemResref:upper() .. ":" .. (row.atWill == 1 and "free" or counter)
                        add(itemPool, item.slot, row.atWill == 1 and P.MAX_REQUESTS or item.count)
                    end
                else add(pool, nil, row.count) end
            end
        end
    end
    if BfBot.Share then BfBot.Share.AddSources(snap) end
    for _,preset in pairs(preferences and preferences.presets or {})do
        P.NormalizeRadialRequests(snap,preset.requests)
    end
    return snap
end

function P.Validate(value)
    local state = { v = 1, active = 1, presets = {} }
    local fresh=type(value)~="table" or next(value)==nil
    if type(value) ~= "table" then value = {} end
    for i = 1, 8 do
        local input = type(value.presets) == "table" and value.presets[i]
        if type(input) == "table" then
            local preset = { name = text(input.name, 80) and input.name or (P.Text("Preset ") .. i), requests = {} }
            for _, r in ipairs(type(input.requests) == "table" and input.requests or {}) do
                if #preset.requests >= P.MAX_REQUESTS then break end
                if type(r) == "table" and text(r.group, 100) and text(r.target, 200) then
                    preset.requests[#preset.requests + 1] = { group = r.group, target = r.target,
                        source = text(r.source, 200) and r.source or nil,
                        var = text(r.var, 8) and r.var or nil, on = r.on == 0 and 0 or 1 }
                end
            end
            state.presets[i] = preset
        end
    end
    if not next(state.presets) then
        state.presets[1] = { name = P.Text("Pre-Battle Buffs"), requests = {} }
        state.presets[2] = { name = P.Text("Wake Up Buffs"), requests = {} }
    end
    if integer(value.active, 1, 8) and state.presets[value.active] then state.active = value.active
    else for i = 1, 8 do if state.presets[i] then state.active = i; break end end end
    local rest = type(value.rest) == "table" and value.rest or {}
    local validRest = integer(rest.preset, 1, 8) and state.presets[rest.preset]
    state.rest = { on = rest.on == 1 and validRest and 1 or 0,
        preset = validRest and rest.preset or state.active }
    if fresh then state.rest={on=1,preset=2} end
    state.transfer = BfBot.Share and BfBot.Share.ValidateJournal(value.transfer) or nil
    -- Preserve explicit Normal; migrate retired quick-cast preferences to 2x.
    -- nil follows UI++; explicit skin affects BuffBot only.
    if integer(value.skin,0,3) then state.skin=value.skin end
    state.quick = 0
    state.fast = value.fast~=1 and value.quick==0 and 0 or 1
    state.fastRate = value.fastRate==4 and 4 or 2
    for _, field in ipairs({ "hidden", "include" }) do
        state[field] = {}
        local count = 0
        for key, flag in pairs(type(value[field]) == "table" and value[field] or {}) do
            if text(key, 100) and flag == 1 and count < 1024 then
                state[field][key] = 1; count = count + 1
            end
        end
    end
    return state
end
function P.GetState()
    local owner = BfBot.Persist._GetProtagonist()
    if not owner then return nil end
    local aux = EEex_GetUDAux(owner)
    if not aux.BBParty then aux.BBParty = P.Validate(nil) end
    return aux.BBParty
end
function P.Init()
    if BfBot._partyMarshalRegistered then return end
    EEex_Sprite_AddMarshalHandlers("BuffBotParty",
        function(sprite)
            local okCopy, copying = pcall(function() return EEex.IsMarshallingCopy() end)
            if okCopy and copying then return {} end
            local state = EEex_GetUDAux(sprite).BBParty
            return state and BfBot.Plan.Validate(state) or {}
        end,
        function(sprite, data)
            if type(data) == "table" and data.v == 1 then
                EEex_GetUDAux(sprite).BBParty = BfBot.Plan.Validate(data)
            end
        end)
    BfBot._partyMarshalRegistered = true
end

-- Explicit migration leaves the original caster presets intact and preserves
-- source locks, variants, repeats and per-caster priority in the new plan.
function P.ImportLegacy(snapshot, index)
    local requests = {}
    local entries = {}
    for _, actor in ipairs(snapshot.order) do
        local config = BfBot.Persist.GetConfig(actor.sprite)
        local preset = config and config.presets[index]
        for resource, cfg in pairs(preset and preset.spells or {}) do
            local row = actor.rows[resource]
            if cfg.on == 1 and not row then return nil, P.Text("Legacy source unavailable: ") .. resource end
            if cfg.on == 1 and row then
                entries[#entries + 1] = { actor = actor, row = row, cfg = cfg,
                    key = P.GroupKey(row), resource = resource }
            end
        end
    end
    table.sort(entries, function(a, b)
        if (a.cfg.pri or 999) ~= (b.cfg.pri or 999) then return (a.cfg.pri or 999) < (b.cfg.pri or 999) end
        return a.actor.key .. a.resource < b.actor.key .. b.resource
    end)
    for _, e in ipairs(entries) do
        local targets = BfBot.Persist._ResolveConfigTarget(e.cfg.tgt,
            e.actor.slot, e.resource, e.cfg.pri or 999)
        if #targets == 0 then return nil, P.Text("Legacy recipient unavailable: ") .. e.resource end
        for _, t in ipairs(targets) do
            local keys = {}
            if t.target == "self" then keys[1] = e.row.radialParty and "party" or e.actor.key
            elseif t.target == "all" then
                if e.row.isAoE == 1 then keys[1] = "party"
                else for _, a in ipairs(snapshot.order) do keys[#keys + 1] = a.key end end
            elseif type(t.target) == "number" then
                for _, a in ipairs(snapshot.order) do
                    if a.slot == t.target - 1 then keys[1] = a.key end
                end
            end
            for _, target in ipairs(keys) do
                for _ = 1, BfBot.Persist._NormalizeSpellRepeat(e.cfg.rep) do
                    if #requests >= P.MAX_REQUESTS then return nil, P.Text("Plan exceeds 256 requests") end
                    requests[#requests + 1] = { group = e.key, target = target,
                        source = e.actor.key, var = e.cfg.var, on = 1 }
                end
            end
        end
    end
    return requests
end
function P.BuildQueue(snapshot, requests)
    if #requests > P.MAX_REQUESTS then return nil, nil, P.Text("Plan exceeds 256 requests") end
    local plan = P.Assign(snapshot, requests)
    if plan.missing > 0 then return nil, plan end
    local queue = {}
    for _, d in ipairs(plan.decisions) do
        if d.source then
            local s, r = d.source, d.request
            local target = r.target == "party" and "all" or (snapshot.actors[r.target].slot + 1)
            queue[#queue + 1] = { caster = s.slot, spell = s.row.resref,
                casterRef = s.casterRef,
                target = s.selfOnly and "self" or target, var = r.var, rep = 1,
                plannedActor = s.actor, plannedTarget = r.target, planIndex = #queue+1,
                invisibilityTarget = P.DeliversInvisibility(s.row,r.var)
                    and ((s.aoe or s.row.isAoE==1 or r.target=="party") and "party" or r.target) or nil,
                plannedItemSlot = s.itemSlot, itemOwner = s.itemOwner,
                sharedItem = s.itemOwner and s.row.itemResref or nil,
                isProjectImage = s.row.isProjectImage }
        end
    end
    if #queue == 0 then return nil, plan end
    -- Retain the executor's existing Project Image owner/ordering safeguards.
    if BfBot.Persist._ApplyPuppetLockPolicy then
        local clones = BfBot.Persist._CollectLiveCloneDescriptors()
        for _, actor in ipairs(snapshot.casters or snapshot.order) do
            local entries = {}
            for _, entry in ipairs(queue) do
                if entry.plannedActor == actor.key then entries[#entries + 1] = entry end
            end
            local _, skips = BfBot.Persist._ApplyPuppetLockPolicy(
                { oid = actor.sprite.m_id, name = actor.name }, entries, clones)
            if #skips > 0 then return nil, plan, P.Text("Project Image locks a planned caster") end
        end
    end
    return queue, plan
end
