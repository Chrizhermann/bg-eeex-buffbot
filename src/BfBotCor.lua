-- ============================================================
-- BfBotCor.lua — BuffBot Core Logic
-- Spell Scanner (BfBot.Scan), Buff Classifier (BfBot.Class),
-- and Execution Engine (BfBot.Exec)
-- ============================================================

-- Root namespace
BfBot = BfBot or {}
BfBot.Scan = {}
BfBot.Class = {}
BfBot.Exec = {}
BfBot.Persist = {}
BfBot.VERSION = "0.3.0-dev"

-- ============================================================
-- Logging
-- ============================================================

BfBot._logLevel = 2 -- 0=off, 1=errors, 2=warnings, 3=verbose

-- Log file path (game directory)
BfBot._logFile = "buffbot_test.log"
BfBot._logHandle = nil

-- Open log file for writing (call once before test runs)
function BfBot._OpenLog()
    local h, err = io.open(BfBot._logFile, "w")
    if h then
        BfBot._logHandle = h
        h:write("=== BuffBot Log " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n")
    end
end

-- Close log file
function BfBot._CloseLog()
    if BfBot._logHandle then
        BfBot._logHandle:close()
        BfBot._logHandle = nil
    end
end

-- Open log file in append mode (doesn't truncate)
function BfBot._OpenLogAppend(filename)
    BfBot._CloseLog()
    local fname = filename or BfBot._logFile
    local h, err = io.open(fname, "a")
    if h then
        BfBot._logHandle = h
        h:write("\n=== BuffBot Log " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n")
    end
    return h ~= nil
end

-- Output function: writes to log file AND shows in-game
function BfBot._Print(msg)
    local s = tostring(msg)
    Infinity_DisplayString(s)
    if BfBot._logHandle then
        BfBot._logHandle:write(s .. "\n")
        BfBot._logHandle:flush()
    end
end

function BfBot._Error(msg)
    if BfBot._logLevel >= 1 then
        BfBot._Print("[BuffBot ERROR] " .. tostring(msg))
    end
end

function BfBot._Warn(msg)
    if BfBot._logLevel >= 2 then
        BfBot._Print("[BuffBot WARN] " .. tostring(msg))
    end
end

function BfBot._Log(msg)
    if BfBot._logLevel >= 3 then
        BfBot._Print("[BuffBot] " .. tostring(msg))
    end
end

-- ============================================================
-- Shared Utilities
-- ============================================================

--- Get character name safely. Used by both Exec and UI modules.
function BfBot._GetName(sprite)
    if not sprite then return "?" end
    local ok, name = pcall(function() return sprite:getName() end)
    if ok and name and name ~= "" then return name end
    return "?"
end

-- ============================================================
-- Field Name Resolution
-- Uncertain field names on EEex userdata types are resolved
-- at runtime by BfBot.Test.CheckFields(). Until then, use
-- the primary (most likely) names from architecture docs.
-- ============================================================

BfBot._fields = {
    -- Spell_ability_st fields
    fb_count = "effectCount",       -- fallback: "featureBlockCount"
    fb_start = "startingEffect",    -- fallback: "featureBlockOffset"
    friendly_flags = "type",        -- bit 10 (0x0400) = friendly

    -- Item_effect_st fields (feature blocks from SPL data)
    fb_opcode = "effectID",
    fb_timing = "durationType",
    fb_duration = "duration",
    fb_param1 = "effectAmount",
    fb_param2 = "dwFlags",
    fb_target = "targetType",
    fb_res = "res",                 -- fallback: "resource"; call :get()
    fb_special = "special",

    -- Resolved flag: set to true after CheckFields succeeds
    _resolved = false,
}

-- ============================================================
-- Caches
-- ============================================================

BfBot._cache = {
    -- Classification cache: resref -> ClassResult
    -- Never invalidated within a session (SPL data is static)
    class = {},

    -- Scan cache: spriteID -> { spells = {...}, timestamp = number }
    -- Invalidated per-sprite on spell list change events
    scan = {},
}

-- User override table: resref -> boolean|nil
BfBot._overrides = {}

-- ============================================================
-- Opcode Score Tables
-- Source: docs/spell-system-and-buff-classification.md §2.3
-- Verified against IESDP BG(2)EE opcode reference.
-- Opcodes not in any table score 0 (neutral).
-- ============================================================

BfBot.Class._OPCODE_SCORES = {}

-- Helper to populate score table from an array of opcodes
local function _addOpcodes(tbl, opcodes, score)
    for _, op in ipairs(opcodes) do
        tbl[op] = score
    end
end

-- Strong buff opcodes: +2 each
_addOpcodes(BfBot.Class._OPCODE_SCORES, {
    -- Stat modifiers
    0,   -- AC vs. Damage Type
    1,   -- Attacks Per Round
    6,   -- Charisma
    10,  -- Constitution
    15,  -- Dexterity
    19,  -- Intelligence
    22,  -- Luck (cumulative)
    44,  -- Strength
    49,  -- Wisdom
    54,  -- THAC0
    167, -- THAC0 (Missiles)
    233, -- Proficiency
    278, -- To Hit
    284, -- Melee THAC0
    285, -- Melee Damage
    286, -- Missile Damage
    301, -- Critical Hit
    305, -- THAC0 (Off-Hand)
    306, -- THAC0 (On-Hand)
    325, -- Save vs. All
    345, -- Enchantment Bonus
    346, -- Save vs. School

    -- Resistances
    27,  -- Acid Resistance
    28,  -- Cold Resistance
    29,  -- Electricity Resistance
    30,  -- Fire Resistance
    31,  -- Magic Damage Resistance
    84,  -- Magical Fire Resistance
    85,  -- Magical Cold Resistance
    86,  -- Slashing Resistance
    87,  -- Crushing Resistance
    88,  -- Piercing Resistance
    89,  -- Missiles Resistance

    -- Saving throws
    33,  -- Save vs. Death
    34,  -- Save vs. Wands
    35,  -- Save vs. Petrification/Polymorph
    36,  -- Save vs. Breath
    37,  -- Save vs. Spells

    -- Buff states and protections
    16,  -- Haste
    18,  -- Maximum HP
    20,  -- Invisibility
    65,  -- Blur
    69,  -- Non-Detection
    83,  -- Protection from Projectile
    98,  -- Regeneration
    100, -- Protection from Creature Type
    101, -- Protection from Opcode
    102, -- Protection from Spell Levels
    119, -- Mirror Image
    120, -- Protection from Melee Weapons
    129, -- Aid (state)
    130, -- Bless (state)
    131, -- Positive Chant (state)
    132, -- Raise STR/CON/DEX Non-Cumulative
    133, -- Luck Non-Cumulative
    153, -- Sanctuary
    155, -- Minor Globe of Invulnerability
    156, -- Protection from Normal Missiles
    163, -- Free Action
    166, -- Magic Resistance
    218, -- Stoneskin
    282, -- Set Spell State (SPLSTATE)
    314, -- Golem Stoneskin
    317, -- Haste 2
    328, -- Set Extended/Spell State
    335, -- Seven Eyes

    -- Spell protection and bounce
    197, -- Bounce (by Projectile)
    198, -- Bounce (by Opcode)
    199, -- Bounce (by Power Level)
    200, -- Bounce (by Power Level, decrementing)
    201, -- Immunity (by Power Level, decrementing)
    202, -- Bounce (by School)
    203, -- Bounce (by Secondary Type)
    204, -- Protection (by School)
    205, -- Protection (by Secondary Type)
    206, -- Protection from Spell
    207, -- Bounce (by Resource)
    212, -- Freedom
    223, -- Immunity (by School, decrementing)
    226, -- Immunity (by Secondary Type, decrementing)
    227, -- Bounce (by School, decrementing)
    228, -- Bounce (by Secondary Type, decrementing)
    259, -- Spell Trap (by Power Level)
    292, -- Backstab Protection
    299, -- Chaos Shield
    302, -- Can Use Any Item
    310, -- Protection from Timestop
    318, -- Protection from Resource
    324, -- Immunity to Resource and Message

    -- Skill modifiers
    21,  -- Lore
    59,  -- Stealth
    90,  -- Open Locks
    91,  -- Find Traps
    92,  -- Pick Pockets
    190, -- Attack Speed
    191, -- Casting Level
    262, -- Visual Range
    275, -- Hide in Shadows
    276, -- Detect Illusion
    277, -- Set Traps
}, 2)

-- Weak buff opcodes: +1 each
_addOpcodes(BfBot.Class._OPCODE_SCORES, {
    17,  -- Current HP (Healing)
    42,  -- Wizard Spell Slots
    62,  -- Priest Spell Slots
    63,  -- Infravision
    111, -- Create Magical Weapon
    171, -- Give Ability
    188, -- Aura Cleansing
    189, -- Casting Time Modifier
    250, -- Damage Modifier
    261, -- Restore Lost Spells
}, 1)

-- Strong offensive opcodes: -3 each
_addOpcodes(BfBot.Class._OPCODE_SCORES, {
    5,   -- Charm
    12,  -- Damage
    13,  -- Instant Death
    24,  -- Horror (Panic)
    25,  -- Poison
    38,  -- Silence
    39,  -- Sleep
    40,  -- Slow
    45,  -- Stun
    55,  -- Kill Creature Type
    74,  -- Blindness
    76,  -- Feeblemindedness
    78,  -- Disease
    80,  -- Deafness
    109, -- Hold
    128, -- Confusion
    134, -- Petrification
    157, -- Web
    175, -- Hold (II)
    185, -- Hold (II, variant)
    209, -- Kill 60HP
    210, -- Stun 90HP
    211, -- Imprisonment
    213, -- Maze
    216, -- Level Drain
    217, -- Unconsciousness 20HP
    238, -- Disintegrate
    241, -- Control Creature
    264, -- Drop Weapons in Panic
    333, -- Static Charge
}, -3)

-- Summoning opcodes: -2 each
_addOpcodes(BfBot.Class._OPCODE_SCORES, {
    67,  -- Summon Creature
    151, -- Replace Creature
    331, -- Random Monster Summoning
}, -2)

-- MSECTYPE score table
-- Source: docs/spell-system-and-buff-classification.md §2.6
BfBot.Class._MSECTYPE_SCORES = {
    [0]  = 0,  -- None
    [1]  = 2,  -- Spell Protections
    [2]  = 2,  -- Specific Protections
    [3]  = 2,  -- Illusionary Protections
    [4]  = -1, -- Magic Attack
    [5]  = -1, -- Divination Attack
    [6]  = 0,  -- Conjuration
    [7]  = 2,  -- Combat Protections
    [8]  = 0,  -- Contingency
    [9]  = 0,  -- Battleground
    [10] = -3, -- Offensive Damage
    [11] = -3, -- Disabling
    [12] = 0,  -- Combination
    [13] = 0,  -- Non-Combat
}

-- Neutral opcodes (visual, sound, infrastructure) — used by
-- _IsGameplayOpcode to filter what counts for duration calc.
-- These don't affect scoring either (they're not in _OPCODE_SCORES).
BfBot.Class._NEUTRAL_OPCODES = {}
_addOpcodes(BfBot.Class._NEUTRAL_OPCODES, {
    -- Color and glow effects
    7, 8, 9, 41, 50, 51, 52, 53, 61, 66,
    -- Casting graphics, animations
    114, 138, 140, 141, 184, 215,
    -- Text display, sound effects
    139, 174, 327, 330,
    -- Portrait icon management
    142, 169, 240,
    -- Avatar/animation effects
    271, 287, 291, 296, 315, 336, 339, 342,
    -- Effect removal / self-cleanup
    321, 337, 220, 221, 229, 230, 266,
    -- Script/variable management
    82, 99, 103, 107, 187, 265, 309,
    -- Spell casting infrastructure
    146, 147, 148, 177, 182, 183, 232, 234, 272, 283,
}, true)

-- ============================================================
-- BfBot.Class — Internal Helpers
-- ============================================================

--- Access a feature block by index using pointer arithmetic.
--- Confirmed pattern from architecture-proposal.md R1 resolution.
function BfBot.Class._GetFeatureBlock(header, ability, index)
    local startIdx = ability[BfBot._fields.fb_start]
    local ptr = EEex_UDToPtr(header)
        + header.effectsOffset
        + Item_effect_st.sizeof * (startIdx + index)
    return EEex_PtrToUD(ptr, "Item_effect_st")
end

--- Iterate all feature blocks for an ability.
--- fn(fb, index) is called for each block. Return true from fn to stop early.
--- Wraps iteration in pcall to handle bad pointers gracefully.
function BfBot.Class._IterateFeatureBlocks(header, ability, fn)
    local countField = BfBot._fields.fb_count
    local count = ability[countField]
    if not count or count <= 0 then return end

    for i = 0, count - 1 do
        local ok, fb = pcall(BfBot.Class._GetFeatureBlock, header, ability, i)
        if ok and fb then
            local stop = fn(fb, i)
            if stop then return end
        else
            BfBot._Warn("Feature block access failed at index " .. i
                .. ": " .. tostring(fb))
        end
    end
end

--- Check if an opcode is gameplay-affecting (not visual/infrastructure).
--- Used to filter which effects contribute to duration calculation.
function BfBot.Class._IsGameplayOpcode(opcode)
    return not BfBot.Class._NEUTRAL_OPCODES[opcode]
end

-- ============================================================
-- BfBot.Class — Scoring Functions
-- ============================================================

--- Step 1: Compute targeting score from ability flags and target type.
--- Returns score contribution and friendly flag value.
function BfBot.Class.ScoreTargeting(ability)
    local score = 0
    local friendlyFlag = false

    -- Check friendly flag: bit 10 of ability.type
    local flagsField = BfBot._fields.friendly_flags
    local flagsVal = ability[flagsField]
    if flagsVal and type(flagsVal) == "number" then
        friendlyFlag = bit.band(flagsVal, 0x0400) ~= 0
        if friendlyFlag then
            score = score + 5
        end
    end

    -- Check target type
    local targetType = ability.actionType
    if targetType then
        if targetType == 5 or targetType == 7 then
            -- Self-only target: buff signal
            score = score + 3
        elseif targetType == 3 then
            -- Dead actor target: resurrection, not a buff
            score = score - 5
        end
        -- targetType 1 (living) and 4 (area) add 0
    end

    return score, friendlyFlag
end

--- Step 2: Compute MSECTYPE score from SPL header secondary type.
function BfBot.Class.ScoreMSECTYPE(header)
    local msectype = header.secondaryType
    if not msectype then return 0 end
    return BfBot.Class._MSECTYPE_SCORES[msectype] or 0
end

--- Step 3: Scan all feature blocks and compute opcode score.
--- Also extracts SPLSTATE IDs, self-replace flag, and AoE signals.
function BfBot.Class.ScoreOpcodes(header, ability, resref)
    local score = 0
    local splstates = {}
    local selfReplace = false
    local fbAoE = false

    BfBot.Class._IterateFeatureBlocks(header, ability, function(fb, _)
        local opcode = fb[BfBot._fields.fb_opcode]
        if not opcode then return end

        -- Opcode scoring
        local opScore = BfBot.Class._OPCODE_SCORES[opcode]
        if opScore then
            score = score + opScore
        end

        -- Extract SPLSTATE IDs from opcodes 282 and 328
        if opcode == 282 or opcode == 328 then
            local stateID = fb[BfBot._fields.fb_param2]
            if stateID and stateID > 0 then
                table.insert(splstates, stateID)
            end
        end

        -- Detect self-replace: opcode 321 (Remove Effects by Resource)
        -- targeting the spell's own resref
        if opcode == 321 and resref then
            local ok, resVal = pcall(function()
                return fb[BfBot._fields.fb_res]:get()
            end)
            if ok and resVal == resref then
                selfReplace = true
            end
        end

        -- AoE signal from feature block target type
        local fbTarget = fb[BfBot._fields.fb_target]
        if fbTarget then
            -- 4 = everyone, 6 = caster's group
            if fbTarget == 4 or fbTarget == 6 then
                fbAoE = true
            end
        end
    end)

    return score, {
        splstates = splstates,
        selfReplace = selfReplace,
        fbAoE = fbAoE,
    }
end

-- ============================================================
-- BfBot.Class — Duration
-- ============================================================

--- Compute effective duration from feature blocks.
--- Returns duration in seconds (-1 for permanent) and type string.
function BfBot.Class.GetDuration(header, ability)
    local maxDuration = 0
    local hasPermanent = false

    BfBot.Class._IterateFeatureBlocks(header, ability, function(fb, _)
        local opcode = fb[BfBot._fields.fb_opcode]
        if not opcode or not BfBot.Class._IsGameplayOpcode(opcode) then
            return
        end

        local rawTiming = fb[BfBot._fields.fb_timing]
        if not rawTiming then return end
        -- EEex reads durationType as a word/dword; actual timing mode
        -- is the low byte only (IESDP: 1 byte at offset 0x000C)
        local timing = bit.band(rawTiming, 0xFF)

        if timing == 1 or timing == 4 or timing == 9 then
            -- Permanent (until dispelled, or absolute permanent)
            hasPermanent = true
        elseif timing == 0 or timing == 3 then
            -- Timed: use duration field (seconds)
            local dur = fb[BfBot._fields.fb_duration]
            if dur and dur > maxDuration then
                maxDuration = dur
            end
        end
    end)

    if hasPermanent then
        return -1, "permanent"
    end
    return maxDuration, "timed"
end

--- Categorize a duration into "long", "short", "instant", or "permanent".
function BfBot.Class.GetDurationCategory(durationSeconds)
    local threshold = 300 -- 5 turns = 300 seconds (configurable via INI later)
    if durationSeconds == -1 then return "permanent" end
    if durationSeconds == 0 then return "instant" end
    if durationSeconds >= threshold then return "long" end
    return "short"
end

-- ============================================================
-- BfBot.Class — AoE and Targeting
-- ============================================================

--- Determine if a spell is AoE (party-wide) or single-target.
--- For BuffBot: AoE = "cast once, covers party". Self-only = "cast once on self" (not AoE).
function BfBot.Class.IsAoE(ability, fbAoE)
    local targetType = ability.actionType
    -- Self-only spells are never AoE for buff purposes
    if targetType == 5 or targetType == 7 then return false end
    -- Area target type = AoE
    if targetType == 4 then return true end
    -- For living-actor targeting, count 0 means area delivery
    if targetType == 1 and ability.actionCount == 0 then return true end
    -- Feature block signals AoE
    if fbAoE then return true end
    return false
end

--- Determine the smart default target for a spell.
function BfBot.Class.GetDefaultTarget(ability, isAoE)
    local targetType = ability.actionType
    -- Self-only spells
    if targetType == 5 or targetType == 7 then return "s" end
    -- Everything else defaults to party
    return "p"
end

-- ============================================================
-- BfBot.Class — Override Management
-- ============================================================

--- Check if a spell has a user override classification.
function BfBot.Class.GetOverride(resref)
    return BfBot._overrides[resref]
end

--- Set a user override classification for a spell.
function BfBot.Class.SetOverride(resref, value)
    BfBot._overrides[resref] = value
    -- Invalidate classification cache for this resref
    BfBot._cache.class[resref] = nil
end

-- ============================================================
-- BfBot.Class — Main Classification Function
-- ============================================================

--- Full classification of a spell. Returns a ClassResult table.
--- Results are cached by resref (SPL data does not change in-session).
function BfBot.Class.Classify(resref, header, ability)
    -- Check cache
    local cached = BfBot._cache.class[resref]
    if cached then return cached end

    local result = {}
    result.msectype = header.secondaryType or 0

    -- Check user override
    local override = BfBot.Class.GetOverride(resref)
    if override ~= nil then
        result.isBuff = override
        result.isAmbiguous = false
        result.overridden = true
        result.score = override and 10 or -10
        result.targetScore = 0
        result.msecScore = 0
        result.opcodeScore = 0
        result.splstates = {}
        result.selfReplace = false
        result.friendlyFlag = false

        -- Still compute duration, AoE, defaultTarget (useful regardless)
        result.duration, _ = BfBot.Class.GetDuration(header, ability)
        result.durCat = BfBot.Class.GetDurationCategory(result.duration)
        result.isAoE = BfBot.Class.IsAoE(ability, false)
        result.defaultTarget = BfBot.Class.GetDefaultTarget(ability, result.isAoE)

        BfBot._cache.class[resref] = result
        return result
    end

    result.overridden = false

    -- Step 1: Targeting score
    result.targetScore, result.friendlyFlag = BfBot.Class.ScoreTargeting(ability)

    -- Step 2: MSECTYPE score
    result.msecScore = BfBot.Class.ScoreMSECTYPE(header)

    -- Step 3: Opcode score + extract metadata
    local opcodeExtras
    result.opcodeScore, opcodeExtras = BfBot.Class.ScoreOpcodes(header, ability, resref)
    result.splstates = opcodeExtras.splstates
    result.selfReplace = opcodeExtras.selfReplace

    -- Total score
    result.score = result.targetScore + result.msecScore + result.opcodeScore

    -- Step 4: Threshold
    if result.score >= 3 then
        result.isBuff = true
        result.isAmbiguous = false
    elseif result.score <= -3 then
        result.isBuff = false
        result.isAmbiguous = false
    else
        -- Ambiguous: lean buff if score >= 0
        result.isAmbiguous = true
        result.isBuff = (result.score >= 0)
    end

    -- Duration
    result.duration, _ = BfBot.Class.GetDuration(header, ability)
    result.durCat = BfBot.Class.GetDurationCategory(result.duration)

    -- AoE
    result.isAoE = BfBot.Class.IsAoE(ability, opcodeExtras.fbAoE)

    -- Default target
    result.defaultTarget = BfBot.Class.GetDefaultTarget(ability, result.isAoE)

    -- Cache and return
    BfBot._cache.class[resref] = result
    return result
end

-- ============================================================
-- BfBot.Scan — Spell Scanner
-- ============================================================

--- Internal: Build a SpellEntry from button data and SPL header.
local function _buildSpellEntry(sprite, resref, count, icon, nameRef, disabled, header, ability)
    local name = ""
    if nameRef and nameRef ~= 0 and nameRef ~= -1 then
        name = Infinity_FetchString(nameRef)
    end
    if (not name or name == "") and header then
        local ok, fetchedName = pcall(function()
            return Infinity_FetchString(header.genericName)
        end)
        if ok and fetchedName and fetchedName ~= "" then
            name = fetchedName
        end
    end
    if not name or name == "" then
        name = resref
    end

    -- Get spell type from header
    local spellType = 0
    if header then
        spellType = header.itemType or 0
    end

    -- Get icon from ability if not from button data
    if (not icon or icon == "") and ability then
        local ok, abilIcon = pcall(function()
            return ability.quickSlotIcon:get()
        end)
        if ok and abilIcon and abilIcon ~= "" then
            icon = abilIcon
        end
    end

    -- Classify
    local classResult = nil
    if header and ability then
        local ok, result = pcall(BfBot.Class.Classify, resref, header, ability)
        if ok then
            classResult = result
        else
            BfBot._Warn("Classification failed for " .. resref .. ": " .. tostring(result))
        end
    end

    return {
        resref = resref,
        name = name,
        icon = icon or "",
        count = count or 0,
        level = header and header.spellLevel or 0,
        spellType = spellType,
        disabled = (disabled and disabled ~= 0) or false,
        class = classResult,
    }
end

--- Scan all castable spells for a party member.
--- Returns a table keyed by resref and total spell count.
function BfBot.Scan.GetCastableSpells(sprite)
    if not sprite then return {}, 0 end

    -- Check scan cache
    local spriteID = nil
    local ok, id = pcall(function() return sprite.m_id end)
    if ok and id then
        spriteID = id
        local cached = BfBot._cache.scan[spriteID]
        if cached then
            return cached.spells, cached.count
        end
    end

    local spells = {}
    local count = 0
    local seen = {}

    -- Helper: process a button list from GetQuickButtons
    local function processButtonList(buttonList)
        if not buttonList then return end

        -- Wrap iteration in pcall so list is ALWAYS freed even on error
        local iterOk, iterErr = pcall(function()
            EEex_Utility_IterateCPtrList(buttonList, function(bd)
                -- Extract resref
                local resOk, resref = pcall(function()
                    return bd.m_abilityId.m_res:get()
                end)
                if not resOk or not resref or resref == "" then return end

                -- Skip duplicates (same spell from different button entries)
                if seen[resref] then
                    -- Accumulate count for duplicate entries
                    if spells[resref] then
                        local bdCount = 0
                        pcall(function() bdCount = bd.m_count end)
                        if bdCount > 0 then
                            spells[resref].count = spells[resref].count + bdCount
                        else
                            spells[resref].count = spells[resref].count + 1
                        end
                    end
                    return
                end
                seen[resref] = true

                -- Extract button data fields
                local bdCount = 0
                pcall(function() bdCount = bd.m_count end)
                if bdCount <= 0 then bdCount = 1 end -- at least 1 if it's in the list

                local bdIcon = ""
                pcall(function() bdIcon = bd.m_icon:get() end)

                local bdName = 0
                pcall(function() bdName = bd.m_name end)

                local bdDisabled = 0
                pcall(function() bdDisabled = bd.m_bDisabled end)

                -- Load SPL header
                local header = EEex_Resource_Demand(resref, "SPL")
                if not header then
                    BfBot._Warn("Cannot load SPL for " .. resref)
                    return
                end

                -- Get caster level and ability
                local casterLevel = 1
                local clOk, cl = pcall(function()
                    return sprite:getCasterLevelForSpell(resref, true)
                end)
                if clOk and cl and cl > 0 then
                    casterLevel = cl
                end

                local ability = header:getAbilityForLevel(casterLevel)
                if not ability then
                    ability = header:getAbility(0)
                end
                if not ability then
                    BfBot._Warn("No ability for " .. resref .. " at level " .. casterLevel)
                    return
                end

                -- Build entry
                local entry = _buildSpellEntry(
                    sprite, resref, bdCount, bdIcon, bdName, bdDisabled,
                    header, ability
                )
                spells[resref] = entry
                count = count + 1
            end)
        end)

        -- Always free the list, even if iteration errored
        pcall(EEex_Utility_FreeCPtrList, buttonList)

        if not iterOk then
            BfBot._Warn("Button list iteration failed: " .. tostring(iterErr))
        end
    end

    -- Get memorized wizard + priest spells (type 2)
    local spellOk, spellList = pcall(function()
        return sprite:GetQuickButtons(2, false)
    end)
    if spellOk and spellList then
        processButtonList(spellList)
    else
        BfBot._Warn("GetQuickButtons(2) failed: " .. tostring(spellList))
    end

    -- Get innate abilities (type 4)
    local innateOk, innateList = pcall(function()
        return sprite:GetQuickButtons(4, false)
    end)
    if innateOk and innateList then
        processButtonList(innateList)
    else
        BfBot._Warn("GetQuickButtons(4) failed: " .. tostring(innateList))
    end

    -- Cache results
    if spriteID then
        BfBot._cache.scan[spriteID] = {
            spells = spells,
            count = count,
        }
    end

    return spells, count
end

--- Scan all party members.
--- Returns table keyed by slot (0-5), each containing GetCastableSpells result.
function BfBot.Scan.ScanParty()
    local results = {}
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local spells, count = BfBot.Scan.GetCastableSpells(sprite)
            results[slot] = {
                sprite = sprite,
                name = sprite:getName() or ("Slot " .. slot),
                spells = spells,
                count = count,
            }
        end
    end
    return results
end

--- Invalidate scan cache for one sprite.
function BfBot.Scan.Invalidate(sprite)
    if not sprite then return end
    local ok, id = pcall(function() return sprite.m_id end)
    if ok and id then
        BfBot._cache.scan[id] = nil
    end
end

--- Invalidate all scan caches.
function BfBot.Scan.InvalidateAll()
    BfBot._cache.scan = {}
end

--- Load and classify a single spell by resref.
function BfBot.Scan.GetSpellInfo(resref, sprite)
    -- Check classification cache
    local cached = BfBot._cache.class[resref]

    local header = EEex_Resource_Demand(resref, "SPL")
    if not header then return nil end

    local casterLevel = 10 -- default
    if sprite then
        local ok, cl = pcall(function()
            return sprite:getCasterLevelForSpell(resref, true)
        end)
        if ok and cl and cl > 0 then
            casterLevel = cl
        end
    end

    local ability = header:getAbilityForLevel(casterLevel)
    if not ability then
        ability = header:getAbility(0)
    end
    if not ability then return nil end

    local classResult = BfBot.Class.Classify(resref, header, ability)

    return {
        resref = resref,
        name = Infinity_FetchString(header.genericName) or resref,
        level = header.spellLevel or 0,
        spellType = header.itemType or 0,
        class = classResult,
    }
end

-- ============================================================
-- Execution Engine (BfBot.Exec)
-- Parallel per-caster buff casting with EEex_LuaAction chaining
-- ============================================================

-- State
BfBot.Exec._state = "idle"       -- "idle" | "running" | "done" | "stopped"
BfBot.Exec._casters = {}         -- {[slot] = {queue={}, index=0, done=false, sprite=s, name=n}}
BfBot.Exec._activeCasters = 0    -- casters still processing (0 = all done)
BfBot.Exec._log = {}             -- log entries: {type=str, msg=str}
BfBot.Exec._castCount = 0        -- casts issued across all casters
BfBot.Exec._skipCount = 0        -- entries skipped across all casters
BfBot.Exec._totalEntries = 0     -- total entries across all casters
BfBot.Exec._logFile = "buffbot_exec.log"

--- Log an execution event.
function BfBot.Exec._LogEntry(type, msg)
    table.insert(BfBot.Exec._log, { type = type, msg = msg })
    BfBot._Print("[BuffBot] " .. type .. ": " .. msg)
end

--- Check if a sprite is alive (not dead/petrified/etc).
function BfBot.Exec._IsAlive(sprite)
    if not sprite then return false end
    local ok, state = pcall(function()
        return sprite.m_baseStats.m_generalState
    end)
    if not ok then return false end
    return EEex_BAnd(state, 0xFC0) == 0
end

--- Check if a sprite has an active timed effect from a given spell resref.
function BfBot.Exec._HasActiveEffect(sprite, resref)
    if not sprite or not resref then return false end
    local found = false
    local ok = pcall(function()
        EEex_Utility_IterateCPtrList(sprite.m_timedEffectList, function(effect)
            local effectRes = effect.m_sourceRes:get()
            if effectRes and effectRes == resref then
                found = true
                return true -- stop iteration
            end
        end)
    end)
    return ok and found
end

--- Get character name safely (delegates to shared BfBot._GetName).
function BfBot.Exec._GetName(sprite)
    return BfBot._GetName(sprite)
end

--- Resolve a user-specified target into expanded queue entries.
function BfBot.Exec._ResolveTargets(target, casterSprite, casterSlot, isAoE)
    local results = {}

    if target == "self" then
        table.insert(results, {
            targetObj = "Myself",
            targetSlot = casterSlot,
            targetSprite = casterSprite,
            targetName = BfBot.Exec._GetName(casterSprite),
        })
    elseif type(target) == "number" and target >= 1 and target <= 6 then
        local slot = target - 1
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite and BfBot.Exec._IsAlive(sprite) then
            table.insert(results, {
                targetObj = "Player" .. target,
                targetSlot = slot,
                targetSprite = sprite,
                targetName = BfBot.Exec._GetName(sprite),
            })
        end
    elseif target == "all" then
        if isAoE then
            table.insert(results, {
                targetObj = "Myself",
                targetSlot = casterSlot,
                targetSprite = casterSprite,
                targetName = "party (AoE)",
            })
        else
            for i = 0, 5 do
                local sprite = EEex_Sprite_GetInPortrait(i)
                if sprite and BfBot.Exec._IsAlive(sprite) then
                    table.insert(results, {
                        targetObj = "Player" .. (i + 1),
                        targetSlot = i,
                        targetSprite = sprite,
                        targetName = BfBot.Exec._GetName(sprite),
                    })
                end
            end
        end
    end

    return results
end

--- Build per-caster execution queues from user input.
-- userQueue: array of {caster=0-5, spell="RESREF", target="self"|"all"|1-6}
-- Returns: {[slot] = {entries}} grouped by caster, or nil + error
function BfBot.Exec._BuildQueue(userQueue)
    if not userQueue or #userQueue == 0 then
        return nil, "empty queue"
    end

    local byCaster = {}
    local totalEntries = 0

    for i, entry in ipairs(userQueue) do
        local casterSlot = entry.caster
        if type(casterSlot) ~= "number" or casterSlot < 0 or casterSlot > 5 then
            BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": invalid caster slot " .. tostring(casterSlot))
            goto continue
        end

        local casterSprite = EEex_Sprite_GetInPortrait(casterSlot)
        if not casterSprite then
            BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": no character in slot " .. casterSlot)
            goto continue
        end

        local casterName = BfBot.Exec._GetName(casterSprite)
        local resref = entry.spell
        if type(resref) ~= "string" or resref == "" then
            BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": invalid spell resref")
            goto continue
        end

        -- Look up spell data from scanner
        local spells = BfBot.Scan.GetCastableSpells(casterSprite)
        local spellData = spells and spells[resref]
        if not spellData then
            BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": " .. casterName
                .. " does not have " .. resref .. " available")
            goto continue
        end

        local classResult = spellData.class
        local isAoE = classResult and classResult.isAoE or false
        local splstates = classResult and classResult.splstates or {}
        local spellName = spellData.name or resref

        -- Resolve targets
        local targets = BfBot.Exec._ResolveTargets(
            entry.target, casterSprite, casterSlot, isAoE
        )

        if #targets == 0 then
            BfBot.Exec._LogEntry("ERROR", "Entry " .. i .. ": no valid targets for " .. spellName)
            goto continue
        end

        -- Group by caster slot
        byCaster[casterSlot] = byCaster[casterSlot] or {}

        for _, tgt in ipairs(targets) do
            table.insert(byCaster[casterSlot], {
                casterSlot = casterSlot,
                casterSprite = casterSprite,
                casterName = casterName,
                resref = resref,
                spellName = spellName,
                targetObj = tgt.targetObj,
                targetSlot = tgt.targetSlot,
                targetSprite = tgt.targetSprite,
                targetName = tgt.targetName,
                splstates = splstates,
                isAoE = isAoE,
            })
            totalEntries = totalEntries + 1
        end

        ::continue::
    end

    if totalEntries == 0 then
        return nil, "no valid entries after expansion"
    end

    return byCaster, totalEntries
end

--- Pre-flight checks for a single queue entry.
function BfBot.Exec._CheckEntry(entry)
    if BfBot.Exec._state ~= "running" then
        return false
    end

    local label = entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName

    -- Caster alive
    if not BfBot.Exec._IsAlive(entry.casterSprite) then
        BfBot.Exec._LogEntry("SKIP", label .. " (caster dead)")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        return false
    end

    -- Spell slot available (invalidate cache to get fresh count)
    BfBot.Scan.Invalidate(entry.casterSprite)
    local spells = BfBot.Scan.GetCastableSpells(entry.casterSprite)
    local spellData = spells and spells[entry.resref]
    if not spellData or spellData.count <= 0 then
        BfBot.Exec._LogEntry("SKIP", label .. " (no slot)")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        return false
    end

    -- Target alive (skip for "Myself")
    if entry.targetObj ~= "Myself" then
        if not BfBot.Exec._IsAlive(entry.targetSprite) then
            BfBot.Exec._LogEntry("SKIP", label .. " (target dead)")
            BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
            return false
        end
    end

    -- Buff already active check
    local targetSprite = entry.targetSprite
    if entry.isAoE then
        targetSprite = entry.casterSprite
    end

    -- SPLSTATE check (fast path)
    if entry.splstates and #entry.splstates > 0 then
        for _, stateID in ipairs(entry.splstates) do
            local ok, active = pcall(function()
                return targetSprite:getSpellState(stateID)
            end)
            if ok and active then
                BfBot.Exec._LogEntry("SKIP", label .. " (already active, splstate " .. stateID .. ")")
                BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
                return false
            end
        end
    end

    -- Effect list check (fallback — catches spells without SPLSTATEs)
    if BfBot.Exec._HasActiveEffect(targetSprite, entry.resref) then
        BfBot.Exec._LogEntry("SKIP", label .. " (already active, effect list)")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        return false
    end

    return true
end

--- Process a caster's queue entry at the given index.
-- Each caster runs their own chain independently.
function BfBot.Exec._ProcessCasterEntry(slot, index)
    local caster = BfBot.Exec._casters[slot]
    if not caster then return end

    -- This caster's queue exhausted
    if index > #caster.queue then
        caster.done = true
        BfBot.Exec._activeCasters = BfBot.Exec._activeCasters - 1
        BfBot.Exec._LogEntry("INFO", caster.name .. " finished")
        if BfBot.Exec._activeCasters <= 0 then
            BfBot.Exec._Complete()
        end
        return
    end

    -- Stopped by user
    if BfBot.Exec._state ~= "running" then
        return
    end

    caster.index = index
    local entry = caster.queue[index]

    -- Pre-flight checks — skip immediately recurses to next
    if not BfBot.Exec._CheckEntry(entry) then
        BfBot.Exec._ProcessCasterEntry(slot, index + 1)
        return
    end

    -- Build BCS action strings
    local spellAction = string.format('SpellRES("%s",%s)', entry.resref, entry.targetObj)
    local advanceAction = string.format('EEex_LuaAction("BfBot.Exec._Advance(%d)")', slot)

    -- Queue both on the caster: spell first, then our callback
    EEex_Action_QueueResponseStringOnAIBase(spellAction, entry.casterSprite)
    EEex_Action_QueueResponseStringOnAIBase(advanceAction, entry.casterSprite)

    BfBot.Exec._LogEntry("CAST",
        entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName)
    BfBot.Exec._castCount = BfBot.Exec._castCount + 1
end

--- Called by the engine via EEex_LuaAction after a caster's spell completes.
-- @param slot number: the caster's party slot (0-5)
function BfBot.Exec._Advance(slot)
    if BfBot.Exec._state ~= "running" then return end
    local caster = BfBot.Exec._casters[slot]
    if not caster or caster.done then return end
    BfBot.Exec._ProcessCasterEntry(slot, caster.index + 1)
end

--- Log execution summary and transition to "done" state.
function BfBot.Exec._Complete()
    BfBot.Exec._state = "done"
    local cast = BfBot.Exec._castCount
    local skip = BfBot.Exec._skipCount
    local total = cast + skip
    BfBot.Exec._LogEntry("DONE",
        string.format("Total: %d | Cast: %d | Skipped: %d", total, cast, skip))
    BfBot._Print("[BuffBot] === Execution Complete ===")
    BfBot._CloseLog()
end

--- Start executing a buff queue with parallel per-caster casting.
-- @param queue array of {caster=0-5, spell="RESREF", target="self"|"all"|1-6}
-- @return true if started, false + reason string if not
function BfBot.Exec.Start(queue)
    if BfBot.Exec._state == "running" then
        BfBot._Print("[BuffBot] Already running. Call BfBot.Exec.Stop() first.")
        return false, "already running"
    end

    -- Open execution log file
    BfBot._OpenLogAppend(BfBot.Exec._logFile)

    -- Reset state
    BfBot.Exec._state = "idle"
    BfBot.Exec._casters = {}
    BfBot.Exec._activeCasters = 0
    BfBot.Exec._log = {}
    BfBot.Exec._castCount = 0
    BfBot.Exec._skipCount = 0
    BfBot.Exec._totalEntries = 0

    -- Build per-caster queues
    local byCaster, totalEntries = BfBot.Exec._BuildQueue(queue)
    if not byCaster then
        BfBot.Exec._LogEntry("ERROR", "Failed to build queue: " .. tostring(totalEntries))
        BfBot._CloseLog()
        return false, totalEntries
    end

    BfBot.Exec._totalEntries = totalEntries

    -- Initialize per-caster state and print plan
    local casterCount = 0
    BfBot._Print("[BuffBot] === Starting Execution: " .. totalEntries .. " entries ===")

    -- Sort caster slots for deterministic display order
    local slots = {}
    for slot, _ in pairs(byCaster) do table.insert(slots, slot) end
    table.sort(slots)

    for _, slot in ipairs(slots) do
        local entries = byCaster[slot]
        local sprite = entries[1].casterSprite
        local name = entries[1].casterName

        BfBot.Exec._casters[slot] = {
            queue = entries,
            index = 0,
            done = false,
            sprite = sprite,
            name = name,
        }
        BfBot.Exec._activeCasters = BfBot.Exec._activeCasters + 1
        casterCount = casterCount + 1

        -- Log this caster's plan
        BfBot._Print("[BuffBot]   " .. name .. " (" .. #entries .. " spells):")
        for i, e in ipairs(entries) do
            BfBot._Print("[BuffBot]     " .. i .. ". " .. e.spellName .. " -> " .. e.targetName)
        end
    end

    BfBot._Print("[BuffBot] " .. casterCount .. " casters working in parallel")

    -- Go — start ALL casters simultaneously
    BfBot.Exec._state = "running"
    for _, slot in ipairs(slots) do
        BfBot.Exec._ProcessCasterEntry(slot, 1)
    end

    return true
end

--- Stop execution mid-queue.
function BfBot.Exec.Stop()
    if BfBot.Exec._state ~= "running" then
        BfBot._Print("[BuffBot] Not running.")
        return
    end
    BfBot.Exec._state = "stopped"
    BfBot.Exec._LogEntry("INFO", "Stopped by user")
    BfBot._Print("[BuffBot] === Execution Stopped ===")
    BfBot._Print(string.format("[BuffBot]   Cast: %d | Skipped: %d",
        BfBot.Exec._castCount, BfBot.Exec._skipCount))
    BfBot._CloseLog()
end

--- Get current execution state.
function BfBot.Exec.GetState()
    return BfBot.Exec._state
end

--- Get execution log entries.
function BfBot.Exec.GetLog()
    return BfBot.Exec._log
end

-- ============================================================
-- Configuration Persistence (BfBot.Persist)
-- Save/load per-character config via EEex marshal handlers,
-- global preferences via INI
-- ============================================================

-- Constants
BfBot.Persist._SCHEMA_VERSION = 1
BfBot.Persist._KEY = "BB"        -- UDAux storage key
BfBot.Persist._HANDLER = "BuffBot" -- marshal handler name

-- INI preference defaults (cross-save, stored in baldur.ini)
BfBot.Persist._INI_DEFAULTS = {
    LongThreshold = 300,  -- seconds (5 turns) — divides "long" from "short"
    DefaultPreset = 1,    -- which preset tab opens by default
    HotkeyCode    = 87,   -- F11
    ShowTooltips  = 1,    -- show spell tooltips in panel
    ConfirmCast   = 0,    -- show confirmation before casting
}

-- ---- Boolean sanitization ----

--- Recursively convert any boolean values to 1/0 in a table.
-- EEex marshal only supports number/string/table — booleans crash saves.
function BfBot.Persist._SanitizeValues(tbl)
    if type(tbl) ~= "table" then return end
    for k, v in pairs(tbl) do
        local vt = type(v)
        if vt == "boolean" then
            tbl[k] = v and 1 or 0
        elseif vt == "table" then
            BfBot.Persist._SanitizeValues(v)
        end
    end
end

-- ---- Default config ----

--- Return a fresh empty config with correct schema.
function BfBot.Persist.GetDefaultConfig()
    return {
        v  = BfBot.Persist._SCHEMA_VERSION,
        ap = 1,
        presets = {
            [1] = { name = "Long Buffs",  cat = "long",  spells = {} },
            [2] = { name = "Short Buffs", cat = "short", spells = {} },
        },
        opts = { skip = 1, cheat = 0 },
    }
end

--- Create a default spell entry from classification data.
-- @param classResult  classification table (may be nil)
-- @param enabled      optional 0 or 1 (default 1)
function BfBot.Persist._MakeDefaultSpellEntry(classResult, enabled)
    local tgt = "p"
    if classResult and classResult.defaultTarget == "s" then
        tgt = "s"
    end
    return { on = (enabled == 0) and 0 or 1, tgt = tgt, pri = 999 }
end

--- Scan a character's spells and create a populated default config.
function BfBot.Persist._CreateDefaultConfig(sprite)
    local config = BfBot.Persist.GetDefaultConfig()

    -- Try to populate from scanner (may fail if sprite not fully loaded)
    local ok, spells, count = pcall(BfBot.Scan.GetCastableSpells, sprite)
    if not ok or not spells or count == 0 then
        -- Store empty config; will be populated when UI opens
        local setOk = pcall(function()
            EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = config
        end)
        if not setOk then
            BfBot._Warn("[Persist] Failed to store default config in UDAux")
        end
        return config
    end

    -- Collect buff spells with classification data
    local buffs = {}
    for resref, data in pairs(spells) do
        if data.class and data.class.isBuff and data.count > 0 then
            table.insert(buffs, {
                resref    = resref,
                classData = data.class,
                duration  = data.class.duration or 0,
                durCat    = data.class.durCat or "short",
            })
        end
    end

    -- Sort: permanent first, then long desc, then short desc
    local durOrder = { permanent = 1, long = 2, short = 3, instant = 4 }
    table.sort(buffs, function(a, b)
        local oa = durOrder[a.durCat] or 5
        local ob = durOrder[b.durCat] or 5
        if oa ~= ob then return oa < ob end
        if a.duration ~= b.duration then return a.duration > b.duration end
        return a.resref < b.resref
    end)

    -- Distribute ALL spells to BOTH presets (different enabled states).
    -- Enabled spells get low priorities (cast first), disabled get high.
    local p1enCount, p2enCount = 0, 0
    for _, buff in ipairs(buffs) do
        if buff.durCat == "long" or buff.durCat == "permanent" then
            p1enCount = p1enCount + 1
        elseif buff.durCat == "short" then
            p2enCount = p2enCount + 1
        end
    end

    local p1en, p1dis = 1, 1
    local p2en, p2dis = 1, 1
    for _, buff in ipairs(buffs) do
        local isLong = (buff.durCat == "long" or buff.durCat == "permanent")
        local isShort = (buff.durCat == "short")

        -- Preset 1: long/permanent enabled, everything else disabled
        local e1 = BfBot.Persist._MakeDefaultSpellEntry(buff.classData, isLong and 1 or 0)
        if isLong then
            e1.pri = p1en;  p1en = p1en + 1
        else
            e1.pri = p1enCount + p1dis;  p1dis = p1dis + 1
        end
        config.presets[1].spells[buff.resref] = e1

        -- Preset 2: short enabled, everything else disabled
        local e2 = BfBot.Persist._MakeDefaultSpellEntry(buff.classData, isShort and 1 or 0)
        if isShort then
            e2.pri = p2en;  p2en = p2en + 1
        else
            e2.pri = p2enCount + p2dis;  p2dis = p2dis + 1
        end
        config.presets[2].spells[buff.resref] = e2
    end

    -- Store in UDAux
    pcall(function()
        EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = config
    end)

    return config
end

-- ---- Validation ----

--- Validate and repair a config table. Never errors.
function BfBot.Persist._ValidateConfig(config)
    if type(config) ~= "table" then
        return BfBot.Persist.GetDefaultConfig()
    end

    -- Schema version
    if type(config.v) ~= "number" then
        config.v = BfBot.Persist._SCHEMA_VERSION
    end

    -- Active preset
    if type(config.ap) ~= "number" or config.ap < 1 or config.ap > 5 then
        config.ap = 1
    end

    -- Presets
    if type(config.presets) ~= "table" then
        config.presets = {
            [1] = { name = "Long Buffs",  cat = "long",  spells = {} },
            [2] = { name = "Short Buffs", cat = "short", spells = {} },
        }
    end

    -- Validate each preset
    for idx, preset in pairs(config.presets) do
        if type(preset) ~= "table" then
            config.presets[idx] = { name = "Preset " .. idx, cat = "custom", spells = {} }
        else
            if type(preset.name) ~= "string" then preset.name = "Preset " .. idx end
            if type(preset.cat) ~= "string" then preset.cat = "custom" end
            if type(preset.spells) ~= "table" then
                preset.spells = {}
            else
                -- Validate individual spell entries
                for resref, entry in pairs(preset.spells) do
                    if type(entry) ~= "table" then
                        preset.spells[resref] = nil  -- remove corrupt entry
                    else
                        if type(entry.on) ~= "number" then entry.on = 0 end
                        if type(entry.tgt) ~= "string" then entry.tgt = "p" end
                        if type(entry.pri) ~= "number" then entry.pri = 999 end
                    end
                end
            end
        end
    end

    -- Options
    if type(config.opts) ~= "table" then
        config.opts = { skip = 1, cheat = 0 }
    else
        if type(config.opts.skip) ~= "number" then config.opts.skip = 1 end
        if type(config.opts.cheat) ~= "number" then config.opts.cheat = 0 end
    end

    -- Safety: convert any stray booleans
    BfBot.Persist._SanitizeValues(config)

    return config
end

--- Migrate config from an older schema version. Currently a no-op.
function BfBot.Persist._MigrateConfig(config, fromVersion)
    -- v1 is the initial version; no migrations needed yet.
    -- Future: if fromVersion == 1 then ... migrate to v2 ... end
    config.v = BfBot.Persist._SCHEMA_VERSION
    return config
end

-- ---- Marshal handlers ----

--- Exporter: called by EEex during save.
function BfBot.Persist._Export(sprite)
    local ok, result = pcall(function()
        -- Skip temporary copies (quicksave previews, area transitions)
        local copyOk, isCopy = pcall(function() return EEex.IsMarshallingCopy() end)
        if copyOk and isCopy then
            return {}
        end
        local config = EEex_GetUDAux(sprite)[BfBot.Persist._KEY]
        if config then
            return { cfg = config }
        end
        return {}
    end)
    if ok then return result end
    return {}  -- on error, return empty (don't crash save)
end

--- Importer: called by EEex during load.
function BfBot.Persist._Import(sprite, data)
    local ok, err = pcall(function()
        if not data or type(data) ~= "table" then return end
        local config = data.cfg
        if not config then return end

        -- Validate and repair
        config = BfBot.Persist._ValidateConfig(config)

        -- Migrate if needed
        if config.v < BfBot.Persist._SCHEMA_VERSION then
            config = BfBot.Persist._MigrateConfig(config, config.v)
        end

        EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = config
    end)
    if not ok then
        BfBot._Warn("[Persist] Import failed: " .. tostring(err))
    end
end

--- Register marshal handlers. Call once at load time.
function BfBot.Persist.Init()
    EEex_Sprite_AddMarshalHandlers(BfBot.Persist._HANDLER,
        function(sprite) return BfBot.Persist._Export(sprite) end,
        function(sprite, data) BfBot.Persist._Import(sprite, data) end
    )
end

-- ---- Config access ----

--- Get the config for a character sprite. Creates default if none exists.
function BfBot.Persist.GetConfig(sprite)
    if not sprite then return nil end
    local ok, config = pcall(function()
        return EEex_GetUDAux(sprite)[BfBot.Persist._KEY]
    end)
    if not ok then return nil end
    if not config then
        config = BfBot.Persist._CreateDefaultConfig(sprite)
    end
    return config
end

--- Store a config on a character sprite. Validates before storing.
function BfBot.Persist.SetConfig(sprite, config)
    if not sprite or not config then return end
    config = BfBot.Persist._ValidateConfig(config)
    pcall(function()
        EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = config
    end)
end

--- Get a specific preset for a character.
function BfBot.Persist.GetPreset(sprite, presetIndex)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config or not config.presets then return nil end
    return config.presets[presetIndex]
end

--- Get the active preset and its index.
function BfBot.Persist.GetActivePreset(sprite)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return nil, 1 end
    local idx = config.ap or 1
    return config.presets[idx], idx
end

--- Set the active preset index (clamped 1-5).
function BfBot.Persist.SetActivePreset(sprite, presetIndex)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return end
    config.ap = math.max(1, math.min(5, presetIndex))
end

-- ---- Spell config accessors ----

--- Set whether a spell is enabled in a preset.
function BfBot.Persist.SetSpellEnabled(sprite, presetIndex, resref, enabled)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset then return end
    if not preset.spells[resref] then
        preset.spells[resref] = BfBot.Persist._MakeDefaultSpellEntry(nil)
    end
    preset.spells[resref].on = enabled and 1 or 0
end

--- Set the target for a spell in a preset.
function BfBot.Persist.SetSpellTarget(sprite, presetIndex, resref, target)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells[resref] then return end
    preset.spells[resref].tgt = target
end

--- Set the priority for a spell in a preset.
function BfBot.Persist.SetSpellPriority(sprite, presetIndex, resref, priority)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells[resref] then return end
    preset.spells[resref].pri = priority
end

--- Get the config entry for a spell in a preset.
function BfBot.Persist.GetSpellConfig(sprite, presetIndex, resref)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells then return nil end
    return preset.spells[resref]
end

-- ---- Options ----

--- Get a per-character option value.
function BfBot.Persist.GetOpt(sprite, key)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config or not config.opts then return 0 end
    return config.opts[key] or 0
end

--- Set a per-character option value.
function BfBot.Persist.SetOpt(sprite, key, value)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config or not config.opts then return end
    if type(value) == "boolean" then value = value and 1 or 0 end
    config.opts[key] = value
end

-- ---- Queue building ----

--- Build an execution queue from a preset across all party members.
-- Returns queue compatible with BfBot.Exec.Start(), or nil + error message.
function BfBot.Persist.BuildQueueFromPreset(presetIndex)
    if not presetIndex then return nil, "no preset index" end

    local queue = {}

    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if not sprite then goto nextSlot end

        local config = BfBot.Persist.GetConfig(sprite)
        if not config then goto nextSlot end

        local preset = config.presets[presetIndex]
        if not preset or not preset.spells then goto nextSlot end

        -- Invalidate scan cache for fresh data
        BfBot.Scan.Invalidate(sprite)
        local ok, castable, _ = pcall(BfBot.Scan.GetCastableSpells, sprite)
        if not ok or not castable then goto nextSlot end

        -- Collect enabled, castable spells with priority
        local entries = {}
        for resref, spellCfg in pairs(preset.spells) do
            if spellCfg.on == 1 then
                local scanData = castable[resref]
                if scanData and scanData.count > 0 and not scanData.disabled then
                    local tgt = spellCfg.tgt
                    local pri = spellCfg.pri or 999

                    if type(tgt) == "table" then
                        -- Multi-target: one queue entry per target in the list
                        for _, slotStr in ipairs(tgt) do
                            local num = tonumber(slotStr)
                            if num and num >= 1 and num <= 6 then
                                table.insert(entries, {
                                    caster = slot,
                                    spell  = resref,
                                    target = num,
                                    pri    = pri,
                                })
                            end
                        end
                    else
                        -- Single target: map config format to exec engine format
                        local target
                        if tgt == "s" then
                            target = "self"
                        elseif tgt == "p" then
                            target = "all"
                        else
                            local num = tonumber(tgt)
                            if num and num >= 1 and num <= 6 then
                                target = num
                            else
                                target = "all"  -- fallback for unknown
                            end
                        end

                        table.insert(entries, {
                            caster = slot,
                            spell  = resref,
                            target = target,
                            pri    = pri,
                        })
                    end
                end
            end
        end

        -- Sort by priority (ascending: lower = cast first)
        table.sort(entries, function(a, b) return a.pri < b.pri end)

        -- Append to queue (strip pri field — exec engine doesn't use it)
        for _, e in ipairs(entries) do
            table.insert(queue, {
                caster = e.caster,
                spell  = e.spell,
                target = e.target,
            })
        end

        ::nextSlot::
    end

    if #queue == 0 then
        return nil, "no castable spells in preset " .. presetIndex
    end

    return queue
end

-- ---- INI preferences (global, cross-save) ----

--- Get a global preference from baldur.ini.
function BfBot.Persist.GetPref(key)
    local default = BfBot.Persist._INI_DEFAULTS[key] or 0
    local ok, val = pcall(Infinity_GetINIValue, "BuffBot", key, default)
    if ok then return val end
    return default
end

--- Set a global preference in baldur.ini.
function BfBot.Persist.SetPref(key, value)
    pcall(Infinity_SetINIValue, "BuffBot", key, value)
end

--- Rename a preset.
function BfBot.Persist.RenamePreset(sprite, presetIndex, newName)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset then return end
    preset.name = tostring(newName)
end

--- Create a new preset (up to 5). Populates with all buff spells from existing
--- presets (union), all disabled. Returns the new preset index, or nil if full.
function BfBot.Persist.CreatePreset(sprite, name)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return nil end

    -- Find next available slot (max 5)
    local idx = nil
    for i = 1, 5 do
        if not config.presets[i] then
            idx = i
            break
        end
    end
    if not idx then return nil end  -- all 5 taken

    -- Collect union of all spells across existing presets
    local allSpells = {}
    for _, preset in pairs(config.presets) do
        if preset.spells then
            for resref, cfg in pairs(preset.spells) do
                if not allSpells[resref] then
                    allSpells[resref] = { tgt = cfg.tgt or "p", pri = cfg.pri or 999 }
                end
            end
        end
    end

    -- Build spell table for new preset — all disabled
    local spells = {}
    for resref, info in pairs(allSpells) do
        spells[resref] = { on = 0, tgt = info.tgt, pri = info.pri }
    end

    config.presets[idx] = {
        name = name or ("Preset " .. idx),
        cat = "custom",
        spells = spells,
    }

    return idx
end

--- Delete a preset by index. Refuses to delete the last remaining preset.
--- Returns true on success, nil on failure.
function BfBot.Persist.DeletePreset(sprite, presetIndex)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return nil end

    -- Count existing presets
    local count = 0
    for i = 1, 5 do
        if config.presets[i] then count = count + 1 end
    end
    if count <= 1 then return nil end  -- can't delete last preset

    if not config.presets[presetIndex] then return nil end
    config.presets[presetIndex] = nil

    -- If active preset was deleted, switch to first available
    if config.ap == presetIndex then
        for i = 1, 5 do
            if config.presets[i] then
                config.ap = i
                break
            end
        end
    end

    return 1  -- integer, not boolean
end

-- ============================================================
-- Party-wide preset operations
-- ============================================================

--- Create a new preset for ALL party members at the same index.
--- Finds the first slot free across all characters. Returns index or nil.
function BfBot.Persist.CreatePresetAll(name)
    -- Find first index free across all party members
    local idx = nil
    for i = 1, 5 do
        local allFree = true
        for slot = 0, 5 do
            local sprite = EEex_Sprite_GetInPortrait(slot)
            if sprite then
                local config = BfBot.Persist.GetConfig(sprite)
                if config and config.presets[i] then
                    allFree = false
                    break
                end
            end
        end
        if allFree then idx = i; break end
    end
    if not idx then return nil end

    -- Create at that index for each party member
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local config = BfBot.Persist.GetConfig(sprite)
            if config then
                -- Collect union of all spells across existing presets
                local allSpells = {}
                for _, preset in pairs(config.presets) do
                    if preset.spells then
                        for resref, cfg in pairs(preset.spells) do
                            if not allSpells[resref] then
                                allSpells[resref] = { tgt = cfg.tgt or "p", pri = cfg.pri or 999 }
                            end
                        end
                    end
                end
                local spells = {}
                for resref, info in pairs(allSpells) do
                    spells[resref] = { on = 0, tgt = info.tgt, pri = info.pri }
                end
                config.presets[idx] = {
                    name = name or ("Preset " .. idx),
                    cat = "custom",
                    spells = spells,
                }
            end
        end
    end
    return idx
end

--- Delete a preset for ALL party members. Returns 1 if any were deleted.
function BfBot.Persist.DeletePresetAll(presetIndex)
    local anyDeleted = nil
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local result = BfBot.Persist.DeletePreset(sprite, presetIndex)
            if result then anyDeleted = 1 end
        end
    end
    return anyDeleted
end

--- Rename a preset for ALL party members.
function BfBot.Persist.RenamePresetAll(presetIndex, newName)
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            BfBot.Persist.RenamePreset(sprite, presetIndex, newName)
        end
    end
end

-- ============================================================
-- Per-Character Queue Building
-- ============================================================

--- Build execution queue for a single character's preset.
-- Like BuildQueueFromPreset but only for one party slot.
-- @param slot number: party portrait slot (0-5)
-- @param presetIndex number: preset index (1-5)
-- @return queue array or nil, error string
function BfBot.Persist.BuildQueueForCharacter(slot, presetIndex)
    if not slot or not presetIndex then return nil, "missing slot or preset" end

    local sprite = EEex_Sprite_GetInPortrait(slot)
    if not sprite then return nil, "no sprite in slot " .. slot end

    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return nil, "no config for slot " .. slot end

    local preset = config.presets[presetIndex]
    if not preset or not preset.spells then
        return nil, "no preset " .. presetIndex .. " for slot " .. slot
    end

    -- Invalidate scan cache for fresh data
    BfBot.Scan.Invalidate(sprite)
    local ok, castable, _ = pcall(BfBot.Scan.GetCastableSpells, sprite)
    if not ok or not castable then return nil, "scan failed for slot " .. slot end

    -- Collect enabled, castable spells with priority
    local entries = {}
    for resref, spellCfg in pairs(preset.spells) do
        if spellCfg.on == 1 then
            local scanData = castable[resref]
            if scanData and scanData.count > 0 and not scanData.disabled then
                local tgt = spellCfg.tgt
                local pri = spellCfg.pri or 999

                if type(tgt) == "table" then
                    for _, slotStr in ipairs(tgt) do
                        local num = tonumber(slotStr)
                        if num and num >= 1 and num <= 6 then
                            table.insert(entries, {
                                caster = slot,
                                spell  = resref,
                                target = num,
                                pri    = pri,
                            })
                        end
                    end
                else
                    local target
                    if tgt == "s" then
                        target = "self"
                    elseif tgt == "p" then
                        target = "all"
                    else
                        local num = tonumber(tgt)
                        if num and num >= 1 and num <= 6 then
                            target = num
                        else
                            target = "all"
                        end
                    end

                    table.insert(entries, {
                        caster = slot,
                        spell  = resref,
                        target = target,
                        pri    = pri,
                    })
                end
            end
        end
    end

    -- Sort by priority (ascending: lower = cast first)
    table.sort(entries, function(a, b) return a.pri < b.pri end)

    -- Strip pri field — exec engine doesn't use it
    local queue = {}
    for _, e in ipairs(entries) do
        table.insert(queue, {
            caster = e.caster,
            spell  = e.spell,
            target = e.target,
        })
    end

    if #queue == 0 then
        return nil, "no castable spells in preset " .. presetIndex .. " for slot " .. slot
    end

    return queue
end

-- ============================================================
-- Innate Ability Management (BfBot.Innate)
-- Generates SPL files at runtime and grants per-preset innate
-- abilities to party members for F12 / special abilities access.
-- ============================================================

BfBot.Innate = {}

-- Read base strref from file (written by tools/patch_tlk.py at deploy time).
-- If the file doesn't exist, innates will have no tooltip names.
BfBot.Innate._baseStrref = nil
local _sf = io.open("override/bfbot_strrefs.txt", "r")
if _sf then
    BfBot.Innate._baseStrref = tonumber(_sf:read("*l"))
    _sf:close()
end

-- ---- Binary packing helpers (little-endian) ----

local function _splByte(n)  return string.char(n % 256) end
local function _splWord(n)  return string.char(n % 256, math.floor(n / 256) % 256) end
local function _splDword(n)
    if n < 0 then n = n + 4294967296 end
    return string.char(
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256
    )
end
local function _splResref(s)
    s = s or ""
    return s .. string.rep("\0", 8 - #s)
end
local function _splPad(n) return string.rep("\0", n) end

--- Build a minimal SPL binary for a BuffBot innate ability.
-- @param slot number: party slot (0-5), baked into opcode 402 param1
-- @param preset number: preset index (1-5), baked into opcode 402 param2
-- @return string: raw SPL binary data (250 bytes)
function BfBot.Innate._BuildSPL(slot, preset)
    local selfRef = string.format("BFBT%d%d", slot, preset)

    -- Name strref: base + (preset-1) if TLK was patched, else -1 (no name)
    local nameStrref = 0xFFFFFFFF
    if BfBot.Innate._baseStrref then
        nameStrref = BfBot.Innate._baseStrref + (preset - 1)
    end

    local HEADER_SIZE = 0x72   -- 114 bytes
    local EXT_SIZE    = 0x28   -- 40 bytes
    local FEAT_SIZE   = 0x30   -- 48 bytes
    local extOffset   = HEADER_SIZE
    local featOffset  = HEADER_SIZE + EXT_SIZE

    -- SPL Header (114 bytes)
    local header = "SPL "                       -- 0x0000: Signature
        .. "V1  "                               -- 0x0004: Version
        .. _splDword(nameStrref)                 -- 0x0008: Unidentified name strref
        .. _splDword(nameStrref)                 -- 0x000C: Identified name strref
        .. _splResref("")                       -- 0x0010: Completion sound
        .. _splDword(0)                         -- 0x0018: Flags
        .. _splWord(4)                          -- 0x001C: Spell type = 4 (Innate)
        .. _splDword(0)                         -- 0x001E: Exclusion flags
        .. _splWord(0)                          -- 0x0022: Casting graphics
        .. _splByte(0)                          -- 0x0024: unused
        .. _splByte(0)                          -- 0x0025: Primary type
        .. _splByte(0)                          -- 0x0026: unused
        .. _splByte(0)                          -- 0x0027: Secondary type
        .. _splPad(12)                          -- 0x0028: unused block
        .. _splDword(preset)                      -- 0x0034: Spell level = preset (separate F12 lines)
        .. _splWord(0)                          -- 0x0038: Stack amount
        .. _splResref("SPWI218B")               -- 0x003A: Spellbook icon (Stoneskin button BAM)
        .. _splWord(0)                          -- 0x0042: Lore to ID
        .. _splResref("")                       -- 0x0044: Ground icon
        .. _splDword(0)                         -- 0x004C: Weight
        .. _splDword(0xFFFFFFFF)                -- 0x0050: Description unidentified
        .. _splDword(0xFFFFFFFF)                -- 0x0054: Description identified
        .. _splResref("")                       -- 0x0058: Description icon
        .. _splDword(0)                         -- 0x0060: Enchantment
        .. _splDword(extOffset)                 -- 0x0064: Extended header offset
        .. _splWord(1)                          -- 0x0068: Extended header count
        .. _splDword(featOffset)                -- 0x006A: Feature block table offset
        .. _splWord(0)                          -- 0x006E: Casting feature block offset
        .. _splWord(0)                          -- 0x0070: Casting feature block count

    -- Extended Header / Ability (40 bytes)
    local ability = _splByte(1)                 -- 0x0000: Spell form = standard
        .. _splByte(0x04)                       -- 0x0001: Flags = friendly
        .. _splWord(4)                          -- 0x0002: Location = Innate
        .. _splResref("SPWI218B")               -- 0x0004: Memorised icon (Stoneskin button BAM)
        .. _splByte(5)                          -- 0x000C: Target = self
        .. _splByte(0)                          -- 0x000D: Target count
        .. _splWord(0)                          -- 0x000E: Range
        .. _splWord(preset)                      -- 0x0010: Level required = preset (matches spell level)
        .. _splWord(0)                          -- 0x0012: Casting time = instant
        .. _splWord(1)                          -- 0x0014: Times per day = 1
        .. _splWord(0)                          -- 0x0016: Dice sides
        .. _splWord(0)                          -- 0x0018: Dice thrown
        .. _splWord(0)                          -- 0x001A: Enchanted
        .. _splWord(0)                          -- 0x001C: Damage type
        .. _splWord(2)                          -- 0x001E: Feature block count = 2
        .. _splWord(0)                          -- 0x0020: Feature block offset (index)
        .. _splWord(0)                          -- 0x0022: Charges
        .. _splWord(0)                          -- 0x0024: Charge depletion
        .. _splWord(1)                          -- 0x0026: Projectile = 1 (none)

    -- Feature Block 1: Opcode 402 (EEex Invoke Lua)
    local feat402 = _splWord(402)               -- 0x0000: Opcode
        .. _splByte(1)                          -- 0x0002: Target = self
        .. _splByte(0)                          -- 0x0003: Power
        .. _splDword(slot)                      -- 0x0004: Param1 = party slot
        .. _splDword(preset)                    -- 0x0008: Param2 = preset index
        .. _splByte(0)                          -- 0x000C: Timing = 0 (instant/duration)
        .. _splByte(0)                          -- 0x000D: Dispel/resistance
        .. _splDword(0)                         -- 0x000E: Duration = 0 (one-shot)
        .. _splByte(100)                        -- 0x0012: Probability1
        .. _splByte(0)                          -- 0x0013: Probability2
        .. _splResref("BFBOTGO")                -- 0x0014: Resource (function name)
        .. _splDword(0)                         -- 0x001C: Dice thrown
        .. _splDword(0)                         -- 0x0020: Dice sides
        .. _splDword(0)                         -- 0x0024: Save type
        .. _splDword(0)                         -- 0x0028: Save bonus
        .. _splDword(0)                         -- 0x002C: Stacking ID

    -- Feature Block 2: Opcode 171 (Give Innate Spell Ability — re-grant self)
    local feat171 = _splWord(171)               -- 0x0000: Opcode
        .. _splByte(1)                          -- 0x0002: Target = self
        .. _splByte(0)                          -- 0x0003: Power
        .. _splDword(0)                         -- 0x0004: Param1
        .. _splDword(0)                         -- 0x0008: Param2
        .. _splByte(0)                          -- 0x000C: Timing = 0 (instant/duration)
        .. _splByte(0)                          -- 0x000D: Dispel/resistance
        .. _splDword(0)                         -- 0x000E: Duration
        .. _splByte(100)                        -- 0x0012: Probability1
        .. _splByte(0)                          -- 0x0013: Probability2
        .. _splResref(selfRef)                  -- 0x0014: Resource = self (re-grant)
        .. _splDword(0)                         -- 0x001C: Dice thrown
        .. _splDword(0)                         -- 0x0020: Dice sides
        .. _splDword(0)                         -- 0x0024: Save type
        .. _splDword(0)                         -- 0x0028: Save bonus
        .. _splDword(0)                         -- 0x002C: Stacking ID

    return header .. ability .. feat402 .. feat171
end

--- Write all 30 SPL files to the override folder (always overwrites).
-- Called once at mod init time (before menus load).
-- SPL version tag lets us detect when binary format changes.
BfBot.Innate._SPL_VERSION = 2  -- bump this when _BuildSPL format changes

function BfBot.Innate._EnsureSPLFiles()
    local count = 0
    for slot = 0, 5 do
        for preset = 1, 5 do
            local resref = string.format("BFBT%d%d", slot, preset)
            local path = "override/" .. resref .. ".SPL"
            local data = BfBot.Innate._BuildSPL(slot, preset)
            local f = io.open(path, "wb")
            if f then
                f:write(data)
                f:close()
                count = count + 1
            end
        end
    end
    return count
end

--- Grant innate abilities to all party members based on their configured presets.
function BfBot.Innate.Grant()
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local config = BfBot.Persist.GetConfig(sprite)
            if config then
                for idx = 1, 5 do
                    if config.presets[idx] then
                        local resref = string.format("BFBT%d%d", slot, idx)
                        EEex_Action_QueueResponseStringOnAIBase(
                            'AddSpecialAbility("' .. resref .. '")', sprite)
                    end
                end
            end
        end
    end
end

--- Remove all BuffBot innates from a specific character.
-- NOTE: RemoveSpellRES may not be in INSTANT.IDS. Using queued execution as fallback.
-- If innates accumulate in testing, consider opcode 172 (Remove Innate) via effect.
function BfBot.Innate.Revoke(slot)
    local sprite = EEex_Sprite_GetInPortrait(slot)
    if not sprite then return end
    for idx = 1, 5 do
        local resref = string.format("BFBT%d%d", slot, idx)
        EEex_Action_QueueResponseStringOnAIBase(
            'RemoveSpellRES("' .. resref .. '")', sprite)
    end
end

--- Refresh innates for a specific character (e.g., after preset create/delete).
function BfBot.Innate.Refresh(slot)
    BfBot.Innate.Revoke(slot)
    local sprite = EEex_Sprite_GetInPortrait(slot)
    if not sprite then return end
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return end
    for idx = 1, 5 do
        if config.presets[idx] then
            local resref = string.format("BFBT%d%d", slot, idx)
            EEex_Action_QueueResponseStringOnAIBase(
                'AddSpecialAbility("' .. resref .. '")', sprite)
        end
    end
end

--- Refresh innates for ALL party members.
function BfBot.Innate.RefreshAll()
    for slot = 0, 5 do
        BfBot.Innate.Refresh(slot)
    end
end

-- ============================================================
-- Innate Ability Handler (Global Function for Opcode 402)
-- Called by the engine when a BFBT*.SPL innate is activated.
-- ============================================================

--- Opcode 402 Invoke Lua handler — triggers a specific preset for a specific character.
-- param1 is a CGameEffect userdata: m_effectAmount = party slot, m_dWFlags = preset index.
function BFBOTGO(param1, param2, special)
    local slot = param1 and param1.m_effectAmount or 0
    local presetIdx = param1 and param1.m_dWFlags or 1

    local logf = io.open("buffbot_innate.log", "a")
    if logf then
        logf:write(string.format("[%s] BFBOTGO: slot=%d preset=%d\n",
            os.date("%Y-%m-%d %H:%M:%S"), slot, presetIdx))
        logf:close()
    end

    local sprite = EEex_Sprite_GetInPortrait(slot)
    if not sprite then return end

    if BfBot.Exec.GetState() == "running" then
        sprite:displayTextRef(14007)
        return
    end

    local queue = BfBot.Persist.BuildQueueForCharacter(slot, presetIdx)
    if queue and #queue > 0 then
        BfBot.Exec.Start(queue)
    end
end

-- ============================================================
-- Module loaded
-- ============================================================

-- No output at load time — Infinity_DisplayString may not be available yet
