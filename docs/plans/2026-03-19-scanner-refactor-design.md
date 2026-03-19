# Scanner Refactor Design (GitHub #17)

## Problem

The scanner uses `GetQuickButtons(type, false)` as the primary spell source. This causes:

1. **Exhausted spells disappear** — spells with 0 remaining slots are not returned at all. The `GetQuickButtons(type, true)` metadata pass is a no-op. A `GetSpellMetadata()` SPL-loading fallback was added as a workaround.
2. **Incomplete catalog** — only memorized spells with available slots appear. Known-but-unmemorized spells are invisible to the scanner.

## Solution

Use EEex known spells iterators as the **primary catalog source**, with `GetQuickButtons` providing slot counts only.

## Data Flow

```
Known Spells Iterators (Mage + Priest + Innate)
    -> full catalog: resref, name, icon, level, ability, classification,
                     duration, isAoE, isSelfOnly

GetQuickButtons(2/4, false)
    -> slot counts only: {[resref] = count}

Merge: catalog entries get count overlaid.
       count=0 = known but exhausted/unmemorized.
```

## Verified API

```lua
-- Yields (level, index, resref, ability) for every known spell
for lvl, idx, resref, ability in EEex_Sprite_GetKnownMageSpellsWithAbilityIterator(sprite) do end
for lvl, idx, resref, ability in EEex_Sprite_GetKnownPriestSpellsWithAbilityIterator(sprite) do end
for lvl, idx, resref, ability in EEex_Sprite_GetKnownInnateSpellsWithAbilityIterator(sprite) do end
```

Verified via EEex remote console 2026-03-14. Branwen: 49 priest spells vs 4 from `GetQuickButtons(2, false)`.

## Changes

### BfBotScn.lua

1. **New primary loop**: Three iterators build the full spell catalog. Each yields `(level, index, resref, ability)`. Ability provides icon and target type directly. SPL header loaded via `EEex_Resource_Demand` for classification and feature block analysis.

2. **Quick buttons become count overlay**: `GetQuickButtons(2, false)` and `GetQuickButtons(4, false)` iterated once to build `{[resref] = count}` lookup. Merged into catalog entries.

3. **Remove dead code**:
   - Secondary `GetQuickButtons(type, true)` pass (broken no-op)
   - `metadataOnly` code path in `processButtonList`
   - `GetSpellMetadata()` function (no longer needed)

4. **Scan entry gains**: `isAoE` (0/1 integer) and `isSelfOnly` (0/1 integer) at top level, mirrored from classification.

### BfBotCls.lua

- Add `isSelfOnly` to classification result alongside existing `isAoE`.
- `isSelfOnly = (ability.actionType == 5 or ability.actionType == 7)`

### BfBotUI.lua

- Remove `GetSpellMetadata` fallback in `_Refresh()` — catalog always has metadata.
- Auto-merge step 6: drop `scan.count > 0` gate — known-but-exhausted spells are in the catalog.

## What Doesn't Change

- `_buildSpellEntry` shape (add two fields, rest unchanged)
- Classification scoring logic
- Persistence schema (still v5)
- Cache invalidation flow
- Execution engine
- Override system (`ovr` field, Add/Remove UX)

## UX Model

- **Default view**: Buff-classified spells appear in presets (auto-populated, like today)
- **Add Spell**: Opens picker showing full catalog minus what's in the preset
- **Disable** (toggle off): Visible in preset, won't cast
- **Block** (`ovr = -1`): Hidden from all presets, won't auto-add. Reversible via Add Spell

## Depends On / Blocks

- Depends on: nothing
- Blocks: #18 (target picker redesign uses `isAoE`/`isSelfOnly`)
