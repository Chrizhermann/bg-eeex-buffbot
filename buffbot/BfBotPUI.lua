-- Recipient-first beta UI. The caster editor and all legacy presets remain
-- accessible. This panel owns party plans, not per-character spell settings.
BfBot.PartyUI = {}
local U, P = BfBot.PartyUI, BfBot.Plan
bbPartyBuffs, bbPartyTargets, bbPartyRequests = {}, {}, {}
bbPartyBuffSelection, bbPartyTargetSelection, bbPartyRequestSelection = 0, 0, 0
bbPartyName, bbPartyStatus, bbPartyDetails = "", "", ""
U._variant = {}

function U.Duration(n)
    if n == -1 then return P.Text("Permanent") end
    if not n or n == 0 then return P.Text("Instant/unknown") end
    if n >= 3600 then return string.format("%.1fh", n / 3600) end
    if n >= 60 then return string.format("%.1fm", n / 60) end
    return string.format("%ds", n)
end
function U.Layout()
    if BfBot.Visual and BfBot.Visual.active then return BfBot.Visual.Layout() end
    local sw, sh = Infinity_GetScreenSize()
    local w, h = math.floor(sw * .94), math.floor(sh * .9)
    local x, y = math.floor((sw - w) / 2), math.floor((sh - h) / 2)
    U.screenW, U.screenH = sw, sh
    local function area(name, dx, dy, aw, ah)
        Infinity_SetArea(name, x + dx, y + dy, aw, ah)
    end
    area("bpBg", 0, 0, w, h)
    local tabW = math.min(110, math.floor((w - 320) / 4))
    for i, name in ipairs({"bpDashboardTab", "bpOrderTab", "bpSummaryTab"}) do
        area(name, 12 + (i - 1) * (tabW + 4), 10, tabW, 30)
    end
    area("bpPreset", w - 286, 10, 174, 30)
    area("bpNew", w - 108, 10, 30, 30)
    area("bpSettings", w - 74, 10, 30, 30)
    area("bpClose", w - 40, 10, 28, 30)
    local recipientW = math.min(130, math.floor((w - 236) / 7))
    for i = 0, 6 do area("bpRecipient" .. i, 12 + i * (recipientW + 3), 48, recipientW, 30) end
    area("bpSearch", w - 202, 50, 156, 26)
    area("bpSearchBg", w - 208, 48, 196, 30)
    area("bpSearchFrame", w - 209, 47, 198, 32)
    area("bpSearchHint", w - 202, 50, 156, 26)
    area("bpSearchClear", w - 38, 51, 24, 24)
    local headX = 12
    for _, col in ipairs({{"Icon",5},{"Name",22},{"Uses",8},{"Duration",11},{"Recipients",48},{"Actions",6}}) do
        area("bpHead" .. col[1], headX + 2, 84, math.floor((w - 24) * col[2] / 100) - 4, 24)
        headX = headX + (w - 24) * col[2] / 100
    end
    area("bpDashboard", 12, 112, w - 24, h - 218)
    local function headers(prefix,columns)
        local dx=12
        for _,col in ipairs(columns) do
            area(prefix..col[1],dx+2,50,math.floor((w-24)*col[2]/100)-4,26)
            dx=dx+(w-24)*col[2]/100
        end
    end
    headers("bpOrderHead",{{"Order",6},{"Icon",4},{"Name",29},{"Recipient",16},{"Caster",22},{"Duration",11},{"Move",8},{"Remove",4}})
    headers("bpSummaryHead",{{"Icon",5},{"Name",38},{"Caster",32},{"Duration",17},{"Remove",8}})
    area("bpSummary",12,84,w-24,h-190)
    area("bpPlan",12,120,w-24,h-226)
    for i,key in ipairs({'Smart','Long','Custom','Undo'}) do area('bpOrder'..key,12+(i-1)*148,48,140,28) end
    local dx=12
    for _,col in ipairs({{'Order',6},{'Icon',4},{'Name',29},{'Recipient',16},{'Caster',22},{'Duration',11},{'Move',8},{'Remove',4}}) do
        area('bpOrderHead'..col[1],dx+2,86,math.floor((w-24)*col[2]/100)-4,26)
        dx=dx+(w-24)*col[2]/100
    end
    area("bpAdd", 12, h - 100, 142, 28)
    area("bpHidden", 160, h - 100, 96, 28)
    area("bpRest", 12, h - 64, math.min(260, w - 280), 30)
    area("bpStatus", 282, h - 62, math.max(20, w - 494), 32)
    area("bpCast", w - 200, h - 64, 110, 30)
    area("bpStop", w - 84, h - 64, 72, 30)
    area("bpFeedback", 12, h - 28, w - 24, 22)
end
function U.Open()
    if BfBot.UI and BfBot.UI._CloseQuickMenu then BfBot.UI._CloseQuickMenu() end
    if not P.GetState() then return end
    if BfBot.Visual and BfBot.Visual.Available() then return BfBot.Visual.Open() end
    Infinity_PushMenu("BUFFBOT_PARTY")
end
function U.Close()
    if BfBot.Visual and BfBot.Visual.active then return BfBot.Visual.Close() end
    Infinity_PopMenu("BUFFBOT_PARTY")
end
function U.Legacy()
    U.Close()
    Infinity_PushMenu("BUFFBOT_MAIN")
end
function U.OnOpen()
    U.Layout()
    U.Refresh()
end
function U.TargetWarning(d)
    local target = d and d.request and U.snapshot.actors[d.request.target]
    return target and target.improvedInvisible and d.source
        and d.source.actor ~= d.request.target and not d.source.aoe
end
local function sourceDescription(d)
    if not d or not d.source then return d and d.reason or "" end
    return d.source.casterName .. " / " .. U.Duration(d.duration)
        .. (U.TargetWarning(d) and P.Text(" / improved invisible") or "")
end
function U.VariantInfo(group, variant)
    for _,source in ipairs(group and group.sources or {}) do
        for _,v in ipairs(source.variants or {}) do
            if v.resref == variant then return v end
        end
    end
end
function U.BuffName(group, variant)
    if not group then return variant or "" end
    if not variant then return group.name end
    local v = U.VariantInfo(group, variant)
    local name = v and (v.name or v.label) or variant
    if name == group.name or name == variant then name = v and v.label or variant end
    local prefix, suffix = name:match("^(.-):%s*(.+)$")
    if prefix and group.name:sub(-#prefix):lower()==prefix:lower() then name=suffix end
    if name:lower():find(group.name:lower(),1,true) then return name end
    return group.name .. " — " .. name
end
function U.Refresh(fresh)
    if fresh ~= false then BfBot.Scan.InvalidateAll();U.rowOrder=nil end
    U.state = P.GetState()
    if not U.state then return end
    U.snapshot = P.Snapshot()
    U.preset = U.state.presets[U.state.active]
    P.ApplyOrder(U.snapshot,U.preset,P.EstimateCast)
    U.plan = P.Assign(U.snapshot, U.preset.requests)
    bbPartyName = U.preset.name
    bbPartyBuffs, bbPartyRequests, bbPartyTargets = {}, {}, {}
    for key, group in pairs(U.snapshot.groups) do
        local pools, free, total, low, high, casters, names = {}, 0, 0, nil, nil, {}, {}
        local unlimited = false
        for _, s in ipairs(group.sources) do
            if not s.reason then
                unlimited = unlimited or s.row.atWill == 1
                local cap = U.snapshot.pools[s.pool] or 0
                local remaining = cap - (U.plan.used[s.pool] or 0)
                if not pools[s.pool] then
                    total, free = total + cap, free + cap - (U.plan.used[s.pool] or 0)
                    pools[s.pool] = true
                end
                if cap > 0 and not casters[s.actor] then
                    names[#names + 1] = s.casterName; casters[s.actor] = true
                end
                if remaining > 0 then
                    local duration = s.duration or 0
                    if duration == -1 then duration = math.huge end
                    low, high = math.min(low or duration, duration), math.max(high or duration, duration)
                end
            end
        end
        table.sort(names)
        local function dur(d) return U.Duration(d == math.huge and -1 or d) end
        bbPartyBuffs[#bbPartyBuffs + 1] = { key = key, name = group.name,
            uses = unlimited and P.Text("At will") or (free .. "/" .. total), casters = table.concat(names, ", "),
            duration = not low and P.Text("No unreserved uses")
                or (low == high and dur(low) or (dur(low) .. " - " .. dur(high))) }
    end
    table.sort(bbPartyBuffs, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.key < b.key
    end)
    bbPartyBuffSelection = 0
    for i, row in ipairs(bbPartyBuffs) do if row.key == U.group then bbPartyBuffSelection = i end end
    if bbPartyBuffSelection == 0 and bbPartyBuffs[1] then
        bbPartyBuffSelection, U.group = 1, bbPartyBuffs[1].key
    end
    local group = U.snapshot.groups[U.group]
    U.variants = {}
    local variantsSeen = {}
    for _, s in ipairs(group and group.sources or {}) do
        for _, v in ipairs(s.variants or {}) do
            if not variantsSeen[v.resref] then U.variants[#U.variants + 1] = v; variantsSeen[v.resref] = true end
        end
    end
    table.sort(U.variants, function(a, b) return a.resref < b.resref end)
    if #U.variants > 0 and not variantsSeen[U._variant[U.group]] then
        U._variant[U.group] = U.variants[1].resref
    end
    bbPartyRequestSelection = 0
    for i, d in ipairs(U.plan.decisions) do
        local r = d.request
        local g = U.snapshot.groups[r.group]
        local actor = U.snapshot.actors[r.target]
        bbPartyRequests[i] = { request = r, name = g and U.BuffName(g,r.var) or r.group .. (r.var and (" — " .. r.var) or ""),
            target = r.target == "party" and P.Text("Party") or (actor and actor.name or r.target),
            assignment = sourceDescription(d), unavailable = d.source == nil }
        if r == U.request then bbPartyRequestSelection = i end
    end
    local function target(key, name)
        local existing
        for i, r in ipairs(U.preset.requests) do
            if r.group == U.group and r.target == key then existing = i; break end
        end
        local decision
        if existing then decision = U.plan.decisions[existing]
        elseif group then
            local trial = {}
            for i, r in ipairs(U.preset.requests) do trial[i] = r end
            trial[#trial + 1] = { group = U.group, target = key, var = U._variant[U.group] }
            decision = P.Assign(U.snapshot, trial).decisions[#trial]
        end
        bbPartyTargets[#bbPartyTargets + 1] = { key = key, name = name,
            checked = existing and "[x]" or "[ ]", assignment = sourceDescription(decision),
            unavailable = not existing and not (decision and decision.source), index = existing }
    end
    target("party", P.Text("Party"))
    for _, actor in ipairs(U.snapshot.order) do target(actor.key, actor.name) end
    bbPartyStatus = #U.preset.requests .. P.Text(" planned / ") .. U.plan.missing .. P.Text(" unavailable")
    U.UpdateDetails()
    if U.BuildDashboard then U.BuildDashboard() end
end
function U.SelectBuff()
    local row = bbPartyBuffs[bbPartyBuffSelection]
    if row then U.group = row.key; U.Refresh() end
end
function U.SelectRequest()
    local row = bbPartyRequests[bbPartyRequestSelection]
    U.request = row and row.request or nil
    if U.request then
        U.group = U.request.group
        if U.request.var then U._variant[U.group] = U.request.var end
        U.Refresh()
    else U.UpdateDetails() end
end
function U.UpdateDetails()
    local actor = U.request and P.CasterActor(U.snapshot,U.request.source)
    local selected = U.plan and U.plan.decisions[bbPartyRequestSelection]
    local level = selected and selected.source and selected.source.casterLevel
    bbPartyDetails = U.request and (P.Text("Source: ") .. (actor and actor.name or P.CasterLabel(U.snapshot,U.request.source) or P.Text("Auto"))
        .. (level and (P.Text(" / effective caster level ") .. level) or "")
        .. (U.request.var and (" / " .. U.request.var) or "")) or P.Text("Select a planned buff to change its source or order.")
    if U.TargetWarning(selected) then
        bbPartyDetails = bbPartyDetails .. "\n"
            .. P.Text("Target has Improved Invisibility; the engine may reject this cast.")
    end
end
function U.ToggleTarget()
    local row = bbPartyTargets[bbPartyTargetSelection]
    if not row then return end
    if row.index then table.remove(U.preset.requests, row.index)
    elseif row.unavailable then bbPartyStatus = row.assignment; return
    elseif #U.preset.requests < P.MAX_REQUESTS then
        U.preset.requests[#U.preset.requests + 1] = { group = U.group,
            target = row.key, var = U._variant[U.group], on = 1 }
    else bbPartyStatus = P.Text("Maximum 256 planned casts"); return end
    U.Refresh()
end
function U.CycleVariant()
    if #U.variants == 0 then return end
    local nextIndex = 1
    for i, v in ipairs(U.variants) do
        if v.resref == U._variant[U.group] then nextIndex = i % #U.variants + 1 end
    end
    U._variant[U.group] = U.variants[nextIndex].resref
    U.Refresh()
end
function U.VariantLabel()
    for _, v in ipairs(U.variants or {}) do
        if v.resref == U._variant[U.group] then return P.Text("Variant: ") .. (v.name or v.label or v.resref) end
    end
    return P.Text("Select recipients below")
end
function U.CycleSource()
    if not U.request then return end
    local group = U.snapshot.groups[U.request.group]
    local choices, seen = { false }, {}
    for _, s in ipairs(group and group.sources or {}) do
        if not seen[s.actor] then choices[#choices + 1] = s.actor; seen[s.actor] = true end
    end
    table.sort(choices, function(a, b) return (a or "") < (b or "") end)
    local pos = 1
    for i, key in ipairs(choices) do if key == U.request.source then pos = i % #choices + 1 end end
    if not U.request.source then pos = #choices > 1 and 2 or 1 end
    U.request.source = choices[pos] or nil
    U.Refresh()
end
function U.Move(delta)
    for i, r in ipairs(U.preset.requests) do
        if r == U.request and U.preset.requests[i + delta] then
            U.preset.requests[i], U.preset.requests[i + delta] = U.preset.requests[i + delta], r
            P.SaveCustomOrder(U.preset);U.undoOrder=nil
            U.Refresh(); return
        end
    end
end
function U.Remove()
    for i, r in ipairs(U.preset.requests) do
        if r == U.request then table.remove(U.preset.requests, i); U.request = nil; U.Refresh(); return end
    end
end
function U.Preset(delta)
    local current = U.state.active
    for offset = 1, 8 do
        local index = (current - 1 + delta * offset) % 8 + 1
        if U.state.presets[index] then U.state.active = index; U.request = nil; U.Refresh(); return end
    end
end
function U.NewPreset()
    for i = 1, 8 do
        if not U.state.presets[i] then
            U.state.presets[i] = { name = P.Text("Preset ") .. i, requests = {}, orderMode="smart" }
            U.state.active = i; U.request = nil; U.Refresh(); return
        end
    end
    bbPartyStatus = P.Text("Maximum eight presets")
end
function U.CanDeletePreset()
    local count=0
    for i=1,8 do if U.state.presets[i] then count=count+1 end end
    return count>1
end
function U.DeletePreset()
    local state=P.GetState();local index=U.deleteIndex
    if state~=U.deleteState or not index or state.presets[index]~=U.deletePreset then
        bbPartyFeedback=P.Text('Preset changed; try again');return
    end
    local nextIndex
    for i=1,8 do if i~=index and state.presets[i] then nextIndex=nextIndex or i end end
    if not nextIndex then bbPartyFeedback=P.Text('Keep at least one preset');return end
    state.presets[index]=nil;state.active=nextIndex
    if state.rest.preset==index then
        state.rest={on=0,preset=nextIndex}
        if BfBot.Rest then BfBot.Rest.pending=nil end
    end
    U.request=nil;U.deletePreset=nil;U.deleteState=nil
    if BfBot.Visual and BfBot.Visual.active then BfBot.Visual.ClosePopup() end
    U.Refresh();bbPartyFeedback=P.Text('Preset deleted')
end
function U.ExportPlan()
    local name,why=BfBot.PlanIO.Export(U.preset)
    bbPartyFeedback=name and (P.Text('Exported: ')..BfBot.PlanIO.directory..'/'..name) or why
end
function U.ImportPlan(name)
    local preset,why=BfBot.PlanIO.Read(name)
    if preset then
        local index;index,why=BfBot.PlanIO.Insert(U.state,preset)
        if index then U.request=nil;U.Refresh();bbPartyFeedback=P.Text('Plan imported; review recipients and unavailable sources');return end
    end
    bbPartyFeedback=why or P.Text('Import failed')
end
function U.Rename()
    local name = bbPartyName:match("^%s*(.-)%s*$")
    if #name > 0 and #name <= 80 and not name:find("%c") then U.preset.name = name end
    U.Refresh()
end
function U.ImportLegacy()
    if #U.preset.requests > 0 then bbPartyStatus = P.Text("Import into an empty preset"); return end
    local requests, reason = P.ImportLegacy(U.snapshot, U.state.active)
    if not requests then bbPartyStatus = reason; return end
    U.preset.requests = requests
    P.SaveCustomOrder(U.preset)
    U.Refresh()
end
function U.RestLabel()
    local state = P.GetState()
    local rest = state and state.rest
    local preset = rest and state.presets[rest.preset]
    return rest and rest.on == 1 and preset
        and (P.Text("After rest: ") .. preset.name) or P.Text("After rest: off")
end
function U.ToggleRest()
    local state = P.GetState()
    if not state then return end
    local rest = state.rest
    if not rest then rest = { on = 0, preset = state.active }; state.rest = rest end
    if rest.on == 1 and rest.preset == state.active then rest.on = 0
    else rest.on, rest.preset = 1, state.active end
    if BfBot.Rest then BfBot.Rest.pending = nil end
end
function U.CanCast()
    return U.plan and U.plan.missing == 0 and #U.preset.requests > 0
        and BfBot.Exec.GetState() ~= "running"
end
function U.Cast()
    if BfBot.Mp and BfBot.Mp._IsMpSession() then
        bbPartyStatus = P.Text("Party planning is a single-player beta; use the caster editor"); return
    end
    U.Refresh() -- Commit only against fresh availability, never a cached preview.
    if not U.CanCast() then return end
    P.ApplyOrder(U.snapshot,U.preset,P.EstimateCast)
    local queue, _, reason = P.BuildQueue(U.snapshot, U.preset.requests)
    if not queue then bbPartyStatus = reason or P.Text("Resolve unavailable casts before casting"); return end
    if BfBot.Exec.Start(queue, U.state.fast==1 and 4 or 0, nil) then U.Close() end
end

-- The list widget dispatches clicks through its selected-row variable. Never
-- use render-time rowNumber in actions (it can point at the last painted row).
bbPartyRows, bbPartySummary, bbPartyChoices = {}, {}, {}
bbPartyRowSelection, bbPartySummarySelection, bbPartyChoiceSelection = 0, 0, 0
bbPartyQuery, bbPartyFeedback = "", ""
U.view, U.recipient = "dashboard", "all"
U.sortField, U.sortDescending = "name", false

local function copyRequests(requests)
    local result = {}
    for i, r in ipairs(requests) do result[i] = r end
    return result
end
local function planned(group, target, variant)
    for i, r in ipairs(U.preset.requests) do
        if r.group == group and r.target == target and r.var == variant then return i end
    end
end
function U.Preview(group, target, variant)
    local index = planned(group, target, variant)
    if index then return U.plan.decisions[index], index end
    local trial = copyRequests(U.preset.requests)
    trial[#trial + 1] = { group = group, target = target, var = variant, on = 1 }
    local result = P.Assign(U.snapshot, trial)
    local decision = result.decisions[#trial]
    -- A full plan must not acquire a new missing cast through a preview.
    if #trial > P.MAX_REQUESTS then
        return { reason = P.Text("Maximum 256 planned casts") }
    end
    return decision
end
-- Target legality is independent of reservations. Keep the actual next-cast
-- decision separate from source capabilities and the row's full duration range.
function U.Possibilities(group, target, variant)
    local request={group=group,target=target,var=variant,on=1}
    local result={eligible=false}
    for _,source in ipairs((U.snapshot.groups[group] or {}).sources or {}) do
        if P.SourceAllowed(U.snapshot,source,request) then
            result.eligible=true
            if (U.snapshot.pools[source.pool] or 0)>0 then
                local n=P.SourceDuration(source,request)
                if n==-1 then n=math.huge end
                result.low=math.min(result.low or n,n)
                result.high=math.max(result.high or n,n)
                if not result.source or P.BetterSource(source,result.source,request) then result.source=source end
            end
        end
    end
    if result.source then result.duration=P.SourceDuration(result.source,request) end
    return result
end
function U.Portrait(slot)
    for _, actor in ipairs(U.snapshot and U.snapshot.order or {}) do
        if actor.slot == slot and actor.sprite then
            local ok, resref = pcall(function() return actor.sprite.m_baseStats.m_portraitSmall:get() end)
            if ok and type(resref) == "string" and resref ~= "" then return resref end
        end
    end
    local id = charTable and charTable[slot + 1]
    local actor = characters and id and characters[id]
    return actor and actor.portrait or ""
end
function U.BuildDashboard()
    U.state.hidden, U.state.include = U.state.hidden or {}, U.state.include or {}
    if U.recipient ~= "all" and not U.snapshot.actors[U.recipient] then U.recipient = "all" end
    U.dashboard = {}
    local counts = {}
    for _, g in pairs(U.snapshot.groups) do counts[g.name] = (counts[g.name] or 0) + 1 end
    local function buildRow(key, group, variant, metadata, isVariantGroup)
        local row = { key=key, id=key .. ":" .. (variant or ""), variant=variant,
            name=group and U.BuffName(group,variant) or key .. (variant and (" — " .. variant) or ""),
            icon=metadata and metadata.icon ~= "" and metadata.icon or group and group.icon or "",
            free=0,total=0,planned=0,cells={},party=false,qualifier="",variantGroup=isVariantGroup }
        local pools, livingSource = {}, false
        for _,source in ipairs(group and group.sources or {}) do
            local compatible = variant and U.VariantInfo({sources={source}},variant)
                or not variant and not (source.variants and #source.variants>0)
            if compatible then
                local cap=U.snapshot.pools[source.pool] or 0
                if not source.reason and cap>0 then livingSource=true end
                if not source.reason and not pools[source.pool] then
                    row.total=row.total+cap
                    row.free=row.free+math.max(0,cap-(U.plan.used[source.pool] or 0))
                    pools[source.pool]=true
                end
                row.party=row.party or source.aoe==true
                row.atWill=row.atWill or source.row.atWill==1
            end
        end
        row.uses=row.atWill and P.Text("At will") or row.free .. "/" .. row.total
        if group then
            local item=group.kind=="itm" or group.sources[1] and group.sources[1].row.kind=="itm"
            row.qualifier=item and P.Text("Item") or ""
            if counts[group.name]>1 then
                row.qualifier=(item and P.Text("Item") or P.Text("Spell"))
                    .. " / " .. (group.sources[1] and group.sources[1].row.resref or key)
            end
            if isVariantGroup then row.qualifier=P.Text("Shared uses: ") .. group.name end
            if isVariantGroup and not variant then row.qualifier=P.Text("Choose a supported variant") end
            if variant and not metadata then row.qualifier=P.Text("Buff unavailable") end
        else row.qualifier=P.Text("Buff unavailable") end
        local party,index=U.Preview(key,"party",variant)
        row.partyCell={decision=party,index=index,checked=index~=nil,
            available=party and party.source~=nil,target="party",name=P.Text("Party"),
            possibilities=U.Possibilities(key,"party",variant)}
        for i,actor in ipairs(U.snapshot.order) do
            local d,existing=U.Preview(key,actor.key,variant)
            row.cells[i]={target=actor.key,name=actor.name,slot=actor.slot,decision=d,
                index=existing,checked=existing~=nil,available=d and d.source~=nil,
                possibilities=U.Possibilities(key,actor.key,variant)}
        end
        for _,r in ipairs(U.preset.requests) do
            if r.group==key and r.var==variant then
                row.planned=row.planned+1
                if r.target=="party" then row.party=true end
            end
        end
        if (livingSource or row.planned>0) and not U.state.hidden[key] then
            U.dashboard[#U.dashboard+1]=row
        end
    end
    for _,catalog in ipairs(bbPartyBuffs) do
        local group=U.snapshot.groups[catalog.key]
        local variants,seen={},{}
        for _,source in ipairs(group.sources) do
            for _,v in ipairs(source.variants or {}) do
                if not seen[v.resref] then variants[#variants+1]=v;seen[v.resref]=true end
            end
        end
        if #variants==0 then buildRow(catalog.key,group,nil,nil,false)
        else
            for _,v in ipairs(variants) do buildRow(catalog.key,group,v.resref,v,true) end
        end
        -- Keep invalid/imported requests removable without silently choosing a school.
        for _,r in ipairs(U.preset.requests) do
            if r.group==catalog.key and ((r.var and not seen[r.var]) or (#variants>0 and not r.var and not seen[''])) then
                buildRow(catalog.key,group,r.var,nil,#variants>0)
                seen[r.var or '']=true
            end
        end
    end
    -- Missing parent resources preserve each requested school independently.
    local missing={}
    for _,r in ipairs(U.preset.requests) do
        local id=r.group .. ":" .. (r.var or "")
        if not U.snapshot.groups[r.group] and not missing[id] then
            buildRow(r.group,nil,r.var,nil,false);missing[id]=true
        end
    end
    table.sort(U.dashboard,function(a,b)
        if a.name~=b.name then return a.name<b.name end
        return a.id<b.id
    end)
    U.FilterDashboard()
    bbPartySummary = {}
    local targets = {{key="party",name=P.Text("Party")}}
    for _, actor in ipairs(U.snapshot.order) do targets[#targets + 1] = actor end
    for _, target in ipairs(targets) do
        bbPartySummary[#bbPartySummary + 1] = { heading=true,name=target.name,icon="",portrait=target.slot~=nil and U.Portrait(target.slot) or "",party=target.key=="party" }
        local added = false
        for i, row in ipairs(bbPartyRequests) do
            if row.request.target == target.key then
                bbPartySummary[#bbPartySummary + 1] = { name = row.name,
                    icon = U.RequestIcon(i), assignment = row.assignment,
                    unavailable = row.unavailable, request = row.request,planIndex=i }
                added = true
            end
        end
        if not added then bbPartySummary[#bbPartySummary + 1] = {name=P.Text("None"),icon=""} end
    end
    -- Orphaned/departed recipients remain reviewable/removable in cast order.
    for i, row in ipairs(bbPartyRequests) do
        if row.request.target ~= "party" and not U.snapshot.actors[row.request.target] then
            bbPartySummary[#bbPartySummary + 1] = { name = row.name .. " / " .. row.target,
                icon = "", assignment = row.assignment, unavailable = true, request = row.request,planIndex=i }
        end
    end
end
function U.FilterDashboard(resort)
    local queryChanged = bbPartyQuery ~= U.lastQuery
    bbPartyRows = {}
    local query = (bbPartyQuery or ""):lower()
    for _, row in ipairs(U.dashboard or {}) do
        local matches = query == "" or row.name:lower():find(query, 1, true)
        local allowed = U.recipient == "all" or row.party
        for _, cell in ipairs(row.cells) do
            if cell.target == U.recipient and U.CellVisible(cell) then allowed = true end
        end
        if matches and allowed then
            row.sortLow, row.sortHigh = U.DurationRange(row)
            bbPartyRows[#bbPartyRows + 1] = row
        end
    end
    local function less(a,b)
        if U.sortField == "duration" then
            -- Unknown/unavailable durations stay last in either direction.
            local ak, bk = (a.sortHigh or 0) > 0, (b.sortHigh or 0) > 0
            if ak ~= bk then return ak end
            if ak and a.sortHigh ~= b.sortHigh then
                if U.sortDescending then return a.sortHigh > b.sortHigh end
                return a.sortHigh < b.sortHigh
            end
            if ak and a.sortLow ~= b.sortLow then
                if U.sortDescending then return a.sortLow > b.sortLow end
                return a.sortLow < b.sortLow
            end
        end
        local an, bn = a.name:lower(), b.name:lower()
        if an ~= bn then
            if U.sortField == "name" and U.sortDescending then return an > bn end
            return an < bn
        end
        return a.id < b.id
    end
    if resort or not U.rowOrder or U.orderPreset~=U.preset then
        U.rowOrder={};U.orderPreset=U.preset
        local ordered={}
        for _,row in ipairs(U.dashboard or {}) do
            row.sortLow,row.sortHigh=U.DurationRange(row);ordered[#ordered+1]=row
        end
        table.sort(ordered,less)
        for i,row in ipairs(ordered) do U.rowOrder[row.id]=i end
        U.lastRowRank=#ordered
    end
    -- New/restored entries append until the next explicit sort or refresh.
    for _,row in ipairs(U.dashboard or {}) do
        if not U.rowOrder[row.id] then
            U.lastRowRank=U.lastRowRank+1;U.rowOrder[row.id]=U.lastRowRank
        end
    end
    table.sort(bbPartyRows,function(a,b) return U.rowOrder[a.id]<U.rowOrder[b.id] end)
    bbPartyRowSelection = 0
    if BfBot.Visual and BfBot.Visual.active and BfBot.Visual.AfterFilter then BfBot.Visual.AfterFilter() end
    U.lastQuery = bbPartyQuery
    if queryChanged then U.ResetBrowserScroll() end
end
function U.ResetBrowserScroll()
    if not EEex_Menu_GetItem then return end
    local visual=BfBot.Visual
    local name=visual and visual.active and ('rxDashboard'..(visual.wide and 'Wide' or '')) or 'bpDashboard'
    local item=EEex_Menu_GetItem(name)
    if item and item.scrollbar then item.scrollbar.top=0 end
end
function U.SortBy(field)
    if field ~= "name" and field ~= "duration" then return end
    if U.sortField == field then U.sortDescending = not U.sortDescending
    else U.sortField, U.sortDescending = field, false end
    U.FilterDashboard(true)
    U.ResetBrowserScroll()
end
function U.SortHeading(field)
    return P.Text(field == "name" and "Name" or "Duration")
        .. (U.sortField == field and (U.sortDescending and "  v" or "  ^") or "")
end
function U.ClearSearch()
    bbPartyQuery = ""; U.FilterDashboard()
end
function U.SetView(view)
    U.view = view; bbPartyFeedback = ""; U.Refresh(false)
end
function U.SetRecipient(slot)
    local actor = slot and U.snapshot.order[slot]
    U.recipient = actor and actor.key or "all"
    U.FilterDashboard(true)
    U.ResetBrowserScroll()
end
function U.RecipientName(slot)
    return slot == 0 and P.Text("All buffs") or U.snapshot and U.snapshot.order[slot]
        and U.snapshot.order[slot].name or ""
end
function U.IsRecipient(slot)
    return slot == 0 and U.recipient == "all" or U.snapshot and U.snapshot.order[slot]
        and U.recipient == U.snapshot.order[slot].key or false
end
function U.IsDashboard() return U.view == "dashboard" end
function U.Tick()
    if bbPartyQuery ~= U.lastQuery then U.FilterDashboard() end
    if Infinity_GetScreenSize then
        local w,h = Infinity_GetScreenSize()
        if w ~= U.screenW or h ~= U.screenH then U.Layout() end
    end
    return false
end
-- The dashboard packs applicable recipients into a compact strip.
function U.CellVisible(cell)
    return cell and (cell.checked or cell.available or cell.possibilities and cell.possibilities.eligible)
end
function U.DashboardCell(rowIndex, slot)
    local row = bbPartyRows[rowIndex]
    if not row or row.party or row.heading then return nil end
    local visible = 0
    for _, cell in ipairs(row.cells) do
        if (U.recipient == "all" or U.recipient == cell.target)
            and U.CellVisible(cell) then
            visible = visible + 1
            if visible == slot then return cell end
        end
    end
end
function U.CellText(rowIndex, slot)
    local row, cell = bbPartyRows[rowIndex], U.DashboardCell(rowIndex, slot)
    if not row or not cell or row.party then return "" end
    return (cell.checked and (cell.available and "[x] " or "[!] ") or cell.available and "[ ] " or "[-] ")
        .. cell.name
end
-- The row summarizes all compatible source durations, before reserving uses.
-- Portraits and the plan continue to show actual assigned/next-cast durations.
function U.DurationRange(row)
    if not row then return end
    local low, high
    local function include(cell)
        local p=cell and cell.possibilities
        if not p or p.low==nil then return end
        low,high=math.min(low or p.low,p.low),math.max(high or p.high,p.high)
    end
    if row.party then include(row.partyCell)
    else
        for _,cell in ipairs(row.cells) do
            if (U.recipient == "all" or U.recipient == cell.target)
                and U.CellVisible(cell) then include(cell) end
        end
    end
    return low, high
end
function U.RowDuration(index)
    local row = bbPartyRows[index]
    if not row then return "" end
    local low, high = U.DurationRange(row)
    if not low then return P.Text("Buff unavailable") end
    local function formatted(n) return U.Duration(n == math.huge and -1 or n) end
    return low == high and formatted(low) or formatted(low) .. " - " .. formatted(high)
end
function U.CellDuration(index,slot)
    local cell = U.DashboardCell(index,slot)
    local d = cell and (cell.decision and cell.decision.source and cell.decision or not cell.checked and cell.possibilities)
    return d and d.source and U.Duration(d.duration) or ""
end
function U.PartyPortrait(index,slot)
    local row = bbPartyRows[index]
    local actor = U.snapshot and U.snapshot.order[slot]
    return row and row.party and actor and U.Portrait(actor.slot) or ""
end
function U.PartyText(index)
    local row = bbPartyRows[index]
    if not row or not row.party then return "" end
    local cell = row.partyCell
    return (cell.checked and (cell.available and "[x] " or "[!] ") or "[ ] ") .. P.Text("Party")
end
function U.DashboardColor(rowIndex, slot)
    local cell = U.DashboardCell(rowIndex, slot)
    return cell and cell.checked and not cell.available and {155,40,25} or {38,32,26}
end
function U.CellPortrait(rowIndex, slot)
    local row, cell = bbPartyRows[rowIndex], U.DashboardCell(rowIndex, slot)
    return row and not row.party and U.CellVisible(cell) and U.Portrait(cell.slot) or ""
end
function U.ToggleCell(row, target)
    local decision, index = U.Preview(row.key, target, row.variant)
    if index then
        -- A checkbox represents coverage, so clear imported repeat requests
        -- for this recipient together instead of leaving a hidden duplicate.
        for i = #U.preset.requests, 1, -1 do
            local r = U.preset.requests[i]
            if r.group == row.key and r.target == target and r.var == row.variant then table.remove(U.preset.requests, i) end
        end
        bbPartyFeedback = ""
    elseif not decision or not decision.source then
        bbPartyFeedback = decision and decision.reason or P.Text("No eligible source"); return
    elseif #U.preset.requests < P.MAX_REQUESTS then
        U.preset.requests[#U.preset.requests + 1] = { group = row.key, target = target, var = row.variant, on = 1 }
        bbPartyFeedback = sourceDescription(decision)
    else bbPartyFeedback = P.Text("Maximum 256 planned casts"); return end
    U.Refresh(false)
end
function U.DashboardClick(column)
    local row = bbPartyRows[bbPartyRowSelection]
    if not row or row.heading then return end
    if column <= (BfBot.Visual and BfBot.Visual.active and 4 or 2) then U.OpenChoices("sources", row.key, row.variant)
    elseif column >= 5 and column <= 10 then
        if row.party then
            if column == 5 then U.ToggleCell(row,"party") end
        else
            local cell = U.DashboardCell(bbPartyRowSelection, column - 4)
            if cell then U.ToggleCell(row, cell.target) end
        end
    elseif column == 11 then
        for i = #U.preset.requests, 1, -1 do
            if U.preset.requests[i].group == row.key and U.preset.requests[i].var == row.variant then table.remove(U.preset.requests, i) end
        end
        U.Refresh(false)
    end
end
function U.RowName(index)
    local row = bbPartyRows[index]
    return row and (row.name .. (row.qualifier ~= "" and ("\n" .. row.qualifier) or "")) or ""
end
function U.RowTip(index) return U.RowName(index) end
function U.PartyColor(index)
    local row = bbPartyRows[index]
    return row and row.party and row.partyCell.checked and not row.partyCell.available
        and {155,40,25} or {38,32,26}
end
function U.SummaryName(index)
    local row = bbPartySummary[index]
    local request=row and row.planIndex and bbPartyRequests[row.planIndex]
    return row and row.name or ""
end
function U.SummaryTip(index)
    local row=bbPartySummary[index];local r=row and row.planIndex and bbPartyRequests[row.planIndex]
    return U.SummaryName(index)
end
function U.SummaryPortrait(index,slot)
    local row=bbPartySummary[index]
    if not row or not row.heading then return "" end
    if row.party then
        local actor=U.snapshot.order[slot]
        return actor and U.Portrait(actor.slot) or ""
    end
    return slot==1 and row.portrait or ""
end
function U.SummaryCaster(index)
    local row=bbPartySummary[index]
    return row and row.request and U.OrderCaster(row.planIndex) or ""
end
function U.SummaryDuration(index)
    local row=bbPartySummary[index]
    return row and row.request and U.OrderDuration(row.planIndex) or ""
end
function U.RequestIcon(index)
    local row = bbPartyRequests[index]
    local group = row and U.snapshot.groups[row.request.group]
    local v = row and U.VariantInfo(group,row.request.var)
    return v and v.icon ~= "" and v.icon or group and group.icon or ""
end
function U.OrderCaster(index)
    local row=bbPartyRequests[index]
    if not row then return "" end
    local d=U.plan.decisions[index]
    local actor=P.CasterActor(U.snapshot,row.request.source)
    local name=row.request.source and (actor and actor.name or P.CasterLabel(U.snapshot,row.request.source))
        or (P.Text("Auto") .. (d.source and (" ("..d.source.casterName..")") or ""))
    return name
end
function U.OrderDuration(index)
    local d=U.plan.decisions[index]
    return d and d.source and U.Duration(d.duration) or "—"
end
function U.OrderName(index)
    local row=bbPartyRequests[index]
    local d=U.plan.decisions[index]
    return row and row.name .. (row.unavailable and ("\n"..(d.reason or P.Text("Buff unavailable"))) or "") or ""
end
function U.OrderTip(index) return U.OrderName(index) end
function U.CanMove(index,delta) return bbPartyRequests[index]~=nil and bbPartyRequests[index+delta]~=nil end
function U.CanSortOrder()
    return U.preset~=nil and BfBot.Exec.GetState()~='running'
end
function U.IsOrderMode(mode)
    return U.preset and (U.preset.orderMode or 'custom')==mode or false
end
function U.SortOrder(mode)
    if not U.CanSortOrder() or (mode~='smart' and mode~='long' and mode~='custom') then return end
    P.EnsureManualOrder(U.preset)
    local before={};for i,r in ipairs(U.preset.requests) do before[i]=r end
    local oldMode=U.preset.orderMode or 'custom'
    U.preset.orderMode=mode
    if mode=='custom' then P.RestoreCustomOrder(U.preset)
    else P.ApplyOrder(U.snapshot,U.preset,P.EstimateCast) end
    local after={};local changed=oldMode~=mode
    for i,r in ipairs(U.preset.requests) do after[i]=r;changed=changed or r~=before[i] end
    if changed then U.undoOrder={preset=U.preset,before=before,after=after,mode=oldMode,afterMode=mode} end
    U.Refresh(false)
    bbPartyFeedback=P.Text(mode=='smart' and 'Smart order active' or mode=='long' and 'Long first active' or 'Custom order active')
end
function U.CanUndoOrder()
    local undo=U.undoOrder
    if not undo or U.preset~=undo.preset or BfBot.Exec.GetState()=='running'
        or (U.preset.orderMode or 'custom')~=undo.afterMode or #U.preset.requests~=#undo.after then return false end
    for i,r in ipairs(undo.after) do if U.preset.requests[i]~=r then return false end end
    return true
end
function U.UndoOrder()
    if not U.CanUndoOrder() then return end
    local undo=U.undoOrder
    U.preset.requests=undo.before;U.preset.orderMode=undo.mode;U.undoOrder=nil
    U.Refresh(false)
    bbPartyFeedback=P.Text('Previous order restored')
end
function U.OrderClick(column)
    local index=bbPartyRequestSelection
    local row=bbPartyRequests[index]
    if not row then return end
    U.request=row.request
    if column==5 then U.OpenCaster(index,"bpPlan",.55)
    elseif column==7 and U.CanMove(index,-1) then U.Move(-1)
    elseif column==8 and U.CanMove(index,1) then U.Move(1)
    elseif column==9 then U.Remove() end
end
function U.SummaryClick(column)
    local row=bbPartySummary[bbPartySummarySelection]
    if not row or not row.request then return end
    U.request=row.request
    if column==3 then U.OpenCaster(row.planIndex,"bpSummary",.43,bbPartySummarySelection)
    elseif column==5 then U.Remove() end
end
-- Test the entire plan: a caster preference must not steal a use reserved by
-- another satisfiable request, and must support this exact recipient/variant.
function U.TryCaster(request,actor)
    local trial,index={},nil
    for i,r in ipairs(U.preset.requests) do
        trial[i]=r
        if r==request then
            index=i;local copy={};for k,v in pairs(r) do copy[k]=v end
            copy.source=actor or nil;trial[i]=copy
        end
    end
    if not index then return nil,P.Text("Buff unavailable") end
    local plan=P.Assign(U.snapshot,trial)
    local d=plan.decisions[index]
    if not d.source then return nil,d.reason end
    for i,old in ipairs(U.plan.decisions) do
        if old.source and not plan.decisions[i].source then return nil,plan.decisions[i].reason end
    end
    return d
end
function U.OpenCaster(index,listName,column,rowIndex)
    if BfBot.Visual and BfBot.Visual.active then return BfBot.Visual.OpenCaster(index,listName,column,rowIndex) end
    local row=bbPartyRequests[index]
    if not row then return end
    U.request=row.request
    U.choiceName=row.name
    U.choiceRequest,U.choicePreset=row.request,U.preset
    U.OpenChoices("caster")
    -- Reposition after list geometry is known; the popup is anchored to the
    -- visible row rather than a render-time global or the bottom of the panel.
    if EEex_Menu_GetItemArea then
        local x,y,w=EEex_Menu_GetItemArea(listName)
        local item=EEex_Menu_GetItem(listName)
        local top=item and item.scrollbar and item.scrollbar.top or 0
        U.choiceAnchor={x=x+w*column,y=y+((rowIndex or index)-1)*42-top+42,w=w*.22}
        U.PopupLayout(false)
    end
end
function U.SetCaster(actor)
    local request,preset=U.choiceRequest,U.choicePreset
    U.Refresh()
    if U.preset~=preset then return end
    local d,reason=U.TryCaster(request,actor)
    if not d then bbPartyFeedback=reason or P.Text("No eligible source");return end
    request.source=actor or nil
    U.request=request;bbPartyFeedback="";U.Refresh(false)
end
function U.OpenChoices(mode, key, variant)
    U.choiceMode, U.choiceGroup = mode, key
    bbPartyChoiceTitle, bbPartyChoiceHint = "", ""
    bbPartyChoices, bbPartyChoiceSelection = {}, 0
    local function add(name, kind, value, icon)
        bbPartyChoices[#bbPartyChoices + 1] = {name=name,kind=kind,value=value,icon=icon or ""}
    end
    if mode == "caster" then
        U.choiceAnchor=nil
        local request=U.choiceRequest
        bbPartyChoiceTitle=P.Text("Caster: ") .. (U.choiceName or U.BuffName(U.snapshot.groups[request.group],request.var))
        local actor=U.snapshot.actors[request.target]
        bbPartyChoiceHint=P.Text("Recipient: ") .. (request.target=="party" and P.Text("Party") or actor and actor.name or request.target)
        local function casterOption(key,name)
            local decision,why=U.TryCaster(request,key)
            local label=(request.source==key or not request.source and not key) and "[x] " or ""
            label=label..name.." / "..(decision and U.Duration(decision.duration) or why or P.Text("No eligible source"))
            add(label,decision and "caster" or "info",key)
        end
        casterOption(false,P.Text("Auto"))
        local seen={}
        for _,source in ipairs((U.snapshot.groups[request.group] or {}).sources or {}) do
            if not seen[source.actor] then casterOption(source.actor,source.casterName);seen[source.actor]=true end
        end
    elseif mode == "presets" or mode == "rest" then
        if mode == "rest" then add(P.Text("Off"), "rest", 0) end
        for i=1,8 do
            local preset = U.state.presets[i]
            if preset then
                local label=(mode=='presets' and (i..'. ') or '')..preset.name
                add(label, mode == "rest" and "rest" or "preset", i)
            end
        end
    elseif mode == "settings" then
        local casting=U.state.fast==1 and ('Fast-forward '..(U.state.fastRate or 2)..'x')
            or 'Normal'
        add(P.Text('Theme...'),'openTheme')
        add(P.Text('Casting: ')..P.Text(casting),'openCasting')
        add(P.Text("Rename"), "rename")
        add(P.Text("Refresh"), "refresh")
        add(P.Text("Import caster preset"), "import")
        add(P.Text('Export plan'), 'exportPlan')
        add(P.Text('Import plan...'), 'openPlanImport')
        add(P.Text('Delete preset...'), 'openDelete')
        add(P.Text("Caster editor"), "legacy")
    elseif mode=='casting' then
        bbPartyChoiceTitle=P.Text('Casting mode')
        bbPartyChoiceHint=P.Text('Fast-forward speeds up the world at up to 30 rendered FPS.')
        for _,option in ipairs({{'Fast-forward 2x (Recommended)',2},{'Fast-forward 4x',4},{'Normal',0}}) do
            local active=option[2]==0 and U.state.fast~=1 and U.state.quick==0
                or (option[2]==2 or option[2]==4) and U.state.fast==1 and U.state.fastRate==option[2]
            add((active and '[x] ' or '')..P.Text(option[1]),'castingMode',option[2])
        end
    elseif mode=='theme' then
        bbPartyChoiceTitle=P.Text('BuffBot theme')
        bbPartyChoiceHint=P.Text('Auto follows UI++; without UI++, Auto uses BG1.')
        for _,option in ipairs({{'Auto',-1},{'Siege of Dragonspear',0},{'Icewind Dale',1},{'Baldur’s Gate',2},{'Baldur’s Gate II',3}}) do
            local active=U.state.skin==option[2] or U.state.skin==nil and option[2]==-1
            add((active and '[x] ' or '')..option[1],'theme',option[2])
        end
    elseif mode=='delete' then
        U.deleteIndex,U.deletePreset,U.deleteState=U.state.active,U.preset,U.state
        bbPartyChoiceTitle=P.Text('Delete preset?')
        bbPartyChoiceHint=U.preset.name..' / '..#U.preset.requests..' '..P.Text('requests')
        add(P.Text('Delete'), 'deletePreset');add(P.Text('Cancel'),'cancel')
    elseif mode=='planImport' then
        bbPartyChoiceTitle=P.Text('Import plan')
        bbPartyChoiceHint=P.Text('Creates a new preset; existing presets are kept')
        for _,name in ipairs(BfBot.PlanIO.List()) do add(name,'importPlan',name) end
    elseif mode == "sources" then
        local group = U.snapshot.groups[key]
        bbPartyChoiceTitle = P.Text("Sources: ") .. (group and U.BuffName(group,variant) or key)
        local hasVariants = false
        for _,s in ipairs(group and group.sources or {}) do
            if s.variants and #s.variants>0 then hasVariants=true end
        end
        bbPartyChoiceHint = hasVariants and (P.Text("Shared uses: ") .. group.name
            .. "\n" .. P.Text("Variants spend the same parent spell uses."))
            or P.Text("Available casters and durations. Select recipients in the main list.")
        local seen = {}
        for _, source in ipairs(group and group.sources or {}) do
            if (variant and U.VariantInfo({sources={source}},variant))
                or (not variant and not hasVariants) then
                local cap=U.snapshot.pools[source.pool] or 0
                local duration=variant and source.variantDurations and source.variantDurations[variant] or source.duration
                local label=P.Text("Caster: ") .. source.casterName .. " / " .. U.Duration(duration)
                    .. " / " .. P.Text("Uses: ") .. math.max(0,cap-(U.plan.used[source.pool] or 0)) .. "/" .. cap
                    .. (source.reason and (" / " .. source.reason) or "")
                if not seen[label] then add(label,"info");seen[label]=true end
            end
        end
        if #bbPartyChoices==0 then add(P.Text("No eligible source"),"info") end
        add(P.Text(hasVariants and "Hide spell and all variants" or "Hide"), "hide", key)
    elseif mode == "hidden" then
        bbPartyChoiceTitle=P.Text("Hidden")
        for hidden in pairs(U.state.hidden) do
            local group = U.snapshot.groups[hidden]
            add(group and group.name or hidden, "restore", hidden, group and group.icon)
        end
    elseif mode == "add" then
        bbPartyChoiceTitle=P.Text("Add spell / item")
        local seen = {}
        for _, actor in ipairs(U.snapshot.casters or U.snapshot.order) do
            for _, row in pairs(actor.rows or {}) do
                local group = P.GroupKey(row)
                if not seen[group] and row.class and (row.count or 0) > 0
                    and (U.state.hidden[group] or not U.snapshot.groups[group]) then
                    add(row.name .. " / " .. actor.name, "include", group, row.icon)
                    seen[group] = true
                end
            end
        end
    end
    if mode == "hidden" or mode == "add" then
        table.sort(bbPartyChoices, function(a,b) return a.name < b.name end)
    end
    U.choiceVariant=variant
    if BfBot.Visual and BfBot.Visual.active and BfBot.Visual.ShowChoices then
        return BfBot.Visual.ShowChoices()
    end
    Infinity_PushMenu("BUFFBOT_PARTY_CHOICES")
end
function U.Choose()
    local row = bbPartyChoices[bbPartyChoiceSelection]
    if not row or row.kind == "info" then return end
    if BfBot.Visual and BfBot.Visual.popup then BfBot.Visual.ClosePopup()
    else Infinity_PopMenu("BUFFBOT_PARTY_CHOICES") end
    if row.kind == "caster" then U.SetCaster(row.value);return
    elseif row.kind == "preset" then U.state.active = row.value; U.request = nil
    elseif row.kind == "rest" then
        U.state.rest = {on=row.value == 0 and 0 or 1,preset=row.value == 0 and U.state.active or row.value}
        if BfBot.Rest then BfBot.Rest.pending = nil end
    elseif row.kind == "hide" then U.state.hidden[row.value] = 1
    elseif row.kind == "restore" then U.state.hidden[row.value] = nil
    elseif row.kind == "include" then U.state.hidden[row.value] = nil; U.state.include[row.value] = 1
    elseif row.kind == "rename" then U.OpenRename(); return
    elseif row.kind=='exportPlan' then U.ExportPlan();return
    elseif row.kind=='openPlanImport' then U.OpenChoices('planImport');return
    elseif row.kind=='openDelete' then U.OpenChoices('delete');return
    elseif row.kind=='openTheme' then U.OpenChoices('theme');return
    elseif row.kind=='theme' then
        U.state.skin=row.value~=-1 and row.value or nil
        if BfBot.Visual then BfBot.Visual.skinOverride=U.state.skin end
        if BfBot.Visual and BfBot.Visual.active then BfBot.Visual.Layout() end
    elseif row.kind=='openCasting' then U.OpenChoices('casting');return
    elseif row.kind=='castingMode' then
        U.state.fast=(row.value==2 or row.value==4) and 1 or 0
        U.state.quick=0
        if U.state.fast==1 then U.state.fastRate=row.value end
    elseif row.kind=='importPlan' then U.ImportPlan(row.value);return
    elseif row.kind=='deletePreset' then U.DeletePreset();return
    elseif row.kind=='cancel' then return
    elseif row.kind == "import" then U.ImportLegacy(); return
    elseif row.kind == "legacy" then U.Legacy(); return end
    U.Refresh(row.kind == "refresh" or row.kind == "include")
end
function U.OpenRename(isNew)
    bbPartyName = U.preset.name
    if BfBot.Visual and BfBot.Visual.active and BfBot.Visual.Rename then
        return BfBot.Visual.Rename(isNew)
    end
    Infinity_PushMenu("BUFFBOT_PARTY_RENAME")
end
function U.CreatePreset()
    local old = U.state.active
    U.NewPreset()
    if U.state.active ~= old then U.OpenRename(true) end
end
function U.SaveName()
    U.Rename()
    if BfBot.Visual and BfBot.Visual.popup then BfBot.Visual.ClosePopup()
    else Infinity_PopMenu("BUFFBOT_PARTY_RENAME") end
end
function U.PopupLayout(rename)
    local sw,sh = Infinity_GetScreenSize()
    local header = not rename and bbPartyChoiceTitle and bbPartyChoiceTitle~=""
        and (bbPartyChoiceHint~="" and 88 or 40) or 0
    local w,h = math.min(520,sw-40), rename and 142 or math.min(430,sh-40,#bbPartyChoices*34+64+header)
    local x,y = math.floor((sw-w)/2),math.floor((sh-h)/2)
    if not rename and (U.choiceMode == "presets" or U.choiceMode == "rest" or U.choiceMode == "settings") then
        local anchor = U.choiceMode == "presets" and "bpPreset"
            or U.choiceMode == "rest" and "bpRest" or "bpSettings"
        local ax,ay,aw,ah = EEex_Menu_GetItemArea(anchor)
        w = U.choiceMode == "presets" and aw or math.max(260,aw)
        x = math.min(ax,sw-w-8)
        y = ay + ah + 2
        if y+h > sh-8 then y = ay-h-2 end
    end
    if not rename and U.choiceMode=="caster" and U.choiceAnchor then
        local anchor=U.choiceAnchor
        w=math.min(420,sw-40);x=math.max(8,math.min(anchor.x,sw-w-8))
        y=anchor.y
        if y+h>sh-8 then y=math.max(8,anchor.y-42-h) end
    end
    local function area(name,dx,dy,aw,ah) Infinity_SetArea(name,x+dx,y+dy,aw,ah) end
    if rename then
        area("bpRenameShadow",5,5,w+2,h+2)
        area("bpRenameTop",-3,-3,w+6,3);area("bpRenameBottom",-3,h,w+6,3)
        area("bpRenameLeft",-3,0,3,h);area("bpRenameRight",w,0,3,h)
        area("bpRenameBg",0,0,w,h);area("bpName",16,20,w-32,30)
        area("bpSaveName",w-180,h-50,78,30);area("bpCancelName",w-94,h-50,78,30)
    else
        area("bpChoicesShadow",5,5,w+2,h+2)
        area("bpChoicesTop",-3,-3,w+6,3);area("bpChoicesBottom",-3,h,w+6,3)
        area("bpChoicesLeft",-3,0,3,h);area("bpChoicesRight",w,0,3,h)
        area("bpChoicesBg",0,0,w,h)
        area("bpChoicesTitle",12,10,w-24,30);area("bpChoicesHint",12,42,w-24,44)
        area("bpChoices",12,12+header,w-24,h-64-header)
        area("bpChoicesClose",w-94,h-42,78,28)
    end
end
