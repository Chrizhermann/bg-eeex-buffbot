-- Party-wide recipient plans. Persistent requests contain identities, never
-- sprite pointers or reservations; every preview/run plans a fresh snapshot.
BfBot.Plan = {}
local P = BfBot.Plan
P.MAX_REQUESTS = 256

local _textKeys = {
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
function P.Assign(snapshot, requests)
    local result = { decisions = {}, used = {}, missing = 0 }
    local candidates, occupants = {}, {}
    local function allowed(s, r)
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
    local function duration(s, r)
        return (r.var and s.variantDurations and s.variantDurations[r.var]) or s.duration or 0
    end
    local function better(a, b, r)
        local ad, bd = duration(a, r), duration(b, r)
        if ad == -1 then ad = math.huge end
        if bd == -1 then bd = math.huge end
        if ad ~= bd then return ad > bd end
        if (a.casterLevel or 0) ~= (b.casterLevel or 0) then
            return (a.casterLevel or 0) > (b.casterLevel or 0)
        end
        return a.id < b.id
    end
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
            local ok, why = allowed(s, request)
            if ok then candidates[i][#candidates[i] + 1] = s else reason = why end
        end
        table.sort(candidates[i], function(a, b) return better(a, b, request) end)
        if request.on == 0 then decision.reason = P.Text("Disabled")
        elseif not move(i, {}) then
            decision.reason = #candidates[i] > 0 and P.Text("No unreserved uses") or reason
            result.missing = result.missing + 1
        end
    end
    for _, d in ipairs(result.decisions) do
        if d.source then
            d.duration = duration(d.source, d.request)
            result.used[d.source.pool] = (result.used[d.source.pool] or 0) + 1
        end
    end
    return result
end

-- Native pools. Sorcerer/shaman choices at one level share uses; prepared
-- casters and innates spend the specific resource. 5E stays in the legacy
-- editor until its cross-wrapper pool semantics have been verified here.
function P.SpellPool(actor, row)
    if row.d5 then return nil, P.Text("5E sources require the caster editor") end
    if not integer(actor.class, 1, 21) then return nil, P.Text("Caster class unavailable") end
    if (actor.class == 19 and row.spellType == 1)
        or (actor.class == 21 and row.spellType == 2) then
        return actor.key .. ":level:" .. row.spellType .. ":" .. row.level
    end
    return actor.key .. ":spell:" .. row.resref:upper()
end
local function putPool(snapshot, key, count)
    count = integer(count, 0, 1000000) and count or 0
    snapshot.pools[key] = math.min(snapshot.pools[key] or count, count)
end
function P.Snapshot()
    local owner = BfBot.Persist._GetProtagonist and BfBot.Persist._GetProtagonist()
    local preferences = owner and EEex_GetUDAux(owner).BBParty
    local snap = { actors = {}, order = {}, groups = {}, pools = {} }
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local key = P.ActorKey(sprite)
            local okClass, cls = pcall(function() return sprite.m_typeAI.m_Class end)
            local actor = { key = key, name = BfBot._GetName(sprite), slot = slot,
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
        end
    end
    for _, actor in ipairs(snap.order) do
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
            if row.class and (row.class.isBuff or manual) then
                local key = P.GroupKey(row)
                local group = snap.groups[key]
                if not group then
                    group = { key = key, name = row.name, kind = row.kind,
                        icon = row.icon, sources = {} }
                    snap.groups[key] = group
                end
                local reason = actor.ambiguous and P.Text("Ambiguous character identity")
                    or not actor.alive and P.Text("Caster is dead")
                    or not actor.controlled and P.Text("Caster controlled by another player")
                    or poolReason
                local function add(sourcePool, itemSlot, count)
                    if sourcePool then putPool(snap, sourcePool, count) end
                    local source = { id = actor.key .. "/" .. key .. "/" .. tostring(itemSlot or "spell"),
                        actor = actor.key, casterName = actor.name, slot = actor.slot,
                        row = row, pool = sourcePool or (actor.key .. ":unavailable"),
                        reason = reason, duration = row.duration, casterLevel = row.casterLevel,
                        selfOnly = row.isSelfOnly == 1, aoe = row.isAoE == 1,
                        variants = row.variants, variantDurations = {}, itemSlot = itemSlot }
                    if row.hasVariants == 1 and (not row.variants or #row.variants == 0) then
                        source.reason = P.Text("Variant metadata unavailable")
                    end
                    if row.kind == "itm" and BfBot.Persist.GetPref("ItemUseMode") == "swap"
                        and itemSlot >= 18 and itemSlot <= 33 and row.itemType ~= 9 then
                        local copy = {}
                        for k, v in pairs(row) do copy[k] = v end
                        copy.itemSlot = itemSlot
                        local swap, why = BfBot.Scan._PlanItemSwap(actor.sprite, copy)
                        if not swap then source.reason = why end
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
    return snap
end

function P.Validate(value)
    local state = { v = 1, active = 1, presets = {} }
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
        state.presets[1] = { name = P.Text("Preset ") .. 1, requests = {} }
        state.presets[2] = { name = P.Text("Preset ") .. 2, requests = {} }
    end
    if integer(value.active, 1, 8) and state.presets[value.active] then state.active = value.active
    else for i = 1, 8 do if state.presets[i] then state.active = i; break end end end
    local rest = type(value.rest) == "table" and value.rest or {}
    local validRest = integer(rest.preset, 1, 8) and state.presets[rest.preset]
    state.rest = { on = rest.on == 1 and validRest and 1 or 0,
        preset = validRest and rest.preset or state.active }
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
            if t.target == "self" then keys[1] = e.actor.key
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
                target = s.selfOnly and "self" or target, var = r.var, rep = 1,
                plannedActor = s.actor, plannedTarget = r.target,
                plannedItemSlot = s.itemSlot, isProjectImage = s.row.isProjectImage }
        end
    end
    if #queue == 0 then return nil, plan end
    -- Retain the executor's existing Project Image owner/ordering safeguards.
    if BfBot.Persist._ApplyPuppetLockPolicy then
        local clones = BfBot.Persist._CollectLiveCloneDescriptors()
        for _, actor in ipairs(snapshot.order) do
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
