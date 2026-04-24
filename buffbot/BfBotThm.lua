-- BfBotThm.lua — Theme palettes + accessor.
-- Loaded after BfBotCor but before BfBotUI (UI references _T).
BfBot = BfBot or {}
BfBot.Theme = BfBot.Theme or {}

-- ============================================================
-- Palette Key Glossary
--
-- Meta (not colors):
--   overlay      — dark-mode rectangle opacity (0-255; 0=off)
--   borderResref — PVRZ resref for the 9-slice border texture
--   bgResref     — PVRZ resref for the panel background MOS
--
-- Generic text colors:
--   title        — panel and sub-menu headers
--   text         — default body text (spell names, inputs)
--   textMuted    — disabled/unavailable text
--   textAccent   — emphasized text (user-added spell override)
--
-- Menu-region specific:
--   grip         — resize grip in bottom-right corner
--   reset        — "Reset Layout" button text
--   headerSub    — target picker / column headers
--   lockText     — "Lock" label text next to the lock column
--   spellLocked  — spell name tint when that row is locked
--
-- Target picker row states:
--   pickerSel    — currently-selected row
--   pickerOn     — checked (in the target set)
--   pickerOff    — unchecked
--
-- Quick Cast button states:
--   qcOff        — Normal casting speed (default)
--   qcLong       — Fast casting for long buffs only
--   qcAll        — Fast casting for all buffs (cheat)
--
-- Lock column character ('[L]' / '[ ]'):
--   lockActive   — color when spell is locked
--   lockInactive — color when spell is unlocked
-- ============================================================

-- Six palettes keyed as <accent>_<mode>.
-- Each palette is flat; _T(key) reads from the active palette.
BfBot.Theme._palettes = {
    bg2_light = {
        overlay      = 0,
        borderResref = "BFBOTFR",
        bgResref     = "BFBOTBG",
        -- Generic
        title        = "{50, 30, 10}",
        text         = "{50, 30, 10}",
        textMuted    = "{140, 130, 120}",
        textAccent   = "{40, 80, 160}",
        -- Specific menu regions
        grip         = "{120, 100, 70}",
        reset        = "{180, 160, 130}",
        headerSub    = "{120, 90, 20}",
        lockText     = "{150, 120, 80}",
        spellLocked  = "{100, 70, 20}",
        -- Picker
        pickerSel    = "{255, 255, 150}",
        pickerOn     = "{220, 220, 220}",
        pickerOff    = "{140, 140, 140}",
        -- QuickCast
        qcOff        = "{80, 60, 40}",
        qcLong       = "{160, 120, 20}",
        qcAll        = "{180, 60, 30}",
        -- Lock column
        lockActive   = "{230, 200, 60}",
        lockInactive = "{120, 100, 80}",
    },
    bg2_dark = {
        overlay      = 160,
        borderResref = "BFBOTFR",
        bgResref     = "BFBOTBG",
        title        = "{230, 200, 150}",
        text         = "{210, 190, 160}",
        textMuted    = "{130, 120, 105}",
        textAccent   = "{130, 180, 240}",
        grip         = "{180, 150, 110}",
        reset        = "{200, 180, 150}",
        headerSub    = "{220, 180, 100}",
        lockText     = "{180, 160, 120}",
        spellLocked  = "{230, 190, 110}",
        pickerSel    = "{255, 240, 140}",
        pickerOn     = "{210, 200, 180}",
        pickerOff    = "{130, 120, 110}",
        qcOff        = "{160, 140, 110}",
        qcLong       = "{230, 200, 80}",
        qcAll        = "{240, 120, 70}",
        lockActive   = "{250, 220, 90}",
        lockInactive = "{150, 135, 115}",
    },
    sod_light = {
        overlay      = 60,
        borderResref = "BFBOTFR2",
        bgResref     = "BFBOTBG2",
        title        = "{220, 230, 240}",
        text         = "{220, 225, 235}",
        textMuted    = "{150, 160, 170}",
        textAccent   = "{140, 200, 240}",
        grip         = "{180, 190, 210}",
        reset        = "{200, 210, 225}",
        headerSub    = "{170, 200, 220}",
        lockText     = "{170, 180, 200}",
        spellLocked  = "{200, 220, 240}",
        pickerSel    = "{255, 255, 180}",
        pickerOn     = "{230, 235, 245}",
        pickerOff    = "{140, 150, 165}",
        qcOff        = "{130, 140, 160}",
        qcLong       = "{200, 200, 90}",
        qcAll        = "{240, 130, 80}",
        lockActive   = "{240, 220, 110}",
        lockInactive = "{130, 140, 160}",
    },
    sod_dark = {
        overlay      = 180,
        borderResref = "BFBOTFR2",
        bgResref     = "BFBOTBG2",
        title        = "{200, 220, 235}",
        text         = "{190, 210, 225}",
        textMuted    = "{130, 145, 155}",
        textAccent   = "{120, 190, 240}",
        grip         = "{160, 180, 200}",
        reset        = "{180, 200, 220}",
        headerSub    = "{160, 200, 230}",
        lockText     = "{160, 170, 190}",
        spellLocked  = "{180, 210, 235}",
        pickerSel    = "{255, 250, 170}",
        pickerOn     = "{220, 230, 245}",
        pickerOff    = "{130, 145, 160}",
        qcOff        = "{130, 140, 165}",
        qcLong       = "{220, 220, 90}",
        qcAll        = "{240, 120, 70}",
        lockActive   = "{240, 220, 110}",
        lockInactive = "{130, 145, 165}",
    },
    bg1_light = {
        overlay      = 60,
        borderResref = "BFBOTFR3",
        bgResref     = "BFBOTBG3",
        title        = "{230, 200, 160}",
        text         = "{220, 195, 160}",
        textMuted    = "{160, 140, 120}",
        textAccent   = "{240, 180, 100}",
        grip         = "{200, 170, 130}",
        reset        = "{220, 195, 170}",
        headerSub    = "{230, 180, 90}",
        lockText     = "{190, 160, 120}",
        spellLocked  = "{240, 190, 100}",
        pickerSel    = "{255, 240, 140}",
        pickerOn     = "{230, 215, 195}",
        pickerOff    = "{150, 135, 120}",
        qcOff        = "{150, 130, 105}",
        qcLong       = "{220, 190, 80}",
        qcAll        = "{240, 130, 80}",
        lockActive   = "{250, 220, 100}",
        lockInactive = "{160, 140, 120}",
    },
    bg1_dark = {
        overlay      = 180,
        borderResref = "BFBOTFR3",
        bgResref     = "BFBOTBG3",
        title        = "{240, 200, 130}",
        text         = "{220, 190, 150}",
        textMuted    = "{150, 130, 110}",
        textAccent   = "{240, 170, 90}",
        grip         = "{190, 165, 125}",
        reset        = "{220, 190, 150}",
        headerSub    = "{230, 175, 80}",
        lockText     = "{180, 150, 115}",
        spellLocked  = "{240, 180, 90}",
        pickerSel    = "{255, 240, 140}",
        pickerOn     = "{220, 205, 180}",
        pickerOff    = "{140, 125, 110}",
        qcOff        = "{140, 120, 100}",
        qcLong       = "{225, 190, 75}",
        qcAll        = "{240, 120, 65}",
        lockActive   = "{255, 220, 95}",
        lockInactive = "{150, 135, 115}",
    },
}

-- Active palette reference; defaults to bg2_light (pixel-match current behavior).
BfBot.Theme._active = BfBot.Theme._palettes.bg2_light

--- Theme color accessor (PLACEHOLDER NAME — renamed to BfBot.UI._T in Task 3).
-- Returns the active palette's value for the given semantic key, or magenta
-- "{255, 0, 255}" if the key is missing (visible debug signal).
-- @param key string — one of the keys listed in the Palette Key Glossary above
function BfBot.UI_T_PENDING_MOVE(key)
    local v = BfBot.Theme._active[key]
    if v == nil then return "{255, 0, 255}" end
    return v
end
