from __future__ import annotations

import faulthandler
from pathlib import Path
import sys

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CORE_SOURCE = (ROOT / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")
INNATE_SOURCE = (ROOT / "buffbot/BfBotInn.lua").read_text(encoding="utf-8")
TEST_SOURCE = (ROOT / "buffbot/BfBotTst.lua").read_text(encoding="utf-8")


@pytest.fixture
def innate_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        io = nil
        BfBot = {
            MAX_PRESETS = 8,
            Innate = {},
            _Warn = function(_) end,
        }
        """
    )
    runtime.execute(INNATE_SOURCE)
    return runtime


@pytest.mark.parametrize(
    ("slot", "preset"),
    [(slot, preset) for slot in range(6) for preset in range(1, 9)],
)
def test_generated_preset_innate_has_only_the_dispatch_effect(
    innate_lua: LuaRuntime,
    slot: int,
    preset: int,
) -> None:
    facts = innate_lua.execute(
        f"""
        local data = BfBot.Innate._BuildSPL({slot}, {preset})

        local function u16(offset)
            local b1, b2 = string.byte(data, offset + 1, offset + 2)
            return b1 + b2 * 256
        end

        local function u32(offset)
            local b1, b2, b3, b4 = string.byte(data, offset + 1, offset + 4)
            return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        end

        local featureOffset = u32(0x6A)
        local resource = data:sub(featureOffset + 0x14 + 1, featureOffset + 0x1B + 1)
            :gsub("%z+$", "")

        return {{
            size = #data,
            signature = data:sub(1, 8),
            completionSoundIsBlank = data:sub(0x10 + 1, 0x17 + 1)
                == string.rep("\0", 8),
            spellLevel = u32(0x34),
            abilityCount = u16(0x68),
            featureOffset = featureOffset,
            requiredLevel = u16(0x72 + 0x10),
            timesPerDay = u16(0x72 + 0x14),
            featureCount = u16(0x72 + 0x1E),
            opcode = u16(featureOffset),
            effectSlot = u32(featureOffset + 0x04),
            effectPreset = u32(featureOffset + 0x08),
            resource = resource,
        }}
        """
    )

    assert facts["size"] == 202
    assert facts["signature"] == "SPL V1  "
    assert facts["completionSoundIsBlank"]
    assert facts["spellLevel"] == preset
    assert facts["abilityCount"] == 1
    assert facts["featureOffset"] == 154
    assert facts["requiredLevel"] == preset
    assert facts["timesPerDay"] == 1
    assert facts["featureCount"] == 1
    assert facts["opcode"] == 402
    assert facts["effectSlot"] == slot
    assert facts["effectPreset"] == preset
    assert facts["resource"] == "BFBOTGO"


def test_reconciliation_remover_keeps_all_48_opcode_172_effects(
    innate_lua: LuaRuntime,
) -> None:
    script = """
        local data = BfBot.Innate._BuildRemoverSPL()

        local function u16(offset)
            local b1, b2 = string.byte(data, offset + 1, offset + 2)
            return b1 + b2 * 256
        end

        local function u32(offset)
            local b1, b2, b3, b4 = string.byte(data, offset + 1, offset + 4)
            return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        end

        local featureOffset = u32(0x6A)
        local featureCount = u16(0x72 + 0x1E)
        local allRemoveInnate = true
        local resources = {}
        for i = 0, featureCount - 1 do
            local offset = featureOffset + i * 48
            allRemoveInnate = allRemoveInnate and u16(offset) == 172
            resources[#resources + 1] = data
                :sub(offset + 0x14 + 1, offset + 0x1B + 1)
                :gsub("%z+$", "")
        end

        return {
            size = #data,
            featureOffset = featureOffset,
            featureCount = featureCount,
            allRemoveInnate = allRemoveInnate,
            firstResource = resources[1],
            lastResource = resources[#resources],
        }
        """
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        facts = innate_lua.execute(script)
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert facts["size"] == 2458
    assert facts["featureOffset"] == 154
    assert facts["featureCount"] == 48
    assert facts["allRemoveInnate"]
    assert facts["firstResource"] == "BFBT01"
    assert facts["lastResource"] == "BFBT58"


def test_in_game_innate_diagnostic_reports_recharge_storage_details() -> None:
    diagnostic = TEST_SOURCE.split(
        "function BfBot.Test.Innate()", maxsplit=1
    )[1].split(
        "function BfBot.Test.QuickCast()", maxsplit=1
    )[0]

    assert "Known:" in diagnostic
    assert "Memorized container 0:" in diagnostic
    assert "available" in diagnostic
    assert "Raw flags:" in diagnostic
    assert "m_memorizedSpellsInnate:getReference(0)" in diagnostic
    assert "mem.m_spellId:get()" in diagnostic
    assert "mem.m_flags" in diagnostic


def test_quick_lists_recharge_uses_the_single_innate_container_and_preserves_flags(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        if type(BfBot.Innate._OnQuickListsChecked) ~= "function" then
            return { implemented = false }
        end

        local requestedContainers = {}
        local mpCalls = 0
        local entry = {
            m_spellId = { get = function() return "BFBT01" end },
            m_flags = 4,
        }
        local list = { entry }
        local sprite = {
            portraitIndex = 0,
            m_memorizedSpellsInnate = {
                getReference = function(_, index)
                    requestedContainers[#requestedContainers + 1] = index
                    return list
                end,
            },
        }

        EEex_Sprite_GetPortraitIndex = function(value)
            return value.portraitIndex
        end
        EEex_Utility_IterateCPtrList = function(values, callback)
            for _, value in ipairs(values) do
                if callback(value) then break end
            end
        end
        EEex_IsBitUnset = function(value, bitIndex)
            return bit.band(value, bit.lshift(1, bitIndex)) == 0
        end
        EEex_SetBit = function(value, bitIndex)
            return bit.bor(value, bit.lshift(1, bitIndex))
        end
        BfBot.Mp = {
            IsLocallyControlled = function()
                mpCalls = mpCalls + 1
                return false
            end,
        }

        BfBot.Innate._OnQuickListsChecked(sprite, "BFBT01", -1)
        local firstFlags = entry.m_flags
        BfBot.Innate._OnQuickListsChecked(sprite, "BFBT01", -1)
        local repeatedFlags = entry.m_flags

        entry.m_spellId.get = function() return "BFBT08" end
        entry.m_flags = 2
        BfBot.Innate._OnQuickListsChecked(sprite, "BFBT08", -1)

        local everyContainerIsZero = #requestedContainers == 3
        for _, index in ipairs(requestedContainers) do
            everyContainerIsZero = everyContainerIsZero and index == 0
        end

        return {
            implemented = true,
            firstFlags = firstFlags,
            repeatedFlags = repeatedFlags,
            presetEightFlags = entry.m_flags,
            everyContainerIsZero = everyContainerIsZero,
            mpCalls = mpCalls,
        }
        """
    )

    assert facts["implemented"]
    assert facts["firstFlags"] == 5
    assert facts["repeatedFlags"] == 5
    assert facts["presetEightFlags"] == 3
    assert facts["everyContainerIsZero"]
    assert facts["mpCalls"] == 0


def test_recharge_skips_available_duplicates_and_restores_only_one_spent_entry(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        local function entry(flags)
            return {
                m_spellId = { get = function() return "BFBT01" end },
                m_flags = flags,
            }
        end

        local entries = { entry(5), entry(4), entry(2) }
        local requestedContainer = nil
        local sprite = {
            m_memorizedSpellsInnate = {
                getReference = function(_, index)
                    requestedContainer = index
                    return entries
                end,
            },
        }

        EEex_Utility_IterateCPtrList = function(values, callback)
            for _, value in ipairs(values) do
                if callback(value) then break end
            end
        end
        EEex_IsBitUnset = function(value, bitIndex)
            return bit.band(value, bit.lshift(1, bitIndex)) == 0
        end
        EEex_SetBit = function(value, bitIndex)
            return bit.bor(value, bit.lshift(1, bitIndex))
        end

        local restored, status = BfBot.Innate._RestoreSpent(sprite, "BFBT01")
        return {
            restored = restored,
            status = status,
            requestedContainer = requestedContainer,
            firstFlags = entries[1].m_flags,
            secondFlags = entries[2].m_flags,
            thirdFlags = entries[3].m_flags,
        }
        """
    )

    assert facts["restored"]
    assert facts["status"] == "restored"
    assert facts["requestedContainer"] == 0
    assert facts["firstFlags"] == 5
    assert facts["secondFlags"] == 5
    assert facts["thirdFlags"] == 2


def test_recharge_reports_missing_innate_storage_without_throwing(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        EEex_Sprite_GetPortraitIndex = function(_) return 0 end
        local ok, restored, status = pcall(
            BfBot.Innate._OnQuickListsChecked,
            {},
            "BFBT01",
            -1
        )
        return { ok = ok, restored = restored, status = status }
        """
    )

    assert facts["ok"]
    assert not facts["restored"]
    assert facts["status"] == "missing_container"


def test_recharge_deduplicates_missing_entry_diagnostics(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        local warnings = {}
        BfBot._Warn = function(message)
            warnings[#warnings + 1] = message
        end
        EEex_Sprite_GetPortraitIndex = function(_) return 0 end
        EEex_Utility_IterateCPtrList = function(_, _) end

        local sprite = {
            m_memorizedSpellsInnate = {
                getReference = function(_, index)
                    assert(index == 0)
                    return {}
                end,
            },
        }

        local firstRestored, firstStatus =
            BfBot.Innate._OnQuickListsChecked(sprite, "BFBT01", -1)
        local secondRestored, secondStatus =
            BfBot.Innate._OnQuickListsChecked(sprite, "BFBT01", -1)

        return {
            firstRestored = firstRestored,
            firstStatus = firstStatus,
            secondRestored = secondRestored,
            secondStatus = secondStatus,
            warningCount = #warnings,
            warning = warnings[1],
        }
        """
    )

    assert not facts["firstRestored"]
    assert facts["firstStatus"] == "not_found"
    assert not facts["secondRestored"]
    assert facts["secondStatus"] == "not_found"
    assert facts["warningCount"] == 1
    assert "BFBT01" in facts["warning"]
    assert "not_found" in facts["warning"]


@pytest.mark.parametrize(
    ("resref", "portrait_index", "change_amount", "expected_status"),
    [
        ("BFBTCH", 0, -1, "ignored"),
        ("BFBTRM", 0, -1, "ignored"),
        ("BFBT09", 0, -1, "ignored"),
        ("BFBT01", -1, -1, "identity_mismatch"),
        ("BFBT01", 1, -1, "identity_mismatch"),
        ("BFBT01", 0, 0, "ignored"),
        ("BFBT01", 0, 1, "ignored"),
    ],
)
def test_recharge_rejects_non_consumption_and_non_party_events_before_iteration(
    innate_lua: LuaRuntime,
    resref: str,
    portrait_index: int,
    change_amount: int,
    expected_status: str,
) -> None:
    facts = innate_lua.execute(
        f"""
        local containerReads = 0
        local iteratorCalls = 0
        local mpCalls = 0
        local entry = {{
            m_spellId = {{ get = function() return "BFBT01" end }},
            m_flags = 4,
        }}
        local sprite = {{
            portraitIndex = {portrait_index},
            m_memorizedSpellsInnate = {{
                getReference = function(_, _)
                    containerReads = containerReads + 1
                    return {{ entry }}
                end,
            }},
        }}

        EEex_Sprite_GetPortraitIndex = function(value)
            return value.portraitIndex
        end
        EEex_Utility_IterateCPtrList = function(_, _)
            iteratorCalls = iteratorCalls + 1
        end
        BfBot.Mp = {{
            IsLocallyControlled = function()
                mpCalls = mpCalls + 1
                return false
            end,
        }}

        local restored, status = BfBot.Innate._OnQuickListsChecked(
            sprite, "{resref}", {change_amount})
        return {{
            restored = restored,
            status = status,
            flags = entry.m_flags,
            containerReads = containerReads,
            iteratorCalls = iteratorCalls,
            mpCalls = mpCalls,
        }}
        """
    )

    assert not facts["restored"]
    assert facts["status"] == expected_status
    assert facts["flags"] == 4
    assert facts["containerReads"] == 0
    assert facts["iteratorCalls"] == 0
    assert facts["mpCalls"] == 0


def test_innate_listeners_register_once_and_late_bind_across_reload() -> None:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        io = nil
        Infinity_DisplayString = function(_) end
        BfBot = {}
        """
    )
    runtime.execute(CORE_SOURCE)
    runtime.execute(
        """
        local loadedCount = 0
        local quickCount = 0
        local loadedCallback = nil
        local quickCallback = nil

        EEex_Sprite_AddLoadedListener = function(callback)
            loadedCount = loadedCount + 1
            loadedCallback = callback
        end
        EEex_Sprite_AddQuickListsCheckedListener = function(callback)
            quickCount = quickCount + 1
            quickCallback = callback
        end

        testListenerState = {
            loadedCount = function() return loadedCount end,
            quickCount = function() return quickCount end,
            loadedCallback = function() return loadedCallback end,
            quickCallback = function() return quickCallback end,
        }
        """
    )
    runtime.execute(INNATE_SOURCE)
    runtime.execute(
        """
        BfBot.Innate.Init()
        BfBot.Innate.Init()
        firstQuickCallback = testListenerState.quickCallback()
        """
    )

    runtime.execute(INNATE_SOURCE)
    facts = runtime.execute(
        """
        local reboundCalls = 0
        BfBot.Innate._OnQuickListsChecked = function(sprite, resref, changeAmount)
            reboundCalls = reboundCalls + 1
            return sprite, resref, changeAmount
        end
        BfBot.Innate.Init()

        local quickPresent = type(firstQuickCallback) == "function"
        if quickPresent then firstQuickCallback({}, "BFBT01", -1) end

        return {
            loadedCount = testListenerState.loadedCount(),
            quickCount = testListenerState.quickCount(),
            quickPresent = quickPresent,
            reboundCalls = reboundCalls,
        }
        """
    )

    assert facts["loadedCount"] == 1
    assert facts["quickCount"] == 1
    assert facts["quickPresent"]
    assert facts["reboundCalls"] == 1


def test_force_reload_migrates_the_legacy_loaded_listener_guard() -> None:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        io = nil
        Infinity_DisplayString = function(_) end
        BfBot = {}
        """
    )
    runtime.execute(CORE_SOURCE)
    runtime.execute(
        """
        local loadedCount = 1 -- listener already registered by v1.6.1
        local quickCount = 0
        BfBot.Innate = { _initDone = true }

        EEex_Sprite_AddLoadedListener = function(_)
            loadedCount = loadedCount + 1
        end
        EEex_Sprite_AddQuickListsCheckedListener = function(_)
            quickCount = quickCount + 1
        end

        legacyReloadState = {
            loadedCount = function() return loadedCount end,
            quickCount = function() return quickCount end,
        }
        """
    )

    runtime.execute(INNATE_SOURCE)
    facts = runtime.execute(
        """
        BfBot.Innate.Init()
        return {
            loadedCount = legacyReloadState.loadedCount(),
            quickCount = legacyReloadState.quickCount(),
            loadedGuard = BfBot._innateLoadedListenerRegistered == true,
            quickGuard = BfBot._innateQuickListsListenerRegistered == true,
        }
        """
    )

    assert facts["loadedCount"] == 1
    assert facts["quickCount"] == 1
    assert facts["loadedGuard"]
    assert facts["quickGuard"]


def test_bfbotgo_has_no_per_use_action_queue_or_special_ability_grant() -> None:
    handler_body = INNATE_SOURCE.split("function BFBOTGO", maxsplit=1)[1]

    assert "AddSpecialAbility" not in handler_body
    assert "EEex_Action_QueueResponseStringOnAIBase" not in handler_body


@pytest.mark.parametrize(
    ("case", "quick_cast_mode"),
    [
        ("normal", 0),
        ("normal", 1),
        ("normal", 2),
        ("busy", 0),
        ("empty", 0),
        ("error", 0),
    ],
)
def test_recharge_is_independent_of_every_bfbotgo_outcome(
    innate_lua: LuaRuntime,
    case: str,
    quick_cast_mode: int,
) -> None:
    script = f"""
        local case = "{case}"
        local queueActions = {{}}
        local displayRefs = {{}}
        local displays = {{}}
        local buildCalls = 0
        local drainCalls = 0
        local startCalls = 0
        local startMode = nil
        local startPreset = nil

        local entry = {{
            m_spellId = {{ get = function() return "BFBT01" end }},
            m_flags = 4,
        }}
        local sprite = {{
            portraitIndex = 0,
            m_memorizedSpellsInnate = {{
                getReference = function(_, index)
                    assert(index == 0)
                    return {{ entry }}
                end,
            }},
            displayTextRef = function(_, strref)
                displayRefs[#displayRefs + 1] = strref
            end,
        }}

        EEex_Sprite_GetPortraitIndex = function(value)
            return value.portraitIndex
        end
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return sprite end
            return nil
        end
        EEex_Utility_IterateCPtrList = function(values, callback)
            for _, value in ipairs(values) do
                if callback(value) then break end
            end
        end
        EEex_IsBitUnset = function(value, bitIndex)
            return bit.band(value, bit.lshift(1, bitIndex)) == 0
        end
        EEex_SetBit = function(value, bitIndex)
            return bit.bor(value, bit.lshift(1, bitIndex))
        end
        EEex_Action_QueueResponseStringOnAIBase = function(action, _)
            queueActions[#queueActions + 1] = action
        end

        BfBot._Display = function(message)
            displays[#displays + 1] = message
        end
        BfBot.Exec = {{
            GetState = function()
                return case == "busy" and "running" or "idle"
            end,
            Start = function(_, mode, preset)
                startCalls = startCalls + 1
                startMode = mode
                startPreset = preset
            end,
        }}
        BfBot.Persist = {{
            BuildQueueForCharacter = function(_, _)
                buildCalls = buildCalls + 1
                if case == "error" then error("synthetic build failure") end
                if case == "empty" then return {{}}, "synthetic empty" end
                return {{ {{ tag = "entry" }} }}
            end,
            DrainBuildSkips = function()
                drainCalls = drainCalls + 1
            end,
            GetQuickCast = function(_, _)
                return {quick_cast_mode}
            end,
        }}

        local restored, rechargeStatus =
            BfBot.Innate._OnQuickListsChecked(sprite, "BFBT01", -1)
        BFBOTGO({{ m_effectAmount = 0, m_dWFlags = 1 }}, nil, nil)

        return {{
            restored = restored,
            rechargeStatus = rechargeStatus,
            flags = entry.m_flags,
            actionCount = #queueActions,
            displayRefCount = #displayRefs,
            displayRef = displayRefs[1],
            displayCount = #displays,
            display = displays[1] or "",
            buildCalls = buildCalls,
            drainCalls = drainCalls,
            startCalls = startCalls,
            startMode = startMode,
            startPreset = startPreset,
        }}
        """
    suppress_fault_handler = (
        case == "error" and sys.platform == "win32" and faulthandler.is_enabled()
    )
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        facts = innate_lua.execute(script)
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert facts["restored"]
    assert facts["rechargeStatus"] == "restored"
    assert facts["flags"] == 5
    assert facts["actionCount"] == 0

    if case == "normal":
        assert facts["buildCalls"] == 1
        assert facts["drainCalls"] == 1
        assert facts["startCalls"] == 1
        assert facts["startMode"] == quick_cast_mode
        assert facts["startPreset"] == 1
    elif case == "busy":
        assert facts["buildCalls"] == 0
        assert facts["startCalls"] == 0
        assert facts["displayRefCount"] == 1
        assert facts["displayRef"] == 14007
    elif case == "empty":
        assert facts["buildCalls"] == 1
        assert facts["drainCalls"] == 1
        assert facts["startCalls"] == 0
        assert "No spells to cast" in facts["display"]
        assert "synthetic empty" in facts["display"]
    else:
        assert case == "error"
        assert facts["buildCalls"] == 1
        assert facts["drainCalls"] == 0
        assert facts["startCalls"] == 0
        assert "BuffBot innate error" in facts["display"]
        assert "synthetic build failure" in facts["display"]
