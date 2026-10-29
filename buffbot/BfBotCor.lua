-- ============================================================
-- BfBotCor.lua — BuffBot Namespace, Logging & Shared Utilities
-- Root namespace, logging functions, field resolution, caches.
-- Module files: BfBotCls, BfBotScn, BfBotExe, BfBotPer, BfBotInn
-- ============================================================

-- Root namespace
BfBot = BfBot or {}
BfBot.VERSION = "1.12.4"
BfBot.MAX_PRESETS = 8
BfBot.MAX_SPELL_REPEATS = 5

-- Remaining-duration threshold for the active-buff skip (issue #84). A buff
-- whose remaining lifetime is BELOW the threshold is cast again instead of
-- skipped, so a long buff that survived a rest with a tiny remainder gets a
-- fresh timer. 0 keeps the historical behavior: every active buff skips.
BfBot.MAX_REFRESH_BELOW = 86400  -- one game day; upper bound for RefreshBelow
-- Threshold the panel's "Refresh low" state uses when RefreshBelow is off:
-- five minutes. Same value as the LongThreshold default in BfBotPer.lua,
-- which is what divides "long" from "short" — so "low" means "less of this
-- buff is left than it takes to count as long at all".
BfBot.REFRESH_LOW_SECONDS = 300

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

BfBot._reportedErrors = BfBot._reportedErrors or {}

--- Display an error once per session; repeats of the same message stay quiet.
--- For failures that would otherwise recur on every run or tick.
function BfBot._ErrorOnce(msg)
    local s = tostring(msg)
    if BfBot._reportedErrors[s] then return end
    BfBot._reportedErrors[s] = 1
    BfBot._Error(s)
end

-- ============================================================
-- Overhead feedback
-- ============================================================

-- Matches EEex_Sprite_DisplayTextRef's default text color.
local _OVERHEAD_TEXT_COLOR = 0xBED7D7

-- EEex has no overhead-text helper that takes a string:
-- EEex_Sprite_DisplayTextRef and the DisplayStringHead action both want a TLK
-- strref, while BuffBot feedback is UTF-8 catalog text (BfBotLoc). The engine's
-- CMessageDisplayText carries CString text; with m_overHead set, its Run()
-- attaches a floating CGameText to the target sprite (checked in the
-- disassembly of 2.7.3.0 and 2.6.6.0); whether the text also reaches the
-- message log is left to the engine. EEex v0.11, v1.2.0 and v1.3.1 bind the
-- same CMessageDisplayText:Construct(name, text, nameColor, textColor,
-- marker, caller, target), which copies both strings.
local function _queueOverheadText(sprite, text)
    local handler = EngineGlobals.g_pBaldurChitin.m_cMessageHandler
    local id = sprite.m_id
    local nameColor = CVidPalette.RANGE_COLORS:get(
        sprite.m_baseStats.m_colors:get(2))
    local message = EEex_NewUD("CMessageDisplayText")
    local ok, err = pcall(EEex_RunWithStackManager, {
        { ["name"] = "text", ["struct"] = "CString",
          ["constructor"] = { ["args"] = { text } } } },
        function(manager)
            message:Construct(sprite.m_sName, manager:getUD("text"),
                nameColor, _OVERHEAD_TEXT_COLOR, -1, id, id)
        end)
    if not ok then
        EEex_FreeUD(message)
        error(err, 0)
    end
    message.m_overHead = 1
    -- The handler owns the message from here and deletes it after Run().
    handler:AddMessage(message, false)
end

--- Show BuffBot feedback as floating text over a sprite.
--- Falls back to the message log when there is no sprite or the engine
--- message cannot be queued; a queueing failure is also reported once, so
--- the notice is never silently lost (bg-eeex-buffbot#76).
-- @param sprite userdata|nil: CGameSprite to show the text over
-- @param text string: already-localized feedback text
-- @return boolean: true when the overhead message was queued
function BfBot._DisplayOverhead(sprite, text)
    if sprite ~= nil then
        local ok, err = pcall(_queueOverheadText, sprite, text)
        if ok then return true end
        BfBot._ErrorOnce("Overhead text failed, showing it in the message log: "
            .. tostring(err))
    end
    BfBot._Display(text)
    return false
end

-- EEex v0.11 lets listener errors escape into the engine. Keep every
-- BuffBot-owned event boundary contained while preserving successful return
-- arity (including nil slots) for callbacks whose values EEex consumes.
local _bfbotUnpack = table.unpack or unpack
local function _bfbotPack(...)
    return { n = select("#", ...), ... }
end

local function _bfbotSafeToString(value, fallback)
    local ok, converted = pcall(tostring, value)
    if ok then return converted end
    return fallback
end

BfBot._callbackErrors = BfBot._callbackErrors or {}

function BfBot._SafeCallback(label, callback)
    return function(...)
        local result = _bfbotPack(pcall(callback, ...))
        if not result[1] then
            -- Protect the complete diagnostic path as well as the callback:
            -- user-supplied tostring metamethods, shared diagnostic state, and
            -- the reporter itself must never rethrow into EEex.
            pcall(function()
                local safeLabel = _bfbotSafeToString(
                    label, "<unprintable callback label>")
                local safeError = _bfbotSafeToString(
                    result[2], "<unprintable callback error>")
                local message = safeLabel .. ": " .. safeError
                local callbackErrors = BfBot._callbackErrors
                if type(callbackErrors) ~= "table" then
                    callbackErrors = {}
                    BfBot._callbackErrors = callbackErrors
                end
                if not callbackErrors[message] then
                    callbackErrors[message] = 1
                    pcall(BfBot._Error, "EEex callback failed -- " .. message)
                end
            end)
            return nil
        end
        return _bfbotUnpack(result, 2, result.n)
    end
end

-- ============================================================
-- Shared Utilities
-- ============================================================

--- Strip Infinity Engine color escape codes (^0xAABBGGRR<text>^-) from a string.
-- Tweaks Anthology's "Colorize NPC Names and Tooltips" component rewrites CRE
-- name strrefs to wrap them in color escapes. The engine's main renderer parses
-- the escape; `text lua "..."` bindings in .menu files do not, so the prefix
-- leaks as literal text on tabs/buttons. Strip at the source.
function BfBot._StripColorEscape(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("%^%-", ""):gsub("%^0x%x%x%x%x%x%x%x%x", ""))
end

--- Get character name safely. Used by Exec, Innate, and UI modules.
function BfBot._GetName(sprite)
    if not sprite then return "?" end
    local ok, name = pcall(function() return sprite:getName() end)
    if ok and name and name ~= "" then
        name = BfBot._StripColorEscape(name)
        if name ~= "" then return name end
    end
    return "?"
end

--- Get a character's death variable / script name safely.
-- Display names can change during play (for example, Anomen becoming
-- "Sir Anomen"), while the death variable remains the stable identity used
-- by scripts. The protagonist commonly reports an empty or "None" value;
-- callers decide whether that value is usable for their purpose.
-- @param sprite userdata: a creature sprite
-- @return string: the death variable, or "" if unavailable
function BfBot._GetDeathVar(sprite)
    if not sprite then return "" end
    local ok, value = pcall(function() return sprite.m_scriptName end)
    if not ok or value == nil then return "" end
    if type(value) == "string" then return value end
    local getOk, deathVar = pcall(function() return value:get() end)
    if getOk and type(deathVar) == "string" then return deathVar end
    return ""
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

    -- Allied-summon sweep cache: { at = clockTicks, list = {entries} } | nil
    -- nil until the first BfBot.Scan.GetAlliedSummons() call; TTL-checked
    -- there (~2s). Cleared by BfBot.Scan.InvalidateSummons().
    summons = nil,
}

-- User override table: resref -> boolean|nil
BfBot._overrides = {}
