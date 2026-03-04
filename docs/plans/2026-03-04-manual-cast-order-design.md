# Manual Cast Order — Design Document

**Date**: 2026-03-04
**GitHub Issue**: #5

## Summary

Add Move Up / Move Down buttons to the BuffBot config panel so players can reorder spells within a preset, controlling the casting order. Per-character, per-preset — each character's spell order is independent.

## Why It Matters

Cast order is important for hardcore players (SCS/Ascension). Examples:
- Cast Protection from Evil before Haste (so PfE isn't wasted during Haste casting time)
- Cast shorter buffs last so they have maximum uptime
- Cast party-wide buffs before single-target buffs

## Design

### Interaction Model

1. Select a row in the spell list (existing behavior)
2. Click **Up** or **Down** button to move the selected spell one position
3. The spell swaps with its neighbor; selection follows the moved spell
4. Repeat to move multiple positions

### UI Changes (BuffBot.menu)

Two new buttons in the action row below the spell list (y=434), placed in the gap between Target and Delete Preset:

| Element | Area | Notes |
|---------|------|-------|
| Enable | 350, 434, 120, 28 | Existing — unchanged |
| Target | 476, 434, 160, 28 | Existing — unchanged |
| **Up** | **642, 434, 48, 28** | **New** — enabled when selection > 1 |
| **Down** | **694, 434, 48, 28** | **New** — enabled when selection < last row |
| Delete Preset | 740, 434, 130, 28 | Existing — unchanged |

Both buttons gated by `BfBot.UI._HasSelection()` plus boundary checks.

### Lua Changes (BfBotUI.lua)

New functions:

- `BfBot.UI.MoveSpellUp()` — moves selected spell up one position
- `BfBot.UI.MoveSpellDown()` — moves selected spell down one position
- `BfBot.UI._CanMoveUp()` — selection exists and row > 1
- `BfBot.UI._CanMoveDown()` — selection exists and row < #spellTable

### Priority Reassignment Strategy

After each move, **renumber all priorities contiguously** (1, 2, 3, ...) based on current display order. This:
- Avoids gaps or collisions in `pri` values
- Keeps data clean for `BuildQueueFromPreset` sorting
- Works regardless of initial priority state (auto-assigned 1,2,3... or messy 1,5,999)

### Selection Preservation

After a move, `buffbot_selectedRow` is updated to follow the moved spell (row ± 1) so the player can press Up/Down repeatedly without re-selecting.

### No Persistence Changes

- `SetSpellPriority()` already exists in BfBotPer.lua
- `pri` field already exists in spell config entries
- Schema stays at v4
- No migration needed

### Scope

- Per-character, per-preset (each character has independent spell order)
- No party-wide sync
- No drag-and-drop (IE .menu list widget doesn't support it)

## Implementation Tasks

1. Add `MoveSpellUp`, `MoveSpellDown`, `_CanMoveUp`, `_CanMoveDown` to BfBotUI.lua
2. Add `_RenumberPriorities` helper that walks `buffbot_spellTable` and writes contiguous `pri` values back to Persist
3. Add Up/Down buttons to BuffBot.menu in the action row
4. Test in-game: move spells, verify order persists across tab switches and save/load
