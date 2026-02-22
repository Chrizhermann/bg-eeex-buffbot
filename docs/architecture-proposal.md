# BuffBot Architecture Proposal

> Synthesized from analysis of EEex APIs, spell data formats, UI patterns, BSME source code, existing buff solutions (EPS/SCS), and WeiDU packaging. Every API call, opcode, and pattern referenced here is grounded in the research documents in `docs/`.

---

## Table of Contents

1. [Module Structure](#1-module-structure)
2. [Data Flow](#2-data-flow)
3. [Configuration Schema](#3-configuration-schema)
4. [Buff Set Design](#4-buff-set-design)
5. [Trigger Mechanisms](#5-trigger-mechanisms)
6. [Execution Engine Design](#6-execution-engine-design)
7. [MVP Scope](#7-mvp-scope)
8. [Extension Roadmap](#8-extension-roadmap)
9. [Risks and Open Questions](#9-risks-and-open-questions)

---

## 1. Module Structure

### File Map

| File | Resref | Role | Install Method |
|------|--------|------|----------------|
| `M_BfBot.lua` | M_BfBot (7) | Bootstrap — engine auto-loads via M_ prefix | `COPY` |
| `BfBotWei.lua` | BfBotWei (8) | WeiDU-generated constants (translated strings, BAM names, dimensions) | `COPY` + `EVALUATE_BUFFER` |
| `BfBotEx.lua` | BfBotEx (7) | EEex hook registration, event listeners, initialization | `COPY` |
| `BfBotCor.lua` | BfBotCor (7) | Core logic — spell scanner, classifier, execution engine, config model | `COPY` |
| `BuffBot.menu` | BuffBot (7) | UI panel definitions (.menu DSL) | `COPY` + `EVALUATE_BUFFER` |
| `setup-buffbot.tp2` | — | WeiDU installer | — |

All resrefs ≤8 characters for `Infinity_DoFile()` and `EEex_Menu_LoadFile()` compatibility.

### Module Responsibilities

#### M_BfBot.lua — Bootstrap (≈20 lines)
Engine auto-loads all `M_*.lua` from override alphabetically. EEex's `M___EEex.lua` (triple underscores) loads first, then `M_BfBot.lua` ('B' sorts after '_').

```lua
-- M_BfBot.lua
if not EEex_Active then return end

Infinity_DoFile("BfBotWei")  -- WeiDU-injected constants
Infinity_DoFile("BfBotCor")  -- Core logic (scanner, classifier, engine, config)
Infinity_DoFile("BfBotEx")   -- EEex hooks (depends on BfBotCor being loaded)
```

#### BfBotWei.lua — WeiDU Constants
Generated at install time via `EVALUATE_BUFFER`. Contains translated strings, game-specific BAM names, and UI dimensions. Pure data, no logic.

```lua
-- BfBotWei.lua (template — %var% replaced at install time)
BfBot_SlotBam       = "%BfBot_SlotBam%"
BfBot_ButtonBam     = "%BfBot_ButtonBam%"
BfBot_SidebarWidth  = %BfBot_SidebarWidth%
BfBot_Str = {
    TooltipOpen    = "%BfBot_Tooltip_Open%",
    TooltipCast    = "%BfBot_Tooltip_CastAll%",
    LabelPresets   = "%BfBot_Label_Presets%",
    -- ... etc
}
```

#### BfBotCor.lua — Core Logic (≈800-1200 lines)
The main module. Contains all domain logic organized into namespaced tables:

```lua
BfBot = {}            -- Root namespace
BfBot.Scan = {}       -- Spell Scanner module
BfBot.Class = {}      -- Buff Classifier module
BfBot.Cfg = {}        -- Config Data Model module
BfBot.Exec = {}       -- Execution Engine module
BfBot.UI = {}         -- UI state management (Lua side)
BfBot.Persist = {}    -- Persistence module
```

**Spell Scanner (`BfBot.Scan`)**:
- Enumerates all castable spells for a character using `sprite:GetQuickButtons(2, 0)` (wizard) and `(4, 0)` (innate)
- Uses `EEex_Sprite_GetKnownPriestSpellsWithAbilityIterator(sprite, 1, 7)` for priest spells (since GetQuickButtons type for priest is uncertain)
- Loads SPL headers via `EEex_Resource_Demand(resref, "SPL")`
- Reads extended headers via `EEex_Resource_GetSpellAbilityForLevel(header, casterLevel)`
- Caches results per character; invalidated by event listeners
- Returns spell data table: `{ resref, name, icon, count, level, type, ability, header }`

**Buff Classifier (`BfBot.Class`)**:
- Implements the 3-step scoring algorithm (see §4 of spell-system doc)
- Step 1: Friendly flag (extended header flags bit 2) = +5, self-target (type 5/7) = +3
- Step 2: Opcode scoring across all feature blocks
- Step 3: Net score threshold (≥+3 = buff, ≤-3 = not buff, else ambiguous)
- MSECTYPE fast-path: values 1,2,3,7 add +3 before opcode scan
- Builds resref→SPLSTATE map by scanning for opcode 282/328 in feature blocks
- Calculates effective duration from feature block timing modes
- All results cached per resref (spells don't change within a session)

**Config Data Model (`BfBot.Cfg`)**:
- Manages the per-character configuration schema (see §3)
- Provides get/set accessors for preset data
- Handles default config initialization for new characters
- Manages user override table for buff classification

**Execution Engine (`BfBot.Exec`)**:
- Builds a cast queue from current preset config + party state
- Normal mode: queues `Spell()` BCS actions via `EEex_Action_QueueResponseStringOnAIBase()`
- Cheat mode: uses `EEex_Action_ExecuteResponseStringOnAIBaseInstantly()` with `ReallyForceSpellDead`
- Checks active buffs before queuing (skip logic)
- Handles party-targeted spells (one cast per party member)
- Tracks execution state (idle, casting, complete, interrupted)

**Persistence (`BfBot.Persist`)**:
- Registers marshal handlers via `EEex_Sprite_AddMarshalHandlers()`
- Saves/loads config to/from `EEex_GetUDAux(sprite)["BB"]`
- INI file for cross-save preferences via `Infinity_GetINIValue()`/`SetINIValue()`
- Future: file I/O for preset export/import

#### BfBotEx.lua — EEex Hooks (≈150 lines)
Registers all EEex event listeners and sets up the initialization chain:

```lua
-- BfBotEx.lua
EEex_Menu_AddMainFileLoadedListener(function()
    -- 1. Load UI
    EEex_Menu_LoadFile("BuffBot")

    -- 2. Inject actionbar button
    EEex_Menu_InjectTemplate("WORLD_ACTIONBAR", "BFBOT_BTN", ?, 0, 48, 48)

    -- 3. Register keyboard shortcut
    EEex_Key_AddPressedListener(function(key)
        if key == EEex_Key_GetFromName("F11") then
            BfBot.UI.TogglePanel()
        end
    end)
end)

-- Spell list refresh triggers
EEex_Sprite_AddQuickListsCheckedListener(function(sprite)
    BfBot.UI.OnSpellListChanged(sprite)
end)
EEex_Sprite_AddQuickListCountsResetListener(function(sprite)
    BfBot.UI.OnSpellListChanged(sprite)
end)
EEex_Sprite_AddQuickListNotifyRemovedListener(function(sprite)
    BfBot.UI.OnSpellListChanged(sprite)
end)
EEex_Sprite_AddSpellDisableStateChangedListener(function(sprite)
    BfBot.UI.OnSpellListChanged(sprite)
end)

-- Save/load persistence
EEex_Sprite_AddMarshalHandlers("BuffBot",
    function(sprite) return BfBot.Persist.Export(sprite) end,
    function(sprite, data) BfBot.Persist.Import(sprite, data) end
)

-- Config restoration on sprite load
EEex_Sprite_AddLoadedListener(function(sprite)
    BfBot.Persist.OnSpriteLoaded(sprite)
end)

-- Resolution change handling
EEex_Menu_AddWindowSizeChangedListener(function(w, h)
    BfBot.UI.OnResolutionChange(w, h)
end)
```

#### BuffBot.menu — UI Definitions
Defines the panel layout using .menu DSL. Uses `lua` keyword bindings to read Lua state variables and call Lua functions. Contains:
- Main panel menu (`BUFFBOT_MAIN`)
- Actionbar button template (`BFBOT_BTN`)
- Target picker sub-menu (`BUFFBOT_TARGETS`)
- Character tab buttons
- Preset tab buttons
- Spell list (using `list` widget)
- Cast trigger buttons (Long Buffs / Short Buffs)
- Options section (skip active toggle, etc.)

---

## 2. Data Flow

### Text Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         INITIALIZATION                              │
│                                                                     │
│  Engine ──► M___EEex.lua ──► M_BfBot.lua ──► BfBotWei/Cor/Ex      │
│                                    │                                │
│                          MainFileLoadedListener                     │
│                                    │                                │
│                    ┌───────────────┼───────────────┐                │
│                    ▼               ▼               ▼                │
│             LoadFile("BuffBot")  InjectTemplate  KeyListener        │
│               (.menu loaded)    (actionbar btn)  (F11 hotkey)       │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                      SPELL SCANNING FLOW                            │
│                                                                     │
│  Party Member (sprite)                                              │
│        │                                                            │
│        ▼                                                            │
│  GetQuickButtons(2,0) ──► Wizard spells (memorized, castable)      │
│  GetQuickButtons(4,0) ──► Innate abilities                         │
│  GetKnownPriestSpellsWithAbilityIterator ──► Priest spells         │
│        │                                                            │
│        ▼                                                            │
│  For each resref:                                                   │
│    EEex_Resource_Demand(resref, "SPL") ──► SPL header              │
│    GetSpellAbilityForLevel(header, level) ──► Extended header       │
│        │                                                            │
│        ▼                                                            │
│  BfBot.Class.Classify(resref, header, ability)                     │
│    ├── Step 1: Friendly flag (bit 2 of ext hdr flags) + target type│
│    ├── Step 2: Opcode scoring across feature blocks                 │
│    ├── Step 3: Net score threshold (≥+3 = buff)                    │
│    └── Step 4: Manual override check                                │
│        │                                                            │
│        ▼                                                            │
│  Result: { resref, name, icon, count, level, type,                 │
│            isBuff, isAmbiguous, duration, durationCategory,        │
│            isAoE, splstateIDs[], defaultTarget }                   │
│        │                                                            │
│        ▼                                                            │
│  Cached in BfBot.spellCache[resref]                                │
│  Filtered list stored in BfBot.UI.spellTable (bound to .menu list) │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                    CONFIGURATION FLOW                                │
│                                                                     │
│  User opens panel (actionbar btn or F11)                            │
│        │                                                            │
│        ▼                                                            │
│  BfBot.UI.TogglePanel()                                            │
│    ├── Select character (tab click ──► BfBot.UI.SetCharacter())    │
│    ├── Select preset (tab click ──► BfBot.UI.SetPreset())          │
│    └── Scan spells ──► Populate list                                │
│        │                                                            │
│        ▼                                                            │
│  .menu list widget reads bfbot_spellTable[] every frame             │
│    ├── Checkbox toggle ──► BfBot.Cfg.SetSpellEnabled(resref, bool) │
│    ├── Target button ──► push BUFFBOT_TARGETS ──► SetTarget()      │
│    └── Drag/priority ──► BfBot.Cfg.SetSpellPriority(resref, pos)  │
│        │                                                            │
│        ▼                                                            │
│  Config state lives in:                                             │
│    BfBot.Cfg.GetConfig(sprite) ──► config table in UDAux           │
│        │                                                            │
│        ▼                                                            │
│  Auto-persisted via marshal handlers on save                        │
│  Restored via EEex_Sprite_AddLoadedListener on load                 │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                     EXECUTION FLOW                                  │
│                                                                     │
│  User clicks "Cast Long Buffs" or "Cast Short Buffs"               │
│        │                                                            │
│        ▼                                                            │
│  BfBot.Exec.Start(presetIndex)                                     │
│        │                                                            │
│        ▼                                                            │
│  Build cast queue:                                                  │
│    For each party member with enabled spells in this preset:        │
│      For each enabled spell (sorted by priority):                   │
│        ├── Skip if disabled in config                               │
│        ├── Skip if count == 0 (no slots remaining)                  │
│        ├── Skip if active buff detected:                            │
│        │     Check EEex_Sprite_GetSpellState(target, splstateID)   │
│        │     (fallback: effect iteration for spells w/o SPLSTATE)  │
│        └── Add to queue: { caster, resref, target, action }       │
│        │                                                            │
│        ▼                                                            │
│  Sort queue: casters ordered by party slot, spells by priority      │
│  Default priority: longest duration first                           │
│        │                                                            │
│        ▼                                                            │
│  NORMAL MODE:                                                       │
│    For each entry in queue:                                         │
│      Compile: 'Spell("RESREF", TargetObj)'                        │
│      Queue: EEex_Action_QueueResponseStringOnAIBase(action, caster)│
│    Engine handles: aura cooldown, casting speed, interrupts         │
│    Completion: action listeners track progress                      │
│        │                                                            │
│  CHEAT MODE:                                                        │
│    For each entry in queue:                                         │
│      EEex_Action_ExecuteResponseStringOnAIBaseInstantly(            │
│        'ReallyForceSpellDead("RESREF", TargetObj)', caster)        │
│      + RemoveSpell("RESREF") to consume slot                       │
│    Instant — no aura, no cast time                                  │
│        │                                                            │
│        ▼                                                            │
│  DisplayStringHead feedback per character:                          │
│    "Casting Shield..." / "Buffing complete" / "Out of spell slots" │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                    EVENT REFRESH FLOW                                │
│                                                                     │
│  QuickListsCheckedListener ──┐                                     │
│  QuickListCountsResetListener ──┤                                  │
│  QuickListNotifyRemovedListener ──► BfBot.UI.OnSpellListChanged()  │
│  SpellDisableStateChangedListener ──┘                              │
│        │                                                            │
│        ▼                                                            │
│  Re-scan affected character's spells                                │
│  Update bfbot_spellTable                                            │
│  .menu list auto-refreshes (reads table every frame)                │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Configuration Schema

### Per-Character Config (stored in UDAux)

```lua
-- Accessed via: EEex_GetUDAux(sprite)["BB"]
local config = {
    v = 1,                     -- Schema version (for migration)
    ap = 1,                    -- Active preset index (1-5)

    presets = {
        [1] = {
            name = "Long Buffs",
            cat = "long",      -- Category: "long", "short", "custom"
            spells = {
                ["SPWI304"] = {  -- keyed by resref
                    on = true,   -- Enabled in this preset
                    tgt = "p",   -- Target: "s"=self, "p"=party, "1"-"6"=specific Player slot
                    pri = 1,     -- Priority (lower = cast first)
                },
                ["SPPR301"] = {
                    on = true,
                    tgt = "s",
                    pri = 2,
                },
                -- ... more spells
            },
        },
        [2] = {
            name = "Short Buffs",
            cat = "short",
            spells = { ... },
        },
        -- [3]-[5] initially nil (created on demand)
    },

    opts = {
        skip = true,           -- Skip already-active buffs (default: true)
        cheat = false,         -- Cheat mode: instant casting (default: false)
    },
}
```

### Spell Classification Cache (runtime only, not persisted)

```lua
-- BfBot.spellCache[resref] — rebuilt on first access, invalidated on rest/area change
BfBot.spellCache = {
    ["SPWI304"] = {
        resref = "SPWI304",
        name = "Haste",
        icon = "SPWI304C",          -- BAM resref
        level = 3,
        spellType = 1,              -- 1=Wizard, 2=Priest, 4=Innate
        isBuff = true,
        isAmbiguous = false,
        score = 7,                  -- Classification score
        duration = 30,              -- Seconds (at caster level, or -1 for permanent)
        durCat = "short",           -- "short" (<5 turns), "long" (>=5 turns), "permanent"
        splstates = {16},           -- SPLSTATE IDs set by this spell (for skip logic)
        selfReplace = false,        -- Uses opcode 321 on own resref
        isAoE = true,               -- AoE party buff (cast once) vs single-target (cast per target)
        defaultTarget = "p",        -- Smart default: "s"=self, "p"=party
        friendlyFlag = true,        -- Extended header friendly ability bit
        msectype = 0,               -- MSECTYPE.IDS value
    },
    -- ...
}
```

### User Override Table (persisted globally, not per-character)

```lua
-- Stored in INI file: Infinity_SetINIString("BuffBot", "Overrides", serialized)
-- Or in a global variable: EEex_GameState_SetGlobalString("BB_OVR_SPWI304", "1")
-- Limited by 32-char string constraint — use INI for flexibility
BfBot.overrides = {
    ["SPWI304"] = true,     -- Force-classified as buff
    ["SPWI502"] = false,    -- Force-classified as not-buff
    -- nil = use auto-classification
}
```

### Global Preferences (INI, cross-save)

```lua
-- Infinity_GetINIValue("BuffBot", key, default)
-- These survive across save games
{
    ShowTooltips = 1,           -- Show spell tooltips in panel
    DefaultPreset = 1,          -- Which preset tab opens by default
    HotkeyCode = 87,            -- F11 keycode (customizable)
    LongThreshold = 300,        -- Duration threshold in seconds (5 turns)
    ConfirmCast = 0,            -- Show confirmation before casting (0=no, 1=yes)
}
```

### Target Resolution

Target values in config (`tgt` field) map to BCS objects at execution time:

| Config Value | BCS Object | Meaning |
|---|---|---|
| `"s"` | `Myself` | Self-targeted |
| `"p"` | (special) | AoE buffs: cast once (projectile covers party). Single-target buffs: one cast per `Player1`..`Player6` |
| `"1"` | `Player1` | Specific party member slot 1 |
| `"2"` | `Player2` | Specific party member slot 2 |
| ... | ... | ... |
| `"6"` | `Player6` | Specific party member slot 6 |

For party-wide targeting (`"p"`), the behavior depends on the spell's delivery type: **AoE spells** (Bless, Haste — detected via `isAoE` flag) are cast once targeting the caster, since the projectile covers the party. **Single-target friendly spells** (Protection from Evil) are expanded into N separate cast actions, one per living party member. Self-only spells (target type 5/7 in extended header) force `tgt = "s"` regardless of config.

---

## 4. Buff Set Design

### Duration Categories

Based on the spell system research, define three duration tiers using the effective duration from feature block analysis:

| Category | Duration | Typical Spells | Cast Priority |
|---|---|---|---|
| **Long** | >= 5 turns (300 seconds) or permanent | Stoneskin (12hr), Protection from Evil (perm), Chaotic Commands (1 turn/lvl), Shield (5 rounds/lvl at high level) | Cast first (most efficient) |
| **Short** | < 5 turns (< 300 seconds) | Haste (3 rounds + 1/lvl), Improved Haste (1 round/lvl), Draw Upon Holy Might (1 round/lvl), Bless (6 rounds + 1/lvl at low level) | Cast second (closer to combat) |
| **Permanent** | Timing mode 1 or 4 (permanent until dispelled) | Protection from Evil, Armor of Faith | Subset of Long |

The 5-turn (300-second) threshold was chosen because:
- At caster level 10, most "per-level" buffs with 1 round/level = 60 seconds (well under threshold)
- Buffs with 1 turn/level at level 10 = 600 seconds (well over threshold)
- This cleanly separates "cast before leaving camp" buffs from "cast right before combat" buffs
- Configurable via INI preference `LongThreshold`

### Duration Calculation

```lua
function BfBot.Class.GetDuration(header, casterLevel)
    local ability = EEex_Resource_GetSpellAbilityForLevel(header, casterLevel)
    if not ability then return 0, "unknown" end

    local maxDuration = 0
    local hasPermanent = false

    -- Scan feature blocks for timing/duration
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

function BfBot.Class.GetDurationCategory(durationSeconds)
    local threshold = Infinity_GetINIValue("BuffBot", "LongThreshold", 300)
    if durationSeconds == -1 then return "long" end       -- permanent = long
    if durationSeconds >= threshold then return "long" end
    return "short"
end
```

### Default Presets

When a character first opens BuffBot, two presets are auto-created:

**Preset 1 — "Long Buffs"**: Auto-populated with all classified buff spells where `durCat == "long"`. Default priority: longest duration first (permanent > higher duration > lower duration). Default target: smart default from spell target type.

**Preset 2 — "Short Buffs"**: Auto-populated with all classified buff spells where `durCat == "short"`. Same priority/target logic.

The auto-population happens once; after that the user's manual configuration takes precedence. New spells learned by the character appear in the list but are disabled by default (the user opts them in).

### Trigger Buttons

The main panel has two prominent cast buttons:

```
┌──────────────────────────────────────┐
│  [Cast Long Buffs]  [Cast Short Buffs] │
└──────────────────────────────────────┘
```

Each button triggers `BfBot.Exec.Start(presetIndex)` for the corresponding preset. The currently-viewed preset's button is highlighted. Additional presets (3-5) use the same cast mechanism, triggered from their tab.

### Future: Healing Mode

A third category for reactive healing, not a duration category but a distinct mode:
- Triggered by HP threshold (e.g., < 50% HP)
- Uses healing spells (opcode 17) rather than buff spells
- Requires combat-reactive AI script integration (see §8)
- Completely out of MVP scope

---

## 5. Trigger Mechanisms

### MVP Triggers

#### Primary: UI Button Press
The cast buttons in the BuffBot panel. Player opens panel, clicks "Cast Long Buffs" or "Cast Short Buffs".

```lua
function BfBot.Exec.Start(presetIndex)
    if BfBot.Exec.state ~= "idle" then return end
    BfBot.Exec.BuildQueue(presetIndex)
    BfBot.Exec.ExecuteQueue()
end
```

#### Secondary: Keyboard Shortcut
F11 (configurable) toggles the panel. Could also bind direct cast shortcuts (e.g., Shift+F11 = cast active preset without opening panel).

```lua
EEex_Key_AddPressedListener(function(key)
    local hotkey = Infinity_GetINIValue("BuffBot", "HotkeyCode", 87) -- F11
    if key == hotkey then
        BfBot.UI.TogglePanel()
    end
end)
```

### Injected Actionbar Button

A small button injected into the game's action bar that opens the BuffBot panel:

```lua
EEex_Menu_InjectTemplate("WORLD_ACTIONBAR", "BFBOT_BTN", x, 0, 48, 48)
```

Uses `EEex_Menu_InjectTemplate` (not actionbar interception), so it does NOT conflict with BSME's approach. The button uses a custom BAM icon (`BFBTN.BAM` — game-specific variant selected at install time).

### Future Triggers (Post-MVP)

| Trigger | Mechanism | Priority |
|---|---|---|
| **Direct cast hotkey** | F12 = cast long buffs without opening panel | High (easy) |
| **Custom innate ability** | Create an SPL that calls `BfBot.Exec.Start()` via EEex opcode hooks — feels native, shows in action bar. Requires creating a custom SPL at install time and granting it to all party members. | Medium |
| **AI script integration** | A BCS script block that reads `BB_SHOULD_BUFF` local variable and triggers casting. BuffBot Lua sets the variable based on conditions (entering area, rest complete, combat end). | Medium |
| **Combat-reactive** | AI script checks HP thresholds, buff expirations, enemy proximity → sets trigger variable → Lua executes appropriate preset | Low (complex) |

---

## 6. Execution Engine Design

### Queue Construction

```lua
function BfBot.Exec.BuildQueue(presetIndex)
    local queue = {}

    -- Iterate party members (slot 0-5)
    for slot = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(slot)
        if not sprite then goto continue end

        local config = BfBot.Cfg.GetConfig(sprite)
        if not config then goto continue end

        local preset = config.presets[presetIndex]
        if not preset then goto continue end

        -- Get this character's castable spells
        local castable = BfBot.Scan.GetCastableSpells(sprite)

        -- Build entries for enabled spells, sorted by priority
        local entries = {}
        for resref, spellCfg in pairs(preset.spells) do
            if spellCfg.on and castable[resref] then
                local cache = BfBot.spellCache[resref]
                if not cache then goto nextSpell end

                -- Expand targets
                local targets = BfBot.Exec.ResolveTargets(sprite, slot, spellCfg.tgt, cache)

                for _, target in ipairs(targets) do
                    -- Skip if buff already active on target
                    if config.opts.skip and BfBot.Exec.IsBuffActive(target.sprite, cache) then
                        goto nextTarget
                    end

                    table.insert(entries, {
                        casterSlot = slot,
                        caster = sprite,
                        resref = resref,
                        targetObj = target.bcsObj,   -- "Myself", "Player2", etc.
                        targetSprite = target.sprite,
                        priority = spellCfg.pri,
                        duration = cache.duration,
                    })

                    ::nextTarget::
                end
                ::nextSpell::
            end
        end

        -- Sort by priority (lower = first), then by duration (longest first as tiebreak)
        table.sort(entries, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            return (a.duration or 0) > (b.duration or 0)
        end)

        for _, entry in ipairs(entries) do
            table.insert(queue, entry)
        end

        ::continue::
    end

    BfBot.Exec.queue = queue
    BfBot.Exec.queueIndex = 0
end
```

### Target Resolution

Party-targeted spells (`tgt = "p"`) need different handling depending on whether the spell is AoE or single-target:

- **AoE buff** (Bless, Haste, Chant): One cast affects the whole party via its projectile. Cast once, targeting the caster (`Myself`) or the party center. Casting N times would waste N-1 spell slots.
- **Single-target friendly buff** (Protection from Evil, Stoneskin on others via mod): Must be cast once per target party member.

The spell cache includes an `isAoE` field determined during classification (see below).

```lua
function BfBot.Exec.ResolveTargets(casterSprite, casterSlot, targetCfg, spellCache)
    -- Self-only spells always target self
    if spellCache.defaultTarget == "s" then
        return {{ bcsObj = "Myself", sprite = casterSprite }}
    end

    if targetCfg == "s" then
        return {{ bcsObj = "Myself", sprite = casterSprite }}
    elseif targetCfg == "p" then
        if spellCache.isAoE then
            -- AoE party buff: cast once, targeting self (projectile covers party)
            -- Skip check uses caster as representative target
            return {{ bcsObj = "Myself", sprite = casterSprite }}
        else
            -- Single-target friendly buff: one cast per living party member
            local targets = {}
            for i = 0, 5 do
                local s = EEex_Sprite_GetInPortrait(i)
                if s and BfBot.Exec.IsAlive(s) then
                    table.insert(targets, {
                        bcsObj = "Player" .. (i + 1),
                        sprite = s,
                    })
                end
            end
            return targets
        end
    else
        -- Specific slot ("1"-"6")
        local slotNum = tonumber(targetCfg)
        if slotNum then
            local s = EEex_Sprite_GetInPortrait(slotNum - 1)
            if s then
                return {{ bcsObj = "Player" .. slotNum, sprite = s }}
            end
        end
        return {}
    end
end
```

#### AoE Detection

Determined during classification and cached in `spellCache.isAoE`. Detection heuristic:

1. **Extended header target type = 4** (any point / ground location): Always AoE.
2. **Extended header Target Count = 0** (at offset 0x000D): The "0=area" value indicates area-targeting.
3. **Feature block effect target types** (if accessible via R1): If any feature block uses effect target type 4 (everyone) or 6 (caster's group), the spell has AoE delivery.
4. **Fallback**: Spells with target type 1 (living actor) + friendly flag + target count > 0 are treated as single-target by default. Manual override via `BfBot.overrides[resref]` can flag them as AoE if misclassified.

Examples from research:
- **Bless (SPPR101)**: Target type 1, but described as "party-wide" — the projectile creates the AoE. Likely Target Count = 0 or feature block target = 4/6.
- **Haste (SPWI305)**: Target type 1, "area/party, friendly" — same pattern.
- **Protection from Evil (SPPR107)**: Target type 1, "single target, friendly" — Target Count = 1, cast per-target.
- **Stoneskin (SPWI408)**: Target type 5, self-only — never expanded to party.

```lua
function BfBot.Class.IsAoE(ability)
    -- Target type 4 is explicitly area-targeted
    if ability.target == 4 then return true end
    -- Target Count 0 indicates area delivery
    if ability.targetCount == 0 then return true end
    -- Feature block check (if accessible) — see R1
    -- Fallback: treat as single-target
    return false
end
```

**[NEEDS-TESTING]**: Verify `ability.targetCount` field exists on `Spell_ability_st` userdata. If not, fall back to projectile-based detection or manual classification.

### Active Buff Detection (Skip Logic)

```lua
function BfBot.Exec.IsBuffActive(targetSprite, spellCache)
    -- Method 1: Check SPLSTATE (fast, preferred)
    if spellCache.splstates and #spellCache.splstates > 0 then
        for _, stateID in ipairs(spellCache.splstates) do
            if EEex_Sprite_GetSpellState(targetSprite, stateID) then
                return true
            end
        end
        return false
    end

    -- Method 2: Effect iteration (fallback for spells without SPLSTATE)
    -- [NEEDS-TESTING] — depends on available EEex effect iteration API
    -- For MVP: if no SPLSTATE, assume not active (err on side of recasting)
    return false
end
```

### Normal Mode Execution

In normal mode, all spell actions are queued onto each caster's action queue at once. The engine handles pacing (6-second aura cooldown between casts, casting time, etc.).

```lua
function BfBot.Exec.ExecuteNormal()
    BfBot.Exec.state = "casting"

    -- Group queue entries by caster
    local byCaster = {}
    for _, entry in ipairs(BfBot.Exec.queue) do
        if not byCaster[entry.casterSlot] then
            byCaster[entry.casterSlot] = {}
        end
        table.insert(byCaster[entry.casterSlot], entry)
    end

    -- Queue all actions for each caster
    for slot, entries in pairs(byCaster) do
        local caster = entries[1].caster

        -- Announce start
        BfBot.Exec.Feedback(caster, "Buffing...")

        for _, entry in ipairs(entries) do
            local action = string.format(
                'Spell("%s",%s)',
                entry.resref,
                entry.targetObj
            )
            EEex_Action_QueueResponseStringOnAIBase(action, caster)
        end
    end

    -- The engine now processes queued actions automatically
    -- Track completion via action listeners or periodic polling
end
```

**Key design choice**: Queue ALL actions at once per caster, not one-at-a-time with manual delays. The engine's action queue already handles sequential execution with proper aura cooldown timing. This is simpler and more robust than trying to manage timing ourselves.

### Cheat Mode Execution

Cheat mode must still consume spell slots (per CLAUDE.md: "Spell slots still consumed"). The proven mechanism from EPS (Enhanced Powergaming Scripts) is `ReallyForceSpell()` + `RemoveSpell()`: the force-cast applies the spell instantly without requiring a memorized slot, then `RemoveSpell()` removes one memorized instance to "pay" for it.

```lua
function BfBot.Exec.ExecuteCheat()
    BfBot.Exec.state = "casting"

    for _, entry in ipairs(BfBot.Exec.queue) do
        -- Step 1: Force-cast the spell instantly (bypasses aura + cast time)
        local castAction = string.format(
            'ReallyForceSpellDead("%s",%s)',
            entry.resref,
            entry.targetObj
        )
        EEex_Action_ExecuteResponseStringOnAIBaseInstantly(castAction, entry.caster)

        -- Step 2: Remove one memorized instance to consume the slot
        -- RemoveSpell removes the spell from the memorized list (restores at rest)
        local removeAction = string.format(
            'RemoveSpell("%s")',
            entry.resref
        )
        EEex_Action_ExecuteResponseStringOnAIBaseInstantly(removeAction, entry.caster)
    end

    -- All spells applied instantly
    BfBot.Exec.state = "idle"
    BfBot.Exec.FeedbackAll("Buffing complete!")
end
```

**Why two actions**: `ReallyForceSpellDead` bypasses slot requirements (it always succeeds), so we must manually remove a slot with `RemoveSpell` to enforce the "slots still consumed" rule. This matches the proven EPS accelerated mode pattern. If the character has no memorized instance of the spell, `RemoveSpell` is a no-op — the spell still fires but costs nothing (edge case: innate abilities, which have no slots to consume anyway).

**[NEEDS-TESTING]**: Confirm `RemoveSpell` is in INSTANT.IDS and works with `ExecuteResponseStringOnAIBaseInstantly`. If not, queue it as a regular action after the instant cast instead.

### Spell Ordering

Default order within a preset: **longest duration first**. This is the proven strategy from EPS — cast the 12-hour Stoneskin before the 3-round Haste. The user can override this via the priority field in config.

Across casters: **party slot order** (Player1 first, Player6 last). This is simple and predictable. In normal mode, since each caster's actions are queued independently, all casters will start casting simultaneously (each waiting for their own aura cooldown).

### Handling Failures and Interruptions

**Slot exhaustion**: In normal mode, `Spell()` fails naturally if no slot is available — the action simply doesn't execute and the engine moves to the next queued action. No special handling needed; the caster just skips that spell silently.

For user-visible feedback on skipped spells, check slot counts BEFORE queuing:

```lua
-- Check if character has slots for this spell
local slotCount = castable[resref] and castable[resref].count or 0
if slotCount <= 0 then
    -- Skip and notify
    BfBot.Exec.Feedback(sprite, "Out of " .. spellName .. " slots")
    goto nextSpell
end
```

**Manual interruption**: If the player issues a manual command to a character mid-buffing, the engine clears that character's action queue (standard BG behavior). BuffBot does not need special handling — the remaining queued actions are simply lost. The player chose to interrupt.

**Combat interruption**: A spell being cast can be interrupted by damage. The engine handles this (caster takes damage → casting fails → next action in queue starts). BuffBot doesn't need to detect or retry — the queue continues with the next spell.

**State tracking**: A lightweight polling check on a timer (or piggyback on `EEex_Opcode_AddListsResolvedListener`) to detect when all casters have empty action queues → set `BfBot.Exec.state = "idle"`.

### Feedback

```lua
function BfBot.Exec.Feedback(sprite, message)
    local action = string.format('DisplayStringHead(Myself,%d)',
        BfBot.Exec.GetStringRef(message))
    EEex_Action_QueueResponseStringOnAIBase(action, sprite)
end
```

Or use `Infinity_DisplayString()` for console-style messages that don't appear over character heads.

**Note**: `DisplayStringHead` requires a strref (string reference number). For custom messages, we may need to use `EEex_Action_ExecuteResponseStringOnAIBaseInstantly('DisplayStringHead(Myself,X)', sprite)` where X is a pre-created strref, or use Infinity_DisplayString for a simpler approach. This is an open question (see §9).

---

## 7. MVP Scope

### What's In (MVP v0.1)

| Feature | Details |
|---|---|
| **Spell scanning** | Enumerate memorized wizard, priest, and innate spells via GetQuickButtons + iterator APIs |
| **Buff classification** | Friendly flag + target type scoring. MSECTYPE fast-path. Manual override table. (Opcode scanning if feature block access works — see R1 in §9) |
| **Duration classification** | Long vs Short based on feature block duration. Fallback: use MSECTYPE or manual categorization if feature blocks inaccessible |
| **Configuration UI** | Panel with character tabs (party slot buttons), preset tabs (2 default), spell list with checkboxes and target dropdowns |
| **Two default presets** | "Long Buffs" and "Short Buffs" auto-populated by duration category |
| **Target selection** | Per-spell target: Self, Party, or specific Player (1-6) |
| **Normal mode casting** | Queue Spell() actions via EEex_Action_QueueResponseStringOnAIBase, engine handles pacing |
| **Active buff skip** | Check SPLSTATE before queuing (for spells with known SPLSTATE mappings) |
| **Panel access** | Injected actionbar button + F11 keyboard shortcut |
| **Save persistence** | Config saved per-character via marshal handlers + UDAux |
| **Event-driven refresh** | Spell list updates on cast, rest, spell removal, disable state change |

### What's Out (Post-MVP)

| Feature | Reason | When |
|---|---|---|
| Cheat mode | Easy to add but not essential for first test | v0.2 |
| Presets 3-5 | UI and data model support them, but 2 is enough for MVP | v0.2 |
| Preset copy/duplicate | Nice-to-have | v0.2 |
| Effect iteration fallback | SPLSTATE covers most common buffs | v0.2 |
| Custom priority ordering | Default (longest-first) is good enough | v0.2 |
| INI preferences | Hardcode defaults for MVP | v0.3 |
| Preset export/import | Requires file I/O, edge cases. ExportPreset/ImportPreset to/from files. | v0.3 |
| Preset template library | Built-in shareable templates ("Standard Prebuff", "Boss Fight") stored outside saves | v0.3 |
| Custom spell ordering UI (drag) | Complex UI interaction | v0.3 |
| Healing mode | Entirely different trigger model | v0.4+ |
| Combat-reactive casting | Requires AI script integration | v0.5+ |
| Item abilities | Needs research on item ability enumeration | v0.4+ |
| Contingency/Sequencer setup | Complex, niche use case | v0.6+ |
| Multi-class spellbook merging | Works naturally since we scan all sources, but edge cases need testing | v0.2 |
| Party change handling | Config persists by character identity — needs testing for leave/rejoin | v0.2 |

### First Testable Milestone

**Milestone 0 — Skeleton** (can be tested in-game):
1. `M_BfBot.lua` loads without errors
2. Actionbar button appears and opens/closes an empty panel
3. F11 hotkey toggles the panel
4. Panel shows a list of the selected character's memorized spells (names + icons)
5. Config persists through save/load cycle

**Milestone 1 — Functional MVP**:
1. Spell list shows classified buff spells with enable/disable checkboxes
2. Target dropdown works (Self / Party / specific party member)
3. Two preset tabs (Long Buffs / Short Buffs) with auto-populated spell lists
4. "Cast" button triggers sequential buff casting in normal mode
5. Active buffs are skipped (SPLSTATE check)
6. Config changes persist in save game

---

## 8. Extension Roadmap

Priority order, with implementation notes:

### v0.2 — Quality of Life
1. **Cheat mode toggle**: Add `opts.cheat` to config, switch `ExecuteNormal()` ↔ `ExecuteCheat()` based on flag. Checkbox in options section.
2. **Presets 3-5**: Data model already supports them. Add tab buttons and "New Preset" / "Delete Preset" buttons.
3. **Preset copy/duplicate**: Deep-copy preset table, add to config.
4. **Effect iteration fallback**: For spells without SPLSTATE entries, iterate active effects checking source resref. Depends on resolving the effect iteration API (R3 in §9).
5. **Party change resilience**: Test leave/rejoin behavior. Config keyed by character name + ID. Warn on name collision.

### v0.3 — Polish
6. **Custom spell priority ordering**: Slider or drag-reorder in the spell list. Already has `pri` field in config.
7. **INI preferences panel**: Simple options menu (long/short threshold, hotkey, tooltips).
8. **Preset export/import**: `io.open()` for write, `loadfile()` for read. Validate schema on import.
9. **Spell description tooltip**: Show spell description on hover/right-click using `Infinity_FetchString(header.genericDescription)`.
10. **Cast progress indicator**: Show "Casting 3/12..." counter during execution.
11. **Config rematch to different character**: Per CLAUDE.md: "Rematching config to a different character is possible but requires explicit player confirmation with a warning." UI flow: select a character with no config → offer to copy config from another character (dropdown) → confirmation dialog warning that this replaces any existing config on the target. Useful when replacing a party member with a similar-class character (e.g., swapping one cleric for another).

### v0.4 — Items & Advanced
12. **Equipped item abilities**: Enumerate via item quick buttons (`GetQuickButtons` type for items — needs research). Show in spell list alongside spells. Deferred from MVP because: (a) the `GetQuickButtons` button type for equipped item abilities is unconfirmed and needs runtime testing; (b) item abilities have different casting mechanics (uses/day vs memorized slots); (c) CLAUDE.md lists equipped abilities as in-scope but not MVP-critical. Per CLAUDE.md: "Equipped item abilities (e.g., activated item effects) should be available in the config alongside spells/abilities."
13. **Healing button**: New preset category. Trigger: HP threshold check via periodic polling or `EEex_Opcode_AddListsResolvedListener`. Spells classified by opcode 17 (healing).
14. **Bard Song handling**: Detect spell type 5, treat as modal action rather than cast. Toggle via `EEex_Action_QueueResponseStringOnAIBase('BardSong()', sprite)`.

### v0.5 — AI Integration
15. **Combat-reactive short buffs**: BCS script block reads `BB_SHOULD_SHORT_BUFF` local variable. BuffBot Lua sets it based on: entering combat (`See([EVILCUTOFF])`), combat starting nearby, or manual trigger. Script calls `EEex_Action_QueueResponseStringOnAIBase()` to execute the short buff preset.
16. **Auto-rebuff on expiration**: Track buff durations via game timer. When a buff is about to expire (< 1 round remaining), re-queue the cast. Requires duration tracking per active buff.

### v0.6+ — Advanced
17. **Contingency/Sequencer auto-setup**: Create contingency/sequencer with pre-selected spells. Complex — requires understanding `SetupContingency()` and `FillContingency()` BCS actions or Lua equivalents.
18. **Advanced targeting rules**: "Cast Stoneskin on whoever has lowest AC" — requires evaluating party stats at cast time. Adds conditional logic to target resolution.
19. **Per-encounter vs per-rest buff profiles**: Detect rest completion (via `QuickListCountsResetListener`) and auto-trigger long buff preset. Detect combat end and auto-trigger short buff preset.

---

## 9. Risks and Open Questions

> **Status**: All critical and high risks resolved. Spell Scanner + Classifier implemented and tested in-game (52 tests passing, Feb 2025).
>
> **Implementation findings** (verified in-game):
> - `durationType` must be masked: `bit.band(rawTiming, 0xFF)` — EEex reads it as word/dword, not byte
> - `print()` goes to stdout (invisible in EEex console) — use `Infinity_DisplayString()` for in-game output
> - No `Infinity_DisplayString()` calls during M_ file loading — engine display not ready, causes crash
> - Friendly flag (bit 10 of `ability.type`) is unreliable — many buff spells (Haste, Bless) don't set it. Opcode scoring is the primary classification signal.
> - MSECTYPE values in modded games can exceed 0-13 (e.g., SCS Haste = 20). Safe: table returns 0 for unknown.
> - `GetQuickButtons(2, false)` confirmed returns wizard+priest combined (tested on Jaheira cleric/druid)
> - Only **1 runtime test** remains: Q9 (InjectTemplate + resolution change). Q2 and Q7 are confirmed.

### Resolved Risks

**R1: Feature Block Access API** `[CRITICAL]` → **RESOLVED**

Feature blocks use the `Item_effect_st` type (48 bytes, shared between SPL and ITM). Access via pointer arithmetic on `Spell_Header_st.effectsOffset` + `Spell_ability_st.startingEffect`:

```lua
function BfBot.Class.GetFeatureBlock(header, ability, index)
    local ptr = EEex_UDToPtr(header)
        + header.effectsOffset
        + Item_effect_st.sizeof * (ability.startingEffect + index)
    return EEex_PtrToUD(ptr, "Item_effect_st")
end

for i = 0, ability.effectCount - 1 do
    local fb = BfBot.Class.GetFeatureBlock(header, ability, i)
    -- fb.effectID = opcode, fb.durationType = timing mode, fb.duration = seconds
    -- fb.targetType = effect target, fb.res = resource resref
    -- fb.effectAmount = param1, fb.dwFlags = param2, fb.special = special
end
```

Confirmed from `EEex_Resource.lua` (same pointer arithmetic pattern as `EEex_Resource_GetSpellAbility`) and EEex v0.11.0 official structure documentation.

**IESDP → EEex field name mapping** (critical for implementation):

| IESDP Name | EEex Field | On Type | Notes |
|---|---|---|---|
| Target Type | `actionType` | `Spell_ability_st` | 1=living actor, 4=any point, 5=caster, 7=caster alt |
| Target Count | `actionCount` | `Spell_ability_st` | 0=area, 1+=selectable targets |
| Flags (friendly bit) | `type` (bit 10) | `Spell_ability_st` | `bit.band(ability.type, 0x0400) ~= 0` for friendly |
| Feature Block Count | `effectCount` | `Spell_ability_st` | Number of effects for this ability |
| Feature Block Offset | `startingEffect` | `Spell_ability_st` | Index into global effect table |
| Feature Block Table Offset | `effectsOffset` | `Spell_Header_st` | File offset to effect table |
| Casting Time | `speedFactor` | `Spell_ability_st` | In tenths of a round |
| Projectile | `missileType` | `Spell_ability_st` | PROJECTL.IDS + 1 |
| Secondary Type (MSECTYPE) | `secondaryType` | `Spell_Header_st` | |
| Opcode | `effectID` | `Item_effect_st` | Effect opcode number |
| Timing Mode | `durationType` | `Item_effect_st` | 0=limited, 1=permanent, 4=perm until dispelled |
| Duration | `duration` | `Item_effect_st` | In seconds |
| Effect Target Type | `targetType` | `Item_effect_st` | 4=everyone, 6=caster's group → AoE |
| Parameter 1 | `effectAmount` | `Item_effect_st` | |
| Parameter 2 | `dwFlags` | `Item_effect_st` | |
| Resource | `res` | `Item_effect_st` | 8-byte resref (for opcode 282/321) |

**R2: GetQuickButtons Button Types** `[HIGH]` → **RESOLVED (high confidence)**

BSME (by EEex's author) uses `sprite:GetQuickButtons(2, 0)` and labels it "Wizard/Priest memorized spells" in its source comments. Type 2 returns both wizard and priest memorized spells; type 4 returns innates. If priest needed a separate type, every multi-class Cleric/Mage in BSME would be broken.

Fallback confirmed: `EEex_Sprite_GetKnownPriestSpellsWithAbilityIterator(sprite, 1, 7)` exists in `EEex_Sprite.lua:837` but returns *known* spells (spellbook), not *memorized* (castable).

**R3: Effect Iteration API** `[MEDIUM]` → **RESOLVED**

The modern API for iterating active effects is direct field access on `CGameSprite` userdata, confirmed in `B3EffMen.lua:123` and `EEex_Trigger.lua:76-81`:

```lua
-- Timed effects (buffs with duration)
EEex_Utility_IterateCPtrList(sprite.m_timedEffectList, function(effect)
    -- effect is CGameEffect userdata
    -- effect.m_effectId = opcode number
    -- effect.m_sourceRes:get() = source spell resref
    -- effect.m_duration, effect.m_durationType, etc.
end)

-- Equipped item effects
EEex_Utility_IterateCPtrList(sprite.m_equipedEffectList, function(effect)
    -- same CGameEffect fields
end)
```

This provides the active buff fallback check for spells without SPLSTATE entries: iterate `m_timedEffectList`, match `m_sourceRes` against the spell resref being checked.

**R4: Marshal Handler Availability** `[HIGH]` → **RESOLVED**

Confirmed in `EEex_Sprite.lua:983-990` (v0.11.0-alpha):

```lua
function EEex_Sprite_AddMarshalHandlers(handlerName, exporter, importer)
    EEex_Sprite_Private_MarshalHandlers[handlerName] = {
        ["exporter"] = exporter,  -- function(sprite) -> table
        ["importer"] = importer,  -- function(sprite, table)
    }
end
```

Full binary serialization system: Lua tables → binary data appended to CRE effects list → restored on load. `EEex_GetUDAux(sprite)` used throughout the codebase. The system even preserves data from missing handlers as fallback storage (`EEex_Sprite.lua:1409-1411`), making it safe for mod uninstall/reinstall scenarios.

### Moderate Risks (Unchanged)

**R5: InjectTemplate Position** `[MEDIUM]`
- Position depends on UI framework and resolution. Measure dynamically via `Infinity_GetMenuArea("WORLD_ACTIONBAR")`.
- `EEex_Menu_AddWindowSizeChangedListener` confirmed available for repositioning.
- Set base x/y via EVALUATE_BUFFER from the tp2.

**R6: DisplayStringHead for Custom Messages** `[LOW]` → **Partially Resolved**
- `DisplayStringHead` is **NOT** in INSTANT.IDS. Only `DisplayStringHeadDead` (ID 342) and `DisplayStringHeadNoLog` (ID 388) are instant-capable.
- EEex provides Lua-side feedback: `sprite:displayTextRef(strref, {overHead = true})` (`EEex_Sprite.lua:928-948`) — does not require INSTANT.IDS.
- MVP plan: Use `Infinity_DisplayString()` for console-style feedback, or `sprite:displayTextRef()` for overhead text.

**R7: Action Queue Conflicts** `[MEDIUM]` — Working-as-designed, no action needed.

**R8: Concurrent Casting Across Party** `[LOW]` — Working-as-designed, no action needed.

### Resolved: Cheat Mode Slot Consumption (Q12)

**`RemoveSpell` is NOT in INSTANT.IDS.** The cheat mode design must be adjusted:

```lua
-- Step 1: Instant cast (works — ReallyForceSpellDead IS in INSTANT.IDS, ID 240)
EEex_Action_ExecuteResponseStringOnAIBaseInstantly(
    'ReallyForceSpellDead("SPWI304",Myself)', caster)

-- Step 2: Queue slot consumption as regular action (RemoveSpell NOT instant-capable)
EEex_Action_QueueResponseStringOnAIBase(
    'RemoveSpell("SPWI304")', caster)
```

This means cheat mode isn't fully instant — the slot removal happens asynchronously. Acceptable because: (a) the buff effect IS applied instantly, (b) slot consumption is a bookkeeping detail, (c) cheat mode is post-MVP.

### Open Questions Status

| ID | Question | Status | Resolution |
|---|---|---|---|
| Q1 | `Spell_ability_st` fields | **RESOLVED** | Full field listing from EEex v0.11.0 docs (see R1 table above) |
| Q2 | GetQuickButtons priest type | **RESOLVED (100%)** | Verified in-game: GetQuickButtons(2,0) returns wizard+priest combined. Tested on Jaheira (cleric/druid). |
| Q3 | MarshalHandlers existence | **RESOLVED** | Confirmed in EEex_Sprite.lua:983-990 |
| Q4 | UDAux config size limits | **Deferred** | Post-MVP concern. Config tables are small (~2KB for 5 presets) |
| Q5 | ReallyForceSpellDead cross-targeting | **Deferred** | Cheat mode is post-MVP |
| Q6 | Spell() with no slot | **Deferred** | Expected to fail silently (standard engine behavior). Post-MVP concern |
| Q7 | Multiple queued actions on same caster | **DEFERRED** | Not yet tested directly, but scanner + classification runs 52 tests successfully. Action queuing test deferred to execution engine implementation. |
| Q8 | BCS target object syntax | **RESOLVED** | `Player1` through `Player6`, confirmed from EEex source and ACTION.IDS |
| Q9 | InjectTemplate + resolution change | **NEEDS RUNTIME** | Quick check — `WindowSizeChangedListener` available as backup |
| Q10 | EEex version in circulation | **RESOLVED** | v0.11.0-alpha (latest release) |
| Q11 | `ability.targetCount` field | **RESOLVED** | Field is `ability.actionCount` (offset 0x0D) |
| Q12 | RemoveSpell in INSTANT.IDS | **RESOLVED** | NOT in INSTANT.IDS. Cheat mode adjusted (see above) |

### Remaining Runtime Tests (2 items)

1. **Q7: Multiple queued Spell() actions** — Queue 3+ `Spell()` actions on the same caster via `EEex_Action_QueueResponseStringOnAIBase`. Verify all execute sequentially. Test during execution engine implementation.
2. **Q9: InjectTemplate resilience** — Change game resolution, verify injected actionbar button persists. Test during UI implementation.

These are quick manual checks (5-10 minutes total), not a diagnostic harness.

---

## Verification Plan

### Testing Strategy for MVP

1. **Pre-implementation runtime checks** (5-10 minutes, in-game Lua console):
   - Q7: Queue 3 Spell() actions on same caster, verify sequential execution
   - Q2: Check GetQuickButtons(2,0) on a Cleric includes SPPR* resrefs
   - Q9: Inject a template, change resolution, check persistence

2. **Unit-level** (Lua console): Test spell scanning, classification, and config operations by calling BfBot functions directly from the game's Lua console (accessible via EEex)

3. **Integration** (in-game):
   - Create a party with mixed classes (Fighter/Mage, Cleric, pure Mage, Bard)
   - Memorize a variety of known buff and non-buff spells
   - Open BuffBot panel → verify correct spell classification
   - Toggle spells on/off → verify config updates
   - Set different targets → verify target dropdown
   - Click "Cast Long Buffs" → verify spells cast in correct order on correct targets
   - Save game → reload → verify config persists
   - Rest → verify spell list refreshes
   - Level up → verify new spells appear

4. **Edge cases**:
   - Character with no buff spells (should show empty list)
   - All spells already active (should skip all, show feedback)
   - Only 1 spell slot remaining for a level with 3 enabled buffs
   - Party member leaves mid-config → rejoin → verify config restoration
   - Interrupt buffing by issuing manual command → verify graceful handling

---

*This document is the implementation blueprint for BuffBot. All APIs, opcodes, and patterns are grounded in the research documents in `docs/` and verified against EEex v0.11.0-alpha source code. Items marked [NEEDS RUNTIME] require brief in-game verification (5-10 minutes total) before implementation proceeds.*
