# Classifier False Positive Reduction — Design Document

Date: 2026-03-03

## Problem

The buff classifier (`BfBot.Class.Classify`) produces too many false positives. Spells that are not prebuffs — traps, setup spells, crafting abilities, pure heals, offensive spells, and toggle stances — score above the buff threshold (+3) and appear in the config UI as castable buffs.

These false positives fall into clear categories (from in-game test log analysis):

| Category | Examples | Should be buff? |
|----------|----------|-----------------|
| Traps | Set Snare, Set Spike/Exploding/Time Trap | No |
| Setup spells | Contingency, Chain Contingency, Simbul's Sequencer/Trigger/Matrix | No |
| Utility/crafting | Alchemy, Scribe Scrolls, Tracking, Magical Stone | No |
| Toggle stances | Power Attack (stance), Expertise, Rapid Shot (mod: C0FIG/C0ARC) | No |
| Pure heals | Cure Light Wounds, Slow Poison, Cure Disease, Neutralize Poison | No |
| Offensive (scoring positive) | Charm Animal, Charm Person, War Cry, Fireburst | No |
| BuffBot's own innates | BFBT01, BFBT02, etc. | No (filter in scanner) |
| Summons | Summon Planetar, Elemental Prince Call | OK (keep) |
| Shapeshifts | Black Bear, Brown Bear, Wolf | OK (keep) |

## Root Cause Analysis

Feature block dumps (`DumpFeatureBlocks`) reveal two systemic root causes:

### Root Cause 1: SCS anti-stacking opcode 324 inflates scores

SCS adds `opcode 324` (Immunity to Resource and Message) referencing the spell's own resref to prevent double-application. Each instance scores +2 as a "protection opcode" — but it's anti-stacking infrastructure, not a real buff.

Evidence:
- **SPCL311 (Charm Animal)**: 4x `op=324 r=spcl311` = +8 fake, plus `op=5 Charm = -3`. Net +5. Without self-refs: -3 (correctly offensive).
- **SPWI523 (Fireburst)**: `op=324 r=spwi523` = +2 fake. Without: 0.
- **SPCL908 (War Cry)**: `op=324 r=SPCL908` = +2 fake, plus `op=24 Horror = -3`. Without: -3 (correctly offensive).
- **C0FIG01 (Power Attack stance)**: `op=318 r=C0FIG01` = +2 fake (toggle mechanism). Without: 0.
- **SPCL922 (Tracking)**: 2x `op=318 r=SPCL922` = +4 fake. Without: 0.

### Root Cause 2: No substance requirement — targeting alone passes threshold

Self-targeted and/or friendly-flagged spells get +3 to +8 from targeting score alone (self-target +3, friendly flag +5). The buff threshold is only +3. But their feature blocks contain zero actual buff effects — all opcodes are neutral (visual, sound, cast spell, create item) or unknown.

Evidence:
- **SPCL412 (Set Snare)**: `op=146, 252, 215` — all neutral. Opcode score: 0.
- **SPIN141 (Contingency)**: Only `op=146` — neutral. Opcode score: 0.
- **GBALCHMG (Alchemy)**: 10x `op=122` (Create Item, not scored) — opcode score: 0.
- **SPIN101 (Cure Light Wounds)**: `op=17` (+1 heal), rest neutral. Only "buff" is instant HP.
- **SPPR212 (Slow Poison)**: `op=141, 50, 240, 11, 164, 240, 174` — all neutral/unknown. Opcode score: 0.

## Solution

Four generic heuristic changes. No hardcoded resref lists (except BFBT prefix for our own generated innates).

### Change 1: Self-Referencing Opcode Discount

In `ScoreOpcodes`, when processing opcode 318 (Protection from Resource) or 324 (Immunity to Resource and Message):
- Compare the feature block's resource field against the spell's own resref (case-insensitive)
- If they match → score 0 instead of +2 (do not add to opcode score)
- For opcode 318 matches: also set `selfReplace = true` (extends existing toggle detection which only checks opcode 321)

### Change 2: Substance Check

Define two categories of positive-scoring opcodes:

**Substantive** — opcodes that represent real gameplay buff effects:
- All stat modifiers (0, 1, 6, 10, 15, 19, 22, 44, 49, 54, 167, 233, 278, 284, 285, 286, 301, 305, 306, 325, 345, 346)
- All resistances (27-31, 84-89)
- All saving throws (33-37)
- All buff states and protections (16, 18, 20, 65, 69, 83, 98, 100, 101, 102, 119, 120, 129, 130, 131, 132, 133, 153, 155, 156, 163, 166, 218, 282, 314, 317, 328, 335)
- All spell protections/bounces (197-207, 212, 223, 226-228, 259, 292, 299, 302, 310, 318*, 324*)
- Skill modifiers (21, 59, 90, 91, 92, 190, 191, 262, 275, 276, 277)
- Weak buff effects: 42 (Wizard Spell Slots), 62 (Priest Spell Slots), 63 (Infravision), 111 (Create Magical Weapon), 188 (Aura Cleansing), 189 (Casting Time Modifier), 250 (Damage Modifier), 261 (Restore Lost Spells)

*318/324 are only substantive when NOT self-referencing (per Change 1).

**Soft** — opcodes that can appear in buffs but aren't buff effects themselves:
- 17 (Current HP / Healing) — instant heal, not an ongoing buff
- 171 (Give Ability) — re-granting mechanism, not a buff effect

In `ScoreOpcodes`, track a boolean `hasSubstantive` flag. Set it to true when any substantive opcode with a positive score contribution is encountered.

In `Classify`, after computing total score: if `score >= 3` but `hasSubstantive == false`, override classification to `isBuff = false, isAmbiguous = true`.

### Change 3: selfReplace Penalty

In `Classify`, if `selfReplace` is true (from opcode 321, or the new opcode 318 self-ref detection from Change 1), apply a score penalty of -8. Toggle/stance spells are not prebuffs.

### Change 4: BFBT Prefix Filter

In the scanner (`BfBot.Scan.GetCastableSpells`), skip any spell whose resref starts with `"BFBT"`. This filters BuffBot's own generated innate abilities.

## Impact Analysis

### False positives eliminated

| Spell | Score before | Score after | Mechanism |
|-------|-------------|-------------|-----------|
| Set Snare (SPCL412) | ~+5 | ~+5 but no substance | Substance check |
| Set Spike Trap (SPCL910) | ~+5 | ~+5 but no substance | Substance check |
| Contingency (SPIN141) | ~+8 | ~+8 but no substance | Substance check |
| Simbul's Matrix (SPIN145) | ~+8 | ~+8 but no substance | Substance check |
| Alchemy (GBALCHMG) | ~+5 | ~+5 but no substance | Substance check |
| Scribe Scrolls (GBSCRBMG) | ~+5 | ~+5 but no substance | Substance check |
| Tracking (SPCL922) | ~+7 | ~-5 | 318 discount + selfReplace -8 |
| Power Attack stance (C0FIG01) | ~+7 | ~-5 | 318 discount + selfReplace -8 |
| Expertise (C0FIG02) | ~+7 | ~-5 | 318 discount + selfReplace -8 |
| Rapid Shot (C0ARC03) | ~+7 | ~-5 | 318 discount + selfReplace -8 |
| Cure Light Wounds (SPIN101) | ~+9 | ~+9 but no substance | Substance check (only op=17) |
| Slow Poison (SPPR212) | ~+8 | ~+8 but no substance | Substance check (0 scoring ops) |
| Charm Animal (SPCL311) | ~+5 | ~-3 | 324 discount removes +8 |
| Fireburst (SPWI523) | ~+7 | ~+5 but no substance | 324 discount + substance check |
| War Cry (SPCL908) | ~+7 | ~+5 but no substance | 324 discount + substance check |
| BFBT innates | BUFF | filtered | Prefix filter in scanner |

### True buffs preserved

| Spell | Why still buff |
|-------|---------------|
| Haste (SPWI305) | op=16 Haste (substantive) |
| Stoneskin (SPWI408) | op=218 Stoneskin (substantive) |
| Bless (SPPR101) | op=130 Bless state (substantive) |
| Shield (SPWI114) | AC/resistance opcodes (substantive) |
| Death Ward (SPPR409) | op=101 Protection from Opcode (substantive) |
| Mirror Image (SPWI212) | op=119 Mirror Image (substantive) |
| Hardiness (SPCL907) | Resistance opcodes (substantive) |
| Berserker Rage (SPIN117) | Stat boosts + immunities (substantive) |
| Deathblow (SPCL902) | op=282 Set Spell State (substantive) |
| Critical Strike (SPCL905) | op=282 Set Spell State (substantive) |
| GWW (SPCL901) | op=282 Set Spell State (substantive) |
| Energy Blades (SPWI920) | op=111 Create Magical Weapon (substantive) |
| Improved Alacrity (SPWI921) | op=188 Aura Cleansing (substantive) |

### Edge cases

- **Opcode 171 (Give Ability) as non-substantive**: A hypothetical spell whose ONLY buff effect is granting a new ability would be classified as non-buff. This is acceptable — weapon-creating buffs use op=111 (substantive), not op=171. Abilities that use op=171 for re-granting (traps, HLAs) are correctly excluded.
- **Opcode 282 (Set Spell State) is substantive**: Combat HLAs (Deathblow, Critical Strike, GWW) work primarily through spell states. Keeping 282 as substantive preserves these as buffs.
- **Modded spells with custom mechanics**: The heuristic reads actual SPL data, not spell names. If a modded War Cry includes self-buff opcodes, it would correctly classify as buff. If it doesn't (like the current SCS version), it won't.

## Testing

Update `VerifyKnownSpells` test cases with new expectations:
- Add false positive spells as `expected = false` entries
- Verify real buffs still pass
- Run `ScanAll` and confirm reduced buff counts per character

Verify in-game:
- Deploy and run `BfBot.Test.RunAll()`
- Check spell lists in config UI — traps, setup spells, stances should no longer appear
- Confirm real buffs (Haste, Stoneskin, etc.) still present
