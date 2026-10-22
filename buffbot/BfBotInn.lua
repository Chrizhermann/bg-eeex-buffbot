-- Retired preset shortcuts: upgrade cleanup plus helper resources used by the
-- legacy caster editor. No shortcut SPL generation, grants or recharge hooks.
BfBot.Innate = nil -- Retire callbacks retained by a live module reload.
BfBot.Legacy = { pending = {} }
local L = BfBot.Legacy

local function retired(res)
    return type(res)=='string' and res:upper():match('^BFBT[0-5][1-8]$')~=nil
end

-- Count before changing either engine list. Include spent/memorized-only entries
-- and duplicate copies left by older versions; preserve all real game abilities.
function L.PresetAbilityCounts(sprite)
    local counts,memCounts={},{}
    for _,_,res in EEex_Sprite_GetKnownInnateSpellsIterator(sprite) do
        if retired(res) then res=res:upper();counts[res]=(counts[res] or 0)+1 end
    end
    if sprite.m_memorizedSpellsInnate then
        local list=sprite.m_memorizedSpellsInnate:getReference(0)
        if list then EEex_Utility_IterateCPtrList(list,function(mem)
            local res=mem.m_spellId:get()
            if retired(res) then res=res:upper();memCounts[res]=(memCounts[res] or 0)+1 end
        end) end
    end
    for res,count in pairs(memCounts) do counts[res]=math.max(counts[res] or 0,count) end
    return counts
end
function L.RemovePresetAbilities(sprite)
    local counts=L.PresetAbilityCounts(sprite)
    local removed=0
    for res,count in pairs(counts) do
        for _=1,count do
            sprite:applyEffect({effectID=172,timing=1,res=res,sourceID=sprite.m_id,targetID=sprite.m_id})
            removed=removed+1
        end
    end
    return removed
end
function L.QueueCleanup(sprite)
    if sprite and next(L.PresetAbilityCounts(sprite)) then L.pending[sprite.m_id]=true end
end
function L.Tick()
    if not e or not worldScreen or e:GetActiveEngine()~=worldScreen then return end
    if BfBot.Exec.GetState()=='running' or BfBot.Share and BfBot.Share.run then return end
    local n=0
    for id in pairs(L.pending) do
        local sprite=EEex_GameObject_Get(id)
        if sprite and EEex_GameObject_IsSprite(sprite,false) then
            L.RemovePresetAbilities(EEex_GameObject_CastUserType(sprite))
        end
        L.pending[id]=nil;n=n+1
        if n>=6 then break end
    end
end
function L.Init()
    if BfBot._retiredAbilitiesListenerRegistered then return end
    BfBot._retiredAbilitiesListenerRegistered=true
    EEex_Sprite_AddLoadedListener(BfBot._SafeCallback("legacy.preset_cleanup",function(sprite)
        BfBot.Legacy.QueueCleanup(sprite)
    end))
end

-- A saved action may still reference an old opcode-402 shortcut. It must never
-- dispatch a plan after the feature is removed; the next world tick removes it.
function BFBOTGO() end

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

function BfBot.Legacy._BuildCheatSPL()
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
function BfBot.Legacy._BuildCheatRemoverSPL()
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


-- These two invisible helpers belong to the original caster editor's quick mode.
-- They are not preset abilities and are never granted to a character.
function L.EnsureHelperSpells()
    if BfBot._noIO then return end
    for name,data in pairs({BFBTCH=L._BuildCheatSPL(),BFBTCR=L._BuildCheatRemoverSPL()}) do
        local f=io.open('override/'..name..'.SPL','wb')
        if f then f:write(data);f:close() end
    end
end
