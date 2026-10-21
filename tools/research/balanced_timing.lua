-- Offline feasibility model only. Not loaded, installed, or used by BuffBot.
-- All values are measured integer ticks supplied by a future engine adapter.
-- This does not infer casting time, aura timing, or delivery from spell data.
local M = {}
local MAX = 9007199254740991 -- largest exactly representable integer in LuaJIT

local function tick(n)
    return type(n) == 'number' and n >= 0 and n <= MAX and n == math.floor(n)
end
local function key(s)
    return type(s) == 'string' and s ~= ''
end
local function sum(a, b)
    if b > MAX - a then return nil end
    return a + b
end

-- jobs preserve user order within each caster. Different casters are independent.
-- releaseTicks: start -> spell release/action completion.
-- readyTicks: start -> earliest next action start (includes aura/animation gates).
-- deliveryTicks: release -> last effect delivery belonging to this cast.
-- The final trailing aura is not part of preparation completion.
function M.Schedule(jobs, initialReady)
    if type(jobs) ~= 'table' or #jobs > 256 then return nil, 'Invalid job list' end
    local count = 0
    for i in pairs(jobs) do
        if not tick(i) or i < 1 or i > #jobs then return nil, 'Invalid job list' end
        count = count + 1
    end
    if count ~= #jobs then return nil, 'Invalid job list' end
    initialReady = initialReady or {}
    if type(initialReady) ~= 'table' then return nil, 'Invalid initial readiness' end
    for caster, ready in pairs(initialReady) do
        if not key(caster) or not tick(ready) then return nil, 'Invalid initial readiness' end
    end
    local lanes, order, entries, ids = {}, {}, {}, {}
    local horizon = 0
    for i, job in ipairs(jobs) do
        if type(job) ~= 'table' or not key(job.id) or ids[job.id]
            or not key(job.caster) then return nil, 'Invalid or duplicate job identity' end
        if job.kind ~= 'spl' then return nil, 'Only independent spell casts are modeled' end
        if job.dependencies ~= nil and (type(job.dependencies) ~= 'table'
            or next(job.dependencies) ~= nil) then return nil, 'Dependencies require a separate model' end
        if not tick(job.releaseTicks) or not tick(job.readyTicks)
            or job.readyTicks < job.releaseTicks or not tick(job.deliveryTicks or 0) then
            return nil, 'Invalid measured timing'
        end
        ids[job.id] = true
        local lane = lanes[job.caster]
        if not lane then
            lane = { caster = job.caster, cursor = initialReady[job.caster] or 0,
                finish = 0, entries = {} }
            lanes[job.caster] = lane; order[#order + 1] = job.caster
        end
        local release = sum(lane.cursor, job.releaseTicks)
        local ready = sum(lane.cursor, job.readyTicks)
        local delivery = release and sum(release, job.deliveryTicks or 0)
        if not release or not ready or not delivery then return nil, 'Timing overflow' end
        local entry = { id = job.id, caster = job.caster, index = i,
            start = lane.cursor, release = release, delivery = delivery }
        lane.entries[#lane.entries + 1] = entry; entries[i] = entry
        lane.cursor = ready
        lane.finish = math.max(lane.finish, delivery)
        horizon = math.max(horizon, lane.finish)
    end
    -- Translate each independent sequence so its last delivery lands at the
    -- common finish, without changing its internal ordering or timing gaps.
    for _, caster in ipairs(order) do
        local lane = lanes[caster]
        lane.offset = horizon - lane.finish
        for _, entry in ipairs(lane.entries) do
            entry.start = entry.start + lane.offset
            entry.release = entry.release + lane.offset
            entry.delivery = entry.delivery + lane.offset
            entry.virtualAge = horizon - entry.delivery
        end
        lane.finish = horizon
    end
    return { finish = horizon, entries = entries, lanes = lanes, casterOrder = order }
end

-- Per-effect arithmetic proposal, never an engine mutation. Existing effects
-- need no timestamps because they are deliberately left alone.
-- durationTicks: original finite duration of THIS effect (not catalog maximum).
-- realAgeTicks: actual elapsed game ticks since THIS effect landed.
-- virtualAgeTicks: normal reference finish minus reference effect delivery.
-- Exact correction can require extending a newly produced, still-live effect;
-- allowExtension=false is a conservative beta alternative, not exact balance.
function M.Correction(effect)
    if type(effect) ~= 'table' then return nil, 'Invalid effect record' end
    if effect.owned ~= true then return { action = 'untouched', reason = 'Not attributed to this run' } end
    if effect.timing == 'permanent' then return { action = 'untouched', reason = 'Permanent effect' } end
    if effect.timing ~= 'finite' then return nil, 'Unsupported effect timing' end
    if not tick(effect.durationTicks) or not tick(effect.realAgeTicks)
        or not tick(effect.virtualAgeTicks) then return nil, 'Invalid effect timing' end
    local current = math.max(0, effect.durationTicks - effect.realAgeTicks)
    local ideal = math.max(0, effect.durationTicks - effect.virtualAgeTicks)
    if current == 0 and ideal > 0 then
        return { action = 'blocked', reason = 'Cannot revive an expired effect',
            currentRemaining = current, idealRemaining = ideal }
    end
    local target = ideal
    local conservative = false
    if target > current and effect.allowExtension ~= true then
        target = current; conservative = true
    end
    local delta = target - current
    local action = target == 0 and current > 0 and 'expire'
        or delta < 0 and 'shorten' or delta > 0 and 'extend' or 'unchanged'
    return { action = action, currentRemaining = current, idealRemaining = ideal,
        targetRemaining = target, shiftTicks = delta, conservative = conservative }
end

return M
