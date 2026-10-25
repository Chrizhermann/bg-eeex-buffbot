-- ============================================================
-- BfBotInn.lua — Runtime SPL files and F12 innate cleanup (BfBot.Innate)
-- Writes the Quick Cast helper SPLs and removes the per-preset F12
-- innate abilities that earlier versions granted.
-- BuffBot no longer runs presets from F12.
-- ============================================================

BfBot.Innate = {}

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
    -- Params match real IA (SPWI921): param1=0, param2=1 (enable mode)
    local feat188 = _splWord(188)               -- 0x0000: Opcode
        .. _splByte(1)                          -- 0x0002: Target = self
        .. _splByte(0)                          -- 0x0003: Power
        .. _splDword(0)                         -- 0x0004: Param1 = 0
        .. _splDword(1)                         -- 0x0008: Param2 = 1 (enable)
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
        .. _splDword(10)                        -- 0x0004: Param1 = 10 (reduce casting time by 10)
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

--- Write BuffBot's runtime SPL files to the override folder (always overwrites).
-- Called once at mod init time (before menus load). Earlier versions also
-- wrote the F12 preset SPLs (BFBT{slot}{preset}) and their remover BFBTRM;
-- copies of those stay in override and are never cast again (see BFBOTGO).
function BfBot.Innate._EnsureSPLFiles()
    if BfBot._noIO then return 0 end
    local count = 0

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

-- Object ids of the party members _RemoveLegacy has handled in this game.
BfBot.Innate._cleaned = {}

local function _spriteId(sprite)
    local ok, id = pcall(function() return sprite.m_id end)
    if ok and type(id) == "number" then return id end
    return nil
end

--- Log a message to the innate log file (append mode).
local function _InnateLog(msg)
    if not io then return end
    local logf = io.open("buffbot_innate.log", "a")
    if logf then
        logf:write(string.format("[%s] %s\n", os.date and os.date("%Y-%m-%d %H:%M:%S") or "?", msg))
        logf:close()
    end
end

--- Count the F12 preset innates (BFBT{slot}{preset}) an earlier version
-- granted to sprite. Returns the copies per resref (v1.3.9 could stack dozens
-- of one) and the total number of entries, or nil and the error when the
-- known-innate walk fails.
function BfBot.Innate._LegacyCopies(sprite)
    local counts, total = {}, 0
    local ok, err = pcall(function()
        for _, _, resref in EEex_Sprite_GetKnownInnateSpellsIterator(sprite) do
            if type(resref) == "string" then
                local key = resref:upper()
                if key:match("^BFBT[0-5][1-8]$") then
                    counts[key] = (counts[key] or 0) + 1
                    total = total + 1
                end
            end
        end
    end)
    if not ok then return nil, err end
    return counts, total
end

--- Remove the leftover F12 preset innates from sprite. Each opcode 172
-- application removes one known copy. EEex_GameObject_ApplyEffect resolves it
-- during the call, so the removal works while the game is paused, needs no
-- SPL file, and cannot be dropped the way a queued action is when the player
-- gives an order first. Returns the number removed and the number still known
-- afterwards, or nil and the error when the innates cannot be read.
function BfBot.Innate._RemoveFrom(sprite)
    local counts, total = BfBot.Innate._LegacyCopies(sprite)
    if not counts then return nil, total end
    if total == 0 then return 0, 0 end
    for resref, copies in pairs(counts) do
        for _ = 1, copies do
            EEex_GameObject_ApplyEffect(sprite, {
                effectID = 172,     -- Remove Spell (innates included)
                durationType = 1,   -- permanent, as BuffBot's remover SPL used
                res = resref,
            })
        end
    end
    local after, left = BfBot.Innate._LegacyCopies(sprite)
    if not after then return nil, left end
    return total - left, left
end

--- Remove the leftover F12 preset innates from every party member not handled
-- yet in this game; saves made before BuffBot dropped the feature still carry
-- them. Driven by the exec safety tick, not by a load event: on 2.7.3.0 with
-- EEex v1.3.1 the party loads before its members hold portrait slots, and a
-- companion who joins without a load fires none. A member is recorded before
-- the removal, so a failure cannot repeat every tick; one who leaves is
-- forgotten and handled again on rejoining. Object ids repeat between games,
-- so Init clears the record when a game is destroyed (load or exit).
function BfBot.Innate._RemoveLegacy()
    local present = {}
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        local id = sprite and _spriteId(sprite)
        if id then
            present[id] = true
            if not BfBot.Innate._cleaned[id] then
                BfBot.Innate._cleaned[id] = true
                local removed, left = BfBot.Innate._RemoveFrom(sprite)
                local name = BfBot._GetName(sprite)
                if not removed then
                    BfBot._Warn("[Innate] Could not read the innates of "
                        .. name .. ": " .. tostring(left))
                else
                    if removed > 0 then
                        _InnateLog(string.format(
                            "Removed %d leftover F12 preset innate(s) from %s",
                            removed, name))
                    end
                    if left > 0 then
                        BfBot._Warn(string.format(
                            "[Innate] %d leftover F12 preset innate(s) remain on %s",
                            left, name))
                    end
                end
            end
        end
    end
    for id in pairs(BfBot.Innate._cleaned) do
        if not present[id] then BfBot.Innate._cleaned[id] = nil end
    end
end

--- Register the game-destroyed listener once per game process. The root-level
-- guard survives force-reloading this module (which replaces the BfBot.Innate
-- table), and the listener reaches the current module through BfBot.Innate.
function BfBot.Innate.Init()
    if not BfBot._innateCleanupListenerRegistered then
        EEex_GameState_AddDestroyedListener(BfBot._SafeCallback(
            "innate.game_destroyed", function()
                if BfBot.Innate then BfBot.Innate._cleaned = {} end
            end))
        BfBot._innateCleanupListenerRegistered = true
    end
end

-- ============================================================
-- Leftover F12 Innate Handler (Global Function for Opcode 402)
-- ============================================================

--- Opcode 402 handler named by the F12 preset SPLs of earlier versions. Those
-- SPL files can outlive the feature in override, and a party member carries
-- the innates until _RemoveLegacy has run, so a click must stay harmless:
-- opcode 402 shows "panic" when its handler is missing or throws. The click
-- runs nothing and is only noted in the innate log.
function BFBOTGO(param1)
    pcall(function()
        _InnateLog(string.format(
            "Ignored a leftover F12 preset innate (slot %s, preset %s)",
            tostring(param1 and param1.m_effectAmount),
            tostring(param1 and param1.m_dWFlags)))
    end)
end
