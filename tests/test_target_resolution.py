from __future__ import annotations

from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CORE_SOURCE = (ROOT / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")


@pytest.fixture
def target_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute(CORE_SOURCE)
    runtime.execute(
        """
        BfBot.Scan = {}
        BfBot.Class = {}
        BfBot.Innate = {}
        BfBot.Mp = {}
        """
    )
    runtime.execute(PERSIST_SOURCE)
    return runtime


def test_death_variable_helper_handles_wrapped_and_direct_values(
    target_lua: LuaRuntime,
) -> None:
    facts = target_lua.execute(
        """
        local wrapped = {
            m_scriptName = { get = function() return "ANOMEN" end },
        }
        local direct = { m_scriptName = "DIRECT_DV" }
        local malformed = {
            m_scriptName = { get = function() return 42 end },
        }
        return {
            wrapped = BfBot._GetDeathVar(wrapped),
            direct = BfBot._GetDeathVar(direct),
            malformed = BfBot._GetDeathVar(malformed),
            absent = BfBot._GetDeathVar(nil),
        }
        """
    )

    assert facts["wrapped"] == "ANOMEN"
    assert facts["direct"] == "DIRECT_DV"
    assert facts["malformed"] == ""
    assert facts["absent"] == ""


def test_name_resolution_prefers_exact_display_name_then_falls_back_to_dv(
    target_lua: LuaRuntime,
) -> None:
    facts = target_lua.execute(
        """
        local function sprite(name, deathVar)
            return {
                name = name,
                getName = function(self) return self.name end,
                m_scriptName = { get = function() return deathVar end },
            }
        end
        local party = {
            [0] = sprite("Hero", "None"),
            [1] = sprite("Sir Anomen", "ANOMEN"),
            [2] = sprite("Anomen", "OTHER_DV"),
        }
        EEex_Sprite_GetInPortrait = function(slot) return party[slot] end

        local exact = BfBot.Persist._ResolveNameToSlot("Anomen")
        party[2].name = "Other"
        local dvUpper = BfBot.Persist._ResolveNameToSlot("ANOMEN")
        local dvLower = BfBot.Persist._ResolveNameToSlot("anomen")
        return {
            exact = exact,
            dvUpper = dvUpper,
            dvLower = dvLower,
            noneIgnored = BfBot.Persist._ResolveNameToSlot("none") == nil,
            missing = BfBot.Persist._ResolveNameToSlot("Missing") == nil,
        }
        """
    )

    assert facts["exact"] == 2
    assert facts["dvUpper"] == 1
    assert facts["dvLower"] == 1
    assert facts["noneIgnored"]
    assert facts["missing"]


def test_config_target_never_turns_an_unknown_name_into_party_wide_cast(
    target_lua: LuaRuntime,
) -> None:
    facts = target_lua.execute(
        """
        local party = {
            [0] = {
                getName = function() return "Hero" end,
                m_scriptName = { get = function() return "None" end },
            },
            [1] = {
                getName = function() return "Sir Anomen" end,
                m_scriptName = { get = function() return "ANOMEN" end },
            },
            [2] = {
                getName = function() return "Jaheira" end,
                m_scriptName = { get = function() return "JAHEIRA" end },
            },
        }
        EEex_Sprite_GetInPortrait = function(slot) return party[slot] end

        local partyUnknown = BfBot.Persist._ResolveConfigTarget(
            "Missing", 0, "WARD", 10)
        local summonRef = { kind = "summon", oid = 77, name = "Planetar" }
        local summonUnknown = BfBot.Persist._ResolveConfigTarget(
            "Missing", summonRef, "WARD", 10)
        local partyResolved = BfBot.Persist._ResolveConfigTarget(
            "anomen", 4, "WARD", 10)
        local mixed = BfBot.Persist._ResolveConfigTarget(
            { "Missing", "anomen", "Jaheira" }, summonRef, "WARD", 10)

        return {
            partyUnknown = #partyUnknown,
            summonUnknown = #summonUnknown,
            partyResolvedCount = #partyResolved,
            partyResolvedTarget = partyResolved[1] and partyResolved[1].target,
            partyShape = partyResolved[1] and partyResolved[1].caster == 4
                and partyResolved[1].casterRef == nil,
            mixedCount = #mixed,
            mixedFirstTarget = mixed[1] and mixed[1].target,
            mixedSecondTarget = mixed[2] and mixed[2].target,
            mixedFirstPriority = mixed[1] and mixed[1].pri,
            mixedSecondPriority = mixed[2] and mixed[2].pri,
            summonShape = mixed[1] and mixed[1].caster == nil
                and mixed[1].casterRef == summonRef,
        }
        """
    )

    assert facts["partyUnknown"] == 0
    assert facts["summonUnknown"] == 0
    assert facts["partyResolvedCount"] == 1
    assert facts["partyResolvedTarget"] == 2
    assert facts["partyShape"]
    assert facts["mixedCount"] == 2
    assert facts["mixedFirstTarget"] == 2
    assert facts["mixedSecondTarget"] == 3
    assert facts["mixedFirstPriority"] == pytest.approx(10.002)
    assert facts["mixedSecondPriority"] == pytest.approx(10.003)
    assert facts["summonShape"]


def test_character_builder_surfaces_fully_unresolved_targets_as_a_build_skip(
    target_lua: LuaRuntime,
) -> None:
    facts = target_lua.execute(
        """
        local caster = {
            m_id = 41,
            getName = function() return "Caster" end,
            m_scriptName = { get = function() return "CASTER_DV" end },
        }
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return caster end
            return nil
        end
        local config = BfBot.Persist.GetDefaultConfig()
        config.presets[1].spells = {
            WARD = { on = 1, tgt = "Departed NPC", pri = 1, rep = 4 },
        }
        BfBot.Persist.GetConfig = function(sprite)
            assert(sprite == caster)
            return config
        end
        BfBot.Scan.Invalidate = function(sprite) assert(sprite == caster) end
        BfBot.Scan.GetCastableSpells = function(sprite)
            assert(sprite == caster)
            return {
                WARD = {
                    count = 1,
                    name = "Protective Ward",
                    durCat = "long",
                    kind = "spl",
                },
            }
        end

        local logged = {}
        BfBot.Exec = {
            _logFile = "unused.log",
            _LogEntry = function(kind, msg)
                logged[#logged + 1] = kind .. ":" .. msg
            end,
        }
        BfBot._OpenLogAppend = function() BfBot._logHandle = {} end
        BfBot._CloseLog = function() BfBot._logHandle = nil end
        BfBot.Persist.DrainBuildSkips()

        local queue, reason, detail =
            BfBot.Persist.BuildQueueForCharacter(0, 1)
        local skips = BfBot.Persist.DrainBuildSkips()
        return {
            queueMissing = queue == nil,
            reason = reason,
            reasonPreset = detail and detail.preset,
            reasonSlot = detail and detail.slot,
            skipCount = #skips,
            skip = skips[1],
            logged = logged[1],
        }
        """
    )

    assert facts["queueMissing"]
    assert facts["reason"] == "reason.queue.no_castable_spells_for_slot"
    assert facts["reasonPreset"] == 1
    assert facts["reasonSlot"] == 0
    assert facts["skipCount"] == 1
    assert "Caster" in facts["skip"]
    assert "Protective Ward" in facts["skip"]
    assert "no configured targets" in facts["skip"]
    assert facts["logged"].startswith("SKIP:")


def test_character_builder_keeps_valid_spell_when_another_has_no_targets(
    target_lua: LuaRuntime,
) -> None:
    facts = target_lua.execute(
        """
        local caster = {
            m_id = 41,
            getName = function() return "Caster" end,
            m_scriptName = { get = function() return "CASTER_DV" end },
        }
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return caster end
            return nil
        end
        local config = BfBot.Persist.GetDefaultConfig()
        config.presets[1].spells = {
            GOOD = { on = 1, tgt = "s", pri = 1, rep = 5 },
            BAD = { on = 1, tgt = "Departed NPC", pri = 2, rep = 3 },
        }
        BfBot.Persist.GetConfig = function() return config end
        BfBot.Persist._CollectLiveCloneDescriptors = function() return {} end
        BfBot.Scan.Invalidate = function() end
        BfBot.Scan.GetCastableSpells = function()
            return {
                GOOD = {
                    count = 1, name = "Good Ward", durCat = "long",
                    kind = "itm", leafResrefs = { "GOODLEAF" },
                },
                BAD = { count = 1, name = "Bad Ward", durCat = "short" },
            }
        end
        BfBot.Exec = {
            _logFile = "unused.log",
            _LogEntry = function() end,
        }
        BfBot._OpenLogAppend = function() BfBot._logHandle = {} end
        BfBot._CloseLog = function() BfBot._logHandle = nil end
        BfBot.Persist.DrainBuildSkips()

        local queue = assert(BfBot.Persist.BuildQueueForCharacter(0, 1))
        local skips = BfBot.Persist.DrainBuildSkips()
        return {
            count = #queue,
            caster = queue[1].caster,
            noCasterRef = queue[1].casterRef == nil,
            target = queue[1].target,
            kind = queue[1].kind,
            leaf = queue[1].leafResrefs and queue[1].leafResrefs[1],
            repeatCount = queue[1].rep,
            skipCount = #skips,
            skip = skips[1],
        }
        """
    )

    assert facts["count"] == 1
    assert facts["caster"] == 0
    assert facts["noCasterRef"]
    assert facts["target"] == "self"
    assert facts["kind"] == "itm"
    assert facts["leaf"] == "GOODLEAF"
    assert facts["repeatCount"] == 5
    assert facts["skipCount"] == 1
    assert "Bad Ward" in facts["skip"]


def test_cast_all_builder_surfaces_unresolved_targets_without_queueing_them(
    target_lua: LuaRuntime,
) -> None:
    facts = target_lua.execute(
        """
        local caster = {
            m_id = 41,
            getName = function() return "Caster" end,
            m_scriptName = { get = function() return "CASTER_DV" end },
        }
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return caster end
            return nil
        end
        local config = BfBot.Persist.GetDefaultConfig()
        config.presets[1].spells = {
            WARD = { on = 1, tgt = { "Gone One", "Gone Two" }, pri = 1 },
        }
        BfBot.Persist.GetConfig = function(sprite)
            assert(sprite == caster)
            return config
        end
        BfBot.Persist.GetPref = function(key)
            if key == "SummonsJoinCast" then return 0 end
            return BfBot.Persist._INI_DEFAULTS[key]
        end
        BfBot.Persist._CollectLiveCloneDescriptors = function() return {} end
        BfBot.Scan.Invalidate = function(sprite) assert(sprite == caster) end
        BfBot.Scan.GetCastableSpells = function(sprite)
            assert(sprite == caster)
            return {
                WARD = { count = 1, name = "Protective Ward", kind = "spl" },
            }
        end

        BfBot.Exec = {
            _logFile = "unused.log",
            _LogEntry = function() end,
        }
        BfBot._OpenLogAppend = function() BfBot._logHandle = {} end
        BfBot._CloseLog = function() BfBot._logHandle = nil end
        BfBot.Persist.DrainBuildSkips()

        local queue, reason, detail = BfBot.Persist.BuildQueueFromPreset(1)
        local skips = BfBot.Persist.DrainBuildSkips()
        return {
            queueMissing = queue == nil,
            reason = reason,
            reasonIndex = detail and detail.index,
            skipCount = #skips,
            skip = skips[1],
        }
        """
    )

    assert facts["queueMissing"]
    assert facts["reason"] == "reason.queue.no_castable_preset_spells"
    assert facts["reasonIndex"] == 1
    assert facts["skipCount"] == 1
    assert "Caster" in facts["skip"]
    assert "Protective Ward" in facts["skip"]


def test_summon_builder_keeps_valid_target_shape_and_skips_unknown_only_spell(
    target_lua: LuaRuntime,
) -> None:
    facts = target_lua.execute(
        """
        local party = {
            [0] = {
                getName = function() return "Hero" end,
                m_scriptName = { get = function() return "None" end },
            },
            [1] = {
                getName = function() return "Sir Anomen" end,
                m_scriptName = { get = function() return "ANOMEN" end },
            },
        }
        EEex_Sprite_GetInPortrait = function(slot) return party[slot] end
        local summon = {
            m_id = 77,
            getName = function() return "Planetar" end,
            m_scriptName = { get = function() return "PLANGOOD" end },
        }
        local preset = { qc = 0, spells = {
            GOOD = { on = 1, tgt = "anomen", pri = 1, rep = 5 },
            BAD = { on = 1, tgt = "Departed NPC", pri = 2, rep = 3 },
        } }
        BfBot.Persist.PeekSummonPreset = function(identity, presetIdx)
            assert(identity == "summon:test" and presetIdx == 1)
            return preset
        end
        BfBot.Scan.Invalidate = function(sprite) assert(sprite == summon) end
        BfBot.Scan.GetCastableSpells = function(sprite)
            assert(sprite == summon)
            return {
                GOOD = { count = 1, name = "Good Ward", durCat = "long" },
                BAD = { count = 1, name = "Bad Ward", durCat = "short" },
            }
        end
        local logged = {}
        BfBot.Exec = {
            _logFile = "unused.log",
            _ResolveCaster = function(ref)
                assert(ref.kind == "summon" and ref.oid == 77)
                return summon
            end,
            _LogEntry = function(kind, msg)
                logged[#logged + 1] = kind .. ":" .. msg
            end,
        }
        BfBot._OpenLogAppend = function() BfBot._logHandle = {} end
        BfBot._CloseLog = function() BfBot._logHandle = nil end
        BfBot.Persist.DrainBuildSkips()

        local queue = assert(BfBot.Persist.BuildQueueForSummon({
            identity = "summon:test", oid = 77, name = "Planetar",
        }, 1))
        local skips = BfBot.Persist.DrainBuildSkips()
        return {
            count = #queue,
            target = queue[1].target,
            casterRef = queue[1].casterRef,
            repeatCount = queue[1].rep,
            skipCount = #skips,
            skip = skips[1],
        }
        """
    )

    assert facts["count"] == 1
    assert facts["target"] == 2
    assert facts["casterRef"]["kind"] == "summon"
    assert facts["casterRef"]["oid"] == 77
    assert facts["repeatCount"] == 5
    assert facts["skipCount"] == 1
    assert "Planetar" in facts["skip"]
    assert "Bad Ward" in facts["skip"]
