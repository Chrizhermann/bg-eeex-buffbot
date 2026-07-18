-- ============================================================
-- BfBotPer.lua — Configuration Persistence (BfBot.Persist)
-- Save/load per-character config via EEex marshal handlers,
-- global preferences via INI
-- ============================================================

BfBot.Persist = {}

-- Constants
BfBot.Persist._SCHEMA_VERSION = 8
BfBot.Persist._KEY = "BB"        -- UDAux storage key
BfBot.Persist._HANDLER = "BuffBot" -- marshal handler name

-- INI preference defaults (cross-save, stored in baldur.ini)
BfBot.Persist._INI_DEFAULTS = {
    LongThreshold = 300,  -- seconds (5 turns) — divides "long" from "short"
    DefaultPreset = 1,    -- which preset tab opens by default
    HotkeyCode    = 87,   -- F11
    ShowTooltips  = 1,    -- show spell tooltips in panel
    ConfirmCast   = 0,    -- show confirmation before casting
    CombatInterrupt = 1,  -- stop casting when hostiles detected nearby
    PanelX        = -1,   -- -1 = use default (centered)
    PanelY        = -1,
    PanelW        = -1,   -- -1 = use default (80% of screen)
    PanelH        = -1,
    Theme         = "bg2_light",  -- palette key (string)
    FontSize      = 2,    -- 1=small, 2=medium, 3=large
    MpControlMode = "auto",  -- multiplayer caster filter: "auto" | "manual" | "all"
    MpControlNames = "",     -- manual mode: comma-separated names the local player controls
    SummonsJoinCast = 1,     -- allied summons/clones with configured presets join party casts (#19)
}

-- ---- Default config ----

--- Return a fresh empty config with correct schema.
function BfBot.Persist.GetDefaultConfig()
    return {
        v  = BfBot.Persist._SCHEMA_VERSION,
        ap = 1,
        presets = {
            [1] = { name = "Long Buffs",  cat = "long",  qc = 0, spells = {} },
            [2] = { name = "Short Buffs", cat = "short", qc = 0, spells = {} },
        },
        opts = { skip = 1 },
        ovr  = {},
        -- v8: per-identity summon presets (issue #19). Present on every
        -- config for uniformity, but only the PROTAGONIST's is ever read —
        -- see GetSummonPreset.
        summons = {},
    }
end

--- Create a default spell entry from classification data.
-- @param classResult  classification table (may be nil)
-- @param enabled      optional 0 or 1 (default 1)
function BfBot.Persist._MakeDefaultSpellEntry(classResult, enabled)
    local tgt = "p"
    if classResult and classResult.defaultTarget == "s" then
        tgt = "s"
    end
    return { on = (enabled == 0) and 0 or 1, tgt = tgt, pri = 999, lock = 0 }
end

--- Scan a character's spells and create a populated default config.
function BfBot.Persist._CreateDefaultConfig(sprite)
    local config = BfBot.Persist.GetDefaultConfig()

    -- Try to populate from scanner (may fail if sprite not fully loaded)
    local ok, spells, count = pcall(BfBot.Scan.GetCastableSpells, sprite)
    if not ok or not spells or count == 0 then
        -- Store empty config; will be populated when UI opens
        local setOk = pcall(function()
            EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = config
        end)
        if not setOk then
            BfBot._Warn("[Persist] Failed to store default config in UDAux")
        end
        return config
    end

    -- Collect buff spells with classification data
    local buffs = {}
    for resref, data in pairs(spells) do
        if data.class and data.class.isBuff and data.count > 0 then
            table.insert(buffs, {
                resref    = resref,
                classData = data.class,
                duration  = data.duration or 0,
                durCat    = data.durCat or "short",
            })
        end
    end

    -- Sort: permanent first, then long desc, then short desc
    local durOrder = { permanent = 1, long = 2, short = 3, instant = 4 }
    table.sort(buffs, function(a, b)
        local oa = durOrder[a.durCat] or 5
        local ob = durOrder[b.durCat] or 5
        if oa ~= ob then return oa < ob end
        if a.duration ~= b.duration then return a.duration > b.duration end
        return a.resref < b.resref
    end)

    -- Distribute ALL spells to BOTH presets (different enabled states).
    -- Enabled spells get low priorities (cast first), disabled get high.
    local p1enCount, p2enCount = 0, 0
    for _, buff in ipairs(buffs) do
        if buff.durCat == "long" or buff.durCat == "permanent" then
            p1enCount = p1enCount + 1
        elseif buff.durCat == "short" then
            p2enCount = p2enCount + 1
        end
    end

    local p1en, p1dis = 1, 1
    local p2en, p2dis = 1, 1
    for _, buff in ipairs(buffs) do
        local isLong = (buff.durCat == "long" or buff.durCat == "permanent")
        local isShort = (buff.durCat == "short")

        -- Preset 1: long/permanent enabled, everything else disabled
        local e1 = BfBot.Persist._MakeDefaultSpellEntry(buff.classData, isLong and 1 or 0)
        if isLong then
            e1.pri = p1en;  p1en = p1en + 1
        else
            e1.pri = p1enCount + p1dis;  p1dis = p1dis + 1
        end
        config.presets[1].spells[buff.resref] = e1

        -- Preset 2: short enabled, everything else disabled
        local e2 = BfBot.Persist._MakeDefaultSpellEntry(buff.classData, isShort and 1 or 0)
        if isShort then
            e2.pri = p2en;  p2en = p2en + 1
        else
            e2.pri = p2enCount + p2dis;  p2dis = p2dis + 1
        end
        config.presets[2].spells[buff.resref] = e2
    end

    -- Store in UDAux. Only call Refresh if the write succeeded — otherwise
    -- Refresh → GetConfig → _CreateDefaultConfig re-enters recursively
    -- (GetConfig's `if not config` gate sees the still-empty UDAux), which
    -- recurses until stack overflow.
    local setOk = pcall(function()
        EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = config
    end)
    if not setOk then
        BfBot._Warn("[Persist] Failed to store default config in UDAux; skipping innate reconciliation")
        return config
    end

    -- Reconcile innates with the new config. UDAux is now populated, so
    -- Refresh's call to GetConfig returns the stored config (no reentry).
    if BfBot.Innate and BfBot.Innate.Refresh then
        for s = 0, 5 do
            if EEex_Sprite_GetInPortrait(s) == sprite then
                BfBot.Innate.Refresh(s)
                break
            end
        end
    end

    return config
end

-- ---- Validation ----

--- Validate and repair a config table. Never errors.
function BfBot.Persist._ValidateConfig(config)
    if type(config) ~= "table" then
        return BfBot.Persist.GetDefaultConfig()
    end

    -- Schema version
    if type(config.v) ~= "number" then
        config.v = BfBot.Persist._SCHEMA_VERSION
    end

    -- Active preset
    if type(config.ap) ~= "number" or config.ap < 1 or config.ap > 5 then
        config.ap = 1
    end

    -- Presets
    if type(config.presets) ~= "table" then
        config.presets = {
            [1] = { name = "Long Buffs",  cat = "long",  spells = {} },
            [2] = { name = "Short Buffs", cat = "short", spells = {} },
        }
    end

    -- Validate each preset
    for idx, preset in pairs(config.presets) do
        if type(preset) ~= "table" then
            config.presets[idx] = { name = "Preset " .. idx, cat = "custom", spells = {} }
        else
            if type(preset.name) ~= "string" then preset.name = "Preset " .. idx end
            if type(preset.cat) ~= "string" then preset.cat = "custom" end
            if type(preset.qc) ~= "number" or preset.qc < 0 or preset.qc > 2 then
                preset.qc = 0
            end
            if type(preset.spells) ~= "table" then
                preset.spells = {}
            else
                -- Validate individual spell entries
                for resref, entry in pairs(preset.spells) do
                    if type(entry) ~= "table" then
                        preset.spells[resref] = nil  -- remove corrupt entry
                    else
                        if type(entry.on) ~= "number" then entry.on = 0 end
                        -- tgt: string ("s", "p", "1"-"6") or table of name strings
                        local tt = type(entry.tgt)
                        if tt == "table" then
                            -- Validate table entries: keep only strings, drop corrupt
                            local cleaned = {}
                            for _, v in ipairs(entry.tgt) do
                                if type(v) == "string" then
                                    table.insert(cleaned, v)
                                end
                            end
                            if #cleaned == 0 then
                                entry.tgt = "p"  -- empty table → default
                            else
                                entry.tgt = cleaned
                            end
                        elseif tt ~= "string" then
                            entry.tgt = "p"
                        end
                        if type(entry.pri) ~= "number" then entry.pri = 999 end
                        if type(entry.lock) ~= "number" or (entry.lock ~= 0 and entry.lock ~= 1) then
                            entry.lock = 0
                        end
                    end
                end
            end
        end
    end

    -- Options
    if type(config.opts) ~= "table" then
        config.opts = { skip = 1 }
    else
        if type(config.opts.skip) ~= "number" then config.opts.skip = 1 end
    end

    -- Overrides (classification-level)
    if type(config.ovr) ~= "table" then
        config.ovr = {}
    else
        for resref, val in pairs(config.ovr) do
            if val ~= 1 and val ~= -1 then
                config.ovr[resref] = nil
            end
        end
    end

    -- Summons (schema v8): full subtree scrub — see _ValidateSummons. This
    -- is NOT left to the runtime accessor (GetSummonPreset): hand-edited
    -- preset files enter through ImportConfig → _ValidateConfig, and a single
    -- marshal-unsafe value (boolean/userdata) parked anywhere in the config
    -- crashes the NEXT save. Runtime reads/writes still go through
    -- GetSummonPreset (protagonist-only), which additionally repairs shape
    -- for mid-session mutations.
    if type(config.summons) ~= "table" then
        config.summons = {}
    else
        BfBot.Persist._ValidateSummons(config.summons)
    end

    return config
end

--- Scrub the summons subtree in place (schema v8). Whitelist by construction:
--- identity entries must be { presets = { [1..MAX_PRESETS] = { qc, spells } } };
--- unknown keys are dropped, known fields are type-enforced, malformed
--- identities/presets/entries are removed. Guarantees the subtree holds only
--- numbers/strings/tables (marshal constraint) after the pass.
-- @param summons  config.summons table (mutated in place)
-- @return the same table, scrubbed
function BfBot.Persist._ValidateSummons(summons)
    if type(summons) ~= "table" then return {} end
    for identity, entry in pairs(summons) do
        if type(identity) ~= "string" or identity == ""
            or type(entry) ~= "table" or type(entry.presets) ~= "table" then
            summons[identity] = nil
        else
            -- Identity entry: whitelist { presets }
            for k in pairs(entry) do
                if k ~= "presets" then entry[k] = nil end
            end
            for idx, preset in pairs(entry.presets) do
                if type(idx) ~= "number" or idx ~= math.floor(idx)
                    or idx < 1 or idx > BfBot.MAX_PRESETS
                    or type(preset) ~= "table" then
                    entry.presets[idx] = nil
                else
                    -- Preset: whitelist { qc, spells }
                    for k in pairs(preset) do
                        if k ~= "qc" and k ~= "spells" then preset[k] = nil end
                    end
                    if type(preset.qc) ~= "number"
                        or preset.qc < 0 or preset.qc > 2 then
                        preset.qc = 0
                    end
                    if type(preset.spells) ~= "table" then preset.spells = {} end
                    for resref, se in pairs(preset.spells) do
                        if type(resref) ~= "string" or type(se) ~= "table" then
                            preset.spells[resref] = nil
                        else
                            -- Spell entry: whitelist { on, tgt, pri, var }
                            for k in pairs(se) do
                                if k ~= "on" and k ~= "tgt"
                                    and k ~= "pri" and k ~= "var" then
                                    se[k] = nil
                                end
                            end
                            if type(se.on) ~= "number" then se.on = 0 end
                            local tt = type(se.tgt)
                            if tt == "table" then
                                local cleaned = {}
                                for _, v in ipairs(se.tgt) do
                                    if type(v) == "string" then
                                        table.insert(cleaned, v)
                                    end
                                end
                                if #cleaned == 0 then
                                    se.tgt = "p"
                                else
                                    se.tgt = cleaned
                                end
                            elseif tt ~= "string" then
                                se.tgt = "p"
                            end
                            if type(se.pri) ~= "number" then se.pri = 999 end
                            if se.var ~= nil and type(se.var) ~= "string" then
                                se.var = nil
                            end
                        end
                    end
                end
            end
        end
    end
    return summons
end

--- Migrate config from an older schema version.
function BfBot.Persist._MigrateConfig(config, fromVersion)
    if fromVersion < 4 then
        local globalCheat = (config.opts and config.opts.cheat == 1) and 2 or 0
        if config.presets then
            for _, preset in pairs(config.presets) do
                if type(preset) == "table" and preset.qc == nil then
                    preset.qc = globalCheat
                end
            end
        end
        if config.opts then
            config.opts.cheat = nil
        end
    end
    if fromVersion < 5 then
        if not config.ovr then config.ovr = {} end
    end
    if fromVersion < 6 then
        -- Add lock = 0 to all existing spell entries (validator default would also
        -- handle missing, but making it explicit documents the migration).
        if config.presets then
            for _, preset in pairs(config.presets) do
                if type(preset) == "table" and type(preset.spells) == "table" then
                    for _, entry in pairs(preset.spells) do
                        if type(entry) == "table" and entry.lock == nil then
                            entry.lock = 0
                        end
                    end
                end
            end
        end
    end
    if fromVersion < 7 then
        -- Strip Tweaks Anthology "Colorize NPC Names" color escapes (^0xAABBGGRR<name>^-)
        -- from persisted target names. Pre-v7 configs may have prefixed names baked in,
        -- which would never match a stripped _GetName(sprite) result post-fix. See #40.
        if config.presets then
            for _, preset in pairs(config.presets) do
                if type(preset) == "table" and type(preset.spells) == "table" then
                    for _, entry in pairs(preset.spells) do
                        if type(entry) == "table" then
                            if type(entry.tgt) == "string" then
                                entry.tgt = BfBot._StripColorEscape(entry.tgt)
                            elseif type(entry.tgt) == "table" then
                                for i, v in ipairs(entry.tgt) do
                                    if type(v) == "string" then
                                        entry.tgt[i] = BfBot._StripColorEscape(v)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if fromVersion < 8 then
        -- v8: summon casters (#19) — per-identity summon presets under
        -- config.summons. The table is added uniformly to EVERY character's
        -- config (simplest uniform bump), but only the PROTAGONIST's summons
        -- table is ever read or written — see _GetProtagonistConfig /
        -- GetSummonPreset.
        config.summons = config.summons or {}
    end
    config.v = BfBot.Persist._SCHEMA_VERSION
    return config
end

--- Lazy migration: fix wrong default targets from v1/v2 AoE misclassification.
--- Loads SPL data directly for each resref (works regardless of memorization state).
function BfBot.Persist._MigrateV1Targets(sprite, config)
    for _, preset in pairs(config.presets or {}) do
        if type(preset) ~= "table" or not preset.spells then goto nextPreset end
        for resref, spellCfg in pairs(preset.spells) do
            if spellCfg.tgt == "p" then
                -- Load SPL directly — works regardless of memorization state
                local ok, header = pcall(EEex_Resource_Demand, resref, "SPL")
                if ok and header then
                    local aOk, ability = pcall(function() return header:getAbility(0) end)
                    if aOk and ability then
                        local cOk, classResult = pcall(BfBot.Class.Classify, resref, header, ability)
                        if cOk and classResult and not classResult.isAoE then
                            spellCfg.tgt = "s"
                        end
                    end
                end
            end
        end
        ::nextPreset::
    end
end

-- ---- Marshal handlers ----

--- Exporter: called by EEex during save.
function BfBot.Persist._Export(sprite)
    local ok, result = pcall(function()
        -- Skip temporary copies (quicksave previews, area transitions)
        local copyOk, isCopy = pcall(function() return EEex.IsMarshallingCopy() end)
        if copyOk and isCopy then
            return {}
        end
        local config = EEex_GetUDAux(sprite)[BfBot.Persist._KEY]
        if config then
            return { cfg = config }
        end
        return {}
    end)
    if ok then return result end
    return {}  -- on error, return empty (don't crash save)
end

--- Importer: called by EEex during load.
function BfBot.Persist._Import(sprite, data)
    local ok, err = pcall(function()
        if not data or type(data) ~= "table" then return end
        local config = data.cfg
        if not config then return end

        -- Validate and repair
        config = BfBot.Persist._ValidateConfig(config)

        -- Migrate if needed
        if config.v < BfBot.Persist._SCHEMA_VERSION then
            config = BfBot.Persist._MigrateConfig(config, config.v)
        end

        EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = config

        -- Sync persisted overrides to classifier
        if config.ovr then
            for resref, val in pairs(config.ovr) do
                if val == 1 then
                    BfBot.Class.SetOverride(resref, true)
                elseif val == -1 then
                    BfBot.Class.SetOverride(resref, false)
                end
            end
        end
    end)
    if not ok then
        BfBot._Warn("[Persist] Import failed: " .. tostring(err))
    end
end

--- Register marshal handlers. Call once at load time.
function BfBot.Persist.Init()
    EEex_Sprite_AddMarshalHandlers(BfBot.Persist._HANDLER,
        function(sprite) return BfBot.Persist._Export(sprite) end,
        function(sprite, data) BfBot.Persist._Import(sprite, data) end
    )
end

-- ---- Config access ----

--- Get the config for a character sprite. Creates default if none exists.
function BfBot.Persist.GetConfig(sprite)
    if not sprite then return nil end
    local ok, config = pcall(function()
        return EEex_GetUDAux(sprite)[BfBot.Persist._KEY]
    end)
    if not ok then return nil end
    if not config then
        config = BfBot.Persist._CreateDefaultConfig(sprite)
    end
    -- Lazy migration: fix wrong default targets from v1/v2 AoE misclassification
    if config and type(config.v) == "number" and config.v < 3 then
        BfBot.Persist._MigrateV1Targets(sprite, config)
        config.v = 3
    end
    -- Lazy schema migration: _Import migrates at save load, but a config can
    -- still be at an older version mid-session (e.g. the module was reloaded
    -- after a schema bump). _MigrateConfig mutates in place, so the table
    -- held by UDAux stays migrated after the first access.
    if config and type(config.v) == "number"
        and config.v < BfBot.Persist._SCHEMA_VERSION then
        config = BfBot.Persist._MigrateConfig(config, config.v)
    end
    -- Shape guarantee (v8): a config can carry the current version yet miss
    -- the summons table (stamped by an intermediate module state, or a table
    -- lost across a round-trip under an older module). The migration gate
    -- can't catch that — v is already current — so repair at the read path;
    -- _ValidateConfig does the same at import/SetConfig time.
    if config and type(config.summons) ~= "table" then
        config.summons = {}
    end
    return config
end

--- Store a config on a character sprite. Validates before storing.
function BfBot.Persist.SetConfig(sprite, config)
    if not sprite or not config then return end
    config = BfBot.Persist._ValidateConfig(config)
    pcall(function()
        EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = config
    end)
end

--- Get a specific preset for a character.
function BfBot.Persist.GetPreset(sprite, presetIndex)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config or not config.presets then return nil end
    return config.presets[presetIndex]
end

--- Get the active preset and its index.
function BfBot.Persist.GetActivePreset(sprite)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return nil, 1 end
    local idx = config.ap or 1
    return config.presets[idx], idx
end

--- Set the active preset index (clamped 1-5).
function BfBot.Persist.SetActivePreset(sprite, presetIndex)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return end
    config.ap = math.max(1, math.min(BfBot.MAX_PRESETS, presetIndex))
end

-- ---- Spell config accessors ----

--- Set whether a spell is enabled in a preset.
function BfBot.Persist.SetSpellEnabled(sprite, presetIndex, resref, enabled)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset then return end
    if not preset.spells[resref] then
        preset.spells[resref] = BfBot.Persist._MakeDefaultSpellEntry(nil)
    end
    preset.spells[resref].on = (enabled == 1) and 1 or 0
end

--- Set the target for a spell in a preset.
function BfBot.Persist.SetSpellTarget(sprite, presetIndex, resref, target)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells[resref] then return end
    preset.spells[resref].tgt = target
end

--- Set the tgtUnlock override for a spell in a preset.
-- When set to 1, the target picker is enabled even for self-only/AoE spells.
function BfBot.Persist.SetTgtUnlock(sprite, presetIndex, resref, value)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells[resref] then return end
    preset.spells[resref].tgtUnlock = (value == 1) and 1 or 0
end

--- Get the tgtUnlock override for a spell in a preset.
-- @return number: 1 if unlocked, 0 or nil if locked (default)
function BfBot.Persist.GetTgtUnlock(sprite, presetIndex, resref)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells or not preset.spells[resref] then return 0 end
    return preset.spells[resref].tgtUnlock or 0
end

--- Get the selected variant resref for a spell in a preset.
--- @return string|nil: variant resref, or nil if not set
function BfBot.Persist.GetSpellVariant(sprite, presetIndex, resref)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells or not preset.spells[resref] then return nil end
    return preset.spells[resref].var
end

--- Set the selected variant resref for a spell in a preset.
function BfBot.Persist.SetSpellVariant(sprite, presetIndex, resref, variantResref)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset then return end
    if not preset.spells[resref] then
        preset.spells[resref] = BfBot.Persist._MakeDefaultSpellEntry(nil)
    end
    preset.spells[resref].var = variantResref  -- string or nil to clear
end

--- Set the priority for a spell in a preset.
function BfBot.Persist.SetSpellPriority(sprite, presetIndex, resref, priority)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells[resref] then return end
    preset.spells[resref].pri = priority
end

--- Get the lock state for a spell in a preset (0 = unlocked, 1 = locked).
function BfBot.Persist.GetSpellLock(sprite, presetIndex, resref)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells or not preset.spells[resref] then return 0 end
    return preset.spells[resref].lock or 0
end

--- Set the lock state for a spell in a preset. Creates the entry if missing.
function BfBot.Persist.SetSpellLock(sprite, presetIndex, resref, locked)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset then return end
    if not preset.spells[resref] then
        preset.spells[resref] = BfBot.Persist._MakeDefaultSpellEntry(nil)
    end
    preset.spells[resref].lock = (locked == 1) and 1 or 0
end

--- Get the config entry for a spell in a preset.
function BfBot.Persist.GetSpellConfig(sprite, presetIndex, resref)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells then return nil end
    return preset.spells[resref]
end

-- ---- Summon config accessors (schema v8, issue #19) ----
-- Summon/clone presets are keyed by summon IDENTITY (BfBot.Scan._SummonIdentity)
-- and live ONLY on the protagonist's config:
--     config.summons[identity] = { presets = { [n] = { qc, spells } } }
-- Every character's config carries a summons table (uniform v8 migration),
-- but all reads and writes go through the protagonist so the data has one
-- authoritative home that survives party reordering.

--- Find the protagonist sprite: the party member whose JOIN-ORDER character
--- index is 0 (EEex_Sprite_GetCharacterIndex) — NOT portrait slot 0, which
--- changes when portraits are reordered.
-- @return sprite or nil (+ warn) if no character-index-0 member exists
function BfBot.Persist._GetProtagonist()
    local firstErr = nil
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local ok, idx = pcall(EEex_Sprite_GetCharacterIndex, sprite)
            if ok and idx == 0 then
                return sprite
            elseif not ok and not firstErr then
                firstErr = tostring(idx)  -- surface API failure, don't mask it
            end
        end
    end
    BfBot._Warn("[Persist] _GetProtagonist: no party sprite with character index 0"
        .. (firstErr and (" (GetCharacterIndex error: " .. firstErr .. ")") or ""))
    return nil
end

--- Config of the protagonist (nil-safe). All summon config lives here.
function BfBot.Persist._GetProtagonistConfig()
    local prot = BfBot.Persist._GetProtagonist()
    if not prot then return nil end
    return BfBot.Persist.GetConfig(prot)
end

--- PURE (no engine calls): seed a clone's spell table from its owner's
--- preset, filtered to the spells the clone can actually cast. Deep-copies
--- on/tgt/pri/var — tgt may be an ordered TABLE of names, which must be
--- copied, never aliased, so edits to the summon config can never mutate the
--- owner's preset (or vice versa). Output holds numbers/strings/tables only
--- (marshal constraint: no booleans, no userdata).
--- Nil-safe: invalid ownerPreset or cloneCastable returns {}.
-- @param ownerPreset    owner preset table { spells = { [resref] = entry } }
-- @param cloneCastable  scan result for the clone { [resref] = {count=..} }
-- @return table: fresh spells table (never aliases input tables)
function BfBot.Persist._SeedCloneSpells(ownerPreset, cloneCastable)
    local seeded = {}
    if type(ownerPreset) ~= "table" or type(ownerPreset.spells) ~= "table"
        or type(cloneCastable) ~= "table" then
        return seeded
    end
    for resref, entry in pairs(ownerPreset.spells) do
        local scanData = cloneCastable[resref]
        if type(entry) == "table" and type(scanData) == "table"
            and (tonumber(scanData.count) or 0) > 0 then
            local copy = {
                on  = (type(entry.on) == "number") and entry.on or 0,
                pri = (type(entry.pri) == "number") and entry.pri or 999,
            }
            if type(entry.var) == "string" then copy.var = entry.var end
            if type(entry.tgt) == "table" then
                local t = {}
                for _, v in ipairs(entry.tgt) do
                    if type(v) == "string" then table.insert(t, v) end
                end
                if #t > 0 then copy.tgt = t else copy.tgt = "p" end
            elseif type(entry.tgt) == "string" then
                copy.tgt = entry.tgt
            else
                copy.tgt = "p"
            end
            seeded[resref] = copy
        end
    end
    return seeded
end

--- Shared argument validation for the summon-preset accessors
--- (GetSummonPreset / PeekSummonPreset). Same contract for both:
--- invalid args → warn + nil.
--- Integer preset index required: the Get accessor CREATES at the key, and a
--- fractional key would persist entries the export serializer silently drops
--- (its integer-key walk requires k == floor(k)).
-- @param fn        accessor name for the warn prefix
-- @param identity  summon identity key (non-empty string)
-- @param presetIdx preset index 1..BfBot.MAX_PRESETS (integer)
-- @return 1 when valid, nil (+ warn) otherwise
function BfBot.Persist._CheckSummonArgs(fn, identity, presetIdx)
    if type(identity) ~= "string" or identity == "" then
        BfBot._Warn("[Persist] " .. fn .. ": invalid identity ("
            .. tostring(identity) .. ")")
        return nil
    end
    if type(presetIdx) ~= "number" or presetIdx < 1
        or presetIdx > BfBot.MAX_PRESETS
        or presetIdx ~= math.floor(presetIdx) then
        BfBot._Warn("[Persist] " .. fn .. ": invalid preset index ("
            .. tostring(presetIdx) .. ")")
        return nil
    end
    return 1
end

--- READ-ONLY summon-preset lookup: the stored preset table, or nil when the
--- identity/preset does not exist. NEVER creates, never seeds, never mutates
--- config. Contract: queue building is a read path — only UI/seed flows may
--- create presets (via GetSummonPreset). Without this, every detected summon
--- would pollute the protagonist config (and thus the save) with empty
--- identities. Malformed stored shapes read as nil here (no repair — the
--- write accessor and _ValidateSummons own repairs).
-- @param identity   summon identity key (non-empty string)
-- @param presetIdx  preset index 1..BfBot.MAX_PRESETS
-- @return preset table { qc, spells } or nil
function BfBot.Persist.PeekSummonPreset(identity, presetIdx)
    if not BfBot.Persist._CheckSummonArgs("PeekSummonPreset", identity, presetIdx) then
        return nil
    end
    local config = BfBot.Persist._GetProtagonistConfig()
    if not config then
        BfBot._Warn("[Persist] PeekSummonPreset: no protagonist config")
        return nil
    end
    if type(config.summons) ~= "table" then return nil end
    local entry = config.summons[identity]
    if type(entry) ~= "table" or type(entry.presets) ~= "table" then return nil end
    local preset = entry.presets[presetIdx]
    if type(preset) ~= "table" then return nil end
    return preset
end

--- Get (lazily creating) a summon preset on the protagonist's config.
--- Seeding happens on CREATE only; later reads return the stored table
--- untouched (shape-repaired, never re-seeded). Everything stored is
--- numbers/strings/tables only (marshal constraint).
-- @param identity   summon identity key (non-empty string)
-- @param presetIdx  preset index 1..BfBot.MAX_PRESETS
-- @param seedCtx    optional { ownerSprite=..., cloneSprite=... }: on create,
--                   seed from the owner's same-index preset filtered to the
--                   clone's castable set. Owner preset missing → seeds empty.
-- @return preset table { qc, spells }, or nil (+ warn) on invalid args /
--         no protagonist
function BfBot.Persist.GetSummonPreset(identity, presetIdx, seedCtx)
    if not BfBot.Persist._CheckSummonArgs("GetSummonPreset", identity, presetIdx) then
        return nil
    end
    local config = BfBot.Persist._GetProtagonistConfig()
    if not config then
        BfBot._Warn("[Persist] GetSummonPreset: no protagonist config")
        return nil
    end
    -- Shape repair on read — _ValidateSummons scrubs the subtree at
    -- import/SetConfig time; this path covers mid-session mutations. Repairs
    -- of EXISTING (non-nil) data warn: external corruption must be
    -- diagnosable, never silently discarded.
    if type(config.summons) ~= "table" then config.summons = {} end
    local entry = config.summons[identity]
    if type(entry) ~= "table" or type(entry.presets) ~= "table" then
        if entry ~= nil then
            BfBot._Warn("[Persist] GetSummonPreset: malformed entry for '"
                .. identity .. "' (" .. type(entry) .. ") replaced")
        end
        entry = { presets = {} }
        config.summons[identity] = entry
    end
    local preset = entry.presets[presetIdx]
    if type(preset) ~= "table" then
        if preset ~= nil then
            BfBot._Warn("[Persist] GetSummonPreset: corrupt preset " .. presetIdx
                .. " for '" .. identity .. "' (" .. type(preset) .. ") recreated")
        end
        -- CREATE path — the only place seeding ever happens
        preset = { qc = 0, spells = {} }
        if seedCtx ~= nil then
            if type(seedCtx) == "table" and seedCtx.ownerSprite
                and seedCtx.cloneSprite then
                local ownerPreset = BfBot.Persist.GetPreset(
                    seedCtx.ownerSprite, presetIdx)
                local scanOk, castable = pcall(
                    BfBot.Scan.GetCastableSpells, seedCtx.cloneSprite)
                if not scanOk then
                    BfBot._Warn("[Persist] GetSummonPreset: clone scan failed,"
                        .. " seeding empty (" .. tostring(castable) .. ")")
                    castable = nil
                end
                preset.spells = BfBot.Persist._SeedCloneSpells(ownerPreset, castable)
            else
                BfBot._Warn("[Persist] GetSummonPreset: malformed seedCtx"
                    .. " ignored (need ownerSprite + cloneSprite)")
            end
        end
        entry.presets[presetIdx] = preset
    else
        -- READ path — repair shape (warn: see above), never re-seed
        if type(preset.spells) ~= "table" then
            if preset.spells ~= nil then
                BfBot._Warn("[Persist] GetSummonPreset: spells for '" .. identity
                    .. "' preset " .. presetIdx .. " was " .. type(preset.spells)
                    .. " — reset to empty")
            end
            preset.spells = {}
        end
        -- qc: same 0..2 contract as _ValidateSummons — out-of-range values
        -- from hand-imported files must never reach consumers
        if type(preset.qc) ~= "number" or preset.qc < 0 or preset.qc > 2 then
            if preset.qc ~= nil then
                BfBot._Warn("[Persist] GetSummonPreset: qc for '" .. identity
                    .. "' preset " .. presetIdx .. " was "
                    .. tostring(preset.qc) .. " — reset to 0")
            end
            preset.qc = 0
        end
    end
    return preset
end

-- ---- Options ----

--- Get a per-character option value.
function BfBot.Persist.GetOpt(sprite, key)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config or not config.opts then return 0 end
    return config.opts[key] or 0
end

--- Set a per-character option value.
function BfBot.Persist.SetOpt(sprite, key, value)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config or not config.opts then return end
    if type(value) == "boolean" then value = value and 1 or 0 end
    config.opts[key] = value
end

-- ---- Quick Cast (per-preset) ----

function BfBot.Persist.GetQuickCast(sprite, presetIndex)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset then return 0 end
    return preset.qc or 0
end

function BfBot.Persist.SetQuickCast(sprite, presetIndex, value)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset then return end
    preset.qc = math.max(0, math.min(2, value or 0))
end

function BfBot.Persist.SetQuickCastAll(presetIndex, value)
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            BfBot.Persist.SetQuickCast(sprite, presetIndex, value)
        end
    end
end

-- ---- Override accessors ----

--- Get all classification overrides for a character.
function BfBot.Persist.GetOverrides(sprite)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return {} end
    return config.ovr or {}
end

--- Set a classification override (1=include, -1=exclude, nil=clear).
function BfBot.Persist.SetOverride(sprite, resref, value)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return end
    if not config.ovr then config.ovr = {} end
    config.ovr[resref] = value
    -- Sync to classifier in-memory table
    if value == 1 then
        BfBot.Class.SetOverride(resref, true)
    elseif value == -1 then
        BfBot.Class.SetOverride(resref, false)
    else
        BfBot.Class.SetOverride(resref, nil)
    end
end

-- ---- Config export/import ----

BfBot.Persist._PRESETS_DIR = "override/bfbot_presets"

-- Lua keywords can never be emitted as bare table keys (`end = {...}` is a
-- syntax error on re-import). Reachable via summon identities: a summon with
-- script name "END" derives identity "end". Includes goto (LuaJIT 5.1+ext).
BfBot.Persist._LUA_KEYWORDS = {
    ["and"] = 1, ["break"] = 1, ["do"] = 1, ["else"] = 1, ["elseif"] = 1,
    ["end"] = 1, ["false"] = 1, ["for"] = 1, ["function"] = 1, ["goto"] = 1,
    ["if"] = 1, ["in"] = 1, ["local"] = 1, ["nil"] = 1, ["not"] = 1,
    ["or"] = 1, ["repeat"] = 1, ["return"] = 1, ["then"] = 1, ["true"] = 1,
    ["until"] = 1, ["while"] = 1,
}

--- Recursively serialize a Lua value to a string representation.
-- Supports number, string, table, nil. Sorts keys: integers first (ascending),
-- then strings (alphabetical). Short arrays (<=10 items, all simple) inline.
-- @param val     any value to serialize
-- @param indent  string: current indentation level (default "")
-- @return string: Lua source code representing the value
function BfBot.Persist._Serialize(val, indent)
    indent = (indent and type(indent) == "string") and indent or ""
    local vt = type(val)

    if vt == "number" then
        -- Use integer format for whole numbers, float otherwise
        if val == math.floor(val) and val >= -2147483648 and val <= 2147483647 then
            return string.format("%d", val)
        else
            return string.format("%.17g", val)
        end
    elseif vt == "string" then
        return string.format("%q", val)
    elseif vt == "nil" then
        return "nil"
    elseif vt == "boolean" then
        -- Shouldn't appear in config, but handle gracefully (convert to 1/0)
        return val and "1" or "0"
    elseif vt ~= "table" then
        return "nil" -- unsupported type
    end

    -- Table serialization
    -- Separate integer keys from string keys
    local intKeys = {}
    local strKeys = {}
    for k, _ in pairs(val) do
        if type(k) == "number" and k == math.floor(k) and k >= 1 then
            table.insert(intKeys, k)
        elseif type(k) == "string" then
            table.insert(strKeys, k)
        end
    end
    table.sort(intKeys)
    table.sort(strKeys)

    -- Check if this is a short simple array (for inline formatting)
    local isSimpleArray = #strKeys == 0 and #intKeys <= 10
    if isSimpleArray then
        -- Verify contiguous keys starting at 1 and all values are simple
        for i, k in ipairs(intKeys) do
            if k ~= i then isSimpleArray = false; break end
            local et = type(val[k])
            if et ~= "number" and et ~= "string" then
                isSimpleArray = false; break
            end
        end
    end

    if isSimpleArray and #intKeys > 0 then
        -- Inline format: {1, 2, "foo"}
        local parts = {}
        for _, k in ipairs(intKeys) do
            table.insert(parts, BfBot.Persist._Serialize(val[k]))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end

    -- Multi-line format
    local nextIndent = indent .. "    "
    local lines = {}
    table.insert(lines, "{")

    -- Integer keys first
    for _, k in ipairs(intKeys) do
        local serialized = BfBot.Persist._Serialize(val[k], nextIndent)
        table.insert(lines, nextIndent .. "[" .. k .. "] = " .. serialized .. ",")
    end

    -- String keys
    for _, k in ipairs(strKeys) do
        local serialized = BfBot.Persist._Serialize(val[k], nextIndent)
        -- Use simple key format for valid identifiers (keywords excluded —
        -- a bare `end = ...` would make the export unparseable), bracketed otherwise
        if k:match("^[%a_][%w_]*$") and not BfBot.Persist._LUA_KEYWORDS[k] then
            table.insert(lines, nextIndent .. k .. " = " .. serialized .. ",")
        else
            table.insert(lines, nextIndent .. "[" .. string.format("%q", k) .. "] = " .. serialized .. ",")
        end
    end

    table.insert(lines, indent .. "}")
    return table.concat(lines, "\n")
end

--- Ensure the presets directory exists.
function BfBot.Persist._EnsurePresetsDir()
    if not os then return end
    os.execute('mkdir "' .. BfBot.Persist._PRESETS_DIR .. '" 2>nul')
end

--- Export a character's full config to a Lua file in the presets directory.
-- @param sprite  character sprite
-- @return true, safeName on success; false, errorMsg on failure
function BfBot.Persist.ExportConfig(sprite)
    if BfBot._noIO then return false, "LuaJIT required for export" end
    if not sprite then return false, "no sprite" end

    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return false, "no config" end

    -- Get character name and sanitize for filename
    local rawName = BfBot._GetName(sprite)
    if not rawName or rawName == "?" then rawName = "Unknown" end
    local safeName = rawName:gsub("[^%w_]", "")
    if safeName == "" then safeName = "Unknown" end

    -- Prevent path traversal (extra safety — gsub already strips . and /)
    safeName = safeName:gsub("%.%.", ""):gsub("[/\\]", "")

    BfBot.Persist._EnsurePresetsDir()

    local filepath = BfBot.Persist._PRESETS_DIR .. "/" .. safeName .. ".lua"
    local f, err = io.open(filepath, "w")
    if not f then
        return false, "cannot open file: " .. tostring(err)
    end

    -- Write header comment
    f:write("-- BuffBot config export: " .. rawName .. "\n")
    f:write("-- Exported: " .. (os.date and os.date("%Y-%m-%d %H:%M:%S") or "?") .. "\n")
    f:write("-- Schema version: " .. tostring(config.v) .. "\n\n")

    -- Serialize config
    local serialized = BfBot.Persist._Serialize(config)
    f:write("BfBot._import = " .. serialized .. "\n")

    f:close()
    return true, safeName
end

--- List available export files in the presets directory.
-- @return array of {name=displayName, filename=fullFilename}
function BfBot.Persist.ListExports()
    if BfBot._noIO then return {} end
    local results = {}
    local pipe = io.popen('dir /b "override\\bfbot_presets\\*.lua" 2>nul')
    if not pipe then return results end

    for line in pipe:lines() do
        if line and line ~= "" then
            -- Strip .lua extension for display name
            local display = line:gsub("%.lua$", "")
            table.insert(results, { name = display, filename = line })
        end
    end
    pipe:close()
    return results
end

--- Import a config from a file and apply it to a character.
-- Filters out spells the character cannot cast. Syncs overrides to classifier.
-- @param sprite    character sprite
-- @param filename  filename (just the name, e.g. "Jaheira.lua")
-- @return true, presetCount, skippedCount on success; false, errorMsg on failure
function BfBot.Persist.ImportConfig(sprite, filename)
    if BfBot._noIO then return false, "LuaJIT required for import" end
    if not sprite then return false, "no sprite" end
    if not filename then return false, "no filename" end

    -- Sanitize filename to prevent path traversal
    if filename:find("%.%.") or filename:find("[/\\]") then
        return false, "invalid filename"
    end

    local filepath = BfBot.Persist._PRESETS_DIR .. "/" .. filename
    local f, err = io.open(filepath, "r")
    if not f then
        return false, "cannot open file: " .. tostring(err)
    end

    local content = f:read("*a")
    f:close()

    if not content or content == "" then
        return false, "empty file"
    end

    -- Execute the file content to populate BfBot._import
    BfBot._import = nil
    local chunk, loadErr = loadstring(content)
    if not chunk then
        BfBot._import = nil
        return false, "parse error: " .. tostring(loadErr)
    end

    local execOk, execErr = pcall(chunk)
    if not execOk then
        BfBot._import = nil
        return false, "exec error: " .. tostring(execErr)
    end

    local imported = BfBot._import
    BfBot._import = nil  -- cleanup global immediately

    if type(imported) ~= "table" then
        return false, "file did not set BfBot._import to a table"
    end

    -- Validate and migrate
    imported = BfBot.Persist._ValidateConfig(imported)
    if imported.v < BfBot.Persist._SCHEMA_VERSION then
        imported = BfBot.Persist._MigrateConfig(imported, imported.v)
    end

    -- Get character's castable spells to filter imported config
    local castable = nil
    local scanOk, spells = pcall(BfBot.Scan.GetCastableSpells, sprite)
    if scanOk and spells then
        castable = spells
    end

    -- Filter spells in each preset: remove spells this character can't cast
    local totalSkipped = 0
    local presetCount = 0
    for idx, preset in pairs(imported.presets) do
        if type(preset) == "table" and preset.spells then
            presetCount = presetCount + 1
            if castable then
                local toRemove = {}
                for resref, _ in pairs(preset.spells) do
                    if not castable[resref] then
                        table.insert(toRemove, resref)
                    end
                end
                for _, resref in ipairs(toRemove) do
                    preset.spells[resref] = nil
                    totalSkipped = totalSkipped + 1
                end
            end
        end
    end

    -- Store the imported config
    pcall(function()
        EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = imported
    end)

    -- Sync overrides to classifier
    if imported.ovr then
        for resref, val in pairs(imported.ovr) do
            if val == 1 then
                BfBot.Class.SetOverride(resref, true)
            elseif val == -1 then
                BfBot.Class.SetOverride(resref, false)
            end
        end
    end

    -- Invalidate scan cache so UI picks up changes
    pcall(BfBot.Scan.Invalidate, sprite)

    return true, presetCount, totalSkipped
end

-- ---- Queue building ----

--- Resolve a character name to a party slot (0-5).
-- Iterates party, compares _GetName(sprite) to name.
-- @param name string: character name to find
-- @return number|nil: slot (0-5) or nil if not in party
function BfBot.Persist._ResolveNameToSlot(name)
    if not name or name == "" then return nil end
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite and BfBot._GetName(sprite) == name then
            return slot
        end
    end
    return nil
end

--- Resolve a config target (tgt field) into one or more exec queue entries.
-- Accepts both legacy slot strings ("1"-"6") and name strings ("Branwen").
-- @param tgt string|table: "s", "p", slot string, name string, or table of slot/name strings
-- @param caster number|table: party slot 0-5 (legacy party path — entries get
--        `caster = slot`, byte-identical to the historical output) OR a
--        pre-built caster-ref table (summon path, issue #19 — entries get
--        `casterRef = ref`, the Task-4 exec seam; `tgt = "s"` then means the
--        summon itself)
-- @param resref string: spell resref
-- @param pri number: priority value
-- @return table: array of {caster|casterRef, spell, target, pri} entries
function BfBot.Persist._ResolveConfigTarget(tgt, caster, resref, pri)
    local results = {}
    -- Entry factory: the only line that differs between the party and summon
    -- paths. The same ref TABLE is shared across a spell's entries — exec
    -- treats casterRef as read-only, so aliasing is safe.
    local function mkEntry(target, priVal)
        local e = { spell = resref, target = target, pri = priVal }
        if type(caster) == "table" then
            e.casterRef = caster
        else
            e.caster = caster
        end
        return e
    end
    if type(tgt) == "table" then
        -- Ordered target list: one queue entry per target.
        -- Fractional sub-priority preserves target order within the spell
        -- after BuildQueueFromPreset sorts by pri (Lua sort is unstable).
        local subPri = 0
        for _, entry in ipairs(tgt) do
            subPri = subPri + 1
            local num = tonumber(entry)
            if num and num >= 1 and num <= 6 then
                -- Legacy slot string
                table.insert(results, mkEntry(num, pri + subPri / 1000))
            else
                -- Name-based: resolve to slot
                local resolved = BfBot.Persist._ResolveNameToSlot(entry)
                if resolved then
                    -- slot 0-5 → Player 1-6
                    table.insert(results, mkEntry(resolved + 1, pri + subPri / 1000))
                end
                -- Unresolved names silently skipped
            end
        end
    else
        local target
        if tgt == "s" then
            target = "self"
        elseif tgt == "p" then
            target = "all"
        else
            local num = tonumber(tgt)
            if num and num >= 1 and num <= 6 then
                -- Legacy slot string
                target = num
            else
                -- Name-based: resolve to slot
                local resolved = BfBot.Persist._ResolveNameToSlot(tgt)
                if resolved then
                    target = resolved + 1
                else
                    target = "all"  -- fallback for unresolved
                end
            end
        end
        table.insert(results, mkEntry(target, pri))
    end
    return results
end

-- ---- Summon queue building (issue #19) ----

--- Multiplayer gate for the summon sweep — Task 13 seam. Single-player →
--- always true. An ESTABLISHED multiplayer session → false: BuffBot's cast
--- chains are queued on the LOCAL action list only (see BfBotMp.lua), so
--- queuing onto a summon another machine may own would hang its chain. The
--- conservative ownership rule (clone follows its owner's control, ownerless
--- summons host-only) lands with Task 13 as
--- BfBot.Mp.IsSummonLocallyControlled; this predicate defers to it once it
--- exists.
-- @param summonEntry detection entry (unused until Task 13)
-- @return boolean
function BfBot.Persist._SummonPassesMpRule(summonEntry)
    if BfBot.Mp and BfBot.Mp.IsSummonLocallyControlled then
        return BfBot.Mp.IsSummonLocallyControlled(summonEntry) and true or false
    end
    -- Pre-Task-13 fallback: single-player detection via the engine's
    -- connection flag, mirroring BfBot.Mp.IsLocallyControlled's short-circuit.
    -- Reflection failure → treat as single-player (never silently stop SP
    -- buffing; the exec watchdog backstops any resulting MP hang).
    local ok, established = pcall(function()
        local chitin = rawget(_G, "EEex_EngineGlobal_CBaldurChitin")
            or (rawget(_G, "EngineGlobals") and EngineGlobals.g_pBaldurChitin)
        if not chitin then return false end
        local conn = chitin.cNetwork.m_bConnectionEstablished
        return conn ~= nil and conn ~= false and conn ~= 0
    end)
    if ok and established then return false end
    return true
end

--- Collect live Project-Image clone descriptors for the puppet-lock policy.
--- Fresh by construction: drops the summon sweep cache, then re-classifies
--- each candidate off a fresh oid+name resolve (detection entries reflect
--- allegiance/liveness at sweep time only). Only PI-type clones
--- (stat 139 == 2) produce descriptors — Simulacrum (3) locks nothing.
--- Owner linkage is read directly off the LIVE clone sprite: m_nCopyParent
--- is the owner's object id (probe-verified); the detection entry only
--- carries ownerName.
--- LIMITATION: detection rides on GetAlliedSummons, so a spell-less clone
--- would be missed — acceptable: Project Image exists only on casters, and
--- clones copy the full spellbook.
-- @return array of { cloneType = 2, ownerOid = number|nil, ownerName = string|nil }
function BfBot.Persist._CollectLiveCloneDescriptors()
    local out = {}
    if not (BfBot.Scan and BfBot.Scan.GetAlliedSummons
        and BfBot.Exec and BfBot.Exec._ResolveCaster) then
        return out
    end
    pcall(BfBot.Scan.InvalidateSummons)  -- build-time freshness (≤2s TTL cache)
    local okList, list = pcall(BfBot.Scan.GetAlliedSummons)
    if not okList or type(list) ~= "table" then return out end
    for _, e in ipairs(list) do
        local sprite = BfBot.Exec._ResolveCaster({
            kind = "summon", oid = e.oid, name = e.name })
        if sprite then
            local okC, fresh = pcall(BfBot.Scan.ClassifySummonSprite, sprite)
            if okC and type(fresh) == "table" and fresh.kind == "clone"
                and fresh.cloneType == 2 then
                local ownerOid = nil
                local okP, cp = pcall(function() return sprite.m_nCopyParent end)
                if okP and type(cp) == "number" and cp ~= -1 then
                    ownerOid = cp
                end
                out[#out + 1] = { cloneType = fresh.cloneType,
                    ownerOid = ownerOid, ownerName = fresh.ownerName }
            end
        end
    end
    return out
end

--- PURE decision core for the Project-Image owner-lock policy (issue #19).
--- Probe-verified engine fact: while a PI clone lives, actions queued on its
--- OWNER are engine-delayed and fire as "zombie casts" when the image
--- expires. Rules, in order:
---   Rule 1: a live PI clone (cloneType 2) owned by this caster → ALL
---           entries skipped (the clone casts instead). Owner matched by
---           object id when the descriptor carries one; name compare is the
---           fallback only when it doesn't.
---   Rule 2: the caster's own chain casts Project Image with entries AFTER
---           it → trailing entries dropped; entries before it and the PI
---           cast itself stay. Detection is pragmatic: the scan entry's
---           display NAME matched against "project image" case-insensitively
---           (resref is NOT assumable under Spell Revisions relocation).
---           LIMITATION: the name match is English-only — on TLK-localized
---           installs (e.g. German "Projektion") rule 2 does not match, and
---           modded PI-alikes with different names aren't caught either. In
---           both cases the degradation is benign: the trailing entries fire
---           delayed at image expiry and the exec watchdog still completes
---           the run. Rule 1 is locale-independent (stat 139 + object id),
---           so the owner lock itself holds on every locale.
---   Rule 3: Simulacrum (cloneType 3) locks nothing — only cloneType 2
---           participates, no other handling.
--- No logging here (pure, synthetic-testable) — callers log the returned
--- skip records (see _LogBuildSkips).
-- @param caster     { oid = number|nil, name = string|nil } — the party caster
-- @param entries    ONE caster's priority-sorted entry list; each entry
--                   carries `spellName` (display name, rule-2 match)
-- @param liveClones array of { cloneType, ownerOid|nil, ownerName|nil }
-- @return kept (array, same entry tables), skips (array of { msg = string })
function BfBot.Persist._ApplyPuppetLockPolicy(caster, entries, liveClones)
    local kept, skips = {}, {}
    if type(entries) ~= "table" then return kept, skips end
    if type(caster) ~= "table" then caster = {} end
    if type(liveClones) ~= "table" then liveClones = {} end

    -- Rule 1: is this caster the owner of a live PI clone?
    for _, c in ipairs(liveClones) do
        if type(c) == "table" and c.cloneType == 2 then
            local owned
            if c.ownerOid ~= nil then
                -- Object id is authoritative when available
                owned = (caster.oid ~= nil and c.ownerOid == caster.oid)
            else
                owned = (c.ownerName ~= nil and c.ownerName == caster.name)
            end
            if owned then
                if #entries > 0 then
                    skips[#skips + 1] = { msg = tostring(caster.name)
                        .. " puppet-locked by Project Image — cast again"
                        .. " after the image expires" }
                end
                return kept, skips  -- kept stays empty
            end
        end
    end

    -- Rule 2: drop trailing entries after a Project Image cast in the chain.
    for i, e in ipairs(entries) do
        kept[#kept + 1] = e
        local nm = type(e.spellName) == "string" and e.spellName:lower() or ""
        if nm:find("project image", 1, true) then
            if #entries > i then
                skips[#skips + 1] = { msg = tostring(caster.name) .. ": "
                    .. (#entries - i) .. " entries after Project Image skipped"
                    .. " — owner locked while image is active" }
            end
            break
        end
    end
    return kept, skips
end

--- Log puppet-lock skip records from the queue builders. Uses the exec
--- SKIP-logging convention (BfBot.Exec._LogEntry). Builders run BEFORE
--- Exec.Start opens the run's log, so when no log handle is open this
--- briefly opens buffbot_exec.log in append mode (the _SweepOrphanCheat
--- pattern); when one IS open (test suite, mid-run), it writes there and
--- leaves the handle alone.
function BfBot.Persist._LogBuildSkips(skips)
    if type(skips) ~= "table" or #skips == 0 then return end
    if not (BfBot.Exec and BfBot.Exec._LogEntry) then return end
    local hadLog = BfBot._logHandle ~= nil
    if not hadLog then BfBot._OpenLogAppend(BfBot.Exec._logFile) end
    for _, s in ipairs(skips) do
        if type(s) == "table" and type(s.msg) == "string" then
            BfBot.Exec._LogEntry("SKIP", s.msg)
            -- Also queue for the panel: Exec.Start resets the in-memory log
            -- an instant after the builders write it, so the UI drains this
            -- and re-appends the lines into the fresh run's IN-MEMORY log
            -- only (Task 10) — the file line above is the single file write.
            table.insert(BfBot.Persist._pendingSkips, s.msg)
        end
    end
    if not hadLog then BfBot._CloseLog() end
end

-- Build-time SKIP messages awaiting panel surfacing (transient, never saved).
BfBot.Persist._pendingSkips = BfBot.Persist._pendingSkips or {}

--- Hand over (and clear) the build-time SKIP messages collected since the
--- last drain. UI cast handlers drain once BEFORE building (discard stale)
--- and once after a SUCCESSFUL Exec.Start (surface into the fresh run's
--- panel log); a refused Start and the F12 innate path drain-and-discard
--- (the lines were file-logged at build time).
-- @return array of message strings (possibly empty)
function BfBot.Persist.DrainBuildSkips()
    local msgs = BfBot.Persist._pendingSkips
    BfBot.Persist._pendingSkips = {}
    return msgs
end

--- Build an execution queue for a single allied summon/clone (issue #19).
--- READ path by contract: uses PeekSummonPreset — an unconfigured summon
--- must never create config (queue building would otherwise pollute the
--- protagonist's save with an empty identity per detected summon).
--- Mirrors the per-character builder's spells walk exactly: honors on
--- (enabled), pri (priority order), tgt (via _ResolveConfigTarget with a
--- summon caster ref: "s" → the summon itself, names/tables → party slots
--- as today) and var (variant).
--- Quick Cast: the summon preset carries its OWN qc (0..2); the cheat flag
--- is computed here per entry with the same duration-boundary rule
--- Exec._BuildQueue applies to qcMode, and attached as entry.cheat (1/0) so
--- the summon follows its own qc even inside a party run with a different
--- mode.
-- @param summonEntry detection-entry table {oid, name, identity}
--        (ClassifySummonSprite shape; a sprite field, if present, is
--        IGNORED — the builder always fresh-resolves from oid+name)
-- @param presetIdx  preset index 1..BfBot.MAX_PRESETS
-- @return queue array compatible with BfBot.Exec.Start(), or nil + reason
function BfBot.Persist.BuildQueueForSummon(summonEntry, presetIdx)
    if type(summonEntry) ~= "table" or type(summonEntry.oid) ~= "number"
        or type(summonEntry.name) ~= "string" then
        return nil, "invalid summon entry"
    end

    local preset = BfBot.Persist.PeekSummonPreset(summonEntry.identity, presetIdx)
    if not preset or type(preset.spells) ~= "table"
        or next(preset.spells) == nil then
        return nil, "no configured summon preset " .. tostring(presetIdx)
            .. " for '" .. tostring(summonEntry.identity) .. "'"
    end

    -- Build-time sprite: ALWAYS a fresh oid+name resolve — never the
    -- caller-supplied summonEntry.sprite, whose freshness this function
    -- cannot verify (issue-#38 class: pcall does NOT catch the access
    -- violation from dereferencing a freed CGameSprite, and stored
    -- detection entries WILL be handed in once the summon UI lands). The
    -- resolver also carries the anti-recycle name guard, so a recycled
    -- object id never builds a queue for the wrong sprite.
    if not (BfBot.Exec and BfBot.Exec._ResolveCaster) then
        return nil, "caster resolver unavailable"
    end
    local sprite = BfBot.Exec._ResolveCaster({ kind = "summon",
        oid = summonEntry.oid, name = summonEntry.name })
    if not sprite then
        BfBot._Warn("[Persist] BuildQueueForSummon: summon gone ("
            .. summonEntry.name .. ", oid " .. summonEntry.oid .. ")")
        return nil, "summon gone (" .. summonEntry.name .. ")"
    end

    -- Fresh scan (same invalidate-then-scan the party builders do)
    BfBot.Scan.Invalidate(sprite)
    local ok, castable, _ = pcall(BfBot.Scan.GetCastableSpells, sprite)
    if not ok or not castable then
        return nil, "scan failed for summon " .. summonEntry.name
    end

    local casterRef = { kind = "summon", oid = summonEntry.oid,
                        name = summonEntry.name }

    -- Collect enabled, castable spells with priority
    local entries = {}
    for resref, spellCfg in pairs(preset.spells) do
        if spellCfg.on == 1 then
            local scanData = castable[resref]
            if scanData and scanData.count > 0 then
                local resolved = BfBot.Persist._ResolveConfigTarget(
                    spellCfg.tgt, casterRef, resref, spellCfg.pri or 999)
                for _, e in ipairs(resolved) do
                    -- Display name rides along for the puppet-lock rule-2
                    -- name match; never copied onto the final queue entry.
                    e.spellName = scanData.name or resref
                    table.insert(entries, e)
                end
            end
        end
    end

    -- Sort by priority (ascending: lower = cast first)
    table.sort(entries, function(a, b) return a.pri < b.pri end)

    -- Puppet-lock rule 2 on the summon's OWN chain (issue #19): a clone
    -- preset seeded from a PI-enabled owner includes Project Image
    -- (_SeedCloneSpells mirrors the owner by design), and a clone casting
    -- PI engine-locks ITSELF — the trailing entries would sit as zombie
    -- casts and stall the run into the watchdog. Empty descriptor list:
    -- rule 1 is owner-only (a clone is not a party owner), so only the
    -- trailing-entry drop applies here.
    do
        local kept, skips = BfBot.Persist._ApplyPuppetLockPolicy(
            { oid = summonEntry.oid, name = summonEntry.name }, entries, {})
        BfBot.Persist._LogBuildSkips(skips)
        entries = kept
    end

    -- Append to queue (strip pri/spellName ride-alongs — exec rebuilds its
    -- own entries from the scan)
    local qc = (type(preset.qc) == "number") and preset.qc or 0
    local queue = {}
    for _, e in ipairs(entries) do
        local scanData = castable[e.spell]
        local spellCfg = preset.spells[e.spell]
        local durCat = scanData and scanData.durCat or "short"
        local isCheat = (qc == 2)
            or (qc == 1 and (durCat == "long" or durCat == "permanent"))
        table.insert(queue, {
            casterRef = e.casterRef,
            spell  = e.spell,
            target = e.target,
            durCat = durCat,
            var    = spellCfg and spellCfg.var or nil,
            cheat  = isCheat and 1 or 0,  -- explicit 0: own qc beats run qcMode
        })
    end

    if #queue == 0 then
        return nil, "no castable spells in summon preset " .. presetIdx
            .. " for '" .. tostring(summonEntry.identity) .. "'"
    end

    return queue
end

--- Build an execution queue from a preset across all party members, plus
--- (issue #19) any configured allied summons/clones in the leader's area.
-- Returns queue compatible with BfBot.Exec.Start(), or nil + error message.
function BfBot.Persist.BuildQueueFromPreset(presetIndex)
    if not presetIndex then return nil, "no preset index" end

    local queue = {}

    -- Live Project-Image clones engine-lock their owners (probe-verified:
    -- actions queued on a PI owner sit in the queue and fire as "zombie
    -- casts" when the image expires). Collect live-clone descriptors ONCE up
    -- front. This runs regardless of the SummonsJoinCast pref — the engine
    -- lock is a fact, not a feature.
    local liveClones = BfBot.Persist._CollectLiveCloneDescriptors()

    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if not sprite then goto nextSlot end

        -- Multiplayer: skip casters the local machine doesn't control — queuing
        -- casts on another player's character never runs locally and would hang.
        if BfBot.Mp and BfBot.Mp.IsLocallyControlled
            and not BfBot.Mp.IsLocallyControlled(sprite) then
            goto nextSlot
        end

        local config = BfBot.Persist.GetConfig(sprite)
        if not config then goto nextSlot end

        local preset = config.presets[presetIndex]
        if not preset or not preset.spells then goto nextSlot end

        -- Invalidate scan cache for fresh data
        BfBot.Scan.Invalidate(sprite)
        local ok, castable, _ = pcall(BfBot.Scan.GetCastableSpells, sprite)
        if not ok or not castable then goto nextSlot end

        -- Collect enabled, castable spells with priority
        local entries = {}
        for resref, spellCfg in pairs(preset.spells) do
            if spellCfg.on == 1 then
                local scanData = castable[resref]
                if scanData and scanData.count > 0 then
                    local resolved = BfBot.Persist._ResolveConfigTarget(
                        spellCfg.tgt, slot, resref, spellCfg.pri or 999)
                    for _, e in ipairs(resolved) do
                        -- Display name rides along for the puppet-lock rule-2
                        -- name match; never copied onto the final queue entry.
                        e.spellName = scanData.name or resref
                        table.insert(entries, e)
                    end
                end
            end
        end

        -- Sort by priority (ascending: lower = cast first)
        table.sort(entries, function(a, b) return a.pri < b.pri end)

        -- Puppet-lock policy (issue #19): a PI-locked owner's entries are
        -- skipped entirely; a chain that casts PI drops its trailing entries.
        do
            local casterOid = nil
            local okId, id = pcall(function() return sprite.m_id end)
            if okId and type(id) == "number" then casterOid = id end
            local kept, skips = BfBot.Persist._ApplyPuppetLockPolicy(
                { oid = casterOid, name = BfBot._GetName(sprite) },
                entries, liveClones)
            BfBot.Persist._LogBuildSkips(skips)
            entries = kept
        end

        -- Append to queue (strip pri field — exec engine doesn't use it)
        for _, e in ipairs(entries) do
            local scanData = castable[e.spell]
            local spellCfg = preset.spells[e.spell]
            table.insert(queue, {
                caster = e.caster,
                spell  = e.spell,
                target = e.target,
                durCat = scanData and scanData.durCat or "short",
                var    = spellCfg and spellCfg.var or nil,
            })
        end

        ::nextSlot::
    end

    -- ---- Allied-summon sweep (issue #19) ----
    -- Configured allied summons/clones join the party cast. Kill-switch: INI
    -- pref SummonsJoinCast (default 1). NOTE the puppet-lock policy above is
    -- NOT behind this pref — the engine lock exists whether or not summons
    -- join the cast.
    if BfBot.Persist.GetPref("SummonsJoinCast") == 1
        and BfBot.Scan and BfBot.Scan.GetAlliedSummons
        and BfBot.Exec and BfBot.Exec._ResolveCaster then
        local okList, list = pcall(BfBot.Scan.GetAlliedSummons)
        if not okList then
            BfBot._Warn("[Persist] summon sweep failed: " .. tostring(list))
            list = nil
        end
        for _, entry in ipairs(type(list) == "table" and list or {}) do
            -- (1) Multiplayer rule seam — single-player always true; the
            --     conservative ownership rule lands with Task 13.
            -- (2) Allegiance re-validation: detection entries reflect
            --     allegiance at sweep time only — re-classify off a fresh
            --     oid+name resolve so a stale/charmed/dead summon drops out
            --     at build time.
            local fresh = nil
            if BfBot.Persist._SummonPassesMpRule(entry) then
                local sprite = BfBot.Exec._ResolveCaster({
                    kind = "summon", oid = entry.oid, name = entry.name })
                if sprite then
                    local okC, fc = pcall(BfBot.Scan.ClassifySummonSprite, sprite)
                    if okC then
                        fresh = fc
                    else
                        BfBot._Warn("[Persist] summon re-classify failed ("
                            .. tostring(entry.name) .. "): " .. tostring(fc))
                    end
                end
            end
            -- (3) Only a configured preset with ≥1 enabled spell builds —
            --     PeekSummonPreset: the sweep must never create config.
            if fresh then
                local preset = BfBot.Persist.PeekSummonPreset(
                    fresh.identity, presetIndex)
                local anyOn = false
                if preset and type(preset.spells) == "table" then
                    for _, se in pairs(preset.spells) do
                        if type(se) == "table" and se.on == 1 then
                            anyOn = true
                            break
                        end
                    end
                end
                if anyOn then
                    local sq = BfBot.Persist.BuildQueueForSummon(fresh, presetIndex)
                    if sq then
                        for _, e in ipairs(sq) do
                            table.insert(queue, e)
                        end
                    end
                end
            end
        end
    end

    if #queue == 0 then
        return nil, "no castable spells in preset " .. presetIndex
    end

    return queue
end

-- ---- INI preferences (global, cross-save) ----

--- Get a global preference from baldur.ini.
-- String defaults dispatch to Infinity_GetINIString; numbers use Infinity_GetINIValue.
function BfBot.Persist.GetPref(key)
    local default = BfBot.Persist._INI_DEFAULTS[key] or 0
    if type(default) == "string" then
        if Infinity_GetINIString then
            local ok, val = pcall(Infinity_GetINIString, "BuffBot", key, default)
            if ok then return val end
        end
        return default
    end
    local ok, val = pcall(Infinity_GetINIValue, "BuffBot", key, default)
    if ok then return val end
    return default
end

--- Set a global preference in baldur.ini.
-- String values dispatch to Infinity_SetINIString if available; numbers use Infinity_SetINIValue.
function BfBot.Persist.SetPref(key, value)
    if type(value) == "string" then
        if Infinity_SetINIString then
            pcall(Infinity_SetINIString, "BuffBot", key, value)
        else
            -- Fallback: some EEex builds may only expose SetINIValue
            pcall(Infinity_SetINIValue, "BuffBot", key, value)
        end
    else
        pcall(Infinity_SetINIValue, "BuffBot", key, value)
    end
end

-- ---- Preset management ----

--- Rename a preset.
function BfBot.Persist.RenamePreset(sprite, presetIndex, newName)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset then return end
    preset.name = tostring(newName)
end

--- Create a new preset (up to 5). Populates with all buff spells from existing
--- presets (union), all disabled. Returns the new preset index, or nil if full.
function BfBot.Persist.CreatePreset(sprite, name)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return nil end

    -- Find next available slot (max 5)
    local idx = nil
    for i = 1, BfBot.MAX_PRESETS do
        if not config.presets[i] then
            idx = i
            break
        end
    end
    if not idx then return nil end  -- all 5 taken

    -- Collect union of all spells across existing presets
    local allSpells = {}
    for _, preset in pairs(config.presets) do
        if preset.spells then
            for resref, cfg in pairs(preset.spells) do
                if not allSpells[resref] then
                    -- Re-classify target from SPL data (don't copy potentially stale tgt)
                    local tgt = cfg.tgt or "p"
                    local ok, header = pcall(EEex_Resource_Demand, resref, "SPL")
                    if ok and header then
                        local aOk, ability = pcall(function() return header:getAbility(0) end)
                        if aOk and ability then
                            local cOk, classResult = pcall(BfBot.Class.Classify, resref, header, ability)
                            if cOk and classResult then
                                tgt = classResult.defaultTarget or "s"
                            end
                        end
                    end
                    allSpells[resref] = { tgt = tgt, pri = cfg.pri or 999 }
                end
            end
        end
    end

    -- Build spell table for new preset — all disabled
    local spells = {}
    for resref, info in pairs(allSpells) do
        spells[resref] = { on = 0, tgt = info.tgt, pri = info.pri }
    end

    config.presets[idx] = {
        name = name or ("Preset " .. idx),
        cat = "custom",
        qc = 0,
        spells = spells,
    }

    return idx
end

--- Delete a preset by index. Refuses to delete the last remaining preset.
--- Returns 1 on success, nil on failure.
function BfBot.Persist.DeletePreset(sprite, presetIndex)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return nil end

    -- Count existing presets
    local count = 0
    for i = 1, BfBot.MAX_PRESETS do
        if config.presets[i] then count = count + 1 end
    end
    if count <= 1 then return nil end  -- can't delete last preset

    if not config.presets[presetIndex] then return nil end
    config.presets[presetIndex] = nil

    -- Always validate config.ap points to an existing preset
    if not config.presets[config.ap] then
        for i = 1, BfBot.MAX_PRESETS do
            if config.presets[i] then
                config.ap = i
                break
            end
        end
    end

    return 1  -- integer, not boolean
end

-- ============================================================
-- Party-wide preset operations
-- ============================================================

--- Create a new preset for ALL party members at the same index.
--- Finds the first slot free across all characters. Returns index or nil.
function BfBot.Persist.CreatePresetAll(name)
    -- Find first index free across all party members
    local idx = nil
    for i = 1, BfBot.MAX_PRESETS do
        local allFree = true
        for slot = 0, 5 do
            local sprite = EEex_Sprite_GetInPortrait(slot)
            if sprite then
                local config = BfBot.Persist.GetConfig(sprite)
                if config and config.presets[i] then
                    allFree = false
                    break
                end
            end
        end
        if allFree then idx = i; break end
    end
    if not idx then return nil end

    -- Create at that index for each party member
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local config = BfBot.Persist.GetConfig(sprite)
            if config then
                -- Collect union of all spells across existing presets
                local allSpells = {}
                for _, preset in pairs(config.presets) do
                    if preset.spells then
                        for resref, cfg in pairs(preset.spells) do
                            if not allSpells[resref] then
                                allSpells[resref] = { tgt = cfg.tgt or "p", pri = cfg.pri or 999 }
                            end
                        end
                    end
                end
                local spells = {}
                for resref, info in pairs(allSpells) do
                    spells[resref] = { on = 0, tgt = info.tgt, pri = info.pri }
                end
                config.presets[idx] = {
                    name = name or ("Preset " .. idx),
                    cat = "custom",
                    qc = 0,
                    spells = spells,
                }
            end
        end
    end
    return idx
end

--- Delete a preset for ALL party members. Returns 1 if any were deleted.
function BfBot.Persist.DeletePresetAll(presetIndex)
    local anyDeleted = nil
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            local result = BfBot.Persist.DeletePreset(sprite, presetIndex)
            if result then anyDeleted = 1 end
        end
    end
    return anyDeleted
end

--- Rename a preset for ALL party members.
function BfBot.Persist.RenamePresetAll(presetIndex, newName)
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            BfBot.Persist.RenamePreset(sprite, presetIndex, newName)
        end
    end
end

--- Build an execution queue for a single character's preset.
-- Returns queue compatible with BfBot.Exec.Start(), or nil + error.
function BfBot.Persist.BuildQueueForCharacter(slot, presetIndex)
    if not slot or not presetIndex then return nil, "missing slot or preset" end

    local sprite = EEex_Sprite_GetInPortrait(slot)
    if not sprite then return nil, "no sprite in slot " .. slot end

    -- Multiplayer: refuse to build a queue for a caster this machine doesn't
    -- control (the cast would never run locally and would hang the engine).
    if BfBot.Mp and BfBot.Mp.IsLocallyControlled
        and not BfBot.Mp.IsLocallyControlled(sprite) then
        return nil, "not locally controlled"
    end

    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return nil, "no config for slot " .. slot end

    local preset = config.presets[presetIndex]
    if not preset or not preset.spells then
        return nil, "no preset " .. presetIndex .. " for slot " .. slot
    end

    -- Invalidate scan cache for fresh data
    BfBot.Scan.Invalidate(sprite)
    local ok, castable, _ = pcall(BfBot.Scan.GetCastableSpells, sprite)
    if not ok or not castable then return nil, "scan failed for slot " .. slot end

    -- Collect enabled, castable spells with priority
    local entries = {}
    for resref, spellCfg in pairs(preset.spells) do
        if spellCfg.on == 1 then
            local scanData = castable[resref]
            if scanData and scanData.count > 0 then
                local resolved = BfBot.Persist._ResolveConfigTarget(
                    spellCfg.tgt, slot, resref, spellCfg.pri or 999)
                for _, e in ipairs(resolved) do
                    -- Display name rides along for the puppet-lock rule-2
                    -- name match; never copied onto the final queue entry.
                    e.spellName = scanData.name or resref
                    table.insert(entries, e)
                end
            end
        end
    end

    -- Sort by priority (ascending: lower = cast first)
    table.sort(entries, function(a, b) return a.pri < b.pri end)

    -- Puppet-lock policy (issue #19), same rules as BuildQueueFromPreset: a
    -- PI-locked owner's entries are skipped entirely (the probe-verified
    -- zombie-cast hazard applies to the Cast-Character button and the F12
    -- innate path just the same — both build here); a chain that casts PI
    -- drops its trailing entries. Deliberate scope extension of the plan's
    -- puppet-lock policy to the per-character builder (Task 7 review).
    -- Guarded on #entries: an empty build can't be locked, so don't pay for
    -- the area sweep (the policy on empty input is a no-op either way).
    local puppetLocked = nil
    if #entries > 0 then
        local liveClones = BfBot.Persist._CollectLiveCloneDescriptors()
        local casterOid = nil
        local okId, id = pcall(function() return sprite.m_id end)
        if okId and type(id) == "number" then casterOid = id end
        local kept, skips = BfBot.Persist._ApplyPuppetLockPolicy(
            { oid = casterOid, name = BfBot._GetName(sprite) },
            entries, liveClones)
        BfBot.Persist._LogBuildSkips(skips)
        -- Rule 1 is the only path that empties a non-empty build: surface it
        -- as a distinct reason so the panel doesn't blame "no spells" (T10).
        if #kept == 0 then puppetLocked = 1 end
        entries = kept
    end

    -- Strip pri/spellName ride-alongs — exec engine doesn't use them
    local queue = {}
    for _, e in ipairs(entries) do
        local scanData = castable[e.spell]
        local spellCfg = preset.spells[e.spell]
        table.insert(queue, {
            caster = e.caster,
            spell  = e.spell,
            target = e.target,
            durCat = scanData and scanData.durCat or "short",
            var    = spellCfg and spellCfg.var or nil,
        })
    end

    if #queue == 0 then
        if puppetLocked == 1 then
            return nil, "puppet-locked"
        end
        return nil, "no castable spells in preset " .. presetIndex .. " for slot " .. slot
    end

    return queue
end
