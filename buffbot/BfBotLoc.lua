-- BfBotLoc.lua — file-backed runtime localization with checked-in English fallback

BfBot = BfBot or {}

local _registry = {
    ["innate.preset_1"] = { id = 200, fallback = [=[BuffBot 1]=] },
    ["innate.preset_2"] = { id = 201, fallback = [=[BuffBot 2]=] },
    ["innate.preset_3"] = { id = 202, fallback = [=[BuffBot 3]=] },
    ["innate.preset_4"] = { id = 203, fallback = [=[BuffBot 4]=] },
    ["innate.preset_5"] = { id = 204, fallback = [=[BuffBot 5]=] },
    ["innate.preset_6"] = { id = 205, fallback = [=[BuffBot 6]=] },
    ["innate.preset_7"] = { id = 206, fallback = [=[BuffBot 7]=] },
    ["innate.preset_8"] = { id = 207, fallback = [=[BuffBot 8]=] },
    ["common.buffbot"] = { id = 300, fallback = [=[BuffBot]=] },
    ["common.party"] = { id = 301, fallback = [=[Party]=] },
    ["common.summons"] = { id = 302, fallback = [=[Summons]=] },
    ["common.self"] = { id = 303, fallback = [=[Self]=] },
    ["common.none"] = { id = 304, fallback = [=[None]=] },
    ["common.reset"] = { id = 305, fallback = [=[Reset]=] },
    ["common.rename"] = { id = 306, fallback = [=[Rename]=] },
    ["common.new"] = { id = 307, fallback = [=[New]=] },
    ["common.add_spell"] = { id = 308, fallback = [=[Add Spell/Item]=] },
    ["common.remove"] = { id = 309, fallback = [=[Remove]=] },
    ["common.export"] = { id = 310, fallback = [=[Export]=] },
    ["common.import"] = { id = 311, fallback = [=[Import]=] },
    ["common.up"] = { id = 312, fallback = [=[Up]=] },
    ["common.down"] = { id = 313, fallback = [=[Down]=] },
    ["common.sort"] = { id = 314, fallback = [=[Sort]=] },
    ["common.delete_preset"] = { id = 315, fallback = [=[Delete Preset]=] },
    ["common.delete_preset_compact"] = { id = 316, fallback = [=[Del Preset]=] },
    ["common.stop"] = { id = 317, fallback = [=[Stop]=] },
    ["common.close"] = { id = 318, fallback = [=[Close]=] },
    ["common.all_party"] = { id = 319, fallback = [=[All Party]=] },
    ["common.clear"] = { id = 320, fallback = [=[Clear]=] },
    ["common.done"] = { id = 321, fallback = [=[Done]=] },
    ["common.unlock_targeting"] = { id = 322, fallback = [=[Unlock Targeting]=] },
    ["common.ok"] = { id = 323, fallback = [=[OK]=] },
    ["common.cancel"] = { id = 324, fallback = [=[Cancel]=] },
    ["common.delete"] = { id = 325, fallback = [=[Delete]=] },
    ["common.select"] = { id = 326, fallback = [=[Select]=] },
    ["common.enable"] = { id = 327, fallback = [=[Enable]=] },
    ["common.disable"] = { id = 328, fallback = [=[Disable]=] },
    ["common.target"] = { id = 329, fallback = [=[Target]=] },
    ["common.variant"] = { id = 330, fallback = [=[Variant]=] },
    ["common.spells"] = { id = 331, fallback = [=[Spells]=] },
    ["common.items"] = { id = 332, fallback = [=[Items]=] },
    ["ui.tooltip.configuration"] = { id = 400, fallback = [=[BuffBot Configuration]=] },
    ["ui.no_allied_summons"] = { id = 401, fallback = [=[No allied summons detected]=] },
    ["ui.title.preset"] = { id = 402, fallback = [=[BuffBot - {preset}]=] },
    ["ui.title.summons"] = { id = 403, fallback = [=[BuffBot - Summons]=] },
    ["ui.title.summon_preset"] = { id = 404, fallback = [=[BuffBot - {summon} - {preset}]=] },
    ["ui.clone.mislead"] = { id = 405, fallback = [=[{owner}'s Mislead]=] },
    ["ui.clone.project_image"] = { id = 406, fallback = [=[{owner}'s Image]=] },
    ["ui.clone.simulacrum"] = { id = 407, fallback = [=[{owner}'s Simulacrum]=] },
    ["ui.clone.generic"] = { id = 408, fallback = [=[{owner}'s Clone]=] },
    ["ui.cast.all"] = { id = 409, fallback = [=[Cast All]=] },
    ["ui.cast.character"] = { id = 410, fallback = [=[Cast Character]=] },
    ["ui.cast.named"] = { id = 411, fallback = [=[Cast {name}]=] },
    ["ui.cast.summon"] = { id = 412, fallback = [=[Cast (this summon)]=] },
    ["ui.qualifier.self_only"] = { id = 413, fallback = [=[(Self-only)]=] },
    ["ui.qualifier.party_wide"] = { id = 414, fallback = [=[(Party-wide)]=] },
    ["ui.rename_preset_title"] = { id = 415, fallback = [=[Rename Preset:]=] },
    ["ui.add_spell_title"] = { id = 416, fallback = [=[Add Spell or Item to Buff List]=] },
    ["ui.add_to_buff_list"] = { id = 417, fallback = [=[Add to Buff List]=] },
    ["ui.import_config_title"] = { id = 418, fallback = [=[Import Config]=] },
    ["ui.select_variant_title"] = { id = 419, fallback = [=[Select Variant: {spell}]=] },
    ["ui.delete_preset_confirm"] = { id = 420, fallback = [=[Delete preset "{name}" for ALL party members?]=] },
    ["ui.variant.selected"] = { id = 421, fallback = [=[Var: {name}]=] },
    ["ui.target.selected"] = { id = 422, fallback = [=[Target: {target}]=] },
    ["ui.repeat.label"] = { id = 423, fallback = [=[Repeat: {count}]=] },
    ["ui.repeat.spell_tooltip"] = { id = 424, fallback = [=[Cast this spell {count} times per resolved target. Each attempt uses a spell slot and normal casting rules. Left-click increases; right-click decreases. Range 1–{max}.]=] },
    ["ui.repeat.item_tooltip"] = { id = 425, fallback = [=[Use this item {count} times per resolved target. Each attempt consumes a stack or charge and follows normal item-use rules. Left-click increases; right-click decreases. Range 1–{max}.]=] },
    ["ui.target.player"] = { id = 426, fallback = [=[Player {index}]=] },
    ["ui.target.multiple"] = { id = 427, fallback = [=[{name} +{count}]=] },
    ["ui.status.casting"] = { id = 428, fallback = [=[Casting...]=] },
    ["ui.status.casting_quick_long"] = { id = 429, fallback = [=[Casting (Quick: Long)...]=] },
    ["ui.status.casting_quick_all"] = { id = 430, fallback = [=[Casting (Quick: All)...]=] },
    ["ui.status.done"] = { id = 431, fallback = [=[Done]=] },
    ["ui.status.stopped"] = { id = 432, fallback = [=[Stopped]=] },
    ["ui.quick_cast.off"] = { id = 433, fallback = [=[Quick Cast: Off]=] },
    ["ui.quick_cast.long"] = { id = 434, fallback = [=[Quick Cast: Long]=] },
    ["ui.quick_cast.all"] = { id = 435, fallback = [=[Quick Cast: All]=] },
    ["ui.quick_cast.tooltip_unavailable"] = { id = 436, fallback = [=[Normal casting speed]=] },
    ["ui.quick_cast.tooltip_off"] = { id = 437, fallback = [=[Normal casting speed — spells respect aura cooldown. Click to cycle.]=] },
    ["ui.quick_cast.tooltip_long"] = { id = 438, fallback = [=[Fast casting for 'long' buffs (300s+ duration). Short buffs cast normally. Click to cycle.]=] },
    ["ui.quick_cast.tooltip_all"] = { id = 439, fallback = [=[Fast casting for ALL buffs regardless of duration (cheat). Click to cycle.]=] },
    ["ui.duration.permanent"] = { id = 440, fallback = [=[Perm]=] },
    ["ui.duration.instant"] = { id = 441, fallback = [=[Inst]=] },
    ["ui.duration.hours_minutes"] = { id = 442, fallback = [=[{hours}h {minutes}m]=] },
    ["ui.duration.hours"] = { id = 443, fallback = [=[{hours}h]=] },
    ["ui.duration.minutes_seconds"] = { id = 444, fallback = [=[{minutes}m {seconds}s]=] },
    ["ui.duration.minutes"] = { id = 445, fallback = [=[{minutes}m]=] },
    ["ui.duration.seconds"] = { id = 446, fallback = [=[{seconds}s]=] },
    ["ui.category.permanent"] = { id = 447, fallback = [=[permanent]=] },
    ["ui.category.long"] = { id = 448, fallback = [=[long]=] },
    ["ui.category.short"] = { id = 449, fallback = [=[short]=] },
    ["ui.category.instant"] = { id = 450, fallback = [=[instant]=] },
    ["ui.category.unknown"] = { id = 451, fallback = [=[unknown]=] },
    ["ui.repeat.compact"] = { id = 452, fallback = [=[R{count}]=] },
    ["ui.lock.compact"] = { id = 453, fallback = [=[[L]]=] },
    ["feedback.no_luajit"] = { id = 500, fallback = [=[BuffBot: LuaJIT not detected. F12 innates, Quick Cast, Export/Import, and logging are disabled. Install EEex LuaJIT component for full functionality.]=] },
    ["feedback.combat_stopped"] = { id = 501, fallback = [=[BuffBot: Combat detected - casting stopped]=] },
    ["feedback.cast_timeout"] = { id = 502, fallback = [=[BuffBot: casting timed out - stopped]=] },
    ["feedback.party_changed_after_run"] = { id = 503, fallback = [=[BuffBot: Party changed — retry after the current run]=] },
    ["feedback.party_changed_refreshing"] = { id = 504, fallback = [=[BuffBot: Party changed — refreshing innates, try again]=] },
    ["feedback.no_spells_with_reason"] = { id = 505, fallback = [=[BuffBot: No spells or items to use ({reason})]=] },
    ["feedback.innate_error"] = { id = 506, fallback = [=[BuffBot innate error: {error}]=] },
    ["feedback.no_spells_preset"] = { id = 507, fallback = [=[BuffBot: No spells or items to use in this preset]=] },
    ["feedback.character_remote_control"] = { id = 508, fallback = [=[BuffBot: {name} is controlled by another player]=] },
    ["feedback.character_project_image_locked"] = { id = 509, fallback = [=[BuffBot: {name} is puppet-locked by Project Image — cast again after the image expires]=] },
    ["feedback.no_spells_character"] = { id = 510, fallback = [=[BuffBot: No spells or items to use for this character]=] },
    ["feedback.no_summon_selected"] = { id = 511, fallback = [=[BuffBot: No summon selected]=] },
    ["feedback.no_spells_summon"] = { id = 512, fallback = [=[BuffBot: No spells to cast for this summon]=] },
    ["feedback.no_spells_summon_with_reason"] = { id = 513, fallback = [=[BuffBot: No spells to cast for this summon ({reason})]=] },
    ["feedback.no_additional_spells"] = { id = 514, fallback = [=[BuffBot: No additional spells or items to add]=] },
    ["feedback.export_success"] = { id = 515, fallback = [=[BuffBot: Exported config as '{file}']=] },
    ["feedback.export_failed"] = { id = 516, fallback = [=[BuffBot: Export failed — {reason}]=] },
    ["feedback.no_exported_configs"] = { id = 517, fallback = [=[BuffBot: No configs found in bfbot_presets/]=] },
    ["feedback.import_success"] = { id = 518, fallback = [=[BuffBot: Imported '{file}' ({presets} presets, {skipped} entries skipped)]=] },
    ["feedback.import_failed"] = { id = 519, fallback = [=[BuffBot: Import failed — {reason}]=] },
    ["reason.exec.empty_queue"] = { id = 520, fallback = [=[empty queue]=] },
    ["reason.exec.no_valid_entries"] = { id = 521, fallback = [=[no valid entries after expansion]=] },
    ["reason.exec.already_running"] = { id = 522, fallback = [=[already running]=] },
    ["reason.export.luajit_required"] = { id = 523, fallback = [=[LuaJIT required for export]=] },
    ["reason.export.no_sprite"] = { id = 524, fallback = [=[no character selected]=] },
    ["reason.export.no_config"] = { id = 525, fallback = [=[no configuration found]=] },
    ["reason.export.cannot_open_file"] = { id = 526, fallback = [=[cannot open file: {error}]=] },
    ["reason.import.luajit_required"] = { id = 527, fallback = [=[LuaJIT required for import]=] },
    ["reason.import.no_sprite"] = { id = 528, fallback = [=[no character selected]=] },
    ["reason.import.no_filename"] = { id = 529, fallback = [=[no filename selected]=] },
    ["reason.import.invalid_filename"] = { id = 530, fallback = [=[invalid filename]=] },
    ["reason.import.cannot_open_file"] = { id = 531, fallback = [=[cannot open file: {error}]=] },
    ["reason.import.empty_file"] = { id = 532, fallback = [=[empty file]=] },
    ["reason.import.parse_error"] = { id = 533, fallback = [=[parse error: {error}]=] },
    ["reason.import.exec_error"] = { id = 534, fallback = [=[execution error: {error}]=] },
    ["reason.import.invalid_data"] = { id = 535, fallback = [=[file did not contain a valid BuffBot configuration]=] },
    ["reason.queue.invalid_summon"] = { id = 536, fallback = [=[invalid summon entry]=] },
    ["reason.queue.no_summon_preset"] = { id = 537, fallback = [=[no configured summon preset {index}]=] },
    ["reason.queue.caster_resolver_unavailable"] = { id = 538, fallback = [=[caster resolver unavailable]=] },
    ["reason.queue.summon_gone"] = { id = 539, fallback = [=[summon gone ({name})]=] },
    ["reason.queue.summon_scan_failed"] = { id = 540, fallback = [=[scan failed for summon {name}]=] },
    ["reason.queue.no_castable_summon_spells"] = { id = 541, fallback = [=[no castable spells in summon preset {index}]=] },
    ["reason.queue.no_preset_index"] = { id = 542, fallback = [=[no preset index]=] },
    ["reason.queue.no_castable_preset_spells"] = { id = 543, fallback = [=[no castable spells or usable items in preset {index}]=] },
    ["reason.queue.missing_slot_or_preset"] = { id = 544, fallback = [=[missing character slot or preset]=] },
    ["reason.queue.no_sprite_in_slot"] = { id = 545, fallback = [=[no character in slot {slot}]=] },
    ["reason.queue.not_locally_controlled"] = { id = 546, fallback = [=[not locally controlled]=] },
    ["reason.queue.no_config_for_slot"] = { id = 547, fallback = [=[no configuration for slot {slot}]=] },
    ["reason.queue.no_preset_for_slot"] = { id = 548, fallback = [=[no preset {preset} for slot {slot}]=] },
    ["reason.queue.scan_failed_for_slot"] = { id = 549, fallback = [=[scan failed for slot {slot}]=] },
    ["reason.queue.project_image_locked"] = { id = 550, fallback = [=[puppet-locked by Project Image]=] },
    ["reason.queue.no_castable_spells_for_slot"] = { id = 551, fallback = [=[no castable spells or usable items in preset {preset} for slot {slot}]=] },
    ["default.preset.long"] = { id = 600, fallback = [=[Long Buffs]=] },
    ["default.preset.short"] = { id = 601, fallback = [=[Short Buffs]=] },
    ["default.preset.indexed"] = { id = 602, fallback = [=[Preset {index}]=] },
    ["options.tab"] = { id = 700, fallback = [=[BuffBot]=] },
    ["options.dark_mode"] = { id = 701, fallback = [=[Dark Mode]=] },
    ["options.dark_mode_description"] = { id = 702, fallback = [=[Dim the panel parchment for low-light play. The accent palette is preserved.]=] },
    ["options.color_scheme"] = { id = 703, fallback = [=[Color Scheme]=] },
    ["options.color_scheme_description"] = { id = 704, fallback = [=[Choose the panel accent palette: classic BG2 parchment, the steel-blue Siege of Dragonspear, or the warm BG1 amber.]=] },
    ["options.color_scheme_bg2"] = { id = 705, fallback = [=[Baldur's Gate 2]=] },
    ["options.color_scheme_sod"] = { id = 706, fallback = [=[Siege of Dragonspear]=] },
    ["options.color_scheme_bg1"] = { id = 707, fallback = [=[Baldur's Gate 1]=] },
    ["options.text_size"] = { id = 708, fallback = [=[Text Size]=] },
    ["options.text_size_description"] = { id = 709, fallback = [=[Scale all panel text. Close and reopen the BuffBot panel after changing this for the new size to take effect.]=] },
    ["options.text_size_small"] = { id = 710, fallback = [=[Small]=] },
    ["options.text_size_medium"] = { id = 711, fallback = [=[Medium]=] },
    ["options.text_size_large"] = { id = 712, fallback = [=[Large]=] },
}

local _registryById = {}
for _, entry in pairs(_registry) do
    _registryById[entry.id] = entry
end

local _selectedById = {}
local function _LoadSelectedCatalog()
    if type(io) ~= "table" or type(io.open) ~= "function" then return end

    local openOK, handle = pcall(io.open, "override/bfbot_l10n.tra", "r")
    if not openOK or not handle then return end

    local readOK, content = pcall(function() return handle:read("*a") end)
    pcall(function() handle:close() end)
    if not readOK or type(content) ~= "string" then return end

    for line in content:gmatch("[^\r\n]+") do
        local idText, value = line:match(
            "^%s*@(%d+)%s*=%s*~([^~]+)~%s*$"
        )
        local catalogId = idText and tonumber(idText) or nil
        if catalogId and _registryById[catalogId]
                and _selectedById[catalogId] == nil then
            _selectedById[catalogId] = value
        end
    end
end

_LoadSelectedCatalog()

local _resolved = {}
local _unknownWarnings = {}

local function _SafeKeyText(key)
    local ok, text = pcall(tostring, key)
    if ok then return text end
    return "<unprintable key>"
end

local function _UnknownKey(key)
    local keyText = _SafeKeyText(key)
    if not _unknownWarnings[keyText] then
        _unknownWarnings[keyText] = 1
        if type(BfBot._Warn) == "function" then
            pcall(BfBot._Warn, "Missing localization key: " .. keyText)
        end
    end
    return "[[BuffBot missing localization: " .. keyText .. "]]"
end

BfBot.L10N = {
    -- Kept inspectable so automated catalog checks can prove exact ID/key/text
    -- parity without maintaining another parser for Lua source.
    _Registry = _registry,
}

function BfBot.L10N.Get(key)
    local entry = _registry[key]
    if not entry then return _UnknownKey(key) end

    local cached = _resolved[key]
    if cached ~= nil then return cached end

    local value = _selectedById[entry.id] or entry.fallback
    _resolved[key] = value
    return value
end

function BfBot.L10N.Format(key, values)
    local template = BfBot.L10N.Get(key)
    return (template:gsub("{([a-z][a-z0-9_]*)}", function(name)
        local value = type(values) == "table" and values[name] or nil
        if value == nil then return "{" .. name .. "}" end
        return tostring(value)
    end))
end

-- Stable public failure codes are deliberately mapped explicitly.  This keeps
-- caller-facing reason localization separate from arbitrary localization keys,
-- and preserves prose returned by older hot-reloaded modules.
local _reasonKeys = {
    ["reason.exec.empty_queue"] = "reason.exec.empty_queue",
    ["reason.exec.no_valid_entries"] = "reason.exec.no_valid_entries",
    ["reason.exec.already_running"] = "reason.exec.already_running",
    ["reason.export.luajit_required"] = "reason.export.luajit_required",
    ["reason.export.no_sprite"] = "reason.export.no_sprite",
    ["reason.export.no_config"] = "reason.export.no_config",
    ["reason.export.cannot_open_file"] = "reason.export.cannot_open_file",
    ["reason.import.luajit_required"] = "reason.import.luajit_required",
    ["reason.import.no_sprite"] = "reason.import.no_sprite",
    ["reason.import.no_filename"] = "reason.import.no_filename",
    ["reason.import.invalid_filename"] = "reason.import.invalid_filename",
    ["reason.import.cannot_open_file"] = "reason.import.cannot_open_file",
    ["reason.import.empty_file"] = "reason.import.empty_file",
    ["reason.import.parse_error"] = "reason.import.parse_error",
    ["reason.import.exec_error"] = "reason.import.exec_error",
    ["reason.import.invalid_data"] = "reason.import.invalid_data",
    ["reason.queue.invalid_summon"] = "reason.queue.invalid_summon",
    ["reason.queue.no_summon_preset"] = "reason.queue.no_summon_preset",
    ["reason.queue.caster_resolver_unavailable"] = "reason.queue.caster_resolver_unavailable",
    ["reason.queue.summon_gone"] = "reason.queue.summon_gone",
    ["reason.queue.summon_scan_failed"] = "reason.queue.summon_scan_failed",
    ["reason.queue.no_castable_summon_spells"] = "reason.queue.no_castable_summon_spells",
    ["reason.queue.no_preset_index"] = "reason.queue.no_preset_index",
    ["reason.queue.no_castable_preset_spells"] = "reason.queue.no_castable_preset_spells",
    ["reason.queue.missing_slot_or_preset"] = "reason.queue.missing_slot_or_preset",
    ["reason.queue.no_sprite_in_slot"] = "reason.queue.no_sprite_in_slot",
    ["reason.queue.not_locally_controlled"] = "reason.queue.not_locally_controlled",
    ["reason.queue.no_config_for_slot"] = "reason.queue.no_config_for_slot",
    ["reason.queue.no_preset_for_slot"] = "reason.queue.no_preset_for_slot",
    ["reason.queue.scan_failed_for_slot"] = "reason.queue.scan_failed_for_slot",
    ["reason.queue.project_image_locked"] = "reason.queue.project_image_locked",
    ["reason.queue.no_castable_spells_for_slot"] = "reason.queue.no_castable_spells_for_slot",
}

function BfBot.L10N.Reason(code, detail)
    if code == nil then return nil end

    if type(code) ~= "string" then return _UnknownKey(code) end

    local key = _reasonKeys[code]
    if not key then
        if code:match("^reason%.") then return _UnknownKey(code) end
        return code
    end

    local template = BfBot.L10N.Get(key)
    for name in template:gmatch("{([a-z][a-z0-9_]*)}") do
        if type(detail) ~= "table" or detail[name] == nil then
            return _UnknownKey(code)
        end
    end
    return BfBot.L10N.Format(key, detail)
end
