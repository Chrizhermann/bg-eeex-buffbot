"""Only what the PARTY conjured may be driven as a summon caster (issue #101).

Reported from a live BG2 playthrough: standing next to Vithal, the friendly
quest mage of the Underdark elemental-portal quest, BuffBot offered his whole
spellbook — Time Stop included — as if he were a summon. He is not. He passes
the allied EA band (2..30) like every summon does, and nothing downstream ever
asked the one question that separates them: did anybody in the party conjure
this creature?

Two engine links answer it and the filter now requires one of them:
  clone  — m_bInCopy / m_nCopyParent  (Project Image, Simulacrum, Mislead)
  summon — m_lSummonedBy.m_Instance, the engine's own SUMMONED_BY object
           (EEex_Marshal.lua reads exactly this field), plus EEex's UDAux
           summoner UUID as the save/load fallback.

The band itself stays untouched: it still has to let CONTROLLED(5) and
CHARMED(6) summons through, because a dominated creature's own skeletons are
still the party's.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
SCAN_SOURCE = (ROOT / "buffbot/BfBotScn.lua").read_text(encoding="utf-8")
EXEC_SOURCE = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")


# A sprite here is a plain table carrying only the fields the filter reads.
# `origin` spells out the engine linkage:
#   nothing         -> never conjured (Vithal, a charmed enemy, an area spawn)
#   summonedBy = id -> m_lSummonedBy.m_Instance
#   copyParent = id -> m_nCopyParent (+ stat 139 clone type)
#   summonerUUID    -> EEex's UDAux key, set at summon time, marshalled
#   blind = true    -> an engine build where none of the fields can be read
_HELPERS = """
objects, scanCalls, warnings = {}, {}, {}
BfBot._Warn = function(message) warnings[#warnings + 1] = message end

local blindMeta = { __index = function(_, key)
    error("no such field on this build: " .. tostring(key), 0)
end }

function Sprite(spec)
    local sprite = {
        m_id = spec.id,
        m_baseStats = { m_generalState = spec.state or 0 },
        m_typeAI = { m_EnemyAlly = spec.ea or 4 },
        m_scriptName = { get = function() return spec.scriptName or "" end },
        m_resref = { get = function() return spec.cre or "" end },
        _portrait = spec.portrait or -1,
        _name = spec.name or "Something",
        _stat139 = spec.cloneType or 0,
        _uuid = spec.summonerUUID,
        _spells = spec.spells == nil and 3 or spec.spells,
    }
    sprite.getStat = function(_, id)
        if id == 139 then return sprite._stat139 end
        return 0
    end
    if spec.blind then
        setmetatable(sprite, blindMeta)
    else
        sprite.m_nCopyParent = spec.copyParent or -1
        sprite.m_bInCopy = spec.copyParent ~= nil
        sprite.m_lSummonedBy = { m_Instance = spec.summonedBy or 0 }
    end
    if spec.id then objects[spec.id] = sprite end
    return sprite
end

EEex_BAnd = function(a, b)
    local result, bit = 0, 1
    while a > 0 or b > 0 do
        if (a % 2 == 1) and (b % 2 == 1) then result = result + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return result
end
EEex_Sprite_GetPortraitIndex = function(sprite) return sprite._portrait end
EEex_GameObject_Get = function(id) return objects[id] end
EEex_GameObject_IsSprite = function(object) return object ~= nil end
EEex_GameObject_CastUserType = function(object) return object end
EEex_GetUDAux = function(sprite)
    return { EEex_SummonerUUID = sprite._uuid }
end
BfBot._GetName = function(sprite) return sprite._name end
"""


@pytest.fixture
def lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        BfBot = { _cache = { class = {}, scan = {}, summons = nil },
                  _overrides = {}, _fields = {}, Scan = {}, Class = {} }
        """
    )
    runtime.execute(_HELPERS)
    runtime.execute(SCAN_SOURCE)
    runtime.execute(
        """
        -- The spellbook scan is the expensive filter; count its calls so the
        -- cost ordering (origin check first) is testable.
        BfBot.Scan.GetCastableSpells = function(sprite)
            scanCalls[#scanCalls + 1] = sprite._name
            return {}, sprite._spells
        end
        """
    )
    return runtime


def classify(lua: LuaRuntime, sprite):
    """Always (entry, reason) — Lua hands back a bare value for a single
    return, a tuple only when the reason is there too."""
    result = lua.eval("BfBot.Scan.ClassifySummonSprite")(sprite)
    return result if isinstance(result, tuple) else (result, None)


def party_member(lua: LuaRuntime, *, id: int, slot: int, name: str = "Jan"):
    return lua.eval("Sprite")(
        lua.table_from({"id": id, "portrait": slot, "name": name, "ea": 2})
    )


def make(lua: LuaRuntime, **spec):
    return lua.eval("Sprite")(lua.table_from(spec))


# ---------------------------------------------------------------------------
# The report: a friendly NPC is not a summon
# ---------------------------------------------------------------------------


def test_friendly_quest_npc_is_rejected(lua):
    """Vithal: alive, not in the party, EA ALLY, a full spellbook — and nobody
    conjured him. The whole point of the issue."""
    party_member(lua, id=1, slot=0)
    vithal = make(lua, id=50, name="Vithal", ea=4, scriptName="VITHAL")

    entry, reason = classify(lua, vithal)

    assert entry is None
    assert reason == "origin"


def test_charmed_enemy_is_rejected(lua):
    """EA CHARMED(6) sits inside the allied band, so the band alone would hand
    the player a dominated enemy mage's spellbook for as long as the charm
    holds."""
    party_member(lua, id=1, slot=0)
    charmed = make(lua, id=51, name="Enemy Mage", ea=6)

    entry, reason = classify(lua, charmed)

    assert entry is None
    assert reason == "origin"


def test_rejected_ally_never_pays_for_a_spellbook_scan(lua):
    """Cost ordering: the origin check is a handful of field reads and must run
    before the per-sprite spellbook scan, which is the expensive one."""
    party_member(lua, id=1, slot=0)
    classify(lua, make(lua, id=50, name="Vithal"))

    assert list(lua.eval("scanCalls").values()) == []


def test_party_member_is_still_excluded_by_the_portrait_filter(lua):
    leader = party_member(lua, id=1, slot=0, name="Protagonist")

    assert classify(lua, leader)[0] is None


# ---------------------------------------------------------------------------
# What the party conjured still gets through
# ---------------------------------------------------------------------------


def test_party_summon_is_accepted(lua):
    """A skeleton Jan summoned: m_lSummonedBy points at his object id."""
    party_member(lua, id=1, slot=0, name="Jan")
    skeleton = make(lua, id=60, name="Skeleton Warrior", summonedBy=1,
                    scriptName="SKELETON")

    entry, _ = classify(lua, skeleton)

    assert entry is not None
    assert entry["kind"] == "summon"
    assert entry["oid"] == 60
    assert entry["identity"] == "skeleton"


def test_project_image_clone_is_accepted_with_its_owner(lua):
    """The clone path is unchanged: owner name still keys the config, clone
    type still comes from stat 139."""
    party_member(lua, id=1, slot=0, name="Jan")
    image = make(lua, id=61, name="Jan", copyParent=1, cloneType=2,
                 scriptName="COPY")

    entry, _ = classify(lua, image)

    assert entry is not None
    assert entry["kind"] == "clone"
    assert entry["cloneType"] == 2
    assert entry["ownerName"] == "Jan"
    assert entry["identity"] == "clone:Jan"


def test_familiar_summoned_by_a_party_member_is_accepted(lua):
    party_member(lua, id=1, slot=2, name="Imoen")
    imp = make(lua, id=62, name="Imp", ea=3, summonedBy=1, scriptName="IMP")

    assert classify(lua, imp)[0] is not None


def test_summon_of_a_clone_reaches_the_party_through_the_chain(lua):
    """A Simulacrum casting Planetar: the Planetar's summoner is the
    Simulacrum, whose copy parent is a PC. The chain decides, not the direct
    owner."""
    party_member(lua, id=1, slot=0, name="Protagonist")
    make(lua, id=70, name="Protagonist", copyParent=1, cloneType=3,
         scriptName="COPY")
    planetar = make(lua, id=71, name="Planetar", summonedBy=70,
                    scriptName="PLANETAR")

    entry, _ = classify(lua, planetar)

    assert entry is not None
    assert entry["kind"] == "summon"


def test_npc_own_summon_is_rejected(lua):
    """An elemental Vithal summoned for himself: allied, conjured — but the
    chain ends at a creature the party does not command."""
    party_member(lua, id=1, slot=0)
    make(lua, id=50, name="Vithal")
    elemental = make(lua, id=52, name="Fire Elemental", summonedBy=50)

    entry, reason = classify(lua, elemental)

    assert entry is None
    assert reason == "origin"


# ---------------------------------------------------------------------------
# Degradation: never hide the player's own summons
# ---------------------------------------------------------------------------


def test_summon_whose_summoner_is_gone_is_kept(lua):
    """The summoner died or has not been restored yet. The creature still
    carries a summoner link, so it WAS conjured — dropping it would make the
    player's own summons vanish from the panel at the worst moment."""
    party_member(lua, id=1, slot=0)
    orphan = make(lua, id=63, name="Skeleton", summonedBy=999)

    assert classify(lua, orphan)[0] is not None


def test_udaux_summoner_uuid_carries_a_summon_across_a_save_load(lua):
    """The engine does not persist the summoner link; EEex restores it
    asynchronously from a UUID it keeps in UDAux. Between the load and that
    callback the live field is empty while the UUID already proves the
    creature was summoned."""
    party_member(lua, id=1, slot=0)
    loaded = make(lua, id=64, name="Skeleton", summonedBy=0,
                  summonerUUID="uuid-1234")

    entry, _ = classify(lua, loaded)

    assert entry is not None
    assert entry["kind"] == "summon"


def test_engine_without_the_linkage_fields_stays_permissive(lua):
    """Compatibility posture: on a build where not one linkage field can be
    read, the filter must fall back to the old behaviour instead of emptying
    the Summons view."""
    party_member(lua, id=1, slot=0)
    opaque = make(lua, id=65, name="Mystery Summon", blind=True)

    entry, _ = classify(lua, opaque)

    assert entry is not None
    assert entry["kind"] == "summon"


def test_owner_chain_cycle_does_not_hang_or_reject(lua):
    """A linkage loop is unresolvable, not evidence of an NPC owner."""
    lua.execute("objects[80] = Sprite({ id = 80, summonedBy = 81 })")
    lua.execute("objects[81] = Sprite({ id = 81, summonedBy = 80 })")

    assert lua.eval("BfBot.Scan._OwnerChainReachesParty(80)") is None


def test_owner_chain_depth_is_bounded(lua):
    """Three steps is the budget; a longer chain reads as unresolvable rather
    than walking the area forever."""
    party_member(lua, id=1, slot=0)
    for oid in range(90, 95):
        make(lua, id=oid, summonedBy=oid + 1 if oid < 94 else 1)

    assert lua.eval("BfBot.Scan._OWNER_CHAIN_MAX") == 3
    assert lua.eval("BfBot.Scan._OwnerChainReachesParty(90)") is None


# ---------------------------------------------------------------------------
# The late-join contract
# ---------------------------------------------------------------------------


def test_late_join_retries_an_origin_reject(lua):
    """A sprite that JUST loaded has not had its linkage set yet (the engine
    settles it in the same window as the name, probe 2026-07-14). The late-join
    path classifies exactly such sprites, so an "origin" verdict there has to
    mean "retry", not "drop" — otherwise a Planetar summoned mid-run never
    joins the queue."""
    assert 'return why == "origin"' in EXEC_SOURCE


def test_origin_reason_is_the_only_retryable_one(lua):
    """Every other reject (dead, party, hostile, no spells) returns a bare nil,
    so the late-join path drops those immediately."""
    party_member(lua, id=1, slot=0)
    hostile = make(lua, id=66, name="Enemy", ea=255, summonedBy=1)
    spell_less = make(lua, id=67, name="Bear", summonedBy=1, spells=0)

    assert classify(lua, hostile)[1] is None
    assert classify(lua, spell_less)[1] is None
