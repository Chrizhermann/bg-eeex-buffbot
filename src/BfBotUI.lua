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

-- Cast button label
buffbot_castLabel = "Cast"

-- Target picker state
buffbot_targetRow = 0            -- which spell row opened the picker
buffbot_multiTarget = 0          -- 1 if current spell is multi-target mode
buffbot_targetHeader = ""        -- header text for target picker (spell name + count)

-- Rename dialog state
buffbot_renameInput = ""

-- ============================================================
-- Initialization (called from M_BfBot.lua listener)
-- ============================================================

function BfBot.UI._OnMenusLoaded()
    -- Load our .menu definitions
    EEex_Menu_LoadFile("BuffBot")

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
        buffbot_castLabel = "Cast"
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
    if not config.presets[BfBot.UI._presetIdx] then
        BfBot.UI._presetIdx = config.ap or 1
    end

    local preset = config.presets[BfBot.UI._presetIdx]
    if not preset then
        buffbot_spellTable = {}
        return
    end

    -- 5. Get castable spells from scanner (uses CACHE — no invalidation here)
    local castable = BfBot.Scan.GetCastableSpells(sprite)

    -- 6. Build spell table from preset config, cross-ref with scan data
    local rows = {}
    for resref, spellCfg in pairs(preset.spells) do
        local scan = castable[resref]
        local name = resref
        local icon = ""
        local count = 0
        local isCastable = 0

        if scan then
            name = scan.name
            icon = scan.icon
            count = scan.count
            isCastable = (count > 0 and not scan.disabled) and 1 or 0
        end

        table.insert(rows, {
            resref   = resref,
            name     = name,
            icon     = icon,
            count    = count,
            countText = count > 0 and ("x" .. count) or "--",
            on       = spellCfg.on or 0,
            targetText = BfBot.UI._TargetToText(spellCfg.tgt),
            tgt      = spellCfg.tgt or "p",
            castable = isCastable,
            pri      = spellCfg.pri or 999,
        })
    end

    -- Sort by priority (ascending: lower = cast first)
    table.sort(rows, function(a, b) return a.pri < b.pri end)
    buffbot_spellTable = rows

    -- 7. Update title, cast label, status
    buffbot_title = "BuffBot - " .. (preset.name or "Preset")
    buffbot_castLabel = "Cast " .. (preset.name or "Preset")
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
-- Spell Toggle (integer path — NO booleans)
-- ============================================================

function BfBot.UI.ToggleSpell(row)
    local entry = buffbot_spellTable[row]
    if not entry or entry.castable == 0 then return end
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
-- Target Picking (single-select + multi-select toggle mode)
-- ============================================================

function BfBot.UI.OpenTargets(row)
    buffbot_targetRow = row
    local entry = buffbot_spellTable[row]
    -- Multi-target mode: single-target spell with count > 1
    if entry and entry.count > 1 then
        buffbot_multiTarget = 1
        buffbot_targetHeader = (entry.name or entry.resref) .. " (x" .. entry.count .. ")"
    else
        buffbot_multiTarget = 0
        buffbot_targetHeader = ""
    end
    Infinity_PushMenu("BUFFBOT_TARGETS")
end

--- Open target picker for the currently selected row (called from external button).
function BfBot.UI.OpenTargetsForSelected()
    if buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable then
        BfBot.UI.OpenTargets(buffbot_selectedRow)
    end
end

--- Pick a target — called from BUFFBOT_TARGETS buttons.
-- In single mode: sets target directly and closes picker.
-- In multi mode: "s"/"p" set directly and close; character slots toggle.
function BfBot.UI.PickTarget(value)
    local row = buffbot_targetRow
    local entry = buffbot_spellTable[row]
    if not entry then return end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end

    if buffbot_multiTarget == 0 or value == "s" or value == "p" then
        -- Single mode, or Self/Party shortcut: set directly and close
        BfBot.Persist.SetSpellTarget(sprite, BfBot.UI._presetIdx, entry.resref, value)
        entry.tgt = value
        entry.targetText = BfBot.UI._TargetToText(value)
        Infinity_PopMenu("BUFFBOT_TARGETS")
    else
        -- Multi mode: toggle this slot in the target list
        local tgt = entry.tgt
        -- Normalize to table if currently a string
        if type(tgt) ~= "table" then
            if tgt and tgt ~= "s" and tgt ~= "p" then
                tgt = {tgt}
            else
                tgt = {}
            end
        end

        -- Toggle: remove if present, add if absent
        local found = false
        local newTgt = {}
        for _, slot in ipairs(tgt) do
            if slot == value then
                found = true
            else
                table.insert(newTgt, slot)
            end
        end
        if not found then
            table.insert(newTgt, value)
        end

        -- Save (use table even if only 1 entry — consistent for multi-copy spells)
        BfBot.Persist.SetSpellTarget(sprite, BfBot.UI._presetIdx, entry.resref, newTgt)
        entry.tgt = newTgt
        entry.targetText = BfBot.UI._TargetToText(newTgt)
    end
end

--- Check if a party slot is in the current multi-target list.
function BfBot.UI._IsTargetChecked(slot)
    local entry = buffbot_spellTable[buffbot_targetRow]
    if not entry then return false end
    local tgt = entry.tgt
    local slotStr = tostring(slot)
    if type(tgt) == "table" then
        for _, v in ipairs(tgt) do
            if v == slotStr then return true end
        end
        return false
    end
    return tgt == slotStr
end

--- Button text for character slot in target picker.
-- In multi mode: shows "[X] Name" or "[ ] Name".
-- In single mode: shows just "Name".
function BfBot.UI._PickerBtnText(slot)
    local name = buffbot_charNames[slot] or ("Player " .. slot)
    if buffbot_multiTarget == 1 then
        if BfBot.UI._IsTargetChecked(slot) then
            return "[X] " .. name
        else
            return "[ ] " .. name
        end
    end
    return name
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
        BfBot.UI._Refresh()
    end
end

--- Delete the current preset for all party members and switch to nearest.
function BfBot.UI.DeleteCurrentPreset()
    local result = BfBot.Persist.DeletePresetAll(BfBot.UI._presetIdx)
    if result then
        -- Switch to first available preset (check current character's config)
        local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
        if sprite then
            local config = BfBot.Persist.GetConfig(sprite)
            if config then
                for i = 1, 5 do
                    if config.presets[i] then
                        BfBot.UI._presetIdx = i
                        break
                    end
                end
            end
        end
        BfBot.UI._Refresh()
    end
end

-- ============================================================
-- Cast / Stop
-- ============================================================

function BfBot.UI.Cast()
    local queue = BfBot.Persist.BuildQueueFromPreset(BfBot.UI._presetIdx)
    if queue then
        BfBot.Exec.Start(queue)
        buffbot_status = BfBot.UI._GetStatusText()
    end
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
    return BfBot.Exec.GetState() == "idle" and #buffbot_spellTable > 0
end

--- Is execution currently running?
function BfBot.UI._IsRunning()
    return BfBot.Exec.GetState() == "running"
end

--- Is a spell row selected?
function BfBot.UI._HasSelection()
    return buffbot_isOpen and buffbot_selectedRow > 0 and buffbot_selectedRow <= #buffbot_spellTable
end

--- Can we create more presets? (fewer than 5 exist)
function BfBot.UI._CanCreatePreset()
    return buffbot_isOpen and buffbot_presetCount < 5
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

--- Spell name color: grey for unavailable, white for normal.
function BfBot.UI._SpellNameColor(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.castable == 0 then
        return {128, 128, 128}
    end
    return {255, 255, 255}
end

--- Checkbox display: "+" for enabled, empty for disabled.
function BfBot.UI._CheckboxText(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.on == 1 then return "[X]" end
    return "[ ]"
end

--- Convert target config value to display text.
-- tgt can be: "s", "p", "1"-"6" (string), or {"1","3","5"} (table of slots).
function BfBot.UI._TargetToText(tgt)
    if tgt == "s" then return "Self"
    elseif tgt == "p" then return "Party"
    elseif type(tgt) == "table" then
        if #tgt == 0 then return "None" end
        if #tgt == 1 then
            local num = tonumber(tgt[1])
            if num and num >= 1 and num <= 6 then
                return buffbot_charNames[num] or ("Player " .. num)
            end
        end
        -- Multiple targets — try comma-joined names, fall back to count
        local names = {}
        for _, slot in ipairs(tgt) do
            local num = tonumber(slot)
            if num and num >= 1 and num <= 6 then
                table.insert(names, buffbot_charNames[num] or ("P" .. num))
            end
        end
        local joined = table.concat(names, ", ")
        if #joined > 20 then
            return #tgt .. " targets"
        end
        return joined
    else
        local num = tonumber(tgt)
        if num and num >= 1 and num <= 6 then
            return buffbot_charNames[num] or ("Player " .. num)
        end
    end
    return "Party"
end

--- Execution status text for the status label.
function BfBot.UI._GetStatusText()
    local state = BfBot.Exec.GetState()
    if state == "running" then return "Casting..."
    elseif state == "done" then return "Done"
    elseif state == "stopped" then return "Stopped"
    else return "" end
end
