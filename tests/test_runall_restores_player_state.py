"""BfBot.Test.RunAll() and its phases leave the player's own state as it was.

Players run the in-game suite on their real saves. It drives the real
persistence API on the loaded party, so before this was guarded a passing run
replaced the leader's presets with defaults, imported a test export over the
second member, deleted the leader's export file and left test keys in
baldur.ini. These tests run the real phases under LuaJIT, against a party
that has non-default configs, an unfinished item swap, a config-less member,
classifier overrides, its own baldur.ini values and its own export files,
and compare all of it before and after: same tables, same content, same
bytes, nothing left queued on a sprite.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MODULES = ["BfBotCor", "BfBotLoc", "BfBotThm", "BfBotCls", "BfBotExe",
           "BfBotMp", "BfBotPer", "BfBotInn", "BfBotUI", "BfBotTst"]
SOURCES = {name: (ROOT / f"buffbot/{name}.lua").read_text(encoding="utf-8")
           for name in MODULES}
TEST_SOURCE = SOURCES["BfBotTst"]
PERSIST_SOURCE = SOURCES["BfBotPer"]

# Every phase that writes player state, and the section name it reports.
GUARDED_PHASES = {
    "Override": "Override",
    "SpellLockPersist": "SpellLockPersist",
    "ExportImport": "ExportImport",
    "TargetPicker": "TargetPicker",
    "CombatSafety": "Combat Safety",
    "SubwindowDetection": "Subwindow Detection",
    "MovablePanel": "MovablePanel",
    "Theming": "Theming",
    "Watchdog": "Watchdog",
    "Mp": "Multiplayer",
    "SummonCasters": "SummonCasters",
    "RefreshThreshold": "RefreshThreshold",
    "Persist": "Persistence",
    # Plans read-only, but reads the live config to check the migration --
    # and GetConfig stores a default for a character that has none.
    "PlanModel": "Plan Model",
    "QuickCast": "Quick Cast",
    "StaleState": "Stale State",
}


# The engine, as far as the phases reach it. Paths outside the scratch
# folder are refused, so no phase can touch a real override folder.
ENGINE = r"""
T_Out = {}
T_Calls = {}
Infinity_DisplayString = function(msg) T_Out[#T_Out + 1] = tostring(msg) end

-- The game folder is T_ROOT: relative paths (override/..., the logs) land
-- there, and an absolute path anywhere else is refused.
T_Foreign = {}
do
    local realOpen, realRemove = io.open, os.remove
    local function resolve(path)
        local p = tostring(path):gsub("\\", "/")
        if not p:match("^%a:") and p:sub(1, 1) ~= "/" then return T_ROOT .. "/" .. p end
        if p:sub(1, #T_ROOT + 1) == T_ROOT .. "/" then return p end
    end
    io.open = function(path, mode)
        local inside = resolve(path)
        if inside then return realOpen(inside, mode) end
        T_Foreign[#T_Foreign + 1] = "open " .. tostring(mode or "r") .. " " .. tostring(path)
        return nil, tostring(path) .. ": No such file or directory", 2
    end
    os.remove = function(path)
        local inside = resolve(path)
        if inside then return realRemove(inside) end
        T_Foreign[#T_Foreign + 1] = "remove " .. tostring(path)
        return nil, tostring(path) .. ": No such file or directory", 2
    end
    -- Only ExportConfig's mkdir of the (existing) presets folder is expected.
    T_Commands = {}
    os.execute = function(command)
        T_Commands[#T_Commands + 1] = tostring(command)
        return 0
    end
    -- ListExports lists override\bfbot_presets with `dir /b`; answer it from
    -- the scratch presets folder instead.
    io.popen = function(command)
        if tostring(command):find("bfbot_presets", 1, true) then
            local names = T_ListPresets()
            local i = 0
            return {
                lines = function()
                    return function()
                        i = i + 1
                        return names[i]
                    end
                end,
                close = function() end,
            }
        end
        T_Foreign[#T_Foreign + 1] = "popen " .. tostring(command)
        return nil
    end
end

-- baldur.ini as the 2.7.3.0 engine behaves (probed in a lab): values are
-- stored as text, GetINIValue reads the leading integer, there is no
-- SetINIString, and RemoveINIEntry deletes a key.
T_Ini = {}
T_IniWrites = 0
function T_IniSection(section)
    T_Ini[section] = T_Ini[section] or {}
    return T_Ini[section]
end
Infinity_GetINIString = function(section, key, default)
    local value = T_IniSection(section)[key]
    if value == nil then return default end
    return value
end
Infinity_GetINIValue = function(section, key, default)
    local value = T_IniSection(section)[key]
    if value == nil then return default end
    return tonumber(value:match("^%s*([-+]?%d+)")) or 0
end
Infinity_SetINIValue = function(section, key, value)
    if type(value) == "number" and value == math.floor(value) then
        value = string.format("%d", value)
    end
    T_IniSection(section)[key] = tostring(value)
    T_IniWrites = T_IniWrites + 1
end
Infinity_RemoveINIEntry = function(section, key)
    T_IniSection(section)[key] = nil
    T_IniWrites = T_IniWrites + 1
end

T_Clock = 100000
Infinity_GetClockTicks = function()
    T_Clock = T_Clock + 16
    return T_Clock
end
T_GameTime = 50000
EEex_EngineGlobal_CBaldurChitin = { m_pObjectGame = { m_worldTime = {} } }
setmetatable(EEex_EngineGlobal_CBaldurChitin.m_pObjectGame.m_worldTime, {
    __index = function(_, key)
        if key == "m_gameTime" then return T_GameTime end
    end,
})
Infinity_GetScreenSize = function() return 1920, 1080 end
T_Areas = {}
Infinity_SetArea = function(name, x, y, w, h)
    if x == nil then error("no such area " .. tostring(name)) end
    T_Areas[name] = { x, y, w, h }
end
Infinity_GetArea = function(name)
    local a = T_Areas[name]
    if a then return a[1], a[2], a[3], a[4] end
    return 0, 0, 0, 0
end
Infinity_PushMenu = function() end
Infinity_PopMenu = function() end
Infinity_FetchString = function(ref) return "String " .. tostring(ref) end
EEex_Resource_Demand = function() return nil end  -- no SPL/ITM files here

-- Floating text over a sprite (BfBot._DisplayOverhead).
T_Overhead = {}
EngineGlobals = { g_pBaldurChitin = { m_cMessageHandler = {
    AddMessage = function(_, message) T_Overhead[#T_Overhead + 1] = message.text end,
} } }
CVidPalette = { RANGE_COLORS = { get = function(_, color) return color end } }
EEex_NewUD = function()
    return { Construct = function(self, _, text) self.text = text end }
end
EEex_RunWithStackManager = function(specs, fn)
    fn({ getUD = function() return specs[1].constructor.args[1] end })
end
EEex_FreeUD = function() end

function EEex_IsBitUnset(value, bit) return math.floor(value / 2 ^ bit) % 2 == 0 end
function EEex_IsBitSet(value, bit) return not EEex_IsBitUnset(value, bit) end
function EEex_SetBit(value, bit)
    if EEex_IsBitSet(value, bit) then return value end
    return value + 2 ^ bit
end
function EEex_BAnd(a, b)
    local result, bit = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then result = result + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return result
end
EEex_Utility_IterateCPtrList = function(list, fn)
    for _, value in ipairs(list or {}) do
        if fn(value) then return end
    end
end

-- The party: portrait slot, join order, display name, death variable.
T_Party = {}
T_Aux = {}
T_Queued = {}
function T_AddMember(slot, index, name, deathVar)
    local sprite = {
        name = name, m_sName = name, m_id = 1000 + slot, m_scriptName = deathVar,
        index = index, innates = {}, effects = {},
        m_baseStats = { m_generalState = 0, m_colors = { get = function() return 0 end } },
        m_derivedStats = { m_generalState = 0 },
        m_timedEffectList = {}, m_equipedEffectList = {},
    }
    function sprite:getName() return self.name end
    function sprite:getActiveStats() return self.m_derivedStats end
    function sprite:getSpellState() return false end
    T_Party[slot] = sprite
    return sprite
end
EEex_Sprite_GetInPortrait = function(slot) return T_Party[slot] end
EEex_Sprite_GetCharacterIndex = function(sprite) return sprite.index end
EEex_Sprite_GetPortraitIndex = function(sprite)
    for slot = 0, 5 do
        if T_Party[slot] == sprite then return slot end
    end
    return -1
end
EEex_GetUDAux = function(sprite)
    local aux = T_Aux[sprite]
    if not aux then
        aux = {}
        T_Aux[sprite] = aux
    end
    return aux
end
EEex_Sprite_GetKnownInnateSpellsIterator = function(sprite)
    local i = 0
    return function()
        i = i + 1
        local resref = sprite.innates[i]
        if resref then return 0, i - 1, resref end
    end
end
EEex_Action_QueueResponseStringOnAIBase = function(text, sprite)
    T_Queued[#T_Queued + 1] = { text = text, sprite = sprite }
end
EEex_Action_ExecuteResponseStringOnAIBaseInstantly = function(text, sprite)
    T_Calls.instant = (T_Calls.instant or 0) + 1
    local resref = text:match('^AddSpecialAbility%("([^"]+)"%)$')
    if not resref then error("unexpected instant action " .. text) end
    for _, known in ipairs(sprite.innates) do
        if known == resref then return end
    end
    sprite.innates[#sprite.innates + 1] = resref
end
-- Opcode 172 removes an innate, 321 the effects from a source resource;
-- anything else is kept on the sprite as "opcode:source resource".
EEex_GameObject_ApplyEffect = function(sprite, args)
    local function drop(list, keep)
        for i = #list, 1, -1 do
            if not keep(list[i]) then table.remove(list, i) end
        end
    end
    if args.effectID == 172 then
        drop(sprite.innates, function(resref) return resref ~= args.res end)
    elseif args.effectID == 321 then
        drop(sprite.effects, function(effect)
            return effect:match("^%d+:(.*)$") ~= tostring(args.res)
        end)
    else
        sprite.effects[#sprite.effects + 1] = args.effectID .. ":"
            .. tostring(args.m_sourceRes or args.res)
    end
end
EEex_Sprite_AddMarshalHandlers = function() end
EEex_Sprite_AddLoadedListener = function() end
EEex_Sprite_AddQuickListsCheckedListener = function() end
EEex_Menu_AddAfterMainFileLoadedListener = function() end
"""


# What the scanner reports for each member: resref -> (buff?, kind, durCat).
WORLD = r"""
T_Castable = {
    [0] = { SPWI305 = { true, "spl", "long" }, SPWI408 = { true, "spl", "short" },
            SPPR101 = { true, "spl", "long" }, SPWI112 = { false, "spl", "short" },
            SPWI212 = { false, "spl", "short" }, SPPR103 = { true, "spl", "short" },
            POTN52 = { true, "itm", "short" } },
    [1] = { SPPR101 = { true, "spl", "long" }, SPPR107 = { true, "spl", "short" },
            SPPR203 = { false, "spl", "short" } },
    [2] = { SPWI305 = { true, "spl", "long" }, SPWI101 = { false, "spl", "short" } },
}
local function T_Count(label)
    T_Calls[label] = (T_Calls[label] or 0) + 1
end
local function T_CastableFor(sprite)
    local slot = EEex_Sprite_GetPortraitIndex(sprite)
    local spells, count = {}, 0
    for resref, info in pairs(T_Castable[slot] or {}) do
        local isBuff = info[1]
        local override = BfBot._overrides[resref]
        if override ~= nil then isBuff = override end
        spells[resref] = {
            resref = resref, count = 1, kind = info[2], durCat = info[3],
            duration = info[3] == "long" and 3600 or 60,
            name = "Name " .. resref, level = 1, spellType = 1,
            class = { isBuff = isBuff, overridden = override ~= nil,
                      isAoE = false, isSelfOnly = false, defaultTarget = "s" },
        }
        count = count + 1
    end
    return spells, count
end
BfBot = BfBot or {}
BfBot.Scan = {
    Invalidate = function() T_Count("Scan.Invalidate") end,
    InvalidateAll = function() T_Count("Scan.InvalidateAll") end,
    InvalidateSummons = function() T_Count("Scan.InvalidateSummons") end,
    GetCastableSpells = function(sprite) return T_CastableFor(sprite) end,
    ScanParty = function()
        local party = {}
        for slot = 0, 5 do
            local sprite = T_Party[slot]
            if sprite then
                local spells, count = T_CastableFor(sprite)
                party[slot] = { sprite = sprite, name = sprite.name,
                                spells = spells, count = count }
            end
        end
        return party
    end,
    GetAlliedSummons = function() return {} end,
    ClassifySummonSprite = function() return nil end,
    _SummonIdentity = function() return nil end,
}
"""


# The player's own state: two members with configs of their own (one with
# an unfinished item swap), one member BuffBot never configured. The safety
# tick removed the F12 innates earlier versions granted right after the
# load, so the leader keeps only an innate of their own.
PLAYER = r"""
local leader = T_AddMember(0, 0, "Zyntris", "")
local second = T_AddMember(1, 1, "Jaheira", "JAHEIRA")
local third = T_AddMember(2, 2, "Imoen", "IMOEN2")
leader.innates = { "SPCL900" }

EEex_GetUDAux(leader)[BfBot.Persist._KEY] = {
    v = 10, ap = 2,
    presets = {
        [1] = { name = "Morning", cat = "long", qc = 1, spells = {
            SPWI305 = { kind = "spl", on = 1, tgt = "p", pri = 1, rep = 2,
                        lock = 1, tgtUnlock = 1 },
            SPPR101 = { kind = "spl", on = 0, tgt = { "Jaheira", "Imoen" },
                        pri = 2, rep = 1, lock = 0, var = "SPPR101B" },
            POTN52 = { kind = "itm", on = 1, tgt = "s", pri = 3, rep = 1, lock = 0 },
            ["itm:RING95:2"] = { kind = "itm", on = 1, tgt = "s", pri = 4,
                                 rep = 1, lock = 0 },
        } },
        [2] = { name = "Fight", cat = "short", qc = 2, spells = {
            SPWI408 = { kind = "spl", on = 1, tgt = "Jaheira", pri = 1, rep = 1, lock = 0 },
            SPPR103 = { kind = "spl", on = 1, tgt = "s", pri = 2, rep = 3, lock = 0 },
        } },
        [3] = { name = "Spare", cat = "custom", qc = 0, spells = {} },
    },
    opts = { skip = 0 },
    ovr = { SPWI212 = 1, SPPR103 = -1 },
    summons = {
        ["clone:Zyntris"] = { presets = { [1] = { qc = 1, spells = {
            SPWI305 = { on = 1, tgt = "s", pri = 1, rep = 1 },
        } } } },
    },
}
EEex_GetUDAux(second)[BfBot.Persist._KEY] = {
    v = 10, ap = 1,
    presets = {
        [1] = { name = "Long Buffs", cat = "long", qc = 0, spells = {
            SPPR101 = { kind = "spl", on = 1, tgt = { "Zyntris" }, pri = 1, rep = 1, lock = 0 },
        } },
        [2] = { name = "Short Buffs", cat = "short", qc = 0, spells = {
            SPPR107 = { kind = "spl", on = 1, tgt = "p", pri = 1, rep = 1, lock = 1 },
        } },
    },
    opts = { skip = 1 }, ovr = {}, summons = {},
}
-- An item swap a crash interrupted: the save keeps the validated journal.
EEex_GetUDAux(second).BBItemSwap = {
    item = "RING95", previous = "RING02", pack = 21, equip = 7,
}
BfBot._overrides = { SPWI212 = true, SPPR103 = false }

local ini = T_IniSection("BuffBot")
ini.Theme = "bg2_dark"
ini.FontSize = "3"
ini.PanelX, ini.PanelY, ini.PanelW, ini.PanelH = "40", "30", "900", "600"
ini.CombatInterrupt = "0"
ini.ItemUseMode = "swap"
ini.LongThreshold = "300"
ini.Debug = "0"
T_IniSection("Program Options")["Volume Music"] = "40"

BfBot.Theme._fontSize = 3
BfBot.UI._panelX, BfBot.UI._panelY = 40, 30
BfBot.UI._panelW, BfBot.UI._panelH = 900, 600
"""


# A canonical text of everything the player owns, plus the table identities.
SNAPSHOT = r"""
function T_Canon(value, seen)
    if type(value) ~= "table" then
        return type(value) .. ":" .. tostring(value)
    end
    seen = seen or {}
    if seen[value] then return "<cycle>" end
    seen[value] = true
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        return type(a) .. tostring(a) < type(b) .. tostring(b)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = T_Canon(key, seen) .. "=" .. T_Canon(value[key], seen)
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

function T_State()
    local state = {}
    for slot = 0, 5 do
        local sprite = T_Party[slot]
        if sprite then
            local aux = EEex_GetUDAux(sprite)
            state["member" .. slot .. ".aux"] = T_Canon(aux)
            state["member" .. slot .. ".innates"] = table.concat(sprite.innates, ",")
            state["member" .. slot .. ".effects"] = table.concat(sprite.effects, ",")
            state["member" .. slot .. ".name"] = sprite.name
        end
    end
    state.overrides = T_Canon(BfBot._overrides)
    state.ini = T_Canon(T_Ini)
    state.fontSize = tostring(BfBot.Theme._fontSize)
    state.panel = table.concat({ tostring(BfBot.UI._panelX), tostring(BfBot.UI._panelY),
        tostring(BfBot.UI._panelW), tostring(BfBot.UI._panelH) }, ",")
    state.importGlobal = tostring(BfBot._import)
    return state
end

--- Run what the phases queued on sprites, the way the engine would on its
--- next ticks. Returns the queued actions that are not BuffBot Lua actions.
function T_RunQueued()
    local engine = {}
    local i = 0
    while i < #T_Queued do
        i = i + 1
        local text = T_Queued[i].text
        local body = text:match('^EEex_LuaAction%("(.*)"%)$')
        if body then
            assert(loadstring(body))()
        else
            engine[#engine + 1] = text
        end
    end
    T_Queued = {}
    return engine
end

function T_Refs()
    local refs = { overrides = BfBot._overrides }
    for slot = 0, 5 do
        local sprite = T_Party[slot]
        if sprite then
            local aux = EEex_GetUDAux(sprite)
            refs[slot] = { config = aux[BfBot.Persist._KEY], itemSwap = aux.BBItemSwap }
        end
    end
    return refs
end

function T_SameRefs(refs)
    local same = refs.overrides == BfBot._overrides
    for slot = 0, 5 do
        local sprite = T_Party[slot]
        if sprite then
            local aux = EEex_GetUDAux(sprite)
            same = same and rawequal(refs[slot].config, aux[BfBot.Persist._KEY])
                and rawequal(refs[slot].itemSwap, aux.BBItemSwap)
        end
    end
    return same
end
"""


# Counters that show a phase really reached the writers it is guarded for.
COUNTERS = r"""
local function T_Wrap(tbl, name, label)
    local fn = tbl[name]
    if type(fn) ~= "function" then error("no function " .. label) end
    tbl[name] = function(...)
        T_Calls[label] = (T_Calls[label] or 0) + 1
        return fn(...)
    end
end
for _, name in ipairs({
    "SetPref", "SetOverride", "SetSpellLock", "ExportConfig", "ImportConfig",
    "_Import", "SetOpt", "SetQuickCast", "SetTgtUnlock", "SetSpellVariant",
    "SetRefreshBelow", "GetSummonPreset", "CreatePreset", "DeletePreset",
    "SetActivePreset", "SetSpellEnabled", "SetSpellPriority", "SetSpellTarget",
    "SetConfig", "_CreateDefaultConfig",
}) do
    T_Wrap(BfBot.Persist, name, "Persist." .. name)
end
T_Wrap(BfBot.Class, "SetOverride", "Class.SetOverride")
T_Wrap(BfBot.Theme, "_SetFontSize", "Theme._SetFontSize")
T_Wrap(BfBot.UI, "_ResetLayout", "UI._ResetLayout")
T_Wrap(BfBot.Exec, "_RecoverItemSwaps", "Exec._RecoverItemSwaps")
"""


def build_world(tmp_path: Path) -> LuaRuntime:
    root = tmp_path / "game"
    presets = root / "override" / "bfbot_presets"
    presets.mkdir(parents=True)
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().T_ROOT = root.as_posix()
    lua.globals().T_ListPresets = lambda: lua.table_from(
        sorted(p.name for p in presets.glob("*.lua")))
    lua.execute(ENGINE)
    lua.execute(WORLD)
    for name in MODULES:
        lua.execute(SOURCES[name])
    lua.execute(
        """
        BfBot._debugMode = 1   -- suite output reaches T_Out as well as the log
        BfBot.Fast = nil
        """
    )
    lua.execute(PLAYER)
    lua.execute(SNAPSHOT)
    lua.execute(COUNTERS)
    # The player's own exports: the leader's, and someone else's.
    (presets / "Zyntris.lua").write_bytes(
        b"-- exported by the player\r\nBfBot._import = { v = 10, ap = 1 }\r\n")
    (presets / "Khalid.lua").write_bytes(b"BfBot._import = { v = 9 }\n")
    return lua


def files(lua: LuaRuntime) -> dict[str, bytes]:
    """The override folder, except the panel art BuffBot regenerates at any
    size it needs (a cache that only grows, not the player's)."""
    override = Path(str(lua.globals().T_ROOT)) / "override"
    return {p.relative_to(override).as_posix(): p.read_bytes()
            for p in sorted(override.rglob("*"))
            if p.is_file() and not re.fullmatch(r"BFBOTBG\d?\.MOS", p.name)}


class Player:
    """The player's state before a phase, to compare against afterwards."""

    def __init__(self, lua: LuaRuntime) -> None:
        self.lua = lua
        self.state = dict(lua.eval("T_State()").items())
        self.refs = lua.eval("T_Refs()")
        self.files = files(lua)

    def changes(self) -> dict[str, tuple]:
        after = dict(self.lua.eval("T_State()").items())
        changed = {key: (self.state.get(key), after.get(key))
                   for key in set(self.state) | set(after)
                   if self.state.get(key) != after.get(key)}
        if not self.lua.globals().T_SameRefs(self.refs):
            changed["table identity"] = ("player's tables", "replaced")
        now = files(self.lua)
        for name in set(self.files) | set(now):
            if self.files.get(name) != now.get(name):
                changed["file " + name] = (self.files.get(name), now.get(name))
        return changed

    def assert_untouched(self) -> None:
        assert self.changes() == {}
        writes = [entry for entry in self.lua.globals().T_Foreign.values()
                  if not entry.startswith("open r")]
        assert writes == [], "wrote outside the game folder"
        commands = set(self.lua.globals().T_Commands.values())
        assert commands <= {'mkdir "override/bfbot_presets" 2>nul'}


def output(lua: LuaRuntime) -> str:
    return "\n".join(lua.globals().T_Out.values())


def calls(lua: LuaRuntime, label: str) -> int:
    return int(lua.globals().T_Calls[label] or 0)


# Watchdog and StaleState strip Quick Cast buffs from the leader, as the end
# of any run does. Nothing else may be queued: a queued action runs only
# after the restore, against the player's own state.
ALLOWED_ENGINE_ACTIONS = {'ReallyForceSpellRES("BFBTCR",Myself)'}

LEADER = "EEex_GetUDAux(T_Party[0])[BfBot.Persist._KEY]"


@pytest.fixture
def world(tmp_path: Path):
    lua = build_world(tmp_path)
    yield lua
    lua.execute("BfBot._CloseLog()")  # an open log blocks tmp cleanup on Windows


def run_queued(lua: LuaRuntime) -> None:
    """Let the engine run what the phase queued, then check what it was."""
    engine = list(lua.eval("T_RunQueued()").values())
    assert set(engine) <= ALLOWED_ENGINE_ACTIONS, engine


# phase, the writers it must reach, Lua that shapes the player's state first.
PHASE_CASES = [
    pytest.param("Override", ["Persist.SetOverride", "Class.SetOverride"], "",
                 id="Override"),
    pytest.param("Override", ["Persist.SetOverride", "Persist._CreateDefaultConfig"],
                 LEADER + " = nil", id="Override-leader-without-config"),
    pytest.param("SpellLockPersist", ["Persist.SetSpellLock"],
                 LEADER + ".presets[1].spells = { SPWI305 = { kind = 'spl', on = 1,"
                 " tgt = 'p', pri = 1, rep = 2, lock = 1 } }",
                 id="SpellLockPersist-locked-spell"),
    pytest.param("ExportImport", ["Persist.ExportConfig", "Persist.ImportConfig"], "",
                 id="ExportImport"),
    pytest.param("ExportImport", ["Persist.ExportConfig", "Persist.ImportConfig"],
                 "assert(os.remove('override/bfbot_presets/Zyntris.lua'))",
                 id="ExportImport-no-export-yet"),
    pytest.param("TargetPicker", ["Persist.SetTgtUnlock"], "", id="TargetPicker"),
    pytest.param("CombatSafety", ["Persist.SetPref", "Exec._RecoverItemSwaps"], "",
                 id="CombatSafety"),
    pytest.param("CombatSafety", ["Persist.SetPref"],
                 "T_IniSection('BuffBot').CombatInterrupt = nil",
                 id="CombatSafety-pref-never-set"),
    pytest.param("SubwindowDetection", ["Persist.SetSpellVariant"],
                 LEADER + ".presets[1].spells = { SPPR101 = { kind = 'spl', on = 1,"
                 " tgt = 'p', pri = 1, rep = 1, lock = 0, var = 'SPPR101B' } }",
                 id="SubwindowDetection-chosen-variant"),
    pytest.param("MovablePanel", ["UI._ResetLayout", "Persist.SetPref"], "",
                 id="MovablePanel"),
    pytest.param("MovablePanel", ["UI._ResetLayout"],
                 "for _, k in ipairs({ 'PanelX', 'PanelY', 'PanelW', 'PanelH' }) do"
                 " T_IniSection('BuffBot')[k] = nil end"
                 " BfBot.UI._panelX, BfBot.UI._panelY = nil, nil"
                 " BfBot.UI._panelW, BfBot.UI._panelH = nil, nil",
                 id="MovablePanel-never-moved"),
    pytest.param("Theming", ["Theme._SetFontSize"], "", id="Theming"),
    pytest.param("Watchdog", ["Exec._RecoverItemSwaps"], "", id="Watchdog"),
    pytest.param("StaleState", ["Exec._RecoverItemSwaps"], "", id="StaleState"),
    pytest.param("Mp", ["Persist.SetPref"], "", id="Mp-mode-never-set"),
    pytest.param("Mp", ["Persist.SetPref"],
                 "T_IniSection('BuffBot').MpControlMode = 'manual'"
                 " T_IniSection('BuffBot').MpControlNames = 'Zyntris,Jaheira'",
                 id="Mp-manual-mode"),
    pytest.param("SummonCasters", ["Persist.GetSummonPreset", "Persist.SetPref"], "",
                 id="SummonCasters"),
    pytest.param("RefreshThreshold", ["Persist.SetPref", "Persist.SetRefreshBelow"], "",
                 id="RefreshThreshold-never-set"),
    pytest.param("RefreshThreshold", ["Persist.SetPref", "Persist.SetRefreshBelow"],
                 "T_IniSection('BuffBot').RefreshBelow = '300'",
                 id="RefreshThreshold-set"),
    pytest.param("Persist", ["Persist.SetOpt", "Persist._Import", "Persist.CreatePreset",
                             "Persist.DeletePreset", "Persist.SetSpellTarget"], "",
                 id="Persist"),
    pytest.param("QuickCast", ["Persist.SetQuickCast"], "", id="QuickCast"),
    pytest.param("LegacyInnateCleanup", ["instant"], "", id="LegacyInnateCleanup"),
]


@pytest.mark.parametrize("phase, writers, prepare", PHASE_CASES)
def test_phase_leaves_the_players_state_as_it_was(
    world: LuaRuntime, phase: str, writers: list[str], prepare: str
) -> None:
    world.execute(prepare)
    player = Player(world)

    world.eval(f"BfBot.Test.{phase}()")

    for label in writers:
        assert calls(world, label) > 0, f"{phase} never reached {label}"
    run_queued(world)
    player.assert_untouched()


# LegacyInnateCleanup's second pass over the party raises while the test's
# grant is on the leader.
BREAK_SECOND_LEGACY_PASS = (
    "local real, passes = BfBot.Innate._RemoveLegacy, 0\n"
    "BfBot.Innate._RemoveLegacy = function(...)\n"
    "    passes = passes + 1\n"
    "    if passes == 2 then error('tick broke') end\n"
    "    return real(...)\n"
    "end"
)

# phase, the writer it reaches before the raise, the raise, the report.
RAISE_CASES = [
    pytest.param("Override", "Persist.SetOverride",
                 "BfBot.Scan.Invalidate = function() error('scanner gone') end",
                 "Override raised: ", id="Override"),
    pytest.param("ExportImport", "Persist.ExportConfig",
                 "BfBot.Persist.ListExports = function() error('listing failed') end",
                 "ExportImport file tests raised: ", id="ExportImport"),
    pytest.param("TargetPicker", "Persist.SetTgtUnlock",
                 "BfBot.UI._TargetToText = function() error('no text') end",
                 "TargetPicker raised: ", id="TargetPicker"),
    pytest.param("Mp", "Persist.SetPref",
                 "local real = BfBot.Mp.IsLocallyControlled\n"
                 "BfBot.Mp.IsLocallyControlled = function(sprite)\n"
                 "    if BfBot.Persist.GetPref('MpControlMode') == 'all' then\n"
                 "        error('ownership probe failed')\n"
                 "    end\n"
                 "    return real(sprite)\n"
                 "end",
                 "Multiplayer raised: ", id="Mp"),
    pytest.param("Persist", "Persist.SetOpt",
                 "local real = BfBot.Persist.SetOpt\n"
                 "BfBot.Persist.SetOpt = function(sprite, key, value)\n"
                 "    real(sprite, key, value)\n"
                 "    if value == 1 then error('marshal failed') end\n"
                 "end",
                 "Persistence raised: ", id="Persist"),
    pytest.param("QuickCast", "Persist.SetQuickCast",
                 "BfBot.Innate._BuildCheatSPL = function() error('no SPL') end",
                 "Quick Cast raised: ", id="QuickCast"),
    pytest.param("LegacyInnateCleanup", "instant", BREAK_SECOND_LEGACY_PASS,
                 "LegacyInnateCleanup cases raised: ", id="LegacyInnateCleanup"),
]


@pytest.mark.parametrize("phase, writer, raise_it, report", RAISE_CASES)
def test_phase_that_raises_still_leaves_the_players_state(
    world: LuaRuntime, phase: str, writer: str, raise_it: str, report: str
) -> None:
    player = Player(world)
    world.execute(raise_it)

    passed = world.eval(f"BfBot.Test.{phase}()")

    assert passed is False
    assert report in output(world)
    assert calls(world, writer) > 0, f"{phase} raised before reaching {writer}"
    run_queued(world)
    player.assert_untouched()


def test_interrupted_legacy_innate_cases_remove_the_test_grant(
    world: LuaRuntime,
) -> None:
    world.execute(BREAK_SECOND_LEGACY_PASS)

    world.globals().BfBot.Test.LegacyInnateCleanup()

    assert ("PASS: cleanup: the test's BFBT01 removed after an interrupted case"
            in output(world))
    assert list(world.globals().T_Party[0].innates.values()) == ["SPCL900"]


def test_legacy_innate_phase_removes_only_leftovers_the_tick_has_not_reached(
    world: LuaRuntime,
) -> None:
    # Right after a load a member can still carry F12 innates from an earlier
    # version. The phase's pass removes them, as the safety tick would a moment
    # later, and touches nothing else.
    world.execute("T_Party[1].innates = { 'BFBT11', 'SPCL901', 'BFBT12' }")
    player = Player(world)

    passed = world.globals().BfBot.Test.LegacyInnateCleanup()

    assert passed is True
    run_queued(world)
    assert player.changes() == {
        "member1.innates": ("BFBT11,SPCL901,BFBT12", "SPCL901")}


def test_legacy_innate_phase_leaves_a_leftover_it_cannot_probe_with(
    world: LuaRuntime,
) -> None:
    # The leader still knows the very innate the phase grants: a grant would
    # add nothing, so the phase skips and the safety tick removes it later.
    world.execute("T_Party[0].innates = { 'BFBT01', 'SPCL900' }")
    player = Player(world)

    passed = world.globals().BfBot.Test.LegacyInnateCleanup()

    assert passed is True
    assert "still knows BFBT01 from an earlier version" in output(world)
    assert calls(world, "instant") == 0
    player.assert_untouched()


def test_export_tests_leave_an_unreadable_export_alone(world: LuaRuntime) -> None:
    world.execute(
        """
        local open = io.open
        io.open = function(path, mode)
            if tostring(path):find("Zyntris.lua", 1, true) and mode == "rb" then
                return nil, path .. ": Permission denied", 13
            end
            return open(path, mode)
        end
        """
    )
    player = Player(world)

    passed = world.globals().BfBot.Test.ExportImport()

    assert passed is False
    assert "file tests not run" in output(world)
    assert calls(world, "Persist.ExportConfig") == 0
    player.assert_untouched()


def test_restore_problem_fails_the_phase_after_putting_the_tables_back(
    world: LuaRuntime,
) -> None:
    player = Player(world)
    world.execute("BfBot.Scan.InvalidateAll = function() error('cache locked') end")

    passed = world.globals().BfBot.Test.Theming()

    assert passed is False
    assert "Theming: could not restore the classifier caches: " in output(world)
    assert "cache locked" in output(world)
    player.assert_untouched()


def test_phase_runs_nothing_when_the_players_state_cannot_be_kept(
    world: LuaRuntime,
) -> None:
    player = Player(world)
    world.execute("T_Defaults = BfBot.Persist._INI_DEFAULTS; BfBot.Persist._INI_DEFAULTS = nil")

    passed = world.globals().BfBot.Test.Theming()

    world.execute("BfBot.Persist._INI_DEFAULTS = T_Defaults")
    assert passed is False
    assert ("Theming raised: could not isolate the player's state, nothing was run"
            in output(world))
    assert calls(world, "Theme._SetFontSize") == 0
    player.assert_untouched()


# ---------------------------------------------------------------- RunAll

RUN_ALL_BODY = re.search(
    r"^function BfBot\.Test\.RunAll\(\)\n(.*?)^end\n", TEST_SOURCE, re.S | re.M).group(1)
RUN_ALL_PHASES = re.findall(r"= BfBot\.Test\.(\w+)\(\)", RUN_ALL_BODY)

# A phase that writes every kind of player state RunAll guards.
VANDAL = r"""
function T_Vandal()
    local leader, second, third = T_Party[0], T_Party[1], T_Party[2]
    local key = BfBot.Persist._KEY
    EEex_GetUDAux(leader)[key].presets[1].name = "vandalized"
    EEex_GetUDAux(leader)[key].ovr.SPWI212 = nil
    EEex_GetUDAux(second)[key] = BfBot.Persist.GetDefaultConfig()
    EEex_GetUDAux(second).BBItemSwap.token = 99
    BfBot.Persist.GetConfig(third)               -- creates a default config
    BfBot._overrides.SPWI212 = nil
    BfBot._overrides.SPWI999 = true
    BfBot.Persist.SetPref("MpControlMode", "all")
    BfBot.Persist.SetPref("Theme", "bg1")
    Infinity_RemoveINIEntry("BuffBot", "CombatInterrupt")
    BfBot.Theme._SetFontSize(1)
    BfBot.UI._ResetLayout()
    return true
end
"""


def stub_phases(lua: LuaRuntime, replace: dict[str, str] | None = None) -> None:
    """Every phase RunAll calls passes and records its run, except `replace`."""
    lua.execute(VANDAL)
    lua.execute("T_Ran = {}")
    for name in RUN_ALL_PHASES:
        body = (replace or {}).get(name, "return true")
        lua.execute(
            f"BfBot.Test.{name} = function() T_Ran[#T_Ran + 1] = '{name}'; {body} end")


def ran(lua: LuaRuntime) -> list[str]:
    return list(lua.globals().T_Ran.values())


def test_run_all_calls_the_phases_these_tests_stub() -> None:
    assert RUN_ALL_PHASES[0] == "CheckFields"
    assert set(GUARDED_PHASES) | {"LegacyInnateCleanup"} <= set(RUN_ALL_PHASES)


def test_run_all_of_the_real_phases_leaves_the_players_state(world: LuaRuntime) -> None:
    # Field names need a live engine; every other phase runs as shipped.
    world.execute("BfBot.Test.CheckFields = function() return true end")
    player = Player(world)

    world.globals().BfBot.Test.RunAll()

    text = output(world)
    assert "CRITICAL" not in text
    assert " raised: " not in text
    for label in ["Persist.SetOverride", "Persist.ImportConfig", "Persist.ExportConfig",
                  "Persist.SetTgtUnlock", "Persist.SetSpellLock", "Persist.SetSpellVariant",
                  "Persist.GetSummonPreset", "Persist.SetQuickCast", "Persist.SetOpt",
                  "Persist._Import", "Persist.SetRefreshBelow", "Persist.SetPref",
                  "Theme._SetFontSize", "UI._ResetLayout", "Exec._RecoverItemSwaps",
                  "instant"]:
        assert calls(world, label) > 0, label
    run_queued(world)
    player.assert_untouched()
    assert world.eval("BfBot._logHandle") is None
    log = (Path(str(world.globals().T_ROOT)) / "buffbot_test.log").read_text(encoding="utf-8")
    assert "BuffBot Test Suite" in log


def test_run_all_restores_what_an_unguarded_phase_wrote(world: LuaRuntime) -> None:
    stub_phases(world, {"NameStrip": "return T_Vandal()"})
    player = Player(world)

    passed = world.globals().BfBot.Test.RunAll()

    assert passed is True
    assert ran(world) == RUN_ALL_PHASES
    run_queued(world)
    player.assert_untouched()


def test_run_all_stops_cleanly_when_a_phase_raises(world: LuaRuntime) -> None:
    stub_phases(world, {"Override": "T_Vandal(); error('phase exploded')"})
    player = Player(world)

    passed = world.globals().BfBot.Test.RunAll()

    assert passed is False
    assert "CRITICAL: the suite stopped: " in output(world)
    assert "phase exploded" in output(world)
    assert ran(world) == RUN_ALL_PHASES[:RUN_ALL_PHASES.index("Override") + 1]
    assert world.eval("BfBot._logHandle") is None
    run_queued(world)
    player.assert_untouched()


def test_run_all_runs_nothing_when_the_players_state_cannot_be_kept(
    world: LuaRuntime,
) -> None:
    stub_phases(world)
    player = Player(world)
    world.execute("T_Defaults = BfBot.Persist._INI_DEFAULTS; BfBot.Persist._INI_DEFAULTS = nil")

    passed = world.globals().BfBot.Test.RunAll()

    world.execute("BfBot.Persist._INI_DEFAULTS = T_Defaults")
    assert passed is False
    assert ("CRITICAL: the suite stopped: could not isolate the player's state,"
            " nothing was run" in output(world))
    assert ran(world) == []
    assert world.eval("BfBot._logHandle") is None
    player.assert_untouched()


def test_run_all_reports_an_ini_key_it_could_not_remove(world: LuaRuntime) -> None:
    stub_phases(world, {"Mp": "BfBot.Persist.SetPref('MpControlMode', 'all'); return true"})
    world.execute("Infinity_RemoveINIEntry = nil")
    player = Player(world)

    passed = world.globals().BfBot.Test.RunAll()

    assert passed is False
    assert ("CRITICAL: could not restore baldur.ini [BuffBot] MpControlMode (was absent)"
            in output(world))
    changed = player.changes()
    assert set(changed) == {"ini"}
    assert "MpControlMode=string:all" in changed["ini"][1]


def test_run_all_without_ini_strings_restores_the_numeric_prefs(world: LuaRuntime) -> None:
    # Without Infinity_GetINIString an absent key reads as its default, so the
    # guard can only compare values, and only numbers read back at all.
    stub_phases(world, {"MovablePanel":
                        "BfBot.UI._ResetLayout(); BfBot.Persist.SetPref('FontSize', 1);"
                        " return true"})
    world.execute("Infinity_GetINIString = nil")
    before = dict(world.globals().T_Ini.BuffBot.items())

    passed = world.globals().BfBot.Test.RunAll()

    assert passed is True
    after = dict(world.globals().T_Ini.BuffBot.items())
    for key in ["PanelX", "PanelY", "PanelW", "PanelH", "FontSize"]:
        assert after[key] == before[key], key


# ------------------------------------------------------------ structure

def phase_body(name: str) -> str:
    match = re.search(rf"^function BfBot\.Test\.{name}\(\)\n(.*?)^end\n",
                      TEST_SOURCE, re.S | re.M)
    assert match, name
    return match.group(1)


@pytest.mark.parametrize("name, section", sorted(GUARDED_PHASES.items()))
def test_every_phase_that_writes_player_state_runs_guarded(name: str, section: str) -> None:
    code = [line for line in phase_body(name).split("\n")
            if line.strip() and not line.strip().startswith("--")]
    assert code[0] == f'    return _GuardPhase("{section}", function()'
    assert code[-1] == "    end)"


def test_run_all_runs_inside_the_player_state_guard() -> None:
    assert "local ran, allOk, problems = _WithPlayerState(function()" in RUN_ALL_BODY
    assert RUN_ALL_BODY.rstrip().endswith("return ran and allOk and #problems == 0")
    assert RUN_ALL_BODY.index("BfBot._OpenLog()") < RUN_ALL_BODY.index("_WithPlayerState")
    assert RUN_ALL_BODY.rindex("BfBot._CloseLog()") > RUN_ALL_BODY.rindex("end)")


# Calls through which a phase writes what the save, baldur.ini or the
# presets folder keeps.
WRITERS = re.compile(
    r"BfBot\.Persist\.(?:Set\w+|ImportConfig|ExportConfig|_Import|CreatePreset"
    r"|DeletePreset|RenamePreset|GetConfig|GetSummonPreset|GetPreset"
    r"|GetActivePreset)\b"
    r"|EEex_GetUDAux|Infinity_SetINI\w+|Infinity_RemoveINIEntry|os\.remove|io\.open"
    r"|BfBot\.Class\.SetOverride|BfBot\._overrides"
    r"|BfBot\.Exec\.(?:Start|Stop|_Complete|_ForceComplete|_SafetyTick|_RecoverItemSwaps)\b"
    r"|BfBot\.Theme\._SetFontSize|BfBot\.UI\._(?:ResetLayout|SaveLayout|OnDrag|OnResize)\b")
UNGUARDED = sorted(set(RUN_ALL_PHASES) - set(GUARDED_PHASES))


@pytest.mark.parametrize("name", UNGUARDED)
def test_unguarded_phases_reach_no_writer(name: str) -> None:
    code = "\n".join(line for line in phase_body(name).split("\n")
                     if not line.strip().startswith("--"))
    assert WRITERS.findall(code) == []


@pytest.mark.parametrize("name", UNGUARDED)
def test_unguarded_phases_leave_the_players_state_as_it_was(
    world: LuaRuntime, name: str
) -> None:
    player = Player(world)

    world.eval(f"BfBot.Test.{name}()")

    run_queued(world)
    player.assert_untouched()


def test_every_buffbot_ini_key_is_kept_by_the_guard() -> None:
    defaults = re.search(r"BfBot\.Persist\._INI_DEFAULTS = \{(.*?)\n\}", PERSIST_SOURCE, re.S)
    kept = set(re.findall(r"^\s+(\w+)\s*=", defaults.group(1), re.M))
    extra = re.search(r"local _EXTRA_INI_KEYS = \{([^}]*)\}", TEST_SOURCE)
    kept |= set(re.findall(r'"(\w+)"', extra.group(1)))
    written = set()
    for source in SOURCES.values():
        written |= set(re.findall(r'SetPref[(,]\s*"(\w+)"', source))
        written |= set(re.findall(
            r'Infinity_(?:SetINI\w+|RemoveINIEntry)[(,]\s*"BuffBot",\s*"(\w+)"', source))
    assert {"BB_TestKey", "Debug", "RefreshBelow"} <= written
    assert written <= kept
