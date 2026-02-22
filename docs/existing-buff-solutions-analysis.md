# Existing Buff Automation Solutions — Analysis

> Landscape analysis of existing buff automation in BG:EE/BG2:EE. Covers Enhanced
> Powergaming Scripts, SCS AI casting patterns, built-in party AI, and the fundamental
> limitations of .BCS scripting that motivate BuffBot's EEex+Lua approach.

---

## 1. Enhanced Powergaming Scripts (EPS) — Deep-Dive

**Author**: SarahG | **Repo**: https://github.com/SarahG-579462/Enhanced-Powergaming-Scripts

Enhanced Powergaming Scripts is the most complete existing solution for automated party
buffing. It uses WeiDU-generated .BCS scripts — no Lua, no EEex dependency.

### Architecture

EPS uses a **template library system** to generate class/kit-specific scripts at install time:

```
enhanced-powergaming-scripts/
├── baf/
│   ├── normal/        # Standard-speed scripts (mocore.baf, mopal.baf, morang.baf, momonk.baf)
│   ├── accelerated/   # Instant-cast variants (same files, ReallyForceSpell + RemoveSpell)
│   ├── celestials/    # Summoned creature AI (devagood.baf, devaevil.baf, plangood.baf)
│   └── simulacrum/    # Simulacrum AI scripts
├── lib/               # WeiDU template libraries (.tph)
│   ├── core_base.tph, paladin_base.tph, ranger_base.tph, monk_base.tph
│   └── sr_*.tph       # Spell Revisions compatibility variants
├── components/        # Game-specific installation logic (BG2EE/, BGEE/, IWDEE/)
└── enhanced-powergaming-scripts.tp2
```

The installer detects game version + installed mods (Spell Revisions, SCS, Song & Silence,
Faiths & Powers, etc.) and cross-multiplies with class/kit/speed options to generate
**1.5+ million script variants**. Each variant is a complete .BCS file with hardcoded spell
references appropriate for that combination.

### Activation & Control

- **Hotkey "D"** toggles pre-buffing mode on/off
- Characters announce buffing start/completion via `DisplayStringHead()`
- Buffing auto-cancels on enemy detection (`See([EVILCUTOFF])`)
- No other player interaction — once triggered, the sequence runs to completion or interruption

### Buff Ordering Strategy

Buffs are cast in **longest duration first** order, determined at install time (not dynamically).
The typical sequence:

| Priority | Category | Examples |
|----------|----------|----------|
| 1 | Potions | Heroism, elemental resistance, giant strength |
| 2 | Fear/death protection | Remove Fear, Death Ward (self then party) |
| 3 | Evil/alignment protection | Protection From Evil 10' Radius, individual PfE |
| 4 | Defensive layers | Armor of Faith, Stoneskin, Iron Skins, Hardiness |
| 5 | Spell-based protection | Mirror Image, Blur, Fire Shield, Spell Turning, Globe of Invulnerability |
| 6 | Offensive/combat enhancement | Haste, Aid, Bless, Chant, Divine Might, Bard Song |
| 7 | Curative/preventative | Poison/disease removal, Vocalize, Sanctuary |
| 8 | Item abilities | Amulet of the Cheetah, Ring of Duplication, Ring of Spell Turning |

### Spell Type Handling

**Arcane vs divine**: Separate spell failure checks gate each casting attempt:
```
CheckStatLT(Myself, 20, SPELLFAILUREMAGE)    // Mage spells
CheckStatLT(Myself, 20, SPELLFAILUREPRIEST)  // Cleric/druid spells
```

**Self-only vs party-wide**: Self-only buffs (Armor of Faith, Spirit Armor) apply to self.
Party-wide buffs (Death Ward, Protection From Evil) cast on self first, then iterate visible
allies using `See()` targeting.

**State restrictions**: Scripts check for conditions that prevent casting — Wild Magic Areas,
Dead Magic Areas, silence (`CLERIC_INSECT_PLAGUE` stat), and spell failure rates.

### Cast Avoidance (Skip Already-Buffed)

EPS uses `CheckSpellState()` before recasting:
```
!CheckSpellState(Myself, DEATH_WARD)   // Don't recast if active
```

This is **imperfect** — not all buffs have corresponding SPLSTATE entries, and some stacking
interactions aren't captured. But it prevents the most common waste cases.

### Speed Modes

| Mode | Mechanism | Timing |
|------|-----------|--------|
| **Normal** | Standard `Spell()` / `ForceSpell()` | Engine aura cooldown (6 sec), natural casting speed |
| **Accelerated** | `ReallyForceSpell()` + `RemoveSpell()` | Near-instant, bypasses casting time |

Accelerated mode forces immediate spell execution then removes the spell from the spellbook
(slots restore at rest). This is essentially a "cheat mode" that still consumes spell
resources.

### Spell Slot Management

**Silent failure**: If a character runs out of slots, the engine simply fails the cast action.
EPS has no detection or notification for slot exhaustion — the character just stops buffing
without explanation.

### Script Pattern

The core BAF pattern:
```baf
// 1. Reset state on rest
IF
  !GlobalTimerNotExpired("MO_SpellCast", "LOCALS")
  Global("MO_BUFF", "LOCALS", 0)
THEN
  RESPONSE #100
    SetGlobal("MO_BUFF", "LOCALS", 0)
    SetGlobal("MO_UsedCheetah", "GLOBALS", 0)  // Reset item usage tracking
END

// 2. Hotkey activation
IF
  Global("MO_BUFF", "LOCALS", 0)
  HotKey(D)
THEN
  RESPONSE #100
    SetGlobal("MO_BUFF", "LOCALS", 1)
    DisplayStringHead(Myself, @1001)  // "Pre-buffing..."
END

// 3. Cast buff (gated by state checks)
IF
  Global("MO_BUFF", "LOCALS", 1)
  !See([EVILCUTOFF])
  CheckStatLT(Myself, 20, SPELLFAILUREPRIEST)
  !CheckSpellState(Myself, DEATH_WARD)
THEN
  RESPONSE #100
    ReallyForceSpell(Myself, CLERIC_DEATH_WARD)
    SetGlobalTimer("MO_SpellCast", "LOCALS", ONE_ROUND)
END

// 4. Cancel on enemy sight
IF
  Global("MO_BUFF", "LOCALS", 1)
  See([EVILCUTOFF])
THEN
  RESPONSE #100
    SetGlobal("MO_BUFF", "LOCALS", 0)
    DisplayStringHead(Myself, @1002)  // "Pre-buffing interrupted"
END
```

Key patterns: global flag gates (`MO_BUFF`), timer-based pacing (`MO_SpellCast`), item usage
tracking (`MO_UsedCheetah`), and enemy detection termination.

### What Users Cannot Configure

| Limitation | Impact |
|-----------|--------|
| **No in-game UI** | Must reinstall mod to change behavior |
| **No per-spell toggle** | Can't disable individual buffs (e.g., skip Haste) |
| **No per-target override** | Can't direct Protection From Evil at a specific party member |
| **No custom ordering** | Duration-based order is fixed; can't prioritize Stoneskin over Mirror Image |
| **No presets** | Single fixed sequence; no "long buffs" vs "short buffs" distinction |
| **No slot exhaustion feedback** | Characters silently stop with no explanation |
| **No buff overlap configuration** | Skip-if-active logic is hardcoded, not toggleable |
| **No export/import** | Config (such as it is) lives in the script file |

### Mod Compatibility

The installer auto-detects Spell Revisions, SCS, Song & Silence, Faiths & Powers, and
IWD Spells, generating appropriate script variants. This works because the spell lists are
determined at install time — but it means any spell mod installed after EPS requires
reinstallation.

---

## 2. SCS (Sword Coast Stratagems) — Casting Patterns

**Repo**: https://github.com/Gibberlings3/SwordCoastStratagems

SCS is primarily an enemy AI enhancement mod, but its casting architecture contains
sophisticated patterns applicable to any spell automation system.

### Architecture: 5-Layer System

```
Layer 1: WeiDU installer (.tpa)     — component selection, difficulty, mod detection
Layer 2: Macro templates (.tph)     — reusable code generation
Layer 3: SSL scripts (.ssl)         — spell decision logic (Script Scripting Language)
Layer 4: BAF/BCS scripts (.baf)     — compiled AI scripts for the engine
Layer 5: Data tables (.2da)         — spell prioritization per class archetype
```

SSL (Script Scripting Language) is SCS's custom preprocessor that compiles into BAF. It adds
macros, templates, and conditional compilation on top of the standard BAF trigger/response
model.

### Directory Structure (casting-relevant)

```
stratagems/
├── mage/
│   ├── ssl/combatblocks/       # 50+ individual spell decision blocks
│   │   ├── first_dispel.ssl    # Dispel escalation logic
│   │   ├── haste.ssl           # Haste precast pattern
│   │   ├── MS1.ssl             # Magic Shield tier 1 (Stoneskin, Mirror Image)
│   │   ├── area_effect.ssl     # AoE positioning logic
│   │   └── ...
│   ├── ssl/generalblocks/      # Shared patterns
│   │   ├── renew.ssl           # Buff renewal logic
│   │   └── easy.ssl            # Difficulty scaling
│   ├── spellchoices/vanilla/   # 13 class-specific spell priority tables
│   │   ├── fighter_mage.2da
│   │   ├── conjurer.2da
│   │   └── ...
│   └── scripts/                # 28+ named character scripts (semaj.baf, etc.)
├── priest/
│   ├── ssl/combatblocks/       # 48+ priest spell decision blocks
│   │   ├── my_defences.ssl     # Self-buff renewal
│   │   ├── group_buffing.ssl   # Party-wide buffs
│   │   └── ...
│   └── priest_shared.tph       # Script generation + spell allocation
├── caster_shared/
│   ├── caster_definitions.ssl  # Action template library (core patterns)
│   └── triggers/               # Trigger definitions and tables
└── lib/
    └── ai_shared.tph           # Shared AI code
```

### Modular Decision Blocks

Each `.ssl` file handles **one tactical decision** — "should I cast this category of spell
right now?" This is the core architectural insight: decompose complex AI into independent,
composable decision units.

**Priest defensive buff categories** (from `my_defences.ssl`), in priority order:

1. **Damage reflection/barriers**: Blade Barrier, Globe of Blades, Aura of Flaming Death
2. **Magical protection**: Shield of the Archons, Spell Turning, Magic Resistance
3. **Status enhancement**: Draw Upon Holy Might, Righteous Magic, Chaotic Commands

Each block has its own trigger conditions, cooldown timer, and state checks.

### Timer-Based Throttling

SCS prevents spell spam with **global timers at multiple granularities**:

| Timer | Duration | Purpose |
|-------|----------|---------|
| `"castspell"` | 6 rounds (~3 sec) | Base cooldown between any spell cast |
| `"redefend"` | 15 rounds (~7-8 sec) | Buff renewal cooldown (matches engine aura) |
| `"firstdispel"` | 1000 rounds (~8 min) | Prevents re-triggering high-impact decisions |
| Level-9 counter | Per-combat cap | Limits high-level spell usage via `IncrementGlobal()` |

### Spell State Checking (Cast Avoidance)

Before recasting any buff, SCS checks whether it's already active:
```
IF !CheckSpellState(Myself, REGEN)
   THEN Cast regeneration buff
```

This uses SPLSTATE.IDS values to detect active spell effects. Combined with the timer system,
it prevents both redundant casting and spam casting.

### Precast vs Combat Casting

SCS separates **pre-combat buffing** from **in-combat tactical casting**:

```
// Pre-combat: long-duration buffs
IF !InCombat()
   THEN Cast long-duration defensive buffs

// In-combat: tactical spells gated by cooldown
IF InCombat()
   AND GlobalTimerExpired("castspell", "LOCALS")
   THEN Cast tactical spell
```

This is directly relevant to BuffBot's preset model — "long buffs" maps to pre-combat, "short
buffs" maps to tactical/in-combat.

### Contextual Casting Gates

Buffs aren't applied indiscriminately. SCS adds proximity and situation checks:

```
// Only buff if enemies are nearby
IF Range(NearestEnemyOf(Myself), 10)
   THEN Cast defensive buff

// Only on appropriate difficulty
IF TriggerBlock(HardPlus)
   THEN Cast advanced buff
```

### Spell Prioritization Tables

Per-class `.2da` files define spell selection priority. Example from `fighter_mage.2da`:
- **Levels 1-2**: Sleep, Charm Person, Power Word Sleep (crowd control emphasis)
- **Levels 3-5**: Hold Person, Domination, Confusion (scaling incapacitation)
- **Levels 6-9**: Power Word Stun/Blind/Kill, Chain Lightning (high-power disable + damage)

This reflects that different archetypes have different optimal spell usage patterns.

### SSL Action Templates

`caster_definitions.ssl` defines reusable action templates:

| Template | Purpose |
|----------|---------|
| `Spell` | Standard spell cast with cooldown |
| `SpellNoDec` | Cast without decrementing slots (infinite casts) |
| `SpellMyself` | Self-targeted buff |
| `SpellPrecast` | Pre-combat buff |
| `SpellPrecastLong` | Extended-range precast |
| `SpellPrecastOutOfSight` | Precast without visibility requirement |
| `SpellArea` | AoE with visibility buff applied first |
| `SpellWand` / `SpellPotion` / `SpellScroll` | Consumable item variants |

Each template encapsulates: trigger validation → spell cast → timer set → side effects.

### Spell Failure Rate Checks

Before any cast, SCS verifies the caster isn't in a high-failure state:
```
CheckStatLT(Myself, 60, SPELLFAILUREMAGE)  // <60% failure rate
```

This prevents wasting high-level spell slots when the caster is affected by silence, Wild
Surge, or other interference effects.

### Tactical Escalation (Dispel Example)

`first_dispel.ssl` demonstrates SCS's escalation pattern:

1. Cast basic Dispel Magic
2. If that doesn't work → Dispel Magic + Greater Malison combo
3. If level 19+ → Preset sequencer: Death Spell + Dispel + Greater Malison
4. 1000-round cooldown prevents re-triggering

The AI doesn't just retry the same spell — it escalates through increasingly powerful
combinations. This is overkill for BuffBot's simpler "apply buffs in order" model but
demonstrates sophisticated decision trees.

---

## 3. Built-in Party AI Script Limitations

The BG:EE and BG2:EE games ship with **"Advanced AI"** scripts that new characters are
assigned by default (with spellcasting enabled).

### What the Built-in AI Does

- Casts a **small hardcoded list** of recognized spells during combat
- Manages basic targeting (attack nearest enemy)
- Uses abilities and some items
- Follows basic tactical positioning

### What the Built-in AI Does NOT Do

| Missing Feature | Impact |
|----------------|--------|
| **No pre-buffing** | Cannot cast buffs before combat starts |
| **Hardcoded spell list** | Many spells are unrecognized — Shield, Blur, Chromatic Orb, Larloch's Minor Drain are all ignored |
| **Poor spell decisions** | When the AI does cast, it often makes tactically poor choices |
| **Turn Undead conflicts** | Clerics with AI enabled stop turning undead and attack in melee instead |
| **Character import bugs** | Characters imported from BGEE to BG2EE have broken script timers |
| **No configuration** | The only options are "enable spellcasting" and "script swap" |
| **No mod awareness** | Mod-added spells are invisible to the built-in AI |

### Community Response

The built-in AI is so limited that the community has created multiple replacements:

- **uScript** (RichMartel) — comprehensive rewrite supporting all Beamdog spells and abilities
- **BP Series Party AI** — older script set with pre-buffing support
- **Enhanced Powergaming Scripts** — the most comprehensive solution (analyzed in §1)

The universal complaint: **the built-in AI treats spellcasters as melee fighters who
occasionally cast a spell**. There's no concept of a buffing phase, no spell prioritization,
and no resource management.

### Why Script Swapping Isn't Configuration

The only way to change AI behavior is `ChangeAIScript()` — swapping to a different pre-compiled
.BCS file. This means:

- Every behavior variation requires a **separate .BCS file** compiled before runtime
- Players must choose from a fixed menu of pre-built scripts
- There's no way to tweak a single setting without swapping the entire AI personality
- The game ships with a handful of scripts; mods can add more, but each is still static

---

## 4. Limitations of .BCS Scripting for Configurability

This section explains **why a pure .BCS script approach cannot achieve what BuffBot needs**,
and why EEex + Lua is necessary.

### Static Compilation

BAF (source) files are compiled into BCS (bytecode) by WeiDU or the engine's built-in
compiler — **once, before the game runs**. There is no mechanism to:

- Recompile scripts during gameplay
- Generate new trigger/response blocks at runtime
- Modify existing blocks based on player input

A script's behavior is **frozen at compile time**. The only runtime variation comes from
variable-gated branches, but the branches themselves must be pre-defined.

### No Dynamic Spell Enumeration

To reference a spell in BCS, you must name its **exact resref** (e.g., `SPWI305` for Haste):

```baf
// This works — hardcoded spell reference
IF HaveSpell("SPWI305") THEN
  RESPONSE #100 Spell(Myself, WIZARD_HASTE)
END

// This is IMPOSSIBLE — no variable/iterator support
IF HaveSpell(getNextSpell()) THEN ...
IF HaveAnyBuff() THEN ...
FOR EACH spell IN memorizedSpells DO ...
```

There is **no loop construct, no iterator, no way to enumerate a character's spellbook** in
BCS. Every spell the script might cast must be individually hardcoded. This is why EPS
generates 1.5M+ script variants — it's the only way to cover all class/kit/mod combinations.

**Contrast with EEex Lua**:
```lua
-- Dynamic spell enumeration at runtime
sprite:iterateKnownMageSpells(function(level, index, resref)
    -- Process each spell dynamically
end)
```

### No Runtime Introspection

BCS scripts cannot query engine state beyond their predefined trigger set:

| Can Do | Cannot Do |
|--------|-----------|
| `HaveSpell("SPWI305")` — check if specific spell memorized | Query "what spells does this character know?" |
| `CheckSpellState(Myself, 18)` — check if specific SPLSTATE active | Query "what buffs are currently active?" |
| `CheckStatGT(Myself, 15, STR)` — check a specific stat | Read SPL file data (duration, targeting, opcodes) |
| `Global("MyVar", "LOCALS", 1)` — check a variable | Store/retrieve complex configuration data |

The trigger system is a **fixed menu of boolean checks**, not a general-purpose query API. You
can ask "is X true?" but not "give me a list of all active effects" or "what's the duration of
this spell?"

### Variable Constraints

BCS variables are severely limited:

- **Name length**: 32 characters maximum
- **Value type**: Integer only (no strings, no tables, no arrays)
- **Scopes**: Global (game-wide), Local (per-creature), Area (per-map) — that's all
- **No structured data**: Cannot store a spell list, a preset configuration, or a targeting map

To store a BuffBot preset in BCS variables, you'd need something like:
```
BUFFBOT_P1_S01_ENABLED  = 1
BUFFBOT_P1_S01_TARGET   = 2
BUFFBOT_P1_S02_ENABLED  = 1
BUFFBOT_P1_S02_TARGET   = 0
... (hundreds of variables for a single preset)
```

This is technically possible but completely unmaintainable, and there's still no way to
dynamically iterate these variables or map them to spell resrefs.

**Contrast with EEex Lua**:
```lua
-- Arbitrary Lua table persisted in save game
local config = {
    presets = {
        ["Long Buffs"] = {
            { resref = "SPWI305", target = "party", enabled = true },
            { resref = "SPPR403", target = "self",  enabled = true },
        }
    }
}
EEex_GetUDAux(sprite)["BuffBot"] = config  -- Saved with the game
```

### No Data-Driven Casting

BCS cannot use variables as parameters to triggers or actions:

```baf
// IMPOSSIBLE — variables can't be used as spell parameters
IF Global("NextSpell", "LOCALS", spellID)
   HaveSpell(spellID)
THEN Spell(Myself, spellID)

// MUST hardcode every spell individually
IF HaveSpell("SPWI305") THEN Spell(Myself, WIZARD_HASTE)
IF HaveSpell("SPWI218") THEN Spell(Myself, WIZARD_MIRROR_IMAGE)
IF HaveSpell("SPWI108") THEN Spell(Myself, WIZARD_SHIELD)
// ... repeat for every spell in the game
```

This means **a BCS script's spell repertoire is fixed at compile time**. Adding support for
one new spell requires editing and recompiling the script.

### Script Switching Is the Only Runtime Option

`ChangeAIScript()` can swap to a different .BCS file at runtime, but:

- The replacement script must be **pre-compiled and already present** in the game files
- You're swapping the **entire AI personality**, not tweaking a single setting
- To support N configurations, you'd need N separate .BCS files
- Player-defined configurations would require **on-the-fly .BCS compilation**, which the
  engine cannot do

### What EEex Changes

EEex bypasses every limitation above by providing Lua access to engine internals:

| BCS Limitation | EEex Solution |
|---------------|---------------|
| No spell enumeration | `sprite:iterateKnownMageSpells()`, `sprite:getQuickButtons()` |
| No spell property inspection | `EEex_Resource_Demand()` → read SPL opcodes, duration, targeting |
| No complex config storage | `EEex_GetUDAux()` + marshal handlers → Lua tables in save games |
| No runtime UI | `.menu` files + Lua bindings → full GUI panels |
| No dynamic casting | `EEex_Action_AddSpriteAction()` → queue spell casts from Lua |
| No event hooks | `EEex_Sprite_AddMarshalHandlers()`, rest/area hooks |

**This is the fundamental reason BuffBot requires EEex**: the feature set (runtime
configurability, dynamic spell discovery, per-target assignment, preset management) is
literally impossible in pure .BCS.

---

## 5. Patterns to Reuse in BuffBot

### From Enhanced Powergaming Scripts

| Pattern | How to Adopt |
|---------|-------------|
| **Longest-duration-first default ordering** | Use as the default sort order for presets. Calculate duration from SPL data at runtime rather than hardcoding. |
| **`ReallyForceSpell()` for instant casting** | Use for cheat mode. Proven mechanism that bypasses casting time while still consuming resources. |
| **`DisplayStringHead()` for status feedback** | Announce buffing start, completion, interruption, and slot exhaustion over character portraits. |
| **Enemy detection cancellation** | Monitor for combat start (`See([EVILCUTOFF])` equivalent via EEex) and optionally interrupt buffing. Make this configurable (some players want to buff through combat). |
| **Spell failure rate gating** | Check `SPELLFAILUREMAGE` / `SPELLFAILUREPRIEST` before queuing a cast. Skip and notify if failure rate is too high. |
| **Item ability usage tracking** | Track activated item cooldowns via local variables to prevent double-activation. |

### From SCS

| Pattern | How to Adopt |
|---------|-------------|
| **Timer-based throttling** | Respect engine aura cooldown (6 seconds in BG2). Don't try to force-queue faster than the engine allows in normal mode. |
| **`CheckSpellState()` for skip-active-buff** | The most reliable method to detect active buffs. Use SPLSTATE.IDS values to check before casting. |
| **Precast vs combat separation** | Map directly to BuffBot's preset model: "Long Buffs" = pre-combat, "Short Buffs" = in-combat/tactical. |
| **Contextual proximity checks** | Optional setting: "only begin buffing when enemies are nearby" for immersion. |
| **Modular decision architecture** | Organize BuffBot's casting logic as independent, composable modules (spell enumeration, buff classification, queue building, cast execution). |
| **Spell failure checks before casting** | Gate each cast attempt on failure rate. SCS's `CheckStatLT(Myself, 60, SPELLFAILUREMAGE)` threshold is a good starting point. |
| **Difficulty-aware behavior** | Consider a "conservative mode" that respects SCS-like resource management (don't blow all high-level slots on buffs). |

### From Both

| Pattern | Details |
|---------|---------|
| **Hotkey/trigger activation** | Both use a clear activation mechanism. BuffBot should support at minimum a hotkey trigger, ideally a dedicated UI button. |
| **Self-first, then party** | For party-wide buffs, cast on self first, then iterate other party members. This is the natural order and both mods follow it. |
| **State announcements** | Characters announcing their buffing status is good UX feedback. BuffBot should maintain this. |
| **Mod compatibility via spell data** | Both achieve mod compatibility by reading spell data rather than maintaining separate lists. BuffBot takes this further with fully dynamic enumeration. |

---

## 6. Gaps BuffBot Fills

### Feature Comparison Matrix

| Capability | Built-in AI | EPS | SCS (enemy AI) | BuffBot |
|-----------|-------------|-----|-----------------|---------|
| Pre-combat buffing | No | Yes (hotkey) | Yes (precast blocks) | Yes (UI-triggered) |
| In-game configuration | No | No | No | **Yes** — full Lua UI panel |
| Per-spell enable/disable | No | No | N/A | **Yes** — toggle each buff |
| Per-target override | No | No | N/A | **Yes** — assign target per spell |
| Custom cast order | No | No (duration-fixed) | No (priority tables) | **Yes** — drag to reorder |
| Multiple presets | No | No | N/A | **Yes** — up to 5 independent presets |
| Dynamic spell discovery | No | No (install-time) | No (install-time) | **Yes** — runtime spellbook scan |
| Slot exhaustion feedback | No | No (silent fail) | N/A | **Yes** — skip + character notification |
| Buff overlap control | No | Partial (hardcoded) | Yes (state checks) | **Yes** — configurable skip/recast |
| Config saves with game | No | N/A (static) | N/A | **Yes** — EEex marshal handlers |
| Export/import presets | No | No | No | **Yes** — file-based |
| Mod-added spell support | No | Partial (reinstall) | Partial (reinstall) | **Yes** — automatic |
| Instant cast option | No | Yes (accelerated) | N/A | **Yes** — cheat mode |

### What BuffBot Uniquely Provides

**1. Runtime Configurability**
Every existing solution is configured at install time (or not at all). BuffBot is the first to
offer in-game, per-character, per-spell configuration via a Lua UI panel. Players can adjust
their buff setup mid-playthrough without reinstalling anything.

**2. Dynamic Spell Discovery**
EPS and SCS hardcode spell lists at install time — if you add a spell mod later, you need to
reinstall. BuffBot scans the character's actual spellbook at runtime, so mod-added spells,
HLAs, kit abilities, and anything else the character gains during play automatically appears in
the configuration panel.

**3. Preset System**
No existing solution supports presets. EPS has one fixed sequence; SCS has priority tables per
class. BuffBot's 5 independent presets let players define distinct buff sets for different
situations (long pre-dungeon buffs, short pre-fight buffs, boss fight prep, etc.) with
different spell selections, orderings, and targets.

**4. Per-Target Spell Assignment**
EPS applies self-only buffs to self and party buffs to the whole party — no per-spell override.
BuffBot lets players assign a specific party member as the target for any targetable buff
(e.g., "always cast Protection From Fire on the frontliner").

**5. Intelligent Feedback**
Slot exhaustion in EPS is a silent failure. BuffBot notifies the player via
`DisplayStringHead()` when a buff is skipped due to missing slots, and the UI reflects which
buffs were successfully cast vs skipped.

**6. Save-Integrated Persistence**
EPS configuration is the script file itself. BuffBot configuration persists in the save game
via EEex's marshal handler system, travels with the save, and can be exported/imported across
playthroughs.

### What BuffBot Does NOT Need to Solve

These are handled well by existing solutions or are out of scope:

- **Enemy AI casting** — SCS does this far better than BuffBot needs to; BuffBot is player-side only
- **Tactical spell escalation** — SCS's dispel chains and sequencer logic are for enemy AI; BuffBot just casts buffs in order
- **Difficulty scaling** — BuffBot's "difficulty" is player-configured via presets, not AI-difficulty-based
- **Combat AI** — BuffBot handles buffing only; actual combat decisions remain with whatever AI script the player uses
- **Consumables** — Deferred to post-MVP; EPS handles potions which is a reasonable reference when we get there
