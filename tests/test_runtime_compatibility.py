from __future__ import annotations

import faulthandler
from pathlib import Path
import re
import sys

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CORE_SOURCE = (ROOT / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")
LOC_SOURCE = (ROOT / "buffbot/BfBotLoc.lua").read_text(encoding="utf-8")
CLASS_SOURCE = (ROOT / "buffbot/BfBotCls.lua").read_text(encoding="utf-8")
SCAN_SOURCE = (ROOT / "buffbot/BfBotScn.lua").read_text(encoding="utf-8")
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")
EXEC_SOURCE = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")
MAIN_SOURCE = (ROOT / "buffbot/M_BfBot.lua").read_text(encoding="utf-8")
INNATE_SOURCE = (ROOT / "buffbot/BfBotInn.lua").read_text(encoding="utf-8")
UI_SOURCE = (ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8")
TEST_SOURCE = (ROOT / "buffbot/BfBotTst.lua").read_text(encoding="utf-8")


class _OpaqueUserData:
    pass


def _execute_with_handled_lua_errors(runtime: LuaRuntime, source: str):
    """Hide Windows' faulthandler noise for Lua errors contained by pcall."""
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        return runtime.execute(source)
    finally:
        if suppress_fault_handler:
            faulthandler.enable()


@pytest.fixture
def lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.globals().python_userdata = _OpaqueUserData()
    runtime.execute(
        """
        assert(type(python_userdata) == "userdata")
        BfBot = {
            MAX_PRESETS = 8,
            MAX_SPELL_REPEATS = 5,
            Scan = {}, Class = {}, Innate = {}, Mp = {},
            _Warn = function(_) end,
            _StripColorEscape = function(s) return s end,
        }
        """
    )
    runtime.execute(PERSIST_SOURCE)
    return runtime


@pytest.fixture
def core_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute(CORE_SOURCE)
    return runtime


@pytest.fixture
def exec_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        BfBot = {
            MAX_PRESETS = 8,
            MAX_SPELL_REPEATS = 5,
            Scan = {}, Class = {}, Innate = {}, Mp = {},
            _cache = { class = {}, scan = {} },
            _Warn = function(_) end,
            _Print = function(_) end,
            _OpenLogAppend = function(_) end,
            _CloseLog = function() end,
            _GetName = function(sprite)
                if type(sprite) == "table" then
                    return sprite.name or "?"
                end
                return tostring(sprite)
            end,
        }
        EEex_BAnd = function() return 0 end
        EEex_Sprite_DisplayStringHead = function() end
        """
    )
    runtime.execute("io = nil")
    runtime.execute(LOC_SOURCE)
    runtime.execute(PERSIST_SOURCE)
    runtime.execute(EXEC_SOURCE)
    runtime.execute(
        """
        -- Install a deterministic two-member party and spellbook for pure
        -- _BuildQueue tests. Callers may replace any seam afterwards.
        function BfBot_TestQueueWorld(spells, partySize)
            local sprites = {
                { name = "A", m_id = 100, m_baseStats = { m_generalState = 0 } },
                { name = "B", m_id = 101, m_baseStats = { m_generalState = 0 } },
            }
            partySize = partySize or 1
            BfBot.Exec._ResolveCaster = function() return sprites[1] end
            BfBot.Scan.GetCastableSpells = function() return spells end
            BfBot.Scan.Invalidate = function() end
            BfBot.Exec._IsAlive = function(sprite) return sprite ~= nil end
            EEex_Sprite_GetInPortrait = function(slot)
                if slot < partySize then return sprites[slot + 1] end
                return nil
            end
            EEex_Sprite_GetCharacterIndex = function(sprite)
                if sprite == sprites[1] then return 0 end
                if sprite == sprites[2] then return 1 end
                error("unknown synthetic sprite")
            end
            return sprites
        end
        """
    )
    return runtime


@pytest.fixture
def project_image_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        BfBot = {
            Class = {}, Scan = {},
            _cache = { class = {}, scan = {} },
            _overrides = {},
            _Warn = function(_) end,
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
        }
        """
    )
    runtime.execute(CLASS_SOURCE)
    runtime.execute(
        """
        -- Native feature blocks are userdata reached through pointer
        -- arithmetic. This seam keeps the real classifier/recursion logic
        -- while supplying equivalent synthetic records to the test runtime.
        BfBot.Class._IterateFeatureBlocks = function(_, ability, fn)
            for i, effect in ipairs(ability.effects or {}) do
                if fn(effect, i - 1) then return end
            end
        end

        BfBot_TestResources = {}
        BfBot_TestResourceDemands = {}

        function BfBot_TestAbility(effects)
            return {
                actionType = 5,
                type = 0,
                effectCount = #effects,
                startingEffect = 0,
                effects = effects,
                quickSlotIcon = { get = function() return "PIICON" end },
            }
        end

        function BfBot_TestHeader(ability, nameRef)
            local header = {
                secondaryType = 0,
                itemType = 1,
                spellLevel = 7,
                genericName = nameRef or 1,
                identifiedName = nameRef or 1,
            }
            header.getAbility = function(_, index)
                if index == 0 then return ability end
                return nil
            end
            header.getAbilityForLevel = function() return ability end
            return header
        end

        EEex_Resource_Demand = function(resref, kind)
            assert(kind == "SPL")
            BfBot_TestResourceDemands[resref] =
                (BfBot_TestResourceDemands[resref] or 0) + 1
            return BfBot_TestResources[resref]
        end
        EEex_Sprite_GetPortraitIndex = function() return -1 end
        Infinity_FetchString = function(_) return "投影术" end
        """
    )
    return runtime


@pytest.fixture
def ui_test_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        BfBot = {
            MAX_PRESETS = 8,
            MAX_SPELL_REPEATS = 5,
            Scan = {}, Class = {}, Innate = {}, Mp = {}, Exec = {}, Persist = {},
            _cache = { class = {}, scan = {} },
            _Warn = function(_) end,
            _Print = function(_) end,
        }
        """
    )
    runtime.execute("io = nil")
    runtime.execute(LOC_SOURCE)
    runtime.execute(UI_SOURCE)
    runtime.execute(TEST_SOURCE)
    return runtime


def test_new_companion_inherits_protagonist_preset_structure(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local protagonist = { id = "protagonist" }
        local conflictingMember = { id = "conflicting" }
        local recruit = { id = "recruit" }

        local protagonistConfig = BfBot.Persist.GetDefaultConfig()
        protagonistConfig.presets[1].name = "Preparation"
        protagonistConfig.presets[1].qc = 2
        protagonistConfig.presets[2] = nil
        protagonistConfig.presets[4] = {
            name = "Boss Fight",
            cat = "encounter",
            qc = 1,
            spells = {
                OWNERONLY = {
                    kind = "spl", on = 1, tgt = "s", pri = 1,
                    rep = 3, lock = 1,
                },
            },
        }
        protagonistConfig.ap = 4

        local conflictingConfig = BfBot.Persist.GetDefaultConfig()
        conflictingConfig.presets[3] = {
            name = "Wrong Template", cat = "custom", qc = 0, spells = {},
        }

        local auxBySprite = {
            [protagonist] = { BB = protagonistConfig },
            [conflictingMember] = { BB = conflictingConfig },
            [recruit] = {},
        }
        EEex_GetUDAux = function(sprite)
            return assert(auxBySprite[sprite])
        end
        EEex_Sprite_GetCharacterIndex = function(sprite)
            if sprite == protagonist then return 0 end
            if sprite == conflictingMember then return 2 end
            if sprite == recruit then return 5 end
            error("unknown synthetic sprite")
        end
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return conflictingMember end
            if slot == 2 then return protagonist end
            if slot == 3 then return recruit end
            return nil
        end
        BfBot.Scan.GetCastableSpells = function(sprite)
            assert(sprite == recruit)
            return {
                LONG = {
                    kind = "spl", count = 1, duration = 600, durCat = "long",
                    class = { isBuff = true, defaultTarget = "p" },
                },
                SHORT = {
                    kind = "spl", count = 1, duration = 60, durCat = "short",
                    class = { isBuff = true, defaultTarget = "s" },
                },
                ITEM = {
                    kind = "itm", count = 1, duration = 600, durCat = "long",
                    class = { isBuff = true, defaultTarget = "s" },
                },
            }, 3
        end

        local created = BfBot.Persist.GetConfig(recruit)
        local inherited = created.presets[4]
        return {
            inherited = inherited ~= nil,
            inheritedName = inherited and inherited.name or nil,
            inheritedCat = inherited and inherited.cat or nil,
            inheritedQc = inherited and inherited.qc or nil,
            firstPresetQc = created.presets[1].qc,
            sparseGapPreserved = created.presets[2] == nil
                and created.presets[3] == nil,
            activePreset = created.ap,
            customLongDisabled = inherited and inherited.spells.LONG
                and inherited.spells.LONG.on == 0,
            customShortDisabled = inherited and inherited.spells.SHORT
                and inherited.spells.SHORT.on == 0,
            customItemDisabled = inherited and inherited.spells.ITEM
                and inherited.spells.ITEM.on == 0,
            ownerSpellNotCopied = inherited
                and inherited.spells.OWNERONLY == nil,
            firstPresetDisabled = created.presets[1].spells.LONG.on == 0
                and created.presets[1].spells.SHORT.on == 0
                and created.presets[1].spells.ITEM.on == 0,
            protagonistWon = created.presets[3] == nil,
            deepCopied = inherited
                and inherited ~= protagonistConfig.presets[4]
                and inherited.spells ~= protagonistConfig.presets[4].spells,
            sourceUnchanged = protagonistConfig.presets[4].spells.OWNERONLY.on == 1
                and protagonistConfig.presets[4].spells.LONG == nil,
            stored = auxBySprite[recruit].BB == created,
        }
        """
    )

    assert facts["inherited"]
    assert facts["inheritedName"] == "Boss Fight"
    assert facts["inheritedCat"] == "encounter"
    assert facts["inheritedQc"] == 0
    assert facts["firstPresetQc"] == 0
    assert facts["sparseGapPreserved"]
    assert facts["activePreset"] == 1
    assert facts["customLongDisabled"]
    assert facts["customShortDisabled"]
    assert facts["customItemDisabled"]
    assert facts["ownerSpellNotCopied"]
    assert facts["firstPresetDisabled"]
    assert facts["protagonistWon"]
    assert facts["deepCopied"]
    assert facts["sourceUnchanged"]
    assert facts["stored"]


def test_new_companion_keeps_inherited_structure_when_scan_is_empty(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local protagonist = {}
        local recruit = {}
        local template = BfBot.Persist.GetDefaultConfig()
        template.presets[1] = nil
        template.presets[2] = nil
        template.presets[4] = {
            name = "Situational", cat = "custom", qc = 2, spells = {},
        }
        local auxBySprite = {
            [protagonist] = { BB = template },
            [recruit] = {},
        }
        EEex_GetUDAux = function(sprite) return auxBySprite[sprite] end
        EEex_Sprite_GetCharacterIndex = function(sprite)
            return sprite == protagonist and 0 or 1
        end
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return protagonist end
            if slot == 1 then return recruit end
            return nil
        end
        BfBot.Scan.GetCastableSpells = function(sprite)
            assert(sprite == recruit)
            return {}, 0
        end

        local created = BfBot.Persist.GetConfig(recruit)
        return {
            name = created.presets[4] and created.presets[4].name or nil,
            qc = created.presets[4] and created.presets[4].qc or nil,
            activePreset = created.ap,
            exactSparseSlots = created.presets[1] == nil
                and created.presets[2] == nil and created.presets[3] == nil,
            empty = created.presets[4]
                and next(created.presets[4].spells) == nil,
            stored = auxBySprite[recruit].BB == created,
        }
        """
    )

    assert facts["name"] == "Situational"
    assert facts["qc"] == 0
    assert facts["activePreset"] == 4
    assert facts["exactSparseSlots"]
    assert facts["empty"]
    assert facts["stored"]


def test_existing_companion_config_is_never_resynchronized(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local protagonist = {}
        local companion = {}
        local template = BfBot.Persist.GetDefaultConfig()
        template.presets[3] = {
            name = "Party Preset", cat = "custom", qc = 0, spells = {},
        }
        local existing = BfBot.Persist.GetDefaultConfig()
        existing.presets[1].name = "Imported Personal Setup"
        local auxBySprite = {
            [protagonist] = { BB = template },
            [companion] = { BB = existing },
        }
        EEex_GetUDAux = function(sprite) return auxBySprite[sprite] end
        EEex_Sprite_GetCharacterIndex = function(sprite)
            return sprite == protagonist and 0 or 1
        end
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return protagonist end
            if slot == 1 then return companion end
            return nil
        end
        BfBot.Scan.GetCastableSpells = function()
            error("existing configs must not be rescanned")
        end

        local returned = BfBot.Persist.GetConfig(companion)
        return {
            sameTable = returned == existing,
            personalName = returned.presets[1].name,
            noPartyPreset = returned.presets[3] == nil,
        }
        """
    )

    assert facts["sameTable"]
    assert facts["personalName"] == "Imported Personal Setup"
    assert facts["noPartyPreset"]


def test_first_config_without_party_template_keeps_default_enablement(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local protagonist = {}
        local aux = {}
        EEex_GetUDAux = function(sprite)
            assert(sprite == protagonist)
            return aux
        end
        EEex_Sprite_GetCharacterIndex = function(sprite)
            assert(sprite == protagonist)
            return 0
        end
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return protagonist end
            return nil
        end
        BfBot.Scan.GetCastableSpells = function(sprite)
            assert(sprite == protagonist)
            return {
                LONG = {
                    kind = "spl", count = 1, duration = 600, durCat = "long",
                    class = { isBuff = true, defaultTarget = "p" },
                },
                SHORT = {
                    kind = "spl", count = 1, duration = 60, durCat = "short",
                    class = { isBuff = true, defaultTarget = "s" },
                },
            }, 2
        end

        local created = BfBot.Persist.GetConfig(protagonist)
        return {
            presetCount = created.presets[1] and created.presets[2]
                and created.presets[3] == nil and 2 or 0,
            longEnabled = created.presets[1].spells.LONG.on,
            shortDisabledInLong = created.presets[1].spells.SHORT.on,
            longDisabledInShort = created.presets[2].spells.LONG.on,
            shortEnabled = created.presets[2].spells.SHORT.on,
        }
        """
    )

    assert facts["presetCount"] == 2
    assert facts["longEnabled"] == 1
    assert facts["shortDisabledInLong"] == 0
    assert facts["longDisabledInShort"] == 0
    assert facts["shortEnabled"] == 1


def test_non_party_sprite_does_not_inherit_party_preset_structure(
    lua: LuaRuntime,
) -> None:
    inherited = lua.execute(
        """
        local protagonist = {}
        local outsider = {}
        local template = BfBot.Persist.GetDefaultConfig()
        template.presets[3] = {
            name = "Party Only", cat = "custom", qc = 0, spells = {},
        }
        local auxBySprite = {
            [protagonist] = { BB = template },
            [outsider] = {},
        }
        EEex_GetUDAux = function(sprite) return auxBySprite[sprite] end
        EEex_Sprite_GetCharacterIndex = function(sprite)
            return sprite == protagonist and 0 or -1
        end
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return protagonist end
            return nil
        end
        BfBot.Scan.GetCastableSpells = function() return {}, 0 end

        local created = BfBot.Persist.GetConfig(outsider)
        return created.presets[3] ~= nil
        """
    )

    assert not inherited


def test_loaded_listener_plans_inherited_innate_with_fresh_sprite_wrappers(
    lua: LuaRuntime,
) -> None:
    lua.execute(INNATE_SOURCE)
    facts = lua.execute(
        """
        local callbackRecruit = { identity = "recruit" }
        local portraitRecruit = { identity = "recruit" }
        local protagonist = { identity = "protagonist" }
        local template = BfBot.Persist.GetDefaultConfig()
        template.presets[1] = nil
        template.presets[2] = nil
        template.presets[3] = {
            name = "Boss Fight", cat = "custom", qc = 2, spells = {},
        }
        local auxByIdentity = {
            protagonist = { BB = template },
            recruit = {},
        }
        EEex_GetUDAux = function(sprite)
            return assert(auxByIdentity[sprite.identity])
        end
        EEex_Sprite_GetCharacterIndex = function(sprite)
            return sprite.identity == "protagonist" and 0 or 2
        end
        EEex_Sprite_GetPortraitIndex = function(sprite)
            assert(sprite == callbackRecruit)
            return 3
        end
        local recruitPortraitReads = 0
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 2 then return protagonist end
            if slot == 3 then
                recruitPortraitReads = recruitPortraitReads + 1
                if recruitPortraitReads == 1 then return portraitRecruit end
                return { identity = "recruit" }
            end
            return nil
        end
        BfBot.Scan.GetCastableSpells = function(sprite)
            assert(sprite == portraitRecruit)
            return {
                LONG = {
                    kind = "spl", count = 1, duration = 600, durCat = "long",
                    class = { isBuff = true, defaultTarget = "p" },
                },
            }, 1
        end

        EEex_Sprite_GetKnownInnateSpellsIterator = function(sprite)
            assert(sprite.identity == "recruit")
            return function() return nil end
        end
        local planCalls = 0
        local inheritedDesired = false
        local activePreset = nil
        local realPlan = BfBot.Innate._PlanReconciliation
        BfBot.Innate._PlanReconciliation = function(sprite, slot, config)
            planCalls = planCalls + 1
            activePreset = config.ap
            local plan = realPlan(sprite, slot, config)
            inheritedDesired = plan.desired.BFBT33 == true
            return plan
        end
        local queued = {}
        EEex_Action_QueueResponseStringOnAIBase = function(action, sprite)
            assert(sprite.identity == "recruit")
            queued[#queued + 1] = action
        end

        BfBot.Innate._OnSpriteLoaded(callbackRecruit)
        return {
            wrappersDiffer = callbackRecruit ~= portraitRecruit,
            stored = auxByIdentity.recruit.BB ~= nil,
            planCalls = planCalls,
            activePreset = activePreset,
            inheritedDesired = inheritedDesired,
            queuedCount = #queued,
            inheritedQueued = table.concat(queued, ""):find(
                'AddSpecialAbility("BFBT33")', 1, true) ~= nil,
        }
        """
    )

    assert facts["wrappersDiffer"]
    assert facts["stored"]
    assert facts["planCalls"] == 1
    assert facts["activePreset"] == 3
    assert facts["inheritedDesired"]
    assert facts["queuedCount"] == 1
    assert facts["inheritedQueued"]


def test_spell_repeat_normalizer_is_strict_and_bounded(lua: LuaRuntime) -> None:
    facts = lua.execute(
        """
        local normalize = BfBot.Persist._NormalizeSpellRepeat
        if type(normalize) ~= "function" then
            return { available = false }
        end
        return {
            available = true,
            nilValue = normalize(nil),
            one = normalize(1),
            five = normalize(5),
            zero = normalize(0),
            six = normalize(6),
            negative = normalize(-1),
            fraction = normalize(2.5),
            stringValue = normalize("2"),
            booleanValue = normalize(true),
            nan = normalize(0 / 0),
            positiveInfinity = normalize(math.huge),
            negativeInfinity = normalize(-math.huge),
        }
        """
    )

    assert facts["available"]
    assert facts["nilValue"] == 1
    assert facts["one"] == 1
    assert facts["five"] == 5
    for key in (
        "zero",
        "six",
        "negative",
        "fraction",
        "stringValue",
        "booleanValue",
        "nan",
        "positiveInfinity",
        "negativeInfinity",
    ):
        assert facts[key] == 1


def test_core_defines_the_spell_repeat_cap(core_lua: LuaRuntime) -> None:
    assert core_lua.eval("BfBot.MAX_SPELL_REPEATS") == 5


def test_default_spell_entries_start_with_one_repeat(lua: LuaRuntime) -> None:
    facts = lua.execute(
        """
        local enabled = BfBot.Persist._MakeDefaultEntry(nil)
        local disabled = BfBot.Persist._MakeDefaultEntry(
            { defaultTarget = "s" }, 0)
        return {
            enabledRepeat = enabled.rep,
            disabledRepeat = disabled.rep,
            disabledTarget = disabled.tgt,
        }
        """
    )

    assert facts["enabledRepeat"] == 1
    assert facts["disabledRepeat"] == 1
    assert facts["disabledTarget"] == "s"


def test_v8_to_current_migration_initializes_repeats_and_party_kind(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local config = {
            v = 8,
            ap = 1,
            presets = {
                [1] = { name = "Party", cat = "custom", qc = 0, spells = {
                    SPWI101 = { on = 1, tgt = "s", pri = 1 },
                    SPWI102 = { on = 1, tgt = "s", pri = 2, rep = 4 },
                    SPWI103 = { on = 1, tgt = "s", pri = 3, rep = 6 },
                } },
            },
            opts = { skip = 1 },
            ovr = {},
            summons = {
                skeleton = { presets = {
                    [1] = { qc = 0, spells = {
                        SPIN101 = { on = 1, tgt = "s", pri = 1 },
                        SPIN102 = { on = 1, tgt = "s", pri = 2, rep = 5 },
                        SPIN103 = { on = 1, tgt = "s", pri = 3, rep = "3" },
                    } },
                } },
            },
        }
        local migrated = BfBot.Persist._MigrateConfig(config, 8)
        return {
            version = migrated.v,
            partyMissing = migrated.presets[1].spells.SPWI101.rep,
            partyValid = migrated.presets[1].spells.SPWI102.rep,
            partyInvalid = migrated.presets[1].spells.SPWI103.rep,
            summonMissing = migrated.summons.skeleton.presets[1]
                .spells.SPIN101.rep,
            summonValid = migrated.summons.skeleton.presets[1]
                .spells.SPIN102.rep,
            summonInvalid = migrated.summons.skeleton.presets[1]
                .spells.SPIN103.rep,
            partyKind = migrated.presets[1].spells.SPWI101.kind,
            summonKind = migrated.summons.skeleton.presets[1]
                .spells.SPIN101.kind,
        }
        """
    )

    assert facts["version"] == 10
    assert facts["partyMissing"] == 1
    assert facts["partyValid"] == 4
    assert facts["partyInvalid"] == 1
    assert facts["summonMissing"] == 1
    assert facts["summonValid"] == 5
    assert facts["summonInvalid"] == 1
    assert facts["partyKind"] == "spl"
    assert facts["summonKind"] is None


def test_current_schema_validation_repairs_malformed_repeats_without_migration(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local config = {
            v = 10,
            ap = 1,
            presets = {
                [1] = { name = "Current", cat = "custom", qc = 0, spells = {
                    MISSING = { on = 1, tgt = "s", pri = 1 },
                    VALID = { on = 1, tgt = "s", pri = 2, rep = 3 },
                    BAD = { on = 1, tgt = "s", pri = 3, rep = 1 / 0 },
                } },
            },
            opts = { skip = 1 },
            ovr = {},
            summons = {
                wolf = { presets = {
                    [1] = { qc = 0, spells = {
                        MISSING = { on = 1, tgt = "s", pri = 1 },
                        VALID = { on = 1, tgt = "s", pri = 2, rep = 2 },
                        BAD = { on = 1, tgt = "s", pri = 3, rep = false },
                    } },
                } },
            },
        }
        local repaired = BfBot.Persist._ValidateConfig(config)
        return {
            version = repaired.v,
            partyMissing = repaired.presets[1].spells.MISSING.rep,
            partyValid = repaired.presets[1].spells.VALID.rep,
            partyBad = repaired.presets[1].spells.BAD.rep,
            summonMissing = repaired.summons.wolf.presets[1]
                .spells.MISSING.rep,
            summonValid = repaired.summons.wolf.presets[1]
                .spells.VALID.rep,
            summonBad = repaired.summons.wolf.presets[1]
                .spells.BAD.rep,
        }
        """
    )

    assert facts["version"] == 10
    assert facts["partyMissing"] == 1
    assert facts["partyValid"] == 3
    assert facts["partyBad"] == 1
    assert facts["summonMissing"] == 1
    assert facts["summonValid"] == 2
    assert facts["summonBad"] == 1


@pytest.mark.parametrize(
    "active_preset", (6, 7, None), ids=("six", "seven", "max")
)
def test_validate_config_preserves_high_active_preset(
    lua: LuaRuntime, active_preset: int | None
) -> None:
    expected = active_preset or int(lua.eval("BfBot.MAX_PRESETS"))
    lua.globals().test_active_preset = expected
    repaired = lua.execute(
        """
        local config = BfBot.Persist.GetDefaultConfig()
        config.presets[test_active_preset] = {
            name = "High preset",
            cat = "custom",
            qc = 0,
            spells = {},
        }
        config.ap = test_active_preset
        return BfBot.Persist._ValidateConfig(config).ap
        """
    )

    assert repaired == expected


@pytest.mark.parametrize(
    "case",
    ("zero", "above-max", "non-number", "missing-preset"),
)
def test_validate_config_resets_invalid_or_missing_active_preset(
    lua: LuaRuntime,
    case: str,
) -> None:
    lua.globals().test_active_preset_case = case
    repaired = lua.execute(
        """
        local config = BfBot.Persist.GetDefaultConfig()
        if test_active_preset_case == "zero" then
            config.ap = 0
        elseif test_active_preset_case == "above-max" then
            config.ap = BfBot.MAX_PRESETS + 1
        elseif test_active_preset_case == "non-number" then
            config.ap = "6"
        elseif test_active_preset_case == "missing-preset" then
            config.ap = 5
        end
        return BfBot.Persist._ValidateConfig(config).ap
        """
    )

    assert repaired == 1


@pytest.mark.parametrize(
    "active_preset", (6, 7, None), ids=("six", "seven", "max")
)
def test_import_validation_preserves_high_active_preset(
    lua: LuaRuntime, active_preset: int | None
) -> None:
    expected = active_preset or int(lua.eval("BfBot.MAX_PRESETS"))
    lua.globals().test_active_preset = expected
    imported = lua.execute(
        """
        local sprite = {}
        local aux = {}
        EEex_GetUDAux = function(seen)
            assert(seen == sprite)
            return aux
        end

        local config = BfBot.Persist.GetDefaultConfig()
        config.presets[test_active_preset] = {
            name = "Imported high preset",
            cat = "custom",
            qc = 0,
            spells = {},
        }
        config.ap = test_active_preset

        BfBot.Persist._Import(sprite, { cfg = config })
        return aux.BB and aux.BB.ap or nil
        """
    )

    assert imported == expected


def test_summon_validation_whitelists_and_normalizes_repeat(lua: LuaRuntime) -> None:
    facts = lua.execute(
        """
        local summons = {
            skeleton = { presets = {
                [1] = { qc = 0, spells = {
                    VALID = {
                        on = 1, tgt = "s", pri = 1, var = "SPIN001",
                        rep = 5, unknown = "drop me",
                    },
                    INVALID = {
                        on = 1, tgt = "p", pri = 2, rep = 2.5,
                        extra = 17,
                    },
                } },
            }, unknownIdentityField = 1 },
        }
        local clean = BfBot.Persist._ValidateSummons(summons)
        local valid = clean.skeleton.presets[1].spells.VALID
        local invalid = clean.skeleton.presets[1].spells.INVALID
        return {
            validRepeat = valid.rep,
            invalidRepeat = invalid.rep,
            unknownSpellDropped = valid.unknown == nil and invalid.extra == nil,
            unknownIdentityDropped = clean.skeleton.unknownIdentityField == nil,
        }
        """
    )

    assert facts["validRepeat"] == 5
    assert facts["invalidRepeat"] == 1
    assert facts["unknownSpellDropped"]
    assert facts["unknownIdentityDropped"]


def test_repeat_accessors_create_and_strictly_normalize_entries(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        if type(BfBot.Persist.SetSpellRepeat) ~= "function"
            or type(BfBot.Persist.GetSpellRepeat) ~= "function" then
            return { available = false }
        end
        local config = BfBot.Persist.GetDefaultConfig()
        BfBot.Persist.GetConfig = function(sprite)
            assert(sprite == "sprite")
            return config
        end
        BfBot.Persist.SetSpellRepeat("sprite", 1, "NEW", 5)
        local valid = BfBot.Persist.GetSpellRepeat("sprite", 1, "NEW")
        BfBot.Persist.SetSpellRepeat("sprite", 1, "NEW", "4")
        local invalid = BfBot.Persist.GetSpellRepeat("sprite", 1, "NEW")
        return {
            available = true,
            valid = valid,
            invalid = invalid,
            createdDefaultFields = config.presets[1].spells.NEW.on == 1
                and config.presets[1].spells.NEW.tgt == "p",
            missing = BfBot.Persist.GetSpellRepeat(
                "sprite", 1, "DOES_NOT_EXIST"),
        }
        """
    )

    assert facts["available"]
    assert facts["valid"] == 5
    assert facts["invalid"] == 1
    assert facts["createdDefaultFields"]
    assert facts["missing"] == 1


def test_clone_seeding_deep_copies_and_normalizes_repeat(lua: LuaRuntime) -> None:
    facts = lua.execute(
        """
        local targetList = { "Imoen", "Jaheira" }
        local owner = { spells = {
            VALID = { on = 1, tgt = targetList, pri = 1, rep = 4 },
            INVALID = { on = 1, tgt = "s", pri = 2, rep = "4" },
        } }
        local seeded = BfBot.Persist._SeedCloneSpells(owner, {
            VALID = { count = 1 },
            INVALID = { count = 1 },
        })
        seeded.VALID.tgt[1] = "Changed"
        return {
            validRepeat = seeded.VALID.rep,
            invalidRepeat = seeded.INVALID.rep,
            targetDeepCopied = targetList[1] == "Imoen"
                and seeded.VALID.tgt ~= targetList,
        }
        """
    )

    assert facts["validRepeat"] == 4
    assert facts["invalidRepeat"] == 1
    assert facts["targetDeepCopied"]


def test_marshal_and_serializer_round_trips_preserve_valid_repeats(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local config = {
            v = 10,
            presets = { [1] = { spells = {
                PARTY = { on = 1, tgt = "s", pri = 1, rep = 4 },
            } } },
            summons = { skeleton = { presets = { [1] = { qc = 0, spells = {
                SUMMON = { on = 1, tgt = "s", pri = 1, rep = 5 },
            } } } } },
        }
        local safe, dropped = BfBot.Persist._MarshalSafeCopy(config)
        local serialized = BfBot.Persist._Serialize(config)
        local chunk = assert(loadstring("return " .. serialized))
        local parsed = chunk()
        return {
            marshalParty = safe.presets[1].spells.PARTY.rep,
            marshalSummon = safe.summons.skeleton.presets[1]
                .spells.SUMMON.rep,
            marshalDropped = dropped,
            serializedParty = parsed.presets[1].spells.PARTY.rep,
            serializedSummon = parsed.summons.skeleton.presets[1]
                .spells.SUMMON.rep,
        }
        """
    )

    assert facts["marshalParty"] == 4
    assert facts["marshalSummon"] == 5
    assert facts["marshalDropped"] == 0
    assert facts["serializedParty"] == 4
    assert facts["serializedSummon"] == 5


def test_external_export_import_round_trip_preserves_valid_repeats(
    lua: LuaRuntime,
    tmp_path: Path,
) -> None:
    lua.globals().repeat_presets_dir = tmp_path.as_posix()
    facts = lua.execute(
        """
        local live = {
            v = 10,
            ap = 1,
            presets = { [1] = {
                name = "Repeat", cat = "custom", qc = 0,
                spells = {
                    PARTY = { on = 1, tgt = "s", pri = 1, rep = 4 },
                },
            } },
            opts = { skip = 1 },
            ovr = {},
            summons = { skeleton = { presets = { [1] = { qc = 0, spells = {
                SUMMON = { on = 1, tgt = "s", pri = 1, rep = 5 },
            } } } } },
        }
        local aux = { BB = live }
        EEex_GetUDAux = function(sprite)
            assert(sprite == "sprite")
            return aux
        end
        BfBot._GetName = function() return "Repeat Tester" end
        BfBot.Persist._PRESETS_DIR = repeat_presets_dir
        BfBot.Persist._EnsurePresetsDir = function() end
        BfBot.Scan.GetCastableSpells = function()
            return { PARTY = { count = 1 } }
        end
        BfBot.Scan.Invalidate = function() end
        BfBot.Class.SetOverride = function() end

        local exportOk, safeName = BfBot.Persist.ExportConfig("sprite")
        aux.BB = BfBot.Persist.GetDefaultConfig()
        local importOk, presetCount, skipped = BfBot.Persist.ImportConfig(
            "sprite", safeName .. ".lua")
        return {
            exportOk = exportOk,
            importOk = importOk,
            presetCount = presetCount,
            skipped = skipped,
            partyRepeat = aux.BB.presets[1].spells.PARTY.rep,
            summonRepeat = aux.BB.summons.skeleton.presets[1]
                .spells.SUMMON.rep,
        }
        """
    )

    assert facts["exportOk"]
    assert facts["importOk"]
    assert facts["presetCount"] == 1
    assert facts["skipped"] == 0
    assert facts["partyRepeat"] == 4
    assert facts["summonRepeat"] == 5


def test_localized_defaults_only_name_new_or_missing_presets(
    lua: LuaRuntime,
    tmp_path: Path,
) -> None:
    import_path = tmp_path / "localized-import.lua"
    import_path.write_text(
        """
BfBot._import = {
    v = 10,
    ap = 1,
    presets = {
        [1] = { name = "Imported Personal Setup", cat = "custom", qc = 0, spells = {} },
        [2] = { name = "导入的预设", cat = "custom", qc = 0, spells = {} },
    },
    opts = { skip = 1 },
    ovr = {},
    summons = {},
}
""".strip(),
        encoding="utf-8",
    )
    lua.globals().localized_presets_dir = tmp_path.as_posix()

    facts = lua.execute(
        """
        local selectedLanguage = "zh"
        BfBot.L10N = {
            Get = function(key)
                if selectedLanguage == "zh" then
                    if key == "default.preset.long" then return "长期增益" end
                    if key == "default.preset.short" then return "短期增益" end
                end
                if key == "default.preset.long" then return "Long Buffs" end
                if key == "default.preset.short" then return "Short Buffs" end
                error("unexpected Get key: " .. tostring(key))
            end,
            Format = function(key, values)
                assert(key == "default.preset.indexed")
                if selectedLanguage == "zh" then
                    return "预设 " .. tostring(values.index)
                end
                return "Preset " .. tostring(values.index)
            end,
        }

        local created = BfBot.Persist.GetDefaultConfig()
        local existing = BfBot.Persist.GetDefaultConfig()
        existing.presets[1].name = "Existing Long"
        existing.presets[2].name = "用户短预设"

        local repaired = {
            v = 10, ap = 4,
            presets = { [4] = { cat = "custom", qc = 0, spells = {} } },
            opts = { skip = 1 }, ovr = {}, summons = {},
        }
        BfBot.Persist._ValidateConfig(existing)
        BfBot.Persist._ValidateConfig(repaired)

        local protagonist = { id = "protagonist" }
        local companion = { id = "companion" }
        local protagonistConfig = BfBot.Persist.GetDefaultConfig()
        protagonistConfig.presets[1].name = "Inherited Exact Name"
        BfBot.Persist._GetProtagonist = function() return protagonist end
        EEex_Sprite_GetCharacterIndex = function(sprite)
            assert(sprite == companion)
            return 1
        end
        EEex_Sprite_GetInPortrait = function() return nil end
        EEex_GetUDAux = function(sprite)
            assert(sprite == protagonist)
            return { BB = protagonistConfig }
        end
        local inherited = BfBot.Persist._GetInheritedPresetStructure(companion)

        local importedAux = {}
        EEex_GetUDAux = function(sprite)
            assert(sprite == companion)
            return importedAux
        end
        BfBot.Persist._PRESETS_DIR = localized_presets_dir
        BfBot.Scan.GetCastableSpells = function() return {} end
        BfBot.Scan.Invalidate = function() end
        BfBot.Class.SetOverride = function() end
        local importOk = BfBot.Persist.ImportConfig(
            companion, "localized-import.lua")
        BfBot.Persist.GetConfig = function() return importedAux.BB end
        BfBot.Persist.RenamePreset(companion, 1, "User Renamed")

        selectedLanguage = "en"
        BfBot.Persist._ValidateConfig(created)
        BfBot.Persist._ValidateConfig(existing)
        BfBot.Persist._ValidateConfig(repaired)
        BfBot.Persist._ValidateConfig(importedAux.BB)

        return {
            createdLong = created.presets[1].name,
            createdShort = created.presets[2].name,
            existingLong = existing.presets[1].name,
            existingShort = existing.presets[2].name,
            repairedMissing = repaired.presets[4].name,
            inherited = inherited.presets[1].name,
            importOk = importOk,
            renamed = importedAux.BB.presets[1].name,
            importedChinese = importedAux.BB.presets[2].name,
        }
        """
    )

    assert facts["createdLong"] == "长期增益"
    assert facts["createdShort"] == "短期增益"
    assert facts["existingLong"] == "Existing Long"
    assert facts["existingShort"] == "用户短预设"
    assert facts["repairedMissing"] == "预设 4"
    assert facts["inherited"] == "Inherited Exact Name"
    assert facts["importOk"]
    assert facts["renamed"] == "User Renamed"
    assert facts["importedChinese"] == "导入的预设"


def test_sparse_preset_creation_localizes_once_without_resync(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local selectedLanguage = "zh"
        BfBot.L10N = {
            Get = function(key)
                if key == "default.preset.long" then return "长期增益" end
                if key == "default.preset.short" then return "短期增益" end
                error("unexpected Get key: " .. tostring(key))
            end,
            Format = function(key, values)
                assert(key == "default.preset.indexed")
                local prefix = selectedLanguage == "zh" and "预设 " or "Preset "
                return prefix .. tostring(values.index)
            end,
        }

        local singleConfig = BfBot.Persist.GetDefaultConfig()
        EEex_Resource_Demand = function() return nil end
        BfBot.Persist.GetConfig = function() return singleConfig end
        local singleIdx = BfBot.Persist.CreatePreset("single", nil)

        local partyConfigs = {
            A = singleConfig,
            B = BfBot.Persist.GetDefaultConfig(),
        }
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return "A" end
            if slot == 1 then return "B" end
            return nil
        end
        BfBot.Persist.GetConfig = function(sprite) return partyConfigs[sprite] end
        local partyIdx = BfBot.Persist.CreatePresetAll(nil)

        selectedLanguage = "en"
        BfBot.Persist._ValidateConfig(singleConfig)
        BfBot.Persist._ValidateConfig(partyConfigs.B)
        return {
            singleIdx = singleIdx,
            singleName = singleConfig.presets[singleIdx].name,
            partyIdx = partyIdx,
            partyAName = partyConfigs.A.presets[partyIdx].name,
            partyBName = partyConfigs.B.presets[partyIdx].name,
        }
        """
    )

    assert facts["singleIdx"] == 3
    assert facts["singleName"] == "预设 3"
    assert facts["partyIdx"] == 4
    assert facts["partyAName"] == "预设 4"
    assert facts["partyBName"] == "预设 4"


def test_export_import_failures_return_stable_codes_and_details(
    lua: LuaRuntime,
    tmp_path: Path,
) -> None:
    (tmp_path / "empty.lua").write_text("", encoding="utf-8")
    (tmp_path / "parse.lua").write_text("this is not Lua", encoding="utf-8")
    (tmp_path / "exec.lua").write_text("error('synthetic boom')", encoding="utf-8")
    (tmp_path / "invalid.lua").write_text("BfBot._import = 17", encoding="utf-8")
    lua.globals().failure_presets_dir = tmp_path.as_posix()

    facts = _execute_with_handled_lua_errors(
        lua,
        """
        BfBot._noIO = true
        local _, exportNoIo, exportNoIoDetail =
            BfBot.Persist.ExportConfig("sprite")
        local _, importNoIo, importNoIoDetail =
            BfBot.Persist.ImportConfig("sprite", "x.lua")

        BfBot._noIO = false
        BfBot.Persist._PRESETS_DIR = failure_presets_dir
        BfBot.Persist._EnsurePresetsDir = function() end
        local _, exportNoSprite, exportNoSpriteDetail =
            BfBot.Persist.ExportConfig(nil)
        BfBot.Persist.GetConfig = function() return nil end
        local _, exportNoConfig, exportNoConfigDetail =
            BfBot.Persist.ExportConfig("sprite")
        BfBot.Persist.GetConfig = function()
            return BfBot.Persist.GetDefaultConfig()
        end
        BfBot._GetName = function() return "Ascii Name" end

        local realOpen = io.open
        io.open = function(_, mode)
            assert(mode == "w")
            return nil, "synthetic denied"
        end
        local _, exportOpen, exportOpenDetail =
            BfBot.Persist.ExportConfig("sprite")
        io.open = realOpen

        local _, importNoSprite, importNoSpriteDetail =
            BfBot.Persist.ImportConfig(nil, "x.lua")
        local _, importNoFilename, importNoFilenameDetail =
            BfBot.Persist.ImportConfig("sprite", nil)
        local _, importInvalidFilename, importInvalidFilenameDetail =
            BfBot.Persist.ImportConfig("sprite", "../x.lua")
        local _, importOpen, importOpenDetail =
            BfBot.Persist.ImportConfig("sprite", "missing.lua")
        local _, importEmpty, importEmptyDetail =
            BfBot.Persist.ImportConfig("sprite", "empty.lua")
        local _, importParse, importParseDetail =
            BfBot.Persist.ImportConfig("sprite", "parse.lua")
        local _, importExec, importExecDetail =
            BfBot.Persist.ImportConfig("sprite", "exec.lua")
        local _, importInvalid, importInvalidDetail =
            BfBot.Persist.ImportConfig("sprite", "invalid.lua")

        return {
            exportNoIo = exportNoIo,
            exportNoIoStructured = type(exportNoIoDetail) == "table",
            exportNoSprite = exportNoSprite,
            exportNoSpriteStructured = type(exportNoSpriteDetail) == "table",
            exportNoConfig = exportNoConfig,
            exportNoConfigStructured = type(exportNoConfigDetail) == "table",
            exportOpen = exportOpen,
            exportOpenError = exportOpenDetail and exportOpenDetail.error,
            importNoIo = importNoIo,
            importNoIoStructured = type(importNoIoDetail) == "table",
            importNoSprite = importNoSprite,
            importNoSpriteStructured = type(importNoSpriteDetail) == "table",
            importNoFilename = importNoFilename,
            importNoFilenameStructured = type(importNoFilenameDetail) == "table",
            importInvalidFilename = importInvalidFilename,
            importInvalidFilenameStructured = type(importInvalidFilenameDetail) == "table",
            importOpen = importOpen,
            importOpenError = importOpenDetail and importOpenDetail.error,
            importEmpty = importEmpty,
            importEmptyStructured = type(importEmptyDetail) == "table",
            importParse = importParse,
            importParseError = importParseDetail and importParseDetail.error,
            importExec = importExec,
            importExecError = importExecDetail and importExecDetail.error,
            importInvalid = importInvalid,
            importInvalidStructured = type(importInvalidDetail) == "table",
        }
        """
    )

    assert facts["exportNoIo"] == "reason.export.luajit_required"
    assert facts["exportNoIoStructured"]
    assert facts["exportNoSprite"] == "reason.export.no_sprite"
    assert facts["exportNoSpriteStructured"]
    assert facts["exportNoConfig"] == "reason.export.no_config"
    assert facts["exportNoConfigStructured"]
    assert facts["exportOpen"] == "reason.export.cannot_open_file"
    assert "synthetic denied" in facts["exportOpenError"]
    assert facts["importNoIo"] == "reason.import.luajit_required"
    assert facts["importNoIoStructured"]
    assert facts["importNoSprite"] == "reason.import.no_sprite"
    assert facts["importNoSpriteStructured"]
    assert facts["importNoFilename"] == "reason.import.no_filename"
    assert facts["importNoFilenameStructured"]
    assert facts["importInvalidFilename"] == "reason.import.invalid_filename"
    assert facts["importInvalidFilenameStructured"]
    assert facts["importOpen"] == "reason.import.cannot_open_file"
    assert facts["importOpenError"]
    assert facts["importEmpty"] == "reason.import.empty_file"
    assert facts["importEmptyStructured"]
    assert facts["importParse"] == "reason.import.parse_error"
    assert facts["importParseError"]
    assert facts["importExec"] == "reason.import.exec_error"
    assert "synthetic boom" in facts["importExecError"]
    assert facts["importInvalid"] == "reason.import.invalid_data"
    assert facts["importInvalidStructured"]


def test_queue_failures_return_stable_codes_and_placeholder_details(
    exec_lua: LuaRuntime,
) -> None:
    facts = _execute_with_handled_lua_errors(
        exec_lua,
        """
        local _, invalidSummon, invalidSummonDetail =
            BfBot.Persist.BuildQueueForSummon(nil, 3)

        BfBot.Persist.PeekSummonPreset = function() return nil end
        local _, noSummonPreset, noSummonPresetDetail =
            BfBot.Persist.BuildQueueForSummon({
                identity = "summon:test", oid = 77, name = "Skeleton",
            }, 3)

        local summonEntry = {
            identity = "summon:test", oid = 77, name = "Skeleton",
        }
        BfBot.Persist.PeekSummonPreset = function()
            return { qc = 0, spells = {
                BUFF = { on = 1, tgt = "s", pri = 1 },
            } }
        end
        local savedExec = BfBot.Exec
        BfBot.Exec = nil
        local _, noResolver, noResolverDetail =
            BfBot.Persist.BuildQueueForSummon(summonEntry, 3)
        BfBot.Exec = { _ResolveCaster = function() return nil end }
        local _, summonGone, summonGoneDetail =
            BfBot.Persist.BuildQueueForSummon(summonEntry, 3)
        local summonSprite = { name = "Skeleton", m_id = 77 }
        BfBot.Exec._ResolveCaster = function() return summonSprite end
        BfBot.Scan.Invalidate = function() end
        BfBot.Scan.GetCastableSpells = function()
            error("synthetic summon scan failure")
        end
        local _, summonScan, summonScanDetail =
            BfBot.Persist.BuildQueueForSummon(summonEntry, 3)
        BfBot.Scan.GetCastableSpells = function() return {} end
        local _, noSummonSpells, noSummonSpellsDetail =
            BfBot.Persist.BuildQueueForSummon(summonEntry, 3)
        BfBot.Exec = savedExec

        local _, noPresetIndex, noPresetIndexDetail =
            BfBot.Persist.BuildQueueFromPreset(nil)
        local _, missingCharacterArgs, missingCharacterArgsDetail =
            BfBot.Persist.BuildQueueForCharacter(nil, 3)

        EEex_Sprite_GetInPortrait = function() return nil end
        local _, noSprite, noSpriteDetail =
            BfBot.Persist.BuildQueueForCharacter(2, 3)

        local sprite = { name = "Remote Mage", m_id = 42 }
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 2 then return sprite end
            return nil
        end
        BfBot.Mp.IsLocallyControlled = function() return false end
        local _, remote, remoteDetail =
            BfBot.Persist.BuildQueueForCharacter(2, 3)

        BfBot.Mp.IsLocallyControlled = function() return true end
        BfBot.Persist.GetConfig = function() return nil end
        local _, noConfig, noConfigDetail =
            BfBot.Persist.BuildQueueForCharacter(2, 3)

        BfBot.Persist.GetConfig = function()
            return { presets = {} }
        end
        local _, noCharacterPreset, noCharacterPresetDetail =
            BfBot.Persist.BuildQueueForCharacter(2, 3)

        BfBot.Persist.GetConfig = function()
            return { presets = { [3] = { spells = {} } } }
        end
        BfBot.Scan.Invalidate = function() end
        BfBot.Scan.GetCastableSpells = function()
            error("synthetic scan failure")
        end
        local _, scanFailed, scanFailedDetail =
            BfBot.Persist.BuildQueueForCharacter(2, 3)

        return {
            invalidSummon = invalidSummon,
            invalidSummonStructured = type(invalidSummonDetail) == "table",
            noSummonPreset = noSummonPreset,
            noSummonPresetIndex = noSummonPresetDetail and noSummonPresetDetail.index,
            noSummonPresetIdentity = noSummonPresetDetail and noSummonPresetDetail.identity,
            noResolver = noResolver,
            noResolverStructured = type(noResolverDetail) == "table",
            summonGone = summonGone,
            summonGoneName = summonGoneDetail and summonGoneDetail.name,
            summonGoneOid = summonGoneDetail and summonGoneDetail.oid,
            summonScan = summonScan,
            summonScanName = summonScanDetail and summonScanDetail.name,
            summonScanError = summonScanDetail and summonScanDetail.error,
            noSummonSpells = noSummonSpells,
            noSummonSpellsIndex = noSummonSpellsDetail and noSummonSpellsDetail.index,
            noSummonSpellsIdentity = noSummonSpellsDetail and noSummonSpellsDetail.identity,
            noPresetIndex = noPresetIndex,
            noPresetIndexStructured = type(noPresetIndexDetail) == "table",
            missingCharacterArgs = missingCharacterArgs,
            missingCharacterArgsStructured = type(missingCharacterArgsDetail) == "table",
            noSprite = noSprite,
            noSpriteSlot = noSpriteDetail and noSpriteDetail.slot,
            remote = remote,
            remoteSlot = remoteDetail and remoteDetail.slot,
            remoteName = remoteDetail and remoteDetail.name,
            noConfig = noConfig,
            noConfigSlot = noConfigDetail and noConfigDetail.slot,
            noCharacterPreset = noCharacterPreset,
            noCharacterPresetIndex = noCharacterPresetDetail and noCharacterPresetDetail.preset,
            noCharacterPresetSlot = noCharacterPresetDetail and noCharacterPresetDetail.slot,
            scanFailed = scanFailed,
            scanFailedSlot = scanFailedDetail and scanFailedDetail.slot,
            scanFailedError = scanFailedDetail and scanFailedDetail.error,
        }
        """
    )

    assert facts["invalidSummon"] == "reason.queue.invalid_summon"
    assert facts["invalidSummonStructured"]
    assert facts["noSummonPreset"] == "reason.queue.no_summon_preset"
    assert facts["noSummonPresetIndex"] == 3
    assert facts["noSummonPresetIdentity"] == "summon:test"
    assert facts["noResolver"] == "reason.queue.caster_resolver_unavailable"
    assert facts["noResolverStructured"]
    assert facts["summonGone"] == "reason.queue.summon_gone"
    assert facts["summonGoneName"] == "Skeleton"
    assert facts["summonGoneOid"] == 77
    assert facts["summonScan"] == "reason.queue.summon_scan_failed"
    assert facts["summonScanName"] == "Skeleton"
    assert "synthetic summon scan failure" in facts["summonScanError"]
    assert facts["noSummonSpells"] == "reason.queue.no_castable_summon_spells"
    assert facts["noSummonSpellsIndex"] == 3
    assert facts["noSummonSpellsIdentity"] == "summon:test"
    assert facts["noPresetIndex"] == "reason.queue.no_preset_index"
    assert facts["noPresetIndexStructured"]
    assert facts["missingCharacterArgs"] == "reason.queue.missing_slot_or_preset"
    assert facts["missingCharacterArgsStructured"]
    assert facts["noSprite"] == "reason.queue.no_sprite_in_slot"
    assert facts["noSpriteSlot"] == 2
    assert facts["remote"] == "reason.queue.not_locally_controlled"
    assert facts["remoteSlot"] == 2
    assert facts["remoteName"] == "Remote Mage"
    assert facts["noConfig"] == "reason.queue.no_config_for_slot"
    assert facts["noConfigSlot"] == 2
    assert facts["noCharacterPreset"] == "reason.queue.no_preset_for_slot"
    assert facts["noCharacterPresetIndex"] == 3
    assert facts["noCharacterPresetSlot"] == 2
    assert facts["scanFailed"] == "reason.queue.scan_failed_for_slot"
    assert facts["scanFailedSlot"] == 2
    assert "synthetic scan failure" in facts["scanFailedError"]


def test_exec_public_failures_return_stable_codes_and_structured_details(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local emptyQueue, emptyCode, emptyDetail =
            BfBot.Exec._BuildQueue(nil, 0)
        local invalidQueue, invalidCode, invalidDetail =
            BfBot.Exec._BuildQueue({ { caster = 99 } }, 0)

        BfBot.Exec._state = "running"
        local started, runningCode, runningDetail =
            BfBot.Exec.Start({}, 0)
        return {
            emptyQueue = emptyQueue,
            emptyCode = emptyCode,
            emptyStructured = type(emptyDetail) == "table",
            invalidQueue = invalidQueue,
            invalidCode = invalidCode,
            invalidStructured = type(invalidDetail) == "table",
            started = started,
            runningCode = runningCode,
            runningStructured = type(runningDetail) == "table",
        }
        """
    )

    assert facts["emptyQueue"] is None
    assert facts["emptyCode"] == "reason.exec.empty_queue"
    assert facts["emptyStructured"]
    assert facts["invalidQueue"] is None
    assert facts["invalidCode"] == "reason.exec.no_valid_entries"
    assert facts["invalidStructured"]
    assert not facts["started"]
    assert facts["runningCode"] == "reason.exec.already_running"
    assert facts["runningStructured"]


def test_exec_start_forwards_build_failure_result(exec_lua: LuaRuntime) -> None:
    facts = exec_lua.execute(
        """
        local detail = { source = "synthetic builder" }
        BfBot.Exec._state = "idle"
        BfBot.Exec._BuildQueue = function()
            return nil, "reason.exec.no_valid_entries", detail
        end

        local function capture(...)
            local first, second, third = ...
            return {
                count = select("#", ...),
                first = first,
                second = second,
                third = third,
            }
        end

        local result = capture(BfBot.Exec.Start({}, 0))
        return {
            count = result.count,
            started = result.first,
            code = result.second,
            sameDetail = result.third == detail,
            detailSource = result.third and result.third.source,
        }
        """
    )

    assert facts["count"] == 3
    assert not facts["started"]
    assert facts["code"] == "reason.exec.no_valid_entries"
    assert facts["sameDetail"]
    assert facts["detailSource"] == "synthetic builder"


def test_exec_start_success_returns_fixed_three_value_tuple(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        BfBot.Exec._state = "idle"
        local processed = 0
        BfBot.Exec._BuildQueue = function()
            return {
                p0 = {
                    {
                        casterName = "Synthetic Caster",
                        casterRef = { kind = "party", slot = 0 },
                        spellName = "Synthetic Ward",
                        targetName = "Self",
                        cheat = 0,
                    },
                },
            }, 1, nil
        end
        BfBot.Exec._ProcessCasterEntry = function(key, index)
            assert(key == "p0")
            assert(index == 1)
            processed = processed + 1
        end

        local function capture(...)
            local first, second, third = ...
            return {
                count = select("#", ...),
                first = first,
                secondIsNil = second == nil,
                thirdIsNil = third == nil,
                processed = processed,
            }
        end

        local result = capture(BfBot.Exec.Start({}, 0))
        return result
        """
    )

    assert facts["count"] == 3
    assert facts["first"]
    assert facts["secondIsNil"]
    assert facts["thirdIsNil"]
    assert facts["processed"] == 1


def test_non_ascii_export_names_use_distinct_join_order_fallbacks(
    lua: LuaRuntime,
    tmp_path: Path,
) -> None:
    lua.globals().export_presets_dir = tmp_path.as_posix()
    facts = lua.execute(
        """
        local sprites = {
            { name = "阿莉娜", index = 0 },
            { name = "梅丽珊", index = 1 },
            { name = "Ascii Name", index = 2 },
        }
        local config = BfBot.Persist.GetDefaultConfig()
        BfBot.Persist.GetConfig = function() return config end
        BfBot.Persist._PRESETS_DIR = export_presets_dir
        BfBot.Persist._EnsurePresetsDir = function() end
        BfBot._GetName = function(sprite) return sprite.name end
        EEex_Sprite_GetCharacterIndex = function(sprite) return sprite.index end

        local okA, nameA = BfBot.Persist.ExportConfig(sprites[1])
        local okB, nameB = BfBot.Persist.ExportConfig(sprites[2])
        local okAscii, nameAscii = BfBot.Persist.ExportConfig(sprites[3])
        return {
            okA = okA, nameA = nameA,
            okB = okB, nameB = nameB,
            okAscii = okAscii, nameAscii = nameAscii,
        }
        """
    )

    assert facts["okA"]
    assert facts["nameA"] == "BuffBot-Player1"
    assert facts["okB"]
    assert facts["nameB"] == "BuffBot-Player2"
    assert facts["okAscii"]
    assert facts["nameAscii"] == "AsciiName"
    assert (tmp_path / "BuffBot-Player1.lua").is_file()
    assert (tmp_path / "BuffBot-Player2.lua").is_file()
    assert not (tmp_path / "Unknown.lua").exists()


def test_create_preset_and_create_preset_all_initialize_repeat(
    lua: LuaRuntime,
) -> None:
    single = lua.execute(
        """
        local config = BfBot.Persist.GetDefaultConfig()
        config.presets[1].spells.TEST = {
            on = 1, tgt = "s", pri = 7, rep = 5,
        }
        EEex_Resource_Demand = function() return nil end
        BfBot.Persist.GetConfig = function() return config end
        local idx = BfBot.Persist.CreatePreset("sprite", "New")
        return { idx = idx, rep = config.presets[idx].spells.TEST.rep }
        """
    )

    assert single["idx"] == 3
    assert single["rep"] == 1

    party = lua.execute(
        """
        local configs = {
            A = BfBot.Persist.GetDefaultConfig(),
            B = BfBot.Persist.GetDefaultConfig(),
        }
        configs.A.presets[1].spells.ASPELL = {
            on = 1, tgt = "s", pri = 1, rep = 5,
        }
        configs.B.presets[1].spells.BSPELL = {
            on = 1, tgt = "s", pri = 1, rep = 4,
        }
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return "A" end
            if slot == 1 then return "B" end
            return nil
        end
        BfBot.Persist.GetConfig = function(sprite) return configs[sprite] end
        local idx = BfBot.Persist.CreatePresetAll("Party New")
        return {
            idx = idx,
            aRepeat = configs.A.presets[idx].spells.ASPELL.rep,
            bRepeat = configs.B.presets[idx].spells.BSPELL.rep,
        }
        """
    )

    assert party["idx"] == 3
    assert party["aRepeat"] == 1
    assert party["bRepeat"] == 1


def test_summon_entry_creation_initializes_repeat(
    ui_test_lua: LuaRuntime,
) -> None:
    facts = ui_test_lua.execute(
        """
        local preset = { qc = 0, spells = {} }
        BfBot.UI._presetIdx = 1
        BfBot.UI._SelectedSummon = function()
            return { identity = "skeleton" }
        end
        BfBot.Persist.PeekSummonPreset = function(identity, presetIdx)
            assert(identity == "skeleton" and presetIdx == 1)
            return preset
        end
        local entry = BfBot.UI._SummonSpellEntry("SUMMON", 1)
        return { repeatCount = entry.rep, stored = preset.spells.SUMMON == entry }
        """
    )

    assert facts["repeatCount"] == 1
    assert facts["stored"]


def test_summon_refresh_merge_initializes_repeat(
    ui_test_lua: LuaRuntime,
) -> None:
    facts = ui_test_lua.execute(
        """
        local preset = { qc = 0, spells = {} }
        local config = {
            presets = { [1] = { name = "Long Buffs" } },
        }
        BfBot.UI._presetIdx = 1
        BfBot.UI._UpdateSummonTabNames = function() end
        BfBot.UI._ClampPresetIdx = function() end
        BfBot.UI._UpdateSummonQc = function() end
        BfBot.UI._CastCharLabel = function() return "Cast Skeleton" end
        BfBot.UI._GetStatusText = function() return "" end
        BfBot.UI._SelectedSummon = function()
            return { identity = "skeleton", name = "Skeleton" }
        end
        BfBot.UI._GetSelectedSprite = function() return "summon-sprite" end
        BfBot.UI._SummonTabLabel = function() return "Skeleton" end
        BfBot.UI._EnsureSummonPreset = function() end
        BfBot.UI._BuildSpellRows = function() return {} end
        BfBot.Persist._GetProtagonist = function() return "protagonist" end
        BfBot.Persist.GetConfig = function() return config end
        BfBot.Persist.GetSummonPreset = function() return preset end
        BfBot.Scan.GetCastableSpells = function(sprite)
            assert(sprite == "summon-sprite")
            return {
                NEWSUMMON = {
                    count = 1,
                    class = { isBuff = true, defaultTarget = "s" },
                },
            }
        end
        BfBot.UI._RefreshSummonsView()
        return {
            repeatCount = preset.spells.NEWSUMMON.rep,
            target = preset.spells.NEWSUMMON.tgt,
        }
        """
    )

    assert facts["repeatCount"] == 1
    assert facts["target"] == "s"


def test_repeat_builders_propagate_normalized_counts_without_slot_capping(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local sprite = {
            name = "Caster", m_id = 41,
            m_baseStats = { m_generalState = 0 },
        }
        local config = BfBot.Persist.GetDefaultConfig()
        config.presets[1].spells = {
            FIRST = { on = 1, tgt = "s", pri = 1, rep = 5 },
            SECOND = { on = 1, tgt = "s", pri = 2, rep = "4" },
        }
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return sprite end
            return nil
        end
        BfBot.Persist.GetConfig = function(seen)
            assert(seen == sprite)
            return config
        end
        BfBot.Persist.GetPref = function(key)
            if key == "SummonsJoinCast" then return 0 end
            return BfBot.Persist._INI_DEFAULTS[key]
        end
        BfBot.Persist._CollectLiveCloneDescriptors = function() return {} end
        BfBot.Scan.Invalidate = function() end
        BfBot.Scan.GetCastableSpells = function(seen)
            assert(seen == sprite)
            return {
                FIRST = { count = 1, name = "First", durCat = "long" },
                SECOND = { count = 1, name = "Second", durCat = "short" },
            }
        end

        local party = assert(BfBot.Persist.BuildQueueFromPreset(1))
        local character = assert(BfBot.Persist.BuildQueueForCharacter(0, 1))
        return {
            partyCount = #party,
            partyFirst = party[1].rep,
            partyMalformed = party[2].rep,
            characterCount = #character,
            characterFirst = character[1].rep,
            characterMalformed = character[2].rep,
        }
        """
    )

    assert facts["partyCount"] == 2
    assert facts["partyFirst"] == 5
    assert facts["partyMalformed"] == 1
    assert facts["characterCount"] == 2
    assert facts["characterFirst"] == 5
    assert facts["characterMalformed"] == 1


def test_repeat_summon_builder_propagates_counts_and_own_quick_cast(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local sprite = {
            name = "Skeleton", m_id = 77,
            m_baseStats = { m_generalState = 0 },
        }
        local preset = { qc = 2, spells = {
            FIRST = { on = 1, tgt = "s", pri = 1, rep = 5,
                      var = "FIRSTV" },
            SECOND = { on = 1, tgt = "s", pri = 2, rep = 9 },
        } }
        BfBot.Persist.PeekSummonPreset = function(identity, presetIdx)
            assert(identity == "summon:test" and presetIdx == 1)
            return preset
        end
        BfBot.Exec._ResolveCaster = function(ref)
            assert(ref.kind == "summon" and ref.oid == 77
                and ref.name == "Skeleton")
            return sprite
        end
        BfBot.Scan.Invalidate = function() end
        BfBot.Scan.GetCastableSpells = function(seen)
            assert(seen == sprite)
            return {
                FIRST = { count = 1, name = "First", durCat = "long" },
                SECOND = { count = 1, name = "Second", durCat = "short" },
            }
        end

        local queue = assert(BfBot.Persist.BuildQueueForSummon({
            identity = "summon:test", oid = 77, name = "Skeleton",
        }, 1))
        return {
            count = #queue,
            firstRepeat = queue[1].rep,
            malformedRepeat = queue[2].rep,
            variant = queue[1].var,
            firstCheat = queue[1].cheat,
            secondCheat = queue[2].cheat,
        }
        """
    )

    assert facts["count"] == 2
    assert facts["firstRepeat"] == 5
    assert facts["malformedRepeat"] == 1
    assert facts["variant"] == "FIRSTV"
    assert facts["firstCheat"] == 1
    assert facts["secondCheat"] == 1


def test_project_image_classification_uses_opcode_236_image_type(
    project_image_lua: LuaRuntime,
) -> None:
    facts = project_image_lua.execute(
        """
        local function classify(resref, imageType)
            local ability = BfBot_TestAbility({
                { effectID = 236, dwFlags = imageType },
            })
            local header = BfBot_TestHeader(ability)
            return BfBot.Class.Classify(resref, header, ability)
        end

        local projectImage = classify("NOTVANIL", 2)
        local mislead = classify("MISLEAD", 1)
        local simulacrum = classify("SIMUL", 3)

        BfBot._overrides.OVERRIDE = false
        local overridden = classify("OVERRIDE", 2)
        return {
            projectImage = projectImage.isProjectImage == true,
            mislead = mislead.isProjectImage == true,
            simulacrum = simulacrum.isProjectImage == true,
            overridden = overridden.isProjectImage == true,
        }
        """
    )

    assert facts["projectImage"]
    assert not facts["mislead"]
    assert not facts["simulacrum"]
    assert facts["overridden"]


def test_project_image_classification_recomputes_flag_across_resref_cache(
    project_image_lua: LuaRuntime,
) -> None:
    facts = project_image_lua.execute(
        """
        local misleadAbility = BfBot_TestAbility({
            { effectID = 236, dwFlags = 1 },
        })
        local projectImageAbility = BfBot_TestAbility({
            { effectID = 236, dwFlags = 2 },
        })
        local misleadHeader = BfBot_TestHeader(misleadAbility)
        local projectImageHeader = BfBot_TestHeader(projectImageAbility)

        -- Non-PI first, then PI under the same resref.
        local nonPiFirst = BfBot.Class.Classify(
            "SAME", misleadHeader, misleadAbility)
        local piSecond = BfBot.Class.Classify(
            "SAME", projectImageHeader, projectImageAbility)
        local forwardCached = BfBot._cache.class.SAME

        -- PI first, then non-PI under the same resref.
        BfBot._cache.class = {}
        local piFirst = BfBot.Class.Classify(
            "SAME", projectImageHeader, projectImageAbility)
        local nonPiSecond = BfBot.Class.Classify(
            "SAME", misleadHeader, misleadAbility)
        local reverseCached = BfBot._cache.class.SAME

        return {
            forwardFirst = nonPiFirst.isProjectImage == true,
            forwardSecond = piSecond.isProjectImage == true,
            forwardDistinct = nonPiFirst ~= piSecond,
            forwardCacheUnchanged = forwardCached.isProjectImage == false,
            forwardOtherFieldsReused = piSecond.leafResrefs
                == nonPiFirst.leafResrefs,
            reverseFirst = piFirst.isProjectImage == true,
            reverseSecond = nonPiSecond.isProjectImage == true,
            reverseDistinct = piFirst ~= nonPiSecond,
            reverseCacheUnchanged = reverseCached.isProjectImage == true,
            reverseOtherFieldsReused = nonPiSecond.leafResrefs
                == piFirst.leafResrefs,
        }
        """
    )

    assert not facts["forwardFirst"]
    assert facts["forwardSecond"]
    assert facts["forwardDistinct"]
    assert facts["forwardCacheUnchanged"]
    assert facts["forwardOtherFieldsReused"]
    assert facts["reverseFirst"]
    assert not facts["reverseSecond"]
    assert facts["reverseDistinct"]
    assert facts["reverseCacheUnchanged"]
    assert facts["reverseOtherFieldsReused"]


def test_project_image_classification_recurses_two_wrappers_and_guards_cycles(
    project_image_lua: LuaRuntime,
) -> None:
    facts = project_image_lua.execute(
        """
        local leafAbility = BfBot_TestAbility({
            { effectID = 236, dwFlags = 2 },
        })
        local midAbility = BfBot_TestAbility({
            { effectID = 146, res = "LEAF" },
        })
        local rootAbility = BfBot_TestAbility({
            { effectID = 146, res = "MID" },
        })
        BfBot_TestResources.LEAF = BfBot_TestHeader(leafAbility)
        BfBot_TestResources.MID = BfBot_TestHeader(midAbility)
        local rootHeader = BfBot_TestHeader(rootAbility)
        local wrapped = BfBot.Class.Classify(
            "ROOT", rootHeader, rootAbility).isProjectImage == true

        -- A third wrapper is outside the established depth-2 boundary.
        local tooDeepLeaf = BfBot_TestAbility({
            { effectID = 236, dwFlags = 2 },
        })
        local tooDeepB = BfBot_TestAbility({
            { effectID = 146, res = "DEEPLEAF" },
        })
        local tooDeepA = BfBot_TestAbility({
            { effectID = 146, res = "DEEPB" },
        })
        local tooDeepRoot = BfBot_TestAbility({
            { effectID = 146, res = "DEEPA" },
        })
        BfBot_TestResources.DEEPLEAF = BfBot_TestHeader(tooDeepLeaf)
        BfBot_TestResources.DEEPB = BfBot_TestHeader(tooDeepB)
        BfBot_TestResources.DEEPA = BfBot_TestHeader(tooDeepA)
        local beyondLimit = BfBot.Class.Classify(
            "DEEPROOT", BfBot_TestHeader(tooDeepRoot), tooDeepRoot)
            .isProjectImage == true

        -- The helper receives the root resref so a child that points back to
        -- it is rejected by the case-insensitive visited set instead of being
        -- demanded again.
        local cycleAbility = BfBot_TestAbility({
            { effectID = 146, res = "cycleroot" },
            { effectID = 236, dwFlags = 2 },
        })
        local cycleRootAbility = BfBot_TestAbility({
            { effectID = 146, res = "CYCLE" },
        })
        BfBot_TestResources.CYCLE = BfBot_TestHeader(cycleAbility)
        BfBot_TestResources.CYCLEROOT = BfBot_TestHeader(cycleRootAbility)
        BfBot_TestResourceDemands = {}
        local helper = BfBot.Class._IsProjectImage
        local cycleSafe = type(helper) == "function"
            and helper("CYCLEROOT", BfBot_TestResources.CYCLEROOT,
                cycleRootAbility) == true
        return {
            wrapped = wrapped,
            beyondLimit = beyondLimit,
            cycleSafe = cycleSafe,
            cycleRootDemands = BfBot_TestResourceDemands.CYCLEROOT or 0,
            cycleRootLowerDemands = BfBot_TestResourceDemands.cycleroot or 0,
            cycleChildDemands = BfBot_TestResourceDemands.CYCLE or 0,
        }
        """
    )

    assert facts["wrapped"]
    assert not facts["beyondLimit"]
    assert facts["cycleSafe"]
    assert facts["cycleRootDemands"] == 0
    assert facts["cycleRootLowerDemands"] == 0
    assert facts["cycleChildDemands"] == 1


def test_project_image_wrapper_dag_revisits_child_at_shallower_depth(
    project_image_lua: LuaRuntime,
) -> None:
    detected = project_image_lua.execute(
        """
        -- ROOT first reaches X too deeply to follow X -> PI, then reaches the
        -- same X directly. A global seen-set must not suppress that valid
        -- shallower path.
        local projectImage = BfBot_TestAbility({
            { effectID = 236, dwFlags = 2 },
        })
        local x = BfBot_TestAbility({
            { effectID = 146, res = "PI" },
        })
        local a = BfBot_TestAbility({
            { effectID = 146, res = "X" },
        })
        local root = BfBot_TestAbility({
            { effectID = 146, res = "A" },
            { effectID = 146, res = "X" },
        })
        BfBot_TestResources.PI = BfBot_TestHeader(projectImage)
        BfBot_TestResources.X = BfBot_TestHeader(x)
        BfBot_TestResources.A = BfBot_TestHeader(a)

        return BfBot.Class._IsProjectImage(
            "ROOT", BfBot_TestHeader(root), root)
        """
    )

    assert detected


def test_project_image_scan_entry_carries_integer_structural_flag(
    project_image_lua: LuaRuntime,
) -> None:
    facts = project_image_lua.execute(
        SCAN_SOURCE
        + """
        local ability = BfBot_TestAbility({
            { effectID = 236, dwFlags = 2 },
        })
        local header = BfBot_TestHeader(ability)
        BfBot_TestResources.ZHPI = header

        local sprite = { m_id = 91 }
        sprite.getCasterLevelForSpell = function() return 14 end
        sprite.GetQuickButtons = function() return nil end

        EEex_Sprite_GetKnownMageSpellsWithAbilityIterator = function(seen)
            assert(seen == sprite)
            local yielded = false
            return function()
                if yielded then return nil end
                yielded = true
                return 7, 0, "ZHPI", ability
            end
        end
        EEex_Sprite_GetKnownPriestSpellsWithAbilityIterator = function()
            return function() return nil end
        end
        EEex_Sprite_GetKnownInnateSpellsWithAbilityIterator = function()
            return function() return nil end
        end

        local spells = BfBot.Scan.GetCastableSpells(sprite)
        local entry = assert(spells.ZHPI)
        return {
            name = entry.name,
            scanFlag = entry.isProjectImage,
            classFlag = entry.class and entry.class.isProjectImage == true,
        }
        """
    )

    assert facts["name"] == "投影术"
    assert facts["scanFlag"] == 1
    assert facts["classFlag"]


def test_project_image_flag_propagates_through_party_and_summon_builders(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local sprite = {
            name = "Caster", m_id = 41,
            m_baseStats = { m_generalState = 0 },
        }
        local preset = { qc = 0, spells = {
            PI = { on = 1, tgt = "s", pri = 1, rep = 5 },
            TAIL = { on = 1, tgt = "s", pri = 2, rep = 4 },
        } }
        local config = BfBot.Persist.GetDefaultConfig()
        config.presets[1] = preset
        local castable = {
            PI = {
                count = 1, name = "投影术",
                durCat = "long", isProjectImage = 1,
            },
            TAIL = { count = 1, name = "Stoneskin", durCat = "long" },
        }

        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return sprite end
            return nil
        end
        BfBot.Persist.GetConfig = function(seen)
            assert(seen == sprite)
            return config
        end
        BfBot.Persist.GetPref = function(key)
            if key == "SummonsJoinCast" then return 0 end
            return BfBot.Persist._INI_DEFAULTS[key]
        end
        BfBot.Persist._CollectLiveCloneDescriptors = function() return {} end
        BfBot.Scan.Invalidate = function() end
        BfBot.Scan.GetCastableSpells = function(seen)
            assert(seen == sprite)
            return castable
        end

        local party = assert(BfBot.Persist.BuildQueueFromPreset(1))
        local character = assert(BfBot.Persist.BuildQueueForCharacter(0, 1))

        BfBot.Persist.PeekSummonPreset = function(identity, presetIdx)
            assert(identity == "summon:test" and presetIdx == 1)
            return preset
        end
        BfBot.Exec._ResolveCaster = function(ref)
            assert(ref.kind == "summon" and ref.oid == 77)
            return sprite
        end
        local summon = assert(BfBot.Persist.BuildQueueForSummon({
            identity = "summon:test", oid = 77, name = "Skeleton",
        }, 1))
        return {
            partyCount = #party,
            partyRepeat = party[1] and party[1].rep,
            characterCount = #character,
            characterRepeat = character[1] and character[1].rep,
            summonCount = #summon,
            summonRepeat = summon[1] and summon[1].rep,
        }
        """
    )

    assert facts["partyCount"] == 1
    assert facts["partyRepeat"] == 1
    assert facts["characterCount"] == 1
    assert facts["characterRepeat"] == 1
    assert facts["summonCount"] == 1
    assert facts["summonRepeat"] == 1


def test_project_image_repeat_is_copied_and_forced_to_one_by_structural_flag(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local caster = { oid = 100, name = "Mage" }
        local image = {
            caster = 0, spell = "PI", spellName = "投影术",
            isProjectImage = 1,
            target = "self", pri = 1, rep = 5,
        }
        local tail = {
            caster = 0, spell = "TAIL", spellName = "Stoneskin",
            target = "self", pri = 2, rep = 4,
        }
        local kept, skips = BfBot.Persist._ApplyPuppetLockPolicy(
            caster, { image, tail }, {})
        local englishOnly = {
            caster = 0, spell = "PLAIN", spellName = "Project Image",
            target = "self", pri = 1, rep = 5,
        }
        local plainKept, plainSkips = BfBot.Persist._ApplyPuppetLockPolicy(
            caster, { englishOnly, tail }, {})
        local locked = BfBot.Persist._ApplyPuppetLockPolicy(
            caster, { image }, {
                { cloneType = 2, ownerOid = 100, ownerName = "Mage" },
            })
        return {
            keptCount = #kept,
            retainedRepeat = kept[1] and kept[1].rep,
            copied = kept[1] ~= image,
            sourceRepeat = image.rep,
            tailRepeat = tail.rep,
            skipCount = #skips,
            plainKeptCount = #plainKept,
            plainSkipCount = #plainSkips,
            plainFirstUnchanged = plainKept[1] == englishOnly,
            lockedCount = #locked,
        }
        """
    )

    assert facts["keptCount"] == 1
    assert facts["retainedRepeat"] == 1
    assert facts["copied"]
    assert facts["sourceRepeat"] == 5
    assert facts["tailRepeat"] == 4
    assert facts["skipCount"] == 1
    assert facts["plainKeptCount"] == 2
    assert facts["plainSkipCount"] == 0
    assert facts["plainFirstUnchanged"]
    assert facts["lockedCount"] == 0


def test_repeat_expansion_normalizes_values_and_keeps_distinct_entries(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        BfBot_TestQueueWorld({
            MISSING = { count = 1, name = "Missing", class = {} },
            ONE = { count = 1, name = "One", class = {} },
            FIVE = { count = 1, name = "Five", class = {} },
            STRING = { count = 1, name = "String", class = {} },
            HIGH = { count = 1, name = "High", class = {} },
        }, 1)
        local byCaster, total = BfBot.Exec._BuildQueue({
            { caster = 0, spell = "MISSING", target = "self" },
            { caster = 0, spell = "ONE", target = "self", rep = 1 },
            { caster = 0, spell = "FIVE", target = "self", rep = 5 },
            { caster = 0, spell = "STRING", target = "self", rep = "5" },
            { caster = 0, spell = "HIGH", target = "self", rep = 6 },
        }, 0)
        local queue = assert(byCaster.p0)
        local distinct = true
        for i = 1, #queue do
            for j = i + 1, #queue do
                if queue[i] == queue[j] then distinct = false end
            end
        end

        -- Exec must remain defensive when persistence was not loaded or its
        -- normalizer is replaced by a non-callable value.
        BfBot.Persist._NormalizeSpellRepeat = nil
        local fallback, fallbackTotal = BfBot.Exec._BuildQueue({
            { caster = 0, spell = "FIVE", target = "self", rep = 5 },
            { caster = 0, spell = "STRING", target = "self", rep = "5" },
        }, 0)
        return {
            total = total,
            queueCount = #queue,
            oneCount = (function()
                local n = 0
                for _, entry in ipairs(queue) do
                    if entry.resref == "ONE" then n = n + 1 end
                end
                return n
            end)(),
            missingCount = (function()
                local n = 0
                for _, entry in ipairs(queue) do
                    if entry.resref == "MISSING" then n = n + 1 end
                end
                return n
            end)(),
            fiveCount = (function()
                local n = 0
                for _, entry in ipairs(queue) do
                    if entry.resref == "FIVE" then n = n + 1 end
                end
                return n
            end)(),
            distinct = distinct,
            fallbackTotal = fallbackTotal,
            fallbackCount = fallback and #fallback.p0 or 0,
        }
        """
    )

    assert facts["total"] == 9
    assert facts["queueCount"] == 9
    assert facts["missingCount"] == 1
    assert facts["oneCount"] == 1
    assert facts["fiveCount"] == 5
    assert facts["distinct"]
    assert facts["fallbackTotal"] == 6
    assert facts["fallbackCount"] == 6


def test_repeat_expansion_keeps_spell_priority_contiguous(
    exec_lua: LuaRuntime,
) -> None:
    sequence = exec_lua.execute(
        """
        BfBot_TestQueueWorld({
            S = { count = 1, name = "S", class = {} },
            B = { count = 1, name = "B", class = {} },
        }, 1)
        local byCaster = assert(BfBot.Exec._BuildQueue({
            { caster = 0, spell = "S", target = "self", rep = 5 },
            { caster = 0, spell = "B", target = "self", rep = 1 },
        }, 0))
        local out = {}
        for _, entry in ipairs(byCaster.p0) do
            out[#out + 1] = entry.resref
        end
        return table.concat(out, ",")
        """
    )

    assert sequence == "S,S,S,S,S,B"


def test_repeat_expansion_is_target_outer_for_explicit_targets(
    exec_lua: LuaRuntime,
) -> None:
    sequence = exec_lua.execute(
        """
        BfBot_TestQueueWorld({
            BUFF = { count = 1, name = "Buff", class = {} },
        }, 2)
        local byCaster = assert(BfBot.Exec._BuildQueue({
            { caster = 0, spell = "BUFF", target = 1, rep = 2 },
            { caster = 0, spell = "BUFF", target = 2, rep = 2 },
        }, 0))
        local out = {}
        for _, entry in ipairs(byCaster.p0) do
            out[#out + 1] = entry.targetObj
        end
        return table.concat(out, ",")
        """
    )

    assert sequence == "Player1,Player1,Player2,Player2"


def test_repeat_expansion_is_target_outer_for_non_aoe_all(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        BfBot_TestQueueWorld({
            BUFF = {
                count = 1, name = "Buff",
                class = { isAoE = false, splstates = {} },
            },
        }, 2)
        local byCaster, total = BfBot.Exec._BuildQueue({
            { caster = 0, spell = "BUFF", target = "all", rep = 2 },
        }, 0)
        local out = {}
        for _, entry in ipairs(byCaster.p0) do
            out[#out + 1] = entry.targetObj
        end
        return { total = total, sequence = table.concat(out, ",") }
        """
    )

    assert facts["total"] == 4
    assert facts["sequence"] == "Player1,Player1,Player2,Player2"


def test_repeat_expansion_casts_aoe_all_only_repeat_count_times(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        BfBot_TestQueueWorld({
            AOE = {
                count = 1, name = "Area Buff",
                class = { isAoE = true, splstates = {} },
            },
        }, 2)
        local byCaster, total = BfBot.Exec._BuildQueue({
            { caster = 0, spell = "AOE", target = "all", rep = 2 },
        }, 0)
        return {
            total = total,
            queueCount = #byCaster.p0,
            firstTarget = byCaster.p0[1].targetObj,
            secondTarget = byCaster.p0[2] and byCaster.p0[2].targetObj,
        }
        """
    )

    assert facts["total"] == 2
    assert facts["queueCount"] == 2
    assert facts["firstTarget"] == "Myself"
    assert facts["secondTarget"] == "Myself"


def test_repeat_expansion_preserves_quick_cast_modes_and_summon_override(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        BfBot_TestQueueWorld({
            SHORT = { count = 1, name = "Short", class = {} },
            LONG = { count = 1, name = "Long", class = {} },
            PERM = { count = 1, name = "Permanent", class = {} },
        }, 1)
        local raw = {
            { caster = 0, spell = "SHORT", target = "self",
              durCat = "short", rep = 2 },
            { caster = 0, spell = "LONG", target = "self",
              durCat = "long", rep = 2 },
            { caster = 0, spell = "PERM", target = "self",
              durCat = "permanent", rep = 2 },
        }
        local function flags(qc)
            local by = assert(BfBot.Exec._BuildQueue(raw, qc))
            local out = {}
            for _, entry in ipairs(by.p0) do
                out[#out + 1] = entry.cheat and "1" or "0"
            end
            return table.concat(out), #by.p0
        end
        local off, offCount = flags(0)
        local long, longCount = flags(1)
        local all, allCount = flags(2)

        local summonRef = { kind = "summon", oid = 77, name = "Skeleton" }
        local forcedOff = assert(BfBot.Exec._BuildQueue({ {
            casterRef = summonRef, spell = "LONG", target = "self",
            durCat = "long", rep = 2, cheat = 0,
        } }, 2))
        local forcedOn = assert(BfBot.Exec._BuildQueue({ {
            casterRef = summonRef, spell = "SHORT", target = "self",
            durCat = "short", rep = 2, cheat = 1,
        } }, 0))
        local key = "s77"
        return {
            off = off, offCount = offCount,
            long = long, longCount = longCount,
            all = all, allCount = allCount,
            forcedOffCount = #forcedOff[key],
            forcedOff = (forcedOff[key][1].cheat and "1" or "0")
                .. (forcedOff[key][2] and
                    (forcedOff[key][2].cheat and "1" or "0") or "x"),
            forcedOnCount = #forcedOn[key],
            forcedOn = (forcedOn[key][1].cheat and "1" or "0")
                .. (forcedOn[key][2] and
                    (forcedOn[key][2].cheat and "1" or "0") or "x"),
        }
        """
    )

    assert facts["offCount"] == 6
    assert facts["off"] == "000000"
    assert facts["longCount"] == 6
    assert facts["long"] == "001111"
    assert facts["allCount"] == 6
    assert facts["all"] == "111111"
    assert facts["forcedOffCount"] == 2
    assert facts["forcedOff"] == "00"
    assert facts["forcedOnCount"] == 2
    assert facts["forcedOn"] == "11"


def test_item_repeat_expansion_retains_item_metadata_and_party_ref(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local leafs = { "ITEMLEAF" }
        BfBot_TestQueueWorld({
            ITEM = {
                kind = "itm", count = 2, name = "Buff Item",
                leafResrefs = leafs,
                class = { splstates = {} },
            },
        }, 1)
        local byCaster, total = BfBot.Exec._BuildQueue({ {
            caster = 0, spell = "ITEM", target = "self",
            durCat = "long", rep = 2,
        } }, 2)
        local queue = assert(byCaster.p0)
        return {
            total = total,
            queueCount = #queue,
            distinct = queue[1] ~= queue[2],
            kind1 = queue[1].kind,
            kind2 = queue[2].kind,
            leaf1 = queue[1].leafResrefs[1],
            leaf2 = queue[2].leafResrefs[1],
            cheat1 = queue[1].cheat,
            cheat2 = queue[2].cheat,
            casterKind = queue[1].casterRef.kind,
            casterSlot = queue[1].casterRef.slot,
            cachedSprite = queue[1].casterSprite,
        }
        """
    )

    assert facts["total"] == 2
    assert facts["queueCount"] == 2
    assert facts["distinct"]
    assert facts["kind1"] == "itm"
    assert facts["kind2"] == "itm"
    assert facts["leaf1"] == "ITEMLEAF"
    assert facts["leaf2"] == "ITEMLEAF"
    assert not facts["cheat1"]
    assert not facts["cheat2"]
    assert facts["casterKind"] == "party"
    assert facts["casterSlot"] == 0
    assert facts["cachedSprite"] is None


def test_item_execution_uses_fresh_sprite_and_leaf_recheck_skips_repeat(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local spells = {
            ITEM = {
                kind = "itm", count = 2, name = "Buff Item",
                leafResrefs = { "ITEMLEAF" },
                class = { splstates = {} },
            },
        }
        local buildSprites = BfBot_TestQueueWorld(spells, 1)
        local byCaster = assert(BfBot.Exec._BuildQueue({ {
            caster = 0, spell = "ITEM", target = "self", rep = 2,
        } }, 2))
        local freshSprite = {
            name = "Fresh A", m_id = 100,
            m_baseStats = { m_generalState = 0 },
        }
        local actions, queuedOnFresh, active, checkedLeaf = {}, true, false, false
        EEex_Action_QueueResponseStringOnAIBase = function(action, sprite)
            if sprite ~= freshSprite then queuedOnFresh = false end
            actions[#actions + 1] = action
        end
        BfBot.Exec._ResolveCasterForStep = function() return freshSprite end
        BfBot.Exec._DetectCombat = function() return false end
        BfBot.Exec._HasActiveEffect = function(_, resref)
            if resref == "ITEMLEAF" then checkedLeaf = true end
            return active and resref == "ITEMLEAF"
        end
        BfBot.Exec._NoteProgress = function() end
        BfBot.Exec._Complete = function() BfBot.Exec._state = "done" end
        BfBot.Exec._state = "running"
        BfBot.Exec._castCount = 0
        BfBot.Exec._skipCount = 0
        BfBot.Exec._activeCasters = 1
        BfBot.Exec._casters = { p0 = {
            ref = { kind = "party", slot = 0 },
            queue = byCaster.p0, index = 0, done = false,
            name = "A", cheatBoundary = 0, cheatApplied = false,
        } }

        BfBot.Exec._ProcessCasterEntry("p0", 1)
        active = true
        BfBot.Exec._Advance("p0")
        return {
            buildAndFreshDiffer = buildSprites[1] ~= freshSprite,
            queuedOnFresh = queuedOnFresh,
            actionCount = #actions,
            firstAction = actions[1],
            secondAction = actions[2],
            checkedLeaf = checkedLeaf,
            castCount = BfBot.Exec._castCount,
            skipCount = BfBot.Exec._skipCount,
            state = BfBot.Exec._state,
        }
        """
    )

    assert facts["buildAndFreshDiffer"]
    assert facts["queuedOnFresh"]
    assert facts["actionCount"] == 2
    assert facts["firstAction"] == 'UseItem("ITEM",Myself)'
    assert facts["secondAction"] == (
        'EEex_LuaAction("BfBot.Exec._Advance([[p0]])")'
    )
    assert facts["checkedLeaf"]
    assert facts["castCount"] == 1
    assert facts["skipCount"] == 1
    assert facts["state"] == "done"


def test_repeat_attempts_recheck_slots_and_continue_to_later_priority(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local spells = {
            S = { count = 1, name = "S", class = { splstates = {} } },
            B = { count = 1, name = "B", class = { splstates = {} } },
        }
        local sprites = BfBot_TestQueueWorld(spells, 1)
        local byCaster = assert(BfBot.Exec._BuildQueue({
            { caster = 0, spell = "S", target = "self", rep = 5 },
            { caster = 0, spell = "B", target = "self", rep = 1 },
        }, 0))
        local actions = {}
        EEex_Action_QueueResponseStringOnAIBase = function(action, sprite)
            assert(sprite == sprites[1])
            actions[#actions + 1] = action
        end
        BfBot.Exec._ResolveCasterForStep = function() return sprites[1] end
        BfBot.Exec._DetectCombat = function() return false end
        BfBot.Exec._HasActiveEffect = function() return false end
        BfBot.Exec._NoteProgress = function() end
        BfBot.Exec._state = "running"
        BfBot.Exec._castCount = 0
        BfBot.Exec._skipCount = 0
        BfBot.Exec._activeCasters = 1
        BfBot.Exec._casters = { p0 = {
            ref = { kind = "party", slot = 0 },
            queue = byCaster.p0, index = 0, done = false,
            name = "A", cheatBoundary = 0, cheatApplied = false,
        } }

        BfBot.Exec._ProcessCasterEntry("p0", 1)
        spells.S.count = 0
        BfBot.Exec._Advance("p0")
        local spellActions = {}
        for _, action in ipairs(actions) do
            if action:find("SpellRES", 1, true) == 1 then
                spellActions[#spellActions + 1] = action
            end
        end
        return {
            queueCount = #byCaster.p0,
            castCount = BfBot.Exec._castCount,
            skipCount = BfBot.Exec._skipCount,
            spellActions = table.concat(spellActions, "|"),
            currentIndex = BfBot.Exec._casters.p0.index,
        }
        """
    )

    assert facts["queueCount"] == 6
    assert facts["castCount"] == 2
    assert facts["skipCount"] == 4
    assert 'SpellRES("S",Myself)' in facts["spellActions"]
    assert 'SpellRES("B",Myself)' in facts["spellActions"]
    assert facts["currentIndex"] == 6


def test_repeat_attempts_recheck_active_effects_after_first_cast(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local spells = {
            BUFF = {
                count = 3, name = "Buff", class = { splstates = {} },
            },
        }
        local sprites = BfBot_TestQueueWorld(spells, 1)
        local byCaster = assert(BfBot.Exec._BuildQueue({
            { caster = 0, spell = "BUFF", target = "self", rep = 3 },
        }, 0))
        local active = false
        EEex_Action_QueueResponseStringOnAIBase = function() end
        BfBot.Exec._ResolveCasterForStep = function() return sprites[1] end
        BfBot.Exec._DetectCombat = function() return false end
        BfBot.Exec._HasActiveEffect = function() return active end
        BfBot.Exec._NoteProgress = function() end
        BfBot.Exec._Complete = function()
            BfBot.Exec._state = "done"
        end
        BfBot.Exec._state = "running"
        BfBot.Exec._castCount = 0
        BfBot.Exec._skipCount = 0
        BfBot.Exec._activeCasters = 1
        BfBot.Exec._casters = { p0 = {
            ref = { kind = "party", slot = 0 },
            queue = byCaster.p0, index = 0, done = false,
            name = "A", cheatBoundary = 0, cheatApplied = false,
        } }

        BfBot.Exec._ProcessCasterEntry("p0", 1)
        active = true
        BfBot.Exec._Advance("p0")
        return {
            queueCount = #byCaster.p0,
            castCount = BfBot.Exec._castCount,
            skipCount = BfBot.Exec._skipCount,
            state = BfBot.Exec._state,
        }
        """
    )

    assert facts["queueCount"] == 3
    assert facts["castCount"] == 1
    assert facts["skipCount"] == 2
    assert facts["state"] == "done"


def test_many_already_active_repeat_attempts_complete_without_stack_growth(
    exec_lua: LuaRuntime,
) -> None:
    # Lupa implements protected Lua calls with Windows SEH signals. Suppress
    # pytest's faulthandler while this regression intentionally crosses the
    # old overflow threshold; the Lua pcall result remains fully asserted.
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        facts = exec_lua.execute(
            """
        local sprites = {}
        for i = 1, 6 do
            sprites[i] = {
                name = "P" .. i,
                m_id = 100 + i,
                m_baseStats = { m_generalState = 0 },
            }
        end

        local spells = {}
        local rawQueue = {}
        for i = 1, 400 do
            local resref = string.format("R%04d", i)
            spells[resref] = {
                count = 1,
                name = resref,
                class = { isAoE = false, splstates = {} },
            }
            rawQueue[i] = {
                caster = 0,
                spell = resref,
                target = "all",
                rep = 5,
            }
        end

        BfBot.Exec._ResolveCaster = function() return sprites[1] end
        BfBot.Scan.GetCastableSpells = function() return spells end
        BfBot.Scan.Invalidate = function() end
        BfBot.Exec._IsAlive = function(sprite) return sprite ~= nil end
        EEex_Sprite_GetInPortrait = function(slot)
            return sprites[slot + 1]
        end
        EEex_Sprite_GetCharacterIndex = function(sprite)
            for i = 1, #sprites do
                if sprite == sprites[i] then return i - 1 end
            end
            error("unknown synthetic sprite")
        end

        local byCaster, total = BfBot.Exec._BuildQueue(rawQueue, 0)
        assert(total == 12000 and #byCaster.p0 == 12000)

        local actionCount = 0
        EEex_Action_QueueResponseStringOnAIBase = function()
            actionCount = actionCount + 1
        end
        BfBot.Exec._HasActiveEffect = function() return true end
        -- Keep the production skip/check/resolve/completion paths, but avoid
        -- retaining 12,000 log messages in this stack-safety regression.
        BfBot.Exec._LogEntry = function() end
        BfBot.Exec._state = "running"
        BfBot.Exec._castCount = 0
        BfBot.Exec._skipCount = 0
        BfBot.Exec._activeCasters = 1
        BfBot.Exec._totalEntries = total
        BfBot.Exec._casters = { p0 = {
            ref = { kind = "party", slot = 0 },
            queue = byCaster.p0,
            index = 0,
            done = false,
            name = "P1",
            cheatBoundary = 0,
            cheatApplied = false,
        } }

        local ok, err = pcall(BfBot.Exec._ProcessCasterEntry, "p0", 1)
        return {
            ok = ok,
            error = tostring(err),
            state = BfBot.Exec._state,
            skipCount = BfBot.Exec._skipCount,
            castCount = BfBot.Exec._castCount,
            activeCasters = BfBot.Exec._activeCasters,
            casterDone = BfBot.Exec._casters.p0.done,
            casterIndex = BfBot.Exec._casters.p0.index,
            actionCount = actionCount,
            total = total,
        }
            """
        )
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert facts["ok"], facts["error"]
    assert facts["total"] == 12_000
    assert facts["skipCount"] == 12_000
    assert facts["castCount"] == 0
    assert facts["actionCount"] == 0
    assert facts["activeCasters"] == 0
    assert facts["casterDone"] is True
    assert facts["casterIndex"] == 12_000
    assert facts["state"] == "done"


def test_variant_repeat_attempts_consume_the_parent_slot_each_time(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local spells = {
            PARENT = {
                count = 3, name = "Parent", class = { splstates = {} },
            },
        }
        local sprites = BfBot_TestQueueWorld(spells, 1)
        local byCaster = assert(BfBot.Exec._BuildQueue({
            { caster = 0, spell = "PARENT", target = "self",
              rep = 3, var = "VARIANT" },
        }, 0))
        local actions = {}
        local consumeCalls = 0
        BfBot.Exec._ConsumeSpellSlot = function(sprite, resref)
            assert(sprite == sprites[1] and resref == "PARENT")
            consumeCalls = consumeCalls + 1
            return consumeCalls ~= 2
        end
        EEex_Action_QueueResponseStringOnAIBase = function(action)
            actions[#actions + 1] = action
        end
        BfBot.Exec._ResolveCasterForStep = function() return sprites[1] end
        BfBot.Exec._DetectCombat = function() return false end
        BfBot.Exec._HasActiveEffect = function() return false end
        BfBot.Exec._NoteProgress = function() end
        BfBot.Exec._state = "running"
        BfBot.Exec._castCount = 0
        BfBot.Exec._skipCount = 0
        BfBot.Exec._activeCasters = 1
        BfBot.Exec._casters = { p0 = {
            ref = { kind = "party", slot = 0 },
            queue = byCaster.p0, index = 0, done = false,
            name = "A", cheatBoundary = 0, cheatApplied = false,
        } }

        BfBot.Exec._ProcessCasterEntry("p0", 1)
        BfBot.Exec._Advance("p0")
        BfBot.Exec._Advance("p0")
        local variantCasts = 0
        for _, action in ipairs(actions) do
            if action == 'ReallyForceSpellRES("VARIANT",Myself)' then
                variantCasts = variantCasts + 1
            end
        end
        return {
            queueCount = #byCaster.p0,
            consumeCalls = consumeCalls,
            variantCasts = variantCasts,
            castCount = BfBot.Exec._castCount,
            skipCount = BfBot.Exec._skipCount,
        }
        """
    )

    assert facts["queueCount"] == 3
    assert facts["consumeCalls"] == 3
    assert facts["variantCasts"] == 2
    assert facts["castCount"] == 2
    assert facts["skipCount"] == 1


def test_late_summon_attachment_uses_repeat_expansion(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        BfBot_TestQueueWorld({
            BUFF = { count = 1, name = "Buff", class = {} },
        }, 1)
        local kickedKey, kickedIndex
        BfBot.Exec._ProcessCasterEntry = function(key, index)
            kickedKey, kickedIndex = key, index
        end
        BfBot.Exec._NoteProgress = function() end
        BfBot.Exec._state = "running"
        BfBot.Exec._qcMode = 0
        BfBot.Exec._casters = {}
        BfBot.Exec._activeCasters = 0
        BfBot.Exec._totalEntries = 0
        local attached = BfBot.Exec._AttachCaster(
            { oid = 77, name = "Skeleton" },
            { {
                casterRef = { kind = "summon", oid = 77, name = "Skeleton" },
                spell = "BUFF", target = "self", rep = 3, cheat = 1,
            } })
        local caster = BfBot.Exec._casters.s77
        return {
            attached = attached,
            queueCount = caster and #caster.queue or 0,
            totalEntries = BfBot.Exec._totalEntries,
            cheatBoundary = caster and caster.cheatBoundary or 0,
            kickedKey = kickedKey,
            kickedIndex = kickedIndex,
        }
        """
    )

    assert facts["attached"]
    assert facts["queueCount"] == 3
    assert facts["totalEntries"] == 3
    assert facts["cheatBoundary"] == 3
    assert facts["kickedKey"] == "s77"
    assert facts["kickedIndex"] == 1


def test_repeat_attempts_preserve_stop_gone_summon_and_watchdog_boundaries(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local sprites = BfBot_TestQueueWorld({
            BUFF = {
                count = 3, name = "Buff", class = { splstates = {} },
            },
        }, 1)
        local byCaster = assert(BfBot.Exec._BuildQueue({
            { caster = 0, spell = "BUFF", target = "self", rep = 3 },
        }, 0))
        local actions = {}
        EEex_Action_QueueResponseStringOnAIBase = function(action)
            actions[#actions + 1] = action
        end
        BfBot.Exec._ResolveCasterForStep = function() return sprites[1] end
        BfBot.Exec._DetectCombat = function() return false end
        BfBot.Exec._HasActiveEffect = function() return false end
        BfBot.Exec._NoteProgress = function() end
        BfBot.Exec._state = "running"
        BfBot.Exec._castCount = 0
        BfBot.Exec._skipCount = 0
        BfBot.Exec._activeCasters = 1
        BfBot.Exec._casters = { p0 = {
            ref = { kind = "party", slot = 0 },
            queue = byCaster.p0, index = 0, done = false,
            name = "A", cheatBoundary = 0, cheatApplied = false,
        } }
        BfBot.Exec._ProcessCasterEntry("p0", 1)
        BfBot.Exec._state = "stopped"
        BfBot.Exec._Advance("p0")
        local stoppedCastCount = BfBot.Exec._castCount
        local stoppedIndex = BfBot.Exec._casters.p0.index
        local stoppedActions = #actions

        -- A vanished summon between repeat attempts finishes only its chain.
        local completed = false
        BfBot.Exec._state = "running"
        BfBot.Exec._activeCasters = 1
        BfBot.Exec._casters = { s77 = {
            ref = { kind = "summon", oid = 77, name = "Skeleton" },
            queue = byCaster.p0, index = 1, done = false,
            name = "Skeleton", cheatBoundary = 0, cheatApplied = false,
        } }
        BfBot.Exec._ResolveCasterForStep = function() return nil end
        BfBot.Exec._Complete = function()
            completed = true
            BfBot.Exec._state = "done"
        end
        BfBot.Exec._Advance("s77")
        local summonDone = BfBot.Exec._casters.s77.done
        local activeAfterGone = BfBot.Exec._activeCasters

        -- The watchdog remains a whole-run safety net after expansion.
        local watchdogReason
        Infinity_GetClockTicks = function() return 3000 end
        BfBot.Exec._state = "running"
        BfBot.Exec._casters = { p0 = {
            ref = { kind = "party", slot = 0 }, queue = byCaster.p0,
            index = 1, done = false, name = "A", cheatBoundary = 0,
            cheatApplied = false,
        } }
        BfBot.Exec._activeCasters = 1
        BfBot.Exec._lastSafetyTick = 0
        BfBot.Exec._lastProgressGameTime = 0
        BfBot.Exec._IsStateStale = function() return false end
        BfBot.Exec._ProcessLateJoins = function() end
        BfBot.Exec._GetGameTime = function() return 1000 end
        BfBot.Exec._ForceComplete = function(reason)
            watchdogReason = reason
            BfBot.Exec._state = "done"
        end
        BfBot.Exec._SafetyTick()
        return {
            queueCount = #byCaster.p0,
            stoppedCastCount = stoppedCastCount,
            stoppedIndex = stoppedIndex,
            stoppedActions = stoppedActions,
            summonDone = summonDone,
            activeAfterGone = activeAfterGone,
            completed = completed,
            watchdogFired = type(watchdogReason) == "string"
                and watchdogReason:find("Watchdog", 1, true) ~= nil,
            watchdogState = BfBot.Exec._state,
        }
        """
    )

    assert facts["queueCount"] == 3
    assert facts["stoppedCastCount"] == 1
    assert facts["stoppedIndex"] == 1
    assert facts["stoppedActions"] == 2
    assert facts["summonDone"]
    assert facts["activeAfterGone"] == 0
    assert facts["completed"]
    assert facts["watchdogFired"]
    assert facts["watchdogState"] == "done"


def test_safety_tick_retries_pending_innate_refresh_after_execution(
    exec_lua: LuaRuntime,
) -> None:
    script = """
        local now = 3000
        local refreshAttempts = 0
        local warning = nil

        Infinity_GetClockTicks = function() return now end
        EEex_Sprite_GetInPortrait = function(_) return nil end
        BfBot.Exec._IsStateStale = function() return false end
        BfBot.Exec._ProcessLateJoins = function() end
        BfBot.Exec._GetGameTime = function() return nil end
        BfBot.Exec._state = "running"
        BfBot.Exec._casters = {}
        BfBot.Exec._lastSafetyTick = 0
        BfBot._innateRefreshPending = true
        BfBot._Warn = function(message) warning = message end
        BfBot.Innate.RefreshAll = function()
            refreshAttempts = refreshAttempts + 1
            if refreshAttempts == 1 then error("synthetic refresh failure") end
        end

        BfBot.Exec._SafetyTick()
        local attemptsWhileRunning = refreshAttempts
        local pendingWhileRunning = BfBot._innateRefreshPending == true

        BfBot.Exec._state = "done"
        now = 6000
        BfBot.Exec._SafetyTick()
        local pendingAfterFailure = BfBot._innateRefreshPending == true

        now = 9000
        BfBot.Exec._SafetyTick()
        return {
            refreshAttempts = refreshAttempts,
            attemptsWhileRunning = attemptsWhileRunning,
            pendingWhileRunning = pendingWhileRunning,
            pendingAfterFailure = pendingAfterFailure,
            pendingAfterSuccess = BfBot._innateRefreshPending == true,
            warning = warning or "",
        }
        """
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        facts = exec_lua.execute(script)
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert facts["refreshAttempts"] == 2
    assert facts["attemptsWhileRunning"] == 0
    assert facts["pendingWhileRunning"]
    assert facts["pendingAfterFailure"]
    assert not facts["pendingAfterSuccess"]
    assert "synthetic refresh failure" in facts["warning"]


def test_in_game_spell_picker_sort_phase(ui_test_lua: LuaRuntime) -> None:
    assert ui_test_lua.eval("BfBot.Test.SpellPickerSort()")


def test_safe_callback_preserves_interior_and_trailing_nil_returns(
    core_lua: LuaRuntime,
) -> None:
    facts = core_lua.execute(
        """
        local function pack(...)
            return { n = select("#", ...), ... }
        end
        local wrapped = BfBot._SafeCallback("test.success", function(value)
            return value, nil, "tail", nil
        end)
        local result = pack(wrapped(7))
        return {
            count = result.n,
            first = result[1],
            secondIsNil = result[2] == nil,
            third = result[3],
            fourthIsNil = result[4] == nil,
        }
        """
    )

    assert facts["count"] == 4
    assert facts["first"] == 7
    assert facts["secondIsNil"]
    assert facts["third"] == "tail"
    assert facts["fourthIsNil"]


def test_safe_callback_contains_reports_and_deduplicates_failures(
    core_lua: LuaRuntime,
) -> None:
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        facts = core_lua.execute(
            """
            local diagnostics = {}
            BfBot._Error = function(message)
                diagnostics[#diagnostics + 1] = message
            end
            BfBot._callbackErrors = {}
            local wrapped = BfBot._SafeCallback("test.failure", function()
                error("synthetic callback failure")
            end)
            local firstOk, firstResult = pcall(wrapped)
            local secondOk, secondResult = pcall(wrapped)
            return {
                firstContained = firstOk and firstResult == nil,
                secondContained = secondOk and secondResult == nil,
                diagnosticCount = #diagnostics,
                diagnostic = diagnostics[1],
            }
            """
        )
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert facts["firstContained"]
    assert facts["secondContained"]
    assert facts["diagnosticCount"] == 1
    assert "test.failure" in facts["diagnostic"]
    assert "synthetic callback failure" in facts["diagnostic"]


def test_safe_callback_contains_reporting_failures(core_lua: LuaRuntime) -> None:
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        contained = core_lua.execute(
            """
            BfBot._callbackErrors = {}
            BfBot._Error = function()
                error("synthetic reporting failure")
            end
            local wrapped = BfBot._SafeCallback("test.reporting", function()
                error("synthetic callback failure")
            end)
            local ok, result = pcall(wrapped)
            return ok and result == nil
            """
        )
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert contained


def test_safe_callback_contains_throwing_tostring_and_reports_fallback(
    core_lua: LuaRuntime,
) -> None:
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        facts = core_lua.execute(
            """
            local diagnostics = {}
            local label = setmetatable({}, {
                __tostring = function() error("label tostring failure") end,
            })
            local callbackError = setmetatable({}, {
                __tostring = function() error("error tostring failure") end,
            })
            BfBot._callbackErrors = {}
            BfBot._Error = function(message)
                diagnostics[#diagnostics + 1] = message
            end
            local wrapped = BfBot._SafeCallback(label, function()
                error(callbackError)
            end)
            local firstOk, firstResult = pcall(wrapped)
            local secondOk, secondResult = pcall(wrapped)
            return {
                firstContained = firstOk and firstResult == nil,
                secondContained = secondOk and secondResult == nil,
                diagnosticCount = #diagnostics,
                diagnostic = diagnostics[1],
            }
            """
        )
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert facts["firstContained"]
    assert facts["secondContained"]
    assert facts["diagnosticCount"] == 1
    assert "unprintable callback label" in facts["diagnostic"]
    assert "unprintable callback error" in facts["diagnostic"]


def _assert_registration_is_wrapped(
    source: str,
    registration: str,
    label: str,
) -> None:
    pattern = (
        rf"{re.escape(registration)}\s*\(\s*"
        rf"BfBot\._SafeCallback\s*\(\s*{re.escape(chr(34) + label + chr(34))}"
    )
    assert re.search(pattern, source), f"{registration} is not wrapped as {label}"


def test_main_callback_registrations_are_wrapped_after_core_load() -> None:
    core_load = MAIN_SOURCE.index('Infinity_DoFile("BfBotCor")')
    no_io_assignment = MAIN_SOURCE.index("BfBot._noIO = 1")
    no_io_notice = MAIN_SOURCE.index('"main.no_luajit_notice"')

    assert no_io_assignment < core_load < no_io_notice
    _assert_registration_is_wrapped(
        MAIN_SOURCE,
        "EEex_Menu_AddAfterMainFileLoadedListener",
        "main.no_luajit_notice",
    )
    _assert_registration_is_wrapped(
        MAIN_SOURCE,
        "EEex_Sprite_AddLoadedListener",
        "main.late_join",
    )
    assert re.search(
        r"EEex_Menu_AddAfterMainFileLoadedListener\s*\(\s*"
        r"BfBot\._SafeCallback\s*\(\s*\"main\.menu_loaded\"",
        MAIN_SOURCE,
    )


def test_innate_sprite_loaded_registration_is_wrapped_without_silent_pcall() -> None:
    _assert_registration_is_wrapped(
        INNATE_SOURCE,
        "EEex_Sprite_AddLoadedListener",
        "innate.sprite_loaded",
    )
    _assert_registration_is_wrapped(
        INNATE_SOURCE,
        "EEex_Sprite_AddQuickListsCheckedListener",
        "innate.quick_lists_checked",
    )
    assert "pcall(BfBot.Innate.Refresh" not in INNATE_SOURCE


@pytest.mark.parametrize(
    ("registration", "label"),
    [
        ("EEex_Key_AddPressedListener", "ui.key_pressed"),
        ("EEex_Sprite_AddQuickListsCheckedListener", "ui.quick_lists_checked"),
        (
            "EEex_Sprite_AddQuickListCountsResetListener",
            "ui.quick_list_counts_reset",
        ),
        (
            "EEex_Sprite_AddQuickListNotifyRemovedListener",
            "ui.quick_list_notify_removed",
        ),
        ("EEex_Menu_AddWindowSizeChangedListener", "ui.window_size_changed"),
    ],
)
def test_ui_listener_registration_is_wrapped(registration: str, label: str) -> None:
    _assert_registration_is_wrapped(UI_SOURCE, registration, label)


@pytest.mark.parametrize(
    ("reference", "label"),
    [
        ("reference_onOpen", "ui.world_actionbar_open"),
        ("reference_onClose", "ui.world_actionbar_close"),
    ],
)
def test_world_actionbar_item_function_is_wrapped(reference: str, label: str) -> None:
    assert re.search(
        rf"EEex_Menu_SetItemFunction\s*\(\s*actionbarMenu\.{reference}\s*,\s*"
        rf"BfBot\._SafeCallback\s*\(\s*{re.escape(chr(34) + label + chr(34))}",
        UI_SOURCE,
    )


def test_in_game_eeex_compatibility_phase_is_wired_into_run_all() -> None:
    assert "function BfBot.Test.EEexCompatibility()" in TEST_SOURCE
    assert re.search(
        r"local\s+eeexCompatOk\s*=\s*BfBot\.Test\.EEexCompatibility\(\)",
        TEST_SOURCE,
    )
    assert re.search(r"EEex Compatibility:.*eeexCompatOk", TEST_SOURCE)
    assert re.search(r"return .*and eeexCompatOk", TEST_SOURCE)


def test_marshal_safe_copy_converts_nested_boolean_values(lua: LuaRuntime) -> None:
    safe, dropped = lua.execute(
        """
        local source = {
            enabled = true,
            nested = { disabled = false, deeper = { active = true } },
        }
        return BfBot.Persist._MarshalSafeCopy(source)
        """
    )

    assert safe["enabled"] == 1
    assert safe["nested"]["disabled"] == 0
    assert safe["nested"]["deeper"]["active"] == 1
    assert dropped == 0


def test_marshal_safe_copy_preserves_scalars_arrays_and_mixed_keys(
    lua: LuaRuntime,
) -> None:
    safe, dropped = lua.execute(
        """
        local source = {
            [1] = "first",
            [2] = "second",
            [7] = "sparse",
            label = "preserved exactly",
            number = -123,
            nested = { [-2] = "negative", name = "mixed" },
        }
        return BfBot.Persist._MarshalSafeCopy(source)
        """
    )

    assert safe[1] == "first"
    assert safe[2] == "second"
    assert safe[7] == "sparse"
    assert safe["label"] == "preserved exactly"
    assert safe["number"] == -123
    assert safe["nested"][-2] == "negative"
    assert safe["nested"]["name"] == "mixed"
    assert dropped == 0


def test_marshal_safe_copy_preserves_v011_round_trip_safe_numeric_values(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local source = {
            ordinary = 42,
            schemaMinusOne = -1,
            u8Min = 0,
            u8Max = 255,
            u16Min = 256,
            u16Max = 65535,
            u32Min = 65536,
            u32Max = 4294967295,
            u64Min = 4294967296,
            u64LastRepresentable = (2 ^ 64) - 2048,
            i8Min = -128,
            i16Near = -257,
            i16Min = -32768,
            i32Near = -65537,
            i32Min = -(2 ^ 31),
            i64Near = -4294967297,
            i64Min = -(2 ^ 63),
        }
        local safe, dropped = BfBot.Persist._MarshalSafeCopy(source)
        local preserved = true
        local sourceCount, safeCount = 0, 0
        for key, value in pairs(source) do
            sourceCount = sourceCount + 1
            if safe[key] ~= value then preserved = false end
        end
        for _ in pairs(safe) do safeCount = safeCount + 1 end
        return {
            preserved = preserved,
            sameCount = safeCount == sourceCount,
            fresh = safe ~= source,
            dropped = dropped,
        }
        """
    )

    assert facts["preserved"]
    assert facts["sameCount"]
    assert facts["fresh"]
    assert facts["dropped"] == 0


def test_marshal_safe_copy_drops_v011_unsafe_numeric_values(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local source = {
            fraction = 1.5,
            negativeFraction = -1.5,
            nan = 0 / 0,
            positiveInfinity = math.huge,
            negativeInfinity = -math.huge,
            positiveOutside = 2 ^ 64,
            negativeOutside = -(2 ^ 63) - 2048,
            i8GapHigh = -129,
            i8GapLow = -256,
            i16GapHigh = -32769,
            i16GapLow = -65536,
            i32GapHigh = -2147483649,
            i32GapLow = -4294967296,
            keep = 7,
        }
        local safe, dropped = BfBot.Persist._MarshalSafeCopy(source)
        return {
            unsafeDropped = safe.fraction == nil
                and safe.negativeFraction == nil
                and safe.nan == nil
                and safe.positiveInfinity == nil
                and safe.negativeInfinity == nil
                and safe.positiveOutside == nil
                and safe.negativeOutside == nil
                and safe.i8GapHigh == nil and safe.i8GapLow == nil
                and safe.i16GapHigh == nil and safe.i16GapLow == nil
                and safe.i32GapHigh == nil and safe.i32GapLow == nil,
            safePreserved = safe.keep == 7,
            sourceUnchanged = source.fraction == 1.5
                and source.negativeFraction == -1.5
                and source.nan ~= source.nan
                and source.positiveInfinity == math.huge
                and source.negativeInfinity == -math.huge
                and source.keep == 7,
            dropped = dropped,
        }
        """
    )

    assert facts["unsafeDropped"]
    assert facts["safePreserved"]
    assert facts["sourceUnchanged"]
    assert facts["dropped"] == 13


def test_marshal_safe_copy_filters_numeric_keys_by_v011_round_trip_safety(
    lua: LuaRuntime,
) -> None:
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        facts = lua.execute(
            """
            local source = {}
            local entries = {
                { 0, "zero" },
                { 255, "u8 max" },
                { 256, "u16 min" },
                { 65535, "u16 max" },
                { 65536, "u32 min" },
                { 4294967295, "u32 max" },
                { 4294967296, "u64 min" },
                { (2 ^ 64) - 2048, "u64 last representable" },
                { -1, "schema minus one" },
                { -128, "i8 min" },
                { -257, "i16 near" },
                { -32768, "i16 min" },
                { -65537, "i32 near" },
                { -(2 ^ 31), "i32 min" },
                { -4294967297, "i64 near" },
                { -(2 ^ 63), "i64 min" },
                { 1.5, "fraction" },
                { -1.5, "negative fraction" },
                { 0 / 0, "nan" },
                { math.huge, "positive infinity" },
                { -math.huge, "negative infinity" },
                { 2 ^ 64, "positive outside" },
                { -(2 ^ 63) - 2048, "negative outside" },
                { -129, "i8 gap high" },
                { -256, "i8 gap low" },
                { -32769, "i16 gap high" },
                { -65536, "i16 gap low" },
                { -2147483649, "i32 gap high" },
                { -4294967296, "i32 gap low" },
            }
            local originalPairs = pairs
            pairs = function(tbl)
                if tbl ~= source then return originalPairs(tbl) end
                local index = 0
                return function()
                    index = index + 1
                    local entry = entries[index]
                    if entry then return entry[1], entry[2] end
                end
            end
            local copyOk, safe, dropped = pcall(
                BfBot.Persist._MarshalSafeCopy, source)
            pairs = originalPairs
            if not copyOk then
                return { completed = false, error = tostring(safe) }
            end

            local copied = 0
            for _ in originalPairs(safe) do copied = copied + 1 end
            return {
                completed = true,
                validBoundaries = safe[0] == "zero"
                    and safe[255] == "u8 max"
                    and safe[256] == "u16 min"
                    and safe[65535] == "u16 max"
                    and safe[65536] == "u32 min"
                    and safe[4294967295] == "u32 max"
                    and safe[4294967296] == "u64 min"
                    and safe[(2 ^ 64) - 2048] == "u64 last representable"
                    and safe[-1] == "schema minus one"
                    and safe[-128] == "i8 min"
                    and safe[-257] == "i16 near"
                    and safe[-32768] == "i16 min"
                    and safe[-65537] == "i32 near"
                    and safe[-(2 ^ 31)] == "i32 min"
                    and safe[-4294967297] == "i64 near"
                    and safe[-(2 ^ 63)] == "i64 min",
                copied = copied,
                dropped = dropped,
            }
            """
        )
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert facts["completed"], facts["error"]
    assert facts["validBoundaries"]
    assert facts["copied"] == 16
    assert facts["dropped"] == 13


def test_marshal_safe_copy_drops_unsupported_keys_without_key_collisions(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local tableKey = {}
        local functionKey = function() end
        local threadKey = coroutine.create(function() end)
        local source = { [1] = "numeric one", [true] = "boolean true", keep = "ok" }
        source[tableKey] = "table key"
        source[functionKey] = "function key"
        source[threadKey] = "thread key"
        source[python_userdata] = "userdata key"

        local safe, dropped = BfBot.Persist._MarshalSafeCopy(source)
        return {
            numericPreserved = safe[1] == "numeric one",
            booleanDropped = safe[true] == nil,
            tableDropped = safe[tableKey] == nil,
            functionDropped = safe[functionKey] == nil,
            threadDropped = safe[threadKey] == nil,
            userdataDropped = safe[python_userdata] == nil,
            ordinaryPreserved = safe.keep == "ok",
            sourceUnchanged = source[1] == "numeric one"
                and source[true] == "boolean true"
                and source[tableKey] == "table key"
                and source[functionKey] == "function key"
                and source[threadKey] == "thread key"
                and source[python_userdata] == "userdata key",
            dropped = dropped,
        }
        """
    )

    assert facts["numericPreserved"]
    assert facts["booleanDropped"]
    assert facts["tableDropped"]
    assert facts["functionDropped"]
    assert facts["threadDropped"]
    assert facts["userdataDropped"]
    assert facts["ordinaryPreserved"]
    assert facts["sourceUnchanged"]
    assert facts["dropped"] == 5


def test_marshal_safe_copy_drops_unsupported_values_and_cycles(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local fn = function() return "still live" end
        local thread = coroutine.create(function() end)
        local cycle = { keep = "inside cycle" }
        cycle.back = cycle
        local source = {
            fn = fn,
            userdata = python_userdata,
            thread = thread,
            cycle = cycle,
            keep = "safe",
        }

        local safe, dropped = BfBot.Persist._MarshalSafeCopy(source)
        return {
            functionDropped = safe.fn == nil,
            userdataDropped = safe.userdata == nil,
            threadDropped = safe.thread == nil,
            cycleLinkDropped = type(safe.cycle) == "table"
                and safe.cycle.keep == "inside cycle"
                and safe.cycle.back == nil,
            safeScalarPreserved = safe.keep == "safe",
            sourceUnchanged = source.fn == fn
                and source.userdata == python_userdata
                and source.thread == thread
                and source.cycle == cycle
                and cycle.back == cycle,
            dropped = dropped,
        }
        """
    )

    assert facts["functionDropped"]
    assert facts["userdataDropped"]
    assert facts["threadDropped"]
    assert facts["cycleLinkDropped"]
    assert facts["safeScalarPreserved"]
    assert facts["sourceUnchanged"]
    assert facts["dropped"] == 4


def test_marshal_safe_copy_copies_shared_acyclic_children_per_path(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local child = { flag = true, label = "shared" }
        local source = { left = child, right = child }
        local safe, dropped = BfBot.Persist._MarshalSafeCopy(source)
        return {
            leftCopied = safe.left ~= child
                and safe.left.flag == 1 and safe.left.label == "shared",
            rightCopied = safe.right ~= child
                and safe.right.flag == 1 and safe.right.label == "shared",
            branchesIndependent = safe.left ~= safe.right,
            sourceStillShared = source.left == child and source.right == child
                and child.flag == true and type(child.flag) == "boolean",
            dropped = dropped,
        }
        """
    )

    assert facts["leftCopied"]
    assert facts["rightCopied"]
    assert facts["branchesIndependent"]
    assert facts["sourceStillShared"]
    assert facts["dropped"] == 0


def test_marshal_safe_copy_leaves_the_deep_source_unchanged(lua: LuaRuntime) -> None:
    facts = lua.execute(
        """
        local fn = function() return 17 end
        local thread = coroutine.create(function() end)
        local shared = { yes = true, no = false }
        local source = {
            bool = true,
            nested = { value = false, text = "same", number = 42 },
            left = shared,
            right = shared,
            fn = fn,
            userdata = python_userdata,
            thread = thread,
        }
        source.self = source

        local safe = BfBot.Persist._MarshalSafeCopy(source)
        return {
            freshRoot = safe ~= source and safe.nested ~= source.nested,
            booleansUnchanged = source.bool == true
                and source.nested.value == false
                and shared.yes == true and shared.no == false,
            scalarsUnchanged = source.nested.text == "same"
                and source.nested.number == 42,
            referencesUnchanged = source.left == shared and source.right == shared
                and source.fn == fn and source.userdata == python_userdata
                and source.thread == thread and source.self == source,
        }
        """
    )

    assert facts["freshRoot"]
    assert facts["booleansUnchanged"]
    assert facts["scalarsUnchanged"]
    assert facts["referencesUnchanged"]


def test_export_returns_safe_copy_warns_once_and_preserves_live_udaux(
    lua: LuaRuntime,
) -> None:
    facts = lua.execute(
        """
        local warnings = {}
        BfBot._Warn = function(message) warnings[#warnings + 1] = message end
        local fn = function() return "live" end
        local live = { nested = { enabled = true }, bad = fn }
        live.self = live
        local aux = { BB = live }
        EEex = { IsMarshallingCopy = function() return false end }
        EEex_GetUDAux = function(sprite)
            assert(sprite == "sprite")
            return aux
        end

        local exported = BfBot.Persist._Export("sprite")
        return {
            fresh = type(exported.cfg) == "table" and exported.cfg ~= live
                and exported.cfg.nested ~= live.nested,
            safe = exported.cfg.nested.enabled == 1
                and exported.cfg.bad == nil and exported.cfg.self == nil,
            liveUnchanged = aux.BB == live and live.nested.enabled == true
                and type(live.nested.enabled) == "boolean"
                and live.bad == fn and live.self == live,
            warningCount = #warnings,
            warning = warnings[1],
        }
        """
    )

    assert facts["fresh"]
    assert facts["safe"]
    assert facts["liveUnchanged"]
    assert facts["warningCount"] == 1
    assert "Persist" in facts["warning"]
    assert "marshal" in facts["warning"].lower()


def test_export_keeps_temporary_marshalling_copies_empty(lua: LuaRuntime) -> None:
    facts = lua.execute(
        """
        EEex = { IsMarshallingCopy = function() return true end }
        local udauxReads = 0
        EEex_GetUDAux = function()
            udauxReads = udauxReads + 1
            return { BB = { value = 7 } }
        end
        local copyResult = BfBot.Persist._Export("sprite")
        return {
            empty = type(copyResult) == "table"
                and next(copyResult) == nil,
            udauxReads = udauxReads,
        }
        """
    )

    assert facts["empty"]
    assert facts["udauxReads"] == 0


def test_export_contains_udaux_errors_and_returns_empty(lua: LuaRuntime) -> None:
    # LuaJIT implements caught Lua errors with Windows SEH. Python's fault
    # handler otherwise prints a misleading fatal-exception stack even though
    # both Lua pcalls succeed, so suppress it only around this intentional fault.
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        facts = lua.execute(
            """
            local warnings = {}
            BfBot._Warn = function(message)
                warnings[#warnings + 1] = message
            end
            EEex = { IsMarshallingCopy = function() return false end }
            EEex_GetUDAux = function() error("synthetic UDAux failure") end
            local exportOk, exported = pcall(BfBot.Persist._Export, "sprite")

            BfBot._Warn = function() error("synthetic warning failure") end
            local warningOk, warningResult = pcall(
                BfBot.Persist._Export, "sprite")
            return {
                contained = exportOk,
                empty = type(exported) == "table" and next(exported) == nil,
                warningCount = #warnings,
                warning = warnings[1],
                warningFailureContained = warningOk
                    and type(warningResult) == "table"
                    and next(warningResult) == nil,
            }
            """
        )
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert facts["contained"]
    assert facts["empty"]
    assert facts["warningCount"] == 1
    assert "synthetic UDAux failure" in facts["warning"]
    assert facts["warningFailureContained"]


def test_export_contains_error_objects_whose_tostring_throws(
    lua: LuaRuntime,
) -> None:
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        facts = lua.execute(
            """
            local errorObject = setmetatable({}, {
                __tostring = function()
                    error("synthetic tostring failure")
                end,
            })
            EEex = { IsMarshallingCopy = function() return false end }
            EEex_GetUDAux = function() error(errorObject) end

            local exportOk, exported = pcall(
                BfBot.Persist._Export, "sprite")
            return {
                contained = exportOk,
                empty = exportOk and type(exported) == "table"
                    and next(exported) == nil,
            }
            """
        )
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert facts["contained"]
    assert facts["empty"]
