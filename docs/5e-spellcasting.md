# 5E Spellcasting compatibility and testing

BuffBot **v1.9.0-alpha** adds experimental compatibility with [subtledoctor's 5E Spellcasting mod](https://github.com/UnearthedArcana/5E_spellcasting). It uses that mod's preparation and shared spell slots. It does not recreate 5e casting inside EEex.

## Current state

A user playtest on **BG2:EE 2.6.6, EEex 1.2.0 with LuaJIT, and 5E Spellcasting 2.7.2** found that a short arcane buff preset with Quick Cast worked well after a performance correction. The execution logs show completed runs and active-buff skips. A small pause between casts remains expected.

The full automated suite has **535 passing tests**, including checks for 5E spell mapping, shared availability, unprepared/exhausted spells, refresh waits, targeting, and repeated spell-list notifications. Exact slot accounting, other caster types, clones, and larger mod combinations still need in-game testing. BG:EE and EET have not been playtested with this integration.

## Setup

1. Use a separate test installation and save. If copying an installation, check its save directory too: a copied game can still point at your normal saves.
2. Install EEex with LuaJIT, then 5E Spellcasting, then BuffBot. Follow any other mods' install-order instructions. BuffBot detects 5E automatically.
3. Use a character already converted to 5E casting. A save created before installing 5E is not automatically a prepared test character. Prepare spells through 5E's own interface, rest, and let its casting abilities finish updating before the first check.
4. Start with a short preset and buffs that are not already active. An "already active" skip does not test whether a cast spends a slot.

Keep the game unpaused while waiting for preparation and spell-slot updates.

## What to expect

- Spells appear under their normal names, without a second set of internal casting abilities.
- Spells of the same level share the available count. For example, with two level-2 slots left, casting one level-2 buff leaves one slot for any other prepared level-2 spell.
- Unprepared spells and spells with no slots left are unavailable. BuffBot does not fall back to spending ordinary memorization slots for a converted caster.
- 5E schedules a one-second refresh after casting. BuffBot waits for availability to return, so Quick Cast still has short pauses.
- Save configuration stays in the existing BuffBot format; the integration adds no saved 5E-specific settings.

## Limitations

- **Variant-selection spells are skipped on converted casters**, even when a BuffBot variant is selected. Cast them manually.
- **Old preset entries pointing directly at `D5Z...I` abilities stop casting.** Replace them with the spell's normal entry.
- **An unfinished dual-class conversion or preparation step may leave affected spells unavailable.** Finish preparation and rest before retrying; BuffBot deliberately declines ordinary-slot casts in that state.
- **Divine casters, multiclass/dual-class combinations, special free casts, mod-added spell copies, repeats, summons, and clones need broader playtesting.** Some have automated coverage, which is not live acceptance.
- Copied BuffBot F12 abilities on clones remain unsupported. Use the Summons view or Cast All; this general BuffBot limitation also applies to 5E games.

## Short tester checklist

The first three checks are the most useful starting point. Run the others when convenient.

1. **Basic casting:** prepare two different buffs of the same spell level, with at least two slots left. Put them in a preset with Quick Cast Off and run it. Both should apply, the shared pool should fall by two, and the game should remain responsive.
2. **Last available slot:** repeat with only one slot left and buffs that are not active. Only one should cast; the other should be skipped without the run getting stuck or spending a slot below zero.
3. **Quick Cast:** rest and repeat the first check with Quick Cast All. Expect the same spell effects and slot cost, with short pauses while 5E refreshes.
4. **Preparation and rest:** leave a known buff unprepared and enable it in a preset. It should remain unavailable and spend no slot. Prepare it, rest, and check that it becomes usable. If a kit grants it for free, choose another spell for this check.
5. **Already active:** run a buff again while its effect is still active. With "skip active buffs" enabled, it should be skipped without spending a slot.
6. **Refresh timing:** try starting a second preset immediately after a cast or just after resting. BuffBot should wait or leave unavailable spells out; it should not cast from ordinary slots or become stuck.
7. **Other characters:** if available, repeat the basic check with a Cleric/Druid, a multiclass caster, or a clone through the Summons view. An unconverted caster should behave as before.

For a useful report, note the spell names and the pool count before and after each run. Reports of failures and successful combinations are both welcome.

## Reporting a problem

Run this in the in-game console while on the world screen, ideally just after the problem:

```lua
BfBot.FiveE.Diagnose()
```

Attach these files from the game folder to a [new BuffBot issue](https://github.com/Chrizhermann/bg-eeex-buffbot/issues/new):

- `buffbot_5e.log` — generated by the command above.
- `buffbot_exec.log` — the cast sequence and skip reasons.
- `WeiDU.log` — installed mods and their order.

Include the checklist step, spell names, caster class/kit, game and EEex versions, 5E Spellcasting version, and whether Quick Cast was enabled. For count problems, include the before/after counts or screenshots. If the game became too slow to run a command, keep the existing logs and describe where it happened; there is no need to force another cast.

## Notes for maintainers

`BfBot5e.lua` reads 5E's installed `D5ZCLONS.2DA`, validates each generated casting ability against the spell it actually delivers, and overlays the normal spell catalog with current availability. Execution uses the 5E casting ability; upstream still owns preparation, slot spending, and refreshing.

Keep generated casting abilities out of ordinary buff/duration analysis: their payload includes large bookkeeping spells. Coalesce 5E spell-list notifications before rebuilding an open panel. Preserve a known ability's presence even at zero count, since that helps identify converted casters.

Refresh callbacks carry a unique token so an old wait cannot resume a new run. The normal execution callback's separate, pre-existing stop/restart issue is outside this compatibility change. Do not claim the full in-game matrix passed based on mocked tests or completed log entries alone.
