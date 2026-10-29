-- tools/probe_summon_origin.lua — engine probes for the #101 summon-origin
-- filter. Loaded into a lab game through the remote console's loadfile path;
-- it registers globals that persist across follow-up commands.
--
-- The question offline tests cannot answer: does the engine actually set
-- `m_lSummonedBy` for a creature a party member summoned, and leave it empty
-- for one that was merely created? The A/B is deliberately exact — the SAME
-- creature file, once summoned by a real spell, once spawned by
-- CreateCreature — so the only difference left is the summoning itself.
--
-- SELF-CONTAINED apart from the BfBot.* reads it REPORTS on. Every engine
-- access is pcall-guarded. NEVER EEex_PtrToUD an area-list value: those are
-- object ids, not pointers (C-level crash that bypasses pcall).

local function _field(object, read)
    local ok, value = pcall(read, object)
    if not ok then return "ERR" end
    if value == nil then return "nil" end
    return tostring(value)
end

local function _name(sprite)
    local ok, value = pcall(function() return BfBot._GetName(sprite) end)
    if ok and value then return tostring(value) end
    local okName, raw = pcall(function() return sprite:getName() end)
    return okName and tostring(raw) or "?"
end

--- Every sprite in the leader's area, with the two linkage fields, EEex's
--- marshalled summoner UUID, and the verdict BuffBot's filter reaches.
function BfBotProbe101_Dump()
    local leader = EEex_Sprite_GetInPortrait(0)
    if not leader then return "no leader sprite" end

    local lines, seen = {}, {}
    local ok, err = pcall(function()
        EEex_Utility_IterateCPtrList(leader.m_pArea.m_lVertSort, function(id)
            if seen[id] then return end
            seen[id] = true
            local object = EEex_GameObject_Get(id)
            if not object or not EEex_GameObject_IsSprite(object, false) then
                return
            end
            local sprite = EEex_GameObject_CastUserType(object)

            local verdict
            local origin, why = BfBot.Scan._ReadSummonOrigin(sprite)
            if origin then
                local party = origin.ownerId
                    and tostring(BfBot.Scan._OwnerChainReachesParty(origin.ownerId))
                    or "unresolved"
                verdict = origin.kind .. " owner=" .. tostring(origin.ownerId)
                    .. " party=" .. party
            else
                verdict = "REJECT(" .. tostring(why) .. ")"
            end
            local accepted = BfBot.Scan.ClassifySummonSprite(sprite) ~= nil

            lines[#lines + 1] = string.format(
                "%-20s id=%-6s ea=%-5s por=%-4s parent=%-6s inCopy=%-6s"
                    .. " summonedBy=%-7s uuid=%-4s %-34s caster=%s",
                _name(sprite), tostring(id),
                _field(sprite, function(s) return s.m_typeAI.m_EnemyAlly end),
                _field(sprite, EEex_Sprite_GetPortraitIndex),
                _field(sprite, function(s) return s.m_nCopyParent end),
                _field(sprite, function(s) return s.m_bInCopy end),
                _field(sprite, function(s) return s.m_lSummonedBy.m_Instance end),
                _field(sprite, function(s)
                    local aux = EEex_GetUDAux(s)
                    return (aux and aux["EEex_SummonerUUID"]) and "set" or nil
                end),
                verdict, tostring(accepted))
        end)
    end)
    if not ok then return "area sweep failed: " .. tostring(err) end

    table.sort(lines)
    return table.concat(lines, "\n")
end

--- The CRE an opcode-67 block in `resref` conjures, or nil.
local function _summonedCre(resref)
    if type(BfBot._fields) ~= "table" then return nil end
    local opField, resField = BfBot._fields.fb_opcode, BfBot._fields.fb_res
    local okHdr, header = pcall(EEex_Resource_Demand, resref, "SPL")
    if not okHdr or not header then return nil end
    local found = nil
    for index = 0, (header.abilityCount or 0) - 1 do
        local okAb, ability = pcall(function() return header:getAbility(index) end)
        if okAb and ability then
            BfBot.Class._IterateFeatureBlocks(header, ability, function(fb)
                if fb[opField] == 67 then
                    local res = fb[resField]
                    if type(res) == "userdata" then
                        local okG, value = pcall(function() return res:get() end)
                        res = okG and value or "?"
                    end
                    if type(res) == "string" and res ~= "" then
                        found = res
                        return true
                    end
                end
            end)
        end
        if found then return found end
    end
    return nil
end

--- Find a spell that carries opcode 67 (summon creature) and the CRE it
--- conjures. Discovered, never hardcoded: resrefs differ per game and per mod,
--- and a guessed one would silently probe nothing.
---
--- The party's own spellbooks first, because force-casting what a character
--- actually knows is the most faithful test. A lab party may know none, so the
--- fallback walks the engine's systematic spell names (SPWI/SPPR <level><nn>)
--- and asks the resource manager — `ReallyForceSpellRES` casts a spell whether
--- or not it is memorized, which is exactly how BuffBot applies its own
--- Quick Cast SPL, so an unlearned spell still exercises the real code path.
--- @return "slot=N resref=XXXX cre=YYYY" or a diagnosis.
function BfBotProbe101_FindSummonSpell()
    if type(BfBot._fields) ~= "table" then return "BfBot._fields missing" end
    local tried = 0

    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local okSpells, spells = pcall(BfBot.Scan.GetCastableSpells, sprite)
            if okSpells and type(spells) == "table" then
                for resref in pairs(spells) do
                    tried = tried + 1
                    local cre = _summonedCre(resref)
                    if cre then
                        return "slot=" .. slot .. " resref=" .. resref
                            .. " cre=" .. cre .. " source=spellbook"
                    end
                end
            end
        end
    end
    local known = tried

    local caster = nil
    for slot = 0, 5 do
        if EEex_Sprite_GetInPortrait(slot) then
            caster = slot
            break
        end
    end
    if caster == nil then return "no party member to cast with" end

    for _, prefix in ipairs({ "SPWI", "SPPR" }) do
        for level = 1, 9 do
            for number = 1, 50 do
                local resref = string.format("%s%d%02d", prefix, level, number)
                tried = tried + 1
                local cre = _summonedCre(resref)
                if cre then
                    return "slot=" .. caster .. " resref=" .. resref
                        .. " cre=" .. cre .. " source=resource-scan"
                end
            end
        end
    end
    return "no opcode-67 spell found (" .. known .. " known, "
        .. tried .. " examined in all)"
end

--- Cast `resref` from party `slot` the way BuffBot casts: a queued BCS action
--- on the sprite, so the engine runs its own summoning code path.
function BfBotProbe101_Cast(slot, resref)
    local sprite = EEex_Sprite_GetInPortrait(slot)
    if not sprite then return "no sprite in slot " .. tostring(slot) end
    local ok, err = pcall(EEex_Action_QueueResponseStringOnAIBase,
        'ReallyForceSpellRES("' .. resref .. '",Myself)', sprite)
    if not ok then return "queue failed: " .. tostring(err) end
    return "queued " .. resref .. " on slot " .. slot
end

--- Spawn the SAME creature file without summoning it — the control. A
--- created creature is what a friendly quest NPC looks like to the filter.
function BfBotProbe101_Create(cre)
    local sprite = EEex_Sprite_GetInPortrait(0)
    if not sprite then return "no leader sprite" end
    local ok, err = pcall(EEex_Action_QueueResponseStringOnAIBase,
        'CreateCreatureObjectOffset("' .. cre .. '",Myself,[30.30],0)', sprite)
    if not ok then return "queue failed: " .. tostring(err) end
    return "queued CreateCreatureObjectOffset " .. cre
end

return "probe loaded"
