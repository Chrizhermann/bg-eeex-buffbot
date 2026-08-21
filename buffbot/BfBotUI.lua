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
BfBot.UI._spellSel = nil       -- canonical spell selection {context, resref}; NEVER a row index
BfBot.UI._pendingSpellSelectionSync = nil
BfBot.UI._targetSpellAnchor = nil
BfBot.UI._variantSpellAnchor = nil

-- Summons view state (issue #19, Task 10)
BfBot.UI._SUMMONS_PER_PAGE = 6   -- tab slots per page (mirrors the 6 portrait tabs)
BfBot.UI._summonList = {}        -- UI-owned copies of GetAlliedSummons entries (no sprites)
BfBot.UI._summonSlice = {}       -- current page's entries (kept in sync with tab labels)
BfBot.UI._summonPage = 1         -- 1-based page into _summonList
BfBot.UI._summonSel = nil        -- selection descriptor {identity, oid, name, cloneType} — NEVER a row index
BfBot.UI._summonQc = nil         -- cached summons-view Quick Cast value (see _UpdateSummonQc)

-- Confirm dialog state (BUFFBOT_CONFIRM). _confirmMsg is read every frame
-- by the dialog's message label; _confirmFn holds the pending action and
-- runs only via RunConfirm. Runtime-only — never reaches the marshal layer.
BfBot.UI._confirmMsg = ""
BfBot.UI._confirmFn = nil

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
            if entry.cloneType == 1 then
                return BfBot.L10N.Format("ui.clone.mislead", { owner = owner })
            elseif entry.cloneType == 2 then
                return BfBot.L10N.Format("ui.clone.project_image", { owner = owner })
            elseif entry.cloneType == 3 then
                return BfBot.L10N.Format("ui.clone.simulacrum", { owner = owner })
            end
            return BfBot.L10N.Format("ui.clone.generic", { owner = owner })
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
    local previousContext = nil
    if BfBot.UI._view == "summons" then
        previousContext = BfBot.UI._SpellSelectionContext()
    end
    BfBot.Scan.InvalidateSummons()
    local ok, raw = pcall(BfBot.Scan.GetAlliedSummons)
    if not ok then
        BfBot._Warn("[UI] summon sweep failed: " .. tostring(raw))
        raw = nil
    end
    BfBot.UI._summonList = BfBot.UI._BuildSummonListModel(raw)
    BfBot.UI._summonPage = 1
    BfBot.UI._ReselectSummon()
    if previousContext and not BfBot.UI._SameSpellSelectionContext(
        previousContext, BfBot.UI._SpellSelectionContext()) then
        BfBot.UI._ClearSpellSelection()
    end
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
    if BfBot.UI._IsPartyView() then
        return BfBot.L10N.Get("common.summons")
    end
    return BfBot.L10N.Get("common.party")
end

--- Toggle between party and summons view. Preset index is a shared axis and
--- survives the switch; the summon list is re-swept on every switch.
function BfBot.UI.ToggleView()
    BfBot.UI._ClearSpellSelection()
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
    BfBot.UI._ClearSpellSelection()
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
buffbot_title = BfBot.L10N.Get("common.buffbot")
buffbot_status = ""
buffbot_btnTooltip = BfBot.L10N.Get("ui.tooltip.configuration")
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
buffbot_castLabel = BfBot.L10N.Get("ui.cast.all")
buffbot_castCharLabel = BfBot.L10N.Get("ui.cast.character")

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
buffbot_variantTitle = ""          -- complete localized variant-picker title
buffbot_variantSelected = 0        -- selected row in variant picker

-- ============================================================
-- Stable Spell Selection
-- ============================================================

--- Snapshot the current spell-list context without retaining sprite userdata.
--- Party selections use portrait slot + exact live oid + normalized name.
--- Summon selections likewise include exact oid+name as well as persistent
--- identity metadata, so a replacement caster never inherits old UI state.
function BfBot.UI._SpellSelectionContext()
    local context = {
        view = BfBot.UI._view,
        preset = BfBot.UI._presetIdx,
    }
    if BfBot.UI._view == "summons" then
        local sel = BfBot.UI._summonSel
        context.identity = sel and sel.identity or nil
        context.cloneType = sel and sel.cloneType or nil
        context.oid = sel and sel.oid or nil
        context.name = sel and sel.name or nil
        return context
    end

    context.slot = BfBot.UI._charSlot
    local sprite = BfBot.UI._GetSelectedSprite()
    context.oid = sprite and sprite.m_id or nil
    context.name = sprite and BfBot._GetName(sprite) or nil
    return context
end

--- PURE: compare two spell-list contexts.
function BfBot.UI._SameSpellSelectionContext(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if a.view ~= b.view or a.preset ~= b.preset then return false end
    if a.view == "summons" then
        return a.identity == b.identity and a.cloneType == b.cloneType
            and a.oid == b.oid and a.name == b.name
    end
    return a.slot == b.slot and a.oid == b.oid and a.name == b.name
end

--- Return the current row for a resref, or nil. Resrefs are case-insensitive.
function BfBot.UI._FindSpellRow(resref)
    if type(resref) ~= "string" or resref == "" then return nil end
    local wanted = resref:upper()
    for row, entry in ipairs(buffbot_spellTable) do
        if entry and type(entry.resref) == "string"
            and entry.resref:upper() == wanted then
            return row
        end
    end
    return nil
end

--- Capture a spell identity for a sub-menu action.
function BfBot.UI._MakeSpellAnchor(resref)
    if type(resref) ~= "string" or resref == "" then return nil end
    return {
        context = BfBot.UI._SpellSelectionContext(),
        resref = resref,
    }
end

--- Resolve a sub-menu anchor against the current context and row table.
--- Returns entry, row; context changes and disappearance return nil.
function BfBot.UI._ResolveSpellAnchor(anchor)
    if type(anchor) ~= "table"
        or not BfBot.UI._SameSpellSelectionContext(
            anchor.context, BfBot.UI._SpellSelectionContext()) then
        return nil
    end
    local row = BfBot.UI._FindSpellRow(anchor.resref)
    if not row then return nil end
    return buffbot_spellTable[row], row
end

--- Clear canonical and projected spell selection state.
function BfBot.UI._ClearSpellSelection()
    BfBot.UI._spellSel = nil
    BfBot.UI._pendingSpellSelectionSync = nil
    BfBot.UI._targetSpellAnchor = nil
    BfBot.UI._variantSpellAnchor = nil
    buffbot_selectedRow = 0
    buffbot_selectedHasVariants = 0
end

--- Capture a valid projected row as the canonical selection. Invalid rows are
--- left alone during refresh capture, but user row actions explicitly clear.
function BfBot.UI._CaptureSpellSelection(row, clearIfInvalid)
    local selectedRow = tonumber(row) or 0
    local entry = buffbot_spellTable[selectedRow]
    if not entry or type(entry.resref) ~= "string" or entry.resref == "" then
        if clearIfInvalid then BfBot.UI._ClearSpellSelection() end
        return nil
    end
    BfBot.UI._spellSel = {
        context = BfBot.UI._SpellSelectionContext(),
        resref = entry.resref,
    }
    BfBot.UI._pendingSpellSelectionSync = nil
    buffbot_selectedRow = selectedRow
    BfBot.UI._UpdateVariantState()
    return BfBot.UI._spellSel
end

--- Prepare the canonical identity before replacing/reordering the row table.
--- A pending render repair stays authoritative because the native widget may
--- briefly project its old (but still numerically valid) row.
function BfBot.UI._PrepareSpellSelectionForRebuild()
    local currentContext = BfBot.UI._SpellSelectionContext()
    if BfBot.UI._spellSel
        and not BfBot.UI._SameSpellSelectionContext(
            BfBot.UI._spellSel.context, currentContext) then
        BfBot.UI._ClearSpellSelection()
    elseif not BfBot.UI._pendingSpellSelectionSync then
        BfBot.UI._CaptureSpellSelection(buffbot_selectedRow, false)
    end
end

--- Project the canonical selection into the current rebuilt row table.
--- Context changes and disappearance clear rather than transfer selection.
function BfBot.UI._RestoreSpellSelection()
    local sel = BfBot.UI._spellSel
    if not sel or not BfBot.UI._SameSpellSelectionContext(
        sel.context, BfBot.UI._SpellSelectionContext()) then
        BfBot.UI._ClearSpellSelection()
        return nil
    end
    local row = BfBot.UI._FindSpellRow(sel.resref)
    if not row then
        BfBot.UI._ClearSpellSelection()
        return nil
    end
    buffbot_selectedRow = row
    BfBot.UI._UpdateVariantState()
    if buffbot_isOpen then
        -- The native list may write its bound var back to zero after a table
        -- replacement. Reconcile for two render passes, then stop.
        BfBot.UI._pendingSpellSelectionSync = {
            context = sel.context,
            resref = sel.resref,
            passes = 2,
        }
    end
    return row
end

--- Lightweight render-frame reconciliation for the native list widget.
--- It only acts while a refresh-created token exists. A real user click runs
--- _OnSpellRowAction first, which replaces the canonical selection and
--- cancels this token; any other row write while pending is widget state.
function BfBot.UI._SelectionSyncTick()
    local pending = BfBot.UI._pendingSpellSelectionSync
    if not pending then return false end
    if not buffbot_isOpen then
        BfBot.UI._pendingSpellSelectionSync = nil
        return false
    end
    if not BfBot.UI._SameSpellSelectionContext(
        pending.context, BfBot.UI._SpellSelectionContext()) then
        BfBot.UI._ClearSpellSelection()
        return false
    end

    local row = BfBot.UI._FindSpellRow(pending.resref)
    if not row then
        BfBot.UI._ClearSpellSelection()
        return false
    end

    buffbot_selectedRow = row
    BfBot.UI._UpdateVariantState()
    pending.passes = (pending.passes or 1) - 1
    if pending.passes <= 0 then
        BfBot.UI._pendingSpellSelectionSync = nil
    end
    return false
end

--- Main list action: record row identity before dispatching cell-specific work.
function BfBot.UI._OnSpellRowAction(cell)
    if not BfBot.UI._CaptureSpellSelection(buffbot_selectedRow, true) then return end
    if cell and cell <= 2 then
        BfBot.UI.ToggleSpell(buffbot_selectedRow)
    elseif cell == 6 then
        BfBot.UI.StepSelectedRepeat(1)
    elseif cell == 8 then
        BfBot.UI.ToggleLock(buffbot_selectedRow)
    end
end

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

--- Register global quick-list listeners once per game process. The flags live
--- on the persistent root namespace, while each wrapper resolves BfBot.UI at
--- dispatch time so a force-reloaded module supplies the current handler.
function BfBot.UI._RegisterSpellListeners()
    if not BfBot._uiQuickListsCheckedListenerRegistered then
        EEex_Sprite_AddQuickListsCheckedListener(BfBot._SafeCallback(
            "ui.quick_lists_checked", function(...)
                return BfBot.UI._OnSpellListChanged(...)
            end))
        BfBot._uiQuickListsCheckedListenerRegistered = true
    end
    if not BfBot._uiQuickListCountsResetListenerRegistered then
        EEex_Sprite_AddQuickListCountsResetListener(BfBot._SafeCallback(
            "ui.quick_list_counts_reset", function(...)
                return BfBot.UI._OnSpellCountsReset(...)
            end))
        BfBot._uiQuickListCountsResetListenerRegistered = true
    end
    if not BfBot._uiQuickListNotifyRemovedListenerRegistered then
        EEex_Sprite_AddQuickListNotifyRemovedListener(BfBot._SafeCallback(
            "ui.quick_list_notify_removed", function(...)
                return BfBot.UI._OnSpellRemoved(...)
            end))
        BfBot._uiQuickListNotifyRemovedListenerRegistered = true
    end
end

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
        EEex_Menu_AddBeforeUIItemRenderListener("bbConfFrame", borderHook)
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

    -- Sprite listeners for auto-refresh (root-guarded across F5/module reloads)
    BfBot.UI._RegisterSpellListeners()

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

    -- Override row. Keep the selected-spell Repeat control between the
    -- Add/Remove cluster and the right-aligned import/export cluster.
    local overrideGap = 6
    local addW, removeW, repeatW, ioW = 110, 100, 90, 80
    setArea("bbAdd", cx, r4Y, addW, btnH)
    setArea("bbRmv", cx + addW + overrideGap, r4Y, removeW, btnH)
    setArea("bbRepeat", cx + addW + removeW + 2 * overrideGap,
        r4Y, repeatW, btnH)
    setArea("bbImp", cx + cw - ioW, r4Y, ioW, btnH)
    setArea("bbExp", cx + cw - 2 * ioW - overrideGap, r4Y, ioW, btnH)

    -- Spell action buttons: normal layout. The right-aligned delete button
    -- leaves a flexible gap after Sort at the 550px minimum panel width.
    setArea("bbTog", cx, r5Y, 100, btnH)
    setArea("bbTgt", cx + 105, r5Y, 130, btnH)
    setArea("bbUp", cx + 240, r5Y, 44, btnH)
    setArea("bbDn", cx + 288, r5Y, 44, btnH)
    setArea("bbSort", cx + 336, r5Y, 44, btnH)
    setArea("bbDel", cx + cw - 110, r5Y, 110, btnH)

    -- Spell action buttons: variant layout (includes the Variant picker).
    setArea("bbVTog", cx, r5Y, 80, btnH)
    setArea("bbVTgt", cx + 84, r5Y, 100, btnH)
    setArea("bbVVar", cx + 188, r5Y, 100, btnH)
    setArea("bbVUp", cx + 292, r5Y, 40, btnH)
    setArea("bbVDn", cx + 336, r5Y, 40, btnH)
    setArea("bbVSort", cx + 380, r5Y, 40, btnH)
    setArea("bbVDel", cx + cw - 90, r5Y, 90, btnH)

    -- Action buttons: Cast All, Cast Char, Stop — left side; Quick Cast, Close — right side
    local closeW = 70
    local qcW = 170
    local castAllW = 85
    local castCharW = 115
    local stopW = 55
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
        BfBot.UI._ClearSpellSelection()
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
    -- Keep identity canonical across automatic table replacement. The numeric
    -- row is only the list widget's projection and is rebuilt below.
    BfBot.UI._PrepareSpellSelectionForRebuild()
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
        BfBot.UI._RestoreSpellSelection()
        return
    end

    -- 2. Get current character's sprite + config
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then
        buffbot_spellTable = {}
        buffbot_presetNames = {}
        buffbot_presetCount = 0
        buffbot_title = BfBot.L10N.Get("common.buffbot")
        buffbot_castLabel = BfBot.L10N.Get("ui.cast.all")
        buffbot_castCharLabel = BfBot.L10N.Get("ui.cast.character")
        buffbot_status = ""
        BfBot.UI._RestoreSpellSelection()
        return
    end

    local config = BfBot.Persist.GetConfig(sprite)
    if not config then
        buffbot_spellTable = {}
        BfBot.UI._RestoreSpellSelection()
        return
    end

    -- 3. Update preset tab names and count from config (DYNAMIC)
    buffbot_presetNames = {}
    buffbot_presetCount = 0
    if config.presets then
        for idx, preset in pairs(config.presets) do
            buffbot_presetNames[idx] = preset.name or BfBot.L10N.Format(
                "default.preset.indexed", { index = idx })
            buffbot_presetCount = buffbot_presetCount + 1
        end
    end

    -- 4. Clamp preset index to valid range
    BfBot.UI._ClampPresetIdx(config)

    local preset = config.presets[BfBot.UI._presetIdx]
    if not preset then
        buffbot_spellTable = {}
        BfBot.UI._RestoreSpellSelection()
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
            local entry = BfBot.Persist._MakeDefaultEntry(scan.class, 0, scan.kind)
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
    buffbot_title = BfBot.L10N.Format("ui.title.preset", {
        preset = preset.name or BfBot.L10N.Format(
            "default.preset.indexed", { index = BfBot.UI._presetIdx }),
    })
    buffbot_castLabel = BfBot.L10N.Get("ui.cast.all")
    buffbot_castCharLabel = BfBot.UI._CastCharLabel()
    buffbot_status = BfBot.UI._GetStatusText()
    BfBot.UI._RestoreSpellSelection()
end

-- Complete dynamic templates that feed per-frame menu bindings are prepared
-- when their underlying state changes. Repeat strings have a tiny bounded
-- cache (1..MAX_SPELL_REPEATS); a future cap change rebuilds it once.
local _repeatDisplayCache = {}
local _repeatDisplayMax = nil

local function _EnsureRepeatDisplayCache()
    local max = BfBot.MAX_SPELL_REPEATS
    if _repeatDisplayMax == max then return end
    _repeatDisplayCache = {}
    _repeatDisplayMax = max
    for count = 1, max do
        local values = { count = count, max = max }
        _repeatDisplayCache[count] = {
            compact = BfBot.L10N.Format("ui.repeat.compact", values),
            label = BfBot.L10N.Format("ui.repeat.label", values),
            spellTooltip = BfBot.L10N.Format(
                "ui.repeat.spell_tooltip", values),
            itemTooltip = BfBot.L10N.Format(
                "ui.repeat.item_tooltip", values),
        }
    end
end

local function _RepeatDisplay(value)
    _EnsureRepeatDisplayCache()
    local count = BfBot.Persist._NormalizeSpellRepeat(value)
    return _repeatDisplayCache[count]
end

local function _TargetButtonDisplay(target)
    return BfBot.L10N.Format("ui.target.selected", { target = target })
end

local function _VariantButtonDisplay(name)
    return BfBot.L10N.Format("ui.variant.selected", { name = name })
end

_EnsureRepeatDisplayCache()

--- Build the spell-list rows for one caster's preset, cross-referenced with
--- scan data. Shared by the party view (ovr = config.ovr) and the summons
--- view (ovr = nil — no per-summon classification overrides; absent
--- lock/tgtUnlock fields read as 0, which the v9 summon schema guarantees).
-- @param sprite    caster sprite (party member or freshly-resolved summon)
-- @param preset    preset table { spells = { [resref] = entry } }
-- @param castable  BfBot.Scan.GetCastableSpells(sprite) result
-- @param ovr       classification-override table or nil
-- @return rows array sorted by priority
function BfBot.UI._BuildSpellRows(sprite, preset, castable, ovr)
    local rows = {}
    for resref, spellCfg in pairs(preset.spells) do
        -- Imported item settings are retained in persistence while the item
        -- is absent, but they have no row until the scanner sees the item
        -- again. Absent spells still load SPL metadata and remain visible.
        if spellCfg.kind ~= "itm" or castable[resref] then
        local rep = BfBot.Persist._NormalizeSpellRepeat(spellCfg.rep)
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

        local rowKind = (scan and scan.kind) or spellCfg.kind or "spl"
        local targetText = BfBot.UI._TargetToText(spellCfg.tgt)
        local repeatDisplay = _RepeatDisplay(rep)

        table.insert(rows, {
            resref   = resref,
            kind     = rowKind,
            name     = name,
            icon     = icon,
            dur      = dur,
            durText  = BfBot.UI._FormatDuration(dur),
            durCat   = durCat,
            durCatText = BfBot.UI._CategoryText(durCat),
            count    = count,
            countText = count > 0 and ("x" .. count) or "--",
            rep      = rep,
            repeatText = repeatDisplay.compact,
            on       = spellCfg.on or 0,
            targetText = targetText,
            targetButtonText = _TargetButtonDisplay(targetText),
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
            variantButtonText = variantName
                and _VariantButtonDisplay(variantName) or nil,
        })
        end
    end

    -- Sort by priority (ascending: lower = cast first)
    table.sort(rows, function(a, b) return a.pri < b.pri end)
    return rows
end

--- Summons-view refresh: summon tab labels, preset tabs (names come from the
--- protagonist's config — the preset axis is shared across views), and the
--- selected summon's preset spell table. All config reads/writes go to the
--- summon preset on the protagonist (schema v9: {qc, spells={[res]={on,tgt,
--- pri,rep,var}}}); the summon SPRITE never gets a config of its own.
function BfBot.UI._RefreshSummonsView()
    BfBot.UI._UpdateSummonTabNames()

    -- Preset tabs from the protagonist's config (shared preset axis)
    local prot = BfBot.Persist._GetProtagonist()
    local config = prot and BfBot.Persist.GetConfig(prot) or nil
    buffbot_presetNames = {}
    buffbot_presetCount = 0
    if config and config.presets then
        for idx, preset in pairs(config.presets) do
            buffbot_presetNames[idx] = preset.name or BfBot.L10N.Format(
                "default.preset.indexed", { index = idx })
            buffbot_presetCount = buffbot_presetCount + 1
        end
    end
    BfBot.UI._ClampPresetIdx(config)

    buffbot_castLabel = BfBot.L10N.Get("ui.cast.all")
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
        buffbot_title = BfBot.L10N.Get("ui.title.summons")
        BfBot.UI._UpdateSummonQc()  -- per-frame bbQC cache (review MINOR-4)
        return
    end

    buffbot_title = BfBot.L10N.Format("ui.title.summon_preset", {
        summon = BfBot.UI._SummonTabLabel(entry),
        preset = buffbot_presetNames[BfBot.UI._presetIdx]
            or BfBot.L10N.Format("default.preset.indexed", {
                index = BfBot.UI._presetIdx,
            }),
    })

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
    -- classification overrides). New entries follow the v9 spell-entry
    -- schema: on/tgt/pri/rep (lock/tgtUnlock do not exist for summons).
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
                rep = 1,
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
--- entries follow the v9 schema (on/tgt/pri/rep).
function BfBot.UI._SummonSpellEntry(resref, create)
    local sel = BfBot.UI._SelectedSummon()
    if not sel then return nil end
    local preset = BfBot.Persist.PeekSummonPreset(sel.identity, BfBot.UI._presetIdx)
    if not preset or type(preset.spells) ~= "table" then return nil end
    local e = preset.spells[resref]
    if not e and create then
        e = { on = 0, tgt = "p", pri = 999, rep = 1 }
        preset.spells[resref] = e
    end
    return e
end

-- ============================================================
-- Tab Switching (no cache invalidation)
-- ============================================================

function BfBot.UI.SetChar(slot)
    BfBot.UI._ClearSpellSelection()
    BfBot.UI._view = "party"  -- portrait tabs always land in party view
    BfBot.UI._charSlot = slot
    BfBot.UI._Refresh()
end

function BfBot.UI.SetPreset(idx)
    BfBot.UI._ClearSpellSelection()
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
-- Spell Repeat Count (integer-only persistence)
-- ============================================================

--- PURE: normalize a repeat count, then move one step with wrap-around.
--- Only the UI's supported directions (+1 / -1) are accepted; any other
--- delta follows the primary left-click direction (+1).
function BfBot.UI._StepSpellRepeat(current, delta)
    local rep = BfBot.Persist._NormalizeSpellRepeat(current)
    local step = (delta == -1) and -1 or 1
    local cap = BfBot.MAX_SPELL_REPEATS
    return ((rep - 1 + step) % cap) + 1
end

--- Change the selected spell's repeat count without rebuilding the table.
--- This deliberately ignores castability / remaining slots: an exhausted
--- row is still configuration that the player may edit for a later rest.
function BfBot.UI.StepSelectedRepeat(delta)
    local row = buffbot_selectedRow
    if row < 1 or row > #buffbot_spellTable then return end
    local entry = buffbot_spellTable[row]
    if not entry then return end

    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return end
    local rep = BfBot.UI._StepSpellRepeat(entry.rep, delta)

    if BfBot.UI._view == "summons" then
        local summonEntry = BfBot.UI._SummonSpellEntry(entry.resref, 1)
        if not summonEntry then return end
        summonEntry.rep = rep
    else
        BfBot.Persist.SetSpellRepeat(
            sprite, BfBot.UI._presetIdx, entry.resref, rep, entry.kind)
        rep = BfBot.Persist._NormalizeSpellRepeat(
            BfBot.Persist.GetSpellRepeat(
                sprite, BfBot.UI._presetIdx, entry.resref))
    end

    -- Immediate visual update preserves buffbot_selectedRow; _Refresh()
    -- would clear the selection and is intentionally not used here.
    entry.rep = rep
    entry.repeatText = _RepeatDisplay(rep).compact
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
        BfBot.Persist.SetSpellEnabled(
            sprite, BfBot.UI._presetIdx, entry.resref, newState, entry.kind)
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
    local entry = buffbot_spellTable[row]
    if not entry then return end
    buffbot_targetRow = row  -- compatibility/debug projection; never dereferenced
    BfBot.UI._targetSpellAnchor = BfBot.UI._MakeSpellAnchor(entry.resref)

    buffbot_targetHeader = entry.name or entry.resref
    buffbot_tgtPickerSel = 0

    -- Determine lock state
    local isLocked = 0
    local lockText = ""
    if entry.tgtUnlock ~= 1 then
        if entry.isSelfOnly == 1 then
            isLocked = 1
            lockText = BfBot.L10N.Get("ui.qualifier.self_only")
        elseif entry.isAoE == 1 then
            isLocked = 1
            lockText = BfBot.L10N.Get("ui.qualifier.party_wide")
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
    local entry = BfBot.UI._ResolveSpellAnchor(BfBot.UI._targetSpellAnchor)
    if not entry then
        BfBot.UI._targetSpellAnchor = nil
        Infinity_PopMenu("BUFFBOT_TARGETS")
        return
    end
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then
        BfBot.UI._targetSpellAnchor = nil
        Infinity_PopMenu("BUFFBOT_TARGETS")
        return
    end

    BfBot.UI._SetSpellTargetForView(sprite, entry.resref, "s")
    entry.tgt = "s"
    entry.targetText = BfBot.UI._TargetToText("s")
    entry.targetButtonText = _TargetButtonDisplay(entry.targetText)
    BfBot.UI._targetSpellAnchor = nil
    Infinity_PopMenu("BUFFBOT_TARGETS")
end

--- View-routed target write: party → Persist setter, summons → the stored
--- summon spell entry (v9 schema keeps tgt as "s"/"p"/name/ordered table).
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
    local entry = BfBot.UI._ResolveSpellAnchor(BfBot.UI._targetSpellAnchor)
    if not entry then
        BfBot.UI._targetSpellAnchor = nil
        Infinity_PopMenu("BUFFBOT_TARGETS")
        return
    end
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then
        BfBot.UI._targetSpellAnchor = nil
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
    entry.targetButtonText = _TargetButtonDisplay(entry.targetText)
    BfBot.UI._targetSpellAnchor = nil
    Infinity_PopMenu("BUFFBOT_TARGETS")
end

--- Unlock targeting for a locked spell. Party view only: the v9 summon
--- spell-entry schema has no tgtUnlock field (the picker's Unlock button is
--- hidden in the summons view).
function BfBot.UI.PickerUnlock()
    if BfBot.UI._view == "summons" then return end
    local entry = BfBot.UI._ResolveSpellAnchor(BfBot.UI._targetSpellAnchor)
    if not entry then
        BfBot.UI._targetSpellAnchor = nil
        Infinity_PopMenu("BUFFBOT_TARGETS")
        return
    end
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then
        BfBot.UI._targetSpellAnchor = nil
        Infinity_PopMenu("BUFFBOT_TARGETS")
        return
    end

    BfBot.Persist.SetTgtUnlock(sprite, BfBot.UI._presetIdx, entry.resref, 1)
    entry.tgtUnlock = 1
    buffbot_targetLocked = 0
    buffbot_targetLockText = ""
end

-- ============================================================
-- Generic Confirm Dialog (BUFFBOT_CONFIRM)
-- ============================================================

--- Open the confirmation dialog showing `msg`. `fn` runs only if the
-- user clicks the confirm button (see RunConfirm).
function BfBot.UI.OpenConfirm(msg, fn)
    BfBot.UI._confirmMsg = tostring(msg or "")
    BfBot.UI._confirmFn = fn
    Infinity_PushMenu("BUFFBOT_CONFIRM")
end

--- Confirm-button handler: run the pending action, then clear the holders.
-- The .menu confirm action pops BUFFBOT_CONFIRM right after this call.
function BfBot.UI.RunConfirm()
    local fn = BfBot.UI._confirmFn
    BfBot.UI._confirmMsg = ""
    BfBot.UI._confirmFn = nil
    if fn then
        local ok, err = pcall(fn)
        if not ok then
            BfBot._Error("Confirm action failed: " .. tostring(err))
        end
    end
end

--- Cancel/dismiss handler: clear the holders without running the action.
-- Wired to the Cancel button, the click-outside overlay, and Escape.
function BfBot.UI.CancelConfirm()
    BfBot.UI._confirmMsg = ""
    BfBot.UI._confirmFn = nil
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
        BfBot.UI._ClearSpellSelection()
        BfBot.UI._presetIdx = idx
        BfBot.Innate.RefreshAll()
        BfBot.UI._Refresh()
    end
end

--- Delete the current preset for all party members and switch to nearest.
-- Destructive — routed through the confirm dialog (accidental clicks on
-- the Delete Preset button kept nuking presets). The index is captured at
-- open time so the delete targets the preset named in the message; the
-- original delete + clamp + refresh sequence runs only on confirm.
function BfBot.UI.DeleteCurrentPreset()
    if BfBot.UI._view == "summons" then return end
    local idx = BfBot.UI._presetIdx
    local name = buffbot_presetNames[idx] or BfBot.L10N.Format(
        "default.preset.indexed", { index = idx })
    BfBot.UI.OpenConfirm(BfBot.L10N.Format(
        "ui.delete_preset_confirm", { name = name }), function()
        local result = BfBot.Persist.DeletePresetAll(idx)
        if result then
            BfBot.UI._ClearSpellSelection()
            -- Clamp to first valid preset for the current character
            local sprite = BfBot.UI._GetSelectedSprite()
            if sprite then
                local config = BfBot.Persist.GetConfig(sprite)
                BfBot.UI._ClampPresetIdx(config)
            end
            BfBot.Innate.RefreshAll()
            BfBot.UI._Refresh()
        end
    end)
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
        BfBot._Display(BfBot.L10N.Get("feedback.no_spells_preset"))
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
    local queue, reason, detail = BfBot.Persist.BuildQueueForCharacter(
        BfBot.UI._charSlot, BfBot.UI._presetIdx)
    if not queue or #queue == 0 then
        if reason == "reason.queue.not_locally_controlled" then
            Infinity_DisplayString(BfBot.L10N.Format(
                "feedback.character_remote_control", {
                    name = detail and detail.name or BfBot._GetName(sprite),
                }))
        elseif reason == "reason.queue.project_image_locked" then
            Infinity_DisplayString(BfBot.L10N.Format(
                "feedback.character_project_image_locked", {
                    name = detail and detail.name or BfBot._GetName(sprite),
                }))
        else
            Infinity_DisplayString(BfBot.L10N.Get(
                "feedback.no_spells_character"))
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
        Infinity_DisplayString(BfBot.L10N.Get("feedback.no_summon_selected"))
        return
    end
    BfBot.Persist.DrainBuildSkips()  -- discard skips from earlier builds
    local queue, reason, detail = BfBot.Persist.BuildQueueForSummon(
        entry, BfBot.UI._presetIdx)
    if not queue or #queue == 0 then
        if reason == nil
                or reason == "reason.queue.no_castable_summon_spells" then
            Infinity_DisplayString(BfBot.L10N.Get(
                "feedback.no_spells_summon"))
        else
            Infinity_DisplayString(BfBot.L10N.Format(
                "feedback.no_spells_summon_with_reason", {
                    reason = BfBot.L10N.Reason(reason, detail),
                }))
        end
        return
    end
    BfBot.UI._StartRun(queue, 0, BfBot.UI._presetIdx)
    buffbot_status = BfBot.UI._GetStatusText()
end

function BfBot.UI._CastCharLabel()
    if BfBot.UI._view == "summons" then
        return BfBot.L10N.Get("ui.cast.summon")
    end
    local name = buffbot_charNames[BfBot.UI._charSlot + 1]
    if name then
        return BfBot.L10N.Format("ui.cast.named", { name = name })
    end
    return BfBot.L10N.Get("ui.cast.character")
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

--- Does an event belong to the caster currently displayed by the panel?
--- Compare numeric object IDs; EEex sprite userdata equality is unreliable.
function BfBot.UI._IsDisplayedSpellEventSprite(sprite)
    if not buffbot_isOpen or not sprite then return false end
    local displayed = BfBot.UI._GetSelectedSprite()
    return displayed ~= nil and displayed.m_id == sprite.m_id
end

function BfBot.UI._IsBuffBotGeneratedResref(resref)
    return type(resref) == "string" and resref:upper():sub(1, 4) == "BFBT"
end

function BfBot.UI._OnSpellListChanged(sprite, resref, changeAmount)
    BfBot.Scan.Invalidate(sprite)
    if not BfBot.UI._IsBuffBotGeneratedResref(resref)
        and BfBot.UI._IsDisplayedSpellEventSprite(sprite) then
        BfBot.UI._Refresh()
    end
end

function BfBot.UI._OnSpellCountsReset(sprite)
    BfBot.Scan.Invalidate(sprite)
    if BfBot.UI._IsDisplayedSpellEventSprite(sprite) then BfBot.UI._Refresh() end
end

function BfBot.UI._OnSpellRemoved(sprite, resref)
    BfBot.Scan.Invalidate(sprite)
    if not BfBot.UI._IsBuffBotGeneratedResref(resref)
        and BfBot.UI._IsDisplayedSpellEventSprite(sprite) then
        BfBot.UI._Refresh()
    end
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
    BfBot.UI._PrepareSpellSelectionForRebuild()

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
    BfBot.UI._RestoreSpellSelection()
end

-- ============================================================
-- Spell Override (Add / Remove)
-- ============================================================

--- PURE: order Add Spell picker rows by recovery precedence, then current
--- available count, localized name, and resref. Full ties compare false so
--- the function is a strict comparator for table.sort.
function BfBot.UI._SpellPickerLess(a, b)
    local aExcluded = a.excluded or 0
    local bExcluded = b.excluded or 0
    if aExcluded ~= bExcluded then return aExcluded > bExcluded end

    local aCount = a.count or 0
    local bCount = b.count or 0
    if aCount ~= bCount then return aCount > bCount end

    local aName = a.name or a.resref or ""
    local bName = b.name or b.resref or ""
    if aName ~= bName then return aName < bName end

    return (a.resref or "") < (b.resref or "")
end

--- Build the picker list: castable spells/items the user can add to the preset.
--- Includes non-buff spells (manual inclusion) and previously-excluded buffs
--- (recovery from accidental Remove). Items ride the same excluded-buff path:
--- they auto-merge into presets as buffs, so they only surface here after the
--- user removed them (ovr == -1). The list is sectioned by kind — a [Spells]
--- header row, spell rows, an [Items] header row, item rows; a section with
--- no rows is omitted. Excluded entries sort to the top of their section.
function BfBot.UI._BuildPickerList()
    buffbot_pickerSpells = {}
    buffbot_pickerSelected = 0
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return end
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return end
    local preset = config.presets[BfBot.UI._presetIdx]
    if not preset then return end

    local spells, items = {}, {}
    local castable = BfBot.Scan.GetCastableSpells(sprite)
    for resref, scan in pairs(castable) do
        -- Skip entries already in the preset
        if preset.spells[resref] then goto nextSpell end
        -- Skip entries with no classification
        if not scan.class then goto nextSpell end
        local ovr = config.ovr and config.ovr[resref]
        -- Items use the picker only as a per-character recovery path. A
        -- classifier override is process-global, so another character's
        -- exclusion must not surface this item here without a matching local
        -- persisted override. Spells retain the general non-buff add path.
        if scan.kind == "itm" then
            if ovr ~= -1 then goto nextSpell end
        elseif scan.class.isBuff and ovr ~= -1 then
            goto nextSpell
        end

        table.insert(scan.kind == "itm" and items or spells, {
            resref   = resref,
            kind     = scan.kind,
            name     = scan.name or resref,
            icon     = scan.icon or "",
            durCat   = scan.durCat or "?",
            durCatText = BfBot.UI._CategoryText(scan.durCat),
            count    = scan.count or 0,
            excluded = (ovr == -1) and 1 or 0,
        })
        ::nextSpell::
    end
    -- Sort each section by recovery precedence, current count, localized
    -- name, and resref. Section grouping remains the primary ordering.
    table.sort(spells, BfBot.UI._SpellPickerLess)
    table.sort(items, BfBot.UI._SpellPickerLess)
    -- Assemble sections. Header rows are non-clickable sentinels (isHeader=1);
    -- AddPickedSpell ignores them and _PickerHasSelection treats them as no
    -- selection. Empty sections (and their headers) are omitted, so an empty
    -- picker keeps the existing "nothing to add" behavior.
    if #spells > 0 then
        table.insert(buffbot_pickerSpells, {
            resref = "__HEADER_SPL__",
            name = "[" .. BfBot.L10N.Get("common.spells") .. "]",
            isHeader = 1,
        })
        for _, entry in ipairs(spells) do table.insert(buffbot_pickerSpells, entry) end
    end
    if #items > 0 then
        table.insert(buffbot_pickerSpells, {
            resref = "__HEADER_ITM__",
            name = "[" .. BfBot.L10N.Get("common.items") .. "]",
            isHeader = 1,
        })
        for _, entry in ipairs(items) do table.insert(buffbot_pickerSpells, entry) end
    end
end

--- Open the spell picker sub-menu.
function BfBot.UI.OpenSpellPicker()
    if BfBot.UI._view == "summons" then return end
    BfBot.UI._BuildPickerList()
    if #buffbot_pickerSpells == 0 then
        BfBot._Display(BfBot.L10N.Get("feedback.no_additional_spells"))
        return
    end
    Infinity_PushMenu("BUFFBOT_SPELLPICKER")
end

--- Add the selected spell from the picker (include override).
function BfBot.UI.AddPickedSpell()
    if BfBot.UI._view == "summons" then return end
    local entry = buffbot_pickerSpells[buffbot_pickerSelected]
    if not entry or entry.isHeader then return end  -- ignore section-header rows
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
--- Section-header rows count as no selection (keeps the Add button hidden).
function BfBot.UI._PickerHasSelection()
    local entry = buffbot_pickerSelected > 0 and buffbot_pickerSpells[buffbot_pickerSelected] or nil
    return entry ~= nil and not entry.isHeader
end

-- ============================================================
-- Config Export / Import
-- ============================================================

--- Export current character's config.
function BfBot.UI.ExportConfig()
    if BfBot.UI._view == "summons" then return end
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return end

    local ok, result, detail = BfBot.Persist.ExportConfig(sprite)
    if ok then
        BfBot._Display(BfBot.L10N.Format(
            "feedback.export_success", { file = result }))
    else
        BfBot._Display(BfBot.L10N.Format("feedback.export_failed", {
            reason = BfBot.L10N.Reason(result, detail),
        }))
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
        BfBot._Display(BfBot.L10N.Get("feedback.no_exported_configs"))
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
        BfBot._Display(BfBot.L10N.Format("feedback.import_success", {
            file = entry.name,
            presets = presets,
            skipped = skipped,
        }))
        BfBot.Scan.Invalidate(sprite)
        BfBot.UI._Refresh()
    else
        BfBot._Display(BfBot.L10N.Format("feedback.import_failed", {
            reason = BfBot.L10N.Reason(presets, skipped),
        }))
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
    BfBot.UI._variantSpellAnchor = BfBot.UI._MakeSpellAnchor(entry.resref)

    buffbot_variantHeader = entry.name or entry.resref
    buffbot_variantTitle = BfBot.L10N.Format(
        "ui.select_variant_title", { spell = buffbot_variantHeader })
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

    local entry = BfBot.UI._ResolveSpellAnchor(BfBot.UI._variantSpellAnchor)
    if not entry then
        BfBot.UI._variantSpellAnchor = nil
        Infinity_PopMenu("BUFFBOT_VARIANTS")
        return
    end

    local currentVariant = nil
    if type(entry.variants) == "table" and type(vEntry.resref) == "string" then
        local wanted = vEntry.resref:upper()
        for _, variant in ipairs(entry.variants) do
            if type(variant.resref) == "string"
                and variant.resref:upper() == wanted then
                currentVariant = variant
                break
            end
        end
    end
    if not currentVariant then
        BfBot.UI._variantSpellAnchor = nil
        Infinity_PopMenu("BUFFBOT_VARIANTS")
        return
    end

    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then
        BfBot.UI._variantSpellAnchor = nil
        Infinity_PopMenu("BUFFBOT_VARIANTS")
        return
    end

    -- Store the variant (summons view → the stored summon spell entry)
    if BfBot.UI._view == "summons" then
        local se = BfBot.UI._SummonSpellEntry(entry.resref, 1)
        if se then se.var = vEntry.resref end
    else
        BfBot.Persist.SetSpellVariant(
            sprite, BfBot.UI._presetIdx, entry.resref, vEntry.resref, entry.kind)
    end
    entry.var = vEntry.resref
    entry.variantName = currentVariant.name or vEntry.name
    entry.variantButtonText = _VariantButtonDisplay(entry.variantName)

    BfBot.UI._variantSpellAnchor = nil
    Infinity_PopMenu("BUFFBOT_VARIANTS")
end

--- Variant button text for the selected spell.
function BfBot.UI._VariantBtnText()
    if buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable then
        local entry = buffbot_spellTable[buffbot_selectedRow]
        if entry and entry.variantButtonText then
            return entry.variantButtonText
        end
    end
    return BfBot.L10N.Get("common.variant")
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
        if entry and entry.on == 1 then
            return BfBot.L10N.Get("common.disable")
        end
    end
    return BfBot.L10N.Get("common.enable")
end

--- Target button text: shows current target of selected row.
function BfBot.UI._TargetBtnText()
    if buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable then
        local entry = buffbot_spellTable[buffbot_selectedRow]
        if entry and entry.targetButtonText then return entry.targetButtonText end
    end
    return BfBot.L10N.Get("common.target")
end

--- Normalized repeat count for the selected row (safe while the button is
--- disabled and the menu still evaluates its text / tooltip expressions).
function BfBot.UI._SelectedSpellRepeat()
    local entry = buffbot_spellTable[buffbot_selectedRow]
    return BfBot.Persist._NormalizeSpellRepeat(entry and entry.rep or nil)
end

--- Repeat footer-button text for the selected spell.
function BfBot.UI._RepeatButtonText()
    return _RepeatDisplay(BfBot.UI._SelectedSpellRepeat()).label
end

--- Repeat footer-button tooltip for the selected spell or item.
function BfBot.UI._RepeatTooltip()
    local entry = buffbot_spellTable[buffbot_selectedRow]
    local display = _RepeatDisplay(BfBot.UI._SelectedSpellRepeat())
    if entry and entry.kind == "itm" then
        return display.itemTooltip
    end
    return display.spellTooltip
end

--- Compact repeat text for a list row. The menu can evaluate stale rowNumber
--- values while replacing its list table, so the fallback must be nil-safe.
function BfBot.UI._RepeatRowText(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.repeatText then return entry.repeatText end
    return _RepeatDisplay(entry and entry.rep).compact
end

--- Format a duration in seconds to a human-readable string.
--- Returns mixed format: "1h 30m", "5m", "1m 30s", "45s", "Perm", "Inst", "?"
function BfBot.UI._FormatDuration(seconds)
    if seconds == nil then return "?" end
    if seconds == -1 then return BfBot.L10N.Get("ui.duration.permanent") end
    if seconds == 0 then return BfBot.L10N.Get("ui.duration.instant") end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        if m > 0 then
            return BfBot.L10N.Format("ui.duration.hours_minutes", {
                hours = h, minutes = m,
            })
        end
        return BfBot.L10N.Format("ui.duration.hours", { hours = h })
    end
    if m > 0 then
        if s > 0 then
            return BfBot.L10N.Format("ui.duration.minutes_seconds", {
                minutes = m, seconds = s,
            })
        end
        return BfBot.L10N.Format("ui.duration.minutes", { minutes = m })
    end
    return BfBot.L10N.Format("ui.duration.seconds", { seconds = s })
end

--- Map language-neutral classifier categories only at the display boundary.
function BfBot.UI._CategoryText(category)
    if category == "permanent" then
        return BfBot.L10N.Get("ui.category.permanent")
    elseif category == "long" then
        return BfBot.L10N.Get("ui.category.long")
    elseif category == "short" then
        return BfBot.L10N.Get("ui.category.short")
    elseif category == "instant" then
        return BfBot.L10N.Get("ui.category.instant")
    end
    return BfBot.L10N.Get("ui.category.unknown")
end

--- Spell name color: grey for unavailable, dark blue for manual include,
--- bronze tint for item rows, gold-tinted for locked, dark brown for normal.
function BfBot.UI._SpellNameColor(row)
    local entry = buffbot_spellTable[row]
    if not entry then return _parseColor(BfBot.UI._T("text")) end
    if entry.castable == 0 then return _parseColor(BfBot.UI._T("textMuted")) end
    if entry.ovr == 1 then return _parseColor(BfBot.UI._T("textAccent")) end
    if entry.kind == "itm" and entry.lock ~= 1 then
        return _parseColor(BfBot.UI._T("itemColor"))
    end
    if entry.lock == 1 then return _parseColor(BfBot.UI._T("spellLocked")) end
    return _parseColor(BfBot.UI._T("text"))
end

--- Picker name color: section-header tint for header rows, bronze tint for
--- item rows, normal text tint for spell rows.
function BfBot.UI._PickerNameColor(row)
    local entry = buffbot_pickerSpells[row]
    if not entry then return _parseColor(BfBot.UI._T("text")) end
    if entry.isHeader then return _parseColor(BfBot.UI._T("headerSub")) end
    if entry.kind == "itm" then return _parseColor(BfBot.UI._T("itemColor")) end
    return _parseColor(BfBot.UI._T("text"))
end

--- Repeat column color: repeated casts use the theme accent. A single cast
--- follows the normal spell-row color, including muted unavailable rows.
function BfBot.UI._RepeatColor(row)
    local entry = buffbot_spellTable[row]
    if not entry then return _parseColor(BfBot.UI._T("text")) end
    local rep = BfBot.Persist._NormalizeSpellRepeat(entry.rep)
    if rep > 1 then return _parseColor(BfBot.UI._T("textAccent")) end
    if entry.castable == 0 then return _parseColor(BfBot.UI._T("textMuted")) end
    return _parseColor(BfBot.UI._T("text"))
end

--- Checkbox display: "+" for enabled, empty for disabled.
function BfBot.UI._CheckboxText(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.on == 1 then return "[X]" end
    return "[ ]"
end

--- Lock column display text. The summons view has no lock feature (the v9
--- summon spell-entry schema has no lock field) — the column stays blank.
function BfBot.UI._LockText(row)
    if BfBot.UI._view == "summons" then return "" end
    local entry = buffbot_spellTable[row]
    if entry and entry.lock == 1 then
        return BfBot.L10N.Get("ui.lock.compact")
    end
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
    BfBot.Persist.SetSpellLock(sprite, BfBot.UI._presetIdx, entry.resref, newState, entry.kind)
end

--- Convert target config value to display text.
-- tgt can be: "s", "p", a name string, or a table of name strings.
-- Also handles legacy slot strings ("1"-"6") for backwards compatibility.
function BfBot.UI._TargetToText(tgt)
    if tgt == "s" then return BfBot.L10N.Get("common.self")
    elseif tgt == "p" then return BfBot.L10N.Get("common.party")
    elseif type(tgt) == "table" then
        if #tgt == 0 then return BfBot.L10N.Get("common.none") end
        -- First entry is always the display name (highest priority target)
        local firstName = tgt[1]
        -- Legacy slot string? Resolve to name for display
        local num = tonumber(firstName)
        if num and num >= 1 and num <= 6 then
            firstName = buffbot_charNames[num] or BfBot.L10N.Format(
                "ui.target.player", { index = num })
        end
        if #tgt == 1 then
            return firstName
        end
        return BfBot.L10N.Format("ui.target.multiple", {
            name = firstName, count = #tgt - 1,
        })
    else
        -- Single string: name or legacy slot
        local num = tonumber(tgt)
        if num and num >= 1 and num <= 6 then
            return buffbot_charNames[num] or BfBot.L10N.Format(
                "ui.target.player", { index = num })
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
        if qc == 2 then
            return BfBot.L10N.Get("ui.status.casting_quick_all")
        elseif qc == 1 then
            return BfBot.L10N.Get("ui.status.casting_quick_long")
        else
            return BfBot.L10N.Get("ui.status.casting")
        end
    elseif state == "done" then return BfBot.L10N.Get("ui.status.done")
    elseif state == "stopped" then return BfBot.L10N.Get("ui.status.stopped")
    else return "" end
end

-- ============================================================
-- Quick Cast Cycling Button
-- ============================================================

--- Quick Cast value (0..2) for the current view: party → the selected
--- character's per-preset qc; summons → the CACHED qc of the selected
--- summon's preset (its OWN v9 qc field — the summon follows it even
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
    if qc == 1 then return BfBot.L10N.Get("ui.quick_cast.long") end
    if qc == 2 then return BfBot.L10N.Get("ui.quick_cast.all") end
    return BfBot.L10N.Get("ui.quick_cast.off")
end

function BfBot.UI._QuickCastColor()
    local qc = BfBot.UI._ViewQuickCast()
    if qc == 1 then return _parseColor(BfBot.UI._T("qcLong")) end
    if qc == 2 then return _parseColor(BfBot.UI._T("qcAll")) end
    return _parseColor(BfBot.UI._T("qcOff"))
end

function BfBot.UI._QuickCastTooltip()
    local qc = BfBot.UI._ViewQuickCast()
    if qc == nil then
        return BfBot.L10N.Get("ui.quick_cast.tooltip_unavailable")
    end
    if qc == 1 then return BfBot.L10N.Get("ui.quick_cast.tooltip_long") end
    if qc == 2 then return BfBot.L10N.Get("ui.quick_cast.tooltip_all") end
    return BfBot.L10N.Get("ui.quick_cast.tooltip_off")
end

-- ============================================================
-- Debug Mode Toggle
-- ============================================================

function BfBot.UI.ToggleDebug()
    BfBot._debugMode = (BfBot._debugMode == 1) and 0 or 1
    Infinity_SetINIValue("BuffBot", "Debug", BfBot._debugMode)
    BfBot._Display("BuffBot: Debug mode " .. (BfBot._debugMode == 1 and "ON" or "OFF"))
end
