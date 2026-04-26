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

-- Pre-create BfBot.UI namespace. BfBotThm loads before BfBotUI, so BfBot.UI
-- doesn't exist yet; the `or {}` guard creates it without stomping if it does.
BfBot.UI = BfBot.UI or {}

--- Theme color accessor.
-- Returns the active palette's value for the given semantic key, or magenta
-- "{255, 0, 255}" if the key is missing (visible debug signal).
-- @param key string — one of the keys listed in the Palette Key Glossary above
function BfBot.UI._T(key)
    local v = BfBot.Theme._active[key]
    if v == nil then return "{255, 0, 255}" end
    return v
end

-- ============================================================
-- Custom bb_* text styles (font size scaling)
-- ============================================================
-- BuffBot registers its own text styles as deep-copies of engine styles.
-- This lets us scale `point` (font size) per user preference without
-- mutating the shared engine styles (which other menus use).

-- Base sizes for our custom styles (tuned for BuffBot panel density)
BfBot.Theme._BASE_POINTS = {
    bb_normal           = 12,
    bb_button           = 14,
    bb_title            = 18,
    bb_normal_parchment = 12,
    bb_edit             = 12,
}
-- Parent style each bb_* deep-copies from. ITEM_BUTTON renders its
-- caption through a code path that ignores `text.point` — no Lua
-- mutation can scale button text in BG2EE (Bubb's mods don't try
-- either). We accept that and keep the original "button" parent
-- (STONESML / carved stone) for the right BG aesthetic. Body text,
-- list cells, the title, and clickable text elements (Quick Cast,
-- Reset) all do scale via their own item-type render paths.
BfBot.Theme._STYLE_PARENTS = {
    bb_normal           = "normal",
    bb_button           = "button",
    bb_title            = "title",
    bb_normal_parchment = "normal_parchment",
    bb_edit             = "edit",
}
-- Font size multiplier: 1=small, 2=medium (default), 3=large
BfBot.Theme._SIZE_MULT = { [1] = 0.85, [2] = 1.0, [3] = 1.20 }
BfBot.Theme._fontSize = 2

--- Register bb_* custom styles by deep-copying engine styles.
-- Always re-deep-copies so changes to _STYLE_PARENTS take effect on Lua
-- reload (the prior `not styles[bbName]` guard would have stuck a stale
-- copy across an Infinity_DoFile reload).
function BfBot.Theme._RegisterStyles()
    if not styles then return end
    if not EEex or not EEex.DeepCopy then return end
    for bbName, parent in pairs(BfBot.Theme._STYLE_PARENTS) do
        if styles[parent] then
            styles[bbName] = EEex.DeepCopy(styles[parent])
        end
    end
    BfBot.Theme._RefreshStyles()
end

--- Re-apply current font size to bb_* styles. The engine snapshots
-- `style.point` into each menu item's `text.point` at parse time, so style
-- mutation alone won't reflow live items — `_ApplyFontSizesToMenus` does
-- the live update. We still mutate the styles so any future menu reparse
-- AND wrap calculations like Infinity_GetContentHeight read the new size.
function BfBot.Theme._RefreshStyles()
    if not styles then return end
    local mult = BfBot.Theme._SIZE_MULT[BfBot.Theme._fontSize] or 1.0
    for bbName, basePt in pairs(BfBot.Theme._BASE_POINTS) do
        if styles[bbName] then
            styles[bbName].point = math.floor(basePt * mult)
        end
    end
end

-- Map IE font name → BuffBot's base point. After reparenting bb_button to
-- "normal", every body/button/edit/cell style uses NORMAL; bb_title uses
-- REALMS. STONESML stays in the map as a safety net for any leftover
-- engine style we didn't migrate. Engine items in OTHER menus aren't
-- touched — iteration is scoped to our owned menus.
BfBot.Theme._FONT_TO_BASE_POINT = {
    NORMAL   = 12,  -- bb_normal, bb_button, bb_normal_parchment, bb_edit
    STONESML = 14,  -- legacy fallback (no bb_* style currently uses STONESML)
    REALMS   = 18,  -- bb_title
}

-- Menus we own (defined in buffbot/BuffBot.menu). Iterated by name.
BfBot.Theme._OWNED_MENUS = {
    "BUFFBOT_MAIN",
    "BUFFBOT_TARGETS",
    "BUFFBOT_RENAME",
    "BUFFBOT_SPELLPICKER",
    "BUFFBOT_IMPORT",
    "BUFFBOT_VARIANTS",
}

--- Compute the correct point size for a uiItem by looking up its font name
-- in the BuffBot font→base table and multiplying by the current size mult.
-- No-op when item lacks a recognized font (skips engine items in unrelated
-- menus we don't own).
local function _updateItemPoint(item)
    local txt = item and item.text
    if not txt or not txt.font then return end
    local ok, fontName = pcall(function() return txt.font:get() end)
    if not ok or not fontName then return end
    local base = BfBot.Theme._FONT_TO_BASE_POINT[fontName]
    if not base then return end
    local mult = BfBot.Theme._SIZE_MULT[BfBot.Theme._fontSize] or 1.0
    txt.point = math.floor(base * mult)
end

--- Walk every text-bearing item in BuffBot's menus and write the scaled
-- point directly. Used for the immediate one-shot update on size change.
-- For ITEM_LIST items we also walk `item.list.columns.items` (column
-- templates), since list-cell labels live nested in the list struct and
-- aren't reachable via the top-level `item.next` chain.
function BfBot.Theme._ApplyFontSizesToMenus()
    if not EEex_Menu_Find then return end
    for _, menuName in ipairs(BfBot.Theme._OWNED_MENUS) do
        local menu = EEex_Menu_Find(menuName)
        if menu and menu.items then
            local item = menu.items
            while item ~= nil do
                _updateItemPoint(item)
                if item.list then
                    local cols = item.list.columns
                    if cols and cols.items then
                        local col = cols.items
                        while col ~= nil do
                            _updateItemPoint(col)
                            col = col.next
                        end
                    end
                end
                item = item.next
            end
        end
    end
end

--- Register per-frame render listeners that update each item's text.point
-- right before render. The one-shot mutation in _ApplyFontSizesToMenus only
-- updates the visible state on items the engine re-reads from `text.point`
-- per frame (ITEM_TEXT does, ITEM_BUTTON often snapshots at push). With a
-- BeforeUIItemRenderListener per named item, point gets re-applied every
-- frame so it survives any internal snapshot/cache.
--
-- For lists, BeforeListRendersItemListener fires per cell render — perfect
-- for the spell-row cells that re-instantiate from column templates per row.
function BfBot.Theme._RegisterFontRenderListeners()
    if not EEex_Menu_AddBeforeUIItemRenderListener then return end
    if BfBot.Theme._fontListenersRegistered then return end

    -- Global cache of items we've already wired so reload doesn't re-stack.
    -- Listener storage is by-name, so re-registering just replaces.
    local function _attachItemListeners(menu)
        if not menu or not menu.items then return end
        local item = menu.items
        while item ~= nil do
            local nameOk, name = pcall(function() return item.name:get() end)
            if nameOk and name and name ~= "" and item.text and item.text.font then
                -- Skip border-frame items (their listeners are owned by
                -- BfBot.UI border render hooks and would be replaced).
                if not name:match("^bb.*Frame$") then
                    EEex_Menu_AddBeforeUIItemRenderListener(name, _updateItemPoint)
                end
            end
            -- For lists, register a per-cell render listener that updates
            -- each cell's text.point right before it's drawn.
            if item.list and EEex_Menu_AddBeforeListRendersItemListener then
                local listNameOk, listName = pcall(function() return item.name:get() end)
                if listNameOk and listName and listName ~= "" then
                    EEex_Menu_AddBeforeListRendersItemListener(listName, function(_list, cell)
                        _updateItemPoint(cell)
                    end)
                end
            end
            item = item.next
        end
    end

    for _, menuName in ipairs(BfBot.Theme._OWNED_MENUS) do
        _attachItemListeners(EEex_Menu_Find(menuName))
    end
    BfBot.Theme._fontListenersRegistered = true
end

--- Set font size (1=small, 2=medium, 3=large). Clamped to [1,3].
-- Mutates the styles table (for future reparses + content-height math) and
-- writes the scaled point directly into every live BuffBot menu item.
-- The render listeners registered in _RegisterFontRenderListeners then
-- re-apply this on each subsequent frame so types that snapshot text.point
-- (e.g. buttons) still pick up the new size.
function BfBot.Theme._SetFontSize(n)
    n = tonumber(n) or 2
    if n < 1 then n = 1 end
    if n > 3 then n = 3 end
    BfBot.Theme._fontSize = n
    BfBot.Theme._RefreshStyles()
    BfBot.Theme._ApplyFontSizesToMenus()
end

--- Get current font size (1-3).
function BfBot.Theme._GetFontSize()
    return BfBot.Theme._fontSize
end

-- ============================================================
-- INI persistence (Theme + FontSize)
-- ============================================================

--- Load saved theme + font size from INI; apply to active palette + styles.
-- Called from BfBot.UI._OnMenusLoaded AFTER _RegisterStyles, so _RefreshStyles
-- has bb_* styles to operate on.
function BfBot.Theme._LoadFromINI()
    local name = BfBot.Persist.GetPref("Theme")
    -- Defensive coercion: if INI accessor returns a non-string for any reason,
    -- fall back to the default palette name.
    if type(name) ~= "string" or name == "" then name = "bg2_light" end
    local palette = BfBot.Theme._palettes[name]
    if palette then
        BfBot.Theme._active = palette
    end
    -- FontSize: clamp to [1,3]
    local sz = tonumber(BfBot.Persist.GetPref("FontSize")) or 2
    if sz < 1 then sz = 1 end
    if sz > 3 then sz = 3 end
    BfBot.Theme._fontSize = sz
    BfBot.Theme._RefreshStyles()
end

--- Save current theme name + font size to INI.
-- Reverse-looks-up the active palette to find its registered name.
function BfBot.Theme._SaveToINI()
    for name, palette in pairs(BfBot.Theme._palettes) do
        if palette == BfBot.Theme._active then
            BfBot.Persist.SetPref("Theme", name)
            break
        end
    end
    BfBot.Persist.SetPref("FontSize", BfBot.Theme._fontSize)
end

--- Apply a palette by name + persist + refresh styles.
-- @param name string — palette key (e.g. "bg2_light", "sod_dark")
-- @return true if palette exists and was applied; false otherwise.
function BfBot.Theme.Apply(name)
    local palette = BfBot.Theme._palettes[name]
    if not palette then return false end
    BfBot.Theme._active = palette
    BfBot.Theme._RefreshStyles()
    BfBot.Theme._SaveToINI()
    return true
end

-- ============================================================
-- Active palette decomposition (mode + accent helpers)
-- ============================================================
-- The active palette name is "<accent>_<mode>" where:
--   accent ∈ { bg2, sod, bg1 }
--   mode   ∈ { light, dark }
-- These helpers split that compound name so the EEex Options UI can
-- expose the two axes (Dark Mode toggle + Color Scheme radio) without
-- the user thinking in terms of palette names.

--- Returns 1 if the active palette name ends in "_dark", else 0.
-- Numeric (not boolean) so it round-trips through EEex_Options storage,
-- which uses numeric INI values for toggle widgets.
function BfBot.Theme._IsDark()
    for name, palette in pairs(BfBot.Theme._palettes) do
        if palette == BfBot.Theme._active then
            return (name:match("_dark$") ~= nil) and 1 or 0
        end
    end
    return 0
end

--- Returns "bg2" / "sod" / "bg1" for the active palette's accent prefix.
-- Falls back to "bg2" if the active palette can't be located in the table
-- (should never happen in practice — _active is always one of _palettes).
function BfBot.Theme._GetAccentName()
    for name, palette in pairs(BfBot.Theme._palettes) do
        if palette == BfBot.Theme._active then
            return name:match("^(%w+)_") or "bg2"
        end
    end
    return "bg2"
end

--- Set dark mode while preserving the current accent.
-- @param dark — 1, 0, true, or false (numeric forms come from EEex options).
function BfBot.Theme._SetDarkMode(dark)
    local accent = BfBot.Theme._GetAccentName()
    local truthy = (dark == 1 or dark == true)
    local suffix = truthy and "_dark" or "_light"
    BfBot.Theme.Apply(accent .. suffix)
end

--- Returns 1/2/3 for the active accent (BG2 / SOD / BG1).
function BfBot.Theme._GetAccentIndex()
    local accent = BfBot.Theme._GetAccentName()
    return ({bg2=1, sod=2, bg1=3})[accent] or 1
end

--- Set the accent by index (1=BG2, 2=SOD, 3=BG1) preserving dark/light.
-- Out-of-range / non-numeric input falls back to BG2.
function BfBot.Theme._SetAccent(idx)
    local accent = ({[1]="bg2", [2]="sod", [3]="bg1"})[idx] or "bg2"
    local suffix = (BfBot.Theme._IsDark() == 1) and "_dark" or "_light"
    BfBot.Theme.Apply(accent .. suffix)
end

-- ============================================================
-- EEex Options tab registration
-- ============================================================
-- Adds a "BuffBot" tab to the EEex Options menu (Esc → Options) with three
-- controls: Dark Mode toggle, Color Scheme radio (3 options), Text Size
-- radio (3 options). Calls into the helpers above for value get/set.
--
-- Persistence note: each option uses a custom storage that bridges directly
-- to BfBot.Theme — read() derives the current value from the live theme
-- (no separate INI key for these options), write() applies the value via
-- BfBot.Theme.Apply / _SetFontSize. Those helpers themselves call
-- _SaveToINI, so the existing [BuffBot]Theme + [BuffBot]FontSize INI keys
-- remain the single source of truth. No new INI keys are introduced.
--
-- _registered guards against double-registration (e.g., Infinity_DoFile
-- reloading BfBotThm during dev) — EEex has no AddTab counterpart for
-- removal, so re-registering would duplicate the tab.

BfBot.Theme._registered = BfBot.Theme._registered or false

--- Register translation strings into uiStrings so EEex's t() resolver finds
-- them. uiStrings is the global table populated by EEex's L_*.LUA / X-en_US
-- localization files. Falls through silently for missing keys (showing the
-- raw key in the UI), so populating it here is the safest path.
local function _populateUiStrings()
    if not uiStrings then return end
    uiStrings.BuffBot_Tab               = "BuffBot"
    uiStrings.BuffBot_DarkMode          = "Dark Mode"
    uiStrings.BuffBot_DarkMode_Desc     = "Dim the panel parchment for low-light play. The accent palette is preserved."
    uiStrings.BuffBot_Accent            = "Color Scheme"
    uiStrings.BuffBot_Accent_Desc       = "Choose the panel accent palette: classic BG2 parchment, the steel-blue Siege of Dragonspear, or the warm BG1 amber."
    uiStrings.BuffBot_Accent_BG2        = "Baldur's Gate 2"
    uiStrings.BuffBot_Accent_SOD        = "Siege of Dragonspear"
    uiStrings.BuffBot_Accent_BG1        = "Baldur's Gate 1"
    uiStrings.BuffBot_TextSize          = "Text Size"
    uiStrings.BuffBot_TextSize_Desc     = "Scale all panel text. Close and reopen the BuffBot panel after changing this for the new size to take effect."
    uiStrings.BuffBot_TextSize_Small    = "Small"
    uiStrings.BuffBot_TextSize_Medium   = "Medium"
    uiStrings.BuffBot_TextSize_Large    = "Large"
end

--- Build a custom storage class that bridges between an EEex option's
-- numeric value and live BfBot.Theme state. `getter` reads the current
-- value (number); `setter(value)` applies it. Both sides go through
-- BfBot.Theme helpers, which themselves persist to baldur.ini via
-- _SaveToINI — so this storage is effectively a thin adapter.
local function _makeBridgeStorage(getter, setter)
    -- Inherit from EEex_Options_Private_Storage so canReadEarly() is false
    -- (we want late-phase read so all dependencies are loaded).
    if not EEex_Options_Private_Storage then return nil end
    local storage = {}
    storage.__index = storage
    setmetatable(storage, EEex_Options_Private_Storage)
    -- Storage must implement read/write; canReadEarly is inherited (returns false).
    function storage:read(option)
        local ok, val = pcall(getter)
        if ok then return val end
        return option:_getDefault()
    end
    function storage:write(option, value)
        pcall(setter, value)
    end
    -- Static factory matching EEex's convention.
    storage.new = function(o)
        if o == nil then o = {} end
        setmetatable(o, storage)
        return o
    end
    return storage
end

--- Register the BuffBot tab + options in EEex's Options UI.
-- Idempotent: subsequent calls return early via the _registered flag.
-- Safe-degrades when EEex Options is not loaded (older EEex builds).
function BfBot.Theme._RegisterOptionsTab()
    if BfBot.Theme._registered then return end
    if not EEex_Options_AddTab then return end
    if not EEex_Options_Register then return end
    if not EEex_Options_Option then return end
    if not EEex_Options_DisplayEntry then return end
    if not EEex_Options_ToggleType or not EEex_Options_ToggleWidget then return end
    if not EEex_Options_ClampedAccessor then return end
    if not EEex_Options_Private_Storage then return end

    _populateUiStrings()

    -- Dark Mode (binary toggle: 0/1)
    local DarkBridge = _makeBridgeStorage(
        function() return BfBot.Theme._IsDark() end,
        function(v) BfBot.Theme._SetDarkMode(v) end
    )
    EEex_Options_Register("BuffBot_DarkMode", EEex_Options_Option.new({
        ["default"]  = 0,
        ["type"]     = EEex_Options_ToggleType.new(),
        ["accessor"] = EEex_Options_ClampedAccessor.new({ ["min"] = 0, ["max"] = 1 }),
        ["storage"]  = DarkBridge.new(),
    }))

    -- Color Scheme (3-way radio: 1=BG2, 2=SOD, 3=BG1)
    local AccentBridge = _makeBridgeStorage(
        function() return BfBot.Theme._GetAccentIndex() end,
        function(v) BfBot.Theme._SetAccent(v) end
    )
    EEex_Options_Register("BuffBot_Accent", EEex_Options_Option.new({
        ["default"]  = 1,
        ["type"]     = EEex_Options_ToggleType.new(),
        ["accessor"] = EEex_Options_ClampedAccessor.new({ ["min"] = 1, ["max"] = 3 }),
        ["storage"]  = AccentBridge.new(),
    }))

    -- Text Size (3-way radio: 1=Small, 2=Medium, 3=Large)
    local SizeBridge = _makeBridgeStorage(
        function() return BfBot.Theme._GetFontSize() end,
        function(v)
            BfBot.Theme._SetFontSize(v)
            BfBot.Theme._SaveToINI()
        end
    )
    EEex_Options_Register("BuffBot_TextSize", EEex_Options_Option.new({
        ["default"]  = 2,
        ["type"]     = EEex_Options_ToggleType.new(),
        ["accessor"] = EEex_Options_ClampedAccessor.new({ ["min"] = 1, ["max"] = 3 }),
        ["storage"]  = SizeBridge.new(),
    }))

    -- Build the radio-group DisplayEntries up front so we can capture them
    -- in module-local tables. EEex's toggleAction only updates the clicked
    -- widget's `toggleState`; sibling widgets sharing an optionID only
    -- re-sync on panel show. We patch _setWorkingValue on the radio options
    -- below to keep all siblings in sync per-click.
    local accentEntries = {
        EEex_Options_DisplayEntry.new({
            ["optionID"]    = "BuffBot_Accent",
            ["label"]       = "BuffBot_Accent_BG2",
            ["description"] = "BuffBot_Accent_Desc",
            ["widget"]      = EEex_Options_ToggleWidget.new({
                ["toggleValue"]       = 1,
                ["disallowToggleOff"] = true,
            }),
        }),
        EEex_Options_DisplayEntry.new({
            ["optionID"]    = "BuffBot_Accent",
            ["label"]       = "BuffBot_Accent_SOD",
            ["description"] = "BuffBot_Accent_Desc",
            ["widget"]      = EEex_Options_ToggleWidget.new({
                ["toggleValue"]       = 2,
                ["disallowToggleOff"] = true,
            }),
        }),
        EEex_Options_DisplayEntry.new({
            ["optionID"]    = "BuffBot_Accent",
            ["label"]       = "BuffBot_Accent_BG1",
            ["description"] = "BuffBot_Accent_Desc",
            ["widget"]      = EEex_Options_ToggleWidget.new({
                ["toggleValue"]       = 3,
                ["disallowToggleOff"] = true,
            }),
        }),
    }
    local sizeEntries = {
        EEex_Options_DisplayEntry.new({
            ["optionID"]    = "BuffBot_TextSize",
            ["label"]       = "BuffBot_TextSize_Small",
            ["description"] = "BuffBot_TextSize_Desc",
            ["widget"]      = EEex_Options_ToggleWidget.new({
                ["toggleValue"]       = 1,
                ["disallowToggleOff"] = true,
            }),
        }),
        EEex_Options_DisplayEntry.new({
            ["optionID"]    = "BuffBot_TextSize",
            ["label"]       = "BuffBot_TextSize_Medium",
            ["description"] = "BuffBot_TextSize_Desc",
            ["widget"]      = EEex_Options_ToggleWidget.new({
                ["toggleValue"]       = 2,
                ["disallowToggleOff"] = true,
            }),
        }),
        EEex_Options_DisplayEntry.new({
            ["optionID"]    = "BuffBot_TextSize",
            ["label"]       = "BuffBot_TextSize_Large",
            ["description"] = "BuffBot_TextSize_Desc",
            ["widget"]      = EEex_Options_ToggleWidget.new({
                ["toggleValue"]       = 3,
                ["disallowToggleOff"] = true,
            }),
        }),
    }

    -- Tab definition: 3 groups separated by dividers in the UI.
    EEex_Options_AddTab("BuffBot_Tab", function() return {
        -- Group 1: Dark Mode (single toggle)
        {
            EEex_Options_DisplayEntry.new({
                ["optionID"]    = "BuffBot_DarkMode",
                ["label"]       = "BuffBot_DarkMode",
                ["description"] = "BuffBot_DarkMode_Desc",
                ["widget"]      = EEex_Options_ToggleWidget.new(),
            }),
        },
        -- Group 2: Color Scheme (3 toggles sharing BuffBot_Accent option)
        accentEntries,
        -- Group 3: Text Size (3 toggles sharing BuffBot_TextSize option)
        sizeEntries,
    } end)

    -- _ReadOptions(false) already fired before _OnMenusLoaded, so our newly
    -- registered options were not in the auto-read pass. Manually push the
    -- live theme state into each option's _workingValue so widgets render
    -- the correct selected state on first open.
    local function _seed(id)
        local opt = EEex_Options_Get and EEex_Options_Get(id)
        if opt and opt._read then
            local val = opt:_read()
            if val ~= nil then opt:_set(val, true) end
        end
    end
    _seed("BuffBot_DarkMode")
    _seed("BuffBot_Accent")
    _seed("BuffBot_TextSize")

    -- Patch _setWorkingValue on the two radio-group options to keep all
    -- sibling widgets' visual state in sync per-click. EEex's toggleAction
    -- only updates the clicked widget's `toggleState`; without this, the
    -- previous selection visually stays selected until the user closes and
    -- reopens the Options menu (which re-runs _onShowBeforeLayout).
    local function _patchRadio(optionID, entries)
        local opt = EEex_Options_Get(optionID)
        if not opt then return end
        opt._setWorkingValue = function(self, newValue, needCopy)
            newValue = EEex_Options_Option._setWorkingValue(self, newValue, needCopy)
            for _, de in ipairs(entries) do
                de.widget.toggleState = (de.widget.toggleValue == newValue)
            end
            return newValue
        end
    end
    _patchRadio("BuffBot_Accent", accentEntries)
    _patchRadio("BuffBot_TextSize", sizeEntries)

    BfBot.Theme._registered = true
end
