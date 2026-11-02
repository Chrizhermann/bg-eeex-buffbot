-- ============================================================
-- BfBotSum.lua — predicted spellbooks for casters that do not exist yet
-- ============================================================
--
-- Issue #107. Summon casters (#19, filtered in #101) only work on creatures
-- already standing on the field, because a clone has no spellbook to scan
-- until it is there. This module answers the question BEFORE the cast: given
-- the owner's book and the engine's own copy rules, what will the clone be
-- able to cast?
--
-- Resource analysis only. Nothing here creates a preview creature, applies an
-- effect or touches a memorization flag — it reads the owner's live stats and
-- book, reads SPL and 2DA data, and returns a table.
--
-- The design and the engine rules come from Zach Hopkins' BuffBot Redux
-- (`BfBotSum.lua` there). What is NOT ported is its execution tail and its
-- automatic-order engine: those sit on a timing module this fork does not
-- have, and the execution side is written against BfBotExe.lua instead.
--
-- Why the rules below are written out rather than simplified: each one is a
-- native behaviour that a "nicer" rule would get wrong, and a wrong predicted
-- book means the panel promises casts that will not happen.

BfBot.Summon = {}
local S = BfBot.Summon

-- ============================================================
-- Class composition
-- ============================================================
--
-- CLASS.IDS value -> the single-class components it is made of. A dual or
-- multi class casts from each component's own tables, so capacity has to be
-- asked per component rather than once for the combined class.
local _components = {
    [1] = { 1 }, [2] = { 2 }, [3] = { 3 }, [4] = { 4 }, [5] = { 5 },
    [6] = { 6 }, [7] = { 2, 1 }, [8] = { 2, 3 }, [9] = { 2, 4 },
    [10] = { 2, 1, 4 }, [11] = { 11 }, [12] = { 12 }, [13] = { 1, 4 },
    [14] = { 3, 1 }, [15] = { 3, 4 }, [16] = { 2, 11 }, [17] = { 2, 1, 3 },
    [18] = { 3, 12 }, [19] = { 19 }, [20] = { 20 }, [21] = { 21 },
}

-- The sprite flag that marks which half of a DUAL class is the abandoned one.
-- A dual-class character keeps the old class's levels but may not use its
-- spells until the new class passes it, so the previous component's book has
-- to be recognized and held back.
local _originalFlags = {
    [2] = 8, [1] = 16, [3] = 32, [4] = 64, [11] = 128, [12] = 256,
}

--- PURE: the component classes of `class`, and which half of a dual class is
--- active and which was abandoned.
--- @return parts, active, previous — or nil plus a reason
function S.Classes(class, flags)
    local parts = _components[class]
    if not parts then return nil, "Unsupported caster class" end
    local active, previous
    if #parts == 2 then
        for _, part in ipairs(parts) do
            local mask = _originalFlags[part]
            if mask and BfBot._BAnd(flags or 0, mask) ~= 0 then
                previous = part
            end
        end
    end
    if previous then
        for _, part in ipairs(parts) do
            if part ~= previous then active = part end
        end
    end
    return parts, active, previous
end

-- ============================================================
-- 2DA rules
-- ============================================================

local _tables = {}

--- The MXSPL* rows, read once per table and cached.
--- Uses EEex's own 2DA loader, which BfBot5e.lua already relies on; the raw
--- text path the reference implementation carries as well is for EEex builds
--- without that loader, and every release BuffBot supports has it.
local function _tableData(name)
    if _tables[name] then return _tables[name] end
    if type(EEex_Resource_Load2DA) ~= "function" then return nil end
    local ok, rows = pcall(function()
        local table2da = EEex_Resource_Load2DA(name)
        if not table2da then return nil end
        local sizeX, sizeY = table2da:getDimensions()
        if type(sizeX) ~= "number" or type(sizeY) ~= "number" then
            return nil
        end
        local out = {}
        for row = 0, sizeY - 1 do
            local cells = {}
            out[tostring(table2da:getRowLabel(row))] = cells
            -- getDimensions' x includes the row-label column.
            for col = 0, sizeX - 2 do
                cells[tostring(table2da:getColumnLabel(col))] =
                    tonumber(table2da:getAtPoint(col, row)) or 0
            end
        end
        return out
    end)
    if ok and rows then
        _tables[name] = rows
        return rows
    end
    return nil
end

--- One cell of a spell-slot table, or nil when the table cannot be read.
--- nil and 0 mean different things to every caller here: nil is "the rules are
--- unavailable, do not guess", 0 is "no slots at this level".
function S.Rule(name, row, column)
    local data = _tableData(name)
    if not data then return nil end
    local cells = data[tostring(row)]
    return cells and cells[tostring(column)] or 0
end

--- Drop the cached tables. The in-game suite needs this, and so does a
--- language or install change that could have replaced a 2DA.
function S.ClearRules() _tables = {} end

-- ============================================================
-- The clone's levels
-- ============================================================

--- PURE given `profile`: the levels the clone casts at.
---
--- Simulacrum (image type 3) drains levels; Project Image (type 2) does not.
--- The native drain is `floor(2 * GetAverageLevel(activeClass) / 5)`. In a
--- dual class the engine's average-level query reads the FIRST level field,
--- not a mean of the halves — that is retained deliberately rather than
--- substituting a rule that looks fairer, because the engine is what the
--- player will see happen.
---
--- @return {levels, usable, drain, active, previous} — or nil plus a reason
function S.CloneLevels(profile, kind)
    local parts, active, previous = S.Classes(profile.class, profile.flags)
    if not parts then return nil, active end

    local levels, total = {}, 0
    for i = 1, #parts do
        levels[i] = profile.levels[i] or 0
        total = total + levels[i]
    end
    local average = profile.copyLevel
        or (active and levels[1] or math.ceil(total / #parts))
    local drain = kind == 3 and math.floor(average * 2 / 5) or 0
    for i, part in ipairs(parts) do
        if not active or part == active then
            levels[i] = math.max(1, levels[i] - drain)
        end
    end

    -- A dual class's abandoned half contributes nothing until the active half
    -- passes its level, which is the engine's own rule for when the old book
    -- becomes usable again.
    local usable = {}
    for i, part in ipairs(parts) do
        if not previous or part ~= previous then
            usable[part] = levels[i]
        else
            local activeLevel = 0
            for k, component in ipairs(parts) do
                if component == active then activeLevel = levels[k] end
            end
            if activeLevel > levels[i] then usable[part] = levels[i] end
        end
    end

    return { levels = levels, usable = usable, drain = drain,
             active = active, previous = previous }
end

-- ============================================================
-- Capacity
-- ============================================================

local _MAGE_TABLES = { [1] = "MXSPLWIZ", [5] = "MXSPLBRD", [19] = "MXSPLSRC" }
local _PRIEST_TABLES = {
    [3] = "MXSPLPRS", [11] = "MXSPLDRU", [6] = "MXSPLPAL",
    [12] = "MXSPLRAN", [21] = "MXSPLSHM",
}

--- PURE given `rule`: how many spells of `spellLevel` the clone can hold in
--- `book` ("Mage" or "Priest").
---
--- `rule` is injectable so the whole prediction core can be tested without a
--- game: the offline suite feeds it MXSPL rows directly.
---
--- The three bonuses are the engine's, and each one is wrong to leave out:
--- a specialist wizard gets +1 per level; a Dragon Disciple's kit slot sits on
--- top of MXSPLDD, so reading that table alone undercounts every level; and a
--- cleric or druid adds the MXSPLWIS bonus for their Wisdom.
---
--- Equipped slot bonuses are deliberately NOT replayed: they survive on the
--- copy but do not refill its book, and adding them here would invent
--- prepared spells.
---
--- @return count — or nil plus a reason when the rules cannot be read
function S.Capacity(profile, levels, book, spellLevel, rule)
    rule = rule or S.Rule
    local best = 0
    for class, level in pairs(levels.usable) do
        local tableName
        if book == "Mage" then
            tableName = _MAGE_TABLES[class]
            -- A Dragon Disciple sorcerer reads its own reduced table.
            if class == 19 and BfBot._BAnd(profile.kit or 16384,
                BfBot._BNot(16384)) == 35 then
                tableName = "MXSPLDD"
            end
        elseif book == "Priest" then
            tableName = _PRIEST_TABLES[class]
        end

        if tableName then
            local count = rule(tableName, level, spellLevel)
            if count == nil then
                return nil, "Spell-slot rules unavailable: " .. tableName
            end
            if count > 0 then
                if class == 1 then
                    local kit = profile.kit or 16384
                    local specialist =
                        (BfBot._BAnd(kit, 0x4000) == 0
                            and BfBot._BAnd(kit, 0x3FC0) ~= 0)
                        or BfBot._BAnd(kit, 0x80000000) ~= 0
                    if specialist then count = count + 1 end
                elseif class == 19 then
                    if profile.kit and profile.kit ~= 16384 then
                        count = count + 1
                    end
                elseif class == 3 or class == 11 then
                    local bonus = rule("MXSPLWIS", profile.wis or 10, spellLevel)
                    if bonus == nil then
                        return nil, "Wisdom spell-slot rules unavailable"
                    end
                    count = count + bonus
                end
            end
            best = math.max(best, count)
        end
    end
    return best
end

-- ============================================================
-- The predicted book
-- ============================================================

--- PURE given `profile` and `rule`: the book the clone will have.
---
--- Every memorized entry is kept first, attack spells included, and the list
--- is truncated to the reduced capacity afterwards — in the engine's own
--- order, which sorts by the generic localized name. Filtering buffs out
--- before that step invents spell slots, because the entries that would have
--- been cut are then not there to be cut.
---
--- Simulacrum (3) refreshes the copied memorization; Project Image (2)
--- preserves spent uses, so a spell the owner has already cast is not back.
---
--- @return {counts, books, levels, drain, usable} — or nil plus a reason
function S.Predict(profile, kind, rule)
    if kind ~= 2 and kind ~= 3 then return nil, "Unsupported image type" end
    local levels, why = S.CloneLevels(profile, kind)
    if not levels then return nil, why end

    local result = { counts = {}, books = {}, levels = levels.levels,
                     drain = levels.drain, usable = levels.usable }

    for book, bookLevels in pairs(profile.books or {}) do
        result.books[book] = {}
        for level, entries in ipairs(bookLevels) do
            local capacity
            if kind == 2 or book == "Innate" then
                capacity = #entries
            else
                capacity, why = S.Capacity(profile, levels, book, level, rule)
            end
            if capacity == nil then return nil, why end

            local copies = {}
            for index, entry in ipairs(entries) do
                copies[index] = {
                    res = entry.res,
                    name = entry.sortName or entry.name or entry.res,
                    flags = entry.flags or 0,
                    index = index,
                }
            end

            -- Sorcerers and shamans do not hold a prepared list: the engine
            -- rebuilds their copies from the known choices and the class
            -- capacity, so a short or stale memorized list is not the number
            -- of uses the copy receives.
            local spontaneous = (book == "Mage" and profile.class == 19)
                or (book == "Priest" and profile.class == 21)

            if kind == 3 and book ~= "Innate" then
                table.sort(copies, function(a, b)
                    if a.name ~= b.name then return a.name < b.name end
                    return a.index < b.index
                end)
            end

            local uses = {}
            for index, entry in ipairs(copies) do
                uses[entry.res] = (uses[entry.res] or 0) + 1
                result.books[book][level] = result.books[book][level] or {}
                local list = result.books[book][level]

                if spontaneous then
                    if uses[entry.res] == 1 then
                        local count = kind == 3 and capacity
                            or (profile.availableCounts
                                and profile.availableCounts[entry.res])
                        if count == nil then
                            count = 0
                            for _, other in ipairs(copies) do
                                if other.res == entry.res
                                    and BfBot._BAnd(other.flags, 3) == 1 then
                                    count = count + 1
                                end
                            end
                        end
                        count = math.max(0, math.min(512, count))
                        result.counts[entry.res] = count
                        for n = 1, math.max(1, count) do
                            list[#list + 1] = { res = entry.res,
                                                flags = n <= count and 1 or 0 }
                        end
                    end
                else
                    local within = kind == 2 or book == "Innate"
                        or index <= capacity
                    local available = within
                        and (kind == 3 or BfBot._BAnd(entry.flags, 3) == 1)
                    result.counts[entry.res] = (result.counts[entry.res] or 0)
                        + (available and 1 or 0)
                    list[#list + 1] = { res = entry.res,
                                        flags = available and 1 or 0 }
                end
            end
        end
    end

    return result
end

-- ============================================================
-- Reading the owner
-- ============================================================

--- The owner's live stats and book, in the shape Predict wants.
---
--- The sort name is the spell's GENERIC TLK name, including an empty one on a
--- hidden or helper spell: that is what the engine's book reduction sorts, and
--- the panel's resref fallback would move those entries to the end and
--- predict the wrong survivors.
---
--- @return profile — or nil plus the error
function S.ReadProfile(sprite)
    local ok, value = pcall(function()
        local stats = EEex_Sprite_GetActiveStats(sprite)
        local profile = {
            class = sprite.m_typeAI.m_Class,
            flags = sprite.m_baseStats.m_flags,
            levels = { stats.m_nLevel1, stats.m_nLevel2, stats.m_nLevel3 },
            wis = stats.m_nWIS,
            kit = sprite:getStat(152),
            books = {}, casterLevels = {}, availableCounts = {},
        }

        local parts, active = S.Classes(profile.class, profile.flags)
        if not parts then return nil end
        profile.copyLevel = stats:GetAverageLevel(active or profile.class)

        local names, sortNames = {}, {}
        local catalog = BfBot.Scan.GetCastableSpells(sprite)
        for _, book in ipairs({ "Mage", "Priest", "Innate" }) do
            local rows = {}
            profile.books[book] = rows
            local topLevel = book == "Mage" and 8
                or book == "Priest" and 6 or 0
            for level = 0, topLevel do
                local entries = {}
                rows[level + 1] = entries
                EEex_Utility_IterateCPtrList(
                    sprite["m_memorizedSpells" .. book]:getReference(level),
                    function(memorized)
                        local res = memorized.m_spellId:get()
                        if not names[res] then
                            local row = catalog[res]
                                or BfBot.Scan.DescribeSpell(res, 1)
                            names[res] = row and row.name or res
                            local named, text = pcall(function()
                                local header = EEex_Resource_Demand(res, "SPL")
                                return header
                                    and Infinity_FetchString(header.genericName)
                            end)
                            sortNames[res] = (named and type(text) == "string")
                                and text or names[res]
                            profile.casterLevels[res] =
                                row and row.casterLevel or nil
                            profile.availableCounts[res] =
                                row and row.count or nil
                        end
                        entries[#entries + 1] = {
                            res = res, name = names[res],
                            sortName = sortNames[res],
                            flags = memorized.m_flags,
                        }
                    end)
            end
        end
        return profile
    end)
    return ok and value or nil, (not ok) and tostring(value) or nil
end

--- PURE: how many uses of each resref the owner's own book currently holds.
--- Flag bit pattern 3 == 1 is "memorized and not yet spent".
function S.BookCounts(profile)
    local counts = {}
    for _, levels in pairs(profile.books or {}) do
        for _, entries in ipairs(levels) do
            for _, entry in ipairs(entries) do
                counts[entry.res] = (counts[entry.res] or 0)
                    + (BfBot._BAnd(entry.flags or 0, 3) == 1 and 1 or 0)
            end
        end
    end
    return counts
end

--- PURE: the level the clone casts a spell of `spellType` at.
--- Paladins and rangers cast from a priest list that starts above level 1, so
--- their class level is offset rather than used directly.
local function _castingLevel(usable, spellType)
    if spellType == 1 then
        return math.max(usable[1] or 0, usable[5] or 0, usable[19] or 0, 1)
    end
    if spellType == 2 then
        return math.max(usable[3] or 0, usable[11] or 0, usable[21] or 0,
            (usable[6] or 0) - 8, (usable[12] or 0) - 7, 1)
    end
    local best = 1
    for _, level in pairs(usable) do best = math.max(best, level) end
    return best
end
S._CastingLevel = _castingLevel

--- The clone's rows, in the same shape the scan produces for a live sprite,
--- so the plan model and the panel can treat a predicted caster like any
--- other. `predicted = 1` is what marks them.
---
--- A row's caster level is shifted by the drain rather than recomputed: the
--- owner's own level for that spell is the authority, and the difference
--- between the clone's and the owner's class level is what the copy loses.
function S.BuildRows(profile, prediction)
    local original = S.CloneLevels(profile, 2)
    local usable = prediction and prediction.usable
        or (original and original.usable) or {}
    local counts = prediction and prediction.counts or S.BookCounts(profile)

    local rows, locations = {}, {}
    for _, book in ipairs({ "Mage", "Priest", "Innate" }) do
        for level, entries in ipairs(profile.books[book] or {}) do
            for _, entry in ipairs(entries) do
                locations[entry.res] = locations[entry.res]
                    or { level = level,
                         kind = ({ Mage = 1, Priest = 2, Innate = 4 })[book] }
            end
        end
    end

    for res, count in pairs(counts) do
        local okHeader, header = pcall(EEex_Resource_Demand, res, "SPL")
        if okHeader and header then
            local spellType = header.itemType or header.spellType or 0
            local level = _castingLevel(usable, spellType)
            local before = original
                and _castingLevel(original.usable, spellType) or level
            if profile.casterLevels and profile.casterLevels[res] then
                level = math.max(1,
                    level + profile.casterLevels[res] - before)
            end
            local row = BfBot.Scan.DescribeSpell(res, level)
            if row then
                row.count = count
                row.predicted = 1
                rows[res] = row
                local where = locations[res]
                if where then
                    row.bookLevel = where.level
                    row.bookType = where.kind
                end
            end
        end
    end
    return rows
end
