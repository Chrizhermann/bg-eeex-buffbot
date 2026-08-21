from __future__ import annotations

from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LOC_SOURCE = (ROOT / "buffbot/BfBotLoc.lua").read_text(encoding="utf-8")
UI_SOURCE = (ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8")
MENU_SOURCE = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")
TEST_SOURCE = (ROOT / "buffbot/BfBotTst.lua").read_text(encoding="utf-8")


@pytest.fixture
def ui_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        local party = {
            [0] = { m_id = 100, name = "Aerie" },
            [1] = { m_id = 101, name = "Imoen" },
        }

        BfBot = {
            MAX_PRESETS = 8,
            MAX_SPELL_REPEATS = 5,
            UI = {},
            Scan = {
                Invalidate = function(_) end,
                InvalidateAll = function() end,
                InvalidateSummons = function() end,
            },
            Exec = {
                _ResolveCaster = function(ref)
                    return { m_id = ref.oid, name = ref.name }
                end,
            },
            Persist = {},
            Class = {},
            Theme = {},
            _GetName = function(sprite) return sprite and sprite.name or "" end,
            _SafeCallback = function(_, callback) return callback end,
            _Warn = function(_) end,
        }

        EEex_Sprite_GetInPortrait = function(slot) return party[slot] end
        Infinity_PushMenu = function(_) end
        Infinity_PopMenu = function(_) end
        """
    )
    runtime.execute("io = nil")
    runtime.execute(LOC_SOURCE)
    runtime.execute(UI_SOURCE)
    return runtime


def test_selection_follows_resref_after_reorder(ui_lua: LuaRuntime) -> None:
    assert ui_lua.eval("type(BfBot.UI._OnSpellRowAction)") == "function"

    facts = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_isOpen = true
        buffbot_spellTable = {
            { resref = "SPWI101", hasVariants = 0 },
            { resref = "SPWI102", hasVariants = 1 },
            { resref = "SPWI103", hasVariants = 0 },
        }
        buffbot_selectedRow = 2

        -- Cell 3 selects without toggling or locking.
        BfBot.UI._OnSpellRowAction(3)

        buffbot_spellTable = {
            { resref = "SPWI103", hasVariants = 0 },
            { resref = "SPWI101", hasVariants = 0 },
            { resref = "SPWI102", hasVariants = 1 },
        }
        BfBot.UI._RestoreSpellSelection()

        return {
            row = buffbot_selectedRow,
            resref = buffbot_spellTable[buffbot_selectedRow].resref,
            hasVariants = buffbot_selectedHasVariants,
        }
        """
    )

    assert facts["row"] == 3
    assert facts["resref"] == "SPWI102"
    assert facts["hasVariants"] == 1


def test_refresh_preserves_selected_resref(ui_lua: LuaRuntime) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_isOpen = true
        buffbot_spellTable = {
            { resref = "SPWI101", hasVariants = 0 },
            { resref = "SPWI102", hasVariants = 1 },
        }
        buffbot_selectedRow = 2
        BfBot.UI._OnSpellRowAction(3)

        BfBot.Persist.GetConfig = function(_)
            return {
                presets = {
                    [1] = { name = "Long Buffs", spells = {
                        SPWI101 = { pri = 2 },
                        SPWI102 = { pri = 1 },
                    } },
                },
                ovr = {},
            }
        end
        BfBot.Scan.GetCastableSpells = function(_) return {} end
        BfBot.UI._BuildSpellRows = function(_, _, _, _)
            return {
                { resref = "SPWI102", hasVariants = 1 },
                { resref = "SPWI101", hasVariants = 0 },
            }
        end
        BfBot.UI._CastCharLabel = function() return "Cast Aerie" end
        BfBot.UI._GetStatusText = function() return "" end

        BfBot.UI._Refresh()
        local entry = buffbot_spellTable[buffbot_selectedRow]
        return {
            row = buffbot_selectedRow,
            resref = entry and entry.resref or nil,
            hasVariants = buffbot_selectedHasVariants,
        }
        """
    )

    assert facts["row"] == 1
    assert facts["resref"] == "SPWI102"
    assert facts["hasVariants"] == 1


def test_rapid_refresh_keeps_pending_canonical_resref(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_isOpen = true
        buffbot_spellTable = {
            { resref = "SPWI101", hasVariants = 0 },
            { resref = "SPWI102", hasVariants = 1 },
        }
        buffbot_selectedRow = 2
        BfBot.UI._OnSpellRowAction(3)

        BfBot.Persist.GetConfig = function(_)
            return {
                presets = {
                    [1] = { name = "Long Buffs", spells = {
                        SPWI101 = { pri = 2 },
                        SPWI102 = { pri = 1 },
                    } },
                },
                ovr = {},
            }
        end
        BfBot.Scan.GetCastableSpells = function(_) return {} end
        BfBot.UI._BuildSpellRows = function(_, _, _, _)
            return {
                { resref = "SPWI102", hasVariants = 1 },
                { resref = "SPWI101", hasVariants = 0 },
            }
        end
        BfBot.UI._CastCharLabel = function() return "Cast Aerie" end
        BfBot.UI._GetStatusText = function() return "" end

        BfBot.UI._Refresh()
        -- Before the reconciliation label renders, the widget writes its old
        -- valid index and another quick-list callback triggers a refresh.
        buffbot_selectedRow = 2
        buffbot_selectedHasVariants = 0
        BfBot.UI._Refresh()

        return {
            row = buffbot_selectedRow,
            resref = buffbot_spellTable[buffbot_selectedRow].resref,
            canonical = BfBot.UI._spellSel and BfBot.UI._spellSel.resref,
            hasVariants = buffbot_selectedHasVariants,
        }
        """
    )

    assert facts["row"] == 1
    assert facts["resref"] == "SPWI102"
    assert facts["canonical"] == "SPWI102"
    assert facts["hasVariants"] == 1


@pytest.mark.parametrize("replacement_name", ["Jaheira", "Aerie"])
def test_refresh_clears_selection_when_party_member_changes_silently(
    ui_lua: LuaRuntime,
    replacement_name: str,
) -> None:
    facts = ui_lua.execute(
        """
        local currentParty = { m_id = 100, name = "Aerie" }
        EEex_Sprite_GetInPortrait = function(slot)
            if slot == 0 then return currentParty end
            return nil
        end

        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_isOpen = true
        buffbot_spellTable = {
            { resref = "SPWI101", hasVariants = 1 },
        }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)

        -- The portrait slot now contains another character without going
        -- through SetChar; even the same display name must not transfer state.
        currentParty = { m_id = 102, name = "__REPLACEMENT_NAME__" }
        BfBot.Persist.GetConfig = function(_)
            return {
                presets = {
                    [1] = { name = "Long Buffs", spells = {
                        SPWI101 = { pri = 1 },
                    } },
                },
                ovr = {},
            }
        end
        BfBot.Scan.GetCastableSpells = function(_) return {} end
        BfBot.UI._BuildSpellRows = function(_, _, _, _)
            return { { resref = "SPWI101", hasVariants = 1 } }
        end
        BfBot.UI._CastCharLabel = function() return "Cast replacement" end
        BfBot.UI._GetStatusText = function() return "" end

        BfBot.UI._Refresh()
        return {
            row = buffbot_selectedRow,
            canonicalCleared = BfBot.UI._spellSel == nil,
            hasVariants = buffbot_selectedHasVariants,
        }
        """
        .replace("__REPLACEMENT_NAME__", replacement_name)
    )

    assert facts["row"] == 0
    assert facts["canonicalCleared"]
    assert facts["hasVariants"] == 0


def test_refresh_clears_stale_selection_when_config_disappears(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_isOpen = true
        buffbot_spellTable = {
            { resref = "SPWI101", hasVariants = 1 },
        }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)
        BfBot.Persist.GetConfig = function(_) return nil end

        BfBot.UI._Refresh()
        return {
            rows = #buffbot_spellTable,
            row = buffbot_selectedRow,
            canonicalCleared = BfBot.UI._spellSel == nil,
            hasVariants = buffbot_selectedHasVariants,
        }
        """
    )

    assert facts["rows"] == 0
    assert facts["row"] == 0
    assert facts["canonicalCleared"]
    assert facts["hasVariants"] == 0


def test_main_spell_list_routes_row_actions_through_selection_controller() -> None:
    assert 'action      "BfBot.UI._OnSpellRowAction(cellNumber)"' in MENU_SOURCE


def test_row_action_controller_preserves_repeat_and_lock_cells(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_spellTable = { { resref = "SPWI101", hasVariants = 0 } }
        buffbot_selectedRow = 1

        local repeatDelta = nil
        local lockRow = nil
        BfBot.UI.StepSelectedRepeat = function(delta) repeatDelta = delta end
        BfBot.UI.ToggleLock = function(row) lockRow = row end

        BfBot.UI._OnSpellRowAction(6)
        BfBot.UI._OnSpellRowAction(8)
        return {
            repeatDelta = repeatDelta,
            lockRow = lockRow,
            canonical = BfBot.UI._spellSel and BfBot.UI._spellSel.resref,
        }
        """
    )

    assert facts["repeatDelta"] == 1
    assert facts["lockRow"] == 1
    assert facts["canonical"] == "SPWI101"


@pytest.mark.parametrize(
    "change_context",
    [
        "BfBot.UI.SetChar(1)",
        "BfBot.UI.SetPreset(2)",
        "BfBot.UI.ToggleView()",
        "BfBot.UI.SetSummon(1)",
    ],
)
def test_explicit_context_changes_clear_selection(
    ui_lua: LuaRuntime,
    change_context: str,
) -> None:
    cleared = ui_lua.execute(
        f"""
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        BfBot.UI._summonSlice = {{
            {{ identity = "cre:deva", oid = 200, name = "Deva" }},
        }}
        buffbot_spellTable = {{ {{ resref = "SPPR101", hasVariants = 0 }} }}
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)

        BfBot.UI._Refresh = function() end
        BfBot.UI._RefreshSummonList = function() end
        {change_context}

        return BfBot.UI._spellSel == nil
            and buffbot_selectedRow == 0
            and buffbot_selectedHasVariants == 0
        """
    )

    assert cleared


def test_summon_list_fallback_clears_previous_caster_selection(
    ui_lua: LuaRuntime,
) -> None:
    cleared = ui_lua.execute(
        """
        BfBot.UI._view = "summons"
        BfBot.UI._presetIdx = 1
        BfBot.UI._summonList = {
            { identity = "cre:deva", oid = 200, name = "Deva" },
        }
        BfBot.UI._summonSel = {
            identity = "cre:deva", oid = 200, name = "Deva",
        }
        buffbot_spellTable = { { resref = "SPPR101", hasVariants = 1 } }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)

        BfBot.Scan.GetAlliedSummons = function()
            return {
                { identity = "cre:planetar", oid = 201, name = "Planetar" },
            }
        end
        BfBot.UI._RefreshSummonList()
        return BfBot.UI._spellSel == nil
            and buffbot_selectedRow == 0
            and BfBot.UI._summonSel.identity == "cre:planetar"
        """
    )

    assert cleared


def test_replacement_summon_with_same_identity_clears_selection(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "summons"
        BfBot.UI._presetIdx = 1
        BfBot.UI._summonList = {
            {
                identity = "cre:planetar", cloneType = 0,
                oid = 200, name = "Planetar",
            },
        }
        BfBot.UI._summonSel = {
            identity = "cre:planetar", cloneType = 0,
            oid = 200, name = "Planetar",
        }
        buffbot_spellTable = { { resref = "SPPR101", hasVariants = 1 } }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)

        BfBot.Scan.GetAlliedSummons = function()
            return {
                {
                    identity = "cre:planetar", cloneType = 0,
                    oid = 201, name = "Planetar",
                },
            }
        end
        BfBot.UI._RefreshSummonList()
        return {
            selectedOid = BfBot.UI._summonSel and BfBot.UI._summonSel.oid,
            canonicalCleared = BfBot.UI._spellSel == nil,
            row = buffbot_selectedRow,
            hasVariants = buffbot_selectedHasVariants,
        }
        """
    )

    assert facts["selectedOid"] == 201
    assert facts["canonicalCleared"]
    assert facts["row"] == 0
    assert facts["hasVariants"] == 0


def test_same_live_summon_survives_summon_list_rebuild(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "summons"
        BfBot.UI._presetIdx = 1
        BfBot.UI._summonList = {
            {
                identity = "cre:planetar", cloneType = 0,
                oid = 200, name = "Planetar",
            },
        }
        BfBot.UI._summonSel = {
            identity = "cre:planetar", cloneType = 0,
            oid = 200, name = "Planetar",
        }
        buffbot_spellTable = { { resref = "SPPR101", hasVariants = 1 } }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)

        BfBot.Scan.GetAlliedSummons = function()
            return {
                {
                    identity = "cre:planetar", cloneType = 0,
                    oid = 200, name = "Planetar",
                },
            }
        end
        BfBot.UI._RefreshSummonList()
        return {
            selectedOid = BfBot.UI._summonSel and BfBot.UI._summonSel.oid,
            canonical = BfBot.UI._spellSel and BfBot.UI._spellSel.resref,
            row = buffbot_selectedRow,
            hasVariants = buffbot_selectedHasVariants,
        }
        """
    )

    assert facts["selectedOid"] == 200
    assert facts["canonical"] == "SPPR101"
    assert facts["row"] == 1
    assert facts["hasVariants"] == 1


def test_empty_summons_view_uses_localized_generic_title_without_preset_access(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "summons"
        BfBot.UI._presetIdx = 1
        BfBot.UI._summonList = {}
        BfBot.UI._summonSel = nil

        local originalGet = BfBot.L10N.Get
        BfBot.L10N.Get = function(key)
            if key == "ui.title.summons" then
                return "BuffBot - 召唤物 100%"
            end
            return originalGet(key)
        end

        BfBot.Persist._GetProtagonist = function() return {} end
        BfBot.Persist.GetConfig = function(_)
            return { ap = 1, presets = {} }
        end
        BfBot.Persist.PeekSummonPreset = function(_, _) return nil end
        BfBot.UI._CastCharLabel = function() return "" end
        BfBot.UI._GetStatusText = function() return "" end

        local ok, err = pcall(BfBot.UI._RefreshSummonsView)
        return {
            ok = ok,
            err = err,
            title = buffbot_title,
            spellCount = #buffbot_spellTable,
        }
        """
    )

    assert facts["ok"], facts["err"]
    assert facts["title"] == "BuffBot - 召唤物 100%"
    assert facts["spellCount"] == 0


@pytest.mark.parametrize("operation", ["create", "delete"])
def test_preset_lifecycle_changes_clear_selection(
    ui_lua: LuaRuntime,
    operation: str,
) -> None:
    cleared = ui_lua.execute(
        f"""
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_spellTable = {{ {{ resref = "SPPR101", hasVariants = 1 }} }}
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)

        BfBot.UI._Refresh = function() end
        BfBot.Innate = {{ RefreshAll = function() end }}
        BfBot.Persist.CreatePresetAll = function() return 2 end
        BfBot.Persist.DeletePresetAll = function(_) return true end
        BfBot.Persist.GetConfig = function(_)
            return {{ ap = 1, presets = {{ [1] = {{ spells = {{}} }} }} }}
        end
        if "{operation}" == "create" then
            BfBot.UI.CreateNewPreset()
        else
            BfBot.UI.DeleteCurrentPreset()
            -- Delete is intentionally deferred behind BUFFBOT_CONFIRM.
            assert(BfBot.UI._spellSel ~= nil and buffbot_selectedRow == 1)
            BfBot.UI.RunConfirm()
        end

        return BfBot.UI._spellSel == nil
            and buffbot_selectedRow == 0
            and buffbot_selectedHasVariants == 0
        """
    )

    assert cleared


def test_one_shot_sync_recovers_from_delayed_widget_clear(
    ui_lua: LuaRuntime,
) -> None:
    assert ui_lua.eval("type(BfBot.UI._SelectionSyncTick)") == "function"

    facts = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_isOpen = true
        buffbot_spellTable = {
            { resref = "SPWI101", hasVariants = 0 },
            { resref = "SPWI102", hasVariants = 1 },
        }
        buffbot_selectedRow = 2
        BfBot.UI._OnSpellRowAction(3)

        buffbot_spellTable = {
            { resref = "SPWI102", hasVariants = 1 },
            { resref = "SPWI101", hasVariants = 0 },
        }
        BfBot.UI._RestoreSpellSelection()

        -- Simulate the native list widget clearing its var after replacement.
        buffbot_selectedRow = 0
        buffbot_selectedHasVariants = 0
        local tickResult = BfBot.UI._SelectionSyncTick()

        return {
            tickResult = tickResult,
            row = buffbot_selectedRow,
            resref = buffbot_spellTable[buffbot_selectedRow].resref,
            hasVariants = buffbot_selectedHasVariants,
        }
        """
    )

    # The hidden label remains disabled; evaluating its enabled expression is
    # used only as the render-frame callback (same pattern as _SafetyTick).
    assert not facts["tickResult"]
    assert facts["row"] == 1
    assert facts["resref"] == "SPWI102"
    assert facts["hasVariants"] == 1


def test_one_shot_sync_recovers_from_stale_valid_widget_row(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_isOpen = true
        buffbot_spellTable = {
            { resref = "SPWI101", hasVariants = 0 },
            { resref = "SPWI102", hasVariants = 1 },
        }
        buffbot_selectedRow = 2
        BfBot.UI._OnSpellRowAction(3)

        buffbot_spellTable = {
            { resref = "SPWI102", hasVariants = 1 },
            { resref = "SPWI101", hasVariants = 0 },
        }
        BfBot.UI._RestoreSpellSelection()

        -- Simulate the widget restoring its old numeric index (2), which is
        -- still valid but now points at a different spell.
        buffbot_selectedRow = 2
        buffbot_selectedHasVariants = 0
        BfBot.UI._SelectionSyncTick()
        return {
            row = buffbot_selectedRow,
            resref = buffbot_spellTable[buffbot_selectedRow].resref,
            hasVariants = buffbot_selectedHasVariants,
        }
        """
    )

    assert facts["row"] == 1
    assert facts["resref"] == "SPWI102"
    assert facts["hasVariants"] == 1


def test_main_menu_hosts_selection_sync_tick() -> None:
    assert 'enabled "BfBot.UI._SelectionSyncTick()"' in MENU_SOURCE


def test_target_picker_writes_to_anchored_resref_after_reorder(
    ui_lua: LuaRuntime,
) -> None:
    written_resref = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_charNames = { "Aerie", "Imoen" }
        buffbot_spellTable = {
            {
                resref = "SPWI101", name = "Armor", tgt = "Aerie",
                tgtUnlock = 1, isSelfOnly = 0, isAoE = 0,
            },
            {
                resref = "SPWI102", name = "Blur", tgt = "Imoen",
                tgtUnlock = 1, isSelfOnly = 0, isAoE = 0,
            },
        }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)

        local written = nil
        BfBot.Persist.SetSpellTarget = function(_, _, resref, _)
            written = resref
        end
        BfBot.UI.OpenTargets(1)

        buffbot_spellTable = {
            {
                resref = "SPWI102", name = "Blur", tgt = "Imoen",
                tgtUnlock = 1, isSelfOnly = 0, isAoE = 0,
            },
            {
                resref = "SPWI101", name = "Armor", tgt = "Aerie",
                tgtUnlock = 1, isSelfOnly = 0, isAoE = 0,
            },
        }
        BfBot.UI.PickerDone()
        return written
        """
    )

    assert written_resref == "SPWI101"


@pytest.mark.parametrize("picker_action", ["PickerSelf", "PickerDone"])
def test_target_picker_closes_and_clears_anchor_when_caster_disappears(
    ui_lua: LuaRuntime,
    picker_action: str,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "summons"
        BfBot.UI._summonSel = {
            identity = "cre:planetar", cloneType = 0,
            oid = 200, name = "Planetar",
        }
        BfBot.UI._presetIdx = 1
        buffbot_charNames = { "Aerie", "Imoen" }
        buffbot_spellTable = {
            {
                resref = "SPWI101", name = "Armor", tgt = "Aerie",
                tgtUnlock = 1, isSelfOnly = 0, isAoE = 0,
            },
        }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)
        BfBot.UI.OpenTargets(1)

        local popped = nil
        local wrote = false
        Infinity_PopMenu = function(name) popped = name end
        BfBot.Persist.SetSpellTarget = function(_, _, _, _) wrote = true end
        BfBot.UI._GetSelectedSprite = function() return nil end

        BfBot.UI.__PICKER_ACTION__()
        return {
            anchorCleared = BfBot.UI._targetSpellAnchor == nil,
            popped = popped,
            wrote = wrote,
        }
        """.replace("__PICKER_ACTION__", picker_action)
    )

    assert facts["anchorCleared"]
    assert facts["popped"] == "BUFFBOT_TARGETS"
    assert not facts["wrote"]


def test_variant_picker_writes_to_anchored_resref_after_reorder(
    ui_lua: LuaRuntime,
) -> None:
    written_resref = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_spellTable = {
            {
                resref = "SPWI101", name = "Protection", hasVariants = 1,
                variants = {
                    { resref = "SPWI1A", name = "Protection from Fire" },
                },
            },
            { resref = "SPWI102", name = "Blur", hasVariants = 0 },
        }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)

        local written = nil
        BfBot.Persist.SetSpellVariant = function(_, _, resref, _)
            written = resref
        end
        BfBot.UI.OpenVariants(1)

        buffbot_spellTable = {
            { resref = "SPWI102", name = "Blur", hasVariants = 0 },
            {
                resref = "SPWI101", name = "Protection", hasVariants = 1,
                variants = {
                    { resref = "SPWI1A", name = "Protection from Fire" },
                },
            },
        }
        buffbot_selectedRow = 1
        BfBot.UI.SelectVariant(1)
        return written
        """
    )

    assert written_resref == "SPWI101"


def test_variant_picker_precomputes_complete_localized_title_for_arbitrary_name(
    ui_lua: LuaRuntime,
) -> None:
    spell_name = "龙's \"Ward\" 100%"
    ui_lua.globals().test_spell_name = spell_name

    facts = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_spellTable = {
            {
                resref = "SPWI101", name = test_spell_name, hasVariants = 1,
                variants = {
                    { resref = "SPWI1A", name = "Variant" },
                },
            },
        }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)

        local originalFormat = BfBot.L10N.Format
        BfBot.L10N.Format = function(key, values)
            if key == "ui.select_variant_title" then
                _variantFormatKey = key
                _variantFormatSpell = values and values.spell or nil
                return "选择变体：「" .. tostring(_variantFormatSpell) .. "」 100%"
            end
            return originalFormat(key, values)
        end

        BfBot.UI.OpenVariants(1)
        return {
            title = buffbot_variantTitle,
            formatKey = _variantFormatKey,
            formatSpell = _variantFormatSpell,
            variantAnchor = BfBot.UI._variantSpellAnchor
                and BfBot.UI._variantSpellAnchor.resref or nil,
            selectedAnchor = BfBot.UI._spellSel
                and BfBot.UI._spellSel.resref or nil,
        }
        """
    )

    assert facts["title"] == f"选择变体：「{spell_name}」 100%"
    assert facts["formatKey"] == "ui.select_variant_title"
    assert facts["formatSpell"] == spell_name
    assert facts["variantAnchor"] == "SPWI101"
    assert facts["selectedAnchor"] == "SPWI101"


def test_variant_picker_closes_and_clears_anchor_when_caster_disappears(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "summons"
        BfBot.UI._summonSel = {
            identity = "cre:planetar", cloneType = 0,
            oid = 200, name = "Planetar",
        }
        BfBot.UI._presetIdx = 1
        buffbot_spellTable = {
            {
                resref = "SPWI101", name = "Protection", hasVariants = 1,
                variants = {
                    { resref = "SPWI1A", name = "Protection from Fire" },
                },
            },
        }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)
        BfBot.UI.OpenVariants(1)

        local popped = nil
        local wrote = false
        Infinity_PopMenu = function(name) popped = name end
        BfBot.Persist.SetSpellVariant = function(_, _, _, _) wrote = true end
        BfBot.UI._GetSelectedSprite = function() return nil end

        BfBot.UI.SelectVariant(1)
        return {
            anchorCleared = BfBot.UI._variantSpellAnchor == nil,
            popped = popped,
            wrote = wrote,
        }
        """
    )

    assert facts["anchorCleared"]
    assert facts["popped"] == "BUFFBOT_VARIANTS"
    assert not facts["wrote"]


def test_variant_picker_rejects_variant_removed_during_refresh(
    ui_lua: LuaRuntime,
) -> None:
    written = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_spellTable = {
            {
                resref = "SPWI101", name = "Protection", hasVariants = 1,
                variants = {
                    { resref = "SPWI1A", name = "Protection from Fire" },
                },
            },
        }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)

        local wrote = false
        BfBot.Persist.SetSpellVariant = function(_, _, _, _) wrote = true end
        BfBot.UI.OpenVariants(1)

        buffbot_spellTable = {
            {
                resref = "SPWI101", name = "Protection", hasVariants = 1,
                variants = {
                    { resref = "SPWI1B", name = "Protection from Cold" },
                },
            },
        }
        BfBot.UI.SelectVariant(1)
        return wrote
        """
    )

    assert not written


def test_duration_sort_follows_selected_resref(ui_lua: LuaRuntime) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_isOpen = true
        buffbot_spellTable = {
            { resref = "SPWI101", dur = 10, lock = 0, hasVariants = 0 },
            { resref = "SPWI102", dur = 100, lock = 0, hasVariants = 1 },
        }
        buffbot_selectedRow = 2
        BfBot.UI._OnSpellRowAction(3)
        BfBot.UI._RenumberPriorities = function() end

        BfBot.UI.SortByDuration()
        return {
            row = buffbot_selectedRow,
            resref = buffbot_spellTable[buffbot_selectedRow].resref,
            hasVariants = buffbot_selectedHasVariants,
        }
        """
    )

    assert facts["row"] == 1
    assert facts["resref"] == "SPWI102"
    assert facts["hasVariants"] == 1


def test_duration_sort_keeps_pending_canonical_resref(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        BfBot.UI._presetIdx = 1
        buffbot_isOpen = true
        buffbot_spellTable = {
            { resref = "SPWI101", dur = 10, lock = 0, hasVariants = 0 },
            { resref = "SPWI102", dur = 100, lock = 0, hasVariants = 1 },
        }
        buffbot_selectedRow = 2
        BfBot.UI._OnSpellRowAction(3)

        -- A refresh has already projected the canonical spell to row 1, but
        -- the native widget briefly writes its old valid row before Sort runs.
        buffbot_spellTable = {
            { resref = "SPWI102", dur = 100, lock = 0, hasVariants = 1 },
            { resref = "SPWI101", dur = 10, lock = 0, hasVariants = 0 },
        }
        BfBot.UI._RestoreSpellSelection()
        buffbot_selectedRow = 2
        buffbot_selectedHasVariants = 0
        BfBot.UI._RenumberPriorities = function() end

        BfBot.UI.SortByDuration()
        return {
            row = buffbot_selectedRow,
            resref = buffbot_spellTable[buffbot_selectedRow].resref,
            canonical = BfBot.UI._spellSel and BfBot.UI._spellSel.resref,
            hasVariants = buffbot_selectedHasVariants,
        }
        """
    )

    assert facts["row"] == 1
    assert facts["resref"] == "SPWI102"
    assert facts["canonical"] == "SPWI102"
    assert facts["hasVariants"] == 1


def test_unrelated_spell_event_invalidates_without_refresh(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        buffbot_isOpen = true
        local invalidated = nil
        local refreshes = 0
        BfBot.Scan.Invalidate = function(sprite) invalidated = sprite.m_id end
        BfBot.UI._Refresh = function() refreshes = refreshes + 1 end

        BfBot.UI._OnSpellListChanged(
            { m_id = 999, name = "Unrelated" }, "SPWI101", 1)
        return { invalidated = invalidated, refreshes = refreshes }
        """
    )

    assert facts["invalidated"] == 999
    assert facts["refreshes"] == 0


@pytest.mark.parametrize(
    "event_call",
    [
        'BfBot.UI._OnSpellListChanged(sprite, "SPWI101", 1)',
        'BfBot.UI._OnSpellRemoved(sprite, "SPWI101")',
        "BfBot.UI._OnSpellCountsReset(sprite)",
    ],
)
def test_displayed_caster_event_invalidates_and_refreshes(
    ui_lua: LuaRuntime,
    event_call: str,
) -> None:
    facts = ui_lua.execute(
        f"""
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        buffbot_isOpen = true
        local invalidations = 0
        local refreshes = 0
        BfBot.Scan.Invalidate = function(_) invalidations = invalidations + 1 end
        BfBot.UI._Refresh = function() refreshes = refreshes + 1 end
        local sprite = {{ m_id = 100, name = "Aerie" }}
        {event_call}
        return {{ invalidations = invalidations, refreshes = refreshes }}
        """
    )

    assert facts["invalidations"] == 1
    assert facts["refreshes"] == 1


@pytest.mark.parametrize(
    "callback",
    ["_OnSpellListChanged", "_OnSpellRemoved"],
)
def test_bfbt_event_invalidates_without_visible_refresh(
    ui_lua: LuaRuntime,
    callback: str,
) -> None:
    facts = ui_lua.execute(
        f"""
        BfBot.UI._view = "party"
        BfBot.UI._charSlot = 0
        buffbot_isOpen = true
        local invalidated = nil
        local refreshes = 0
        BfBot.Scan.Invalidate = function(sprite) invalidated = sprite.m_id end
        BfBot.UI._Refresh = function() refreshes = refreshes + 1 end

        BfBot.UI.{callback}(
            {{ m_id = 100, name = "Aerie" }}, "bfbt11", 1)
        return {{ invalidated = invalidated, refreshes = refreshes }}
        """
    )

    assert facts["invalidated"] == 100
    assert facts["refreshes"] == 0


def test_spell_listener_registration_is_idempotent_and_hot_reload_safe(
    ui_lua: LuaRuntime,
) -> None:
    assert ui_lua.eval("type(BfBot.UI._RegisterSpellListeners)") == "function"

    ui_lua.execute(
        """
        _listenerAdds = { checked = 0, reset = 0, removed = 0 }
        _listeners = {}
        BfBot._SafeCallback = function(_, callback) return callback end
        EEex_Sprite_AddQuickListsCheckedListener = function(callback)
            _listenerAdds.checked = _listenerAdds.checked + 1
            _listeners.checked = callback
        end
        EEex_Sprite_AddQuickListCountsResetListener = function(callback)
            _listenerAdds.reset = _listenerAdds.reset + 1
            _listeners.reset = callback
        end
        EEex_Sprite_AddQuickListNotifyRemovedListener = function(callback)
            _listenerAdds.removed = _listenerAdds.removed + 1
            _listeners.removed = callback
        end
        BfBot.UI._RegisterSpellListeners()
        BfBot.UI._RegisterSpellListeners()
        """
    )

    # Simulate a Lua module reload while the root BfBot table survives.
    ui_lua.execute(UI_SOURCE)
    facts = ui_lua.execute(
        """
        local dispatched = nil
        BfBot.UI._OnSpellListChanged = function(_, resref, amount)
            dispatched = resref .. ":" .. amount
        end
        BfBot.UI._RegisterSpellListeners()
        _listeners.checked({}, "SPWI101", 2)
        return {
            checked = _listenerAdds.checked,
            reset = _listenerAdds.reset,
            removed = _listenerAdds.removed,
            dispatched = dispatched,
        }
        """
    )

    assert facts["checked"] == 1
    assert facts["reset"] == 1
    assert facts["removed"] == 1
    assert facts["dispatched"] == "SPWI101:2"


def test_in_game_selection_refresh_phase_is_wired_into_run_all() -> None:
    assert "function BfBot.Test.SelectionRefresh()" in TEST_SOURCE
    assert "local selectionOk = BfBot.Test.SelectionRefresh()" in TEST_SOURCE
    assert 'P("  Selection Refresh:   "' in TEST_SOURCE
    assert "and selectionOk" in TEST_SOURCE


def test_in_game_test_source_parses_under_luajit() -> None:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("BfBot = { _Print = function(_) end }")
    runtime.execute(TEST_SOURCE)
