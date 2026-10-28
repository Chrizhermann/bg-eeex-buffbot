-- lab_rowprobe.lua -- measure the panel's shared character row in a running
-- game and exercise the switches that live in it.
--
--   assert(loadfile("<this file>"))()
--
-- The offline geometry tests drive _Layout through a Lua harness; this reads
-- the areas the engine actually holds, and round-trips the view toggle and the
-- character tabs. It changes the view and the selected character and puts both
-- back; nothing is cast, saved or written to disk.
--
-- The remote console stringifies a return value, so the result comes back as
-- one line of text rather than a table.

assert(BfBot and BfBot.UI, "PROBE_BUFFBOT_REQUIRED")
assert(e and worldScreen and e:GetActiveEngine() == worldScreen,
    "PROBE_ACTIVE_ENGINE_IS_NOT_WORLD")

local function on(name)
    local v = Infinity_IsMenuOnStack(name)
    return v ~= nil and v ~= false and v ~= 0
end

local openedHere = false
if not on("BUFFBOT_MAIN") then
    BfBot.UI.Toggle()
    openedHere = true
end
assert(on("BUFFBOT_MAIN") and buffbot_isOpen, "PROBE_PANEL_DID_NOT_OPEN")

-- Every item's live area, read off the menu the engine is holding.
local areas = {}
do
    local menu = assert(EEex_Menu_Find("BUFFBOT_MAIN"), "PROBE_MENU_NOT_FOUND")
    local item = menu.items
    while item ~= nil do
        local ok, name = pcall(function() return item.name:get() end)
        if ok and type(name) == "string" then
            local okArea, a = pcall(function()
                return { item.area.x, item.area.y, item.area.w, item.area.h }
            end)
            if okArea then areas[name] = a end
        end
        item = item.next
    end
end

local function overlaps(a, b)
    if not a or not b then return false end
    return a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
        and a[2] < b[2] + b[4] and b[2] < a[2] + a[4]
end

-- The toggle is the one control enabled in both views, so nothing else in the
-- shared row may touch it (#100).
local row = { "bbC0", "bbC1", "bbC2", "bbC3", "bbC4", "bbC5",
              "bbS0", "bbS1", "bbS2", "bbS3", "bbS4", "bbS5",
              "bbSPrev", "bbSPage", "bbSNext", "bbSEmpty" }
local covers = {}
for _, name in ipairs(row) do
    if overlaps(areas.bbView, areas[name]) then
        covers[#covers + 1] = name
    end
end

-- The switches themselves: each one has to land and come back.
local startView, startSlot = BfBot.UI._view, BfBot.UI._charSlot
BfBot.UI.ToggleView()
local toSummons = BfBot.UI._view
BfBot.UI.ToggleView()
local backToParty = BfBot.UI._view

local charCount = BfBot.UI._VisibleCount(buffbot_charNames, 6)
local other = (startSlot == 0 and charCount > 1) and 1 or 0
BfBot.UI.SetChar(other)
local switched = BfBot.UI._charSlot
BfBot.UI.SetChar(startSlot)
local restored = BfBot.UI._charSlot

local laid = BfBot.UI._laidOutCounts or {}
if openedHere then BfBot.UI.Close() end

local function rect(name)
    local a = areas[name]
    if not a then return name .. "=?" end
    return name .. "=" .. a[1] .. "," .. a[2] .. "," .. a[3] .. "," .. a[4]
end

return "chars=" .. charCount
    .. " laidOut=" .. tostring(laid.chars) .. "/" .. tostring(laid.presets)
    .. " | " .. rect("bbView") .. " " .. rect("bbSEmpty")
    .. " " .. rect("bbSNext") .. " " .. rect("bbC" .. (charCount - 1))
    .. " | coversToggle=" .. (#covers > 0 and table.concat(covers, ",") or "none")
    .. " | view " .. startView .. "->" .. toSummons .. "->" .. backToParty
    .. " | char " .. startSlot .. "->" .. switched .. "->" .. restored
