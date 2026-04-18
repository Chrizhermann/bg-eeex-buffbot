# Spell Position Lock Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Goal:** Let users pin a spell's row within a preset so Sort by Duration and Move Up/Down respect the lock. State persists per-preset.

**Architecture:** Add `spellCfg.lock` (0/1) to each preset spell entry (schema v5→v6). `SortByDuration` partitions the display table into locked (keyed by row index) and unlocked (ordered) sets, sorts only the unlocked list, and rebuilds keeping locked entries at their row indices. `_FindNextUnlocked` lets Move Up/Down skip past locked rows; locked spells themselves are immovable. UI exposes a new 7th column to the right of the spell list — direct-click toggles the lock.

**Tech Stack:** Lua 5.1 (EEex), `.menu` DSL, WeiDU installer (no build step — deploy via `bash tools/deploy.sh`). Tests run in-game via `BfBot.Test.<Name>()` in the EEex console.

**Reference docs:**
- Design: `docs/plans/2026-04-18-spell-lock-design.md`
- Menu patterns: `~/.claude/skills/bg-modding/references/menu-patterns.md`
- Persistence: `~/.claude/skills/bg-modding/references/eeex-persistence.md`

---

## Task 1: Bump schema version + extend validator, migration, default entry

**Files:**
- Modify: `buffbot/BfBotPer.lua:10` (`_SCHEMA_VERSION`)
- Modify: `buffbot/BfBotPer.lua:68` (`_MakeDefaultSpellEntry`)
- Modify: `buffbot/BfBotPer.lua:213-238` (per-spell validation block in `_ValidateConfig`)
- Modify: `buffbot/BfBotPer.lua:269-288` (`_MigrateConfig`)

**Step 1: Bump schema version**

Change line 10:

```lua
BfBot.Persist._SCHEMA_VERSION = 6
```

**Step 2: Default `lock = 0` in new spell entries**

Replace `_MakeDefaultSpellEntry` return (line 68):

```lua
return { on = (enabled == 0) and 0 or 1, tgt = tgt, pri = 999, lock = 0 }
```

**Step 3: Validate `lock` in `_ValidateConfig`**

In the per-entry validation block (between `if type(entry.pri) ~= "number" then entry.pri = 999 end` at line 237 and the closing `end`s), add:

```lua
if type(entry.lock) ~= "number" or (entry.lock ~= 0 and entry.lock ~= 1) then
    entry.lock = 0
end
```

**Step 4: Add v5→v6 migration branch**

In `_MigrateConfig`, below the `if fromVersion < 5 then ... end` block at line 285, add:

```lua
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
```

**Step 5: Commit**

```bash
git add buffbot/BfBotPer.lua
git commit -m "feat(persist): schema v6 adds spell lock field"
```

---

## Task 2: Add `GetSpellLock` / `SetSpellLock` persistence API

**Files:**
- Modify: `buffbot/BfBotPer.lua:480-491` (insert near `SetSpellPriority` and `GetSpellConfig`)

**Step 1: Add the API functions**

Insert after `SetSpellPriority` (currently at line 480) and before `GetSpellConfig`:

```lua
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
```

**Step 2: Commit**

```bash
git add buffbot/BfBotPer.lua
git commit -m "feat(persist): add GetSpellLock/SetSpellLock API"
```

---

## Task 3: Write `BfBot.Test.SpellLockPersist` (persistence layer)

**Files:**
- Modify: `buffbot/BfBotTst.lua` (append new function near the Override test, ~line 748)
- Modify: `buffbot/BfBotTst.lua` (`RunAll`, ~line 1826, add new phase)

**Step 1: Append the new test function**

After the `Override` test's closing `end` (line ~748), insert:

```lua
-- ============================================================
-- BfBot.Test.SpellLockPersist — Spell lock persistence
-- ============================================================

function BfBot.Test.SpellLockPersist()
    P("=== SpellLockPersist: persistence layer ===")
    _reset()

    local sprite = EEex_Sprite_GetInPortrait(0)
    if not sprite then
        _nok("No sprite in slot 0")
        return _summary("SpellLockPersist")
    end

    local config = BfBot.Persist.GetConfig(sprite)
    if not config then
        _nok("No config for slot 0")
        return _summary("SpellLockPersist")
    end

    -- Pick any real spell resref in preset 1
    local testResref = nil
    for resref, _ in pairs(config.presets[1].spells) do
        testResref = resref
        break
    end
    if not testResref then
        _warning("Preset 1 has no spells; skipping lock API test")
        return _summary("SpellLockPersist")
    end

    -- Test 1: Default lock = 0
    local initial = BfBot.Persist.GetSpellLock(sprite, 1, testResref)
    _check(initial == 0, "Default lock is 0 for " .. testResref)

    -- Test 2: SetSpellLock(1) persists
    BfBot.Persist.SetSpellLock(sprite, 1, testResref, 1)
    local afterSet = BfBot.Persist.GetSpellLock(sprite, 1, testResref)
    _check(afterSet == 1, "Lock set to 1 reads back as 1")

    -- Test 3: SetSpellLock(0) resets
    BfBot.Persist.SetSpellLock(sprite, 1, testResref, 0)
    local afterReset = BfBot.Persist.GetSpellLock(sprite, 1, testResref)
    _check(afterReset == 0, "Lock reset to 0 reads back as 0")

    -- Test 4: Validator defaults missing lock to 0
    local dirty = {
        v = 6, ap = 1,
        presets = {
            [1] = {
                name = "Test", cat = "custom",
                spells = {
                    ["TSTABC"] = { on = 1, tgt = "s", pri = 1 }, -- no lock field
                },
            },
            [2] = { name = "Two", cat = "custom", spells = {} },
        },
    }
    local repaired = BfBot.Persist._ValidateConfig(dirty)
    _check(repaired.presets[1].spells["TSTABC"].lock == 0,
           "Validator defaults missing lock to 0")

    -- Test 5: Validator rejects non-0/1 lock
    local weird = {
        v = 6, ap = 1,
        presets = {
            [1] = {
                name = "Test", cat = "custom",
                spells = {
                    ["TSTABC"] = { on = 1, tgt = "s", pri = 1, lock = 42 },
                    ["TSTDEF"] = { on = 1, tgt = "s", pri = 2, lock = "yes" },
                },
            },
            [2] = { name = "Two", cat = "custom", spells = {} },
        },
    }
    local cleaned = BfBot.Persist._ValidateConfig(weird)
    _check(cleaned.presets[1].spells["TSTABC"].lock == 0,
           "Validator zeroes non-0/1 numeric lock")
    _check(cleaned.presets[1].spells["TSTDEF"].lock == 0,
           "Validator zeroes string lock")

    -- Test 6: v5→v6 migration preserves existing fields and adds lock=0
    local v5 = {
        v = 5, ap = 1,
        presets = {
            [1] = {
                name = "Legacy", cat = "long", qc = 0,
                spells = {
                    ["TSTLEG"] = { on = 1, tgt = "s", pri = 3 },
                },
            },
            [2] = { name = "Two", cat = "short", qc = 0, spells = {} },
        },
        opts = { skip = 1 }, ovr = {},
    }
    local migrated = BfBot.Persist._MigrateConfig(v5, v5.v)
    _check(migrated.v == 6, "Migration bumps version to 6")
    _check(migrated.presets[1].spells["TSTLEG"].lock == 0,
           "Migration adds lock=0 to legacy entries")
    _check(migrated.presets[1].spells["TSTLEG"].on == 1,
           "Migration preserves 'on' field")
    _check(migrated.presets[1].spells["TSTLEG"].pri == 3,
           "Migration preserves 'pri' field")

    return _summary("SpellLockPersist")
end
```

**Step 2: Wire into `RunAll`**

In `RunAll` (around line 1826, after the SubwindowDetection phase), add:

```lua
    -- Phase N: Spell Lock Persistence
    local lockOk = BfBot.Test.SpellLockPersist()
    P("")
```

Also add `lockOk` to the final summary tally (find the `or not lockOk` pattern at the end — the code already aggregates results; if there's no aggregate, add the variable to the existing pattern). Inspect `RunAll` structure before editing.

**Step 3: Commit**

```bash
git add buffbot/BfBotTst.lua
git commit -m "test(persist): add SpellLockPersist test coverage"
```

---

## Task 4: Deploy + verify persistence layer in-game

**Step 1: Deploy**

```bash
bash tools/deploy.sh
```

Expected output: `DEPLOY OK` (or equivalent success message).

**Step 2: Launch game, run test**

Load an existing save. In the EEex Lua console:

```lua
BfBot.Test.SpellLockPersist()
```

Expected: all `PASS` lines, `--- SpellLockPersist: N pass, 0 fail, ... ---`.

**Step 3: Stop — do not proceed if any test fails.**

If failures: inspect the test output, fix the corresponding code, redeploy, rerun. Repeat until clean.

---

## Task 5: Extend `_Refresh` row build with `lock` field

**Files:**
- Modify: `buffbot/BfBotUI.lua:743-765` (row constructor in `_Refresh`)

**Step 1: Add `lock` to the row table**

In the `table.insert(rows, { ... })` block (line 743), add a new field next to `tgtUnlock`:

```lua
tgtUnlock = spellCfg.tgtUnlock or 0,
lock      = spellCfg.lock or 0,
hasVariants = hasVariants,
```

**Step 2: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): expose lock field on spell table rows"
```

---

## Task 6: Rewrite `SortByDuration` — pin-in-place

**Files:**
- Modify: `buffbot/BfBotUI.lua:1260-1273`

**Step 1: Replace the function body**

Replace the existing `SortByDuration` (lines 1260-1273) with:

```lua
--- Sort the current preset's spell list by duration (longest first).
--- Locked spells stay at their current row index. Unlocked spells fill
--- the remaining rows in duration-desc order. Persists via _RenumberPriorities.
function BfBot.UI.SortByDuration()
    local n = #buffbot_spellTable
    if n == 0 then return end

    local function durKey(entry)
        local d = entry.dur
        if d == nil then return -2 end
        if d == -1 then return 1e9 end  -- permanent sorts first
        return d
    end

    -- Partition: keep locked entries pinned to their row indices
    local locked = {}   -- [row] = entry
    local unlocked = {} -- ordered list
    for i, entry in ipairs(buffbot_spellTable) do
        if entry.lock == 1 then
            locked[i] = entry
        else
            table.insert(unlocked, entry)
        end
    end

    -- Sort unlocked by duration desc
    table.sort(unlocked, function(a, b) return durKey(a) > durKey(b) end)

    -- Rebuild: locked at their row, unlocked fill the gaps
    local result = {}
    local uIdx = 1
    for i = 1, n do
        if locked[i] then
            result[i] = locked[i]
        else
            result[i] = unlocked[uIdx]
            uIdx = uIdx + 1
        end
    end
    buffbot_spellTable = result
    BfBot.UI._RenumberPriorities()
end
```

**Step 2: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): pin-in-place sort respects locked rows"
```

---

## Task 7: Add `_FindNextUnlocked` + update `_CanMoveUp/Down` + `MoveSpellUp/Down`

**Files:**
- Modify: `buffbot/BfBotUI.lua:1226-1258`

**Step 1: Add the helper (insert above `_CanMoveUp`, at line 1226)**

```lua
--- Return the next row in `direction` (+1 down, -1 up) whose entry is
--- not locked, or nil if none exists within bounds.
function BfBot.UI._FindNextUnlocked(startRow, direction)
    local n = #buffbot_spellTable
    local row = startRow + direction
    while row >= 1 and row <= n do
        local e = buffbot_spellTable[row]
        if e and e.lock ~= 1 then return row end
        row = row + direction
    end
    return nil
end
```

**Step 2: Replace `_CanMoveUp` and `_CanMoveDown` (current lines 1227-1234)**

```lua
--- Can the selected spell move up? Selected must be unlocked and have an
--- unlocked row above it.
function BfBot.UI._CanMoveUp()
    if not buffbot_isOpen then return false end
    local row = buffbot_selectedRow
    if row <= 1 or row > #buffbot_spellTable then return false end
    local entry = buffbot_spellTable[row]
    if not entry or entry.lock == 1 then return false end
    return BfBot.UI._FindNextUnlocked(row, -1) ~= nil
end

--- Can the selected spell move down? Selected must be unlocked and have an
--- unlocked row below it.
function BfBot.UI._CanMoveDown()
    if not buffbot_isOpen then return false end
    local row = buffbot_selectedRow
    if row < 1 or row >= #buffbot_spellTable then return false end
    local entry = buffbot_spellTable[row]
    if not entry or entry.lock == 1 then return false end
    return BfBot.UI._FindNextUnlocked(row, 1) ~= nil
end
```

**Step 3: Replace `MoveSpellUp` and `MoveSpellDown` (current lines 1236-1258)**

```lua
--- Move the selected spell up to the next unlocked row.
function BfBot.UI.MoveSpellUp()
    local row = buffbot_selectedRow
    if row <= 1 or row > #buffbot_spellTable then return end
    local entry = buffbot_spellTable[row]
    if not entry or entry.lock == 1 then return end
    local target = BfBot.UI._FindNextUnlocked(row, -1)
    if not target then return end
    buffbot_spellTable[row], buffbot_spellTable[target] =
        buffbot_spellTable[target], buffbot_spellTable[row]
    BfBot.UI._RenumberPriorities()
    buffbot_selectedRow = target
end

--- Move the selected spell down to the next unlocked row.
function BfBot.UI.MoveSpellDown()
    local row = buffbot_selectedRow
    if row < 1 or row >= #buffbot_spellTable then return end
    local entry = buffbot_spellTable[row]
    if not entry or entry.lock == 1 then return end
    local target = BfBot.UI._FindNextUnlocked(row, 1)
    if not target then return end
    buffbot_spellTable[row], buffbot_spellTable[target] =
        buffbot_spellTable[target], buffbot_spellTable[row]
    BfBot.UI._RenumberPriorities()
    buffbot_selectedRow = target
end
```

**Step 4: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): Move Up/Down skip over locked rows"
```

---

## Task 8: Add `BfBot.Test.SpellLockOrder` (algorithm tests)

**Files:**
- Modify: `buffbot/BfBotTst.lua` (append new function near `SpellLockPersist`)
- Modify: `buffbot/BfBotTst.lua` (`RunAll`, add new phase)

**Step 1: Append the test function**

After `BfBot.Test.SpellLockPersist`, add:

```lua
-- ============================================================
-- BfBot.Test.SpellLockOrder — Sort and move semantics with locks
-- ============================================================

function BfBot.Test.SpellLockOrder()
    P("=== SpellLockOrder: sort + move with locks ===")
    _reset()

    -- Stub buffbot_spellTable directly; these algorithms are pure data ops.
    local saved = buffbot_spellTable
    local savedRow = buffbot_selectedRow
    local savedIsOpen = buffbot_isOpen
    buffbot_isOpen = true

    -- We stub _RenumberPriorities to a no-op since it needs a real sprite
    local savedRenum = BfBot.UI._RenumberPriorities
    BfBot.UI._RenumberPriorities = function() end

    -- Test 1: Sort pins locked rows
    buffbot_spellTable = {
        { resref = "A", dur = 10, lock = 0 },
        { resref = "B", dur = 20, lock = 1 },
        { resref = "C", dur = 30, lock = 0 },
        { resref = "D", dur = 15, lock = 0 },
    }
    BfBot.UI.SortByDuration()
    local order = table.concat({
        buffbot_spellTable[1].resref,
        buffbot_spellTable[2].resref,
        buffbot_spellTable[3].resref,
        buffbot_spellTable[4].resref,
    }, ",")
    _check(order == "C,B,D,A",
           "Sort pins B@2, unlocked sort desc: expected C,B,D,A; got " .. order)

    -- Test 2: Sort with all locked = no change
    buffbot_spellTable = {
        { resref = "A", dur = 10, lock = 1 },
        { resref = "B", dur = 20, lock = 1 },
    }
    BfBot.UI.SortByDuration()
    _check(buffbot_spellTable[1].resref == "A" and buffbot_spellTable[2].resref == "B",
           "Sort with all locked preserves order")

    -- Test 3: Sort with all unlocked = normal sort
    buffbot_spellTable = {
        { resref = "A", dur = 10, lock = 0 },
        { resref = "B", dur = 30, lock = 0 },
        { resref = "C", dur = 20, lock = 0 },
    }
    BfBot.UI.SortByDuration()
    _check(buffbot_spellTable[1].resref == "B" and
           buffbot_spellTable[2].resref == "C" and
           buffbot_spellTable[3].resref == "A",
           "Sort all unlocked sorts desc by dur")

    -- Test 4: _FindNextUnlocked skips locked rows
    buffbot_spellTable = {
        { resref = "A", lock = 0 },
        { resref = "B", lock = 1 },
        { resref = "C", lock = 1 },
        { resref = "D", lock = 0 },
    }
    _check(BfBot.UI._FindNextUnlocked(1, 1) == 4,
           "_FindNextUnlocked skips two locked rows going down")
    _check(BfBot.UI._FindNextUnlocked(4, -1) == 1,
           "_FindNextUnlocked skips two locked rows going up")
    _check(BfBot.UI._FindNextUnlocked(4, 1) == nil,
           "_FindNextUnlocked returns nil past end")
    _check(BfBot.UI._FindNextUnlocked(1, -1) == nil,
           "_FindNextUnlocked returns nil before start")

    -- Test 5: _CanMoveUp/Down false for locked selected
    buffbot_spellTable = {
        { resref = "A", lock = 0 },
        { resref = "B", lock = 1 },
        { resref = "C", lock = 0 },
    }
    buffbot_selectedRow = 2
    _check(not BfBot.UI._CanMoveUp(),   "_CanMoveUp false for locked selected")
    _check(not BfBot.UI._CanMoveDown(), "_CanMoveDown false for locked selected")

    -- Test 6: MoveSpellDown skips locked row
    buffbot_spellTable = {
        { resref = "A", lock = 0 },
        { resref = "B", lock = 1 },
        { resref = "C", lock = 0 },
    }
    buffbot_selectedRow = 1
    BfBot.UI.MoveSpellDown()
    _check(buffbot_spellTable[1].resref == "C" and
           buffbot_spellTable[2].resref == "B" and
           buffbot_spellTable[3].resref == "A",
           "MoveSpellDown skips locked: A→3, C→1, B stays at 2")
    _check(buffbot_selectedRow == 3, "Selection follows moved spell")

    -- Test 7: MoveSpellUp past locked
    buffbot_spellTable = {
        { resref = "A", lock = 0 },
        { resref = "B", lock = 1 },
        { resref = "C", lock = 0 },
    }
    buffbot_selectedRow = 3
    BfBot.UI.MoveSpellUp()
    _check(buffbot_spellTable[1].resref == "C" and
           buffbot_spellTable[2].resref == "B" and
           buffbot_spellTable[3].resref == "A",
           "MoveSpellUp skips locked: C→1, A→3")

    -- Restore globals
    buffbot_spellTable = saved
    buffbot_selectedRow = savedRow
    buffbot_isOpen = savedIsOpen
    BfBot.UI._RenumberPriorities = savedRenum

    return _summary("SpellLockOrder")
end
```

**Step 2: Wire into `RunAll`**

Add a phase after `SpellLockPersist`:

```lua
    -- Phase N+1: Spell Lock Order
    local lockOrderOk = BfBot.Test.SpellLockOrder()
    P("")
```

**Step 3: Deploy and run the test**

```bash
bash tools/deploy.sh
```

In-game console:

```lua
BfBot.Test.SpellLockOrder()
```

Expected: all PASS.

**Step 4: Commit**

```bash
git add buffbot/BfBotTst.lua
git commit -m "test(ui): sort pinning and move skip-over for locked rows"
```

---

## Task 9: Add UI helpers — `ToggleLock`, `_LockText`, `_LockColor`

**Files:**
- Modify: `buffbot/BfBotUI.lua` (insert near `_CheckboxText`, ~line 1580)

**Step 1: Add the three functions**

After `_CheckboxText` (line 1580), insert:

```lua
--- Lock column display text.
function BfBot.UI._LockText(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.lock == 1 then return "[L]" end
    return "[ ]"
end

--- Lock column color: gold when locked, muted otherwise.
function BfBot.UI._LockColor(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.lock == 1 then return {230, 200, 60} end
    return {120, 100, 80}
end

--- Toggle the lock state on a spell row.
function BfBot.UI.ToggleLock(row)
    local entry = buffbot_spellTable[row]
    if not entry then return end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end
    local newState = (entry.lock == 1) and 0 or 1
    entry.lock = newState  -- immediate visual update
    BfBot.Persist.SetSpellLock(sprite, BfBot.UI._presetIdx, entry.resref, newState)
end
```

**Step 2: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): ToggleLock + lock column view helpers"
```

---

## Task 10: Menu — add 7th lock column, shrink target column, extend cellNumber dispatch

**Files:**
- Modify: `buffbot/BuffBot.menu:417-428` (column 6 "Target display" — shrink width 32 → 26)
- Modify: `buffbot/BuffBot.menu` (insert new column between columns 6 and the `area ... name "bbList"` line at 430)
- Modify: `buffbot/BuffBot.menu:432` (list `action` callback — extend cellNumber dispatch)

**Step 1: Shrink target column width**

In the target display column (line ~418-428), change `width 32` to `width 26`.

**Step 2: Insert new lock column**

Immediately before `area 350 148 520 250` (the list properties at line 430), insert:

```
		-- Column 7: Lock toggle ([L] / [ ])
		column
		{
			width 6
			label
			{
				area 0 0 -1 36
				text lua "BfBot.UI._LockText(rowNumber)"
				text style "normal_parchment"
				text align center center
				text color lua "BfBot.UI._LockColor(rowNumber)"
			}
		}
```

Verify column widths total 100: `8 + 8 + 28 + 12 + 12 + 26 + 6 = 100`. ✓

**Step 3: Extend list action dispatch**

Replace line 432 `action "BfBot.UI._UpdateVariantState(); if cellNumber <= 2 then BfBot.UI.ToggleSpell(buffbot_selectedRow) end"` with:

```
		action      "BfBot.UI._UpdateVariantState(); if cellNumber <= 2 then BfBot.UI.ToggleSpell(buffbot_selectedRow) elseif cellNumber == 7 then BfBot.UI.ToggleLock(buffbot_selectedRow) end"
```

**Step 4: Commit**

```bash
git add buffbot/BuffBot.menu
git commit -m "feat(menu): add lock column to spell list"
```

---

## Task 11: Extend `_SpellNameColor` with locked tint

**Files:**
- Modify: `buffbot/BfBotUI.lua:1567-1573`

**Step 1: Add locked branch**

Replace the function body with:

```lua
--- Spell name color: grey for unavailable, dark blue for manual include,
--- gold-tinted for locked, dark brown for normal.
function BfBot.UI._SpellNameColor(row)
    local entry = buffbot_spellTable[row]
    if not entry then return {50, 30, 10} end
    if entry.castable == 0 then return {140, 130, 120} end
    if entry.ovr == 1 then return {40, 80, 160} end
    if entry.lock == 1 then return {100, 70, 20} end  -- warm gold-brown
    return {50, 30, 10}
end
```

The locked tint stays in the warm/parchment palette so it reads as "pinned" without clashing with the cool blue of include-override.

**Step 2: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "polish(ui): tint locked spell names"
```

---

## Task 12: Deploy + end-to-end in-game smoke test

**Step 1: Deploy**

```bash
bash tools/deploy.sh
```

**Step 2: Run the full test suite**

In-game console:

```lua
BfBot.Test.RunAll()
```

Expected: all phases pass, including `SpellLockPersist` and `SpellLockOrder`.

**Step 3: Manual UI smoke test**

Open BuffBot (F11 or actionbar button). On the active character/preset:

1. Click `[ ]` in the new rightmost column on any spell row → it flips to `[L]` in gold, and the spell name takes the locked tint.
2. Click Sort → verify the locked spell stays at its row while others reorder.
3. Select a locked row → Move Up/Down grays out.
4. Select an unlocked row adjacent to a locked one → Move Up/Down is enabled; clicking it swaps past the locked row.
5. Switch presets and back → lock state persists.
6. Save + reload the game → lock state persists across save/load.
7. Click the locked `[L]` cell → it flips back to `[ ]` and the name tint reverts.

**Step 4: Stop — do not proceed until all seven manual checks pass.**

---

## Task 13: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` (Alpha feature list + Persistence Details section)

**Step 1: Add bullet to Alpha feature list**

In `CLAUDE.md`, insert a new bullet among the Alpha features (order: near "Manual Cast Order"):

```markdown
- **Spell Position Lock** (`BfBot.UI.ToggleLock` + `BfBot.Persist.Get/SetSpellLock`) — per-preset, per-spell row lock. Locked spells stay at their row during Sort by Duration. Move Up/Down skips over locked rows and cannot move a locked spell. UI: 7th column on the right of the spell list, `[L]` / `[ ]` direct click to toggle. Persists in save games via schema v6.
```

**Step 2: Bump schema version note**

Find the "Config schema (v5)" text and update to "v6":

```markdown
- **Config schema** (v6): `{v=6, ap=1, presets={[1]={name,cat,qc=0,spells={[resref]={on,tgt,pri,tgtUnlock,lock}}}, [2]={...}}, opts={skip=1}, ovr={[resref]=1|-1}}` — ... `lock` (optional, 0/1) pins a spell's row position during Sort and prevents Move Up/Down.
```

Update any other v5 references in the file to v6. Grep first: `Grep pattern="v5|v=5"`.

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): document spell position lock (schema v6)"
```

---

## Task 14: Update memory

**Step 1: Update MEMORY.md status note**

Bump the schema version mention in `~/.claude/projects/C--src-private-bg-eeex-buffbot/memory/MEMORY.md`:

- Change `(BfBotPer, schema v5)` to `(BfBotPer, schema v6)`
- Update the "Config schema" line similarly

No code commit needed — memory is outside the repo.

---

## Summary

14 tasks, most 2-5 minutes each. TDD cycle is enforced for the pure-data layers (persistence, sort algorithm, move semantics); UI rendering tasks rely on the in-game smoke test at Task 12. All commits are small and focused. Schema bump to v6 is backward-compatible (missing `lock` field → 0 via validator).

**Total new code:** ~200 lines (persistence API ~20, validator/migration ~15, sort/move ~60, UI helpers ~30, menu column ~15, tests ~75). One column shrink in the menu.

**Rollback plan:** Revert the commits in reverse order. The schema v6 bump is safe — older builds reading v6 configs via `_ValidateConfig` will keep the extra `lock` field (ignored) until the version is noticed by the migration path.
