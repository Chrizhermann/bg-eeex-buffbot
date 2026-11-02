"""The predicted spellbook of a caster that is not on the field yet (#107).

A clone has no book to scan until it exists, so the plan has to work it out
from the owner's book and the engine's own copy rules. Everything that matters
here is a native behaviour a tidier rule would get wrong, and getting one
wrong means the panel promises casts that will not happen -- so these tests
pin the rules themselves, not the code's shape.

The core needs no game: `S.Capacity` takes its 2DA lookup as a parameter, so
the spell-slot tables are fed in directly. `ReadProfile` is the only part that
needs an engine and is covered through stubs.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CORE_SOURCE = (ROOT / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")
SUMMON_SOURCE = (ROOT / "buffbot/BfBotSum.lua").read_text(encoding="utf-8")
SUMMON_PATH = ROOT / "buffbot/BfBotSum.lua"


def summon_runtime() -> LuaRuntime:
    """Core plus the prediction module. No scan, no engine."""
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute("io = nil")
    runtime.execute(CORE_SOURCE)
    runtime.execute("BfBot._Warn = function(_) end")
    runtime.execute(SUMMON_SOURCE)
    return runtime


# A spell-slot lookup that answers from a plain table, standing in for the
# MXSPL* 2DAs. `nil` for a table it does not know, which is what the real
# `S.Rule` returns when a 2DA cannot be read -- the distinction between "no
# slots" and "no rules" is load-bearing.
_RULES = """
function TestRule(tables)
    return function(name, row, column)
        local t = tables[name]
        if t == nil then return nil end
        local r = t[tostring(row)]
        if r == nil then return 0 end
        local value = r[tostring(column)]
        if value == nil then return 0 end
        return value
    end
end

function TestProfile(spec)
    local profile = {
        class = spec.class or 1,
        flags = spec.flags or 0,
        levels = spec.levels or { 1, 0, 0 },
        wis = spec.wis or 10,
        kit = spec.kit or 16384,
        copyLevel = spec.copyLevel,
        books = {},
        casterLevels = spec.casterLevels or {},
        availableCounts = spec.availableCounts,
    }
    for book, levels in pairs(spec.books or {}) do
        local rows = {}
        for level, entries in pairs(levels) do
            local list = {}
            for i, e in ipairs(entries) do
                list[i] = { res = e.res, name = e.name or e.res,
                            sortName = e.sortName or e.name or e.res,
                            flags = e.flags or 1 }
            end
            rows[level] = list
        end
        profile.books[book] = rows
    end
    return profile
end

--- A predicted level's resrefs in order, as "RES:flags" joined by spaces, so
--- a test can assert both survival and availability in one string.
function TestBookLine(prediction, book, level)
    local list = prediction.books[book] and prediction.books[book][level]
    if not list then return "" end
    local parts = {}
    for _, entry in ipairs(list) do
        parts[#parts + 1] = entry.res .. ":" .. tostring(entry.flags)
    end
    return table.concat(parts, " ")
end

function TestCount(prediction, res)
    return prediction.counts[res] or -1
end

function TestUsable(levels)
    local parts = {}
    for class, level in pairs(levels.usable) do
        parts[#parts + 1] = class .. "=" .. level
    end
    table.sort(parts)
    return table.concat(parts, " ")
end
"""


@pytest.fixture()
def lua() -> LuaRuntime:
    runtime = summon_runtime()
    runtime.execute(_RULES)
    return runtime


# ----------------------------------------------------------------------
# Class composition
# ----------------------------------------------------------------------


def test_a_single_class_has_one_component(lua: LuaRuntime) -> None:
    parts, active, previous = lua.eval("BfBot.Summon.Classes(1, 0)")
    assert list(parts.values()) == [1]
    assert active is None and previous is None


def test_a_dual_class_names_its_active_and_abandoned_half(lua: LuaRuntime) -> None:
    # Class 14 is FIGHTER_MAGE's priest/mage pairing {3, 1}; flag 32 marks
    # component 3 as the original, so the mage half is the active one.
    parts, active, previous = lua.eval("BfBot.Summon.Classes(14, 32)")
    assert list(parts.values()) == [3, 1]
    assert previous == 3
    assert active == 1


def test_an_unknown_class_is_refused_with_a_reason(lua: LuaRuntime) -> None:
    parts, reason = lua.eval("BfBot.Summon.Classes(99, 0)")
    assert parts is None
    assert "Unsupported caster class" in reason


# ----------------------------------------------------------------------
# The clone's levels
# ----------------------------------------------------------------------


def test_project_image_drains_nothing(lua: LuaRuntime) -> None:
    levels = lua.eval(
        "BfBot.Summon.CloneLevels(TestProfile({class=1, levels={20,0,0}}), 2)")
    assert levels.drain == 0
    assert lua.eval("TestUsable(...)", levels) == "1=20"


def test_simulacrum_drains_two_fifths_of_the_average_level(lua: LuaRuntime) -> None:
    # floor(2 * 20 / 5) = 8, so a level-20 mage's Simulacrum casts at 12.
    levels = lua.eval(
        "BfBot.Summon.CloneLevels(TestProfile({class=1, levels={20,0,0}}), 3)")
    assert levels.drain == 8
    assert lua.eval("TestUsable(...)", levels) == "1=12"


def test_the_drain_floors_at_level_one(lua: LuaRuntime) -> None:
    levels = lua.eval(
        "BfBot.Summon.CloneLevels(TestProfile({class=1, levels={3,0,0}}), 3)")
    assert lua.eval("TestUsable(...)", levels) == "1=2"
    deep = lua.eval(
        "BfBot.Summon.CloneLevels(TestProfile({class=1, levels={1,0,0}}), 3)")
    assert lua.eval("TestUsable(...)", deep) == "1=1"


def test_the_engines_own_average_is_used_when_the_sprite_supplied_one(
        lua: LuaRuntime) -> None:
    """`copyLevel` comes from `GetAverageLevel`, and it wins.

    In a dual class the engine's average-level query reads the first level
    field rather than a mean of the halves. Substituting a mean here would
    predict a different drain from the one the player gets.
    """
    levels = lua.eval(
        "BfBot.Summon.CloneLevels("
        "TestProfile({class=14, flags=32, levels={9,20,0}, copyLevel=9}), 3)")
    assert levels.drain == 3  # floor(2 * 9 / 5), from copyLevel, not from 14.5


def test_a_dual_classs_abandoned_half_is_held_back_until_passed(
        lua: LuaRuntime) -> None:
    """The old book is unusable while the new class is behind it."""
    behind = lua.eval(
        "BfBot.Summon.CloneLevels("
        "TestProfile({class=14, flags=32, levels={9,4,0}}), 2)")
    # Component 3 (abandoned, level 9) is absent; only the active mage half.
    assert lua.eval("TestUsable(...)", behind) == "1=4"

    ahead = lua.eval(
        "BfBot.Summon.CloneLevels("
        "TestProfile({class=14, flags=32, levels={9,12,0}}), 2)")
    assert lua.eval("TestUsable(...)", ahead) == "1=12 3=9"


# ----------------------------------------------------------------------
# Capacity
# ----------------------------------------------------------------------


def test_capacity_comes_from_the_classs_own_table(lua: LuaRuntime) -> None:
    count = lua.eval(
        "BfBot.Summon.Capacity("
        "TestProfile({class=1, levels={12,0,0}}),"
        "BfBot.Summon.CloneLevels(TestProfile({class=1, levels={12,0,0}}), 2),"
        "'Mage', 3, TestRule({MXSPLWIZ={['12']={['3']=4}}}))")
    assert count == 4


def test_a_specialist_wizard_gets_one_more_slot_per_level(
        lua: LuaRuntime) -> None:
    def capacity(kit: str) -> int:
        return lua.eval(
            "(function() local p = TestProfile({class=1, levels={12,0,0}, "
            f"kit={kit}}})"
            " return BfBot.Summon.Capacity(p,"
            " BfBot.Summon.CloneLevels(p, 2), 'Mage', 3,"
            " TestRule({MXSPLWIZ={['12']={['3']=4}}})) end)()")

    assert capacity("16384") == 4          # no kit
    assert capacity("0x0040") == 5         # a specialist school bit
    assert capacity("0x80000000") == 5     # the high specialist bit


def test_a_dragon_disciple_reads_its_own_table_and_keeps_the_kit_slot(
        lua: LuaRuntime) -> None:
    """MXSPLDD alone undercounts every level, so the kit slot is added."""
    count = lua.eval(
        "(function() local p = TestProfile({class=19, levels={12,0,0},"
        " kit=35+16384})"
        " return BfBot.Summon.Capacity(p, BfBot.Summon.CloneLevels(p, 2),"
        " 'Mage', 3, TestRule({MXSPLDD={['12']={['3']=2}},"
        " MXSPLSRC={['12']={['3']=5}}})) end)()")
    assert count == 3  # MXSPLDD's 2, not MXSPLSRC's 5, plus the kit slot


def test_a_cleric_adds_the_wisdom_bonus(lua: LuaRuntime) -> None:
    count = lua.eval(
        "(function() local p = TestProfile({class=3, levels={10,0,0}, wis=18})"
        " return BfBot.Summon.Capacity(p, BfBot.Summon.CloneLevels(p, 2),"
        " 'Priest', 2, TestRule({MXSPLPRS={['10']={['2']=3}},"
        " MXSPLWIS={['18']={['2']=2}}})) end)()")
    assert count == 5


def test_unreadable_rules_refuse_rather_than_answering_zero(
        lua: LuaRuntime) -> None:
    """A missing 2DA must not look like "this clone has no spells"."""
    count, reason = lua.eval(
        "(function() local p = TestProfile({class=1, levels={12,0,0}})"
        " return BfBot.Summon.Capacity(p, BfBot.Summon.CloneLevels(p, 2),"
        " 'Mage', 3, TestRule({})) end)()")
    assert count is None
    assert "MXSPLWIZ" in reason


def test_a_missing_wisdom_table_refuses_too(lua: LuaRuntime) -> None:
    count, reason = lua.eval(
        "(function() local p = TestProfile({class=3, levels={10,0,0}})"
        " return BfBot.Summon.Capacity(p, BfBot.Summon.CloneLevels(p, 2),"
        " 'Priest', 2, TestRule({MXSPLPRS={['10']={['2']=3}}})) end)()")
    assert count is None
    assert "Wisdom" in reason


# ----------------------------------------------------------------------
# The predicted book
# ----------------------------------------------------------------------


_BOOK = """
TestProfile({class=1, levels={12,0,0}, books={Mage={
    [1] = {
        {res='AAA', sortName='Zebra', flags=1},
        {res='BBB', sortName='Apple', flags=1},
        {res='CCC', sortName='Mango', flags=1},
    },
}}})
"""


def test_an_unsupported_image_type_is_refused(lua: LuaRuntime) -> None:
    prediction, reason = lua.eval(
        f"BfBot.Summon.Predict({_BOOK}, 1, TestRule({{}}))")
    assert prediction is None
    assert "Unsupported image type" in reason


def test_project_image_keeps_the_whole_list(lua: LuaRuntime) -> None:
    """Type 2 copies the book as it stands; capacity is the entry count."""
    prediction = lua.eval(
        f"BfBot.Summon.Predict({_BOOK}, 2, TestRule({{}}))")
    assert lua.eval("TestBookLine(...)", prediction, "Mage", 1) == (
        "AAA:1 BBB:1 CCC:1")


def test_project_image_preserves_spent_uses(lua: LuaRuntime) -> None:
    """A spell the owner already cast is not back on the image."""
    prediction = lua.eval(
        "BfBot.Summon.Predict(TestProfile({class=1, levels={12,0,0},"
        " books={Mage={[1]={{res='AAA', flags=1}, {res='BBB', flags=0}}}}}),"
        " 2, TestRule({}))")
    assert lua.eval("TestBookLine(...)", prediction, "Mage", 1) == "AAA:1 BBB:0"
    assert lua.eval("TestCount(...)", prediction, "AAA") == 1
    assert lua.eval("TestCount(...)", prediction, "BBB") == 0


def test_simulacrum_truncates_to_capacity_in_the_engines_name_order(
        lua: LuaRuntime) -> None:
    """The engine sorts by generic name, then cuts.

    Capacity 2 out of three entries: Apple and Mango survive, Zebra does not,
    whatever order the owner's book held them in.
    """
    prediction = lua.eval(
        f"BfBot.Summon.Predict({_BOOK}, 3,"
        # Row 8, not 12: the drain is floor(2 * 12 / 5) = 4.
        " TestRule({MXSPLWIZ={['8']={['1']=2}}}))")
    assert lua.eval("TestBookLine(...)", prediction, "Mage", 1) == (
        "BBB:1 CCC:1 AAA:0")
    assert lua.eval("TestCount(...)", prediction, "AAA") == 0


def test_simulacrum_refreshes_spent_uses(lua: LuaRuntime) -> None:
    """Type 3 re-memorizes, so a spent entry comes back."""
    prediction = lua.eval(
        "BfBot.Summon.Predict(TestProfile({class=1, levels={12,0,0},"
        " books={Mage={[1]={{res='AAA', flags=0}}}}}), 3,"
        " TestRule({MXSPLWIZ={['8']={['1']=4}}}))")
    assert lua.eval("TestCount(...)", prediction, "AAA") == 1


def test_a_stable_sort_keeps_equal_names_in_book_order(
        lua: LuaRuntime) -> None:
    prediction = lua.eval(
        "BfBot.Summon.Predict(TestProfile({class=1, levels={12,0,0},"
        " books={Mage={[1]={{res='AAA', sortName='Same'},"
        " {res='BBB', sortName='Same'}, {res='CCC', sortName='Same'}}}}}), 3,"
        " TestRule({MXSPLWIZ={['8']={['1']=2}}}))")
    assert lua.eval("TestBookLine(...)", prediction, "Mage", 1) == (
        "AAA:1 BBB:1 CCC:0")


def test_innate_abilities_are_never_truncated(lua: LuaRuntime) -> None:
    """They are not memorized slots, so capacity does not apply."""
    prediction = lua.eval(
        "BfBot.Summon.Predict(TestProfile({class=1, levels={12,0,0},"
        " books={Innate={[1]={{res='AAA'}, {res='BBB'}, {res='CCC'}}}}}), 3,"
        " TestRule({}))")
    assert lua.eval("TestBookLine(...)", prediction, "Innate", 1) == (
        "AAA:1 BBB:1 CCC:1")


def test_a_spontaneous_caster_gets_capacity_many_uses(lua: LuaRuntime) -> None:
    """A sorcerer holds no prepared list.

    The engine rebuilds the copy from the known choices and the class
    capacity, so a memorized list with one entry still yields the full number
    of casts -- taking the list's length would under-predict every sorcerer.
    """
    prediction = lua.eval(
        "BfBot.Summon.Predict(TestProfile({class=19, levels={12,0,0},"
        " books={Mage={[1]={{res='AAA', flags=1}}}}}), 3,"
        " TestRule({MXSPLSRC={['8']={['1']=5}}}))")
    assert lua.eval("TestCount(...)", prediction, "AAA") == 5
    assert lua.eval("TestBookLine(...)", prediction, "Mage", 1) == (
        "AAA:1 AAA:1 AAA:1 AAA:1 AAA:1")


def test_a_spontaneous_image_uses_the_owners_remaining_casts(
        lua: LuaRuntime) -> None:
    """Project Image preserves what the sorcerer has left, not the capacity."""
    prediction = lua.eval(
        "BfBot.Summon.Predict(TestProfile({class=19, levels={12,0,0},"
        " availableCounts={AAA=2},"
        " books={Mage={[1]={{res='AAA', flags=1}}}}}), 2,"
        " TestRule({MXSPLSRC={['12']={['1']=5}}}))")
    assert lua.eval("TestCount(...)", prediction, "AAA") == 2


def test_unreadable_rules_stop_the_prediction(lua: LuaRuntime) -> None:
    prediction, reason = lua.eval(
        f"BfBot.Summon.Predict({_BOOK}, 3, TestRule({{}}))")
    assert prediction is None
    assert "MXSPLWIZ" in reason


# ----------------------------------------------------------------------
# What the owner has now
# ----------------------------------------------------------------------


def test_book_counts_only_count_unspent_entries(lua: LuaRuntime) -> None:
    counts = lua.eval(
        "BfBot.Summon.BookCounts(TestProfile({class=1, levels={12,0,0},"
        " books={Mage={[1]={{res='AAA', flags=1}, {res='AAA', flags=0},"
        " {res='BBB', flags=1}}}}}))")
    assert counts["AAA"] == 1
    assert counts["BBB"] == 1


# ----------------------------------------------------------------------
# Casting level
# ----------------------------------------------------------------------


def test_an_arcane_spell_takes_the_best_arcane_component(
        lua: LuaRuntime) -> None:
    assert lua.eval(
        "BfBot.Summon._CastingLevel({[1]=7, [3]=12}, 1)") == 7


def test_a_divine_spell_offsets_paladins_and_rangers(lua: LuaRuntime) -> None:
    """Their priest list starts above level 1, so the class level is shifted.

    A level-9 paladin casts as a level-1 priest, not a level-9 one.
    """
    assert lua.eval("BfBot.Summon._CastingLevel({[6]=9}, 2)") == 1
    assert lua.eval("BfBot.Summon._CastingLevel({[12]=10}, 2)") == 3
    assert lua.eval("BfBot.Summon._CastingLevel({[3]=9}, 2)") == 9


def test_an_unknown_spell_type_takes_the_best_level_available(
        lua: LuaRuntime) -> None:
    assert lua.eval("BfBot.Summon._CastingLevel({[1]=4, [3]=11}, 0)") == 11


def test_a_casting_level_is_never_below_one(lua: LuaRuntime) -> None:
    assert lua.eval("BfBot.Summon._CastingLevel({}, 1)") == 1
    assert lua.eval("BfBot.Summon._CastingLevel({}, 2)") == 1
    assert lua.eval("BfBot.Summon._CastingLevel({}, 0)") == 1


# ----------------------------------------------------------------------
# Source hygiene
# ----------------------------------------------------------------------


def test_the_module_uses_no_bare_bit_library(lua: LuaRuntime) -> None:
    """Issue #106: a bare `bit.band` stops BuffBot loading without LuaJIT."""
    source = SUMMON_PATH.read_text(encoding="utf-8")
    offenders = [
        line.strip() for line in source.splitlines()
        if "bit." in line and not line.strip().startswith("--")
    ]
    assert offenders == []


def test_the_2da_reader_is_the_only_engine_dependency_of_the_core() -> None:
    """The prediction core has to stay testable without a game.

    `Predict`, `CloneLevels`, `Capacity`, `Classes` and `BookCounts` must not
    reach for the engine: `Capacity` takes its lookup as a parameter, and that
    is what lets every rule above be pinned offline. `ReadProfile` and
    `BuildRows` are the parts that may.
    """
    source = SUMMON_PATH.read_text(encoding="utf-8")
    core_start = source.index("function S.Classes")
    core_end = source.index("function S.ReadProfile")
    core = source[core_start:core_end]
    allowed = {"EEex_Resource_Load2DA"}
    found = {
        name for name in (
            word.split("(")[0].strip("(),.:")
            for line in core.splitlines()
            for word in line.split()
            if word.startswith("EEex_") or ".EEex_" in word
        ) if name.startswith("EEex_")
    }
    assert found <= allowed, found
