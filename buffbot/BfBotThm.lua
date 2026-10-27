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
--   itemColor    — spell-name tint for item (kind="itm") rows
--
-- Menu-region specific:
--   grip         — resize grip in bottom-right corner
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
        -- Caption on a chrome plate. Pecca's art is dark in every
        -- skin, so this follows the plate, not the parchment.
        btnText      = "{235, 222, 196}",
        btnTextOff   = "{142, 128, 104}",
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
        headerSub    = "{120, 90, 20}",
        lockText     = "{150, 120, 80}",
        spellLocked  = "{100, 70, 20}",
        -- Picker
        pickerSel    = "{255, 255, 150}",
        pickerOn     = "{220, 220, 220}",
        pickerOff    = "{140, 140, 140}",
        -- QuickCast
        qcOff        = "{176, 164, 142}",
        qcLong       = "{160, 120, 20}",
        qcAll        = "{180, 60, 30}",
        -- Lock column
        lockActive   = "{230, 200, 60}",
        lockInactive = "{120, 100, 80}",
        itemColor    = "{205, 127, 50}",
    },
    bg2_dark = {
        -- Caption on a chrome plate. Pecca's art is dark in every
        -- skin, so this follows the plate, not the parchment.
        btnText      = "{235, 222, 196}",
        btnTextOff   = "{142, 128, 104}",
        overlay      = 160,
        borderResref = "BFBOTFR",
        bgResref     = "BFBOTBG",
        title        = "{230, 200, 150}",
        text         = "{210, 190, 160}",
        textMuted    = "{130, 120, 105}",
        textAccent   = "{130, 180, 240}",
        grip         = "{180, 150, 110}",
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
        itemColor    = "{217, 160, 99}",
    },
    sod_light = {
        -- Caption on a chrome plate. Pecca's art is dark in every
        -- skin, so this follows the plate, not the parchment.
        btnText      = "{226, 226, 232}",
        btnTextOff   = "{132, 134, 146}",
        overlay      = 60,
        borderResref = "BFBOTFR2",
        bgResref     = "BFBOTBG2",
        title        = "{220, 230, 240}",
        text         = "{220, 225, 235}",
        textMuted    = "{150, 160, 170}",
        textAccent   = "{140, 200, 240}",
        grip         = "{180, 190, 210}",
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
        itemColor    = "{206, 142, 78}",
    },
    sod_dark = {
        -- Caption on a chrome plate. Pecca's art is dark in every
        -- skin, so this follows the plate, not the parchment.
        btnText      = "{226, 226, 232}",
        btnTextOff   = "{132, 134, 146}",
        overlay      = 180,
        borderResref = "BFBOTFR2",
        bgResref     = "BFBOTBG2",
        title        = "{200, 220, 235}",
        text         = "{190, 210, 225}",
        textMuted    = "{130, 145, 155}",
        textAccent   = "{120, 190, 240}",
        grip         = "{160, 180, 200}",
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
        itemColor    = "{204, 140, 73}",
    },
    bg1_light = {
        -- Caption on a chrome plate. Pecca's art is dark in every
        -- skin, so this follows the plate, not the parchment.
        btnText      = "{236, 224, 190}",
        btnTextOff   = "{176, 154, 124}",
        overlay      = 60,
        borderResref = "BFBOTFR3",
        bgResref     = "BFBOTBG3",
        title        = "{230, 200, 160}",
        text         = "{220, 195, 160}",
        textMuted    = "{160, 140, 120}",
        textAccent   = "{240, 180, 100}",
        grip         = "{200, 170, 130}",
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
        itemColor    = "{214, 138, 84}",
    },
    bg1_dark = {
        -- Caption on a chrome plate. Pecca's art is dark in every
        -- skin, so this follows the plate, not the parchment.
        btnText      = "{236, 224, 190}",
        btnTextOff   = "{176, 154, 124}",
        overlay      = 180,
        borderResref = "BFBOTFR3",
        bgResref     = "BFBOTBG3",
        title        = "{240, 200, 130}",
        text         = "{220, 190, 150}",
        textMuted    = "{150, 130, 110}",
        textAccent   = "{240, 170, 90}",
        grip         = "{190, 165, 125}",
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
        itemColor    = "{198, 142, 95}",
    },
}

-- Active palette reference; defaults to bg2_light (pixel-match current behavior).
BfBot.Theme._active = BfBot.Theme._palettes.bg2_light

-- Pre-create BfBot.UI namespace. BfBotThm loads before BfBotUI, so BfBot.UI
-- doesn't exist yet; the `or {}` guard creates it without stomping if it does.
BfBot.UI = BfBot.UI or {}

-- Packed-color cache, keyed by the palette's own "{R, G, B}" string. Every
-- rendered row asks _T for its colors, so the match+pack runs once per shade
-- for the whole session rather than once per frame.
BfBot.Theme._packed = {}

--- Pack a palette "{R, G, B}" string the way the engine reads a color.
-- The engine wants one 32-bit number, and it unpacks it as
-- alpha<<24 | blue<<16 | green<<8 | red — blue and red the other way round
-- from the usual 0xAARRGGBB. EEex reads its own font colors exactly this way
-- (`EEex_Options_Private_UnpackColor`, and `GetFontStyleColor` masks the alpha
-- byte to 0), which is the evidence this byte order is right.
local function _pack(s)
    local cached = BfBot.Theme._packed[s]
    if cached then return cached end
    local r, g, b = s:match("^%{(%d+),%s*(%d+),%s*(%d+)%}$")
    if not r then return 0x0000FF end  -- unreadable entry → red, a visible signal
    local packed = (tonumber(b) * 0x10000) + (tonumber(g) * 0x100) + tonumber(r)
    BfBot.Theme._packed[s] = packed
    return packed
end

--- Theme color accessor.
-- Returns the active palette's color for the given semantic key as the packed
-- number the engine expects, or magenta if the key is missing (visible debug
-- signal). Hand the result straight to `text color lua` or to any Lua color
-- callback — both want the same number.
--
-- Before v1.12.1 this returned the palette's raw "{R, G, B}" string, which no
-- engine path could read, so every label fell back to its style's default and
-- the panel rendered the same near-black text in all six palettes.
-- @param key string — one of the keys listed in the Palette Key Glossary above
function BfBot.UI._T(key)
    local v = BfBot.Theme._active[key]
    if v == nil then return 0xFF00FF end
    return _pack(v)
end

--- The palette's raw "{R, G, B}" string, for callers that need the components
-- rather than a color to render — the test suite reads these.
function BfBot.UI._TRaw(key)
    return BfBot.Theme._active[key]
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
    -- Button captions, in their own labels rather than on the buttons.
    -- Two reasons: ITEM_BUTTON ignores a caption's point size, and the
    -- engine's button face (STONESML) is an ALL-CAPS typeface, so
    -- "Add Spell/Item" came out as a fixed-size "ADD SPELL/ITEM" that
    -- overflowed its plate. As a label in the body face it keeps its own
    -- case, fits, and follows the font-size preference.
    bb_caption          = 12,
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
    bb_caption          = "normal",
}
-- Font size multiplier: 1=small, 2=medium (default), 3=large
BfBot.Theme._SIZE_MULT = { [1] = 0.85, [2] = 1.0, [3] = 1.20 }
BfBot.Theme._fontSize = 2

-- Per-control caption scale, keyed by the control's name. A footer row that
-- does not fit narrows every plate in it by one factor; the captions are
-- separate items drawn at the font's own size and centred, so without this
-- they keep their width while the plates shrink -- "Down" printed across
-- "Up" and "Sort", "Delete Preset" ran off the panel, and the click landed
-- on whatever plate was really under the text. _Layout fills this.
BfBot.Theme._captionScales = {}

--- The factor an item's text size is multiplied by, 1 when it is not on a
--- narrowed plate. A caption label is "<control>_t" and the two status
--- toggles that have to stay text items carry the control's own name, so
--- both resolve to the same entry.
--- @param itemName string|nil menu item name
function BfBot.Theme.CaptionScale(itemName)
    if type(itemName) ~= "string" then return 1 end
    local scales = BfBot.Theme._captionScales
    local scale = scales[itemName]
    if scale == nil and itemName:sub(-2) == "_t" then
        scale = scales[itemName:sub(1, -3)]
    end
    if type(scale) ~= "number" or scale ~= scale or scale > 1 then return 1 end
    if scale <= 0 then return 1 end
    return scale
end

--- Replace the caption scales. _Layout reports only the controls it narrowed,
--- so a panel that grows again gives every other caption its size back.
--- @param scales table|nil control name -> factor in (0, 1]
function BfBot.Theme.ApplyCaptionScales(scales)
    local out = {}
    for name, scale in pairs(scales or {}) do out[name] = scale end
    BfBot.Theme._captionScales = out
end

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
    local map, ambiguous = BfBot.Theme._DeriveFontBasePoints()
    BfBot.Theme._FONT_TO_BASE_POINT = map
    if #ambiguous > 0 and BfBot._Warn then
        BfBot._Warn("Theme: fonts shared by text styles of different sizes keep their "
            .. "load-time size: " .. table.concat(ambiguous, ", "))
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

--- Map each font the registered bb_* styles inherit (upper case) to BuffBot's
-- base point. A parsed item keeps only its font, not its style, so the font is
-- what live rescaling goes by. The fonts come from the game's own styles:
-- BG2:EE draws body, cell and edit text in NORMAL and titles in REALMS, while
-- IWD:EE uses POSTANTI for parchment and edit text and SHERWOOD for titles;
-- both use STONESML for buttons (whose point ITEM_BUTTON ignores). A font two
-- bb_* styles share with different base points (a UI mod can make it so) stays
-- unmapped: which style an item came from is unknowable, so it keeps the size
-- it was parsed with, correct for the text size chosen at load.
-- @return map, sorted list of the fonts left unmapped as ambiguous
function BfBot.Theme._DeriveFontBasePoints()
    local map, ambiguous = {}, {}
    if type(styles) == "table" then
        for bbName, basePt in pairs(BfBot.Theme._BASE_POINTS) do
            local style = styles[bbName]
            local font = type(style) == "table" and style.font
            if type(font) == "string" and font ~= "" then
                font = font:upper()
                if not ambiguous[font] then
                    if map[font] == nil then
                        map[font] = basePt
                    elseif map[font] ~= basePt then
                        map[font] = nil
                        ambiguous[font] = true
                    end
                end
            end
        end
    end
    local list = {}
    for font in pairs(ambiguous) do list[#list + 1] = font end
    table.sort(list)
    return map, list
end

-- Engine items in OTHER menus aren't touched — iteration is scoped to our
-- owned menus. Filled by _RegisterStyles; deriving here as well keeps live
-- scaling working when this file is reloaded after the styles exist.
BfBot.Theme._FONT_TO_BASE_POINT = BfBot.Theme._DeriveFontBasePoints()

-- Menus we own (defined in buffbot/BuffBot.menu). Iterated by name.
BfBot.Theme._OWNED_MENUS = {
    "BUFFBOT_MAIN",
    "BUFFBOT_TARGETS",
    "BUFFBOT_RENAME",
    "BUFFBOT_CONFIRM",
    "BUFFBOT_SPELLPICKER",
    "BUFFBOT_IMPORT",
    "BUFFBOT_VARIANTS",
    "BUFFBOT_QUICK_PRESETS",
}

--- Compute the correct point size for a uiItem by looking up its font name
-- in the BuffBot font→base table and multiplying by the current size mult.
-- No-op when item lacks a recognized font (skips engine items in unrelated
-- menus we don't own).
local function _updateItemPoint(item, itemName)
    local txt = item and item.text
    if not txt or not txt.font then return end
    local ok, fontName = pcall(function() return txt.font:get() end)
    if not ok or type(fontName) ~= "string" then return end
    local base = BfBot.Theme._FONT_TO_BASE_POINT[fontName:upper()]
    if not base then return end
    local mult = BfBot.Theme._SIZE_MULT[BfBot.Theme._fontSize] or 1.0
    -- A caption on a plate the footer had to narrow shrinks with it. This has
    -- to happen here, in the per-render listener, because the listener is the
    -- last word on an item's point: writing a scaled point anywhere else is
    -- overwritten before the next frame is drawn.
    -- Past six points the panel is simply too small, and an unreadable
    -- caption on its own plate still beats a readable one printed over its
    -- neighbour, where the click would land on that one instead.
    txt.point = math.max(
        math.floor(base * mult * BfBot.Theme.CaptionScale(itemName)), 6)
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
-- updates item types that re-read `text.point`; ITEM_BUTTON ignores the field
-- even here. A BeforeUIItemRenderListener per named item keeps scalable item
-- types synchronized across internal snapshots and menu pushes.
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
                    -- The name is captured here rather than read back from
                    -- the item each frame: the listener is per name anyway,
                    -- and the caption scale is looked up by it.
                    local itemName = name
                    EEex_Menu_AddBeforeUIItemRenderListener(name, function(it)
                        _updateItemPoint(it, itemName)
                    end)
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
-- re-apply this on each subsequent frame for item types that support dynamic
-- point sizing. Engine ITEM_BUTTON captions remain fixed-size.
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

-- ============================================================
-- Themed control art (buffbot/visual)
-- ============================================================
-- The control BAMs are BAM V2: their pixels live in the numbered PVRZ pages
-- shipped beside them. Each skin has its own look, carried either by the file
-- name (BFBCHK<skin>) or by the cycle. The art carries a separate usage
-- permission — see ATTRIBUTION.md — so an install can legitimately be without
-- it. Every caller must degrade to the text markers rather than render blank.

--- Skin index into the control art: 0 BG:EE, 1 IWD, 2 SoD, 3 BG2.
-- Read off the art, not assumed: skin 0 is BG:EE's red marble with gold
-- filigree and a round socket, 1 is IWD's plain wood, 2 is SoD's cold steel
-- with a square socket, 3 is BG2's dark stone. The plate cycles and the
-- BFBCHK<skin> files use the same order. BuffBot has no IWD palette; its
-- accents map onto the other three.
function BfBot.Theme.ControlSkin()
    return ({ bg1 = 0, sod = 2, bg2 = 3 })[BfBot.Theme._GetAccentName()] or 3
end

--- True once the control art is confirmed present. Cached: a missing resource
--- cannot appear while the game runs, and this is read per rendered row.
function BfBot.Theme.HasControlArt()
    if BfBot.Theme._controlArt ~= nil then return BfBot.Theme._controlArt end
    if type(EEex_Resource_Fetch) ~= "function" then return false end
    for _, resref in ipairs({ "BFBCHK0", "BFBCHK1", "BFBCHK2", "BFBCHK3", "BFBGLYPH" }) do
        local ok, found = pcall(EEex_Resource_Fetch, resref, "BAM")
        if not ok then return false end
        if not found then
            BfBot.Theme._controlArt = false
            return false
        end
    end
    BfBot.Theme._controlArt = true
    return true
end

--- True once the panel chrome art is confirmed present — the button plates,
--- tabs, cast plate and scrollbar. Checked separately from the row art above
--- so a partial install degrades per group: a panel can keep its themed
--- checkboxes while falling back to the game's own buttons (ButtonBam below).
--- Cached for the same reason: a missing resource cannot appear mid-session.
function BfBot.Theme.HasChromeArt()
    if BfBot.Theme._chromeArt ~= nil then return BfBot.Theme._chromeArt end
    if type(EEex_Resource_Fetch) ~= "function" then return false end
    for _, resref in ipairs({ "BFBPLAT", "BFBTAB", "BFBCAST", "BFBSCRL" }) do
        local ok, found = pcall(EEex_Resource_Fetch, resref, "BAM")
        if not ok then return false end
        if not found then
            BfBot.Theme._chromeArt = false
            return false
        end
    end
    BfBot.Theme._chromeArt = true
    return true
end

-- ============================================================
-- Engine button art
-- ============================================================
-- Without the chrome art the panel's buttons and tabs draw the game's own
-- wide button BAM. BG:EE, BG2:EE and EET use GUIOSTUL. IWD:EE ships a BAM
-- under that name too, but its frames are unrelated texture fragments; the
-- game's own buttons use GUIBUTMT, with the same frame order (normal,
-- pressed, highlighted, disabled). engine.lua's engine_mode names the game:
-- 0 BGEE, 1 BG2EE, 2 IWDEE.

--- Resref of the engine button BAM for the running game.
function BfBot.Theme.ButtonBam()
    return engine_mode == 2 and "GUIBUTMT" or "GUIOSTUL"
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
-- Adds a "BuffBot" tab to the EEex Options menu (Esc → Options) with
-- appearance controls and the inventory item-use mode.
--
-- Persistence note: appearance options bridge to live BfBot.Theme state,
-- using the existing [BuffBot]Theme + [BuffBot]FontSize keys. Item use
-- bridges to the [BuffBot]ItemUseMode preference (inventory or swap).
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
    uiStrings.BuffBot_Tab = BfBot.L10N.Get("options.tab")
    uiStrings.BuffBot_DarkMode = BfBot.L10N.Get("options.dark_mode")
    uiStrings.BuffBot_DarkMode_Desc = BfBot.L10N.Get("options.dark_mode_description")
    uiStrings.BuffBot_Accent = BfBot.L10N.Get("options.color_scheme")
    uiStrings.BuffBot_Accent_Desc = BfBot.L10N.Get("options.color_scheme_description")
    uiStrings.BuffBot_Accent_BG2 = BfBot.L10N.Get("options.color_scheme_bg2")
    uiStrings.BuffBot_Accent_SOD = BfBot.L10N.Get("options.color_scheme_sod")
    uiStrings.BuffBot_Accent_BG1 = BfBot.L10N.Get("options.color_scheme_bg1")
    uiStrings.BuffBot_TextSize = BfBot.L10N.Get("options.text_size")
    uiStrings.BuffBot_TextSize_Desc = BfBot.L10N.Get("options.text_size_description")
    uiStrings.BuffBot_TextSize_Small = BfBot.L10N.Get("options.text_size_small")
    uiStrings.BuffBot_TextSize_Medium = BfBot.L10N.Get("options.text_size_medium")
    uiStrings.BuffBot_TextSize_Large = BfBot.L10N.Get("options.text_size_large")
    uiStrings.BuffBot_ItemUseMode = BfBot.L10N.Get("options.item_use_mode")
    uiStrings.BuffBot_ItemUseMode_Desc = BfBot.L10N.Get("options.item_use_mode_description")
    uiStrings.BuffBot_ItemUseMode_Inventory = BfBot.L10N.Get("options.item_use_inventory")
    uiStrings.BuffBot_ItemUseMode_Swap = BfBot.L10N.Get("options.item_use_swap")
    uiStrings.BuffBot_RefreshBelow = BfBot.L10N.Get("options.refresh_below")
    uiStrings.BuffBot_RefreshBelow_Desc = BfBot.L10N.Get("options.refresh_below_description")
    uiStrings.BuffBot_RefreshBelow_Off = BfBot.L10N.Get("options.refresh_below_off")
    uiStrings.BuffBot_RefreshBelow_1m = BfBot.L10N.Get("options.refresh_below_1m")
    uiStrings.BuffBot_RefreshBelow_5m = BfBot.L10N.Get("options.refresh_below_5m")
    uiStrings.BuffBot_RefreshBelow_1h = BfBot.L10N.Get("options.refresh_below_1h")
end

-- Radio presets for the RefreshBelow threshold, in seconds (issue #84). The
-- INI value itself is a free number (BfBot.Persist.GetRefreshBelow validates
-- it), so this list is a convenience, not the range of legal values.
BfBot.Theme.REFRESH_BELOW_CHOICES = { 0, 60, 300, 3600 }

--- Radio index for a stored RefreshBelow threshold. A hand-edited value that
--- is not one of the presets shows the largest preset at or below it, so the
--- panel never claims the threshold is off while it is actually on. Reading
--- never writes, so a custom value survives until the user clicks a choice.
function BfBot.Theme._RefreshBelowIndex(seconds)
    if type(seconds) ~= "number" or seconds <= 0 then return 1 end
    local index = 2  -- any positive threshold is at least the smallest preset
    for i, value in ipairs(BfBot.Theme.REFRESH_BELOW_CHOICES) do
        if value > 0 and value <= seconds then index = i end
    end
    return index
end

--- Build a custom storage class that bridges between an EEex option's
-- numeric value and live BuffBot preferences. `getter` reads the current
-- value (number); `setter(value)` applies and persists it.
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
    if not EEex_Options_Widget then return end
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

    -- Inventory items (2-way radio: 1=direct inventory use, 2=equip/use/restore)
    local ItemUseBridge = _makeBridgeStorage(
        function() return BfBot.Persist.GetPref("ItemUseMode") == "swap" and 2 or 1 end,
        function(v) BfBot.Persist.SetPref("ItemUseMode", v == 2 and "swap" or "inventory") end
    )
    EEex_Options_Register("BuffBot_ItemUseMode", EEex_Options_Option.new({
        ["default"]  = 1,
        ["type"]     = EEex_Options_ToggleType.new(),
        ["accessor"] = EEex_Options_ClampedAccessor.new({ ["min"] = 1, ["max"] = 2 }),
        ["storage"]  = ItemUseBridge.new(),
    }))

    -- Refresh nearly-over buffs (4-way radio over REFRESH_BELOW_CHOICES)
    local RefreshBelowBridge = _makeBridgeStorage(
        function()
            return BfBot.Theme._RefreshBelowIndex(
                BfBot.Persist.GetRefreshBelow())
        end,
        function(v)
            local seconds = BfBot.Theme.REFRESH_BELOW_CHOICES[v] or 0
            BfBot.Persist.SetRefreshBelow(seconds)
        end
    )
    EEex_Options_Register("BuffBot_RefreshBelow", EEex_Options_Option.new({
        ["default"]  = 1,
        ["type"]     = EEex_Options_ToggleType.new(),
        ["accessor"] = EEex_Options_ClampedAccessor.new({
            ["min"] = 1, ["max"] = #BfBot.Theme.REFRESH_BELOW_CHOICES }),
        ["storage"]  = RefreshBelowBridge.new(),
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

    local itemUseEntries = {
        EEex_Options_DisplayEntry.new({
            ["optionID"]    = "BuffBot_ItemUseMode",
            ["label"]       = "BuffBot_ItemUseMode_Inventory",
            ["description"] = "BuffBot_ItemUseMode_Desc",
            ["widget"]      = EEex_Options_ToggleWidget.new({
                ["toggleValue"]       = 1,
                ["disallowToggleOff"] = true,
            }),
        }),
        EEex_Options_DisplayEntry.new({
            ["optionID"]    = "BuffBot_ItemUseMode",
            ["label"]       = "BuffBot_ItemUseMode_Swap",
            ["description"] = "BuffBot_ItemUseMode_Desc",
            ["widget"]      = EEex_Options_ToggleWidget.new({
                ["toggleValue"]       = 2,
                ["disallowToggleOff"] = true,
            }),
        }),
    }

    local refreshBelowEntries = {}
    local refreshBelowLabels = {
        "BuffBot_RefreshBelow_Off",
        "BuffBot_RefreshBelow_1m",
        "BuffBot_RefreshBelow_5m",
        "BuffBot_RefreshBelow_1h",
    }
    for i, label in ipairs(refreshBelowLabels) do
        refreshBelowEntries[i] = EEex_Options_DisplayEntry.new({
            ["optionID"]    = "BuffBot_RefreshBelow",
            ["label"]       = label,
            ["description"] = "BuffBot_RefreshBelow_Desc",
            ["widget"]      = EEex_Options_ToggleWidget.new({
                ["toggleValue"]       = i,
                ["disallowToggleOff"] = true,
            }),
        })
    end

    -- Outer groups are columns. Keep inventory controls in the first
    -- column to avoid widening the tab with a fourth column.
    EEex_Options_AddTab("BuffBot_Tab", function() return {
        -- Column 1: Dark Mode and inventory item use
        {
            EEex_Options_DisplayEntry.new({
                ["optionID"]    = "BuffBot_DarkMode",
                ["label"]       = "BuffBot_DarkMode",
                ["description"] = "BuffBot_DarkMode_Desc",
                ["widget"]      = EEex_Options_ToggleWidget.new(),
            }),
            EEex_Options_DisplayEntry.new({
                ["optionID"]    = "BuffBot_ItemUseMode",
                ["label"]       = "BuffBot_ItemUseMode",
                ["description"] = "BuffBot_ItemUseMode_Desc",
                -- The base widget has no layout: this entry is a heading.
                ["widget"]      = setmetatable({}, EEex_Options_Widget),
                ["subOptions"]  = itemUseEntries,
            }),
            EEex_Options_DisplayEntry.new({
                ["optionID"]    = "BuffBot_RefreshBelow",
                ["label"]       = "BuffBot_RefreshBelow",
                ["description"] = "BuffBot_RefreshBelow_Desc",
                -- The base widget has no layout: this entry is a heading.
                ["widget"]      = setmetatable({}, EEex_Options_Widget),
                ["subOptions"]  = refreshBelowEntries,
            }),
        },
        -- Column 2: Color Scheme (3 toggles sharing BuffBot_Accent option)
        accentEntries,
        -- Column 3: Text Size (3 toggles sharing BuffBot_TextSize option)
        sizeEntries,
    } end)

    -- _ReadOptions(false) already fired before _OnMenusLoaded, so our newly
    -- registered options were not in the auto-read pass. Manually push the
    -- live preferences into each option's _workingValue so widgets render
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
    _seed("BuffBot_ItemUseMode")
    _seed("BuffBot_RefreshBelow")

    -- Patch _setWorkingValue on the radio-group options to keep all
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
    _patchRadio("BuffBot_ItemUseMode", itemUseEntries)
    _patchRadio("BuffBot_RefreshBelow", refreshBelowEntries)

    BfBot.Theme._registered = true
end
