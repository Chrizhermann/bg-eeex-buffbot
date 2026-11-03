"""A summon can be the RECIPIENT of a cast (#117).

Until now summons were casters only: they could buff the party and
themselves, and nothing could buff them. A cleric could not put Stoneskin on
the Planetar standing next to him, which with a plannable Simulacrum (#107)
makes a caster nobody can protect.

BCS cannot name a specific creature. EEex can, through OBJECT.IDS 117
`EEex_Target("key")`, which resolves at action-evaluation time from a table on
the caster's own UDAux. Six lab runs on BG2:EE 2.7.3.0 + EEex 1.3.1
(`tools/lab_summon_target.py`) measured what that mechanism will and will not
do, and every rule below is one of those measurements:

  * a FORCED cast through `EEex_Target` lands on an allied summon;
  * `SpellRES` through it never completes and jams the caster beyond
    `virtual_ClearActions(false)` -- so the forced action is not a preference,
    it is the only one, and BuffBot debits the slot itself because the forced
    action does not;
  * an unresolvable key is a clean skip: the queue advances on its own;
  * two keys on one caster resolve independently, so one key is enough.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CORE_SOURCE = (ROOT / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")
LOC_SOURCE = (ROOT / "buffbot/BfBotLoc.lua").read_text(encoding="utf-8")
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")
EXEC_SOURCE = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")


_WORLD = r"""
T_Actions, T_Stored, T_Log, T_Consumed = {}, {}, {}, {}
T_Summons = {}
T_Allied = true
T_SlotAvailable = true

local caster = { name = "Cleric", m_id = 7,
                 m_baseStats = { m_generalState = 0 }, m_timedEffectList = {} }
local member = { name = "Fighter", m_id = 8,
                 m_baseStats = { m_generalState = 0 }, m_timedEffectList = {} }

function T_Caster() return caster end
function T_Member() return member end

--- A summon as the live discovery reports it: identity, object id, name and
--- the sprite. Returned tables are read-only by contract, so the code under
--- test must not sort or mutate them.
function T_Summon(identity, oid, name)
    local sprite = { name = name, m_id = oid,
                     m_baseStats = { m_generalState = 0 },
                     m_timedEffectList = {} }
    T_Summons[#T_Summons + 1] = {
        identity = identity, oid = oid, name = name, sprite = sprite,
    }
    return sprite
end

function T_ClearSummons() T_Summons = {} end

EEex_Utility_IterateCPtrList = function(list, fn)
    for _, v in ipairs(list) do if fn(v) then return end end
end
EEex_BAnd = function() return 0 end

EEex_Sprite_GetInPortrait = function(slot)
    if slot == 0 then return caster end
    if slot == 1 then return member end
    return nil
end
EEex_Sprite_GetCharacterIndex = function(sprite)
    return sprite == caster and 0 or 1
end

EEex_Action_QueueResponseStringOnAIBase = function(action, sprite)
    T_Actions[#T_Actions + 1] = { action = action, sprite = sprite }
end

EEex_AIBase_SetStoredScriptingTarget = function(aiBase, key, target)
    T_Stored[#T_Stored + 1] = { aiBase = aiBase, key = key, target = target }
end
EEex_AIBase_GetStoredScriptingTarget = function(aiBase, key)
    for i = #T_Stored, 1, -1 do
        if T_Stored[i].aiBase == aiBase and T_Stored[i].key == key then
            return T_Stored[i].target
        end
    end
    return nil
end

BfBot.Scan.GetAlliedSummons = function() return T_Summons end
BfBot.Scan.GetCastableSpells = function() return {}, 0 end
BfBot.Scan.Invalidate = function() end

BfBot.Exec._IsAlive = function(sprite) return sprite ~= nil end
BfBot.Exec._SummonStillAllied = function() return T_Allied end
BfBot.Exec._ConsumeSpellSlot = function(sprite, resref)
    T_Consumed[#T_Consumed + 1] = { sprite = sprite, resref = resref }
    return T_SlotAvailable
end
BfBot.Exec._LogEntry = function(level, message)
    T_Log[#T_Log + 1] = { level = level, message = message }
end
BfBot.Exec._ResolveCaster = function(ref)
    if ref.kind == "party" then return EEex_Sprite_GetInPortrait(ref.slot) end
    for _, summon in ipairs(T_Summons) do
        if summon.oid == ref.oid then return summon.sprite end
    end
    return nil
end

--- Drive exactly one entry through the cast dispatch.
---
--- The surrounding loop is replaced: what matters here is which action
--- reaches the engine for a summon recipient, not the scheduling around it.
function T_Cast(entry)
    T_Actions, T_Stored, T_Log, T_Consumed = {}, {}, {}, {}
    BfBot.Exec._state = "running"
    BfBot.Exec._castCount, BfBot.Exec._skipCount = 0, 0
    BfBot.Exec._casters = { p0 = {
        ref = { kind = "party", slot = 0 }, name = "Cleric",
        entries = { entry }, index = 1, cheatBoundary = 0,
        advanceToken = nil,
    } }
    -- Stop the recursion at the next entry: this drives one cast.
    local advanced = 0
    local real = BfBot.Exec._ProcessCasterEntry
    BfBot.Exec._ProcessCasterEntry = function(key, index)
        if index > 1 then advanced = advanced + 1 return end
        return real(key, index)
    end
    local ok, err = pcall(real, "p0", 1)
    BfBot.Exec._ProcessCasterEntry = real
    return {
        ok = ok, err = tostring(err), advanced = advanced,
        casts = BfBot.Exec._castCount, skips = BfBot.Exec._skipCount,
    }
end

--- The queue entry a summon recipient produces, as the builder would make it.
---
--- Overrides are applied with `pairs`, which cannot carry a nil -- so this
--- builder can never be turned into a party entry by nilling fields. Use
--- `T_PartyEntry` for that; three tests once claimed to be about party
--- recipients while silently asserting about summon ones.
function T_Entry(overrides)
    local entry = {
        casterRef = { kind = "party", slot = 0 },
        casterName = "Cleric",
        resref = "SPPR201", kind = "spl", spellName = "Barkskin",
        targetObj = 'EEex_Target("' .. BfBot.Exec.SUMMON_TARGET_KEY .. '")',
        targetName = "Planetar",
        targetRef = { kind = "summon", oid = 4242, name = "Planetar" },
        targetIsSummon = true,
        splstates = {}, rep = 1,
    }
    for key, value in pairs(overrides or {}) do entry[key] = value end
    return entry
end

--- The same entry aimed at a party member: built from nothing, so no summon
--- field can survive into it.
function T_PartyEntry(overrides)
    local entry = {
        casterRef = { kind = "party", slot = 0 },
        casterName = "Cleric",
        resref = "SPPR201", kind = "spl", spellName = "Barkskin",
        targetObj = "Player2", targetName = "Fighter", targetSlot = 1,
        splstates = {}, rep = 1,
    }
    for key, value in pairs(overrides or {}) do entry[key] = value end
    return entry
end
"""


@pytest.fixture
def lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute("io = nil")
    runtime.execute(CORE_SOURCE)
    runtime.execute(
        "BfBot.Scan = BfBot.Scan or {}\n"
        "BfBot.Class = BfBot.Class or {}\n"
        "BfBot.Innate = BfBot.Innate or {}\n"
        "BfBot.Mp = BfBot.Mp or {}\n"
    )
    runtime.execute(LOC_SOURCE)
    runtime.execute(PERSIST_SOURCE)
    runtime.execute(EXEC_SOURCE)
    runtime.execute(_WORLD)
    return runtime


def _actions(lua: LuaRuntime) -> list[str]:
    return [str(row["action"]) for row in lua.eval("T_Actions").values()]


def _log(lua: LuaRuntime) -> list[tuple[str, str]]:
    return [(str(row["level"]), str(row["message"]))
            for row in lua.eval("T_Log").values()]


# ----------------------------------------------------------------------
# The target form
# ----------------------------------------------------------------------
#
# A summon identity is `clone:<owner>`, `cre:<resref>`, `name:<name>` -- or,
# for a non-clone with a script name, the BARE script name. `tgt` already
# holds character names, so that one form would be indistinguishable from a
# character called the same thing. Hence an explicit prefix.


def test_only_the_prefix_marks_a_summon_target(lua: LuaRuntime) -> None:
    assert lua.eval('BfBot.Exec._IsSummonTarget("sum:clone:Jaheira")') is True
    assert lua.eval('BfBot.Exec._IsSummonTarget("clone:Jaheira")') is False
    assert lua.eval('BfBot.Exec._IsSummonTarget("s")') is False
    assert lua.eval('BfBot.Exec._IsSummonTarget("p")') is False
    assert lua.eval('BfBot.Exec._IsSummonTarget(3)') is False
    assert lua.eval("BfBot.Exec._IsSummonTarget(nil)") is False


def test_a_character_named_like_a_summons_script_name_is_not_one(
        lua: LuaRuntime) -> None:
    """The bare-script-name identity form is why the prefix exists: a
    character called "skeleton" must stay a character."""
    assert lua.eval('BfBot.Exec._IsSummonTarget("skeleton")') is False
    assert lua.eval('BfBot.Exec._IsSummonTarget("sum:skeleton")') is True


def test_the_identity_comes_back_out(lua: LuaRuntime) -> None:
    assert lua.eval(
        'BfBot.Exec._SummonTargetIdentity("sum:cre:planetar")'
    ) == "cre:planetar"
    assert lua.eval(
        'BfBot.Exec._SummonTargetIdentity("sum:clone:Jaheira")'
    ) == "clone:Jaheira"


def test_a_target_naming_no_summon_resolves_to_none(lua: LuaRuntime) -> None:
    """An empty identity must not mean "the first summon in the list"."""
    assert lua.eval('BfBot.Exec._SummonTargetIdentity("sum:")') is None
    assert lua.eval('BfBot.Exec._SummonTargetIdentity("Minsc")') is None


def test_the_target_value_round_trips(lua: LuaRuntime) -> None:
    assert lua.eval("""
        BfBot.Exec._SummonTargetIdentity(
            BfBot.Exec.SummonTarget("clone:Jaheira"))
    """) == "clone:Jaheira"
    assert lua.eval('BfBot.Exec.SummonTarget("")') is None
    assert lua.eval("BfBot.Exec.SummonTarget(nil)") is None


# ----------------------------------------------------------------------
# Resolution
# ----------------------------------------------------------------------


def test_a_summon_target_resolves_to_that_summon(lua: LuaRuntime) -> None:
    lua.execute('T_Summon("cre:planetar", 4242, "Planetar")')
    row = lua.eval("""
        (function()
            local t = BfBot.Exec._ResolveTargets(
                "sum:cre:planetar", T_Caster(), 0, false)
            return t[1]
        end)()
    """)
    assert row["targetIsSummon"] is True
    assert str(row["targetName"]) == "Planetar"
    assert row["targetRef"]["kind"] == "summon"
    assert row["targetRef"]["oid"] == 4242


def test_the_target_object_is_the_stored_key_not_a_player_slot(
        lua: LuaRuntime) -> None:
    """`EEex_Target` is the only BCS object that can name a creature which is
    not in the party, and the key has to be the one the cast stores."""
    lua.execute('T_Summon("cre:planetar", 4242, "Planetar")')
    obj = lua.eval("""
        BfBot.Exec._ResolveTargets(
            "sum:cre:planetar", T_Caster(), 0, false)[1].targetObj
    """)
    key = str(lua.eval("BfBot.Exec.SUMMON_TARGET_KEY"))
    assert str(obj) == f'EEex_Target("{key}")'


def test_one_summon_target_is_one_cast_even_among_several(
        lua: LuaRuntime) -> None:
    lua.execute("""
        T_Summon("cre:planetar", 4242, "Planetar")
        T_Summon("cre:skeleton", 99, "Skeleton")
    """)
    count = lua.eval("""
        #BfBot.Exec._ResolveTargets("sum:cre:skeleton", T_Caster(), 0, false)
    """)
    name = lua.eval("""
        BfBot.Exec._ResolveTargets(
            "sum:cre:skeleton", T_Caster(), 0, false)[1].targetName
    """)
    assert count == 1
    assert str(name) == "Skeleton"


def test_a_summon_that_is_gone_says_so_instead_of_failing(
        lua: LuaRuntime) -> None:
    """A summon expires on its own schedule. That is churn, not a fault, and
    the reason lets the builder log it as such."""
    targets, reason = lua.eval("""
        (function()
            local t, why = BfBot.Exec._ResolveTargets(
                "sum:cre:planetar", T_Caster(), 0, false)
            return { n = #t }, why
        end)()
    """)
    assert targets["n"] == 0
    assert str(reason) == "summon gone"


def test_a_party_recipient_keeps_its_silence(lua: LuaRuntime) -> None:
    """Only the summon branch explains itself; an ordinary target returns no
    reason, so the builder's existing error for a missing member stands."""
    _, reason = lua.eval("""
        (function()
            local t, why = BfBot.Exec._ResolveTargets(6, T_Caster(), 0, false)
            return #t, why
        end)()
    """)
    assert reason is None


def test_all_still_means_the_party(lua: LuaRuntime) -> None:
    """"All" is a statement about the party. A summon is reached by naming
    it, never by a party-wide cast picking it up."""
    lua.execute('T_Summon("cre:planetar", 4242, "Planetar")')
    names = lua.eval("""
        (function()
            local out = {}
            for _, t in ipairs(BfBot.Exec._ResolveTargets(
                    "all", T_Caster(), 0, false)) do
                out[#out + 1] = t.targetName
            end
            return table.concat(out, ",")
        end)()
    """)
    assert "Planetar" not in str(names)


# ----------------------------------------------------------------------
# The cast
# ----------------------------------------------------------------------
#
# `_PlanCast` is a pure function of the entry, so these need no engine.


def _plan(lua: LuaRuntime, overrides: str = "{}") -> dict:
    return lua.eval(f"BfBot.Exec._PlanCast(T_Entry({overrides}))")


def test_a_summon_recipient_is_force_cast(lua: LuaRuntime) -> None:
    """Measured: `SpellRES` at `EEex_Target` never completes and jams the
    caster past `virtual_ClearActions(false)`. The forced action lands."""
    plan = _plan(lua)
    assert str(plan["action"]) == "ReallyForceSpellRES"
    assert str(plan["resref"]) == "SPPR201"
    assert plan["refuse"] is None


def test_no_summon_entry_can_ever_be_planned_as_an_ordinary_cast(
        lua: LuaRuntime) -> None:
    """The jam is unrecoverable, so this is the test that matters most. Every
    shape an entry can take, with a summon recipient, must come back forced
    or refused -- never `SpellRES`, `SpellNoDecRES` or `Spell`."""
    shapes = (
        "{}",
        '{ var = "SPPR202" }',
        "{ cheat = 1 }",
        "{ rep = 3 }",
        '{ kind = "spl", var = "SPPR202", cheat = 1 }',
        '{ kind = "itm" }',
        '{ d5 = { wrapper = "D5Z101" } }',
        '{ resref = "SPWI204" }',
    )
    for shape in shapes:
        plan = _plan(lua, shape)
        action = plan["action"]
        if action is None:
            assert plan["refuse"] is not None, shape
            continue
        assert str(action) in ("ReallyForceSpellRES",), shape


def _party_plan(lua: LuaRuntime, overrides: str = "{}") -> dict:
    return lua.eval(f"BfBot.Exec._PlanCast(T_PartyEntry({overrides}))")


def test_the_party_paths_keep_the_actions_they_had(lua: LuaRuntime) -> None:
    """Nothing about the forced cast may leak into an ordinary buff: the
    four existing paths answer exactly what the dispatch used before."""
    assert str(_party_plan(lua)["action"]) == "SpellRES"
    assert str(_party_plan(
        lua, '{ var = "SPPR202" }')["action"]) == "SpellNoDecRES"
    assert str(_party_plan(lua, '{ kind = "itm" }')["action"]) == "item"
    assert str(_party_plan(
        lua, '{ d5 = { wrapper = "D5Z101" } }')["action"]) == "d5"


def test_the_slot_is_spent_by_hand_because_the_forced_action_will_not(
        lua: LuaRuntime) -> None:
    plan = _plan(lua)
    assert plan["needsSlot"] is True
    assert str(plan["slotResref"]) == "SPPR201"


def test_a_variant_at_a_summon_casts_the_variant_and_spends_the_parent(
        lua: LuaRuntime) -> None:
    plan = _plan(lua, '{ var = "SPPR202" }')
    assert str(plan["action"]) == "ReallyForceSpellRES"
    assert str(plan["resref"]) == "SPPR202"
    assert str(plan["slotResref"]) == "SPPR201"


def test_an_ordinary_party_cast_spends_nothing_by_hand(
        lua: LuaRuntime) -> None:
    """The engine debits it, and debiting twice would eat a second slot."""
    plan = _party_plan(lua)
    assert plan["needsSlot"] is None or plan["needsSlot"] is False


def test_a_summon_recipient_has_to_be_aimed_at_first(
        lua: LuaRuntime) -> None:
    """`EEex_Target` reads a store on the caster, written at cast time."""
    assert _plan(lua)["needsAim"] is True
    party = _party_plan(lua)
    assert party["needsAim"] is None or party["needsAim"] is False


def test_an_item_is_refused_at_a_summon_with_a_reason(
        lua: LuaRuntime) -> None:
    """`UseItemSlotAbility` was never measured against `EEex_Target`, and the
    ordinary spell action jams on it. A stated refusal beats a hope."""
    plan = _plan(lua, '{ kind = "itm" }')
    assert plan["action"] is None
    assert "item" in str(plan["refuse"]).lower()


def test_the_5e_wrapper_is_refused_at_a_summon(lua: LuaRuntime) -> None:
    plan = _plan(lua, '{ d5 = { wrapper = "D5Z101" } }')
    assert plan["action"] is None
    assert "5E" in str(plan["refuse"])


def test_a_malformed_entry_refuses_rather_than_guessing(
        lua: LuaRuntime) -> None:
    assert lua.eval("BfBot.Exec._PlanCast(nil).refuse") is not None
    assert lua.eval('BfBot.Exec._PlanCast("nonsense").refuse') is not None


# ----------------------------------------------------------------------
# Aiming
# ----------------------------------------------------------------------


def test_the_recipient_is_stored_on_the_caster_under_the_key(
        lua: LuaRuntime) -> None:
    """`EEex_Target` reads a table on the CASTER's own UDAux, so the store
    belongs on the caster."""
    lua.execute("""
        T_Summon("cre:planetar", 4242, "Planetar")
        T_Stored = {}
        T_Sprite = BfBot.Exec._AimAtSummon(T_Caster(), T_Entry())
    """)
    # Identity has to be compared inside Lua: two `eval`s of the same table
    # hand back different proxy objects.
    facts = lua.eval("""
        (function()
            local row = T_Stored[1]
            return {
                rows = #T_Stored,
                aimed = T_Sprite ~= nil,
                key = row and row.key,
                onCaster = row and row.aiBase == T_Caster(),
                isTheLiveSummon = row and row.target == T_Summons[1].sprite,
            }
        end)()
    """)
    assert facts["aimed"] is True
    assert facts["rows"] == 1
    assert str(facts["key"]) == str(lua.eval("BfBot.Exec.SUMMON_TARGET_KEY"))
    assert facts["onCaster"] is True
    assert facts["isTheLiveSummon"] is True


def test_the_recipient_is_resolved_again_rather_than_reused(
        lua: LuaRuntime) -> None:
    """Object ids are fresh per spawn and a queue is built frames before it
    runs, so the sprite stored is the one found NOW, not the one the builder
    saw. Here the build-time sprite is deliberately a different object."""
    facts = lua.eval("""
        (function()
            T_Summon("cre:planetar", 4242, "Planetar")
            T_Stored = {}
            local stale = { name = "Planetar", m_id = 4242 }
            BfBot.Exec._AimAtSummon(T_Caster(),
                T_Entry({ targetSprite = stale }))
            local row = T_Stored[1]
            return {
                reusedTheStaleOne = row and row.target == stale,
                tookTheLiveOne = row and row.target == T_Summons[1].sprite,
            }
        end)()
    """)
    assert facts["reusedTheStaleOne"] is False
    assert facts["tookTheLiveOne"] is True


def test_a_summon_that_vanished_before_the_cast_is_refused(
        lua: LuaRuntime) -> None:
    """The issue's own rule: a party member who leaves is reported, a summon
    that expires is ordinary churn. The caller logs this at INFO."""
    sprite, why = lua.eval("""
        (function()
            local s, w = BfBot.Exec._AimAtSummon(T_Caster(), T_Entry())
            return s, w
        end)()
    """)
    assert sprite is None
    assert "gone" in str(why)


def test_a_summon_that_turned_is_not_aimed_at(lua: LuaRuntime) -> None:
    """Allegiance is revalidated at the step, the same discipline the caster
    side uses: a charmed-away summon is somebody else's now."""
    lua.execute('T_Summon("cre:planetar", 4242, "Planetar")')
    lua.execute("T_Allied = false; T_Stored = {}")
    sprite, why = lua.eval("""
        (function()
            local s, w = BfBot.Exec._AimAtSummon(T_Caster(), T_Entry())
            return s, w
        end)()
    """)
    assert sprite is None
    assert "allied" in str(why)


def test_a_store_that_does_not_read_back_refuses_the_cast(
        lua: LuaRuntime) -> None:
    """A silent no-op store would send the cast at nobody -- which the engine
    skips quietly, so the run would report a cast that never happened."""
    lua.execute('T_Summon("cre:planetar", 4242, "Planetar")')
    lua.execute(
        "EEex_AIBase_GetStoredScriptingTarget = function() return nil end")
    sprite, why = lua.eval("""
        (function()
            local s, w = BfBot.Exec._AimAtSummon(T_Caster(), T_Entry())
            return s, w
        end)()
    """)
    assert sprite is None
    assert "read back" in str(why)


def test_a_throwing_store_is_a_refusal_not_a_crash(lua: LuaRuntime) -> None:
    lua.execute('T_Summon("cre:planetar", 4242, "Planetar")')
    lua.execute(
        'EEex_AIBase_SetStoredScriptingTarget = function() error("nope") end')
    sprite, why = lua.eval("""
        (function()
            local s, w = BfBot.Exec._AimAtSummon(T_Caster(), T_Entry())
            return s, w
        end)()
    """)
    assert sprite is None
    assert "store" in str(why)


def test_aiming_without_a_ref_refuses(lua: LuaRuntime) -> None:
    sprite, why = lua.eval("""
        (function()
            local s, w = BfBot.Exec._AimAtSummon(
                T_Caster(), T_Entry({ targetRef = nil }))
            return s, w
        end)()
    """)
    assert sprite is None
    assert why is not None


# ----------------------------------------------------------------------
# The structural guard
# ----------------------------------------------------------------------


def test_a_summon_recipient_is_the_first_branch_of_the_cast_dispatch() -> None:
    """Why this is a source test rather than a behavioural one: the branch
    ORDER is what makes the jam impossible. As long as `targetIsSummon` is
    tested before the item, 5E, variant and normal branches, no summon entry
    can reach `SpellRES` whatever else changes around it. Reorder it and this
    fails, instead of a player's caster locking up mid-run."""
    source = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")
    start = source.index("local advanceAction = _advanceAction(key, caster)")
    chain = source[start:start + 6000]
    conditions = [
        chain.index("if entry.targetIsSummon then"),
        chain.index('elseif entry.kind == "itm" then'),
        chain.index("elseif d5 then"),
        chain.index("elseif entry.var then"),
    ]
    assert conditions == sorted(conditions)


def test_the_dispatch_names_no_ordinary_spell_action_for_a_summon() -> None:
    """The summon branch's own body must not contain an ordinary spell
    action, however it is later edited."""
    source = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")
    start = source.index("if entry.targetIsSummon then")
    end = source.index('elseif entry.kind == "itm" then', start)
    branch = source[start:end]
    assert "SpellRES(" not in branch.replace("ReallyForceSpellRES(", "")
    assert "SpellNoDecRES(" not in branch
