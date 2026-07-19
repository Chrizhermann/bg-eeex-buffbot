-- ============================================================
-- BfBotUI.lua — BuffBot Configuration UI
-- Lua-side logic for the BuffBot panel (.menu callbacks,
-- state management, spell table population)
-- ============================================================

-- BfBotThm has already set BfBot.UI = {} and added BfBot.UI._T. Use `or {}`
-- so we don't wipe _T (which the .menu evaluates per-frame for theme colors).
BfBot.UI = BfBot.UI or {}

-- Convert "{R, G, B}" string → {R, G, B} table. Used by color functions
-- that consume _T() (string) and hand tables back to the engine.
local function _parseColor(s)
    local r, g, b = s:match("^%{(%d+),%s*(%d+),%s*(%d+)%}$")
    return { tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0 }
end

-- ============================================================
-- Internal State
-- ============================================================

BfBot.UI._charSlot = 0        -- selected character slot (0-5)
BfBot.UI._presetIdx = 1       -- selected preset index (shared across views)
BfBot.UI._view = "party"      -- active view: "party" (portrait tabs) or "summons"
BfBot.UI._initialized = false

-- Summons view state (issue #19, Task 10)
BfBot.UI._SUMMONS_PER_PAGE = 6   -- tab slots per page (mirrors the 6 portrait tabs)
BfBot.UI._summonList = {}        -- UI-owned copies of GetAlliedSummons entries (no sprites)
BfBot.UI._summonSlice = {}       -- current page's entries (kept in sync with tab labels)
BfBot.UI._summonPage = 1         -- 1-based page into _summonList
BfBot.UI._summonSel = nil        -- selection descriptor {identity, oid, name, cloneType} — NEVER a row index
BfBot.UI._summonQc = nil         -- cached summons-view Quick Cast value (see _UpdateSummonQc)

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
-- Summons View (issue #19, Task 10)
-- ============================================================

--- PURE: slice a summon list into the visible page (≤ _SUMMONS_PER_PAGE
--- entries). The requested page is clamped into [1, pageCount] — an empty
--- list yields an empty slice on page 1/1.
-- @param list  array of summon entries
-- @param page  requested 1-based page number (any number; clamped)
-- @return slice (array), clampedPage, pageCount
function BfBot.UI._SummonPageSlice(list, page)
    local per = BfBot.UI._SUMMONS_PER_PAGE
    local slice = {}
    if type(list) ~= "table" or #list == 0 then
        return slice, 1, 1
    end
    local pageCount = math.ceil(#list / per)
    local p = tonumber(page) or 1
    p = math.floor(p)
    if p < 1 then p = 1 end
    if p > pageCount then p = pageCount end
    local base = (p - 1) * per
    for i = 1, per do
        local e = list[base + i]
        if not e then break end
        slice[i] = e
    end
    return slice, p, pageCount
end

-- Clone-type display nouns (derived stat 139 PUPPETMASTERTYPE: 1=Mislead,
-- 2=Project Image, 3=Simulacrum — probe-verified for 2/3).
local _CLONE_NOUNS = { [1] = "Mislead", [2] = "Image", [3] = "Simulacrum" }

--- PURE: tab label for a summon entry. Clones get an owner-possessive label
--- ("Imoen's Image"); the owner comes from the entry's ownerName, falling
--- back to the "clone:<Owner>" identity. Everything else shows its name.
function BfBot.UI._SummonTabLabel(entry)
    if type(entry) ~= "table" then return "" end
    if entry.kind == "clone" then
        local owner = entry.ownerName
        if (not owner or owner == "") and type(entry.identity) == "string" then
            owner = entry.identity:match("^clone:(.+)$")
        end
        if owner and owner ~= "" then
            return owner .. "'s " .. (_CLONE_NOUNS[entry.cloneType] or "Clone")
        end
    end
    return entry.name or ""
end

--- PURE: build the UI's summon-list model from GetAlliedSummons output.
--- Every entry is COPIED (the scanner's array and entry tables are
--- cache-owned — hand-off 5) and the sprite field is dropped (no userdata in
--- UI state). Entries without a non-empty name are refused: the resolver's
--- anti-oid-recycle guard is conditional on ref.name, so a nameless entry
--- would silently degrade to oid-only matching (hand-off 3).
function BfBot.UI._BuildSummonListModel(raw)
    local model = {}
    if type(raw) ~= "table" then return model end
    for _, e in ipairs(raw) do
        if type(e) == "table" and type(e.oid) == "number"
            and type(e.name) == "string" and e.name ~= ""
            and type(e.identity) == "string" and e.identity ~= "" then
            model[#model + 1] = {
                oid = e.oid,
                name = e.name,
                kind = e.kind,
                identity = e.identity,
                ownerName = e.ownerName,
                cloneType = e.cloneType,
            }
        end
    end
    return model
end

--- Re-establish the selection after a list rebuild — identity-stable, NEVER
--- by row index (rowNumber-staleness class of bug). Pass 1 matches the exact
--- sprite (oid+name); pass 2 falls back to the identity (a respawned "same"
--- summon keeps its tab), PREFERRING an entry of the same clone type — one
--- owner can have BOTH a Project Image and a Simulacrum alive (shared
--- identity "clone:<owner>"), and an expired+resummoned selection must not
--- silently jump to the other clone type (review MINOR-5); first identity
--- match only when no type match exists. No match → first entry; empty
--- list → no selection.
--- Also moves _summonPage to the page containing the selection.
function BfBot.UI._ReselectSummon()
    local list = BfBot.UI._summonList
    local sel = BfBot.UI._summonSel
    local found = nil
    if sel then
        for _, e in ipairs(list) do
            if e.oid == sel.oid and e.name == sel.name then
                found = e
                break
            end
        end
        if not found then
            local anyIdentity = nil
            for _, e in ipairs(list) do
                if e.identity == sel.identity then
                    if e.cloneType == sel.cloneType then
                        found = e
                        break
                    end
                    anyIdentity = anyIdentity or e
                end
            end
            found = found or anyIdentity
        end
    end
    if not found then found = list[1] end
    if found then
        BfBot.UI._summonSel = {
            identity = found.identity, oid = found.oid, name = found.name,
            cloneType = found.cloneType,
        }
        for i, e in ipairs(list) do
            if e == found then
                BfBot.UI._summonPage =
                    math.floor((i - 1) / BfBot.UI._SUMMONS_PER_PAGE) + 1
                break
            end
        end
    else
        BfBot.UI._summonSel = nil
        BfBot.UI._summonPage = 1
    end
end

--- Rebuild _summonList from a fresh area sweep (cache dropped first), reset
--- paging, and re-select identity-stably. Called on panel open (summons
--- view) and on every view switch.
function BfBot.UI._RefreshSummonList()
    BfBot.Scan.InvalidateSummons()
    local ok, raw = pcall(BfBot.Scan.GetAlliedSummons)
    if not ok then
        BfBot._Warn("[UI] summon sweep failed: " .. tostring(raw))
        raw = nil
    end
    BfBot.UI._summonList = BfBot.UI._BuildSummonListModel(raw)
    BfBot.UI._summonPage = 1
    BfBot.UI._ReselectSummon()
    -- Keep the visible slice + tab labels in sync with the rebuilt list —
    -- SetSummon acts on the slice, so it must never lag the list.
    BfBot.UI._UpdateSummonTabNames()
end

--- Selected summon entry from the list model, or nil. The descriptor is
--- matched by oid+name (kept fresh by _ReselectSummon on every rebuild).
function BfBot.UI._SelectedSummon()
    local sel = BfBot.UI._summonSel
    if not sel then return nil end
    for _, e in ipairs(BfBot.UI._summonList) do
        if e.oid == sel.oid and e.name == sel.name then return e end
    end
    return nil
end

--- Is the party view active? (menu `enabled` gates for party-only widgets)
function BfBot.UI._IsPartyView()
    return BfBot.UI._view ~= "summons"
end

--- View toggle button caption: offers the OTHER view.
function BfBot.UI._ViewBtnLabel()
    if BfBot.UI._IsPartyView() then return "Summons" end
    return "Party"
end

--- Toggle between party and summons view. Preset index is a shared axis and
--- survives the switch; the summon list is re-swept on every switch.
function BfBot.UI.ToggleView()
    if BfBot.UI._view == "summons" then
        BfBot.UI._view = "party"
    else
        BfBot.UI._view = "summons"
    end
    BfBot.UI._RefreshSummonList()
    BfBot.UI._Refresh()
end

--- Select the summon in tab slot n (1-6) of the CURRENT page. Uses the
--- displayed slice, so what the user clicked is what gets selected.
function BfBot.UI.SetSummon(n)
    local e = BfBot.UI._summonSlice[n]
    if not e then return end
    BfBot.UI._summonSel = { identity = e.identity, oid = e.oid, name = e.name,
        cloneType = e.cloneType }
    BfBot.UI._Refresh()
end

--- Page the summon tab row by delta (±1). Clamping lives in _SummonPageSlice.
function BfBot.UI.SummonPage(delta)
    local _, p = BfBot.UI._SummonPageSlice(BfBot.UI._summonList,
        BfBot.UI._summonPage + (delta or 0))
    BfBot.UI._summonPage = p
    BfBot.UI._Refresh()
end

--- Summon tab visibility (menu gate): summons view + a label in that slot.
function BfBot.UI._SummonTabVisible(n)
    return buffbot_isOpen and BfBot.UI._view == "summons"
        and buffbot_summonTabNames[n] ~= nil
end

--- Selected-state for summon tab slot n (frame lua).
function BfBot.UI._IsSummonSelected(n)
    local sel = BfBot.UI._summonSel
    if not sel then return false end
    local e = BfBot.UI._summonSlice[n]
    return e ~= nil and e.oid == sel.oid and e.name == sel.name
end

--- Paging controls visible only when the list overflows one page.
function BfBot.UI._SummonPagingVisible()
    return buffbot_isOpen and BfBot.UI._view == "summons"
        and #BfBot.UI._summonList > BfBot.UI._SUMMONS_PER_PAGE
end

--- Empty-state label ("No allied summons detected").
function BfBot.UI._SummonEmptyVisible()
    return buffbot_isOpen and BfBot.UI._view == "summons"
        and #BfBot.UI._summonList == 0
end

--- Current view's selected sprite: party view resolves the portrait slot,
--- summons view live-resolves the selected summon via oid+name re-validation.
--- Always a fresh resolve — never cache the returned userdata across frames (#38).
function BfBot.UI._GetSelectedSprite()
    if BfBot.UI._view == "summons" then
        local entry = BfBot.UI._SelectedSummon()
        return entry and BfBot.Exec._ResolveCaster({
            kind = "summon", oid = entry.oid, name = entry.name,
        }) or nil
    end
    return EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
end

-- ============================================================
-- Global Variables (read by .menu expressions every frame)
-- ============================================================

-- Panel state
buffbot_isOpen = false
buffbot_title = "BuffBot"
buffbot_status = ""
buffbot_btnTooltip = "BuffBot Configuration"
buffbot_btnFrame = 0             -- 0=normal, 1=active/running

-- Character tabs (1-indexed; nil entries = empty party slot)
buffbot_charNames = {}           -- {[1]="Charname", [2]="Jaheira", ...}

-- Summon tabs (1-indexed labels for the CURRENT page; nil = empty slot)
buffbot_summonTabNames = {}      -- {[1]="Imoen's Image", [2]="Deva", ...}
buffbot_summonPageText = ""      -- "1/2"-style page indicator

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

-- Per-theme PVRZ block layout. Each theme's 4 pages compose a 2048x1152
-- base parchment tile that gets repeated to fill the target panel size.
-- PVRZ page numbers match the MOS####.PVRZ filename digits in hex
-- (0x26AC = 9900, 0x26B6 = 9910, 0x26C0 = 9920).
local BLOCKS_BY_THEME = {
    BFBOTBG  = {  -- BG2 default: MOS9900-9903
        { page = 0x26AC, w = 1024, h = 1024, ox = 0,    oy = 0    },
        { page = 0x26AD, w = 1024, h = 1024, ox = 1024, oy = 0    },
        { page = 0x26AE, w = 1024, h = 128,  ox = 0,    oy = 1024 },
        { page = 0x26AF, w = 1024, h = 128,  ox = 1024, oy = 1024 },
    },
    BFBOTBG2 = {  -- SOD: MOS9910-9913
        { page = 0x26B6, w = 1024, h = 1024, ox = 0,    oy = 0    },
        { page = 0x26B7, w = 1024, h = 1024, ox = 1024, oy = 0    },
        { page = 0x26B8, w = 1024, h = 128,  ox = 0,    oy = 1024 },
        { page = 0x26B9, w = 1024, h = 128,  ox = 1024, oy = 1024 },
    },
    BFBOTBG3 = {  -- BG1: MOS9920-9923
        { page = 0x26C0, w = 1024, h = 1024, ox = 0,    oy = 0    },
        { page = 0x26C1, w = 1024, h = 1024, ox = 1024, oy = 0    },
        { page = 0x26C2, w = 1024, h = 128,  ox = 0,    oy = 1024 },
        { page = 0x26C3, w = 1024, h = 128,  ox = 1024, oy = 1024 },
    },
}

--- Generate a per-theme parchment background MOS sized to cover the current
-- panel by tiling 4 PVRZ blocks (one base tile = 2048x1152). At resolutions
-- where 80% of screen exceeds the base tile, a static MOS leaves a black gap.
-- This function writes a tiled MOS V2 to override/<themeBgResref>.MOS.
-- @param themeBgResref string  e.g. "BFBOTBG", "BFBOTBG2", "BFBOTBG3"
function BfBot.UI._GenerateBgMOS(themeBgResref)
    if BfBot._noIO then return end
    themeBgResref = themeBgResref
        or (BfBot.Theme and BfBot.Theme._active and BfBot.Theme._active.bgResref)
        or "BFBOTBG"
    local blocks = BLOCKS_BY_THEME[themeBgResref] or BLOCKS_BY_THEME.BFBOTBG

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

    -- Per-theme MOS dimension cache (skip regeneration if already covered)
    BfBot.UI._mosW = BfBot.UI._mosW or {}
    BfBot.UI._mosH = BfBot.UI._mosH or {}
    if BfBot.UI._mosW[themeBgResref] and BfBot.UI._mosH[themeBgResref]
       and BfBot.UI._mosW[themeBgResref] >= mosW
       and BfBot.UI._mosH[themeBgResref] >= mosH then
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
        local f = io.open("override/" .. themeBgResref .. ".MOS", "wb")
        if f then
            f:write(table.concat(parts))
            f:close()
        end
    end)

    if ok then
        BfBot.UI._mosW[themeBgResref] = mosW
        BfBot.UI._mosH[themeBgResref] = mosH
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
    -- Register bb_* custom text styles (deep-copies of engine styles) BEFORE
    -- the menu renders. The .menu references these via `text style "bb_*"`,
    -- so they must exist before EEex_Menu_LoadFile hands the menu to the engine.
    BfBot.Theme._RegisterStyles()

    -- Restore saved theme + font size from baldur.ini. Must run AFTER
    -- _RegisterStyles because _LoadFromINI calls _RefreshStyles, which mutates
    -- the bb_* styles registered above.
    BfBot.Theme._LoadFromINI()

    -- Register the BuffBot tab in EEex's Options menu. Must run AFTER
    -- _LoadFromINI so the option storage's read() returns the persisted
    -- (not default) values. Idempotent — subsequent calls are no-ops.
    BfBot.Theme._RegisterOptionsTab()

    -- Generate resolution-appropriate parchment background MOS for every theme.
    -- MUST happen before EEex_Menu_LoadFile so the menu picks up the right MOS
    -- for whichever theme is active (and the others when the user switches).
    for _, resref in ipairs({"BFBOTBG", "BFBOTBG2", "BFBOTBG3"}) do
        BfBot.UI._GenerateBgMOS(resref)
    end

    -- Load our .menu definitions
    EEex_Menu_LoadFile("BuffBot")

    -- Apply current font size to live menu items (per-element point mutation).
    -- The engine snapshots `style.point` at parse time, so style changes only
    -- take effect for items parsed afterward. _ApplyFontSizesToMenus walks the
    -- already-parsed items and writes the scaled point directly into each.
    BfBot.Theme._ApplyFontSizesToMenus()

    -- Register per-frame render listeners that re-apply the scaled point to
    -- each item right before it's drawn. Without this, item types that
    -- snapshot `text.point` at push time (buttons, list cells) only pick up
    -- the new size on the next push, not on a live size change.
    BfBot.Theme._RegisterFontRenderListeners()

    -- Register 9-slice border textures (one per theme variant)
    -- Wrapped in pcall — stores status for later console inspection
    BfBot.UI._borderStatus = "not attempted"
    local BORDER_RESREFS = { "BFBOTFR", "BFBOTFR2", "BFBOTFR3" }
    local anyOk = false
    local errs = {}
    for _, resref in ipairs(BORDER_RESREFS) do
        local regOk, regErr = pcall(function()
            EEex.RegisterSlicedRect("BuffBot_Border_" .. resref, {
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
                ["resref"]      = resref,
                ["flags"]       = 0,
            })
        end)
        if regOk then
            anyOk = true
        else
            table.insert(errs, resref .. ": " .. tostring(regErr))
        end
    end
    BfBot.UI._borderStatus = anyOk
        and (#errs == 0 and "registered" or ("registered (partial; " .. table.concat(errs, "; ") .. ")"))
        or ("FAILED: " .. table.concat(errs, "; "))

    -- Render hooks: draw 9-slice border on main panel + all sub-menus
    -- Active theme's borderResref is read at draw time, so theme switches take effect immediately
    if anyOk then
        local borderHook = function(item)
            pcall(function()
                EEex.DrawSlicedRect("BuffBot_Border_" .. BfBot.Theme._active.borderResref, { item:getArea() })
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
    EEex_Menu_SetItemFunction(actionbarMenu.reference_onOpen,
        BfBot._SafeCallback("ui.world_actionbar_open", function()
        local result = oldOnOpen()
        BfBot.UI._OpenActionbarBtn()
        return result
    end))

    local oldOnClose = EEex_Menu_GetItemFunction(actionbarMenu.reference_onClose)
    EEex_Menu_SetItemFunction(actionbarMenu.reference_onClose,
        BfBot._SafeCallback("ui.world_actionbar_close", function()
        BfBot.UI._CloseActionbarBtn()
        return oldOnClose()
    end))

    -- F11 hotkey
    EEex_Key_AddPressedListener(BfBot._SafeCallback(
        "ui.key_pressed", BfBot.UI._OnKeyPressed))

    -- Sprite listeners for auto-refresh (invalidate cache, then refresh panel)
    EEex_Sprite_AddQuickListsCheckedListener(BfBot._SafeCallback(
        "ui.quick_lists_checked", BfBot.UI._OnSpellListChanged))
    EEex_Sprite_AddQuickListCountsResetListener(BfBot._SafeCallback(
        "ui.quick_list_counts_reset", BfBot.UI._OnSpellCountsReset))
    EEex_Sprite_AddQuickListNotifyRemovedListener(BfBot._SafeCallback(
        "ui.quick_list_notify_removed", BfBot.UI._OnSpellRemoved))

    -- Resolution change: regenerate MOS for every theme, clamp stored geometry, re-layout
    EEex_Menu_AddWindowSizeChangedListener(BfBot._SafeCallback(
        "ui.window_size_changed", function(w, h)
        for _, resref in ipairs({"BFBOTBG", "BFBOTBG2", "BFBOTBG3"}) do
            BfBot.UI._GenerateBgMOS(resref)
        end
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
    end))

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

    -- Helper: set area on a named item AND, if it exists, its paired
    -- "<name>_t" text overlay. Buttons use a layered pattern -- a button
    -- item below (BAM, click sound, frame state) and a paired text item
    -- above (no action, scalable caption) -- so the overlay must follow
    -- the button's area on every layout. pcall is defensive: items that
    -- don't have an overlay will silently skip the overlay set.
    local function setArea(name, x, y, w, h)
        Infinity_SetArea(name, x, y, w, h)
        pcall(Infinity_SetArea, name .. "_t", x, y, w, h)
    end

    -- Panel background (parchment inside, border frame extends 24px beyond).
    -- Three labels exist (one per theme); only the active theme's is enabled,
    -- but all three need their area updated so theme switches are seamless.
    setArea("bbBg",  px, py, pw, ph)
    setArea("bbBg2", px, py, pw, ph)
    setArea("bbBg3", px, py, pw, ph)
    setArea("bbDarkOverlay", px, py, pw, ph)
    local bpad = 24  -- border overhang in pixels
    setArea("bbBgFrame", px - bpad, py - bpad, pw + 2 * bpad, ph + 2 * bpad)

    -- Title
    setArea("bbTitle", px, py + 5, pw, 30)

    -- Character tabs (6 buttons, evenly spaced) + view toggle at the right
    local charY = py + 40
    local charH = 24
    local charGap = 4
    local viewW = 88
    local rowW = cw - viewW - charGap   -- tab area shared by both views
    local charW = math.floor((rowW - 5 * charGap) / 6)
    for i = 0, 5 do
        setArea("bbC" .. i, cx + i * (charW + charGap), charY, charW, charH)
    end
    setArea("bbView", cx + cw - viewW, charY, viewW, charH)

    -- Summon tabs (summons view; same row) + paging cluster before the toggle
    local pageBtnW = 24
    local pageLblW = 40
    local pageClusterW = 2 * pageBtnW + pageLblW + 2 * charGap
    local sumW = math.floor((rowW - pageClusterW - 6 * charGap) / 6)
    for i = 0, 5 do
        setArea("bbS" .. i, cx + i * (sumW + charGap), charY, sumW, charH)
    end
    local pcX = cx + 6 * (sumW + charGap)
    setArea("bbSPrev", pcX, charY, pageBtnW, charH)
    setArea("bbSPage", pcX + pageBtnW + charGap, charY, pageLblW, charH)
    setArea("bbSNext", pcX + pageBtnW + pageLblW + 2 * charGap, charY, pageBtnW, charH)
    setArea("bbSEmpty", cx, charY, rowW, charH)

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
        setArea("bbP" .. i, cx + (i - 1) * (preW + preGap), preY, preW, preH)
    end
    local renX = cx + maxP * (preW + preGap)
    setArea("bbRen", renX, preY, renW, preH)
    setArea("bbNew", renX + renW + preGap, preY, newW, preH)

    -- Spell list (fills middle area)
    local listY = py + 98
    local footerH = 130
    local listH = math.max(ph - 98 - footerH, 50)
    setArea("bbList", cx, listY, cw, listH)

    -- Bottom rows (positioned from panel bottom)
    local btnH = 28
    local r4Y = py + ph - footerH + 4   -- Override buttons
    local r5Y = r4Y + 32                -- Spell action buttons
    local r6Y = r5Y + 32                -- Action buttons
    local r7Y = r6Y + 32                -- Status

    -- Override buttons: Add Spell + Remove (left) + Export + Import (right)
    setArea("bbAdd", cx, r4Y, 120, btnH)
    setArea("bbRmv", cx + 126, r4Y, 120, btnH)
    setArea("bbImp", cx + cw - 90, r4Y, 90, btnH)
    setArea("bbExp", cx + cw - 90 - 96, r4Y, 90, btnH)

    -- Spell action buttons: Toggle, Target, Up, Down, Sort, Delete Preset (normal layout)
    setArea("bbTog", cx, r5Y, 120, btnH)
    setArea("bbTgt", cx + 126, r5Y, 160, btnH)
    setArea("bbUp", cx + 292, r5Y, 48, btnH)
    setArea("bbDn", cx + 344, r5Y, 48, btnH)
    setArea("bbSort", cx + 398, r5Y, 48, btnH)
    setArea("bbDel", cx + cw - 130, r5Y, 130, btnH)

    -- Spell action buttons: variant layout (squeezed with Variant button)
    setArea("bbVTog", cx, r5Y, 90, btnH)
    setArea("bbVTgt", cx + 94, r5Y, 110, btnH)
    setArea("bbVVar", cx + 208, r5Y, 110, btnH)
    setArea("bbVUp", cx + 322, r5Y, 44, btnH)
    setArea("bbVDn", cx + 370, r5Y, 44, btnH)
    setArea("bbVSort", cx + 418, r5Y, 44, btnH)
    setArea("bbVDel", cx + cw - 102, r5Y, 102, btnH)

    -- Action buttons: Cast All, Cast Char, Stop — left side; Quick Cast, Close — right side
    local closeW = 80
    local qcW = 180
    local castAllW = 100
    local castCharW = 140
    local stopW = 60
    setArea("bbCast", cx, r6Y, castAllW, btnH)
    setArea("bbCastChar", cx + castAllW + 4, r6Y, castCharW, btnH)
    setArea("bbStop", cx + castAllW + castCharW + 8, r6Y, stopW, btnH)
    setArea("bbClose", cx + cw - closeW, r6Y, closeW, btnH)
    setArea("bbQC", cx + cw - closeW - qcW - 6, r6Y, qcW, btnH)

    -- Status line
    setArea("bbStatus", cx, r7Y, cw, 24)

    -- Drag handle covers title bar area
    setArea("bbDragHandle", px, py, pw, 35)

    -- Resize grip visual + handle at bottom-right corner
    setArea("bbResizeGrip", px + pw - 20, py + ph - 20, 20, 20)
    setArea("bbResizeHandle", px + pw - 80, py + ph - 48, 80, 48)

    -- Reset button in title bar (right-aligned, 50px wide)
    setArea("bbReset", px + pw - 60, py + 5, 50, 24)
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

    -- Regenerate MOS for every theme if panel + border exceeds current textures
    local bpad = 24
    local needW = pw + 2 * bpad + 64
    local needH = ph + 2 * bpad + 64
    for _, resref in ipairs({"BFBOTBG", "BFBOTBG2", "BFBOTBG3"}) do
        local cachedW = BfBot.UI._mosW and BfBot.UI._mosW[resref]
        local cachedH = BfBot.UI._mosH and BfBot.UI._mosH[resref]
        if not cachedW or needW > cachedW or not cachedH or needH > cachedH then
            BfBot.UI._GenerateBgMOS(resref)
        end
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
    -- Summons view: re-sweep the list on every open (summons come and go
    -- between opens; the selection re-establishes identity-stably)
    if BfBot.UI._view == "summons" then
        BfBot.UI._RefreshSummonList()
    end
    -- Selection gone (empty slot / vanished summon) → default to party view,
    -- first party member
    if not BfBot.UI._GetSelectedSprite() then
        BfBot.UI._view = "party"
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

    -- 1. Update party member names for character tabs (also used by the
    -- target picker in BOTH views — summon buffs target party members)
    buffbot_charNames = {}
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            buffbot_charNames[slot + 1] = BfBot._GetName(sprite)
        end
    end

    -- 1b. Summons view has its own data path (summon presets live on the
    -- protagonist's config, NEVER on the summon sprite)
    if BfBot.UI._view == "summons" then
        BfBot.UI._RefreshSummonsView()
        return
    end

    -- 2. Get current character's sprite + config
    local sprite = BfBot.UI._GetSelectedSprite()
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
    buffbot_spellTable = BfBot.UI._BuildSpellRows(sprite, preset, castable, config.ovr)

    -- 8. Update title, cast labels, status
    buffbot_title = "BuffBot - " .. (preset.name or "Preset")
    buffbot_castLabel = "Cast All"
    buffbot_castCharLabel = BfBot.UI._CastCharLabel()
    buffbot_status = BfBot.UI._GetStatusText()
end

--- Build the spell-list rows for one caster's preset, cross-referenced with
--- scan data. Shared by the party view (ovr = config.ovr) and the summons
--- view (ovr = nil — no per-summon classification overrides; absent
--- lock/tgtUnlock fields read as 0, which the v8 summon schema guarantees).
-- @param sprite    caster sprite (party member or freshly-resolved summon)
-- @param preset    preset table { spells = { [resref] = entry } }
-- @param castable  BfBot.Scan.GetCastableSpells(sprite) result
-- @param ovr       classification-override table or nil
-- @return rows array sorted by priority
function BfBot.UI._BuildSpellRows(sprite, preset, castable, ovr)
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
            ovr      = (ovr and ovr[resref]) or 0,
            isAoE    = scan and scan.isAoE or 0,
            isSelfOnly = scan and scan.isSelfOnly or 0,
            tgtUnlock = spellCfg.tgtUnlock or 0,
            lock      = spellCfg.lock or 0,
            hasVariants = hasVariants,
            variants = variants,
            var      = varResref,
            variantName = variantName,
        })
    end

    -- Sort by priority (ascending: lower = cast first)
    table.sort(rows, function(a, b) return a.pri < b.pri end)
    return rows
end

--- Summons-view refresh: summon tab labels, preset tabs (names come from the
--- protagonist's config — the preset axis is shared across views), and the
--- selected summon's preset spell table. All config reads/writes go to the
--- summon preset on the protagonist (schema v8: {qc, spells={[res]={on,tgt,
--- pri,var}}}); the summon SPRITE never gets a config of its own.
function BfBot.UI._RefreshSummonsView()
    BfBot.UI._UpdateSummonTabNames()

    -- Preset tabs from the protagonist's config (shared preset axis)
    local prot = BfBot.Persist._GetProtagonist()
    local config = prot and BfBot.Persist.GetConfig(prot) or nil
    buffbot_presetNames = {}
    buffbot_presetCount = 0
    if config and config.presets then
        for idx, preset in pairs(config.presets) do
            buffbot_presetNames[idx] = preset.name or ("Preset " .. idx)
            buffbot_presetCount = buffbot_presetCount + 1
        end
    end
    BfBot.UI._ClampPresetIdx(config)

    buffbot_castLabel = "Cast All"
    buffbot_castCharLabel = BfBot.UI._CastCharLabel()
    buffbot_status = BfBot.UI._GetStatusText()

    -- Selected summon: fresh oid+name resolve. A vanished selection prunes
    -- the list once (fresh sweep drops dead entries) and falls forward to
    -- the first live entry; empty state otherwise (line-666 pattern).
    local entry = BfBot.UI._SelectedSummon()
    local sprite = BfBot.UI._GetSelectedSprite()
    if entry and not sprite then
        BfBot.UI._RefreshSummonList()
        BfBot.UI._UpdateSummonTabNames()
        entry = BfBot.UI._SelectedSummon()
        sprite = BfBot.UI._GetSelectedSprite()
    end
    if not entry or not sprite then
        buffbot_spellTable = {}
        buffbot_title = "BuffBot - Summons"
        BfBot.UI._UpdateSummonQc()  -- per-frame bbQC cache (review MINOR-4)
        return
    end

    buffbot_title = "BuffBot - " .. BfBot.UI._SummonTabLabel(entry)
        .. " - " .. (buffbot_presetNames[BfBot.UI._presetIdx]
                     or ("Preset " .. BfBot.UI._presetIdx))

    -- First open of this identity+preset creates it (clones seed from the
    -- owner's same-index preset ∩ the clone's castable set)
    BfBot.UI._EnsureSummonPreset(entry)
    local preset = BfBot.Persist.GetSummonPreset(entry.identity, BfBot.UI._presetIdx)
    -- Refresh the per-frame bbQC cache AFTER _EnsureSummonPreset — a
    -- just-created preset must show its (possibly seeded) qc immediately
    -- (review MINOR-4).
    BfBot.UI._UpdateSummonQc()
    if not preset or type(preset.spells) ~= "table" then
        buffbot_spellTable = {}
        return
    end

    -- Castable spells (scan cache — invalidated on panel open, as party view)
    local castable = BfBot.Scan.GetCastableSpells(sprite)

    -- Merge new castable buffs into the preset (disabled, at bottom) — same
    -- behavior as the party view minus the ovr filter (no per-summon
    -- classification overrides). New entries follow the v8 spell-entry
    -- schema: on/tgt/pri only (lock/tgtUnlock do not exist for summons).
    local maxPri = 0
    for _, spellCfg in pairs(preset.spells) do
        if (spellCfg.pri or 0) > maxPri then maxPri = spellCfg.pri end
    end
    for resref, scan in pairs(castable) do
        if not preset.spells[resref] and scan.class and scan.class.isBuff
           and scan.count > 0 then
            maxPri = maxPri + 1
            preset.spells[resref] = {
                on = 0,
                tgt = (scan.class.defaultTarget == "s") and "s" or "p",
                pri = maxPri,
            }
        end
    end

    buffbot_spellTable = BfBot.UI._BuildSpellRows(sprite, preset, castable, nil)
end

--- Recompute the summon tab labels + page indicator for the current page.
--- Also caches the visible slice so clicks act on exactly what is displayed.
function BfBot.UI._UpdateSummonTabNames()
    local slice, p, pageCount = BfBot.UI._SummonPageSlice(
        BfBot.UI._summonList, BfBot.UI._summonPage)
    BfBot.UI._summonPage = p
    BfBot.UI._summonSlice = slice
    buffbot_summonTabNames = {}
    for i, e in ipairs(slice) do
        buffbot_summonTabNames[i] = BfBot.UI._SummonTabLabel(e)
    end
    buffbot_summonPageText = p .. "/" .. pageCount
end

--- Ensure the selected summon's preset exists for the current preset index.
--- Creation happens ONCE per identity+preset; a CLONE's create seeds from
--- its owner's same-index preset filtered to the clone's castable set. The
--- owner is a FRESH resolve of the live clone's m_nCopyParent — never a
--- cached sprite (issue-#38 discipline).
function BfBot.UI._EnsureSummonPreset(entry)
    if type(entry) ~= "table" then return end
    if BfBot.Persist.PeekSummonPreset(entry.identity, BfBot.UI._presetIdx) then
        return  -- already exists — never re-seed
    end
    local seedCtx = nil
    if entry.kind == "clone" then
        local clone = BfBot.Exec._ResolveCaster({
            kind = "summon", oid = entry.oid, name = entry.name })
        if clone then
            local owner = nil
            local okCp, cp = pcall(function() return clone.m_nCopyParent end)
            if okCp and type(cp) == "number" and cp ~= -1 then
                local okOw, ow = pcall(function()
                    local obj = EEex_GameObject_Get(cp)
                    if obj and EEex_GameObject_IsSprite(obj, false) then
                        return EEex_GameObject_CastUserType(obj)
                    end
                    return nil
                end)
                if okOw then
                    owner = ow
                else
                    BfBot._Warn("[UI] _EnsureSummonPreset: owner resolve failed: "
                        .. tostring(ow))
                end
            end
            if owner then
                seedCtx = { ownerSprite = owner, cloneSprite = clone }
            end
        end
    end
    BfBot.Persist.GetSummonPreset(entry.identity, BfBot.UI._presetIdx, seedCtx)
end

--- Summons-view write path: the stored spell entry for `resref` in the
--- selected summon's current preset (the table IS the persisted config —
--- mutations stick). Read-only lookup unless `create` is set; created
--- entries follow the v8 schema (on/tgt/pri).
function BfBot.UI._SummonSpellEntry(resref, create)
    local sel = BfBot.UI._SelectedSummon()
    if not sel then return nil end
    local preset = BfBot.Persist.PeekSummonPreset(sel.identity, BfBot.UI._presetIdx)
    if not preset or type(preset.spells) ~= "table" then return nil end
    local e = preset.spells[resref]
    if not e and create then
        e = { on = 0, tgt = "p", pri = 999 }
        preset.spells[resref] = e
    end
    return e
end

-- ============================================================
-- Tab Switching (no cache invalidation)
-- ============================================================

function BfBot.UI.SetChar(slot)
    BfBot.UI._view = "party"  -- portrait tabs always land in party view
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

    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return end
    -- Integer toggle: 1 -> 0, 0 -> 1. NEVER pass boolean to Persist.
    local newState = (entry.on == 1) and 0 or 1
    if BfBot.UI._view == "summons" then
        local se = BfBot.UI._SummonSpellEntry(entry.resref, 1)
        if not se then return end
        se.on = newState
    else
        BfBot.Persist.SetSpellEnabled(sprite, BfBot.UI._presetIdx, entry.resref, newState)
    end
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
        return BfBot.UI._T("pickerSel")
    end
    local name = buffbot_pickerOrder[row]
    if name and buffbot_pickerChecked[name] then
        return BfBot.UI._T("pickerOn")
    end
    return BfBot.UI._T("pickerOff")
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
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return end

    BfBot.UI._SetSpellTargetForView(sprite, entry.resref, "s")
    entry.tgt = "s"
    entry.targetText = BfBot.UI._TargetToText("s")
    Infinity_PopMenu("BUFFBOT_TARGETS")
end

--- View-routed target write: party → Persist setter, summons → the stored
--- summon spell entry (v8 schema keeps tgt as "s"/"p"/name/ordered table).
function BfBot.UI._SetSpellTargetForView(sprite, resref, tgt)
    if BfBot.UI._view == "summons" then
        local se = BfBot.UI._SummonSpellEntry(resref, 1)
        if se then se.tgt = tgt end
        return
    end
    BfBot.Persist.SetSpellTarget(sprite, BfBot.UI._presetIdx, resref, tgt)
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
    local sprite = BfBot.UI._GetSelectedSprite()
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

    BfBot.UI._SetSpellTargetForView(sprite, entry.resref, tgt)
    entry.tgt = tgt
    entry.targetText = BfBot.UI._TargetToText(tgt)
    Infinity_PopMenu("BUFFBOT_TARGETS")
end

--- Unlock targeting for a locked spell. Party view only: the v8 summon
--- spell-entry schema has no tgtUnlock field (the picker's Unlock button is
--- hidden in the summons view).
function BfBot.UI.PickerUnlock()
    if BfBot.UI._view == "summons" then return end
    local row = buffbot_targetRow
    local entry = buffbot_spellTable[row]
    if not entry then return end
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return end

    BfBot.Persist.SetTgtUnlock(sprite, BfBot.UI._presetIdx, entry.resref, 1)
    entry.tgtUnlock = 1
    buffbot_targetLocked = 0
    buffbot_targetLockText = ""
end

-- ============================================================
-- Preset Management (Rename, Create, Delete)
-- ============================================================

-- Preset management, overrides, and export/import are party-view-only
-- operations (they act on per-CHARACTER configs). Their buttons are gated on
-- _IsPartyView() in the .menu; the guards below are defense in depth so a
-- stray call can never touch a summon sprite's (non-existent) config.

function BfBot.UI.OpenRename()
    if BfBot.UI._view == "summons" then return end
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
    if BfBot.UI._view == "summons" then return end
    local idx = BfBot.Persist.CreatePresetAll()
    if idx then
        BfBot.UI._presetIdx = idx
        BfBot.Innate.RefreshAll()
        BfBot.UI._Refresh()
    end
end

--- Delete the current preset for all party members and switch to nearest.
function BfBot.UI.DeleteCurrentPreset()
    if BfBot.UI._view == "summons" then return end
    local result = BfBot.Persist.DeletePresetAll(BfBot.UI._presetIdx)
    if result then
        -- Clamp to first valid preset for the current character
        local sprite = BfBot.UI._GetSelectedSprite()
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

--- Re-append build-time SKIP lines into the run's fresh IN-MEMORY log
--- ONLY. The builders log SKIPs (file + memory) BEFORE Exec.Start, and
--- Start resets the memory log — without this, the panel-visible log never
--- shows why entries are missing (hand-off 4). The file line was already
--- written at build time, so this inserts directly into BfBot.Exec._log
--- (mirroring _LogEntry's { type, msg } entry shape) instead of calling
--- _LogEntry, which would write the file a second time (review MINOR-1).
--- Only _StartRun may call this, and only after a successful Start.
function BfBot.UI._SurfaceBuildSkips()
    if not BfBot.Persist.DrainBuildSkips then return end
    for _, msg in ipairs(BfBot.Persist.DrainBuildSkips()) do
        table.insert(BfBot.Exec._log, { type = "SKIP", msg = msg })
    end
end

--- Start an exec run and surface the build-time skips into its panel log.
--- Surfacing happens ONLY on a successful Start: a refused Start (already
--- running, or a build error inside Start) does NOT reset the in-memory
--- log, so replaying the skips would append them to the PREVIOUS run's
--- panel log (review MINOR-2). On refusal the pending skips are discarded
--- instead — they were file-logged at build time, nothing is lost there.
--- presetIdx tags the run for the late-join listener (issue #19): every
--- preset-driven entry point passes BfBot.UI._presetIdx so a summon
--- spawning mid-run can look up its own summon preset.
function BfBot.UI._StartRun(queue, qcMode, presetIdx)
    local started = BfBot.Exec.Start(queue, qcMode, presetIdx)
    if started then
        BfBot.UI._SurfaceBuildSkips()
    else
        BfBot.Persist.DrainBuildSkips()
    end
    return started
end

function BfBot.UI.Cast()
    -- Cast All stays PARTY-preset-driven in BOTH views: BuildQueueFromPreset
    -- already sweeps configured allied summons into the run (Task 7), so the
    -- summons view needs no all-variant of its own (deliberate Task-10
    -- decision). Validate the preset index against a PARTY config — in the
    -- summons view that's the protagonist (never GetConfig a summon sprite).
    local sprite
    if BfBot.UI._view == "summons" then
        sprite = BfBot.Persist._GetProtagonist()
    else
        sprite = BfBot.UI._GetSelectedSprite()
    end
    if sprite then
        local config = BfBot.Persist.GetConfig(sprite)
        BfBot.UI._ClampPresetIdx(config)
    end

    BfBot.Persist.DrainBuildSkips()  -- discard skips from earlier builds
    local queue = BfBot.Persist.BuildQueueFromPreset(BfBot.UI._presetIdx)
    if not queue or #queue == 0 then
        BfBot._Display("BuffBot: No spells to cast in this preset")
        return
    end
    local qcMode = sprite and BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx) or 0
    BfBot.UI._StartRun(queue, qcMode, BfBot.UI._presetIdx)
    buffbot_status = BfBot.UI._GetStatusText()
end

function BfBot.UI.CastCharacter()
    -- Summons view: this button is "Cast (this summon)" (hand-off 2)
    if BfBot.UI._view == "summons" then
        BfBot.UI._CastSelectedSummon()
        return
    end

    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return end
    local config = BfBot.Persist.GetConfig(sprite)
    BfBot.UI._ClampPresetIdx(config)

    BfBot.Persist.DrainBuildSkips()  -- discard skips from earlier builds
    local queue, reason = BfBot.Persist.BuildQueueForCharacter(BfBot.UI._charSlot, BfBot.UI._presetIdx)
    if not queue or #queue == 0 then
        if reason == "not locally controlled" then
            Infinity_DisplayString("BuffBot: " .. BfBot._GetName(sprite)
                .. " is controlled by another player")
        elseif reason == "puppet-locked" then
            Infinity_DisplayString("BuffBot: " .. BfBot._GetName(sprite)
                .. " is puppet-locked by Project Image — cast again after the"
                .. " image expires")
        else
            Infinity_DisplayString("BuffBot: No spells to cast for this character")
        end
        return
    end
    local qcMode = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    BfBot.UI._StartRun(queue, qcMode, BfBot.UI._presetIdx)
    buffbot_status = BfBot.UI._GetStatusText()
end

--- Standalone cast for the selected summon (issue #19). Queue entries carry
--- their own per-entry cheat flag from the summon preset's qc, so the run
--- qcMode is always 0 here.
function BfBot.UI._CastSelectedSummon()
    local entry = BfBot.UI._SelectedSummon()
    if not entry then
        Infinity_DisplayString("BuffBot: No summon selected")
        return
    end
    BfBot.Persist.DrainBuildSkips()  -- discard skips from earlier builds
    local queue, reason = BfBot.Persist.BuildQueueForSummon(entry, BfBot.UI._presetIdx)
    if not queue or #queue == 0 then
        Infinity_DisplayString("BuffBot: No spells to cast for this summon"
            .. (reason and (" (" .. reason .. ")") or ""))
        return
    end
    BfBot.UI._StartRun(queue, 0, BfBot.UI._presetIdx)
    buffbot_status = BfBot.UI._GetStatusText()
end

function BfBot.UI._CastCharLabel()
    if BfBot.UI._view == "summons" then
        return "Cast (this summon)"
    end
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
--- In the summons view no portrait tab is selected (hand-off 2).
function BfBot.UI._IsCharSelected(slot)
    if BfBot.UI._view == "summons" then return false end
    return BfBot.UI._charSlot == slot
end

--- Preset tab selected state.
function BfBot.UI._IsPresetSelected(idx)
    return BfBot.UI._presetIdx == idx
end

--- Can we start casting for the current character? (exec idle + current char has preset spells)
function BfBot.UI._CanCast()
    return BfBot.Exec.GetState() ~= "running" and #buffbot_spellTable > 0
end

--- Can we start "Cast All"? (exec idle + any party member has preset spells)
--- Mirrors BuildQueueFromPreset's cross-party scope so the gate doesn't grey
--- out when only the currently-selected char has nothing configured.
function BfBot.UI._CanCastAll()
    if BfBot.Exec.GetState() == "running" then return false end
    if #buffbot_spellTable > 0 then return true end
    local presetIdx = BfBot.UI._presetIdx
    -- The visible spell table already covered the selected PARTY member; in
    -- the summons view it covered a summon instead, so check all six slots.
    local skipSlot = BfBot.UI._IsPartyView() and BfBot.UI._charSlot or -1
    for slot = 0, 5 do
        if slot ~= skipSlot then
            local sprite = EEex_Sprite_GetInPortrait(slot)
            if sprite then
                local config = BfBot.Persist.GetConfig(sprite)
                if config and config.presets then
                    local preset = config.presets[presetIdx]
                    if preset and preset.spells and next(preset.spells) then
                        return true
                    end
                end
            end
        end
    end
    return false
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
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return end
    for i, entry in ipairs(buffbot_spellTable) do
        entry.pri = i
        if BfBot.UI._view == "summons" then
            local se = BfBot.UI._SummonSpellEntry(entry.resref, 1)
            if se then se.pri = i end
        else
            BfBot.Persist.SetSpellPriority(sprite, BfBot.UI._presetIdx, entry.resref, i)
        end
    end
end

--- Return the next row in `direction` (+1 down, -1 up) whose entry is
--- not locked, or nil if none exists within bounds.
function BfBot.UI._FindNextUnlocked(startRow, direction)
    local n = #buffbot_spellTable
    local row = startRow + direction
    while row >= 1 and row <= n do
        local e = buffbot_spellTable[row]
        if e and e.lock ~= 1 then return row end
        row = row + direction
    end
    return nil
end

--- Can the selected spell move up? Selected must be unlocked and have an
--- unlocked row above it.
function BfBot.UI._CanMoveUp()
    if not buffbot_isOpen then return false end
    local row = buffbot_selectedRow
    if row <= 1 or row > #buffbot_spellTable then return false end
    local entry = buffbot_spellTable[row]
    if not entry or entry.lock == 1 then return false end
    return BfBot.UI._FindNextUnlocked(row, -1) ~= nil
end

--- Can the selected spell move down? Selected must be unlocked and have an
--- unlocked row below it.
function BfBot.UI._CanMoveDown()
    if not buffbot_isOpen then return false end
    local row = buffbot_selectedRow
    if row < 1 or row >= #buffbot_spellTable then return false end
    local entry = buffbot_spellTable[row]
    if not entry or entry.lock == 1 then return false end
    return BfBot.UI._FindNextUnlocked(row, 1) ~= nil
end

--- Move the selected spell up to the next unlocked row.
function BfBot.UI.MoveSpellUp()
    local row = buffbot_selectedRow
    if row <= 1 or row > #buffbot_spellTable then return end
    local entry = buffbot_spellTable[row]
    if not entry or entry.lock == 1 then return end
    local target = BfBot.UI._FindNextUnlocked(row, -1)
    if not target then return end
    buffbot_spellTable[row], buffbot_spellTable[target] =
        buffbot_spellTable[target], buffbot_spellTable[row]
    BfBot.UI._RenumberPriorities()
    buffbot_selectedRow = target
end

--- Move the selected spell down to the next unlocked row.
function BfBot.UI.MoveSpellDown()
    local row = buffbot_selectedRow
    if row < 1 or row >= #buffbot_spellTable then return end
    local entry = buffbot_spellTable[row]
    if not entry or entry.lock == 1 then return end
    local target = BfBot.UI._FindNextUnlocked(row, 1)
    if not target then return end
    buffbot_spellTable[row], buffbot_spellTable[target] =
        buffbot_spellTable[target], buffbot_spellTable[row]
    BfBot.UI._RenumberPriorities()
    buffbot_selectedRow = target
end

--- Sort the current preset's spell list by duration (longest first).
--- Locked spells stay at their current row index. Unlocked spells fill
--- the remaining rows in duration-desc order. Persists via _RenumberPriorities.
function BfBot.UI.SortByDuration()
    local n = #buffbot_spellTable
    if n == 0 then return end

    local function durKey(entry)
        local d = entry.dur
        if d == nil then return -2 end
        if d == -1 then return 1e9 end  -- permanent sorts first
        return d
    end

    -- Partition: keep locked entries pinned to their row indices
    local locked = {}   -- [row] = entry
    local unlocked = {} -- ordered list
    for i, entry in ipairs(buffbot_spellTable) do
        if entry.lock == 1 then
            locked[i] = entry
        else
            table.insert(unlocked, entry)
        end
    end

    -- Sort unlocked by duration desc
    table.sort(unlocked, function(a, b) return durKey(a) > durKey(b) end)

    -- Rebuild: locked at their row, unlocked fill the gaps
    local result = {}
    local uIdx = 1
    for i = 1, n do
        if locked[i] then
            result[i] = locked[i]
        else
            result[i] = unlocked[uIdx]
            uIdx = uIdx + 1
        end
    end
    buffbot_spellTable = result
    BfBot.UI._RenumberPriorities()
end

-- ============================================================
-- Spell Override (Add / Remove)
-- ============================================================

--- Build the picker list: castable spells the user can add to the preset.
--- Includes non-buff spells (manual inclusion) and previously-excluded buffs
--- (recovery from accidental Remove). Excluded spells sort to the top.
function BfBot.UI._BuildPickerList()
    buffbot_pickerSpells = {}
    buffbot_pickerSelected = 0
    local sprite = BfBot.UI._GetSelectedSprite()
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
        local ovr = config.ovr and config.ovr[resref]
        -- Skip spells classified as buffs, unless they were excluded by the user
        -- (excluded buffs must remain addable so accidental Remove can be undone).
        if scan.class.isBuff and ovr ~= -1 then goto nextSpell end

        table.insert(buffbot_pickerSpells, {
            resref   = resref,
            name     = scan.name or resref,
            icon     = scan.icon or "",
            durCat   = scan.durCat or "?",
            count    = scan.count or 0,
            excluded = (ovr == -1) and 1 or 0,
        })
        ::nextSpell::
    end
    -- Sort excluded spells first (recently-removed → prominent for undo),
    -- then alphabetical within each group.
    table.sort(buffbot_pickerSpells, function(a, b)
        if a.excluded ~= b.excluded then return a.excluded > b.excluded end
        return a.name < b.name
    end)
end

--- Open the spell picker sub-menu.
function BfBot.UI.OpenSpellPicker()
    if BfBot.UI._view == "summons" then return end
    BfBot.UI._BuildPickerList()
    if #buffbot_pickerSpells == 0 then
        BfBot._Display("BuffBot: No additional spells to add")
        return
    end
    Infinity_PushMenu("BUFFBOT_SPELLPICKER")
end

--- Add the selected spell from the picker (include override).
function BfBot.UI.AddPickedSpell()
    if BfBot.UI._view == "summons" then return end
    local entry = buffbot_pickerSpells[buffbot_pickerSelected]
    if not entry then return end
    local sprite = BfBot.UI._GetSelectedSprite()
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
    if BfBot.UI._view == "summons" then return end
    if not BfBot.UI._HasSelection() then return end
    local entry = buffbot_spellTable[buffbot_selectedRow]
    if not entry then return end
    local sprite = BfBot.UI._GetSelectedSprite()
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
    if BfBot.UI._view == "summons" then return end
    local sprite = BfBot.UI._GetSelectedSprite()
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
    if BfBot.UI._view == "summons" then return end
    BfBot.UI._BuildImportList()
    if #buffbot_importList == 0 then
        BfBot._Display("BuffBot: No configs found in bfbot_presets/")
        return
    end
    Infinity_PushMenu("BUFFBOT_IMPORT")
end

--- Import the selected config from the picker.
function BfBot.UI.ImportSelected()
    if BfBot.UI._view == "summons" then return end
    local entry = buffbot_importList[buffbot_importSelected]
    if not entry then return end
    local sprite = BfBot.UI._GetSelectedSprite()
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

    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then
        Infinity_PopMenu("BUFFBOT_VARIANTS")
        return
    end

    -- Store the variant (summons view → the stored summon spell entry)
    if BfBot.UI._view == "summons" then
        local se = BfBot.UI._SummonSpellEntry(entry.resref, 1)
        if se then se.var = vEntry.resref end
    else
        BfBot.Persist.SetSpellVariant(sprite, BfBot.UI._presetIdx, entry.resref, vEntry.resref)
    end
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

--- Spell name color: grey for unavailable, dark blue for manual include,
--- gold-tinted for locked, dark brown for normal.
function BfBot.UI._SpellNameColor(row)
    local entry = buffbot_spellTable[row]
    if not entry then return _parseColor(BfBot.UI._T("text")) end
    if entry.castable == 0 then return _parseColor(BfBot.UI._T("textMuted")) end
    if entry.ovr == 1 then return _parseColor(BfBot.UI._T("textAccent")) end
    if entry.lock == 1 then return _parseColor(BfBot.UI._T("spellLocked")) end
    return _parseColor(BfBot.UI._T("text"))
end

--- Checkbox display: "+" for enabled, empty for disabled.
function BfBot.UI._CheckboxText(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.on == 1 then return "[X]" end
    return "[ ]"
end

--- Lock column display text. The summons view has no lock feature (the v8
--- summon spell-entry schema has no lock field) — the column stays blank.
function BfBot.UI._LockText(row)
    if BfBot.UI._view == "summons" then return "" end
    local entry = buffbot_spellTable[row]
    if entry and entry.lock == 1 then return "[L]" end
    return "[ ]"
end

--- Lock column color: gold when locked, muted otherwise.
function BfBot.UI._LockColor(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.lock == 1 then return _parseColor(BfBot.UI._T("lockActive")) end
    return _parseColor(BfBot.UI._T("lockInactive"))
end

--- Toggle the lock state on a spell row. Party view only (see _LockText).
function BfBot.UI.ToggleLock(row)
    if BfBot.UI._view == "summons" then return end
    local entry = buffbot_spellTable[row]
    if not entry then return end
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return end
    local newState = (entry.lock == 1) and 0 or 1
    entry.lock = newState  -- immediate visual update
    BfBot.Persist.SetSpellLock(sprite, BfBot.UI._presetIdx, entry.resref, newState)
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

--- Quick Cast value (0..2) for the current view: party → the selected
--- character's per-preset qc; summons → the CACHED qc of the selected
--- summon's preset (its OWN v8 qc field — the summon follows it even
--- inside a party run). The cache exists because this feeds bbQC's
--- per-frame `text lua` / `text color lua`: resolving the summon preset
--- live would walk _SelectedSummon → PeekSummonPreset →
--- _GetProtagonistConfig (up to ~6 GetInPortrait calls + a pcall) several
--- times EVERY frame (review MINOR-4). Party view is a single portrait
--- lookup and stays live.
function BfBot.UI._ViewQuickCast()
    if BfBot.UI._view == "summons" then
        return BfBot.UI._summonQc
    end
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return nil end
    return BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
end

--- Recompute the cached summons-view Quick Cast value (_summonQc). Writer
--- trace — every path that can change the displayed value refreshes the
--- cache, so it can never go stale:
---   * _RefreshSummonsView calls this on EVERY exit; all summons-view
---     state changes funnel through it via _Refresh (panel open, view
---     switch, summon tab select, preset switch, page flip, sprite
---     listeners) — including preset creation by _EnsureSummonPreset.
---   * CycleQuickCast's summons branch writes the cache inline with its
---     qc mutation (the one write that happens without a _Refresh).
--- nil = no selected summon or no preset yet (renders as Off / normal
--- speed, exactly like the pre-cache nil).
function BfBot.UI._UpdateSummonQc()
    local sel = BfBot.UI._SelectedSummon()
    local preset = sel and BfBot.Persist.PeekSummonPreset(
        sel.identity, BfBot.UI._presetIdx)
    if preset then
        BfBot.UI._summonQc = tonumber(preset.qc) or 0
    else
        BfBot.UI._summonQc = nil
    end
end

function BfBot.UI.CycleQuickCast()
    if BfBot.UI._view == "summons" then
        local sel = BfBot.UI._SelectedSummon()
        local preset = sel and BfBot.Persist.PeekSummonPreset(
            sel.identity, BfBot.UI._presetIdx)
        if not preset then return end
        preset.qc = ((tonumber(preset.qc) or 0) + 1) % 3
        BfBot.UI._summonQc = preset.qc  -- keep the per-frame cache fresh
        return
    end
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return end
    local current = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    local next = (current + 1) % 3
    BfBot.Persist.SetQuickCastAll(BfBot.UI._presetIdx, next)
end

function BfBot.UI._QuickCastLabel()
    if not buffbot_isOpen then return "" end
    local qc = BfBot.UI._ViewQuickCast()
    if qc == 1 then return "Quick Cast: Long" end
    if qc == 2 then return "Quick Cast: All" end
    return "Quick Cast: Off"
end

function BfBot.UI._QuickCastColor()
    local qc = BfBot.UI._ViewQuickCast()
    if qc == 1 then return _parseColor(BfBot.UI._T("qcLong")) end
    if qc == 2 then return _parseColor(BfBot.UI._T("qcAll")) end
    return _parseColor(BfBot.UI._T("qcOff"))
end

function BfBot.UI._QuickCastTooltip()
    local qc = BfBot.UI._ViewQuickCast()
    if qc == nil then return "Normal casting speed" end
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
