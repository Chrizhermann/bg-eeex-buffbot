-- probe_modal_menus.lua -- what the engine itself knows about modal menus.
--
-- BfBot.Fast.Safe names eight menus and asks Infinity_IsMenuOnStack about each,
-- with EngineGlobals.popupActive() as an engine-wide backstop. EEex 1.2.0 does
-- not bind popupActive (issue #104), and a parse of BG2:EE's UI.MENU says the
-- eight are not the modal set: the file declares 50 modal menus, two of the
-- eight names (STORE, LOAD_SCREEN) are not menu names at all, and three more
-- are not modal. A hardcoded list cannot be the guard.
--
-- So ask the running game instead. This probe answers whether that is possible:
--
--   1. does the uiMenu binding expose the `modal` flag, and under what name,
--   2. does walking EngineGlobals.menus find the same set the file declares,
--   3. what does one full walk plus an IsMenuOnStack sweep cost, and
--   4. on this build, what does popupActive() say while nothing is open?
--
--   assert(loadfile("<this file>"))()
--   BfBotProbeModal_Fields()      -- field names a uiMenu answers to
--   BfBotProbeModal_List()        -- every menu, with its modal verdict
--   BfBotProbeModal_OnStack()     -- which of them are on the stack right now
--   BfBotProbeModal_Cost(50)      -- microseconds for a full guard sweep
--   BfBotProbeModal_Missing()     -- the eight names, resolved against the UI

local NAMED = { "WORLD_DIALOG", "WORLD_DIALOG_CONFIRM", "STORE",
    "LOAD_SCREEN", "POPUP_INFO", "POPUP_TWOBUTTON", "POPUP_THREEBUTTON",
    "POPUP_FOURBUTTON" }

-- Candidates for the flag's name on the binding: the .menu keyword itself and
-- the spellings the engine's own structs tend to use.
local FLAGS = { "modal", "bModal", "m_bModal", "isModal", "ignoreEsc",
    "bIgnoreEsc", "flags", "nFlags", "panel", "state" }

local function truth(v) return v ~= nil and v ~= false and v ~= 0 end

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

local function menuCount()
    local ok, n = pcall(function() return EngineGlobals.numMenus end)
    if not ok or type(n) ~= "number" then return nil end
    return n
end

local function menuAt(i)
    local ok, menu = pcall(function()
        return EngineGlobals.menus:getReference(i)
    end)
    if not ok then return nil end
    return menu
end

local function nameOf(menu)
    local value = read(menu, "name")
    return type(value) == "string" and value or nil
end

--- Which of the candidate fields a uiMenu actually answers to, with values
--- from one menu the file says is modal and one it says is not.
function BfBotProbeModal_Fields()
    local n = menuCount()
    if not n then return "numMenus unavailable" end
    local samples, lines = {}, { "numMenus=" .. n }
    for i = 0, n - 1 do
        local menu = menuAt(i)
        local name = menu and nameOf(menu)
        -- POPUP_TWOBUTTON is modal in the file; WORLD_ACTIONBAR is not.
        if name == "POPUP_TWOBUTTON" or name == "WORLD_ACTIONBAR" then
            samples[name] = menu
        end
    end
    for _, name in ipairs({ "POPUP_TWOBUTTON", "WORLD_ACTIONBAR" }) do
        local menu = samples[name]
        if not menu then
            lines[#lines + 1] = name .. " not found in the menu list"
        else
            local parts = { name .. ":" }
            for _, field in ipairs(FLAGS) do
                local value, how = read(menu, field)
                if how ~= "absent" then
                    parts[#parts + 1] = field .. "=" .. tostring(value)
                        .. "(" .. how .. ")"
                end
            end
            lines[#lines + 1] = table.concat(parts, " ")
        end
    end
    return table.concat(lines, "\n")
end

--- Every menu the running UI holds, with the verdict of each candidate flag,
--- so the walk can be compared against the file's own 50.
function BfBotProbeModal_List(flag)
    flag = flag or "modal"
    local n = menuCount()
    if not n then return "numMenus unavailable" end
    local modal, plain, unreadable = {}, {}, 0
    for i = 0, n - 1 do
        local menu = menuAt(i)
        local name = menu and nameOf(menu)
        if not name then
            unreadable = unreadable + 1
        else
            local value, how = read(menu, flag)
            if how == "absent" then
                return "uiMenu has no field '" .. flag .. "'"
            end
            if truth(value) then modal[#modal + 1] = name
            else plain[#plain + 1] = name end
        end
    end
    table.sort(modal)
    return string.format("flag=%s total=%d modal=%d plain=%d unreadable=%d\n%s",
        flag, n, #modal, #plain, unreadable, table.concat(modal, " "))
end

--- Which menus are on the stack right now, and what popupActive says, so the
--- two answers can be compared on a build that has both.
function BfBotProbeModal_OnStack(flag)
    flag = flag or "modal"
    local n = menuCount()
    if not n then return "numMenus unavailable" end
    local onStack, modalOnStack = {}, {}
    for i = 0, n - 1 do
        local menu = menuAt(i)
        local name = menu and nameOf(menu)
        if name then
            local ok, up = pcall(Infinity_IsMenuOnStack, name)
            if ok and truth(up) then
                onStack[#onStack + 1] = name
                local value = read(menu, flag)
                if truth(value) then modalOnStack[#modalOnStack + 1] = name end
            end
        end
    end
    table.sort(onStack)
    table.sort(modalOnStack)
    local popup = "unbound"
    if type(EngineGlobals.popupActive) == "function" then
        local ok, value = pcall(EngineGlobals.popupActive)
        popup = ok and tostring(value) or "raised"
    end
    return string.format("popupActive=%s onStack=%d [%s]\nmodalOnStack=%d [%s]",
        popup, #onStack, table.concat(onStack, " "),
        #modalOnStack, table.concat(modalOnStack, " "))
end

--- The case that decides whether the walk may replace popupActive: open a real
--- modal and ask both. A quiet screen agreeing proves nothing on its own --
--- both answer "no" there. `name` is the modal to push; it is popped again.
function BfBotProbeModal_Positive(name, flag)
    name = name or "POPUP_TWOBUTTON"
    flag = flag or "modal"
    local function state()
        local popup = "unbound"
        if type(EngineGlobals.popupActive) == "function" then
            local ok, value = pcall(EngineGlobals.popupActive)
            popup = ok and tostring(value) or "raised"
        end
        local found = {}
        local n = menuCount() or 0
        for i = 0, n - 1 do
            local menu = menuAt(i)
            local menuName = menu and nameOf(menu)
            if menuName and truth(read(menu, flag)) then
                local ok, up = pcall(Infinity_IsMenuOnStack, menuName)
                if ok and truth(up) then found[#found + 1] = menuName end
            end
        end
        return popup, found
    end

    local beforePopup, beforeFound = state()
    local pushed, pushError = pcall(Infinity_PushMenu, name)
    if not pushed then
        return "could not push " .. name .. ": " .. tostring(pushError)
    end
    local duringPopup, duringFound = state()
    pcall(Infinity_PopMenu, name)
    local afterPopup, afterFound = state()

    return string.format(
        "pushed=%s\nbefore: popupActive=%s walk=[%s]\n"
        .. "during: popupActive=%s walk=[%s]\nafter:  popupActive=%s walk=[%s]",
        name, beforePopup, table.concat(beforeFound, " "),
        duringPopup, table.concat(duringFound, " "),
        afterPopup, table.concat(afterFound, " "))
end

--- The shipped guard itself, against the real engine rather than a stub: it
--- has to permit a quiet world screen and refuse while a modal is up. Offline
--- tests drive a menu list this file wrote; this one drives the game's.
function BfBotProbeModal_Guard(name)
    name = name or "POPUP_TWOBUTTON"
    local function verdict()
        local ok, safe, why = pcall(BfBot.Fast.Safe)
        if not ok then return "raised:" .. tostring(safe) end
        return tostring(safe) .. (why and ("/" .. tostring(why)) or "")
    end
    local quiet = verdict()
    local pushed, pushError = pcall(Infinity_PushMenu, name)
    if not pushed then
        return "quiet=" .. quiet .. " could not push " .. name .. ": "
            .. tostring(pushError)
    end
    local during = verdict()
    pcall(Infinity_PopMenu, name)
    local after = verdict()
    -- How many names the guard ended up holding, so the cache is visible.
    local held = BfBot.Fast._blocking and #BfBot.Fast._blocking or -1
    return string.format(
        "quiet=%s during(%s)=%s after=%s cachedNames=%d cachedFor=%s",
        quiet, name, during, after, held,
        tostring(BfBot.Fast._blockingFor))
end

--- The same guard with popupActive taken away, which is what EEex 1.2.0 gives
--- it. This is the #104 claim: the walk alone still refuses on a modal.
function BfBotProbeModal_GuardWithoutPopup(name)
    local real = EngineGlobals.popupActive
    EngineGlobals.popupActive = nil
    local ok, result = pcall(BfBotProbeModal_Guard, name)
    EngineGlobals.popupActive = real
    if not ok then return "raised: " .. tostring(result) end
    return result
end

--- What one guard sweep costs: the walk that finds the modal names plus an
--- IsMenuOnStack for each. `rounds` is how many sweeps to time.
function BfBotProbeModal_Cost(rounds, flag)
    rounds = tonumber(rounds) or 50
    flag = flag or "modal"
    local n = menuCount()
    if not n then return "numMenus unavailable" end
    local clock = os.clock

    local walkStart = clock()
    local names
    for _ = 1, rounds do
        names = {}
        for i = 0, n - 1 do
            local menu = menuAt(i)
            local name = menu and nameOf(menu)
            if name and truth(read(menu, flag)) then
                names[#names + 1] = name
            end
        end
    end
    local walk = (clock() - walkStart) / rounds

    local sweepStart = clock()
    for _ = 1, rounds do
        for _, name in ipairs(names) do
            pcall(Infinity_IsMenuOnStack, name)
        end
    end
    local sweep = (clock() - sweepStart) / rounds

    return string.format(
        "menus=%d modal=%d walk=%.0fus sweep=%.0fus total=%.0fus",
        n, #names, walk * 1e6, sweep * 1e6, (walk + sweep) * 1e6)
end

--- The eight names the shipped guard uses, resolved against the running UI:
--- does each exist, and does the engine call it modal?
function BfBotProbeModal_Missing(flag)
    flag = flag or "modal"
    local n = menuCount()
    if not n then return "numMenus unavailable" end
    local byName = {}
    for i = 0, n - 1 do
        local menu = menuAt(i)
        local name = menu and nameOf(menu)
        if name then byName[name] = menu end
    end
    local lines = {}
    for _, name in ipairs(NAMED) do
        local menu = byName[name]
        if not menu then
            lines[#lines + 1] = name .. " = NO SUCH MENU"
        else
            local value = read(menu, flag)
            lines[#lines + 1] = name .. " = exists, "
                .. (truth(value) and "modal" or "NOT modal")
        end
    end
    return table.concat(lines, "\n")
end

return {}
