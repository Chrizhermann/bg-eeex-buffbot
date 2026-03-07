-- ============================================================
-- BfBotPer.lua — Configuration Persistence (BfBot.Persist)
-- Save/load per-character config via EEex marshal handlers,
-- global preferences via INI
-- ============================================================

BfBot.Persist = {}

-- Constants
BfBot.Persist._SCHEMA_VERSION = 5
BfBot.Persist._KEY = "BB"        -- UDAux storage key
BfBot.Persist._HANDLER = "BuffBot" -- marshal handler name

-- INI preference defaults (cross-save, stored in baldur.ini)
BfBot.Persist._INI_DEFAULTS = {
    LongThreshold = 300,  -- seconds (5 turns) — divides "long" from "short"
    DefaultPreset = 1,    -- which preset tab opens by default
    HotkeyCode    = 87,   -- F11
    ShowTooltips  = 1,    -- show spell tooltips in panel
    ConfirmCast   = 0,    -- show confirmation before casting
}

-- ---- Boolean sanitization ----

--- Recursively convert any boolean values to 1/0 in a table.
-- EEex marshal only supports number/string/table — booleans crash saves.
function BfBot.Persist._SanitizeValues(tbl)
    if type(tbl) ~= "table" then return end
    for k, v in pairs(tbl) do
        local vt = type(v)
        if vt == "boolean" then
            tbl[k] = v and 1 or 0
        elseif vt == "table" then
            BfBot.Persist._SanitizeValues(v)
        end
    end
end

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
    return { on = (enabled == 0) and 0 or 1, tgt = tgt, pri = 999 }
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

    -- Store in UDAux
    pcall(function()
        EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = config
    end)

    -- Grant innate abilities for the new config's presets
    if BfBot.Innate and BfBot.Innate.Grant then
        local slot = nil
        for s = 0, 5 do
            if EEex_Sprite_GetInPortrait(s) == sprite then slot = s; break end
        end
        if slot then
            for idx = 1, BfBot.MAX_PRESETS do
                if config.presets[idx] then
                    local resref = string.format("BFBT%d%d", slot, idx)
                    EEex_Action_QueueResponseStringOnAIBase(
                        'AddSpecialAbility("' .. resref .. '")', sprite)
                end
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
                        if type(entry.tgt) ~= "string" then entry.tgt = "p" end
                        if type(entry.pri) ~= "number" then entry.pri = 999 end
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

    -- Safety: convert any stray booleans
    BfBot.Persist._SanitizeValues(config)

    return config
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
    if config and config.v and config.v < 3 then
        BfBot.Persist._MigrateV1Targets(sprite, config)
        config.v = 3
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

--- Set the priority for a spell in a preset.
function BfBot.Persist.SetSpellPriority(sprite, presetIndex, resref, priority)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells[resref] then return end
    preset.spells[resref].pri = priority
end

--- Get the config entry for a spell in a preset.
function BfBot.Persist.GetSpellConfig(sprite, presetIndex, resref)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells then return nil end
    return preset.spells[resref]
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
        -- Use simple key format for valid identifiers, bracketed otherwise
        if k:match("^[%a_][%w_]*$") then
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
    os.execute('mkdir "' .. BfBot.Persist._PRESETS_DIR .. '" 2>nul')
end

--- Export a character's full config to a Lua file in the presets directory.
-- @param sprite  character sprite
-- @return true, safeName on success; false, errorMsg on failure
function BfBot.Persist.ExportConfig(sprite)
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
    f:write("-- Exported: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
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

    -- Sanitize any stray booleans
    BfBot.Persist._SanitizeValues(imported)

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

--- Resolve a config target (tgt field) into one or more exec queue entries.
-- @param tgt string|table: "s", "p", "1"-"6", or table of slot strings
-- @param slot number: caster party slot (0-5)
-- @param resref string: spell resref
-- @param pri number: priority value
-- @return table: array of {caster, spell, target, pri} entries
function BfBot.Persist._ResolveConfigTarget(tgt, slot, resref, pri)
    local results = {}
    if type(tgt) == "table" then
        -- Multi-target: one queue entry per target in the list
        for _, slotStr in ipairs(tgt) do
            local num = tonumber(slotStr)
            if num and num >= 1 and num <= 6 then
                table.insert(results, {
                    caster = slot,
                    spell  = resref,
                    target = num,
                    pri    = pri,
                })
            end
        end
    else
        -- Single target: map config format to exec engine format
        local target
        if tgt == "s" then
            target = "self"
        elseif tgt == "p" then
            target = "all"
        else
            local num = tonumber(tgt)
            if num and num >= 1 and num <= 6 then
                target = num
            else
                target = "all"  -- fallback for unknown
            end
        end
        table.insert(results, {
            caster = slot,
            spell  = resref,
            target = target,
            pri    = pri,
        })
    end
    return results
end

--- Build an execution queue from a preset across all party members.
-- Returns queue compatible with BfBot.Exec.Start(), or nil + error message.
function BfBot.Persist.BuildQueueFromPreset(presetIndex)
    if not presetIndex then return nil, "no preset index" end

    local queue = {}

    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if not sprite then goto nextSlot end

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
                if scanData and scanData.count > 0 and not scanData.disabled then
                    local resolved = BfBot.Persist._ResolveConfigTarget(
                        spellCfg.tgt, slot, resref, spellCfg.pri or 999)
                    for _, e in ipairs(resolved) do
                        table.insert(entries, e)
                    end
                end
            end
        end

        -- Sort by priority (ascending: lower = cast first)
        table.sort(entries, function(a, b) return a.pri < b.pri end)

        -- Append to queue (strip pri field — exec engine doesn't use it)
        for _, e in ipairs(entries) do
            local scanData = castable[e.spell]
            table.insert(queue, {
                caster = e.caster,
                spell  = e.spell,
                target = e.target,
                durCat = scanData and scanData.durCat or "short",
            })
        end

        ::nextSlot::
    end

    if #queue == 0 then
        return nil, "no castable spells in preset " .. presetIndex
    end

    return queue
end

-- ---- INI preferences (global, cross-save) ----

--- Get a global preference from baldur.ini.
function BfBot.Persist.GetPref(key)
    local default = BfBot.Persist._INI_DEFAULTS[key] or 0
    local ok, val = pcall(Infinity_GetINIValue, "BuffBot", key, default)
    if ok then return val end
    return default
end

--- Set a global preference in baldur.ini.
function BfBot.Persist.SetPref(key, value)
    pcall(Infinity_SetINIValue, "BuffBot", key, value)
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
            if scanData and scanData.count > 0 and not scanData.disabled then
                local resolved = BfBot.Persist._ResolveConfigTarget(
                    spellCfg.tgt, slot, resref, spellCfg.pri or 999)
                for _, e in ipairs(resolved) do
                    table.insert(entries, e)
                end
            end
        end
    end

    -- Sort by priority (ascending: lower = cast first)
    table.sort(entries, function(a, b) return a.pri < b.pri end)

    -- Strip pri field — exec engine doesn't use it
    local queue = {}
    for _, e in ipairs(entries) do
        local scanData = castable[e.spell]
        table.insert(queue, {
            caster = e.caster,
            spell  = e.spell,
            target = e.target,
            durCat = scanData and scanData.durCat or "short",
        })
    end

    if #queue == 0 then
        return nil, "no castable spells in preset " .. presetIndex .. " for slot " .. slot
    end

    return queue
end
