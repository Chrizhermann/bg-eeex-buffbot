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
    local sw, sh = Infinity_GetScreenSize()
    local w, h = math.floor(sw * .94), math.floor(sh * .9)
    local x, y = math.floor((sw - w) / 2), math.floor((sh - h) / 2)
    local left, right = math.floor(w * .47), math.floor(w * .53) - 36
    local function area(name, dx, dy, aw, ah)
        Infinity_SetArea(name, x + dx, y + dy, aw, ah)
    end
    area("bpBg", 0, 0, w, h)
    area("bpTitle", 12, 6, w - 190, 28)
    area("bpLegacy", w - 182, 6, 100, 28)
    area("bpClose", w - 76, 6, 64, 28)
    area("bpPrev", 12, 40, 30, 28)
    area("bpName", 46, 42, left - 218, 24)
    area("bpRename", left - 166, 40, 74, 28)
    area("bpNext", left - 88, 40, 30, 28)
    area("bpNew", left - 54, 40, 54, 28)
    area("bpImport", left + 12, 40, 170, 28)
    area("bpRefresh", w - 110, 40, 98, 28)
    area("bpCatalogHead", 12, 74, left - 12, 24)
    area("bpPlanHead", left + 12, 74, right, 24)
    area("bpCatalog", 12, 100, left - 12, h - 396)
    area("bpVariant", 12, h - 290, left - 12, 28)
    area("bpTargets", 12, h - 256, left - 12, 198)
    area("bpPlan", left + 12, 100, right, h - 230)
    area("bpDetails", left + 12, h - 126, right, 40)
    area("bpSource", left + 12, h - 82, 130, 26)
    area("bpUp", left + 148, h - 82, 52, 26)
    area("bpDown", left + 206, h - 82, 52, 26)
    area("bpRemove", left + 264, h - 82, 80, 26)
    area("bpStatus", 12, h - 52, w - 232, 40)
    area("bpCast", w - 212, h - 46, 120, 32)
    area("bpStop", w - 86, h - 46, 74, 32)
end
function U.Open()
    if not P.GetState() then return end
    Infinity_PushMenu("BUFFBOT_PARTY")
end
function U.Close() Infinity_PopMenu("BUFFBOT_PARTY") end
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
function U.Refresh()
    BfBot.Scan.InvalidateAll()
    U.state = P.GetState()
    if not U.state then return end
    U.snapshot = P.Snapshot()
    U.preset = U.state.presets[U.state.active]
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
        bbPartyRequests[i] = { request = r, name = g and g.name or r.group,
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
    local actor = U.request and U.snapshot.actors[U.request.source]
    local selected = U.plan and U.plan.decisions[bbPartyRequestSelection]
    local level = selected and selected.source and selected.source.casterLevel
    bbPartyDetails = U.request and (P.Text("Source: ") .. (actor and actor.name or U.request.source or P.Text("Auto"))
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
            U.state.presets[i] = { name = P.Text("Preset ") .. i, requests = {} }
            U.state.active = i; U.request = nil; U.Refresh(); return
        end
    end
    bbPartyStatus = P.Text("Maximum eight presets")
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
    U.Refresh()
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
    local queue, _, reason = P.BuildQueue(U.snapshot, U.preset.requests)
    if not queue then bbPartyStatus = reason or P.Text("Resolve unavailable casts before casting"); return end
    if BfBot.Exec.Start(queue, 0, nil) then U.Close() end
end
