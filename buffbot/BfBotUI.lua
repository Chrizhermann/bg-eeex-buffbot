-- ============================================================
-- BfBotUI.lua — BuffBot Configuration UI
-- Lua-side logic for the BuffBot panel (.menu callbacks,
-- state management, spell table population)
-- ============================================================

-- BfBotThm has already set BfBot.UI = {} and added BfBot.UI._T. Use `or {}`
-- so we don't wipe _T (which the .menu evaluates per-frame for theme colors).
BfBot.UI = BfBot.UI or {}

-- ============================================================
-- Internal State
-- ============================================================

BfBot.UI._charSlot = 0        -- selected character slot (0-5)
BfBot.UI._presetIdx = 1       -- selected preset index (shared across views)
BfBot.UI._view = "party"      -- active view: "party" (portrait tabs) or "summons"
BfBot.UI._initialized = false
BfBot.UI._spellSel = nil       -- canonical spell selection {context, resref}; NEVER a row index
BfBot.UI._pendingSpellSelectionSync = nil
BfBot.UI._spellListRefreshPending = nil
BfBot.UI._targetSpellAnchor = nil
BfBot.UI._variantSpellAnchor = nil

-- Summons view state (issue #19, Task 10)
BfBot.UI._SUMMONS_PER_PAGE = 6   -- tab slots per page (mirrors the 6 portrait tabs)
BfBot.UI._summonList = {}        -- UI-owned copies of GetAlliedSummons entries (no sprites)
BfBot.UI._summonSlice = {}       -- current page's entries (kept in sync with tab labels)
BfBot.UI._summonPage = 1         -- 1-based page into _summonList
BfBot.UI._summonSel = nil        -- selection descriptor {identity, oid, name, cloneType} — NEVER a row index
BfBot.UI._summonQc = nil         -- cached summons-view Quick Cast value (see _UpdateSummonQc)

-- The active-buff policy for the next run (issue #84) is NOT panel state:
-- BfBot.Exec owns it (BfBot.Exec.GetForceMode / SetForceMode / CycleForceMode)
-- so the panel rebuild in #81 only has to re-place a button, and so the policy
-- can be set from the console without a panel. The functions below are the
-- panel's thin view of it: one cycle, one label, one color, one tooltip.

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
-- The widget displays references to canonical rows. Filtering never changes
-- the preset's order, cast queue, or the indices used by editing actions.
buffbot_visibleSpells = {}
buffbot_visibleSelectedRow = 0
buffbot_searchText = ""
BfBot.UI._appliedSearchText = ""

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
    buffbot_visibleSelectedRow = 0
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
    BfBot.UI._RebuildVisibleSpells()
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
    BfBot.UI._ProjectVisibleSelection()
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
    BfBot.UI._ProjectVisibleSelection()
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

-- LuaJIT's string.lower handles ASCII only. Fold the Latin and Cyrillic
-- letters used by our catalogs as UTF-8, leaving other scripts unchanged.
function BfBot.UI._SearchName(text)
    local value = tostring(text or ""):lower():gsub("ẞ", "ß")
    return (value:gsub("[\194-\223][\128-\191]", function(char)
        local a, b = char:byte(1, 2)
        local cp = (a - 192) * 64 + b - 128
        if (cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7)
            or (cp >= 0x410 and cp <= 0x42F) then cp = cp + 32
        elseif cp >= 0x400 and cp <= 0x40F then cp = cp + 80
        elseif cp == 0x178 then cp = 0xFF
        elseif ((cp >= 0x100 and cp <= 0x12F)
            or (cp >= 0x132 and cp <= 0x137)
            or (cp >= 0x14A and cp <= 0x177)) and cp % 2 == 0 then cp = cp + 1
        elseif ((cp >= 0x139 and cp <= 0x148)
            or (cp >= 0x179 and cp <= 0x17E)) and cp % 2 == 1 then cp = cp + 1
        end
        return string.char(192 + math.floor(cp / 64), 128 + cp % 64)
    end))
end

function BfBot.UI._RebuildVisibleSpells()
    local query = BfBot.UI._SearchName(buffbot_searchText)
    local rows, indices = {}, {}
    for index, entry in ipairs(buffbot_spellTable) do
        if query == "" or BfBot.UI._SearchName(entry.name or entry.resref):find(query, 1, true) then
            rows[#rows + 1] = entry
            indices[#rows] = index
        end
    end
    buffbot_visibleSpells = rows
    BfBot.UI._visibleSpellIndices = indices
    BfBot.UI._visibleSpellContext = BfBot.UI._SpellSelectionContext()
    BfBot.UI._appliedSearchText = buffbot_searchText
end

function BfBot.UI._VisibleSpellRow(row)
    return BfBot.UI._visibleSpellIndices and BfBot.UI._visibleSpellIndices[row] or 0
end

function BfBot.UI._ProjectVisibleSelection()
    buffbot_visibleSelectedRow = 0
    for visible, index in ipairs(BfBot.UI._visibleSpellIndices or {}) do
        if index == buffbot_selectedRow then
            buffbot_visibleSelectedRow = visible
            return
        end
    end
    -- Keep the identity anchor so clearing the search restores selection,
    -- but disable actions while its row is hidden.
    buffbot_selectedRow = 0
end

function BfBot.UI._SearchTick()
    if not buffbot_isOpen or buffbot_searchText == BfBot.UI._appliedSearchText then return false end
    BfBot.UI._PrepareSpellSelectionForRebuild()
    BfBot.UI._RestoreSpellSelection()
    if EEex_Menu_GetItem then
        local item = EEex_Menu_GetItem("bbList")
        if item and item.scrollbar then item.scrollbar.top = 0 end
    end
    return false
end

function BfBot.UI.ClearSearch()
    buffbot_searchText = ""
    BfBot.UI._SearchTick()
end

function BfBot.UI._OnVisibleSpellRowAction(cell)
    -- A query/context change since the last render invalidates the click.
    if buffbot_searchText ~= BfBot.UI._appliedSearchText
        or not BfBot.UI._SameSpellSelectionContext(
            BfBot.UI._visibleSpellContext, BfBot.UI._SpellSelectionContext()) then
        BfBot.UI._SearchTick()
        return
    end
    local entry = buffbot_visibleSpells[buffbot_visibleSelectedRow]
    local row = entry and BfBot.UI._FindSpellRow(entry.resref)
    if not row or buffbot_spellTable[row] ~= entry then return end
    buffbot_selectedRow = row
    BfBot.UI._OnSpellRowAction(cell)
    BfBot.UI._ProjectVisibleSelection()
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

    -- Register 9-slice border textures (one per theme variant). The atlases
    -- carry Pecca's corner at its native 38x28 and a short slice of each rail
    -- for the edges, which the engine stretches — the rails are uniform, so a
    -- stretched slice and a tiled one look the same.
    -- Wrapped in pcall — stores status for later console inspection
    BfBot.UI._borderStatus = "not attempted"
    BfBot.UI._borderOk = false
    local BORDER_RESREFS = { "BFBOTFR", "BFBOTFR2", "BFBOTFR3" }
    local anyOk = false
    local errs = {}
    for _, resref in ipairs(BORDER_RESREFS) do
        local regOk, regErr = pcall(function()
            EEex.RegisterSlicedRect("BuffBot_Border_" .. resref, {
                ["topLeft"]     = {   0,   0,  38,  28 },
                ["top"]         = {  38,   0, 180,  28 },
                ["topRight"]    = { 218,   0,  38,  28 },
                ["right"]       = { 218,  28,  38,  72 },
                ["bottomRight"] = { 218, 100,  38,  28 },
                ["bottom"]      = {  38, 100, 180,  28 },
                ["bottomLeft"]  = {   0, 100,  38,  28 },
                ["left"]        = {   0,  28,  38,  72 },
                ["center"]      = {  38,  28, 180,  72 },
                ["dimensions"]  = { 256, 128 },
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
    BfBot.UI._borderOk = anyOk and true or false
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
        EEex_Menu_AddBeforeUIItemRenderListener("bbQuickFrame", borderHook)
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
        BfBot.UI._CloseQuickMenu()
        if BfBot.UI._ActionbarVisible() then BfBot.UI._OpenActionbarBtn() end
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
    local sw, sh = Infinity_GetScreenSize()
    local ax, ay, aw, ah = EEex_Menu_GetArea("WORLD_ACTIONBAR")
    if not sw or not sh or not ax then return end
    local x, y = ax + aw, ay + ah - 56
    -- UI++'s artwork can span several screens. Dock to its actual controls
    -- when present; otherwise use the stock actionbar's bottom edge.
    if RgIsModernHud == 1 and EEex_Menu_GetItemArea then
        local bx, by, bw, bh = EEex_Menu_GetItemArea("rgActionbarGoldernButton11")
        if bx and bw and bw > 0 then
            x, y = bx + bw + 4, by + bh - 56
            if x + 56 > sw then
                local left = EEex_Menu_GetItemArea("rgActionbarButton1")
                x = (left or bx) - 60
            end
        end
    end
    x, y = math.max(0, math.min(sw - 56, x)), math.max(0, math.min(sh - 56, y))
    BfBot.UI._hudX, BfBot.UI._hudY = x, y
    Infinity_SetOffset("BUFFBOT_ACTIONBAR", x, y)
    local open = Infinity_IsMenuOnStack("BUFFBOT_ACTIONBAR")
    if open ~= true and open ~= 1 then Infinity_PushMenu("BUFFBOT_ACTIONBAR") end
end

function BfBot.UI._CloseActionbarBtn()
    if BfBot.Fast and BfBot.Fast.run then
        BfBot.Fast.Release("world controls hidden")
        BfBot.Exec.Stop()
    end
    BfBot.UI._CloseQuickMenu()
    Infinity_PopMenu("BUFFBOT_ACTIONBAR")
end

function BfBot.UI._ActionbarVisible()
    local visible = Infinity_IsMenuOnStack("WORLD_ACTIONBAR")
    return e and worldScreen and e:GetActiveEngine() == worldScreen
        and (visible == true or visible == 1)
end

function BfBot.UI._ActionbarTick()
    local now = Infinity_GetClockTicks()
    if BfBot.UI._hudTick and now >= BfBot.UI._hudTick and now - BfBot.UI._hudTick < 250 then return false end
    BfBot.UI._hudTick = now
    if BfBot.UI._ActionbarVisible() then BfBot.UI._OpenActionbarBtn()
    else BfBot.UI._CloseQuickMenu() end
    return false
end

function BfBot.UI._CloseQuickMenu()
    local open = Infinity_IsMenuOnStack("BUFFBOT_QUICK_PRESETS")
    if open == true or open == 1 then Infinity_PopMenu("BUFFBOT_QUICK_PRESETS") end
    BfBot.UI._quickPresets = nil
end

function BfBot.UI._QuickPresetName(row)
    local entry = BfBot.UI._quickPresets and BfBot.UI._quickPresets[row]
    return entry and entry.name or ""
end

function BfBot.UI._ToggleQuickMenu()
    local open = Infinity_IsMenuOnStack("BUFFBOT_QUICK_PRESETS")
    if open == true or open == 1 then return BfBot.UI._CloseQuickMenu() end
    if not BfBot.UI._ActionbarVisible() then return end
    local owner = BfBot.Persist._GetProtagonist()
    local config = owner and BfBot.Persist.GetConfig(owner)
    if not config or not config.presets then return end
    local rows = {}
    for index = 1, BfBot.MAX_PRESETS do
        local preset = config.presets[index]
        if preset then rows[#rows + 1] = { index = index, preset = preset,
            name = preset.name or BfBot.L10N.Format("default.preset.indexed", { index = index }),
            ownerId = owner.m_id, ownerName = BfBot._GetName(owner) } end
    end
    if #rows == 0 then return end
    BfBot.UI._quickPresets = rows
    local sw, sh = Infinity_GetScreenSize()
    local margin, w = 28, math.min(300, sw - 56)
    local rowH = math.min(34, math.floor((sh - 2 * margin - 44) / #rows))
    local h = 44 + #rows * rowH
    local x = math.max(margin, math.min(sw - w - margin, BfBot.UI._hudX or sw))
    local y = math.max(margin, math.min(sh - h - margin, (BfBot.UI._hudY or sh) - h - margin))
    -- The same pairing _Layout uses: a button is a button item with its
    -- caption in a separate label above it, so whatever moves the button has
    -- to move the caption. This menu opens wherever the mouse is, and the
    -- captions used to keep the area the .menu gives them -- eight labels
    -- sitting wherever the panel last was while their rows travelled.
    local function setArea(name, ax, ay, aw, ah)
        Infinity_SetArea(name, ax, ay, aw, ah)
        pcall(Infinity_SetArea, name .. "_t", ax, ay, aw, ah)
        pcall(Infinity_SetArea, name .. "_b", ax, ay, aw, ah)
    end
    Infinity_SetArea("bbQuickOutside", 0, 0, sw, sh)
    for _, name in ipairs({"bbQuickBg", "bbQuickBg2", "bbQuickBg3", "bbQuickOverlay"}) do
        setArea(name, x, y, w, h)
    end
    -- Same rect as the background: an inflated frame leaves a see-through
    -- ring between the parchment edge and the rail (see _Layout).
    setArea("bbQuickFrame", x, y, w, h)
    setArea("bbQuickTitle", x + 12, y + 7, w - 24, 24)
    for i = 1, BfBot.MAX_PRESETS do
        setArea("bbQuickPreset" .. i, x + 10, y + 34 + (i - 1) * rowH, w - 20, rowH - 4)
    end
    Infinity_PushMenu("BUFFBOT_QUICK_PRESETS")
end

function BfBot.UI._CastQuickPreset(row)
    local entry = BfBot.UI._quickPresets and BfBot.UI._quickPresets[row]
    BfBot.UI._CloseQuickMenu()
    if not entry or not BfBot.UI._ActionbarVisible() or BfBot.Exec.GetState() == "running" then return end
    local owner = BfBot.Persist._GetProtagonist()
    if not owner or owner.m_id ~= entry.ownerId or BfBot._GetName(owner) ~= entry.ownerName then return end
    local config = BfBot.Persist.GetConfig(owner)
    if not config or config.presets[entry.index] ~= entry.preset then return end
    BfBot.Scan.InvalidateAll()
    BfBot.Persist.DrainBuildSkips()
    local queue = BfBot.Persist.BuildQueueFromPreset(entry.index)
    if not queue or #queue == 0 then
        BfBot.Persist.DrainBuildSkips()
        BfBot._Display(BfBot.L10N.Get("feedback.no_spells_preset"))
        return
    end
    return BfBot.UI._StartRun(queue, BfBot.Persist.GetQuickCast(owner, entry.index), entry.index)
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
    local gapS = 6   -- the spacing used across the header rows
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
        -- "<name>_b" is a plate drawn UNDER a clickable text element, for the
        -- two status toggles that have to stay text items (only a text item
        -- takes an action together with `text color lua`).
        pcall(Infinity_SetArea, name .. "_b", x, y, w, h)
    end

    --- Lay a cluster of controls left to right from `x`, returning where it
    --- ends. Widths are the caption's natural size; the panel grows by moving
    --- the clusters apart, never by stretching a button into a slab.
    local function cluster(x, y, h, gap, items)
        for _, item in ipairs(items) do
            setArea(item[1], x, y, item[2], h)
            x = x + item[2] + gap
        end
        return x - gap
    end

    -- Panel background and the frame drawn on top of it, on the SAME rect.
    -- Three background labels exist (one per theme); only the active theme's
    -- is enabled, but all three need their area updated so theme switches are
    -- seamless.
    --
    -- The frame rect must not be inflated. Pecca's frame is a thin rail lying
    -- flush with the atlas edge over a transparent middle, so a rect larger
    -- than the parchment moves the rail off the panel and leaves a see-through
    -- ring between the two, with the game showing through it. (The old
    -- generated border filled its rect opaquely and drew behind, which is why
    -- it could overhang.) Same rect: rail on the panel edge, corner bosses on
    -- the panel's corners, transparent middle over parchment.
    setArea("bbBg",  px, py, pw, ph)
    setArea("bbBg2", px, py, pw, ph)
    setArea("bbBg3", px, py, pw, ph)
    setArea("bbDarkOverlay", px, py, pw, ph)
    setArea("bbBgFrame", px, py, pw, ph)

    -- Title
    setArea("bbTitle", px, py + 5, pw, 30)

    -- Character tabs + view toggle at the right. The tabs divide the row
    -- between the characters who are actually in the party: dividing it by
    -- six left a party of three with three tab-widths of empty parchment
    -- between the last name and the Summons toggle. Capped, because one
    -- companion must not get a tab the width of the panel.
    local charY = py + 40
    local charH = 24
    local charGap = 4
    local viewW = 100
    local rowW = cw - viewW - charGap   -- tab area shared by both views
    local function visibleCount(names, limit)
        local count = 0
        for i = 1, limit do
            if names and names[i] ~= nil then count = count + 1 end
        end
        return math.max(count, 1)
    end
    local charCount = visibleCount(buffbot_charNames, 6)
    local charW = math.min(math.floor((rowW - (charCount - 1) * charGap) / charCount), 170)
    -- The width is sized for the tabs that exist, but all six slots are
    -- placed, because a slot the party has not filled is only disabled, not
    -- removed. Sizing for two and placing six marched slots 3-6 off the
    -- panel: an area outside the parchment, under the frame and over
    -- whatever stands beside the panel. A slot past the count is parked on
    -- the last real tab, where it is invisible and inside the panel.
    for i = 0, 5 do
        setArea("bbC" .. i, cx + math.min(i, charCount - 1) * (charW + charGap),
            charY, charW, charH)
    end
    setArea("bbView", math.min(cx + charCount * (charW + charGap), cx + cw - viewW),
        charY, viewW, charH)

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

    -- Preset tabs + Rename / New. Sized to the presets that exist, for the
    -- same reason as the character tabs: eight reserved slots put Rename at
    -- the far right of a row holding two tabs. Rename and New follow the
    -- last tab instead of being pinned to the panel edge, so the row reads
    -- as one group however many presets there are.
    local preY = py + 68
    local preH = 24
    local preGap = 3
    local renW = 78
    local newW = 62
    local maxP = BfBot.MAX_PRESETS
    local preAvailW = cw - renW - newW - 2 * preGap
    local preCount = visibleCount(buffbot_presetNames, maxP)
    local preW = math.min(
        math.floor((preAvailW - (preCount - 1) * preGap) / preCount), 170)
    -- Same slot rule as the character tabs above: sized for the presets that
    -- exist, placed for all eight reserved slots, so a slot past the count is
    -- parked on the last real tab instead of leaving the panel.
    for i = 1, maxP do
        setArea("bbP" .. i,
            cx + math.min(i - 1, preCount - 1) * (preW + preGap),
            preY, preW, preH)
    end
    local renX = cx + preCount * (preW + preGap)
    setArea("bbRen", renX, preY, renW, preH)
    setArea("bbNew", renX + renW + preGap, preY, newW, preH)

    -- Search stays separate from preset order. Casting speed belongs beside
    -- it as a global run preference, leaving per-preset Quick Cast below.
    -- Search row: label, the inset bar, then Clear and the speed toggle at
    -- the right. The bar ends where Clear begins, computed from the two
    -- widths rather than from a stack of literals that had to be kept in
    -- step across four lines.
    local searchY, searchH = py + 98, 26
    local speedW, clearW, labelW = 148, 76, 70
    local clearX = cx + cw - speedW - gapS - clearW
    local barX = cx + labelW + gapS
    setArea("bbSearchLabel", cx, searchY, labelW, searchH)
    setArea("bbSearchBg", barX, searchY, math.max(clearX - gapS - barX, 40), searchH)
    setArea("bbSearch", barX + 8, searchY + 3,
        math.max(clearX - gapS - barX - 16, 24), searchH - 6)
    setArea("bbSearchClear", clearX, searchY, clearW, searchH)
    setArea("bbSpeed", cx + cw - speedW, searchY, speedW, searchH)
    -- Column headers sit in their own strip directly above the list, aligned
    -- to the list's column widths. The engine reserves the scrollbar strip
    -- from the list's content area, so the headers divide what is left of it.
    local hdrY = py + 130
    local hdrH = 20
    local scrollbarW = 16
    local colW = math.max(cw - scrollbarW, 1)
    local function header(name, startPct, widthPct)
        setArea(name, cx + math.floor(colW * startPct / 100), hdrY,
                math.floor(colW * widthPct / 100), hdrH)
    end
    header("bbHName", 16, 26)
    header("bbHDur",  42, 10)
    header("bbHUses", 52, 10)
    header("bbHRep",  62,  8)
    header("bbHTgt",  70, 24)
    header("bbHLock", 94,  6)

    -- Spell list (fills middle area). The footer below is four 28px rows
    -- with 6px between them and 12px of air above the bottom rail; keeping
    -- that arithmetic in one place is what stops the list from growing into
    -- the buttons when a row is added or a height changes.
    local listY = hdrY + hdrH
    local footerH = 12 + 4 * 28 + 3 * 6 + 8   -- edge + rows + gaps + breathing
    -- Whole rows only. The list draws a partial row at the bottom when its
    -- height is not a multiple of `rowheight`, which reads as a spell cut in
    -- half by the parchment. The leftover pixels go above the footer, where
    -- they are just air.
    local rowH = 36                           -- BuffBot.menu: bbList rowheight
    local listH = math.max(ph - 130 - hdrH - footerH, rowH)
    listH = listH - (listH % rowH)
    setArea("bbList", cx, listY, cw, listH)
    setArea("bbSearchEmpty", cx + 10, listY + 8, cw - 20, 28)

    -- ---------------------------------------------------------------
    -- Footer
    -- ---------------------------------------------------------------
    -- The footer is one bar, not four rows of controls pinned to opposite
    -- corners. Pinning looked right at the 550px minimum and fell apart as
    -- the panel grew: the clusters walked to the edges and left a hole the
    -- width of the parchment between them. The bar therefore has a maximum
    -- width and is centred in anything wider, so the controls stay a group
    -- at every size, and every row has a middle zone so the slack lands
    -- between groups rather than in one gap.
    local btnH = 28
    local gap = 6
    local edge = 12                     -- clear air above the bottom rail
    local barW = math.min(cw, 980)
    local bx = cx + math.floor((cw - barW) / 2)
    local bRight = bx + barW
    --- Lay one footer row as a single centred run of groups, scaled to fit.
    ---
    --- Two things shape this. The widths in the calls below are the
    --- captions' natural sizes at the default font, and they add up to more
    --- than the panel's 550px minimum can hold, so a row that does not fit
    --- shrinks every width in it by the same factor -- crowded captions at
    --- the minimum are accepted, controls growing into each other are not.
    --- And the groups stay together in the middle rather than being pinned
    --- to the bar's two edges: pinned, a wide panel showed three buttons at
    --- the far left, two at the far right and a hand's width of empty
    --- parchment between them.
    local groupGap = 28                 -- the seam between two groups
    -- A row that does not fit narrows its plates; the captions are separate
    -- labels and have to narrow with them, or they print over the plate
    -- beside them and the click lands on that one instead. Collected here
    -- and applied in one pass once every row is placed.
    local captionScales = {}
    local function row(y, ...)
        local groups = {}
        local count, widths = 0, 0
        -- select, not ipairs({...}): a nil group (a row with no middle)
        -- is a hole that ipairs stops at, and the groups after it would
        -- silently never be placed.
        for index = 1, select("#", ...) do
            local group = select(index, ...)
            if group and #group > 0 then
                groups[#groups + 1] = group
                for _, item in ipairs(group) do
                    count = count + 1
                    widths = widths + item[2]
                end
            end
        end
        if #groups == 0 then return end

        -- The gaps and the seams are fixed air; only the controls give way.
        local seams = #groups - 1
        local budget = barW - (count - #groups) * gap - seams * groupGap
        local scale = (widths > budget and budget > 0) and (budget / widths) or 1

        local total, scaled = seams * groupGap, {}
        for index, group in ipairs(groups) do
            local fitted = {}
            for i, item in ipairs(group) do
                fitted[i] = { item[1], math.max(math.floor(item[2] * scale), 24) }
                -- The caption follows the plate it actually got, not the
                -- row's factor: the 24px floor above means a narrow plate
                -- can keep more width than `scale` asked for.
                captionScales[item[1]] = fitted[i][2] / item[2]
                total = total + fitted[i][2] + (i > 1 and gap or 0)
            end
            scaled[index] = fitted
        end

        local x = bx + math.floor((barW - total) / 2)
        for _, group in ipairs(scaled) do
            x = cluster(x, y, btnH, gap, group) + groupGap
        end
    end

    local r7Y = py + ph - edge - btnH    -- Status
    local r6Y = r7Y - btnH - gap         -- Cast / Close
    local r5Y = r6Y - btnH - gap         -- Spell actions
    local r4Y = r5Y - btnH - gap         -- Add / Remove / Export / Import

    row(r4Y,
        { { "bbAdd", 150 }, { "bbRmv", 110 }, { "bbRepeat", 100 } },
        nil,
        { { "bbExp", 92 }, { "bbImp", 92 } })

    -- Normal layout: reorder and sort sit in the middle, which is what
    -- fills the row instead of leaving Sort stranded left of a long gap.
    row(r5Y,
        { { "bbTog", 112 }, { "bbTgt", 142 } },
        { { "bbUp", 66 }, { "bbDn", 66 }, { "bbSort", 66 }, { "bbOrder", 162 } },
        { { "bbDel", 142 } })

    -- Variant layout: the same shape with the Variant picker beside Target.
    row(r5Y,
        { { "bbVTog", 112 }, { "bbVTgt", 142 }, { "bbVVar", 142 } },
        { { "bbVUp", 66 }, { "bbVDn", 66 }, { "bbVSort", 66 }, { "bbVOrder", 162 } },
        { { "bbVDel", 142 } })

    row(r6Y,
        { { "bbCast", 98 }, { "bbCastChar", 152 }, { "bbStop", 70 } },
        nil,
        { { "bbQC", 240 }, { "bbClose", 86 } })

    -- The status line reads as prose, so it keeps the panel's own width
    -- rather than the bar's. The active-buff toggle is a control and stays
    -- in the bar with the rest of them.
    -- The toggle is centred like the rows above it; pinned to the bar's
    -- right edge it was the one control left hanging out there once the
    -- other rows moved to the middle.
    local forceW = math.min(182, barW)
    local forceX = bx + math.floor((barW - forceW) / 2)
    setArea("bbForce", forceX, r7Y, forceW, btnH)
    -- The status line runs from the panel edge to wherever the toggle starts.
    -- Giving it the panel's width minus the toggle's would reach past the
    -- toggle whenever the bar is narrower than the panel, and the status text
    -- would print straight through it.
    setArea("bbStatus", cx, r7Y, math.max(forceX - gap - cx, 1), btnH)

    -- Drag handle covers title bar area
    setArea("bbDragHandle", px, py, pw, 35)

    -- Resize grip visual + handle at bottom-right corner
    setArea("bbResizeGrip", px + pw - 20, py + ph - 20, 20, 20)
    setArea("bbResizeHandle", px + pw - 80, py + ph - 48, 80, 48)

    -- Reset button in title bar (right-aligned, 50px wide)
    setArea("bbReset", px + pw - 76, py + 5, 64, 24)

    -- One pass over the captions once every plate has its width. It also
    -- restores the ones this layout did not narrow, so widening the panel
    -- gives their full size back.
    if BfBot.Theme and BfBot.Theme.ApplyCaptionScales then
        BfBot.Theme.ApplyCaptionScales(captionScales)
    end
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

    BfBot.UI._ResizeTo((BfBot.UI._panelW or math.floor(sw * 0.8)) + dx,
        (BfBot.UI._panelH or math.floor(sh * 0.8)) + dy)
end

--- Resize the panel to `pw` x `ph`, enforcing the minimums, the screen and the
--- background textures. The drag handler is one caller; the screenshot lab is
--- another, so a size can be set without faking a mouse drag.
function BfBot.UI._ResizeTo(pw, ph)
    local sw, sh = Infinity_GetScreenSize()
    if not sw or not sh then return end

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
    BfBot.UI._CloseQuickMenu()
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
    BfBot.UI._spellListRefreshPending = nil
    BfBot.UI._SaveLayout()
end

-- ============================================================
-- Data Population
-- ============================================================

--- Refresh all UI state from Persist + Scan data.
-- Called on: panel open, tab switch, spell change listeners.
-- Tab switches do NOT invalidate scan cache — reads cached data.
function BfBot.UI._Refresh()
    BfBot.UI._spellListRefreshPending = nil
    BfBot.UI._RefreshForceRecastCache()
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
--- absent lock reads as 0, which the summon schema guarantees; tgtUnlock is
--- optional in both views).
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
        -- Targeting follows the EFFECTIVE spell: a selected variant is cast
        -- directly at the resolved target, while the opcode-214 parent is
        -- only the engine's self-cast selection wrapper and would otherwise
        -- lock every variant row to "Self only" (#82).
        local effIsAoE = scan and scan.isAoE or 0
        local effIsSelfOnly = scan and scan.isSelfOnly or 0
        if varResref and variants then
            local variant = BfBot.Class.FindVariant(variants, varResref)
            if variant then
                variantName = variant.name
                if variant.isSelfOnly ~= nil then
                    effIsSelfOnly = variant.isSelfOnly
                end
                if variant.isAoE ~= nil then effIsAoE = variant.isAoE end
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
            countText = scan and scan.requiresChoice == 1 and BfBot.L10N.Get("ui.manual_only")
                or (count > 0 and ("x" .. count) or "--"),
            requiresChoice = scan and scan.requiresChoice or 0,
            rep      = rep,
            repeatText = repeatDisplay.compact,
            on       = spellCfg.on or 0,
            targetText = targetText,
            targetButtonText = _TargetButtonDisplay(targetText),
            tgt      = spellCfg.tgt or "p",
            castable = isCastable,
            pri      = spellCfg.pri or 999,
            ovr      = (ovr and ovr[resref]) or 0,
            isAoE    = effIsAoE,
            isSelfOnly = effIsSelfOnly,
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
    -- With the preset's order toggle on, the list is shown in the order it
    -- will actually be cast in. The stored priorities are left alone, so
    -- switching the toggle off gives the player's own order straight back.
    if BfBot.Persist.IsAutoOrder(preset) then
        rows = BfBot.Persist.OrderByDuration(rows)
    end
    return rows
end

--- Summons-view refresh: summon tab labels, preset tabs (names come from the
--- protagonist's config — the preset axis is shared across views), and the
--- selected summon's preset spell table. All config reads/writes go to the
--- summon preset on the protagonist (summon spell entry: {on, tgt, pri,
--- rep, var?, tgtUnlock?}); the summon SPRITE never gets a config of its own.
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
    -- schema: on/tgt/pri/rep (no lock; tgtUnlock is written on demand by
    -- the picker's Unlock button, never seeded here).
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
--- entries follow the summon schema (on/tgt/pri/rep).
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
    -- Availability is transient; preset configuration remains editable for
    -- a later rest or when the spell otherwise becomes available again.
    if not entry then return end

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
    if BfBot.Theme.HasControlArt() then return "" end
    local name = buffbot_pickerOrder[row]
    if not name then return "" end
    if buffbot_pickerChecked[name] then return "[X]" end
    return "[ ]"
end

--- The checkbox cycle for a picker row: ticked, empty, or the greyed tick
--- while targeting is locked. Same art and same cycles as the spell list.
function BfBot.UI._PickerCheckSeq(row)
    local name = buffbot_pickerOrder[row]
    local checked = name ~= nil and buffbot_pickerChecked[name] ~= nil
    if buffbot_targetLocked == 1 then return checked and 2 or 1 end
    return checked and 0 or 1
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
    -- While targeting is locked the rows are shown, not hidden, so the
    -- player can see what unlocking would offer. They read as unavailable.
    if buffbot_targetLocked == 1 then
        return BfBot.UI._T("pickerOff")
    end
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
    if buffbot_targetLocked == 1 then return end
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
--- summon spell entry (tgt stays "s"/"p"/name/ordered table).
function BfBot.UI._SetSpellTargetForView(sprite, resref, tgt)
    if BfBot.UI._view == "summons" then
        local se = BfBot.UI._SummonSpellEntry(resref, 1)
        if se then se.tgt = tgt end
        return
    end
    BfBot.Persist.SetSpellTarget(sprite, BfBot.UI._presetIdx, resref, tgt)
end

--- View-routed tgtUnlock write (#82). Summon spell entries carry the same
--- optional 0/1 field as party entries, so the summons view has the same
--- escape hatch for spells the classifier reports as self-only / party-wide.
function BfBot.UI._SetTgtUnlockForView(sprite, resref, value)
    local normalized = (value == 1) and 1 or 0
    if BfBot.UI._view == "summons" then
        local se = BfBot.UI._SummonSpellEntry(resref, 1)
        if se then se.tgtUnlock = normalized end
        return
    end
    BfBot.Persist.SetTgtUnlock(sprite, BfBot.UI._presetIdx, resref, normalized)
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
--- A still-locked spell closes WITHOUT writing: every control that could
--- have produced a checked name was disabled, so the empty working copy
--- carries no intent and must not overwrite the stored target with the
--- classifier default (#82).
function BfBot.UI.PickerDone()
    if buffbot_targetLocked == 1 then
        BfBot.UI._targetSpellAnchor = nil
        Infinity_PopMenu("BUFFBOT_TARGETS")
        return
    end
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

--- Unlock targeting for a locked spell. Available in BOTH views (#82): the
--- summon spell entry carries the same optional tgtUnlock field, and without
--- it a self-only/party-wide classification was a permanent dead end in the
--- summons view — every control in the picker is gated on the lock.
function BfBot.UI.PickerUnlock()
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

    BfBot.UI._SetTgtUnlockForView(sprite, entry.resref, 1)
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
--- The selected active-buff policy (BfBot.Exec.GetForceMode) rides along on
--- every run started here, which is why Cast All, Cast Character, the HUD
--- preset picker and the summons cast all honor the toggle without each path
--- repeating it. Only a raw console queue runs with the RefreshBelow option
--- alone.
function BfBot.UI._StartRun(queue, qcMode, presetIdx)
    local rate = BfBot.UI._FastForwardRate()
    -- Guarded like the tooltip's threshold read: this module can be
    -- force-reloaded on its own against an older BfBotExe, and a cast button
    -- that hard-errors would be worse than falling back to the safe mode.
    local forceMode = 0
    if BfBot.Exec.GetForceMode then
        local ok, mode = pcall(BfBot.Exec.GetForceMode)
        if ok and type(mode) == "number" then forceMode = mode end
    end
    local started, reason, detail
    if rate > 1 then
        if BfBot.Fast and BfBot.Fast.Start then
            started, reason, detail = BfBot.Fast.Start(queue, rate, presetIdx,
                forceMode)
        else
            started, reason = false, "reason.exec.fast_unavailable"
        end
    else
        started, reason, detail = BfBot.Exec.Start(queue, qcMode, presetIdx,
            forceMode)
    end
    if started then
        BfBot.UI._SurfaceBuildSkips()
    else
        BfBot.Persist.DrainBuildSkips()
        if reason == "reason.exec.fast_unavailable" then
            BfBot._Display(BfBot.L10N.Get("reason.exec.fast_unavailable"))
            if detail and detail.reason then BfBot._Warn("Fast-forward: " .. tostring(detail.reason)) end
        end
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

local function _requestSpellListRefresh()
    if BfBot.FiveE and BfBot.FiveE.IsInstalled and BfBot.FiveE.IsInstalled() then
        -- 5E removes/regrants many abilities per cast. Let the engine finish
        -- that batch before rebuilding the panel once on its next update.
        BfBot.UI._spellListRefreshPending = true
    else
        BfBot.UI._Refresh()
    end
end

function BfBot.UI._SpellListRefreshTick()
    if not BfBot.UI._spellListRefreshPending then return false end
    -- Clear before refreshing: a notification during the refresh belongs to
    -- the next update and must not recursively rebuild the panel.
    BfBot.UI._spellListRefreshPending = nil
    if buffbot_isOpen then BfBot.UI._Refresh() end
    return false
end

function BfBot.UI._OnSpellListChanged(sprite, resref, changeAmount)
    BfBot.Scan.Invalidate(sprite)
    if not BfBot.UI._IsBuffBotGeneratedResref(resref)
        and BfBot.UI._IsDisplayedSpellEventSprite(sprite) then
        _requestSpellListRefresh()
    end
end

function BfBot.UI._OnSpellCountsReset(sprite)
    BfBot.Scan.Invalidate(sprite)
    if BfBot.UI._IsDisplayedSpellEventSprite(sprite) then _requestSpellListRefresh() end
end

function BfBot.UI._OnSpellRemoved(sprite, resref)
    BfBot.Scan.Invalidate(sprite)
    if not BfBot.UI._IsBuffBotGeneratedResref(resref)
        and BfBot.UI._IsDisplayedSpellEventSprite(sprite) then
        _requestSpellListRefresh()
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
    BfBot.UI._CaptureSpellSelection(target, true)
    BfBot.UI._RestoreSpellSelection()
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
    BfBot.UI._CaptureSpellSelection(target, true)
    BfBot.UI._RestoreSpellSelection()
end

--- Sort the current preset's spell list by duration (longest first).
--- Locked spells stay at their current row index. Unlocked spells fill
--- the remaining rows in duration-desc order. Persists via _RenumberPriorities.
--- Reorder the visible rows once, by hand, and keep the result.
---
--- The same rule the per-preset order toggle applies on every refresh --
--- `BfBot.Persist.OrderByDuration` is the one implementation, so the button
--- and the toggle can never drift apart. The difference is that this writes
--- the new order back into the preset: it is the player reordering their
--- own list, not a view of it.
function BfBot.UI.SortByDuration()
    if #buffbot_spellTable == 0 then return end
    if BfBot.UI._IsAutoOrder() then return end
    BfBot.UI._PrepareSpellSelectionForRebuild()
    buffbot_spellTable = BfBot.Persist.OrderByDuration(buffbot_spellTable)
    BfBot.UI._RenumberPriorities()
    BfBot.UI._RestoreSpellSelection()
end

--- True when the preset on screen casts longest-duration-first.
function BfBot.UI._IsAutoOrder()
    if BfBot.UI._view == "summons" then return false end
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return false end
    return BfBot.Persist.GetAutoOrder(sprite, BfBot.UI._presetIdx) == 1
end

--- Flip it, for the whole party's preset of that index. Presets are
--- parallel across characters, so an order that applied to one of them
--- would make "Pre-Battle" mean two different things in one party.
function BfBot.UI.ToggleAutoOrder()
    if BfBot.UI._view == "summons" then return end
    local sprite = BfBot.UI._GetSelectedSprite()
    if not sprite then return end
    local now = BfBot.Persist.GetAutoOrder(sprite, BfBot.UI._presetIdx)
    BfBot.Persist.SetAutoOrderAll(BfBot.UI._presetIdx, now == 1 and 0 or 1)
    BfBot.UI._Refresh()
end

function BfBot.UI._AutoOrderLabel()
    if BfBot.UI._IsAutoOrder() then
        return BfBot.L10N.Get("ui.order.duration")
    end
    return BfBot.L10N.Get("ui.order.manual")
end

function BfBot.UI._AutoOrderTooltip()
    if BfBot.UI._IsAutoOrder() then
        return BfBot.L10N.Get("ui.order.tooltip_duration")
    end
    return BfBot.L10N.Get("ui.order.tooltip_manual")
end

function BfBot.UI._AutoOrderColor()
    return BfBot.UI._T(BfBot.UI._IsAutoOrder() and "qcLong" or "btnText")
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
--- (recovery from accidental Remove), plus supported item powers retained
--- by the scanner when classification missed them. Interactive item powers
--- remain visibly manual-only. The list is sectioned by kind - a [Spells]
--- header row, spell rows, an [Items] header row, item rows; empty sections
--- are omitted. Excluded entries sort to the top of their section.
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
        -- Ordinary classifier misses are manually addable. Process-global
        -- overrides from another character must not leak into this picker.
        if scan.kind == "itm" and scan.class.overridden and ovr == nil then
            goto nextSpell
        end
        if scan.class.isBuff and ovr ~= -1 then
            goto nextSpell
        end

        table.insert(scan.kind == "itm" and items or spells, {
            resref   = resref,
            kind     = scan.kind,
            name     = scan.name or resref,
            icon     = scan.icon or "",
            durCat   = scan.durCat or "?",
            durCatText = scan.requiresChoice == 1 and BfBot.L10N.Get("ui.manual_only")
                or BfBot.UI._CategoryText(scan.durCat),
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
    if not entry then return BfBot.UI._T("text") end
    if entry.castable == 0 then return BfBot.UI._T("textMuted") end
    if entry.ovr == 1 then return BfBot.UI._T("textAccent") end
    if entry.kind == "itm" and entry.lock ~= 1 then
        return BfBot.UI._T("itemColor")
    end
    if entry.lock == 1 then return BfBot.UI._T("spellLocked") end
    return BfBot.UI._T("text")
end

function BfBot.UI._SpellRowTooltip(row)
    local entry = buffbot_spellTable[row]
    if not entry then return "" end
    if entry.requiresChoice == 1 then return BfBot.L10N.Get("reason.item.manual_selection") end
    return entry.name or entry.resref
end

--- Picker name color: section-header tint for header rows, bronze tint for
--- item rows, normal text tint for spell rows.
function BfBot.UI._PickerNameColor(row)
    local entry = buffbot_pickerSpells[row]
    if not entry then return BfBot.UI._T("text") end
    if entry.isHeader then return BfBot.UI._T("headerSub") end
    if entry.kind == "itm" then return BfBot.UI._T("itemColor") end
    return BfBot.UI._T("text")
end

--- Repeat column color: repeated casts use the theme accent. A single cast
--- follows the normal spell-row color, including muted unavailable rows.
function BfBot.UI._RepeatColor(row)
    local entry = buffbot_spellTable[row]
    if not entry then return BfBot.UI._T("text") end
    local rep = BfBot.Persist._NormalizeSpellRepeat(entry.rep)
    if rep > 1 then return BfBot.UI._T("textAccent") end
    if entry.castable == 0 then return BfBot.UI._T("textMuted") end
    return BfBot.UI._T("text")
end

-- ============================================================
-- Panel chrome art
-- ============================================================
-- Buttons, tabs and the cast plate carry Pecca's art instead of the engine's
-- carved stone. Each helper returns the running game's own button BAM
-- (BfBot.Theme.ButtonBam: GUIBUTMT on IWD:EE, GUIOSTUL elsewhere) when the
-- art is absent, so a partial install keeps a working panel rather than
-- invisible buttons or IWD:EE's unrelated GUIOSTUL frames.
--
-- The art is one cycle per skin (0 SoD, 1 IWD, 2 BG1, 3 BG2) with four state
-- frames inside it. Plain buttons leave `frame` alone and let the engine run
-- its own hover/press states; a tab forces the frame, because "this tab is
-- the open one" is not a state the engine knows about.

--- Wide plate for a captioned button.
function BfBot.UI._PlateBam()
    return BfBot.Theme.HasChromeArt() and "BFBPLAT" or BfBot.Theme.ButtonBam()
end

--- Tab plate. Its selected frame carries the skin's accent outline.
function BfBot.UI._TabBam()
    return BfBot.Theme.HasChromeArt() and "BFBTAB" or BfBot.Theme.ButtonBam()
end

--- The caption colour for a button whose own `clickable` gate is `active`.
--- Footer buttons stay on screen when they cannot be used -- hiding them
--- left holes in the bar and moved the neighbours around -- so the caption
--- has to grey out with the plate. A label has no `clickable` of its own.
function BfBot.UI._CaptionColor(active)
    local on = active ~= nil and active ~= false and active ~= 0
    return BfBot.UI._T(on and "btnText" or "btnTextOff")
end

--- True when the 9-slice frame actually draws. Its bottom-right corner boss
--- then sits exactly where the resize grip's "///" used to be printed, so the
--- hint is dropped and the boss marks the corner instead. Without the art the
--- corner is bare parchment and the hint is the only thing that marks it.
function BfBot.UI._HasFrameArt()
    return BfBot.UI._borderOk == true
end

--- The inset bar behind the search box.
function BfBot.UI._SearchBam()
    return BfBot.Theme.HasChromeArt() and "BFBSEAR" or ""
end

--- The wider plate behind Cast and Cast Character.
function BfBot.UI._CastBam()
    return BfBot.Theme.HasChromeArt() and "BFBCAST" or BfBot.Theme.ButtonBam()
end

--- Cycle index for every chrome BAM: the skin. The engine art has one cycle,
--- so it must stay at 0 when the themed art is missing.
function BfBot.UI._ChromeSeq()
    if not BfBot.Theme.HasChromeArt() then return 0 end
    return BfBot.Theme.ControlSkin()
end

--- Frame for a tab. Pecca's selected frame is the third in the cycle; the
--- engine's button (either game's) marks a pressed tab with its second.
function BfBot.UI._TabFrame(selected)
    if not selected then return 0 end
    return BfBot.Theme.HasChromeArt() and 2 or 1
end

--- Checkbox display: "+" for enabled, empty for disabled.
-- The checkbox and lock cells render as art when buffbot/visual is installed
-- and fall back to text markers when it is not (see BfBot.Theme.HasControlArt).
-- Both the text label and the BAM label exist in the column; each blanks itself
-- in the other's case, so exactly one is ever visible.

function BfBot.UI._CheckboxText(row)
    if BfBot.Theme.HasControlArt() then return "" end
    local entry = buffbot_spellTable[row]
    if entry and entry.on == 1 then return "[X]" end
    return "[ ]"
end

--- Checkbox art for the active skin, or "" to leave the cell to the text.
function BfBot.UI._CheckBam()
    if not BfBot.Theme.HasControlArt() then return "" end
    return "BFBCHK" .. BfBot.Theme.ControlSkin()
end

--- BFBCHK cycle 0 is the skin's check mark, cycle 1 its empty box.
function BfBot.UI._CheckSeq(row)
    local entry = buffbot_spellTable[row]
    return (entry and entry.on == 1) and 0 or 1
end

--- Lock art: the "blocked" glyph on locked rows only. An unlocked row stays
--- empty rather than showing a second box — the column header names it, and
--- the glyph sheet has no neutral "unlocked" symbol to pair with it.
--- The socket drawn behind the lock glyph on a locked row.
--- BFBGLYPH is light line art meant for the dark plates; on parchment it
--- was a cream outline on cream and all but invisible. The checkbox
--- column's empty well is the right size and the same visual language, so
--- the glyph sits in one of those.
function BfBot.UI._LockPlateBam(row)
    return (BfBot.UI._LockBam(row) ~= "") and BfBot.UI._CheckBam() or ""
end

function BfBot.UI._LockBam(row)
    if not BfBot.Theme.HasControlArt() then return "" end
    if BfBot.UI._view == "summons" then return "" end
    local entry = buffbot_spellTable[row]
    if not entry or entry.lock ~= 1 then return "" end
    return "BFBGLYPH"
end

--- Lock column display text. The summons view has no lock feature (the v9
--- summon spell-entry schema has no lock field) — the column stays blank.
function BfBot.UI._LockText(row)
    if BfBot.UI._view == "summons" then return "" end
    if BfBot.Theme.HasControlArt() then return "" end
    local entry = buffbot_spellTable[row]
    if entry and entry.lock == 1 then
        return BfBot.L10N.Get("ui.lock.compact")
    end
    return "[ ]"
end

--- Lock column color: gold when locked, muted otherwise.
function BfBot.UI._LockColor(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.lock == 1 then return BfBot.UI._T("lockActive") end
    return BfBot.UI._T("lockInactive")
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
    if BfBot.UI._FastForwardRate() > 1 then return end
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
    if BfBot.UI._FastForwardRate() > 1 then return BfBot.L10N.Get("ui.quick_cast.suspended") end
    local qc = BfBot.UI._ViewQuickCast()
    if qc == 1 then return BfBot.L10N.Get("ui.quick_cast.long") end
    if qc == 2 then return BfBot.L10N.Get("ui.quick_cast.all") end
    return BfBot.L10N.Get("ui.quick_cast.off")
end

function BfBot.UI._QuickCastColor()
    if BfBot.UI._FastForwardRate() > 1 then return BfBot.UI._T("textMuted") end
    local qc = BfBot.UI._ViewQuickCast()
    if qc == 1 then return BfBot.UI._T("qcLong") end
    if qc == 2 then return BfBot.UI._T("qcAll") end
    return BfBot.UI._T("qcOff")
end

function BfBot.UI._QuickCastTooltip()
    if BfBot.UI._FastForwardRate() > 1 then return BfBot.L10N.Get("ui.quick_cast.tooltip_suspended") end
    local qc = BfBot.UI._ViewQuickCast()
    if qc == nil then
        return BfBot.L10N.Get("ui.quick_cast.tooltip_unavailable")
    end
    if qc == 1 then return BfBot.L10N.Get("ui.quick_cast.tooltip_long") end
    if qc == 2 then return BfBot.L10N.Get("ui.quick_cast.tooltip_all") end
    return BfBot.L10N.Get("ui.quick_cast.tooltip_off")
end

-- ============================================================
-- Global simulation speed (per-preset Quick Cast remains saved separately).
function BfBot.UI._FastForwardRate()
    local rate = BfBot.Persist.GetPref and BfBot.Persist.GetPref("FastForward") or 1
    return (rate == 2 or rate == 4) and rate or 1
end

function BfBot.UI.CycleFastForward()
    if BfBot.Exec.GetState() == "running" then return end
    local rate = BfBot.UI._FastForwardRate()
    BfBot.Persist.SetPref("FastForward", rate == 1 and 2 or rate == 2 and 4 or 1)
end

function BfBot.UI._FastForwardLabel()
    local rate = BfBot.UI._FastForwardRate()
    if rate == 2 then return BfBot.L10N.Get("ui.speed.2x") end
    if rate == 4 then return BfBot.L10N.Get("ui.speed.4x") end
    return BfBot.L10N.Get("ui.speed.normal")
end

function BfBot.UI._FastForwardTooltip()
    return BfBot.L10N.Get("ui.speed.tooltip")
end

-- Force Re-Cast (active-buff policy for the next run, issue #84)
-- ============================================================

--- Cached "Refresh Low" tooltip. The threshold it names lives in baldur.ini,
--- and `tooltip lua` is evaluated per frame, so reading the INI inside the
--- tooltip would hit the file on every draw. The cache is rebuilt on panel
--- refresh and on every click — the only moments the threshold can have
--- changed, because the option itself sits in the EEex options menu, which is
--- reachable only while this panel is closed.
local _forceLowTooltip = nil
local _forceLowSeconds = nil

function BfBot.UI._RefreshForceRecastCache()
    -- Exec owns the threshold and is the only authority the run itself uses.
    -- Falling back to the constant keeps the tooltip readable when Exec has
    -- not loaded yet; it cannot change what a run actually skips.
    local seconds
    if BfBot.Exec and BfBot.Exec._RefreshThreshold then
        local ok, value = pcall(BfBot.Exec._RefreshThreshold, 1)
        if ok then seconds = value end
    end
    if type(seconds) ~= "number" or seconds ~= seconds
        or seconds == math.huge then
        seconds = BfBot.REFRESH_LOW_SECONDS
    end
    seconds = math.floor(seconds)
    if _forceLowSeconds == seconds and _forceLowTooltip then return end
    _forceLowSeconds = seconds
    _forceLowTooltip = BfBot.L10N.Format("ui.force_recast.tooltip_low",
        { seconds = seconds })
end

--- The mode this control displays. Exec is the single source of truth; the
--- fallback only keeps the panel drawable if Exec has not loaded yet.
local function _forceMode()
    if BfBot.Exec and BfBot.Exec.GetForceMode then
        local ok, mode = pcall(BfBot.Exec.GetForceMode)
        if ok and type(mode) == "number" then return mode end
    end
    return 0
end

--- Cycle the active-buff policy: skip active → refresh low → force all.
--- Unlike Quick Cast this writes nothing: Exec holds the value for the next
--- run only, so no preset and no save changes.
function BfBot.UI.CycleForceRecast()
    if BfBot.Exec and BfBot.Exec.CycleForceMode then
        pcall(BfBot.Exec.CycleForceMode)
    end
    BfBot.UI._RefreshForceRecastCache()
end

function BfBot.UI._ForceRecastLabel()
    if not buffbot_isOpen then return "" end
    local mode = _forceMode()
    if mode == 1 then return BfBot.L10N.Get("ui.force_recast.low") end
    if mode == 2 then return BfBot.L10N.Get("ui.force_recast.all") end
    return BfBot.L10N.Get("ui.force_recast.off")
end

--- Reuses the Quick Cast palette entries deliberately: both controls answer
--- "how much is BuffBot allowed to do here", so off/warn/cheat read the same.
function BfBot.UI._ForceRecastColor()
    local mode = _forceMode()
    if mode == 1 then return BfBot.UI._T("qcLong") end
    if mode == 2 then return BfBot.UI._T("qcAll") end
    return BfBot.UI._T("qcOff")
end

function BfBot.UI._ForceRecastTooltip()
    local mode = _forceMode()
    if mode == 2 then return BfBot.L10N.Get("ui.force_recast.tooltip_all") end
    if mode == 1 then
        -- Names the threshold the run will really use: the option's value
        -- when it is set, the built-in fallback when it is off.
        if not _forceLowTooltip then BfBot.UI._RefreshForceRecastCache() end
        return _forceLowTooltip
    end
    return BfBot.L10N.Get("ui.force_recast.tooltip_off")
end

-- ============================================================
-- Debug Mode Toggle
-- ============================================================

function BfBot.UI.ToggleDebug()
    BfBot._debugMode = (BfBot._debugMode == 1) and 0 or 1
    Infinity_SetINIValue("BuffBot", "Debug", BfBot._debugMode)
    BfBot._Display("BuffBot: Debug mode " .. (BfBot._debugMode == 1 and "ON" or "OFF"))
end
