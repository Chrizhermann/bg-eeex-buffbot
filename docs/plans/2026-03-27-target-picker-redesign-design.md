# Target Picker Redesign — Design Document

**GitHub issue:** #18
**Date:** 2026-03-27
**Depends on:** #17 (scanner refactor — complete)

## Problem

The current target picker has three issues:

1. **Multi-target is unordered** — cast priority among targets is arbitrary (`{"3","1","5"}` is a set, not a sequence in practice)
2. **Multi-target only available when count > 1** — but ANY single-target spell benefits from a priority fallback list ("cast on Branwen, but if she already has it, try Ajantis")
3. **No targeting type awareness** — self-only and AoE spells show the same picker as single-target spells, even though their targets are predetermined

Additionally, targets are stored as slot numbers (`"4"`), which break silently when the party is rearranged, members leave, or members rejoin in different slots.

## Design

### 1. Targeting Type Gating

Default behavior based on scanner flags (`isAoE`, `isSelfOnly`):

| Spell type | Default target | Picker state |
|---|---|---|
| `isSelfOnly = 1` | Locked to `"s"` (Self) | Disabled, greyed "Self" text |
| `isAoE = 1` | Locked to `"p"` (Party) | Disabled, greyed "Party" text |
| Single-target friendly | Smart default from `GetDefaultTarget` | Full ordered picker |

**Override for modded spells:** Per-spell `tgtUnlock = 1` field on `spells[resref]`. When set, the picker is enabled regardless of `isSelfOnly`/`isAoE` flags. The unlock toggle lives inside the target picker itself — when opened for a locked spell, the picker shows the lock state with an "Unlock Targeting" button at the bottom. This keeps it discoverable without cluttering the main spell list.

### 2. Ordered Target List Picker

Centered popup (~220x420px), replaces current `BUFFBOT_TARGETS` sub-menu:

```
┌─ Resist Fear ───────────────────┐
│                                  │
│   [Self]         [All Party]     │
│                                  │
│   [1] Cavalira                   │
│   [2] Branwen                    │
│   [ ] Ajantis                    │
│   [ ] Garrick                    │
│   [ ] Alora                      │
│   [ ] Neera                      │
│                                  │
│   [▲]  [▼]                       │
│                                  │
│   [Clear]                [Done]  │
└──────────────────────────────────┘
```

**Interaction model:**

- **Click unselected name** → appends as next priority number
- **Click selected name** → removes, remaining numbers shift down (no gaps)
- **Party members always in fixed portrait order** — only priority numbers change
- **Up/Down** → select a numbered entry first (click it), then Up/Down swaps its priority with adjacent entry
- **Self** → sets `tgt = "s"`, auto-closes
- **All Party** → populates all current party members in portrait order as name array (e.g., `{"Cavalira", "Branwen", "Ajantis", ...}`), stays open for reordering
- **Clear** → resets to smart default via `GetDefaultTarget` (self-only → "s", AoE → "p", single-target → "s")
- **Done** → confirms and closes

**Locked state** (self-only/AoE without `tgtUnlock`):

- Header shows spell name + "(Self-only)" or "(Party-wide)"
- Player rows, Self, All Party buttons disabled/greyed
- "Unlock Targeting" button visible at bottom instead of Clear
- Clicking Unlock sets `tgtUnlock = 1`, picker refreshes to full mode

### 3. Data Model

**Name-based storage**, dual-format compatible with old saves:

```lua
-- Single targets (unchanged)
tgt = "s"                                    -- self
tgt = "p"                                    -- party (AoE)

-- Ordered priority list (names instead of slot strings)
tgt = {"Branwen", "Ajantis", "Neera"}        -- array position = cast priority

-- New field on spell config (optional, only when overriding lock)
spells[resref] = {
    on  = 1,
    tgt = {"Branwen", "Ajantis"},
    pri = 3,
    tgtUnlock = 1
}
```

**No schema version bump.** Old saves with slot strings (`"4"`, `{"3","1","5"}`) remain valid input:

- **Lazy conversion in `_Refresh()`**: detects slot strings, resolves to names via `EEex_Sprite_GetInPortrait` + `_GetName`, writes back. Party is guaranteed loaded at UI open time.
- **Dual-format in `_ResolveConfigTarget`**: accepts both formats at cast time. Names resolved via party scan, slot strings resolved directly. Unresolved names silently skipped.
- **Rationale**: marshal import runs during save load when other party sprites may not be fully available. Deferring conversion to UI/cast time avoids timing risks.

**New shared function:**

```lua
BfBot.Persist._ResolveNameToSlot(name)
-- Iterates party slots 0-5, compares _GetName(sprite) to name
-- Returns first match (0-5) or nil
```

**Export/import**: names are human-readable in exported files. Import keeps names not in current party (character might rejoin) rather than dropping them.

### 4. UI Changes to Main Panel

**Target column text** (`_TargetToText` updated):

| `tgt` value | Display |
|---|---|
| `"s"` | "Self" |
| `"p"` | "Party" |
| `{"Branwen"}` | "Branwen" |
| `{"Branwen", "Ajantis"}` | "Branwen +1" |
| `{"Branwen", "Ajantis", "Neera"}` | "Branwen +2" |
| Locked self-only | "Self" (grey) |
| Locked AoE | "Party" (grey) |

**Target button**: opens ordered picker for unlocked spells, opens locked-state picker for locked spells. Grey/dimmed text for locked spells.

**Spell table rows**: add `isAoE`, `isSelfOnly` from scan entries and `tgtUnlock` from spell config. These drive lock/unlock display and picker behavior.

**No changes to**: spell toggle, Move Up/Down, Enable/Disable, Cast/Stop, preset management, Quick Cast, or any other existing UI.

### 5. Execution Engine Changes

**`_ResolveConfigTarget` update** — handle name-based targets:

- Names resolved via `_ResolveNameToSlot(name)` at cast time
- Unresolved names (not in party) → skip silently, move to next in list
- Old slot strings still work (detected via `tonumber(x) ~= nil`)
- `"s"` and `"p"` unchanged

**No changes to**: `_Advance`, `_BuildSubQueue`, cheat mode tagging, BFBTCH/BFBTCR application, or the LuaAction chain. Only target resolution is affected.

### 6. Testing

**New tests:**

1. **Name resolution** — `_ResolveNameToSlot` finds correct slot, returns nil for absent characters
2. **Dual-format acceptance** — `_ResolveConfigTarget` handles slot strings, names, "s", "p", mixed tables
3. **Lazy conversion** — `_Refresh` converts slot strings to names in spell config
4. **Ordered priority** — target array order preserved through resolve → queue build → execution
5. **Lock gating** — self-only/AoE spells get locked targets, `tgtUnlock` overrides
6. **Clear resets to default** — respects `GetDefaultTarget` based on targeting type
7. **All Party populates names** — fills ordered array with current party member names in portrait order
8. **Missing party member** — name in target list but not in party → skipped gracefully

**Existing tests unaffected** — no schema migration, dual-format handling is additive.

**In-game smoke test checklist:**

- Open picker for single-target spell → ordered list works
- Open picker for self-only spell → locked state shows
- Unlock a self-only spell → picker enables
- Set ordered targets → cast → correct order observed
- Remove a party member → cast → skipped target, continues to next
- Load old save with slot-based targets → work correctly, convert to names on panel open
