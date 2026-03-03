-- ============================================================
-- BfBotTst.lua — BuffBot In-Game Test Suite
-- Run from EEex Lua console: BfBot.Test.RunAll()
-- ============================================================

BfBot = BfBot or {}
BfBot.Test = {}

-- ============================================================
-- Test Utilities
-- Use BfBot._Print (Infinity_DisplayString) for in-game output
-- ============================================================

local P = function(msg) BfBot._Print(msg) end

local _pass = 0
local _fail = 0
local _warn = 0

local function _reset()
    _pass = 0
    _fail = 0
    _warn = 0
end

local function _ok(msg)
    _pass = _pass + 1
    P("  PASS: " .. msg)
end

local function _nok(msg)
    _fail = _fail + 1
    P("  FAIL: " .. msg)
end

local function _warning(msg)
    _warn = _warn + 1
    P("  WARN: " .. msg)
end

local function _summary(section)
    P(string.format("  --- %s: %d pass, %d fail, %d warn ---",
        section, _pass, _fail, _warn))
    return _fail == 0
end

--- Try to read a field on a userdata. Returns value, fieldName on success.
local function _tryField(ud, names, expectedType)
    if type(names) == "string" then names = { names } end
    for _, name in ipairs(names) do
        local ok, val = pcall(function() return ud[name] end)
        if ok and val ~= nil then
            if expectedType == nil or type(val) == expectedType then
                return val, name
            end
        end
    end
    return nil, nil
end

-- ============================================================
-- BfBot.Test.CheckFields — Field Name Verification
-- MUST run first. Verifies all assumed field names.
-- ============================================================

function BfBot.Test.CheckFields()
    P("=== CheckFields: Verifying EEex field names ===")
    _reset()

    -- 1. Load a known spell (Haste — SPWI305)
    local header = EEex_Resource_Demand("SPWI305", "SPL")
    if not header then
        _nok("Cannot load SPWI305 (Haste). Is the game running with EEex?")
        return _summary("CheckFields")
    end
    _ok("EEex_Resource_Demand('SPWI305', 'SPL') loaded")

    -- 2. Verify Spell_Header_st fields
    local headerChecks = {
        { "itemType",          "number",  "spell type" },
        { "spellLevel",        "number",  "spell level" },
        { "genericName",       "number",  "name strref" },
        { "secondaryType",     "number",  "MSECTYPE" },
        { "abilityCount",      "number",  "ability count" },
        { "abilityOffset",     "number",  "ability offset" },
        { "effectsOffset",     "number",  "effects offset" },
    }

    for _, check in ipairs(headerChecks) do
        local val, name = _tryField(header, check[1], check[2])
        if val ~= nil then
            _ok("Header." .. check[1] .. " = " .. tostring(val)
                .. " (" .. check[3] .. ")")
        else
            _nok("Header." .. check[1] .. " not accessible ("
                .. check[3] .. ")")
        end
    end

    -- Verify spell name fetch
    local spellName = Infinity_FetchString(header.genericName)
    if spellName and spellName ~= "" then
        _ok("FetchString(genericName) = \"" .. spellName .. "\"")
    else
        _warning("FetchString(genericName) returned empty")
    end

    -- 3. Get ability for Haste at caster level 10
    local ability = header:getAbilityForLevel(10)
    if not ability then
        ability = header:getAbility(0)
    end
    if not ability then
        _nok("Cannot get ability for SPWI305")
        return _summary("CheckFields")
    end
    _ok("getAbilityForLevel(10) succeeded")

    -- 4. Verify confirmed Spell_ability_st fields
    local abilChecks = {
        { "actionType",     "number",  "target type" },
        { "actionCount",    "number",  "target count" },
        { "minCasterLevel", "number",  "min caster level" },
    }
    for _, check in ipairs(abilChecks) do
        local val, name = _tryField(ability, check[1], check[2])
        if val ~= nil then
            _ok("Ability." .. check[1] .. " = " .. tostring(val)
                .. " (" .. check[3] .. ")")
        else
            _nok("Ability." .. check[1] .. " not accessible ("
                .. check[3] .. ")")
        end
    end

    -- Verify quickSlotIcon
    local iconOk, iconVal = pcall(function()
        return ability.quickSlotIcon:get()
    end)
    if iconOk and iconVal then
        _ok("quickSlotIcon:get() = \"" .. iconVal .. "\"")
    else
        _warning("quickSlotIcon:get() failed: " .. tostring(iconVal))
    end

    -- 5. Verify UNCERTAIN fields with fallbacks
    -- Feature block count
    local fbCount, fbCountName = _tryField(ability,
        { "effectCount", "featureBlockCount" }, "number")
    if fbCount ~= nil then
        _ok("Ability." .. fbCountName .. " = " .. tostring(fbCount)
            .. " (fb count)")
        BfBot._fields.fb_count = fbCountName
    else
        _nok("FB count field not found (tried: effectCount, featureBlockCount)")
    end

    -- Feature block start index
    local fbStart, fbStartName = _tryField(ability,
        { "startingEffect", "featureBlockOffset" }, "number")
    if fbStart ~= nil then
        _ok("Ability." .. fbStartName .. " = " .. tostring(fbStart)
            .. " (fb start)")
        BfBot._fields.fb_start = fbStartName
    else
        _nok("FB start field not found (tried: startingEffect, featureBlockOffset)")
    end

    -- Friendly flags field
    local flagsVal, flagsName = _tryField(ability, { "type", "flags" }, "number")
    if flagsVal ~= nil then
        _ok("Ability." .. flagsName .. " = " .. tostring(flagsVal)
            .. " (flags)")
        BfBot._fields.friendly_flags = flagsName
        local friendly = bit.band(flagsVal, 0x0400) ~= 0
        P("       -> Friendly bit10: " .. tostring(friendly))
        local friendlyByte = bit.band(flagsVal, 0x04) ~= 0
        P("       -> Friendly bit2:  " .. tostring(friendlyByte))
    else
        _warning("Flags field not found (tried: type, flags)")
    end

    -- 6. Verify feature block access via pointer arithmetic
    if fbCount and fbCount > 0 and fbStart then
        P("  Attempting feature block pointer arithmetic...")

        local fbOk, fb = pcall(function()
            return BfBot.Class._GetFeatureBlock(header, ability, 0)
        end)

        if fbOk and fb then
            _ok("Feature block pointer arithmetic works")

            local fbChecks = {
                { { "effectID" },       "number",  "opcode" },
                { { "durationType" },   "number",  "timing" },
                { { "duration" },       "number",  "duration" },
                { { "targetType" },     "number",  "target" },
                { { "effectAmount" },   "number",  "param1" },
                { { "dwFlags" },        "number",  "param2" },
                { { "special" },        "number",  "special" },
            }
            for _, check in ipairs(fbChecks) do
                local val, name = _tryField(fb, check[1], check[2])
                if val ~= nil then
                    _ok("FB." .. name .. " = " .. tostring(val)
                        .. " (" .. check[3] .. ")")
                else
                    _nok("FB." .. check[1][1] .. " not accessible ("
                        .. check[3] .. ")")
                end
            end

            -- Verify res field
            local resOk, resVal = pcall(function()
                return fb[BfBot._fields.fb_res]:get()
            end)
            if resOk then
                _ok("FB." .. BfBot._fields.fb_res
                    .. ":get() = \"" .. tostring(resVal) .. "\"")
            else
                local res2Ok, res2Val = pcall(function()
                    return fb.resource:get()
                end)
                if res2Ok then
                    _ok("FB.resource:get() = \"" .. tostring(res2Val)
                        .. "\" (fallback)")
                    BfBot._fields.fb_res = "resource"
                else
                    _warning("FB resource field not accessible")
                end
            end
        else
            _nok("Feature block pointer arithmetic FAILED: " .. tostring(fb))
        end
    else
        _warning("Cannot test FBs (count or start field missing)")
    end

    -- 7. Verify GetQuickButtons
    P("  Verifying GetQuickButtons...")
    local sprite = EEex_Sprite_GetSelected()
    if sprite then
        local gqbOk, buttonList = pcall(function()
            return sprite:GetQuickButtons(2, false)
        end)
        if gqbOk and buttonList then
            local btnCount = 0
            local firstResref = nil
            EEex_Utility_IterateCPtrList(buttonList, function(bd)
                btnCount = btnCount + 1
                if not firstResref then
                    pcall(function()
                        firstResref = bd.m_abilityId.m_res:get()
                    end)
                end
            end)
            EEex_Utility_FreeCPtrList(buttonList)
            _ok("GetQuickButtons(2): " .. btnCount .. " entries"
                .. (firstResref and " (first: " .. firstResref .. ")" or ""))

            -- Check CButtonData fields
            local list2 = sprite:GetQuickButtons(2, false)
            EEex_Utility_IterateCPtrList(list2, function(bd)
                local fields = { "m_count", "m_bDisabled", "m_name" }
                for _, f in ipairs(fields) do
                    local fOk, fVal = pcall(function() return bd[f] end)
                    if fOk and fVal ~= nil then
                        _ok("BtnData." .. f .. " = " .. tostring(fVal))
                    else
                        _warning("BtnData." .. f .. " not accessible")
                    end
                end

                local iOk, iVal = pcall(function() return bd.m_icon:get() end)
                if iOk and iVal then
                    _ok("BtnData.m_icon:get() = \"" .. tostring(iVal) .. "\"")
                else
                    _warning("BtnData.m_icon:get() failed")
                end

                return true -- only check first entry
            end)
            EEex_Utility_FreeCPtrList(list2)
        else
            _nok("GetQuickButtons(2) failed: " .. tostring(buttonList))
        end
    else
        _warning("No sprite selected — cannot test GetQuickButtons")
    end

    BfBot._fields._resolved = true
    P("")
    return _summary("CheckFields")
end

-- ============================================================
-- BfBot.Test.ScanAll — Party-wide spell scan
-- ============================================================

function BfBot.Test.ScanAll()
    P("=== ScanAll: Scanning party spells ===")
    _reset()

    BfBot.Scan.InvalidateAll()

    local party = BfBot.Scan.ScanParty()
    if not party or not next(party) then
        _nok("No party members found. Is a game loaded?")
        return _summary("ScanAll")
    end

    for slot = 0, 5 do
        local data = party[slot]
        if data then
            P(string.format("  [Slot %d] %s - %d spells",
                slot, data.name, data.count))

            local sorted = {}
            for _, entry in pairs(data.spells) do
                table.insert(sorted, entry)
            end
            table.sort(sorted, function(a, b)
                if a.level ~= b.level then return a.level < b.level end
                return a.name < b.name
            end)

            local wizCount, priCount, innCount = 0, 0, 0
            for _, entry in ipairs(sorted) do
                local typeStr = "???"
                if entry.spellType == 1 then
                    typeStr = "WIZ"
                    wizCount = wizCount + 1
                elseif entry.spellType == 2 then
                    typeStr = "PRI"
                    priCount = priCount + 1
                elseif entry.spellType == 4 then
                    typeStr = "INN"
                    innCount = innCount + 1
                end

                local classStr = "???"
                if entry.class then
                    if entry.class.isBuff then
                        classStr = "BUFF"
                    elseif entry.class.isAmbiguous then
                        classStr = "AMB?"
                    else
                        classStr = "----"
                    end
                end

                local durStr = ""
                if entry.class then
                    durStr = entry.class.durCat or ""
                    if entry.class.duration and entry.class.duration > 0 then
                        durStr = durStr .. "(" .. entry.class.duration .. "s)"
                    elseif entry.class.duration == -1 then
                        durStr = durStr .. "(perm)"
                    end
                end

                P(string.format("    L%d %s x%d %s %s %s %s%s",
                    entry.level,
                    typeStr,
                    entry.count,
                    classStr,
                    entry.resref,
                    entry.name,
                    durStr,
                    entry.class and entry.class.isAoE and " [AoE]" or ""
                ))
            end

            P(string.format("    Summary: %d wiz, %d pri, %d inn",
                wizCount, priCount, innCount))

            if data.count > 0 then
                _ok(data.name .. ": " .. data.count .. " spells scanned")
            end
        end
    end

    P("")
    return _summary("ScanAll")
end

-- ============================================================
-- BfBot.Test.Classify — Single spell classification detail
-- ============================================================

function BfBot.Test.Classify(resref)
    if not resref then
        P("Usage: BfBot.Test.Classify('SPWI305')")
        return
    end

    P("=== Classify: " .. resref .. " ===")

    BfBot._cache.class[resref] = nil

    local header = EEex_Resource_Demand(resref, "SPL")
    if not header then
        P("  ERROR: Cannot load " .. resref)
        return
    end

    local ability = header:getAbilityForLevel(10)
    if not ability then
        ability = header:getAbility(0)
    end
    if not ability then
        P("  ERROR: No ability found for " .. resref)
        return
    end

    local name = Infinity_FetchString(header.genericName) or resref
    local typeNames = { [1]="Wizard", [2]="Priest", [4]="Innate" }

    P("  Name: " .. name)
    P("  Level: " .. tostring(header.spellLevel))
    P("  Type: " .. tostring(header.itemType)
        .. " (" .. (typeNames[header.itemType or 0] or "Unknown") .. ")")
    P("  MSECTYPE: " .. tostring(header.secondaryType))
    P("  Target type: " .. tostring(ability.actionType))
    P("  Target count: " .. tostring(ability.actionCount))

    local flagsField = BfBot._fields.friendly_flags
    local flagsVal = ability[flagsField]
    if flagsVal then
        P("  Flags (" .. flagsField .. "): " .. tostring(flagsVal)
            .. " -> friendly=" .. tostring(bit.band(flagsVal, 0x0400) ~= 0))
    end

    local fbCount = ability[BfBot._fields.fb_count]
    P("  Feature blocks: " .. tostring(fbCount))

    local result = BfBot.Class.Classify(resref, header, ability)

    P("  --- Scoring ---")
    P("  Step 1 (targeting): " .. tostring(result.targetScore)
        .. " (friendly=" .. tostring(result.friendlyFlag) .. ")")
    P("  Step 2 (MSECTYPE): " .. tostring(result.msecScore))
    P("  Step 3 (opcodes):  " .. tostring(result.opcodeScore))
    P("  TOTAL SCORE: " .. tostring(result.score)
        .. (result.selfReplacePenalty and result.selfReplacePenalty ~= 0
            and (" (incl selfReplace " .. result.selfReplacePenalty .. ")")
            or ""))
    P("  --- Result ---")
    P("  isBuff: " .. tostring(result.isBuff))
    P("  isAmbiguous: " .. tostring(result.isAmbiguous))
    P("  duration: " .. tostring(result.duration) .. "s"
        .. " (" .. tostring(result.durCat) .. ")")
    P("  isAoE: " .. tostring(result.isAoE))
    P("  defaultTarget: " .. tostring(result.defaultTarget))
    if result.splstates and #result.splstates > 0 then
        P("  SPLSTATEs: " .. table.concat(result.splstates, ", "))
    end
    P("  selfReplace: " .. tostring(result.selfReplace))
    P("  hasSubstantive: " .. tostring(result.hasSubstantive))
    P("  noSubstance: " .. tostring(result.noSubstance))
    if result.selfReplacePenalty and result.selfReplacePenalty ~= 0 then
        P("  selfReplacePenalty: " .. tostring(result.selfReplacePenalty))
    end

    return result
end

-- ============================================================
-- BfBot.Test.DumpFeatureBlocks — Diagnostic dump
-- ============================================================

function BfBot.Test.DumpFeatureBlocks(resref)
    if not resref then
        P("Usage: BfBot.Test.DumpFeatureBlocks('SPWI305')")
        return
    end

    P("=== DumpFeatureBlocks: " .. resref .. " ===")

    local header = EEex_Resource_Demand(resref, "SPL")
    if not header then
        P("  ERROR: Cannot load " .. resref)
        return
    end

    local ability = header:getAbilityForLevel(10)
    if not ability then
        ability = header:getAbility(0)
    end
    if not ability then
        P("  ERROR: No ability found")
        return
    end

    local fbCount = ability[BfBot._fields.fb_count] or 0
    P("  FB count: " .. fbCount)
    P("  effectsOffset: " .. tostring(header.effectsOffset))
    P("  " .. BfBot._fields.fb_start .. ": "
        .. tostring(ability[BfBot._fields.fb_start]))

    BfBot.Class._IterateFeatureBlocks(header, ability, function(fb, i)
        local opcode = fb[BfBot._fields.fb_opcode] or -1
        local rawTiming = fb[BfBot._fields.fb_timing] or -1
        local timing = rawTiming >= 0 and bit.band(rawTiming, 0xFF) or -1
        local duration = fb[BfBot._fields.fb_duration] or 0
        local target = fb[BfBot._fields.fb_target] or -1
        local param1 = fb[BfBot._fields.fb_param1] or 0
        local param2 = fb[BfBot._fields.fb_param2] or 0

        local resVal = ""
        pcall(function()
            resVal = fb[BfBot._fields.fb_res]:get()
        end)

        local score = BfBot.Class._OPCODE_SCORES[opcode] or 0
        local scoreStr = ""
        -- Detect self-referencing 318/324 for annotation
        local isSelfRef = false
        if (opcode == 318 or opcode == 324) and resref then
            local selfUpper = resref:upper()
            if resVal and resVal:upper() == selfUpper then
                isSelfRef = true
            end
        end
        if isSelfRef then
            scoreStr = " [+" .. score .. " SELF-REF->0]"
        elseif score > 0 then
            scoreStr = " [+" .. score .. "]"
        elseif score < 0 then
            scoreStr = " [" .. score .. "]"
        end

        P(string.format("  [%2d] op=%-3d t=%d d=%-5d tgt=%d p1=%-5d p2=%-5d r=%-8s%s",
            i, opcode, timing, duration, target, param1, param2, resVal, scoreStr))
    end)
end

-- ============================================================
-- BfBot.Test.VerifyKnownSpells — Self-test against known results
-- ============================================================

function BfBot.Test.VerifyKnownSpells()
    P("=== VerifyKnownSpells: Classification self-test ===")
    _reset()

    BfBot._cache.class = {}

    local expectations = {
        -- Definite buffs
        { "SPWI305", true,  "Haste" },
        { "SPWI408", true,  "Stoneskin" },
        { "SPPR101", true,  "Bless" },
        { "SPPR107", true,  "Protection from Evil" },
        { "SPWI114", true,  "Shield" },
        { "SPWI212", true,  "Mirror Image" },
        { "SPPR409", true,  "Death Ward" },
        { "SPPR508", true,  "Chaotic Commands" },
        { "SPWI613", true,  "Improved Haste" },
        { "SPWI108", true,  "Armor" },
        { "SPPR201", true,  "Aid" },
        { "SPPR207", nil,   "Barkskin" },  -- SR sub-spell edge case (effects via op146)
        -- Definite non-buffs
        { "SPWI304", false, "Fireball" },
        { "SPWI211", false, "Stinking Cloud" },
        { "SPWI112", false, "Magic Missile" },
        { "SPWI509", false, "Animate Dead" },
        { "SPWI503", false, "Cloudkill" },
        { "SPWI116", false, "Chromatic Orb" },
        -- Former false positives: traps (no substantive opcodes)
        { "SPCL412", false, "Set Snare" },
        { "SPCL910", false, "Set Spike Trap" },
        -- Former false positives: setup spells (no substantive opcodes)
        { "SPIN141", false, "Contingency" },
        { "SPIN142", false, "Chain Contingency" },
        -- Former false positives: pure heals (only op=17 soft)
        { "SPIN101", false, "Cure Light Wounds" },
        { "SPPR212", false, "Slow Poison" },
        -- Former false positives: offensive (324 self-ref discount)
        { "SPCL311", false, "Charm Animal" },
        -- Former false positives: stances (318 self-ref -> selfReplace)
        -- These are mod-specific; will be skipped if SPL not found:
        { "C0FIG01", false, "Power Attack (stance)" },
        { "SPCL922", false, "Tracking" },
        -- Edge cases (no expectation — just log the result)
        { "SPWI317", nil,   "Remove Magic" },
        { "SPCL908", nil,   "War Cry" },
        { "SPWI523", nil,   "Fireburst" },
    }

    for _, test in ipairs(expectations) do
        local resref = test[1]
        local expected = test[2]
        local displayName = test[3]

        local header = EEex_Resource_Demand(resref, "SPL")
        if not header then
            _warning(resref .. " (" .. displayName .. ") - SPL not found")
            goto nextTest
        end

        local ability = header:getAbilityForLevel(10)
        if not ability then
            ability = header:getAbility(0)
        end
        if not ability then
            _warning(resref .. " (" .. displayName .. ") - no ability")
            goto nextTest
        end

        local result = BfBot.Class.Classify(resref, header, ability)

        if expected == true then
            if result.isBuff then
                _ok(string.format("%s %s BUFF (%+d)", resref, displayName, result.score))
            else
                _nok(string.format("%s %s expected BUFF got %s (%+d: t=%+d m=%+d o=%+d)",
                    resref, displayName,
                    result.isAmbiguous and "AMB" or "NOT",
                    result.score, result.targetScore, result.msecScore, result.opcodeScore))
            end
        elseif expected == false then
            if not result.isBuff then
                _ok(string.format("%s %s NOT BUFF (%+d)", resref, displayName, result.score))
            else
                _nok(string.format("%s %s expected NOT BUFF got BUFF (%+d: t=%+d m=%+d o=%+d)",
                    resref, displayName,
                    result.score, result.targetScore, result.msecScore, result.opcodeScore))
            end
        else
            if result then
                _ok(string.format("%s %s %s (%+d)",
                    resref, displayName,
                    result.isBuff and "BUFF" or (result.isAmbiguous and "AMB" or "NOT"),
                    result.score))
            end
        end

        ::nextTest::
    end

    P("")
    return _summary("VerifyKnownSpells")
end

-- ============================================================
-- BfBot.Test.RunAll — Full test suite
-- ============================================================

function BfBot.Test.RunAll()
    -- Open log file so output is captured
    BfBot._OpenLog()

    P("========================================")
    P("  BuffBot Test Suite v" .. (BfBot.VERSION or "?"))
    P("========================================")

    -- Phase 1: Field verification (must pass)
    local fieldsOk = BfBot.Test.CheckFields()
    P("")
    if not fieldsOk then
        P("CRITICAL: Field verification failed.")
        P("Run BfBot.Test.DumpFeatureBlocks('SPWI305') to investigate.")
        BfBot._CloseLog()
        return false
    end

    -- Phase 2: Known spell classification
    local classOk = BfBot.Test.VerifyKnownSpells()
    P("")

    -- Phase 3: Party scan
    local scanOk = BfBot.Test.ScanAll()
    P("")

    -- Phase 4: Persistence
    local persistOk = BfBot.Test.Persist()
    P("")

    -- Phase 5: Quick Cast
    local qcOk = BfBot.Test.QuickCast()
    P("")

    -- Summary
    P("========================================")
    P("  Fields: " .. (fieldsOk and "PASS" or "FAIL"))
    P("  Classification: " .. (classOk and "PASS" or "FAIL"))
    P("  Party scan: " .. (scanOk and "PASS" or "FAIL"))
    P("  Persistence: " .. (persistOk and "PASS" or "FAIL"))
    P("  Quick Cast: " .. (qcOk and "PASS" or "FAIL"))
    P("========================================")
    P("Log written to: " .. BfBot._logFile)

    BfBot._CloseLog()
    return fieldsOk and classOk and scanOk and persistOk and qcOk
end

-- ============================================================
-- BfBot.Test.BuildTestQueue — Full dynamic buff discovery
-- ============================================================

--- Scan ALL party members for ALL memorized buff spells and build a queue.
-- Returns: queue table suitable for BfBot.Exec.Start(), or nil if nothing found
function BfBot.Test.BuildTestQueue()
    P("[BuffBot] Scanning party for ALL buff spells...")

    local queue = {}
    local totalSpells = 0
    local totalBuffs = 0

    -- Duration category sort order: long buffs first (most valuable to have up)
    local durOrder = { permanent = 1, long = 2, short = 3, instant = 4 }

    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if not sprite then goto nextSlot end

        local name = BfBot._GetName(sprite)
        BfBot.Scan.Invalidate(sprite)
        local spells, count = BfBot.Scan.GetCastableSpells(sprite)
        if not spells or count == 0 then goto nextSlot end

        totalSpells = totalSpells + count
        local casterBuffs = {}

        for resref, data in pairs(spells) do
            if data.class and data.class.isBuff and data.count > 0 and not data.disabled then
                local target = (data.class.defaultTarget == "s") and "self" or "all"
                table.insert(casterBuffs, {
                    caster = slot,
                    spell = resref,
                    target = target,
                    name = data.name or resref,
                    durCat = data.class.durCat or "?",
                    duration = data.class.duration or 0,
                    level = data.level or 0,
                    count = data.count,
                })
            end
        end

        -- Sort: long buffs first, then short, then by level desc, then name
        table.sort(casterBuffs, function(a, b)
            local oa = durOrder[a.durCat] or 5
            local ob = durOrder[b.durCat] or 5
            if oa ~= ob then return oa < ob end
            if a.duration ~= b.duration then return a.duration > b.duration end
            if a.level ~= b.level then return a.level > b.level end
            return a.name < b.name
        end)

        totalBuffs = totalBuffs + #casterBuffs
        P(string.format("[BuffBot]   %s (slot %d): %d buffs of %d spells",
            name, slot, #casterBuffs, count))
        for _, b in ipairs(casterBuffs) do
            P(string.format("[BuffBot]     %s [%s] L%d x%d (%s)",
                b.name, b.spell, b.level, b.count, b.durCat))
            table.insert(queue, { caster = b.caster, spell = b.spell, target = b.target })
        end

        ::nextSlot::
    end

    P(string.format("[BuffBot] Total: %d buffs from %d spells across party", totalBuffs, totalSpells))

    if #queue == 0 then
        P("[BuffBot] No buff spells found! Make sure characters have buffs memorized.")
        return nil
    end

    return queue
end

-- ============================================================
-- BfBot.Test.Persist — Persistence module tests
-- ============================================================

--- Helper: recursively check that no value in a table is boolean.
local function _hasBooleans(tbl, path)
    path = path or "config"
    for k, v in pairs(tbl) do
        local vt = type(v)
        local kpath = path .. "." .. tostring(k)
        if vt == "boolean" then
            return true, kpath
        elseif vt == "table" then
            local found, where = _hasBooleans(v, kpath)
            if found then return true, where end
        end
    end
    return false, nil
end

--- Helper: count entries in a table (pairs).
local function _tcount(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

--- Test the persistence module.
-- Usage from console: BfBot.Test.Persist()
function BfBot.Test.Persist()
    _reset()
    P("")
    P("========================================")
    P("  Phase 4: Persistence Tests")
    P("========================================")
    P("")

    -- Need at least one party member
    local sprite = EEex_Sprite_GetInPortrait(0)
    if not sprite then
        _nok("No party member in slot 0")
        return _summary("Persistence")
    end
    _ok("Got sprite for slot 0")

    -- ---- Test 1: GetDefaultConfig ----
    P("")
    P("  [1] Default config structure")

    local defCfg = BfBot.Persist.GetDefaultConfig()
    if defCfg then _ok("GetDefaultConfig() returned table")
    else _nok("GetDefaultConfig() returned nil"); return _summary("Persistence") end

    if defCfg.v == BfBot.Persist._SCHEMA_VERSION then _ok("Schema version: " .. defCfg.v)
    else _nok("Schema version: expected " .. BfBot.Persist._SCHEMA_VERSION .. ", got " .. tostring(defCfg.v)) end

    if defCfg.ap == 1 then _ok("Active preset: 1")
    else _nok("Active preset: expected 1, got " .. tostring(defCfg.ap)) end

    if defCfg.presets and defCfg.presets[1] and defCfg.presets[1].name == "Long Buffs" then
        _ok("Preset 1: Long Buffs")
    else _nok("Preset 1 missing or wrong name") end

    if defCfg.presets and defCfg.presets[2] and defCfg.presets[2].name == "Short Buffs" then
        _ok("Preset 2: Short Buffs")
    else _nok("Preset 2 missing or wrong name") end

    if defCfg.opts and defCfg.opts.skip == 1 then _ok("opts.skip = 1")
    else _nok("opts.skip missing or wrong") end

    if defCfg.presets[1].qc == 0 then _ok("preset 1 qc = 0")
    else _nok("preset 1 qc missing or wrong") end

    -- ---- Test 2: Boolean safety on default config ----
    P("")
    P("  [2] Boolean safety (default config)")

    local hasBool, boolPath = _hasBooleans(defCfg)
    if not hasBool then _ok("No booleans in default config")
    else _nok("Boolean found at " .. tostring(boolPath)) end

    -- ---- Test 3: Create default config for sprite (with auto-population) ----
    P("")
    P("  [3] CreateDefaultConfig + auto-population")

    -- Clear existing config
    pcall(function()
        EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = nil
    end)

    local config = BfBot.Persist.GetConfig(sprite)
    if config then _ok("GetConfig returned config after clear")
    else _nok("GetConfig returned nil"); return _summary("Persistence") end

    if config.v == BfBot.Persist._SCHEMA_VERSION then _ok("Created config has correct version")
    else _nok("Created config version: " .. tostring(config.v)) end

    -- Check auto-population (both presets should have ALL buff spells)
    local p1Count = _tcount(config.presets[1].spells)
    local p2Count = _tcount(config.presets[2].spells)
    P("    Preset 1 (Long Buffs): " .. p1Count .. " spells total")
    P("    Preset 2 (Short Buffs): " .. p2Count .. " spells total")

    if p1Count > 0 or p2Count > 0 then
        _ok("Auto-populated " .. p1Count .. " buff spells into both presets")
    else
        _warning("No buff spells auto-populated (character may have no buffs memorized)")
    end

    if p1Count == p2Count then
        _ok("Both presets have equal spell count (" .. p1Count .. ")")
    else
        _nok("Preset counts differ: P1=" .. p1Count .. " P2=" .. p2Count)
    end

    -- Check priorities are sequential and enabled spells sort before disabled
    if p1Count > 0 then
        local maxPri = 0
        local priOk = true
        local maxEnabledPri, minDisabledPri = 0, 9999
        for _, entry in pairs(config.presets[1].spells) do
            if entry.pri > maxPri then maxPri = entry.pri end
            if type(entry.pri) ~= "number" then priOk = false end
            if entry.on == 1 and entry.pri > maxEnabledPri then maxEnabledPri = entry.pri end
            if entry.on == 0 and entry.pri < minDisabledPri then minDisabledPri = entry.pri end
        end
        if priOk and maxPri <= p1Count then _ok("Preset 1 priorities sequential (max=" .. maxPri .. ")")
        elseif priOk then _warning("Preset 1 max priority " .. maxPri .. " > count " .. p1Count)
        else _nok("Preset 1 has non-numeric priorities") end

        if maxEnabledPri > 0 and minDisabledPri < 9999 then
            if maxEnabledPri < minDisabledPri then
                _ok("Preset 1: enabled spells have lower pri than disabled")
            else
                _nok("Preset 1: enabled pri " .. maxEnabledPri .. " >= disabled pri " .. minDisabledPri)
            end
        end
    end

    -- Boolean safety on created config
    hasBool, boolPath = _hasBooleans(config)
    if not hasBool then _ok("No booleans in created config")
    else _nok("Boolean found at " .. tostring(boolPath)) end

    -- ---- Test 4: Spell config accessors ----
    P("")
    P("  [4] Spell config accessors")

    -- Pick a spell resref to test with
    local testResref = nil
    for resref, _ in pairs(config.presets[1].spells) do
        testResref = resref
        break
    end
    if not testResref then
        -- Use a synthetic resref
        testResref = "ZZTST01"
        BfBot.Persist.SetSpellEnabled(sprite, 1, testResref, true)
    end

    -- Enable/disable round-trip
    BfBot.Persist.SetSpellEnabled(sprite, 1, testResref, true)
    local entry = BfBot.Persist.GetSpellConfig(sprite, 1, testResref)
    if entry and entry.on == 1 then _ok("SetSpellEnabled(true) -> on=1")
    else _nok("SetSpellEnabled(true) failed: on=" .. tostring(entry and entry.on)) end

    BfBot.Persist.SetSpellEnabled(sprite, 1, testResref, false)
    entry = BfBot.Persist.GetSpellConfig(sprite, 1, testResref)
    if entry and entry.on == 0 then _ok("SetSpellEnabled(false) -> on=0")
    else _nok("SetSpellEnabled(false) failed: on=" .. tostring(entry and entry.on)) end

    -- Target round-trip
    BfBot.Persist.SetSpellTarget(sprite, 1, testResref, "3")
    entry = BfBot.Persist.GetSpellConfig(sprite, 1, testResref)
    if entry and entry.tgt == "3" then _ok("SetSpellTarget('3') -> tgt='3'")
    else _nok("SetSpellTarget failed: tgt=" .. tostring(entry and entry.tgt)) end

    BfBot.Persist.SetSpellTarget(sprite, 1, testResref, "s")
    entry = BfBot.Persist.GetSpellConfig(sprite, 1, testResref)
    if entry and entry.tgt == "s" then _ok("SetSpellTarget('s') -> tgt='s'")
    else _nok("SetSpellTarget failed: tgt=" .. tostring(entry and entry.tgt)) end

    -- Priority round-trip
    BfBot.Persist.SetSpellPriority(sprite, 1, testResref, 42)
    entry = BfBot.Persist.GetSpellConfig(sprite, 1, testResref)
    if entry and entry.pri == 42 then _ok("SetSpellPriority(42) -> pri=42")
    else _nok("SetSpellPriority failed: pri=" .. tostring(entry and entry.pri)) end

    -- ---- Test 5: Active preset ----
    P("")
    P("  [5] Active preset switching")

    BfBot.Persist.SetActivePreset(sprite, 2)
    local preset, idx = BfBot.Persist.GetActivePreset(sprite)
    if idx == 2 then _ok("SetActivePreset(2) -> idx=2")
    else _nok("SetActivePreset(2) failed: idx=" .. tostring(idx)) end

    if preset and preset.name == "Short Buffs" then _ok("Active preset is 'Short Buffs'")
    else _nok("Active preset name wrong: " .. tostring(preset and preset.name)) end

    -- Clamp test
    BfBot.Persist.SetActivePreset(sprite, 99)
    _, idx = BfBot.Persist.GetActivePreset(sprite)
    if idx == 5 then _ok("SetActivePreset(99) clamped to 5")
    else _nok("Clamp failed: idx=" .. tostring(idx)) end

    BfBot.Persist.SetActivePreset(sprite, 0)
    _, idx = BfBot.Persist.GetActivePreset(sprite)
    if idx == 1 then _ok("SetActivePreset(0) clamped to 1")
    else _nok("Clamp failed: idx=" .. tostring(idx)) end

    -- Restore to 1
    BfBot.Persist.SetActivePreset(sprite, 1)

    -- ---- Test 6: Options ----
    P("")
    P("  [6] Per-character options")

    BfBot.Persist.SetOpt(sprite, "skip", 0)
    if BfBot.Persist.GetOpt(sprite, "skip") == 0 then _ok("SetOpt skip=0 round-trip")
    else _nok("SetOpt skip=0 failed") end

    BfBot.Persist.SetOpt(sprite, "skip", 1)
    if BfBot.Persist.GetOpt(sprite, "skip") == 1 then _ok("SetOpt skip=1 round-trip")
    else _nok("SetOpt skip=1 failed") end

    -- ---- Test 7: Validation ----
    P("")
    P("  [7] Config validation")

    -- Corrupt config: missing fields
    local corrupt1 = { v = 1 }
    local repaired1 = BfBot.Persist._ValidateConfig(corrupt1)
    if repaired1.presets and repaired1.presets[1] then _ok("Repaired missing presets")
    else _nok("Failed to repair missing presets") end

    if repaired1.opts and repaired1.opts.skip == 1 then _ok("Repaired missing opts")
    else _nok("Failed to repair missing opts") end

    -- Corrupt config: not a table
    local repaired2 = BfBot.Persist._ValidateConfig("garbage")
    if type(repaired2) == "table" and repaired2.v == BfBot.Persist._SCHEMA_VERSION then
        _ok("Non-table input -> fresh default config")
    else _nok("Non-table input not handled") end

    -- Corrupt config: booleans in values (should be sanitized)
    local corrupt3 = BfBot.Persist.GetDefaultConfig()
    corrupt3.opts.skip = true  -- boolean! should be sanitized
    local repaired3 = BfBot.Persist._ValidateConfig(corrupt3)
    hasBool, boolPath = _hasBooleans(repaired3)
    if not hasBool then _ok("Boolean sanitization works")
    else _nok("Boolean survived at " .. tostring(boolPath)) end

    -- ---- Test 8: Marshal round-trip ----
    P("")
    P("  [8] Marshal export/import round-trip")

    -- Re-enable the test spell
    BfBot.Persist.SetSpellEnabled(sprite, 1, testResref, true)
    BfBot.Persist.SetSpellPriority(sprite, 1, testResref, 7)

    do
        local exported = BfBot.Persist._Export(sprite)
        if type(exported) ~= "table" then
            _nok("Export returned " .. type(exported))
        elseif not exported.cfg then
            -- May be empty if IsMarshallingCopy returned true (harmless in test)
            _warning("Export empty (IsMarshallingCopy may be true in test context)")
        else
            _ok("Export returned table with 'cfg' key")

            -- Import on same sprite (simulates save/load)
            BfBot.Persist._Import(sprite, exported)
            local reimported = BfBot.Persist.GetConfig(sprite)
            if not reimported then
                _nok("Import failed — config nil after import")
            else
                _ok("Import succeeded")
                local reEntry = BfBot.Persist.GetSpellConfig(sprite, 1, testResref)
                if reEntry and reEntry.on == 1 and reEntry.pri == 7 then
                    _ok("Round-trip preserved spell entry (on=1, pri=7)")
                else
                    _nok("Round-trip lost data: on=" .. tostring(reEntry and reEntry.on) ..
                         " pri=" .. tostring(reEntry and reEntry.pri))
                end
            end
        end
    end

    -- ---- Test 9: BuildQueueFromPreset ----
    P("")
    P("  [9] BuildQueueFromPreset")

    -- Ensure we have enabled spells for the queue builder
    BfBot.Persist.SetSpellEnabled(sprite, 1, testResref, true)

    local queue, qErr = BfBot.Persist.BuildQueueFromPreset(1)
    if queue then
        _ok("BuildQueueFromPreset(1) returned " .. #queue .. " entries")

        -- Validate queue entry format
        local formatOk = true
        for i, entry in ipairs(queue) do
            if type(entry.caster) ~= "number" or entry.caster < 0 or entry.caster > 5 then
                _nok("Entry " .. i .. ": bad caster=" .. tostring(entry.caster))
                formatOk = false
            end
            if type(entry.spell) ~= "string" or entry.spell == "" then
                _nok("Entry " .. i .. ": bad spell=" .. tostring(entry.spell))
                formatOk = false
            end
            local t = entry.target
            if t ~= "self" and t ~= "all" and (type(t) ~= "number" or t < 1 or t > 6) then
                _nok("Entry " .. i .. ": bad target=" .. tostring(t))
                formatOk = false
            end
        end
        if formatOk then _ok("All queue entries have valid format")
        else _warning("Some queue entries had format issues") end
    else
        -- Queue may be nil if no enabled castable spells (e.g., pure fighter in slot 0)
        _warning("BuildQueueFromPreset(1) returned nil: " .. tostring(qErr))
    end

    -- ---- Test 10: INI preferences ----
    P("")
    P("  [10] INI preferences")

    local iniOk = true
    local setOk = pcall(BfBot.Persist.SetPref, "BB_TestKey", 42)
    if setOk then
        local val = BfBot.Persist.GetPref("BB_TestKey")
        if val == 42 then _ok("INI round-trip: SetPref/GetPref = 42")
        else
            _warning("INI GetPref returned " .. tostring(val) .. " (expected 42; INI may not be writable)")
            iniOk = false
        end
    else
        _warning("INI SetPref failed (INI functions may not be available)")
        iniOk = false
    end

    -- Clean up test key
    if iniOk then pcall(BfBot.Persist.SetPref, "BB_TestKey", 0) end

    -- ---- Summary ----
    P("")

    -- Clean up synthetic resref if we created one
    if testResref == "ZZTST01" then
        local p = BfBot.Persist.GetPreset(sprite, 1)
        if p and p.spells then p.spells["ZZTST01"] = nil end
    end

    local result = _summary("Persistence")

    P("")
    P("  To test save/load persistence:")
    P("    1. Run BfBot.Test.Persist() (this test)")
    P("    2. Save the game")
    P("    3. Load the saved game")
    P("    4. Run BfBot.Test.Persist() again")
    P("    5. Config should survive the save/load cycle")
    P("")

    return result
end

-- ============================================================
-- BfBot.Test.Exec — Live execution test
-- ============================================================

--- Run the execution engine with auto-discovered buff spells.
-- Usage from console: BfBot.Test.Exec()
function BfBot.Test.Exec()
    P("")
    P("========================================")
    P("  BuffBot Execution Engine Test")
    P("========================================")

    local queue = BfBot.Test.BuildTestQueue()
    if not queue then
        P("[BuffBot] Cannot run test — no spells found.")
        return false
    end

    P("")
    P("[BuffBot] Starting execution (parallel per-caster)...")
    P("[BuffBot] Watch in-game: each caster works through their own queue simultaneously.")
    P("[BuffBot] Call BfBot.Test.ExecLog() after completion to review.")
    P("[BuffBot] Call BfBot.Exec.Stop() to abort mid-run.")
    P("")

    local ok, err = BfBot.Exec.Start(queue)
    if not ok then
        P("[BuffBot] Failed to start: " .. tostring(err))
        return false
    end

    return true
end

--- Print the execution log from the last run.
function BfBot.Test.ExecLog()
    local log = BfBot.Exec.GetLog()
    local state = BfBot.Exec.GetState()

    P("")
    P("[BuffBot] === Execution Log (state: " .. state .. ") ===")

    if #log == 0 then
        P("[BuffBot]   (no entries)")
    else
        for i, entry in ipairs(log) do
            P("[BuffBot]   " .. i .. ". [" .. entry.type .. "] " .. entry.msg)
        end
    end

    P("[BuffBot] Log file: " .. BfBot.Exec._logFile)
    P("")
end

--- Stop execution and show status.
function BfBot.Test.ExecStop()
    BfBot.Exec.Stop()
    BfBot.Test.ExecLog()
end

-- ============================================================
-- Innate Ability Diagnostics
-- ============================================================

--- Diagnostic: check SPL files on disk and known innates per party member.
function BfBot.Test.Innate()
    local P = Infinity_DisplayString

    P("")
    P("[BuffBot] === Innate Ability Diagnostics ===")
    P("")

    -- Check SPL files on disk
    local splFound, splMissing = 0, 0
    for slot = 0, 5 do
        for preset = 1, 5 do
            local resref = string.format("BFBT%d%d", slot, preset)
            local path = "override/" .. resref .. ".SPL"
            local f = io.open(path, "rb")
            if f then
                local size = f:seek("end")
                f:close()
                splFound = splFound + 1
            else
                splMissing = splMissing + 1
            end
        end
    end
    P(string.format("[BuffBot] SPL files on disk: %d found, %d missing", splFound, splMissing))
    P("")

    -- Check known innates per party member
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local name = BfBot._GetName(sprite)
            local bfbtInnates = {}
            local otherCount = 0

            -- Iterate known innate spells
            local iter = EEex_Sprite_GetKnownInnateSpellsIterator(sprite)
            if iter then
                while iter:hasNext() do
                    local spell = iter:next()
                    local resref = spell.m_spellId:get()
                    if resref and resref:sub(1, 4) == "BFBT" then
                        table.insert(bfbtInnates, resref)
                    else
                        otherCount = otherCount + 1
                    end
                end
            end

            if #bfbtInnates > 0 then
                P(string.format("[BuffBot] Slot %d (%s): %d BuffBot innates: %s  (+%d other)",
                    slot, name, #bfbtInnates, table.concat(bfbtInnates, ", "), otherCount))
            else
                P(string.format("[BuffBot] Slot %d (%s): NO BuffBot innates  (%d other innates)",
                    slot, name, otherCount))
            end

            -- Check config
            local config = BfBot.Persist.GetConfig(sprite)
            if config then
                local presetCount = 0
                for i = 1, 5 do
                    if config.presets[i] then presetCount = presetCount + 1 end
                end
                P(string.format("[BuffBot]   Config: %d presets, expected %d innates",
                    presetCount, presetCount))
            else
                P("[BuffBot]   Config: NONE (no presets configured)")
            end
        end
    end

    P("")
    P("[BuffBot] Granted flag: " .. tostring(BfBot.Innate._granted))
    P("[BuffBot] To manually grant: BfBot.Innate.Grant()")
    P("[BuffBot] To re-generate SPLs: BfBot.Innate._EnsureSPLFiles()")
    P("")
end

-- ============================================================
-- BfBot.Test.QuickCast — Quick Cast feature tests
-- ============================================================

function BfBot.Test.QuickCast()
    _reset()
    P("")
    P("========================================")
    P("  Quick Cast Tests")
    P("========================================")
    P("")

    local sprite = EEex_Sprite_GetInPortrait(0)
    if not sprite then
        _nok("No party member in slot 0")
        return _summary("Quick Cast")
    end

    -- ---- Test 1: Schema migration (v3 -> v4) ----
    P("  [1] Schema migration v3->v4")

    local oldConfig = {
        v = 3, ap = 1,
        presets = {
            [1] = { name = "Long Buffs", cat = "long", spells = {} },
            [2] = { name = "Short Buffs", cat = "short", spells = {} },
        },
        opts = { skip = 1, cheat = 1 },
    }
    local migrated = BfBot.Persist._MigrateConfig(oldConfig, 3)
    if migrated.v == 4 then _ok("Version bumped to 4")
    else _nok("Version: " .. tostring(migrated.v)) end

    if migrated.presets[1].qc == 2 then _ok("Preset 1 qc=2 (from opts.cheat=1)")
    else _nok("Preset 1 qc=" .. tostring(migrated.presets[1].qc)) end

    if migrated.presets[2].qc == 2 then _ok("Preset 2 qc=2 (from opts.cheat=1)")
    else _nok("Preset 2 qc=" .. tostring(migrated.presets[2].qc)) end

    if migrated.opts.cheat == nil then _ok("opts.cheat removed after migration")
    else _nok("opts.cheat still present: " .. tostring(migrated.opts.cheat)) end

    local oldConfig2 = {
        v = 3, ap = 1,
        presets = { [1] = { name = "P1", cat = "long", spells = {} } },
        opts = { skip = 1, cheat = 0 },
    }
    local migrated2 = BfBot.Persist._MigrateConfig(oldConfig2, 3)
    if migrated2.presets[1].qc == 0 then _ok("cheat=0 -> qc=0")
    else _nok("cheat=0 migration: qc=" .. tostring(migrated2.presets[1].qc)) end

    -- ---- Test 2: Quick Cast accessors ----
    P("")
    P("  [2] Quick Cast accessors")

    local config = BfBot.Persist.GetConfig(sprite)
    if not config then
        _nok("No config for sprite"); return _summary("Quick Cast")
    end

    BfBot.Persist.SetQuickCast(sprite, 1, 0)
    if BfBot.Persist.GetQuickCast(sprite, 1) == 0 then _ok("SetQuickCast(0) round-trip")
    else _nok("SetQuickCast(0) failed") end

    BfBot.Persist.SetQuickCast(sprite, 1, 1)
    if BfBot.Persist.GetQuickCast(sprite, 1) == 1 then _ok("SetQuickCast(1) round-trip")
    else _nok("SetQuickCast(1) failed") end

    BfBot.Persist.SetQuickCast(sprite, 1, 2)
    if BfBot.Persist.GetQuickCast(sprite, 1) == 2 then _ok("SetQuickCast(2) round-trip")
    else _nok("SetQuickCast(2) failed") end

    BfBot.Persist.SetQuickCast(sprite, 1, 5)
    if BfBot.Persist.GetQuickCast(sprite, 1) == 2 then _ok("SetQuickCast(5) clamped to 2")
    else _nok("Clamp failed: " .. tostring(BfBot.Persist.GetQuickCast(sprite, 1))) end

    BfBot.Persist.SetQuickCast(sprite, 1, -1)
    if BfBot.Persist.GetQuickCast(sprite, 1) == 0 then _ok("SetQuickCast(-1) clamped to 0")
    else _nok("Clamp failed: " .. tostring(BfBot.Persist.GetQuickCast(sprite, 1))) end

    BfBot.Persist.SetQuickCast(sprite, 1, 0)

    -- ---- Test 3: Default config has qc=0 ----
    P("")
    P("  [3] Default config qc field")

    local defCfg = BfBot.Persist.GetDefaultConfig()
    if defCfg.presets[1].qc == 0 then _ok("Default preset 1 qc=0")
    else _nok("Default preset 1 qc=" .. tostring(defCfg.presets[1].qc)) end

    if defCfg.presets[2].qc == 0 then _ok("Default preset 2 qc=0")
    else _nok("Default preset 2 qc=" .. tostring(defCfg.presets[2].qc)) end

    -- ---- Test 4: Validation repairs invalid qc ----
    P("")
    P("  [4] Validation repairs qc")

    local badConfig = BfBot.Persist.GetDefaultConfig()
    badConfig.presets[1].qc = 99
    badConfig.presets[2].qc = nil
    local repaired = BfBot.Persist._ValidateConfig(badConfig)
    if repaired.presets[1].qc == 0 then _ok("qc=99 repaired to 0")
    else _nok("qc=99 not repaired: " .. tostring(repaired.presets[1].qc)) end

    if repaired.presets[2].qc == 0 then _ok("qc=nil repaired to 0")
    else _nok("qc=nil not repaired: " .. tostring(repaired.presets[2].qc)) end

    -- ---- Test 5: Boolean safety (qc should never be boolean) ----
    P("")
    P("  [5] Boolean safety for qc")

    local boolConfig = BfBot.Persist.GetDefaultConfig()
    boolConfig.presets[1].qc = true
    BfBot.Persist._SanitizeValues(boolConfig)
    if boolConfig.presets[1].qc == 1 then _ok("Boolean qc=true sanitized to 1")
    else _nok("Boolean qc not sanitized: " .. tostring(boolConfig.presets[1].qc)) end

    -- ---- Test 6: SPL file generation ----
    P("")
    P("  [6] Cheat SPL files")

    local cheatData = BfBot.Innate._BuildCheatSPL()
    if type(cheatData) == "string" and #cheatData == 250 then
        _ok("BFBTCH.SPL: 250 bytes")
    else
        _nok("BFBTCH.SPL: " .. type(cheatData) .. " " .. tostring(cheatData and #cheatData))
    end

    if cheatData:sub(1, 4) == "SPL " then _ok("BFBTCH signature OK")
    else _nok("BFBTCH bad signature: " .. cheatData:sub(1, 4)) end

    local removerData = BfBot.Innate._BuildCheatRemoverSPL()
    if type(removerData) == "string" and #removerData == 202 then
        _ok("BFBTCR.SPL: 202 bytes")
    else
        _nok("BFBTCR.SPL: " .. type(removerData) .. " " .. tostring(removerData and #removerData))
    end

    if removerData:sub(1, 4) == "SPL " then _ok("BFBTCR signature OK")
    else _nok("BFBTCR bad signature: " .. removerData:sub(1, 4)) end

    -- ---- Summary ----
    P("")
    return _summary("Quick Cast")
end

-- ============================================================
-- Spell Search — find spells by name substring
-- Usage: BfBot.Test.FindSpell("project") or BfBot.Test.FindSpell("simul")
-- ============================================================

function BfBot.Test.FindSpell(query)
    BfBot._OpenLogAppend("buffbot_probe.log")
    P("=== Spell Search: '" .. tostring(query) .. "' ===")
    local q = string.lower(tostring(query))
    local found = 0
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local name = BfBot._GetName(sprite)
            local ok, spells = pcall(function() return BfBot.Scan.GetCastableSpells(sprite) end)
            if ok and spells then
                for _, sp in ipairs(spells) do
                    local spName = string.lower(sp.name or "")
                    local spRes = string.lower(sp.resref or "")
                    if spName:find(q, 1, true) or spRes:find(q, 1, true) then
                        found = found + 1
                        P("  " .. name .. ": " .. (sp.resref or "?") .. " = " .. (sp.name or "?")
                            .. " (src=" .. tostring(sp.source) .. " lvl=" .. tostring(sp.level) .. ")")
                    end
                end
            else
                P("  " .. name .. ": scanner error — " .. tostring(spells))
            end
        end
    end
    if found == 0 then P("  No matches found via scanner.") end
    P("=== " .. found .. " matches ===")
    BfBot._CloseLog()
end

--- Dump ALL spells for a party slot (bypasses scanner, shows everything)
--- Usage: BfBot.Test.DumpSpells(0) for party slot 0
function BfBot.Test.DumpSpells(slot)
    BfBot._OpenLogAppend("buffbot_probe.log")
    local sprite = EEex_Sprite_GetInPortrait(slot or 0)
    if not sprite then P("No sprite in slot " .. tostring(slot)); BfBot._CloseLog(); return end
    P("=== All Spells for slot " .. tostring(slot) .. " (" .. BfBot._GetName(sprite) .. ") ===")
    local function _dumpBook(btype, lbl)
        P("  [" .. lbl .. "]")
        local ok, btns = pcall(function() return sprite:GetQuickButtons(btype, false) end)
        if not ok then P("    ERROR: " .. tostring(btns)); return end
        if not btns then P("    nil"); return end
        -- Try ipairs first (ordered), fall back to manual index
        local count = 0
        pcall(function()
            local i = 0
            while true do
                local entry = btns[i]
                if not entry then break end
                local resref = "?"
                pcall(function() resref = entry.m_quickItemResRef:get() end)
                if resref == "?" then
                    pcall(function() resref = entry.m_res:get() end)
                end
                if resref == "?" then
                    pcall(function() resref = tostring(entry) end)
                end
                P("    [" .. i .. "] " .. resref)
                count = count + 1
                i = i + 1
                if i > 300 then break end
            end
        end)
        P("    total: " .. count)
    end
    _dumpBook(2, "Wizard+Priest")
    _dumpBook(4, "Innate")
    P("=== Done ===")
    BfBot._CloseLog()
end

-- ============================================================
-- Clone/Summon Probe — diagnostic for non-party sprites
-- Usage: select a clone/summon in-game, then: BfBot.Test.Probe()
-- Also scans nearby object IDs to find non-party sprites.
-- Output: buffbot_probe.log in game directory + in-game display
-- ============================================================

BfBot.Probe = {}

-- Safe field read: returns string
local function _probeField(obj, field)
    local ok, val = pcall(function() return obj[field] end)
    if not ok then return nil end
    if val == nil then return nil end
    if type(val) == "userdata" then
        local ok2, str = pcall(function() return val:get() end)
        if ok2 and str then return tostring(str) end
        return tostring(val)
    end
    return tostring(val)
end

-- Dump everything we can learn about a sprite.
-- Each section is wrapped in pcall so one crash doesn't kill the rest.
local function _dumpSprite(sprite, label)
    P("")
    P("--- " .. label .. " ---")

    -- Identity
    local sid = _probeField(sprite, "m_id") or "?"
    local sname = "?"
    pcall(function() sname = sprite:getName() end)
    P("  id=" .. sid .. " name=" .. sname)

    -- Script names (try multiple field names)
    pcall(function()
        local scripts = {"m_sName", "m_scriptName", "m_sScriptOverride", "m_sScriptClass",
            "m_sScriptRace", "m_sScriptGeneral", "m_sScriptDefault", "m_sScriptSpecific",
            "m_sAreaName", "m_sDialogRes", "m_sDeathVariable"}
        for _, f in ipairs(scripts) do
            local v = _probeField(sprite, f)
            if v and v ~= "" then P("  " .. f .. "=" .. v) end
        end
    end)

    -- Base stats
    pcall(function()
        local stats = sprite.m_baseStats
        if stats then
            local sfields = {"m_generalState", "m_nClass", "m_nRace", "m_nGender",
                "m_nAlignment", "m_nKit", "m_nSpecific", "m_nEA", "m_nGeneral",
                "m_nLevel_first", "m_nLevel_second", "m_nLevel_third",
                "m_nHitPoints", "m_nMaxHitPoints"}
            for _, f in ipairs(sfields) do
                local v = _probeField(stats, f)
                if v then P("  " .. f .. "=" .. v) end
            end
        end
    end)

    -- THE KEY UNKNOWNS: relationship / summoner fields
    P("  [Relationship fields]")
    local foundRel = 0
    local relFields = {
        "m_summoner", "m_summonerID", "m_nSummonerID",
        "m_controllerID", "m_masterID", "m_ownerId", "m_ownerID",
        "m_parentID", "m_creatorID", "m_cloneOf", "m_cloneID",
        "m_originalID", "m_bSummon", "m_bIsSummon", "m_nSummonType",
        "m_bIsClone", "m_nImageType", "m_bFamiliar", "m_familiarOwner",
        "m_allegiance", "m_nAllegiance", "m_controlledBy", "m_controller",
        "m_bInParty", "m_nInParty", "m_nPortraitSlot", "m_bSelectable",
        "m_bVisible", "m_pArea", "m_posX", "m_posY",
    }
    for _, f in ipairs(relFields) do
        pcall(function()
            local v = _probeField(sprite, f)
            if v then
                P("  ** " .. f .. "=" .. v .. " **")
                foundRel = foundRel + 1
            end
        end)
    end
    if foundRel == 0 then P("  (none found)") end

    -- Party slot check
    pcall(function()
        local inSlot = -1
        local myId = tonumber(sid)
        if myId then
            for s = 0, 5 do
                local ps = EEex_Sprite_GetInPortrait(s)
                if ps then
                    local psid = _probeField(ps, "m_id")
                    if tonumber(psid) == myId then inSlot = s; break end
                end
            end
        end
        P("  partySlot=" .. (inSlot >= 0 and tostring(inSlot) or "NONE"))
    end)

    -- Active effects (first 30, highlight interesting opcodes)
    P("  [Active effects]")
    local effCount = 0
    pcall(function()
        EEex_Utility_IterateCPtrList(sprite.m_timedEffectList, function(eff)
            effCount = effCount + 1
            if effCount <= 30 then
                local op = _probeField(eff, "m_effectId") or "?"
                local src = "?"
                pcall(function() src = eff.m_sourceRes:get() end)
                local p1 = _probeField(eff, "m_effectAmount") or "?"
                local p2 = _probeField(eff, "m_dWFlags") or "?"
                local opN = tonumber(op) or -1
                local mark = ""
                if opN == 158 or opN == 260 or opN == 228 or opN == 402 then mark = " <<<" end
                P("    #" .. effCount .. " op=" .. op .. " src=" .. src
                    .. " p1=" .. p1 .. " p2=" .. p2 .. mark)
            end
        end)
    end)
    P("  total effects: " .. effCount)

    -- Spellbook — use BfBot.Scan.GetCastableSpells (safe, already tested)
    -- instead of raw GetQuickButtons which crashes on pairs()
    P("  [Spellbook]")
    pcall(function()
        local spells, count = BfBot.Scan.GetCastableSpells(sprite)
        if spells then
            P("  castable spells: " .. tostring(count))
            local shown = 0
            for _, sp in ipairs(spells) do
                if shown < 10 then
                    P("    " .. (sp.resref or "?") .. " = " .. (sp.name or "?")
                        .. " (lvl=" .. tostring(sp.level) .. ")")
                    shown = shown + 1
                end
            end
            if count > 10 then P("    ... (+" .. (count - 10) .. " more)") end
        else
            P("  GetCastableSpells returned nil")
        end
    end)

    -- UDAux
    pcall(function()
        local aux = EEex_GetUDAux(sprite)
        P("  UDAux: accessible (type=" .. type(aux) .. ")")
    end)

    -- Spell states (sample 0-79)
    pcall(function()
        local states = {}
        for i = 0, 79 do
            local ssOk, active = pcall(function() return sprite:getSpellState(i) end)
            if ssOk and active then table.insert(states, i) end
        end
        if #states > 0 then P("  SPLSTATEs: " .. table.concat(states, ",")) end
    end)

    -- Test action queuing
    pcall(function()
        local aqOk = pcall(function()
            EEex_Action_QueueResponseStringOnAIBase('DisplayStringHead(Myself,14674)', sprite)
        end)
        P("  ActionQueue: " .. (aqOk and "OK" or "FAILED"))
    end)
end

-- Find non-party sprites by scanning object IDs near party member IDs
local function _scanNearbyObjects()
    P("")
    P("=== Scanning nearby object IDs ===")
    local partyIds = {}
    for slot = 0, 5 do
        local sp = EEex_Sprite_GetInPortrait(slot)
        if sp then
            local id = tonumber(_probeField(sp, "m_id"))
            if id then table.insert(partyIds, id) end
        end
    end
    if #partyIds == 0 then P("  No party members found"); return end

    local minId, maxId = partyIds[1], partyIds[1]
    for _, id in ipairs(partyIds) do
        if id < minId then minId = id end
        if id > maxId then maxId = id end
    end
    P("  Party ID range: " .. minId .. " - " .. maxId)

    -- Build party ID lookup
    local isParty = {}
    for _, id in ipairs(partyIds) do isParty[id] = true end

    -- Scan a wider range around party IDs
    local nonParty = {}
    for testId = math.max(1, minId - 20), maxId + 50 do
        if not isParty[testId] then
            local ok, obj = pcall(function() return EEex_GameObject_Get(testId) end)
            if ok and obj then
                local oname = "?"
                pcall(function() oname = obj:getName() end)
                if oname and oname ~= "" and oname ~= "?" then
                    table.insert(nonParty, {id = testId, obj = obj, name = oname})
                    P("  ** NON-PARTY id=" .. testId .. " name=" .. oname .. " **")
                end
            end
        end
    end
    return nonParty
end

-- Deep probe of m_lVertSort objects — v5 (SAFE: no EEex_PtrToUD)
-- v4 crashed: the list values are object IDs, not memory pointers.
-- EEex_PtrToUD on an ID causes a native segfault. Use EEex_GameObject_Get instead.
local function _probeAreaObjects()
    P("")
    P("=== Deep probe of area objects (m_lVertSort) v5 ===")

    local area = nil
    pcall(function()
        local sp = EEex_Sprite_GetInPortrait(0)
        if sp then area = sp.m_pArea end
    end)
    if not area then P("  Cannot get area object"); return end

    local vertSort = nil
    pcall(function() vertSort = area.m_lVertSort end)
    if not vertSort then P("  Cannot get m_lVertSort"); return end

    -- Collect all values from the list
    local ids = {}
    pcall(function()
        EEex_Utility_IterateCPtrList(vertSort, function(obj)
            -- Extract numeric value (could be number or userdata containing a number)
            local val = nil
            if type(obj) == "number" then
                val = obj
            else
                -- Try tonumber on tostring (worked in v3: "131139536")
                pcall(function() val = tonumber(tostring(obj)) end)
            end
            if val then table.insert(ids, val) end
        end)
    end)
    P("  Extracted " .. #ids .. " values from m_lVertSort")
    if #ids > 0 then
        P("  First 5: " .. table.concat({unpack(ids, 1, math.min(5, #ids))}, ", "))
    end

    -- Try EEex_GameObject_Get on each value (safe — returns nil if not found)
    P("")
    P("  [Looking up objects via EEex_GameObject_Get]")
    local creatures = {}
    local foundCount = 0
    local failCount = 0

    -- Build party ID lookup
    local partyIds = {}
    for s = 0, 5 do
        pcall(function()
            local ps = EEex_Sprite_GetInPortrait(s)
            if ps then partyIds[ps.m_id] = s end
        end)
    end

    for i, id in ipairs(ids) do
        local obj = nil
        local ok = pcall(function() obj = EEex_GameObject_Get(id) end)
        if ok and obj then
            foundCount = foundCount + 1
            local name = nil
            pcall(function() name = obj:getName() end)
            local oid = _probeField(obj, "m_id")
            local otype = _probeField(obj, "m_objectType")

            if name and name ~= "" then
                local oidNum = tonumber(oid)
                local slot = oidNum and partyIds[oidNum]
                if slot then
                    P("  [" .. i .. "] PARTY slot " .. slot .. ": " .. name
                        .. " (id=" .. (oid or "?") .. " type=" .. (otype or "?") .. ")")
                else
                    P("  [" .. i .. "] ** NON-PARTY: " .. name
                        .. " (id=" .. (oid or "?") .. " type=" .. (otype or "?") .. ") **")
                    table.insert(creatures, {obj = obj, name = name, idx = i, id = id})
                end
            else
                -- Non-creature object (door, trigger, etc.) — just count type
                if i <= 5 then
                    P("  [" .. i .. "] object: id=" .. (oid or "?")
                        .. " type=" .. (otype or "?") .. " name=<none>")
                end
            end
        else
            failCount = failCount + 1
        end
    end

    P("")
    P("  EEex_GameObject_Get: " .. foundCount .. " found, " .. failCount .. " failed")
    P("  Non-party creatures: " .. #creatures)

    -- Full dump of each non-party creature
    for _, c in ipairs(creatures) do
        _dumpSprite(c.obj, "AREA CREATURE: " .. c.name .. " (listVal=" .. c.id .. ")")
    end

    return creatures
end

-- Probe area access — globals, area fields, and deep object probe
local function _probeAreaAccess()
    P("")
    P("=== Area access probes ===")

    -- Try global functions
    local globalAttempts = {
        {"EEex_GetCurrentArea", function() return EEex_GetCurrentArea() end},
        {"EEex_Area_GetCurrent", function() return EEex_Area_GetCurrent() end},
        {"g_pBaldurChitin", function() return g_pBaldurChitin end},
    }
    for _, a in ipairs(globalAttempts) do
        pcall(function()
            local val = a[2]()
            if val ~= nil then
                P("  ** " .. a[1] .. " = " .. tostring(val) .. " (type=" .. type(val) .. ") **")
            end
        end)
    end

    -- Deep probe the area objects
    return _probeAreaObjects()
end

--- Main probe: dumps party baseline, probes area objects, finds creatures
function BfBot.Probe.Run()
    BfBot._OpenLogAppend("buffbot_probe.log")
    P("=== BuffBot Clone/Summon Probe v5 ===")

    -- 1. Party baseline (slot 0) — abbreviated
    local baseline = EEex_Sprite_GetInPortrait(0)
    if baseline then
        local bname = BfBot._GetName(baseline)
        local bid = _probeField(baseline, "m_id") or "?"
        P("Party slot 0: " .. bname .. " (id=" .. bid .. ")")
    end

    -- 2. Area object deep probe (the main event)
    --    Iterates m_lVertSort, identifies creatures, dumps non-party ones
    local creatures = _probeAreaAccess()

    if not creatures or #creatures == 0 then
        P("")
        P("No non-party creatures found in area.")
        P("Make sure summons/clones are alive in the current area.")
    end

    P("")
    P("=== Probe complete — see buffbot_probe.log ===")
    BfBot._CloseLog()
end

--- Quick probe: just area objects, no party baseline
function BfBot.Probe.Quick()
    BfBot._OpenLogAppend("buffbot_probe.log")
    P("=== Quick Probe v5 ===")
    _probeAreaObjects()
    P("=== Done ===")
    BfBot._CloseLog()
end

-- ============================================================
-- Module loaded
-- ============================================================

-- No output at load time — Infinity_DisplayString may not be available yet
