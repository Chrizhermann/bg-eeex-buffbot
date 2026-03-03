-- ============================================================
-- probe_clone.lua — Diagnostic probe for clone/summon sprites
-- ============================================================
-- Usage:
--   1. Deploy: bash tools/deploy.sh
--   2. In-game: cast Project Image, Simulacrum, or Summon Planetar
--   3. Select the clone/summon (click on it)
--   4. In EEex console: Infinity_DoFile("probe_clone")
--   5. Then run: BfBot.Probe.Run()
--   6. Check buffbot_probe.log in game directory
--
-- Also dumps party member #0 as a control baseline.
-- ============================================================

BfBot = BfBot or {}
BfBot.Probe = {}

local LOG_FILE = "buffbot_probe.log"
local _h = nil

-- ============================================================
-- Logging helpers
-- ============================================================
local function _open()
    _h = io.open(LOG_FILE, "w")
    if _h then
        _h:write("=== BuffBot Clone Probe " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n\n")
    end
end

local function _log(msg)
    local s = tostring(msg)
    Infinity_DisplayString(s)
    if _h then _h:write(s .. "\n"); _h:flush() end
end

local function _close()
    if _h then _h:close(); _h = nil end
end

-- Safe field access: returns value or error string
local function _try(obj, field)
    local ok, val = pcall(function() return obj[field] end)
    if ok then
        if val == nil then return "<nil>"
        elseif type(val) == "userdata" then
            -- Try :get() for string fields
            local ok2, str = pcall(function() return val:get() end)
            if ok2 and str then return tostring(str) .. " [ud:get()]" end
            -- Try tostring
            return tostring(val) .. " [userdata]"
        else
            return tostring(val)
        end
    else
        return "<ERROR: " .. tostring(val) .. ">"
    end
end

-- Safe method call
local function _tryMethod(obj, method, ...)
    local args = {...}
    local ok, val = pcall(function() return obj[method](obj, unpack(args)) end)
    if ok then
        if val == nil then return "<nil>"
        else return tostring(val) end
    else
        return "<ERROR: " .. tostring(val) .. ">"
    end
end

-- ============================================================
-- Probe a single sprite
-- ============================================================
local function _probeSprite(sprite, label)
    _log("──────────────────────────────────────────────────")
    _log("PROBING: " .. label)
    _log("──────────────────────────────────────────────────")

    -- 1. Basic identity
    _log("\n[1] IDENTITY")
    _log("  m_id            = " .. _try(sprite, "m_id"))
    _log("  getName()       = " .. _tryMethod(sprite, "getName"))
    _log("  type(sprite)    = " .. type(sprite))
    _log("  tostring        = " .. tostring(sprite))

    -- 2. Script names
    _log("\n[2] SCRIPT NAMES")
    local scriptFields = {
        "m_sName", "m_scriptName", "m_sScriptOverride", "m_sScriptClass",
        "m_sScriptRace", "m_sScriptGeneral", "m_sScriptDefault",
        "m_sScriptSpecific", "m_sScriptArea", "m_sAreaName",
        "m_sDialogRes", "m_sDeathVariable"
    }
    for _, f in ipairs(scriptFields) do
        local val = _try(sprite, f)
        if val ~= "<nil>" and not val:find("^<ERROR") then
            _log("  " .. f .. " = " .. val)
        end
    end

    -- 3. Stats (base)
    _log("\n[3] BASE STATS")
    local ok_stats, stats = pcall(function() return sprite.m_baseStats end)
    if ok_stats and stats then
        local statFields = {
            "m_generalState", "m_nClass", "m_nRace", "m_nGender",
            "m_nAlignment", "m_nKit", "m_nSpecific", "m_nEA",
            "m_nGeneral", "m_nLevel_first", "m_nLevel_second", "m_nLevel_third",
            "m_nHitPoints", "m_nMaxHitPoints", "m_nMoraleBreak",
        }
        for _, f in ipairs(statFields) do
            _log("  " .. f .. " = " .. _try(stats, f))
        end
    else
        _log("  <cannot access m_baseStats>")
    end

    -- 4. Live stats
    _log("\n[4] LIVE STATS")
    local ok_live, lstats = pcall(function() return sprite.m_liveStats end)
    if ok_live and lstats then
        _log("  m_nClass   = " .. _try(lstats, "m_nClass"))
        _log("  m_nLevel_first = " .. _try(lstats, "m_nLevel_first"))
        _log("  m_nEA      = " .. _try(lstats, "m_nEA"))
    else
        _log("  <cannot access m_liveStats>")
    end

    -- 5. Relationship fields (THE KEY UNKNOWNS)
    _log("\n[5] RELATIONSHIP / SUMMONER FIELDS (probing undocumented)")
    local relFields = {
        -- Possible summoner/controller references
        "m_summoner", "m_summonerID", "m_nSummonerID",
        "m_controllerID", "m_masterID", "m_ownerId", "m_ownerID",
        "m_parentID", "m_creatorID", "m_masterSprite",
        -- Clone-specific
        "m_cloneOf", "m_cloneID", "m_nCloneID", "m_originalID",
        "m_bSummon", "m_bIsSummon", "m_nSummonType",
        "m_bIsClone", "m_nImageType",
        -- Familiar
        "m_bFamiliar", "m_familiarOwner",
        -- Allegiance / control
        "m_allegiance", "m_nAllegiance",
        "m_controlledBy", "m_controller",
        -- CRE fields
        "m_pCRE", "m_creatureFileData",
        -- ObjectID references
        "m_lAttacker", "m_lTarget", "m_lProtector",
        -- Misc flags
        "m_bInParty", "m_nInParty", "m_nPortraitSlot",
        "m_bSelectable", "m_bVisible",
        "m_nMoveScale", "m_nMovementRate",
    }
    for _, f in ipairs(relFields) do
        local val = _try(sprite, f)
        -- Only log if not nil and not error (reduce noise)
        if val ~= "<nil>" and not val:find("^<ERROR") then
            _log("  ** " .. f .. " = " .. val .. " **")
        end
    end
    -- Also try the fields that errored, but log them separately
    _log("  [Fields that returned errors or nil - abbreviated]")
    local nilCount, errCount = 0, 0
    for _, f in ipairs(relFields) do
        local val = _try(sprite, f)
        if val == "<nil>" then nilCount = nilCount + 1
        elseif val:find("^<ERROR") then errCount = errCount + 1 end
    end
    _log("  nil fields: " .. nilCount .. ", error fields: " .. errCount)

    -- 6. Party slot check
    _log("\n[6] PARTY SLOT CHECK")
    local spriteId = nil
    pcall(function() spriteId = sprite.m_id end)
    local foundSlot = -1
    for slot = 0, 5 do
        local ps = EEex_Sprite_GetInPortrait(slot)
        if ps then
            local psId = nil
            pcall(function() psId = ps.m_id end)
            if psId and spriteId and psId == spriteId then
                foundSlot = slot
                break
            end
        end
    end
    if foundSlot >= 0 then
        _log("  IN PARTY: slot " .. foundSlot)
    else
        _log("  NOT IN PARTY (no matching portrait slot)")
    end

    -- 7. Effect list (active effects)
    _log("\n[7] ACTIVE EFFECTS (m_timedEffectList)")
    local effectCount = 0
    local ok_eff = pcall(function()
        EEex_Utility_IterateCPtrList(sprite.m_timedEffectList, function(effect)
            effectCount = effectCount + 1
            local opcode = _try(effect, "m_effectId")
            local source = "<unknown>"
            pcall(function() source = effect.m_sourceRes:get() end)
            local param1 = _try(effect, "m_effectAmount")
            local param2 = _try(effect, "m_dWFlags")
            local duration = _try(effect, "m_duration")
            local timing = _try(effect, "m_durationType")
            -- Log all effects but highlight interesting opcodes
            local prefix = "  "
            -- 158=Simulacrum, 260=ProjectImage, 402=InvokeLua, 171=GiveInnate
            -- 228=Summon creature
            local op = tonumber(opcode) or -1
            if op == 158 or op == 260 or op == 228 or op == 402 or op == 171 then
                prefix = "  >> "
            end
            _log(prefix .. "#" .. effectCount .. " op=" .. opcode
                .. " src=" .. source .. " p1=" .. param1 .. " p2=" .. param2
                .. " dur=" .. duration .. " timing=" .. timing)
        end)
    end)
    if not ok_eff then
        _log("  <cannot iterate effect list>")
    else
        _log("  Total effects: " .. effectCount)
    end

    -- 8. Spellbook access
    _log("\n[8] SPELLBOOK (GetQuickButtons)")
    local function _probeButtons(btype, label)
        local ok_qb, buttons = pcall(function()
            return sprite:GetQuickButtons(btype, false)
        end)
        if ok_qb and buttons then
            local count = 0
            for _ in pairs(buttons) do count = count + 1 end
            _log("  " .. label .. ": " .. count .. " entries")
            -- Show first 5
            local shown = 0
            for k, v in pairs(buttons) do
                if shown >= 5 then
                    _log("    ... (+" .. (count - 5) .. " more)")
                    break
                end
                _log("    " .. tostring(k) .. " = " .. tostring(v))
                shown = shown + 1
            end
        else
            _log("  " .. label .. ": <not accessible>")
        end
    end
    _probeButtons(2, "Wizard+Priest (type 2)")
    _probeButtons(4, "Innate (type 4)")

    -- 9. UDAux access
    _log("\n[9] UDAux ACCESS")
    local ok_aux, aux = pcall(function() return EEex_GetUDAux(sprite) end)
    if ok_aux and aux then
        _log("  EEex_GetUDAux: accessible (type=" .. type(aux) .. ")")
        local ok_bb = pcall(function() return aux["BB"] end)
        _log("  aux['BB']: " .. (ok_bb and tostring(aux["BB"]) or "<error>"))
    else
        _log("  EEex_GetUDAux: <not accessible>")
    end

    -- 10. Spell state sampling
    _log("\n[10] SPELL STATES (sampling first 80)")
    local activeStates = {}
    for i = 0, 79 do
        local ok_ss, active = pcall(function()
            return sprite:getSpellState(i)
        end)
        if ok_ss and active then
            table.insert(activeStates, i)
        end
    end
    if #activeStates > 0 then
        _log("  Active SPLSTATEs: " .. table.concat(activeStates, ", "))
    else
        _log("  No active SPLSTATEs (0-79)")
    end

    -- 11. Action queue test (harmless — just queues a display string)
    _log("\n[11] ACTION QUEUE TEST")
    local ok_aq = pcall(function()
        EEex_Action_QueueResponseStringOnAIBase(
            'DisplayStringHead(Myself,14674)', sprite)  -- 14674 = "Done"
    end)
    _log("  QueueResponseStringOnAIBase: " .. (ok_aq and "OK (queued DisplayStringHead)" or "FAILED"))

    _log("")
end

-- ============================================================
-- Area sprite iteration probes
-- ============================================================
local function _probeAreaAccess()
    _log("══════════════════════════════════════════════════")
    _log("AREA ACCESS PROBES")
    _log("══════════════════════════════════════════════════\n")

    -- Try various ways to access the game area
    local areaAttempts = {
        -- Global functions
        { name = "EEex_GetCurrentArea()", fn = function() return EEex_GetCurrentArea() end },
        { name = "EEex_Area_GetCurrent()", fn = function() return EEex_Area_GetCurrent() end },
        { name = "EEex_GameState_GetCurrentArea()", fn = function() return EEex_GameState_GetCurrentArea() end },
        -- Game object access
        { name = "EEex_GameObject_GetCurrentArea()", fn = function() return EEex_GameObject_GetCurrentArea() end },
        -- Chitin/engine globals
        { name = "g_pBaldurChitin", fn = function() return g_pBaldurChitin end },
        { name = "g_pChitin", fn = function() return g_pChitin end },
        { name = "EEex_GetChitin()", fn = function() return EEex_GetChitin() end },
    }

    for _, a in ipairs(areaAttempts) do
        local ok, val = pcall(a.fn)
        if ok and val ~= nil then
            _log("  ** " .. a.name .. " = " .. tostring(val) .. " (type=" .. type(val) .. ") **")
            -- If it's userdata, try to find sprite list fields
            if type(val) == "userdata" then
                local listFields = {
                    "m_lVertSort", "m_lVertSortBack",
                    "m_aGameObjects", "m_gameObjects",
                    "m_lObjects", "m_objectList",
                    "m_lCREList", "m_creatureList",
                    "m_pSpriteList", "m_spriteList",
                    "m_lTemporal", "m_lTemporalBack",
                }
                for _, f in ipairs(listFields) do
                    local ok2, lval = pcall(function() return val[f] end)
                    if ok2 and lval ~= nil then
                        _log("    ** " .. f .. " = " .. tostring(lval) .. " **")
                        -- Try to iterate if it looks like a CPtrList
                        pcall(function()
                            local count = 0
                            EEex_Utility_IterateCPtrList(lval, function(obj)
                                count = count + 1
                                if count <= 10 then
                                    local oid = "<unknown>"
                                    pcall(function() oid = obj.m_id end)
                                    local oname = "<unknown>"
                                    pcall(function() oname = obj:getName() end)
                                    _log("      [" .. count .. "] id=" .. tostring(oid) .. " name=" .. tostring(oname))
                                end
                            end)
                            _log("      Total objects in list: " .. count)
                        end)
                    end
                end
            end
        else
            -- Only log errors, not nil returns
            if not ok then
                _log("  " .. a.name .. " = <ERROR: " .. tostring(val) .. ">")
            end
        end
    end

    -- Try EEex_GameObject_Get with party member IDs ± offsets
    _log("\n  [Probing EEex_GameObject_Get near party IDs]")
    local partyIds = {}
    for slot = 0, 5 do
        local sp = EEex_Sprite_GetInPortrait(slot)
        if sp then
            pcall(function() table.insert(partyIds, sp.m_id) end)
        end
    end
    if #partyIds > 0 then
        local minId = partyIds[1]
        local maxId = partyIds[1]
        for _, id in ipairs(partyIds) do
            if id < minId then minId = id end
            if id > maxId then maxId = id end
        end
        _log("  Party ID range: " .. minId .. " - " .. maxId)
        -- Probe IDs around party range
        for testId = minId - 5, maxId + 20 do
            local ok3, obj = pcall(function() return EEex_GameObject_Get(testId) end)
            if ok3 and obj then
                local inParty = false
                for _, pid in ipairs(partyIds) do
                    if pid == testId then inParty = true; break end
                end
                if not inParty then
                    local oname = "<unknown>"
                    pcall(function() oname = obj:getName() end)
                    _log("  ** NON-PARTY OBJECT id=" .. testId .. " name=" .. tostring(oname) .. " type=" .. type(obj) .. " **")
                    -- Quick probe of this object
                    local oScr = "<nil>"
                    pcall(function() oScr = obj.m_sName:get() end)
                    _log("     script=" .. oScr)
                end
            end
        end
    end
end

-- ============================================================
-- Main entry point
-- ============================================================
function BfBot.Probe.Run()
    _open()
    _log("BuffBot Clone/Summon Diagnostic Probe v1.0\n")

    -- Probe party member slot 0 as control baseline
    local baseline = EEex_Sprite_GetInPortrait(0)
    if baseline then
        _probeSprite(baseline, "PARTY MEMBER SLOT 0 (baseline)")
    else
        _log("WARNING: No character in party slot 0\n")
    end

    -- Probe selected sprites
    _log("══════════════════════════════════════════════════")
    _log("SELECTED SPRITES (non-party)")
    _log("══════════════════════════════════════════════════\n")

    local selectedCount = 0
    local ok_sel = pcall(function()
        EEex_Sprite_IterateSelected(function(sprite)
            selectedCount = selectedCount + 1
            -- Check if in party
            local inParty = false
            local sid = nil
            pcall(function() sid = sprite.m_id end)
            for slot = 0, 5 do
                local ps = EEex_Sprite_GetInPortrait(slot)
                if ps then
                    local psid = nil
                    pcall(function() psid = ps.m_id end)
                    if psid and sid and psid == sid then
                        inParty = true
                        break
                    end
                end
            end
            if not inParty then
                _probeSprite(sprite, "SELECTED NON-PARTY SPRITE #" .. selectedCount)
            else
                _log("Selected sprite #" .. selectedCount .. " is party member (skipping)\n")
            end
        end)
    end)

    if not ok_sel then
        _log("EEex_Sprite_IterateSelected: NOT AVAILABLE\n")
        -- Fallback: try GetSelected
        local ok_gs, sel = pcall(function() return EEex_Sprite_GetSelected() end)
        if ok_gs and sel then
            _log("EEex_Sprite_GetSelected: returned " .. tostring(sel))
            _probeSprite(sel, "SELECTED SPRITE (GetSelected fallback)")
        else
            _log("EEex_Sprite_GetSelected: NOT AVAILABLE\n")
        end
    end

    if selectedCount == 0 then
        _log("No sprites selected. Select a clone/summon and re-run.\n")
    end

    -- Probe area access
    _probeAreaAccess()

    _log("\n══════════════════════════════════════════════════")
    _log("PROBE COMPLETE — see " .. LOG_FILE)
    _log("══════════════════════════════════════════════════")
    _close()
end

-- Also provide a quick version that just checks the selected sprite
function BfBot.Probe.Quick()
    _open()
    _log("BuffBot Quick Clone Probe\n")
    local ok, sel = pcall(function() return EEex_Sprite_GetSelected() end)
    if ok and sel then
        _probeSprite(sel, "SELECTED SPRITE")
    else
        _log("No sprite selected or GetSelected not available")
    end
    _close()
end

Infinity_DisplayString("probe_clone.lua loaded. Run: BfBot.Probe.Run()")
