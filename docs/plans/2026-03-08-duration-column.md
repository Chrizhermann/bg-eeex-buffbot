# Duration Column Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a duration column to the spell list showing per-caster-level durations, and fix the shared classification cache bug where duration was keyed by resref instead of per-sprite.

**Architecture:** Move `duration`/`durCat` from classification cache (resref-keyed) to scan entries (per-sprite). Add format helper and new list column in UI. Propagate `durCat` through queue entries for Quick Cast.

**Tech Stack:** Lua (EEex), .menu DSL (Infinity Engine UI)

---

### Task 1: Move duration from classification to scan entry

**Files:**
- Modify: `buffbot/BfBotScn.lua:54-63` (_buildSpellEntry return table)
- Modify: `buffbot/BfBotCls.lua:536-538` (Classify override path)
- Modify: `buffbot/BfBotCls.lua:594-596` (Classify normal path)

**Step 1: Add duration fields to scan entry**

In `buffbot/BfBotScn.lua`, after classification (line 52), compute duration from the ability already resolved for this caster's level. Add `duration` and `durCat` to the returned table:

```lua
    -- Compute duration from ability (per caster level, not from classification cache)
    local duration = 0
    local durCat = "instant"
    if header and ability then
        duration = BfBot.Class.GetDuration(header, ability)
        durCat = BfBot.Class.GetDurationCategory(duration)
    end

    return {
        resref = resref,
        name = name,
        icon = icon or "",
        count = count or 0,
        level = header and header.spellLevel or 0,
        spellType = spellType,
        disabled = (disabled and disabled ~= 0) or false,
        class = classResult,
        duration = duration,
        durCat = durCat,
    }
```

**Step 2: Remove duration from classification result**

In `buffbot/BfBotCls.lua`, remove duration computation from BOTH paths in `Classify()`:

Override path (lines 536-538) — remove these two lines:
```lua
        result.duration, _ = BfBot.Class.GetDuration(header, ability)
        result.durCat = BfBot.Class.GetDurationCategory(result.duration)
```

Keep the comment line 536 but change it to:
```lua
        -- Duration computed per-sprite in scan entry, not here (classification is resref-level)
```

Normal path (lines 594-596) — same removal:
```lua
    -- Duration
    result.duration, _ = BfBot.Class.GetDuration(header, ability)
    result.durCat = BfBot.Class.GetDurationCategory(result.duration)
```

Replace with:
```lua
    -- Duration computed per-sprite in scan entry, not here (classification is resref-level)
```

**Step 3: Commit**

```bash
git add buffbot/BfBotScn.lua buffbot/BfBotCls.lua
git commit -m "refactor: move duration from classification cache to per-sprite scan entry"
```

---

### Task 2: Update Persist consumers

**Files:**
- Modify: `buffbot/BfBotPer.lua:90-91` (_CreateDefaultConfig buff collection)
- Modify: `buffbot/BfBotPer.lua:588-595` (BuildQueueFromPreset queue entry)
- Modify: `buffbot/BfBotPer.lua:839-843` (BuildQueueForCharacter queue entry)

**Step 1: Fix _CreateDefaultConfig field paths**

Lines 90-91, change:
```lua
                duration  = data.class.duration or 0,
                durCat    = data.class.durCat or "short",
```
To:
```lua
                duration  = data.duration or 0,
                durCat    = data.durCat or "short",
```

**Step 2: Add durCat to BuildQueueFromPreset queue entries**

Lines 590-594, change:
```lua
            table.insert(queue, {
                caster = e.caster,
                spell  = e.spell,
                target = e.target,
            })
```
To:
```lua
            local scanData = castable[e.spell]
            table.insert(queue, {
                caster = e.caster,
                spell  = e.spell,
                target = e.target,
                durCat = scanData and scanData.durCat or "short",
            })
```

**Step 3: Add durCat to BuildQueueForCharacter queue entries**

Lines 839-843, change:
```lua
        table.insert(queue, {
            caster = e.caster,
            spell  = e.spell,
            target = e.target,
        })
```
To:
```lua
        local scanData = castable[e.spell]
        table.insert(queue, {
            caster = e.caster,
            spell  = e.spell,
            target = e.target,
            durCat = scanData and scanData.durCat or "short",
        })
```

**Step 4: Commit**

```bash
git add buffbot/BfBotPer.lua
git commit -m "refactor: read duration from scan entry, add durCat to queue entries"
```

---

### Task 3: Update Exec consumer

**Files:**
- Modify: `buffbot/BfBotExe.lua:162-163` (cheat tagging)

**Step 1: Read durCat from queue entry instead of classResult**

Lines 161-163, change:
```lua
        elseif qcMode == 1 then
            local durCat = classResult and classResult.durCat or "short"
            isCheat = (durCat == "permanent" or durCat == "long")
```
To:
```lua
        elseif qcMode == 1 then
            local durCat = entry.durCat or "short"
            isCheat = (durCat == "permanent" or durCat == "long")
```

Note: `entry` here is the user queue entry from the `for i, entry in ipairs(userQueue)` loop at line 110.

**Step 2: Commit**

```bash
git add buffbot/BfBotExe.lua
git commit -m "refactor: read durCat from queue entry for Quick Cast tagging"
```

---

### Task 4: Add duration column to UI

**Files:**
- Modify: `buffbot/BfBotUI.lua:335-347` (_Refresh spell table rows)
- Modify: `buffbot/BfBotUI.lua:706-712` (_BuildPickerList)
- Add function: `buffbot/BfBotUI.lua` (new _FormatDuration, before _SpellNameColor)
- Modify: `buffbot/BuffBot.menu:319-357` (list columns)

**Step 1: Add _FormatDuration function**

Add before `_SpellNameColor` (find the `-- Spell Name Color` section):

```lua
--- Format a duration in seconds to a human-readable string.
--- Returns mixed format: "1h 30m", "5m", "1m 30s", "45s", "Perm", "Inst", "?"
function BfBot.UI._FormatDuration(seconds)
    if seconds == nil then return "?" end
    if seconds == -1 then return "Perm" end
    if seconds == 0 then return "Inst" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        if m > 0 then return h .. "h " .. m .. "m" end
        return h .. "h"
    end
    if m > 0 then
        if s > 0 then return m .. "m " .. s .. "s" end
        return m .. "m"
    end
    return s .. "s"
end
```

**Step 2: Add dur and durText to spell table rows in _Refresh**

In `_Refresh()` step 7 (lines 335-347), after the `if scan then` block extracts name/icon/count, also extract duration. Add `dur` and `durText` to the row:

After line 333 (`isCastable = ...`), add:
```lua
            dur = scan.duration
            durCat = scan.durCat
```

And declare `dur` and `durCat` as locals before the `if scan then` block:
```lua
        local dur = nil
        local durCat = "instant"
```

Add to the `table.insert(rows, {` block after `icon = icon,`:
```lua
            dur      = dur,
            durText  = BfBot.UI._FormatDuration(dur),
            durCat   = durCat,
```

**Step 3: Update picker durCat reference**

Line 710, change:
```lua
            durCat = scan.class.durCat or "?",
```
To:
```lua
            durCat = scan.durCat or "?",
```

**Step 4: Add duration column to BuffBot.menu**

Insert a new column between Column 3 (Name, width 40) and Column 4 (Count, width 12). Reduce Name width from 40 to 28 to make room:

Change Column 3 width (line 322):
```
			width 28
```

Insert new Column 4 (Duration) after the Name column closing `}` (after line 331):
```
		-- Column 4: Duration
		column
		{
			width 12
			label
			{
				area 0 0 -1 36
				text lua "buffbot_spellTable[rowNumber] and buffbot_spellTable[rowNumber].durText or ''"
				text style "normal"
				text align center center
			}
		}
```

Renumber comments: old Column 4 (Count) becomes Column 5, old Column 5 (Target) becomes Column 6.

**Step 5: Commit**

```bash
git add buffbot/BfBotUI.lua buffbot/BuffBot.menu
git commit -m "feat(ui): add duration column showing per-caster-level buff duration"
```

---

### Task 5: Update test output

**Files:**
- Modify: `buffbot/BfBotTst.lua:354-359` (scan test spell output)
- Modify: `buffbot/BfBotTst.lua:452-453` (classify detail output)
- Modify: `buffbot/BfBotTst.lua:839-840` (exec test buff collection)

**Step 1: Update scan test output**

Lines 354-359, change:
```lua
                local durStr = ""
                if entry.class then
                    durStr = entry.class.durCat or ""
                    if entry.class.duration and entry.class.duration > 0 then
                        durStr = durStr .. "(" .. entry.class.duration .. "s)"
                    elseif entry.class.duration == -1 then
                        durStr = durStr .. "(perm)"
                    end
                end
```
To:
```lua
                local durStr = entry.durCat or ""
                if entry.duration and entry.duration > 0 then
                    durStr = durStr .. "(" .. entry.duration .. "s)"
                elseif entry.duration == -1 then
                    durStr = durStr .. "(perm)"
                end
```

**Step 2: Update classify detail output**

Lines 452-453 reference `result.duration` and `result.durCat` from the classify result. Since classify no longer returns these, change to compute them on the spot for test display:

```lua
    -- Duration (computed from ability, not from classification result)
    local testDur = BfBot.Class.GetDuration(header, ability)
    local testDurCat = BfBot.Class.GetDurationCategory(testDur)
    P("  duration: " .. tostring(testDur) .. "s"
        .. " (" .. tostring(testDurCat) .. ")")
```

This requires `header` and `ability` to be in scope at this point. Check the surrounding test function to confirm they are (they should be — the classify test loads the SPL header and ability before calling Classify).

**Step 3: Update exec test buff collection**

Lines 839-840, change:
```lua
                    durCat = data.class.durCat or "?",
                    duration = data.class.duration or 0,
```
To:
```lua
                    durCat = data.durCat or "?",
                    duration = data.duration or 0,
```

**Step 4: Commit**

```bash
git add buffbot/BfBotTst.lua
git commit -m "test: update duration references to use scan entry instead of classification"
```

---

### Task 6: Deploy and live test

**Step 1: Deploy**
```bash
bash tools/deploy.sh
```

**Step 2: In-game test — duration column**
1. Open BuffBot panel (F11)
2. Verify duration column shows between Name and Count
3. Check values: `Perm` for permanent buffs, `5m`/`1h` etc. for timed buffs, `Inst` for instant
4. Switch characters — verify different caster levels show different durations for shared spells

**Step 3: In-game test — Quick Cast**
1. Set Quick Cast to "Long" on a preset
2. Cast — verify long/permanent buffs still get fast casting, short buffs cast normally

**Step 4: In-game test — automated**
```
BfBot.Test.RunAll()
```
Expected: All tests pass.

---

## Task Dependencies

```
Task 1 (Scan+Cls) ──┬── Task 2 (Persist) ── Task 3 (Exec) ──┐
                     ├── Task 4 (UI) ─────────────────────────├── Task 6 (Deploy+Test)
                     └── Task 5 (Tests) ──────────────────────┘
```
