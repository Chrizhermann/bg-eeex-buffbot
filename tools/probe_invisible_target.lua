-- tools/probe_invisible_target.lua — can a BuffBot cast still reach a
-- recipient who has been made invisible? (issue #113)
--
-- The question offline tests cannot answer. BuffBot does not click a target:
-- it queues `ReallyForceSpellRES(res, PlayerN)`. Whether the engine's
-- targeting restriction applies to a *scripted force-cast* at all, and which
-- state imposes it, decides whether #113's ordering rule is correctness work
-- or a rule for a problem that does not exist.
--
-- Three states plus a control, and each gets its OWN recipient rather than
-- one recipient cleaned between trials: removing an applied effect by resref
-- has semantics this probe would then also be testing, and an accumulated
-- state would confound the next trial. Independent recipients need no removal.
--
--   visible    -- the control. If this does not land, nothing else means
--                 anything.
--   invisible  -- opcode 20, parameter 2 = 0 (STATE_INVISIBLE). Hides from
--                 enemies; a player can still click their own character.
--   improved   -- opcode 20, parameter 2 = 1 (STATE_IMPROVEDINVISIBILITY).
--                 The state that is held to refuse single-target spells.
--   sanctuary  -- opcode 153, a separate opcode and its own SPLSTATE (20).
--
-- Detection counts the effects on the recipient whose source is the cast
-- spell, before and after: an increase means it landed, whatever the
-- recipient already carried. The caster's `m_curAction.m_actionID` is sampled
-- while the cast runs, because "the action never ran" and "it ran and the
-- effect was blocked" are different answers that would otherwise look alike.
--
-- SELF-CONTAINED apart from the BfBot.* reads it uses to pick a real spell.
-- Every engine access is pcall-guarded.

local S = {}
BfBotProbe113 = S

S.caster = nil         -- portrait slot that casts; found by PickCast
S.resref = nil
S.spellName = nil
S.trials = {}          -- state -> {slot, before, actions}

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

--- How many effects on sprite name resref as their source.
local function _countFrom(sprite, resref)
    local want, found = resref:upper(), 0
    local ok = pcall(function()
        EEex_Utility_IterateCPtrList(sprite.m_timedEffectList, function(effect)
            local okRes, res = pcall(function() return effect.m_sourceRes:get() end)
            if okRes and res and res:upper() == want then found = found + 1 end
        end)
    end)
    if not ok then return nil end
    return found
end

--- Every state we can read that bears on being targetable.
---
--- Plain reads only. The first run of this probe evaluated three conditional
--- strings per sprite through `EEex_Trigger_EvalConditionalStringAsAIBase`
--- and the console command was claimed and then never answered within 30 s:
--- eighteen BCS compilations inside one poll callback. Never put a script
--- compilation in a probe's per-sprite loop.
---
--- The STATE.IDS bitfield is reported raw rather than tested against named
--- bits, so the A/B itself shows which bit `op20 p2=0` and `p2=1` each set
--- instead of this probe asserting a symbol's value.
local function _states(sprite)
    local okState, state = pcall(EEex_Sprite_GetState, sprite)
    local okSan, sanctuary = pcall(EEex_Sprite_GetSpellState, sprite, 20)
    return string.format("state=%s san=%s",
        okState and string.format("0x%08X", state or 0) or "ERR",
        okSan and tostring(sanctuary) or "ERR")
end

--- The PlayerN index a BCS action needs: join order, never portrait order.
local function _playerRef(sprite)
    local ok, index = pcall(EEex_Sprite_GetCharacterIndex, sprite)
    if not ok or not index then return nil end
    return "Player" .. tostring(index + 1)
end

--- Which portrait slots hold a sprite, so the driver knows what it can use.
function BfBotProbe113_Party()
    local lines = {}
    for slot = 0, 5 do
        local sprite = _sprite(slot)
        if sprite then
            local ok, index = pcall(EEex_Sprite_GetCharacterIndex, sprite)
            lines[#lines + 1] = string.format("slot=%d name=%s player=%s %s",
                slot, _name(sprite), ok and tostring(index + 1) or "ERR",
                _states(sprite))
        end
    end
    return table.concat(lines, "\n")
end

--- Why a row cannot serve as the probe's cast, or nil when it can.
local function _rejected(row, resref)
    if not resref or resref == "" then return "no resref" end
    if row.isAoE == 1 then return "area" end
    if row.isSelfOnly == 1 then return "self only" end
    if row.variants and #row.variants > 0 then return "has variants" end
    return nil
end

--- Pick a real single-target buff out of a party member's own spellbook,
--- using BuffBot's scan and classifier rather than a hardcoded resref, so the
--- answer describes what BuffBot would actually cast.
---
--- The caster is chosen BEFORE the recipients, because a three-member save has
--- no slots to spare: assigning recipients first once left only a member with
--- nothing single-target in its book, and the probe stopped without saying so.
--- Every rejected row is reported for the same reason -- "no spell to cast" is
--- not a finding, it is a probe that did not run.
function BfBotProbe113_PickCast()
    local notes = {}
    for slot = 0, 5 do
        local sprite = _sprite(slot)
        if sprite then
            local ok, rows, total = pcall(BfBot.Scan.GetCastableSpells, sprite)
            if not ok then
                notes[#notes + 1] = string.format("slot %d: scan failed (%s)",
                    slot, tostring(rows))
            elseif not rows or (total or 0) == 0 then
                notes[#notes + 1] = string.format("slot %d: no castable rows",
                    slot)
            else
                -- Keyed by resref, so pairs() and the `count` return; `#rows`
                -- is 0 on this table and reported an empty spellbook for a
                -- party that has one.
                local counts, fallback = {}, nil
                for resref, row in pairs(rows) do
                    local why = _rejected(row, resref)
                    if not why then
                        if (row.count or 0) > 0 then
                            S.caster, S.resref = slot, resref
                            S.spellName = row.name or resref
                            return string.format(
                                "caster=%d (%s) resref=%s name=%s memorized=%s",
                                slot, _name(sprite), resref,
                                tostring(S.spellName), tostring(row.count))
                        end
                        fallback = fallback or { resref = resref, row = row }
                    else
                        counts[why] = (counts[why] or 0) + 1
                    end
                end
                if fallback then
                    S.caster, S.resref = slot, fallback.resref
                    S.spellName = fallback.row.name or fallback.resref
                    return string.format(
                        "caster=%d (%s) resref=%s name=%s memorized=0",
                        slot, _name(sprite), fallback.resref,
                        tostring(S.spellName))
                end
                local parts = {}
                for why, count in pairs(counts) do
                    parts[#parts + 1] = why .. "=" .. count
                end
                table.sort(parts)
                notes[#notes + 1] = string.format("slot %d: %d rows, all "
                    .. "rejected (%s)", slot, total,
                    table.concat(parts, " "))
            end
        end
    end
    return "NO CAST: no single-target buff in any book\n"
        .. table.concat(notes, "\n")
end

--- Which slot casts, once PickCast has chosen it.
function BfBotProbe113_Caster()
    return tostring(S.caster)
end

--- Does this SPL's own ability deliver `opcode`, and with `param2` when one
--- is asked for? Structural, so a candidate resref is never trusted for its
--- name. Uses BuffBot's own feature walk, which follows op=146 wrappers.
local function _delivers(resref, opcode, param2)
    local okHeader, header = pcall(EEex_Resource_Demand, resref, "SPL")
    if not okHeader or not header then return false, "no such SPL" end
    local okAbility, ability = pcall(function() return header:getAbility(0) end)
    if not okAbility or not ability then return false, "no ability 0" end
    -- The ability's own blocks are enough: a state spell delivers op20 or
    -- op153 itself rather than through an op=146 wrapper, and this probe
    -- should not need a seam in shipped code to ask one question.
    local found = false
    local ok, err = pcall(BfBot.Class._IterateFeatureBlocks, header, ability,
        function(fb, _)
            if fb[BfBot._fields.fb_opcode] ~= opcode then return end
            if param2 ~= nil and fb[BfBot._fields.fb_param2] ~= param2 then
                return
            end
            found = true
            return true
        end)
    if not ok then return false, "walk failed: " .. tostring(err) end
    return found, found and "ok" or "opcode not delivered"
end

--- The spell each state needs, verified before it is used. Candidates are
--- the vanilla resrefs; the structural check is what makes using one safe.
local STATE_SPELLS = {
    invisible = { opcode = 20, param2 = 0,
        candidates = { "SPWI203", "SPPR301", "SPIN101" } },
    improved = { opcode = 20, param2 = 1,
        candidates = { "SPWI405", "SPIN129", "SPIN137" } },
    sanctuary = { opcode = 153, param2 = nil,
        candidates = { "SPPR104", "SPPR103" } },
}

--- Sweep the spell ranges for a SPL that delivers `opcode` (with `param2`
--- when one is given), and remember it for `state`. Named resrefs are tried
--- first; the sweep is the fallback that survives a mod having moved the
--- spell, and it is deliberately its own console command because several
--- hundred resource probes must not run inside a per-sprite loop.
---
--- @return a line naming what was found, and how many resources were probed
function BfBotProbe113_SweepFor(state, opcode, param2)
    local prefixes = { "SPPR", "SPWI", "SPIN", "SPCL" }
    local probed, found = 0, nil
    for _, prefix in ipairs(prefixes) do
        for level = 1, 9 do
            for index = 1, 99 do
                local resref = string.format("%s%d%02d", prefix, level, index)
                local okDemand, header = pcall(EEex_Resource_Demand,
                    resref, "SPL")
                probed = probed + 1
                if okDemand and header then
                    local ok = _delivers(resref, opcode,
                        param2 ~= -1 and param2 or nil)
                    if ok then found = resref; break end
                end
            end
            if found then break end
        end
        if found then break end
    end
    S.stateSpell = S.stateSpell or {}
    if found then S.stateSpell[state] = found end
    return string.format("%s: %s after %d probes", state,
        found or "NOT FOUND", probed)
end

--- Which spell will be used for each state, and why a state has none. Run
--- before any trial so a run that cannot test a state says so up front
--- rather than reporting a verdict about a state that was never applied.
function BfBotProbe113_FindStateSpells()
    local lines = {}
    S.stateSpell = {}
    for _, state in ipairs({ "invisible", "improved", "sanctuary" }) do
        local spec = STATE_SPELLS[state]
        local chosen, notes = nil, {}
        for _, resref in ipairs(spec.candidates) do
            local ok, why = _delivers(resref, spec.opcode, spec.param2)
            notes[#notes + 1] = resref .. "=" .. tostring(why)
            if ok then chosen = resref; break end
        end
        S.stateSpell[state] = chosen
        lines[#lines + 1] = string.format("%-10s %s   (%s)", state,
            chosen or "NONE", table.concat(notes, " "))
    end
    return table.concat(lines, "\n")
end

--- Put `state` on the recipient in `slot` by casting the engine's own spell
--- at them instantly. Nothing is applied for "visible".
---
--- Returns the state before and after so the caller can see the application
--- actually changed something; a trial whose state did not change must not be
--- reported as a verdict about that state.
function BfBotProbe113_SetState(state, slot)
    local sprite = _sprite(slot)
    if not sprite then return "no sprite in slot " .. tostring(slot) end
    S.trials[state] = { slot = slot, actions = {} }

    if state == "visible" then
        return string.format("visible on slot %d (%s): nothing applied  %s",
            slot, _name(sprite), _states(sprite))
    end

    local resref = S.stateSpell and S.stateSpell[state]
    if not resref then
        S.trials[state].unusable = "no verified spell for " .. state
        return string.format("%s on slot %d: NO SPELL -- trial cannot run",
            state, slot)
    end

    local before = _states(sprite)
    local ok, err = pcall(EEex_Action_QueueResponseStringOnAIBase,
        string.format('ApplySpellRES("%s",Myself)', resref), sprite)
    if not ok then
        S.trials[state].unusable = "apply failed: " .. tostring(err)
        return string.format("%s on slot %d: apply failed (%s)", state, slot,
            tostring(err))
    end
    S.trials[state].stateSpell = resref
    S.trials[state].stateBefore = before
    return string.format("%s on slot %d (%s): applying %s  before: %s",
        state, slot, _name(sprite), resref, before)
end

--- Did the state application take? Called after giving it a moment. A trial
--- whose state did not change is marked unusable, so the verdict says so
--- instead of claiming an answer about a state that was never on.
function BfBotProbe113_ConfirmState(state)
    local trial = S.trials[state]
    if not trial then return "no trial for " .. tostring(state) end
    local sprite = _sprite(trial.slot)
    if not sprite then return "no recipient sprite" end
    local after = _states(sprite)
    trial.stateAfter = after
    if state ~= "visible" and after == trial.stateBefore then
        trial.unusable = "the state did not change: " .. after
    end
    return string.format("%s: %s -> %s%s", state,
        tostring(trial.stateBefore), after,
        trial.unusable and ("  UNUSABLE: " .. trial.unusable) or "")
end

--- Queue the cast exactly the way BfBot.Exec does.
function BfBotProbe113_Cast(state)
    local trial = S.trials[state]
    if not trial then return "no trial set up for " .. tostring(state) end
    local caster, recipient = _sprite(S.caster), _sprite(trial.slot)
    if not caster or not recipient then return "a sprite is missing" end
    local ref = _playerRef(recipient)
    if not ref then return "no PlayerN for the recipient" end

    trial.before = _countFrom(recipient, S.resref)
    trial.actions = {}
    local action = string.format('ReallyForceSpellRES("%s",%s)', S.resref, ref)
    local ok, err = pcall(EEex_Action_QueueResponseStringOnAIBase, action, caster)
    if not ok then return "queue failed: " .. tostring(err) end
    return string.format("%s: queued %s  before=%s", state, action,
        tostring(trial.before))
end

--- Sample the caster's current action. Called repeatedly between Cast and
--- Result so a dropped action is distinguishable from a blocked effect.
function BfBotProbe113_Sample(state)
    local trial = S.trials[state]
    local caster = _sprite(S.caster)
    if not trial or not caster then return "no trial or caster" end
    local ok, id = pcall(function() return caster.m_curAction.m_actionID end)
    local value = ok and tostring(id) or "ERR"
    trial.actions[#trial.actions + 1] = value
    return value
end

--- Did it land?
function BfBotProbe113_Result(state)
    local trial = S.trials[state]
    if not trial then return "no trial for " .. tostring(state) end
    local recipient = _sprite(trial.slot)
    if not recipient then return "no recipient sprite" end

    local after = _countFrom(recipient, S.resref)
    local landed = "UNKNOWN"
    if trial.before ~= nil and after ~= nil then
        landed = (after > trial.before) and "LANDED" or "did NOT land"
    end
    if trial.unusable then
        landed = "NO VERDICT"
    end
    local seen, order = {}, {}
    for _, id in ipairs(trial.actions) do
        if not seen[id] then order[#order + 1] = id end
        seen[id] = (seen[id] or 0) + 1
    end
    local actions = {}
    for _, id in ipairs(order) do
        actions[#actions + 1] = id .. "x" .. seen[id]
    end
    return string.format(
        "%-10s %-13s (%s -> %s effects from %s)  actions=%s  %s  via=%s%s",
        state, landed, tostring(trial.before), tostring(after),
        tostring(S.resref), table.concat(actions, ","), _states(recipient),
        tostring(trial.stateSpell or "-"),
        trial.unusable and ("  [" .. trial.unusable .. "]") or "")
end

--- Project Image's own case: the owner is puppet-locked, which the existing
--- policy knows as a *caster* lock. Is the owner also unreachable as a
--- *recipient*? Reports what can be read without casting Project Image, so a
--- run where no PI exists still says something useful.
function BfBotProbe113_ProjectImage()
    local lines = {}
    for slot = 0, 5 do
        local sprite = _sprite(slot)
        if sprite then
            local ok, stat = pcall(function() return sprite:getStat(139) end)
            local okCopy, parent = pcall(function() return sprite.m_nCopyParent end)
            lines[#lines + 1] = string.format(
                "slot %d %-16s stat139=%s copyParent=%s %s",
                slot, _name(sprite), ok and tostring(stat) or "ERR",
                okCopy and tostring(parent) or "ERR", _states(sprite))
        end
    end
    return table.concat(lines, "\n")
end

return "BfBotProbe113 ready"
