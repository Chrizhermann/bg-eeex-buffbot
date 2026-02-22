# Spell System & Buff Classification Reference

> Technical reference for programmatically classifying spells as buffs at runtime
> using EEex's Lua API to read SPL file data. Opcode numbers and field offsets
> verified against [IESDP BG(2)EE](https://gibberlings3.github.io/iesdp/opcodes/bgee.htm).
>
> Confidence tags: **[VERIFIED]** = confirmed against IESDP or EEex source,
> **[INFERRED]** = high confidence from cross-referencing multiple sources,
> **[NEEDS-TESTING]** = requires runtime verification with EEex installed.

---

## 1. SPL File Structure

SPL V1 files define spells and abilities in the Infinity Engine. Each SPL consists of
three structures: a **header**, one or more **extended headers** (abilities), and
**feature blocks** (effects/opcodes).

### 1.1 SPL Header (114 bytes) **[VERIFIED]**

Fields relevant to buff classification:

| Offset | Size | Type | Field | BuffBot Use |
|--------|------|------|-------|-------------|
| 0x0008 | 4 | strref | Spell Name (unidentified) | Display name |
| 0x0018 | 4 | dword | Flags | Behavioral flags (bitfield) |
| 0x001C | 2 | word | Spell Type | 0=Special, 1=Wizard, 2=Priest, 3=Psionic, 4=Innate, 5=Bard Song |
| 0x001E | 4 | dword | Exclusion Flags | Class/alignment restrictions |
| 0x0025 | 1 | byte | Primary Type (School) | SCHOOL.IDS value — spell school |
| 0x0027 | 1 | byte | Secondary Type | MSECTYPE.IDS value — used by Breach/Dispel |
| 0x0034 | 4 | dword | Spell Level | 1-9 (wizard), 1-7 (priest) |
| 0x003A | 8 | resref | Spellbook Icon | BAM resource for UI display |
| 0x0050 | 4 | strref | Description (unidentified) | Tooltip text |
| 0x0064 | 4 | dword | Extended Header Offset | File offset to first ability |
| 0x0068 | 2 | word | Extended Header Count | Number of abilities |
| 0x006A | 4 | dword | Feature Block Table Offset | File offset to global feature blocks |
| 0x006E | 2 | word | Casting Feature Block Offset | Index into feature blocks for casting effects |
| 0x0070 | 2 | word | Casting Feature Block Count | Number of casting-time feature blocks |

**EEex access** (from `Spell_Header_st` userdata):
```lua
local header = EEex_Resource_Demand("SPWI305", "SPL")
-- Fields: header.spellType, header.spellLevel, header.primaryType,
--         header.secondaryType, header.abilityCount, header.flags
local name = Infinity_FetchString(header.spellName)
```

### 1.2 Extended Header / Ability (40 bytes each) **[VERIFIED]**

Each extended header represents a castable variant of the spell, typically one per
caster level bracket.

| Offset | Size | Type | Field | BuffBot Use |
|--------|------|------|-------|-------------|
| 0x0000 | 1 | byte | Spell Form | 1=Standard, 2=Projectile |
| 0x0001 | 1 | byte | **Flags** | **Bit 2 (0x04): Friendly ability** |
| 0x0002 | 2 | word | Location | 0=None, 2=Spell, 3=Item, 4=Innate |
| 0x0004 | 8 | resref | Memorised Icon | BAM for memorized display |
| 0x000C | 1 | byte | **Target Type** | **Primary targeting classification** |
| 0x000D | 1 | byte | Target Count | 0=area, 1+=selectable targets |
| 0x000E | 2 | word | Range | Distance in search-map units |
| 0x0010 | 2 | word | Min Caster Level | Minimum level for this ability variant |
| 0x0012 | 2 | word | Casting Time | In tenths of a round (6 = 1 round) |
| 0x0014 | 2 | word | Times Per Day | Uses/day for innates (0=unlimited) |
| 0x001E | 2 | word | Feature Block Count | Number of effects in this ability |
| 0x0020 | 2 | word | Feature Block Offset | Index into global feature block table |
| 0x0026 | 2 | word | Projectile | PROJECTL.IDS value + 1 |

#### Extended Header Target Type Values **[VERIFIED]**

| Value | Meaning | Buff Signal |
|-------|---------|-------------|
| 0 | Invalid | — |
| 1 | Living actor (any creature) | Ambiguous — could target friend or foe |
| 2 | Inventory item | Not a buff |
| 3 | Dead actor | Not a buff (raise dead / resurrection) |
| 4 | Any point / ground location | Ambiguous — area effect |
| 5 | Caster (self only) | **Strong buff indicator** |
| 7 | Caster (self, alternate) | **Strong buff indicator** |

#### Extended Header Flags **[VERIFIED]**

| Bit | Mask | Meaning | BuffBot Use |
|-----|------|---------|-------------|
| 2 | 0x04 | **Friendly ability** | **Primary buff signal — spell is flagged as beneficial** |

> The "Friendly ability" flag at offset 0x0001 bit 2 is the most direct engine-level
> signal that a spell is beneficial. When set, the engine treats the spell as targeting
> allies. This should be the first check in any classification algorithm.

**EEex access** (from `Spell_ability_st` userdata):
```lua
local ability = EEex_Resource_GetSpellAbilityForLevel(header, casterLevel)
-- Fields: ability.target, ability.range, ability.castingTime,
--         ability.featureBlockCount, ability.featureBlockOffset, ability.projectile
-- Flags byte needs direct field access or bitmask check
```

### 1.3 Feature Block / Effect (48 bytes each) **[VERIFIED]**

Each feature block is a single spell effect with an opcode, parameters, duration,
and save information.

| Offset | Size | Type | Field | BuffBot Use |
|--------|------|------|-------|-------------|
| 0x0000 | 2 | word | **Opcode Number** | **Effect type — core of buff classification** |
| 0x0002 | 1 | byte | Target Type | Who this effect applies to |
| 0x0003 | 1 | byte | Power | Spell level for dispel checks |
| 0x0004 | 4 | dword | Parameter 1 | Opcode-specific (magnitude, type, etc.) |
| 0x0008 | 4 | dword | Parameter 2 | Opcode-specific (subtype, mode, etc.) |
| 0x000C | 1 | byte | **Timing Mode** | **Duration type — key for duration classification** |
| 0x000D | 1 | byte | Dispel/Resistance | 0=normal, 1=dispellable, 2=bypass MR, 3=both |
| 0x000E | 4 | dword | **Duration** | **Effect length in seconds (for timing mode 0)** |
| 0x0012 | 1 | byte | Probability 1 | Upper bound of probability range (0-100) |
| 0x0013 | 1 | byte | Probability 2 | Lower bound (effect fires if roll is between P2 and P1) |
| 0x0014 | 8 | resref | Resource | Referenced resource (SPL, EFF, VVC, etc.) |
| 0x001C | 4 | dword | Dice Thrown / Max Level | Dice count or level cap |
| 0x0020 | 4 | dword | Dice Sides / Min Level | Dice sides or level floor |
| 0x0024 | 4 | dword | Saving Throw Type | Bitmask: 1=Spells, 2=Breath, 4=Death, 8=Wands, 16=Poly |
| 0x0028 | 4 | dword | Saving Throw Bonus | Modifier to save DC (negative = harder) |
| 0x002C | 4 | dword | Stacking ID | Same ID = non-stacking (TobEx/EE feature) |

#### Feature Block Target Type Values **[VERIFIED]**

| Value | Meaning | Notes |
|-------|---------|-------|
| 0 | None | Passive/global effects |
| 1 | Self (caster) | Effect applies only to caster |
| 2 | Pre-target | Creature/point that was targeted |
| 3 | Party | All party members |
| 4 | Everyone (all in area) | Friends and foes |
| 5 | Everyone except caster | |
| 6 | Caster's group | Allied creatures |
| 7 | Target at area | Area around target point |
| 8 | Single target | The targeted creature |
| 9 | Original caster | Source of the effect chain |

---

## 2. Buff Classification Strategy

### 2.1 Algorithm Overview

Classification uses a three-step approach: **targeting filter** → **opcode scoring**
→ **threshold check**, with manual override as a final layer.

```
┌─────────────────────────────────────────────────┐
│ 1. Check Extended Header flags & target type    │
│    → Friendly flag set?  → Likely buff          │
│    → Target 5/7 (self)? → Likely buff           │
│    → Target 1 + no friendly flag? → Ambiguous   │
│    → Target 4 (area)?   → Check projectile      │
├─────────────────────────────────────────────────┤
│ 2. Score all feature block opcodes              │
│    → Sum: +2 for buff opcodes                   │
│    → Sum: -3 for offensive opcodes              │
│    → Ignore visual/neutral opcodes              │
├─────────────────────────────────────────────────┤
│ 3. Combine signals                              │
│    → Friendly flag + positive score → BUFF      │
│    → No friendly flag + negative score → NOT    │
│    → Mixed/zero → flag for manual override      │
├─────────────────────────────────────────────────┤
│ 4. Check manual override table                  │
│    → User overrides always win                  │
└─────────────────────────────────────────────────┘
```

### 2.2 Step 1: Targeting Filter **[VERIFIED]**

Read the extended header for the spell at the caster's level:

```lua
local header = EEex_Resource_Demand(resref, "SPL")
local ability = EEex_Resource_GetSpellAbilityForLevel(header, casterLevel)
local targetType = ability.target  -- 0-7
-- Check friendly flag: ability flags byte, bit 2
```

| Condition | Signal |
|-----------|--------|
| Friendly ability flag (bit 2) set | +5 (strong buff signal) |
| Target type = 5 or 7 (self) | +3 (self-buff) |
| Target type = 1 (living actor) without friendly flag | 0 (ambiguous) |
| Target type = 4 (area) | 0 (ambiguous, check effects) |
| Target type = 3 (dead actor) | -5 (resurrection, not a buff to queue) |

### 2.3 Step 2: Opcode Scoring **[VERIFIED]**

Scan all feature blocks in the ability. For each opcode, add its score.
Skip opcodes used purely for visual effects, self-cleanup (op 321), or UI display.

#### Strong Buff Opcodes (score +2 each)

**Stat Modifiers:**

| Opcode | Name |
|--------|------|
| 0 | AC vs. Damage Type Modifier |
| 1 | Attacks Per Round Modifier |
| 6 | Charisma Modifier |
| 10 | Constitution Modifier |
| 15 | Dexterity Modifier |
| 19 | Intelligence Modifier |
| 22 | Cumulative Luck Bonus |
| 44 | Strength Modifier |
| 49 | Wisdom Modifier |
| 54 | THAC0 Modifier |
| 167 | THAC0 Modifier (Missiles) |
| 233 | Proficiency Modifier |
| 278 | To Hit Modifier |
| 284 | Melee THAC0 Modifier |
| 285 | Melee Weapon Damage Modifier |
| 286 | Missile Weapon Damage Modifier |
| 301 | Critical Hit Modifier |
| 305 | THAC0 Modifier (Off-Hand) |
| 306 | THAC0 Modifier (On-Hand) |
| 325 | Save vs. All |
| 345 | Enchantment Bonus |
| 346 | Save vs. School Bonus |

**Resistances:**

| Opcode | Name |
|--------|------|
| 27 | Acid Resistance Modifier |
| 28 | Cold Resistance Modifier |
| 29 | Electricity Resistance Modifier |
| 30 | Fire Resistance Modifier |
| 31 | Magic Damage Resistance Modifier |
| 84 | Magical Fire Resistance Modifier |
| 85 | Magical Cold Resistance Modifier |
| 86 | Slashing Resistance Modifier |
| 87 | Crushing Resistance Modifier |
| 88 | Piercing Resistance Modifier |
| 89 | Missiles Resistance Modifier |

**Saving Throws:**

| Opcode | Name |
|--------|------|
| 33 | Save vs. Death Modifier |
| 34 | Save vs. Wands Modifier |
| 35 | Save vs. Petrification/Polymorph Modifier |
| 36 | Save vs. Breath Weapons Modifier |
| 37 | Save vs. Spells Modifier |

**Buff States and Protections:**

| Opcode | Name |
|--------|------|
| 16 | Haste |
| 18 | Maximum HP Modifier |
| 20 | Invisibility |
| 65 | Blur |
| 69 | Non-Detection |
| 83 | Protection from Projectile |
| 98 | Regeneration |
| 100 | Protection from Creature Type |
| 101 | Protection from Opcode |
| 102 | Protection from Spell Levels |
| 119 | Mirror Image |
| 120 | Protection from Melee Weapons |
| 129 | Aid (state) |
| 130 | Bless (state) |
| 131 | Positive Chant (state) |
| 132 | Raise STR/CON/DEX Non-Cumulative |
| 133 | Luck Non-Cumulative |
| 153 | Sanctuary |
| 155 | Minor Globe of Invulnerability |
| 156 | Protection from Normal Missiles |
| 163 | Free Action |
| 166 | Magic Resistance Modifier |
| 218 | Stoneskin |
| 282 | Scripting State Modifier (Set Spell State) |
| 314 | Golem Stoneskin |
| 317 | Haste 2 |
| 328 | Set Extended or Spell State |
| 335 | Seven Eyes |

**Spell Protection and Bounce:**

| Opcode | Name |
|--------|------|
| 197 | Bounce (by Impact Projectile) |
| 198 | Bounce (by Opcode) |
| 199 | Bounce (by Power Level) |
| 200 | Bounce (by Power Level, decrementing) |
| 201 | Immunity (by Power Level, decrementing) |
| 202 | Bounce (by School) |
| 203 | Bounce (by Secondary Type) |
| 204 | Protection (by School) |
| 205 | Protection (by Secondary Type) |
| 206 | Protection from Spell |
| 207 | Bounce (by Resource) |
| 212 | Freedom |
| 223 | Immunity (by School, decrementing) |
| 226 | Immunity (by Secondary Type, decrementing) |
| 227 | Bounce (by School, decrementing) |
| 228 | Bounce (by Secondary Type, decrementing) |
| 259 | Spell Trap (by Power Level) |
| 292 | Backstab Protection |
| 299 | Chaos Shield |
| 302 | Can Use Any Item |
| 310 | Protection from Timestop |
| 318 | Protection from Resource |
| 324 | Immunity to Resource and Message |

**Skill Modifiers:**

| Opcode | Name |
|--------|------|
| 21 | Lore Modifier |
| 59 | Stealth Modifier |
| 90 | Open Locks Modifier |
| 91 | Find Traps Modifier |
| 92 | Pick Pockets Modifier |
| 190 | Attack Speed Factor |
| 191 | Casting Level Modifier |
| 262 | Visual Range |
| 275 | Hide in Shadows Modifier |
| 276 | Detect Illusion Modifier |
| 277 | Set Traps Modifier |

#### Weak Buff Opcodes (score +1 each)

| Opcode | Name | Reason |
|--------|------|--------|
| 17 | Current HP Modifier | Healing, not a sustained buff |
| 42 | Wizard Spell Slots Modifier | Buff-adjacent (only when positive) |
| 62 | Priest Spell Slots Modifier | Buff-adjacent (only when positive) |
| 63 | Infravision | Minor utility |
| 111 | Create Magical Weapon | Buff-adjacent |
| 171 | Give Ability | Grants new ability |
| 188 | Aura Cleansing | Beneficial utility |
| 189 | Casting Time Modifier | Buff when reducing cast time |
| 250 | Damage Modifier | Buff when increasing damage |
| 261 | Restore Lost Spells | Utility buff |

#### Strong Offensive Opcodes (score -3 each)

| Opcode | Name |
|--------|------|
| 5 | Charm Creature |
| 12 | Damage |
| 13 | Instant Death |
| 24 | Horror (Panic) |
| 25 | Poison |
| 38 | Silence |
| 39 | Unconsciousness (Sleep) |
| 40 | Slow |
| 45 | Stun |
| 55 | Kill Creature Type |
| 74 | Blindness |
| 76 | Feeblemindedness |
| 78 | Disease |
| 80 | Deafness |
| 109 | Hold |
| 128 | Confusion |
| 134 | Petrification |
| 157 | Web |
| 175 | Hold (II) |
| 185 | Hold (II, variant) |
| 209 | Kill 60HP |
| 210 | Stun 90HP |
| 211 | Imprisonment |
| 213 | Maze |
| 216 | Level Drain |
| 217 | Unconsciousness 20HP |
| 238 | Disintegrate |
| 241 | Control Creature |
| 264 | Drop Weapons in Panic |
| 333 | Static Charge |

#### Summoning Opcodes (score -2 each)

Not buffs — they create separate creatures rather than enhancing the caster/target.

| Opcode | Name |
|--------|------|
| 67 | Summon Creature |
| 151 | Replace Creature |
| 331 | Random Monster Summoning |

#### Neutral / Ignore Opcodes (score 0)

Visual effects, sounds, infrastructure — do not influence classification:

| Opcodes | Category |
|---------|----------|
| 7, 8, 9, 41, 50, 51, 52, 53, 61, 66 | Color and glow effects |
| 114, 138, 140, 141, 184, 215 | Casting graphics, animations |
| 139, 174, 327, 330 | Text display, sound effects |
| 142, 169, 240 | Portrait icon management |
| 271, 287, 291, 296, 315, 336, 339, 342 | Avatar/animation effects |
| 321, 337, 220, 221, 229, 230, 266 | Effect removal / self-cleanup |
| 82, 99, 103, 107, 187, 265, 309 | Script/variable management |
| 146, 147, 148, 177, 182, 183, 232, 234, 272, 283 | Spell casting infrastructure |

### 2.4 Step 3: Net Score Threshold

```lua
local totalScore = targetingScore + opcodeScore

if totalScore >= 3 then
    return "buff"           -- confident buff classification
elseif totalScore <= -3 then
    return "not_buff"       -- confident non-buff
else
    return "ambiguous"      -- flag for manual review
end
```

### 2.5 Step 4: Manual Override

User overrides are stored per-spell resref and persist across sessions. An override
always takes precedence over the algorithm.

```lua
-- Override table: resref → true (force buff) / false (force non-buff) / nil (auto)
local overrides = BuffBot_LoadOverrides()
if overrides[resref] ~= nil then
    return overrides[resref]
end
```

### 2.6 Secondary Type as Supporting Signal **[VERIFIED]**

The SPL header's secondary type (MSECTYPE.IDS, offset 0x0027) provides an additional
classification signal:

| MSECTYPE | Name | Buff Signal |
|----------|------|-------------|
| 0 | None | Neutral |
| 1 | Spell Protections | Buff (+2) |
| 2 | Specific Protections | Buff (+2) |
| 3 | Illusionary Protections | Buff (+2) |
| 4 | Magic Attack | Not buff (-2) |
| 5 | Divination Attack | Not buff (-1) |
| 6 | Conjuration | Neutral |
| 7 | Combat Protections | Buff (+2) |
| 8 | Contingency | Neutral |
| 9 | Battleground | Neutral |
| 10 | Offensive Damage | Not buff (-3) |
| 11 | Disabling | Not buff (-3) |
| 12 | Combination | Neutral |
| 13 | Non-Combat | Neutral |

---

## 3. Duration Classification

### 3.1 Time Units in BG:EE **[VERIFIED]**

| Unit | Equivalence | Duration Value (seconds) |
|------|-------------|-------------------------|
| 1 round | 6 seconds | 6 |
| 1 turn | 10 rounds | 60 |
| 1 hour (game time) | 5 turns = 50 rounds | 300 |

Feature block duration (offset 0x000E) is in **seconds** when timing mode = 0.

### 3.2 Timing Mode Values **[VERIFIED]**

Timing mode (feature block offset 0x000C) determines how duration is interpreted:

| Mode | Name | Duration Meaning | BuffBot Classification |
|------|------|------------------|----------------------|
| 0 | Instant/Limited | Duration field = seconds | Read duration value |
| 1 | Instant/Permanent | Lasts until dispelled or death | Treat as "long" |
| 2 | While Equipped | Active while item equipped | Item-only, skip for spells |
| 3 | Delayed/Limited | Delay, then temporary | Read duration value |
| 4 | Delayed/Permanent | Delay, then permanent until dispelled | Treat as "long" |
| 9 | Permanent (absolute) | Permanent stat change, survives death | Treat as "permanent" |
| 4096 | Absolute duration | Duration = specific game time point | Rare, treat as "long" |

Modes 5-8 and 10 are rarely used in practice.

### 3.3 Computing Effective Duration **[INFERRED]**

To determine a spell's effective duration:

1. Iterate all feature blocks in the ability
2. Skip visual-only and infrastructure opcodes (see neutral list above)
3. For each gameplay-affecting effect, record `(timingMode, duration)`
4. Take the **maximum duration** among all timing mode 0/3 effects
5. If any effect uses timing mode 1/4 (permanent until dispelled), classify as "long"
6. Some spells scale duration by caster level via multiple extended headers — use the
   ability matching the caster's level

```lua
local function getEffectiveDuration(header, casterLevel)
    local ability = EEex_Resource_GetSpellAbilityForLevel(header, casterLevel)
    if not ability then return 0, "unknown" end

    local maxDuration = 0
    local hasPermanent = false

    -- Iterate feature blocks for this ability
    for i = 0, ability.featureBlockCount - 1 do
        local fb = getFeatureBlock(header, ability.featureBlockOffset + i)
        if isGameplayOpcode(fb.opcode) then
            if fb.timingMode == 1 or fb.timingMode == 4 then
                hasPermanent = true
            elseif fb.timingMode == 0 or fb.timingMode == 3 then
                maxDuration = math.max(maxDuration, fb.duration)
            end
        end
    end

    if hasPermanent then return -1, "permanent" end
    return maxDuration, "timed"
end
```

### 3.4 Duration Thresholds

| Category | Duration | Examples |
|----------|----------|---------|
| **Short** | < 30 seconds (< 5 rounds) | Improved Haste (1 round/level at low levels), Protection from Magical Weapons (4 rounds) |
| **Medium** | 30-60 seconds (5-10 rounds) | Haste (3 rounds + 1/level), Draw Upon Holy Might (1 round/level) |
| **Long** | > 60 seconds (> 1 turn) | Stoneskin (12 hours), Bless (5 rounds + 1/level at high levels), Shield (5 rounds/level) |
| **Permanent** | Timing mode 1 or 4 | Protection from Evil (permanent until dispelled) |
| **Special** | Until charges depleted | Stoneskin (skins), Mirror Image (images) — duration is "long" but effect ends when consumed |

> For BuffBot preset purposes: "Long Buffs" preset = Long + Permanent.
> "Short Buffs" preset = Short + Medium, or anything the player wants re-cast frequently.

---

## 4. Spell Stacking Rules

### 4.1 Same-Opcode Stacking **[INFERRED]**

Many stat-modifying opcodes use Parameter 2 to control stacking behavior:

| Parameter 2 Value | Type | Stacking Behavior |
|-------------------|------|-------------------|
| 0 | Cumulative | **Stacks** — adds to existing value |
| 1 | Flat / Set | **Overwrites** — sets to fixed value, last applied wins |
| 2 | Percentage | **Stacks** — percentage modification |
| 3 | First-only | **Blocks** — only the first instance applies; later ones are ignored |

This applies to opcodes like 0 (AC), 1 (APR), 6/10/15/19/44/49 (ability scores),
33-37 (saving throws), 54 (THAC0), and most resistance opcodes.

**Example**: Two spells both applying opcode 0 (AC modifier) with type 0 (cumulative)
will stack. But Shield (type 1, set AC to value) will overwrite other type-1 AC effects.

### 4.2 Same-Spell Stacking (Opcode 321 Self-Replacement) **[VERIFIED]**

Many buff spells include opcode 321 (Remove Effects by Resource) targeting their own
resref as the first feature block. This means re-casting the spell removes the previous
instance before applying the new one — **self-replacing, not stacking**.

```
Spell SPPR111 (Armor of Faith):
  Feature Block 0: Opcode 321, Resource = "SPPR111"  ← removes previous cast
  Feature Block 1: Opcode 0, AC modifier, etc.
  ...
```

**BuffBot implication**: For self-replacing spells, there's no need to skip re-casting
if already active — the engine handles the replacement. But we should still detect this
pattern to avoid wasting spell slots on a buff that's already at full duration.

Detection:
```lua
local function isSelfReplacing(header, ability)
    -- Check if first feature block is opcode 321 targeting own resref
    local fb = getFeatureBlock(header, ability.featureBlockOffset)
    return fb and fb.opcode == 321 and fb.resource == header.resref
end
```

### 4.3 MSECTYPE and Breach/Dispel Removal **[VERIFIED]**

The SPL header's secondary type (MSECTYPE.IDS) determines which removal spells
can strip the buff:

| MSECTYPE | Name | Removed By |
|----------|------|------------|
| 1 | Spell Protections | Secret Word, Ruby Ray, Pierce Magic, Khelben's Warding Whip, Spell Strike |
| 2 | Specific Protections | Breach, Pierce Shield |
| 3 | Illusionary Protections | Oracle, True Sight |
| 7 | Combat Protections | Breach, Pierce Shield |

> **For BuffBot**: The secondary type is informational — it tells us what can strip the
> buff, but doesn't affect our "is it a buff?" classification. It may be useful for
> advanced features like "re-buff after Breach" detection.

### 4.4 Active Buff Detection for Skip Logic **[VERIFIED]**

To implement "skip if already active," use these methods in order of preference:

**Method 1: Spell States (fast, preferred)**

Many buff spells set a spell state via opcode 282 or 328. Check SPLSTATE.IDS:

```lua
local isActive = EEex_Sprite_GetSpellState(sprite, splstateID)
-- Returns boolean
```

See Section 6.4 for the complete SPLSTATE.IDS reference.

**Method 2: Effect Iteration (fallback)**

For spells that don't set a spell state, iterate the creature's active effects and
look for the spell's resref in the source resource field:

```lua
-- [NEEDS-TESTING] Modern EEex API for effect iteration
EEex_IterateActorEffects(spriteID, function(effectData)
    local sourceResref = readResref(effectData, 0x94)  -- offset in EFF v2.0
    if sourceResref == targetResref then
        -- Buff is active
    end
end)
```

**Method 3: Self-Replacing Detection**

If the spell uses opcode 321 self-replacement (see 4.2), re-casting is harmless —
the engine removes the old instance automatically. BuffBot can skip the active check
for these spells if the user prefers "always recast."

### 4.5 Key Resource-Based Opcodes **[VERIFIED]**

| Opcode | Name | Function |
|--------|------|----------|
| 206 | Protection from Spell | Blocks a specific spell (by resref) from affecting target |
| 318 | Protection from Resource | Blocks ALL effects from a specific resource (resref) |
| 321 | Remove Effects by Resource | Removes all active effects originating from a resource |
| 324 | Immunity to Resource (+ Message) | Like 318 but with a feedback string displayed |

---

## 5. Example Classifications

Each example walks through the algorithm for a well-known buff spell.

### 5.1 Bless (SPPR101) — Priest 1

| Property | Value |
|----------|-------|
| Resref | SPPR101 |
| Type | Priest, Level 1, School: Conjuration |
| Secondary Type | 0 (None) |
| Target | Living actor (1), Friendly flag likely set |
| Key Opcodes | 130 (Bless state), 54 (THAC0 +1), 23 (Morale +1), 282/328 (set spell state BLESS=22) |
| Duration | ~6 rounds (36 seconds) at typical levels |
| SPLSTATE | 22 (BLESS) |
| **Classification** | **BUFF** — friendly flag, party-wide, stat boosts |
| Stacking | Doesn't stack with itself (Bless state is either on or off) |
| Duration Class | Medium |

### 5.2 Chant (SPPR203) — Priest 2

| Property | Value |
|----------|-------|
| Resref | SPPR203 |
| Type | Priest, Level 2, School: Conjuration |
| Target | Living actor (1), area effect |
| Key Opcodes | 131 (Positive Chant state), 54 (THAC0 +1), 22 (Luck +1), 282/328 (set BENEFICIAL_CHANT=10) |
| Duration | Duration of chanting (sustained while caster doesn't act) |
| SPLSTATE | 10 (BENEFICIAL_CHANT) |
| **Classification** | **BUFF** — stat boosts, party-wide beneficial |
| Stacking | Doesn't stack with Bless (they use separate states but both give THAC0/luck) |
| Duration Class | Sustained / Medium |

### 5.3 Protection from Evil (SPPR107) — Priest 1

| Property | Value |
|----------|-------|
| Resref | SPPR107 |
| Type | Priest, Level 1, School: Abjuration |
| Secondary Type | 2 (Specific Protections) |
| Target | Living actor (1), single target, friendly |
| Key Opcodes | 0 (AC bonus -2 vs evil), 33-37 (saving throw bonuses +2 vs evil), 101 (Protection from opcode — charm immunity), 206 (Protection from Spell), 282/328 (set PROTECTION_FROM_EVIL=1) |
| Duration | Permanent until dispelled (timing mode 1) |
| SPLSTATE | 1 (PROTECTION_FROM_EVIL) |
| **Classification** | **BUFF** — friendly flag, protections + saving throws |
| Stacking | Non-stacking with itself (spell state check) |
| Duration Class | Permanent (until dispelled) |
| Notes | Also has a wizard version (SPWI113) |

### 5.4 Remove Fear (SPPR108) — Priest 1

| Property | Value |
|----------|-------|
| Resref | SPPR108 |
| Type | Priest, Level 1, School: Abjuration |
| Target | Living actor (1), friendly |
| Key Opcodes | 161 (Cure Horror — removes fear), 101 (Protection from opcode — fear immunity), 282/328 (set RESIST_FEAR=106) |
| Duration | Cure is instant; fear immunity lasts ~1 turn |
| SPLSTATE | 106 (RESIST_FEAR) |
| **Classification** | **BUFF** — cure + temporary immunity = pre-buff candidate |
| Duration Class | Medium (the immunity portion) |

### 5.5 Armor of Faith (SPPR111) — Priest 1

| Property | Value |
|----------|-------|
| Resref | SPPR111 |
| Type | Priest, Level 1, School: Necromancy |
| Secondary Type | 7 (Combat Protections) |
| Target | Caster (5), self only |
| Key Opcodes | 321 (self-remove SPPR111), 86-89 (physical resistance 5-25%), 27-31 (elemental resistance), 282/328 (set ARMOR_OF_FAITH=2) |
| Duration | 1 round/level |
| SPLSTATE | 2 (ARMOR_OF_FAITH) |
| **Classification** | **BUFF** — self-targeting, damage resistances |
| Stacking | Self-replacing via opcode 321 |
| Duration Class | Medium-Long (scales with level) |

### 5.6 Resist Fear (SPPR208) — Priest 2

| Property | Value |
|----------|-------|
| Resref | SPPR208 |
| Type | Priest, Level 2, School: Abjuration |
| Target | Living actor (1), area/party, friendly |
| Key Opcodes | 101 (Protection from opcode — fear/horror immunity), 161 (Cure Horror), 282/328 (set RESIST_FEAR=106) |
| Duration | 1 turn (60 seconds) |
| SPLSTATE | 106 (RESIST_FEAR) |
| **Classification** | **BUFF** — party-wide fear immunity |
| Duration Class | Long (1 turn) |

### 5.7 Draw Upon Holy Might (SPPR214) — Priest 2

| Property | Value |
|----------|-------|
| Resref | SPPR214 |
| Type | Priest, Level 2, School: Invocation |
| Target | Caster (5), self only |
| Key Opcodes | 44 (STR +1 per 3 levels), 10 (CON +1 per 3 levels), 15 (DEX +1 per 3 levels), 282/328 (set DRAW_UPON_HOLY_MIGHT=25) |
| Duration | 1 round/level |
| SPLSTATE | 25 (DRAW_UPON_HOLY_MIGHT) |
| **Classification** | **BUFF** — self-targeting, ability score boosts |
| Duration Class | Medium (scales with level) |

### 5.8 Protection from Fire (SPPR306) — Priest 3

| Property | Value |
|----------|-------|
| Resref | SPPR306 |
| Type | Priest, Level 3, School: Abjuration |
| Secondary Type | 2 (Specific Protections) |
| Target | Living actor (1), single target, friendly |
| Key Opcodes | 321 (self-remove SPPR306), 30 (Fire Resistance +80%), 84 (Magical Fire Resistance) |
| Duration | 5 rounds + 1 round/level |
| **Classification** | **BUFF** — friendly, fire resistance |
| Stacking | Self-replacing via opcode 321 |
| Duration Class | Long at higher levels |

### 5.9 Death Ward (SPPR409) — Priest 4

| Property | Value |
|----------|-------|
| Resref | SPPR409 |
| Type | Priest, Level 4, School: Necromancy |
| Secondary Type | 2 (Specific Protections) |
| Target | Living actor (1), single target, friendly |
| Key Opcodes | 101 (Protection from opcode — death effects, level drain, etc.), 282/328 (set DEATH_WARD=8) |
| Duration | Permanent until dispelled |
| SPLSTATE | 8 (DEATH_WARD) |
| **Classification** | **BUFF** — strong protection against death/level drain |
| Duration Class | Permanent |

### 5.10 Defensive Harmony (SPPR410) — Priest 4

| Property | Value |
|----------|-------|
| Resref | SPPR406 |
| Type | Priest, Level 4, School: Enchantment |
| Target | Living actor (1), party-wide, friendly |
| Key Opcodes | 0 (AC bonus), 33-37 (saving throw bonuses) |
| Duration | ~6 rounds (36 seconds) + level-based |
| **Classification** | **BUFF** — party-wide AC and saving throw bonuses |
| Duration Class | Medium |

### 5.11 Chaotic Commands (SPPR508) — Priest 5

| Property | Value |
|----------|-------|
| Resref | SPPR508 |
| Type | Priest, Level 5, School: Enchantment |
| Secondary Type | 2 (Specific Protections) |
| Target | Living actor (1), single target, friendly |
| Key Opcodes | 101 (Protection from opcodes: confusion, charm, hold, fear, etc.), 282/328 (set CHAOTIC_COMMANDS=41) |
| Duration | 1 turn/level |
| SPLSTATE | 41 (CHAOTIC_COMMANDS) |
| **Classification** | **BUFF** — strong mental protection |
| Duration Class | Long |

### 5.12 Shield (SPWI114) — Wizard 1

| Property | Value |
|----------|-------|
| Resref | SPWI114 |
| Type | Wizard, Level 1, School: Abjuration |
| Secondary Type | 7 (Combat Protections) |
| Target | Caster (5), self only |
| Key Opcodes | 0 (AC set to value — type 1/flat), 89 (Missiles Resistance), 156 (Protection from Normal Missiles), 282/328 (set WIZARD_SHIELD=126) |
| Duration | 5 rounds/level |
| SPLSTATE | 126 (WIZARD_SHIELD) |
| **Classification** | **BUFF** — self-targeting, AC and missile protection |
| Duration Class | Long |

### 5.13 Mirror Image (SPWI212) — Wizard 2

| Property | Value |
|----------|-------|
| Resref | SPWI212 |
| Type | Wizard, Level 2, School: Illusion |
| Secondary Type | 3 (Illusionary Protections) |
| Target | Caster (5), self only |
| Key Opcodes | 119 (Mirror Image — creates 2-8 images based on level), 282/328 (set spell state) |
| Duration | Until images depleted or 3 turns/level |
| SPLSTATE | (check SPLSTATE table) |
| **Classification** | **BUFF** — self-targeting, defensive images |
| Duration Class | Special — charges (images) deplete on hit |

### 5.14 Haste (SPWI305) — Wizard 3

| Property | Value |
|----------|-------|
| Resref | SPWI305 |
| Type | Wizard, Level 3, School: Transmutation |
| Target | Living actor (1), area/party, friendly |
| Key Opcodes | 16 (Haste — type 0: normal haste), 1 (APR +1), 126 (Movement rate bonus) |
| Duration | 3 rounds + 1 round/level |
| SPLSTATE | (state set varies) |
| **Classification** | **BUFF** — party-wide haste |
| Stacking | Normal Haste does NOT stack with Improved Haste |
| Duration Class | Medium (grows with level) |
| Notes | Haste causes 1-round fatigue after expiration |

### 5.15 Stoneskin (SPWI408) — Wizard 4

| Property | Value |
|----------|-------|
| Resref | SPWI408 |
| Type | Wizard, Level 4, School: Transmutation |
| Secondary Type | 7 (Combat Protections) |
| Target | Caster (5), self only |
| Key Opcodes | 218 (Stoneskin — absorbs physical hits, 1 skin per 2 levels), 282/328 (set STONESKIN=18) |
| Duration | Until skins depleted or 12 hours |
| SPLSTATE | 18 (STONESKIN) |
| **Classification** | **BUFF** — self-targeting, physical damage absorption |
| Duration Class | Special — charges (skins) deplete on hit; time duration is very long |
| Notes | Removed by Breach (secondary type 7 = Combat Protections) |

### 5.16 Spell Immunity (SPWI510) — Wizard 5

| Property | Value |
|----------|-------|
| Resref | SPWI510 |
| Type | Wizard, Level 5, School: Abjuration |
| Secondary Type | 1 (Spell Protections) |
| Target | Caster (5), self only |
| Key Opcodes | 204 (Protection by School), 206 (Protection from Spell), 282/328 (set SI_xxx spell states 56-63) |
| Duration | 24 hours |
| SPLSTATE | 56-63 (SI_ABJURATION through SI_TRANSMUTATION, depending on school chosen) |
| **Classification** | **BUFF** — self-targeting, spell school immunity |
| Duration Class | Long (effectively permanent for a game session) |
| Notes | Player chooses which school to be immune to; sets corresponding SI_* spell state |

### 5.17 Improved Haste (SPWI613) — Wizard 6

| Property | Value |
|----------|-------|
| Resref | SPWI613 |
| Type | Wizard, Level 6, School: Transmutation |
| Target | Living actor (1), single target, friendly |
| Key Opcodes | 16 (Haste — type 1: improved haste), 1 (APR doubled) |
| Duration | 1 round/level |
| **Classification** | **BUFF** — single target improved haste |
| Stacking | Does NOT stack with normal Haste (Haste overrides are managed by opcode 16 type) |
| Duration Class | Short-Medium (1 round/level) |

### 5.18 Protection from Magical Weapons (SPWI611) — Wizard 6

| Property | Value |
|----------|-------|
| Resref | SPWI611 |
| Type | Wizard, Level 6, School: Abjuration |
| Secondary Type | 7 (Combat Protections) |
| Target | Caster (5), self only |
| Key Opcodes | 120 (Protection from Melee Weapons — enchanted), 83 (Protection from Projectile), 282/328 (set PROTECTION_FROM_MAGICAL_WEAPONS=120) |
| Duration | 4 rounds |
| SPLSTATE | 120 (PROTECTION_FROM_MAGICAL_WEAPONS) |
| **Classification** | **BUFF** — self-targeting, weapon immunity |
| Duration Class | Short (4 rounds = 24 seconds) |
| Notes | Removed by Breach. Short duration makes it a "Short Buffs" preset spell |

### 5.19 Tenser's Transformation (SPWI603) — Wizard 6

| Property | Value |
|----------|-------|
| Resref | SPWI603 |
| Type | Wizard, Level 6, School: Transmutation |
| Target | Caster (5), self only |
| Key Opcodes | 44 (STR boost), 10 (CON boost), 15 (DEX boost), 0 (AC bonus), 18 (Max HP bonus), 1 (APR bonus), 145 (Disable Spell Casting), 282/328 (set TENSERS_TRANSFORMATION=112) |
| Duration | 1 round/level |
| SPLSTATE | 112 (TENSERS_TRANSFORMATION) |
| **Classification** | **BUFF** — despite disabling spellcasting, it's a deliberate self-buff for melee combat |
| Duration Class | Medium |
| Notes | **Edge case**: Contains opcode 145 (Disable Spell Casting) which would score -3 offensive. But the friendly flag, self-targeting, and stat boosts give a strong positive net score. The algorithm should still classify it correctly; if not, manual override handles it. |

### 5.20 Bard Song — Innate Ability

| Property | Value |
|----------|-------|
| Type | Innate, Bard Song (spell type 5) |
| Target | Area around caster, party-wide |
| Key Opcodes | 130 (Bless state), 22 (Luck), 23 (Morale), 54 (THAC0), varies by kit |
| Duration | **Sustained** — active only while bard is singing (modal action) |
| SPLSTATE | 85 (BARD_SONG), 86-91 for kit variants |
| **Classification** | **BUFF** — but requires special handling as a modal action, not a memorized spell |
| Duration Class | Sustained (active while modal state is engaged) |
| Notes | BuffBot should detect Bard Song as a special case: it's not cast from a spell slot but toggled as a modal action via MODAL.IDS. The bard cannot take other actions while singing (except with HLA Enhanced Bard Song). |

---

## 6. IDS Files Reference

### 6.1 SPELL.IDS — Spell Identification **[VERIFIED]**

Maps numeric spell IDs to resource references (resrefs). The encoding:

```
Numeric ID format: [prefix digit][3-digit spell number]

Prefix digit → Resref prefix:
  1 → SPPR  (Priest/Cleric)
  2 → SPWI  (Wizard/Mage)
  3 → SPIN  (Innate abilities)
  4 → SPCL  (Class/special abilities)

Examples:
  1101 → SPPR101 (Bless)
  1203 → SPPR203 (Chant)
  2305 → SPWI305 (Haste)
  2408 → SPWI408 (Stoneskin)
  3101 → SPIN101 (first innate ability)
```

**Resref naming convention:**
- `SP[TYPE][LEVEL][SEQUENCE]` where LEVEL is 1 digit and SEQUENCE is 2 digits
- SPWI305 = Wizard spell, level 3, spell #05
- SPPR107 = Priest spell, level 1, spell #07
- Mod-added spells use unused numbers in the standard ranges or high numbers

**EEex access:**
```lua
local ids = EEex_Resource_LoadIDS("SPELL")
local symbol = EEex_Resource_GetIDSStart(ids, 2305)  -- → "WIZARD_HASTE"

EEex_Resource_IterateUnpackedIDSEntries(ids, function(id, line, start)
    -- id: numeric (e.g. 2305)
    -- start: symbolic name (e.g. "WIZARD_HASTE")
end)

EEex_Resource_FreeIDS(ids)
```

### 6.2 SCHOOL.IDS — Spell Schools **[VERIFIED]**

| ID | School | Notes |
|----|--------|-------|
| 0 | None | Unclassified |
| 1 | Abjuration | Protections, wards, dispels |
| 2 | Conjuration | Summoning, creation |
| 3 | Divination | Detection, knowledge |
| 4 | Enchantment | Mind-affecting, charms |
| 5 | Illusion | Deception, images |
| 6 | Invocation (Evocation) | Direct damage, force |
| 7 | Necromancy | Death, undead, life drain |
| 8 | Transmutation (Alteration) | Physical changes, buffs |
| 9 | Generalist | No specific school |
| 10 | Wild Magic | Unpredictable effects (EE addition) |

Stored in SPL header at offset 0x0025 (Primary Type).

**Buff-leaning schools**: Abjuration (1), Transmutation (8) — most buff spells fall here.
**Offensive-leaning schools**: Invocation (6), Necromancy (7), Enchantment (4).
**Mixed**: Conjuration (2), Illusion (5), Divination (3).

### 6.3 MSECTYPE.IDS — Secondary Spell Types **[VERIFIED]**

| ID | Name | Buff? | Removed By |
|----|------|-------|------------|
| 0 | None | — | Dispel Magic (level check) |
| 1 | Spell Protections | Yes | Secret Word, Ruby Ray, Spell Strike |
| 2 | Specific Protections | Yes | Breach, Pierce Shield |
| 3 | Illusionary Protections | Yes | True Sight, Oracle |
| 4 | Magic Attack | No | — |
| 5 | Divination Attack | No | — |
| 6 | Conjuration | — | — |
| 7 | Combat Protections | Yes | Breach, Pierce Shield |
| 8 | Contingency | — | — |
| 9 | Battleground | — | — |
| 10 | Offensive Damage | No | — |
| 11 | Disabling | No | — |
| 12 | Combination | — | — |
| 13 | Non-Combat | — | — |

Stored in SPL header at offset 0x0027 (Secondary Type).

**Key insight for BuffBot**: Secondary types 1, 2, 3, 7 are definitionally buffs/protections.
If a spell has one of these secondary types, it is a buff — this can serve as a fast-path
classification before even scanning opcodes.

### 6.4 SPLSTATE.IDS — Spell States **[VERIFIED]**

Used with opcodes 282 and 328 to set/check spell states. Check via
`EEex_Sprite_GetSpellState(sprite, stateID)`.

**Buff-related spell states** (most commonly needed for active buff detection):

| ID | State | Typical Source Spell |
|----|-------|---------------------|
| 1 | PROTECTION_FROM_EVIL | Protection from Evil |
| 2 | ARMOR_OF_FAITH | Armor of Faith |
| 8 | DEATH_WARD | Death Ward |
| 9 | HOLY_POWER | Holy Power |
| 10 | BENEFICIAL_CHANT | Chant (positive) |
| 12 | BENEFICIAL_PRAYER | Prayer (positive) |
| 18 | STONESKIN | Stoneskin |
| 19 | IRON_SKINS | Iron Skins (Druid) |
| 20 | SANCTUARY | Sanctuary |
| 22 | BLESS | Bless |
| 23 | AID | Aid |
| 24 | BARKSKIN | Barkskin |
| 25 | DRAW_UPON_HOLY_MIGHT | Draw Upon Holy Might |
| 29 | FREE_ACTION | Free Action |
| 41 | CHAOTIC_COMMANDS | Chaotic Commands |
| 45 | CATS_GRACE | Cat's Grace |
| 56 | SI_ABJURATION | Spell Immunity: Abjuration |
| 57 | SI_CONJURATION | Spell Immunity: Conjuration |
| 58 | SI_DIVINATION | Spell Immunity: Divination |
| 59 | SI_ENCHANTMENT | Spell Immunity: Enchantment |
| 60 | SI_ILLUSION | Spell Immunity: Illusion |
| 61 | SI_EVOCATION | Spell Immunity: Evocation |
| 62 | SI_NECROMANCY | Spell Immunity: Necromancy |
| 63 | SI_TRANSMUTATION | Spell Immunity: Transmutation |
| 64-69 | BUFF_PRO_WEAPONS through BUFF_ILLUSION | Protection buff categories |
| 76 | BARBARIAN_RAGE | Barbarian Rage |
| 77 | BERSERKER_RAGE | Berserker Rage |
| 81 | DEFENSIVE_STANCE | Defensive Stance |
| 83 | CHAOS_SHIELD | Chaos Shield |
| 85-91 | BARD_SONG through ENHANCED_JESTER_SONG | Bard Song variants |
| 93 | ENCHANTED_WEAPON | Enchanted Weapon |
| 95 | SPIRIT_FORM | Spirit Form |
| 106 | RESIST_FEAR | Resist Fear / Remove Fear |
| 107 | PROTECTION_FROM_PETRIFICATION | Protection from Petrification |
| 108 | SPELL_SHIELD | Spell Shield |
| 109 | PROTECTION_FROM_NORMAL_MISSILES | Protection from Normal Missiles |
| 111 | PROTECTION_FROM_NORMAL_WEAPONS | Protection from Normal Weapons |
| 112 | TENSERS_TRANSFORMATION | Tenser's Transformation |
| 118 | HARDINESS | Hardiness (HLA) |
| 120 | PROTECTION_FROM_MAGICAL_WEAPONS | Protection from Magical Weapons |
| 121 | MANTLE | Mantle |
| 122 | IMPROVED_MANTLE | Improved Mantle |
| 123 | ABSOLUTE_IMMUNITY | Absolute Immunity |
| 126 | WIZARD_SHIELD | Shield (Wizard) |

**Debuff-related spell states** (useful for detecting active debuffs to cure):

| ID | State | Source |
|----|-------|--------|
| 0 | HOPELESSNESS | Hopelessness spell |
| 3 | NAUSEA | Nausea effects |
| 4 | ENFEEBLED | Enfeebled |
| 7 | HELD | Hold Person/Monster |
| 11 | DETRIMENTAL_CHANT | Chant (enemy) |
| 13 | DETRIMENTAL_PRAYER | Prayer (enemy) |
| 26 | ENTANGLE | Entangle |
| 27 | WEB | Web |
| 28 | GREASE | Grease |
| 38 | DEAFENED | Deafness |
| 42 | MISCAST_MAGIC | Miscast Magic |
| 43 | PAIN | Pain |
| 44 | MALISON | Malison (Greater) |
| 55 | DOOM | Doom |
| 70 | FAERIE_FIRE | Faerie Fire |
| 71 | GLITTERDUST | Glitterdust |

### 6.5 Building a Spell State Lookup Table **[INFERRED]**

At startup, BuffBot can build a mapping from spell resrefs to their SPLSTATE IDs by
scanning spells for opcodes 282 and 328:

```lua
local function buildSpellStateMap(resref, header)
    local states = {}
    -- Scan feature blocks for opcode 282 (Scripting State Modifier)
    -- and opcode 328 (Set Extended or Spell State)
    for each feature block do
        if fb.opcode == 282 or fb.opcode == 328 then
            table.insert(states, fb.parameter2)  -- parameter2 = state ID
        end
    end
    return states
end
```

This lets us quickly check active buffs via `EEex_Sprite_GetSpellState()` without
needing to iterate active effects at runtime.

---

## 7. Quick Reference: Opcode-to-Purpose Map

Complete lookup table for all opcodes referenced in this document, sorted by number:

| # | Name | Category |
|---|------|----------|
| 0 | AC vs. Damage Type | Buff (stat) |
| 1 | Attacks Per Round | Buff (combat) |
| 5 | Charm Creature | Offensive |
| 6 | Charisma Modifier | Buff (stat) |
| 10 | Constitution Modifier | Buff (stat) |
| 12 | Damage | Offensive |
| 13 | Instant Death | Offensive |
| 15 | Dexterity Modifier | Buff (stat) |
| 16 | Haste | Buff (combat) |
| 17 | Current HP Modifier | Heal (weak buff) |
| 18 | Maximum HP Modifier | Buff (stat) |
| 19 | Intelligence Modifier | Buff (stat) |
| 20 | Invisibility | Buff (defense) |
| 22 | Luck Bonus | Buff (stat) |
| 24 | Horror | Offensive |
| 25 | Poison | Offensive |
| 27-31 | Elemental Resistances | Buff (resistance) |
| 33-37 | Saving Throw Modifiers | Buff (stat) |
| 38 | Silence | Offensive |
| 39 | Unconsciousness/Sleep | Offensive |
| 40 | Slow | Offensive |
| 44 | Strength Modifier | Buff (stat) |
| 45 | Stun | Offensive |
| 49 | Wisdom Modifier | Buff (stat) |
| 54 | THAC0 Modifier | Buff (stat) |
| 65 | Blur | Buff (defense) |
| 67 | Summon Creature | Summoning |
| 69 | Non-Detection | Buff (defense) |
| 74 | Blindness | Offensive |
| 76 | Feeblemindedness | Offensive |
| 78 | Disease | Offensive |
| 83 | Protection from Projectile | Buff (defense) |
| 84-89 | Damage Type Resistances | Buff (resistance) |
| 98 | Regeneration | Buff (heal) |
| 100 | Protection from Creature Type | Buff (defense) |
| 101 | Protection from Opcode | Buff (defense) |
| 102 | Protection from Spell Levels | Buff (defense) |
| 109 | Hold | Offensive |
| 119 | Mirror Image | Buff (defense) |
| 120 | Protection from Melee Weapons | Buff (defense) |
| 128 | Confusion | Offensive |
| 129 | Aid | Buff (state) |
| 130 | Bless | Buff (state) |
| 131 | Positive Chant | Buff (state) |
| 134 | Petrification | Offensive |
| 153 | Sanctuary | Buff (defense) |
| 155 | Minor Globe | Buff (defense) |
| 156 | Prot. Normal Missiles | Buff (defense) |
| 157 | Web | Offensive |
| 163 | Free Action | Buff (defense) |
| 166 | Magic Resistance Modifier | Buff (stat) |
| 175 | Hold (II) | Offensive |
| 197-207 | Bounce/Immunity/Protection | Buff (spell defense) |
| 206 | Protection from Spell | Buff (spell defense) |
| 216 | Level Drain | Offensive |
| 218 | Stoneskin | Buff (defense) |
| 238 | Disintegrate | Offensive |
| 282 | Scripting State Modifier | Infrastructure (set spell state) |
| 292 | Backstab Protection | Buff (defense) |
| 299 | Chaos Shield | Buff (defense) |
| 310 | Protection from Timestop | Buff (defense) |
| 314 | Golem Stoneskin | Buff (defense) |
| 317 | Haste 2 | Buff (combat) |
| 318 | Protection from Resource | Buff (spell defense) |
| 321 | Remove Effects by Resource | Infrastructure (self-cleanup) |
| 324 | Immunity to Resource | Buff (spell defense) |
| 325 | Save vs. All | Buff (stat) |
| 328 | Set Extended/Spell State | Infrastructure (set spell state) |
| 335 | Seven Eyes | Buff (defense) |

---

## References

- [IESDP SPL V1 File Format](https://gibberlings3.github.io/iesdp/file_formats/ie_formats/spl_v1.htm)
- [IESDP BG(2)EE Opcodes](https://gibberlings3.github.io/iesdp/opcodes/bgee.htm)
- [IESDP SPLSTATE.IDS](https://gibberlings3.github.io/iesdp/files/ids/bgee/splstate.htm)
- [IESDP SPELL.IDS](https://gibberlings3.github.io/iesdp/files/ids/bgee/spell.htm)
- [Spell Types (BG Wiki)](https://baldursgate.fandom.com/wiki/Spell_types)
- [EEex API Surface](eeex-api-surface.md) — companion document for runtime access patterns
