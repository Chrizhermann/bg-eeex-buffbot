# Combat Safety — Design Document

**Date**: 2026-03-31
**Issue**: #22
**Status**: Approved

## Problem

BuffBot's Quick Cast mode applies Improved Alacrity + casting speed reduction (BFBTCH.SPL) to party members during buff casting. If combat starts during buffing, the player gains an unfair advantage. Additionally, edge cases (player clearing action queues, Lua errors, engine quirks) can leave BFBTCH active after BuffBot stops, giving permanent cheat buffs.

Two requirements:
1. **Combat interrupt**: running buff queues should abort cleanly when hostiles are detected nearby.
2. **Quick Cast safety**: BFBTCH must never remain active outside of BuffBot's casting. No exceptions.

## Combat Detection

**API**: `sprite:countAllOfTypeStringInRange("[ENEMY]", 400)` on the party leader (`EEex_Sprite_GetSelected()`).

- `[ENEMY]` matches EA >= 200 (EVILCUTOFF range) — same hostility threshold the engine uses.
- Range 400 = SPAWN_RANGE, same as rest prevention. Matches player expectations.
- LOS check enabled (default) — enemies behind walls don't trigger.
- Checks the party leader only, consistent with the engine's rest check.

## Queue Interruption

**Where**: Inside `BfBot.Exec._Advance(slot)`, before advancing to the next entry. This is the natural heartbeat — fires after every spell completes.

**Behavior**:
1. First `_Advance` that detects hostiles calls `BfBot.Exec.Stop()`.
2. Current spell for each caster finishes (already queued in engine action queue).
3. All subsequent spells skipped via existing `_state ~= "running"` guards.
4. Cheat buffs cleaned up for all casters (existing Stop behavior).
5. `DisplayStringHead` notification on party leader: "BuffBot: Combat detected — casting stopped".
6. No new state needed — reuses `"stopped"`, reason logged.

**Guard**: `BfBot.Persist.GetPref("CombatInterrupt")` checked before detection. Default `1` (on). Stored in `baldur.ini` `[BuffBot]` section via `Infinity_GetINIValue`/`Infinity_SetINIValue`.

## Quick Cast Safety Net

Two layers:

### Layer 1 — Cleanup on Stop/Complete (existing)

`Stop()` and `_Complete()` already apply BFBTCR for any caster with `cheatApplied = true`. Covers the happy path and combat interrupt path.

### Layer 2 — Paranoid safety net (new)

A `.menu` `enabled` tick on the BUFFBOT_BTN template (actionbar injection — always visible on world screen). Calls `BfBot.Exec._SafetyTick()` every ~2 seconds, rate-limited via `Infinity_GetClockTicks()`.

Logic:
1. If exec state is `"running"` → do nothing (exec engine owns cheat management).
2. If exec state is NOT `"running"` → iterate party members, check `m_timedEffectList` for effects with `m_sourceRes == "BFBTCH"`. If found, apply BFBTCR via `ReallyForceSpellRES` and log a warning.

**Not toggleable** — always active. This is the hard safety guarantee.

**Placement**: In the BUFFBOT_BTN template (not BUFFBOT_PANEL) so it runs whenever the world screen is active, regardless of whether the config panel is open.

## INI Preference

| Key | Section | Default | Description |
|-----|---------|---------|-------------|
| `CombatInterrupt` | `[BuffBot]` | `1` | Enable combat detection queue interrupt |

Quick Cast safety net has no toggle — always on.

## Files Changed

| File | Changes |
|------|---------|
| `BfBotExe.lua` | Add `_DetectCombat()` helper, call from `_Advance()`. Add `_SafetyTick()` with rate limiting. |
| `BfBotPer.lua` | Add `CombatInterrupt` INI pref default in init. |
| `BuffBot.menu` | Add hidden `label` with `enabled "_SafetyTick()"` to BUFFBOT_BTN template. |
| `BfBotTst.lua` | Unit tests for detection helper and safety tick logic. |

## Testing

### Unit tests
- Combat detection helper: mock sprite returning 0 vs >0 enemy count.
- Safety tick: verify BFBTCH cleanup triggers when state is not `"running"`.

### In-game verification
1. Start buff queue near hostiles → auto-stop + notification.
2. Quick Cast queue → Stop → move around → BFBTCH cleaned up by safety net within ~2s.
3. Start buffing → walk into aggro range → interrupt after current spell.
4. Set `CombatInterrupt=0` → buffing continues with enemies nearby.
5. Quick Cast with `CombatInterrupt=0` → enemies appear → queue continues, BFBTCH cleaned up on completion.

### Edge cases
- Player clicks movement mid-cast (flushes action queue) → safety net catches orphaned BFBTCH.
- All casters casting simultaneously → one triggers stop, others abort cleanly.
- Combat interrupt near end of queue (1 spell remaining).
