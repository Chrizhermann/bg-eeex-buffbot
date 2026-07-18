-- tools/probe_summons.lua — Phase-0 engine probes for summon casters (issue #19).
--
-- SELF-CONTAINED: no BfBot.* dependencies (except the optional BFBOTGO hook,
-- which requires BuffBot to be loaded). Usage:
--   1. load into the running game via the remote console's @file mode:
--        bash .../eeex-remote.sh "<game>/override" @tools/probe_summons.lua
--      (do NOT copy into override/ + Infinity_DoFile: files ADDED to override
--      mid-session are not in the resource index — DoFile silently no-ops;
--      verified 2026-07-11. @file sends the chunk straight through loadstring.)
--   2. call the BfBotProbe* globals as single-line follow-up commands
--      (globals persist across remote-console commands).
--
-- Safety: every engine access is pcall-guarded; errors are reported inline in
-- the returned string. NEVER EEex_PtrToUD area-list values — they are object
-- IDs, not pointers (C-level crash, bypasses pcall).

-- ---------------------------------------------------------------- helpers --

--- pcall-guarded dotted-path field fetch; returns a printable string.
--- "—" = field missing / indexing errored (distinct from a real nil value).
local function _probeField(obj, path)
    local ok, val = pcall(function()
        local cur = obj
        for part in path:gmatch("[^%.]+") do
            cur = cur[part]
        end
        return cur
    end)
    if not ok then return "—" end
    if val == nil then return "nil" end
    if type(val) == "userdata" then
        local parts = {}
        local okG, str = pcall(function() return val:get() end)
        if okG and str ~= nil then parts[#parts + 1] = "get()=" .. tostring(str) end
        local okI, mid = pcall(function() return val.m_id end)
        if okI and mid ~= nil then parts[#parts + 1] = "m_id=" .. tostring(mid) end
        parts[#parts + 1] = "[" .. tostring(val) .. "]"
        return table.concat(parts, " ")
    end
    return tostring(val)
end

--- Object ID -> live CGameSprite (or nil). Never errors.
local function _resolveSpriteById(id)
    id = tonumber(id)
    if not id then return nil end
    local sprite = nil
    pcall(function()
        local obj = EEex_GameObject_Get(id)
        if obj and EEex_GameObject_IsSprite(obj, false) then
            sprite = EEex_GameObject_CastUserType(obj)
        end
    end)
    return sprite
end

--- Coerce one m_lVertSort list value to an object ID. The list stores object
--- IDs in the pointer slots — probe which Lua-side form EEex hands us.
local function _coerceListValue(v)
    if type(v) == "number" then return v, "v is a plain Lua number (use directly)" end
    local n = tonumber(v)
    if n then return n, "tonumber(v)" end
    local ok, id = pcall(function() return v.m_objectID end)
    if ok and type(id) == "number" then return id, "v.m_objectID" end
    ok, id = pcall(function() return v.m_id end)
    if ok and type(id) == "number" then return id, "v.m_id" end
    if EEex_UDToPtr then
        ok, id = pcall(function() return EEex_UDToPtr(v) end)
        if ok and type(id) == "number" then return id, "EEex_UDToPtr(v)" end
    end
    return nil, "UNRESOLVED type=" .. type(v) .. " tostring=" .. tostring(v):sub(1, 40)
end

--- Iterate object IDs in area.m_lVertSort. Tries EEex_Utility_IterateCPtrList
--- first, falls back to a manual node walk. Returns (workingFormString, err).
local function _iterateAreaObjectIds(area, fn)
    local form, firstBad = nil, nil
    local okIter, errIter = pcall(function()
        EEex_Utility_IterateCPtrList(area.m_lVertSort, function(v)
            local id, how = _coerceListValue(v)
            if id then
                form = form or ("EEex_Utility_IterateCPtrList(area.m_lVertSort, fn) — " .. how)
                fn(id)
            else
                firstBad = firstBad or how
            end
        end)
    end)
    if okIter and form then return form, firstBad end
    -- Fallback: manual CPtrList node walk with field-name probing.
    local walked = 0
    local okWalk, errWalk = pcall(function()
        local list = area.m_lVertSort
        local node = list.m_pNodeHead
        while node do
            local v = nil
            local okD = pcall(function() v = node.data end)
            if not okD then pcall(function() v = node.m_data end) end
            local id, how = _coerceListValue(v)
            if id then
                form = form or ("manual walk m_pNodeHead/.pNext, node.data — " .. how)
                fn(id)
            else
                firstBad = firstBad or how
            end
            local nxt = nil
            if not pcall(function() nxt = node.pNext end) then
                pcall(function() nxt = node.m_pNext end)
            end
            node = nxt
            walked = walked + 1
            if walked > 4000 then break end -- cycle guard
        end
    end)
    if form then return form, firstBad end
    return nil, "iter failed: IterateCPtrList=" .. tostring(errIter)
        .. " | manual=" .. tostring(errWalk) .. " | firstBad=" .. tostring(firstBad)
end

-- Candidate summon/puppet/owner fields to probe on every interesting sprite.
-- Discovered live via getmetatable(sprite)[".get"] enumeration (EEex v0.11):
-- CGameSprite has NO m_puppetType/m_puppetMaster/m_summonerID bindings; the
-- clone concept is "copy": m_nCopyParent (-1 for normal sprites), m_bInCopy,
-- m_bCopyForAdd. Gender byte lives at m_baseStats.m_sex (not m_gender).
local _CANDIDATE_FIELDS = {
    "m_nCopyParent", "m_bInCopy", "m_bCopyForAdd", "m_type", "m_triggerId",
    "m_resref", "m_specificScriptName", "m_baseStats.m_sex",
    "m_baseStats.m_generalState",
}

-- ------------------------------------------------------------- area probe --

--- Dump every sprite in the leader's area: identity + candidate owner fields.
--- Full field dump for party members and EA<=30 non-party sprites; one-liner
--- for the rest. Records the working iteration form in BFBT_PROBE_ITER.
function BfBotProbe()
    local out = {}
    local function add(s) if #out < 500 then out[#out + 1] = s end end
    local leader = EEex_Sprite_GetInPortrait(0)
    if not leader then return "NO LEADER (portrait slot 0 empty?)" end
    local area = nil
    pcall(function() area = leader.m_pArea end)
    if not area then return "leader.m_pArea is nil" end

    local count = 0
    local form, iterNote = _iterateAreaObjectIds(area, function(id)
        local ok, err = pcall(function()
            local obj = EEex_GameObject_Get(id)
            if not obj or not EEex_GameObject_IsSprite(obj, false) then return end
            local s = EEex_GameObject_CastUserType(obj)
            count = count + 1
            local name = "?"
            pcall(function() name = EEex_Sprite_GetName(s) or "?" end)
            if name == "?" or name == "" then
                pcall(function() name = s:getName() or name end)
            end
            local portrait = -2
            pcall(function() portrait = EEex_Sprite_GetPortraitIndex(s) end)
            local ea = _probeField(s, "m_typeAI.m_EnemyAlly")
            local eaNum = tonumber(ea)
            add(string.format("id=%s name=%s script=%s portrait=%s EA=%s otype=%s",
                tostring(id), tostring(name), _probeField(s, "m_scriptName"),
                tostring(portrait), ea, _probeField(s, "m_objectType")))
            if portrait >= 0 or (eaNum and eaNum <= 30) then
                add("    m_id=" .. _probeField(s, "m_id"))
                for _, f in ipairs(_CANDIDATE_FIELDS) do
                    add("    " .. f .. "=" .. _probeField(s, f))
                end
            end
        end)
        if not ok then
            add("OBJ ERROR id=" .. tostring(id) .. ": " .. tostring(err))
        end
    end)

    BFBT_PROBE_ITER = form
    table.insert(out, 1, "ITER_FORM: " .. tostring(form)
        .. (iterNote and (" | note: " .. tostring(iterNote)) or ""))
    table.insert(out, 2, "sprites seen: " .. tostring(count))
    return table.concat(out, "\n")
end

-- ---------------------------------------------------- fast clone/ally scan --

-- Engine puppet mechanism is exposed as DERIVED STATS (stats.ids):
--   138 PUPPETMASTERID, 139 PUPPETMASTERTYPE, 140 PUPPETTYPE, 141 PUPPETID
-- CGameSprite side: m_bInCopy (bool), m_nCopyParent (owner object id, -1 none).
-- Clones expire in ~1-2 min on this SR install — probe fast after spawn.
local function _puppetStats(s)
    local r = "?"
    pcall(function()
        r = string.format("138=%s 139=%s 140=%s 141=%s",
            tostring(s:getStat(138)), tostring(s:getStat(139)),
            tostring(s:getStat(140)), tostring(s:getStat(141)))
    end)
    return r
end

--- One-shot: every live copy-clone in the area + its owner's puppet stats.
function BfBotProbeFindClone()
    local leader = EEex_Sprite_GetInPortrait(0)
    if not leader then return "no leader" end
    local found = {}
    pcall(function()
        EEex_Utility_IterateCPtrList(leader.m_pArea.m_lVertSort, function(v)
            local id = tonumber(v)
            local obj = id and EEex_GameObject_Get(id)
            if obj and EEex_GameObject_IsSprite(obj, false) then
                local s = EEex_GameObject_CastUserType(obj)
                local isCopy = false
                pcall(function() isCopy = (s.m_bInCopy == true) end)
                if isCopy then
                    local ownerLine = ""
                    pcall(function()
                        local oobj = EEex_GameObject_Get(s.m_nCopyParent)
                        if oobj then
                            local os = EEex_GameObject_CastUserType(oobj)
                            ownerLine = string.format("\n  OWNER id=%s name=%s %s",
                                tostring(s.m_nCopyParent),
                                tostring(EEex_Sprite_GetName(os)), _puppetStats(os))
                        end
                    end)
                    found[#found + 1] = string.format(
                        "CLONE id=%s name=%s script=%s EA=%s level=%s %s%s",
                        tostring(id), tostring(EEex_Sprite_GetName(s)),
                        tostring(s.m_scriptName:get()),
                        tostring(s.m_typeAI.m_EnemyAlly), tostring(s:getStat(34)),
                        _puppetStats(s), ownerLine)
                end
            end
        end)
    end)
    return #found > 0 and table.concat(found, "\n") or "no clone in area"
end

--- One-shot: every allied (EA<=30) non-party sprite — summons, planetars,
--- familiars — with puppet stats and CRE resref.
function BfBotProbeFindAllies()
    local leader = EEex_Sprite_GetInPortrait(0)
    if not leader then return "no leader" end
    local found = {}
    pcall(function()
        EEex_Utility_IterateCPtrList(leader.m_pArea.m_lVertSort, function(v)
            local id = tonumber(v)
            local obj = id and EEex_GameObject_Get(id)
            if obj and EEex_GameObject_IsSprite(obj, false) then
                local s = EEex_GameObject_CastUserType(obj)
                local ea, portrait = 999, -2
                pcall(function() ea = s.m_typeAI.m_EnemyAlly end)
                pcall(function() portrait = EEex_Sprite_GetPortraitIndex(s) end)
                if portrait == -1 and ea <= 30 then
                    found[#found + 1] = string.format(
                        "ALLY id=%s name=%s script=%s EA=%s sex=%s resref=%s copyParent=%s %s",
                        tostring(id), tostring(EEex_Sprite_GetName(s)),
                        tostring(s.m_scriptName:get()), tostring(ea),
                        _probeField(s, "m_baseStats.m_sex"),
                        _probeField(s, "m_resref"),
                        tostring(s.m_nCopyParent), _puppetStats(s))
                end
            end
        end)
    end)
    return #found > 0 and table.concat(found, "\n") or "no allied non-party sprites in area"
end

-- ------------------------------------------------------------ find spells --

--- Find memorized spells/innates by case-insensitive name substring across
--- all 6 party members. type 2 = wizard+priest spells, type 4 = innate+song.
function BfBotProbeFind(nameSub)
    local sub = tostring(nameSub or ""):lower()
    local out = {}
    for slot = 0, 5 do
        local s = EEex_Sprite_GetInPortrait(slot)
        if s then
            for _, qtype in ipairs({ 2, 4 }) do
                local okBtn, buttons = pcall(function()
                    return s:GetQuickButtons(qtype, false)
                end)
                if okBtn and buttons then
                    local okIter, errIter = pcall(function()
                        EEex_Utility_IterateCPtrList(buttons, function(bd)
                            pcall(function()
                                local resref = bd.m_abilityId.m_res:get()
                                local name = Infinity_FetchString(bd.m_name)
                                if name and name:lower():find(sub, 1, true) then
                                    out[#out + 1] = string.format(
                                        "slot=%d type=%d resref=%s name=%s count=%s",
                                        slot, qtype, tostring(resref), tostring(name),
                                        tostring(bd.m_count))
                                end
                            end)
                        end)
                    end)
                    pcall(EEex_Utility_FreeCPtrList, buttons)
                    if not okIter then
                        out[#out + 1] = "slot=" .. slot .. " type=" .. qtype
                            .. " ITER ERR: " .. tostring(errIter)
                    end
                end
            end
        end
    end
    return #out > 0 and table.concat(out, "\n")
        or ("no match for '" .. sub .. "'")
end

--- List castable spells of ANY sprite by object id (planetar spell discovery).
function BfBotProbeSpells(objectId)
    local s = _resolveSpriteById(objectId)
    if not s then return "no live sprite for object id " .. tostring(objectId) end
    local out = {}
    for _, qtype in ipairs({ 2, 4 }) do
        local okBtn, buttons = pcall(function()
            return s:GetQuickButtons(qtype, false)
        end)
        if okBtn and buttons then
            pcall(function()
                EEex_Utility_IterateCPtrList(buttons, function(bd)
                    pcall(function()
                        out[#out + 1] = string.format("type=%d resref=%s name=%s count=%s",
                            qtype, tostring(bd.m_abilityId.m_res:get()),
                            tostring(Infinity_FetchString(bd.m_name)), tostring(bd.m_count))
                    end)
                    if #out >= 60 then return true end
                end)
            end)
            pcall(EEex_Utility_FreeCPtrList, buttons)
        else
            out[#out + 1] = "type=" .. qtype .. " GetQuickButtons ERR: " .. tostring(buttons)
        end
    end
    return #out > 0 and table.concat(out, "\n") or "(no castable entries)"
end

-- ------------------------------------------------------------ cast/queue ---

--- Queue SpellRES(resref, Myself) on a portrait-slot party sprite.
function BfBotProbeCast(slot, resref)
    local s = EEex_Sprite_GetInPortrait(tonumber(slot) or -1)
    if not s then return "no sprite in portrait slot " .. tostring(slot) end
    local action = string.format('SpellRES("%s",Myself)', tostring(resref))
    local ok, err = pcall(function()
        EEex_Action_QueueResponseStringOnAIBase(action, s)
    end)
    return ok and ("queued " .. action .. " on portrait slot " .. tostring(slot))
        or ("QUEUE ERROR: " .. tostring(err))
end

--- Queue a BCS action on a NON-party sprite resolved by object id.
--- `actionOrResref`: full action string (contains "(") or a bare resref,
--- which becomes SpellRES(resref, target or Myself).
function BfBotProbeQueueOn(objectId, actionOrResref, target)
    local s = _resolveSpriteById(objectId)
    if not s then return "no live sprite for object id " .. tostring(objectId) end
    local action = tostring(actionOrResref)
    if not action:find("(", 1, true) then
        action = string.format('SpellRES("%s",%s)', action, tostring(target or "Myself"))
    end
    local ok, err = pcall(function()
        EEex_Action_QueueResponseStringOnAIBase(action, s)
    end)
    return ok and ("queued " .. action .. " on id " .. tostring(objectId))
        or ("QUEUE ERROR: " .. tostring(err))
end

--- Cast-timer snapshot for any sprite by object id (did a queued cast start?).
function BfBotProbeTimer(objectId)
    local s = _resolveSpriteById(objectId)
    if not s then return "no live sprite for object id " .. tostring(objectId) end
    local t = "ERR"
    pcall(function() t = tostring(EEex_Sprite_GetCastTimer(s)) end)
    return "castTimer=" .. t
        .. " curActionID=" .. _probeField(s, "m_curAction.m_actionID")
end

-- --------------------------------------------------------------- innates ---

--- List known innates of a sprite by object id (looking for BFBT* on clones).
--- Primary: plain known-innate iterator (verified pattern from dump_innates).
--- Also probes the WithAbility variant and reports what it yields.
function BfBotProbeInnates(objectId)
    local s = _resolveSpriteById(objectId)
    if not s then return "no live sprite for object id " .. tostring(objectId) end
    local out, bfbt = {}, 0
    if EEex_Sprite_GetKnownInnateSpellsIterator then
        local ok, err = pcall(function()
            for level, idx, resref in EEex_Sprite_GetKnownInnateSpellsIterator(s) do
                out[#out + 1] = string.format("L%d#%d %s", level, idx, tostring(resref))
                if tostring(resref):match("^BFBT") then bfbt = bfbt + 1 end
            end
        end)
        if not ok then out[#out + 1] = "plain iter ERR: " .. tostring(err) end
    else
        out[#out + 1] = "EEex_Sprite_GetKnownInnateSpellsIterator: nil"
    end
    local withAbility = "n/a"
    if EEex_Sprite_GetKnownInnateSpellsWithAbilityIterator then
        local okW, errW = pcall(function()
            local n = 0
            for a, b, c, d in EEex_Sprite_GetKnownInnateSpellsWithAbilityIterator(s) do
                n = n + 1
                if n == 1 then
                    withAbility = string.format("yields: %s | %s | %s | %s",
                        tostring(a), tostring(b), tostring(c), tostring(d))
                end
            end
            withAbility = withAbility .. " (" .. n .. " entries)"
        end)
        if not okW then withAbility = "ERR: " .. tostring(errW) end
    else
        withAbility = "function nil"
    end
    return string.format("innates (%d entries, %d BFBT*):\n%s\nWithAbilityIterator: %s",
        #out, bfbt, table.concat(out, "\n"), withAbility)
end

-- ----------------------------------------------------- BFBOTGO capture hook --

--- Capture-only monkey-patch of BuffBot's opcode-402 handler. Does NOT
--- delegate: no buff run fires and no innate re-grant happens while hooked.
function BfBotProbeHookGo()
    if type(BFBOTGO) ~= "function" then
        return "BFBOTGO is not a function (BuffBot not loaded?)"
    end
    BFBOTGO_orig = BFBOTGO_orig or BFBOTGO
    BFBOTGO = function(p1, p2, sp)
        -- Never error out of an opcode-402 handler (engine shows "panic").
        pcall(function()
            local okS, src = pcall(function() return p1.m_sourceId end)
            local okA, amt = pcall(function() return p1.m_effectAmount end)
            local okF, flg = pcall(function() return p1.m_dWFlags end)
            local okT, tgt = pcall(function() return p1.m_sourceTarget end)
            BFBT_PROBE_LAST = string.format(
                "sourceId=%s effectAmount(slot)=%s dwFlags(preset)=%s sourceTarget=%s",
                tostring(okS and src or "ERR"), tostring(okA and amt or "ERR"),
                tostring(okF and flg or "ERR"), tostring(okT and tgt or "ERR"))
        end)
    end
    BFBT_PROBE_LAST = "(hooked, nothing captured yet)"
    return "hooked BFBOTGO (capture-only, no delegation)"
end

function BfBotProbeUnhookGo()
    if BFBOTGO_orig then
        BFBOTGO = BFBOTGO_orig
        BFBOTGO_orig = nil
        return "BFBOTGO restored"
    end
    return "nothing to restore (not hooked)"
end

function BfBotProbeLast()
    return tostring(BFBT_PROBE_LAST)
end

return "probe_summons loaded"
