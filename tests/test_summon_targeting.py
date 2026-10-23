"""Target selection for summon casters and for opcode-214 variant spells.

Issue #78. Two defects met in the Summons view:

1. A row's targeting flags came from the opcode-214 PARENT ability, which is
   the engine's self-cast selection wrapper (target type 5/7 in 247 of the 249
   op-214 abilities of the reference install). Execution casts the SELECTED
   VARIANT directly (`ReallyForceSpellRES`), so the variant's own target type
   decides which targets are legal.
2. The resulting "self-only" lock disables every control in the target picker,
   and the Unlock escape hatch was party-view only — so a locked row was a
   permanent dead end for a summon caster, whose buffs are meant for the party.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CORE_SOURCE = (ROOT / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")
LOC_SOURCE = (ROOT / "buffbot/BfBotLoc.lua").read_text(encoding="utf-8")
CLASS_SOURCE = (ROOT / "buffbot/BfBotCls.lua").read_text(encoding="utf-8")
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")
EXEC_SOURCE = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")
UI_SOURCE = (ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8")
MENU_SOURCE = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")


# Synthetic SPL headers: `actionType` is the ability target type the engine
# stores at ability offset 0x0C. 5/7 = caster, 1 = one creature, 4 = party-wide.
_SPL_HELPERS = """
function BfBot_TestSpl(targetTypes)
    local abilities = {}
    for index, targetType in ipairs(targetTypes) do
        abilities[index - 1] = {
            actionType = targetType,
            quickSlotIcon = { get = function() return "ICON" end },
        }
    end
    return {
        abilityCount = #targetTypes,
        genericName = 0,
        identifiedName = 0,
        getAbility = function(_, index) return abilities[index] end,
    }
end
"""


@pytest.fixture
def class_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute("io = nil")
    runtime.execute(CORE_SOURCE)
    runtime.execute(CLASS_SOURCE)
    runtime.execute(_SPL_HELPERS)
    return runtime


@pytest.fixture
def ui_lua() -> LuaRuntime:
    """Party of two plus the real classifier (the row builder calls into it)."""
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute("io = nil")
    runtime.execute(CORE_SOURCE)
    runtime.execute(CLASS_SOURCE)
    runtime.execute(
        """
        BfBot.Scan = {
            Invalidate = function(_) end,
            InvalidateAll = function() end,
            InvalidateSummons = function() end,
        }
        BfBot.Innate = {}
        BfBot.Mp = {}
        BfBot.Theme = {}
        BfBot._Warn = function(_) end
        """
    )
    runtime.execute(LOC_SOURCE)
    runtime.execute(PERSIST_SOURCE)
    runtime.execute(
        """
        local party = {
            [0] = { m_id = 100, name = "Aerie" },
            [1] = { m_id = 101, name = "Imoen" },
        }

        BfBot.Exec = {
            _ResolveCaster = function(ref)
                return { m_id = ref.oid, name = ref.name }
            end,
        }
        BfBot._GetName = function(sprite) return sprite and sprite.name or "" end
        BfBot._SafeCallback = function(_, callback) return callback end

        EEex_Sprite_GetInPortrait = function(slot) return party[slot] end
        Infinity_PushMenu = function(_) end
        Infinity_PopMenu = function(_) end
        """
    )
    runtime.execute(UI_SOURCE)
    runtime.execute(_SPL_HELPERS)
    return runtime


@pytest.fixture
def persist_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        BfBot = {
            MAX_PRESETS = 8,
            MAX_SPELL_REPEATS = 5,
            Scan = {}, Class = {}, Innate = {}, Mp = {},
            _Warn = function(_) end,
            _StripColorEscape = function(s) return s end,
        }
        """
    )
    runtime.execute("io = nil")
    runtime.execute(LOC_SOURCE)
    runtime.execute(PERSIST_SOURCE)
    return runtime


@pytest.fixture
def exec_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute("io = nil")
    runtime.execute(CORE_SOURCE)
    runtime.execute(CLASS_SOURCE)
    runtime.execute(
        """
        BfBot.Scan = {}
        BfBot.Innate = {}
        BfBot.Mp = {}
        BfBot._OpenLogAppend = function(_) end
        BfBot._CloseLog = function() end
        BfBot._Print = function(_) end
        BfBot._GetName = function(sprite)
            if type(sprite) == "table" then return sprite.name or "?" end
            return tostring(sprite)
        end
        EEex_BAnd = function() return 0 end
        """
    )
    runtime.execute(LOC_SOURCE)
    runtime.execute(PERSIST_SOURCE)
    runtime.execute(EXEC_SOURCE)
    return runtime


# ---------------------------------------------------------------- classifier


def test_resource_targeting_reads_every_ability_of_the_resource(
    class_lua: LuaRuntime,
) -> None:
    facts = class_lua.execute(
        """
        local function flags(targetTypes)
            local t = BfBot.Class.GetResourceTargeting(
                BfBot_TestSpl(targetTypes))
            return { selfOnly = t.isSelfOnly, aoe = t.isAoE,
                     default = t.defaultTarget }
        end
        return {
            -- SPWI422's op-214 wrapper: caster-only, instant
            wrapper = flags({ 7 }),
            -- its ProFire variant (spwi319): 14 single-creature abilities
            variant = flags({ 1, 1, 1, 1 }),
            -- party-wide buff
            partyWide = flags({ 4 }),
            -- mixed: one creature-targeting ability is enough to unlock
            mixed = flags({ 5, 1 }),
            -- every ability caster-only
            allSelf = flags({ 5, 7, 5 }),
        }
        """
    )

    assert dict(facts["wrapper"]) == {"selfOnly": 1, "aoe": 0, "default": "s"}
    assert dict(facts["variant"]) == {"selfOnly": 0, "aoe": 0, "default": "s"}
    assert dict(facts["partyWide"]) == {"selfOnly": 0, "aoe": 1, "default": "p"}
    assert dict(facts["mixed"]) == {"selfOnly": 0, "aoe": 0, "default": "s"}
    assert dict(facts["allSelf"]) == {"selfOnly": 1, "aoe": 0, "default": "s"}


def test_resource_targeting_falls_back_to_ability_zero_then_reports_unknown(
    class_lua: LuaRuntime,
) -> None:
    facts = class_lua.execute(
        """
        -- abilityCount unreadable (mod-written header, EEex binding change):
        -- the first ability still decides.
        local countless = {
            abilityCount = nil,
            getAbility = function(_, index)
                if index == 0 then return { actionType = 1 } end
                return nil
            end,
        }
        -- Nothing readable at all: no verdict, so the caller keeps its own.
        local opaque = {
            abilityCount = 2,
            getAbility = function() error("bad pointer") end,
        }
        local fallback = BfBot.Class.GetResourceTargeting(countless)
        return {
            fallbackSelfOnly = fallback.isSelfOnly,
            opaqueUnknown = BfBot.Class.GetResourceTargeting(opaque) == nil,
            nilUnknown = BfBot.Class.GetResourceTargeting(nil) == nil,
        }
        """
    )

    assert facts["fallbackSelfOnly"] == 0
    assert facts["opaqueUnknown"]
    assert facts["nilUnknown"]


def test_find_variant_matches_resrefs_case_insensitively(
    class_lua: LuaRuntime,
) -> None:
    facts = class_lua.execute(
        """
        local variants = {
            { resref = "SPWI319", name = "Protection From Fire" },
            { resref = "spwi320", name = "Protection From Cold" },
        }
        return {
            lowerQuery = BfBot.Class.FindVariant(variants, "spwi319").name,
            upperQuery = BfBot.Class.FindVariant(variants, "SPWI320").name,
            missing = BfBot.Class.FindVariant(variants, "SPWI999") == nil,
            noList = BfBot.Class.FindVariant(nil, "SPWI319") == nil,
            noResref = BfBot.Class.FindVariant(variants, "") == nil,
        }
        """
    )

    assert facts["lowerQuery"] == "Protection From Fire"
    assert facts["upperQuery"] == "Protection From Cold"
    assert facts["missing"]
    assert facts["noList"]
    assert facts["noResref"]


def test_detected_variants_carry_their_own_target_shape(
    class_lua: LuaRuntime,
) -> None:
    """SPWI422 ("Protection from Elemental Energy") reference layout:
    a caster-only op-214 wrapper over single-creature protection spells."""
    facts = class_lua.execute(
        """
        local subSpells = {
            SPWI319 = BfBot_TestSpl({ 1, 1 }),   -- ProFire: one creature
            SPWI320 = BfBot_TestSpl({ 4 }),      -- synthetic party-wide variant
            -- SPWI512 deliberately absent: an unreadable variant must report
            -- no verdict instead of a guessed one.
        }
        EEex_Resource_Demand = function(resref, kind)
            assert(kind == "SPL")
            local header = subSpells[resref]
            if not header then error("missing " .. resref) end
            return header
        end
        local rows = {
            { label = "ProFire", resref = "SPWI319" },
            { label = "ProCold", resref = "SPWI320" },
            { label = "ProElec", resref = "SPWI512" },
        }
        EEex_Resource_Load2DA = function(name)
            assert(name == "DVWI426")
            return {
                getDimensions = function() return 1, #rows end,
                getAtPoint = function(_, _, y) return rows[y + 1].resref end,
                getRowLabel = function(_, y) return rows[y + 1].label end,
            }
        end
        BfBot.Class._GetFeatureBlock = function()
            return {
                effectID = 214,
                res = { get = function() return "DVWI426" end },
            }
        end

        local parent = BfBot_TestSpl({ 5 })
        local variants = BfBot.Class._DetectVariants(
            parent, { effectCount = 1, actionType = 5 })
        local out = {}
        for _, variant in ipairs(variants) do
            out[variant.label] = {
                selfOnly = variant.isSelfOnly,
                aoe = variant.isAoE,
                default = variant.defaultTarget,
                unknown = variant.isSelfOnly == nil,
            }
        end
        out.count = #variants
        return out
        """
    )

    assert facts["count"] == 3
    assert dict(facts["ProFire"]) == {
        "selfOnly": 0, "aoe": 0, "default": "s", "unknown": False,
    }
    assert dict(facts["ProCold"]) == {
        "selfOnly": 0, "aoe": 1, "default": "p", "unknown": False,
    }
    assert dict(facts["ProElec"]) == {"unknown": True}


# ------------------------------------------------------------------ UI rows


def test_spell_row_targeting_follows_the_selected_variant(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        local castable = {
            SPWI422 = {
                name = "Protection from Elemental Energy", icon = "",
                count = 1, duration = 0, durCat = "short", kind = "spl",
                -- as classified from the op-214 wrapper ability
                isSelfOnly = 1, isAoE = 0, hasVariants = 1,
                variants = {
                    { resref = "SPWI319", name = "Fire",
                      isSelfOnly = 0, isAoE = 0, defaultTarget = "s" },
                    { resref = "SPWI320", name = "Cold",
                      isSelfOnly = 0, isAoE = 1, defaultTarget = "p" },
                },
            },
        }
        local function rowFor(var)
            local preset = { spells = { SPWI422 = {
                on = 1, tgt = "p", pri = 1, rep = 1, var = var,
            } } }
            local rows = BfBot.UI._BuildSpellRows(
                { m_id = 1, name = "Planetar" }, preset, castable, nil)
            return rows[1]
        end
        local noVariant = rowFor(nil)
        local creature = rowFor("spwi319")
        local partyWide = rowFor("SPWI320")
        return {
            wrapperSelfOnly = noVariant.isSelfOnly,
            wrapperAoE = noVariant.isAoE,
            creatureSelfOnly = creature.isSelfOnly,
            creatureAoE = creature.isAoE,
            creatureName = creature.variantName,
            partyWideSelfOnly = partyWide.isSelfOnly,
            partyWideAoE = partyWide.isAoE,
        }
        """
    )

    # No variant chosen yet → the wrapper's own verdict stands.
    assert facts["wrapperSelfOnly"] == 1
    assert facts["wrapperAoE"] == 0
    # Variant chosen → its target shape wins, so the picker is no longer locked.
    assert facts["creatureSelfOnly"] == 0
    assert facts["creatureAoE"] == 0
    assert facts["creatureName"] == "Fire"
    assert facts["partyWideSelfOnly"] == 0
    assert facts["partyWideAoE"] == 1


def test_spell_row_keeps_the_parent_verdict_when_the_variant_is_unreadable(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        local castable = {
            PARENT = {
                name = "Menu Spell", icon = "", count = 1, duration = 0,
                durCat = "short", kind = "spl",
                isSelfOnly = 1, isAoE = 0, hasVariants = 1,
                variants = {
                    -- SPL could not be loaded: no targeting fields at all
                    { resref = "GONE", name = "Gone" },
                },
            },
        }
        local preset = { spells = { PARENT = {
            on = 1, tgt = "s", pri = 1, rep = 1, var = "GONE",
        } } }
        local rows = BfBot.UI._BuildSpellRows(
            { m_id = 1, name = "Planetar" }, preset, castable, nil)
        return {
            selfOnly = rows[1].isSelfOnly,
            aoe = rows[1].isAoE,
            variantName = rows[1].variantName,
        }
        """
    )

    assert facts["selfOnly"] == 1
    assert facts["aoe"] == 0
    assert facts["variantName"] == "Gone"


# -------------------------------------------------------------- target picker


_SUMMON_PICKER_WORLD = """
BfBot.UI._view = "summons"
BfBot.UI._presetIdx = 1
BfBot.UI._summonSel = {
    identity = "cre:planetar", cloneType = 0, oid = 200, name = "Planetar",
}
BfBot.UI._summonList = { {
    identity = "cre:planetar", cloneType = 0, oid = 200, name = "Planetar",
} }
buffbot_isOpen = true
buffbot_charNames = { "Aerie", "Imoen" }

BfBot_TestSummonPreset = { qc = 0, spells = { SPWI422 = {
    on = 1, tgt = "s", pri = 1, rep = 1, var = "SPWI319",
} } }
BfBot.Persist.PeekSummonPreset = function(identity, presetIdx)
    assert(identity == "cre:planetar" and presetIdx == 1)
    return BfBot_TestSummonPreset
end
BfBot.Persist.SetSpellTarget = function()
    error("summons view must not write through the party setter")
end
BfBot.Persist.SetTgtUnlock = function()
    error("summons view must not write through the party setter")
end
"""


def test_summons_view_unlocks_a_variant_row_and_persists_ordered_names(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        _SUMMON_PICKER_WORLD
        + """
        -- Row as the UI builds it for a variant whose own target type is
        -- caster-only (a genuinely self-only variant): locked on open.
        buffbot_spellTable = { {
            resref = "SPWI422", name = "Protection from Elemental Energy",
            tgt = "s", isSelfOnly = 1, isAoE = 0, tgtUnlock = 0,
            hasVariants = 1, var = "SPWI319",
        } }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)
        BfBot.UI.OpenTargets(1)
        local lockedOnOpen = buffbot_targetLocked

        BfBot.UI.PickerUnlock()
        local lockedAfterUnlock = buffbot_targetLocked
        local storedUnlock = BfBot_TestSummonPreset.spells.SPWI422.tgtUnlock

        -- Imoen first, then Aerie: picker order is cast priority.
        BfBot.UI.PickerToggle(1)
        BfBot.UI.PickerToggle(2)
        BfBot.UI.PickerSelect(2)
        BfBot.UI.PickerMoveUp()
        BfBot.UI.PickerDone()

        local stored = BfBot_TestSummonPreset.spells.SPWI422.tgt
        local names = {}
        if type(stored) == "table" then
            for _, name in ipairs(stored) do names[#names + 1] = name end
        end
        return {
            lockedOnOpen = lockedOnOpen,
            lockedAfterUnlock = lockedAfterUnlock,
            storedUnlock = storedUnlock,
            storedIsTable = type(stored) == "table",
            names = table.concat(names, ","),
            rowTarget = buffbot_spellTable[1].tgt,
            anchorCleared = BfBot.UI._targetSpellAnchor == nil,
        }
        """
    )

    assert facts["lockedOnOpen"] == 1
    assert facts["lockedAfterUnlock"] == 0
    assert facts["storedUnlock"] == 1
    assert facts["storedIsTable"]
    assert facts["names"] == "Imoen,Aerie"
    assert facts["anchorCleared"]


def test_summons_view_picker_offers_the_party_and_self_only(
    ui_lua: LuaRuntime,
) -> None:
    """A summon is a caster, never a recipient: the ordered list holds party
    members, and "buff the summon" is expressed by Self (tgt = "s")."""
    facts = ui_lua.execute(
        _SUMMON_PICKER_WORLD
        + """
        buffbot_spellTable = { {
            resref = "SPWI422", name = "Protection from Elemental Energy",
            tgt = "Aerie", isSelfOnly = 0, isAoE = 0, tgtUnlock = 0,
            hasVariants = 1, var = "SPWI319",
        } }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)
        BfBot.UI.OpenTargets(1)

        local order = {}
        for _, name in ipairs(buffbot_pickerOrder) do
            order[#order + 1] = name
        end
        BfBot.UI.PickerSelf()
        return {
            locked = buffbot_targetLocked,
            order = table.concat(order, ","),
            checkedAerie = buffbot_pickerChecked.Aerie,
            storedAfterSelf = BfBot_TestSummonPreset.spells.SPWI422.tgt,
        }
        """
    )

    assert facts["locked"] == 0
    assert facts["order"] == "Aerie,Imoen"
    assert facts["checkedAerie"] == 1
    assert facts["storedAfterSelf"] == "s"


@pytest.mark.parametrize("view", ["party", "summons"])
def test_done_on_a_still_locked_row_keeps_the_stored_target(
    ui_lua: LuaRuntime, view: str,
) -> None:
    """Every control that could check a name is disabled while locked, so the
    empty working copy carries no intent and must not overwrite the config."""
    facts = ui_lua.execute(
        _SUMMON_PICKER_WORLD
        + """
        BfBot.UI._view = "__VIEW__"
        local partyWrites = 0
        BfBot.Persist.SetSpellTarget = function() partyWrites = partyWrites + 1 end
        BfBot.UI._charSlot = 0
        buffbot_spellTable = { {
            resref = "SPWI422", name = "Menu Spell", tgt = "Aerie",
            isSelfOnly = 1, isAoE = 0, tgtUnlock = 0, hasVariants = 1,
        } }
        buffbot_selectedRow = 1
        BfBot.UI._OnSpellRowAction(3)
        BfBot.UI.OpenTargets(1)
        local popped = nil
        Infinity_PopMenu = function(name) popped = name end
        BfBot.UI.PickerDone()
        return {
            locked = buffbot_targetLocked,
            partyWrites = partyWrites,
            storedTarget = BfBot_TestSummonPreset.spells.SPWI422.tgt,
            rowTarget = buffbot_spellTable[1].tgt,
            popped = popped,
            anchorCleared = BfBot.UI._targetSpellAnchor == nil,
        }
        """.replace("__VIEW__", view)
    )

    assert facts["locked"] == 1
    assert facts["partyWrites"] == 0
    assert facts["storedTarget"] == "s"  # untouched seed value
    assert facts["rowTarget"] == "Aerie"
    assert facts["popped"] == "BUFFBOT_TARGETS"
    assert facts["anchorCleared"]


def test_unlock_button_is_gated_on_the_lock_alone() -> None:
    marker = 'action  "BfBot.UI.PickerUnlock()"'
    block_start = MENU_SOURCE.rindex("button", 0, MENU_SOURCE.index(marker))
    block = MENU_SOURCE[block_start : MENU_SOURCE.index(marker)]
    enabled = re.search(r'enabled\s+"([^"]+)"', block)
    assert enabled is not None
    assert enabled.group(1).strip() == "buffbot_targetLocked == 1"


# ----------------------------------------------------------------- persistence


def test_summon_schema_keeps_tgtunlock_and_still_rejects_foreign_keys(
    persist_lua: LuaRuntime,
) -> None:
    facts = persist_lua.execute(
        """
        local config = {
            v = 10, ap = 1,
            presets = { [1] = {
                name = "Party", cat = "custom", qc = 0,
                spells = { PARTY = {
                    kind = "spl", on = 1, tgt = "s", pri = 1, rep = 1,
                    lock = 0, tgtUnlock = "yes",
                } },
            } },
            opts = { skip = 1 },
            ovr = {},
            summons = { ["cre:planetar"] = { presets = { [1] = {
                qc = 0,
                spells = {
                    KEPT = {
                        on = 1, tgt = "Aerie", pri = 1, rep = 1,
                        tgtUnlock = 1,
                    },
                    BOGUS = {
                        on = 1, tgt = "s", pri = 2, rep = 1,
                        tgtUnlock = 7, kind = "itm", lock = 1,
                    },
                    PLAIN = { on = 1, tgt = "s", pri = 3, rep = 1 },
                },
            } } } },
        }
        local clean = BfBot.Persist._ValidateConfig(config)
        local spells = clean.summons["cre:planetar"].presets[1].spells
        return {
            keptUnlock = spells.KEPT.tgtUnlock,
            bogusUnlock = spells.BOGUS.tgtUnlock,
            bogusKind = spells.BOGUS.kind,
            bogusLock = spells.BOGUS.lock,
            plainUnlock = spells.PLAIN.tgtUnlock,
            partyUnlock = clean.presets[1].spells.PARTY.tgtUnlock,
        }
        """
    )

    assert facts["keptUnlock"] == 1
    assert facts["bogusUnlock"] == 0
    assert facts["bogusKind"] is None   # summon presets stay spell-only
    assert facts["bogusLock"] is None   # and keep no party-only lock field
    assert facts["plainUnlock"] is None  # optional: absent stays absent
    assert facts["partyUnlock"] == 0    # party path normalizes garbage too


def test_clone_seeding_carries_the_owner_unlock_with_the_copied_target(
    persist_lua: LuaRuntime,
) -> None:
    facts = persist_lua.execute(
        """
        local ownerPreset = { spells = {
            UNLOCKED = {
                kind = "spl", on = 1, tgt = { "Aerie", "Imoen" }, pri = 1,
                rep = 2, tgtUnlock = 1, lock = 1,
            },
            LOCKED = {
                kind = "spl", on = 1, tgt = "s", pri = 2, rep = 1,
            },
        } }
        local castable = {
            UNLOCKED = { count = 1, kind = "spl" },
            LOCKED = { count = 1, kind = "spl" },
        }
        local seeded = BfBot.Persist._SeedCloneSpells(ownerPreset, castable)
        local names = {}
        for _, name in ipairs(seeded.UNLOCKED.tgt) do
            names[#names + 1] = name
        end
        return {
            unlocked = seeded.UNLOCKED.tgtUnlock,
            locked = seeded.LOCKED.tgtUnlock,
            names = table.concat(names, ","),
            aliased = seeded.UNLOCKED.tgt == ownerPreset.spells.UNLOCKED.tgt,
            kindLeaked = seeded.UNLOCKED.kind,
            lockLeaked = seeded.UNLOCKED.lock,
        }
        """
    )

    assert facts["unlocked"] == 1
    assert facts["locked"] is None
    assert facts["names"] == "Aerie,Imoen"
    assert not facts["aliased"]
    assert facts["kindLeaked"] is None
    assert facts["lockLeaked"] is None


# ------------------------------------------------------------------ execution


@pytest.mark.parametrize(
    ("variant_aoe", "expected"),
    [(0, "Player1,Player2"), (1, "Myself")],
)
def test_variant_target_type_decides_how_all_expands(
    exec_lua: LuaRuntime, variant_aoe: int, expected: str,
) -> None:
    """The op-214 wrapper is caster-only, so its classification says "not
    AoE". A party-wide VARIANT must still resolve to a single area cast."""
    sequence = exec_lua.execute(
        """
        local sprites = {
            { name = "A", m_id = 100 },
            { name = "B", m_id = 101 },
        }
        BfBot.Exec._ResolveCaster = function() return sprites[1] end
        BfBot.Exec._IsAlive = function(sprite) return sprite ~= nil end
        BfBot.Scan.Invalidate = function() end
        BfBot.Scan.GetCastableSpells = function()
            return { SPWI422 = {
                count = 1, name = "Menu Spell", durCat = "short",
                class = { isAoE = false, splstates = {} },
                variants = { { resref = "SPWI319", name = "Fire",
                               isSelfOnly = 0, isAoE = __AOE__ } },
            } }
        end
        EEex_Sprite_GetInPortrait = function(slot)
            return sprites[slot + 1]
        end
        EEex_Sprite_GetCharacterIndex = function(sprite)
            if sprite == sprites[1] then return 0 end
            return 1
        end

        local byCaster = assert(BfBot.Exec._BuildQueue({
            { caster = 0, spell = "SPWI422", target = "all",
              var = "SPWI319", rep = 1 },
        }, 0))
        local out = {}
        for _, entry in ipairs(byCaster.p0) do
            out[#out + 1] = entry.targetObj
        end
        return table.concat(out, ",")
        """.replace("__AOE__", str(variant_aoe))
    )

    assert sequence == expected
