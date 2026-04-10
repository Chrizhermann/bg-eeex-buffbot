-- ============================================================
-- BfBotUI.lua — BuffBot Configuration UI
-- Lua-side logic for the BuffBot panel (.menu callbacks,
-- state management, spell table population)
-- ============================================================

BfBot.UI = {}

-- ============================================================
-- Internal State
-- ============================================================

BfBot.UI._charSlot = 0        -- selected character slot (0-5)
BfBot.UI._presetIdx = 1       -- selected preset index (1-5)
BfBot.UI._initialized = false

-- Panel geometry (nil = use default 80%-centered)
BfBot.UI._panelX = nil
BfBot.UI._panelY = nil
BfBot.UI._panelW = nil
BfBot.UI._panelH = nil

-- Minimum panel dimensions (widest button row ~420px + padding)
BfBot.UI._MIN_W = 550
BfBot.UI._MIN_H = 350

--- Ensure _presetIdx points to a valid preset for the given config.
-- Returns the clamped index (also sets BfBot.UI._presetIdx).
function BfBot.UI._ClampPresetIdx(config)
    if config and config.presets and config.presets[BfBot.UI._presetIdx] then
        return BfBot.UI._presetIdx  -- already valid
    end
    -- Fall back to config.ap, then first valid preset
    if config and config.presets then
        if config.ap and config.presets[config.ap] then
            BfBot.UI._presetIdx = config.ap
            return config.ap
        end
        for i = 1, BfBot.MAX_PRESETS do
            if config.presets[i] then
                BfBot.UI._presetIdx = i
                return i
            end
        end
    end
    BfBot.UI._presetIdx = 1
    return 1
end

-- ============================================================
-- Global Variables (read by .menu expressions every frame)
-- ALL values must be numbers/strings/tables — NO BOOLEANS.
-- EEex marshal crashes on booleans in UDAux.
-- ============================================================

-- Panel state
buffbot_isOpen = false
buffbot_title = "BuffBot"
buffbot_status = ""
buffbot_btnTooltip = "BuffBot Configuration"
buffbot_btnFrame = 0             -- 0=normal, 1=active/running

-- Character tabs (1-indexed; nil entries = empty party slot)
buffbot_charNames = {}           -- {[1]="Charname", [2]="Jaheira", ...}

-- Preset tabs (1-indexed; nil entries = no preset at that index)
buffbot_presetNames = {}         -- {[1]="Long Buffs", [2]="Short Buffs"}
buffbot_presetCount = 0          -- number of active presets

-- Spell list (1-indexed array for list widget)
buffbot_spellTable = {}
buffbot_selectedRow = 0

-- Cast button labels
buffbot_castLabel = "Cast All"
buffbot_castCharLabel = "Cast Character"

-- Target picker state
buffbot_targetRow = 0            -- which spell row opened the picker
buffbot_targetHeader = ""        -- header text for target picker (spell name)
buffbot_targetLocked = 0         -- 1 if spell is self-only/AoE and not unlocked
buffbot_targetLockText = ""      -- "(Self-only)" or "(Party-wide)" for locked spells
buffbot_pickerOrder = {}         -- all party names in display/priority order (reorderable)
buffbot_pickerChecked = {}       -- {[name]=1} for names included in target list
buffbot_tgtPickerSel = 0         -- selected ROW index in picker (1-6, for Up/Down/highlight)

-- Rename dialog state
buffbot_renameInput = ""

-- Spell picker state (for "Add Spell" sub-menu)
buffbot_pickerSpells = {}
buffbot_pickerSelected = 0

-- Import picker state (for "Import Config" sub-menu)
buffbot_importList = {}
buffbot_importSelected = 0

-- Variant picker state (for "Select Variant" sub-menu)
buffbot_selectedHasVariants = 0    -- 0/1: does the selected spell have variants?
buffbot_variantTable = {}          -- array for variant picker list
buffbot_variantHeader = ""         -- header text for variant picker
buffbot_variantSelected = 0        -- selected row in variant picker

-- ============================================================
-- Runtime MOS Generation (ultrawide / high-res support)
-- ============================================================

--- Generate BFBOTBG.MOS sized to the current screen by tiling existing
-- PVRZ blocks. The base parchment tile is 2048x1152 (4 PVRZ blocks).
-- At resolutions where 80% of screen exceeds that, the static MOS
-- leaves a black gap. This function writes a tiled MOS V2 to override.
function BfBot.UI._GenerateBgMOS()
    if BfBot._noIO then return end
    local sw, sh = Infinity_GetScreenSize()
    if not sw or not sh then return end

    -- Panel is 80% of screen; add margin so MOS fully covers border overhang
    local pw = math.floor(sw * 0.8) + 64
    local ph = math.floor(sh * 0.8) + 64

    -- How many times to repeat the 2048x1152 base tile
    local tilesX = math.ceil(pw / 2048)
    local tilesY = math.ceil(ph / 1152)
    local mosW = tilesX * 2048
    local mosH = tilesY * 1152

    -- Skip regeneration if current MOS already covers this size
    if BfBot.UI._mosW and BfBot.UI._mosW >= mosW and BfBot.UI._mosH >= mosH then
        return
    end

    -- MOS V2 binary helpers
    local function u32(n)
        return string.char(
            n % 256,
            math.floor(n / 256) % 256,
            math.floor(n / 65536) % 256,
            math.floor(n / 16777216) % 256
        )
    end

    -- Base tile: 4 PVRZ blocks composing a 2048x1152 parchment tile
    --   MOS9900 (1024x1024) @ (0,0)     | MOS9901 (1024x1024) @ (1024,0)
    --   MOS9902 (1024x128)  @ (0,1024)   | MOS9903 (1024x128)  @ (1024,1024)
    local blocks = {
        { page = 0x26AC, w = 1024, h = 1024, ox = 0,    oy = 0    },  -- MOS9900
        { page = 0x26AD, w = 1024, h = 1024, ox = 1024, oy = 0    },  -- MOS9901
        { page = 0x26AE, w = 1024, h = 128,  ox = 0,    oy = 1024 },  -- MOS9902
        { page = 0x26AF, w = 1024, h = 128,  ox = 1024, oy = 1024 },  -- MOS9903
    }

    local numBlocks = tilesX * tilesY * 4
    local parts = {}

    -- MOS V2 header (24 bytes)
    parts[#parts + 1] = "MOS V2  "
    parts[#parts + 1] = u32(mosW)
    parts[#parts + 1] = u32(mosH)
    parts[#parts + 1] = u32(numBlocks)
    parts[#parts + 1] = u32(24)  -- offset to block entries

    -- Block entries (28 bytes each): tile the base pattern across the target area
    for ty = 0, tilesY - 1 do
        for tx = 0, tilesX - 1 do
            for _, b in ipairs(blocks) do
                parts[#parts + 1] = u32(b.page)   -- PVRZ page
                parts[#parts + 1] = u32(0)         -- source X (always 0)
                parts[#parts + 1] = u32(0)         -- source Y (always 0)
                parts[#parts + 1] = u32(b.w)       -- width
                parts[#parts + 1] = u32(b.h)       -- height
                parts[#parts + 1] = u32(tx * 2048 + b.ox)  -- target X
                parts[#parts + 1] = u32(ty * 1152 + b.oy)  -- target Y
            end
        end
    end

    local ok, err = pcall(function()
        local f = io.open("override/BFBOTBG.MOS", "wb")
        if f then
            f:write(table.concat(parts))
            f:close()
        end
    end)

    if ok then
        BfBot.UI._mosW = mosW
        BfBot.UI._mosH = mosH
    end
end

-- ============================================================
-- Layout Persistence (INI-backed panel position/size)
-- ============================================================

--- Load saved panel geometry from INI. Values of 0 mean "use default".
function BfBot.UI._LoadLayout()
    local x = BfBot.Persist.GetPref("PanelX")
    local y = BfBot.Persist.GetPref("PanelY")
    local w = BfBot.Persist.GetPref("PanelW")
    local h = BfBot.Persist.GetPref("PanelH")
    BfBot.UI._panelX = (x >= 0) and x or nil
    BfBot.UI._panelY = (y >= 0) and y or nil
    BfBot.UI._panelW = (w > 0) and w or nil
    BfBot.UI._panelH = (h > 0) and h or nil
end

--- Save current panel geometry to INI.
function BfBot.UI._SaveLayout()
    BfBot.Persist.SetPref("PanelX", BfBot.UI._panelX or -1)
    BfBot.Persist.SetPref("PanelY", BfBot.UI._panelY or -1)
    BfBot.Persist.SetPref("PanelW", BfBot.UI._panelW or -1)
    BfBot.Persist.SetPref("PanelH", BfBot.UI._panelH or -1)
end

-- ============================================================
-- Initialization (called from M_BfBot.lua listener)
-- ============================================================

function BfBot.UI._OnMenusLoaded()
    -- Generate resolution-appropriate parchment background MOS
    -- MUST happen before EEex_Menu_LoadFile so the menu picks up the right MOS
    BfBot.UI._GenerateBgMOS()

    -- Load our .menu definitions
    EEex_Menu_LoadFile("BuffBot")

    -- Register 9-slice border texture for custom panel frame
    -- Wrapped in pcall — stores status for later console inspection
    BfBot.UI._borderStatus = "not attempted"
    local regOk, regErr = pcall(function()
        EEex.RegisterSlicedRect("BuffBot_Border", {
            ["topLeft"]     = {   0,   0, 128, 128 },
            ["top"]         = { 128,   0, 256, 128 },
            ["topRight"]    = { 384,   0, 128, 128 },
            ["right"]       = { 384, 128, 128, 256 },
            ["bottomRight"] = { 384, 384, 128, 128 },
            ["bottom"]      = { 128, 384, 256, 128 },
            ["bottomLeft"]  = {   0, 384, 128, 128 },
            ["left"]        = {   0, 128, 128, 256 },
            ["center"]      = { 128, 128, 256, 256 },
            ["dimensions"]  = { 512, 512 },
            ["resref"]      = "BFBOTFR",
            ["flags"]       = 0,
        })
    end)
    BfBot.UI._borderStatus = regOk and "registered" or ("FAILED: " .. tostring(regErr))

    -- Render hooks: draw 9-slice border on main panel + all sub-menus
    if regOk then
        local borderHook = function(item)
            pcall(function()
                EEex.DrawSlicedRect("BuffBot_Border", { item:getArea() })
            end)
        end
        EEex_Menu_AddBeforeUIItemRenderListener("bbBgFrame",  borderHook)
        EEex_Menu_AddBeforeUIItemRenderListener("bbTgtFrame", borderHook)
        EEex_Menu_AddBeforeUIItemRenderListener("bbRenFrame", borderHook)
        EEex_Menu_AddBeforeUIItemRenderListener("bbPickFrame", borderHook)
        EEex_Menu_AddBeforeUIItemRenderListener("bbImpFrame", borderHook)
        EEex_Menu_AddBeforeUIItemRenderListener("bbVarFrame", borderHook)
    end

    -- Hook WORLD_ACTIONBAR open/close to push/pop companion button menu
    -- (same pattern as B3EffMen.lua — avoids fighting for space inside the actionbar)
    local actionbarMenu = EEex_Menu_Find("WORLD_ACTIONBAR")

    local oldOnOpen = EEex_Menu_GetItemFunction(actionbarMenu.reference_onOpen)
    EEex_Menu_SetItemFunction(actionbarMenu.reference_onOpen, function()
        local result = oldOnOpen()
        BfBot.UI._OpenActionbarBtn()
        return result
    end)

    local oldOnClose = EEex_Menu_GetItemFunction(actionbarMenu.reference_onClose)
    EEex_Menu_SetItemFunction(actionbarMenu.reference_onClose, function()
        BfBot.UI._CloseActionbarBtn()
        return oldOnClose()
    end)

    -- F11 hotkey
    EEex_Key_AddPressedListener(BfBot.UI._OnKeyPressed)

    -- Sprite listeners for auto-refresh (invalidate cache, then refresh panel)
    EEex_Sprite_AddQuickListsCheckedListener(BfBot.UI._OnSpellListChanged)
    EEex_Sprite_AddQuickListCountsResetListener(BfBot.UI._OnSpellCountsReset)
    EEex_Sprite_AddQuickListNotifyRemovedListener(BfBot.UI._OnSpellRemoved)

    -- Resolution change: regenerate MOS, clamp stored geometry, re-layout
    EEex_Menu_AddWindowSizeChangedListener(function(w, h)
        BfBot.UI._GenerateBgMOS()
        -- Clamp stored geometry to new screen bounds
        if BfBot.UI._panelW or BfBot.UI._panelH or BfBot.UI._panelX or BfBot.UI._panelY then
            local sw, sh = w, h
            if BfBot.UI._panelW and BfBot.UI._panelW > sw then BfBot.UI._panelW = nil end
            if BfBot.UI._panelH and BfBot.UI._panelH > sh then BfBot.UI._panelH = nil end
            local cpw = BfBot.UI._panelW or math.floor(sw * 0.8)
            local cph = BfBot.UI._panelH or math.floor(sh * 0.8)
            if BfBot.UI._panelX and BfBot.UI._panelX + cpw > sw then
                BfBot.UI._panelX = math.max(0, sw - cpw)
            end
            if BfBot.UI._panelY and BfBot.UI._panelY + cph > sh then
                BfBot.UI._panelY = math.max(0, sh - cph)
            end
        end
        if buffbot_isOpen then
            BfBot.UI._Layout()
        end
    end)

    -- Load debug mode preference from INI
    local debugPref = Infinity_GetINIValue("BuffBot", "Debug", 0)
    BfBot._debugMode = (debugPref == 1) and 1 or 0

    -- Load saved panel geometry from INI
    BfBot.UI._LoadLayout()

    BfBot.UI._initialized = true
end

-- ============================================================
-- Actionbar Companion Button (pushed/popped with WORLD_ACTIONBAR)
-- ============================================================

function BfBot.UI._OpenActionbarBtn()
    -- Position flush to the right of WORLD_ACTIONBAR at any resolution
    local ax, ay, aw, ah = EEex_Menu_GetArea("WORLD_ACTIONBAR")
    if ax then
        Infinity_SetOffset("BUFFBOT_ACTIONBAR", ax + aw, ay)
    end
    Infinity_PushMenu("BUFFBOT_ACTIONBAR")
end

function BfBot.UI._CloseActionbarBtn()
    Infinity_PopMenu("BUFFBOT_ACTIONBAR")
end

-- ============================================================
-- Dynamic Layout (user-stored or default 80% of screen)
-- ============================================================

function BfBot.UI._Layout()
    local sw, sh = Infinity_GetScreenSize()
    if not sw or not sh then return end
    local pw = BfBot.UI._panelW or math.floor(sw * 0.8)
    local ph = BfBot.UI._panelH or math.floor(sh * 0.8)
    local px = BfBot.UI._panelX or math.floor((sw - pw) / 2)
    local py = BfBot.UI._panelY or math.floor((sh - ph) / 2)
    local pad = 10
    local cx = px + pad
    local cw = pw - 2 * pad

    -- Panel background (parchment inside, border frame extends 24px beyond)
    Infinity_SetArea("bbBg", px, py, pw, ph)
    local bpad = 24  -- border overhang in pixels
    Infinity_SetArea("bbBgFrame", px - bpad, py - bpad, pw + 2 * bpad, ph + 2 * bpad)

    -- Title
    Infinity_SetArea("bbTitle", px, py + 5, pw, 30)

    -- Character tabs (6 buttons, evenly spaced)
    local charY = py + 40
    local charH = 24
    local charGap = 4
    local charW = math.floor((cw - 5 * charGap) / 6)
    for i = 0, 5 do
        Infinity_SetArea("bbC" .. i, cx + i * (charW + charGap), charY, charW, charH)
    end

    -- Preset tabs (up to MAX_PRESETS buttons + Rename 56px + New 50px)
    local preY = py + 68
    local preH = 24
    local preGap = 3
    local renW = 56
    local newW = 50
    local maxP = BfBot.MAX_PRESETS
    local preAvailW = cw - renW - newW - 2 * preGap
    local preW = math.floor((preAvailW - (maxP - 1) * preGap) / maxP)
    for i = 1, maxP do
        Infinity_SetArea("bbP" .. i, cx + (i - 1) * (preW + preGap), preY, preW, preH)
    end
    local renX = cx + maxP * (preW + preGap)
    Infinity_SetArea("bbRen", renX, preY, renW, preH)
    Infinity_SetArea("bbNew", renX + renW + preGap, preY, newW, preH)

    -- Spell list (fills middle area)
    local listY = py + 98
    local footerH = 130
    local listH = math.max(ph - 98 - footerH, 50)
    Infinity_SetArea("bbList", cx, listY, cw, listH)

    -- Bottom rows (positioned from panel bottom)
    local btnH = 28
    local r4Y = py + ph - footerH + 4   -- Override buttons
    local r5Y = r4Y + 32                -- Spell action buttons
    local r6Y = r5Y + 32                -- Action buttons
    local r7Y = r6Y + 32                -- Status

    -- Override buttons: Add Spell + Remove (left) + Export + Import (right)
    Infinity_SetArea("bbAdd", cx, r4Y, 120, btnH)
    Infinity_SetArea("bbRmv", cx + 126, r4Y, 120, btnH)
    Infinity_SetArea("bbImp", cx + cw - 90, r4Y, 90, btnH)
    Infinity_SetArea("bbExp", cx + cw - 90 - 96, r4Y, 90, btnH)

    -- Spell action buttons: Toggle, Target, Up, Down, Sort, Delete Preset (normal layout)
    Infinity_SetArea("bbTog", cx, r5Y, 120, btnH)
    Infinity_SetArea("bbTgt", cx + 126, r5Y, 160, btnH)
    Infinity_SetArea("bbUp", cx + 292, r5Y, 48, btnH)
    Infinity_SetArea("bbDn", cx + 344, r5Y, 48, btnH)
    Infinity_SetArea("bbSort", cx + 398, r5Y, 48, btnH)
    Infinity_SetArea("bbDel", cx + cw - 130, r5Y, 130, btnH)

    -- Spell action buttons: variant layout (squeezed with Variant button)
    Infinity_SetArea("bbVTog", cx, r5Y, 90, btnH)
    Infinity_SetArea("bbVTgt", cx + 94, r5Y, 110, btnH)
    Infinity_SetArea("bbVVar", cx + 208, r5Y, 110, btnH)
    Infinity_SetArea("bbVUp", cx + 322, r5Y, 44, btnH)
    Infinity_SetArea("bbVDn", cx + 370, r5Y, 44, btnH)
    Infinity_SetArea("bbVSort", cx + 418, r5Y, 44, btnH)
    Infinity_SetArea("bbVDel", cx + cw - 102, r5Y, 102, btnH)

    -- Action buttons: Cast All, Cast Char, Stop — left side; Quick Cast, Close — right side
    local closeW = 80
    local qcW = 180
    local castAllW = 100
    local castCharW = 140
    local stopW = 60
    Infinity_SetArea("bbCast", cx, r6Y, castAllW, btnH)
    Infinity_SetArea("bbCastChar", cx + castAllW + 4, r6Y, castCharW, btnH)
    Infinity_SetArea("bbStop", cx + castAllW + castCharW + 8, r6Y, stopW, btnH)
    Infinity_SetArea("bbClose", cx + cw - closeW, r6Y, closeW, btnH)
    Infinity_SetArea("bbQC", cx + cw - closeW - qcW - 6, r6Y, qcW, btnH)

    -- Status line
    Infinity_SetArea("bbStatus", cx, r7Y, cw, 24)

    -- Drag handle covers title bar area
    Infinity_SetArea("bbDragHandle", px, py, pw, 35)

    -- Resize grip visual + handle at bottom-right corner
    Infinity_SetArea("bbResizeGrip", px + pw - 20, py + ph - 20, 20, 20)
    Infinity_SetArea("bbResizeHandle", px + pw - 80, py + ph - 48, 80, 48)

    -- Reset button in title bar (right-aligned, 50px wide)
    Infinity_SetArea("bbReset", px + pw - 60, py + 5, 50, 24)
end

-- ============================================================
-- Drag & Resize Handlers (called by .menu handle elements)
-- ============================================================

--- Called per-frame during title bar drag. Moves the panel.
function BfBot.UI._OnDrag()
    local dx = motionX or 0
    local dy = motionY or 0
    if dx == 0 and dy == 0 then return end

    local sw, sh = Infinity_GetScreenSize()
    if not sw or not sh then return end

    -- Materialize all 4 values on first interaction
    local pw = BfBot.UI._panelW or math.floor(sw * 0.8)
    local ph = BfBot.UI._panelH or math.floor(sh * 0.8)
    local px = (BfBot.UI._panelX or math.floor((sw - pw) / 2)) + dx
    local py = (BfBot.UI._panelY or math.floor((sh - ph) / 2)) + dy

    -- Clamp to screen (keep fully on-screen)
    px = math.max(0, math.min(px, sw - pw))
    py = math.max(0, math.min(py, sh - ph))

    BfBot.UI._panelX = px
    BfBot.UI._panelY = py
    BfBot.UI._panelW = pw
    BfBot.UI._panelH = ph
    BfBot.UI._Layout()
end

--- Called per-frame during bottom-right corner drag. Resizes the panel.
function BfBot.UI._OnResize()
    local dx = motionX or 0
    local dy = motionY or 0
    if dx == 0 and dy == 0 then return end

    local sw, sh = Infinity_GetScreenSize()
    if not sw or not sh then return end

    local pw = (BfBot.UI._panelW or math.floor(sw * 0.8)) + dx
    local ph = (BfBot.UI._panelH or math.floor(sh * 0.8)) + dy

    -- Enforce minimums
    pw = math.max(BfBot.UI._MIN_W, pw)
    ph = math.max(BfBot.UI._MIN_H, ph)

    -- Materialize position + clamp size to screen
    local px = BfBot.UI._panelX or math.floor((sw - pw) / 2)
    local py = BfBot.UI._panelY or math.floor((sh - ph) / 2)
    pw = math.min(pw, sw - px)
    ph = math.min(ph, sh - py)

    BfBot.UI._panelX = px
    BfBot.UI._panelY = py
    BfBot.UI._panelW = pw
    BfBot.UI._panelH = ph

    -- Regenerate MOS if panel + border exceeds current texture
    local bpad = 24
    local needW = pw + 2 * bpad + 64
    local needH = ph + 2 * bpad + 64
    if not BfBot.UI._mosW or needW > BfBot.UI._mosW
       or not BfBot.UI._mosH or needH > BfBot.UI._mosH then
        BfBot.UI._GenerateBgMOS()
    end

    BfBot.UI._Layout()
end

--- Reset panel to default 80%-centered layout.
function BfBot.UI._ResetLayout()
    BfBot.UI._panelX = nil
    BfBot.UI._panelY = nil
    BfBot.UI._panelW = nil
    BfBot.UI._panelH = nil
    BfBot.Persist.SetPref("PanelX", -1)
    BfBot.Persist.SetPref("PanelY", -1)
    BfBot.Persist.SetPref("PanelW", -1)
    BfBot.Persist.SetPref("PanelH", -1)
    BfBot.UI._Layout()
end

-- ============================================================
-- Panel Open/Close
-- ============================================================

function BfBot.UI.Toggle()
    if Infinity_IsMenuOnStack("BUFFBOT_MAIN") then
        Infinity_PopMenu("BUFFBOT_MAIN")
    else
        Infinity_PushMenu("BUFFBOT_MAIN")
    end
end

function BfBot.UI.Close()
    Infinity_PopMenu("BUFFBOT_MAIN")
end

function BfBot.UI._OnOpen()
    buffbot_isOpen = true
    BfBot.UI._Layout()
    -- Default to first party member if current slot is empty
    if not EEex_Sprite_GetInPortrait(BfBot.UI._charSlot) then
        BfBot.UI._charSlot = 0
    end
    -- Invalidate all scan caches on panel open (party may have changed)
    BfBot.Scan.InvalidateAll()
    BfBot.UI._Refresh()
end

function BfBot.UI._OnClose()
    buffbot_isOpen = false
    BfBot.UI._SaveLayout()
end

-- ============================================================
-- Data Population
-- ============================================================

--- Refresh all UI state from Persist + Scan data.
-- Called on: panel open, tab switch, spell change listeners.
-- Tab switches do NOT invalidate scan cache — reads cached data.
function BfBot.UI._Refresh()
    -- Reset row selection on any refresh
    buffbot_selectedRow = 0
    buffbot_selectedHasVariants = 0

    -- 1. Update party member names for character tabs
    buffbot_charNames = {}
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            buffbot_charNames[slot + 1] = BfBot._GetName(sprite)
        end
    end

    -- 2. Get current character's sprite + config
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then
        buffbot_spellTable = {}
        buffbot_presetNames = {}
        buffbot_presetCount = 0
        buffbot_title = "BuffBot"
        buffbot_castLabel = "Cast All"
        buffbot_castCharLabel = "Cast Character"
        buffbot_status = ""
        return
    end

    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return end

    -- 3. Update preset tab names and count from config (DYNAMIC)
    buffbot_presetNames = {}
    buffbot_presetCount = 0
    if config.presets then
        for idx, preset in pairs(config.presets) do
            buffbot_presetNames[idx] = preset.name or ("Preset " .. idx)
            buffbot_presetCount = buffbot_presetCount + 1
        end
    end

    -- 4. Clamp preset index to valid range
    BfBot.UI._ClampPresetIdx(config)

    local preset = config.presets[BfBot.UI._presetIdx]
    if not preset then
        buffbot_spellTable = {}
        return
    end

    -- 5. Get castable spells from scanner (uses CACHE — no invalidation here)
    local castable = BfBot.Scan.GetCastableSpells(sprite)

    -- 6. Merge new buff spells from scanner into preset (disabled, at bottom)
    local maxPri = 0
    for _, spellCfg in pairs(preset.spells) do
        if (spellCfg.pri or 0) > maxPri then maxPri = spellCfg.pri end
    end
    for resref, scan in pairs(castable) do
        local ovr = config.ovr and config.ovr[resref]
        if not preset.spells[resref] and scan.class and scan.class.isBuff
           and scan.count > 0 and ovr ~= -1 then
            maxPri = maxPri + 1
            local entry = BfBot.Persist._MakeDefaultSpellEntry(scan.class, 0)
            entry.pri = maxPri
            preset.spells[resref] = entry
        end
    end

    -- 6b. Lazy slot→name conversion: convert legacy slot strings to character names.
    -- Old saves store tgt as "1"-"6" or {"3","1","5"}. Convert to name-based
    -- format now that party is guaranteed loaded.
    for resref, spellCfg in pairs(preset.spells) do
        local tgt = spellCfg.tgt
        if type(tgt) == "table" then
            local converted = false
            local newTgt = {}
            for _, entry in ipairs(tgt) do
                local num = tonumber(entry)
                if num and num >= 1 and num <= 6 then
                    -- Legacy slot string → resolve to name
                    local slotSprite = EEex_Sprite_GetInPortrait(num - 1)
                    if slotSprite then
                        table.insert(newTgt, BfBot._GetName(slotSprite))
                        converted = true
                    end
                    -- Empty slot → drop (character left party)
                else
                    -- Already a name string, keep as-is
                    table.insert(newTgt, entry)
                end
            end
            if converted then
                spellCfg.tgt = newTgt
            end
        elseif type(tgt) == "string" and tgt ~= "s" and tgt ~= "p" then
            local num = tonumber(tgt)
            if num and num >= 1 and num <= 6 then
                -- Single legacy slot string → convert to name
                local slotSprite = EEex_Sprite_GetInPortrait(num - 1)
                if slotSprite then
                    spellCfg.tgt = BfBot._GetName(slotSprite)
                end
            end
        end
    end

    -- 7. Build spell table from preset config, cross-ref with scan data
    local rows = {}
    for resref, spellCfg in pairs(preset.spells) do
        local scan = castable[resref]
        local name = resref
        local icon = ""
        local count = 0
        local isCastable = 0
        local dur = nil
        local durCat = "instant"

        if scan then
            name = scan.name
            icon = scan.icon
            count = scan.count
            isCastable = (count > 0) and 1 or 0
            dur = scan.duration
            durCat = scan.durCat
        else
            -- Spell not in scanner results (removed from spellbook, dual-class lockout, etc.)
            -- Load SPL directly for display metadata
            local hdrOk, header = pcall(EEex_Resource_Demand, resref, "SPL")
            if hdrOk and header then
                local function tryStrref(strref)
                    if not strref or strref == 0xFFFFFFFF or strref == -1
                       or strref == 0 or strref == 9999999 then
                        return nil
                    end
                    local sOk, fetched = pcall(Infinity_FetchString, strref)
                    if sOk and fetched and fetched ~= "" then return fetched end
                    return nil
                end
                name = tryStrref(header.genericName)
                       or tryStrref(header.identifiedName)
                       or resref

                local casterLevel = 1
                local clOk, cl = pcall(function()
                    return sprite:getCasterLevelForSpell(resref, true)
                end)
                if clOk and cl and cl > 0 then casterLevel = cl end
                local ability = header:getAbilityForLevel(casterLevel)
                if not ability then ability = header:getAbility(0) end
                if ability then
                    local iconOk, abilIcon = pcall(function()
                        return ability.quickSlotIcon:get()
                    end)
                    if iconOk and abilIcon and abilIcon ~= "" then icon = abilIcon end
                    dur = BfBot.Class.GetDuration(header, ability)
                    durCat = BfBot.Class.GetDurationCategory(dur)
                end
            end
        end

        -- Variant fields from scan data and config
        local hasVariants = scan and scan.hasVariants or 0
        local variants = scan and scan.variants or nil
        local varResref = spellCfg.var or nil
        local variantName = nil
        if varResref and variants then
            for _, v in ipairs(variants) do
                if v.resref:upper() == varResref:upper() then
                    variantName = v.name
                    break
                end
            end
        end

        table.insert(rows, {
            resref   = resref,
            name     = name,
            icon     = icon,
            dur      = dur,
            durText  = BfBot.UI._FormatDuration(dur),
            durCat   = durCat,
            count    = count,
            countText = count > 0 and ("x" .. count) or "--",
            on       = spellCfg.on or 0,
            targetText = BfBot.UI._TargetToText(spellCfg.tgt),
            tgt      = spellCfg.tgt or "p",
            castable = isCastable,
            pri      = spellCfg.pri or 999,
            ovr      = (config.ovr and config.ovr[resref]) or 0,
            isAoE    = scan and scan.isAoE or 0,
            isSelfOnly = scan and scan.isSelfOnly or 0,
            tgtUnlock = spellCfg.tgtUnlock or 0,
            hasVariants = hasVariants,
            variants = variants,
            var      = varResref,
            variantName = variantName,
        })
    end

    -- Sort by priority (ascending: lower = cast first)
    table.sort(rows, function(a, b) return a.pri < b.pri end)
    buffbot_spellTable = rows

    -- 7. Update title, cast labels, status
    buffbot_title = "BuffBot - " .. (preset.name or "Preset")
    buffbot_castLabel = "Cast All"
    buffbot_castCharLabel = BfBot.UI._CastCharLabel()
    buffbot_status = BfBot.UI._GetStatusText()
end

-- ============================================================
-- Tab Switching (no cache invalidation)
-- ============================================================

function BfBot.UI.SetChar(slot)
    BfBot.UI._charSlot = slot
    BfBot.UI._Refresh()
end

function BfBot.UI.SetPreset(idx)
    BfBot.UI._presetIdx = idx
    BfBot.UI._Refresh()
end

-- ============================================================
-- Variant State Tracking
-- ============================================================

--- Update buffbot_selectedHasVariants based on current selection.
-- Called from list action callback whenever selection changes.
function BfBot.UI._UpdateVariantState()
    if buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable then
        local entry = buffbot_spellTable[buffbot_selectedRow]
        buffbot_selectedHasVariants = (entry and entry.hasVariants == 1) and 1 or 0
    else
        buffbot_selectedHasVariants = 0
    end
end

-- ============================================================
-- Spell Toggle (integer path — NO booleans)
-- ============================================================

function BfBot.UI.ToggleSpell(row)
    local entry = buffbot_spellTable[row]
    if not entry or entry.castable == 0 then return end

    -- Enable gate: variant spell without variant selected → open picker instead
    if entry.hasVariants == 1 and entry.on == 0 and not entry.var then
        BfBot.UI.OpenVariants(row)
        return
    end

    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end
    -- Integer toggle: 1 -> 0, 0 -> 1. NEVER pass boolean to Persist.
    local newState = (entry.on == 1) and 0 or 1
    BfBot.Persist.SetSpellEnabled(sprite, BfBot.UI._presetIdx, entry.resref, newState)
    entry.on = newState  -- immediate visual update
end

--- Toggle the currently selected row in the list (called from external button).
function BfBot.UI.ToggleSelected()
    if buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable then
        BfBot.UI.ToggleSpell(buffbot_selectedRow)
    end
end

-- ============================================================
-- Target Picking (ordered priority list with visual reordering)
-- ============================================================

--- Open the target picker for a spell row.
function BfBot.UI.OpenTargets(row)
    buffbot_targetRow = row
    local entry = buffbot_spellTable[row]
    if not entry then return end

    buffbot_targetHeader = entry.name or entry.resref
    buffbot_tgtPickerSel = 0

    -- Determine lock state
    local isLocked = 0
    local lockText = ""
    if entry.tgtUnlock ~= 1 then
        if entry.isSelfOnly == 1 then
            isLocked = 1
            lockText = "(Self-only)"
        elseif entry.isAoE == 1 then
            isLocked = 1
            lockText = "(Party-wide)"
        end
    end
    buffbot_targetLocked = isLocked
    buffbot_targetLockText = lockText

    -- Build the ordered display list: checked targets first (in priority order),
    -- then unchecked party members (in portrait order).
    buffbot_pickerOrder = {}
    buffbot_pickerChecked = {}

    local tgt = entry.tgt
    local checkedNames = {}
    if type(tgt) == "table" then
        for _, name in ipairs(tgt) do
            table.insert(buffbot_pickerOrder, name)
            buffbot_pickerChecked[name] = 1
            checkedNames[name] = true
        end
    elseif type(tgt) == "string" and tgt ~= "s" and tgt ~= "p" then
        table.insert(buffbot_pickerOrder, tgt)
        buffbot_pickerChecked[tgt] = 1
        checkedNames[tgt] = true
    end

    -- Append unchecked party members in portrait order
    for slot = 1, 6 do
        local name = buffbot_charNames[slot]
        if name and not checkedNames[name] then
            table.insert(buffbot_pickerOrder, name)
        end
    end

    Infinity_PushMenu("BUFFBOT_TARGETS")
end

--- Open target picker for the currently selected row (called from external button).
function BfBot.UI.OpenTargetsForSelected()
    if buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable then
        BfBot.UI.OpenTargets(buffbot_selectedRow)
    end
end

--- Get the display name for row N in the picker (1-6).
function BfBot.UI._PickerRowName(row)
    return buffbot_pickerOrder[row] or ""
end

--- Button text for a picker row. Left-side checkbox label.
function BfBot.UI._PickerCheckText(row)
    local name = buffbot_pickerOrder[row]
    if not name then return "" end
    if buffbot_pickerChecked[name] then return "[X]" end
    return "[ ]"
end

--- Button text for a picker row. Name label (right side).
-- Prepends "> " for the selected-for-reordering row.
function BfBot.UI._PickerNameText(row)
    local name = buffbot_pickerOrder[row]
    if not name then return "" end
    if row == buffbot_tgtPickerSel then
        return "> " .. name
    end
    return name
end

--- Text color for a picker row — highlight if selected.
function BfBot.UI._PickerRowColor(row)
    if row == buffbot_tgtPickerSel then
        return "{255, 255, 150}"  -- yellow highlight for selected row
    end
    local name = buffbot_pickerOrder[row]
    if name and buffbot_pickerChecked[name] then
        return "{220, 220, 220}"  -- white for checked
    end
    return "{140, 140, 140}"  -- grey for unchecked
end

--- Toggle the checkbox for a picker row (left-click on checkbox area).
function BfBot.UI.PickerToggle(row)
    if buffbot_targetLocked == 1 then return end
    local name = buffbot_pickerOrder[row]
    if not name then return end

    if buffbot_pickerChecked[name] then
        buffbot_pickerChecked[name] = nil
    else
        buffbot_pickerChecked[name] = 1
    end
end

--- Select a picker row (click on name area).
function BfBot.UI.PickerSelect(row)
    if row >= 1 and row <= #buffbot_pickerOrder then
        buffbot_tgtPickerSel = row
    end
end

--- Quick-set: Self target. Sets tgt="s" and closes.
function BfBot.UI.PickerSelf()
    if buffbot_targetLocked == 1 then return end
    local row = buffbot_targetRow
    local entry = buffbot_spellTable[row]
    if not entry then return end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end

    BfBot.Persist.SetSpellTarget(sprite, BfBot.UI._presetIdx, entry.resref, "s")
    entry.tgt = "s"
    entry.targetText = BfBot.UI._TargetToText("s")
    Infinity_PopMenu("BUFFBOT_TARGETS")
end

--- Quick-set: All Party. Checks all party members, keeps current order.
function BfBot.UI.PickerAllParty()
    if buffbot_targetLocked == 1 then return end
    for _, name in ipairs(buffbot_pickerOrder) do
        buffbot_pickerChecked[name] = 1
    end
end

--- Move selected row up (visually and in priority).
function BfBot.UI.PickerMoveUp()
    local sel = buffbot_tgtPickerSel
    if sel <= 1 or sel > #buffbot_pickerOrder then return end
    buffbot_pickerOrder[sel], buffbot_pickerOrder[sel - 1] =
        buffbot_pickerOrder[sel - 1], buffbot_pickerOrder[sel]
    buffbot_tgtPickerSel = sel - 1
end

--- Move selected row down (visually and in priority).
function BfBot.UI.PickerMoveDown()
    local sel = buffbot_tgtPickerSel
    if sel < 1 or sel >= #buffbot_pickerOrder then return end
    buffbot_pickerOrder[sel], buffbot_pickerOrder[sel + 1] =
        buffbot_pickerOrder[sel + 1], buffbot_pickerOrder[sel]
    buffbot_tgtPickerSel = sel + 1
end

--- Clear targets: uncheck all, reset selection.
function BfBot.UI.PickerClear()
    if buffbot_targetLocked == 1 then return end
    buffbot_pickerChecked = {}
    buffbot_tgtPickerSel = 0
end

--- Confirm and close the picker. Saves the working copy to persist.
function BfBot.UI.PickerDone()
    local row = buffbot_targetRow
    local entry = buffbot_spellTable[row]
    if not entry then
        Infinity_PopMenu("BUFFBOT_TARGETS")
        return
    end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then
        Infinity_PopMenu("BUFFBOT_TARGETS")
        return
    end

    -- Build target list: checked names in display order (top-to-bottom = cast priority)
    local tgt = {}
    for _, name in ipairs(buffbot_pickerOrder) do
        if buffbot_pickerChecked[name] then
            table.insert(tgt, name)
        end
    end

    -- Empty list → use smart default
    if #tgt == 0 then
        if entry.isSelfOnly == 1 then
            tgt = "s"
        elseif entry.isAoE == 1 then
            tgt = "p"
        else
            tgt = "s"
        end
    end

    BfBot.Persist.SetSpellTarget(sprite, BfBot.UI._presetIdx, entry.resref, tgt)
    entry.tgt = tgt
    entry.targetText = BfBot.UI._TargetToText(tgt)
    Infinity_PopMenu("BUFFBOT_TARGETS")
end

--- Unlock targeting for a locked spell.
function BfBot.UI.PickerUnlock()
    local row = buffbot_targetRow
    local entry = buffbot_spellTable[row]
    if not entry then return end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end

    BfBot.Persist.SetTgtUnlock(sprite, BfBot.UI._presetIdx, entry.resref, 1)
    entry.tgtUnlock = 1
    buffbot_targetLocked = 0
    buffbot_targetLockText = ""
end

-- ============================================================
-- Preset Management (Rename, Create, Delete)
-- ============================================================

function BfBot.UI.OpenRename()
    local name = buffbot_presetNames[BfBot.UI._presetIdx]
    buffbot_renameInput = name or ""
    Infinity_PushMenu("BUFFBOT_RENAME")
end

function BfBot.UI.ConfirmRename()
    local name = buffbot_renameInput
    if name and name ~= "" then
        BfBot.Persist.RenamePresetAll(BfBot.UI._presetIdx, name)
        BfBot.UI._Refresh()
    end
end

--- Create a new preset for all party members and switch to it.
function BfBot.UI.CreateNewPreset()
    local idx = BfBot.Persist.CreatePresetAll()
    if idx then
        BfBot.UI._presetIdx = idx
        BfBot.Innate.RefreshAll()
        BfBot.UI._Refresh()
    end
end

--- Delete the current preset for all party members and switch to nearest.
function BfBot.UI.DeleteCurrentPreset()
    local result = BfBot.Persist.DeletePresetAll(BfBot.UI._presetIdx)
    if result then
        -- Clamp to first valid preset for the current character
        local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
        if sprite then
            local config = BfBot.Persist.GetConfig(sprite)
            BfBot.UI._ClampPresetIdx(config)
        end
        BfBot.Innate.RefreshAll()
        BfBot.UI._Refresh()
    end
end

-- ============================================================
-- Cast / Stop
-- ============================================================

function BfBot.UI.Cast()
    -- Validate preset index before building queue
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if sprite then
        local config = BfBot.Persist.GetConfig(sprite)
        BfBot.UI._ClampPresetIdx(config)
    end

    local queue = BfBot.Persist.BuildQueueFromPreset(BfBot.UI._presetIdx)
    if not queue or #queue == 0 then
        BfBot._Display("BuffBot: No spells to cast in this preset")
        return
    end
    local qcMode = sprite and BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx) or 0
    BfBot.Exec.Start(queue, qcMode)
    buffbot_status = BfBot.UI._GetStatusText()
end

function BfBot.UI.CastCharacter()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end
    local config = BfBot.Persist.GetConfig(sprite)
    BfBot.UI._ClampPresetIdx(config)

    local queue = BfBot.Persist.BuildQueueForCharacter(BfBot.UI._charSlot, BfBot.UI._presetIdx)
    if not queue or #queue == 0 then
        Infinity_DisplayString("BuffBot: No spells to cast for this character")
        return
    end
    local qcMode = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    BfBot.Exec.Start(queue, qcMode)
    buffbot_status = BfBot.UI._GetStatusText()
end

function BfBot.UI._CastCharLabel()
    local name = buffbot_charNames[BfBot.UI._charSlot + 1]
    if name then return "Cast " .. name end
    return "Cast Character"
end

function BfBot.UI.Stop()
    BfBot.Exec.Stop()
    buffbot_status = BfBot.UI._GetStatusText()
end

-- ============================================================
-- Hotkey Handler
-- ============================================================

function BfBot.UI._OnKeyPressed(key)
    if key == EEex_Key_GetFromName("F11") then
        -- Only toggle when the world screen is active
        if worldScreen == e:GetActiveEngine() then
            BfBot.UI.Toggle()
            return true  -- consume the keypress
        end
    end
    return false
end

-- ============================================================
-- Sprite Listener Callbacks (invalidate cache, then refresh)
-- ============================================================

function BfBot.UI._OnSpellListChanged(sprite, resref, changeAmount)
    BfBot.Scan.Invalidate(sprite)
    if buffbot_isOpen then BfBot.UI._Refresh() end
end

function BfBot.UI._OnSpellCountsReset(sprite)
    BfBot.Scan.Invalidate(sprite)
    if buffbot_isOpen then BfBot.UI._Refresh() end
end

function BfBot.UI._OnSpellRemoved(sprite, resref)
    BfBot.Scan.Invalidate(sprite)
    if buffbot_isOpen then BfBot.UI._Refresh() end
end

-- ============================================================
-- Display Helpers (called from .menu expressions every frame)
-- Keep these LIGHTWEIGHT — read cached globals only.
-- ============================================================

--- Character tab selected state (returns boolean for frame lua).
function BfBot.UI._IsCharSelected(slot)
    return BfBot.UI._charSlot == slot
end

--- Preset tab selected state.
function BfBot.UI._IsPresetSelected(idx)
    return BfBot.UI._presetIdx == idx
end

--- Can we start casting? (exec idle + spells exist)
function BfBot.UI._CanCast()
    return BfBot.Exec.GetState() ~= "running" and #buffbot_spellTable > 0
end

--- Is execution currently running?
function BfBot.UI._IsRunning()
    return BfBot.Exec.GetState() == "running"
end

--- Is a spell row selected?
function BfBot.UI._HasSelection()
    return buffbot_isOpen and buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable
end

--- Renumber all spell priorities contiguously (1, 2, 3, ...) based on
--- current buffbot_spellTable order. Writes back to Persist.
function BfBot.UI._RenumberPriorities()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end
    for i, entry in ipairs(buffbot_spellTable) do
        entry.pri = i
        BfBot.Persist.SetSpellPriority(sprite, BfBot.UI._presetIdx, entry.resref, i)
    end
end

--- Can the selected spell be moved up? (selection exists and row > 1)
function BfBot.UI._CanMoveUp()
    return buffbot_isOpen and buffbot_selectedRow > 1 and buffbot_selectedRow <= #buffbot_spellTable
end

--- Can the selected spell be moved down? (selection exists and row < last)
function BfBot.UI._CanMoveDown()
    return buffbot_isOpen and buffbot_selectedRow > 0 and buffbot_selectedRow < #buffbot_spellTable
end

--- Move the selected spell up one position.
function BfBot.UI.MoveSpellUp()
    local row = buffbot_selectedRow
    if row <= 1 or row > #buffbot_spellTable then return end
    -- Swap in display table
    buffbot_spellTable[row], buffbot_spellTable[row - 1] = buffbot_spellTable[row - 1], buffbot_spellTable[row]
    -- Renumber all priorities
    BfBot.UI._RenumberPriorities()
    -- Follow the moved spell
    buffbot_selectedRow = row - 1
end

--- Move the selected spell down one position.
function BfBot.UI.MoveSpellDown()
    local row = buffbot_selectedRow
    if row < 1 or row >= #buffbot_spellTable then return end
    -- Swap in display table
    buffbot_spellTable[row], buffbot_spellTable[row + 1] = buffbot_spellTable[row + 1], buffbot_spellTable[row]
    -- Renumber all priorities
    BfBot.UI._RenumberPriorities()
    -- Follow the moved spell
    buffbot_selectedRow = row + 1
end

--- Sort the current preset's spell list by duration (longest first).
--- Permanent > long > short > instant > unknown. Persists via _RenumberPriorities.
function BfBot.UI.SortByDuration()
    if #buffbot_spellTable == 0 then return end
    -- Map dur to a sort key: permanent (-1) → huge, nil → -2 (bottom)
    local function durKey(entry)
        local d = entry.dur
        if d == nil then return -2 end
        if d == -1 then return 1e9 end  -- permanent sorts first
        return d                         -- timed: higher seconds = earlier
    end
    table.sort(buffbot_spellTable, function(a, b) return durKey(a) > durKey(b) end)
    BfBot.UI._RenumberPriorities()
end

-- ============================================================
-- Spell Override (Add / Remove)
-- ============================================================

--- Build the picker list: non-buff castable spells not in current preset.
function BfBot.UI._BuildPickerList()
    buffbot_pickerSpells = {}
    buffbot_pickerSelected = 0
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return end
    local preset = config.presets[BfBot.UI._presetIdx]
    if not preset then return end

    local castable = BfBot.Scan.GetCastableSpells(sprite)
    for resref, scan in pairs(castable) do
        -- Skip spells already in the preset
        if preset.spells[resref] then goto nextSpell end
        -- Skip spells with no classification
        if not scan.class then goto nextSpell end
        -- Skip spells already classified as buffs (auto-merge handles those)
        if scan.class.isBuff then goto nextSpell end
        -- Skip excluded spells
        local ovr = config.ovr and config.ovr[resref]
        if ovr == -1 then goto nextSpell end

        table.insert(buffbot_pickerSpells, {
            resref = resref,
            name   = scan.name or resref,
            icon   = scan.icon or "",
            durCat = scan.durCat or "?",
            count  = scan.count or 0,
        })
        ::nextSpell::
    end
    table.sort(buffbot_pickerSpells, function(a, b) return a.name < b.name end)
end

--- Open the spell picker sub-menu.
function BfBot.UI.OpenSpellPicker()
    BfBot.UI._BuildPickerList()
    if #buffbot_pickerSpells == 0 then
        BfBot._Display("BuffBot: No additional spells to add")
        return
    end
    Infinity_PushMenu("BUFFBOT_SPELLPICKER")
end

--- Add the selected spell from the picker (include override).
function BfBot.UI.AddPickedSpell()
    local entry = buffbot_pickerSpells[buffbot_pickerSelected]
    if not entry then return end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end

    -- Set include override (classification-level)
    BfBot.Persist.SetOverride(sprite, entry.resref, 1)

    -- Invalidate caches so re-classification picks up the override
    BfBot._cache.class[entry.resref] = nil
    BfBot.Scan.Invalidate(sprite)

    Infinity_PopMenu("BUFFBOT_SPELLPICKER")
    BfBot.UI._Refresh()  -- auto-merge will pick up the newly-classified buff
end

--- Exclude the selected spell from the buff list.
-- Sets exclude override, removes from ALL presets for this character.
function BfBot.UI.ExcludeSelected()
    if not BfBot.UI._HasSelection() then return end
    local entry = buffbot_spellTable[buffbot_selectedRow]
    if not entry then return end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end

    -- Set exclude override
    BfBot.Persist.SetOverride(sprite, entry.resref, -1)

    -- Remove from ALL presets
    local config = BfBot.Persist.GetConfig(sprite)
    if config and config.presets then
        for _, preset in pairs(config.presets) do
            if preset.spells then
                preset.spells[entry.resref] = nil
            end
        end
    end

    -- Invalidate caches
    BfBot._cache.class[entry.resref] = nil
    BfBot.Scan.Invalidate(sprite)

    buffbot_selectedRow = 0
    BfBot.UI._Refresh()
end

--- Picker display helpers
function BfBot.UI._PickerHasSelection()
    return buffbot_pickerSelected > 0 and buffbot_pickerSelected <= #buffbot_pickerSpells
end

-- ============================================================
-- Config Export / Import
-- ============================================================

--- Export current character's config.
function BfBot.UI.ExportConfig()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end

    local ok, result = BfBot.Persist.ExportConfig(sprite)
    if ok then
        BfBot._Display("BuffBot: Exported config as '" .. result .. "'")
    else
        BfBot._Display("BuffBot: Export failed — " .. tostring(result))
    end
end

--- Build the import picker list from available files.
function BfBot.UI._BuildImportList()
    buffbot_importList = {}
    buffbot_importSelected = 0
    local exports = BfBot.Persist.ListExports()
    for _, entry in ipairs(exports) do
        table.insert(buffbot_importList, {
            name = entry.name,
            filename = entry.filename,
        })
    end
end

--- Open the import picker sub-menu.
function BfBot.UI.OpenImportPicker()
    BfBot.UI._BuildImportList()
    if #buffbot_importList == 0 then
        BfBot._Display("BuffBot: No configs found in bfbot_presets/")
        return
    end
    Infinity_PushMenu("BUFFBOT_IMPORT")
end

--- Import the selected config from the picker.
function BfBot.UI.ImportSelected()
    local entry = buffbot_importList[buffbot_importSelected]
    if not entry then return end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end

    local ok, presets, skipped = BfBot.Persist.ImportConfig(sprite, entry.filename)
    Infinity_PopMenu("BUFFBOT_IMPORT")

    if ok then
        BfBot._Display("BuffBot: Imported '" .. entry.name .. "' ("
            .. presets .. " presets, " .. skipped .. " spells skipped)")
        BfBot.Scan.Invalidate(sprite)
        BfBot.UI._Refresh()
    else
        BfBot._Display("BuffBot: Import failed — " .. tostring(presets))
    end
end

--- Import picker has a valid selection.
function BfBot.UI._ImportHasSelection()
    return buffbot_importSelected > 0 and buffbot_importSelected <= #buffbot_importList
end

-- ============================================================
-- Variant Picker (select spell variant for opcode 214 spells)
-- ============================================================

--- Open the variant picker for a spell row.
function BfBot.UI.OpenVariants(row)
    local entry = buffbot_spellTable[row]
    if not entry or not entry.variants then return end

    buffbot_variantHeader = entry.name or entry.resref
    buffbot_variantSelected = 0
    buffbot_variantTable = {}

    for i, v in ipairs(entry.variants) do
        table.insert(buffbot_variantTable, {
            resref = v.resref,
            name   = v.name,
            icon   = v.icon,
            label  = v.label,
        })
    end

    Infinity_PushMenu("BUFFBOT_VARIANTS")
end

--- Open variants for currently selected row (button handler).
function BfBot.UI.OpenVariantsForSelected()
    if buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable then
        BfBot.UI.OpenVariants(buffbot_selectedRow)
    end
end

--- Select a variant and close the picker.
function BfBot.UI.SelectVariant(row)
    local vEntry = buffbot_variantTable[row]
    if not vEntry then return end

    local spellRow = buffbot_selectedRow
    local entry = buffbot_spellTable[spellRow]
    if not entry then
        Infinity_PopMenu("BUFFBOT_VARIANTS")
        return
    end

    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then
        Infinity_PopMenu("BUFFBOT_VARIANTS")
        return
    end

    -- Store the variant
    BfBot.Persist.SetSpellVariant(sprite, BfBot.UI._presetIdx, entry.resref, vEntry.resref)
    entry.var = vEntry.resref
    entry.variantName = vEntry.name

    Infinity_PopMenu("BUFFBOT_VARIANTS")
end

--- Variant button text for the selected spell.
function BfBot.UI._VariantBtnText()
    if buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable then
        local entry = buffbot_spellTable[buffbot_selectedRow]
        if entry and entry.variantName then
            return "Var: " .. entry.variantName
        end
    end
    return "Variant"
end

--- Can we create more presets? (fewer than 5 exist)
function BfBot.UI._CanCreatePreset()
    return buffbot_isOpen and buffbot_presetCount < BfBot.MAX_PRESETS
end

--- Can we delete the current preset? (more than 1 exists)
function BfBot.UI._CanDeletePreset()
    return buffbot_isOpen and buffbot_presetCount > 1
end

--- Toggle button text: "Enable" or "Disable" based on selected row.
function BfBot.UI._ToggleBtnText()
    if buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable then
        local entry = buffbot_spellTable[buffbot_selectedRow]
        if entry and entry.on == 1 then return "Disable" end
    end
    return "Enable"
end

--- Target button text: shows current target of selected row.
function BfBot.UI._TargetBtnText()
    if buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable then
        local entry = buffbot_spellTable[buffbot_selectedRow]
        if entry then return "Target: " .. (entry.targetText or "Party") end
    end
    return "Target"
end

--- Format a duration in seconds to a human-readable string.
--- Returns mixed format: "1h 30m", "5m", "1m 30s", "45s", "Perm", "Inst", "?"
function BfBot.UI._FormatDuration(seconds)
    if seconds == nil then return "?" end
    if seconds == -1 then return "Perm" end
    if seconds == 0 then return "Inst" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        if m > 0 then return h .. "h " .. m .. "m" end
        return h .. "h"
    end
    if m > 0 then
        if s > 0 then return m .. "m " .. s .. "s" end
        return m .. "m"
    end
    return s .. "s"
end

--- Spell name color: grey for unavailable, dark blue for manual include, dark brown for normal.
function BfBot.UI._SpellNameColor(row)
    local entry = buffbot_spellTable[row]
    if not entry then return {50, 30, 10} end
    if entry.castable == 0 then return {140, 130, 120} end
    if entry.ovr == 1 then return {40, 80, 160} end
    return {50, 30, 10}
end

--- Checkbox display: "+" for enabled, empty for disabled.
function BfBot.UI._CheckboxText(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.on == 1 then return "[X]" end
    return "[ ]"
end

--- Convert target config value to display text.
-- tgt can be: "s", "p", a name string, or a table of name strings.
-- Also handles legacy slot strings ("1"-"6") for backwards compatibility.
function BfBot.UI._TargetToText(tgt)
    if tgt == "s" then return "Self"
    elseif tgt == "p" then return "Party"
    elseif type(tgt) == "table" then
        if #tgt == 0 then return "None" end
        -- First entry is always the display name (highest priority target)
        local firstName = tgt[1]
        -- Legacy slot string? Resolve to name for display
        local num = tonumber(firstName)
        if num and num >= 1 and num <= 6 then
            firstName = buffbot_charNames[num] or ("Player " .. num)
        end
        if #tgt == 1 then
            return firstName
        end
        return firstName .. " +" .. (#tgt - 1)
    else
        -- Single string: name or legacy slot
        local num = tonumber(tgt)
        if num and num >= 1 and num <= 6 then
            return buffbot_charNames[num] or ("Player " .. num)
        end
        -- Name string — return as-is
        return tgt
    end
end

--- Execution status text for the status label.
function BfBot.UI._GetStatusText()
    local state = BfBot.Exec.GetState()
    if state == "running" then
        local qc = BfBot.Exec._qcMode or 0
        if qc == 2 then return "Casting (Quick: All)..."
        elseif qc == 1 then return "Casting (Quick: Long)..."
        else return "Casting..." end
    elseif state == "done" then return "Done"
    elseif state == "stopped" then return "Stopped"
    else return "" end
end

-- ============================================================
-- Quick Cast Cycling Button
-- ============================================================

function BfBot.UI.CycleQuickCast()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end
    local current = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    local next = (current + 1) % 3
    BfBot.Persist.SetQuickCastAll(BfBot.UI._presetIdx, next)
end

function BfBot.UI._QuickCastLabel()
    if not buffbot_isOpen then return "" end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return "Quick Cast: Off" end
    local qc = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    if qc == 1 then return "Quick Cast: Long" end
    if qc == 2 then return "Quick Cast: All" end
    return "Quick Cast: Off"
end

function BfBot.UI._QuickCastColor()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return {80, 60, 40} end
    local qc = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    if qc == 1 then return {160, 120, 20} end
    if qc == 2 then return {180, 60, 30} end
    return {80, 60, 40}
end

function BfBot.UI._QuickCastTooltip()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return "Normal casting speed" end
    local qc = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    if qc == 1 then return "Fast casting for 'long' buffs (300s+ duration). Short buffs cast normally. Click to cycle." end
    if qc == 2 then return "Fast casting for ALL buffs regardless of duration (cheat). Click to cycle." end
    return "Normal casting speed — spells respect aura cooldown. Click to cycle."
end

-- ============================================================
-- Debug Mode Toggle
-- ============================================================

function BfBot.UI.ToggleDebug()
    BfBot._debugMode = (BfBot._debugMode == 1) and 0 or 1
    Infinity_SetINIValue("BuffBot", "Debug", BfBot._debugMode)
    BfBot._Display("BuffBot: Debug mode " .. (BfBot._debugMode == 1 and "ON" or "OFF"))
end
