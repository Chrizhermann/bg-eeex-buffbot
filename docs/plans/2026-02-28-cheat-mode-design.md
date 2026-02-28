# Cheat Mode (Quick Cast) — Design Document

## Problem

BuffBot casts buffs through the normal engine pipeline: aura cooldown (6s between spells) + casting time per spell. This is realistic but slow — a full prebuff sequence can take minutes of real time.

For long-duration buffs (8+ in-game hours), saving 30 seconds of casting time is negligible relative to the buff duration. For short-duration buffs (1-2 minutes), those saved seconds represent a meaningful gameplay advantage.

Players want the option to speed up casting, with awareness of how much they're "cheating."

## Design

### Mechanism

Apply a temporary "cheat buff" SPL to each caster before their queue starts:

- **Opcode 188** (Aura Cleansing / Improved Alacrity) — removes 6-second aura cooldown
- **Opcode 189** (Casting Time Modifier, param1 = -99) — near-zero casting time

Stays in the normal `SpellRES()` pipeline. Slot consumption, skip detection, animations, sounds — all work unchanged. Just dramatically faster.

### Per-Preset 3-State Toggle

Each preset has an independent `qc` (quick cast) field:

| Value | Label | Behavior |
|-------|-------|----------|
| 0 | Off | Normal casting speed |
| 1 | Long | IA + fast speed for spells with duration >= LongThreshold (300s). Short spells cast normally. |
| 2 | All | IA + fast speed for ALL spells in the preset |

### Two-Pass Queue Splitting

When `qc=1` (Long only), each caster's sub-queue is split by duration:

1. Apply `BFBTCH.SPL` (cheat buff) to caster
2. Cast all spells with `durCat` in `{"permanent", "long"}` — fast
3. Apply `BFBTCR.SPL` (cheat remover, opcode 321 targeting BFBTCH) — removes IA
4. Cast remaining spells — normal speed

When `qc=2` (All): apply `BFBTCH`, cast everything, let it expire or clean up at end.
When `qc=0` (Off): no cheat SPL applied.

### Duration Threshold

Reuses existing `LongThreshold` INI pref (300 seconds = 5 turns). Spells with duration >= 300s or `durCat` of "permanent"/"long" qualify for the fast tier.

### SPL Files

**`BFBTCH.SPL`** (cheat buff): Generated at runtime, same binary pattern as innate SPLs.
- Header (114 bytes) + 1 ability (40 bytes, self/instant) + 2 effects (48 bytes each)
- Effect 1: Opcode 188 (Aura Cleansing), timed ~5 minutes
- Effect 2: Opcode 189 (Casting Time Modifier, param1 = -99), timed ~5 minutes

**`BFBTCR.SPL`** (cheat remover): Generated at runtime.
- Header (114 bytes) + 1 ability (40 bytes, self/instant) + 1 effect (48 bytes)
- Effect 1: Opcode 321 (Remove Effects by Resource), resource = "BFBTCH"

## Config & Persistence

### Preset Schema Change

`qc` field added to each preset:

```
presets = {
  [1] = { name="Long Buffs", cat="long", qc=0, spells={...} },
  [2] = { name="Short Buffs", cat="short", qc=2, spells={...} },
}
```

### Schema Migration (v3 to v4)

- If `opts.cheat == 1`: set `qc=2` on all presets
- If `opts.cheat == 0`: set `qc=0` on all presets
- Remove `opts.cheat` from opts
- Bump `config.v` to 4

### New Presets

`CreatePreset` and `_CreateDefaultConfig` set `qc=0` by default on new presets.

## UI / UX

### Cycling Button

Placed near the Cast/Stop buttons. Single click cycles Off -> Long -> All -> Off.

| State | Button Text | Text Color | Tooltip |
|-------|------------|------------|---------|
| Off | `Quick Cast: Off` | White `{200,200,200}` | "Normal casting speed" |
| Long | `Quick Cast: Long` | Yellow `{230,200,60}` | "Fast casting for buffs lasting 5+ turns" |
| All | `Quick Cast: All` | Red/Orange `{230,100,60}` | "Fast casting for ALL buffs (cheat)" |

### .menu Implementation

```
button {
    area <x> <y> <w> <h>
    text lua "BfBot.UI._QuickCastLabel()"
    text color lua "BfBot.UI._QuickCastColor()"
    action "BfBot.UI.CycleQuickCast()"
    tooltip lua "BfBot.UI._QuickCastTooltip()"
}
```

### Lua Functions

- `BfBot.UI.CycleQuickCast()` — cycles qc 0->1->2->0 on current preset
- `BfBot.UI._QuickCastLabel()` — returns display text based on preset's qc value
- `BfBot.UI._QuickCastColor()` — returns `{R,G,B}` table based on qc value
- `BfBot.UI._QuickCastTooltip()` — returns tooltip string based on qc value

### Execution Status

Optional: status text shows "Casting (Quick)..." when cheat mode is active.

### Innate Abilities (F12)

Innate-triggered execution reads the preset's `qc` field automatically. No separate UI needed.

## Execution Engine Changes

### Start Flow

1. `BuildQueueFromPreset(idx)` reads `preset.qc` and passes it through to `Exec.Start(queue, qcMode)`
2. `_BuildQueue` splits each caster's entries into cheat/normal buckets based on `qcMode` and spell `durCat`
3. `_ProcessCasterEntry` handles the IA apply/remove boundary actions

### Stop Handling

`Exec.Stop()` queues `BFBTCR` removal for any caster that had cheat buff applied, preventing IA from lingering after abort.

### Skip Detection

Unchanged. `_CheckEntry` runs per-entry as before. IA just reduces real time between checks.

## Edge Cases

- **IA already active from real spell**: Harmless. Our IA stacks or overlaps; `BFBTCR` only removes our resource-specific effects via opcode 321.
- **All spells are long when qc=1**: Normal bucket is empty; skip removal step, let BFBTCH expire.
- **All spells are short when qc=1**: Cheat bucket is empty; skip BFBTCH entirely, cast normally.
- **Player stops mid-cheat**: `Exec.Stop()` cleans up BFBTCH on affected casters.
- **Party has IA from Improved Alacrity spell**: Unaffected. Our removal only targets BFBTCH resource.
