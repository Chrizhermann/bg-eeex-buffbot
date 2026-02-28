-- ============================================================
-- BfBotInn.lua — Innate Ability Management (BfBot.Innate)
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

--- Build a cheat-mode helper SPL (BFBTCH.SPL) that grants Improved Alacrity
-- + casting time reduction for 300 seconds. Invisible, self-only, no icon/name.
-- @return string: raw SPL binary data (250 bytes)
function BfBot.Innate._BuildCheatSPL()
    local HEADER_SIZE = 0x72   -- 114 bytes
    local EXT_SIZE    = 0x28   -- 40 bytes
    local FEAT_SIZE   = 0x30   -- 48 bytes
    local extOffset   = HEADER_SIZE
    local featOffset  = HEADER_SIZE + EXT_SIZE

    -- SPL Header (114 bytes)
    local header = "SPL "                       -- 0x0000: Signature
        .. "V1  "                               -- 0x0004: Version
        .. _splDword(0xFFFFFFFF)                -- 0x0008: Unidentified name strref (none)
        .. _splDword(0xFFFFFFFF)                -- 0x000C: Identified name strref (none)
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
        .. _splDword(1)                         -- 0x0034: Spell level = 1
        .. _splWord(0)                          -- 0x0038: Stack amount
        .. _splResref("")                       -- 0x003A: Spellbook icon (none — invisible)
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
        .. _splResref("")                       -- 0x0004: Memorised icon (none — invisible)
        .. _splByte(5)                          -- 0x000C: Target = self
        .. _splByte(0)                          -- 0x000D: Target count
        .. _splWord(0)                          -- 0x000E: Range
        .. _splWord(1)                          -- 0x0010: Level required = 1
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

    -- Feature Block 1: Opcode 188 (Aura Cleansing / Improved Alacrity)
    local feat188 = _splWord(188)               -- 0x0000: Opcode
        .. _splByte(1)                          -- 0x0002: Target = self
        .. _splByte(0)                          -- 0x0003: Power
        .. _splDword(1)                         -- 0x0004: Param1 = 1 (enable)
        .. _splDword(0)                         -- 0x0008: Param2
        .. _splByte(0)                          -- 0x000C: Timing = 0 (duration)
        .. _splByte(0)                          -- 0x000D: Dispel/resistance
        .. _splDword(300)                       -- 0x000E: Duration = 300 seconds
        .. _splByte(100)                        -- 0x0012: Probability1
        .. _splByte(0)                          -- 0x0013: Probability2
        .. _splResref("")                       -- 0x0014: Resource
        .. _splDword(0)                         -- 0x001C: Dice thrown
        .. _splDword(0)                         -- 0x0020: Dice sides
        .. _splDword(0)                         -- 0x0024: Save type
        .. _splDword(0)                         -- 0x0028: Save bonus
        .. _splDword(0)                         -- 0x002C: Stacking ID

    -- Feature Block 2: Opcode 189 (Casting Time Modifier)
    local feat189 = _splWord(189)               -- 0x0000: Opcode
        .. _splByte(1)                          -- 0x0002: Target = self
        .. _splByte(0)                          -- 0x0003: Power
        .. _splDword(-10)                       -- 0x0004: Param1 = -10 (reduce by 10)
        .. _splDword(0)                         -- 0x0008: Param2
        .. _splByte(0)                          -- 0x000C: Timing = 0 (duration)
        .. _splByte(0)                          -- 0x000D: Dispel/resistance
        .. _splDword(300)                       -- 0x000E: Duration = 300 seconds
        .. _splByte(100)                        -- 0x0012: Probability1
        .. _splByte(0)                          -- 0x0013: Probability2
        .. _splResref("")                       -- 0x0014: Resource
        .. _splDword(0)                         -- 0x001C: Dice thrown
        .. _splDword(0)                         -- 0x0020: Dice sides
        .. _splDword(0)                         -- 0x0024: Save type
        .. _splDword(0)                         -- 0x0028: Save bonus
        .. _splDword(0)                         -- 0x002C: Stacking ID

    return header .. ability .. feat188 .. feat189
end

--- Build a cheat-mode remover SPL (BFBTCR.SPL) that removes BFBTCH effects.
-- Uses opcode 321 (Remove Effects by Resource) with instant/permanent timing.
-- @return string: raw SPL binary data (202 bytes)
function BfBot.Innate._BuildCheatRemoverSPL()
    local HEADER_SIZE = 0x72   -- 114 bytes
    local EXT_SIZE    = 0x28   -- 40 bytes
    local FEAT_SIZE   = 0x30   -- 48 bytes
    local extOffset   = HEADER_SIZE
    local featOffset  = HEADER_SIZE + EXT_SIZE

    -- SPL Header (114 bytes)
    local header = "SPL "                       -- 0x0000: Signature
        .. "V1  "                               -- 0x0004: Version
        .. _splDword(0xFFFFFFFF)                -- 0x0008: Unidentified name strref (none)
        .. _splDword(0xFFFFFFFF)                -- 0x000C: Identified name strref (none)
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
        .. _splDword(1)                         -- 0x0034: Spell level = 1
        .. _splWord(0)                          -- 0x0038: Stack amount
        .. _splResref("")                       -- 0x003A: Spellbook icon (none — invisible)
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
        .. _splResref("")                       -- 0x0004: Memorised icon (none — invisible)
        .. _splByte(5)                          -- 0x000C: Target = self
        .. _splByte(0)                          -- 0x000D: Target count
        .. _splWord(0)                          -- 0x000E: Range
        .. _splWord(1)                          -- 0x0010: Level required = 1
        .. _splWord(0)                          -- 0x0012: Casting time = instant
        .. _splWord(1)                          -- 0x0014: Times per day = 1
        .. _splWord(0)                          -- 0x0016: Dice sides
        .. _splWord(0)                          -- 0x0018: Dice thrown
        .. _splWord(0)                          -- 0x001A: Enchanted
        .. _splWord(0)                          -- 0x001C: Damage type
        .. _splWord(1)                          -- 0x001E: Feature block count = 1
        .. _splWord(0)                          -- 0x0020: Feature block offset (index)
        .. _splWord(0)                          -- 0x0022: Charges
        .. _splWord(0)                          -- 0x0024: Charge depletion
        .. _splWord(1)                          -- 0x0026: Projectile = 1 (none)

    -- Feature Block 1: Opcode 321 (Remove Effects by Resource)
    local feat321 = _splWord(321)               -- 0x0000: Opcode
        .. _splByte(1)                          -- 0x0002: Target = self
        .. _splByte(0)                          -- 0x0003: Power
        .. _splDword(0)                         -- 0x0004: Param1
        .. _splDword(0)                         -- 0x0008: Param2
        .. _splByte(1)                          -- 0x000C: Timing = 1 (instant/permanent)
        .. _splByte(0)                          -- 0x000D: Dispel/resistance
        .. _splDword(0)                         -- 0x000E: Duration = 0
        .. _splByte(100)                        -- 0x0012: Probability1
        .. _splByte(0)                          -- 0x0013: Probability2
        .. _splResref("BFBTCH")                 -- 0x0014: Resource = BFBTCH (target to remove)
        .. _splDword(0)                         -- 0x001C: Dice thrown
        .. _splDword(0)                         -- 0x0020: Dice sides
        .. _splDword(0)                         -- 0x0024: Save type
        .. _splDword(0)                         -- 0x0028: Save bonus
        .. _splDword(0)                         -- 0x002C: Stacking ID

    return header .. ability .. feat321
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

    -- Write cheat-mode helper SPLs
    local cheatPath = "override/BFBTCH.SPL"
    local cheatData = BfBot.Innate._BuildCheatSPL()
    local cf = io.open(cheatPath, "wb")
    if cf then
        cf:write(cheatData)
        cf:close()
        count = count + 1
    end

    local removerPath = "override/BFBTCR.SPL"
    local removerData = BfBot.Innate._BuildCheatRemoverSPL()
    local rf = io.open(removerPath, "wb")
    if rf then
        rf:write(removerData)
        rf:close()
        count = count + 1
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
        local qcMode = BfBot.Persist.GetQuickCast(sprite, presetIdx)
        BfBot.Exec.Start(queue, qcMode)
    end
end
