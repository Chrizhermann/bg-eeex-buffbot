-- ============================================================
-- BfBotPln.lua — Shared plan model (BfBot.Plan)
-- Party-wide buff requests, caster allocation and queue building
-- ============================================================
--
-- Adapted from Zach Hopkins' BuffBot Redux (issue #81, PR #80), with thanks.
--
-- This is the single allocation layer both panel views sit on. A REQUEST says
-- what a recipient should receive; it never names a sprite, an object ID or a
-- reserved use. Every preview and every run plans a FRESH snapshot from the
-- live party, because spell uses, equipment, summons and allegiance all move
-- between the moment a plan is edited and the moment it is cast.
--
-- The caster view reads the same requests grouped by `source`; the recipient
-- view (step 3) reads them grouped by `target`. There is deliberately no
-- second store: the requests live in the existing "BuffBot" save subtree, so
-- an edit in either view is the same edit.
--
-- What this module intentionally does NOT do:
--
--   * Automatic reordering. The fork's smart/long order engine reorders casts
--     by measured retained duration. "User spell priority is always respected
--     — no automatic reordering by duration category" is a standing design
--     decision here (CLAUDE.md), so the ordering heuristics are not ported.
--     `manual` carries the player's own order and nothing rewrites it.
--   * Its own save handler. The fork keeps a second `BuffBotParty` marshal
--     subtree next to `BuffBot`; two stores mean two truths for one buff.
--   * Player-facing prose. Rejections come back as the plain identifiers in
--     `P.REASON`. The view that displays a rejection maps it to localized
--     text, so the wording is written and reviewed where it is shown.

BfBot.Plan = {}
local P = BfBot.Plan

-- The engine's own action queue is the real limit on a single run; 256 is far
-- above any plausible party plan (6 casters x 8 presets x repeats) and keeps
-- the allocator's worst case bounded.
P.MAX_REQUESTS = 256

-- Why a cast cannot happen. Data-layer vocabulary, not display text: a view
-- maps these to localized strings. Keep them stable — they are compared, and
-- step 3's catalog keys will be derived from them.
P.REASON = {
    PREFERRED_CASTER_UNAVAILABLE = "preferred_caster_unavailable",
    RECIPIENT_UNAVAILABLE        = "recipient_unavailable",
    RECIPIENT_DEAD               = "recipient_dead",
    RECIPIENT_AMBIGUOUS          = "recipient_ambiguous",
    SELF_ONLY                    = "self_only",
    PARTY_WIDE_CAST              = "party_wide_cast",
    CHOOSE_RECIPIENT             = "choose_recipient",
    VARIANT_UNSUPPORTED          = "variant_unsupported",
    VARIANT_UNAVAILABLE          = "variant_unavailable",
    VARIANT_METADATA_MISSING     = "variant_metadata_missing",
    NO_ELIGIBLE_SOURCE           = "no_eligible_source",
    BUFF_UNAVAILABLE             = "buff_unavailable",
    DISABLED                     = "disabled",
    NO_UNRESERVED_USES           = "no_unreserved_uses",
    FIVE_E_SOURCE                = "five_e_source",
    CASTER_CLASS_UNAVAILABLE     = "caster_class_unavailable",
    CASTER_AMBIGUOUS             = "caster_ambiguous",
    CASTER_DEAD                  = "caster_dead",
    CASTER_NOT_CONTROLLED        = "caster_not_controlled",
    PROJECT_IMAGE_LOCKED         = "project_image_locked",
    ITEM_REQUIRES_CHOICE         = "item_requires_choice",
    SUMMON_ITEM_NOT_EQUIPPED     = "summon_item_not_equipped",
    PLAN_TOO_LARGE               = "plan_too_large",
    LEGACY_SOURCE_GONE           = "legacy_source_gone",
    LEGACY_RECIPIENT_GONE        = "legacy_recipient_gone",
}

local function integer(n, lo, hi)
    return type(n) == "number" and n == math.floor(n) and n >= lo and n <= hi
end

-- ============================================================
-- Identities
-- ============================================================

--- Stable key for a party member. The protagonist has an empty death variable,
--- so join order identifies them; everyone else is keyed by DV, which survives
--- a rename (knighthood turns Anomen into Sir Anomen). The display name is the
--- last resort and the only ambiguous one — `Snapshot` flags collisions.
function P.ActorKey(sprite)
    if EEex_Sprite_GetCharacterIndex(sprite) == 0 then return "protagonist" end
    local dv = BfBot._GetDeathVar(sprite)
    if dv ~= "" and dv:upper() ~= "NONE" then return "dv:" .. dv:upper() end
    return "name:" .. BfBot._GetName(sprite)
end

--- Recipients stay party-only. Casters additionally admit allied spellcasting
--- summons, keyed by their clone owner or scan identity — never by the spawn's
--- object ID, which is fresh for every summon.
function P.CasterKey(sprite, descriptor)
    if EEex_Sprite_GetPortraitIndex(sprite) ~= -1 then return P.ActorKey(sprite) end
    local entry = descriptor or BfBot.Scan.ClassifySummonSprite(sprite)
    if not entry then return nil end
    if entry.kind == "clone" then
        local owner = EEex_GameObject_Get(sprite.m_nCopyParent)
        if not owner or not EEex_GameObject_IsSprite(owner, false) then return nil end
        owner = EEex_GameObject_CastUserType(owner)
        if EEex_Sprite_GetPortraitIndex(owner) == -1 then return nil end
        return "summon:clone:" .. P.ActorKey(owner) .. ":" .. tostring(entry.cloneType or 0)
    end
    return "summon:" .. entry.identity
end

function P.CasterActor(snapshot, key)
    return (snapshot.casterActors or snapshot.actors)[key]
end

--- Group key: one ability, whoever can cast it. Items key on the resref plus
--- the F8 power index, because a multi-power item is several distinct buffs.
function P.GroupKey(row)
    if row.kind == "itm" then
        return "itm:" .. row.itemResref:upper() .. ":" .. row.abilityIdx
    end
    return "spl:" .. row.resref:upper()
end

-- ============================================================
-- Resource pools
-- ============================================================

--- Which pool a cast spends from. Sorcerers (19) and shamans (21) choose at
--- cast time, so every spell of one level shares a pool; prepared casters and
--- innates spend the specific memorized resource. 5E Spellcasting routes its
--- own wrappers and its cross-wrapper pool semantics are not verified here, so
--- those rows stay in the per-caster view.
function P.SpellPool(actor, row)
    if row.d5 then return nil, P.REASON.FIVE_E_SOURCE end
    if not integer(actor.class, 1, 21) then return nil, P.REASON.CASTER_CLASS_UNAVAILABLE end
    if (actor.class == 19 and row.spellType == 1)
        or (actor.class == 21 and row.spellType == 2) then
        return (actor.poolKey or actor.key) .. ":level:" .. row.spellType .. ":" .. row.level
    end
    return (actor.poolKey or actor.key) .. ":spell:" .. row.resref:upper()
end

--- A pool's capacity is the SMALLEST count any source reported for it, never
--- the sum: a sorcerer's level-3 pool is registered once per known level-3
--- spell, and each row reports the same remaining uses.
local function putPool(snapshot, key, count)
    count = integer(count, 0, 1000000) and count or 0
    snapshot.pools[key] = math.min(snapshot.pools[key] or count, count)
end

-- ============================================================
-- Allocation
-- ============================================================

function P.SourceAllowed(snapshot, source, request)
    if source.reason then return false, source.reason end
    if request.source and request.source ~= source.actor then
        return false, P.REASON.PREFERRED_CASTER_UNAVAILABLE
    end
    if request.target ~= "party" then
        local recipient = snapshot.actors[request.target]
        if not recipient then return false, P.REASON.RECIPIENT_UNAVAILABLE end
        if recipient.alive == false then return false, P.REASON.RECIPIENT_DEAD end
        if recipient.ambiguous then return false, P.REASON.RECIPIENT_AMBIGUOUS end
    end
    if source.selfOnly and request.target ~= source.actor then
        return false, P.REASON.SELF_ONLY
    end
    if source.aoe and request.target ~= "party" then
        return false, P.REASON.PARTY_WIDE_CAST
    end
    if not source.aoe and request.target == "party" then
        return false, P.REASON.CHOOSE_RECIPIENT
    end
    if source.variants and #source.variants > 0 then
        for _, variant in ipairs(source.variants) do
            if variant.resref == request.var then return true end
        end
        return false, P.REASON.VARIANT_UNSUPPORTED
    elseif request.var then
        return false, P.REASON.VARIANT_UNAVAILABLE
    end
    return true
end

function P.SourceDuration(source, request)
    return (request.var and source.variantDurations
        and source.variantDurations[request.var]) or source.duration or 0
end

--- Longest duration wins, then the higher caster level, then a stable key.
--- -1 means permanent, which outranks every finite duration.
function P.BetterSource(a, b, request)
    local ad, bd = P.SourceDuration(a, request), P.SourceDuration(b, request)
    if ad == -1 then ad = math.huge end
    if bd == -1 then bd = math.huge end
    if ad ~= bd then return ad > bd end
    if (a.casterLevel or 0) ~= (b.casterLevel or 0) then
        return (a.casterLevel or 0) > (b.casterLevel or 0)
    end
    return a.id < b.id
end

--- Flatten per-entry repeats into one allocation unit each, keeping a
--- back-pointer to the configured request. The panel shows one row with
--- "x3"; the allocator has to reserve three uses for it, and each use may
--- legitimately land on a different caster.
function P.ExpandRequests(requests)
    local flat = {}
    for _, request in ipairs(requests or {}) do
        local repeats = BfBot.Persist._NormalizeSpellRepeat(request.rep)
        for index = 1, repeats do
            if #flat >= P.MAX_REQUESTS then return flat, true end
            flat[#flat + 1] = {
                group = request.group, target = request.target,
                source = request.source, var = request.var,
                on = request.on, origin = request, repeatIndex = index,
            }
        end
    end
    return flat, false
end

--- Pure allocation. Every source spends one unit from exactly one pool.
--- Augmenting paths keep a scarce source free for a later request that has no
--- alternative, so an earlier recipient only loses its stronger caster when
--- moving it is the sole way to satisfy another request. Nothing here mutates
--- sources, requests or pool capacities.
function P.Assign(snapshot, requests)
    local result = { decisions = {}, used = {}, missing = 0 }
    local candidates, occupants = {}, {}

    local function move(index, visited)
        -- Always take a free source before displacing an earlier recipient.
        for _, source in ipairs(candidates[index]) do
            local pool = source.pool
            local bucket = occupants[pool] or {}
            if not visited[pool] and #bucket < (snapshot.pools[pool] or 0) then
                occupants[pool] = bucket
                bucket[#bucket + 1] = index
                result.decisions[index].source = source
                return true
            end
        end
        for _, source in ipairs(candidates[index]) do
            local pool = source.pool
            if not visited[pool] then
                visited[pool] = true
                local bucket = occupants[pool] or {}
                occupants[pool] = bucket
                if #bucket < (snapshot.pools[pool] or 0) then
                    bucket[#bucket + 1] = index
                    result.decisions[index].source = source
                    return true
                end
                -- Move the LATEST prior occupant first: earlier priorities
                -- keep the stronger source where that is still possible.
                for j = #bucket, 1, -1 do
                    if move(bucket[j], visited) then
                        bucket[j] = index
                        result.decisions[index].source = source
                        return true
                    end
                end
            end
        end
        return false
    end

    for index, request in ipairs(requests) do
        if index > P.MAX_REQUESTS then break end
        local decision = { request = request }
        result.decisions[index], candidates[index] = decision, {}
        local group = snapshot.groups[request.group]
        local reason = group and P.REASON.NO_ELIGIBLE_SOURCE or P.REASON.BUFF_UNAVAILABLE
        for _, source in ipairs(group and group.sources or {}) do
            local ok, why = P.SourceAllowed(snapshot, source, request)
            if ok then candidates[index][#candidates[index] + 1] = source
            else reason = why end
        end
        table.sort(candidates[index], function(a, b)
            return P.BetterSource(a, b, request)
        end)
        if request.on == 0 then
            decision.reason = P.REASON.DISABLED
        elseif not move(index, {}) then
            decision.reason = #candidates[index] > 0
                and P.REASON.NO_UNRESERVED_USES or reason
            result.missing = result.missing + 1
        end
    end

    for _, decision in ipairs(result.decisions) do
        if decision.source then
            decision.duration = P.SourceDuration(decision.source, decision.request)
            result.used[decision.source.pool] =
                (result.used[decision.source.pool] or 0) + 1
        end
    end
    return result
end

-- ============================================================
-- Catalog policy
-- ============================================================

--- Which scanned rows the plan offers on its own. Deliberately narrower than
--- the classifier's discovery score: offensive spells collect positive points
--- from stat changes, protections and bookkeeping states, so a raw score would
--- fill the browser with fireballs. Those rows stay reachable through the
--- per-caster view and through an explicit Add, and an explicit override or a
--- self/friendly ability always keeps the player's intent.
function P.IsAutomaticBuff(row)
    local class = row and row.class
    if not class or not class.isBuff or row.requiresChoice == 1 then return false end
    if row.kind == "itm" or class.overridden or class.isSelfOnly
        or class.friendlyFlag then return true end
    -- MSECTYPE 4/10/11 are the hostile schools; everything else passes.
    return class.msectype ~= 4 and class.msectype ~= 10 and class.msectype ~= 11
end

--- A radial self-cast ("Chant", "Protection from Evil 10'") reaches the whole
--- party from the caster's own position. An older per-caster entry recorded it
--- as a self cast on each recipient; recognizing the delivery turns it into one
--- party request on its original caster, keeping order, variant and repeats.
function P.NormalizeRadialRequests(snapshot, requests)
    for _, request in ipairs(requests or {}) do
        if request.target ~= "party"
            and (not request.source or request.source == request.target) then
            local group = snapshot.groups[request.group]
            for _, source in ipairs(group and group.sources or {}) do
                if source.actor == request.target and source.row
                    and source.row.radialParty == 1 then
                    request.source = request.source or request.target
                    request.target = "party"
                    break
                end
            end
        end
    end
end

-- ============================================================
-- Snapshot
-- ============================================================

--- Build the live catalog: who can cast, what they can cast, and how many
--- uses each resource pool still holds. Read-only with respect to the save.
function P.Snapshot()
    local snap = { actors = {}, order = {}, groups = {}, pools = {},
        casterActors = {}, casters = {} }

    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local key = P.ActorKey(sprite)
            local okClass, class = pcall(function() return sprite.m_typeAI.m_Class end)
            local actor = { key = key, name = BfBot._GetName(sprite), slot = slot,
                casterRef = { kind = "party", slot = slot },
                class = okClass and class or nil,
                alive = BfBot.Exec._IsAlive(sprite),
                controlled = not BfBot.Mp or not BfBot.Mp.IsLocallyControlled
                    or BfBot.Mp.IsLocallyControlled(sprite),
                sprite = sprite }
            -- Two party members whose only identity is a shared display name.
            -- Neither can be addressed reliably, so both are refused rather
            -- than silently buffing whichever one resolved first.
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
            local ref = { kind = "summon", oid = entry.oid, name = entry.name }
            local sprite = BfBot.Exec._ResolveCaster(ref)
            local fresh = sprite and BfBot.Scan.ClassifySummonSprite(sprite)
            local key = fresh and P.CasterKey(sprite, fresh)
            if key then
                -- A live Project Image locks its owner: skip every owner entry
                -- while the image exists (CLAUDE.md, PI lock policy).
                if fresh.kind == "clone" and fresh.cloneType == 2 then
                    local ownerKey = key:match("^summon:clone:(.*):2$")
                    if snap.actors[ownerKey] then
                        snap.actors[ownerKey].projectImageLocked = true
                    end
                end
                local actor = { key = key, name = entry.name,
                    -- Each live copy keeps its own uses, so the pool key
                    -- carries the spawn while the saved preference does not.
                    poolKey = key .. ":spawn:" .. tostring(entry.oid),
                    casterRef = ref, sprite = sprite,
                    class = sprite.m_typeAI.m_Class,
                    alive = BfBot.Exec._IsAlive(sprite),
                    controlled = not BfBot.Mp or not BfBot.Mp.IsSummonLocallyControlled
                        or BfBot.Mp.IsSummonLocallyControlled(fresh) }
                snap.casterActors[key] = actor
                snap.casters[#snap.casters + 1] = actor
            end
        end
    end

    for _, actor in ipairs(snap.casters) do
        local rows = BfBot.Scan.GetCastableSpells(actor.sprite)
        actor.rows = rows
        for _, row in pairs(rows) do
            -- Register EVERY known native spell, buff or not: a spontaneous
            -- caster's level pool must not come out as the sum of its rows.
            local pool, poolReason
            if row.kind ~= "itm" then
                pool, poolReason = P.SpellPool(actor, row)
                if pool then putPool(snap, pool, row.count) end
            end
            -- A summon's self-only buff helps nobody in the party and would
            -- occupy a plan row that cannot be retargeted.
            local summonSelf = actor.casterRef.kind == "summon"
                and row.isSelfOnly == 1 and row.isAoE ~= 1
            if not summonSelf and row.class and P.IsAutomaticBuff(row) then
                local key = P.GroupKey(row)
                local group = snap.groups[key]
                if not group then
                    group = { key = key, name = row.name, kind = row.kind,
                        icon = row.icon, sources = {} }
                    snap.groups[key] = group
                end
                local reason = actor.ambiguous and P.REASON.CASTER_AMBIGUOUS
                    or actor.projectImageLocked and P.REASON.PROJECT_IMAGE_LOCKED
                    or not actor.alive and P.REASON.CASTER_DEAD
                    or not actor.controlled and P.REASON.CASTER_NOT_CONTROLLED
                    or row.requiresChoice == 1 and P.REASON.ITEM_REQUIRES_CHOICE
                    or poolReason

                local function add(sourcePool, itemSlot, count)
                    if sourcePool then putPool(snap, sourcePool, count) end
                    local source = {
                        id = (actor.poolKey or actor.key) .. "/" .. key
                            .. "/" .. tostring(itemSlot or "spell"),
                        actor = actor.key, casterName = actor.name,
                        slot = actor.slot, casterRef = actor.casterRef,
                        lane = actor.poolKey or actor.key,
                        row = row,
                        pool = sourcePool or (actor.key .. ":unavailable"),
                        reason = reason, duration = row.duration,
                        casterLevel = row.casterLevel,
                        selfOnly = row.isSelfOnly == 1, aoe = row.isAoE == 1,
                        variants = row.variants, variantDurations = {},
                        itemSlot = itemSlot }
                    -- The row says it has variants but the scan could not read
                    -- them: refuse rather than cast the opcode-214 wrapper.
                    if row.hasVariants == 1
                        and (not row.variants or #row.variants == 0) then
                        source.reason = P.REASON.VARIANT_METADATA_MISSING
                    end
                    if row.kind == "itm"
                        and BfBot.Persist.GetPref("ItemUseMode") == "swap"
                        and itemSlot and itemSlot >= 18 and itemSlot <= 33
                        and row.itemType ~= 9 then
                        if actor.casterRef.kind == "summon" then
                            source.reason = P.REASON.SUMMON_ITEM_NOT_EQUIPPED
                        else
                            local copy = {}
                            for k, v in pairs(row) do copy[k] = v end
                            copy.itemSlot = itemSlot
                            local swap, why = BfBot.Scan._PlanItemSwap(actor.sprite, copy)
                            if not swap then source.reason = why end
                        end
                    end
                    -- A variant's duration is its own, not the wrapper's (#82).
                    for _, variant in ipairs(row.variants or {}) do
                        local ok, duration = pcall(function()
                            local header = EEex_Resource_Demand(variant.resref, "SPL")
                            local ability = header
                                and header:getAbilityForLevel(row.casterLevel or 1)
                            if not ability then return 0 end
                            return BfBot.Class.GetDuration(header, ability,
                                nil, nil, nil, row.casterLevel)
                        end)
                        source.variantDurations[variant.resref] = ok and duration or 0
                    end
                    group.sources[#group.sources + 1] = source
                end

                if row.kind == "itm" then
                    -- One source per inventory slot holding the item: each
                    -- copy carries its own charges.
                    for _, item in ipairs(row.sources or {}) do
                        local counter = row.abilityIdx < 3 and row.abilityIdx or 0
                        local itemPool = actor.key .. ":item:" .. item.slot .. ":"
                            .. row.itemResref:upper() .. ":" .. counter
                        add(itemPool, item.slot, item.count)
                    end
                else
                    add(pool, nil, row.count)
                end
            end
        end
    end

    -- Item lending between party members (BfBotShr, step 4 of issue #81).
    if BfBot.Share then BfBot.Share.AddSources(snap) end
    return snap
end

-- ============================================================
-- Migration from the per-caster presets
-- ============================================================

--- Turn one per-character preset index into party-wide requests, preserving
--- the caster lock, the variant, the repeats and the per-caster priority. The
--- original presets are left untouched: this reads, it does not consume.
--- Returns nil plus a reason when a configured spell or recipient is gone,
--- because a silently shortened plan is worse than a refused one.
function P.ImportLegacy(snapshot, index)
    local entries = {}
    for _, actor in ipairs(snapshot.order) do
        local config = BfBot.Persist.GetConfig(actor.sprite)
        local preset = config and config.presets and config.presets[index]
        for resource, cfg in pairs(preset and preset.spells or {}) do
            local row = actor.rows[resource]
            if cfg.on == 1 and not row then
                return nil, P.REASON.LEGACY_SOURCE_GONE, resource
            end
            if cfg.on == 1 and row then
                entries[#entries + 1] = { actor = actor, row = row, cfg = cfg,
                    key = P.GroupKey(row), resource = resource }
            end
        end
    end
    -- `pairs` over a spell table has no order, so sort by the player's own
    -- priority and break ties on a stable key: the same config must always
    -- migrate to the same plan.
    table.sort(entries, function(a, b)
        if (a.cfg.pri or 999) ~= (b.cfg.pri or 999) then
            return (a.cfg.pri or 999) < (b.cfg.pri or 999)
        end
        return a.actor.key .. a.resource < b.actor.key .. b.resource
    end)

    local requests = {}
    for _, entry in ipairs(entries) do
        local targets = BfBot.Persist._ResolveConfigTarget(entry.cfg.tgt,
            entry.actor.slot, entry.resource, entry.cfg.pri or 999)
        if #targets == 0 then
            return nil, P.REASON.LEGACY_RECIPIENT_GONE, entry.resource
        end
        for _, resolved in ipairs(targets) do
            local keys = {}
            if resolved.target == "self" then
                keys[1] = entry.row.radialParty == 1 and "party" or entry.actor.key
            elseif resolved.target == "all" then
                if entry.row.isAoE == 1 then keys[1] = "party"
                else
                    for _, a in ipairs(snapshot.order) do keys[#keys + 1] = a.key end
                end
            elseif type(resolved.target) == "number" then
                -- _ResolveConfigTarget returns Player 1-6; actors carry 0-5.
                for _, a in ipairs(snapshot.order) do
                    if a.slot == resolved.target - 1 then keys[1] = a.key end
                end
            end
            for _, target in ipairs(keys) do
                if #requests >= P.MAX_REQUESTS then
                    return nil, P.REASON.PLAN_TOO_LARGE
                end
                requests[#requests + 1] = { group = entry.key, target = target,
                    source = entry.actor.key, var = entry.cfg.var,
                    on = 1, rep = BfBot.Persist._NormalizeSpellRepeat(entry.cfg.rep),
                    lock = entry.cfg.lock, tgtUnlock = entry.cfg.tgtUnlock,
                    manual = #requests + 1 }
            end
        end
    end
    return requests
end

-- ============================================================
-- Queue building
-- ============================================================

--- Turn an allocated plan into entries for `BfBot.Exec._BuildQueue`, which
--- keeps every existing guard (MP ownership, live re-resolution, skip
--- detection). Refuses a partial plan: if a request has no caster, the player
--- sees why instead of a run that quietly drops casts.
function P.BuildQueue(snapshot, requests)
    local flat, overflow = P.ExpandRequests(requests)
    if overflow then return nil, nil, P.REASON.PLAN_TOO_LARGE end

    local plan = P.Assign(snapshot, flat)
    if plan.missing > 0 then return nil, plan end

    local queue = {}
    for _, decision in ipairs(plan.decisions) do
        local source, request = decision.source, decision.request
        if source then
            local target = request.target == "party" and "all"
                or (snapshot.actors[request.target].slot + 1)
            queue[#queue + 1] = {
                casterRef = source.casterRef,
                caster = source.slot,
                spell = source.row.resref,
                target = source.selfOnly and "self" or target,
                var = request.var,
                -- Repeats are already flattened into separate entries, so each
                -- queue entry is exactly one cast.
                rep = 1,
                plannedActor = source.actor,
                plannedTarget = request.target,
                plannedItemSlot = source.itemSlot,
                isProjectImage = source.row.isProjectImage,
            }
        end
    end
    if #queue == 0 then return nil, plan end

    -- The executor's Project Image policy is the authority on owner locks.
    -- A locked owner means the plan cannot run as written.
    if BfBot.Persist._ApplyPuppetLockPolicy then
        local clones = BfBot.Persist._CollectLiveCloneDescriptors()
        for _, actor in ipairs(snapshot.casters) do
            local entries = {}
            for _, entry in ipairs(queue) do
                if entry.plannedActor == actor.key then
                    entries[#entries + 1] = entry
                end
            end
            if #entries > 0 then
                local _, skips = BfBot.Persist._ApplyPuppetLockPolicy(
                    { oid = actor.sprite.m_id, name = actor.name }, entries, clones)
                if skips and #skips > 0 then
                    return nil, plan, P.REASON.PROJECT_IMAGE_LOCKED
                end
            end
        end
    end
    return queue, plan
end
