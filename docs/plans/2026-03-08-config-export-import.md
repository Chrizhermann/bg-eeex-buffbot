# Config Export/Import Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Export a character's full BuffBot config to a file and import it onto any character, with a picker UI for selecting from available exports.

**Architecture:** Lua table serialization to `override/bfbot_presets/<CharName>.lua`. Export writes config via `io.open`. Import lists files via `io.popen("dir /b ...")`, shows a picker sub-menu, loads via `loadstring`, validates through existing `_ValidateConfig`/`_MigrateConfig`, and filters out spells the character doesn't have.

**Tech Stack:** Lua (EEex), .menu DSL (Infinity Engine UI)

---

### Task 1: Config serialization functions in BfBotPer.lua

**Files:**
- Modify: `buffbot/BfBotPer.lua` (add after the Override accessors section, before queue building)

**Step 1: Add table serializer**

Add after `BfBot.Persist.SetOverride` (find `-- ---- Override accessors ----` section end), before the queue building section:

```lua
-- ---- Export / Import ----

BfBot.Persist._PRESETS_DIR = "override/bfbot_presets"

--- Serialize a Lua value to a string (supports number, string, table, nil).
function BfBot.Persist._Serialize(val, indent)
    indent = indent or 0
    local pad = string.rep("    ", indent)
    local t = type(val)
    if t == "nil" then
        return "nil"
    elseif t == "number" then
        return tostring(val)
    elseif t == "string" then
        return string.format("%q", val)
    elseif t == "table" then
        local parts = {}
        -- Check if array-like (sequential integer keys from 1)
        local maxN = 0
        for k in pairs(val) do
            if type(k) == "number" and k == math.floor(k) and k > 0 then
                if k > maxN then maxN = k end
            end
        end
        local isArray = maxN > 0 and maxN == #val
        if isArray and maxN <= 10 then
            -- Short array: inline
            local items = {}
            for i = 1, maxN do
                items[i] = BfBot.Persist._Serialize(val[i], 0)
            end
            return "{" .. table.concat(items, ", ") .. "}"
        end
        -- General table
        local innerPad = string.rep("    ", indent + 1)
        -- Integer keys first (sorted)
        local intKeys = {}
        local strKeys = {}
        for k in pairs(val) do
            if type(k) == "number" then
                table.insert(intKeys, k)
            else
                table.insert(strKeys, k)
            end
        end
        table.sort(intKeys)
        table.sort(strKeys)
        for _, k in ipairs(intKeys) do
            table.insert(parts, innerPad .. "[" .. k .. "] = " .. BfBot.Persist._Serialize(val[k], indent + 1))
        end
        for _, k in ipairs(strKeys) do
            local key = k
            if k:match("^[%a_][%w_]*$") then
                key = k
            else
                key = "[" .. string.format("%q", k) .. "]"
            end
            table.insert(parts, innerPad .. key .. " = " .. BfBot.Persist._Serialize(val[k], indent + 1))
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. pad .. "}"
    end
    return "nil"
end

--- Ensure the presets directory exists.
function BfBot.Persist._EnsurePresetsDir()
    os.execute('mkdir "' .. BfBot.Persist._PRESETS_DIR .. '" 2>nul')
end

--- Export the config for a character to a file.
-- Returns true on success, false + error message on failure.
function BfBot.Persist.ExportConfig(sprite)
    if not sprite then return false, "No sprite" end
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return false, "No config" end

    local name = BfBot._GetName(sprite)
    if not name or name == "?" then return false, "Unknown character" end

    -- Sanitize filename (alphanumeric + underscore only)
    local safeName = name:gsub("[^%w_]", "_")
    if safeName == "" then safeName = "export" end

    BfBot.Persist._EnsurePresetsDir()
    local path = BfBot.Persist._PRESETS_DIR .. "/" .. safeName .. ".lua"

    local content = "-- BuffBot Config Export: " .. name .. " (" .. os.date("%Y-%m-%d %H:%M:%S") .. ")\n"
        .. "BfBot._import = " .. BfBot.Persist._Serialize(config, 0) .. "\n"

    local f, err = io.open(path, "w")
    if not f then return false, "Cannot write: " .. tostring(err) end
    f:write(content)
    f:close()

    return true, safeName
end

--- List available config files in the presets directory.
-- Returns array of {name="Edwin", filename="Edwin.lua"} or empty table.
function BfBot.Persist.ListExports()
    local results = {}
    local ok, h = pcall(function()
        return io.popen('dir /b "' .. BfBot.Persist._PRESETS_DIR .. '\\*.lua" 2>nul')
    end)
    if not ok or not h then return results end
    local output = h:read("*a")
    h:close()
    if not output or output == "" then return results end
    for line in output:gmatch("[^\r\n]+") do
        local displayName = line:gsub("%.lua$", "")
        table.insert(results, {
            name = displayName,
            filename = line,
        })
    end
    table.sort(results, function(a, b) return a.name < b.name end)
    return results
end

--- Import a config from a file onto a character.
-- Filters out spells the character doesn't have.
-- Returns true, presetCount, skippedCount on success; false, errorMsg on failure.
function BfBot.Persist.ImportConfig(sprite, filename)
    if not sprite then return false, "No sprite" end

    local path = BfBot.Persist._PRESETS_DIR .. "/" .. filename
    local f, err = io.open(path, "r")
    if not f then return false, "Cannot read: " .. tostring(err) end
    local content = f:read("*a")
    f:close()

    -- Load config via loadstring
    BfBot._import = nil
    local fn, loadErr = loadstring(content)
    if not fn then return false, "Invalid file: " .. tostring(loadErr) end
    local execOk, execErr = pcall(fn)
    if not execOk then return false, "Exec error: " .. tostring(execErr) end
    if not BfBot._import or type(BfBot._import) ~= "table" then
        return false, "No config data in file"
    end

    local config = BfBot._import
    BfBot._import = nil  -- clean up global

    -- Validate and migrate
    config = BfBot.Persist._ValidateConfig(config)
    if config.v < BfBot.Persist._SCHEMA_VERSION then
        config = BfBot.Persist._MigrateConfig(config, config.v)
    end
    BfBot.Persist._SanitizeValues(config)

    -- Filter spells: remove resrefs the character doesn't have
    local castable = BfBot.Scan.GetCastableSpells(sprite)
    local skipped = 0
    for _, preset in pairs(config.presets) do
        if preset.spells then
            for resref in pairs(preset.spells) do
                if not castable[resref] then
                    preset.spells[resref] = nil
                    skipped = skipped + 1
                end
            end
        end
    end

    -- Count presets
    local presetCount = 0
    for _ in pairs(config.presets) do presetCount = presetCount + 1 end

    -- Store config
    pcall(function()
        EEex_GetUDAux(sprite)[BfBot.Persist._KEY] = config
    end)

    -- Sync overrides to classifier
    if config.ovr then
        for resref, val in pairs(config.ovr) do
            if val == 1 then
                BfBot.Class.SetOverride(resref, true)
            elseif val == -1 then
                BfBot.Class.SetOverride(resref, false)
            end
        end
    end

    -- Invalidate caches
    BfBot.Scan.Invalidate(sprite)

    return true, presetCount, skipped
end
```

**Step 2: Commit**

```bash
git add buffbot/BfBotPer.lua
git commit -m "feat(persist): add config export/import serialization and file I/O"
```

---

### Task 2: UI functions for export and import in BfBotUI.lua

**Files:**
- Modify: `buffbot/BfBotUI.lua:77` (add global)
- Modify: `buffbot/BfBotUI.lua` (add functions after `BfBot.UI._PickerHasSelection`, end of Spell Override section)

**Step 1: Add import picker global**

After `buffbot_pickerSelected = 0` (line 77), add:

```lua
-- Import picker state (for "Import Config" sub-menu)
buffbot_importList = {}
buffbot_importSelected = 0
```

**Step 2: Add export/import UI functions**

After `BfBot.UI._PickerHasSelection()` (end of Spell Override section), add:

```lua
-- ============================================================
-- Config Export / Import
-- ============================================================

--- Export current character's config.
function BfBot.UI.ExportConfig()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end

    local ok, result = BfBot.Persist.ExportConfig(sprite)
    if ok then
        Infinity_DisplayString("BuffBot: Exported config as '" .. result .. "'")
    else
        Infinity_DisplayString("BuffBot: Export failed — " .. tostring(result))
    end
end

--- Build the import picker list from available files.
function BfBot.UI._BuildImportList()
    buffbot_importList = {}
    buffbot_importSelected = 0
    local exports = BfBot.Persist.ListExports()
    for _, entry in ipairs(exports) do
        table.insert(buffbot_importList, {
            name = entry.name,
            filename = entry.filename,
        })
    end
end

--- Open the import picker sub-menu.
function BfBot.UI.OpenImportPicker()
    BfBot.UI._BuildImportList()
    if #buffbot_importList == 0 then
        Infinity_DisplayString("BuffBot: No configs found in bfbot_presets/")
        return
    end
    Infinity_PushMenu("BUFFBOT_IMPORT")
end

--- Import the selected config from the picker.
function BfBot.UI.ImportSelected()
    local entry = buffbot_importList[buffbot_importSelected]
    if not entry then return end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end

    local ok, presets, skipped = BfBot.Persist.ImportConfig(sprite, entry.filename)
    Infinity_PopMenu("BUFFBOT_IMPORT")

    if ok then
        Infinity_DisplayString("BuffBot: Imported '" .. entry.name .. "' ("
            .. presets .. " presets, " .. skipped .. " spells skipped)")
        BfBot.Scan.Invalidate(sprite)
        BfBot.UI._Refresh()
    else
        Infinity_DisplayString("BuffBot: Import failed — " .. tostring(presets))
    end
end

--- Import picker has a valid selection.
function BfBot.UI._ImportHasSelection()
    return buffbot_importSelected > 0 and buffbot_importSelected <= #buffbot_importList
end
```

**Step 3: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): add export/import config functions and import picker logic"
```

---

### Task 3: Menu layout — Export/Import buttons and BUFFBOT_IMPORT sub-menu

**Files:**
- Modify: `buffbot/BuffBot.menu:396-410` (add buttons after Remove)
- Modify: `buffbot/BuffBot.menu` (add BUFFBOT_IMPORT menu after BUFFBOT_SPELLPICKER)

**Step 1: Add Export and Import buttons**

After the Remove button closing `}` (line 410), before the "Selected spell actions" comment (line 412), insert:

```
	-- Export current character's config
	button
	{
		name    "bbExp"
		enabled "buffbot_isOpen"
		action  "BfBot.UI.ExportConfig()"
		text    "Export"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 610 402 90 28
	}

	-- Import config from file
	button
	{
		name    "bbImp"
		enabled "buffbot_isOpen"
		action  "BfBot.UI.OpenImportPicker()"
		text    "Import"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 706 402 90 28
	}
```

**Step 2: Add BUFFBOT_IMPORT sub-menu**

After the BUFFBOT_SPELLPICKER menu closing `}` (end of file, line 883), add:

```
-- ============================================================
-- Import Config Picker
-- ============================================================

menu
{
	name    "BUFFBOT_IMPORT"
	ignoreesc

	-- Dark overlay (click to close)
	text
	{
		action  "Infinity_PopMenu('BUFFBOT_IMPORT')"
		area    0 0 99999 99999
		rectangle 1
		rectangle opacity 50
		on escape
	}

	-- Panel background
	label
	{
		area 420 150 320 300
		rectangle 5
		rectangle opacity 200
	}

	-- Title
	label
	{
		text    "Import Config"
		text style "title"
		text align center center
		area 420 155 320 25
	}

	-- Config list
	list
	{
		column
		{
			width 100
			label
			{
				area 0 0 -1 34
				text lua "buffbot_importList[rowNumber] and buffbot_importList[rowNumber].name or ''"
				text style "normal"
				text align left center
			}
		}

		area 430 185 280 200
		enabled     "true"
		table       "buffbot_importList"
		var         "buffbot_importSelected"
		rowheight   34
		scrollbar   "GUISCRC"
	}

	-- Import button
	button
	{
		enabled "BfBot.UI._ImportHasSelection()"
		action  "BfBot.UI.ImportSelected()"
		text    "Import"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 430 390 140 28
	}

	-- Cancel button
	button
	{
		action  "Infinity_PopMenu('BUFFBOT_IMPORT')"
		text    "Cancel"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 580 390 120 28
	}
}
```

**Step 3: Commit**

```bash
git add buffbot/BuffBot.menu
git commit -m "feat(menu): add Export/Import buttons and import picker sub-menu"
```

---

### Task 4: WeiDU installer — create presets directory

**Files:**
- Modify: `setup-buffbot.tp2:34` (add MKDIR after file copies)
- Modify: `tools/deploy.sh` (add mkdir)

**Step 1: Add MKDIR to WeiDU installer**

After `COPY ~buffbot/BuffBot.menu~  ~override~` (line 33), before the strref block (line 35), add:

```
// ---- Create presets directory for config export/import ----
MKDIR ~override/bfbot_presets~
```

**Step 2: Add mkdir to deploy script**

In `tools/deploy.sh`, after the file copy commands, add:

```bash
mkdir -p "$OVERRIDE_DIR/bfbot_presets"
```

Find the line that says something like `echo "Deploy complete"` or the end of the copy block, and add the mkdir before it.

**Step 3: Commit**

```bash
git add setup-buffbot.tp2 tools/deploy.sh
git commit -m "feat(install): create bfbot_presets directory for config export/import"
```

---

### Task 5: Tests for export/import

**Files:**
- Modify: `buffbot/BfBotTst.lua` (add `BfBot.Test.ExportImport()` before `RunAll`, update `RunAll`)

**Step 1: Add ExportImport test function**

Before `function BfBot.Test.RunAll()` (line 750), add:

```lua
-- ============================================================
-- BfBot.Test.ExportImport — Config export/import tests
-- ============================================================

function BfBot.Test.ExportImport()
    P("=== ExportImport: Config file export/import ===")
    _reset()

    local sprite0 = EEex_Sprite_GetInPortrait(0)
    if not sprite0 then
        _nok("No sprite in slot 0")
        return _summary("ExportImport")
    end

    -- Test 1: Serializer round-trip
    local testTable = {v=5, presets={[1]={name="Test", spells={["ABC"]={on=1,tgt="s",pri=1}}}}}
    local serialized = BfBot.Persist._Serialize(testTable, 0)
    if serialized and #serialized > 10 then
        _ok("Serializer produced output (" .. #serialized .. " chars)")
    else
        _nok("Serializer failed")
        return _summary("ExportImport")
    end

    -- Verify it parses back
    local fn = loadstring("BfBot._import = " .. serialized)
    if fn then
        BfBot._import = nil
        pcall(fn)
        if BfBot._import and BfBot._import.v == 5 then
            _ok("Serialized output parses back correctly")
        else
            _nok("Parsed data incorrect")
        end
        BfBot._import = nil
    else
        _nok("Serialized output doesn't parse")
    end

    -- Test 2: Export writes a file
    local exportOk, exportName = BfBot.Persist.ExportConfig(sprite0)
    if exportOk then
        _ok("ExportConfig succeeded: " .. tostring(exportName))
    else
        _nok("ExportConfig failed: " .. tostring(exportName))
        return _summary("ExportImport")
    end

    -- Test 3: ListExports finds the file
    local exports = BfBot.Persist.ListExports()
    local found = false
    for _, e in ipairs(exports) do
        if e.name == exportName then found = true; break end
    end
    if found then
        _ok("ListExports found '" .. exportName .. "'")
    else
        _nok("ListExports didn't find '" .. exportName .. "' (found " .. #exports .. " files)")
    end

    -- Test 4: Import onto another character (or same if only 1 party member)
    local targetSlot = 0
    for s = 1, 5 do
        if EEex_Sprite_GetInPortrait(s) then targetSlot = s; break end
    end
    local targetSprite = EEex_Sprite_GetInPortrait(targetSlot)
    if targetSprite then
        local importOk, presetCount, skipped = BfBot.Persist.ImportConfig(
            targetSprite, exportName .. ".lua")
        if importOk then
            _ok("ImportConfig succeeded: " .. presetCount .. " presets, " .. skipped .. " spells skipped")

            -- Verify config was applied
            local config = BfBot.Persist.GetConfig(targetSprite)
            if config and config.presets then
                local pCount = 0
                for _ in pairs(config.presets) do pCount = pCount + 1 end
                if pCount == presetCount then
                    _ok("Imported config has correct preset count")
                else
                    _nok("Preset count mismatch: got " .. pCount .. " expected " .. presetCount)
                end
            else
                _nok("Config nil after import")
            end
        else
            _nok("ImportConfig failed: " .. tostring(presetCount))
        end
    else
        _warning("No second party member for cross-character import test")
    end

    -- Test 5: Import non-existent file
    local badOk, badErr = BfBot.Persist.ImportConfig(sprite0, "NONEXISTENT_FILE.lua")
    if not badOk then
        _ok("ImportConfig correctly rejects missing file")
    else
        _nok("ImportConfig should have failed for missing file")
    end

    -- Cleanup: remove test export file
    pcall(function()
        os.remove(BfBot.Persist._PRESETS_DIR .. "/" .. exportName .. ".lua")
    end)

    return _summary("ExportImport")
end
```

**Step 2: Add ExportImport phase to RunAll**

After the Override phase (line 786), add:

```lua
    -- Phase 7: Export/Import
    local exportOk = BfBot.Test.ExportImport()
    P("")
```

Update the summary block (lines 789-796) to include export/import:

After line 795 (`P("  Overrides: " ..`), add:
```lua
    P("  Export/Import: " .. (exportOk and "PASS" or "FAIL"))
```

Update the return line (line 800) to include exportOk:
```lua
    return fieldsOk and classOk and scanOk and persistOk and qcOk and ovrOk and exportOk
```

**Step 3: Commit**

```bash
git add buffbot/BfBotTst.lua
git commit -m "test: add export/import tests and integrate into RunAll"
```

---

### Task 6: Documentation and deploy

**Files:**
- Modify: `CLAUDE.md` (add export/import section)
- Modify: `README.md` (update features list)

**Step 1: Update CLAUDE.md**

In the "Current Phase" section, add after the Manual Spell Override bullet:

```
- **Config Export/Import** (`BfBot.Persist` + `BfBot.UI`) — Export full character config to `override/bfbot_presets/<CharName>.lua`, import via picker sub-menu. Spells the target character doesn't have are silently dropped. Uses `io.popen` for directory listing, `os.execute` for lazy mkdir.
```

Add a new subsection:

```
### Config Export/Import Details (GitHub #2)
- **Storage**: `override/bfbot_presets/<CharName>.lua` — Lua table serialization of full config
- **Export flow**: Click "Export" → config serialized → written to file named after character
- **Import flow**: Click "Import" → `io.popen("dir /b ...")` lists files → picker sub-menu → select → load via `loadstring` → `_ValidateConfig` + `_MigrateConfig` → filter missing spells → apply
- **Spell filtering**: On import, each preset's spells checked against target character's castable spells. Missing resrefs silently dropped with count in feedback.
- **Directory**: Created at install (WeiDU `MKDIR`) + lazily via `os.execute`
- **API**: `BfBot.Persist.ExportConfig(sprite)`, `BfBot.Persist.ListExports()`, `BfBot.Persist.ImportConfig(sprite, filename)`
- **UI**: BUFFBOT_IMPORT sub-menu with scrollable list + Import/Cancel buttons
```

**Step 2: Update README.md**

In the Features list, add:
```
- **Config export/import** — export character buff configs to files, import onto any character across saves or share with other players
```

**Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document config export/import feature"
```

**Step 4: Deploy and test**

```bash
bash tools/deploy.sh
```

In-game:
```
BfBot.Test.ExportImport()
BfBot.Test.RunAll()
```

Manual test:
1. Open panel, select a caster, click Export
2. Click Import, verify picker shows the exported file
3. Switch to a different character, click Import, select the file
4. Verify presets imported, missing spells skipped

---

## Task Dependencies

```
Task 1 (Serialization) ──┬── Task 2 (UI Logic) ── Task 3 (Menu) ──┐
                          ├── Task 4 (Installer) ──────────────────├── Task 6 (Docs+Deploy)
                          └── Task 5 (Tests) ──────────────────────┘
```
