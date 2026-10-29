-- probe_press_state.lua -- the two things issue #103 could not settle offline.
--
-- The footer buttons drew Pecca's pressed frame, which is nearly the picture
-- the normal one is, while the tabs force the loud selected frame. The panel
-- now decides the frame itself, from the engine's held counter, so a live
-- game has to answer:
--
--   1. does a frame BuffBot returns reach the screen, for every chrome
--      button rather than only the tabs that always had one, and
--   2. what does asking 74 buttons on every rendered frame cost?
--
-- A real press cannot be staged -- nothing in EEex synthesises a mouse down --
-- so question 1 is answered by making _IsHeld say "held" and photographing
-- the result, which exercises the whole path except the counter itself.
--
--   assert(loadfile("<this file>"))()
--   BfBotProbePress_Sweep()            -- what the bindings expose
--   BfBotProbePress_Area("bbAdd")      -- where to crop a shot
--   BfBotProbePress_HoldAll(true)      -- every chrome button reads as held
--   BfBotProbePress_Cost(600)          -- microseconds per _IsHeld call
--   BfBotProbePress_HoldAll(false)
--
-- HoldAll swaps one function and puts the original back; nothing is saved.

local M = {}

-- Field names the LuaBindings expose around a button: the press counter next
-- to the hold action, the three that decide what is drawn, and the ones that
-- might carry a state of their own.
local FIELDS = {
    "framesHeld", "held", "frame", "sequence", "clickable", "toggle",
    "glow", "pulse", "tint", "highlight", "highlightGroup", "state",
}

--- Read one field, surviving both "no such field" and a reference wrapper.
local function read(owner, field)
    local ok, value = pcall(function() return owner[field] end)
    if not ok then return nil, "absent" end
    if value == nil then return nil, "nil" end
    local kind = type(value)
    if kind == "userdata" or kind == "table" then
        local gotOk, got = pcall(function() return value:get() end)
        if gotOk then return got, "get" end
        return tostring(value), kind
    end
    return value, kind
end

local function describe(owner, label, parts)
    if owner == nil then
        parts[#parts + 1] = label .. "=<none>"
        return
    end
    for _, field in ipairs(FIELDS) do
        local value, how = read(owner, field)
        if how ~= "absent" then
            parts[#parts + 1] = label .. "." .. field .. "="
                .. tostring(value) .. "(" .. how .. ")"
        end
    end
end

--- Everything readable about one named button, as one line.
function BfBotProbePress_Fields(name)
    local item = EEex_Menu_GetItem(name)
    if item == nil then return "item=<missing>:" .. tostring(name) end
    local parts = { "item=" .. tostring(name) }
    describe(item, "item", parts)
    local buttonOk, button = pcall(function() return item.button end)
    describe(buttonOk and button or nil, "button", parts)
    return table.concat(parts, " ")
end

--- The button's screen rectangle, so a diff can be read where it matters.
function BfBotProbePress_Area(name)
    local x, y, w, h = EEex_Menu_GetItemArea(name)
    if x == nil then return "area=<missing>:" .. tostring(name) end
    return string.format("area=%d,%d,%d,%d", x, y, w, h)
end

-- The real _IsHeld, while it is replaced.
local realIsHeld = nil

--- Make every chrome button report that it is being held, or stop.
-- The frame expressions call BfBot.UI._IsHeld by name on each render, so
-- swapping the function is enough: no menu is reloaded and no item is poked.
function BfBotProbePress_HoldAll(on)
    if on then
        if realIsHeld == nil then realIsHeld = BfBot.UI._IsHeld end
        BfBot.UI._IsHeld = function() return true end
        return "every chrome button now reads as held"
    end
    if realIsHeld == nil then return "nothing was held" end
    BfBot.UI._IsHeld = realIsHeld
    realIsHeld = nil
    return "the held counter decides again"
end

--- What one rendered frame's worth of held-checks costs, in microseconds.
-- `calls` is how many _IsHeld calls to time; the panel asks once per chrome
-- button per render, and there are 74 of them.
function BfBotProbePress_Cost(calls)
    calls = tonumber(calls) or 740
    local isHeld = realIsHeld or BfBot.UI._IsHeld
    if type(isHeld) ~= "function" then return "no _IsHeld to time" end
    -- A name the menu really has, so the lookup does the work it does live.
    local name = "bbAdd"
    local clock = os.clock
    local started = clock()
    for _ = 1, calls do isHeld(name) end
    local elapsed = clock() - started
    local missing = clock()
    for _ = 1, calls do isHeld("bbNoSuchButton") end
    local elapsedMissing = clock() - missing
    return string.format(
        "calls=%d found=%.1fus/call missing=%.1fus/call perFrame74=%.0fus",
        calls, elapsed / calls * 1e6, elapsedMissing / calls * 1e6,
        elapsed / calls * 74 * 1e6)
end

--- The same read for every kind of chrome button the panel shows, so one call
--- says whether the answer is the same for plates, tabs and the cast plate.
function BfBotProbePress_Sweep()
    local names = { "bbAdd", "bbCast", "bbC0", "bbClose", "bbTog" }
    local lines = {}
    for _, name in ipairs(names) do
        lines[#lines + 1] = BfBotProbePress_Fields(name)
        lines[#lines + 1] = "  " .. BfBotProbePress_Area(name)
    end
    return table.concat(lines, "\n")
end

return M
