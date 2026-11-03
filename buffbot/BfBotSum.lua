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
    -- Ask the index first, the way BfBot5e.lua does: `Load2DA` does NOT
    -- answer nil for a resource that is not installed, it answers a table
    -- with no rows -- which the loader below would then cache as a valid
    -- set of rules and every lookup would fall through to zero.
    if type(EEex_Resource_Fetch) == "function" then
        local okFetch, found = pcall(EEex_Resource_Fetch, name, "2DA")
        if okFetch and found == nil then return nil end
    end
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
    -- An empty result is no rules, not rules that say nothing: a real
    -- MXSPL table always has rows, and the distinction is what keeps
    -- "unreadable" from being read as "this caster gets no spells".
    if ok and rows and next(rows) ~= nil then
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

-- ============================================================
-- What a row actually creates
-- ============================================================

--- A feature block's resource as a plain string, whichever binding it uses.
local function _resourceText(res)
    if type(res) ~= "string" then
        if res == nil then return nil end
        local ok, text = pcall(function() return res:get() end)
        res = ok and text or nil
    end
    return (type(res) == "string" and res ~= "") and res or nil
end

--- What this row creates, read off the installed data rather than assumed.
---
--- Walks the spell or item power's own feature blocks, follows an op=146 cast
--- into the child SPL and an op=177 into its EFF, and reports every clone
--- (opcode 236, image type 2 or 3) and every summoned creature (opcode 67 or
--- 127) it finds. A spell's CASTING effects are walked as well as the
--- ability's, because a wrapper can deliver the creation from either.
---
--- Never "a creature with a familiar name has the familiar book": the resource
--- is reported, and its own CRE is read later.
---
--- @return a list of {kind="clone", image=N} / {kind="creature", resource=R,
---         opcode=N}; empty when the row creates nothing or cannot be read
function S.Discover(row)
    local found, seen, budget = {}, {}, 128
    local visit

    local function effect(opcode, param2, res, depth)
        budget = budget - 1
        if budget < 0 then return end
        if opcode == 236 and (param2 == 2 or param2 == 3) then
            found[#found + 1] = { kind = "clone", image = param2 }
        elseif res and (opcode == 67 or opcode == 127) then
            found[#found + 1] = { kind = "creature", resource = res:upper(),
                                  opcode = opcode }
        elseif res and opcode == 146 then
            visit(res, "SPL", nil, depth + 1)
        elseif res and opcode == 177 then
            visit(res, "EFF", nil, depth + 1)
        end
    end

    visit = function(res, kind, abilityIndex, depth)
        local key = kind .. ":" .. res .. ":" .. tostring(abilityIndex)
        if seen[key] or depth > 4 or budget <= 0 then return end
        seen[key] = true

        local header = EEex_Resource_Demand(res, kind)
        if kind == "EFF" then
            if header then
                effect(header.m_effectId, header.m_dWFlags,
                    _resourceText(header.m_res), depth)
            end
            return
        end

        local ability
        if kind == "ITM" then
            ability = header
                and BfBot.Scan._GetItemAbility(header, abilityIndex or 0)
        else
            ability = header
                and header:getAbilityForLevel(row.casterLevel or 1)
        end
        if not ability then return end

        local fields = BfBot._fields
        local function scan(block)
            effect(block[fields.fb_opcode], block[fields.fb_param2],
                _resourceText(block[fields.fb_res]), depth)
        end

        if kind == "SPL" and (header.castingEffectCount or 0) > 0 then
            -- A synthetic ability so the shared iterator can walk the header's
            -- own casting effects. Its keys come from the field map, never the
            -- literal names, because that map carries fallbacks.
            BfBot.Class._IterateFeatureBlocks(header, {
                [fields.fb_start] = header.castingStartingEffect,
                [fields.fb_count] = header.castingEffectCount,
            }, scan)
        end
        BfBot.Class._IterateFeatureBlocks(header, ability, scan)
    end

    local resource = row.kind == "itm" and row.itemResref or row.resref
    local kind = row.kind == "itm" and "ITM" or "SPL"
    local ok = pcall(visit, resource, kind, row.abilityIdx, 0)
    return ok and found or {}
end

-- ============================================================
-- A fixed summon's own book
-- ============================================================

-- CRE V1.0 is a file format, not an executable-specific layout, so the offsets
-- below belong to the format. Every section is still validated against the
-- resource's own size before any native read: a truncated file would otherwise
-- be read past its end, which no pcall can catch.
local _CRE_HEADER_MIN = 0x2D4
local _CRE = {
    name = 0x08, flags = 0x10, levels = 0x234, wis = 0x23B, class = 0x273,
    spellInfo = 0x2A8, spellInfoCount = 0x2AC,
    memorized = 0x2B0, memorizedCount = 0x2B4,
}

--- The book a summoned creature brings with it, read from its CRE.
--- @return profile — or nil plus the error
function S.ReadCreature(resource)
    local ok, value = pcall(function()
        local res = EEex_Resource_Fetch(resource, "CRE")
        local data = res and res:Demand()
        local size = res and res.nSize
        if not data or type(size) ~= "number" or size < _CRE_HEADER_MIN then
            return nil
        end
        local base = EEex_UDToPtr(data)

        local function str(offset, length)
            local out = {}
            for i = 0, length - 1 do
                local char = EEex_ReadU8(base + offset + i)
                if char == 0 then break end
                out[#out + 1] = string.char(char)
            end
            return table.concat(out)
        end
        if str(0, 8) ~= "CRE V1.0" then return nil end

        local function u32(offset) return EEex_ReadU32(base + offset) end
        local function u16(offset) return EEex_ReadU16(base + offset) end
        local function section(offset, count, stride, limit)
            return offset >= _CRE_HEADER_MIN and count <= limit
                and offset + count * stride <= size
        end

        local memOffset = u32(_CRE.memorized)
        local memCount = u32(_CRE.memorizedCount)
        local infoOffset = u32(_CRE.spellInfo)
        local infoCount = u32(_CRE.spellInfoCount)
        if not section(memOffset, memCount, 12, 4096)
            or not section(infoOffset, infoCount, 16, 32) then
            return nil
        end

        local profile = {
            resource = resource,
            class = EEex_ReadU8(base + _CRE.class),
            flags = u32(_CRE.flags),
            levels = {
                EEex_ReadU8(base + _CRE.levels),
                EEex_ReadU8(base + _CRE.levels + 1),
                EEex_ReadU8(base + _CRE.levels + 2),
            },
            wis = EEex_ReadU8(base + _CRE.wis),
            books = { Mage = {}, Priest = {}, Innate = {} },
        }
        if Infinity_FetchString then
            local named, name = pcall(Infinity_FetchString, u32(_CRE.name))
            if named and type(name) == "string" and name ~= ""
                and #name <= 120 and not name:find("%c") then
                profile.name = name
            end
        end

        local names = {}
        for i = 0, infoCount - 1 do
            local entry = infoOffset + i * 16
            local level = u16(entry) + 1
            local book = ({ [0] = "Priest", [1] = "Mage",
                            [2] = "Innate" })[u16(entry + 6)]
            local first, count = u32(entry + 8), u32(entry + 12)
            if not book or level > 9 or first + count > memCount then
                return nil
            end
            local levels = profile.books[book]
            for n = 1, level do levels[n] = levels[n] or {} end
            for n = first, first + count - 1 do
                local offset = memOffset + n * 12
                local spell = str(offset, 8)
                if not names[spell] then
                    local row = BfBot.Scan.DescribeSpell(spell,
                        profile.levels[1])
                    names[spell] = row and row.name or spell
                end
                local entries = levels[level]
                entries[#entries + 1] = { res = spell, name = names[spell],
                                          flags = u32(offset + 8) }
            end
        end
        return profile
    end)
    return ok and value or nil, (not ok) and tostring(value) or nil
end

-- ============================================================
-- Caches
-- ============================================================

local _mechanics, _creatures = {}, {}
local _forecasts, _forecastCount = {}, 0

--- Drop every cached prediction. The in-game suite needs it, and so does a
--- party change that could have altered a book.
function S.ClearCaches()
    _mechanics, _creatures = {}, {}
    _forecasts, _forecastCount = {}, 0
end

--- The predicted rows for one owner and image type, cached against a stamp of
--- everything the prediction depends on.
---
--- The stamp is content, not a timestamp: a book that has not changed must not
--- be re-predicted every frame the panel is open, and a book that HAS changed
--- -- a spell cast, a rest, a classifier override -- must not serve a stale
--- answer. Sixteen entries, then the whole table goes: a party of six with two
--- image types cannot exceed that, and a long session should not keep a cache
--- for owners who have left.
function S.Forecast(profile, image, key)
    local stamp = {
        tostring(profile.class), tostring(profile.flags),
        tostring(profile.kit), tostring(profile.wis),
        tostring(profile.copyLevel),
        table.concat(profile.levels or {}, ","),
    }
    for _, book in ipairs({ "Mage", "Priest", "Innate" }) do
        stamp[#stamp + 1] = book
        for level, entries in ipairs(profile.books[book] or {}) do
            stamp[#stamp + 1] = tostring(level)
            for _, entry in ipairs(entries) do
                stamp[#stamp + 1] = table.concat({
                    entry.res, tostring(entry.flags), tostring(entry.sortName),
                    tostring(profile.casterLevels
                        and profile.casterLevels[entry.res]),
                    tostring(profile.availableCounts
                        and profile.availableCounts[entry.res]),
                    tostring(BfBot._overrides and BfBot._overrides[entry.res]),
                }, ":")
            end
        end
    end
    stamp = table.concat(stamp, "|")

    local cacheKey = tostring(key) .. ":" .. tostring(image)
    local cached = _forecasts[cacheKey]
    if cached and cached.stamp == stamp then return cached.rows end

    local predicted = S.Predict(profile, image)
    local rows = predicted and S.BuildRows(profile, predicted)
    if not rows then return nil end

    if not cached then _forecastCount = _forecastCount + 1 end
    if _forecastCount > 16 then
        _forecasts, _forecastCount = {}, 1
    end
    _forecasts[cacheKey] = { stamp = stamp, rows = rows }
    return rows
end

--- What this row would create that is worth planning for, cached per row and
--- caster level.
---
--- A clone always counts: its book is the owner's. A summoned creature counts
--- only when its own CRE book holds at least one automatic buff it could
--- actually deliver -- unspent, and either able to reach another creature or
--- an area cast. A Planetar that can buff nobody is not a caster worth
--- offering, and a creature whose CRE cannot be read is not guessed at.
---
--- @return a list of creation descriptors; empty when there is nothing to plan
function S.Creators(row, variant)
    local key = table.concat({
        row.kind or "spl", row.itemResref or row.resref or "",
        tostring(row.abilityIdx or 0), tostring(row.casterLevel or 1),
        variant or "",
    }, ":")
    if _mechanics[key] then return _mechanics[key] end

    -- A selected variant is what gets cast, so it is what gets inspected.
    local selected = row
    if variant then
        selected = { kind = "spl", resref = variant,
                     casterLevel = row.casterLevel }
    end

    local found = {}
    for _, descriptor in ipairs(S.Discover(selected)) do
        if descriptor.kind == "clone" then
            found[#found + 1] = descriptor
        else
            if _creatures[descriptor.resource] == nil then
                local profile = S.ReadCreature(descriptor.resource)
                _creatures[descriptor.resource] = profile
                    and { profile = profile, rows = S.BuildRows(profile) }
                    or false
            end
            local creature = _creatures[descriptor.resource]
            if creature then
                for _, creatureRow in pairs(creature.rows) do
                    if (creatureRow.count or 0) > 0
                        and BfBot.Plan.IsAutomaticBuff(creatureRow)
                        and (creatureRow.isSelfOnly ~= 1
                            or creatureRow.isAoE == 1) then
                        found[#found + 1] = descriptor
                        break
                    end
                end
            end
        end
    end

    _mechanics[key] = found
    return found
end

--- Does this row create a caster worth planning for?
function S.IsCreator(row)
    return #S.Creators(row) > 0
end

--- What `Creators` learned about a summoned creature, or nil when its CRE
--- could not be read. Reading it rather than re-parsing is the point: the
--- same creature appears once per preset entry that summons it.
function S._CreatureCache(resource)
    local entry = _creatures[tostring(resource):upper()]
    return entry or nil
end

-- ============================================================
-- Predicted casters as plan sources
-- ============================================================

--- Is this live caster the thing `description` would create for `owner`?
---
--- Matching by owner and type rather than by object id is what lets a saved
--- planned identity resolve to the spawn that is already standing there. The
--- id is fresh per spawn and must never be persisted.
local function _matchesLive(actor, owner, description)
    if not actor.sprite or not actor.casterRef
        or actor.casterRef.kind ~= "summon" then
        return false
    end
    local origin = BfBot.Scan._ReadSummonOrigin(actor.sprite)
    if not origin or origin.ownerId ~= owner.sprite.m_id then return false end
    if description.kind == "clone" then
        return origin.kind == "clone"
            and origin.cloneType == description.image
    end
    local ok, resref = pcall(function()
        return actor.sprite.m_resref:get()
    end)
    return ok and type(resref) == "string"
        and resref:upper() == description.resource
end

--- Is a stored future-caster spec one this build is willing to act on?
---
--- It crosses a save, an export and a reload before execution binds a real
--- spawn to it, so it is validated rather than trusted: bounded strings, an
--- image type this module can predict, a resref shaped like a resref, and a
--- bounded exclude list of plain non-negative integers.
function S.ValidFuture(spec)
    if type(spec) ~= "table" or type(spec.key) ~= "string" or #spec.key > 200
        or type(spec.owner) ~= "string" or #spec.owner > 200 then
        return false
    end
    if spec.kind == "clone" then
        if spec.image ~= 2 and spec.image ~= 3 then return false end
    elseif spec.kind ~= "creature" or type(spec.resource) ~= "string"
        or #spec.resource > 8 or not spec.resource:match("^[%w_#%-]+$") then
        return false
    end
    if type(spec.exclude) ~= "table" or #spec.exclude > 256 then return false end
    for _, oid in ipairs(spec.exclude) do
        if type(oid) ~= "number" or oid % 1 ~= 0 or oid < 0 then return false end
    end
    return true
end

--- Add a caster for every creation this plan actually performs.
---
--- Called after the preset has become requests and before they are assigned,
--- because only an ENABLED creation step exposes a future book: a Simulacrum
--- the player has switched off conjures nobody.
---
--- Identity is `summon:planned:<owner>:<kind>:<group>` -- the owner, what is
--- created and which creation step creates it. No object id, so the identity
--- survives a save, a reload and a data-only preset export; the spawn it ends
--- up bound to is resolved at execution time.
---
--- Two budget rules, and both exist because getting them wrong hands the
--- player a plan that cannot run:
---
--- * If the thing is ALREADY on the field, the live caster is used and no
---   second actor appears. Two actors would reserve the same uses twice.
--- * A Project Image copies the owner's book INCLUDING spent uses, so a use
---   the owner spends is gone from the image. A planned image therefore draws
---   from the OWNER's pool, not one of its own. A Simulacrum re-memorizes, so
---   it gets its own.
---
--- @param snapshot the snapshot to extend, in place
--- @param requests the plan's requests, as ImportLegacy produced them
function S.AddSources(snapshot, requests)
    if type(requests) ~= "table" or #requests == 0 then return end
    local P = BfBot.Plan

    local assignment = P.Assign(snapshot, requests)
    local live = {}
    for _, actor in ipairs(snapshot.casters) do live[#live + 1] = actor end

    local added, profiles = {}, {}
    for index, request in ipairs(requests) do
        local decision = assignment.decisions[index]
        local source = decision and decision.source
        local owner = source and snapshot.actors[source.actor]

        if source and owner and owner.alive and owner.controlled
            and not owner.ambiguous then
            for _, description in ipairs(S.Creators(source.row, request.var)) do
                local what = description.kind == "clone"
                    and ("image" .. description.image)
                    or description.resource
                local key = "summon:planned:" .. owner.key .. ":" .. what
                    .. ":" .. tostring(request.group)

                -- Idempotent: the panel and the queue builder both ask,
                -- and a second actor for one identity would reserve the same
                -- uses twice.
                if #key <= 200 and not added[key]
                    and not snapshot.casterActors[key] then
                    added[key] = true

                    local existing
                    for _, actor in ipairs(live) do
                        if _matchesLive(actor, owner, description) then
                            existing = actor
                            break
                        end
                    end

                    local rows, profile
                    if existing then
                        rows = existing.rows
                    elseif description.kind == "clone" then
                        if profiles[owner.key] == nil then
                            profiles[owner.key] =
                                S.ReadProfile(owner.sprite) or false
                        end
                        profile = profiles[owner.key] or nil
                        if profile then
                            rows = S.Forecast(profile, description.image,
                                owner.key)
                        end
                    else
                        local creature = S._CreatureCache(description.resource)
                        if creature then
                            profile, rows = creature.profile, creature.rows
                        end
                    end

                    -- A locked owner's planned image is only offered when the
                    -- image is already live: predicting a second one while the
                    -- first still stands would plan a cast the policy refuses.
                    if rows and (existing or not owner.projectImageLocked) then
                        S._AddPredictedActor(snapshot, {
                            key = key, owner = owner, live = existing,
                            rows = rows, profile = profile,
                            description = description, request = request,
                            sourceRow = source.row,
                            ownerIsCasting = decision.source ~= nil,
                            liveCasters = live,
                        })
                    end
                end
            end
        end
    end
end

--- One predicted caster and its sources. Split out of AddSources so the
--- budget rules below sit on their own rather than six levels deep.
function S._AddPredictedActor(snapshot, spec)
    local P = BfBot.Plan
    local description, owner, existing = spec.description, spec.owner, spec.live

    local label = description.kind == "clone"
        and P.CloneLabel(description.image)
        or (existing and existing.name)
        or (spec.profile and spec.profile.name)
        or spec.sourceRow.name or description.resource
    local name = owner.name .. " - " .. label
        .. (existing and "" or " (planned)")

    local future
    if not existing then
        future = { kind = description.kind, image = description.image,
                   resource = description.resource, owner = owner.key,
                   key = spec.key, exclude = {} }
        -- Every summon already on the field is excluded by object id, so
        -- binding cannot pick one of them for this plan's new spawn.
        for _, actor in ipairs(spec.liveCasters) do
            if actor.casterRef and actor.casterRef.kind == "summon" then
                future.exclude[#future.exclude + 1] = actor.casterRef.oid
            end
        end
    end

    local actor = {
        key = spec.key, name = name, rows = spec.rows,
        alive = true, controlled = true,
        class = existing and existing.class
            or (spec.profile and spec.profile.class),
        poolKey = existing and existing.poolKey or spec.key,
        casterRef = existing and existing.casterRef or nil,
        sprite = existing and existing.sprite or nil,
        future = future,
    }
    snapshot.casters[#snapshot.casters + 1] = actor
    snapshot.casterActors[spec.key] = actor

    -- A planned Project Image shares the owner's uses: the copy carries the
    -- owner's spent slots, so one pool serves both and the owner's own casts
    -- are what spend it. A Simulacrum re-memorizes and gets its own pool.
    local sharesOwnerPool = not existing
        and description.kind == "clone" and description.image == 2
        and spec.ownerIsCasting

    for _, row in pairs(spec.rows) do
        local pool, reason = P.SpellPool(
            sharesOwnerPool and owner or actor, row)
        -- The pool carries what the prediction says the caster will have.
        -- AddSources is only reached with an assigned source for the creation
        -- step, so this caster WILL exist; an empty pool here would mean a
        -- planned Simulacrum could never be allocated anything, which is a
        -- plan that silently does nothing.
        --
        -- For a shared owner pool the `min` is the one-budget rule doing its
        -- work: the owner's remaining uses cap what the image can spend.
        local count = row.count
        if pool then
            snapshot.pools[pool] =
                math.min(snapshot.pools[pool] or count, count)
        end

        local groupKey = P.GroupKey(row)
        if row.class and P.IsAutomaticBuff(row)
            and (row.isSelfOnly ~= 1 or row.isAoE == 1) then
            local group = snapshot.groups[groupKey]
            if not group then
                group = { key = groupKey, name = row.name, kind = row.kind,
                          icon = row.icon, sources = {} }
                snapshot.groups[groupKey] = group
            end
            local durations = {}
            for _, variant in ipairs(row.variants or {}) do
                local described = BfBot.Scan.DescribeSpell(variant.resref,
                    row.casterLevel)
                durations[variant.resref] = described and described.duration or 0
            end
            group.sources[#group.sources + 1] = {
                id = spec.key .. "/" .. groupKey,
                actor = spec.key, casterName = name,
                casterRef = actor.casterRef, lane = actor.poolKey,
                liveActor = existing and existing.key or nil,
                row = row, pool = pool or (spec.key .. ":unavailable"),
                reason = reason, duration = row.duration,
                casterLevel = row.casterLevel,
                selfOnly = row.isSelfOnly == 1, aoe = row.isAoE == 1,
                variants = row.variants, variantDurations = durations,
                future = future,
                -- Which request has to run first for this source to exist.
                providerRequest = (not existing) and spec.request or nil,
            }
        end
    end
    return actor
end

-- ============================================================
-- Clones the player can configure before conjuring them
-- ============================================================
--
-- The gap #107 actually closes. Execution already handles a clone that
-- appears mid-run: it late-joins and runs the queue built from its own summon
-- preset (`BfBot.Exec._AttachCaster`, issue #19). What the player cannot do is
-- FILL that preset in advance, because the Summons view is built from
-- `GetAlliedSummons()` -- live sprites only -- so a Simulacrum has no tab
-- until it is standing there, and by then the run is over.
--
-- A predicted entry carries the identity the live clone will have, which is
-- what makes this work at all: `Scan._SummonIdentity` answers
-- "clone:<ownerName>" for a clone, so a preset configured against the
-- prediction is the very preset the real spawn reads.

--- Every clone the party's current presets would conjure, in the shape the
--- Summons view's list model uses, plus `predicted = 1`.
---
--- One entry per owner and clone type. A single owner's Project Image and
--- Simulacrum deliberately SHARE the identity "clone:<owner>" -- that is the
--- existing scheme, and the view already prefers a type match when
--- reselecting -- so the type is carried for the label and the shared
--- identity for the config.
---
--- `oid` is negative and unique: the list model requires a number, nothing
--- may resolve a predicted entry to a sprite, and a negative id can never
--- collide with an engine object id.
---
--- @param presetIdx the party preset being edited
--- @return a list of entries; empty when nothing would be conjured
function S.PredictedSummons(presetIdx)
    local entries, seen, nextOid = {}, {}, -1
    if type(presetIdx) ~= "number" then return entries end

    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local okRows, rows = pcall(BfBot.Scan.GetCastableSpells, sprite)
            local preset = BfBot.Persist.GetPreset(sprite, presetIdx)
            if okRows and rows and preset and type(preset.spells) == "table" then
                local ownerName = BfBot._GetName(sprite)
                for resref, config in pairs(preset.spells) do
                    local row = rows[resref]
                    if row and config.on == 1 then
                        for _, descriptor in
                            ipairs(S.Creators(row, config.var)) do
                            if descriptor.kind == "clone" then
                                local identity = BfBot.Scan._SummonIdentity({
                                    kind = "clone", ownerName = ownerName })
                                local key = identity .. ":"
                                    .. tostring(descriptor.image)
                                if not seen[key] then
                                    seen[key] = true
                                    entries[#entries + 1] = {
                                        oid = nextOid,
                                        name = ownerName .. " - "
                                            .. BfBot.Plan.CloneLabel(
                                                descriptor.image),
                                        kind = "clone",
                                        identity = identity,
                                        ownerName = ownerName,
                                        cloneType = descriptor.image,
                                        predicted = 1,
                                    }
                                    nextOid = nextOid - 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return entries
end

--- The rows a predicted entry's tab should show: the clone's forecast book.
--- @return rows, or nil plus a reason
function S.PredictedRows(entry)
    if type(entry) ~= "table" or entry.predicted ~= 1
        or entry.kind ~= "clone" then
        return nil, "not a predicted clone"
    end
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite and BfBot._GetName(sprite) == entry.ownerName then
            local profile, why = S.ReadProfile(sprite)
            if not profile then return nil, why or "owner unreadable" end
            local rows = S.Forecast(profile, entry.cloneType, entry.identity)
            if not rows then return nil, "prediction unavailable" end
            return rows
        end
    end
    return nil, "owner is not in the party"
end
