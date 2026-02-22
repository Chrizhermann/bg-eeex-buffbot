# EEex API Surface Reference

> Reference document for BuffBot development. Covers EEex architecture, Lua APIs, UI
> integration, event hooks, and compatibility. Confidence levels annotated throughout:
> **[DOC]** = official docs, **[SRC]** = verified from EEex Lua source,
> **[INF]** = inferred from source/forums, **[UNC]** = uncertain / needs runtime verification.
>
> EEex repository: https://github.com/Bubb13/EEex
> EEex docs: https://eeex-docs.readthedocs.io/en/latest/
> IESDP (file formats): https://iesdp.bgforge.net/

---

## 1. How EEex Works

### Architecture Overview **[DOC]**

EEex is an executable-level modding framework for the Enhanced Edition Infinity Engine games.
It uses **in-memory patching** — a loader program modifies the game executable after it has
been placed into memory, before game code begins executing.

```
InfinityLoader.exe
  └─ Loads game executable into memory
  └─ Applies binary patches (function hooks, new code injection)
  └─ Hands control to patched game
       └─ Game's Lua environment now includes EEex functions
       └─ EEex Lua code runs alongside engine Lua code
```

### Key Technical Details **[DOC]** **[SRC]**

- **Loader**: `InfinityLoader.exe` (v0.9.0-alpha+) replaces the vanilla game executable as
  the launch target. The game will not function if launched without it.
- **Implementation language**: Most EEex functionality is implemented as **Lua code** that
  runs in the EE engine's built-in Lua environment. Binary patches are minimal — they
  primarily create bridges between C++ internals and Lua.
- **Userdata bridge**: C++ engine structures (CGameSprite, CDerivedStats, Spell_Header_st,
  etc.) are exposed to Lua as **userdata objects** with methods and field access. This is
  the core mechanism that lets Lua read/write engine internals.
- **Additions**: EEex adds custom Lua functions (~397), custom opcodes (#400-#402), new
  scripting actions/triggers/objects for BCS scripts, and UI extensions.
- **Module system**: EEex has one required core component plus 7 optional modules (effect
  menu, hotkey, timer, scale, empty container, time step, LuaJIT).

### Source File Layout **[SRC]**

The Lua source files in the EEex repository (`EEex/copy/`) define the API:
- `EEex_Sprite.lua` — party/character data, spell iterators, stats, state
- `EEex_Resource.lua` — resource loading (SPL, ITM, 2DA, IDS, etc.)
- `EEex_Action.lua` — action queue, spell casting, script execution
- `EEex_Menu.lua` — UI system extensions, template injection
- `EEex_GameObject.lua` — object lookup, type casting, effect application
- `EEex_GameState.lua` — lifecycle hooks, global variables
- `EEex_Key.lua` — keyboard input handling
- `EEex_Actionbar.lua` — action bar state, spell buttons
- `EEex_Trigger.lua` — BCS trigger evaluation from Lua
- `EEex_Utility.lua` — iterator helpers, memory management

---

## 2. Party / Character Data

### Iterating the Party **[DOC]** **[SRC]**

```lua
-- Get party size
local count = EEex_Sprite_GetNumCharacters()  -- → number

-- Get sprite by portrait slot (0-5)
local sprite = EEex_Sprite_GetInPortrait(0)    -- → CGameSprite | nil
local id     = EEex_Sprite_GetInPortraitID(0)  -- → number (-1 if empty)

-- Iterate all selected sprites
EEex_Sprite_IterateSelected(function(sprite)
    -- process each selected sprite
    -- return true to halt iteration early
end)

-- Get selection "leader" (highest portrait slot or first selected)
local leader   = EEex_Sprite_GetSelected()     -- → CGameSprite | nil
local leaderID = EEex_Sprite_GetSelectedID()   -- → number (-1 if none)

-- All selected IDs as a table
local ids = EEex_Sprite_GetAllSelectedIDs()    -- → table of numbers
```

### Reading Character Properties **[DOC]** **[SRC]**

```lua
-- Character name
-- Implementation: sprite.m_sName.m_pchData:get()
local name = EEex_Sprite_GetName(sprite)                -- → string

-- Portrait index (-1 if not a party member)
local idx = EEex_Sprite_GetPortraitIndex(sprite)        -- → number

-- Active (derived) stats structure
local stats = EEex_Sprite_GetActiveStats(sprite)        -- → CDerivedStats

-- Read a specific stat by offset (uses STATS.IDS values)
-- Implementation: sprite:getActiveStats():GetAtOffset(statID)
local hp  = EEex_Sprite_GetStat(sprite, 1)              -- → number (HP)
local str = EEex_Sprite_GetStat(sprite, 36)             -- → number (STR)

-- General state flags (STATE.IDS values, bitfield)
-- Implementation: sprite:getActiveStats().m_generalState
local state = EEex_Sprite_GetState(sprite)              -- → number
```

**Common STATS.IDS values** relevant to BuffBot:

| ID | Stat | Notes |
|----|------|-------|
| 1 | MAXHITPOINTS | |
| 17 | HITPOINTS | Current HP |
| 34 | LEVEL | First class level |
| 36-42 | STR through CHA | Ability scores |
| 67 | WIZARD_SLOTSI_1 | Wizard spell slots L1 |
| 95 | CLERIC_SLOTS1 | Priest spell slots L1 |
| 96 | CLASS | |
| 101 | KIT | Kit ID |
| 152 | LEVEL2 | Dual/multi second class |
| 153 | LEVEL3 | Triple-class third class |

### Object Lookup **[DOC]**

```lua
-- Get any game object by ID — returns the specific subtype
local obj = EEex_GameObject_Get(objectID)
-- → CGameSprite | CGameContainer | CGameDoor | ... | nil

-- Check if an object is a living sprite
local isSprite = EEex_GameObject_IsSprite(obj, false)   -- → boolean
-- allowDead parameter: if true, dead sprites also return true

-- Cast to the object's true type (for generic CGameObject references)
local typed = EEex_GameObject_CastUserType(obj)
```

### Local Variables (per-creature, saved in game) **[SRC]**

```lua
-- Implementation: sprite.m_pLocalVariables:getInt(name)
EEex_Sprite_GetLocalInt(sprite, "BUFFBOT_PRESET")       -- → number
EEex_Sprite_SetLocalInt(sprite, "BUFFBOT_PRESET", 2)

EEex_Sprite_GetLocalString(sprite, "BUFFBOT_CONFIG")    -- → string
EEex_Sprite_SetLocalString(sprite, "BUFFBOT_CONFIG", "data...")
```

> **Note for BuffBot**: Local variables persist in save games. This is the natural place to
> store per-character buff configuration. Variable names are max 32 characters.

---

## 3. Spell Enumeration

### Iterator Chain Pattern **[SRC]**

EEex provides a layered iterator pattern for spell enumeration. Each layer adds validation:

```
GetKnownSpellsIterator          → yields (level, index, resref)
  └─ GetValidKnownSpellsIterator   → yields (level, index, resref, spellHeader)
       └─ GetKnownSpellsWithAbilityIterator → yields (level, index, resref, header, ability)
```

- **Known**: Raw spellbook entries from the CRE creature data
- **Valid**: Filters to spells whose .SPL resource can actually be loaded
- **WithAbility**: Pairs each spell with the Spell_ability_st matching the caster's level

### Wizard Spells **[SRC]**

```lua
-- Known wizard spells (raw spellbook)
-- Levels 1-9, defaults to full range
-- Implementation: calls CGameSprite.GetKnownSpellMage(sprite, level-1, index)
for level, index, resref in EEex_Sprite_GetKnownMageSpellsIterator(sprite, 1, 9) do
    -- level: 1-9, index: 0-based within level, resref: e.g. "SPWI101"
end

-- Valid wizard spells (resource exists)
for level, index, resref, header in EEex_Sprite_GetValidKnownMageSpellsIterator(sprite) do
    -- header: Spell_Header_st userdata
end

-- With ability data (matched to caster level)
for level, index, resref, header, ability in
    EEex_Sprite_GetKnownMageSpellsWithAbilityIterator(sprite, 1, 9) do
    -- ability: Spell_ability_st userdata
    -- Contains target type, range, casting time, projectile, etc.
end
```

### Priest Spells **[SRC]**

```lua
-- Levels 1-7 for divine magic
for level, index, resref in EEex_Sprite_GetKnownPriestSpellsIterator(sprite, 1, 7) do
end

for level, index, resref, header in EEex_Sprite_GetValidKnownPriestSpellsIterator(sprite) do
end

for level, index, resref, header, ability in
    EEex_Sprite_GetKnownPriestSpellsWithAbilityIterator(sprite, 1, 7) do
end
```

### Innate Abilities **[SRC]**

```lua
-- Innates use fixed level 1 (no level parameter)
-- Implementation: calls CGameSprite.GetKnownSpellInnate(sprite, 0, index)
for level, index, resref in EEex_Sprite_GetKnownInnateSpellsIterator(sprite) do
end

for level, index, resref, header in EEex_Sprite_GetValidKnownInnateSpellsIterator(sprite) do
end
```

### Generic Spell Iterator Helpers **[SRC]**

```lua
-- Validate an arbitrary resref iterator against loadable SPL resources
-- Wraps any iterator yielding resrefs → yields (resref, spellHeader)
for resref, header in EEex_Resource_GetValidSpellsIterator(myResrefIterator) do
end

-- Pair validated spells with caster-level-appropriate abilities
-- Takes an iterator yielding (resref, header) → yields (resref, header, ability)
for resref, header, ability in
    EEex_Sprite_GetSpellsWithAbilityIterator(sprite, validSpellsItr) do
end

-- Combine both: validate + pair abilities in one call
for resref, header, ability in
    EEex_Sprite_GetValidSpellsWithAbilityIterator(sprite, rawResrefItr) do
end
```

### Caster Level **[SRC]**

```lua
-- Get effective caster level for a specific spell
-- Implementation: constructs CSpell from resref, calls sprite:GetCasterLevel()
local casterLvl = EEex_Sprite_GetCasterLevelForSpell(sprite, "SPWI304", true)
-- sprite: CGameSprite
-- "SPWI304": spell resref
-- true: include wild mage level bonus
-- Returns: integer caster level
```

### Memorized Spell Slots **[UNC]**

> **GAP**: No `GetMemorizedSpell*Iterator` functions were found in the EEex source. The
> "known spells" iterators enumerate the **spellbook** (what spells a character knows), not
> what's currently **memorized and available to cast**.
>
> Possible approaches to determine castability:
> 1. **Actionbar button data**: `EEex_Actionbar_GetSpellButtonData()` and
>    `EEex_Sprite_GetSpellButtonDataIteratorFrom2DA()` may reflect currently castable spells
> 2. **CGameSprite internal fields**: The CRE format has memorized spell sections; EEex
>    userdata may expose `GetMemorizedSpellMage(level, index)` on the CGameSprite object
>    even if no top-level wrapper function exists
> 3. **Stat-based slot counts**: `EEex_Sprite_GetStat()` with WIZARD_SLOTSI_* / CLERIC_SLOTS*
>    stat IDs gives total slot counts per level
> 4. **BCS action approach**: Use `Spell()` action which naturally fails if no slot available
>
> **This needs runtime verification with EEex installed.**

---

## 4. Reading Spell Properties

### Loading Spell Resources **[SRC]**

```lua
-- Load a spell into memory and get its header
-- Implementation: binary search in engine resource cache, then Demand() to load
-- Returns Spell_Header_st userdata, or nil if not found
local header = EEex_Resource_Demand("SPWI304", "SPL")

-- Lower-level: find resource in cache without loading into memory
local res = EEex_Resource_Fetch("SPWI304", "SPL")  -- → CResSpell | nil
```

`EEex_Resource_Demand` handles type-specific casting internally:
- `"SPL"` → `Spell_Header_st`
- `"ITM"` → `Item_Header_st`
- `"EFF"` → `CGameEffectBase`
- `"PRO"` → `CProjectileFileFormat` (or BAM/Area subtype)

### Spell_Header_st Fields **[SRC]** **[DOC]**

IESDP SPL V1.0 format. Key fields accessible via userdata:

| Field | Type | Description |
|-------|------|-------------|
| `spellType` | word | 0=Special, 1=Wizard, 2=Priest, 3=Psionic, 4=Innate, 5=Bard Song |
| `primaryType` | byte | School of magic (SCHOOL.IDS) |
| `secondaryType` | byte | Secondary type / sectype (MSECTYPE.IDS) |
| `spellLevel` | dword | Spell level (1-9 wizard, 1-7 priest) |
| `spellName` | dword | String reference (unidentified name) |
| `spellDescription` | dword | String reference (identified description) |
| `abilityCount` | word | Number of extended headers (abilities) |
| `abilityOffset` | dword | File offset to first Spell_ability_st |
| `spellbookIcon` | resref | BAM resource for spellbook icon |
| `flags` | dword | Behavioral flags (bit-mapped) |
| `exclusionFlags` | dword | Class/alignment exclusion flags |
| `castingGraphics` | word | Animation type ID for casting |

### Spell_ability_st Fields **[SRC]** **[DOC]**

Extended header (40 bytes per ability). One spell can have multiple abilities for
different caster levels.

| Field | Type | Description |
|-------|------|-------------|
| `target` | byte | 0=Invalid, 1=Living actor, 2=Inventory, 3=Dead actor, 4=Any point, 5=Caster, 7=Self-cast |
| `targetCount` | byte | Number of targets selectable |
| `range` | word | Distance in search-map units |
| `minCasterLevel` | word | Minimum caster level for this ability |
| `castingTime` | word | In tenths of a round |
| `timesPerDay` | word | Uses per day (for innates) |
| `projectile` | word | Projectile type ID (PROJECTL.IDS + 1) |
| `featureBlockCount` | word | Number of effects |
| `featureBlockOffset` | word | Index into global effect table |
| `spellForm` | byte | 1=Standard, 2=Projectile |
| `memorisedIcon` | resref | BAM for memorized icon |

### Accessing Abilities **[SRC]**

```lua
-- Get ability by 0-based index
local ability = EEex_Resource_GetSpellAbility(header, 0)
-- → Spell_ability_st | nil (nil if index >= abilityCount)

-- Get ability matching a caster level (finds highest qualifying)
-- Iterates abilities, returns last one where casterLevel >= ability.minCasterLevel
local ability = EEex_Resource_GetSpellAbilityForLevel(header, casterLevel)
-- → Spell_ability_st | nil (nil if no abilities or none qualify)
```

### Reading String References **[DOC]**

```lua
-- Convert strref to displayable string
local spellName = Infinity_FetchString(header.spellName)
local spellDesc = Infinity_FetchString(header.spellDescription)
```

### 2DA Resource Access **[DOC]**

For reading game tables (spell lists, kit tables, etc.):

```lua
local tbl = EEex_Resource_Load2DA("SPLSHMUT")
local cols, rows = EEex_Resource_Get2DADimensions(tbl)
local value = EEex_Resource_GetAt2DALabels(tbl, "COLUMN_NAME", "ROW_NAME")
local value = EEex_Resource_GetAt2DAPoint(tbl, colIndex, rowIndex)

-- Iteration
EEex_Resource_Iterate2DARowLabel(tbl, "ROW_NAME", function(colIndex, value)
    -- process each column value in the row
end)

-- Cleanup (optional — garbage collected)
EEex_Resource_Free2DA(tbl)
```

### IDS File Access **[DOC]**

```lua
local ids = EEex_Resource_LoadIDS("SPELL")
local hasEntry = EEex_Resource_IDSHasID(ids, 1234)     -- → boolean
local symbol   = EEex_Resource_GetIDSLine(ids, 1234)   -- → string (full line)
local name     = EEex_Resource_GetIDSStart(ids, 1234)   -- → string (before first paren)

EEex_Resource_IterateUnpackedIDSEntries(ids, function(id, line, start)
    -- id: numeric, line: full string, start: string before paren
end)

EEex_Resource_FreeIDS(ids)
```

---

## 5. Checking Active Buffs / Effects

### Spell States (Primary Method) **[SRC]**

The preferred way to check if a specific buff is active. Uses SPLSTATE.IDS values.
Many buff spells set spell states via opcode #282 (Set Spell State).

```lua
-- Implementation: sprite:getActiveStats():GetSpellState(spellStateID) ~= 0
local hasHaste = EEex_Sprite_GetSpellState(sprite, 1)   -- → boolean
-- spellStateID: integer from SPLSTATE.IDS
```

**Common SPLSTATE.IDS values** (BG2:EE):

| ID | Spell State | Typical Source Spells |
|----|-------------|----------------------|
| 1 | HASTE | Haste, Improved Haste |
| 2 | SLOW | Slow |
| 35 | PROTECTION_FROM_EVIL | Protection from Evil |
| 44 | STONESKIN | Stoneskin |
| 47 | MIRROR_IMAGE | Mirror Image |
| 55 | BLESS | Bless |
| 68 | CHAOTIC_COMMANDS | Chaotic Commands |
| 73 | DEATH_WARD | Death Ward |
| 78 | FREE_ACTION | Free Action |
| 88 | PROTECTION_FROM_FIRE | Protection from Fire |
| 89 | PROTECTION_FROM_COLD | Protection from Cold |
| 95 | PROTECTION_FROM_LIGHTNING | Protection from Lightning |
| 101 | PROTECTION_FROM_ACID | Protection from Acid |

> **Note**: Not all buff spells set spell states. Some older/modded spells may only apply
> effects without a corresponding SPLSTATE entry. For those, effect iteration is needed.

### Stat Checking **[SRC]**

Some buffs modify stats that can be checked directly:

```lua
-- Check if a stat-modifying buff is active by reading the derived stat
local ac = EEex_Sprite_GetStat(sprite, 4)          -- ARMORCLASS
local thac0 = EEex_Sprite_GetStat(sprite, 26)      -- THAC0
local saveDeath = EEex_Sprite_GetStat(sprite, 29)  -- SAVEVSDEATH
```

### Effect Iteration **[INF]**

For checking specific applied effects when spell states aren't available:

```lua
-- Older EEex API pattern (from forum references, may be refactored in v0.9.0+)
EEex_IterateActorEffects(actorID, function(effectOffset)
    -- effectOffset: base address of CGameEffect structure
    -- Read fields using EFF v2.0 offsets:
    --   +0x10: opcode (dword)
    --   +0x14: target (dword)
    --   +0x18: power (dword)
    --   +0x1C: parameter1 (dword)
    --   +0x20: parameter2 (dword)
    --   +0x2C: duration (dword)
    --   +0x94: resource (resref, 8 bytes) — source spell resref
end)
```

> **[UNC]**: The `EEex_IterateActorEffects` function was found in forum posts referencing
> older EEex versions. In v0.9.0+ (x64 rewrite), effect access may use the userdata pattern
> instead of raw memory offsets. The `EEex_Opcode_AddListsResolvedListener` hook fires after
> effects processing and may be the modern approach.

### Applying Effects Directly **[DOC]**

```lua
-- Apply an effect matching the EFF v2.0 file format
EEex_GameObject_ApplyEffect(sprite, {
    effectID = 142,           -- opcode number (required)
    duration = 120,           -- game ticks
    durationType = 1,         -- 0=instant, 1=timed, 2=permanent, etc.
    -- ... ~30 optional fields matching EFF offsets
    sourceRes = "SPWI304",   -- source spell resref
})
```

---

## 6. Triggering Spell Casting

### Normal Casting (Action Queue) **[DOC]** **[SRC]**

Queues BCS script actions on a sprite's AI action queue, behaving identically to
`C:Eval()` in the console. The engine processes actions subject to normal game rules
(aura cooldown, casting time, interrupts, line of sight).

```lua
-- Queue a response string (compiles + queues in one call)
EEex_Action_QueueResponseStringOnAIBase(
    'Spell("SPWI304",Myself)',   -- BCS action syntax
    sprite                        -- CGameAIBase (CGameSprite is a subtype)
)

-- For repeated use: compile once, queue many times
local script = EEex_Action_ParseResponseString('ForceSpell("SPPR103",Myself)')
-- script: CAIScriptFile — must be freed when done

EEex_Action_QueueScriptFileResponseOnAIBase(script, sprite1)
EEex_Action_QueueScriptFileResponseOnAIBase(script, sprite2)

-- IMPORTANT: free compiled script when no longer needed
EEex_Action_FreeScriptFile(script)
-- or: script:free()
```

**BCS Spell Actions** (from ACTION.IDS):

| Action | Behavior |
|--------|----------|
| `Spell(resref, target)` | Normal cast — uses memorized slot, full cast time, can be interrupted |
| `ForceSpell(resref, target)` | Doesn't need memorized slot, cannot be interrupted |
| `ReallyForceSpell(resref, target)` | Like ForceSpell, handles all edge cases |
| `SpellNoDec(resref, target)` | Normal cast without decrementing memorized count |
| `SpellPoint(resref, x, y)` | Cast at ground coordinates |
| `ForceSpellPoint(resref, x, y)` | ForceSpell at coordinates |
| `ReallyForceSpellPoint(resref, x, y)` | ReallyForceSpell at coordinates |
| `ApplySpell(resref, target)` | Instant effect — no cast animation, uses projectile #1 |

**Target objects** (BCS object specifiers):
- `Myself` — the casting sprite itself
- `Player1` through `Player6` — party members by slot
- `LastSeenBy(Myself)` — last creature seen
- `NearestEnemyOf(Myself)` — nearest hostile

### Instant Execution (Cheat Mode) **[DOC]** **[SRC]**

Executes actions immediately without queuing, bypassing the normal action system.
**Only works with actions defined in INSTANT.IDS** (not all actions are instant-capable).

```lua
EEex_Action_ExecuteResponseStringOnAIBaseInstantly(
    'ReallyForceSpellDead("SPWI304",Myself)',
    sprite
)
```

Instant-capable actions include: `ApplySpell`, `ReallyForceSpellDead`,
`DisplayStringHead`, `SetGlobal`, `AddSpecialAbility`, among others.
Standard `Spell()`, `ForceSpell()` are **NOT** in INSTANT.IDS.

### EEex Extended Spell Actions **[INF]**

EEex adds custom actions for offset-based targeting:

```
EEex_SpellObjectOffset(spell, obj, offset)
EEex_ForceSpellObjectOffset(spell, obj, offset)
EEex_ReallyForceSpellObjectOffset(spell, obj, offset)
EEex_ReallyForceSpellObjectOffsetRES(resref, obj, offset)
```

### Action Listeners **[DOC]**

```lua
-- Listen for when any sprite starts executing an action
EEex_Action_AddSpriteStartedActionListener(function(sprite, action)
    -- Fires when a sprite begins processing a new action
end)

-- Filtered variant — only fires for "enabled" sprites (party members?)
EEex_Action_AddEnabledSpriteStartedActionListener(function(sprite, action)
end)

-- Listen for next-action-started events
EEex_Action_AddSpriteStartedNextActionListener(function(sprite, action)
end)
```

---

## 7. Aura / Cooldown State

### Cast Timer **[SRC]**

```lua
-- Current casting counter (0 = not casting)
-- Implementation: sprite.m_castCounter
local timer = EEex_Sprite_GetCastTimer(sprite)          -- → number

-- Casting progress as percentage (0-100)
local pct = EEex_Sprite_GetCastTimerPercentage(sprite)  -- → number   [DOC]
```

### Modal State **[SRC]**

```lua
-- Current modal action (MODAL.IDS values)
-- Implementation: sprite.m_nModalState
local modal = EEex_Sprite_GetModalState(sprite)           -- → number

-- Modal action cooldown timer / percentage
local timer = EEex_Sprite_GetModalTimer(sprite)            -- → number  [DOC]
local pct   = EEex_Sprite_GetModalTimerPercentage(sprite)  -- → number  [DOC]
```

Common MODAL.IDS values: 0=None, 1=BattleSong, 2=DetectTraps, 3=Stealth, 4=TurnUndead

### Contingency Timer **[DOC]**

```lua
local timer = EEex_Sprite_GetContingencyTimer(sprite)           -- → number
local pct   = EEex_Sprite_GetContingencyTimerPercentage(sprite) -- → number
```

### Engine Aura Cooldown **[INF]**

> The 6-second casting delay ("aura cooldown") is managed internally by the engine. After
> a spell finishes casting, the engine enforces a delay before the next spell can begin.
> There is no direct `GetAuraCooldown()` function exposed.
>
> **Workaround options**:
> 1. Track cast completion via `EEex_Action_AddSpriteStartedActionListener` and a timer
> 2. Use `EEex_Sprite_GetCastTimer(sprite) == 0` to check if not currently casting
> 3. Simply queue actions — the engine will pace them naturally via the aura system
> 4. For "normal mode" BuffBot: just queue all spell actions and let the engine handle timing

---

## 8. UI Integration

### Loading Custom Menus **[SRC]**

```lua
-- Load a .menu file into the UI system
-- Implementation: fetches MENU resource and processes via EngineGlobals.uiLoadMenu()
EEex_Menu_LoadFile("M_BBUFF")  -- loads M_BBUFF.menu
```

Menu files are installed via WeiDU `COPY` to the `override/` folder, named as `.menu` files.
They use the EE menu definition language (not standard Lua — a custom declarative format).

### Menu Definition Format **[INF]**

```
menu
{
  name 'BUFFBOT_MAIN'
  align center center
  label
  {
    area 10 10 200 30
    text "BuffBot Configuration"
    text style title
  }
  button
  {
    area 10 50 100 30
    bam GUIOSTUR
    text "Cast All"
    action "BuffBot_CastAll()"
  }
  list
  {
    area 10 90 400 300
    rowheight 32
    table "buffbot_spellList"
    var buffbot_selectedSpell
  }
}
```

### Template Injection **[SRC]**

Inject UI elements into existing game menus without replacing them:

```lua
-- Inject a template into an existing menu at specified coordinates
-- Implementation: uses Infinity_InstanceAnimation with menu override hook
EEex_Menu_InjectTemplate("WORLD_ACTIONBAR", "BUFFBOT_BUTTON", 500, 0, 48, 48)
-- menuName: target menu to inject into
-- templateName: template defined in a loaded .menu file
-- x, y, w, h: position and size within the target menu
```

### Menu Manipulation **[DOC]** **[SRC]**

```lua
-- Find a menu by name
local menu = EEex_Menu_Find("WORLD_ACTIONBAR")     -- → userdata | nil
-- Optional: EEex_Menu_Find(name, panel, state)

-- Get/set functions on menu items
local func = EEex_Menu_GetItemFunction(item)
EEex_Menu_SetItemFunction(item, "BuffBot_OnClick")

-- Get/set item variants
local variant = EEex_Menu_GetItemVariant(item)
EEex_Menu_SetItemVariant(item, newVariant)

-- Get item bounding area
local x, y, w, h = EEex_Menu_GetItemArea(item)

-- Evaluate Lua in menu context
EEex_Menu_Eval("some_lua_expression")
```

### Menu Lifecycle Hooks **[DOC]**

```lua
-- After the main UI.menu file has been loaded (initialization point)
EEex_Menu_AddAfterMainFileLoadedListener(function()
    -- Load our custom menu file here
    EEex_Menu_LoadFile("M_BBUFF")
end)

-- After UI reload (e.g., resolution change)
EEex_Menu_AddAfterMainFileReloadedListener(function()
    -- Re-inject our templates
end)

-- Before individual list items render (for custom rendering)
EEex_Menu_AddBeforeListRendersItemListener(function(list, index)
    -- Customize list item appearance
end)

-- Window size changes
EEex_Menu_AddWindowSizeChangedListener(function(w, h)
    -- Reposition our UI elements
end)
```

### Engine UI Functions **[DOC]**

```lua
-- Menu stack management
Infinity_PushMenu("BUFFBOT_MAIN")    -- push menu onto display stack
Infinity_PopMenu("BUFFBOT_MAIN")     -- remove from stack

-- Check if a menu is currently displayed
local isVisible = Infinity_IsMenuOnStack("BUFFBOT_MAIN")  -- → boolean

-- Screen dimensions
local w, h = Infinity_GetScreenSize()

-- Menu bounding rect
local x, y, w, h = Infinity_GetMenuArea("WORLD_ACTIONBAR")

-- Create UI element instances
Infinity_InstanceAnimation(templateName, bamResRef, x, y, w, h, list, listIndex)

-- Position/resize
Infinity_SetArea("elementName", x, y, w, h)

-- Display feedback text
Infinity_DisplayString("BuffBot: Casting Shield on Fighter")

-- Mouse position
local mx, my = Infinity_GetMousePosition()
```

---

## 9. Event Hooks

### Game Lifecycle **[DOC]**

```lua
-- Fires once after the engine's Lua environment is initialized
-- If already initialized when registered, fires immediately
EEex_GameState_AddInitializedListener(function()
    -- Initialize BuffBot state, load configs
end)

-- After a game session is destroyed (back to main menu)
EEex_GameState_AddDestroyedListener(function()
    -- Clean up BuffBot state
end)

-- Engine shutdown                                               [SRC]
EEex_GameState_AddShutdownListener(function()
    -- Final cleanup
end)

-- Before/after EEex includes are processed                      [SRC]
EEex_GameState_AddBeforeIncludesListener(function() end)
EEex_GameState_AddAfterIncludesListener(function() end)
```

### Sprite Events **[DOC]**

```lua
-- When a sprite is loaded (from save or area transition)
EEex_Sprite_AddLoadedListener(function(sprite)
    -- Initialize BuffBot config for this sprite
end)

-- When spell availability changes (memorization, rest, etc.)
EEex_Sprite_AddSpellDisableStateChangedListener(function(sprite)
    -- Refresh available spell list
end)

-- When quick lists are rechecked
EEex_Sprite_AddQuickListsCheckedListener(function(sprite)
end)

-- When quick list items are removed
EEex_Sprite_AddQuickListNotifyRemovedListener(function(sprite)
end)
```

### Action/Combat Events **[DOC]**

```lua
-- Any sprite starts a new action
EEex_Action_AddSpriteStartedActionListener(function(sprite, action)
    -- Could detect combat start by watching for attack/spell actions
end)

-- Filtered: only "enabled" sprites
EEex_Action_AddEnabledSpriteStartedActionListener(function(sprite, action)
end)
```

### Actionbar Events **[DOC]**

```lua
-- Actionbar buttons have been updated
EEex_Actionbar_AddButtonsUpdatedListener(function()
    -- Refresh our button overlay if needed
end)
```

### Effects Processing **[DOC]**

```lua
-- After all effect lists have been resolved for the current tick
EEex_Opcode_AddListsResolvedListener(function()
    -- Good time to check updated buff states
end)
```

### Keyboard Input **[DOC]**

```lua
EEex_Key_AddPressedListener(function(key)
    -- key: key code
    -- Could trigger BuffBot via hotkey
end)

EEex_Key_AddReleasedListener(function(key)
end)

-- Check if a key is currently held
local isDown = EEex_Key_IsDown(keyCode)             -- → boolean
local name   = EEex_Key_GetName(keyCode)            -- → string
local code   = EEex_Key_GetFromName("F12")          -- → number
```

### Missing Events **[INF]**

> There are **no direct hooks** for:
> - Combat start / combat end
> - Area transition
> - Rest completion
> - Spell cast completion (individual)
>
> **Workarounds**:
> - **Combat**: Watch `EEex_Action_AddSpriteStartedActionListener` for attack actions, or
>   poll `EEex_Sprite_GetState()` for combat-related state flags
> - **Area transition**: Use `EEex_Sprite_AddLoadedListener` (fires when sprites are loaded
>   into new areas)
> - **Rest**: Use BCS script with `Rest()` trigger, or hook via `Infinity_OnRest`
> - **Spell completion**: Track via cast timer going to 0, or action listener sequence

---

## 10. Persistence and Configuration Storage

### Per-Creature Variables (Saved in Game) **[SRC]**

```lua
-- Integer variables — saved with the game, per-creature scope
EEex_Sprite_SetLocalInt(sprite, "BB_PRESET", 1)
local preset = EEex_Sprite_GetLocalInt(sprite, "BB_PRESET")  -- → 0 if unset

-- String variables
EEex_Sprite_SetLocalString(sprite, "BB_CFG", serializedData)
local cfg = EEex_Sprite_GetLocalString(sprite, "BB_CFG")     -- → "" if unset
```

> Variable name max: 32 characters. String value max: 32 characters.
> For larger config data, split across multiple variables or use a global storage approach.

### Global Variables (Saved in Game) **[DOC]**

```lua
EEex_GameState_SetGlobalInt("BB_VERSION", 1)
local ver = EEex_GameState_GetGlobalInt("BB_VERSION")    -- → 0 if unset

EEex_GameState_SetGlobalString("BB_MODE", "normal")
local mode = EEex_GameState_GetGlobalString("BB_MODE")   -- → "" if unset
-- WARNING: Global string values max 32 characters
```

### EEex Variable System **[DOC]**

```lua
-- EEex's own variable store (separate from game globals)
EEex_Variable_SetInt("buffbot_enabled", 1)
local enabled = EEex_Variable_GetInt("buffbot_enabled")

EEex_Variable_SetString("buffbot_version", "0.1.0")
```

> **[UNC]**: Unclear whether EEex variables persist in save games or are session-only.
> Game globals (SetGlobalInt) definitely persist. Sprite locals definitely persist.

### INI File Access **[DOC]**

```lua
-- Read/write to baldur.ini (persists across sessions, not per-save)
local val = Infinity_GetINIValue("BuffBot", "Enabled", 1)
Infinity_SetINIValue("BuffBot", "Enabled", 1)

local str = Infinity_GetINIString("BuffBot", "Mode", "normal")
```

---

## 11. Actionbar Integration

### Reading Spell Button State **[DOC]**

```lua
-- Get current actionbar state (which button set is showing)
local state = EEex_Actionbar_GetState()         -- → number
local last  = EEex_Actionbar_GetLastState()     -- → number

-- Get the actionbar button array
local buttons = EEex_Actionbar_GetArray()        -- → table

-- Set a specific button
EEex_Actionbar_SetButton(index, buttonType)

-- Set entire actionbar state
EEex_Actionbar_SetState(state)
EEex_Actionbar_RestoreLastState()
```

### Spell Button Data **[DOC]**

```lua
-- Iterator over spell button data (what spells are shown in the spell submenu)
local iter = EEex_Actionbar_GetSpellButtonDataIterator()

-- From 2DA table
local iter = EEex_Sprite_GetSpellButtonDataIteratorFrom2DA(sprite, ...)

-- Opcode 214 button data
local iter = EEex_Actionbar_GetOp214ButtonDataIterator()
```

### Suppressing Listeners **[DOC]**

```lua
-- Temporarily suppress actionbar listeners (for batch updates)
EEex_Actionbar_SuppressListeners()
-- ... make changes ...
EEex_Actionbar_RunWithListenersSuppressed(function()
    -- Changes here won't trigger listener callbacks
end)
```

---

## 12. EEex Custom Opcodes

### Opcode #400 — Set Temporary AI Script **[DOC]**

Sets a script on a creature that auto-restores the original when the effect expires.
Similar to standard opcode #82 but with proper cleanup.

### Opcode #401 — Set Extended Stat **[DOC]**

Extends the stat system beyond standard STATS.IDS. Supports cumulative, flat, and
percentage modification modes. Up to 65,737 custom stat entries.

### Opcode #402 — Invoke Lua **[DOC]**

Calls a Lua function when the effect is applied. Could be used to trigger BuffBot logic
from spell effects.

| Parameter | Description |
|-----------|-------------|
| Resource Key | Lua function name (max 8 chars, UPPERCASE) |
| Parameter 1 | First argument passed to the function |
| Parameter 2 | Second argument |
| Special | Third argument |

> **Limitation**: 8-character function name max. For BuffBot, we likely won't use this
> opcode directly — our Lua runs from UI/event hooks, not from spell effects.

---

## 13. Compatibility

### Supported Games **[DOC]**

| Game | Version Required | Notes |
|------|-----------------|-------|
| BG:EE | v2.6.6.0 | Full support |
| BG2:EE | v2.6.6.0 | Full support |
| IWD:EE | v2.6.6.0 | Full support |
| EET | v2.6.6.0 | Same engine, supported |

### Platform Support **[DOC]**

| Platform | Support Level |
|----------|--------------|
| Windows | Native — primary platform |
| Linux | Via Proton/Wine |
| macOS | Wine-based, untested |
| Android/iOS | Not supported |

### Requirements **[DOC]**

- Microsoft Visual C++ Redistributable (x64)
- Must launch via `InfinityLoader.exe` (not the vanilla executable)
- No external mod dependencies; EEex can go anywhere in install order
- Optional: LuaJIT component (experimental, may crash)

### Version History **[DOC]**

- **v0.9.0-alpha**: Major rewrite — x64 support, new userdata-based API, InfinityLoader
- **v0.10.x-alpha**: Current development line, ongoing API additions
- **Pre-0.9.0**: x86 only, different API patterns (raw memory offsets), EEexLoader

> BuffBot should target **v0.9.0-alpha+** minimum. The x64 userdata API is the modern
> approach and what all function signatures in this document reference.

---

## 14. Known Gaps and Open Questions

### Memorized Spell Slots
No `GetMemorizedSpell*` iterator found in EEex source. We can enumerate what spells a
character **knows** but not directly which slots are **memorized and available**.
Needs runtime exploration of CGameSprite userdata methods.

### Menu Function Signatures
All 34 `EEex_Menu_*` functions are officially undocumented. Signatures in this document
are inferred from source code and may be incomplete.

### Effect Iteration (Modern API)
`EEex_IterateActorEffects` is from older EEex. The v0.9.0+ equivalent may use userdata
patterns. Need to check CGameSprite for effect list access methods.

### No Combat Detection Event
No hook fires on combat start/end. Would need to build our own detection via action
listeners or state polling.

### Undocumented Function Stability
48 of the 87 Sprite functions are marked "currently undocumented" in official docs.
We extracted implementations from source, but they could change between EEex versions
without notice.

### Opcode 402 Name Length
Invoke Lua opcode has 8-character function name limit. Not a blocker — we'll trigger
BuffBot logic from event hooks and UI, not from opcode effects.

---

## 15. Reference Mods

### Bubb's Spell Menu Extended
- GitHub: https://github.com/Bubb13/Bubbs-Spell-Menu-Extended
- Requires EEex v0.10.1.1-alpha+
- Demonstrates: spell enumeration, custom UI, actionbar integration
- By the same author as EEex — canonical usage patterns

### Enhanced Powergaming Scripts
- GitHub: https://github.com/SarahG-579462/Enhanced-Powergaming-Scripts
- Uses EEex custom triggers for threat assessment
- Implements pre-buffing and debuffing AI automation
- BCS-based approach (scripts, not Lua UI)
- Compatible with EEex v0.9.0+
