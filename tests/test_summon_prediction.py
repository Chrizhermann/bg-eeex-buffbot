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
# What a row creates (step B)
# ----------------------------------------------------------------------
#
# `Discover` walks installed data, so these tests supply it: a fake resource
# layer with SPL/ITM/EFF headers whose feature blocks are plain tables. That is
# the whole point of the walk being structural -- it can be driven without a
# game, and a mod's wrapper chain is just another table here.

_DISCOVER_WORLD = """
-- Each resource is { casting = {blocks}, abilities = { {blocks}, ... } }.
function TestResources(spec)
    local demanded = {}
    EEex_Resource_Demand = function(res, kind)
        local entry = spec[kind .. ":" .. res:upper()]
        demanded[#demanded + 1] = kind .. ":" .. res:upper()
        if not entry then return nil end
        if kind == "EFF" then
            return { m_effectId = entry.opcode, m_dWFlags = entry.param2,
                     m_res = entry.res }
        end
        local header = {
            castingStartingEffect = 0,
            castingEffectCount = entry.casting and #entry.casting or 0,
            _casting = entry.casting or {},
            _abilities = entry.abilities or {},
        }
        function header:getAbilityForLevel(_)
            return self._abilities[1] and { _blocks = self._abilities[1] } or nil
        end
        return header
    end
    BfBot.Scan = BfBot.Scan or {}
    BfBot.Scan._GetItemAbility = function(header, index)
        local blocks = header._abilities[(index or 0) + 1]
        return blocks and { _blocks = blocks } or nil
    end
    -- The shared iterator, standing in for the classifier's: it is handed
    -- either an ability (our fake, carrying _blocks) or the synthetic casting
    -- ability, whose keys come from the field map.
    BfBot.Class = BfBot.Class or {}
    BfBot.Class._IterateFeatureBlocks = function(header, ability, fn)
        local blocks = ability._blocks
        if not blocks then
            local count = ability[BfBot._fields.fb_count] or 0
            if count > 0 then blocks = header._casting end
        end
        for index, block in ipairs(blocks or {}) do
            if fn(block, index - 1) then return end
        end
    end
    return demanded
end

function TestBlock(opcode, param2, res)
    return { [BfBot._fields.fb_opcode] = opcode,
             [BfBot._fields.fb_param2] = param2,
             [BfBot._fields.fb_res] = res }
end

function TestFound(list)
    local parts = {}
    for _, d in ipairs(list) do
        parts[#parts + 1] = d.kind == "clone"
            and ("clone/" .. d.image)
            or (d.resource .. "/" .. d.opcode)
    end
    return table.concat(parts, " ")
end
"""


@pytest.fixture()
def world(lua: LuaRuntime) -> LuaRuntime:
    lua.execute(_DISCOVER_WORLD)
    return lua


def test_a_project_image_spell_is_found_by_its_opcode(world: LuaRuntime) -> None:
    world.eval("TestResources({['SPL:SPWI714'] = {abilities = {"
               "{TestBlock(236, 2, nil)}}}})")
    found = world.eval("BfBot.Summon.Discover({kind='spl', resref='SPWI714'})")
    assert world.eval("TestFound(...)", found) == "clone/2"


def test_a_simulacrum_is_image_type_three(world: LuaRuntime) -> None:
    world.eval("TestResources({['SPL:SPWI713'] = {abilities = {"
               "{TestBlock(236, 3, nil)}}}})")
    found = world.eval("BfBot.Summon.Discover({kind='spl', resref='SPWI713'})")
    assert world.eval("TestFound(...)", found) == "clone/3"


def test_mislead_is_not_a_planned_caster(world: LuaRuntime) -> None:
    """Image type 1 copies no spellbook, so there is nothing to predict."""
    world.eval("TestResources({['SPL:SPWI613'] = {abilities = {"
               "{TestBlock(236, 1, nil)}}}})")
    found = world.eval("BfBot.Summon.Discover({kind='spl', resref='SPWI613'})")
    assert world.eval("TestFound(...)", found) == ""


def test_both_summon_opcodes_report_their_creature(world: LuaRuntime) -> None:
    world.eval("TestResources({['SPL:SPPR701'] = {abilities = {"
               "{TestBlock(67, 0, 'planetar'), TestBlock(127, 0, 'deva')}}}})")
    found = world.eval("BfBot.Summon.Discover({kind='spl', resref='SPPR701'})")
    assert world.eval("TestFound(...)", found) == "PLANETAR/67 DEVA/127"


def test_a_wrapper_spell_is_followed_through_op146(world: LuaRuntime) -> None:
    world.eval("TestResources({"
               "['SPL:WRAP'] = {abilities = {{TestBlock(146, 0, 'inner')}}},"
               "['SPL:INNER'] = {abilities = {{TestBlock(236, 2, nil)}}}})")
    found = world.eval("BfBot.Summon.Discover({kind='spl', resref='WRAP'})")
    assert world.eval("TestFound(...)", found) == "clone/2"


def test_an_eff_file_is_followed_through_op177(world: LuaRuntime) -> None:
    world.eval("TestResources({"
               "['SPL:VIAEFF'] = {abilities = {{TestBlock(177, 0, 'theeff')}}},"
               "['EFF:THEEFF'] = {opcode = 67, param2 = 0, res = 'planetar'}})")
    found = world.eval("BfBot.Summon.Discover({kind='spl', resref='VIAEFF'})")
    assert world.eval("TestFound(...)", found) == "PLANETAR/67"


def test_a_spells_casting_effects_are_walked_too(world: LuaRuntime) -> None:
    """A wrapper can deliver the creation from the casting block."""
    world.eval("TestResources({['SPL:ATCAST'] = {"
               "casting = {TestBlock(236, 3, nil)}, abilities = {{}}}})")
    found = world.eval("BfBot.Summon.Discover({kind='spl', resref='ATCAST'})")
    assert world.eval("TestFound(...)", found) == "clone/3"


def test_an_item_power_can_create_a_caster(world: LuaRuntime) -> None:
    """A borrowed helm is a creation mechanic like any other."""
    world.eval("TestResources({['ITM:HELM'] = {abilities = {"
               "{TestBlock(0, 0, nil)}, {TestBlock(236, 3, nil)}}}})")
    found = world.eval(
        "BfBot.Summon.Discover({kind='itm', itemResref='HELM', abilityIdx=1})")
    assert world.eval("TestFound(...)", found) == "clone/3"


def test_a_cycle_cannot_run_away(world: LuaRuntime) -> None:
    world.eval("TestResources({"
               "['SPL:LOOPA'] = {abilities = {{TestBlock(146, 0, 'loopb')}}},"
               "['SPL:LOOPB'] = {abilities = {{TestBlock(146, 0, 'loopa')}}}})")
    found = world.eval("BfBot.Summon.Discover({kind='spl', resref='LOOPA'})")
    assert world.eval("TestFound(...)", found) == ""


def test_the_walk_stops_at_depth_four(world: LuaRuntime) -> None:
    """Five links deep is past the limit, so the clone at the end is not seen.

    The limit is what keeps a mod's deep wrapper chain from costing the panel
    a frame; a creation that far down is not reported rather than guessed at.
    """
    spec = ["['SPL:L0'] = {abilities = {{TestBlock(146, 0, 'l1')}}}"]
    for index in range(1, 5):
        spec.append(
            f"['SPL:L{index}'] = {{abilities = {{{{TestBlock(146, 0, "
            f"'l{index + 1}')}}}}}}")
    spec.append("['SPL:L5'] = {abilities = {{TestBlock(236, 2, nil)}}}")
    world.eval("TestResources({" + ",".join(spec) + "})")
    found = world.eval("BfBot.Summon.Discover({kind='spl', resref='L0'})")
    assert world.eval("TestFound(...)", found) == ""


def test_a_missing_resource_is_not_an_error(world: LuaRuntime) -> None:
    world.eval("TestResources({})")
    found = world.eval("BfBot.Summon.Discover({kind='spl', resref='GONE'})")
    assert world.eval("TestFound(...)", found) == ""


# ----------------------------------------------------------------------
# Which creations are worth planning for
# ----------------------------------------------------------------------


_CREATORS_WORLD = """
function TestCreatureBooks(books)
    BfBot.Summon.ClearCaches()
    BfBot.Summon.ReadCreature = function(resource)
        local entry = books[resource:upper()]
        if not entry then return nil, 'absent' end
        return entry.profile
    end
    BfBot.Summon.BuildRows = function(profile)
        return (books[tostring(profile.resource):upper()] or {}).rows or {}
    end
    BfBot.Plan = BfBot.Plan or {}
    BfBot.Plan.IsAutomaticBuff = function(row) return row.buff == 1 end
end
"""


@pytest.fixture()
def creators(world: LuaRuntime) -> LuaRuntime:
    world.execute(_CREATORS_WORLD)
    return world


def test_a_clone_always_counts(creators: LuaRuntime) -> None:
    """Its book is the owner's, so there is nothing to look up."""
    creators.eval("TestResources({['SPL:PI'] = {abilities = {"
                  "{TestBlock(236, 2, nil)}}}})")
    creators.eval("TestCreatureBooks({})")
    found = creators.eval(
        "BfBot.Summon.Creators({kind='spl', resref='PI', casterLevel=12})")
    assert creators.eval("TestFound(...)", found) == "clone/2"
    assert creators.eval(
        "BfBot.Summon.IsCreator({kind='spl', resref='PI', casterLevel=12})")


def test_a_summon_with_a_usable_buff_counts(creators: LuaRuntime) -> None:
    creators.eval("TestResources({['SPL:CALL'] = {abilities = {"
                  "{TestBlock(67, 0, 'planetar')}}}})")
    creators.eval("TestCreatureBooks({PLANETAR = {"
                  "profile = {resource = 'PLANETAR'},"
                  "rows = {HASTE = {count = 2, buff = 1, isSelfOnly = 0}}}})")
    found = creators.eval(
        "BfBot.Summon.Creators({kind='spl', resref='CALL', casterLevel=12})")
    assert creators.eval("TestFound(...)", found) == "PLANETAR/67"


def test_a_summon_whose_buffs_are_all_spent_does_not_count(
        creators: LuaRuntime) -> None:
    creators.eval("TestResources({['SPL:CALL'] = {abilities = {"
                  "{TestBlock(67, 0, 'planetar')}}}})")
    creators.eval("TestCreatureBooks({PLANETAR = {"
                  "profile = {resource = 'PLANETAR'},"
                  "rows = {HASTE = {count = 0, buff = 1, isSelfOnly = 0}}}})")
    found = creators.eval(
        "BfBot.Summon.Creators({kind='spl', resref='CALL', casterLevel=12})")
    assert creators.eval("TestFound(...)", found) == ""


def test_a_summon_that_can_only_buff_itself_does_not_count(
        creators: LuaRuntime) -> None:
    """A caster that reaches nobody is not a caster worth offering."""
    creators.eval("TestResources({['SPL:CALL'] = {abilities = {"
                  "{TestBlock(67, 0, 'brute')}}}})")
    creators.eval("TestCreatureBooks({BRUTE = {"
                  "profile = {resource = 'BRUTE'},"
                  "rows = {RAGE = {count = 2, buff = 1, isSelfOnly = 1,"
                  " isAoE = 0}}}})")
    found = creators.eval(
        "BfBot.Summon.Creators({kind='spl', resref='CALL', casterLevel=12})")
    assert creators.eval("TestFound(...)", found) == ""


def test_a_self_only_area_cast_still_counts(creators: LuaRuntime) -> None:
    """A radial aura is cast on self and lands on everybody."""
    creators.eval("TestResources({['SPL:CALL'] = {abilities = {"
                  "{TestBlock(67, 0, 'chanter')}}}})")
    creators.eval("TestCreatureBooks({CHANTER = {"
                  "profile = {resource = 'CHANTER'},"
                  "rows = {CHANT = {count = 1, buff = 1, isSelfOnly = 1,"
                  " isAoE = 1}}}})")
    found = creators.eval(
        "BfBot.Summon.Creators({kind='spl', resref='CALL', casterLevel=12})")
    assert creators.eval("TestFound(...)", found) == "CHANTER/67"


def test_a_summon_whose_spells_are_not_buffs_does_not_count(
        creators: LuaRuntime) -> None:
    creators.eval("TestResources({['SPL:CALL'] = {abilities = {"
                  "{TestBlock(67, 0, 'archer')}}}})")
    creators.eval("TestCreatureBooks({ARCHER = {"
                  "profile = {resource = 'ARCHER'},"
                  "rows = {ARROW = {count = 9, buff = 0, isSelfOnly = 0}}}})")
    found = creators.eval(
        "BfBot.Summon.Creators({kind='spl', resref='CALL', casterLevel=12})")
    assert creators.eval("TestFound(...)", found) == ""


def test_an_unreadable_creature_is_not_guessed_at(creators: LuaRuntime) -> None:
    """A CRE that cannot be read yields no caster, never a assumed book."""
    creators.eval("TestResources({['SPL:CALL'] = {abilities = {"
                  "{TestBlock(67, 0, 'mystery')}}}})")
    creators.eval("TestCreatureBooks({})")
    found = creators.eval(
        "BfBot.Summon.Creators({kind='spl', resref='CALL', casterLevel=12})")
    assert creators.eval("TestFound(...)", found) == ""


def test_a_selected_variant_is_what_gets_inspected(
        creators: LuaRuntime) -> None:
    """The parent is a selection wrapper; the variant is what is cast."""
    creators.eval("TestResources({"
                  "['SPL:PARENT'] = {abilities = {{TestBlock(214, 0, nil)}}},"
                  "['SPL:CHOSEN'] = {abilities = {{TestBlock(236, 3, nil)}}}})")
    creators.eval("TestCreatureBooks({})")
    plain = creators.eval(
        "BfBot.Summon.Creators({kind='spl', resref='PARENT', casterLevel=12})")
    assert creators.eval("TestFound(...)", plain) == ""
    chosen = creators.eval(
        "BfBot.Summon.Creators({kind='spl', resref='PARENT', casterLevel=12},"
        " 'CHOSEN')")
    assert creators.eval("TestFound(...)", chosen) == "clone/3"


def test_the_answer_is_cached_per_row_and_caster_level(
        creators: LuaRuntime) -> None:
    """The panel asks this per row per frame; the walk must not repeat."""
    demanded = creators.eval("TestResources({['SPL:PI'] = {abilities = {"
                             "{TestBlock(236, 2, nil)}}}})")
    creators.eval("TestCreatureBooks({})")
    row = "{kind='spl', resref='PI', casterLevel=12}"
    creators.eval(f"BfBot.Summon.Creators({row})")
    first = len(demanded)
    creators.eval(f"BfBot.Summon.Creators({row})")
    assert len(demanded) == first

    # A different caster level is a different question: the ability a spell
    # uses can change with level, so the cache key has to carry it.
    creators.eval("BfBot.Summon.Creators({kind='spl', resref='PI',"
                  " casterLevel=20})")
    assert len(demanded) > first


# ----------------------------------------------------------------------
# Predicted casters as plan sources (step C)
# ----------------------------------------------------------------------
#
# These run against the real plan model, because the two budget rules are
# statements about its pools and a stub would let either of them pass while
# being wrong in the game.

PLAN_SOURCE = (ROOT / "buffbot/BfBotPln.lua").read_text(encoding="utf-8")
LOC_SOURCE = (ROOT / "buffbot/BfBotLoc.lua").read_text(encoding="utf-8")
CLASS_SOURCE = (ROOT / "buffbot/BfBotCls.lua").read_text(encoding="utf-8")
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")


# Raw: this is Lua source, so a backslash in it belongs to Lua. Without the
# prefix, `"\n"` below became a real newline and left an unterminated Lua
# string literal.
_PLAN_WORLD = r"""
-- A snapshot with one party owner and, optionally, one live summon of the
-- thing the owner would conjure. Built directly: Snapshot needs an engine,
-- and what is under test is what AddSources does to a snapshot's pools.
function TestPlanSnapshot(spec)
    local snap = { actors = {}, order = {}, groups = {}, pools = {},
                   casterActors = {}, casters = {} }
    local owner = {
        key = "protagonist", name = spec.ownerName or "Owner", slot = 0,
        casterRef = { kind = "party", slot = 0 }, class = spec.ownerClass or 1,
        alive = true, controlled = true,
        projectImageLocked = spec.locked or nil,
        sprite = { m_id = 100 },
        rows = {},
    }
    snap.actors[owner.key] = owner
    snap.order[1] = owner
    snap.casterActors[owner.key] = owner
    snap.casters[1] = owner

    -- The creation step itself: one group whose single source is the owner's.
    local row = { kind = "spl", resref = spec.creation or "PI",
                  name = "The Creation", level = 7, spellType = 1, count = 1,
                  casterLevel = spec.ownerLevel or 12, duration = 0,
                  isAoE = 0, isSelfOnly = 1, class = { isBuff = true } }
    owner.rows[row.resref] = row
    local groupKey = BfBot.Plan.GroupKey(row)
    snap.groups[groupKey] = { key = groupKey, name = row.name, kind = "spl",
        sources = { {
            id = "protagonist/" .. groupKey, actor = owner.key,
            casterName = owner.name, slot = 0, casterRef = owner.casterRef,
            lane = owner.key, row = row,
            pool = owner.key .. ":spell:" .. row.resref,
            duration = 0, casterLevel = row.casterLevel,
            selfOnly = true, aoe = false, variantDurations = {},
        } } }
    snap.pools[owner.key .. ":spell:" .. row.resref] = spec.creationUses or 1

    if spec.liveSummon then
        local liveActor = {
            key = "summon:clone:protagonist:" .. tostring(spec.liveSummon),
            name = "Live Copy",
            poolKey = "summon:live:777", casterRef = { kind = "summon",
                oid = 777, name = "Live Copy" },
            sprite = { m_id = 777, m_resref = { get = function()
                return spec.liveResref or "COPY" end } },
            class = 1, alive = true, controlled = true, rows = {},
        }
        snap.casterActors[liveActor.key] = liveActor
        snap.casters[#snap.casters + 1] = liveActor
    end

    return snap, groupKey, row
end

function TestRequests(groupKey, spec)
    return { { group = groupKey, target = spec.target or "protagonist",
               on = 1, rep = 1, manual = 1 } }
end

--- What AddSources did: the predicted actors, their pool keys and the
--- capacity each pool ended up with.
function TestPredicted(snap)
    local parts = {}
    for _, actor in ipairs(snap.casters) do
        if actor.future or actor.key:find("^summon:planned:") then
            parts[#parts + 1] = actor.key .. "|pool=" .. tostring(actor.poolKey)
                .. "|name=" .. actor.name
        end
    end
    table.sort(parts)
    return table.concat(parts, "\n")
end

function TestPool(snap, key)
    local value = snap.pools[key]
    if value == nil then return -1 end
    return value
end

function TestPoolKeys(snap)
    local parts = {}
    for key, value in pairs(snap.pools) do
        parts[#parts + 1] = key .. "=" .. value
    end
    table.sort(parts)
    return table.concat(parts, " ")
end
"""


def plan_world() -> LuaRuntime:
    """Core, classifier, localization, persistence, the planner, the module."""
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
            DescribeSpell = function(_, _) return nil end,
            _ReadSummonOrigin = function(_) return nil end,
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
    runtime.execute(SUMMON_SOURCE)
    runtime.execute(_PLAN_WORLD)
    return runtime


@pytest.fixture()
def plan() -> LuaRuntime:
    runtime = plan_world()
    # The predicted book is what step A produces; here it is supplied directly
    # so these tests are about the pools, not about prediction again.
    runtime.execute("""
        function TestPredictionStubs(spec)
            BfBot.Summon.Creators = function(_, _) return spec.creators or {} end
            BfBot.Summon.ReadProfile = function(_)
                return { class = 1, name = spec.profileName or "Copy" }
            end
            BfBot.Summon.Forecast = function(_, _, _) return spec.rows end
            BfBot.Summon._CreatureCache = function(_)
                return spec.creature or nil
            end
        end
        function TestRows(spells)
            local rows = {}
            for res, count in pairs(spells) do
                rows[res] = { kind = "spl", resref = res, name = res,
                              level = 3, spellType = 1, count = count,
                              casterLevel = 12, duration = 300,
                              isAoE = 0, isSelfOnly = 0,
                              class = { isBuff = true } }
            end
            return rows
        end
    """)
    return runtime


def test_a_planned_clone_becomes_a_caster(plan: LuaRuntime) -> None:
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({})
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
    """)
    predicted = plan.eval("TestPredicted(snap)")
    assert "summon:planned:protagonist:image3:" in predicted
    assert "Owner - Simulacrum (planned)" in predicted


def test_a_disabled_creation_conjures_nobody(plan: LuaRuntime) -> None:
    """Only an enabled step exposes a future book."""
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({})
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        local requests = TestRequests(groupKey, {})
        requests[1].on = 0
        BfBot.Summon.AddSources(snap, requests)
    """)
    assert plan.eval("TestPredicted(snap)") == ""


def test_no_requests_is_a_no_op(plan: LuaRuntime) -> None:
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({})
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        BfBot.Summon.AddSources(snap, {})
    """)
    assert plan.eval("TestPredicted(snap)") == ""


def test_a_simulacrum_gets_its_own_pool(plan: LuaRuntime) -> None:
    """Type 3 re-memorizes, so its uses are not the owner's."""
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({})
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
    """)
    keys = plan.eval("TestPoolKeys(snap)")
    assert "summon:planned:protagonist:image3" in keys
    assert "protagonist:spell:HASTE" not in keys


def test_a_planned_project_image_draws_from_the_owners_pool(
        plan: LuaRuntime) -> None:
    """Type 2 copies spent uses, so one pool backs both.

    A use the owner spends is gone from the image. Two pools would let the
    plan promise the same Haste twice -- once from the owner and once from
    their image.
    """
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({})
        TestPredictionStubs({ creators = {{kind='clone', image=2}},
                              rows = TestRows({HASTE = 2}) })
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
    """)
    keys = plan.eval("TestPoolKeys(snap)")
    assert "protagonist:spell:HASTE=2" in keys
    assert "summon:planned:protagonist:image2:spell:HASTE" not in keys


def test_a_predicted_pool_starts_empty_until_the_creation_runs(
        plan: LuaRuntime) -> None:
    """A Simulacrum that has not been conjured has cast nothing yet.

    Its sources exist so the plan can see them, but the capacity is 0 until
    execution binds a real spawn -- otherwise the plan would hand out casts
    from a creature that is not there.
    """
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({})
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
    """)
    # Found by the actor's own pool prefix rather than a spelled-out key:
    # the identity carries the creation step, so writing the key out would
    # pin the naming instead of the rule.
    assert plan.eval("""
        (function()
            for _, actor in ipairs(snap.casters) do
                if actor.future then
                    for key, value in pairs(snap.pools) do
                        if key:sub(1, #actor.poolKey) == actor.poolKey then
                            return value
                        end
                    end
                end
            end
            return -1
        end)()
    """) == 0


def test_a_live_copy_is_used_instead_of_a_second_actor(
        plan: LuaRuntime) -> None:
    """The thing is already standing there: one actor, one budget.

    A planned identity and a live one for the same creature would each reserve
    its uses, and the plan would believe it had twice as many casts.
    """
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({liveSummon = 3})
        BfBot.Scan._ReadSummonOrigin = function(sprite)
            if sprite.m_id == 777 then
                return { kind = "clone", cloneType = 3, ownerId = 100 }
            end
            return nil
        end
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        snap.casterActors["summon:clone:protagonist:3"].rows =
            TestRows({HASTE = 2})
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
    """)
    predicted = plan.eval("TestPredicted(snap)")
    # The planned actor exists, but it carries the LIVE pool and no "(planned)".
    assert "pool=summon:live:777" in predicted
    assert "(planned)" not in predicted
    assert plan.eval("TestPool(snap, 'summon:live:777:spell:HASTE')") == 2


def test_a_live_copy_of_another_owner_does_not_count(
        plan: LuaRuntime) -> None:
    """Somebody else's Simulacrum is not this owner's planned one."""
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({liveSummon = 3})
        BfBot.Scan._ReadSummonOrigin = function(_)
            return { kind = "clone", cloneType = 3, ownerId = 999 }
        end
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
    """)
    predicted = plan.eval("TestPredicted(snap)")
    assert "(planned)" in predicted


def test_a_live_copy_of_the_wrong_type_does_not_count(
        plan: LuaRuntime) -> None:
    """A live Project Image is not the Simulacrum this plan conjures."""
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({liveSummon = 2})
        BfBot.Scan._ReadSummonOrigin = function(_)
            return { kind = "clone", cloneType = 2, ownerId = 100 }
        end
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
    """)
    assert "(planned)" in plan.eval("TestPredicted(snap)")


def test_a_locked_owner_gets_no_second_image(plan: LuaRuntime) -> None:
    """A live Project Image locks its owner.

    Predicting another image while the first still stands would plan a cast
    the owner-lock policy then refuses.
    """
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({locked = true})
        TestPredictionStubs({ creators = {{kind='clone', image=2}},
                              rows = TestRows({HASTE = 2}) })
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
    """)
    assert plan.eval("TestPredicted(snap)") == ""


def test_asking_twice_adds_one_actor(plan: LuaRuntime) -> None:
    """The panel and the queue builder both ask."""
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({})
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        local requests = TestRequests(groupKey, {})
        BfBot.Summon.AddSources(snap, requests)
        BfBot.Summon.AddSources(snap, requests)
    """)
    assert len(plan.eval("TestPredicted(snap)").splitlines()) == 1


def test_a_summoned_creature_brings_its_own_rows(plan: LuaRuntime) -> None:
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({})
        TestPredictionStubs({
            creators = {{kind='creature', resource='PLANETAR', opcode=67}},
            creature = { profile = { class = 3, name = "Planetar" },
                         rows = TestRows({HASTE = 1}) } })
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
    """)
    predicted = plan.eval("TestPredicted(snap)")
    assert "summon:planned:protagonist:PLANETAR:" in predicted
    assert "Owner - Planetar (planned)" in predicted


def test_a_creature_whose_cre_is_unreadable_adds_nothing(
        plan: LuaRuntime) -> None:
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({})
        TestPredictionStubs({
            creators = {{kind='creature', resource='MYSTERY', opcode=67}},
            creature = nil })
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
    """)
    assert plan.eval("TestPredicted(snap)") == ""


def test_an_owner_who_cannot_be_read_adds_nothing(plan: LuaRuntime) -> None:
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({})
        TestPredictionStubs({ creators = {{kind='clone', image=3}} })
        BfBot.Summon.ReadProfile = function(_) return nil end
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
    """)
    assert plan.eval("TestPredicted(snap)") == ""


def test_a_predicted_source_names_the_request_that_creates_it(
        plan: LuaRuntime) -> None:
    """Step D needs to know which cast has to come first."""
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({})
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
        Provider = nil
        for _, group in pairs(snap.groups) do
            for _, source in ipairs(group.sources) do
                if source.future then Provider = source.providerRequest end
            end
        end
    """)
    assert plan.eval("Provider ~= nil")
    assert plan.eval("Provider.group") == plan.eval("groupKey")


def test_a_live_sources_future_is_absent(plan: LuaRuntime) -> None:
    """Nothing has to be conjured for a caster already on the field."""
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({liveSummon = 3})
        BfBot.Scan._ReadSummonOrigin = function(sprite)
            if sprite.m_id == 777 then
                return { kind = "clone", cloneType = 3, ownerId = 100 }
            end
        end
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        snap.casterActors["summon:clone:protagonist:3"].rows =
            TestRows({HASTE = 2})
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
        Futures = 0
        for _, group in pairs(snap.groups) do
            for _, source in ipairs(group.sources) do
                if source.future then Futures = Futures + 1 end
            end
        end
    """)
    assert plan.eval("Futures") == 0


def test_the_exclude_list_carries_every_live_summon(plan: LuaRuntime) -> None:
    """Binding must not pick a spawn that was already there."""
    plan.execute("""
        snap, groupKey = TestPlanSnapshot({liveSummon = 2})
        BfBot.Scan._ReadSummonOrigin = function(_) return nil end
        TestPredictionStubs({ creators = {{kind='clone', image=3}},
                              rows = TestRows({HASTE = 2}) })
        BfBot.Summon.AddSources(snap, TestRequests(groupKey, {}))
        Excluded = ""
        for _, actor in ipairs(snap.casters) do
            if actor.future then
                Excluded = table.concat(actor.future.exclude, ",")
            end
        end
    """)
    assert plan.eval("Excluded") == "777"


# ----------------------------------------------------------------------
# A stored future spec is validated, never trusted
# ----------------------------------------------------------------------


def _valid(lua: LuaRuntime, spec: str) -> bool:
    return bool(lua.eval(f"BfBot.Summon.ValidFuture({spec})"))


def test_a_well_formed_clone_spec_is_accepted(lua: LuaRuntime) -> None:
    assert _valid(lua, "{key='k', owner='o', kind='clone', image=2,"
                       " exclude={1,2}}")
    assert _valid(lua, "{key='k', owner='o', kind='clone', image=3,"
                       " exclude={}}")


def test_an_image_type_this_module_cannot_predict_is_refused(
        lua: LuaRuntime) -> None:
    """Mislead copies no book; type 9 is not a type."""
    assert not _valid(lua, "{key='k', owner='o', kind='clone', image=1,"
                           " exclude={}}")
    assert not _valid(lua, "{key='k', owner='o', kind='clone', image=9,"
                           " exclude={}}")


def test_a_creature_spec_needs_a_resref_shaped_resource(
        lua: LuaRuntime) -> None:
    assert _valid(lua, "{key='k', owner='o', kind='creature',"
                       " resource='PLANETAR', exclude={}}")
    assert not _valid(lua, "{key='k', owner='o', kind='creature',"
                           " resource='way too long', exclude={}}")
    assert not _valid(lua, "{key='k', owner='o', kind='creature',"
                           " resource='bad/name', exclude={}}")
    assert not _valid(lua, "{key='k', owner='o', kind='creature',"
                           " exclude={}}")


def test_an_unknown_kind_is_refused(lua: LuaRuntime) -> None:
    assert not _valid(lua, "{key='k', owner='o', kind='wish', exclude={}}")


def test_the_exclude_list_must_be_object_ids(lua: LuaRuntime) -> None:
    assert not _valid(lua, "{key='k', owner='o', kind='clone', image=2,"
                           " exclude={'nope'}}")
    assert not _valid(lua, "{key='k', owner='o', kind='clone', image=2,"
                           " exclude={1.5}}")
    assert not _valid(lua, "{key='k', owner='o', kind='clone', image=2,"
                           " exclude={-1}}")
    assert not _valid(lua, "{key='k', owner='o', kind='clone', image=2}")


def test_unbounded_strings_are_refused(lua: LuaRuntime) -> None:
    long = "x" * 201
    assert not _valid(lua, f"{{key='{long}', owner='o', kind='clone',"
                           " image=2, exclude={}}")
    assert not _valid(lua, f"{{key='k', owner='{long}', kind='clone',"
                           " image=2, exclude={}}")


def test_a_non_table_is_refused(lua: LuaRuntime) -> None:
    assert not _valid(lua, "nil")
    assert not _valid(lua, "'a string'")


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
