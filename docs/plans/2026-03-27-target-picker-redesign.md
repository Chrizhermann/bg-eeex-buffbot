# Target Picker Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the flat target picker with an ordered priority list, name-based storage, and targeting type gating with unlock override.

**Architecture:** Six tasks in dependency order: (1) name resolution + dual-format in Persist, (2) `_ResolveConfigTarget` update in Persist, (3) lazy slot→name conversion in UI `_Refresh`, (4) `tgtUnlock` accessor + lock gating in Persist, (5) new BUFFBOT_TARGETS menu + Lua picker logic, (6) tests. Each task is test-first where possible (in-game test suite), with frequent commits.

**Tech Stack:** Lua (EEex bridge), .menu DSL (Infinity Engine UI), BfBot test suite (`BfBot.Test.RunAll()` in EEex console)

**Design doc:** `docs/plans/2026-03-27-target-picker-redesign-design.md`

---

### Task 0: Add `_ResolveNameToSlot` and dual-format target resolution

**Files:**
- Modify: `buffbot/BfBotPer.lua:765-809` (`_ResolveConfigTarget`)
- Modify: `buffbot/BfBotPer.lua` (add `_ResolveNameToSlot` near line 765)

**Step 1: Add `_ResolveNameToSlot` function**

Add above `_ResolveConfigTarget` (~line 765):

```lua
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
```

**Step 2: Update `_ResolveConfigTarget` for dual-format**

Replace the existing function at line 771 with:

```lua
--- Resolve a config target (tgt field) into one or more exec queue entries.
-- Accepts both legacy slot strings ("1"-"6") and name strings ("Branwen").
-- @param tgt string|table: "s", "p", slot string, name string, or table of slot/name strings
-- @param slot number: caster party slot (0-5)
-- @param resref string: spell resref
-- @param pri number: priority value
-- @return table: array of {caster, spell, target, pri} entries
function BfBot.Persist._ResolveConfigTarget(tgt, slot, resref, pri)
    local results = {}
    if type(tgt) == "table" then
        -- Ordered target list: one queue entry per target
        for _, entry in ipairs(tgt) do
            local num = tonumber(entry)
            if num and num >= 1 and num <= 6 then
                -- Legacy slot string
                table.insert(results, {
                    caster = slot,
                    spell  = resref,
                    target = num,
                    pri    = pri,
                })
            else
                -- Name-based: resolve to slot
                local resolved = BfBot.Persist._ResolveNameToSlot(entry)
                if resolved then
                    table.insert(results, {
                        caster = slot,
                        spell  = resref,
                        target = resolved + 1,  -- slot 0-5 → Player 1-6
                        pri    = pri,
                    })
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
        table.insert(results, {
            caster = slot,
            spell  = resref,
            target = target,
            pri    = pri,
        })
    end
    return results
end
```

**Step 3: Commit**

```bash
git add buffbot/BfBotPer.lua
git commit -m "feat(persist): add name-based target resolution with dual-format support (#18)"
```

---

### Task 1: Add `tgtUnlock` persist accessor

**Files:**
- Modify: `buffbot/BfBotPer.lua` (add accessor after `SetSpellTarget` ~line 419)

**Step 1: Add `SetTgtUnlock` and `GetTgtUnlock` accessors**

Add after `SetSpellTarget` function:

```lua
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
```

**Step 2: Commit**

```bash
git add buffbot/BfBotPer.lua
git commit -m "feat(persist): add tgtUnlock accessor for target picker override (#18)"
```

---

### Task 2: Add `isAoE`, `isSelfOnly`, `tgtUnlock` to spell table rows + lazy slot→name conversion

**Files:**
- Modify: `buffbot/BfBotUI.lua:426-441` (spell table row construction in `_Refresh`)
- Modify: `buffbot/BfBotUI.lua:370-371` (lazy conversion after auto-merge, before row building)

**Step 1: Add lazy slot→name conversion in `_Refresh`**

After step 6 (auto-merge, ~line 370) and before step 7 (row building, ~line 372), add a new step:

```lua
    -- 6b. Lazy slot→name conversion: convert legacy slot strings to character names.
    -- Old saves store tgt as "1"-"6" or {"3","1","5"}. Convert to name-based
    -- format now that party is guaranteed loaded.
    for resref, spellCfg in pairs(preset.spells) do
        local tgt = spellCfg.tgt
        if type(tgt) == "table" then
            local converted = false
            local newTgt = {}
            for _, entry in ipairs(tgt) do
                local num = tonumber(entry)
                if num and num >= 1 and num <= 6 then
                    -- Legacy slot string → resolve to name
                    local slotSprite = EEex_Sprite_GetInPortrait(num - 1)
                    if slotSprite then
                        table.insert(newTgt, BfBot._GetName(slotSprite))
                        converted = true
                    end
                    -- Empty slot → drop (character left party)
                else
                    -- Already a name string, keep as-is
                    table.insert(newTgt, entry)
                end
            end
            if converted then
                spellCfg.tgt = newTgt
            end
        elseif type(tgt) == "string" and tgt ~= "s" and tgt ~= "p" then
            local num = tonumber(tgt)
            if num and num >= 1 and num <= 6 then
                -- Single legacy slot string → convert to name
                local slotSprite = EEex_Sprite_GetInPortrait(num - 1)
                if slotSprite then
                    spellCfg.tgt = BfBot._GetName(slotSprite)
                end
            end
        end
    end
```

**Step 2: Add targeting flags to spell table rows**

In the row construction block (~line 426), add `isAoE`, `isSelfOnly`, and `tgtUnlock` fields. Change the `table.insert(rows, {` block to include:

```lua
        table.insert(rows, {
            resref   = resref,
            name     = name,
            icon     = icon,
            dur      = dur,
            durText  = BfBot.UI._FormatDuration(dur),
            durCat   = durCat,
            count    = count,
            countText = count > 0 and ("x" .. count) or "--",
            on       = spellCfg.on or 0,
            targetText = BfBot.UI._TargetToText(spellCfg.tgt),
            tgt      = spellCfg.tgt or "p",
            castable = isCastable,
            pri      = spellCfg.pri or 999,
            ovr      = (config.ovr and config.ovr[resref]) or 0,
            isAoE    = scan and scan.isAoE or 0,
            isSelfOnly = scan and scan.isSelfOnly or 0,
            tgtUnlock = spellCfg.tgtUnlock or 0,
        })
```

**Step 3: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): add targeting flags to spell rows + lazy slot-to-name conversion (#18)"
```

---

### Task 3: Update `_TargetToText` for name-based targets

**Files:**
- Modify: `buffbot/BfBotUI.lua:1027-1060` (`_TargetToText` function)

**Step 1: Replace `_TargetToText` with name-aware version**

Replace the entire function:

```lua
--- Convert target config value to display text.
-- tgt can be: "s", "p", a name string, or a table of name strings.
-- Also handles legacy slot strings ("1"-"6") for backwards compatibility.
function BfBot.UI._TargetToText(tgt)
    if tgt == "s" then return "Self"
    elseif tgt == "p" then return "Party"
    elseif type(tgt) == "table" then
        if #tgt == 0 then return "None" end
        -- First entry is always the display name (highest priority target)
        local firstName = tgt[1]
        -- Legacy slot string? Resolve to name for display
        local num = tonumber(firstName)
        if num and num >= 1 and num <= 6 then
            firstName = buffbot_charNames[num] or ("Player " .. num)
        end
        if #tgt == 1 then
            return firstName
        end
        return firstName .. " +" .. (#tgt - 1)
    else
        -- Single string: name or legacy slot
        local num = tonumber(tgt)
        if num and num >= 1 and num <= 6 then
            return buffbot_charNames[num] or ("Player " .. num)
        end
        -- Name string — return as-is
        return tgt
    end
    return "Party"
end
```

**Step 2: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): update _TargetToText for name-based targets (#18)"
```

---

### Task 4: Rewrite BUFFBOT_TARGETS menu and picker Lua logic

**Files:**
- Modify: `buffbot/BuffBot.menu:606-752` (BUFFBOT_TARGETS menu definition)
- Modify: `buffbot/BfBotUI.lua:68-71` (global state variables)
- Modify: `buffbot/BfBotUI.lua:491-593` (picker Lua functions)

This is the largest task. It replaces the entire target picker sub-menu and its Lua backend.

**Step 1: Update global state variables**

Replace lines 68-71 in BfBotUI.lua:

```lua
-- Target picker state
buffbot_targetRow = 0            -- which spell row opened the picker
buffbot_targetHeader = ""        -- header text for target picker (spell name)
buffbot_targetLocked = 0         -- 1 if spell is self-only/AoE and not unlocked
buffbot_targetLockText = ""      -- "(Self-only)" or "(Party-wide)" for locked spells
buffbot_pickerTargets = {}       -- working copy of ordered target list (name strings)
buffbot_pickerSelected = 0       -- selected row in picker (for Up/Down reordering)
```

Note: remove `buffbot_multiTarget` — no longer needed (always ordered list mode).

**Step 2: Rewrite `OpenTargets` function**

Replace the `OpenTargets` function (~line 495):

```lua
--- Open the target picker for a spell row.
function BfBot.UI.OpenTargets(row)
    buffbot_targetRow = row
    local entry = buffbot_spellTable[row]
    if not entry then return end

    buffbot_targetHeader = entry.name or entry.resref
    buffbot_pickerSelected = 0

    -- Determine lock state
    local isLocked = 0
    local lockText = ""
    if entry.tgtUnlock ~= 1 then
        if entry.isSelfOnly == 1 then
            isLocked = 1
            lockText = "(Self-only)"
        elseif entry.isAoE == 1 then
            isLocked = 1
            lockText = "(Party-wide)"
        end
    end
    buffbot_targetLocked = isLocked
    buffbot_targetLockText = lockText

    -- Build working copy of current targets
    buffbot_pickerTargets = {}
    local tgt = entry.tgt
    if type(tgt) == "table" then
        for _, name in ipairs(tgt) do
            table.insert(buffbot_pickerTargets, name)
        end
    end
    -- "s" and "p" don't populate the picker list (they use the quick buttons)

    Infinity_PushMenu("BUFFBOT_TARGETS")
end
```

**Step 3: Rewrite picker interaction functions**

Replace all picker functions (PickTarget, _IsTargetChecked, _PickerBtnText) with:

```lua
--- Get the priority number for a character name in the picker, or 0 if not selected.
function BfBot.UI._PickerPriority(name)
    for i, entry in ipairs(buffbot_pickerTargets) do
        if entry == name then return i end
    end
    return 0
end

--- Button text for character slot in target picker.
-- Shows "[N] Name" if selected, "[ ] Name" if not.
function BfBot.UI._PickerBtnText(slot)
    local name = buffbot_charNames[slot] or ("Player " .. slot)
    local pri = BfBot.UI._PickerPriority(name)
    if pri > 0 then
        return "[" .. pri .. "] " .. name
    end
    return "[ ] " .. name
end

--- Toggle a character in the ordered target list.
-- If not selected: append as next priority.
-- If selected: remove and shift remaining numbers down.
function BfBot.UI.PickerToggle(slot)
    if buffbot_targetLocked == 1 then return end
    local name = buffbot_charNames[slot]
    if not name then return end

    local pri = BfBot.UI._PickerPriority(name)
    if pri > 0 then
        -- Remove
        table.remove(buffbot_pickerTargets, pri)
        -- Adjust selected row if needed
        if buffbot_pickerSelected >= pri then
            buffbot_pickerSelected = math.max(0, buffbot_pickerSelected - 1)
        end
    else
        -- Append
        table.insert(buffbot_pickerTargets, name)
    end
end

--- Quick-set: Self target. Sets tgt="s" and closes.
function BfBot.UI.PickerSelf()
    if buffbot_targetLocked == 1 then return end
    local row = buffbot_targetRow
    local entry = buffbot_spellTable[row]
    if not entry then return end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end

    BfBot.Persist.SetSpellTarget(sprite, BfBot.UI._presetIdx, entry.resref, "s")
    entry.tgt = "s"
    entry.targetText = BfBot.UI._TargetToText("s")
    Infinity_PopMenu("BUFFBOT_TARGETS")
end

--- Quick-set: All Party. Populates all current party members in portrait order.
function BfBot.UI.PickerAllParty()
    if buffbot_targetLocked == 1 then return end
    buffbot_pickerTargets = {}
    for slot = 1, 6 do
        local name = buffbot_charNames[slot]
        if name then
            table.insert(buffbot_pickerTargets, name)
        end
    end
end

--- Move selected target up in priority.
function BfBot.UI.PickerMoveUp()
    local sel = buffbot_pickerSelected
    if sel <= 1 or sel > #buffbot_pickerTargets then return end
    -- Swap with previous
    buffbot_pickerTargets[sel], buffbot_pickerTargets[sel - 1] =
        buffbot_pickerTargets[sel - 1], buffbot_pickerTargets[sel]
    buffbot_pickerSelected = sel - 1
end

--- Move selected target down in priority.
function BfBot.UI.PickerMoveDown()
    local sel = buffbot_pickerSelected
    if sel < 1 or sel >= #buffbot_pickerTargets then return end
    -- Swap with next
    buffbot_pickerTargets[sel], buffbot_pickerTargets[sel + 1] =
        buffbot_pickerTargets[sel + 1], buffbot_pickerTargets[sel]
    buffbot_pickerSelected = sel + 1
end

--- Select a target row in the picker (for Up/Down).
-- Click a numbered entry to select it for reordering.
function BfBot.UI.PickerSelect(slot)
    local name = buffbot_charNames[slot]
    if not name then return end
    local pri = BfBot.UI._PickerPriority(name)
    if pri > 0 then
        buffbot_pickerSelected = pri
    end
end

--- Clear targets: reset to smart default.
function BfBot.UI.PickerClear()
    if buffbot_targetLocked == 1 then return end
    local entry = buffbot_spellTable[buffbot_targetRow]
    if not entry then return end

    buffbot_pickerTargets = {}
    buffbot_pickerSelected = 0
    -- Reset tgt to default (will be applied on Done)
end

--- Confirm and close the picker. Saves the working copy to persist.
function BfBot.UI.PickerDone()
    local row = buffbot_targetRow
    local entry = buffbot_spellTable[row]
    if not entry then
        Infinity_PopMenu("BUFFBOT_TARGETS")
        return
    end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then
        Infinity_PopMenu("BUFFBOT_TARGETS")
        return
    end

    -- Determine final tgt value
    local tgt
    if #buffbot_pickerTargets == 0 then
        -- Empty list → use smart default
        if entry.isSelfOnly == 1 then
            tgt = "s"
        elseif entry.isAoE == 1 then
            tgt = "p"
        else
            tgt = "s"  -- single-target default: self
        end
    else
        -- Copy the ordered list
        tgt = {}
        for _, name in ipairs(buffbot_pickerTargets) do
            table.insert(tgt, name)
        end
    end

    BfBot.Persist.SetSpellTarget(sprite, BfBot.UI._presetIdx, entry.resref, tgt)
    entry.tgt = tgt
    entry.targetText = BfBot.UI._TargetToText(tgt)
    Infinity_PopMenu("BUFFBOT_TARGETS")
end

--- Unlock targeting for a locked spell.
function BfBot.UI.PickerUnlock()
    local row = buffbot_targetRow
    local entry = buffbot_spellTable[row]
    if not entry then return end
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end

    BfBot.Persist.SetTgtUnlock(sprite, BfBot.UI._presetIdx, entry.resref, 1)
    entry.tgtUnlock = 1
    buffbot_targetLocked = 0
    buffbot_targetLockText = ""
end
```

**Step 4: Remove obsolete functions**

Delete these functions (no longer needed):
- `BfBot.UI.PickTarget` (replaced by PickerToggle/PickerSelf/PickerAllParty/PickerDone)
- `BfBot.UI._IsTargetChecked` (replaced by _PickerPriority)

**Step 5: Rewrite BUFFBOT_TARGETS menu in BuffBot.menu**

Replace lines 606-752 with:

```
-- ==========================================================
-- Target picker sub-menu — ordered priority list
-- ==========================================================
menu
{
	name    "BUFFBOT_TARGETS"
	ignoreesc

	-- Dark overlay background (click to close = cancel)
	text
	{
		action  "Infinity_PopMenu('BUFFBOT_TARGETS')"
		area    0 0 99999 99999
		rectangle 1
		rectangle opacity 50
		on escape
	}

	-- Border frame
	label
	{
		name    "bbTgtFrame"
		area 450 120 260 450
	}

	-- Panel background (parchment)
	label
	{
		area 474 144 212 402
		mosaic "BFBOTBG"
	}

	-- Header: spell name
	label
	{
		text lua "buffbot_targetHeader"
		text style "normal_parchment"
		text align left center
		text color lua "{120, 90, 20}"
		area 479 149 202 20
	}

	-- Lock state text (Self-only / Party-wide)
	label
	{
		enabled "buffbot_targetLocked == 1"
		text lua "buffbot_targetLockText"
		text style "normal_parchment"
		text align center center
		text color lua "{150, 120, 80}"
		area 479 174 202 20
	}

	-- "Self" button
	button
	{
		enabled "buffbot_targetLocked == 0"
		action  "BfBot.UI.PickerSelf()"
		text    "Self"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 479 199 95 26
	}

	-- "All Party" button
	button
	{
		enabled "buffbot_targetLocked == 0"
		action  "BfBot.UI.PickerAllParty()"
		text    "All Party"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 581 199 95 26
	}

	-- Player 1
	button
	{
		enabled "buffbot_targetLocked == 0 and buffbot_charNames[1] ~= nil"
		action  "BfBot.UI.PickerToggle(1) BfBot.UI.PickerSelect(1)"
		text lua "BfBot.UI._PickerBtnText(1)"
		text style "button"
		text align left center
		bam     "GUIOSTUL"
		scaleToClip
		area 479 231 197 26
	}

	-- Player 2
	button
	{
		enabled "buffbot_targetLocked == 0 and buffbot_charNames[2] ~= nil"
		action  "BfBot.UI.PickerToggle(2) BfBot.UI.PickerSelect(2)"
		text lua "BfBot.UI._PickerBtnText(2)"
		text style "button"
		text align left center
		bam     "GUIOSTUL"
		scaleToClip
		area 479 259 197 26
	}

	-- Player 3
	button
	{
		enabled "buffbot_targetLocked == 0 and buffbot_charNames[3] ~= nil"
		action  "BfBot.UI.PickerToggle(3) BfBot.UI.PickerSelect(3)"
		text lua "BfBot.UI._PickerBtnText(3)"
		text style "button"
		text align left center
		bam     "GUIOSTUL"
		scaleToClip
		area 479 287 197 26
	}

	-- Player 4
	button
	{
		enabled "buffbot_targetLocked == 0 and buffbot_charNames[4] ~= nil"
		action  "BfBot.UI.PickerToggle(4) BfBot.UI.PickerSelect(4)"
		text lua "BfBot.UI._PickerBtnText(4)"
		text style "button"
		text align left center
		bam     "GUIOSTUL"
		scaleToClip
		area 479 315 197 26
	}

	-- Player 5
	button
	{
		enabled "buffbot_targetLocked == 0 and buffbot_charNames[5] ~= nil"
		action  "BfBot.UI.PickerToggle(5) BfBot.UI.PickerSelect(5)"
		text lua "BfBot.UI._PickerBtnText(5)"
		text style "button"
		text align left center
		bam     "GUIOSTUL"
		scaleToClip
		area 479 343 197 26
	}

	-- Player 6
	button
	{
		enabled "buffbot_targetLocked == 0 and buffbot_charNames[6] ~= nil"
		action  "BfBot.UI.PickerToggle(6) BfBot.UI.PickerSelect(6)"
		text lua "BfBot.UI._PickerBtnText(6)"
		text style "button"
		text align left center
		bam     "GUIOSTUL"
		scaleToClip
		area 479 371 197 26
	}

	-- Move Up button
	button
	{
		enabled "buffbot_targetLocked == 0 and buffbot_pickerSelected > 1"
		action  "BfBot.UI.PickerMoveUp()"
		text    lua "'Up (' .. buffbot_pickerSelected .. ')'"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 479 403 95 26
	}

	-- Move Down button
	button
	{
		enabled "buffbot_targetLocked == 0 and buffbot_pickerSelected > 0 and buffbot_pickerSelected < #buffbot_pickerTargets"
		text    lua "'Down (' .. buffbot_pickerSelected .. ')'"
		action  "BfBot.UI.PickerMoveDown()"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 581 403 95 26
	}

	-- Clear button (hidden when locked)
	button
	{
		enabled "buffbot_targetLocked == 0"
		action  "BfBot.UI.PickerClear()"
		text    "Clear"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 479 435 95 26
	}

	-- Done button (always visible)
	button
	{
		action  "BfBot.UI.PickerDone()"
		text    "Done"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 581 435 95 26
	}

	-- Unlock Targeting button (visible only when locked)
	button
	{
		enabled "buffbot_targetLocked == 1"
		action  "BfBot.UI.PickerUnlock()"
		text    "Unlock Targeting"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 479 467 197 26
	}
}
```

**Step 6: Update `OpenTargetsForSelected` (no change needed — it calls `OpenTargets`)**

Verify that `OpenTargetsForSelected` at line 510 still works (it just calls `BfBot.UI.OpenTargets(buffbot_selectedRow)` which is rewritten in step 2). No code change needed.

**Step 7: Commit**

```bash
git add buffbot/BfBotUI.lua buffbot/BuffBot.menu
git commit -m "feat(ui): rewrite target picker with ordered priority list and lock gating (#18)"
```

---

### Task 5: Write tests for target picker redesign

**Files:**
- Modify: `buffbot/BfBotTst.lua` (add new test function + register in RunAll)

**Step 1: Add `BfBot.Test.TargetPicker` function**

Add before `BfBot.Test.RunAll()` (~line 946):

```lua
--- Test: Target picker redesign — name resolution, dual-format, lock gating.
function BfBot.Test.TargetPicker()
    _reset()
    P("")
    P("========================================")
    P("  Target Picker Redesign Tests")
    P("========================================")
    P("")

    local sprite = EEex_Sprite_GetInPortrait(0)
    if not sprite then
        _nok("No party member in slot 0")
        return _summary("TargetPicker")
    end
    local charName = BfBot._GetName(sprite)
    _ok("Slot 0: " .. charName)

    -- Test 1: _ResolveNameToSlot finds slot 0 by name
    P("")
    P("  [1] _ResolveNameToSlot")
    local resolved = BfBot.Persist._ResolveNameToSlot(charName)
    _check(resolved == 0,
        "Resolve '" .. charName .. "' → slot " .. tostring(resolved) .. " (expected 0)")

    -- Test 1b: absent name returns nil
    local absent = BfBot.Persist._ResolveNameToSlot("ZZZZZ_NOBODY")
    _check(absent == nil,
        "Resolve absent name → nil (got " .. tostring(absent) .. ")")

    -- Test 1c: nil/empty returns nil
    _check(BfBot.Persist._ResolveNameToSlot(nil) == nil, "nil → nil")
    _check(BfBot.Persist._ResolveNameToSlot("") == nil, "empty → nil")

    -- Test 2: _ResolveConfigTarget dual-format
    P("")
    P("  [2] _ResolveConfigTarget dual-format")

    -- 2a: "s" → self
    local r = BfBot.Persist._ResolveConfigTarget("s", 0, "TEST", 1)
    _check(#r == 1 and r[1].target == "self",
        "tgt='s' → target='self'")

    -- 2b: "p" → all
    r = BfBot.Persist._ResolveConfigTarget("p", 0, "TEST", 1)
    _check(#r == 1 and r[1].target == "all",
        "tgt='p' → target='all'")

    -- 2c: legacy slot string "1" → target=1
    r = BfBot.Persist._ResolveConfigTarget("1", 0, "TEST", 1)
    _check(#r == 1 and r[1].target == 1,
        "tgt='1' (legacy) → target=1")

    -- 2d: name string → resolved slot + 1
    r = BfBot.Persist._ResolveConfigTarget(charName, 0, "TEST", 1)
    _check(#r == 1 and r[1].target == 1,
        "tgt='" .. charName .. "' → target=1")

    -- 2e: table of names preserves order
    local name2 = nil
    for slot = 1, 5 do
        local sp = EEex_Sprite_GetInPortrait(slot)
        if sp then
            name2 = BfBot._GetName(sp)
            break
        end
    end
    if name2 then
        r = BfBot.Persist._ResolveConfigTarget({name2, charName}, 0, "TEST", 1)
        _check(#r == 2, "Table of 2 names → 2 entries (got " .. #r .. ")")
        if #r == 2 then
            _check(r[2].target == 1,
                "Second entry is slot 0 char (target=" .. tostring(r[2].target) .. ")")
        end
    else
        _warning("Only 1 party member — skipping ordered table test")
    end

    -- 2f: unresolved name in table → skipped
    r = BfBot.Persist._ResolveConfigTarget({"NOBODY", charName}, 0, "TEST", 1)
    _check(#r == 1,
        "Unresolved name skipped: " .. #r .. " entries (expected 1)")

    -- 2g: legacy slot table {"3","1"} still works
    r = BfBot.Persist._ResolveConfigTarget({"1"}, 0, "TEST", 1)
    _check(#r == 1 and r[1].target == 1,
        "Legacy table {'1'} → target=1")

    -- Test 3: tgtUnlock accessor
    P("")
    P("  [3] tgtUnlock accessor")
    local config = BfBot.Persist.GetConfig(sprite)
    if config and config.presets and config.presets[1] then
        -- Find any spell in preset 1
        local testResref = nil
        for resref, _ in pairs(config.presets[1].spells) do
            testResref = resref
            break
        end
        if testResref then
            -- Default should be 0
            local val = BfBot.Persist.GetTgtUnlock(sprite, 1, testResref)
            _check(val == 0, "Default tgtUnlock = 0 (got " .. tostring(val) .. ")")

            -- Set to 1
            BfBot.Persist.SetTgtUnlock(sprite, 1, testResref, 1)
            val = BfBot.Persist.GetTgtUnlock(sprite, 1, testResref)
            _check(val == 1, "After SetTgtUnlock(1) → 1 (got " .. tostring(val) .. ")")

            -- Set back to 0
            BfBot.Persist.SetTgtUnlock(sprite, 1, testResref, 0)
            val = BfBot.Persist.GetTgtUnlock(sprite, 1, testResref)
            _check(val == 0, "After SetTgtUnlock(0) → 0 (got " .. tostring(val) .. ")")
        else
            _warning("No spells in preset 1 — skip tgtUnlock test")
        end
    else
        _warning("No config/preset 1 — skip tgtUnlock test")
    end

    -- Test 4: _TargetToText with name-based targets
    P("")
    P("  [4] _TargetToText name format")
    _check(BfBot.UI._TargetToText("s") == "Self", "'s' → Self")
    _check(BfBot.UI._TargetToText("p") == "Party", "'p' → Party")
    _check(BfBot.UI._TargetToText({}) == "None", "{} → None")
    _check(BfBot.UI._TargetToText({"Branwen"}) == "Branwen",
        "{'Branwen'} → Branwen")
    _check(BfBot.UI._TargetToText({"Branwen", "Ajantis"}) == "Branwen +1",
        "{'Branwen','Ajantis'} → Branwen +1")
    _check(BfBot.UI._TargetToText({"Branwen", "Ajantis", "Neera"}) == "Branwen +2",
        "3 names → Branwen +2")
    -- Legacy slot string
    _check(BfBot.UI._TargetToText("1") == (buffbot_charNames[1] or "Player 1"),
        "'1' → resolved name or Player 1")

    -- Test 5: Boolean safety — tgtUnlock must be number not boolean
    P("")
    P("  [5] Boolean safety")
    if config and config.presets then
        local hasBool = false
        for _, preset in pairs(config.presets) do
            for _, spell in pairs(preset.spells or {}) do
                if type(spell.tgtUnlock) == "boolean" then
                    hasBool = true
                end
            end
        end
        _check(not hasBool, "No boolean tgtUnlock values in config")
    end

    return _summary("TargetPicker")
end
```

**Step 2: Register in RunAll**

Find `BfBot.Test.RunAll()` and add call to `BfBot.Test.TargetPicker()` in the sequence, after `ScannerRefactor` and before the final summary:

```lua
    allOk = BfBot.Test.TargetPicker() and allOk
```

**Step 3: Commit**

```bash
git add buffbot/BfBotTst.lua
git commit -m "test: add target picker redesign tests (#18)"
```

---

### Task 6: Update CLAUDE.md and deploy/verify

**Files:**
- Modify: `CLAUDE.md` (update target picker section, test count)
- Run: `bash tools/deploy.sh` → restart → `BfBot.Test.RunAll()`

**Step 1: Update CLAUDE.md**

Update the "Configuration UI Details" section to document:
- Target picker is now an ordered priority list with name-based storage
- `tgtUnlock` field for overriding self-only/AoE lock
- Lazy slot→name conversion (dual-format compatible)
- `buffbot_multiTarget` removed, replaced by `buffbot_targetLocked` / `buffbot_pickerTargets`
- New picker functions: `PickerToggle`, `PickerSelf`, `PickerAllParty`, `PickerMoveUp/Down`, `PickerClear`, `PickerDone`, `PickerUnlock`

Update the "Persistence Details" section:
- Add `_ResolveNameToSlot`, `GetTgtUnlock`, `SetTgtUnlock` to API list
- Document dual-format target handling

Update test count to reflect new tests.

**Step 2: Deploy and test**

```bash
bash tools/deploy.sh
```

Then in-game: `BfBot.Test.RunAll()` — verify all tests pass including new TargetPicker tests.

**Step 3: In-game smoke test checklist**

- [ ] Open picker for single-target spell → ordered list shows
- [ ] Click names to add in order → numbers appear correctly
- [ ] Click numbered name to remove → numbers shift down
- [ ] Up/Down reordering works
- [ ] Self button → sets "Self", closes
- [ ] All Party → populates all names
- [ ] Clear → resets to default
- [ ] Open picker for self-only spell → locked state, Unlock button visible
- [ ] Unlock → picker enables
- [ ] Set ordered targets → Cast → correct cast order
- [ ] Load old save → slot-based targets display correctly, convert on panel open

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for target picker redesign (#18)"
```
