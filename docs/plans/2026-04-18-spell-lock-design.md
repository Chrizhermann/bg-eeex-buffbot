# Spell Position Lock — Design

**Date**: 2026-04-18
**Status**: Approved, ready for implementation plan

## Problem

Users carefully arrange spell priorities in a preset, then press "Sort by Duration" and lose the manual ordering. They need a way to pin specific spells to their chosen row so sort (and manual moves) respect the lock.

## Summary

Add a per-spell `lock` field (0/1) to the preset config. When set, that spell stays at its row during sort and cannot be moved or swapped past by Move Up/Down. Lock state is toggled via a new 7th column on the right of the spell list.

## Data Model

Extend the per-spell config entry:

```
preset.spells[resref] = { on, tgt, pri, tgtUnlock, var, lock }
                                                        ^ new, default 0
```

- Schema version: v5 → v6.
- `_ValidateConfig`: `if type(entry.lock) ~= "number" then entry.lock = 0 end`.
- `_MigrateConfig`: `if fromVersion < 6 then ... end` — no data transform needed (missing → 0 via validator).
- Persistence API: add `GetSpellLock(sprite, preset, resref)` and `SetSpellLock(sprite, preset, resref, val)`.
- Export/import: no changes — `_Serialize` dumps the whole table.

## Sort Algorithm

`SortByDuration()` becomes a pin-in-place sort:

```
1. Partition buffbot_spellTable:
   - locked[i] = entry     (keyed by current row index)
   - unlocked[] = entries  (ordered list, current order)
2. table.sort(unlocked, durKey-desc)
3. Rebuild: for i = 1..N, if locked[i] keep it, else take next from unlocked[]
4. _RenumberPriorities()
```

Example: `[A(10), B🔒(20), C(30), D(15)]` → unlocked sorted desc `[C(30), D(15), A(10)]` → result `[C, B🔒, D, A]`.

Edge cases:
- All locked → result unchanged, priorities renumbered (effective no-op).
- All unlocked → identical to previous behavior.
- Empty or single-entry list → early-out (existing guard).

## Move Up / Down

Locked spells are immovable in both directions. Adjacent locked rows are skipped over.

```
_FindNextUnlocked(startRow, direction):
  step = +1 or -1
  row = startRow + step
  while row in [1, N]:
    if buffbot_spellTable[row].lock != 1 then return row end
    row = row + step
  return nil
```

- Selected row locked → `_CanMoveUp()` and `_CanMoveDown()` both false.
- Selected row unlocked, adjacent locked → swap with `_FindNextUnlocked(selected, dir)`.
- No unlocked row in direction → button grays out.

## UI

**Menu layout** (`BuffBot.menu`) — 7-column spell list, widths sum to 100:

```
checkbox=8  icon=8  name=28  dur=12  count=10  target=28  lock=6
                                              ^^ shrunk   ^^ new
```

New column uses a `label` (list columns do not support clickable `button` — existing `.menu` limitation):

```
column {
    width 6
    label {
        area 0 0 -1 36
        text lua "BfBot.UI._LockText(rowNumber)"
        text style "normal_parchment"
        text align center center
        text color lua "BfBot.UI._LockColor(rowNumber)"
    }
}
```

**List action dispatch** (existing `cellNumber` guard extended):

```
action "BfBot.UI._UpdateVariantState();
        if cellNumber <= 2 then BfBot.UI.ToggleSpell(buffbot_selectedRow)
        elseif cellNumber == 7 then BfBot.UI.ToggleLock(buffbot_selectedRow) end"
```

**Variant layout** — the squeezed variant-row button layout at y=434 does not touch list columns, so no changes there.

**View helpers**:
- `_LockText(row)` → `"[L]"` if locked, `"[ ]"` otherwise.
- `_LockColor(row)` → yellow/gold `{230,200,60}` when locked, default parchment otherwise.
- Extend `_SpellNameColor(row)` with a subtle locked-tint so pinned rows read as pinned at a glance (chosen not to clash with include-override blue or disabled gray).

**New UI functions** (`BfBotUI.lua`):
- `ToggleLock(row)` — flips `entry.lock`, calls `SetSpellLock`, immediate visual update.
- `_LockText(row)`, `_LockColor(row)` — view helpers.
- `_FindNextUnlocked(start, dir)` — helper used by `_CanMoveUp/Down` and `MoveSpellUp/Down`.

## Spell Table Row

Add `lock` to the row built in `_Refresh`:

```lua
table.insert(rows, {
    ...,
    lock = spellCfg.lock or 0,
})
```

## Edge Cases Handled

- **Auto-merge new spells**: `_MakeDefaultSpellEntry` returns fresh entry, `lock = 0` via validator default. No interaction.
- **Locked spell loses castability** (memorization changed, dual-class lockout): lock persists; the spell is already grayed. No special handling.
- **Import**: imported presets carry their `lock` values. Spells dropped on import also drop their lock. No extra logic.
- **Variant spells**: lock is orthogonal to variant selection. Enable gate on variants unchanged.
- **Preset delete/create**: no cross-preset lock coupling; each preset has its own `lock` field per spell.

## Tests

Add to `BfBotTst.lua`:

- `TestSpellLock()` — set lock on a spell, verify persistence through save/load round-trip via validator.
- `TestSortWithLocks()` — construct a preset with mixed locked/unlocked spells, call SortByDuration, verify locked spells stayed at their row indices and unlocked spells are in duration-desc order.
- `TestMoveSkipLocked()` — construct a preset, lock middle rows, verify `_FindNextUnlocked` skips them and Move Up/Down behavior is correct at the boundaries.

## Affected Files

- `buffbot/BfBotPer.lua` — schema bump, validator, migration, `Get/SetSpellLock`.
- `buffbot/BfBotUI.lua` — `ToggleLock`, `_LockText`, `_LockColor`, `_FindNextUnlocked`, update `SortByDuration`, `_CanMoveUp/Down`, `MoveSpellUp/Down`, `_Refresh` row build, `_SpellNameColor`.
- `buffbot/BuffBot.menu` — add 7th column, adjust target column width, extend list action.
- `buffbot/BfBotTst.lua` — three new tests.
- `CLAUDE.md` — add "Spell Position Lock" bullet to Alpha feature list; bump schema version note to v6.

## Out of Scope

- Lock icon BAM (current text-based `[L]`/`[ ]` is sufficient; BAM polish can come post-MVP).
- Cross-preset lock synchronization (each preset independent — no coupling).
- Bulk lock/unlock button (YAGNI until user asks).
