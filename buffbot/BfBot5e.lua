-- ============================================================
-- BfBot5e.lua — 5E Spellcasting compatibility adapter (BfBot.FiveE)
--
-- UnearthedArcana/Subtledoctor "5E Spellcasting" replaces Vancian casting
-- for converted casters with generated innate wrappers d5z<IND>i, listed in
-- d5zclons.2da (IND -> MEM spell, CAST spell, arcane/divine, processed).
-- Upstream only grants a wrapper for PREPARED spells, and each wrapper cast
-- debits the shared per-level pool, strips every wrapper, and regrants them
-- after a delayed refresh.
--
-- This adapter keeps BuffBot on upstream's rules instead of duplicating them:
--   * scan: wrapper rows are hidden; the spell a wrapper stands for keeps its
--     normal spellbook identity (MEM) and takes the wrapper's live count.
--     Managed casters never fall back to native slots for listed spells.
--   * effects: active-buff detection uses the resource the wrapper really
--     casts (CAST), never the wrapper's own bookkeeping helpers.
--   * exec: casts go through SpellRES(wrapper) and wait for the refresh the
--     wrapper itself declares before the next wrapper-backed attempt.
-- Everything here is transient scan/exec metadata — nothing is persisted.
-- No-op unless D5ZCLONS.2DA loads with at least one usable row.
-- ============================================================

BfBot.FiveE = {}

BfBot.FiveE._TABLE = "D5ZCLONS"
BfBot.FiveE._STATE_SYMBOLS = {
    arcane = "D5_SEMI_ARCANE",
    divine = "D5_SEMI_DIVINE",
}
BfBot.FiveE._TICKS_PER_SECOND = 15     -- m_gameTime rate (gotchas.md)
BfBot.FiveE._POLL_TICKS = 3            -- SmallWait step while a refresh is pending
-- Grace after the wrapper-declared delay. A delayed effect only fires on the
-- sprite's stat rebuild pass (every 15th AI call, 30 ticks while slowed), and
-- upstream's regrant needs several effect hops after that, so allow four
-- normal rebuild periods before treating the wrappers as really gone.
BfBot.FiveE._REFRESH_MARGIN_TICKS = 60
BfBot.FiveE._MAX_DELAY_SECONDS = 6     -- sanity cap on a wrapper-declared delay
BfBot.FiveE._LOG_FILE = "buffbot_5e.log"

-- Lazily loaded session caches (game resources are static per session).
BfBot.FiveE._map = nil          -- nil = not loaded, false = absent/unusable
BfBot.FiveE._mapReason = nil    -- why the map is absent (diagnostics)
BfBot.FiveE._stateIDs = nil     -- { arcane = id?, divine = id? }
BfBot.FiveE._wrapperMeta = {}   -- [WRAPPER] = meta | false
BfBot.FiveE._warned = {}

--- Drop every cached lookup (hot reload, tests, diagnostics).
function BfBot.FiveE.Reset()
    BfBot.FiveE._map = nil
    BfBot.FiveE._mapReason = nil
    BfBot.FiveE._stateIDs = nil
    BfBot.FiveE._wrapperMeta = {}
    BfBot.FiveE._warned = {}
end

local function _warnOnce(key, msg)
    if BfBot.FiveE._warned[key] then return end
    BfBot.FiveE._warned[key] = true
    BfBot._Warn("[5E] " .. msg)
end

--- Normalize a 2DA/effect resource cell to an uppercase resref, or nil for
--- placeholders ("#", "*", "****"), blanks, and values no resref can hold.
local function _resref(value)
    if type(value) ~= "string" then return nil end
    local s = value:match("^%s*(.-)%s*$")
    if s == "" or s:find("^[#*]") or #s > 8 or s:find("%s") then
        return nil
    end
    return s:upper()
end
BfBot.FiveE._Resref = _resref

-- ============================================================
-- Mapping table
-- ============================================================

--- PURE: build the lookup map from raw d5zclons rows.
--- rows: array of { label=IND, mem=, cast=, type=, processed= } strings.
--- A wrapper IND may be shared by several rows (upstream reuses an index
--- when the cast spell is already listed, e.g. Faiths & Powers sphere
--- copies whose MEM differs from CAST), so byIndex keeps every row.
--- Returns map, or nil + reason when no usable row exists.
function BfBot.FiveE._BuildMap(rows)
    local map = {
        byIndex = {}, byWrapper = {}, byMem = {},
        rowCount = 0, dropped = 0, droppedRows = {},
    }
    if type(rows) ~= "table" then return nil, "no_rows" end

    for _, row in ipairs(rows) do
        local label = type(row) == "table" and row.label or nil
        local ind = tonumber(type(label) == "string"
            and label:match("^%s*(.-)%s*$") or label)
        local mem = type(row) == "table" and _resref(row.mem) or nil
        local cast = type(row) == "table" and _resref(row.cast) or nil
        local rawType = type(row) == "table" and type(row.type) == "string"
            and row.type:match("^%s*(.-)%s*$"):lower() or ""
        local isPlaceholder = type(row) == "table"
            and type(row.mem) == "string" and row.mem:find("^%s*#") ~= nil

        local wrapper = nil
        if ind and ind == math.floor(ind) and ind >= 0 then
            wrapper = "D5Z" .. string.format("%d", ind) .. "I"
            if #wrapper > 8 then wrapper = nil end
        end

        if wrapper and mem and cast then
            local rec = {
                ind = ind,
                mem = mem,
                cast = cast,
                type = (rawType == "arcane" or rawType == "divine")
                    and rawType or nil,
                processed = (type(row.processed) == "string"
                    and row.processed:match("^%s*(.-)%s*$"):lower() == "yes")
                    and 1 or 0,
                wrapper = wrapper,
                block = "D5Z" .. string.format("%d", ind) .. "B",
            }
            local slot = map.byIndex[ind]
            if not slot then
                slot = { wrapper = wrapper, rows = {} }
                map.byIndex[ind] = slot
                map.byWrapper[wrapper] = ind
            end
            slot.rows[#slot.rows + 1] = rec
            map.byMem[mem] = map.byMem[mem] or {}
            table.insert(map.byMem[mem], rec)
            map.rowCount = map.rowCount + 1
        elseif not isPlaceholder then
            -- Upstream seeds the table with a "100 # # # #" placeholder row;
            -- anything else that cannot map is a malformed/unsupported row.
            map.dropped = map.dropped + 1
            map.droppedRows[#map.droppedRows + 1] = tostring(label)
        end
    end

    if map.rowCount == 0 then return nil, "no_usable_rows" end
    return map
end

--- Engine read of d5zclons.2da into raw rows. Locates the four columns by
--- label when the binding exposes column labels, else by upstream order.
function BfBot.FiveE._ReadTableRows()
    if type(EEex_Resource_Load2DA) ~= "function" then
        return nil, "no_2da_api"
    end
    -- Cheap index lookup first so an ordinary (non-5E) install never asks
    -- the engine to load a resource it does not have.
    if type(EEex_Resource_Fetch) == "function" then
        local okFetch, res = pcall(EEex_Resource_Fetch, BfBot.FiveE._TABLE, "2DA")
        if okFetch and res == nil then return nil, "absent" end
    end
    local okLoad, tda = pcall(EEex_Resource_Load2DA, BfBot.FiveE._TABLE)
    if not okLoad or not tda then return nil, "load_failed" end
    local okDim, sizeX, sizeY = pcall(function() return tda:getDimensions() end)
    if not okDim or type(sizeX) ~= "number" or type(sizeY) ~= "number"
        or sizeY <= 0 then
        return nil, "absent"
    end
    -- getDimensions' x includes the row-label column.
    if sizeX < 5 then return nil, "too_few_columns" end

    local cols = { mem = 0, cast = 1, type = 2, processed = 3 }
    local okLabels = pcall(function()
        local found = {}
        for x = 0, sizeX - 2 do
            local label = tda:getColumnLabel(x)
            label = type(label) == "string" and label:upper() or ""
            if label == "MEM" then found.mem = x
            elseif label == "CAST" then found.cast = x
            elseif label == "TYPE" then found.type = x
            elseif label == "PROCESSED" then found.processed = x
            end
        end
        if found.mem and found.cast and found.type and found.processed then
            cols = found
        end
    end)
    if not okLabels then
        _warnOnce("column_labels", "column labels unreadable; using upstream column order")
    end

    local rows = {}
    local okRows, err = pcall(function()
        for y = 0, sizeY - 1 do
            rows[#rows + 1] = {
                label = tda:getRowLabel(y),
                mem = tda:getAtPoint(cols.mem, y),
                cast = tda:getAtPoint(cols.cast, y),
                type = tda:getAtPoint(cols.type, y),
                processed = tda:getAtPoint(cols.processed, y),
            }
        end
    end)
    if not okRows then return nil, "read_failed: " .. tostring(err) end
    return rows
end

--- The session map, or nil when 5E Spellcasting is not installed/usable.
function BfBot.FiveE.GetMap()
    if BfBot.FiveE._map ~= nil then
        return BfBot.FiveE._map or nil
    end
    local rows, readReason = BfBot.FiveE._ReadTableRows()
    local map, buildReason = nil, readReason
    if rows then map, buildReason = BfBot.FiveE._BuildMap(rows) end
    BfBot.FiveE._map = map or false
    BfBot.FiveE._mapReason = map and "ok" or buildReason
    if map then
        BfBot._Log(string.format("[5E] %s: %d rows, %d dropped",
            BfBot.FiveE._TABLE, map.rowCount, map.dropped))
        if map.dropped > 0 then
            _warnOnce("dropped_rows", string.format(
                "%s: ignored %d malformed row(s) (labels: %s)",
                BfBot.FiveE._TABLE, map.dropped,
                table.concat(map.droppedRows, ",")))
        end
    end
    return map
end

--- True when the 5E Spellcasting table is installed and usable.
function BfBot.FiveE.IsInstalled()
    return BfBot.FiveE.GetMap() ~= nil
end

-- ============================================================
-- Per-caster conversion state
-- ============================================================

--- Resolve upstream's per-caster SPLSTATE IDs by symbol (never hardcoded:
--- WeiDU assigns them at install time). Missing symbols stay nil.
function BfBot.FiveE._StateIDs()
    if BfBot.FiveE._stateIDs ~= nil then return BfBot.FiveE._stateIDs end
    local ids = {}
    local ok, err = pcall(function()
        local list = EEex_Resource_LoadIDS("SPLSTATE")
        EEex_Resource_IterateUnpackedIDSEntries(list, function(id, line, start)
            local symbol = type(start) == "string" and start or line
            symbol = type(symbol) == "string"
                and symbol:match("^%s*(.-)%s*$"):upper() or ""
            for kind, wanted in pairs(BfBot.FiveE._STATE_SYMBOLS) do
                if symbol == wanted and type(id) == "number" then
                    ids[kind] = id
                end
            end
        end)
    end)
    if not ok then
        _warnOnce("state_ids", "SPLSTATE.IDS lookup failed ("
            .. tostring(err) .. "); relying on wrapper presence only")
    elseif not ids.arcane and not ids.divine then
        _warnOnce("state_ids", "D5_SEMI_ARCANE/D5_SEMI_DIVINE not in SPLSTATE.IDS;"
            .. " relying on wrapper presence only")
    end
    BfBot.FiveE._stateIDs = ids
    return ids
end

--- Which spell families upstream manages for this caster.
--- presentTypes: { arcane = true?, divine = true? } from the wrappers it
--- holds, counting only wrappers whose table rows agree on one family — an
--- index shared by an arcane and a divine row (add_semi_spells cross-family
--- entries) says nothing about which side of a multiclass was converted.
--- A family is managed while its SPLSTATE is active or such a wrapper is
--- present (the latter also covers an unresolvable state lookup).
function BfBot.FiveE.ManagedTypes(sprite, presentTypes)
    local managed = {}
    for kind, id in pairs(BfBot.FiveE._StateIDs()) do
        local ok, active = pcall(function() return sprite:getSpellState(id) end)
        if ok and active then managed[kind] = true end
    end
    for kind in pairs(presentTypes or {}) do managed[kind] = true end
    return managed
end

--- Every source resref currently on the sprite's timed effect list, upper
--- case. One pass: callers ask several questions of the same list.
function BfBot.FiveE._EffectSources(sprite)
    local sources = {}
    pcall(function()
        EEex_Utility_IterateCPtrList(sprite.m_timedEffectList, function(effect)
            local key = _resref(effect.m_sourceRes:get())
            if key then sources[key] = true end
        end)
    end)
    return sources
end

-- ============================================================
-- Wrapper resources
-- ============================================================

local function _fbResref(fb)
    local v = fb[BfBot._fields.fb_res]
    if type(v) == "userdata" or type(v) == "table" then
        local ok, s = pcall(function() return v:get() end)
        return ok and _resref(s) or nil
    end
    return _resref(v)
end

--- Static metadata of one wrapper SPL: which mapped spell it really casts
--- (read from its own op146/op148 payload, validated against the table's
--- CAST candidates for that index) and the longest delayed-effect delay it
--- declares (upstream's regrant timer). false when the wrapper cannot be
--- trusted — callers then hide it and never cast it.
function BfBot.FiveE._WrapperMeta(map, wrapper)
    local cached = BfBot.FiveE._wrapperMeta[wrapper]
    if cached ~= nil then return cached or nil end

    local function reject(reason)
        BfBot.FiveE._wrapperMeta[wrapper] = false
        _warnOnce("wrapper:" .. wrapper, wrapper .. " ignored: " .. reason)
        return nil
    end

    local ind = map.byWrapper[wrapper]
    local slot = ind and map.byIndex[ind]
    if not slot then return reject("not listed in " .. BfBot.FiveE._TABLE) end

    local candidates = {}
    for _, rec in ipairs(slot.rows) do candidates[rec.cast] = true end

    local okHeader, header = pcall(EEex_Resource_Demand, wrapper, "SPL")
    if not okHeader or not header then return reject("SPL not loadable") end
    local okAbility, ability = pcall(function() return header:getAbility(0) end)
    if not okAbility or not ability then return reject("no ability") end

    local cast, delay = nil, 0
    BfBot.Class._IterateFeatureBlocks(header, ability, function(fb)
        local opcode = fb[BfBot._fields.fb_opcode]
        if (opcode == 146 or opcode == 148) and not cast then
            local res = _fbResref(fb)
            if res and candidates[res] then cast = res end
        end
        local rawTiming = fb[BfBot._fields.fb_timing]
        local timing = type(rawTiming) == "number" and bit.band(rawTiming, 0xFF) or -1
        -- Delayed modes: 3 = delay/limited, 4 = delay/permanent,
        -- 5 = delay/while equipped. The duration field is the delay.
        if timing == 3 or timing == 4 or timing == 5 then
            local dur = fb[BfBot._fields.fb_duration]
            if type(dur) == "number" and dur > delay then delay = dur end
        end
    end)
    if not cast then return reject("casts no spell mapped to index " .. ind) end
    if delay > BfBot.FiveE._MAX_DELAY_SECONDS then
        _warnOnce("delay:" .. wrapper, string.format(
            "%s declares a %ds refresh delay; capping the wait at %ds",
            wrapper, delay, BfBot.FiveE._MAX_DELAY_SECONDS))
        delay = BfBot.FiveE._MAX_DELAY_SECONDS
    end

    local mems, families, familyCount, kind = {}, {}, 0, nil
    for _, rec in ipairs(slot.rows) do
        if rec.cast == cast then
            mems[#mems + 1] = rec.mem
            if rec.type and not families[rec.type] then
                families[rec.type] = true
                familyCount = familyCount + 1
                kind = rec.type
            end
        end
    end
    -- Mixed-family index: the wrapper stands for both, so it identifies
    -- neither. Callers fall back to the row's own spell type.
    if familyCount ~= 1 then kind = nil end

    local meta = {
        wrapper = wrapper, ind = ind, cast = cast, type = kind,
        delay = delay, mems = mems, block = slot.rows[1].block,
    }
    BfBot.FiveE._wrapperMeta[wrapper] = meta
    return meta
end

--- Upstream grants location-2 innates, which the engine may list under the
--- Cast Spell button (type 2) and/or innates (type 4). Take the largest
--- per-type count so a double listing never doubles the shared pool.
function BfBot.FiveE._WrapperCount(countsByType, wrapper)
    local best = 0
    for _, counts in pairs(countsByType or {}) do
        for resref, n in pairs(counts) do
            if _resref(resref) == wrapper and type(n) == "number" and n > best then
                best = n
            end
        end
    end
    return best
end

local function _familyOf(rec, entry)
    if rec.type then return rec.type end
    local spellType = entry and entry.spellType
    if spellType == 1 then return "arcane" end
    if spellType == 2 then return "divine" end
    return nil
end

-- ============================================================
-- Catalog overlay (called by BfBot.Scan.GetCastableSpells)
-- ============================================================

--- The wrapper delivers CAST, so CAST's resources are what land on the
--- target: give a MEM row CAST's classification, targeting and effect identity.
--- The executor copies these fields into queue entries at build
--- time, so this must hold whether or not a wrapper is present right now.
--- @return false when CAST cannot be loaded (the row must stay uncastable)
local function _adoptCastIdentity(entry, cast, buildEntry)
    if cast == _resref(entry.resref) then return true end
    local okCast, castEntry = pcall(buildEntry, cast)
    if not okCast or not castEntry then return false end
    entry.class = castEntry.class
    -- Keep the player's include/exclude choice on the visible MEM row.
    -- Classifier results are shared: copy before applying that choice so
    -- another spell mapped to CAST does not inherit MEM's override.
    local override = BfBot.Class.GetOverride(entry.resref)
    if entry.class and override ~= nil then
        local class = {}
        for k, v in pairs(entry.class) do class[k] = v end
        class.isBuff = override
        class.isAmbiguous = false
        class.overridden = true
        class.score = override and 10 or -10
        entry.class = class
    end
    entry.isAoE = castEntry.isAoE
    entry.isSelfOnly = castEntry.isSelfOnly
    entry.leafResrefs = castEntry.leafResrefs
    entry.stateMarkersByResref = castEntry.stateMarkersByResref
    entry.duration = castEntry.duration
    entry.durCat = castEntry.durCat
    entry.hasVariants = castEntry.hasVariants
    entry.variants = castEntry.variants
    entry.isProjectImage = castEntry.isProjectImage
    return true
end

--- Rewrite one sprite's freshly built spell catalog for 5E Spellcasting.
--- @param sprite    the scanned sprite (party member or summon)
--- @param spells    {[resref] = entry} before the item merge (mutated)
--- @param countsByType {[buttonType] = {[resref] = count}} from GetQuickButtons
--- @param buildEntry function(resref) -> scanner catalog entry | nil
--- Rows may be added or removed: the caller recounts the table afterwards.
function BfBot.FiveE.ApplyToCatalog(sprite, spells, countsByType, buildEntry)
    local map = BfBot.FiveE.GetMap()
    if not map then return end

    -- 1. Wrapper rows are upstream plumbing: hide every one of them and
    --    collect the trusted ones with their live counts. Wrappers the
    --    engine lists as quick buttons but the known iterator missed are
    --    still castable, so consider both sources.
    local wrappers = {}
    for resref, entry in pairs(spells) do
        local key = _resref(resref)
        if key and map.byWrapper[key] and entry.kind ~= "itm" then
            spells[resref] = nil
            wrappers[key] = true
        end
    end
    for _, counts in pairs(countsByType or {}) do
        for resref in pairs(counts) do
            local key = _resref(resref)
            if key and map.byWrapper[key] then wrappers[key] = true end
        end
    end

    local present, presentTypes = {}, {}
    for wrapper in pairs(wrappers) do
        local meta = BfBot.FiveE._WrapperMeta(map, wrapper)
        if meta then
            present[#present + 1] = {
                meta = meta,
                count = BfBot.FiveE._WrapperCount(countsByType, wrapper),
            }
            if meta.type then presentTypes[meta.type] = true end
        end
    end
    table.sort(present, function(a, b) return a.meta.ind < b.meta.ind end)

    local managed = BfBot.FiveE.ManagedTypes(sprite, presentTypes)

    local keyOf = {}
    for resref in pairs(spells) do
        local key = _resref(resref)
        if key then keyOf[key] = resref end
    end

    -- 2. Attach each trusted wrapper to the spellbook rows it stands for.
    local function attach(catalogKey, p)
        local entry = spells[catalogKey]
        local current = entry.d5
        if current and current.available == 1
            and (current.count or 0) >= p.count then
            return  -- another index already backs this row at least as well
        end
        local d5 = {
            wrapper = p.meta.wrapper, cast = p.meta.cast, ind = p.meta.ind,
            type = p.meta.type or _familyOf({}, entry), block = p.meta.block,
            delay = p.meta.delay, count = p.count,
            available = p.count > 0 and 1 or 0,
        }
        if not _adoptCastIdentity(entry, p.meta.cast, buildEntry) then
            d5.available = 0
            d5.reason = "cast_unresolved"
            _warnOnce("cast:" .. p.meta.cast, p.meta.wrapper
                .. " casts unloadable " .. p.meta.cast .. "; not castable")
        end
        entry.d5 = d5
        entry.count = d5.available == 1 and p.count or 0
    end

    local attached = {}
    for _, p in ipairs(present) do
        local targets = {}
        for _, mem in ipairs(p.meta.mems) do
            local key = keyOf[mem]
            if key then targets[#targets + 1] = key end
        end
        if #targets == 0 then
            -- Free-cast grants (specialist schools, sphere lists) can hand a
            -- caster a wrapper for a spell it never learned: give that spell
            -- its own logical row under the MEM identity.
            for _, mem in ipairs(p.meta.mems) do
                local okEntry, entry = pcall(buildEntry, mem)
                if okEntry and entry then
                    spells[mem] = entry
                    keyOf[mem] = mem
                    targets[1] = mem
                    break
                end
            end
        end
        for _, key in ipairs(targets) do
            attach(key, p)
            attached[key] = true
        end
        if #targets == 0 then
            _warnOnce("nomem:" .. p.meta.wrapper, p.meta.wrapper
                .. " has no loadable spellbook spell; hidden")
        end
    end

    -- 3. Fail closed for managed families: a listed spell without a
    --    wrapper is unprepared, exhausted, or mid-refresh. Never let it fall
    --    back to a native memorization slot.
    -- With no wrapper of any family in sight, upstream either has nothing
    -- left to grant or is between a cast's strip and its delayed regrant.
    -- Rows that are prepared (no block effect) are marked pending so a queue
    -- built inside that window keeps them and the executor can wait it out.
    local stripped = next(wrappers) == nil
    local blockSources = nil

    for key, entry in pairs(spells) do
        if not attached[key] and entry.kind ~= "itm" then
            local recs = map.byMem[_resref(key) or ""]
            if recs then
                for _, rec in ipairs(recs) do
                    local family = _familyOf(rec, entry)
                    if family and managed[family] then
                        entry.count = 0
                        -- A queue built now (e.g. mid-refresh) keeps this
                        -- identity for later attempts, so it must be CAST's.
                        _adoptCastIdentity(entry, rec.cast, buildEntry)
                        local d5 = {
                            wrapper = rec.wrapper, cast = rec.cast,
                            ind = rec.ind, type = family, block = rec.block,
                            delay = 0, count = 0, available = 0,
                        }
                        if stripped then
                            blockSources = blockSources
                                or BfBot.FiveE._EffectSources(sprite)
                            local meta = not blockSources[rec.block]
                                and BfBot.FiveE._WrapperMeta(map, rec.wrapper)
                            if meta then
                                d5.pending = 1
                                d5.delay = meta.delay
                            end
                        end
                        entry.d5 = d5
                        break
                    end
                end
            end
        end
    end
end

--- True while this row's casts are missing only because upstream is between
--- stripping and regranting its wrappers (BfBot.Persist queue builders).
function BfBot.FiveE.AwaitingRefresh(spellData)
    return spellData ~= nil and spellData.kind ~= "itm"
        and spellData.d5 ~= nil and spellData.d5.pending == 1
end

--- Last-resort pass when ApplyToCatalog raised: hide wrapper rows and make
--- every table-listed spell unavailable, whatever the caster's state.
function BfBot.FiveE.FailClosed(spells)
    local map = BfBot.FiveE.GetMap()
    if not map then return end
    for resref, entry in pairs(spells) do
        local key = _resref(resref)
        if key and entry.kind ~= "itm" then
            if map.byWrapper[key] then
                spells[resref] = nil
            elseif map.byMem[key] then
                entry.count = 0
                entry.d5 = nil
            end
        end
    end
end

-- ============================================================
-- Execution support (called by BfBot.Exec)
-- ============================================================

--- Refresh bookkeeping for one caster after a wrapper cast was queued.
function BfBot.FiveE.NewRefresh(d5)
    local delay = (d5 and type(d5.delay) == "number") and d5.delay or 0
    return {
        delayTicks = math.ceil(delay * BfBot.FiveE._TICKS_PER_SECOND),
        since = nil,   -- game time when the cast finished (set by _Advance)
        polls = 0,
        logged = false,
    }
end

--- Live per-type wrapper counts for a sprite (cheap: quick buttons only).
local function _liveCounts(sprite)
    if not (BfBot.Scan and BfBot.Scan._BuildCountMap) then return nil end
    local ok, _, byType = pcall(BfBot.Scan._BuildCountMap, sprite)
    return ok and byType or nil
end

--- Decide whether a wrapper-backed attempt must wait for upstream's refresh.
--- @return ticks to SmallWait before re-checking, or nil to proceed now.
--- Proceeding does not imply availability — _CheckEntry still decides.
function BfBot.FiveE.RefreshWait(caster, entry, sprite, now)
    local r = caster and caster.d5Refresh
    if not r or not entry or not entry.d5 then return nil end
    r.polls = r.polls + 1

    local elapsed
    if type(now) == "number" and type(r.since) == "number" then
        elapsed = now - r.since
    else
        -- No game clock: estimate conservatively (SmallWait ticks may be
        -- shorter than game ticks) so the wait errs long, never short.
        elapsed = math.floor((r.polls - 1) * BfBot.FiveE._POLL_TICKS / 2)
    end

    local step = BfBot.FiveE._POLL_TICKS
    -- Before the declared delay the wrappers are either not yet removed or
    -- not yet regranted — neither presence nor absence means anything.
    if elapsed < r.delayTicks then
        return math.max(1, math.min(step, r.delayTicks - elapsed))
    end

    local byType = _liveCounts(sprite)
    if byType then
        if BfBot.FiveE._WrapperCount(byType, entry.d5.wrapper) > 0 then
            caster.d5Refresh = nil
            return nil
        end
        -- Any other wrapper back means the regrant already ran: this one
        -- is exhausted or unprepared, so let the preflight skip it now.
        local map = BfBot.FiveE.GetMap()
        for _, counts in pairs(byType) do
            for resref, n in pairs(counts) do
                local key = _resref(resref)
                if key and map and map.byWrapper[key] and n > 0 then
                    caster.d5Refresh = nil
                    return nil
                end
            end
        end
    end

    if elapsed < r.delayTicks + BfBot.FiveE._REFRESH_MARGIN_TICKS then
        return step
    end
    caster.d5Refresh = nil
    return nil
end

--- True when the caster carries upstream's "not prepared" block for this
--- spell's index (effect sourced from d5z<IND>b; removed when prepared).
function BfBot.FiveE.IsBlocked(sprite, d5)
    if not sprite or not d5 or not d5.block then return false end
    return BfBot.FiveE._EffectSources(sprite)[d5.block] == true
end

--- Human-readable skip reason for an unavailable wrapper-backed row.
function BfBot.FiveE.UnavailableReason(sprite, spellData)
    local d5 = spellData and spellData.d5
    if not d5 then return nil end
    if d5.reason == "cast_unresolved" then
        return "5E: cast spell " .. tostring(d5.cast) .. " not loadable"
    end
    if BfBot.FiveE.IsBlocked(sprite, d5) then
        return "no slot - 5E: spell not prepared"
    end
    return "no slot - 5E: no casts left at this level"
end

-- ============================================================
-- Diagnostics for testers: BfBot.FiveE.Diagnose()
-- Writes buffbot_5e.log in the game directory (never the console).
-- ============================================================

local function _rawWrappers(sprite, map)
    local seen = {}
    pcall(function()
        for _, _, resref in EEex_Sprite_GetKnownInnateSpellsWithAbilityIterator(sprite) do
            local key = _resref(resref)
            if key and map.byWrapper[key] then seen[key] = true end
        end
    end)
    return seen
end

local function _diagnoseSprite(label, sprite, map, out)
    out(string.format("[%s] %s", label, BfBot._GetName(sprite)))
    local ids = BfBot.FiveE._StateIDs()
    local states = {}
    for kind, id in pairs(ids) do
        local ok, active = pcall(function() return sprite:getSpellState(id) end)
        states[#states + 1] = kind .. "=" .. (ok and tostring(active) or "error")
    end
    table.sort(states)
    out("  states: " .. (#states > 0 and table.concat(states, " ") or "unresolved"))

    local byType = _liveCounts(sprite) or {}
    local known = _rawWrappers(sprite, map)
    local all = {}
    for key in pairs(known) do all[key] = true end
    for _, counts in pairs(byType) do
        for resref in pairs(counts) do
            local key = _resref(resref)
            if key and map.byWrapper[key] then all[key] = true end
        end
    end
    local list = {}
    for key in pairs(all) do list[#list + 1] = key end
    table.sort(list)
    for _, key in ipairs(list) do
        local c2 = BfBot.FiveE._WrapperCount({ byType[2] or {} }, key)
        local c4 = BfBot.FiveE._WrapperCount({ byType[4] or {} }, key)
        local meta = BfBot.FiveE._WrapperMeta(map, key)
        out(string.format("  wrapper %s known=%s buttons(type2=%d,type4=%d) %s",
            key, tostring(known[key] == true), c2, c4,
            meta and string.format("cast=%s type=%s delay=%ss mem=%s",
                meta.cast, tostring(meta.type), tostring(meta.delay),
                table.concat(meta.mems, "/"))
            or "UNTRUSTED"))
    end

    BfBot.Scan.Invalidate(sprite)
    local okScan, spells = pcall(BfBot.Scan.GetCastableSpells, sprite)
    if not okScan or type(spells) ~= "table" then
        out("  scan failed: " .. tostring(spells))
        return
    end
    local rows = {}
    for resref, entry in pairs(spells) do
        if entry.d5 then rows[#rows + 1] = resref end
        if _resref(resref) and map.byWrapper[_resref(resref)] then
            out("  ERROR: wrapper row leaked into catalog: " .. resref)
        end
    end
    table.sort(rows)
    for _, resref in ipairs(rows) do
        local entry = spells[resref]
        local d5 = entry.d5
        local native = 0
        for _, counts in pairs(byType) do
            for r, n in pairs(counts) do
                if _resref(r) == _resref(resref) then native = native + n end
            end
        end
        local status
        if d5.available == 1 then
            status = "castable"
        elseif BfBot.FiveE.IsBlocked(sprite, d5) then
            status = "not prepared"
        else
            status = "unavailable (" .. (d5.reason or "exhausted or refreshing") .. ")"
        end
        out(string.format("  row %s \"%s\" count=%d via %s cast=%s %s%s",
            resref, tostring(entry.name), entry.count or 0, d5.wrapper,
            d5.cast, status,
            native > 0 and string.format(" [native buttons=%d ignored]", native) or ""))
    end
end

--- Tester diagnostics. Returns true when the report was written.
function BfBot.FiveE.Diagnose()
    if BfBot.Exec and BfBot.Exec._state == "running" then
        BfBot._Display("[BuffBot] 5E diagnostics: wait until casting finishes.")
        return false
    end
    BfBot.FiveE.Reset()
    local opened = BfBot._OpenLogAppend(BfBot.FiveE._LOG_FILE)
    local out = BfBot._Print
    out("=== BuffBot " .. tostring(BfBot.VERSION) .. " 5E Spellcasting diagnostics ===")
    local map = BfBot.FiveE.GetMap()
    if not map then
        out("5E table " .. BfBot.FiveE._TABLE .. ": not usable ("
            .. tostring(BfBot.FiveE._mapReason) .. ")")
    else
        local wrappers = 0
        for _ in pairs(map.byWrapper) do wrappers = wrappers + 1 end
        out(string.format("5E table %s: %d rows, %d wrapper indices, %d dropped",
            BfBot.FiveE._TABLE, map.rowCount, wrappers, map.dropped))
        local ids = BfBot.FiveE._StateIDs()
        out(string.format("SPLSTATE D5_SEMI_ARCANE=%s D5_SEMI_DIVINE=%s",
            tostring(ids.arcane), tostring(ids.divine)))
        local gt = BfBot.Exec and BfBot.Exec._GetGameTime and BfBot.Exec._GetGameTime()
        out("game time: " .. tostring(gt))
        for slot = 0, 5 do
            local sprite = EEex_Sprite_GetInPortrait(slot)
            if sprite then
                local ok, err = pcall(_diagnoseSprite, "party " .. slot, sprite, map, out)
                if not ok then out("  diagnostics failed: " .. tostring(err)) end
            end
        end
        local okSummons, summons = pcall(BfBot.Scan.GetAlliedSummons)
        if okSummons and type(summons) == "table" then
            for _, s in ipairs(summons) do
                local ok, err = pcall(_diagnoseSprite,
                    "summon " .. tostring(s.oid), s.sprite, map, out)
                if not ok then out("  diagnostics failed: " .. tostring(err)) end
            end
        end
    end
    out("=== end ===")
    BfBot._CloseLog()
    BfBot._Display("[BuffBot] 5E diagnostics written to " .. BfBot.FiveE._LOG_FILE)
    return opened
end
