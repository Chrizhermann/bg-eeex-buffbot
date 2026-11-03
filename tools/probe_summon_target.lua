-- #117's engine questions: can a BuffBot cast be aimed at a summon?
--
-- BuffBot queues BCS action strings, and BCS can name `Myself` and `PlayerN`
-- but not an arbitrary creature. EEex adds scripting object 117,
-- `EEex_Target("key")`, which resolves at action-evaluation time by reading
-- `EEex_GetUDAux(caller)["EEex_Target"][key]` and mapping that object id
-- through `EEex_GameObject_Get`. That is the candidate mechanism. Three
-- things about it decide the design, and none can be settled offline:
--
--   Q1 land      does a single-target buff queued at `EEex_Target` actually
--                reach an allied summon, or does the spell's own target type
--                refuse a non-party creature?
--   Q2 gone      the stored target dies between queue and resolve (ordinary
--                summon churn). Does the caster's queue still advance, or
--                does it stall the way the multiplayer "stuck on casting"
--                bug did? A stall would need a liveness check plus a
--                watchdog; a clean skip would not.
--   Q3 two keys  two stored keys, two different targets, two queued casts.
--                Does each land on its own? That decides whether one key per
--                caster is enough or the key must carry the step.
--
-- Plain reads only in loops. The #113 probe hung the game by compiling
-- eighteen BCS conditionals inside one console poll frame; a cast is queued
-- deliberately, a script is never compiled per sprite.
--
-- Every verdict is read back from the recipient's own effect list. "Queued
-- successfully" proves nothing -- that mistake is why the #113 probe reported
-- a verdict about improved invisibility while the sprite was only plainly
-- invisible.

local S = {
    caster = nil,       -- portrait slot of the member who casts the buff
    conjurer = nil,     -- portrait slot of the member who makes the clone
    buff = nil,         -- resref of the single-target buff
    cloneSpell = nil,   -- resref of the Simulacrum / Project Image spell
    cloneKind = nil,    -- 2 = Project Image, 3 = Simulacrum
    clone = nil,        -- {oid=, name=} of the conjured summon
    trials = {},
    marker = {},        -- which Lua marker actions have run
}

local KEY = "BfBotProbe117"
local KEY_A = "BfBotProbe117A"
local KEY_B = "BfBotProbe117B"

-- The marker action proves the queue advanced past the cast. Queued as
-- EEex_LuaAction immediately after it, so it runs only once the cast action
-- has finished -- or never, if the cast blocks forever.
function BfBotProbe117_Mark(tag)
    S.marker[tag] = (S.marker[tag] or 0) + 1
end

local function _sprite(slot)
    local ok, sprite = pcall(EEex_Sprite_GetInPortrait, slot)
    if not ok then return nil end
    return sprite
end

local function _name(sprite)
    local ok, value = pcall(function() return BfBot._GetName(sprite) end)
    if ok and value and value ~= "" then return tostring(value) end
    local okRaw, raw = pcall(function() return sprite:getName() end)
    return okRaw and tostring(raw) or "?"
end

--- How many effects on `sprite` name `resref` as their source.
local function _countFrom(sprite, resref)
    local want, found = resref:upper(), 0
    local ok = pcall(function()
        EEex_Utility_IterateCPtrList(sprite.m_timedEffectList, function(effect)
            local okRes, res = pcall(function()
                return effect.m_sourceRes:get()
            end)
            if okRes and res and res:upper() == want then found = found + 1 end
        end)
    end)
    if not ok then return nil end
    return found
end

local function _playerRef(sprite)
    local ok, index = pcall(EEex_Sprite_GetCharacterIndex, sprite)
    if not ok or not index then return nil end
    return "Player" .. tostring(index + 1)
end

local function _alive(sprite)
    local ok, value = pcall(BfBot.Exec._IsAlive, sprite)
    return ok and value or false
end

--- Report the pause state, and unpause when asked.
---
--- This is why the second run of this probe measured nothing: a loaded save
--- comes up PAUSED, and `SpellRES` needs casting time to elapse. It held the
--- action slot forever while `ReallyForceSpellRES`, which resolves at once,
--- worked fine -- so every `SpellRES` trial looked like a targeting failure.
function BfBotProbe117_Pause(unpause)
    local okRead, paused = pcall(function()
        return worldScreen:CheckIfPaused()
    end)
    if not okRead then return "pause unreadable: " .. tostring(paused) end
    if unpause and paused then
        local okTog, err = pcall(EEex_GameState_TogglePause, false, true,
            false, 0, true)
        if not okTog then return "unpause failed: " .. tostring(err) end
        local okAgain, now = pcall(function()
            return worldScreen:CheckIfPaused()
        end)
        return string.format("was paused; now paused=%s",
            okAgain and tostring(now) or "ERR")
    end
    return "paused=" .. tostring(paused)
end

--- Clear whatever the buff caster is doing.
---
--- The second run's `SpellRES` control jammed the caster, and every later
--- trial then measured that jam rather than its own question -- all four
--- reported action 31 while nothing of theirs ran. A trial that cannot start
--- clean is not a trial.
function BfBotProbe117_Clear()
    local caster = _sprite(S.caster)
    if not caster then return "no buff caster" end
    local ok, err = pcall(function()
        caster:virtual_ClearActions(false)
    end)
    if not ok then return "clear failed: " .. tostring(err) end
    local okRead, id = pcall(function() return caster.m_curAction.m_actionID end)
    return "cleared; action now " .. (okRead and tostring(id) or "ERR")
end

function BfBotProbe117_Party()
    local lines = {}
    for slot = 0, 5 do
        local sprite = _sprite(slot)
        if sprite then
            local okEa, ea = pcall(function()
                return sprite.m_typeAI.m_EnemyAlly
            end)
            lines[#lines + 1] = string.format(
                "slot=%d name=%s player=%s ea=%s alive=%s",
                slot, _name(sprite), tostring(_playerRef(sprite)),
                okEa and tostring(ea) or "ERR", tostring(_alive(sprite)))
        end
    end
    return table.concat(lines, "\n")
end

--- Why a scan row cannot serve as this probe's buff, or nil when it can.
---
--- A self-only spell can never test a foreign target, and an area spell
--- would land on the summon by position rather than by the mechanism under
--- test -- which would answer the wrong question.
--- `count` is the memorized count, filled in by the scan's count overlay.
--- The first run of this probe ignored it and picked `SPPR107`, which that
--- cleric KNOWS but had not memorized -- so `SpellRES` held the action slot
--- for fifteen seconds and all three trials reported nothing, which looked
--- exactly like the mechanism failing. A spell with no memorized use cannot
--- be cast through the ordinary path at all.
local function _rejectedBuff(row, resref)
    if not resref or resref == "" then return "no resref" end
    if row.kind == "itm" then return "item" end
    if row.isAoE == 1 then return "area" end
    if row.isSelfOnly == 1 then return "self only" end
    if row.variants and #row.variants > 0 then return "has variants" end
    -- Two is the floor, not a preference: only the two `SpellRES` trials
    -- spend a slot, because `ReallyForceSpellRES` needs none.
    if (tonumber(row.count) or 0) < 2 then return "fewer than 2 memorized" end
    return nil
end

--- Pick the member who will cast the buff and the spell they will cast.
---
--- Walks the real scan rather than naming a resref, so the probe says what
--- this save actually offered instead of depending on a fixture.
--- Takes the BEST-stocked candidate rather than the first match: this probe
--- fires up to seven casts, and the first acceptable row on a thin save can
--- have exactly the two uses it needs, leaving nothing if a trial is
--- repeated. Every rejection is counted, because "no spell to cast" is not a
--- finding -- it is a probe that did not run.
function BfBotProbe117_PickBuff(avoidSlot)
    local reasons, best = {}, nil
    for slot = 0, 5 do
        if slot ~= avoidSlot then
            local sprite = _sprite(slot)
            if sprite and _alive(sprite) then
                local ok, rows = pcall(BfBot.Scan.GetCastableSpells, sprite)
                if ok and rows then
                    for resref, row in pairs(rows) do
                        local why = _rejectedBuff(row, resref)
                        if not why then
                            local uses = tonumber(row.count) or 0
                            if not best or uses > best.uses then
                                best = { slot = slot, resref = resref,
                                         uses = uses, row = row,
                                         name = _name(sprite) }
                            end
                        else
                            reasons[why] = (reasons[why] or 0) + 1
                        end
                    end
                end
            end
        end
    end
    if best then
        S.caster, S.buff = best.slot, best.resref
        return string.format("caster=%d name=%s buff=%s (%s) memorized=%d",
            best.slot, best.name, best.resref, tostring(best.row.name),
            best.uses)
    end
    local parts = {}
    for why, n in pairs(reasons) do parts[#parts + 1] = why .. "x" .. n end
    table.sort(parts)
    return "no single-target buff found: " .. table.concat(parts, ", ")
end

--- Find the spell that makes a clone, using the prediction's own classifier
--- rather than a hardcoded resref.
--- A Simulacrum is preferred over a Project Image, and not as a detail: an
--- image PUPPET-LOCKS its owner, and the fourth run of this probe aimed its
--- control at that owner moments after casting one. The `SpellRES` jammed
--- the caster for good -- `virtual_ClearActions(false)` would not clear it --
--- and every later trial measured the jam instead of its own question.
function BfBotProbe117_PickClone()
    local found = {}
    for slot = 0, 5 do
        local sprite = _sprite(slot)
        if sprite and _alive(sprite) then
            local ok, rows = pcall(BfBot.Scan.GetCastableSpells, sprite)
            if ok and rows then
                for resref, row in pairs(rows) do
                    for _, d in ipairs(BfBot.Summon.Creators(row)) do
                        if d.kind == "clone"
                                and (tonumber(row.count) or 0) > 0 then
                            found[#found + 1] = {
                                slot = slot, resref = resref,
                                image = d.image, name = _name(sprite),
                                uses = tonumber(row.count) or 0,
                            }
                        end
                    end
                end
            end
        end
    end
    if #found == 0 then
        return "no clone-creating spell with a memorized use in this party"
    end
    table.sort(found, function(a, b)
        -- image 3 is a Simulacrum, which freezes nobody; 2 is a Project
        -- Image, whose owner becomes unusable as a target.
        if a.image ~= b.image then return a.image > b.image end
        return a.uses > b.uses
    end)
    local pick = found[1]
    S.conjurer, S.cloneSpell, S.cloneKind = pick.slot, pick.resref, pick.image
    local others = {}
    for _, f in ipairs(found) do
        others[#others + 1] = string.format("%s(image=%s,slot=%d,uses=%d)",
            f.resref, tostring(f.image), f.slot, f.uses)
    end
    return string.format("conjurer=%d name=%s spell=%s image=%s  from: %s",
        pick.slot, pick.name, pick.resref, tostring(pick.image),
        table.concat(others, " "))
end

--- What can be read about the conjurer after the clone exists. A Project
--- Image's owner is puppet-locked; #107 still asks whether such an owner can
--- RECEIVE a cast, and this run has the answer by accident: it cannot --
--- the cast jams the caster. Reported rather than buried in a probe defect.
function BfBotProbe117_Conjurer()
    local sprite = _sprite(S.conjurer)
    if not sprite then return "no conjurer sprite" end
    local okStat, puppet = pcall(EEex_Sprite_GetStat, sprite, 139)
    local okState, state = pcall(EEex_Sprite_GetState, sprite)
    return string.format(
        "conjurer slot=%d name=%s image=%s stat139=%s state=%s",
        S.conjurer, _name(sprite), tostring(S.cloneKind),
        okStat and tostring(puppet) or "ERR",
        okState and string.format("0x%08X", state or 0) or "ERR")
end

--- Queue the clone cast. ReallyForceSpellRES so the probe does not have to
--- wait out casting time and aura for its instrument; the spell under test
--- in Q1 uses the ordinary path BuffBot uses.
function BfBotProbe117_Conjure()
    local sprite = _sprite(S.conjurer)
    if not sprite then return "no conjurer sprite" end
    if not S.cloneSpell then return "no clone spell picked" end
    local action = string.format('ReallyForceSpellRES("%s",Myself)',
        S.cloneSpell)
    local ok, err = pcall(EEex_Action_QueueResponseStringOnAIBase, action,
        sprite)
    if not ok then return "queue failed: " .. tostring(err) end
    return "queued " .. action
end

--- Which allied summons BuffBot can see now, through its own discovery --
--- so a found clone is one the feature would really offer as a recipient.
function BfBotProbe117_Summons()
    local ok, list = pcall(BfBot.Scan.GetAlliedSummons)
    if not ok then return "GetAlliedSummons failed: " .. tostring(list) end
    if not list or #list == 0 then return "no allied summons" end
    local lines = {}
    for _, e in ipairs(list) do
        lines[#lines + 1] = string.format("oid=%s name=%s identity=%s",
            tostring(e.oid), tostring(e.name), tostring(e.identity))
        if not S.clone then S.clone = { oid = e.oid, name = e.name } end
    end
    return table.concat(lines, "\n")
end

--- Resolve the clone the way exec does: by object id plus name, never
--- through build-time userdata.
local function _cloneSprite()
    if not S.clone then return nil, "no clone recorded" end
    local ok, sprite = pcall(BfBot.Exec._ResolveCaster, {
        kind = "summon", oid = S.clone.oid, name = S.clone.name })
    if not ok then return nil, "resolve failed: " .. tostring(sprite) end
    if not sprite then return nil, "the clone is gone" end
    return sprite, nil
end

--- Party members this probe may aim at: not the caster, and NEVER the
--- conjurer. A Project Image's owner is puppet-locked, and a cast at one
--- jams the caster permanently rather than failing -- which is how the
--- fourth run of this probe lost every trial after its first control.
local function _freeMembers()
    local out = {}
    for slot = 0, 5 do
        if slot ~= S.caster and slot ~= S.conjurer then
            local sprite = _sprite(slot)
            if sprite and _alive(sprite) then out[#out + 1] = sprite end
        end
    end
    return out
end

local function _freeMember(_)
    local free = _freeMembers()
    return free[1]
end

local function _actionSummary(t)
    local seen, order = {}, {}
    for _, id in ipairs(t.actions or {}) do
        if not seen[id] then order[#order + 1] = id end
        seen[id] = (seen[id] or 0) + 1
    end
    local out = {}
    for _, id in ipairs(order) do out[#out + 1] = id .. "x" .. seen[id] end
    return table.concat(out, ",")
end

--- Q0: the control. The same spell at an ordinary `PlayerN`, once through
--- each action the probe uses. Without this, "nothing happened" cannot be
--- told apart from "this caster cannot cast this spell", which is exactly
--- the hole the first run fell into.
---
--- @param action string: "SpellRES" or "ReallyForceSpellRES"
function BfBotProbe117_Control(action)
    local caster = _sprite(S.caster)
    if not caster then return "no buff caster" end
    local target = _freeMember(nil)
    if not target then return "no party member to aim the control at" end
    local ref = _playerRef(target)
    if not ref then return "no PlayerN for the control target" end

    local trial = "control-" .. action
    S.trials[trial] = {
        actions = {}, before = _countFrom(target, S.buff),
        spriteA = target, name = _name(target),
    }
    local cast = string.format('%s("%s",%s)', action, S.buff, ref)
    local mark = string.format(
        'EEex_LuaAction("BfBotProbe117_Mark([[%s]])")', trial)
    local ok, err = pcall(EEex_Action_QueueResponseStringOnAIBase,
        cast .. "\n" .. mark, caster)
    if not ok then return "queue failed: " .. tostring(err) end
    return string.format("queued %s at %s  before=%s", cast,
        S.trials[trial].name, tostring(S.trials[trial].before))
end

function BfBotProbe117_ResultControl(action)
    local trial = "control-" .. action
    local t = S.trials[trial]
    if not t then return "no " .. trial .. " trial" end
    local after = t.spriteA and _countFrom(t.spriteA, S.buff) or nil
    local verdict = "NO VERDICT"
    if t.before ~= nil and after ~= nil then
        verdict = (after > t.before) and "LANDED" or "did NOT land"
    end
    return string.format(
        "Q0 %-20s %-20s (%s -> %s from %s at %s)  actions=%s  marker=%s",
        action, verdict, tostring(t.before), tostring(after),
        tostring(S.buff), t.name, _actionSummary(t),
        tostring(S.marker[trial] or 0))
end

--- What the engine actually compiled. The knowledge base's own advice for a
--- consequential diagnostic: inspect the compiled action list rather than
--- trusting that a queue call parsed what you wrote. This says whether
--- `EEex_Target` reached the action as OBJECT.IDS 117 at all.
function BfBotProbe117_Compiled()
    local cast = string.format('SpellRES("%s",EEex_Target("%s"))',
        S.buff or "SPPR107", KEY)
    local ok, script = pcall(EEex_Action_ParseResponseString, cast)
    if not ok or not script then
        return "parse failed: " .. tostring(script)
    end
    local lines = {}
    local okWalk, err = pcall(function()
        local response = script.m_curResponse
        EEex_Utility_IterateCPtrList(response.m_actionList, function(act)
            local id = act.m_actionID
            local okObj, objIds = pcall(function()
                local out = {}
                for i = 0, 4 do
                    out[#out + 1] = tostring(
                        act.m_target.m_SpecialCase:get(i))
                end
                return table.concat(out, "/")
            end)
            lines[#lines + 1] = string.format(
                "action=%s target.SpecialCase=%s string1=%s",
                tostring(id), okObj and objIds or "ERR",
                tostring(act.m_string1.m_pchData:get()))
        end)
    end)
    pcall(function() script:free() end)
    if not okWalk then return "walk failed: " .. tostring(err) end
    if #lines == 0 then return "the response compiled to NO actions" end
    return table.concat(lines, "\n")
end

--- Q1: store the clone and queue the buff at `EEex_Target(KEY)`.
---
--- @param action string: "SpellRES" (the path BuffBot uses) or
---        "ReallyForceSpellRES" (no slot, no casting time, no aura -- so a
---        negative result is about the target, not about the spell).
function BfBotProbe117_CastAtClone(action)
    action = action or "SpellRES"
    local caster = _sprite(S.caster)
    if not caster then return "no buff caster" end
    local target, why = _cloneSprite()
    if not target then return why end

    local okStore, errStore = pcall(EEex_AIBase_SetStoredScriptingTarget,
        caster, KEY, target)
    if not okStore then return "store failed: " .. tostring(errStore) end

    -- Read the store back: a silent no-op here would make every later
    -- verdict meaningless.
    local okRead, stored = pcall(EEex_AIBase_GetStoredScriptingTarget,
        caster, KEY)
    local storedOk = okRead and stored ~= nil

    local trial = "land-" .. action
    S.trials[trial] = {
        before = _countFrom(target, S.buff),
        actions = {},
        storedOk = storedOk,
    }
    local cast = string.format('%s("%s",EEex_Target("%s"))',
        action, S.buff, KEY)
    local mark = string.format(
        'EEex_LuaAction("BfBotProbe117_Mark([[%s]])")', trial)
    local ok, err = pcall(EEex_Action_QueueResponseStringOnAIBase,
        cast .. "\n" .. mark, caster)
    if not ok then return "queue failed: " .. tostring(err) end
    return string.format("queued %s  stored=%s before=%s",
        cast, tostring(storedOk), tostring(S.trials[trial].before))
end

--- Sample the caster's action slot, so a dropped action is distinguishable
--- from a blocked effect.
function BfBotProbe117_Sample(trial)
    local t = S.trials[trial]
    local caster = _sprite(S.caster)
    if not t or not caster then return "no trial or caster" end
    local ok, id = pcall(function() return caster.m_curAction.m_actionID end)
    local value = ok and tostring(id) or "ERR"
    t.actions[#t.actions + 1] = value
    return value
end

function BfBotProbe117_ResultLand(action)
    action = action or "SpellRES"
    local trial = "land-" .. action
    local t = S.trials[trial]
    if not t then return "no " .. trial .. " trial" end
    local target, why = _cloneSprite()
    local after = target and _countFrom(target, S.buff) or nil
    local verdict = "NO VERDICT"
    if not t.storedOk then
        verdict = "NO VERDICT (the store did not read back)"
    elseif target == nil then
        verdict = "NO VERDICT (" .. tostring(why) .. ")"
    elseif t.before ~= nil and after ~= nil then
        verdict = (after > t.before) and "LANDED" or "did NOT land"
    end
    return string.format(
        "Q1 %-20s %-20s (%s -> %s from %s at the clone)  actions=%s  marker=%s",
        action, verdict, tostring(t.before), tostring(after),
        tostring(S.buff), _actionSummary(t), tostring(S.marker[trial] or 0))
end

--- Q2: `EEex_Target` resolves to nobody when the action runs. Does the
--- caster's queue still advance past the cast?
---
--- The key is cleared after queuing rather than the creature destroyed.
--- EEex's object hook takes the SAME branch either way: `setInstance(nil)`
--- (because `EEex_GameObject_Get` answers nil for a dead id, and because a
--- cleared key answers nil) falls into `fail()`, which sets the decoding
--- object to `CAIObjectType.NOONE`. So this measures exactly what an expired
--- summon does, with nothing to kill and no dependence on a duration.
---
--- What it cannot show: whether the engine reaches that branch at all for a
--- dead id. That is a source read (`EEex_Object.lua`), stated as such.
function BfBotProbe117_CastAtGone()
    local caster = _sprite(S.caster)
    if not caster then return "no buff caster" end
    local target, why = _cloneSprite()
    if not target then return "cannot set up: " .. tostring(why) end

    local okStore = pcall(EEex_AIBase_SetStoredScriptingTarget, caster, KEY,
        target)
    if not okStore then return "store failed" end

    S.trials.gone = { actions = {}, cleared = false,
                      before = _countFrom(target, S.buff) }
    local action = string.format(
        'ReallyForceSpellRES("%s",EEex_Target("%s"))', S.buff, KEY)
    local mark = 'EEex_LuaAction("BfBotProbe117_Mark([[gone]])")'
    local ok, err = pcall(EEex_Action_QueueResponseStringOnAIBase,
        action .. "\n" .. mark, caster)
    if not ok then return "queue failed: " .. tostring(err) end

    -- Clear it in the same frame the cast was queued, so the action cannot
    -- have resolved against the live target first.
    local okClear = pcall(EEex_AIBase_SetStoredScriptingTarget, caster, KEY,
        nil)
    local okRead, stored = pcall(EEex_AIBase_GetStoredScriptingTarget,
        caster, KEY)
    S.trials.gone.cleared = okClear and okRead and stored == nil
    S.trials.gone.spriteA = target
    return string.format("queued %s then cleared the key (cleared=%s)",
        action, tostring(S.trials.gone.cleared))
end

function BfBotProbe117_ResultGone()
    local t = S.trials.gone
    if not t then return "no gone trial" end
    local verdict
    local after = t.spriteA and _countFrom(t.spriteA, S.buff) or nil
    if not t.cleared then
        verdict = "NO VERDICT (the key did not clear)"
    elseif (S.marker.gone or 0) > 0 then
        verdict = "the queue ADVANCED"
    else
        verdict = "the queue did NOT advance"
    end
    return string.format(
        "Q2 nobody    %-34s actions=%s  marker=%s  target %s->%s effects",
        verdict, _actionSummary(t), tostring(S.marker.gone or 0),
        tostring(t.before), tostring(after))
end

--- Q3: two keys, two targets, one caster. Does each cast land on its own?
---
--- The second target is a party member, so this needs no second summon. If
--- each lands where its key points, one key per caster is enough while a
--- single shared key would have collided -- which is the whole question.
function BfBotProbe117_CastTwoKeys()
    local caster = _sprite(S.caster)
    if not caster then return "no buff caster" end

    local free = _freeMembers()
    if #free < 1 then return "no second party member to aim at" end
    local other = free[1]

    local target, why = _cloneSprite()
    if not target then
        -- Without a live clone the two keys can still be two party members,
        -- which answers the addressing question just as well.
        if #free < 2 then
            return "NO VERDICT (no clone and no third member): "
                .. tostring(why)
        end
        target = free[2]
    end

    local okA = pcall(EEex_AIBase_SetStoredScriptingTarget, caster, KEY_A,
        target)
    local okB = pcall(EEex_AIBase_SetStoredScriptingTarget, caster, KEY_B,
        other)
    if not (okA and okB) then return "a store failed" end

    S.trials.keys = {
        actions = {},
        beforeA = _countFrom(target, S.buff),
        beforeB = _countFrom(other, S.buff),
        nameA = _name(target),
        nameB = _name(other),
        refA = { oid = nil, name = _name(target) },
    }
    -- Keep a way back to each sprite that does not hold userdata across the
    -- wait: both are re-read by name in the result.
    S.trials.keys.spriteA, S.trials.keys.spriteB = target, other

    local actionA = string.format(
        'ReallyForceSpellRES("%s",EEex_Target("%s"))', S.buff, KEY_A)
    local actionB = string.format(
        'ReallyForceSpellRES("%s",EEex_Target("%s"))', S.buff, KEY_B)
    local mark = 'EEex_LuaAction("BfBotProbe117_Mark([[keys]])")'
    local ok, err = pcall(EEex_Action_QueueResponseStringOnAIBase,
        actionA .. "\n" .. actionB .. "\n" .. mark, caster)
    if not ok then return "queue failed: " .. tostring(err) end
    return string.format("queued both: A=%s (%s) B=%s (%s)",
        S.trials.keys.nameA, tostring(S.trials.keys.beforeA),
        S.trials.keys.nameB, tostring(S.trials.keys.beforeB))
end

function BfBotProbe117_ResultTwoKeys()
    local t = S.trials.keys
    if not t then return "no two-key trial" end
    local afterA = t.spriteA and _countFrom(t.spriteA, S.buff) or nil
    local afterB = t.spriteB and _countFrom(t.spriteB, S.buff) or nil
    local function moved(before, after)
        if before == nil or after == nil then return "?" end
        return (after > before) and "yes" or "no"
    end
    local a, b = moved(t.beforeA, afterA), moved(t.beforeB, afterB)
    local verdict = "NO VERDICT"
    if a == "yes" and b == "yes" then
        verdict = "both keys hit their own target"
    elseif a == "yes" or b == "yes" then
        verdict = "only one of the two landed"
    elseif a == "no" and b == "no" then
        verdict = "neither landed"
    end
    return string.format(
        "Q3 two keys  %-34s A=%s %s->%s  B=%s %s->%s  marker=%s",
        verdict, t.nameA, tostring(t.beforeA), tostring(afterA),
        t.nameB, tostring(t.beforeB), tostring(afterB),
        tostring(S.marker.keys or 0))
end

--- Is the stored target written into the save? EEex's marshal handler copies
--- only `EEex_SummonerUUID` out of UDAux, so the expectation is no -- but a
--- stored object id reaching a save would be a real problem, so the probe
--- states what it can see rather than trusting the source read.
function BfBotProbe117_StoreShape()
    local caster = _sprite(S.caster)
    if not caster then return "no caster" end
    local okAux, aux = pcall(EEex_GetUDAux, caster)
    if not okAux or type(aux) ~= "table" then
        return "UDAux unreadable: " .. tostring(aux)
    end
    local keys = {}
    for k in pairs(aux) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local target = aux["EEex_Target"]
    local stored = {}
    if type(target) == "table" then
        for k, v in pairs(target) do
            stored[#stored + 1] = tostring(k) .. "=" .. tostring(v)
        end
        table.sort(stored)
    end
    return string.format("UDAux keys: %s\nEEex_Target: %s",
        table.concat(keys, ", "), table.concat(stored, ", "))
end


--- Does the target picker actually offer the summon? (#117)
---
--- The screenshot cannot show this: planning a clone does not put one on the
--- field, and the lab save has none standing. So the check is the picker's
--- own row list, read after a real conjure.
function BfBotProbe117_Picker()
    local sprite = _sprite(S.caster)
    if not sprite then return "no caster" end
    -- The panel's own entry points, as the screenshot tool uses them:
    -- `SetChar` then `Toggle`. There is no `Open`.
    local okOpen, err = pcall(function()
        BfBot.UI.SetChar(S.caster)
        BfBot.UI.SetPreset(1)
        BfBot.UI.Toggle()
    end)
    if not okOpen then return "panel would not open: " .. tostring(err) end

    -- Any row whose targeting is not locked: a self-only row disables every
    -- control, which would make an empty answer meaningless.
    local row, name = nil, nil
    for index, entry in ipairs(buffbot_spellTable or {}) do
        if entry.isSelfOnly ~= 1 and entry.isAoE ~= 1 then
            row, name = index, entry.name or entry.resref
            break
        end
    end
    if not row then return "no unlocked spell row on this caster" end

    local okTargets, errTargets = pcall(BfBot.UI.OpenTargets, row)
    if not okTargets then
        return "OpenTargets failed: " .. tostring(errTargets)
    end

    local lines = { string.format("row %d (%s), %d picker rows:",
        row, tostring(name), #buffbot_pickerOrder) }
    for index, value in ipairs(buffbot_pickerOrder) do
        lines[#lines + 1] = string.format("  %d  %-28s -> %s%s",
            index, tostring(value), BfBot.UI._PickerLabel(value),
            BfBot.UI._PickerRowIsSummon(index) == 1 and "   [summon]" or "")
    end
    return table.concat(lines, "\n")
end

return "ready"
