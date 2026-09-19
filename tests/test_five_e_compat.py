"""5E Spellcasting (UnearthedArcana/Subtledoctor) compatibility adapter.

The synthetic resources below mirror what upstream's process_semi_spells
generates (lib/semi_spontaneous.tpa at 5E_spellcasting 2.7.2): innate wrapper
``d5z<IND>i`` whose payload op146/op148 casts the mapped spell, self-targeted
bookkeeping op146 children (level debit, wrapper strip, delayed regrant), and
``d5zclons.2da`` rows ``IND MEM CAST TYPE PROCESSED``. These tests prove the
BuffBot side of the seam; they cannot prove engine behaviour.
"""

from __future__ import annotations

from pathlib import Path
import re

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LOC_SOURCE = (ROOT / "buffbot/BfBotLoc.lua").read_text(encoding="utf-8")
CLASS_SOURCE = (ROOT / "buffbot/BfBotCls.lua").read_text(encoding="utf-8")
SCAN_SOURCE = (ROOT / "buffbot/BfBotScn.lua").read_text(encoding="utf-8")
FIVE_SOURCE = (ROOT / "buffbot/BfBot5e.lua").read_text(encoding="utf-8")
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")
EXEC_SOURCE = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")
MAIN_SOURCE = (ROOT / "buffbot/M_BfBot.lua").read_text(encoding="utf-8")


FIELDS = """
    _fields = {
        fb_count = "effectCount",
        fb_start = "startingEffect",
        friendly_flags = "type",
        fb_opcode = "effectID",
        fb_timing = "durationType",
        fb_duration = "duration",
        fb_param1 = "effectAmount",
        fb_param2 = "dwFlags",
        fb_target = "targetType",
        fb_res = "res",
        fb_special = "special",
    },
"""

# Synthetic engine: resources, d5zclons.2da, SPLSTATE.IDS, sprites.
WORLD = r"""
BfBot_Warnings = {}
BfBot_TestResources = {}
T_Table = nil
T_Load2DACalls = 0
T_States = { D5_SEMI_ARCANE = 190, D5_SEMI_DIVINE = 191 }

BfBot.Class._IterateFeatureBlocks = function(_, ability, fn)
    for i, effect in ipairs(ability.effects or {}) do
        if fn(effect, i - 1) then return end
    end
end

function T_Ability(effects, actionType)
    -- Feature-block resources are CResRef userdata in EEex (read via :get()).
    for _, effect in ipairs(effects) do
        if type(effect.res) == "string" then
            local res = effect.res
            local ref = newproxy(true)
            getmetatable(ref).__index = { get = function() return res end }
            effect.res = ref
        end
    end
    return {
        actionType = actionType or 5,
        type = 0,
        effectCount = #effects,
        startingEffect = 0,
        effects = effects,
        quickSlotIcon = { get = function() return "ICON" end },
    }
end

function T_Spell(resref, opts)
    opts = opts or {}
    local ability = T_Ability(opts.effects or {
        { effectID = 16, durationType = 0, duration = 300, targetType = 2 },
    }, opts.actionType)
    local header = {
        secondaryType = 0,
        itemType = opts.itemType or 1,
        spellLevel = opts.level or 3,
        genericName = opts.nameRef or 7,
        identifiedName = opts.nameRef or 7,
    }
    header.getAbility = function(_, index)
        if index == 0 then return ability end
        return nil
    end
    header.getAbilityForLevel = function() return ability end
    BfBot_TestResources[resref] = header
    return header
end

-- Upstream wrapper shape (process_semi_spells): payload first, then the
-- self-targeted level debit, the strip-all helper, and the 1s delayed regrant.
function T_Wrapper(ind, cast, opts)
    opts = opts or {}
    local payload = opts.area
        and { effectID = 148, res = cast, durationType = 1, targetType = 1 }
        or { effectID = 146, res = cast, durationType = 9, targetType = 2 }
    local effects = {
        payload,
        { effectID = 146, res = opts.debit or "D5SRC-3", durationType = 1, targetType = 1 },
        { effectID = 146, res = "D5ZZ172", durationType = 1, targetType = 1 },
        { effectID = 146, res = "D5ZSPLD", durationType = 4,
          duration = opts.delay or 1, targetType = 1 },
        { effectID = 146, res = "D5ZSPLA", durationType = 4,
          duration = opts.delay or 1, targetType = 1 },
        { effectID = 326, res = "D5ZZFAT", durationType = 1, targetType = 1 },
    }
    return T_Spell("D5Z" .. ind .. "I", { effects = effects, itemType = 4 })
end

local function tda(rows)
    local labels = { "MEM", "CAST", "TYPE", "PROCESSED" }
    local keys = { "mem", "cast", "type", "processed" }
    local t = {}
    function t:getDimensions() return 5, #rows end
    function t:getRowLabel(y) return rows[y + 1].label end
    function t:getColumnLabel(x) return labels[x + 1] or "" end
    function t:getAtPoint(x, y)
        local row = rows[y + 1]
        if not row or not keys[x + 1] then return "IND" end
        return row[keys[x + 1]]
    end
    return t
end

EEex_Resource_Fetch = function(resref, ext)
    if ext == "2DA" and resref == "D5ZCLONS" and T_Table then return {} end
    return nil
end
EEex_Resource_Load2DA = function(resref)
    T_Load2DACalls = T_Load2DACalls + 1
    assert(resref == "D5ZCLONS")
    return tda(T_Table or {})
end
EEex_Resource_Demand = function(resref, kind)
    assert(kind == "SPL")
    return BfBot_TestResources[resref]
end
EEex_Resource_LoadIDS = function(name)
    assert(name == "SPLSTATE")
    return {}
end
EEex_Resource_IterateUnpackedIDSEntries = function(_, fn)
    for symbol, id in pairs(T_States) do
        if fn(id, symbol, symbol) then return end
    end
end
EEex_Utility_IterateCPtrList = function(list, fn)
    for _, v in ipairs(list) do
        if fn(v) then return end
    end
end
EEex_Utility_FreeCPtrList = function() end
EEex_Sprite_GetPortraitIndex = function() return -1 end
Infinity_FetchString = function(ref) return "Spell" .. tostring(ref) end

local function knownIterator(list)
    return function(sprite)
        local i = 0
        return function()
            i = i + 1
            local resref = sprite[list][i]
            if resref == nil then return nil end
            return 0, i - 1, resref, nil
        end
    end
end
EEex_Sprite_GetKnownMageSpellsWithAbilityIterator = knownIterator("mage")
EEex_Sprite_GetKnownPriestSpellsWithAbilityIterator = knownIterator("priest")
EEex_Sprite_GetKnownInnateSpellsWithAbilityIterator = knownIterator("innate")

function T_Sprite(opts)
    local sprite = {
        m_id = opts.id or 500,
        name = opts.name or "Caster",
        mage = opts.mage or {},
        priest = opts.priest or {},
        innate = opts.innate or {},
        buttons = opts.buttons or {},
        states = opts.states or {},
        m_timedEffectList = {},
    }
    for _, source in ipairs(opts.effects or {}) do
        table.insert(sprite.m_timedEffectList, {
            m_sourceRes = { get = function() return source end },
        })
    end
    function sprite:getSpellState(id) return self.states[id] == true end
    function sprite:getCasterLevelForSpell() return 10 end
    function sprite:GetQuickButtons(btnType)
        local list = {}
        for resref, count in pairs(self.buttons[btnType] or {}) do
            list[#list + 1] = {
                m_abilityId = { m_res = { get = function() return resref end } },
                m_count = count,
            }
        end
        return list
    end
    return sprite
end

function T_Row(label, mem, cast, kind, processed)
    return { label = label, mem = mem, cast = cast, type = kind,
             processed = processed or "yes" }
end
"""


def _runtime() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    # Hot scan loops make LuaJIT record traces; each trace abort unwinds via a
    # handled SEH exception that pytest's faulthandler prints on Windows as a
    # "fatal exception". Interpreted and compiled semantics are identical.
    runtime.execute("jit.off()")
    return runtime


@pytest.fixture
def scan_lua() -> LuaRuntime:
    runtime = _runtime()
    runtime.execute(
        "BfBot = { Class = {}, Scan = {}, _cache = { class = {}, scan = {} },"
        " _overrides = {}, _Log = function() end, _Print = function() end,"
        " _Warn = function(m) table.insert(BfBot_Warnings, m) end,"
        " _GetName = function(s) return s and s.name or '?' end,"
        + FIELDS
        + "}"
    )
    runtime.execute(CLASS_SOURCE)
    runtime.execute(WORLD)
    runtime.execute(SCAN_SOURCE)
    runtime.execute(FIVE_SOURCE)
    return runtime


def _scan(runtime: LuaRuntime, body: str):
    return runtime.execute(body)


# ----------------------------------------------------------------------
# Mapping table
# ----------------------------------------------------------------------


def test_map_parses_upstream_rows_and_reports_only_real_malformed_rows(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        local map = assert(BfBot.FiveE._BuildMap({
            T_Row("100", "#", "#", "#", "#"),             -- upstream placeholder
            T_Row("101", "spwi305", "spwi305", "arcane"),
            T_Row(" 150 ", "FNP101A ", "SPPR101", "Divine", "no"),
            T_Row("150", "SPPR101", "SPPR101", "divine"),
            T_Row("abc", "SPWI112", "SPWI112", "arcane"), -- non-numeric index
            T_Row("10000", "SPWI113", "SPWI113", "arcane"), -- 9-char wrapper
            T_Row("102", "SPWI114", "", "arcane"),         -- no cast spell
            T_Row("103", "TOOLONGRESREF", "X", "arcane"),  -- invalid resref
        }))
        local shared = map.byIndex[150]
        return {
            rows = map.rowCount,
            dropped = map.dropped,
            wrapper101 = map.byWrapper["D5Z101I"],
            mem101 = map.byIndex[101].rows[1].mem,
            sharedRows = #shared.rows,
            sharedWrapper = shared.wrapper,
            fnpCast = map.byMem["FNP101A"][1].cast,
            fnpType = map.byMem["FNP101A"][1].type,
            fnpProcessed = map.byMem["FNP101A"][1].processed,
            block = map.byIndex[101].rows[1].block,
            hasPlaceholder = map.byWrapper["D5Z100I"] ~= nil,
        }
        """
    )

    assert facts["rows"] == 3
    assert facts["dropped"] == 4
    assert facts["wrapper101"] == 101
    assert facts["mem101"] == "SPWI305"
    assert facts["sharedRows"] == 2
    assert facts["sharedWrapper"] == "D5Z150I"
    assert facts["fnpCast"] == "SPPR101"
    assert facts["fnpType"] == "divine"
    assert facts["fnpProcessed"] == 0
    assert facts["block"] == "D5Z101B"
    assert not facts["hasPlaceholder"]


def test_missing_table_is_a_cached_no_op_without_loading_the_2da(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        T_Spell("SPWI305")
        local sprite = T_Sprite({ mage = { "SPWI305" },
                                  buttons = { [2] = { SPWI305 = 2 } },
                                  states = { [190] = true } })
        local spells, count = BfBot.Scan.GetCastableSpells(sprite)
        BfBot.Scan.Invalidate(sprite)
        BfBot.Scan.GetCastableSpells(sprite)
        return {
            count = count,
            native = spells.SPWI305.count,
            hasD5 = spells.SPWI305.d5 ~= nil,
            installed = BfBot.FiveE.IsInstalled(),
            loads = T_Load2DACalls,
            reason = BfBot.FiveE._mapReason,
        }
        """
    )

    assert facts["count"] == 1
    assert facts["native"] == 2
    assert not facts["hasD5"]
    assert not facts["installed"]
    assert facts["loads"] == 0
    assert facts["reason"] == "absent"


# ----------------------------------------------------------------------
# Scanner overlay
# ----------------------------------------------------------------------


def test_prepared_spell_takes_wrapper_count_and_unprepared_spell_is_gated(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        T_Table = {
            T_Row("100", "#", "#", "#", "#"),
            T_Row("101", "SPWI305", "SPWI305", "arcane"),
            T_Row("102", "SPWI306", "SPWI306", "arcane"),
        }
        T_Spell("SPWI305")
        T_Spell("SPWI306")
        T_Wrapper(101, "SPWI305")
        T_Wrapper(102, "SPWI306")
        -- SPWI305 prepared (wrapper granted); SPWI306 known but unprepared.
        -- A stale native memorization of SPWI306 must not become a cast.
        local sprite = T_Sprite({
            mage = { "SPWI305", "SPWI306" },
            innate = { "D5Z101I" },
            buttons = { [2] = { D5Z101I = 3, SPWI306 = 1 } },
            states = { [190] = true },
            effects = { "D5Z102B" },
        })
        local spells, count = BfBot.Scan.GetCastableSpells(sprite)
        local prepared = spells.SPWI305
        local unprepared = spells.SPWI306
        local keys = {}
        for resref in pairs(spells) do keys[#keys + 1] = resref end
        table.sort(keys)
        return {
            keys = table.concat(keys, ","),
            count = count,
            preparedCount = prepared.count,
            wrapper = prepared.d5.wrapper,
            cast = prepared.d5.cast,
            delay = prepared.d5.delay,
            available = prepared.d5.available,
            kind = prepared.kind,
            spellType = prepared.spellType,
            leafs = table.concat(prepared.leafResrefs, ","),
            unpreparedCount = unprepared.count,
            unpreparedAvailable = unprepared.d5.available,
            unpreparedWrapper = unprepared.d5.wrapper,
            reason = BfBot.FiveE.UnavailableReason(sprite, unprepared),
        }
        """
    )

    assert facts["keys"] == "SPWI305,SPWI306"
    assert facts["count"] == 2
    assert facts["preparedCount"] == 3
    assert facts["wrapper"] == "D5Z101I"
    assert facts["cast"] == "SPWI305"
    assert facts["delay"] == 1
    assert facts["available"] == 1
    assert facts["kind"] == "spl"
    assert facts["spellType"] == 1
    # The wrapper's own bookkeeping children must never become leafs.
    assert facts["leafs"] == "SPWI305"
    assert facts["unpreparedCount"] == 0
    assert facts["unpreparedAvailable"] == 0
    assert facts["unpreparedWrapper"] == "D5Z102I"
    assert facts["reason"] == "no slot - 5E: spell not prepared"


def test_two_prepared_spells_share_the_level_pool_count(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        T_Table = {
            T_Row("101", "SPWI305", "SPWI305", "arcane"),
            T_Row("102", "SPWI306", "SPWI306", "arcane"),
        }
        T_Spell("SPWI305"); T_Spell("SPWI306")
        T_Wrapper(101, "SPWI305"); T_Wrapper(102, "SPWI306")
        local sprite = T_Sprite({
            mage = { "SPWI305", "SPWI306" },
            innate = { "D5Z101I", "D5Z102I" },
            -- Location-2 innates may be listed under both buttons: the
            -- shared pool is 2, never 4.
            buttons = { [2] = { D5Z101I = 2, D5Z102I = 2 },
                        [4] = { D5Z101I = 2, D5Z102I = 2 } },
            states = { [190] = true },
        })
        local spells = BfBot.Scan.GetCastableSpells(sprite)
        local first = { spells.SPWI305.count, spells.SPWI306.count }
        -- After one cast upstream regrants both wrappers at the new pool size.
        sprite.buttons = { [2] = { D5Z101I = 1, D5Z102I = 1 } }
        BfBot.Scan.Invalidate(sprite)
        spells = BfBot.Scan.GetCastableSpells(sprite)
        local second = { spells.SPWI305.count, spells.SPWI306.count }
        -- Pool exhausted: upstream grants nothing.
        sprite.buttons = {}
        sprite.innate = {}
        BfBot.Scan.Invalidate(sprite)
        spells = BfBot.Scan.GetCastableSpells(sprite)
        return {
            first = first[1] .. "/" .. first[2],
            second = second[1] .. "/" .. second[2],
            exhausted = spells.SPWI305.count .. "/" .. spells.SPWI306.count,
            exhaustedReason = BfBot.FiveE.UnavailableReason(sprite, spells.SPWI305),
        }
        """
    )

    assert facts["first"] == "2/2"
    assert facts["second"] == "1/1"
    assert facts["exhausted"] == "0/0"
    assert facts["exhaustedReason"] == "no slot - 5E: no casts left at this level"


def test_shared_index_with_mem_different_from_cast_uses_cast_effect_identity(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        -- Faiths & Powers sphere copy: MEM FNP101A casts the real SPPR101
        -- through the same wrapper index as SPPR101 itself.
        T_Table = {
            T_Row("150", "SPPR101", "SPPR101", "divine"),
            T_Row("150", "FNP101A", "SPPR101", "divine"),
        }
        T_Spell("FNP101A", { itemType = 2, level = 1, effects = {
            { effectID = 328, dwFlags = 55, durationType = 0, duration = 60 },
        } })
        T_Spell("SPPR101", { itemType = 2, level = 1, effects = {
            { effectID = 328, dwFlags = 29, durationType = 0, duration = 600 },
            { effectID = 146, res = "SPPR101B", durationType = 1 },
        } })
        T_Spell("SPPR101B", { itemType = 2, level = 1, effects = {
            { effectID = 328, dwFlags = 30, durationType = 0, duration = 600 },
        } })
        T_Wrapper(150, "SPPR101", { debit = "D5SHM-1" })
        local sprite = T_Sprite({
            priest = { "FNP101A" },
            innate = { "D5Z150I" },
            buttons = { [2] = { D5Z150I = 4 } },
            states = { [191] = true },
        })
        local spells, count = BfBot.Scan.GetCastableSpells(sprite)
        local row = spells.FNP101A
        local markers = row.stateMarkersByResref or {}
        return {
            count = count,
            hasCastRow = spells.SPPR101 ~= nil,
            rowCount = row.count,
            cast = row.d5.cast,
            family = row.d5.type,
            leafs = table.concat(row.leafResrefs, ","),
            castMarker = markers.SPPR101 and markers.SPPR101[1] or -1,
            leafMarker = markers.SPPR101B and markers.SPPR101B[1] or -1,
            memMarker = markers.FNP101A ~= nil,
            duration = row.duration,
        }
        """
    )

    assert facts["count"] == 1
    assert not facts["hasCastRow"]
    assert facts["rowCount"] == 4
    assert facts["cast"] == "SPPR101"
    assert facts["family"] == "divine"
    assert facts["leafs"] == "SPPR101B"
    assert facts["castMarker"] == 29
    assert facts["leafMarker"] == 30
    assert not facts["memMarker"]
    assert facts["duration"] == 600


def test_mid_refresh_row_keeps_cast_identity_for_queue_building(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        -- Same Faiths & Powers shape, but the queue is built while upstream
        -- has stripped every wrapper: the row must already carry CAST's
        -- effect identity, because queue entries keep build-time leafs.
        T_Table = { T_Row("150", "FNP101A", "SPPR101", "divine") }
        T_Spell("FNP101A", { itemType = 2, level = 1 })
        T_Spell("SPPR101", { itemType = 2, level = 1, effects = {
            { effectID = 146, res = "SPPR101B", durationType = 1 },
        } })
        T_Spell("SPPR101B", { itemType = 2, level = 1 })
        T_Wrapper(150, "SPPR101", { debit = "D5SHM-1" })
        local sprite = T_Sprite({
            priest = { "FNP101A" },
            buttons = { [2] = { FNP101A = 1 } },
            states = { [191] = true },
        })
        local row = BfBot.Scan.GetCastableSpells(sprite).FNP101A
        return {
            count = row.count,
            available = row.d5.available,
            leafs = table.concat(row.leafResrefs, ","),
        }
        """
    )

    assert facts["count"] == 0
    assert facts["available"] == 0
    assert facts["leafs"] == "SPPR101B"


def test_free_cast_wrapper_for_unknown_spell_gets_a_logical_row(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        T_Table = { T_Row("103", "SPWI401", "SPWI401", "arcane") }
        T_Spell("SPWI401", { level = 4 })
        T_Wrapper(103, "SPWI401", { debit = "D5SRC-4" })
        local sprite = T_Sprite({
            innate = { "D5Z103I" },
            buttons = { [2] = { D5Z103I = 1 } },
            states = { [190] = true },
        })
        local spells, count = BfBot.Scan.GetCastableSpells(sprite)
        local row = spells.SPWI401
        return {
            count = count,
            hasWrapper = spells.D5Z103I ~= nil,
            rowCount = row and row.count or -1,
            spellType = row and row.spellType or -1,
            level = row and row.level or -1,
            wrapper = row and row.d5.wrapper or "",
        }
        """
    )

    assert facts["count"] == 1
    assert not facts["hasWrapper"]
    assert facts["rowCount"] == 1
    assert facts["spellType"] == 1
    assert facts["level"] == 4
    assert facts["wrapper"] == "D5Z103I"


def test_untrusted_wrapper_is_hidden_and_its_spell_stays_unavailable(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        -- The table says index 104 casts SPWI501, but the installed wrapper's
        -- payload casts something else: never trust or cast it.
        T_Table = { T_Row("104", "SPWI501", "SPWI501", "arcane") }
        T_Spell("SPWI501")
        T_Wrapper(104, "SPWI999")
        local sprite = T_Sprite({
            mage = { "SPWI501" },
            innate = { "D5Z104I" },
            buttons = { [2] = { D5Z104I = 2, SPWI501 = 1 } },
            states = { [190] = true },
        })
        local spells, count = BfBot.Scan.GetCastableSpells(sprite)
        return {
            count = count,
            hasWrapper = spells.D5Z104I ~= nil,
            rowCount = spells.SPWI501.count,
            available = spells.SPWI501.d5.available,
            warned = table.concat(BfBot_Warnings, "|"):find("D5Z104I ignored", 1, true) ~= nil,
        }
        """
    )

    assert facts["count"] == 1
    assert not facts["hasWrapper"]
    assert facts["rowCount"] == 0
    assert facts["available"] == 0
    assert facts["warned"]


def test_unconverted_caster_keeps_native_counts(scan_lua: LuaRuntime) -> None:
    facts = scan_lua.execute(
        """
        T_Table = { T_Row("101", "SPWI305", "SPWI305", "arcane") }
        T_Spell("SPWI305")
        T_Wrapper(101, "SPWI305")
        -- Sorcerer / unconverted class: no 5E state, no wrappers.
        local sprite = T_Sprite({
            mage = { "SPWI305" },
            buttons = { [2] = { SPWI305 = 2 } },
        })
        local spells = BfBot.Scan.GetCastableSpells(sprite)
        return { count = spells.SPWI305.count, hasD5 = spells.SPWI305.d5 ~= nil }
        """
    )

    assert facts["count"] == 2
    assert not facts["hasD5"]


def test_converted_caster_mid_refresh_never_falls_back_to_native_slots(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        T_Table = { T_Row("101", "SPWI305", "SPWI305", "arcane") }
        T_Spell("SPWI305")
        T_Wrapper(101, "SPWI305")
        -- State says converted; wrappers are stripped (refresh in flight) and
        -- a native memorization is still listed (post-rest window).
        local sprite = T_Sprite({
            mage = { "SPWI305" },
            buttons = { [2] = { SPWI305 = 1 } },
            states = { [190] = true },
        })
        local spells = BfBot.Scan.GetCastableSpells(sprite)
        return {
            count = spells.SPWI305.count,
            available = spells.SPWI305.d5.available,
            wrapper = spells.SPWI305.d5.wrapper,
        }
        """
    )

    assert facts["count"] == 0
    assert facts["available"] == 0
    assert facts["wrapper"] == "D5Z101I"


def test_wrapper_presence_manages_only_its_family_without_state_ids(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        T_States = {}   -- SPLSTATE symbols unavailable
        T_Table = {
            T_Row("101", "SPWI305", "SPWI305", "arcane"),
            T_Row("102", "SPWI306", "SPWI306", "arcane"),
            T_Row("201", "SPPR201", "SPPR201", "divine"),
        }
        T_Spell("SPWI305"); T_Spell("SPWI306")
        T_Spell("SPPR201", { itemType = 2, level = 2 })
        T_Wrapper(101, "SPWI305"); T_Wrapper(102, "SPWI306")
        T_Wrapper(201, "SPPR201", { debit = "D5SHM-2" })
        local sprite = T_Sprite({
            mage = { "SPWI305", "SPWI306" },
            priest = { "SPPR201" },
            innate = { "D5Z101I" },
            buttons = { [2] = { D5Z101I = 2, SPWI306 = 1, SPPR201 = 1 } },
        })
        local spells = BfBot.Scan.GetCastableSpells(sprite)
        return {
            arcanePrepared = spells.SPWI305.count,
            arcaneGated = spells.SPWI306.count,
            divineNative = spells.SPPR201.count,
            divineD5 = spells.SPPR201.d5 ~= nil,
            warned = table.concat(BfBot_Warnings, "|"):find(
                "relying on wrapper presence", 1, true) ~= nil,
        }
        """
    )

    assert facts["arcanePrepared"] == 2
    assert facts["arcaneGated"] == 0
    assert facts["divineNative"] == 1
    assert not facts["divineD5"]
    assert facts["warned"]


def test_area_wrapper_payload_and_declared_delay_are_read_from_the_wrapper(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        T_Table = { T_Row("110", "SPWI312", "SPWI312", "arcane") }
        T_Spell("SPWI312", { actionType = 4 })
        T_Wrapper(110, "SPWI312", { area = true, delay = 2 })
        local sprite = T_Sprite({
            mage = { "SPWI312" },
            innate = { "D5Z110I" },
            buttons = { [4] = { D5Z110I = 1 } },
            states = { [190] = true },
        })
        local spells = BfBot.Scan.GetCastableSpells(sprite)
        local huge = BfBot.FiveE._BuildMap({ T_Row("111", "SPWI313", "SPWI313", "arcane") })
        T_Spell("SPWI313")
        T_Wrapper(111, "SPWI313", { delay = 3600 })
        local capped = BfBot.FiveE._WrapperMeta(huge, "D5Z111I")
        return {
            count = spells.SPWI312.count,
            cast = spells.SPWI312.d5.cast,
            delay = spells.SPWI312.d5.delay,
            cappedDelay = capped.delay,
        }
        """
    )

    assert facts["count"] == 1
    assert facts["cast"] == "SPWI312"
    assert facts["delay"] == 2
    assert facts["cappedDelay"] == 6


def test_overlay_failure_fails_closed(scan_lua: LuaRuntime) -> None:
    facts = scan_lua.execute(
        """
        T_Table = { T_Row("101", "SPWI305", "SPWI305", "arcane") }
        T_Spell("SPWI305")
        T_Wrapper(101, "SPWI305")
        BfBot.FiveE.ManagedTypes = function() error("synthetic failure") end
        local sprite = T_Sprite({
            mage = { "SPWI305" },
            innate = { "D5Z101I" },
            buttons = { [2] = { D5Z101I = 2, SPWI305 = 1 } },
            states = { [190] = true },
        })
        local spells, count = BfBot.Scan.GetCastableSpells(sprite)
        return {
            count = count,
            hasWrapper = spells.D5Z101I ~= nil,
            rowCount = spells.SPWI305.count,
            warned = table.concat(BfBot_Warnings, "|"):find(
                "overlay failed", 1, true) ~= nil,
        }
        """
    )

    assert facts["count"] == 1
    assert not facts["hasWrapper"]
    assert facts["rowCount"] == 0
    assert facts["warned"]


def test_mixed_family_index_does_not_manage_the_other_side_of_a_multiclass(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        -- add_semi_spells can register an arcane MEM that casts a priest
        -- spell; upstream then reuses that index for the priest spell itself,
        -- so index 101 carries one arcane and one divine row. A divine-only
        -- convert (sorcerer-cleric kit, Cleric->Mage dual before the switch)
        -- holding that wrapper must keep casting its arcane spells natively.
        -- Both row orders, so picking either row's family mismanages one.
        T_States = {}
        T_Table = {
            T_Row("101", "D5NW8", "SPPR607", "arcane"),
            T_Row("101", "SPPR607", "SPPR607", "divine"),
            T_Row("103", "SPPR501", "SPPR501", "divine"),
            T_Row("103", "D5NW9", "SPPR501", "arcane"),
            T_Row("102", "SPWI305", "SPWI305", "arcane"),
        }
        T_Spell("SPPR607", { itemType = 2, level = 6 })
        T_Spell("SPPR501", { itemType = 2, level = 5 })
        T_Spell("SPWI305")
        T_Wrapper(101, "SPPR607", { debit = "D5SHM-6" })
        T_Wrapper(103, "SPPR501", { debit = "D5SHM-5" })
        T_Wrapper(102, "SPWI305")
        local sprite = T_Sprite({
            mage = { "SPWI305" },
            priest = { "SPPR607", "SPPR501" },
            innate = { "D5Z101I", "D5Z103I" },
            buttons = { [2] = { D5Z101I = 2, D5Z103I = 1, SPWI305 = 2 } },
        })
        local spells = BfBot.Scan.GetCastableSpells(sprite)
        return {
            divine = spells.SPPR607.count,
            divineFamily = spells.SPPR607.d5.type,
            divine2 = spells.SPPR501.count,
            arcaneNative = spells.SPWI305.count,
            arcaneD5 = spells.SPWI305.d5 ~= nil,
        }
        """
    )

    assert facts["divine"] == 2
    assert facts["divineFamily"] == "divine"
    assert facts["divine2"] == 1
    assert facts["arcaneNative"] == 2
    assert not facts["arcaneD5"]


def test_stripped_wrappers_mark_prepared_rows_pending_but_not_blocked_ones(
    scan_lua: LuaRuntime,
) -> None:
    facts = scan_lua.execute(
        """
        -- Right after any wrapper cast, upstream's d5zz172 strips every
        -- wrapper and regrants them ~1s later. A prepared spell is pending
        -- (queueable, the executor waits); an unprepared one still carries
        -- its block effect and stays out of the queue.
        T_Table = {
            T_Row("101", "SPWI305", "SPWI305", "arcane"),
            T_Row("102", "SPWI306", "SPWI306", "arcane"),
        }
        T_Spell("SPWI305"); T_Spell("SPWI306")
        T_Wrapper(101, "SPWI305"); T_Wrapper(102, "SPWI306", { delay = 2 })
        local sprite = T_Sprite({
            mage = { "SPWI305", "SPWI306" },
            states = { [190] = true },
            effects = { "D5Z102B" },
        })
        local spells = BfBot.Scan.GetCastableSpells(sprite)
        local prepared, blocked = spells.SPWI305, spells.SPWI306
        -- With a wrapper of any index back, the gap is over: a row with no
        -- casts of its own is exhausted, not refreshing.
        sprite.innate = { "D5Z102I" }
        sprite.buttons = { [2] = { D5Z102I = 1 } }
        BfBot.Scan.Invalidate(sprite)
        local after = BfBot.Scan.GetCastableSpells(sprite).SPWI305
        return {
            preparedPending = prepared.d5.pending or 0,
            preparedDelay = prepared.d5.delay,
            preparedAwaiting = BfBot.FiveE.AwaitingRefresh(prepared),
            blockedPending = blocked.d5.pending or 0,
            blockedAwaiting = BfBot.FiveE.AwaitingRefresh(blocked),
            afterPending = after.d5.pending or 0,
            itemGuard = BfBot.FiveE.AwaitingRefresh(
                { kind = "itm", count = 0, d5 = { pending = 1 } }),
        }
        """
    )

    assert facts["preparedPending"] == 1
    assert facts["preparedDelay"] == 1
    assert facts["preparedAwaiting"] is True
    assert facts["blockedPending"] == 0
    assert facts["blockedAwaiting"] is False
    assert facts["afterPending"] == 0
    assert facts["itemGuard"] is False


# ----------------------------------------------------------------------
# Execution
# ----------------------------------------------------------------------


@pytest.fixture
def exec5_lua() -> LuaRuntime:
    runtime = _runtime()
    runtime.execute(
        "BfBot = { MAX_PRESETS = 8, MAX_SPELL_REPEATS = 5,"
        " Scan = {}, Class = {}, Innate = {}, Mp = {},"
        " _cache = { class = {}, scan = {} }, _overrides = {},"
        " _Warn = function(_) end, _Print = function(_) end,"
        " _Log = function(_) end,"
        " _OpenLogAppend = function(_) end, _CloseLog = function() end,"
        " _GetName = function(s) return type(s) == 'table' and (s.name or '?') or tostring(s) end,"
        + FIELDS
        + "}"
    )
    runtime.execute(
        "EEex_BAnd = function() return 0 end\n"
        "EEex_Sprite_DisplayStringHead = function() end\n"
        "io = nil"
    )
    runtime.execute(LOC_SOURCE)
    runtime.execute(PERSIST_SOURCE)
    runtime.execute(EXEC_SOURCE)
    runtime.execute(FIVE_SOURCE)
    runtime.execute(
        r"""
        -- One converted mage with two prepared level-3 buffs sharing a pool.
        function T_ExecWorld(spells)
            local caster = { name = "Mage", m_id = 7, m_baseStats = { m_generalState = 0 },
                             m_timedEffectList = {} }
            EEex_Utility_IterateCPtrList = function(list, fn)
                for _, v in ipairs(list) do if fn(v) then return end end
            end
            T_Now = 1000
            T_Live = {}          -- live quick-button counts {[type]={[res]=n}}
            T_Actions = {}
            BfBot.FiveE._map = assert(BfBot.FiveE._BuildMap({
                { label = "101", mem = "SPWI305", cast = "SPWI305", type = "arcane", processed = "yes" },
                { label = "102", mem = "SPWI306", cast = "SPWI306", type = "arcane", processed = "yes" },
            }))
            BfBot.Exec._ResolveCaster = function() return caster end
            BfBot.Exec._ResolveCasterForStep = function() return caster end
            BfBot.Exec._IsAlive = function(sprite) return sprite ~= nil end
            BfBot.Exec._DetectCombat = function() return false end
            BfBot.Exec._HasActiveEffect = function() return false end
            BfBot.Exec._NoteProgress = function() end
            BfBot.Exec._GetGameTime = function() return T_Now end
            BfBot.Exec._Complete = function() BfBot.Exec._state = "done" end
            BfBot.Scan.GetCastableSpells = function() return spells end
            BfBot.Scan.Invalidate = function() end
            BfBot.Scan._BuildCountMap = function()
                return {}, { [2] = T_Live[2] or {}, [4] = T_Live[4] or {} }
            end
            EEex_Sprite_GetInPortrait = function(slot)
                if slot == 0 then return caster end
                return nil
            end
            EEex_Sprite_GetCharacterIndex = function() return 0 end
            EEex_Action_QueueResponseStringOnAIBase = function(action, sprite)
                assert(sprite == caster)
                T_Actions[#T_Actions + 1] = action
            end
            return caster
        end

        function T_Row5(resref, wrapper, count)
            return {
                count = count, name = resref, kind = "spl",
                class = { splstates = {} }, leafResrefs = { resref },
                d5 = { wrapper = wrapper, cast = resref, delay = 1,
                       available = count > 0 and 1 or 0, count = count,
                       block = wrapper:sub(1, -2) .. "B" },
            }
        end

        function T_Start(queue)
            local byCaster = assert(BfBot.Exec._BuildQueue(queue, 0))
            BfBot.Exec._state = "running"
            BfBot.Exec._castCount = 0
            BfBot.Exec._skipCount = 0
            BfBot.Exec._activeCasters = 1
            BfBot.Exec._log = {}
            BfBot.Exec._casters = { p0 = {
                ref = { kind = "party", slot = 0 },
                queue = byCaster.p0, index = 0, done = false,
                name = "Mage", cheatBoundary = 0, cheatApplied = false,
            } }
            BfBot.Exec._ProcessCasterEntry("p0", 1)
            return byCaster.p0
        end

        -- Run the next engine-queued LuaAction (advance or resume).
        function T_RunNextLuaAction()
            while #T_Actions > 0 do
                local action = table.remove(T_Actions, 1)
                local fn, key = action:match('EEex_LuaAction%("BfBot%.Exec%.(_%a+)%(%[%[(%w+)%]%]%)"%)')
                if fn then
                    BfBot.Exec[fn](key)
                    return fn
                end
                T_Done[#T_Done + 1] = action
            end
            return nil
        end
        T_Done = {}

        function T_LogText()
            local lines = {}
            for _, e in ipairs(BfBot.Exec._log) do lines[#lines + 1] = e.type .. ": " .. e.msg end
            return table.concat(lines, "\n")
        end
        """
    )
    return runtime


def test_exec_casts_through_wrapper_and_waits_for_upstream_refresh(
    exec5_lua: LuaRuntime,
) -> None:
    facts = exec5_lua.execute(
        """
        local spells = {
            SPWI305 = T_Row5("SPWI305", "D5Z101I", 2),
            SPWI306 = T_Row5("SPWI306", "D5Z102I", 2),
        }
        T_ExecWorld(spells)
        T_Start({
            { caster = 0, spell = "SPWI305", target = "self" },
            { caster = 0, spell = "SPWI306", target = "self" },
        })
        local afterFirst = table.concat(T_Actions, "|")

        -- Wrapper cast finished: upstream stripped every wrapper.
        spells.SPWI305.count = 0; spells.SPWI305.d5.available = 0
        spells.SPWI306.count = 0; spells.SPWI306.d5.available = 0
        local stepped = T_RunNextLuaAction()          -- _Advance
        local waited = table.concat(T_Actions, "|")

        -- Still inside the declared 1 s delay: keep waiting even if the
        -- quick-button list looks populated (removal may lag the advance).
        T_Now = T_Now + 9
        T_Live = { [2] = { D5Z102I = 1 } }
        local resumed1 = T_RunNextLuaAction()         -- _Resume
        local stillWaiting = table.concat(T_Actions, "|")

        -- Regrant done after the delay: pool shrank to 1.
        T_Now = T_Now + 9
        spells.SPWI306.count = 1; spells.SPWI306.d5.available = 1
        local resumed2 = T_RunNextLuaAction()         -- _Resume
        return {
            afterFirst = afterFirst,
            stepped = stepped,
            waited = waited,
            resumed1 = resumed1,
            stillWaiting = stillWaiting,
            resumed2 = resumed2,
            final = table.concat(T_Actions, "|"),
            done = table.concat(T_Done, "|"),
            casts = BfBot.Exec._castCount,
            skips = BfBot.Exec._skipCount,
            log = T_LogText(),
        }
        """
    )

    assert facts["afterFirst"] == (
        'SpellRES("D5Z101I",Myself)|'
        'EEex_LuaAction("BfBot.Exec._Advance([[p0]])")'
    )
    assert facts["stepped"] == "_Advance"
    assert facts["waited"] == (
        'SmallWait(3)|EEex_LuaAction("BfBot.Exec._Resume([[p0]])")'
    )
    assert facts["resumed1"] == "_Resume"
    assert facts["stillWaiting"] == (
        'SmallWait(3)|EEex_LuaAction("BfBot.Exec._Resume([[p0]])")'
    )
    assert facts["resumed2"] == "_Resume"
    assert facts["final"] == (
        'SpellRES("D5Z102I",Myself)|'
        'EEex_LuaAction("BfBot.Exec._Advance([[p0]])")'
    )
    assert "SPWI305" not in facts["done"]
    assert facts["casts"] == 2
    assert facts["skips"] == 0
    assert "(5E D5Z101I)" in facts["log"]
    assert "waiting for 5E spell slots to refresh" in facts["log"]


def test_exec_refresh_wait_ends_when_pool_is_exhausted(
    exec5_lua: LuaRuntime,
) -> None:
    facts = exec5_lua.execute(
        """
        local spells = {
            SPWI305 = T_Row5("SPWI305", "D5Z101I", 1),
            SPWI306 = T_Row5("SPWI306", "D5Z102I", 1),
        }
        T_ExecWorld(spells)
        T_Start({
            { caster = 0, spell = "SPWI305", target = "self" },
            { caster = 0, spell = "SPWI306", target = "self" },
        })
        spells.SPWI305.count = 0; spells.SPWI305.d5.available = 0
        spells.SPWI306.count = 0; spells.SPWI306.d5.available = 0
        T_RunNextLuaAction()                          -- _Advance → wait
        local polls = 0
        while BfBot.Exec._state == "running" and polls < 50 do
            T_Now = T_Now + 3
            if T_RunNextLuaAction() == nil then break end
            polls = polls + 1
        end
        return {
            state = BfBot.Exec._state,
            polls = polls,
            casts = BfBot.Exec._castCount,
            skips = BfBot.Exec._skipCount,
            log = T_LogText(),
        }
        """
    )

    assert facts["state"] == "done"
    # delay (15 ticks) + margin (60 ticks) at 3 ticks per poll, bounded.
    assert 20 <= facts["polls"] <= 30
    assert facts["casts"] == 1
    assert facts["skips"] == 1
    assert "no slot - 5E: no casts left at this level" in facts["log"]


def test_exec_refresh_wait_stops_early_once_any_wrapper_is_regranted(
    exec5_lua: LuaRuntime,
) -> None:
    facts = exec5_lua.execute(
        """
        local spells = {
            SPWI305 = T_Row5("SPWI305", "D5Z101I", 1),
            SPWI306 = T_Row5("SPWI306", "D5Z102I", 1),
        }
        T_ExecWorld(spells)
        T_Start({
            { caster = 0, spell = "SPWI305", target = "self" },
            { caster = 0, spell = "SPWI306", target = "self" },
        })
        spells.SPWI305.count = 0; spells.SPWI305.d5.available = 0
        spells.SPWI306.count = 0; spells.SPWI306.d5.available = 0
        T_RunNextLuaAction()                          -- _Advance → wait
        T_Now = T_Now + 15                            -- delay elapsed
        -- Another level still has casts, so the regrant already ran:
        -- SPWI306's level is empty and waiting longer cannot help.
        T_Live = { [2] = { D5Z120I = 1 } }
        BfBot.FiveE._map.byWrapper.D5Z120I = 120
        T_RunNextLuaAction()                          -- _Resume → skip → done
        return {
            state = BfBot.Exec._state,
            skips = BfBot.Exec._skipCount,
            pending = table.concat(T_Actions, "|"),
        }
        """
    )

    assert facts["state"] == "done"
    assert facts["skips"] == 1
    assert facts["pending"] == ""


def test_exec_repeat_attempts_wait_between_wrapper_casts(
    exec5_lua: LuaRuntime,
) -> None:
    facts = exec5_lua.execute(
        """
        local spells = { SPWI305 = T_Row5("SPWI305", "D5Z101I", 2) }
        T_ExecWorld(spells)
        T_Start({ { caster = 0, spell = "SPWI305", target = "self", rep = 2 } })
        spells.SPWI305.count = 0; spells.SPWI305.d5.available = 0
        T_RunNextLuaAction()                          -- _Advance → wait
        local waiting = T_Actions[1]
        T_Now = T_Now + 15
        T_Live = { [2] = { D5Z101I = 1 } }
        spells.SPWI305.count = 1; spells.SPWI305.d5.available = 1
        T_RunNextLuaAction()                          -- _Resume → cast 2
        return {
            waiting = waiting,
            second = T_Actions[1],
            casts = BfBot.Exec._castCount,
        }
        """
    )

    assert facts["waiting"] == "SmallWait(3)"
    assert facts["second"] == 'SpellRES("D5Z101I",Myself)'
    assert facts["casts"] == 2


def test_exec_native_entry_after_wrapper_cast_is_not_delayed(
    exec5_lua: LuaRuntime,
) -> None:
    facts = exec5_lua.execute(
        """
        local spells = {
            SPWI305 = T_Row5("SPWI305", "D5Z101I", 1),
            SPPR101 = { count = 1, name = "Bless", kind = "spl",
                        class = { splstates = {} }, leafResrefs = { "SPPR101" } },
        }
        T_ExecWorld(spells)
        T_Start({
            { caster = 0, spell = "SPWI305", target = "self" },
            { caster = 0, spell = "SPPR101", target = "self" },
        })
        spells.SPWI305.count = 0; spells.SPWI305.d5.available = 0
        T_RunNextLuaAction()                          -- _Advance
        return { next = T_Actions[1], casts = BfBot.Exec._castCount }
        """
    )

    assert facts["next"] == 'SpellRES("SPPR101",Myself)'
    assert facts["casts"] == 2


def test_exec_5e_variant_entry_is_skipped_without_touching_native_slots(
    exec5_lua: LuaRuntime,
) -> None:
    facts = exec5_lua.execute(
        """
        local spells = { SPWI590 = T_Row5("SPWI590", "D5Z130I", 2) }
        T_ExecWorld(spells)
        local consumed = 0
        BfBot.Exec._ConsumeSpellSlot = function() consumed = consumed + 1; return true end
        T_Start({ { caster = 0, spell = "SPWI590", target = "self", var = "SPWI590A" } })
        return {
            consumed = consumed,
            actions = table.concat(T_Actions, "|"),
            casts = BfBot.Exec._castCount,
            skips = BfBot.Exec._skipCount,
            state = BfBot.Exec._state,
            log = T_LogText(),
        }
        """
    )

    assert facts["consumed"] == 0
    assert facts["actions"] == ""
    assert facts["casts"] == 0
    assert facts["skips"] == 1
    assert facts["state"] == "done"
    assert "variant selection is not supported" in facts["log"]


def test_exec_unprepared_5e_spell_skips_with_precise_reason(
    exec5_lua: LuaRuntime,
) -> None:
    facts = exec5_lua.execute(
        """
        local spells = { SPWI306 = T_Row5("SPWI306", "D5Z102I", 0) }
        local caster = T_ExecWorld(spells)
        caster.m_timedEffectList = {
            { m_sourceRes = { get = function() return "D5Z102B" end } },
        }
        T_Start({ { caster = 0, spell = "SPWI306", target = "self" } })
        return { log = T_LogText(), actions = table.concat(T_Actions, "|") }
        """
    )

    assert "(no slot - 5E: spell not prepared)" in facts["log"]
    assert facts["actions"] == ""


def test_exec_waits_out_a_refresh_that_started_before_the_run(
    exec5_lua: LuaRuntime,
) -> None:
    facts = exec5_lua.execute(
        """
        -- The previous run (or the player) cast a 5E spell a moment ago, so
        -- every wrapper is stripped while this run starts.
        local spells = { SPWI305 = T_Row5("SPWI305", "D5Z101I", 0) }
        spells.SPWI305.d5.pending = 1
        T_ExecWorld(spells)
        T_Start({ { caster = 0, spell = "SPWI305", target = "self" } })
        local waiting = table.concat(T_Actions, "|")
        T_Now = T_Now + 15
        T_Live = { [2] = { D5Z101I = 1 } }
        spells.SPWI305.count = 1
        spells.SPWI305.d5.available = 1
        spells.SPWI305.d5.pending = nil
        T_RunNextLuaAction()
        return {
            waiting = waiting,
            cast = table.concat(T_Actions, "|"),
            casts = BfBot.Exec._castCount,
            skips = BfBot.Exec._skipCount,
        }
        """
    )

    assert facts["waiting"] == (
        'SmallWait(3)|EEex_LuaAction("BfBot.Exec._Resume([[p0]])")'
    )
    assert facts["cast"] == (
        'SpellRES("D5Z101I",Myself)|'
        'EEex_LuaAction("BfBot.Exec._Advance([[p0]])")'
    )
    assert facts["casts"] == 1
    assert facts["skips"] == 0


def test_exec_seeds_the_refresh_wait_only_once_per_caster_and_run(
    exec5_lua: LuaRuntime,
) -> None:
    facts = exec5_lua.execute(
        """
        -- Nothing left to regrant: wait once, then skip the rest at once
        -- instead of waiting again for every following entry.
        local spells = {
            SPWI305 = T_Row5("SPWI305", "D5Z101I", 0),
            SPWI306 = T_Row5("SPWI306", "D5Z102I", 0),
        }
        spells.SPWI305.d5.pending = 1
        spells.SPWI306.d5.pending = 1
        T_ExecWorld(spells)
        T_Start({
            { caster = 0, spell = "SPWI305", target = "self" },
            { caster = 0, spell = "SPWI306", target = "self" },
        })
        local polls = 0
        while BfBot.Exec._state == "running" and polls < 60 do
            T_Now = T_Now + 3
            if T_RunNextLuaAction() == nil then break end
            polls = polls + 1
        end
        return {
            state = BfBot.Exec._state,
            polls = polls,
            skips = BfBot.Exec._skipCount,
            casts = BfBot.Exec._castCount,
        }
        """
    )

    assert facts["state"] == "done"
    assert 20 <= facts["polls"] <= 30
    assert facts["skips"] == 2
    assert facts["casts"] == 0


def test_exec_ignores_a_resume_left_over_from_a_stopped_run(
    exec5_lua: LuaRuntime,
) -> None:
    facts = exec5_lua.execute(
        """
        -- Stop during a refresh wait, then start again: the old run's
        -- SmallWait + _Resume pair is still in the engine's action queue and
        -- must not drive the new run's chain a second time.
        local spells = {
            SPWI305 = T_Row5("SPWI305", "D5Z101I", 1),
            SPPR101 = { count = 2, name = "Bless", kind = "spl",
                        class = { splstates = {} }, leafResrefs = { "SPPR101" } },
        }
        T_ExecWorld(spells)
        T_Start({ { caster = 0, spell = "SPWI305", target = "self" } })
        spells.SPWI305.count = 0
        spells.SPWI305.d5.available = 0
        T_RunNextLuaAction()                          -- _Advance -> wait queued
        T_Actions = {}                                -- engine still holds them
        BfBot.Exec._state = "stopped"

        -- New run, fresh caster record, native spell.
        T_Start({ { caster = 0, spell = "SPPR101", target = "self" } })
        local first = table.concat(T_Actions, "|")
        BfBot.Exec._Resume("p0")                      -- the stale callback
        return { first = first, after = table.concat(T_Actions, "|"),
                 casts = BfBot.Exec._castCount }
        """
    )

    assert facts["first"] == (
        'SpellRES("SPPR101",Myself)|'
        'EEex_LuaAction("BfBot.Exec._Advance([[p0]])")'
    )
    assert facts["after"] == facts["first"]
    assert facts["casts"] == 1


def test_exec_skips_an_active_buff_delivered_under_a_different_mem_resref(
    exec5_lua: LuaRuntime,
) -> None:
    facts = exec5_lua.execute(
        """
        -- Faiths & Powers sphere copy: the row is FNP101A, the wrapper casts
        -- SPPR101, and only SPPR101's own parent marker is live (#69 window).
        local spells = { FNP101A = {
            count = 3, name = "Bless", kind = "spl",
            class = { splstates = {} },
            leafResrefs = { "SPPR101B" },
            stateMarkersByResref = { SPPR101 = { 29 }, SPPR101B = { 30 } },
            d5 = { wrapper = "D5Z150I", cast = "SPPR101", delay = 1,
                   available = 1, count = 3, block = "D5Z150B" },
        } }
        T_ExecWorld(spells)
        BfBot.Exec._HasAnySpellState = function(_, states)
            for _, id in ipairs(states) do if id == 29 then return true end end
            return false
        end
        BfBot.Exec._HasActiveStateMarker = function(_, resref, _)
            return resref == "SPPR101"
        end
        T_Start({ { caster = 0, spell = "FNP101A", target = "self" } })
        return { actions = table.concat(T_Actions, "|"),
                 skips = BfBot.Exec._skipCount, log = T_LogText() }
        """
    )

    assert facts["actions"] == ""
    assert facts["skips"] == 1
    assert "already active: SPPR101" in facts["log"]


# ----------------------------------------------------------------------
# Packaging
# ----------------------------------------------------------------------


def test_every_loaded_module_is_installed_deployed_and_packaged() -> None:
    modules = re.findall(r'Infinity_DoFile\("(\w+)"\)', MAIN_SOURCE)
    assert "BfBot5e" in modules
    assert modules.index("BfBot5e") < modules.index("BfBotExe")

    tp2 = (ROOT / "buffbot/setup-buffbot.tp2").read_text(encoding="utf-8")
    deploy = (ROOT / "tools/deploy.sh").read_text(encoding="utf-8")
    build = (ROOT / "tools/build-release.sh").read_text(encoding="utf-8")
    deploy_lists = re.findall(r"^for f in (M_BfBot\.lua .*?); do$", deploy, re.M)
    assert len(deploy_lists) == 2

    for module in modules:
        filename = f"{module}.lua"
        assert f"COPY ~buffbot/{filename}~" in tp2, filename
        for listed in deploy_lists:
            assert filename in listed.split(), filename
        assert f'"{filename}"' in build, filename
