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
    U.screenW, U.screenH = sw, sh
    local function area(name, dx, dy, aw, ah)
        Infinity_SetArea(name, x + dx, y + dy, aw, ah)
    end
    area("bpBg", 0, 0, w, h)
    local tabW = math.min(110, math.floor((w - 320) / 4))
    for i, name in ipairs({"bpDashboardTab", "bpSummaryTab", "bpCoverageTab", "bpOrderTab"}) do
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
    area("bpShowAll", 264, h - 100, 158, 28)
    local headX = 12
    for _, col in ipairs({{"Icon",5},{"Name",22},{"Uses",8},{"Duration",11},{"Recipients",48},{"Actions",6}}) do
        area("bpHead" .. col[1], headX + 2, 84, math.floor((w - 24) * col[2] / 100) - 4, 24)
        headX = headX + (w - 24) * col[2] / 100
    end
    area("bpDashboard", 12, 112, w - 24, h - 218)
    area("bpCoverage", 12, 112, w - 24, h - 218)
    for i = 1, 6 do
        area("bpCoverageHead" .. i, 12 + math.floor((w - 24) * (.4 + (i - 1) * .1)), 84,
            math.floor((w - 24) * .1), 24)
    end
    area("bpSummary", 12, 50, w - 24, h - 156)
    area("bpPlan", 12, 50, w - 24, h - 194)
    area("bpSource", 12, h - 138, 130, 28)
    area("bpUp", 148, h - 138, 54, 28)
    area("bpDown", 208, h - 138, 54, 28)
    area("bpRemove", 268, h - 138, 80, 28)
    area("bpAdd", 12, h - 100, 142, 28)
    area("bpHidden", 160, h - 100, 96, 28)
    area("bpRest", 12, h - 64, math.min(260, w - 280), 30)
    area("bpStatus", 282, h - 62, math.max(20, w - 494), 32)
    area("bpCast", w - 200, h - 64, 110, 30)
    area("bpStop", w - 84, h - 64, 72, 30)
    area("bpFeedback", 12, h - 28, w - 24, 22)
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
function U.Refresh(fresh)
    if fresh ~= false then BfBot.Scan.InvalidateAll() end
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
    local queue, _, reason = P.BuildQueue(U.snapshot, U.preset.requests)
    if not queue then bbPartyStatus = reason or P.Text("Resolve unavailable casts before casting"); return end
    if BfBot.Exec.Start(queue, 0, nil) then U.Close() end
end

-- The list widget dispatches clicks through its selected-row variable. Never
-- use render-time rowNumber in actions (it can point at the last painted row).
bbPartyRows, bbPartySummary, bbPartyChoices = {}, {}, {}
bbPartyRowSelection, bbPartySummarySelection, bbPartyChoiceSelection = 0, 0, 0
bbPartyQuery, bbPartyFeedback = "", ""
U.view, U.recipient, U.showIneligible = "dashboard", "all", false
U.sortField, U.sortDescending = "name", false

local function copyRequests(requests)
    local result = {}
    for i, r in ipairs(requests) do result[i] = r end
    return result
end
local function planned(group, target)
    for i, r in ipairs(U.preset.requests) do
        if r.group == group and r.target == target then return i end
    end
end
function U.Preview(group, target, variant)
    local index = planned(group, target)
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
    local requested = {}
    for _, r in ipairs(U.preset.requests) do requested[r.group] = true end
    for _, catalog in ipairs(bbPartyBuffs) do
        local group = U.snapshot.groups[catalog.key]
        local row = { key = catalog.key, name = group.name, icon = group.icon or "",
            uses = catalog.uses, free = 0, total = 0, planned = 0, cells = {},
            variant = U._variant[catalog.key], party = false }
        local pools, livingSource = {}, false
        local variants, seen = {}, {}
        for _, source in ipairs(group.sources) do
            local cap = U.snapshot.pools[source.pool] or 0
            if not source.reason and cap > 0 then livingSource = true end
            if not source.reason and not pools[source.pool] then
                row.total = row.total + cap
                row.free = row.free + math.max(0, cap - (U.plan.used[source.pool] or 0))
                pools[source.pool] = true
            end
            row.party = row.party or source.aoe == true
            for _, variant in ipairs(source.variants or {}) do
                if not seen[variant.resref] then
                    variants[#variants + 1] = variant; seen[variant.resref] = true
                end
            end
        end
        table.sort(variants, function(a, b) return a.resref < b.resref end)
        if #variants > 0 and not seen[row.variant] then row.variant = variants[1].resref end
        U._variant[row.key], row.variants = row.variant, variants
        local item = group.kind == "itm" or group.sources[1] and group.sources[1].row.kind == "itm"
        row.qualifier = item and P.Text("Item") or ""
        if counts[group.name] > 1 then
            row.qualifier = (item and P.Text("Item") or P.Text("Spell"))
                .. " / " .. (group.sources[1] and group.sources[1].row.resref or row.key)
        end
        for _, variant in ipairs(variants) do
            if variant.resref == row.variant then
                row.qualifier = variant.name or variant.label or variant.resref
            end
        end
        local party, index = U.Preview(row.key, "party", row.variant)
        row.partyCell = { decision = party, index = index, checked = index ~= nil,
            available = party and party.source ~= nil, target = "party", name = P.Text("Party") }
        for i, actor in ipairs(U.snapshot.order) do
            local d, existing = U.Preview(row.key, actor.key, row.variant)
            row.cells[i] = { target = actor.key, name = actor.name, slot = actor.slot,
                decision = d, index = existing, checked = existing ~= nil,
                available = d and d.source ~= nil }
        end
        for _, r in ipairs(U.preset.requests) do if r.group == row.key then row.planned = row.planned + 1 end end
        -- Exhausted but planned entries remain removable. Unknown/empty
        -- sources do not clutter the browser with anonymous zero-use rows.
        if (livingSource or requested[row.key]) and not U.state.hidden[row.key] then
            U.dashboard[#U.dashboard + 1] = row
        end
    end
    -- A missing resource is still a visible request, never silently erased.
    for key in pairs(requested) do
        if not U.snapshot.groups[key] and not U.state.hidden[key] then
            local row = { key = key, name = key, icon = "", uses = "0/0", cells = {},
                total = 0, free = 0, planned = 0, qualifier = P.Text("Buff unavailable") }
            for i, actor in ipairs(U.snapshot.order) do
                local d, index = U.Preview(key, actor.key)
                row.cells[i] = { target = actor.key, name = actor.name, slot = actor.slot,
                    checked = index ~= nil, index = index, decision = d, available = false }
            end
            local d, index = U.Preview(key, "party")
            row.party, row.partyCell = index ~= nil, { target = "party", name = P.Text("Party"),
                checked = index ~= nil, index = index, decision = d, available = false }
            U.dashboard[#U.dashboard + 1] = row
        end
    end
    table.sort(U.dashboard, function(a,b)
        if a.name ~= b.name then return a.name < b.name end
        return a.key < b.key
    end)
    U.FilterDashboard()
    bbPartySummary = {}
    local targets = {{key="party",name=P.Text("Party")}}
    for _, actor in ipairs(U.snapshot.order) do targets[#targets + 1] = actor end
    for _, target in ipairs(targets) do
        bbPartySummary[#bbPartySummary + 1] = { heading = true, name = target.name, icon = "" }
        local added = false
        for _, row in ipairs(bbPartyRequests) do
            if row.request.target == target.key then
                local group = U.snapshot.groups[row.request.group]
                bbPartySummary[#bbPartySummary + 1] = { name = row.name,
                    icon = group and group.icon or "", assignment = row.assignment,
                    unavailable = row.unavailable, request = row.request }
                added = true
            end
        end
        if not added then bbPartySummary[#bbPartySummary + 1] = {name=P.Text("None"),icon=""} end
    end
    -- Orphaned/departed recipients remain reviewable/removable in cast order.
    for _, row in ipairs(bbPartyRequests) do
        if row.request.target ~= "party" and not U.snapshot.actors[row.request.target] then
            bbPartySummary[#bbPartySummary + 1] = { name = row.name .. " / " .. row.target,
                icon = "", assignment = row.assignment, unavailable = true, request = row.request }
        end
    end
end
function U.FilterDashboard()
    bbPartyRows = {}
    local query = (bbPartyQuery or ""):lower()
    for _, row in ipairs(U.dashboard or {}) do
        local matches = query == "" or row.name:lower():find(query, 1, true)
        local allowed = U.recipient == "all" or row.party or U.showIneligible
        for _, cell in ipairs(row.cells) do
            if cell.target == U.recipient and (cell.checked or cell.available) then allowed = true end
        end
        if matches and allowed then
            row.sortLow, row.sortHigh = U.DurationRange(row)
            bbPartyRows[#bbPartyRows + 1] = row
        end
    end
    table.sort(bbPartyRows, function(a,b)
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
        return a.key < b.key
    end)
    bbPartyRowSelection = 0
    U.lastQuery = bbPartyQuery
end
function U.SortBy(field)
    if field ~= "name" and field ~= "duration" then return end
    if U.sortField == field then U.sortDescending = not U.sortDescending
    else U.sortField, U.sortDescending = field, false end
    U.FilterDashboard()
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
    U.FilterDashboard()
end
function U.RecipientName(slot)
    return slot == 0 and P.Text("All buffs") or U.snapshot and U.snapshot.order[slot]
        and U.snapshot.order[slot].name or ""
end
function U.IsRecipient(slot)
    return slot == 0 and U.recipient == "all" or U.snapshot and U.snapshot.order[slot]
        and U.recipient == U.snapshot.order[slot].key or false
end
function U.IsDashboard() return U.view == "dashboard" or U.view == "coverage" end
function U.Tick()
    if bbPartyQuery ~= U.lastQuery then U.FilterDashboard() end
    if Infinity_GetScreenSize then
        local w,h = Infinity_GetScreenSize()
        if w ~= U.screenW or h ~= U.screenH then U.Layout() end
    end
    return false
end
function U.Cell(rowIndex, slot)
    local row = bbPartyRows[rowIndex]
    if not row then return nil end
    if U.recipient ~= "all" then
        if slot ~= 1 then return nil end
        for _, cell in ipairs(row.cells) do if cell.target == U.recipient then return cell end end
    end
    return row.cells[slot]
end
-- The dashboard packs applicable recipients into a compact strip. Coverage
-- retains its fixed party columns, so the two views must not share click indices.
function U.DashboardCell(rowIndex, slot)
    local row = bbPartyRows[rowIndex]
    if not row or row.party then return nil end
    local visible = 0
    for _, cell in ipairs(row.cells) do
        if (U.recipient == "all" or U.recipient == cell.target)
            and (cell.available or cell.checked) then
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
-- Duration comes from the actual assigned/previewed source, including variants.
-- The row summarizes only the recipients currently visible in this view.
function U.DurationRange(row)
    if not row then return end
    local low, high
    local function include(cell)
        local d = cell and cell.decision
        if not d or not d.source then return end
        local n = d.duration or 0
        if n == -1 then n = math.huge end
        low, high = math.min(low or n,n), math.max(high or n,n)
    end
    if row.party then include(row.partyCell)
    else
        for _,cell in ipairs(row.cells) do
            if (U.recipient == "all" or U.recipient == cell.target)
                and (cell.available or cell.checked) then include(cell) end
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
    local d = cell and cell.decision
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
function U.CellColor(rowIndex, slot)
    local cell = U.Cell(rowIndex, slot)
    if cell and cell.checked and not cell.available then return {155,40,25} end
    return cell and not cell.available and {125,120,112} or {38,32,26}
end
function U.DashboardColor(rowIndex, slot)
    local cell = U.DashboardCell(rowIndex, slot)
    return cell and cell.checked and not cell.available and {155,40,25} or {38,32,26}
end
function U.CellPortrait(rowIndex, slot)
    local row, cell = bbPartyRows[rowIndex], U.DashboardCell(rowIndex, slot)
    return row and not row.party and cell and (cell.available or cell.checked) and U.Portrait(cell.slot) or ""
end
function U.ToggleCell(row, target)
    local decision, index = U.Preview(row.key, target, row.variant)
    if index then
        -- A checkbox represents coverage, so clear imported repeat requests
        -- for this recipient together instead of leaving a hidden duplicate.
        for i = #U.preset.requests, 1, -1 do
            local r = U.preset.requests[i]
            if r.group == row.key and r.target == target then table.remove(U.preset.requests, i) end
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
    if not row then return end
    if column <= 2 then U.OpenChoices("sources", row.key)
    elseif column >= 5 and column <= 10 then
        if row.party then
            if column == 5 then U.ToggleCell(row,"party") end
        else
            local cell = U.DashboardCell(bbPartyRowSelection, column - 4)
            if cell then U.ToggleCell(row, cell.target) end
        end
    elseif column == 11 then
        for i = #U.preset.requests, 1, -1 do
            if U.preset.requests[i].group == row.key then table.remove(U.preset.requests, i) end
        end
        U.Refresh(false)
    end
end
function U.CoverageText(index, slot)
    local row = bbPartyRows[index]
    if not row then return "" end
    if row.party then
        return row.partyCell.checked and ((row.partyCell.available and "[x] " or "[!] ") .. P.Text("Party")) or "-"
    end
    local cell = U.Cell(index, slot)
    return cell and (cell.checked and (cell.available and "[x]" or "[!]") or cell.available and "[ ]" or "-") or ""
end
function U.CoverageClick(column)
    local row = bbPartyRows[bbPartyRowSelection]
    if not row then return end
    if column <= 2 then U.OpenChoices("sources", row.key)
    elseif row.party then bbPartyFeedback = P.Text("Party-wide cast")
    else
        local cell = U.Cell(bbPartyRowSelection, column - 2)
        if cell then U.ToggleCell(row, cell.target) end
    end
end
function U.CoverageColor(index, slot)
    local row = bbPartyRows[index]
    return row and row.party and U.PartyColor(index) or U.CellColor(index, slot)
end
function U.CoverageName(slot)
    if U.recipient ~= "all" then
        return slot == 1 and U.snapshot.actors[U.recipient].name or ""
    end
    return U.RecipientName(slot)
end
function U.RowName(index)
    local row = bbPartyRows[index]
    return row and (row.name .. (row.qualifier ~= "" and ("\n" .. row.qualifier) or "")) or ""
end
function U.PartyColor(index)
    local row = bbPartyRows[index]
    return row and row.party and row.partyCell.checked and not row.partyCell.available
        and {155,40,25} or {38,32,26}
end
function U.SummaryName(index)
    local row = bbPartySummary[index]
    return row and (row.heading and ("[ " .. row.name .. " ]") or row.name) or ""
end
function U.RequestIcon(index)
    local row = bbPartyRequests[index]
    local group = row and U.snapshot.groups[row.request.group]
    return group and group.icon or ""
end
function U.SummaryClick()
    local row = bbPartySummary[bbPartySummarySelection]
    if not row or not row.request then return end
    U.request, U.view = row.request, "order"
    U.Refresh(false)
end
function U.OpenChoices(mode, key)
    U.choiceMode, U.choiceGroup = mode, key
    bbPartyChoices, bbPartyChoiceSelection = {}, 0
    local function add(name, kind, value, icon)
        bbPartyChoices[#bbPartyChoices + 1] = {name=name,kind=kind,value=value,icon=icon or ""}
    end
    if mode == "presets" or mode == "rest" then
        if mode == "rest" then add(P.Text("Off"), "rest", 0) end
        for i=1,8 do
            local preset = U.state.presets[i]
            if preset then add(preset.name, mode == "rest" and "rest" or "preset", i) end
        end
    elseif mode == "settings" then
        add(P.Text("Rename"), "rename")
        add(P.Text("Refresh"), "refresh")
        add(P.Text("Import caster preset"), "import")
        add(P.Text("Caster editor"), "legacy")
    elseif mode == "sources" then
        local group = U.snapshot.groups[key]
        local seen = {}
        for _, source in ipairs(group and group.sources or {}) do
            local label = source.casterName .. " / " .. U.Duration(source.duration)
            if not seen[label] then add(label, "info"); seen[label] = true end
        end
        for _, row in ipairs(U.dashboard) do
            if row.key == key then
                for _, variant in ipairs(row.variants or {}) do
                    add(P.Text("Variant: ") .. (variant.name or variant.label or variant.resref), "variant", variant.resref)
                end
            end
        end
        add(P.Text("Hide"), "hide", key)
    elseif mode == "hidden" then
        for hidden in pairs(U.state.hidden) do
            local group = U.snapshot.groups[hidden]
            add(group and group.name or hidden, "restore", hidden, group and group.icon)
        end
    elseif mode == "add" then
        local seen = {}
        for _, actor in ipairs(U.snapshot.order) do
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
    Infinity_PushMenu("BUFFBOT_PARTY_CHOICES")
end
function U.Choose()
    local row = bbPartyChoices[bbPartyChoiceSelection]
    if not row or row.kind == "info" then return end
    Infinity_PopMenu("BUFFBOT_PARTY_CHOICES")
    if row.kind == "preset" then U.state.active = row.value; U.request = nil
    elseif row.kind == "rest" then
        U.state.rest = {on=row.value == 0 and 0 or 1,preset=row.value == 0 and U.state.active or row.value}
        if BfBot.Rest then BfBot.Rest.pending = nil end
    elseif row.kind == "hide" then U.state.hidden[row.value] = 1
    elseif row.kind == "restore" then U.state.hidden[row.value] = nil
    elseif row.kind == "include" then U.state.hidden[row.value] = nil; U.state.include[row.value] = 1
    elseif row.kind == "variant" then U._variant[U.choiceGroup] = row.value
    elseif row.kind == "rename" then U.OpenRename(); return
    elseif row.kind == "import" then U.ImportLegacy(); return
    elseif row.kind == "legacy" then U.Legacy(); return end
    U.Refresh(row.kind == "refresh" or row.kind == "include")
end
function U.OpenRename()
    bbPartyName = U.preset.name
    Infinity_PushMenu("BUFFBOT_PARTY_RENAME")
end
function U.CreatePreset()
    local old = U.state.active
    U.NewPreset()
    if U.state.active ~= old then U.OpenRename() end
end
function U.SaveName()
    U.Rename(); Infinity_PopMenu("BUFFBOT_PARTY_RENAME")
end
function U.PopupLayout(rename)
    local sw,sh = Infinity_GetScreenSize()
    local w,h = math.min(520,sw-40), rename and 142 or math.min(430,sh-40,#bbPartyChoices*34+64)
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
        area("bpChoicesBg",0,0,w,h);area("bpChoices",12,12,w-24,h-64)
        area("bpChoicesClose",w-94,h-42,78,28)
    end
end
