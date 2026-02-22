# Bubb's Spell Menu Extended (BSME) — Analysis for BuffBot

> BSME v5.1 (Oct 2024) · Requires EEex v0.10.1.1-alpha+ · Same author as EEex (Bubb13)
>
> GitHub: https://github.com/Bubb13/Bubbs-Spell-Menu-Extended
> Forum: https://forums.beamdog.com/discussion/68958/mod-bubbs-spell-menu-v5-1

BSME replaces the stock actionbar spell-selection interface with a full-screen (or overlay) grid showing all spells at once, searchable and filterable. It is the single most important reference implementation for BuffBot: same tech stack (Lua + .menu + WeiDU + EEex), same author as our core dependency, and demonstrates canonical patterns for everything from spell enumeration to dynamic UI generation.

---

## 1. Architecture

### 1.1 File Structure

BSME is a pure Lua + .menu mod. No BAF/BCS scripts, no 2DA files, no SPL files. All engine interaction goes through EEex's Lua bridge.

| File | Lines | Role |
|------|-------|------|
| `B3Spell.menu` | ~371 | UI definitions: 3 menus, 6 template types. Processed by WeiDU `EVALUATE_BUFFER` for variable substitution. |
| `M_B3Spel.lua` | ~2583 | **Main logic**: instance creation system, options/state, slot layout, spell rendering, filtering, sorting, options panel, slot area selection. |
| `B3SpelEx.lua` | ~875 | **Infrastructure**: actionbar hooks, key listeners, spell casting APIs, event listeners, spell enumeration (`FillFromMemorized`), menu file loading, initialization. |
| `B3SplWei.lua` | ~67 | **WeiDU-generated constants**: translated tooltip strings, UI dimensions, BAM names. Template with `%variable%` placeholders filled at install time. |
| `bubb_spell_menu_extended.tp2` | ~160 | WeiDU installer: prerequisite checks, UI framework detection, variable injection, file copying. |
| BAM files | — | Slot backgrounds (game-specific variants for BG:EE/BG2:EE/IWD:EE), innate markers, level numbers, selection box. |

### 1.2 Initialization Chain

```
Engine loads UI.MENU
    → EEex patches applied
    → EEex_Menu_AddMainFileLoadedListener callbacks fire
        → B3Spell_InstallActionbarEnabledHook() runs:
            1. EEex_Menu_LoadFile("B3Spell")        -- loads B3Spell.menu
            2. EEex_Menu_Find("WORLD_ACTIONBAR")     -- finds the actionbar menu
            3. Hooks actionbar onOpen/onClose events
            4. Wraps every actionbar button's 'enabled' function
               to respect B3Spell_ActionbarDisable flag
            5. Creates portrait templates from RIGHT_SIDEBAR items
        → EEex_Actionbar_AddListener(B3Spell_ActionbarListener)
        → EEex_Key_AddPressedListener(B3Spell_KeyPressedListener)
        → Spell state listeners registered (4 listeners, see §3.3)
```

### 1.3 WeiDU EVALUATE_BUFFER Pattern

The .tp2 installer detects the active UI framework (vanilla BG:EE, Dragonspear UI++, LeUI, Infinity UI++, EET, etc.) via a cascading if/else chain, then sets WeiDU variables for game-specific constants: slot BAM names, slider backgrounds, button BAMs, search bar dimensions, Y-offsets.

These variables are injected into `B3SplWei.lua` and `B3Spell.menu` at install time via `EVALUATE_BUFFER`:

```
// In .tp2:
SPRINT ~slotBam~ ~B3SLOT~
SPRINT ~tooltipSearchBar~ @12    // from .tra translation file

// B3SplWei.lua template:
B3Spell_SlotBam = "%slotBam%"
B3Spell_Tooltip_SearchBar = "%tooltipSearchBar%"

// After install:
B3Spell_SlotBam = "B3SLOT"
B3Spell_Tooltip_SearchBar = "Search..."
```

This bridges install-time decisions (which UI mod, which language) into runtime Lua constants. BuffBot should use the same technique for translated strings and UI-framework-dependent values.

### 1.4 What This Proves for BuffBot

A complex spell-related mod can work **entirely in Lua** without compiled scripts. BSME has zero BAF/BCS files — all spell enumeration, UI management, and casting goes through EEex Lua APIs. This validates BuffBot's planned architecture of Lua + .menu for the configuration panel and casting logic.

---

## 2. UI Implementation

### 2.1 Three Menus

BSME defines three menus in `B3Spell.menu`:

**`B3Spell_Menu`** (main spell grid):
- Full-screen or overlay grid of spell icons
- Static elements: exit background, dark background overlay, search bar (edit element), slot size slider, optimize button
- Template instances: spell icons, slot backgrounds, click targets, key binding labels, innate markers, filter buttons, scroll arrows, options button

**`B3Spell_Menu_Options`** (settings panel):
- Toggle options: auto-pause, background dimming, modal, search focus, slot optimization, control bar, monolithic mode, alignment, key bindings display
- Uses text + toggle template instances positioned dynamically
- "Select Slots Area" button opens the third menu

**`B3Spell_Menu_SelectSlotArea`** (area selection):
- Drag handles (top/right/bottom/left) for resizing the spell grid area
- Accept button to confirm

### 2.2 Template Instance System (Core Pattern)

BSME does **not** use the `list` widget for its spell grid. Instead, each spell slot is composed of multiple layered template instances, all positioned programmatically.

**Template types defined in .menu:**

| Template | Element Type | Purpose |
|----------|-------------|---------|
| `TEMPLATE_Bam` | label | Slot background BAM, generic BAM display |
| `TEMPLATE_Icon` | label | Spell icon with count overlay, greyscale, tint |
| `TEMPLATE_Action` | button | Invisible click target: tooltip, left-click (cast), right-click (description) |
| `TEMPLATE_BamButton` | button | Clickable BAM: scroll arrows, filter buttons |
| `TEMPLATE_Text` | label | Text display: key bindings, labels |
| `TEMPLATE_OptionsButton` | button | Opens options panel |

Each spell slot is rendered as 3-5 layered instances:
1. `TEMPLATE_Bam` — slot frame background
2. `TEMPLATE_Icon` — spell icon with castable count and greyscale state
3. `TEMPLATE_Text` — key binding label (if enabled)
4. `TEMPLATE_Bam` — innate marker (if innate ability)
5. `TEMPLATE_Action` — invisible click overlay with tooltip

### 2.3 Instance Lifecycle

**Creation:**
```lua
function B3Spell_CreateInstance(menuName, templateName, x, y, w, h)
    local entry = B3Spell_InstanceIDs[menuName][templateName]
    local newID = entry.maxID + 1
    entry.maxID = newID
    entry.instanceData[newID] = { ["id"] = newID }

    local oldID = currentAnimationID
    currentAnimationID = newID
    Infinity_InstanceAnimation(templateName, nil, x, y, w, h, nil, nil)
    currentAnimationID = oldID

    return entry.instanceData[newID]
end
```

**Data binding** — each template callback uses the engine-set global `instanceId`:
```lua
function B3Spell_Menu_TEMPLATE_Icon_Icon()
    return B3Spell_InstanceIDs["B3Spell_Menu"]["B3Spell_Menu_TEMPLATE_Icon"]
        .instanceData[instanceId].icon
end
```

**Positioning:**
```lua
EEex_Menu_StoreTemplateInstance(menuName, templateName, id, "TempAlias")
Infinity_SetArea("TempAlias", x, y, w, h)
```

**Destruction:**
```lua
function B3Spell_DestroyInstances(menuName)
    EEex_Menu_DestroyAllTemplates(menuName)
    -- Reset maxID and instanceData for all templates in this menu
end
```

**Global registry:**
```lua
B3Spell_InstanceIDs = {
    ["B3Spell_Menu"] = {
        ["B3Spell_Menu_TEMPLATE_Icon"] = {
            maxID = 0,
            instanceData = {
                [1] = { icon = "SPWI304", count = 2, ... },
                [2] = { icon = "SPWI305", count = 1, ... },
                ...
            }
        },
        ...
    }
}
```

### 2.4 Dynamic Layout

The slot grid is calculated at runtime based on available screen space:

1. **Slot size optimization** — iterates from max slot size downward until all spells fit. In overlay mode, targets 50% of vertical space.
2. **Row calculation** — each spell level gets at least one row. Overflow spells get additional rows or scroll arrows.
3. **Alignment** — horizontal (left/center/right) and vertical (top/center/bottom) configurable.
4. **All positioning via Lua** — the .menu file defines no positions for templates; everything is set at runtime via `Infinity_SetArea()`.

### 2.5 Options System

Options are declared in a `B3Spell_Options` table with a compact structure per option:

```lua
{
    set = function(val) ... end,
    get = function() return ... end,
    write = function(val) Infinity_SetINIValue("Bubbs Spell Menu Extended", key, val) end,
    forceOthers = {                    -- cascading dependencies
        ["Auto-Pause"] = 0,
        ["Disable Control Bar"] = 1,
    },
    toggleWarning = "Are you sure?",   -- confirmation before toggle
    onChange = function() ... end,      -- callback
    suboptions = { ... },              -- nested radio-button options
}
```

The `forceOthers` mechanism is notable: enabling one option can automatically enable/disable others (e.g., enabling "Always Open" forces "Auto-Pause" off and "Disable Control Bar" on). BuffBot's preset system could use a similar declarative dependency pattern.

---

## 3. Spell Data Access

### 3.1 Enumeration via GetQuickButtons

The primary spell enumeration function is `B3Spell_FillFromMemorized`:

```lua
local sprite = EEex_GameObject_GetSelected()

-- Wizard/Priest memorized spells
local spellButtons = sprite:GetQuickButtons(2, 0)

-- Innate abilities
local innateButtons = sprite:GetQuickButtons(4, 0)

EEex_Utility_IterateCPtrList(spellButtons, function(buttonData)
    local resref = buttonData.m_abilityId.m_res:get()  -- e.g., "SPWI304"
    local count  = buttonData.m_count                   -- remaining casts
    local icon   = buttonData.m_icon:get()              -- BAM name
    local name   = buttonData.m_name                    -- strref
    local off    = buttonData.m_bDisabled               -- 1 if disabled (Silence, etc.)

    local header = EEex_Resource_Demand(resref, "SPL")
    local level  = header.spellLevel                    -- 1-9
    local type   = header.itemType                      -- 1=Wizard, 2=Priest, 4=Innate
    local desc   = header.genericDescription            -- strref
    ...
end)
```

**Critical detail**: `GetQuickButtons(2, 0)` returns **memorized** (castable) spells, not all known spells. This is exactly what BuffBot needs — it's the character's current available spell list, already filtered by memorization state.

### 3.2 Spell Data Structure

BSME stores each spell as:

```lua
{
    slotOrderType        = ...,              -- sort group (for monolithic mode)
    spellCastableCount   = m_count,          -- remaining memorizations
    spellDescription     = genericDescription, -- description strref
    spellDisabled        = m_bDisabled == 1, -- disabled by Silence, etc.
    spellIcon            = m_icon:get(),     -- BAM resref for icon
    spellKeyBindingName  = ...,              -- hotkey display name
    spellLevel           = spellLevel,       -- 1-9+
    spellModeType        = modeType,         -- Normal/Innate/Opcode214
    spellName            = Infinity_FetchString(nameStrref),
    spellNameStrref      = nameStrref,
    spellQuickButtonType = quickButtonType,  -- 2 or 4
    spellRealNameStrref  = genericName,      -- SPL header name strref
    spellResref          = resref,           -- "SPWI304" etc.
    spellType            = itemType,         -- 1=Wizard, 2=Priest, etc.
}
```

### 3.3 Event-Driven Refresh

BSME keeps the UI synchronized with engine state via four listeners:

```lua
-- Spell count decremented (a spell was cast)
EEex_Sprite_AddQuickListsCheckedListener(B3Spell_OnSpellCountChanged)

-- All counts reset (after rest)
EEex_Sprite_AddQuickListCountsResetListener(B3Spell_OnSpellCountsReset)

-- Spell removed from list
EEex_Sprite_AddQuickListNotifyRemovedListener(B3Spell_OnSpellRemoved)

-- Spell disabled/enabled (e.g., Silence cast/dispelled)
EEex_Sprite_AddSpellDisableStateChangedListener(B3Spell_OnSpellDisableStateChanged)

-- Game destroyed (save load, quit)
EEex_GameState_AddDestroyedListener(B3Spell_OnGameDestroyed)
```

Each handler: destroy all instances → re-read spell data → re-create instances. This full-rebuild approach is simpler than incremental updates and works well because the spell grid is relatively small (dozens of instances, not hundreds).

### 3.4 Opcode #214 (Sequencer/Contingency) Spells

For internal spell lists created by opcode #214 (Spell Sequencer, Minor Sequencer, Contingency, Spell Trigger), BSME uses a different API:

```lua
local internalButtons = sprite:GetInternalButtonList()
-- Cast via:
sprite:ReadyOffInternalList(buttonData.m_CButtonData, 0)
```

This is separate from the normal spell enumeration path. BuffBot likely doesn't need this for MVP since sequencers/contingencies are explicitly out of scope.

---

## 4. User Interaction Patterns

### 4.1 Actionbar Interception

BSME intercepts the engine's actionbar state changes to replace the stock spell selection:

```lua
function B3Spell_ActionbarListener(config, state)
    -- Spell-related actionbar configs:
    -- 21 = Cast Spell (regular)
    -- 23 = Special Abilities
    -- 28 = Opcode #214 Internal List (sequencer/contingency)
    -- 30 = Cleric/Mage Spells

    if config == 21 then
        EEex_Actionbar_RestoreLastState()  -- revert actionbar (no flash)
        B3Spell_LaunchSpellMenu("Normal", spriteID)
    elseif config == 23 then
        EEex_Actionbar_RestoreLastState()
        B3Spell_LaunchSpellMenu("Innate", spriteID)
    -- ... etc
    end
end

EEex_Actionbar_AddListener(B3Spell_ActionbarListener)
```

The `RestoreLastState()` call immediately reverts the actionbar, so the user never sees the stock spell panel — the BSME grid appears instead. BuffBot should **not** use this approach (it would conflict with BSME), but should use `EEex_Menu_InjectTemplate` to add a custom button instead (see §5.2).

### 4.2 Casting

Casting is a single engine call:

```lua
sprite:ReadySpell(spellData.m_CButtonData, 0)
```

This is equivalent to the player clicking a spell in the stock UI. The engine handles everything: aura cooldown, casting animation, targeting cursor for targeted spells, interrupts.

In non-overlay mode, BSME pops its menu before casting. In overlay ("Always Open") mode, it stays open.

### 4.3 Filtering

Four filter modes, applied to the spell list before rendering:

| Filter | Logic |
|--------|-------|
| All | Show everything (wizard + priest + innate) |
| Mage | `spellType == 1` (wizard only) |
| Cleric | `spellType == 2` (priest only) |
| Search | Case-insensitive substring match on `spellName` |

Filters are toggle buttons in the control bar. The search bar is an `edit` element bound to `B3Spell_SearchEdit` — the engine provides two-way binding via the `var` property.

### 4.4 Sorting

BSME implements a natural alphanumeric sort (`B3Spell_AlphanumericSortSpellInfo`) that handles embedded numbers correctly (e.g., "Level 2" sorts before "Level 10"). Sort keys in priority order:

1. `slotOrderType` — monolithic mode grouping (innates first, spells first, or mixed)
2. `spellLevel` — numerical spell level
3. `spellName` — alphabetical

### 4.5 Display Modes

| Mode | Behavior |
|------|----------|
| **Standard** | Full-screen modal grid. Opens on cast-spell click, closes after casting or escape. |
| **Overlay** ("Always Open") | Persistent widget hovering over the game world. Stays open after casting. |
| **Monolithic** | Spells + innates combined in a single view (vs. separate menus). Configurable sort order. |

### 4.6 Settings Persistence

All BSME options persist via `Infinity_GetINIValue` / `Infinity_SetINIValue` under the INI section `"Bubbs Spell Menu Extended"`. This is **global** (not per-save), which is appropriate for UI preferences but not for per-character buff configurations.

---

## 5. Code Patterns We Should Adopt

### Pattern 1: Template Instance Management

**What BSME does**: Global `B3Spell_InstanceIDs` table tracks all template instances by `[menuName][templateName][instanceId]`. Each template callback looks up `instanceId` to find its data.

**How BuffBot should adapt**: Same pattern for spell rows in the config panel. Each spell entry needs an icon, name label, checkbox, and target dropdown — all as template instances with data in a global registry.

```lua
-- BuffBot adaptation:
BuffBot_InstanceIDs = {}

function BuffBot_CreateInstance(menuName, templateName, x, y, w, h, data)
    -- Same lifecycle as BSME
    local entry = BuffBot_InstanceIDs[menuName][templateName]
    local newID = entry.maxID + 1
    entry.maxID = newID
    entry.instanceData[newID] = data  -- spell config data
    ...
end
```

### Pattern 2: Menu File Loading Chain

**What BSME does**:
```lua
EEex_Menu_AddMainFileLoadedListener(function()
    EEex_Menu_LoadFile("B3Spell")
    -- Hook existing menus, register listeners
end)
```

**How BuffBot should adapt**: Identical chain. Register a `MainFileLoadedListener`, call `EEex_Menu_LoadFile("BuffBot")`, then inject our button into the actionbar and register spell state listeners.

### Pattern 3: Spell Enumeration via GetQuickButtons

**What BSME does**: `sprite:GetQuickButtons(2, 0)` + `sprite:GetQuickButtons(4, 0)` + `EEex_Utility_IterateCPtrList` to enumerate memorized spells and innates.

**How BuffBot should adapt**: Same API, but additionally:
- Load the SPL header via `EEex_Resource_Demand(resref, "SPL")` to access extended headers
- Read the Extended Header flags byte (bit 2 = "Friendly ability") for buff classification
- Read feature blocks for opcode-based buff scoring
- Read duration from feature block timing mode + duration fields

BSME only reads `spellLevel`, `itemType`, and string refs from the SPL header. BuffBot needs to go deeper into the spell data.

### Pattern 4: Event-Driven Refresh

**What BSME does**: Four listeners (QuickListsChecked, QuickListCountsReset, QuickListNotifyRemoved, SpellDisableStateChanged) trigger full UI rebuild.

**How BuffBot should adapt**: Same four listeners, but BuffBot's response differs:
- When spell counts change → update the config panel's "available" indicators
- When spells are removed → remove from config or mark unavailable
- When disabled state changes → grey out in config or skip during casting
- BuffBot also needs to refresh when the selected character changes (party tab switch)

### Pattern 5: WeiDU EVALUATE_BUFFER Bridge

**What BSME does**: `.tp2` detects UI framework, sets variables, substitutes into `B3SplWei.lua` and `B3Spell.menu` at install time.

**How BuffBot should adopt**: Same pattern for:
- Translated strings (tooltip text, button labels, section headers)
- UI-framework-dependent BAM names and dimensions
- Any install-time configuration choices

### Pattern 6: Actionbar Button Injection (not interception)

**What BSME does**: Intercepts actionbar configs 21/23/28/30 to replace the stock spell panel. This conflicts with other mods doing the same.

**What BuffBot should do instead**: Inject a dedicated button via `EEex_Menu_InjectTemplate("WORLD_ACTIONBAR", "BUFFBOT_BTN", x, y, w, h)`. This adds our button without replacing any existing functionality, and is compatible with BSME being installed simultaneously. See [eeex-api-surface.md §7](eeex-api-surface.md) and [ui-menu-patterns.md §4.3, Option A](ui-menu-patterns.md).

### Pattern 7: Options with Cascading Dependencies

**What BSME does**: Declarative `forceOthers` in the options table — toggling one option auto-sets others.

**How BuffBot should adapt**: For preset-level settings that interact (e.g., "cheat mode" should auto-enable "ignore slot exhaustion"), use the same declarative dependency pattern.

---

## 6. Differences from Our Needs

### 6.1 No Buff Classification

**BSME**: Shows all spells. No concept of "buff" vs "offensive" vs "utility."

**BuffBot needs**: Opcode-based scoring algorithm (see [spell-system-and-buff-classification.md §4](spell-system-and-buff-classification.md)) using Extended Header friendly flag (bit 2), target type, and feature block opcode scanning. Plus manual override table for edge cases.

### 6.2 No Targeting Logic

**BSME**: Triggers normal engine casting (`sprite:ReadySpell`), which shows the targeting cursor for targeted spells. The player picks the target manually.

**BuffBot needs**: Automatic target assignment per-spell. Must use BCS action strings like `Spell("SPWI305", PartySlot2)` via `EEex_Action_QueueResponseStringOnAIBase` to specify the target programmatically. Self-only spells target the caster; party buffs target each party member in sequence. Per-spell override lets the player assign specific targets. See [eeex-api-surface.md §4](eeex-api-surface.md).

### 6.3 No Queued/Sequential Casting

**BSME**: Casts one spell at a time. Player selects each spell individually.

**BuffBot needs**: A casting queue that processes spells sequentially. Queue spells via `EEex_Action_QueueResponseStringOnAIBase` (engine handles pacing — aura cooldown, casting time, Improved Alacrity). For cheat mode, use `EEex_Action_ExecuteResponseStringOnAIBaseInstantly` with `ApplySpell` or `ReallyForceSpellDead` (the only instant-capable actions). Need action completion listener (`EEex_Action_AddSpriteStartedActionListener`) to track queue progress. See [eeex-api-surface.md §4](eeex-api-surface.md).

### 6.4 No Per-Save Configuration

**BSME**: All settings stored in the game's INI file via `Infinity_GetINIValue` / `Infinity_SetINIValue`. Global across saves — appropriate for UI preferences.

**BuffBot needs**: Per-character buff presets that persist in save games. Primary mechanism: `EEex_Sprite_AddMarshalHandlers("BuffBot", exportFn, importFn)` + `EEex_GetUDAux(sprite)["BB_Config"]` for arbitrary Lua table data in saves (requires EEex v0.10.3+). INI file for global preferences (like "default to cheat mode"). See [ui-menu-patterns.md §6](ui-menu-patterns.md).

### 6.5 No Multi-Character Coordination

**BSME**: Works with the currently selected character only (`EEex_GameObject_GetSelected()`).

**BuffBot needs**: Party-wide orchestration. Must iterate all party members (via `EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_group.m_memberList` or equivalent), enumerate each character's spells, apply each character's preset, and coordinate the casting queue across multiple characters. The config panel needs character tabs.

### 6.6 No Active Effect Detection

**BSME**: Does not check whether a buff is already active on a target. Shows all memorized spells regardless.

**BuffBot needs**: "Skip active buffs" requires checking target state before casting. Three approaches in preference order:
1. **Spell states** (fast): `EEex_Sprite_GetSpellState(sprite, splstateID)` for buffs that set SPLSTATE.IDS values via opcode #282
2. **Effect iteration** (fallback): scan active effects for the specific spell resref
3. **Self-replacing detection**: if spell uses opcode 321 self-replacement, re-casting is harmless even without detection

See [spell-system-and-buff-classification.md §7](spell-system-and-buff-classification.md).

### 6.7 No Duration Tracking

**BSME**: Does not read or display spell durations.

**BuffBot needs**: Duration data for ordering (longest-duration-first default), for "short buffs" vs "long buffs" preset classification, and potentially for showing remaining buff time. Read from feature block timing mode (0=limited, 1=permanent) and duration field (seconds). See [spell-system-and-buff-classification.md §6](spell-system-and-buff-classification.md).

---

## Appendix: Complete EEex API Surface Used by BSME

For reference, the full set of EEex APIs that BSME uses, grouped by category. APIs marked with **★** are directly relevant to BuffBot.

### Actionbar
| API | Purpose |
|-----|---------|
| `EEex_Actionbar_AddListener(fn)` | Listen for actionbar state changes |
| `EEex_Actionbar_GetArray()` | Access CInfButtonArray fields |
| `EEex_Actionbar_GetState()` | Get current actionbar state number |
| ★ `EEex_Actionbar_RestoreLastState()` | Revert actionbar after intervention |
| `EEex_Actionbar_IsThievingHotkeyOpeningSpecialAbilities()` | Edge case detection |
| `EEex_Actionbar_ButtonType.*` | Enum constants |
| `EEex_CInfButtonArray.SetQuickSlot(data, n, type)` | Quick slot assignment |

### Sprite / Game Objects
| API | Purpose |
|-----|---------|
| ★ `EEex_GameObject_GetSelected()` | Get currently selected party member |
| ★ `EEex_GameObject_Get(id)` | Get sprite by ID |
| `object:isSprite()` | Type check |
| `object:getClass()` | Get class ID |
| `object:getActiveStats()` | Get derived stats |
| ★ `sprite:GetQuickButtons(type, 0)` | **THE key API**: spell button list (2=spells, 4=innates) |
| `sprite:GetInternalButtonList()` | Opcode #214 internal list |
| ★ `sprite:ReadySpell(buttonData, flag)` | Initiate spell casting |
| `sprite:ReadyOffInternalList(data, flag)` | Cast from internal list |

### Spell State Listeners
| API | Purpose |
|-----|---------|
| ★ `EEex_Sprite_AddQuickListsCheckedListener(fn)` | Spell count changed |
| ★ `EEex_Sprite_AddQuickListCountsResetListener(fn)` | All counts reset (after rest) |
| ★ `EEex_Sprite_AddQuickListNotifyRemovedListener(fn)` | Spell removed from list |
| ★ `EEex_Sprite_AddSpellDisableStateChangedListener(fn)` | Spell disabled/enabled |

### Resources
| API | Purpose |
|-----|---------|
| ★ `EEex_Resource_Demand(resref, "SPL")` | Load spell header data |

### Menu System
| API | Purpose |
|-----|---------|
| ★ `EEex_Menu_AddMainFileLoadedListener(fn)` | Hook after UI.MENU loads |
| `EEex_Menu_AddBeforeMainFileReloadedListener(fn)` | Hook before UI reload |
| ★ `EEex_Menu_LoadFile(name)` | Load custom .menu file |
| ★ `EEex_Menu_Find(menuName)` | Find menu by name |
| `EEex_Menu_GetItemFunction(ref)` | Get event handler from menu item |
| `EEex_Menu_SetItemFunction(ref, fn)` | Replace event handler |
| ★ `EEex_Menu_InjectTemplateInstance(menu, tmpl, id, x, y, w, h)` | Create template instance |
| ★ `EEex_Menu_DestroyAllTemplates(menu)` | Destroy all instances in menu |
| `EEex_Menu_CreateTemplateFromCopy(menu, name, item)` | Clone UI item as template |
| ★ `EEex_Menu_StoreTemplateInstance(menu, tmpl, id, name)` | Name instance for positioning |
| `EEex_Menu_AddBeforeUIItemRenderListener(name, fn)` | Custom render hook |
| ★ `EEex_Menu_AddWindowSizeChangedListener(fn)` | Screen resize |

### Keys
| API | Purpose |
|-----|---------|
| `EEex_Key_AddPressedListener(fn)` | Global key handler |
| `EEex_Key_GetFromName(name)` | Key code from name |

### Game State
| API | Purpose |
|-----|---------|
| ★ `EEex_GameState_AddDestroyedListener(fn)` | Game unload/save load cleanup |
| `EEex_Area_GetVisible()` | Check if area loaded (nil = crash danger) |

### Engine Globals
| API | Purpose |
|-----|---------|
| `EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_group.m_memberList` | Party member list |
| `EngineGlobals.g_pBaldurChitin.m_pEngineWorld:TogglePauseGame(...)` | Pause/unpause |
| `EngineGlobals.capture.item` | Currently focused UI element |

### Engine UI Functions
| API | Purpose |
|-----|---------|
| ★ `Infinity_PushMenu(name)` / `Infinity_PopMenu(name)` | Menu stack |
| ★ `Infinity_IsMenuOnStack(name)` | Check if menu displayed |
| ★ `Infinity_SetArea(name, x, y, w, h)` | Position/resize element |
| `Infinity_GetArea(name)` | Get element position |
| ★ `Infinity_GetScreenSize()` | Screen dimensions |
| `Infinity_FocusTextEdit(name)` | Focus text input |
| `Infinity_TextEditHasFocus()` | Check text input focus |
| ★ `Infinity_FetchString(strref)` | Resolve string reference |
| ★ `Infinity_GetINIValue(section, key, default)` | Read INI setting |
| ★ `Infinity_SetINIValue(section, key, value)` | Write INI setting |
| `Infinity_GetClockTicks()` | Timing |
| `Infinity_GetContentHeight(font, w, text, pt, flags)` | Text measurement |
| `Infinity_DoFile(name)` | Execute Lua file |

### Utility
| API | Purpose |
|-----|---------|
| ★ `EEex_Utility_IterateCPtrList(list, fn)` | Iterate engine linked list |
| `EEex_Utility_FreeCPtrList(list)` | Free engine linked list |
| `EEex_Once(key, fn)` | Execute-once guard |
| `EEex_Utility_NewScope(fn)` | Immediately-invoked scope |
| `EEex_UDToLightUD(ud)` | Userdata conversion |
| `EEex_RunWithStackManager(specs, fn)` | Managed stack allocation |
