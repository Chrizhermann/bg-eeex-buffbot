-- ============================================================
-- BfBotCls.lua — Buff Classifier (BfBot.Class)
-- Opcode-based scoring, MSECTYPE, duration, AoE detection,
-- manual override, and main classification function.
-- ============================================================

BfBot.Class = {}

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
-- Internal Helpers
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
-- Scoring Functions
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
--- Also extracts SPLSTATE IDs, self-replace flag, AoE signals,
--- and whether any substantive buff opcode contributed.
--- "Soft" opcodes (17=Healing, 171=Give Ability) score normally
--- but don't count as substantive evidence of a buff.
--- Self-referencing opcodes 318/324 (anti-stacking / toggle
--- infrastructure) are discounted to 0 instead of +2.
function BfBot.Class.ScoreOpcodes(header, ability, resref)
    local score = 0
    local splstates = {}
    local selfReplace = false
    local isToggle = false
    local fbAoE = false
    local hasSubstantive = false

    -- Soft opcodes: positive score but not substantive buff effects
    local SOFT_OPCODES = {[17] = true, [171] = true}

    local resrefUpper = resref and resref:upper() or nil

    BfBot.Class._IterateFeatureBlocks(header, ability, function(fb, _)
        local opcode = fb[BfBot._fields.fb_opcode]
        if not opcode then return end

        -- Check for self-referencing protection/immunity opcodes
        local isSelfRef = false
        if (opcode == 318 or opcode == 324) and resrefUpper then
            local ok, resVal = pcall(function()
                return fb[BfBot._fields.fb_res]:get()
            end)
            if ok and resVal and resVal:upper() == resrefUpper then
                isSelfRef = true
                -- opcode 318 self-ref = toggle mechanism (like stances)
                if opcode == 318 then
                    isToggle = true
                end
            end
        end

        -- Opcode scoring (skip self-referencing 318/324)
        local opScore = BfBot.Class._OPCODE_SCORES[opcode]
        if opScore then
            if isSelfRef then
                -- Don't add score for self-referencing protection/immunity
                -- (SCS anti-stacking or mod toggle infrastructure)
            else
                score = score + opScore
                -- Track substantive buff opcodes (positive, non-soft)
                if opScore > 0 and not SOFT_OPCODES[opcode] then
                    hasSubstantive = true
                end
            end
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
        if opcode == 321 and resrefUpper then
            local ok, resVal = pcall(function()
                return fb[BfBot._fields.fb_res]:get()
            end)
            if ok and resVal and resVal:upper() == resrefUpper then
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
        isToggle = isToggle,
        fbAoE = fbAoE,
        hasSubstantive = hasSubstantive,
    }
end

-- ============================================================
-- Duration
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
-- AoE and Targeting
-- ============================================================

--- Determine if a spell is AoE (party-wide) or single-target.
--- For BuffBot: AoE = "cast once, covers party". Self-only = "cast once on self" (not AoE).
--- Only trusts ability header target types; feature block signals (fbAoE) and
--- actionCount==0 are unreliable with SCS (false positives on single-target spells).
function BfBot.Class.IsAoE(ability, fbAoE)
    local targetType = ability.actionType
    -- Self-only spells are never AoE for buff purposes
    if targetType == 5 or targetType == 7 then return false end
    -- Party-wide target types = AoE (4 = everyone, 3 = everyone except caster)
    if targetType == 4 or targetType == 3 then return true end
    return false
end

--- Determine the smart default target for a spell.
function BfBot.Class.GetDefaultTarget(ability, isAoE)
    local targetType = ability.actionType
    -- Self-only spells
    if targetType == 5 or targetType == 7 then return "s" end
    -- AoE spells default to party
    if isAoE then return "p" end
    -- Single-target: default to self (user can override to party or specific member)
    return "s"
end

-- ============================================================
-- Override Management
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
-- Main Classification Function
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
        result.selfReplacePenalty = 0
        result.splstates = {}
        result.selfReplace = false
        result.hasSubstantive = true
        result.noSubstance = false
        result.friendlyFlag = false

        -- Duration computed per-sprite in scan entry, not here (classification is resref-level)
        result.isAoE = BfBot.Class.IsAoE(ability, false)
        result.defaultTarget = BfBot.Class.GetDefaultTarget(ability, result.isAoE)

        BfBot._cache.class[resref] = result
        return result
    end

    result.overridden = false
    result.noSubstance = false

    -- Step 1: Targeting score
    result.targetScore, result.friendlyFlag = BfBot.Class.ScoreTargeting(ability)

    -- Step 2: MSECTYPE score
    result.msecScore = BfBot.Class.ScoreMSECTYPE(header)

    -- Step 3: Opcode score + extract metadata
    local opcodeExtras
    result.opcodeScore, opcodeExtras = BfBot.Class.ScoreOpcodes(header, ability, resref)
    result.splstates = opcodeExtras.splstates
    result.selfReplace = opcodeExtras.selfReplace
    result.isToggle = opcodeExtras.isToggle
    result.hasSubstantive = opcodeExtras.hasSubstantive

    -- Toggle penalty: opcode 318 self-ref = stance/toggle, not prebuff
    -- (opcode 321 self-ref = normal buff refresh, no penalty)
    result.selfReplacePenalty = result.isToggle and -8 or 0

    -- Total score
    result.score = result.targetScore + result.msecScore
        + result.opcodeScore + result.selfReplacePenalty

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

    -- Step 5: Substance check
    -- If score passed threshold but no substantive buff opcode
    -- contributed, the score came entirely from targeting/MSECTYPE/
    -- infrastructure. Not a real buff.
    if result.isBuff and not result.hasSubstantive then
        result.isBuff = false
        result.isAmbiguous = true
        result.noSubstance = true
    end

    -- Duration computed per-sprite in scan entry, not here (classification is resref-level)

    -- AoE
    result.isAoE = BfBot.Class.IsAoE(ability, opcodeExtras.fbAoE)

    -- Default target
    result.defaultTarget = BfBot.Class.GetDefaultTarget(ability, result.isAoE)

    -- Cache and return
    BfBot._cache.class[resref] = result
    return result
end
