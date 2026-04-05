-- ============================================================
-- BfBotCor.lua — BuffBot Namespace, Logging & Shared Utilities
-- Root namespace, logging functions, field resolution, caches.
-- Module files: BfBotCls, BfBotScn, BfBotExe, BfBotPer, BfBotInn
-- ============================================================

-- Root namespace
BfBot = BfBot or {}
BfBot.VERSION = "1.3.1-alpha"
BfBot.MAX_PRESETS = 8

-- ============================================================
-- Logging
-- ============================================================

BfBot._logLevel = 2 -- 0=off, 1=errors, 2=warnings, 3=verbose
BfBot._debugMode = 0 -- 0=quiet (log file only), 1=verbose (log + in-game display)

-- Log file path (game directory)
BfBot._logFile = "buffbot_test.log"
BfBot._logHandle = nil

-- Open log file for writing (call once before test runs)
function BfBot._OpenLog()
    if BfBot._noIO then return end
    local h, err = io.open(BfBot._logFile, "w")
    if h then
        BfBot._logHandle = h
        h:write("=== BuffBot Log " .. (os.date and os.date("%Y-%m-%d %H:%M:%S") or "?") .. " ===\n")
    end
end

-- Close log file
function BfBot._CloseLog()
    if BfBot._logHandle then
        BfBot._logHandle:close()
        BfBot._logHandle = nil
    end
end

-- Open log file in append mode (doesn't truncate)
function BfBot._OpenLogAppend(filename)
    if BfBot._noIO then return false end
    BfBot._CloseLog()
    local fname = filename or BfBot._logFile
    local h, err = io.open(fname, "a")
    if h then
        BfBot._logHandle = h
        h:write("\n=== BuffBot Log " .. (os.date and os.date("%Y-%m-%d %H:%M:%S") or "?") .. " ===\n")
    end
    return h ~= nil
end

-- Output function: writes to log file, shows in-game ONLY if debug mode is on
function BfBot._Print(msg)
    local s = tostring(msg)
    if BfBot._debugMode == 1 then
        Infinity_DisplayString(s)
    end
    if BfBot._logHandle then
        BfBot._logHandle:write(s .. "\n")
        BfBot._logHandle:flush()
    end
end

--- Always display in-game, regardless of debug mode. For user-facing feedback.
function BfBot._Display(msg)
    local s = tostring(msg)
    Infinity_DisplayString(s)
    if BfBot._logHandle then
        BfBot._logHandle:write(s .. "\n")
        BfBot._logHandle:flush()
    end
end

function BfBot._Error(msg)
    if BfBot._logLevel >= 1 then
        BfBot._Display("[BuffBot ERROR] " .. tostring(msg))
    end
end

function BfBot._Warn(msg)
    if BfBot._logLevel >= 2 then
        BfBot._Print("[BuffBot WARN] " .. tostring(msg))
    end
end

function BfBot._Log(msg)
    if BfBot._logLevel >= 3 then
        BfBot._Print("[BuffBot] " .. tostring(msg))
    end
end

-- ============================================================
-- Shared Utilities
-- ============================================================

--- Get character name safely. Used by Exec, Innate, and UI modules.
function BfBot._GetName(sprite)
    if not sprite then return "?" end
    local ok, name = pcall(function() return sprite:getName() end)
    if ok and name and name ~= "" then return name end
    return "?"
end

-- ============================================================
-- Field Name Resolution
-- Uncertain field names on EEex userdata types are resolved
-- at runtime by BfBot.Test.CheckFields(). Until then, use
-- the primary (most likely) names from architecture docs.
-- ============================================================

BfBot._fields = {
    -- Spell_ability_st fields
    fb_count = "effectCount",       -- fallback: "featureBlockCount"
    fb_start = "startingEffect",    -- fallback: "featureBlockOffset"
    friendly_flags = "type",        -- bit 10 (0x0400) = friendly

    -- Item_effect_st fields (feature blocks from SPL data)
    fb_opcode = "effectID",
    fb_timing = "durationType",
    fb_duration = "duration",
    fb_param1 = "effectAmount",
    fb_param2 = "dwFlags",
    fb_target = "targetType",
    fb_res = "res",                 -- fallback: "resource"; call :get()
    fb_special = "special",

    -- Resolved flag: set to true after CheckFields succeeds
    _resolved = false,
}

-- ============================================================
-- Caches
-- ============================================================

BfBot._cache = {
    -- Classification cache: resref -> ClassResult
    -- Never invalidated within a session (SPL data is static)
    class = {},

    -- Scan cache: spriteID -> { spells = {...}, timestamp = number }
    -- Invalidated per-sprite on spell list change events
    scan = {},
}

-- User override table: resref -> boolean|nil
BfBot._overrides = {}
