# Quick Cast (Cheat Mode) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a per-preset 3-state "Quick Cast" toggle (Off/Long/All) that applies Improved Alacrity + casting speed reduction to speed up buffing, with a two-pass queue split by spell duration.

**Architecture:** Generates two runtime SPL files (BFBTCH for cheat buff, BFBTCR for removal). Execution engine splits each caster's queue into cheat/normal buckets and applies the cheat buff at boundaries. Per-preset `qc` field persists in the existing UDAux marshal config with schema migration v3->v4. UI cycling button in the config panel.

**Tech Stack:** Lua (EEex bridge), .menu DSL, SPL binary generation, BCS action queuing

**Design Doc:** `docs/plans/2026-02-28-cheat-mode-design.md`

---

### Task 0: Generate cheat SPL files (BFBTCH + BFBTCR)

**Files:**
- Modify: `src/BfBotInn.lua:145-168` (after `_BuildSPL`, extend `_EnsureSPLFiles`)

**Step 1: Add `_BuildCheatSPL()` function after `_BuildSPL` (line 145)**

Insert after the closing `end` of `_BuildSPL`:

```lua
--- Build the Quick Cast cheat buff SPL (BFBTCH).
-- Applies: Opcode 188 (Aura Cleansing) + Opcode 189 (Casting Time -10).
-- Duration: 300 seconds (generous — covers any queue).
-- @return string: raw SPL binary data (250 bytes)
function BfBot.Innate._BuildCheatSPL()
    local HEADER_SIZE = 0x72
    local EXT_SIZE    = 0x28
    local FEAT_SIZE   = 0x30
    local extOffset   = HEADER_SIZE
    local featOffset  = HEADER_SIZE + EXT_SIZE

    local header = "SPL "
        .. "V1  "
        .. _splDword(0xFFFFFFFF)           -- 0x0008: name strref (none)
        .. _splDword(0xFFFFFFFF)           -- 0x000C: name strref (none)
        .. _splResref("")                  -- 0x0010: completion sound
        .. _splDword(0)                    -- 0x0018: flags
        .. _splWord(4)                     -- 0x001C: spell type = innate
        .. _splDword(0)                    -- 0x001E: exclusion flags
        .. _splWord(0)                     -- 0x0022: casting graphics
        .. _splByte(0) .. _splByte(0)      -- 0x0024-0025: unused
        .. _splByte(0) .. _splByte(0)      -- 0x0026-0027: unused
        .. _splPad(12)                     -- 0x0028: unused block
        .. _splDword(1)                    -- 0x0034: spell level
        .. _splWord(0)                     -- 0x0038: stack amount
        .. _splResref("")                  -- 0x003A: icon (invisible)
        .. _splWord(0)                     -- 0x0042: lore
        .. _splResref("")                  -- 0x0044: ground icon
        .. _splDword(0)                    -- 0x004C: weight
        .. _splDword(0xFFFFFFFF)           -- 0x0050: desc unidentified
        .. _splDword(0xFFFFFFFF)           -- 0x0054: desc identified
        .. _splResref("")                  -- 0x0058: desc icon
        .. _splDword(0)                    -- 0x0060: enchantment
        .. _splDword(extOffset)            -- 0x0064: ext header offset
        .. _splWord(1)                     -- 0x0068: ext header count
        .. _splDword(featOffset)           -- 0x006A: feature block offset
        .. _splWord(0)                     -- 0x006E: casting feat offset
        .. _splWord(0)                     -- 0x0070: casting feat count

    local ability = _splByte(1)            -- spell form = standard
        .. _splByte(0x04)                  -- flags = friendly
        .. _splWord(4)                     -- location = innate
        .. _splResref("")                  -- icon (invisible)
        .. _splByte(5)                     -- target = self
        .. _splByte(0)                     -- target count
        .. _splWord(0)                     -- range
        .. _splWord(1)                     -- level required
        .. _splWord(0)                     -- casting time = instant
        .. _splWord(0)                     -- times per day
        .. _splWord(0) .. _splWord(0)      -- dice
        .. _splWord(0)                     -- enchanted
        .. _splWord(0)                     -- damage type
        .. _splWord(2)                     -- feature block count = 2
        .. _splWord(0)                     -- feature block offset (index)
        .. _splWord(0)                     -- charges
        .. _splWord(0)                     -- charge depletion
        .. _splWord(1)                     -- projectile = none

    -- Opcode 188: Aura Cleansing (Improved Alacrity)
    local feat188 = _splWord(188)
        .. _splByte(1)                     -- target = self
        .. _splByte(0)                     -- power
        .. _splDword(1)                    -- param1 = 1 (enable)
        .. _splDword(0)                    -- param2
        .. _splByte(0)                     -- timing = duration
        .. _splByte(0)                     -- dispel/resistance
        .. _splDword(300)                  -- duration = 300 seconds
        .. _splByte(100) .. _splByte(0)    -- probability 0-100
        .. _splResref("")                  -- resource
        .. _splDword(0) .. _splDword(0)    -- dice
        .. _splDword(0) .. _splDword(0)    -- save
        .. _splDword(0)                    -- stacking ID

    -- Opcode 189: Casting Speed Modifier (-10)
    local feat189 = _splWord(189)
        .. _splByte(1)                     -- target = self
        .. _splByte(0)                     -- power
        .. _splDword(-10)                  -- param1 = -10 (max IE casting time is 10)
        .. _splDword(0)                    -- param2
        .. _splByte(0)                     -- timing = duration
        .. _splByte(0)                     -- dispel/resistance
        .. _splDword(300)                  -- duration = 300 seconds
        .. _splByte(100) .. _splByte(0)    -- probability 0-100
        .. _splResref("")                  -- resource
        .. _splDword(0) .. _splDword(0)    -- dice
        .. _splDword(0) .. _splDword(0)    -- save
        .. _splDword(0)                    -- stacking ID

    return header .. ability .. feat188 .. feat189
end
```

**Step 2: Add `_BuildCheatRemoverSPL()` function**

Insert immediately after `_BuildCheatSPL`:

```lua
--- Build the Quick Cast cheat remover SPL (BFBTCR).
-- Opcode 321: Remove Effects by Resource, targeting "BFBTCH".
-- @return string: raw SPL binary data (202 bytes)
function BfBot.Innate._BuildCheatRemoverSPL()
    local HEADER_SIZE = 0x72
    local EXT_SIZE    = 0x28
    local FEAT_SIZE   = 0x30
    local extOffset   = HEADER_SIZE
    local featOffset  = HEADER_SIZE + EXT_SIZE

    local header = "SPL "
        .. "V1  "
        .. _splDword(0xFFFFFFFF)
        .. _splDword(0xFFFFFFFF)
        .. _splResref("")
        .. _splDword(0)
        .. _splWord(4)
        .. _splDword(0)
        .. _splWord(0)
        .. _splByte(0) .. _splByte(0)
        .. _splByte(0) .. _splByte(0)
        .. _splPad(12)
        .. _splDword(1)
        .. _splWord(0)
        .. _splResref("")
        .. _splWord(0)
        .. _splResref("")
        .. _splDword(0)
        .. _splDword(0xFFFFFFFF)
        .. _splDword(0xFFFFFFFF)
        .. _splResref("")
        .. _splDword(0)
        .. _splDword(extOffset)
        .. _splWord(1)
        .. _splDword(featOffset)
        .. _splWord(0)
        .. _splWord(0)

    local ability = _splByte(1)
        .. _splByte(0x04)
        .. _splWord(4)
        .. _splResref("")
        .. _splByte(5)
        .. _splByte(0)
        .. _splWord(0)
        .. _splWord(1)
        .. _splWord(0)
        .. _splWord(0)
        .. _splWord(0) .. _splWord(0)
        .. _splWord(0)
        .. _splWord(0)
        .. _splWord(1)                    -- feature block count = 1
        .. _splWord(0)
        .. _splWord(0)
        .. _splWord(0)
        .. _splWord(1)

    -- Opcode 321: Remove Effects by Resource
    local feat321 = _splWord(321)
        .. _splByte(1)                     -- target = self
        .. _splByte(0)                     -- power
        .. _splDword(0)                    -- param1
        .. _splDword(0)                    -- param2
        .. _splByte(1)                     -- timing = 1 (instant/permanent)
        .. _splByte(0)                     -- dispel/resistance
        .. _splDword(0)                    -- duration
        .. _splByte(100) .. _splByte(0)    -- probability 0-100
        .. _splResref("BFBTCH")            -- resource = cheat buff to remove
        .. _splDword(0) .. _splDword(0)    -- dice
        .. _splDword(0) .. _splDword(0)    -- save
        .. _splDword(0)                    -- stacking ID

    return header .. ability .. feat321
end
```

**Step 3: Extend `_EnsureSPLFiles()` to write BFBTCH and BFBTCR**

In `_EnsureSPLFiles` (line 152-168), add after the slot/preset loop ends (before `return count`):

```lua
    -- Write Quick Cast cheat SPLs
    local cheatData = BfBot.Innate._BuildCheatSPL()
    local cheatF = io.open("override/BFBTCH.SPL", "wb")
    if cheatF then cheatF:write(cheatData); cheatF:close(); count = count + 1 end

    local removerData = BfBot.Innate._BuildCheatRemoverSPL()
    local removerF = io.open("override/BFBTCR.SPL", "wb")
    if removerF then removerF:write(removerData); removerF:close(); count = count + 1 end
```

**Step 4: Deploy and verify SPL files exist**

Run: `bash tools/deploy.sh`
Verify: `ls -la "/c/games/Baldur's Gate II Enhanced Edition/override/BFBTCH.SPL" "/c/games/Baldur's Gate II Enhanced Edition/override/BFBTCR.SPL"`
Expected: BFBTCH.SPL = 250 bytes, BFBTCR.SPL = 202 bytes (after game restart to trigger M_BfBot.lua)

**Step 5: Commit**

```bash
git add src/BfBotInn.lua
git commit -m "feat: generate BFBTCH/BFBTCR cheat buff SPL files at runtime"
```

---

### Task 1: Schema migration v3->v4 + persistence accessors

**Files:**
- Modify: `src/BfBotPer.lua:10` (schema version)
- Modify: `src/BfBotPer.lua:42-51` (default config)
- Modify: `src/BfBotPer.lua:152-211` (validation)
- Modify: `src/BfBotPer.lua:214-243` (migration)
- Modify: `src/BfBotPer.lua:379-394` (new accessors after options section)
- Modify: `src/BfBotPer.lua:529-580` (CreatePreset — add qc to new preset)
- Modify: `src/BfBotPer.lua:617-665` (CreatePresetAll — add qc to new preset)

**Step 1: Bump schema version**

At line 10, change:
```lua
BfBot.Persist._SCHEMA_VERSION = 3
```
to:
```lua
BfBot.Persist._SCHEMA_VERSION = 4
```

**Step 2: Add `qc=0` to default presets**

In `GetDefaultConfig()` (line 42-51), change both preset entries:
```lua
        presets = {
            [1] = { name = "Long Buffs",  cat = "long",  qc = 0, spells = {} },
            [2] = { name = "Short Buffs", cat = "short", qc = 0, spells = {} },
        },
```

**Step 3: Add qc validation in `_ValidateConfig`**

In the preset validation loop (around line 176-197), after `if type(preset.cat) ~= "string" then preset.cat = "custom" end`, add:
```lua
            if type(preset.qc) ~= "number" or preset.qc < 0 or preset.qc > 2 then
                preset.qc = 0
            end
```

**Step 4: Remove opts.cheat validation**

In the options validation (around line 200-205), remove:
```lua
        if type(config.opts.cheat) ~= "number" then config.opts.cheat = 0 end
```

**Step 5: Add v3->v4 migration in `_MigrateConfig`**

Replace the existing `_MigrateConfig` body (line 214-219) with:
```lua
function BfBot.Persist._MigrateConfig(config, fromVersion)
    -- v1/v2 -> v3: target fixup (deferred to _MigrateV1Targets)

    -- v3 -> v4: move opts.cheat to per-preset qc field
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

    config.v = BfBot.Persist._SCHEMA_VERSION
    return config
end
```

**Step 6: Add Quick Cast accessors**

After the Options section (after `SetOpt`, around line 394), add:

```lua
-- ---- Quick Cast (per-preset) ----

--- Get the quick cast mode for a preset (0=off, 1=long, 2=all).
function BfBot.Persist.GetQuickCast(sprite, presetIndex)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset then return 0 end
    return preset.qc or 0
end

--- Set the quick cast mode for a preset. Clamps to 0-2.
function BfBot.Persist.SetQuickCast(sprite, presetIndex, value)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset then return end
    preset.qc = math.max(0, math.min(2, value or 0))
end

--- Set quick cast mode for a preset across ALL party members.
function BfBot.Persist.SetQuickCastAll(presetIndex, value)
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if sprite then
            BfBot.Persist.SetQuickCast(sprite, presetIndex, value)
        end
    end
end
```

**Step 7: Add `qc=0` to CreatePreset and CreatePresetAll**

In `CreatePreset` (around line 573), add `qc = 0` to the new preset table:
```lua
    config.presets[idx] = {
        name = name or ("Preset " .. idx),
        cat = "custom",
        qc = 0,
        spells = spells,
    }
```

In `CreatePresetAll` (around line 657), same change:
```lua
                config.presets[idx] = {
                    name = name or ("Preset " .. idx),
                    cat = "custom",
                    qc = 0,
                    spells = spells,
                }
```

**Step 8: Add `qc=0` to `_CreateDefaultConfig` presets**

In `_CreateDefaultConfig` (line 67), the config starts from `GetDefaultConfig()` which already has `qc=0` from Step 2. No additional change needed.

**Step 9: Commit**

```bash
git add src/BfBotPer.lua
git commit -m "feat: schema v4 — per-preset quick cast field with migration"
```

---

### Task 2: Execution engine cheat mode

**Files:**
- Modify: `src/BfBotExe.lua:9-16` (new state fields)
- Modify: `src/BfBotExe.lua:98-181` (`_BuildQueue` — tag entries with cheat flag)
- Modify: `src/BfBotExe.lua:256-298` (`_ProcessCasterEntry` — boundary actions)
- Modify: `src/BfBotExe.lua:309-319` (`_Complete` — cleanup)
- Modify: `src/BfBotExe.lua:321-392` (`Start` — accept qcMode, propagate)
- Modify: `src/BfBotExe.lua:395-406` (`Stop` — cleanup cheat buff)

**Step 1: Add qcMode state field**

After line 16 (`_logFile`), add:
```lua
BfBot.Exec._qcMode = 0              -- quick cast mode (0=off, 1=long, 2=all)
```

**Step 2: Tag entries with cheat flag in `_BuildQueue`**

Change the `_BuildQueue` function signature (line 101) to accept qcMode:
```lua
function BfBot.Exec._BuildQueue(userQueue, qcMode)
```

Inside the target expansion loop (around line 156-171), add a `cheat` field to each entry based on qcMode and the spell's duration category:
```lua
        -- Determine if this entry gets cheat mode
        local isCheat = false
        if qcMode == 2 then
            isCheat = true
        elseif qcMode == 1 then
            local durCat = classResult and classResult.durCat or "short"
            isCheat = (durCat == "permanent" or durCat == "long")
        end

        for _, tgt in ipairs(targets) do
            table.insert(byCaster[casterSlot], {
                casterSlot = casterSlot,
                casterSprite = casterSprite,
                casterName = casterName,
                resref = resref,
                spellName = spellName,
                targetObj = tgt.targetObj,
                targetSlot = tgt.targetSlot,
                targetSprite = tgt.targetSprite,
                targetName = tgt.targetName,
                splstates = splstates,
                isAoE = isAoE,
                cheat = isCheat,
            })
            totalEntries = totalEntries + 1
        end
```

**Step 3: Sort per-caster queues — cheat entries first**

After `_BuildQueue` builds `byCaster`, add sorting that puts cheat entries first while preserving original order within each group. Add before the `return byCaster, totalEntries` (line 180):

```lua
    -- Sort each caster's queue: cheat entries first, then normal (stable order within groups)
    if qcMode == 1 then
        for slot, entries in pairs(byCaster) do
            local cheatEntries = {}
            local normalEntries = {}
            for _, e in ipairs(entries) do
                if e.cheat then
                    table.insert(cheatEntries, e)
                else
                    table.insert(normalEntries, e)
                end
            end
            -- Rebuild: cheat first, then normal
            local merged = {}
            for _, e in ipairs(cheatEntries) do table.insert(merged, e) end
            for _, e in ipairs(normalEntries) do table.insert(merged, e) end
            byCaster[slot] = merged
        end
    end
```

**Step 4: Compute cheat boundary per caster in `Start`**

In the `Start` function, after initializing per-caster state (around line 366-373), compute the boundary:

```lua
        -- Compute cheat boundary (last cheat entry index, 0 if none)
        local cheatBoundary = 0
        if BfBot.Exec._qcMode > 0 then
            for i, e in ipairs(entries) do
                if e.cheat then cheatBoundary = i end
            end
        end

        BfBot.Exec._casters[slot] = {
            queue = entries,
            index = 0,
            done = false,
            sprite = sprite,
            name = name,
            cheatBoundary = cheatBoundary,
            cheatApplied = false,
        }
```

**Step 5: Apply/remove cheat buff in `_ProcessCasterEntry`**

In `_ProcessCasterEntry` (line 258-298), after the pre-flight check passes and before building BCS action strings, add boundary logic:

```lua
    -- Quick Cast: apply cheat buff before first cheat entry
    if index == 1 and caster.cheatBoundary > 0 and not caster.cheatApplied then
        EEex_Action_QueueResponseStringOnAIBase(
            'ApplySpellRES("BFBTCH",Myself)', entry.casterSprite)
        caster.cheatApplied = true
        BfBot.Exec._LogEntry("INFO", entry.casterName .. " Quick Cast ON")
    end

    -- Quick Cast: remove cheat buff at boundary (transition from cheat to normal)
    if index == caster.cheatBoundary + 1 and caster.cheatApplied then
        EEex_Action_QueueResponseStringOnAIBase(
            'ApplySpellRES("BFBTCR",Myself)', entry.casterSprite)
        caster.cheatApplied = false
        BfBot.Exec._LogEntry("INFO", entry.casterName .. " Quick Cast OFF")
    end
```

**Step 6: Clean up cheat buff in `_Complete`**

In `_Complete` (line 310-319), add cleanup before setting state to "done":

```lua
    -- Clean up any lingering cheat buffs (qcMode=2 or all entries were cheat)
    for slot, caster in pairs(BfBot.Exec._casters) do
        if caster.cheatApplied and caster.sprite then
            pcall(function()
                EEex_Action_QueueResponseStringOnAIBase(
                    'ApplySpellRES("BFBTCR",Myself)', caster.sprite)
            end)
            caster.cheatApplied = false
        end
    end
```

**Step 7: Clean up cheat buff in `Stop`**

In `Stop` (line 395-406), add the same cleanup after setting state to "stopped":

```lua
    -- Clean up cheat buffs on stopped casters
    for slot, caster in pairs(BfBot.Exec._casters) do
        if caster.cheatApplied and caster.sprite then
            pcall(function()
                EEex_Action_QueueResponseStringOnAIBase(
                    'ApplySpellRES("BFBTCR",Myself)', caster.sprite)
            end)
            caster.cheatApplied = false
        end
    end
```

**Step 8: Update `Start` to accept and store qcMode**

Change the `Start` signature (line 324):
```lua
function BfBot.Exec.Start(queue, qcMode)
```

In the reset section (line 334-340), add:
```lua
    BfBot.Exec._qcMode = qcMode or 0
```

Update the `_BuildQueue` call (line 343):
```lua
    local byCaster, totalEntries = BfBot.Exec._BuildQueue(queue, BfBot.Exec._qcMode)
```

Update the plan display (line 354) to show cheat mode:
```lua
    local qcLabel = BfBot.Exec._qcMode == 2 and " (Quick Cast: All)"
        or BfBot.Exec._qcMode == 1 and " (Quick Cast: Long)" or ""
    BfBot._Print("[BuffBot] === Starting Execution: " .. totalEntries .. " entries" .. qcLabel .. " ===")
```

**Step 9: Commit**

```bash
git add src/BfBotExe.lua
git commit -m "feat: execution engine cheat mode with two-pass queue splitting"
```

---

### Task 3: UI — Quick Cast cycling button

**Files:**
- Modify: `src/BfBotUI.lua:429-444` (Cast/Stop — pass qcMode)
- Modify: `src/BfBotUI.lua:486-602` (add new helper functions at end)
- Modify: `src/BuffBot.menu:354-403` (add button in action area)

**Step 1: Add Quick Cast UI functions**

At the end of `BfBotUI.lua` (before the closing comment or after `_GetStatusText`), add:

```lua
-- ============================================================
-- Quick Cast Cycling Button
-- ============================================================

--- Cycle quick cast mode: 0 -> 1 -> 2 -> 0 for current preset across all characters.
function BfBot.UI.CycleQuickCast()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end
    local current = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    local next = (current + 1) % 3
    BfBot.Persist.SetQuickCastAll(BfBot.UI._presetIdx, next)
end

--- Quick Cast button label (read by .menu every frame).
function BfBot.UI._QuickCastLabel()
    if not buffbot_isOpen then return "" end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return "Quick Cast: Off" end
    local qc = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    if qc == 1 then return "Quick Cast: Long" end
    if qc == 2 then return "Quick Cast: All" end
    return "Quick Cast: Off"
end

--- Quick Cast button color: white=off, yellow=long, red=all.
function BfBot.UI._QuickCastColor()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return {200, 200, 200} end
    local qc = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    if qc == 1 then return {230, 200, 60} end
    if qc == 2 then return {230, 100, 60} end
    return {200, 200, 200}
end

--- Quick Cast tooltip.
function BfBot.UI._QuickCastTooltip()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return "Normal casting speed" end
    local qc = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    if qc == 1 then return "Fast casting for buffs lasting 5+ turns (click to cycle)" end
    if qc == 2 then return "Fast casting for ALL buffs — cheat (click to cycle)" end
    return "Normal casting speed (click to cycle)"
end
```

**Step 2: Update `Cast()` to pass qcMode**

Replace the existing `Cast` function (line 433-439):

```lua
function BfBot.UI.Cast()
    local queue = BfBot.Persist.BuildQueueFromPreset(BfBot.UI._presetIdx)
    if queue then
        local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
        local qcMode = sprite and BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx) or 0
        BfBot.Exec.Start(queue, qcMode)
        buffbot_status = BfBot.UI._GetStatusText()
    end
end
```

**Step 3: Update `_GetStatusText` to show cheat mode**

Replace the existing `_GetStatusText` function (line 595-601):

```lua
function BfBot.UI._GetStatusText()
    local state = BfBot.Exec.GetState()
    if state == "running" then
        local qc = BfBot.Exec._qcMode or 0
        if qc == 2 then return "Casting (Quick: All)..."
        elseif qc == 1 then return "Casting (Quick: Long)..."
        else return "Casting..." end
    elseif state == "done" then return "Done"
    elseif state == "stopped" then return "Stopped"
    else return "" end
end
```

**Step 4: Add cycling button to BuffBot.menu**

In `BuffBot.menu`, in the "Action buttons + status" section (after the Stop button at line 381, before the Close button at line 385), add:

```
	-- Quick Cast cycling button
	button
	{
		enabled "buffbot_isOpen"
		action  "BfBot.UI.CycleQuickCast()"
		text lua "BfBot.UI._QuickCastLabel()"
		text style "button"
		text color lua "BfBot.UI._QuickCastColor()"
		tooltip lua "BfBot.UI._QuickCastTooltip()"
		bam     "GUIOSTUL"
		scaleToClip
		area 622 468 162 28
	}
```

This places it between the Stop button (ends at x=616) and Close button. Shift the Close button right to make room:

Change Close button area from `area 790 468 80 28` to `area 790 468 80 28` (already fits — 622+162=784, close at 790 has 6px gap).

**Step 5: Commit**

```bash
git add src/BfBotUI.lua src/BuffBot.menu
git commit -m "feat: Quick Cast cycling button in config panel"
```

---

### Task 4: Innate handler — pass qcMode through F12 path

**Files:**
- Modify: `src/BfBotInn.lua:232-255` (`BFBOTGO` handler)

**Step 1: Update BFBOTGO to read and pass qcMode**

Replace the queue-building section of `BFBOTGO` (around line 251-254):

```lua
    local queue = BfBot.Persist.BuildQueueForCharacter(slot, presetIdx)
    if queue and #queue > 0 then
        local qcMode = BfBot.Persist.GetQuickCast(sprite, presetIdx)
        BfBot.Exec.Start(queue, qcMode)
    end
```

**Step 2: Commit**

```bash
git add src/BfBotInn.lua
git commit -m "feat: innate abilities pass quick cast mode to execution engine"
```

---

### Task 5: Tests

**Files:**
- Modify: `src/BfBotTst.lua` (add new test section before final module loaded comment)

**Step 1: Add Quick Cast test function**

Before the "Module loaded" comment at the end of `BfBotTst.lua` (line 1250), add:

```lua
-- ============================================================
-- BfBot.Test.QuickCast — Quick Cast feature tests
-- ============================================================

function BfBot.Test.QuickCast()
    _reset()
    P("")
    P("========================================")
    P("  Quick Cast Tests")
    P("========================================")
    P("")

    local sprite = EEex_Sprite_GetInPortrait(0)
    if not sprite then
        _nok("No party member in slot 0")
        return _summary("Quick Cast")
    end

    -- ---- Test 1: Schema migration (v3 -> v4) ----
    P("  [1] Schema migration v3->v4")

    local oldConfig = {
        v = 3, ap = 1,
        presets = {
            [1] = { name = "Long Buffs", cat = "long", spells = {} },
            [2] = { name = "Short Buffs", cat = "short", spells = {} },
        },
        opts = { skip = 1, cheat = 1 },
    }
    local migrated = BfBot.Persist._MigrateConfig(oldConfig, 3)
    if migrated.v == 4 then _ok("Version bumped to 4")
    else _nok("Version: " .. tostring(migrated.v)) end

    if migrated.presets[1].qc == 2 then _ok("Preset 1 qc=2 (from opts.cheat=1)")
    else _nok("Preset 1 qc=" .. tostring(migrated.presets[1].qc)) end

    if migrated.presets[2].qc == 2 then _ok("Preset 2 qc=2 (from opts.cheat=1)")
    else _nok("Preset 2 qc=" .. tostring(migrated.presets[2].qc)) end

    if migrated.opts.cheat == nil then _ok("opts.cheat removed after migration")
    else _nok("opts.cheat still present: " .. tostring(migrated.opts.cheat)) end

    -- Migration with cheat=0
    local oldConfig2 = {
        v = 3, ap = 1,
        presets = { [1] = { name = "P1", cat = "long", spells = {} } },
        opts = { skip = 1, cheat = 0 },
    }
    local migrated2 = BfBot.Persist._MigrateConfig(oldConfig2, 3)
    if migrated2.presets[1].qc == 0 then _ok("cheat=0 -> qc=0")
    else _nok("cheat=0 migration: qc=" .. tostring(migrated2.presets[1].qc)) end

    -- ---- Test 2: Quick Cast accessors ----
    P("")
    P("  [2] Quick Cast accessors")

    -- Ensure config exists
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then
        _nok("No config for sprite"); return _summary("Quick Cast")
    end

    BfBot.Persist.SetQuickCast(sprite, 1, 0)
    if BfBot.Persist.GetQuickCast(sprite, 1) == 0 then _ok("SetQuickCast(0) round-trip")
    else _nok("SetQuickCast(0) failed") end

    BfBot.Persist.SetQuickCast(sprite, 1, 1)
    if BfBot.Persist.GetQuickCast(sprite, 1) == 1 then _ok("SetQuickCast(1) round-trip")
    else _nok("SetQuickCast(1) failed") end

    BfBot.Persist.SetQuickCast(sprite, 1, 2)
    if BfBot.Persist.GetQuickCast(sprite, 1) == 2 then _ok("SetQuickCast(2) round-trip")
    else _nok("SetQuickCast(2) failed") end

    -- Clamp test
    BfBot.Persist.SetQuickCast(sprite, 1, 5)
    if BfBot.Persist.GetQuickCast(sprite, 1) == 2 then _ok("SetQuickCast(5) clamped to 2")
    else _nok("Clamp failed: " .. tostring(BfBot.Persist.GetQuickCast(sprite, 1))) end

    BfBot.Persist.SetQuickCast(sprite, 1, -1)
    if BfBot.Persist.GetQuickCast(sprite, 1) == 0 then _ok("SetQuickCast(-1) clamped to 0")
    else _nok("Clamp failed: " .. tostring(BfBot.Persist.GetQuickCast(sprite, 1))) end

    -- Reset
    BfBot.Persist.SetQuickCast(sprite, 1, 0)

    -- ---- Test 3: Default config has qc=0 ----
    P("")
    P("  [3] Default config qc field")

    local defCfg = BfBot.Persist.GetDefaultConfig()
    if defCfg.presets[1].qc == 0 then _ok("Default preset 1 qc=0")
    else _nok("Default preset 1 qc=" .. tostring(defCfg.presets[1].qc)) end

    if defCfg.presets[2].qc == 0 then _ok("Default preset 2 qc=0")
    else _nok("Default preset 2 qc=" .. tostring(defCfg.presets[2].qc)) end

    -- ---- Test 4: Validation repairs invalid qc ----
    P("")
    P("  [4] Validation repairs qc")

    local badConfig = BfBot.Persist.GetDefaultConfig()
    badConfig.presets[1].qc = 99
    badConfig.presets[2].qc = nil
    local repaired = BfBot.Persist._ValidateConfig(badConfig)
    if repaired.presets[1].qc == 0 then _ok("qc=99 repaired to 0")
    else _nok("qc=99 not repaired: " .. tostring(repaired.presets[1].qc)) end

    if repaired.presets[2].qc == 0 then _ok("qc=nil repaired to 0")
    else _nok("qc=nil not repaired: " .. tostring(repaired.presets[2].qc)) end

    -- ---- Test 5: Boolean safety (qc should never be boolean) ----
    P("")
    P("  [5] Boolean safety for qc")

    local boolConfig = BfBot.Persist.GetDefaultConfig()
    boolConfig.presets[1].qc = true  -- WRONG — should be number
    BfBot.Persist._SanitizeValues(boolConfig)
    if boolConfig.presets[1].qc == 1 then _ok("Boolean qc=true sanitized to 1")
    else _nok("Boolean qc not sanitized: " .. tostring(boolConfig.presets[1].qc)) end

    -- ---- Test 6: SPL file generation ----
    P("")
    P("  [6] Cheat SPL files")

    local cheatData = BfBot.Innate._BuildCheatSPL()
    if type(cheatData) == "string" and #cheatData == 250 then
        _ok("BFBTCH.SPL: 250 bytes")
    else
        _nok("BFBTCH.SPL: " .. type(cheatData) .. " " .. tostring(cheatData and #cheatData))
    end

    -- Verify signature
    if cheatData:sub(1, 4) == "SPL " then _ok("BFBTCH signature OK")
    else _nok("BFBTCH bad signature: " .. cheatData:sub(1, 4)) end

    local removerData = BfBot.Innate._BuildCheatRemoverSPL()
    if type(removerData) == "string" and #removerData == 202 then
        _ok("BFBTCR.SPL: 202 bytes")
    else
        _nok("BFBTCR.SPL: " .. type(removerData) .. " " .. tostring(removerData and #removerData))
    end

    if removerData:sub(1, 4) == "SPL " then _ok("BFBTCR signature OK")
    else _nok("BFBTCR bad signature: " .. removerData:sub(1, 4)) end

    -- ---- Summary ----
    P("")
    return _summary("Quick Cast")
end
```

**Step 2: Update existing tests for schema v4**

In the Persist test section, update the default config test (around line 801-802):
- Remove: `if defCfg.opts and defCfg.opts.cheat == 0 then _ok("opts.cheat = 0")`
- Add: `if defCfg.presets[1].qc == 0 then _ok("preset 1 qc = 0")`

Update the boolean test for opts (line 958-962):
- Remove: the `SetOpt(sprite, "cheat", true)` / `SetOpt(sprite, "cheat", 0)` test
- These are no longer relevant since opts.cheat no longer exists

Update the corrupt config boolean test (line 986):
- Remove: `corrupt3.opts.cheat = false`

**Step 3: Add `QuickCast` to `RunAll`**

Find the `RunAll` function and add `BfBot.Test.QuickCast()` call after the existing test phases.

**Step 4: Commit**

```bash
git add src/BfBotTst.lua
git commit -m "test: add Quick Cast test suite, update persistence tests for schema v4"
```

---

### Task 6: Update CLAUDE.md + deploy + verify + final commit

**Files:**
- Modify: `CLAUDE.md` (document cheat mode in Current Phase and Execution Engine sections)

**Step 1: Update CLAUDE.md**

Add Quick Cast documentation to the relevant sections:
- Current Phase: note Quick Cast feature is implemented
- Execution Engine Details: document qcMode parameter and two-pass splitting
- Config schema: update to v4, document qc field
- UI Details: document cycling button

**Step 2: Deploy and test in-game**

Run: `bash tools/deploy.sh`
Start game, load a save, run in EEex console:
```
BfBot.Test.QuickCast()
```
Expected: All tests pass.

Then test the full flow:
```
BfBot.Test.RunAll()
```
Expected: All existing tests still pass + new Quick Cast tests pass.

Manual in-game verification:
1. Open BuffBot panel (F11)
2. Verify "Quick Cast: Off" button appears near Cast/Stop
3. Click it — cycles to "Quick Cast: Long" (yellow text)
4. Click again — cycles to "Quick Cast: All" (red/orange text)
5. Click again — back to "Quick Cast: Off" (white text)
6. Set to "Long", press Cast — verify execution log shows "Quick Cast ON" / "Quick Cast OFF" transitions
7. Set to "All", press Cast — verify all spells cast with IA (very fast)
8. Test Stop during cheat mode — verify IA is cleaned up

**Step 3: Final commit**

```bash
git add CLAUDE.md
git commit -m "docs: document Quick Cast feature in CLAUDE.md"
```
