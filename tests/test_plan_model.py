"""The shared plan model: identities, resource pools, allocation, migration.

Step 2 of issue #81. One plan, two projections — the caster view groups the
same requests by source, the recipient view by target. These tests pin the
parts that both views depend on and that a UI test cannot reach: which caster
a request lands on when several could cast it, what happens when a pool runs
dry, and that a per-character v10 preset migrates without losing depth.

The allocator is pure, so most of this needs no engine at all. `Snapshot`
does, and gets a stubbed party.
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
PLAN_SOURCE = (ROOT / "buffbot/BfBotPln.lua").read_text(encoding="utf-8")
PLAN_PATH = ROOT / "buffbot/BfBotPln.lua"


def plan_runtime() -> LuaRuntime:
    """Core, the real classifier and the real persistence, plus the planner.

    Persistence is the real module because `ExpandRequests` and `ImportLegacy`
    call into its repeat normalization and target resolution — the contract
    being tested is the one those functions actually have.
    """
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
        BfBot.Exec = { _IsAlive = function(_) return true end }
        BfBot._Warn = function(_) end
        """
    )
    runtime.execute(LOC_SOURCE)
    runtime.execute(PERSIST_SOURCE)
    runtime.execute(PLAN_SOURCE)
    return runtime


# A snapshot is plain data, so the tests build one directly rather than
# driving a stubbed party through `Snapshot` for every allocation case.
_SNAPSHOT_HELPERS = """
function TestSnapshot(spec)
    local snap = { actors = {}, order = {}, groups = {}, pools = {},
                   casterActors = {}, casters = {} }
    for slot, actor in ipairs(spec.actors or {}) do
        local entry = { key = actor.key, name = actor.name or actor.key,
                        slot = slot - 1, alive = actor.alive ~= false,
                        ambiguous = actor.ambiguous, controlled = true,
                        class = actor.class or 1,
                        casterRef = { kind = "party", slot = slot - 1 },
                        sprite = { m_id = slot } }
        snap.actors[actor.key] = entry
        snap.order[#snap.order + 1] = entry
        snap.casterActors[actor.key] = entry
        snap.casters[#snap.casters + 1] = entry
    end
    for _, group in ipairs(spec.groups or {}) do
        local sources = {}
        for _, s in ipairs(group.sources) do
            local actor = snap.actors[s.actor]
            sources[#sources + 1] = {
                id = s.id or (s.actor .. "/" .. group.key),
                actor = s.actor, pool = s.pool, reason = s.reason,
                duration = s.duration, casterLevel = s.casterLevel,
                selfOnly = s.selfOnly, aoe = s.aoe,
                variants = s.variants, variantDurations = s.variantDurations or {},
                itemSlot = s.itemSlot,
                slot = actor and actor.slot,
                casterRef = actor and actor.casterRef,
                row = s.row or { kind = "spl", resref = group.resref or "SPWI001" },
            }
            snap.pools[s.pool] = s.uses
        end
        snap.groups[group.key] = { key = group.key, name = group.name or group.key,
                                   kind = group.kind or "spl", sources = sources }
    end
    for key, uses in pairs(spec.pools or {}) do snap.pools[key] = uses end
    return snap
end
"""


@pytest.fixture
def lua() -> LuaRuntime:
    runtime = plan_runtime()
    runtime.execute(_SNAPSHOT_HELPERS)
    return runtime


def test_group_keys_separate_each_item_power_but_not_each_caster(lua):
    """One ability is one group whoever casts it; each F8 power is its own."""
    assert lua.eval(
        'BfBot.Plan.GroupKey({ kind = "spl", resref = "spwi219" })'
    ) == "spl:SPWI219"
    first = lua.eval(
        'BfBot.Plan.GroupKey({ kind = "itm", itemResref = "ring06", abilityIdx = 0 })'
    )
    second = lua.eval(
        'BfBot.Plan.GroupKey({ kind = "itm", itemResref = "ring06", abilityIdx = 1 })'
    )
    assert first == "itm:RING06:0"
    assert second == "itm:RING06:1"
    assert first != second


def test_spontaneous_casters_share_one_pool_per_level(lua):
    """A sorcerer picks at cast time, so every level-3 spell draws one pool.

    A prepared caster spends the specific memorized resource, so two level-3
    spells are two pools. Getting this wrong would let the plan promise more
    casts than a sorcerer can actually make.
    """
    sorcerer = 'BfBot.Plan.SpellPool({ key = "a", class = 19 }, %s)'
    cleric = 'BfBot.Plan.SpellPool({ key = "b", class = 2 }, %s)'
    haste = '{ kind = "spl", resref = "SPWI302", spellType = 1, level = 3 }'
    fly = '{ kind = "spl", resref = "SPWI314", spellType = 1, level = 3 }'

    assert lua.eval(sorcerer % haste) == lua.eval(sorcerer % fly) == "a:level:1:3"
    assert lua.eval(cleric % haste) != lua.eval(cleric % fly)
    assert lua.eval(cleric % haste) == "b:spell:SPWI302"


def test_a_shaman_shares_priest_levels_but_not_mage_levels(lua):
    """Class 21 is spontaneous on the PRIEST side (spellType 2) only."""
    shaman = 'BfBot.Plan.SpellPool({ key = "s", class = 21 }, %s)'
    priest = '{ kind = "spl", resref = "SPPR301", spellType = 2, level = 3 }'
    priest2 = '{ kind = "spl", resref = "SPPR302", spellType = 2, level = 3 }'
    mage = '{ kind = "spl", resref = "SPWI302", spellType = 1, level = 3 }'

    assert lua.eval(shaman % priest) == lua.eval(shaman % priest2) == "s:level:2:3"
    assert lua.eval(shaman % mage) == "s:spell:SPWI302"


def test_a_summons_pool_key_carries_its_spawn_so_two_copies_never_share_uses(lua):
    """`poolKey` wins over `key`: the saved identity is shared, the uses are not."""
    first = lua.eval(
        'BfBot.Plan.SpellPool({ key = "summon:x", poolKey = "summon:x:spawn:11",'
        ' class = 2 }, { kind = "spl", resref = "SPPR101", spellType = 2, level = 1 })'
    )
    second = lua.eval(
        'BfBot.Plan.SpellPool({ key = "summon:x", poolKey = "summon:x:spawn:12",'
        ' class = 2 }, { kind = "spl", resref = "SPPR101", spellType = 2, level = 1 })'
    )
    assert first != second


def test_five_e_and_unknown_classes_are_refused_with_a_reason(lua):
    """Both refuse by returning nil plus a code, never a usable pool key."""
    pool, reason = lua.eval(
        'BfBot.Plan.SpellPool({ key = "a", class = 2 },'
        ' { kind = "spl", resref = "X", d5 = true })'
    )
    assert pool is None and reason == "five_e_source"

    pool, reason = lua.eval(
        'BfBot.Plan.SpellPool({ key = "a", class = nil },'
        ' { kind = "spl", resref = "X", spellType = 1, level = 1 })'
    )
    assert pool is None and reason == "caster_class_unavailable"


# Each case: what to set on the single source, what the request asks for, and
# the cause the planner must name. The party holds Imoen, Minsc, a dead
# member and two members sharing one display name.
_REJECTIONS = [
    ("", 'target = "imoen", source = "minsc"', "preferred_caster_unavailable"),
    ("", 'target = "ghost"', "recipient_unavailable"),
    ("", 'target = "dead"', "recipient_dead"),
    ("", 'target = "twin"', "recipient_ambiguous"),
    ("selfOnly = true", 'target = "minsc"', "self_only"),
    ("aoe = true", 'target = "minsc"', "party_wide_cast"),
    ("", 'target = "party"', "choose_recipient"),
    ("", 'target = "imoen", var = "SPWI999"', "variant_unavailable"),
]


@pytest.mark.parametrize("source_fields, request_fields, expected", _REJECTIONS)
def test_every_rejection_names_its_own_cause(lua, source_fields, request_fields, expected):
    """A request that cannot be served says why, so a view can explain it."""
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" }, { key = "minsc" },
                       { key = "dead", alive = false },
                       { key = "twin", ambiguous = true } },
            groups = { { key = "g", sources = {
                { actor = "imoen", pool = "p", uses = 1, duration = 100 } } } },
        })
        """
    )
    if source_fields:
        lua.execute(f'snap.groups["g"].sources[1].{source_fields}')
    allowed, reason = lua.eval(
        'BfBot.Plan.SourceAllowed(snap, snap.groups["g"].sources[1],'
        f' {{ group = "g", on = 1, {request_fields} }})'
    )
    assert allowed is False
    assert reason == expected


def test_a_source_that_is_already_unusable_reports_its_own_reason_first(lua):
    """The caster being dead outranks any complaint about the request."""
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" } },
            groups = { { key = "g", sources = {
                { actor = "imoen", pool = "p", uses = 1, reason = "caster_dead" } } } },
        })
        """
    )
    allowed, reason = lua.eval(
        'BfBot.Plan.SourceAllowed(snap, snap.groups["g"].sources[1],'
        ' { group = "g", target = "party", on = 1 })'
    )
    assert allowed is False and reason == "caster_dead"


def test_a_variant_request_must_name_a_variant_the_source_offers(lua):
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" } },
            groups = { { key = "g", sources = { { actor = "imoen", pool = "p",
                uses = 1, variants = { { resref = "SPWI001" } } } } } },
        })
        """
    )
    assert lua.eval(
        'BfBot.Plan.SourceAllowed(snap, snap.groups["g"].sources[1],'
        ' { group = "g", target = "imoen", var = "SPWI001", on = 1 })'
    ) is True
    allowed, reason = lua.eval(
        'BfBot.Plan.SourceAllowed(snap, snap.groups["g"].sources[1],'
        ' { group = "g", target = "imoen", var = "SPWI002", on = 1 })'
    )
    assert allowed is False and reason == "variant_unsupported"


def test_the_longest_duration_wins_and_permanent_outranks_every_number(lua):
    """-1 means permanent. Ties fall to caster level, then to a stable id."""
    better = (
        'BfBot.Plan.BetterSource({ id = "a", duration = %s, casterLevel = %s },'
        ' { id = "b", duration = %s, casterLevel = %s }, {})'
    )
    assert lua.eval(better % (600, 1, 300, 1)) is True
    assert lua.eval(better % (-1, 1, 6000, 20)) is True
    assert lua.eval(better % (300, 12, 300, 9)) is True
    assert lua.eval(better % (300, 9, 300, 12)) is False
    # Same duration, same level: the id decides, so the plan is reproducible.
    assert lua.eval(better % (300, 9, 300, 9)) is True


def test_a_variants_own_duration_decides_the_better_source(lua):
    """A variant is cast directly, so its duration — not the wrapper's — counts."""
    assert lua.eval(
        'BfBot.Plan.BetterSource('
        '{ id = "a", duration = 10, variantDurations = { V = 7200 } },'
        '{ id = "b", duration = 6000, variantDurations = {} },'
        '{ var = "V" })'
    ) is True


def test_the_allocator_gives_each_request_its_own_use(lua):
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" }, { key = "minsc" } },
            groups = { { key = "g", sources = {
                { actor = "imoen", pool = "imoen:haste", uses = 2, duration = 300 } } } },
        })
        plan = BfBot.Plan.Assign(snap, {
            { group = "g", target = "imoen", on = 1 },
            { group = "g", target = "minsc", on = 1 },
        })
        """
    )
    assert lua.eval("plan.missing") == 0
    assert lua.eval('plan.used["imoen:haste"]') == 2
    assert lua.eval("plan.decisions[1].duration") == 300


def test_a_pool_that_runs_dry_leaves_the_later_request_unserved(lua):
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" }, { key = "minsc" } },
            groups = { { key = "g", sources = {
                { actor = "imoen", pool = "p", uses = 1, duration = 300 } } } },
        })
        plan = BfBot.Plan.Assign(snap, {
            { group = "g", target = "imoen", on = 1 },
            { group = "g", target = "minsc", on = 1 },
        })
        """
    )
    assert lua.eval("plan.missing") == 1
    assert lua.eval("plan.decisions[1].source ~= nil") is True
    assert lua.eval("plan.decisions[2].reason") == "no_unreserved_uses"


def test_a_scarce_caster_is_displaced_so_a_request_with_no_alternative_is_served(lua):
    """The augmenting path: Imoen can buff anyone, Viconia only herself.

    Both would rather take Imoen's cast (longer duration). Serving the first
    request greedily and stopping would leave Viconia's own self-only source
    idle while her request fails. The allocator moves the earlier recipient
    onto its second choice instead.
    """
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" }, { key = "viconia" } },
            groups = { { key = "g", sources = {
                { actor = "imoen", pool = "imoen:p", uses = 1, duration = 600 },
                { actor = "viconia", pool = "vic:p", uses = 1, duration = 300,
                  selfOnly = true },
            } } },
        })
        plan = BfBot.Plan.Assign(snap, {
            { group = "g", target = "viconia", on = 1 },
            { group = "g", target = "imoen", on = 1 },
        })
        """
    )
    assert lua.eval("plan.missing") == 0
    assert lua.eval("plan.decisions[1].source.actor") == "viconia"
    assert lua.eval("plan.decisions[2].source.actor") == "imoen"


def test_a_disabled_request_is_not_counted_as_missing(lua):
    """Switching a row off is the player's choice, not a planning failure."""
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" } },
            groups = { { key = "g", sources = {
                { actor = "imoen", pool = "p", uses = 1, duration = 10 } } } },
        })
        plan = BfBot.Plan.Assign(snap, { { group = "g", target = "imoen", on = 0 } })
        """
    )
    assert lua.eval("plan.missing") == 0
    assert lua.eval("plan.decisions[1].reason") == "disabled"
    assert lua.eval("plan.decisions[1].source == nil") is True


def test_a_buff_nobody_has_a_group_with_no_casters_and_a_refusing_caster_differ(lua):
    """Three different player problems, three different answers.

    "Nobody in the party has this buff" is not the same as "this buff exists
    but no one can currently cast it", and neither is "this caster refuses
    this particular request" — which keeps its own, more useful cause.
    """
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" } },
            groups = { { key = "nobody", sources = {} },
                       { key = "selfish", sources = {
                { actor = "imoen", pool = "p", uses = 1, selfOnly = true } } } },
        })
        plan = BfBot.Plan.Assign(snap, {
            { group = "absent", target = "imoen", on = 1 },
            { group = "nobody", target = "imoen", on = 1 },
            { group = "selfish", target = "party", on = 1 },
        })
        """
    )
    assert lua.eval("plan.decisions[1].reason") == "buff_unavailable"
    assert lua.eval("plan.decisions[2].reason") == "no_eligible_source"
    assert lua.eval("plan.decisions[3].reason") == "self_only"
    assert lua.eval("plan.missing") == 3


def test_repeats_become_one_allocation_unit_each_and_keep_their_origin(lua):
    """The panel shows one row with "x3"; three uses have to be reserved."""
    lua.execute(
        """
        origin = { group = "g", target = "imoen", on = 1, rep = 3 }
        flat, overflow = BfBot.Plan.ExpandRequests({ origin })
        """
    )
    assert lua.eval("#flat") == 3
    assert lua.eval("overflow") is False
    assert lua.eval("flat[1].origin == origin and flat[3].origin == origin") is True
    assert [lua.eval(f"flat[{i}].repeatIndex") for i in (1, 2, 3)] == [1, 2, 3]


def test_a_missing_or_absurd_repeat_count_becomes_one_cast(lua):
    """Repeat normalization is persistence's contract; the planner reuses it."""
    for rep in ("nil", "0", "-4", "2.5", "999", "0/0"):
        count = lua.eval(
            "(function() local f = BfBot.Plan.ExpandRequests("
            "{ { group = 'g', target = 't', on = 1, rep = %s } }) return #f end)()" % rep
        )
        assert count == 1, rep
    assert lua.eval(
        "(function() local f = BfBot.Plan.ExpandRequests("
        "{ { group = 'g', target = 't', on = 1, rep = BfBot.MAX_SPELL_REPEATS } })"
        " return #f end)()"
    ) == lua.eval("BfBot.MAX_SPELL_REPEATS")


def test_expansion_stops_at_the_request_ceiling_and_says_so(lua):
    """Overflow is reported, never silently truncated into a shorter plan."""
    lua.execute(
        """
        many = {}
        for i = 1, 200 do many[i] = { group = "g", target = "t", on = 1, rep = 5 } end
        flat, overflow = BfBot.Plan.ExpandRequests(many)
        """
    )
    assert lua.eval("overflow") is True
    assert lua.eval("#flat") <= lua.eval("BfBot.Plan.MAX_REQUESTS")


def test_the_browser_offers_buffs_but_not_the_classifiers_hostile_schools(lua):
    """Offensive spells score positively on stat and protection opcodes, so a
    raw classifier score would fill the plan with fireballs. MSECTYPE 4/10/11
    are held back; an explicit override or a self/friendly ability is not."""
    auto = "BfBot.Plan.IsAutomaticBuff(%s)"
    assert lua.eval(auto % '{ class = { isBuff = true, msectype = 1 } }') is True
    assert lua.eval(auto % '{ class = { isBuff = true, msectype = 4 } }') is False
    assert lua.eval(auto % '{ class = { isBuff = true, msectype = 10 } }') is False
    assert lua.eval(auto % '{ class = { isBuff = true, msectype = 11 } }') is False
    assert lua.eval(
        auto % '{ class = { isBuff = true, msectype = 4, overridden = true } }'
    ) is True
    assert lua.eval(
        auto % '{ class = { isBuff = true, msectype = 4, isSelfOnly = true } }'
    ) is True
    assert lua.eval(
        auto % '{ class = { isBuff = true, msectype = 4, friendlyFlag = true } }'
    ) is True
    assert lua.eval(auto % '{ class = { isBuff = false, msectype = 1 } }') is False
    assert lua.eval(auto % "nil") is False


def test_an_item_power_that_opens_a_selection_menu_is_not_offered_automatically(lua):
    """BuffBot cannot answer the engine's own choice dialog, so it must not
    promise the cast. The row stays reachable through an explicit Add."""
    assert lua.eval(
        'BfBot.Plan.IsAutomaticBuff({ kind = "itm", requiresChoice = 1,'
        ' class = { isBuff = true, msectype = 1 } })'
    ) is False
    assert lua.eval(
        'BfBot.Plan.IsAutomaticBuff({ kind = "itm", requiresChoice = 0,'
        ' class = { isBuff = true, msectype = 1 } })'
    ) is True


def test_a_radial_self_cast_becomes_one_party_request_on_its_own_caster(lua):
    """Chant reaches the party from where the caster stands. A migrated entry
    recorded it per recipient; recognizing the delivery collapses it to one
    cast and keeps the original caster."""
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "jaheira" } },
            groups = { { key = "g", sources = { { actor = "jaheira", pool = "p",
                uses = 1, row = { kind = "spl", resref = "SPPR103",
                radialParty = 1 } } } } },
        })
        requests = { { group = "g", target = "jaheira", on = 1 } }
        BfBot.Plan.NormalizeRadialRequests(snap, requests)
        """
    )
    assert lua.eval("requests[1].target") == "party"
    assert lua.eval("requests[1].source") == "jaheira"


def test_a_plain_self_cast_is_left_alone(lua):
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "jaheira" } },
            groups = { { key = "g", sources = { { actor = "jaheira", pool = "p",
                uses = 1, row = { kind = "spl", resref = "SPPR101" } } } } },
        })
        requests = { { group = "g", target = "jaheira", on = 1 } }
        BfBot.Plan.NormalizeRadialRequests(snap, requests)
        """
    )
    assert lua.eval("requests[1].target") == "jaheira"


def test_the_queue_it_builds_is_what_the_executor_already_accepts(lua):
    """`BfBot.Exec._BuildQueue` keeps every guard — MP ownership, live caster
    re-resolution, skip detection. The planner hands it entries in its own
    shape rather than casting anything itself."""
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" }, { key = "minsc" } },
            groups = { { key = "spl:SPWI302", resref = "SPWI302", sources = {
                { actor = "imoen", pool = "p", uses = 2, duration = 300 } } } },
        })
        queue, plan = BfBot.Plan.BuildQueue(snap, {
            { group = "spl:SPWI302", target = "minsc", on = 1, rep = 2 } })
        """
    )
    assert lua.eval("#queue") == 2
    assert lua.eval("queue[1].spell") == "SPWI302"
    # _ResolveConfigTarget's vocabulary: Player 1-6, not the 0-5 portrait slot.
    assert lua.eval("queue[1].target") == 2
    assert lua.eval('queue[1].casterRef.kind') == "party"
    assert lua.eval("queue[1].casterRef.slot") == 0
    # Repeats are already separate entries, so no entry asks for a second cast.
    assert lua.eval("queue[1].rep") == 1 and lua.eval("queue[2].rep") == 1
    assert lua.eval("queue[1].plannedActor") == "imoen"
    assert lua.eval("queue[1].plannedTarget") == "minsc"


def test_a_self_only_source_casts_on_itself_rather_than_on_a_slot_number(lua):
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" } },
            groups = { { key = "g", resref = "SPWI120", sources = {
                { actor = "imoen", pool = "p", uses = 1, selfOnly = true } } } },
        })
        queue = BfBot.Plan.BuildQueue(snap, { { group = "g", target = "imoen", on = 1 } })
        """
    )
    assert lua.eval("queue[1].target") == "self"


def test_a_party_request_casts_once_on_everyone(lua):
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "jaheira" } },
            groups = { { key = "g", resref = "SPPR103", sources = {
                { actor = "jaheira", pool = "p", uses = 1, aoe = true } } } },
        })
        queue = BfBot.Plan.BuildQueue(snap, { { group = "g", target = "party", on = 1 } })
        """
    )
    assert lua.eval("#queue") == 1
    assert lua.eval("queue[1].target") == "all"


def test_a_plan_that_cannot_be_served_in_full_is_refused_not_shortened(lua):
    """A run that quietly drops casts is worse than one that explains itself:
    the player walks into the fight believing they are buffed."""
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" }, { key = "minsc" } },
            groups = { { key = "g", resref = "SPWI302", sources = {
                { actor = "imoen", pool = "p", uses = 1, duration = 300 } } } },
        })
        queue, plan = BfBot.Plan.BuildQueue(snap, {
            { group = "g", target = "imoen", on = 1 },
            { group = "g", target = "minsc", on = 1 },
        })
        """
    )
    assert lua.eval("queue == nil") is True
    assert lua.eval("plan.missing") == 1
    assert lua.eval("plan.decisions[2].reason") == "no_unreserved_uses"


def test_an_all_disabled_plan_builds_no_queue(lua):
    lua.execute(
        """
        snap = TestSnapshot({
            actors = { { key = "imoen" } },
            groups = { { key = "g", resref = "SPWI302", sources = {
                { actor = "imoen", pool = "p", uses = 1 } } } },
        })
        queue, plan = BfBot.Plan.BuildQueue(snap, { { group = "g", target = "imoen", on = 0 } })
        """
    )
    assert lua.eval("queue == nil") is True
    assert lua.eval("plan.missing") == 0


# ---------------------------------------------------------------------------
# Migration from the per-character presets
# ---------------------------------------------------------------------------


_LEGACY_HELPERS = """
-- A v10 config as the save holds it, plus the scan rows its entries name.
function TestLegacy(perActor)
    BfBot.Persist.GetConfig = function(sprite)
        return perActor[sprite.m_id] and perActor[sprite.m_id].config or nil
    end
    BfBot.Persist._ResolveNameToSlot = function(name)
        return perActor._slots and perActor._slots[name] or nil
    end
end
"""


@pytest.fixture
def legacy(lua) -> LuaRuntime:
    lua.execute(_LEGACY_HELPERS)
    return lua


def test_migration_keeps_the_caster_lock_the_variant_and_the_repeats(legacy):
    """Depth must survive the merge. The entry said "Jaheira casts this three
    times on herself, variant X" — the plan has to say the same thing."""
    legacy.execute(
        """
        snap = TestSnapshot({ actors = { { key = "jaheira" } } })
        snap.order[1].rows = { SPPR301 = { kind = "spl", resref = "SPPR301" } }
        TestLegacy({ [1] = { config = { v = 10, presets = { [1] = { spells = {
            SPPR301 = { kind = "spl", on = 1, tgt = "s", pri = 1, rep = 3,
                        var = "SPPR301A", lock = 1, tgtUnlock = 1 } } } } } } })
        requests = BfBot.Plan.ImportLegacy(snap, 1)
        """
    )
    assert legacy.eval("#requests") == 1
    assert legacy.eval("requests[1].group") == "spl:SPPR301"
    assert legacy.eval("requests[1].source") == "jaheira"
    assert legacy.eval("requests[1].target") == "jaheira"
    assert legacy.eval("requests[1].var") == "SPPR301A"
    assert legacy.eval("requests[1].rep") == 3
    assert legacy.eval("requests[1].lock") == 1
    assert legacy.eval("requests[1].tgtUnlock") == 1


def test_migration_follows_the_players_own_priority(legacy):
    """`pairs` over a spell table has no order. The player's priority does, and
    the same config has to migrate to the same plan every time."""
    legacy.execute(
        """
        snap = TestSnapshot({ actors = { { key = "jaheira" } } })
        snap.order[1].rows = {
            A = { kind = "spl", resref = "A" }, B = { kind = "spl", resref = "B" },
            C = { kind = "spl", resref = "C" } }
        TestLegacy({ [1] = { config = { v = 10, presets = { [1] = { spells = {
            A = { on = 1, tgt = "s", pri = 3 },
            B = { on = 1, tgt = "s", pri = 1 },
            C = { on = 1, tgt = "s", pri = 2 } } } } } } })
        requests = BfBot.Plan.ImportLegacy(snap, 1)
        order = {}
        for i, r in ipairs(requests) do order[i] = r.group end
        """
    )
    assert [legacy.eval(f"order[{i}]") for i in (1, 2, 3)] == [
        "spl:B", "spl:C", "spl:A"
    ]
    assert [legacy.eval(f"requests[{i}].manual") for i in (1, 2, 3)] == [1, 2, 3]


def test_a_party_target_on_a_single_target_spell_becomes_one_request_per_member(legacy):
    """"All" on a spell that is not area-delivered means six casts, and the
    plan has to show six rows so the use count is honest."""
    legacy.execute(
        """
        snap = TestSnapshot({ actors = { { key = "jaheira" }, { key = "minsc" },
                                         { key = "imoen" } } })
        for _, a in ipairs(snap.order) do
            a.rows = { SPPR201 = { kind = "spl", resref = "SPPR201", isAoE = 0 } }
        end
        TestLegacy({ [1] = { config = { v = 10, presets = { [1] = { spells = {
            SPPR201 = { on = 1, tgt = "p", pri = 1 } } } } } } })
        requests = BfBot.Plan.ImportLegacy(snap, 1)
        targets = {}
        for i, r in ipairs(requests) do targets[i] = r.target end
        """
    )
    assert legacy.eval("#requests") == 3
    assert {legacy.eval(f"targets[{i}]") for i in (1, 2, 3)} == {
        "jaheira", "minsc", "imoen"
    }


def test_a_party_target_on_an_area_spell_stays_a_single_cast(legacy):
    legacy.execute(
        """
        snap = TestSnapshot({ actors = { { key = "jaheira" }, { key = "minsc" } } })
        for _, a in ipairs(snap.order) do
            a.rows = { SPPR401 = { kind = "spl", resref = "SPPR401", isAoE = 1 } }
        end
        TestLegacy({ [1] = { config = { v = 10, presets = { [1] = { spells = {
            SPPR401 = { on = 1, tgt = "p", pri = 1 } } } } } } })
        requests = BfBot.Plan.ImportLegacy(snap, 1)
        """
    )
    assert legacy.eval("#requests") == 1
    assert legacy.eval("requests[1].target") == "party"


def test_a_radial_self_cast_migrates_straight_to_a_party_request(legacy):
    legacy.execute(
        """
        snap = TestSnapshot({ actors = { { key = "jaheira" } } })
        snap.order[1].rows = { SPPR103 = { kind = "spl", resref = "SPPR103",
                                           radialParty = 1 } }
        TestLegacy({ [1] = { config = { v = 10, presets = { [1] = { spells = {
            SPPR103 = { on = 1, tgt = "s", pri = 1 } } } } } } })
        requests = BfBot.Plan.ImportLegacy(snap, 1)
        """
    )
    assert legacy.eval("requests[1].target") == "party"


def test_a_named_target_resolves_through_persistence_to_that_party_member(legacy):
    legacy.execute(
        """
        snap = TestSnapshot({ actors = { { key = "jaheira" }, { key = "minsc" } } })
        for _, a in ipairs(snap.order) do
            a.rows = { SPPR201 = { kind = "spl", resref = "SPPR201", isAoE = 0 } }
        end
        TestLegacy({ _slots = { ["Minsc"] = 1 },
            [1] = { config = { v = 10, presets = { [1] = { spells = {
                SPPR201 = { on = 1, tgt = "Minsc", pri = 1 } } } } } } })
        requests = BfBot.Plan.ImportLegacy(snap, 1)
        """
    )
    assert legacy.eval("#requests") == 1
    assert legacy.eval("requests[1].target") == "minsc"


def test_migration_refuses_rather_than_dropping_a_configured_cast(legacy):
    """A spell the character no longer knows, or a recipient who left the
    party, means the migrated plan would be a lie. Refuse and name it."""
    legacy.execute(
        """
        snap = TestSnapshot({ actors = { { key = "jaheira" } } })
        snap.order[1].rows = {}
        TestLegacy({ [1] = { config = { v = 10, presets = { [1] = { spells = {
            SPPR301 = { on = 1, tgt = "s", pri = 1 } } } } } } })
        requests, reason, detail = BfBot.Plan.ImportLegacy(snap, 1)
        """
    )
    assert legacy.eval("requests == nil") is True
    assert legacy.eval("reason") == "legacy_source_gone"
    assert legacy.eval("detail") == "SPPR301"

    legacy.execute(
        """
        snap = TestSnapshot({ actors = { { key = "jaheira" } } })
        snap.order[1].rows = { SPPR201 = { kind = "spl", resref = "SPPR201" } }
        TestLegacy({ _slots = {},
            [1] = { config = { v = 10, presets = { [1] = { spells = {
                SPPR201 = { on = 1, tgt = "Khalid", pri = 1 } } } } } } })
        requests, reason, detail = BfBot.Plan.ImportLegacy(snap, 1)
        """
    )
    assert legacy.eval("requests == nil") is True
    assert legacy.eval("reason") == "legacy_recipient_gone"
    assert legacy.eval("detail") == "SPPR201"


def test_a_disabled_legacy_entry_is_skipped_and_never_blocks_the_migration(legacy):
    """An off row whose spell is gone is not a problem worth refusing over."""
    legacy.execute(
        """
        snap = TestSnapshot({ actors = { { key = "jaheira" } } })
        snap.order[1].rows = { KEEP = { kind = "spl", resref = "KEEP" } }
        TestLegacy({ [1] = { config = { v = 10, presets = { [1] = { spells = {
            KEEP = { on = 1, tgt = "s", pri = 1 },
            GONE = { on = 0, tgt = "s", pri = 2 } } } } } } })
        requests, reason = BfBot.Plan.ImportLegacy(snap, 1)
        """
    )
    assert legacy.eval("reason == nil") is True
    assert legacy.eval("#requests") == 1
    assert legacy.eval("requests[1].group") == "spl:KEEP"


def test_migration_reads_every_party_member_into_one_plan(legacy):
    """This is the whole point of the merge: six per-character preset 1s become
    one party plan, each request remembering who was configured to cast it."""
    legacy.execute(
        """
        snap = TestSnapshot({ actors = { { key = "jaheira" }, { key = "imoen" } } })
        snap.order[1].rows = { SPPR301 = { kind = "spl", resref = "SPPR301" } }
        snap.order[2].rows = { SPWI302 = { kind = "spl", resref = "SPWI302" } }
        TestLegacy({
            [1] = { config = { v = 10, presets = { [1] = { spells = {
                SPPR301 = { on = 1, tgt = "s", pri = 1 } } } } } },
            [2] = { config = { v = 10, presets = { [1] = { spells = {
                SPWI302 = { on = 1, tgt = "s", pri = 2 } } } } } },
        })
        requests = BfBot.Plan.ImportLegacy(snap, 1)
        """
    )
    assert legacy.eval("#requests") == 2
    assert legacy.eval("requests[1].source") == "jaheira"
    assert legacy.eval("requests[2].source") == "imoen"


def test_migration_leaves_the_per_character_presets_untouched(legacy):
    """Reading, not consuming: the old config stays valid until the schema
    bump actually moves it, so a half-finished migration loses nothing."""
    legacy.execute(
        """
        snap = TestSnapshot({ actors = { { key = "jaheira" } } })
        snap.order[1].rows = { SPPR301 = { kind = "spl", resref = "SPPR301" } }
        original = { on = 1, tgt = "s", pri = 1, rep = 2 }
        TestLegacy({ [1] = { config = { v = 10, presets = { [1] = {
            spells = { SPPR301 = original } } } } } })
        BfBot.Plan.ImportLegacy(snap, 1)
        """
    )
    assert legacy.eval("original.on") == 1
    assert legacy.eval("original.tgt") == "s"
    assert legacy.eval("original.pri") == 1
    assert legacy.eval("original.rep") == 2


# ---------------------------------------------------------------------------
# Layering
# ---------------------------------------------------------------------------


def plan_code() -> str:
    """The module with its comments stripped.

    These checks are about what the code does, and the header explains at
    length which fork features are deliberately absent — scanning the prose
    too would make every such explanation break its own test.
    """
    return "\n".join(
        line for line in PLAN_PATH.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("--")
    )


def test_the_planner_produces_no_display_text_of_its_own():
    """Rejections are the plain identifiers in `P.REASON`. The view that shows
    one maps it to localized text, so the wording is written and reviewed
    where the player reads it — not buried in the allocator.

    This also keeps the planner outside the `reason.*` catalog contract that
    `test_localization.py` enforces for persistence, execution and fast-forward.
    """
    code = plan_code()
    assert "BfBot.L10N" not in code
    assert "Infinity_DisplayString" not in code
    assert "Infinity_FetchString" not in code
    # No `reason.*` catalog code is produced here, so the planner stays
    # outside the contract test_localization.py enforces on its producers.
    assert not re.search(r"[\"']reason\.", code)


def test_every_reason_the_planner_can_return_is_declared_in_one_place():
    """A view switches on these, so an undeclared literal would be a silent
    hole in its explanation table."""
    runtime = plan_runtime()
    declared = set(runtime.eval("BfBot.Plan.REASON").values())
    used = set(re.findall(r"P\.REASON\.([A-Z_]+)", plan_code()))
    names = set(runtime.eval("BfBot.Plan.REASON").keys())
    assert used <= names, sorted(used - names)
    # Each identifier is distinct, so two causes can never be confused.
    assert len(declared) == len(names)


def test_the_planner_holds_no_save_state_and_registers_no_second_handler():
    """One plan model means one store. The fork keeps a `BuffBotParty` subtree
    beside `BuffBot`; two stores mean two truths for the same buff, and the
    player has to learn which screen owns which setting."""
    code = plan_code()
    assert "AddMarshalHandlers" not in code
    assert "BuffBotParty" not in code
    assert "BBParty" not in code


def test_the_planner_never_reorders_the_players_priority():
    """"User spell priority is always respected — no automatic reordering by
    duration category" is a standing design decision. The fork's smart/long
    order engine is deliberately not ported."""
    code = plan_code()
    for absent in ("SortRequests", "ApplyOrder", "orderScore", "CastAges"):
        assert absent not in code, absent
    # `manual` is carried through migration and never recomputed.
    assert "manual = #requests + 1" in code


def test_the_planner_loads_after_the_modules_it_calls_into():
    """Scan, Class, Exec and Persist must all exist by the time it runs."""
    bootstrap = (ROOT / "buffbot/M_BfBot.lua").read_text(encoding="utf-8")
    order = [
        bootstrap.index(f'Infinity_DoFile("{name}")')
        for name in ("BfBotCls", "BfBotScn", "BfBotExe", "BfBotPer", "BfBotPln")
    ]
    assert order == sorted(order)


def test_the_module_compiles_under_luajit():
    runtime = LuaRuntime(unpack_returned_tuples=True)
    assert runtime.eval(f"loadstring({PLAN_SOURCE!r})") is not None


# ---------------------------------------------------------------------------
# Identities and the live snapshot
# ---------------------------------------------------------------------------


_ENGINE_STUBS = """
-- A sprite here is a plain table; only the fields the planner reads exist.
function TestSprite(spec)
    return { m_id = spec.id, m_typeAI = { m_Class = spec.class or 1 },
             m_nCopyParent = spec.copyParent,
             _index = spec.index, _portrait = spec.portrait,
             _dv = spec.dv or "", _name = spec.name or "someone",
             _rows = spec.rows or {} }
end

function TestParty(sprites, summons)
    local byIndex = {}
    for _, s in ipairs(sprites) do byIndex[s._portrait] = s end
    EEex_Sprite_GetInPortrait = function(slot) return byIndex[slot] end
    EEex_Sprite_GetCharacterIndex = function(s) return s._index end
    EEex_Sprite_GetPortraitIndex = function(s) return s._portrait or -1 end
    BfBot._GetDeathVar = function(s) return s._dv end
    BfBot._GetName = function(s) return s._name end
    BfBot.Exec._IsAlive = function(s) return s._alive ~= false end
    BfBot.Scan.GetCastableSpells = function(s) return s._rows end
    BfBot.Persist.GetPref = function(_) return "direct" end
    BfBot.Scan.GetAlliedSummons = function()
        local list = {}
        for i, s in ipairs(summons or {}) do
            list[i] = { oid = s.m_id, name = s._name }
        end
        return list
    end
    BfBot.Exec._ResolveCaster = function(ref)
        for _, s in ipairs(summons or {}) do
            if s.m_id == ref.oid then return s end
        end
        return byIndex[ref.slot]
    end
    BfBot.Scan.ClassifySummonSprite = function(s) return s._summon end
    EEex_GameObject_Get = function(id)
        for _, s in ipairs(sprites) do if s.m_id == id then return s end end
    end
    EEex_GameObject_IsSprite = function(_, _) return true end
    EEex_GameObject_CastUserType = function(s) return s end
end

function TestRow(spec)
    return { resref = spec.resref, kind = spec.kind or "spl",
             name = spec.name or spec.resref, icon = "ICON",
             count = spec.count or 1, level = spec.level or 1,
             spellType = spec.spellType or 1, duration = spec.duration or 300,
             casterLevel = spec.casterLevel or 1,
             isAoE = spec.isAoE or 0, isSelfOnly = spec.isSelfOnly or 0,
             isProjectImage = 0, hasVariants = 0, radialParty = spec.radialParty or 0,
             itemResref = spec.itemResref, abilityIdx = spec.abilityIdx,
             itemType = spec.itemType, sources = spec.sources,
             class = spec.class or { isBuff = true, msectype = 1 } }
end
"""


@pytest.fixture
def engine(lua) -> LuaRuntime:
    lua.execute(_ENGINE_STUBS)
    return lua


def test_the_protagonist_is_keyed_by_join_order_and_everyone_else_by_death_variable(engine):
    """A rename breaks a name key - knighthood turns Anomen into Sir Anomen -
    so the death variable is the identity. The protagonist has none, which is
    exactly why join order identifies them."""
    engine.execute(
        """
        TestParty({ TestSprite({ id = 1, index = 0, portrait = 0, dv = "" }) }, {})
        pc = BfBot.Plan.ActorKey(TestSprite({ id = 1, index = 0, dv = "" }))
        anomen = BfBot.Plan.ActorKey(TestSprite({ id = 2, index = 3, dv = "Anomen" }))
        unnamed = BfBot.Plan.ActorKey(
            TestSprite({ id = 3, index = 4, dv = "NONE", name = "Hobgoblin" }))
        """
    )
    assert engine.eval("pc") == "protagonist"
    assert engine.eval("anomen") == "dv:ANOMEN"
    # "NONE" is the engine's placeholder, not an identity.
    assert engine.eval("unnamed") == "name:Hobgoblin"


def test_a_clone_is_keyed_by_its_owner_and_its_clone_type(engine):
    """Project Image and Simulacrum are both scriptname COPY, so the type has
    to be part of the key or the two would share one plan row."""
    engine.execute(
        """
        owner = TestSprite({ id = 7, index = 0, portrait = 0, dv = "" })
        TestParty({ owner }, {})
        image = TestSprite({ id = 8, copyParent = 7 })
        image._portrait = -1
        key = BfBot.Plan.CasterKey(image, { kind = "clone", cloneType = 2 })
        sim = BfBot.Plan.CasterKey(image, { kind = "clone", cloneType = 3 })
        plain = BfBot.Plan.CasterKey(image, { kind = "summon", identity = "MDOG" })
        """
    )
    assert engine.eval("key") == "summon:clone:protagonist:2"
    assert engine.eval("sim") == "summon:clone:protagonist:3"
    assert engine.eval("plain") == "summon:MDOG"


def test_a_party_member_is_their_own_caster_key(engine):
    engine.execute(
        """
        pc = TestSprite({ id = 1, index = 0, portrait = 0, dv = "" })
        TestParty({ pc }, {})
        key = BfBot.Plan.CasterKey(pc)
        """
    )
    assert engine.eval("key") == "protagonist"


def test_the_snapshot_collects_every_caster_of_a_shared_buff_into_one_group(engine):
    """Two clerics who both know Bless are two sources of one group - that is
    what lets the allocator pick the stronger one."""
    engine.execute(
        """
        a = TestSprite({ id = 1, index = 0, portrait = 0, dv = "", name = "CHARNAME",
            class = 2, rows = { SPPR101 = TestRow({ resref = "SPPR101",
                spellType = 2, casterLevel = 5, count = 2 }) } })
        b = TestSprite({ id = 2, index = 1, portrait = 1, dv = "Jaheira",
            name = "Jaheira", class = 2, rows = { SPPR101 = TestRow({
                resref = "SPPR101", spellType = 2, casterLevel = 12, count = 1 }) } })
        TestParty({ a, b }, {})
        snap = BfBot.Plan.Snapshot()
        group = snap.groups["spl:SPPR101"]
        """
    )
    assert engine.eval("#snap.casters") == 2
    assert engine.eval("#group.sources") == 2
    assert engine.eval("snap.pools['protagonist:spell:SPPR101']") == 2
    assert engine.eval("snap.pools['dv:JAHEIRA:spell:SPPR101']") == 1
    # Each source carries the level it would cast at, so BetterSource can pick.
    levels = sorted(engine.eval(f"group.sources[{i}].casterLevel") for i in (1, 2))
    assert levels == [5, 12]


def test_a_spontaneous_level_pool_is_its_uses_not_the_sum_of_its_spells(engine):
    """A sorcerer with four level-3 spells and two level-3 slots has TWO casts.
    Registering each known spell's count additively would promise eight."""
    engine.execute(
        """
        rows = {}
        for _, res in ipairs({ "SPWI302", "SPWI304", "SPWI312", "SPWI314" }) do
            rows[res] = TestRow({ resref = res, spellType = 1, level = 3, count = 2 })
        end
        sorc = TestSprite({ id = 1, index = 0, portrait = 0, dv = "",
            class = 19, rows = rows })
        TestParty({ sorc }, {})
        snap = BfBot.Plan.Snapshot()
        """
    )
    assert engine.eval("snap.pools['protagonist:level:1:3']") == 2
    missing = engine.eval(
        """(function()
            local requests = {}
            for i = 1, 3 do
                requests[i] = { group = "spl:SPWI302", target = "protagonist", on = 1 }
            end
            return BfBot.Plan.Assign(snap, requests).missing
        end)()"""
    )
    assert missing == 1


def test_a_hostile_spell_is_registered_as_a_pool_but_never_offered_as_a_buff(engine):
    """The pool has to know about every known spell - otherwise a sorcerer's
    level pool is wrong - while the browser must not offer a fireball."""
    engine.execute(
        """
        sorc = TestSprite({ id = 1, index = 0, portrait = 0, dv = "", class = 19,
            rows = { SPWI304 = TestRow({ resref = "SPWI304", spellType = 1,
                level = 3, count = 4, class = { isBuff = true, msectype = 4 } }) } })
        TestParty({ sorc }, {})
        snap = BfBot.Plan.Snapshot()
        """
    )
    assert engine.eval("snap.pools['protagonist:level:1:3']") == 4
    assert engine.eval("snap.groups['spl:SPWI304'] == nil") is True


def test_a_summons_self_only_buff_is_left_out(engine):
    """Nobody in the party gains from it, and it would occupy a plan row that
    can never be retargeted."""
    engine.execute(
        """
        pc = TestSprite({ id = 1, index = 0, portrait = 0, dv = "" })
        mob = TestSprite({ id = 50, name = "Skeleton Warrior", class = 2, rows = {
            SELFBUF = TestRow({ resref = "SELFBUF", spellType = 2, isSelfOnly = 1 }),
            SHARED = TestRow({ resref = "SHARED", spellType = 2 }) } })
        mob._portrait = -1
        mob._summon = { kind = "summon", identity = "SKELWAR" }
        TestParty({ pc }, { mob })
        snap = BfBot.Plan.Snapshot()
        """
    )
    assert engine.eval("snap.casterActors['summon:SKELWAR'] ~= nil") is True
    assert engine.eval("snap.groups['spl:SELFBUF'] == nil") is True
    assert engine.eval("snap.groups['spl:SHARED'] ~= nil") is True


def test_a_summons_area_buff_is_kept_even_though_its_target_type_says_self(engine):
    """A radial cast from a summon still covers the party standing around it."""
    engine.execute(
        """
        pc = TestSprite({ id = 1, index = 0, portrait = 0, dv = "" })
        mob = TestSprite({ id = 50, name = "Aerial Servant", class = 2, rows = {
            AURA = TestRow({ resref = "AURA", spellType = 2,
                isSelfOnly = 1, isAoE = 1 }) } })
        mob._portrait = -1
        mob._summon = { kind = "summon", identity = "AERIAL" }
        TestParty({ pc }, { mob })
        snap = BfBot.Plan.Snapshot()
        """
    )
    assert engine.eval("snap.groups['spl:AURA'] ~= nil") is True


def test_a_live_project_image_locks_its_owners_entries(engine):
    """A live PI locks its owner (CLAUDE.md). Every source the owner offers
    carries the lock as its reason, so the plan explains itself instead of
    queueing a cast the engine will refuse."""
    engine.execute(
        """
        pc = TestSprite({ id = 1, index = 0, portrait = 0, dv = "", class = 1,
            rows = { SPWI302 = TestRow({ resref = "SPWI302" }) } })
        image = TestSprite({ id = 99, name = "CHARNAME", class = 1, copyParent = 1,
            rows = {} })
        image._portrait = -1
        image._summon = { kind = "clone", cloneType = 2 }
        TestParty({ pc }, { image })
        snap = BfBot.Plan.Snapshot()
        """
    )
    assert engine.eval("snap.actors['protagonist'].projectImageLocked") is True
    assert engine.eval(
        "snap.groups['spl:SPWI302'].sources[1].reason"
    ) == "project_image_locked"


def test_each_inventory_copy_of_an_item_is_its_own_source_with_its_own_charges(engine):
    """Two Potions of Defence in two slots are two uses, not one shared pool."""
    engine.execute(
        """
        pc = TestSprite({ id = 1, index = 0, portrait = 0, dv = "", class = 1,
            rows = { ["POTN14:0"] = TestRow({ resref = "POTN14:0", kind = "itm",
                itemResref = "POTN14", abilityIdx = 0, itemType = 9, count = 3,
                sources = { { slot = 18, count = 2 }, { slot = 19, count = 1 } } }) } })
        TestParty({ pc }, {})
        snap = BfBot.Plan.Snapshot()
        group = snap.groups["itm:POTN14:0"]
        """
    )
    assert engine.eval("#group.sources") == 2
    assert engine.eval("snap.pools['protagonist:item:18:POTN14:0']") == 2
    assert engine.eval("snap.pools['protagonist:item:19:POTN14:0']") == 1
    assert engine.eval("group.sources[1].itemSlot") == 18


def test_two_party_members_sharing_one_name_and_no_death_variable_are_refused(engine):
    """Neither can be addressed reliably, so buffing whichever one resolved
    first is not an acceptable answer."""
    engine.execute(
        """
        a = TestSprite({ id = 1, index = 1, portrait = 0, dv = "", name = "Kagain",
            class = 2, rows = { SPPR101 = TestRow({ resref = "SPPR101", spellType = 2 }) } })
        b = TestSprite({ id = 2, index = 2, portrait = 1, dv = "", name = "Kagain",
            class = 2, rows = {} })
        TestParty({ a, b }, {})
        snap = BfBot.Plan.Snapshot()
        """
    )
    assert engine.eval("snap.actors['name:Kagain'].ambiguous") is True
    assert engine.eval(
        "snap.groups['spl:SPPR101'].sources[1].reason"
    ) == "caster_ambiguous"


def test_a_dead_caster_cannot_be_planned_with(engine):
    engine.execute(
        """
        pc = TestSprite({ id = 1, index = 0, portrait = 0, dv = "", class = 2,
            rows = { SPPR101 = TestRow({ resref = "SPPR101", spellType = 2 }) } })
        pc._alive = false
        TestParty({ pc }, {})
        snap = BfBot.Plan.Snapshot()
        """
    )
    assert engine.eval("snap.groups['spl:SPPR101'].sources[1].reason") == "caster_dead"


def test_the_snapshot_reads_the_save_but_never_writes_it():
    """Planning happens on every preview and every run. Nothing about it may
    touch the save, or opening the panel would dirty a save game."""
    code = plan_code()
    for absent in ("EEex_GetUDAux", "SetConfig", "SetPref", "_Save"):
        assert absent not in code, absent


def radial_runtime(setup: str) -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute("io = nil")
    runtime.execute(CORE_SOURCE)
    runtime.execute(CLASS_SOURCE)
    runtime.execute(setup)
    return runtime


# The real reads are two fixed offsets into the PRO header; the stub routes
# them back through a table so the flag/radius logic itself is exercised.
_PROJECTILE_STUBS = """
TestProjectiles = { [10] = { type = 3, flags = 0xC0, radius = 30 },
                    [11] = { type = 3, flags = 0xC0, radius = 0 },
                    [12] = { type = 1, flags = 0xC0, radius = 30 },
                    [13] = { type = 3, flags = 0x40, radius = 30 } }
TestLoads = 0
EEex_Resource_LoadIDS = function(_, _)
    return { getLine = function(_, index) return index .. " PRO" .. index end }
end
EEex_Resource_Demand = function(resource, _)
    local index = tonumber(resource:match("PRO(%d+)"))
    local p = TestProjectiles[index]
    if not p then return nil end
    TestLoads = TestLoads + 1
    TestCurrent = p
    return { m_wFileType = p.type }
end
-- EEex_ReadU16 takes ONE argument, the address. A stub that returned the PRO
-- table from EEex_UDToPtr would make `ptr + 0x1F8` an arithmetic error on a
-- table, which the pcall would swallow into a silent "not radial".
EEex_UDToPtr = function(_) return 0 end
EEex_ReadU16 = function(address)
    if address == 0x1F8 then return TestCurrent.flags end
    return TestCurrent.radius
end
"""


def test_a_radial_projectile_makes_a_self_cast_cover_the_party():
    """Chant's ability says caster, but its projectile is a 10-foot area, so
    one cast reaches everyone. Read from PROJECTL.IDS and the PRO header: an
    area projectile (file type 3) with a radius and both area flags set.

    missileType is 1-based over an IDS that starts at 0, so index 11 is PRO10.
    """
    runtime = radial_runtime(_PROJECTILE_STUBS)
    radial = "BfBot.Class.IsRadialParty({ actionType = %s, missileType = %s })"
    assert runtime.eval(radial % (5, 11)) is True
    # Zero radius, not an area projectile, only one of the two flags, no PRO.
    assert runtime.eval(radial % (5, 12)) is False
    assert runtime.eval(radial % (5, 13)) is False
    assert runtime.eval(radial % (5, 14)) is False
    assert runtime.eval(radial % (5, 15)) is False
    # Not a self-cast at all, and the no-projectile sentinel.
    assert runtime.eval(radial % (1, 11)) is False
    assert runtime.eval(radial % (5, 1)) is False
    assert runtime.eval(radial % (5, "nil")) is False


def test_each_projectile_is_resolved_once_for_the_whole_session():
    """A party's spellbooks name the same handful of projectiles hundreds of
    times, and every miss costs an IDS lookup plus a PRO load."""
    runtime = radial_runtime(_PROJECTILE_STUBS)
    runtime.execute(
        """
        for _ = 1, 50 do
            BfBot.Class.IsRadialParty({ actionType = 5, missileType = 11 })
        end
        """
    )
    assert runtime.eval("TestLoads") == 1
    assert runtime.eval(
        "BfBot.Class.IsRadialParty({ actionType = 5, missileType = 11 })"
    ) is True


def test_an_unreadable_projectile_is_treated_as_an_ordinary_self_cast():
    """Failing closed: a missing or malformed PRO must not turn a
    single-target buff into a party cast the engine then refuses."""
    runtime = radial_runtime(
        'EEex_Resource_LoadIDS = function(_, _) error("no IDS here") end'
    )
    assert runtime.eval(
        "BfBot.Class.IsRadialParty({ actionType = 5, missileType = 10 })"
    ) is False
