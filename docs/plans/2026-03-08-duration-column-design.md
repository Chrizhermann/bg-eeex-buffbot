# Duration Column Design

**Date**: 2026-03-08
**Status**: Approved

## Problem

1. **Missing UI info**: Users can't see how long their buffs last. For level-scaled spells (e.g. "5 rounds/level"), the actual duration depends on caster level and isn't shown anywhere.
2. **Shared cache bug**: `duration` and `durCat` are stored in the classification cache (`BfBot._cache.class[resref]`), which is keyed by resref only. Whichever character classifies a spell first sets the cached duration for all characters, regardless of their caster level.

## Solution

### 1. Move duration to scan entry (bug fix)

Move `duration` and `durCat` from the classification result to the scan entry, which is already per-sprite.

- **BfBotScn.lua** `_buildSpellEntry()`: Compute `duration` and `durCat` using the level-appropriate ability (already resolved via `sprite:getCasterLevelForSpell` + `header:getAbilityForLevel`).
- **BfBotCls.lua** `Classify()`: Remove `result.duration` and `result.durCat` from classification results. Keep `GetDuration()` and `GetDurationCategory()` as utility functions.
- **All consumers**: Switch from `scan.class.duration`/`scan.class.durCat` to `scan.duration`/`scan.durCat`.

### 2. Duration column in UI

New column in the spell list between Name and Count.

**Format function** `BfBot.UI._FormatDuration(seconds)`:
- `-1` -> `"Perm"`
- `0` -> `"Inst"`
- `nil` -> `"?"`
- `>= 3600`: `1h 30m` (omit minutes if 0)
- `>= 60`: `5m` or `1m 30s` (omit seconds if 0)
- `< 60`: `45s`

**Menu**: New list column (~12% width) between Name and Count. Name column width reduced to compensate.

### 3. Queue format for Quick Cast

Add `durCat` to queue entries (`{caster, spell, target, durCat}`). `BuildQueueFromPreset` reads `durCat` from scan data. Exec uses queue entry's `durCat` for cheat tagging instead of classification cache.

### 4. Consumer updates

| File | Change |
|------|--------|
| BfBotPer.lua:90-121 | `data.class.duration` -> `data.duration`, `data.class.durCat` -> `data.durCat` |
| BfBotExe.lua:162-163 | Read `durCat` from queue entry instead of `classResult` |
| BfBotTst.lua (4 sites) | Field path changes |
| BfBotUI.lua:710 | `scan.class.durCat` -> `scan.durCat` |

### 5. Testing

- Existing classification tests verify `GetDuration()` and `GetDurationCategory()`
- Live in-game testing: verify durations differ per caster level, format renders correctly, Quick Cast still tags correctly
