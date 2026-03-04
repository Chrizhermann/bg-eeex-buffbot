# Manual Cast Order Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Move Up / Move Down buttons so players can reorder spells within a preset to control casting order.

**Architecture:** Two new buttons in the existing action row below the spell list. Lua functions swap the selected spell with its neighbor in `buffbot_spellTable`, then renumber all `pri` values contiguously (1, 2, 3, ...) and write them back via `SetSpellPriority`. Selection follows the moved spell.

**Tech Stack:** Lua (BfBotUI.lua), .menu DSL (BuffBot.menu), EEex persistence (SetSpellPriority)

**Design doc:** `docs/plans/2026-03-04-manual-cast-order-design.md`

---

### Task 1: Add Lua reorder functions to BfBotUI.lua

**Files:**
- Modify: `buffbot/BfBotUI.lua:534-547` (after `_HasSelection`, before `_CanCreatePreset`)

**Step 1: Add helper and move functions**

Insert these functions after `_HasSelection()` (line 537) and before `_CanCreatePreset()` (line 539) in `buffbot/BfBotUI.lua`:

```lua
--- Renumber all spell priorities contiguously (1, 2, 3, ...) based on
--- current buffbot_spellTable order. Writes back to Persist.
function BfBot.UI._RenumberPriorities()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return end
    for i, entry in ipairs(buffbot_spellTable) do
        entry.pri = i
        BfBot.Persist.SetSpellPriority(sprite, BfBot.UI._presetIdx, entry.resref, i)
    end
end

--- Can the selected spell be moved up? (selection exists and row > 1)
function BfBot.UI._CanMoveUp()
    return buffbot_isOpen and buffbot_selectedRow > 1 and buffbot_selectedRow <= #buffbot_spellTable
end

--- Can the selected spell be moved down? (selection exists and row < last)
function BfBot.UI._CanMoveDown()
    return buffbot_isOpen and buffbot_selectedRow > 0 and buffbot_selectedRow < #buffbot_spellTable
end

--- Move the selected spell up one position.
function BfBot.UI.MoveSpellUp()
    local row = buffbot_selectedRow
    if row <= 1 or row > #buffbot_spellTable then return end
    -- Swap in display table
    buffbot_spellTable[row], buffbot_spellTable[row - 1] = buffbot_spellTable[row - 1], buffbot_spellTable[row]
    -- Renumber all priorities
    BfBot.UI._RenumberPriorities()
    -- Follow the moved spell
    buffbot_selectedRow = row - 1
end

--- Move the selected spell down one position.
function BfBot.UI.MoveSpellDown()
    local row = buffbot_selectedRow
    if row < 1 or row >= #buffbot_spellTable then return end
    -- Swap in display table
    buffbot_spellTable[row], buffbot_spellTable[row + 1] = buffbot_spellTable[row + 1], buffbot_spellTable[row]
    -- Renumber all priorities
    BfBot.UI._RenumberPriorities()
    -- Follow the moved spell
    buffbot_selectedRow = row + 1
end
```

**Step 2: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): add MoveSpellUp/Down and priority renumbering"
```

---

### Task 2: Add Up/Down buttons to BuffBot.menu

**Files:**
- Modify: `buffbot/BuffBot.menu:340-352` (between Target button and Delete Preset button)

**Step 1: Add buttons**

Insert two new button blocks between the Target button (ends at line 340) and the Delete Preset button (starts at line 343) in `buffbot/BuffBot.menu`:

```menu
	-- Move selected spell up in cast order
	button
	{
		enabled "BfBot.UI._CanMoveUp()"
		action  "BfBot.UI.MoveSpellUp()"
		text    "Up"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 642 434 48 28
	}

	-- Move selected spell down in cast order
	button
	{
		enabled "BfBot.UI._CanMoveDown()"
		action  "BfBot.UI.MoveSpellDown()"
		text    "Down"
		text style "button"
		bam     "GUIOSTUL"
		scaleToClip
		area 694 434 48 28
	}
```

**Step 2: Commit**

```bash
git add buffbot/BuffBot.menu
git commit -m "feat(ui): add Up/Down buttons for spell reordering"
```

---

### Task 3: Deploy and test in-game

**Step 1: Deploy**

```bash
bash tools/deploy.sh
```

Restart game, load save with a party.

**Step 2: Test checklist**

- [ ] Open BuffBot panel (F11 or actionbar button)
- [ ] Select a spell in the list — Up and Down buttons appear enabled
- [ ] Click Up on first row — button is disabled (can't move above top)
- [ ] Click Down on last row — button is disabled (can't move below bottom)
- [ ] Select a middle spell, click Up — spell moves up, selection follows
- [ ] Click Up repeatedly — spell moves to top, then Up disables
- [ ] Select a spell, click Down — spell moves down, selection follows
- [ ] Switch to another character tab and back — order persists
- [ ] Switch to another preset tab and back — order persists
- [ ] Cast the preset — spells cast in the new order
- [ ] Save, reload — order persists
- [ ] Reorder, then save/load — order still persisted

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix(ui): address cast order issues found during testing"
```
