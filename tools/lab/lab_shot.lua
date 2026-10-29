-- lab_shot.lua -- put the BuffBot panel into a known state and capture it.
--
-- Two phases, each its own Remote Console request, because Infinity_TakeScreenshot()
-- captures the frame that is drawn next: the prepare phase must have been rendered
-- before the capture phase queues the shot.
--
--   assert(loadfile("<this file>"))({phase = "prepare", theme = "bg2_light",
--                                    slot = 0, preset = 1, enable = {1,2,3},
--                                    lock = 2, order = 1})
--   assert(loadfile("<this file>"))({phase = "capture"})
--
-- The PNG lands in the lab profile's ScrnShot folder. Nothing is cast, saved or
-- loaded here; the theme preference is written to the lab's baldur.ini only.

local args = ... or {}
-- Engine predicates answer with booleans, nil or 0, and 0 is true in Lua.
local function on(name)
    local v = Infinity_IsMenuOnStack(name)
    return v ~= nil and v ~= false and v ~= 0
end

assert(BfBot and BfBot.UI and BfBot.Theme and BfBot.Persist, "SHOT_BUFFBOT_REQUIRED")
assert(e and worldScreen and e:GetActiveEngine() == worldScreen, "SHOT_ACTIVE_ENGINE_IS_NOT_WORLD")
assert(on("WORLD_ACTIONBAR") and not on("START_MAIN"), "SHOT_WORLD_MENU_REQUIRED")

if args.phase == "capture" then
    local receipt = assert(LabShotReceipt, "SHOT_PREPARATION_REQUIRED")
    assert(not receipt.queued, "SHOT_ALREADY_QUEUED")
    -- Two frames are not enough: a theme the panel has not shown yet brings in a
    -- background MOS the renderer still has to load, and the first frames after the
    -- switch came out without it (lab-verified 2026-10-25).
    assert(Infinity_GetFrameCounter() >= receipt.frame + 20, "SHOT_WAIT_FOR_RENDER")
    assert(on("BUFFBOT_MAIN") and buffbot_isOpen, "SHOT_PANEL_CLOSED")
    if receipt.dialog then
        assert(on(receipt.dialogMenu), "SHOT_DIALOG_CLOSED:" .. receipt.dialogMenu)
    end
    assert(BfBot.Theme._GetAccentName() .. (BfBot.Theme._IsDark() == 1 and "_dark" or "_light")
        == receipt.theme, "SHOT_THEME_CHANGED")
    Infinity_TakeScreenshot()
    receipt.queued = true
    return { queued = true, theme = receipt.theme, frame = Infinity_GetFrameCounter() }
end

assert(args.phase == "prepare", "SHOT_PHASE_REQUIRED")
local theme = assert(args.theme, "SHOT_THEME_REQUIRED")
assert(BfBot.Theme._palettes[theme], "SHOT_UNKNOWN_THEME:" .. tostring(theme))
local slot, preset = args.slot or 0, args.preset or 1
local sprite = assert(EEex_Sprite_GetInPortrait(slot), "SHOT_PARTY_MEMBER_MISSING")
local config = assert(BfBot.Persist.GetConfig(sprite), "SHOT_CONFIG_REQUIRED")
assert(config.presets and config.presets[preset], "SHOT_PRESET_REQUIRED")

local before = { theme = BfBot.Theme._GetAccentName()
    .. (BfBot.Theme._IsDark() == 1 and "_dark" or "_light") }

BfBot.UI._CloseQuickMenu()
-- Apply the theme with the panel closed and open it afterwards, so every shot
-- shows a panel that was built under this theme rather than one repainted while
-- it was open. Switching with the panel open is a separate case worth its own look.
if on("BUFFBOT_MAIN") and before.theme ~= theme then BfBot.UI.Close() end
assert(BfBot.Theme.Apply(theme), "SHOT_THEME_DID_NOT_APPLY")
-- The player's text size, because the footer widths are the captions' natural
-- sizes and a larger font is exactly where a caption outgrows its plate. The
-- lab profile's own value applies when nothing is asked for.
if args.fontSize then
    -- _SetFontSize clamps to [1,3] and returns nothing, so the size is read
    -- back rather than trusted: a typo would otherwise shoot the default.
    BfBot.Theme._SetFontSize(args.fontSize)
    assert(BfBot.Theme._GetFontSize() == args.fontSize,
        "SHOT_FONT_SIZE_REFUSED:" .. tostring(args.fontSize))
end
BfBot.UI.SetChar(slot)
BfBot.UI.SetPreset(preset)
if not on("BUFFBOT_MAIN") then BfBot.UI.Toggle() end
-- An explicit panel size, centred, so one run can show the same panel small
-- and large. Without it the panel keeps whatever size the lab profile saved.
if args.panelW and args.panelH then
    local sw, sh = Infinity_GetScreenSize()
    BfBot.UI._panelX = math.max(0, math.floor((sw - args.panelW) / 2))
    BfBot.UI._panelY = math.max(0, math.floor((sh - args.panelH) / 2))
    BfBot.UI._ResizeTo(args.panelW, args.panelH)
end
-- The preset's cast-order toggle, so one run can show both states.
if args.order ~= nil then
    BfBot.Persist.SetAutoOrderAll(preset, args.order)
    BfBot.UI._Refresh()
end
buffbot_searchText = args.query or ""
BfBot.UI._SearchTick()
assert(on("BUFFBOT_MAIN") and buffbot_isOpen, "SHOT_PANEL_DID_NOT_OPEN")

-- Rows are addressed canonically, the way the list's own handlers do.
local rows = buffbot_spellTable or {}
for _, row in ipairs(args.enable or {}) do
    local entry = rows[row]
    if entry and entry.on ~= 1 and entry.lock ~= 1 then BfBot.UI.ToggleSpell(row) end
end
if args.lock then
    local entry = rows[args.lock]
    assert(entry, "SHOT_LOCK_ROW_MISSING:" .. tostring(args.lock))
    if entry.lock ~= 1 then BfBot.UI.ToggleLock(args.lock) end
end

local visible = {}
for index, entry in ipairs(buffbot_visibleSpells or {}) do
    if index <= 12 then
        local canonical = BfBot.UI._VisibleSpellRow(index)
        visible[index] = { row = canonical, resref = entry.resref, name = entry.name,
                           on = entry.on or 0, lock = entry.lock or 0 }
    end
end

-- One of BuffBot's own dialogs on top of the panel, so the shot covers the
-- chrome the dialogs draw too, not only the main panel's.
if args.dialog == "targets" then
    BfBot.UI.OpenTargets(args.dialogRow or 1)
    assert(on("BUFFBOT_TARGETS"), "SHOT_TARGETS_DID_NOT_OPEN")
elseif args.dialog == "picker" then
    BfBot.UI.OpenSpellPicker()
    assert(on("BUFFBOT_SPELLPICKER"), "SHOT_PICKER_DID_NOT_OPEN")
elseif args.dialog == "rename" then
    BfBot.UI.OpenRename()
    assert(on("BUFFBOT_RENAME"), "SHOT_RENAME_DID_NOT_OPEN")
elseif args.dialog then
    error("SHOT_UNKNOWN_DIALOG:" .. tostring(args.dialog))
end

-- What the captions actually ended up at: the plate's width beside the point
-- size the caption is drawn in. A caption wider than its plate prints over
-- the plate next to it, and a screenshot is a poor instrument for telling
-- 11 points from 12.
-- The remote console stringifies a return value, so this comes back as one
-- line of "name=point@plateWidth" rather than a table.
local function captionReport()
    if not EEex_Menu_Find then return "no-menu-api" end
    local menu = EEex_Menu_Find("BUFFBOT_MAIN")
    local item = menu and menu.items
    local parts = {}
    while item ~= nil do
        local nameOk, name = pcall(function() return item.name:get() end)
        if nameOk and type(name) == "string" and name:sub(-2) == "_t" then
            -- The scale, not the live text.point: the per-render listener
            -- writes the point right before each draw, so reading it here
            -- reports the frame before this layout rather than this one.
            local areaOk, w = pcall(function() return item.area.w end)
            local scale = BfBot.Theme.CaptionScale
                and BfBot.Theme.CaptionScale(name) or 1
            parts[#parts + 1] = name .. "="
                .. string.format("%.2f", scale)
                .. "@" .. tostring(areaOk and w or "?")
        end
        item = item.next
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

-- The panel's own size, which is nil until something saved geometry: a
-- profile that has never dragged or resized the panel leaves _panelW unset
-- and _Layout falls back to 80% of the screen. Reporting that fallback is
-- the point of the line -- reading the nil was an error that killed the run
-- before the first shot on any fresh lab profile.
local panelW, panelH = BfBot.UI._panelW, BfBot.UI._panelH
if not panelW or not panelH then
    local screenW, screenH = Infinity_GetScreenSize()
    panelW = panelW or math.floor((screenW or 0) * 0.8)
    panelH = panelH or math.floor((screenH or 0) * 0.8)
end

LabShotReceipt = {
    frame = Infinity_GetFrameCounter(), theme = theme, before = before,
    captions = captionReport(),
    fontSize = BfBot.Theme._GetFontSize and BfBot.Theme._GetFontSize(),
    slot = BfBot.UI._charSlot, preset = BfBot.UI._presetIdx, view = BfBot.UI._view,
    owner = BfBot._GetName(sprite), rows = #rows, visible = visible,
    screen = { Infinity_GetScreenSize() },
    dialog = args.dialog,
    dialogMenu = args.dialog and ({ targets = "BUFFBOT_TARGETS",
        picker = "BUFFBOT_SPELLPICKER", rename = "BUFFBOT_RENAME" })[args.dialog],
    panel = { BfBot.UI._panelX, BfBot.UI._panelY, panelW, panelH },
}
-- A table comes back from the console as "table: 0x...", so the line that is
-- worth reading is returned as text. LabShotReceipt stays for probing by hand.
return "panel=" .. panelW .. "x" .. panelH
    .. " font=" .. tostring(BfBot.Theme._GetFontSize
        and BfBot.Theme._GetFontSize())
    .. " | " .. LabShotReceipt.captions
