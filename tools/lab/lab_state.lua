-- lab_state.lua -- capture BuffBot's player-owned state in a lab game, set up a
-- fixture, run the in-game suite. Driven by tools/lab_runall_check.py, one
-- Remote Console request per call:
--   assert(loadfile("<this file>"))({cmd = "...", out = "<dir>", ...})
-- Returns a string. Snapshots are written as JSON files into `out`.
-- The fixture command writes BuffBot state into the loaded save: labs only.

local args = ...
assert(type(args) == "table", "LAB_STATE_ARGS_REQUIRED")
BfBotLab = BfBotLab or {}
local Lab = BfBotLab

local SENTINEL = "\1lab-absent\1"

-- ---- serialization -------------------------------------------------------

local function keyLess(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
end

-- Strict, deterministic: keeps booleans apart from 1/0 and every key type.
local function strict(v, seen)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
    if t ~= "table" then return "<" .. t .. ">" end
    seen = seen or {}
    if seen[v] then return "<cycle>" end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, keyLess)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = "[" .. strict(k, seen) .. "]=" .. strict(v[k], seen)
    end
    seen[v] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function jsonString(s)
    s = tostring(s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

-- Tables of strings only (what snapshot() builds).
local function json(v)
    if type(v) ~= "table" then return jsonString(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, keyLess)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = jsonString(k) .. ":" .. json(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function writeFile(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- ---- state ---------------------------------------------------------------

local function iniRaw(key)
    if type(Infinity_GetINIString) ~= "function" then return "<no Infinity_GetINIString>" end
    local ok, v = pcall(Infinity_GetINIString, "BuffBot", key, SENTINEL)
    if not ok then return "<error " .. tostring(v) .. ">" end
    if v == SENTINEL then return "<absent>" end
    return string.format("%q", tostring(v))
end

local function presetFiles()
    local names = {}
    local pipe = io.popen('dir /b /a-d "override\\bfbot_presets" 2>nul')
    if pipe then
        for line in pipe:lines() do
            if line ~= "" then names[#names + 1] = line end
        end
        pipe:close()
    end
    table.sort(names)
    local files = {}
    for _, name in ipairs(names) do
        files[name] = readFile("override/bfbot_presets/" .. name) or "<unreadable>"
    end
    return files
end

local function innates(sprite)
    local seen = {}
    local ok, err = pcall(function()
        for _, _, resref in EEex_Sprite_GetKnownInnateSpellsIterator(sprite) do
            if type(resref) == "string" and resref:match("^BFBT") then
                seen[resref] = (seen[resref] or 0) + 1
            end
        end
    end)
    if not ok then return "<error " .. tostring(err) .. ">" end
    return strict(seen)
end

local function paletteName()
    local active = BfBot.Theme and BfBot.Theme._active
    for name, palette in pairs((BfBot.Theme and BfBot.Theme._palettes) or {}) do
        if palette == active then return name end
    end
    return tostring(active)
end

local function snapshot()
    local s = { members = {}, ini = {}, files = presetFiles(), memory = {} }
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local aux = EEex_GetUDAux(sprite)
            local cfg = aux[BfBot.Persist._KEY]
            s.members["slot" .. slot] = {
                name = tostring(BfBot._GetName(sprite)),
                config = cfg ~= nil and BfBot.Persist._Serialize(cfg) or "nil",
                strict = strict(cfg),
                table = tostring(cfg),
                itemSwap = strict(aux.BBItemSwap),
                innates = innates(sprite),
            }
        end
    end
    for key in pairs(BfBot.Persist._INI_DEFAULTS) do s.ini[key] = iniRaw(key) end
    s.ini.BB_TestKey = iniRaw("BB_TestKey")
    s.ini.Debug = iniRaw("Debug")
    s.memory.overrides = strict(BfBot._overrides)
    s.memory.overridesTable = tostring(BfBot._overrides)
    s.memory.fontSize = tostring(BfBot.Theme and BfBot.Theme._fontSize)
    s.memory.palette = paletteName()
    s.memory.panel = strict({ x = BfBot.UI._panelX, y = BfBot.UI._panelY,
        w = BfBot.UI._panelW, h = BfBot.UI._panelH })
    s.memory.innateRefreshPending = tostring(BfBot._innateRefreshPending)
    s.memory.pendingSkips = strict(BfBot.Persist._pendingSkips)
    s.memory.execState = tostring(BfBot.Exec and BfBot.Exec._state)
    return s
end

-- ---- fixture -------------------------------------------------------------

local function sortedSpells(preset)
    local list = {}
    for resref in pairs(preset and preset.spells or {}) do list[#list + 1] = resref end
    table.sort(list)
    return list
end

local KNOWN = {}
for resref in ("SPCL311 SPCL412 SPCL908 SPCL910 SPCL922 SPIN101 SPIN141 SPIN142 SPPR101 "
    .. "SPPR107 SPPR201 SPPR207 SPPR212 SPPR409 SPPR508 SPWI108 SPWI112 SPWI114 SPWI116 "
    .. "SPWI211 SPWI212 SPWI304 SPWI305 SPWI317 SPWI319 SPWI408 SPWI422 SPWI503 SPWI509 "
    .. "SPWI523 SPWI613 SPPR327"):gmatch("%S+") do KNOWN[resref] = true end

local function setupFixture()
    local log = {}
    local function note(s) log[#log + 1] = s end
    local leader = EEex_Sprite_GetInPortrait(0)
    local second = EEex_Sprite_GetInPortrait(1)
    local third = EEex_Sprite_GetInPortrait(2)
    assert(leader and second, "LAB_FIXTURE_NEEDS_TWO_MEMBERS")
    local leaderName = BfBot._GetName(leader)
    local secondName = BfBot._GetName(second)

    -- Party-wide structure the player builds in the panel.
    BfBot.Persist.RenamePresetAll(1, "Lab Morning")
    BfBot.Persist.RenamePresetAll(2, "Lab Fight")
    local boss = BfBot.Persist.CreatePresetAll("Lab Boss")
    note("CreatePresetAll -> " .. tostring(boss))
    BfBot.Innate.RefreshAll()

    -- Leader: quick cast, active preset, lock/repeat/targets in presets 2-3.
    BfBot.Persist.SetQuickCast(leader, 1, 2)
    if boss then BfBot.Persist.SetQuickCast(leader, boss, 1) end
    BfBot.Persist.SetActivePreset(leader, boss or 2)
    local l2 = sortedSpells(BfBot.Persist.GetPreset(leader, 2))
    if l2[1] then
        BfBot.Persist.SetSpellLock(leader, 2, l2[1], 1)
        BfBot.Persist.SetSpellRepeat(leader, 2, l2[1], 3)
        note("leader p2 lock+rep3 " .. l2[1])
    end
    if l2[2] then
        BfBot.Persist.SetSpellTarget(leader, 2, l2[2], { secondName, leaderName })
        BfBot.Persist.SetTgtUnlock(leader, 2, l2[2], 1)
        BfBot.Persist.SetSpellPriority(leader, 2, l2[2], 42)
        note("leader p2 tgt table+unlock+pri42 " .. l2[2])
    end
    if boss then
        local lb = sortedSpells(BfBot.Persist.GetPreset(leader, boss))
        for i = 1, math.min(3, #lb) do
            BfBot.Persist.SetSpellEnabled(leader, boss, lb[i], 1)
            BfBot.Persist.SetSpellPriority(leader, boss, lb[i], i)
        end
        note("leader boss enabled " .. tostring(math.min(3, #lb)))
    end
    -- One include override on a castable non-buff the suite does not pin.
    local castable = BfBot.Scan.GetCastableSpells(leader) or {}
    local include
    local refs = {}
    for resref in pairs(castable) do refs[#refs + 1] = resref end
    table.sort(refs)
    for _, resref in ipairs(refs) do
        local scan = castable[resref]
        if not KNOWN[resref] and scan.kind ~= "itm" and scan.class
            and not scan.class.isBuff and not scan.class.overridden then
            include = resref
            break
        end
    end
    if include then
        BfBot.Persist.SetOverride(leader, include, 1)
        note("leader include override " .. include)
    end

    -- Second member: its own choices in presets 1-2.
    BfBot.Persist.SetQuickCast(second, 2, 1)
    BfBot.Persist.SetActivePreset(second, 2)
    local s1 = sortedSpells(BfBot.Persist.GetPreset(second, 1))
    for i = 1, math.min(2, #s1) do
        local entry = BfBot.Persist.GetSpellConfig(second, 1, s1[i])
        BfBot.Persist.SetSpellEnabled(second, 1, s1[i], entry.on == 1 and 0 or 1)
        note("second p1 toggled " .. s1[i])
    end
    local s2 = sortedSpells(BfBot.Persist.GetPreset(second, 2))
    if s2[1] then
        BfBot.Persist.SetSpellTarget(second, 2, s2[1], leaderName)
        BfBot.Persist.SetSpellLock(second, 2, s2[1], 1)
        note("second p2 tgt leader+lock " .. s2[1])
    end

    if third then
        BfBot.Persist.SetQuickCast(third, 1, 1)
        local t1 = sortedSpells(BfBot.Persist.GetPreset(third, 1))
        if t1[1] then
            BfBot.Persist.SetSpellRepeat(third, 1, t1[1], 2)
            note("third p1 rep2 " .. t1[1])
        end
    end

    -- Global preferences the player chose.
    BfBot.Persist.SetPref("PanelX", 120)
    BfBot.Persist.SetPref("PanelY", 80)
    BfBot.Persist.SetPref("PanelW", 1000)
    BfBot.Persist.SetPref("PanelH", 700)
    BfBot.Persist.SetPref("FontSize", 3)
    BfBot.Persist.SetPref("CombatInterrupt", 0)
    BfBot.UI._LoadLayout()
    BfBot.Theme._SetFontSize(3)

    -- The player's own export of the leader, which must survive the suite.
    local exportOk, exportName = BfBot.Persist.ExportConfig(leader)
    note("ExportConfig -> " .. tostring(exportOk) .. " " .. tostring(exportName))
    return table.concat(log, "\n")
end

-- ---- INI probe -----------------------------------------------------------

local function probeIni()
    local r = {}
    local function add(k, v) r[#r + 1] = k .. " = " .. tostring(v) end
    for _, name in ipairs({ "Infinity_GetINIString", "Infinity_SetINIString",
        "Infinity_GetINIValue", "Infinity_SetINIValue", "Infinity_RemoveINIEntry" }) do
        add("type(" .. name .. ")", type(_G[name]))
    end
    local function try(label, fn, ...)
        local ok, a, b = pcall(fn, ...)
        add(label, (ok and "ok " or "ERR ") .. strict(a) .. (b ~= nil and (" " .. strict(b)) or ""))
    end
    try("GetINIString absent", Infinity_GetINIString, "BuffBot", "BB_LabProbeAbsent", SENTINEL)
    try("GetINIValue absent", Infinity_GetINIValue, "BuffBot", "BB_LabProbeAbsent", -12345)
    try("GetINIString Theme", Infinity_GetINIString, "BuffBot", "Theme", SENTINEL)
    try("GetINIString FontSize", Infinity_GetINIString, "BuffBot", "FontSize", SENTINEL)
    try("GetINIValue Theme", Infinity_GetINIValue, "BuffBot", "Theme", -12345)
    try("SetINIValue str", Infinity_SetINIValue, "BuffBot", "BB_LabProbeStr", "abc def")
    try("GetINIString str", Infinity_GetINIString, "BuffBot", "BB_LabProbeStr", SENTINEL)
    try("GetINIValue str", Infinity_GetINIValue, "BuffBot", "BB_LabProbeStr", -12345)
    try("SetINIValue num", Infinity_SetINIValue, "BuffBot", "BB_LabProbeNum", 42)
    try("GetINIString num", Infinity_GetINIString, "BuffBot", "BB_LabProbeNum", SENTINEL)
    try("GetINIValue num", Infinity_GetINIValue, "BuffBot", "BB_LabProbeNum", -12345)
    try("SetINIValue empty", Infinity_SetINIValue, "BuffBot", "BB_LabProbeEmpty", "")
    try("GetINIString empty", Infinity_GetINIString, "BuffBot", "BB_LabProbeEmpty", SENTINEL)
    try("SetINIValue negnum-str", Infinity_SetINIValue, "BuffBot", "BB_LabProbeNeg", "-1")
    try("GetINIValue negnum-str", Infinity_GetINIValue, "BuffBot", "BB_LabProbeNeg", -12345)
    if type(Infinity_RemoveINIEntry) == "function" then
        try("RemoveINIEntry str", Infinity_RemoveINIEntry, "BuffBot", "BB_LabProbeStr")
        try("GetINIString str after remove", Infinity_GetINIString, "BuffBot", "BB_LabProbeStr", SENTINEL)
        try("RemoveINIEntry num", Infinity_RemoveINIEntry, "BuffBot", "BB_LabProbeNum")
        try("GetINIValue num after remove", Infinity_GetINIValue, "BuffBot", "BB_LabProbeNum", -12345)
        try("RemoveINIEntry empty", Infinity_RemoveINIEntry, "BuffBot", "BB_LabProbeEmpty")
        try("GetINIString empty after remove", Infinity_GetINIString, "BuffBot", "BB_LabProbeEmpty", SENTINEL)
        try("RemoveINIEntry neg", Infinity_RemoveINIEntry, "BuffBot", "BB_LabProbeNeg")
        try("RemoveINIEntry absent", Infinity_RemoveINIEntry, "BuffBot", "BB_LabProbeNever")
        try("GetINIString never", Infinity_GetINIString, "BuffBot", "BB_LabProbeNever", SENTINEL)
    end
    return table.concat(r, "\n"):gsub(SENTINEL, "<SENTINEL>")
end

-- ---- commands ------------------------------------------------------------

local cmd = args.cmd
if cmd == "probe_ini" then
    local text = probeIni()
    if args.out then writeFile(args.out .. "/probe-ini.txt", text) end
    return text
elseif cmd == "fixture" then
    local text = setupFixture()
    if args.out then writeFile(args.out .. "/fixture.txt", text) end
    return text
elseif cmd == "snapshot" then
    local s = snapshot()
    Lab[args.name] = s
    writeFile(args.out .. "/" .. args.name .. ".json", json(s))
    local n = 0
    for _ in pairs(s.members) do n = n + 1 end
    return "snapshot " .. args.name .. ": " .. n .. " members"
elseif cmd == "runall" then
    local lines = {}
    local print0 = BfBot._Print
    local ok, result = pcall(BfBot.Test.RunAll)
    local log = BfBot._logFile and readFile(BfBot._logFile) or ""
    writeFile(args.out .. "/" .. (args.name or "runall") .. ".log", log)
    local fails = {}
    for line in log:gmatch("[^\n]+") do
        if line:find("FAIL") or line:find("ERROR") or line:find("raised") then
            fails[#fails + 1] = line
        end
    end
    return "RunAll ok=" .. tostring(ok) .. " result=" .. tostring(result)
        .. " logLines=" .. select(2, log:gsub("\n", "")) .. "\n" .. table.concat(fails, "\n")
elseif cmd == "save" then
    EEex_Action_QueueResponseStringOnAIBase("SaveGame(1)", EEex_Sprite_GetInPortrait(0))
    return "SaveGame(1) queued"
end
error("LAB_STATE_UNKNOWN_CMD:" .. tostring(cmd))
