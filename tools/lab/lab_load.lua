-- lab_load.lua -- load one existing save of a quiet lab game from its main menu.
--
-- The EEex Remote Console polls from a 1x1 menu element, so our chunk runs inside
-- a render callback. Native save/load calls from there crash the process (BuffBot
-- validation record 2026-10-21), so the transition is driven the way the player
-- drives it: the game's own buttons, clicked through queued SDL events.
-- Recipe and guard order come from the item-randomiser lab's FLPRQA runner.
--
-- Needs the QA button names in override/UI.MENU: BFQA_SINGLE (START_MAIN),
-- FLPR_QA_START_LOAD (START_SP), FLPR_QA_LOAD_CONFIRM / FLPR_QA_LOAD_BACK (LOAD).
--
-- Usage, in one Remote Console request:
--   assert(loadfile("<this file>"))({folder = "000000010-My Save", status = "<path>"})
-- It returns at once; the clicks happen over the following frames. Poll the status
-- file for {"status":"complete"} or {"status":"failed","error":...}.

-- BG2:EE opens on the campaign screen (START). Its three logos carry no name,
-- so they are addressed by their BAM and verified against their stock rect.
local CAMPAIGNS = {
    soa = { bam = "LOGOSOA", x = 106, y = 270, w = 202, h = 240 },
    tob = { bam = "LOGOTOB", x = 400, y = 270, w = 235, h = 224 },
    tbp = { bam = "LOGOTBP", x = 718, y = 282, w = 226, h = 212 },
}

local args = ...
assert(type(args) == "table", "LAB_LOAD_ARGS_REQUIRED")
local folder, status_path = args.folder, args.status
local campaign = CAMPAIGNS[args.campaign or "soa"]
assert(type(folder) == "string" and folder:match("^%d%d%d%d%d%d%d%d%d%-"), "LAB_LOAD_SAVE_FOLDER_REQUIRED")
assert(type(status_path) == "string" and #status_path > 0, "LAB_LOAD_STATUS_PATH_REQUIRED")
assert(campaign, "LAB_LOAD_UNKNOWN_CAMPAIGN:" .. tostring(args.campaign))
assert(type(EEexRemote) == "table" and type(EEexRemote.Poll) == "function", "LAB_LOAD_REMOTE_MISSING")

LabLoad = LabLoad or {}
local L = LabLoad
assert(not (L.run and L.run.status == "running"), "LAB_LOAD_ALREADY_RUNNING")

-- Engine predicates answer with booleans, nil or 0, and 0 is true in Lua.
local function truthy(v)
    return v ~= nil and v ~= false and v ~= 0
end

local SETTLE_FRAMES = 15

local function on(name)
    return truthy(Infinity_IsMenuOnStack(name))
end

local function transitioning()
    return truthy(Infinity_GetTransitionInProgress())
end

-- The console's own menu (EEEX_REMOTE) sits on top of START and WORLD_ACTIONBAR
-- and lets clicks through, so it counts as a quiet foreground.
local function foreground_ok()
    local screen = Infinity_GetCurrentScreenName()
    if screen == "EEEX_REMOTE" then return true end
    for _, name in ipairs({ "START_SP", "START_MAIN", "START", "WORLD_ACTIONBAR" }) do
        if on(name) then return screen == name end
    end
    return false
end

-- Minimal JSON string body: the values are our own labels and Lua error
-- messages, so dropping control characters loses nothing a reader needs.
local function json_text(value)
    local text = tostring(value):gsub('[%z\1-\31]', " ")
    return (text:gsub('[\\"]', { ["\\"] = "\\\\", ['"'] = '\\"' }))
end

local function write_status(run)
    local parts = {}
    for _, key in ipairs({ "status", "step", "folder", "error" }) do
        if run[key] ~= nil then
            parts[#parts + 1] = string.format('"%s":"%s"', key, json_text(run[key]))
        end
    end
    parts[#parts + 1] = '"clicks":' .. #run.clicks
    parts[#parts + 1] = '"clock":' .. Infinity_GetClockTicks()
    local file = assert(io.open(status_path, "w"))
    assert(file:write("{" .. table.concat(parts, ",") .. "}\n"))
    assert(file:close())
end

local function click(run, menu, button, next_step)
    assert(on(menu), "LAB_LOAD_MENU_MISSING:" .. menu)
    local item = assert(nameToItem[button], "LAB_LOAD_BUTTON_MISSING:" .. button)
    -- Advance before queuing: a delayed transition must never click twice.
    run.step = next_step
    run.clicks[#run.clicks + 1] = button
    Infinity_ClickItem(item)
end

-- The campaign logo has no name to look up, so verify what we found before
-- clicking it: a wrong hit on the title screen could quit the game.
local function click_campaign(run)
    local raw = assert(Infinity_FindItemWithBam(campaign.bam, 0),
        "LAB_LOAD_CAMPAIGN_ITEM_MISSING:" .. campaign.bam)
    local item = EEex_PtrToUD(EEex_LightUDToPtr(raw), "uiItem")
    assert(EEex_UDToPtr(item.menu) == EEex_UDToPtr(EEex_Menu_Find("START"))
        and item.area.x == campaign.x and item.area.y == campaign.y
        and item.area.w == campaign.w and item.area.h == campaign.h,
        "LAB_LOAD_CAMPAIGN_ITEM_UNEXPECTED:" .. campaign.bam)
    run.step = "campaign"
    run.clicks[#run.clicks + 1] = campaign.bam
    Infinity_ClickItem(raw)
end

-- The Single Player button runs startEngine:SetEngineState(1) and then
-- Infinity_TransitionMenu('START_SP'). The engine state is what matters: without
-- it the load button on START_SP bounces back to the campaign screen instead of
-- opening LOAD (lab-verified 2026-10-25), so the button has to be clicked -- its
-- menu push alone is not enough. Its transition, on the other hand, sometimes
-- settles back on START, so push START_SP ourselves if it has not shown up.
local function click_single_player(run)
    click(run, "START_MAIN", "BFQA_SINGLE", "single")
end

local function push_single_player(run)
    assert(EEex_Menu_Find("START_SP"), "LAB_LOAD_START_SP_MISSING")
    run.clicks[#run.clicks + 1] = "push:START_SP"
    Infinity_PushMenu("START_SP")
end

local function step(run)
    assert(Infinity_GetClockTicks() - run.started < 90000, "LAB_LOAD_TIMEOUT:" .. run.step)
    if transitioning() then return end
    local frame = Infinity_GetFrameCounter()
    -- A queued click only lands once the menu it belongs to has been laid out and
    -- drawn. Two frames are not enough right after a push: the click on START_SP's
    -- load button was silently swallowed (lab-verified 2026-10-25). Half a second
    -- of rendered frames between steps is cheap and made it reliable.
    if run.frame and frame < run.frame + SETTLE_FRAMES then return end
    run.frame = frame
    -- Progress is read off the menu stack, not off Infinity_GetCurrentScreenName():
    -- the console's own EEEX_REMOTE menu sits on top of the start screens, so it is
    -- the current screen name throughout. The frame and transition gates above are
    -- what keep a step from clicking twice.

    if run.step == "begin" then
        assert(foreground_ok(), "LAB_LOAD_FOREGROUND_CHANGED")
        if on("START_MAIN") then click_single_player(run)
        elseif on("START") then click_campaign(run)
        else error("LAB_LOAD_START_SCREEN_REQUIRED") end
    elseif run.step == "campaign" and on("START_MAIN") then
        click_single_player(run)
    elseif run.step == "single" and not on("LOAD") then
        if on("START_SP") then
            click(run, "START_SP", "FLPR_QA_START_LOAD", "list")
        elseif not run.pushed then
            run.pushed = true
            push_single_player(run)
        end
    elseif run.step == "list" and on("LOAD") then
        local found, count, seen = nil, 0, {}
        for index, save in ipairs(assert(gameSaves.files)) do
            if #seen < 12 then seen[#seen + 1] = tostring(save.fileName) end
            if save.fileName == folder or save.fileName == "home:/save/" .. folder then
                count, found = count + 1, index
            end
        end
        if count ~= 1 then
            -- Back out of LOAD first: the console takes no requests while it is open.
            run.problem = (count > 1) and ("LAB_LOAD_SAVE_AMBIGUOUS:" .. folder)
                or ("LAB_LOAD_SAVE_MISSING:" .. table.concat(seen, "|"))
            click(run, "LOAD", "FLPR_QA_LOAD_BACK", "left")
        else
            currentSave = found
            click(run, "LOAD", "FLPR_QA_LOAD_CONFIRM", "world")
        end
    elseif run.step == "left" and not on("LOAD") then
        error(run.problem)
    elseif run.step == "world" and on("WORLD_ACTIONBAR") and not on("LOAD")
        and not on("CHAPTER") and EEex_Sprite_GetInPortrait(0) ~= nil
        and not transitioning() then
        -- Loading from the main menu leaves the start screens on the stack under
        -- the world. They show through in a screenshot, so take them off.
        for _, name in ipairs({ "START_SP", "START_MAIN", "START" }) do
            if on(name) then
                run.clicks[#run.clicks + 1] = "pop:" .. name
                Infinity_PopMenu(name)
            end
        end
        run.status = "complete"
    end
end

L.run = { status = "running", step = "begin", folder = folder, clicks = {},
          started = Infinity_GetClockTicks() }

if not L.PollOriginal then
    L.PollOriginal = EEexRemote.Poll
    EEexRemote.Poll = function(...)
        local run = L.run
        if run and run.status == "running" then
            local before = run.status .. ":" .. run.step
            local ok, reason = pcall(step, run)
            if not ok then run.status, run.error = "failed", tostring(reason) end
            if before ~= run.status .. ":" .. run.step then pcall(write_status, run) end
        end
        -- While a save/load screen is up, no console request may run.
        for _, name in ipairs({ "LOAD", "SAVE", "SAVE_NEWSAVE" }) do
            if on(name) then return "" end
        end
        return L.PollOriginal(...)
    end
end

write_status(L.run)
return { started = true, folder = folder, wrapped = EEexRemote.Poll ~= L.PollOriginal }
