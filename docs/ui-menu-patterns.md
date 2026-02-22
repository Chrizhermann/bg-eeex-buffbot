# BG:EE UI System — Menu Patterns & Custom Panel Reference

> Analysis document for BuffBot development. Covers the .menu file format, Lua bindings,
> custom panel creation, and patterns from existing mods. Primary source: Bubb's Spell Menu
> Extended (BSME) v5.1 — by the same author as EEex, and the closest existing example to
> what BuffBot needs to build.
>
> Confidence levels: **[SRC]** = verified from BSME/EEex source code,
> **[DOC]** = official documentation or Beamdog forums,
> **[INF]** = inferred from source patterns, **[UNC]** = uncertain / needs runtime testing.
>
> Key references:
> - BSME source: https://github.com/Bubb13/Bubbs-Spell-Menu-Extended (v5.1)
> - EEex source: https://github.com/Bubb13/EEex
> - Beamdog forums: "The New UI System: How to Use It"
> - EEex docs: https://eeex-docs.readthedocs.io/en/latest/
> - IESDP: https://gibberlings3.github.io/iesdp/
>
> Verified against actual game files from a modded BG2:EE+EET install:
> - `ui.menu` (22,850 lines), `bgee.lua` (7,485 lines), `B3Spell.menu` (372 lines),
>   `M_B3Spel.lua` (2,566 lines), `EEex_Menu.lua` (452 lines), `EEex_Marshal.lua` (42 lines)

---

## 1. The .menu File Format

The Enhanced Edition uses a custom declarative format for UI definitions. Files have the
`.menu` extension and are loaded by the engine's UI parser. The format is C-like with
braces, keywords, and string/number literals. It is **not** Lua — it is a separate DSL
parsed by the engine's C++ code.

### 1.1 Top-Level Structure **[SRC]**

A `.menu` file contains one or more `menu { }` blocks. Each block defines an independent
menu that can be pushed onto and popped from the engine's display stack.

```
menu
{
    name      "BUFFBOT_MAIN"           -- unique string ID
    onopen    "BuffBot_OnOpen()"       -- Lua function called when menu is pushed
    onclose   "BuffBot_OnClose()"      -- Lua function called when menu is popped
    modal lua "BuffBot_IsModal()"      -- if returns true, blocks clicks outside this menu
    ignoreesc                          -- do not close when Escape is pressed

    -- Element definitions go here (label, button, list, etc.)
}
```

**Properties of the `menu` block:**

| Property | Type | Description |
|----------|------|-------------|
| `name` | `"string"` | Unique identifier. Used with `Infinity_PushMenu`/`PopMenu`. |
| `onopen` | `"LuaExpr"` | Called when the menu is pushed onto the display stack. Can be multi-line. |
| `onclose` | `"LuaExpr"` | Called when the menu is popped from the display stack. |
| `modal` | flag | If present, menu is always modal (blocks clicks outside). **[SRC: ui.menu]** |
| `modal lua` | `"LuaExpr"` | If expression returns true, menu is conditionally modal. **[SRC: BSME]** |
| `ignoreesc` | flag | If present, pressing Escape does not close this menu. |
| `align` | `H V` | `left\|center\|right` `top\|center\|bottom`. Anchors menu position. **[SRC: ui.menu]** |

Multiple menus in one file:

```
menu
{
    name "BUFFBOT_MAIN"
    -- ... main panel elements
}

menu
{
    name "BUFFBOT_TARGET_PICKER"
    -- ... target selection sub-panel
}
```

### 1.1b Inline Lua Code Blocks **[SRC: ui.menu]**

The `.menu` format supports inline Lua code blocks between menu definitions using
backtick (`` ` ``) delimiters. This is how `ui.menu` defines helper functions alongside
menu elements:

```
`
function refreshMageBook()
    if currentSpellLevel == nil then
        currentSpellLevel = 1
    end
    if bookMode == 0 then
        bookSpells = characters[id].mageSpells[currentSpellLevel]
        -- ...
    end
end
`

menu
{
    name 'MAGE'
    onopen "refreshMageBook()"
    -- ...
}
```

The engine executes these Lua blocks in order as it parses the `.menu` file. Functions
defined in backtick blocks are available to all subsequent menu elements. `ui.menu`
heavily uses this pattern — approximately 40% of its 22,850 lines are inline Lua code.

**For BuffBot**: Prefer putting Lua code in separate `.lua` files loaded via
`Infinity_DoFile` or `EEex_Menu_LoadFile`. Inline backtick blocks work but are harder to
debug and maintain. BSME uses separate `.lua` files for all logic.
```

### 1.2 Element Types **[SRC]**

Seven element types are confirmed from BSME source. Each element is a block nested inside
a `menu { }` block.

#### `label` — Non-Interactive Display Element

Used for background images, icons, text labels, and tick-driven animations.

```
label
{
    name         "BuffBot_SpellIcon"            -- optional name for Infinity_SetArea
    enabled      "BuffBot_IsVisible()"          -- Lua expression; false hides the element

    -- BAM (animated sprite) display:
    bam          "GUIOSTUR"                     -- static BAM resref
    bam lua      "myBamVariable"                -- or from a Lua global variable
    sequence     0                              -- animation sequence index
    sequence lua "GetSequence()"                -- or from Lua
    frame        1                              -- frame within sequence
    frame lua    "GetFrame()"                   -- or from Lua
    scaleToClip                                 -- stretch BAM to fill the area

    -- Spell/item icon display:
    icon lua       "GetSpellIcon()"             -- resref string for spell icon
    count lua      "GetSpellCount()"            -- integer count shown in corner
    useOverlayTint "ShouldTint()"               -- if true, skip the grey-out tint
    greyscale lua  "IsDisabled()"               -- if true, render in greyscale
    overlayTint 60 60 60                        -- RGB for the disabled tint overlay

    -- Solid rectangle fill:
    rectangle         1                         -- fill style (0-7)
    rectangle opacity 100                       -- 0–1000ish; 100 = light dark overlay

    -- Mosaic (tiled background):
    mosaic "STON10"                             -- tiled mosaic image resref

    -- Transparency / compositing:
    usealpha lua "true"                         -- use alpha channel [SRC: ui.menu]
    fill 112 111 111 64                         -- solid RGBA fill [SRC: ui.menu]
    ignoreEvents                                -- don't consume mouse events [SRC: ui.menu/BSME]

    -- Text display:
    text lua    "GetLabelText()"                -- text content from Lua
    text style  "normal"                        -- references a style in BGEE.lua
    text align  left center                     -- horizontal vertical alignment
    text font   "MODESTOM"                      -- font resource override [SRC: BSME]
    text color  lua "GetColor()"                -- dynamic text color [SRC: BSME]
    text color  B                               -- or static color code (single char) [SRC: ui.menu]
    text shadow 1                               -- enable drop shadow [SRC: ui.menu]
    text shadow lua "isModified(rowNumber)"     -- or dynamic shadow [SRC: ui.menu]
    text point  10                              -- font point size override [SRC: ui.menu]
    text upper                                  -- force uppercase [SRC: ui.menu]
    text useFontZoom 0                          -- disable UI zoom scaling [SRC: BSME]
    align center center                         -- element alignment within parent [SRC: ui.menu]

    -- Position:
    area 10 10 200 30                           -- x y w h in pixels
    area 0 0 -1 -1                              -- -1 = fill available space [SRC: ui.menu]
}
```

#### `button` — Interactive Clickable Element

```
button
{
    name     "BuffBot_CastButton"
    enabled  "BuffBot_CanCast()"                -- visibility + interactivity gate
    clickable lua "BuffBot_IsClickable()"       -- visible but greyed-out when false [SRC: ui.menu]
    action   "BuffBot_OnCast()"                 -- left-click callback
    actionAlt "BuffBot_OnRightClick()"          -- right-click callback
    actionHold "BuffBot_OnHold()"               -- called while button is held down [SRC: ui.menu]
    on escape                                   -- also triggered by Escape key

    -- Visual:
    bam lua   "castButtonBam"                   -- button graphic (Lua variable)
    bam       GUIOSTLL                          -- or static resref (no quotes needed)
    frame lua "GetCastButtonFrame()"
    sequence  0                                 -- static sequence index
    sequence lua "GetCastButtonSeq()"           -- or from Lua
    scaleToClip
    highlightgroup mgpage                       -- mutual-highlight group name [SRC: ui.menu]

    -- Text on the button:
    text      "BUTTON_STRREF"                   -- static string (looked up as strref/token)
    text lua   "castButtonText"                 -- or text from a Lua global
    text style "button"                         -- style reference
    text upper                                  -- force uppercase [SRC: ui.menu]
    pad 0 15 0 15                               -- padding: left top right bottom

    -- Tooltip:
    tooltip lua "GetCastTooltip()"              -- hover text from Lua
    tooltip force lua "shouldForceTooltip()"    -- show tooltip even when not hovered [SRC: ui.menu]
    tooltip force top                           -- force tooltip above the button [SRC: ui.menu]

    -- Icon options (same as label):
    useOverlayTint "ShouldTint()"
    greyscale lua  "IsDisabled()"
    overlayTint 60 60 60

    area 10 50 100 30
}
```

#### `list` — Scrollable Table Widget

The engine's built-in scrollable list. Rows are defined by columns, each containing a
label or button. Data comes from a Lua table.

```
list
{
    name       "BuffBot_SpellList"
    enabled    "BuffBot_IsEnabled()"
    table      "buffbot_spellTable"             -- Lua GLOBAL table variable name (string)
    var        "buffbot_selectedRow"             -- Lua GLOBAL for selected row index
    rowheight  35                                -- pixel height per row (vertical lists)
    rowwidth   36                                -- pixel width per item (horizontal lists) [SRC: ui.menu]
    scrollbar  "GUISCRC"                         -- scrollbar BAM resref
    scrollbar clunkyScroll 35                    -- scroll step size
    hidehighlight                                -- suppress default selection highlight
    sound      ""                                -- click sound ("" = silent) [SRC: ui.menu]

    column
    {
        width 20                                 -- percentage of list width
        label
        {
            area 0 0 32 32
            bam lua "buffbot_spellTable[rowNumber].icon"
            scaleToClip
        }
    }
    column
    {
        width 60
        label
        {
            area 0 0 200 30
            text lua "buffbot_spellTable[rowNumber].name"
            text align left center
        }
    }
    column
    {
        width 20
        button
        {
            area 0 0 30 30
            action "BuffBot_ToggleSpell(rowNumber)"
            bam lua "buffbot_spellTable[rowNumber].checkBam"
            frame lua "buffbot_spellTable[rowNumber].checkFrame"
        }
    }

    area 10 90 400 300

    -- List action with column detection:
    action
    "
        if cellNumber == 1 then                 -- cellNumber = 1-based column index [SRC: ui.menu]
            BuffBot_OnIconClick(rowNumber)
        end
    "
    actionalt                                   -- right-click action [SRC: ui.menu]
    "
        BuffBot_OnSpellRightClick(rowNumber)
    "
}
```

The engine automatically sets these global variables for list expressions: **[SRC: ui.menu]**

| Variable | Description |
|----------|-------------|
| `rowNumber` | Current row index (1-based) — set per-row during rendering and in actions |
| `cellNumber` | Current column index (1-based) — available in `action`/`actionalt` callbacks |

**Horizontal lists**: Use `rowwidth` instead of `rowheight` to create a horizontal strip
of items (e.g., the spell memorization slots at the bottom of the mage book screen). The
engine renders items left-to-right instead of top-to-bottom. **[SRC: ui.menu]**

#### `edit` — Text Input Field

```
edit
{
    name    "BuffBot_PresetName"
    enabled "BuffBot_IsRenaming()"
    var     "buffbot_presetNameInput"            -- Lua global receiving typed text
    action  "return BuffBot_ValidateChar()"      -- return 1 to accept, 0 to reject keystroke
    text style "edit"
    align center bottom
    maxlines 1
    area 0 0 200 24
}
```

#### `slider` — Horizontal Slider

```
slider
{
    name         "BuffBot_PrioritySlider"
    enabled      "BuffBot_IsEnabled()"
    position     "buffbot_sliderPos"             -- Lua global (integer) for current position
    settings lua "BuffBot_GetSliderSteps()"      -- returns integer: number of steps
    action       "BuffBot_OnSliderChange()"      -- called when slider moves
    tooltip lua  "BuffBot_GetSliderTooltip()"
    bam lua      "sliderThumbBam"                -- thumb graphic
    sequence     0
    frame        1
    sliderBackground "SLDRSTAR"                  -- track background BAM
    scaleToClip
    area 10 200 200 20
}
```

#### `handle` — Draggable Element

Used for resize operations. During drag, `motionX` and `motionY` globals are set. **[SRC]**

```
handle
{
    name       "BuffBot_ResizeHandle"
    actionDrag "BuffBot_OnResize()"              -- called during drag
    area 390 290 20 20
}
```

#### `text` — Scrollable Text / Click Region

The `text` element serves two very different roles: **[SRC: ui.menu]**

**Role 1: Scrollable text display** (with content and scrollbar):

```
text
{
    name       "BuffBot_Description"
    area       448 412 322 156
    text lua   "GetSpellDescription()"          -- long text content
    text style "normal_parchment"
    scrollbar  'GUISCRC'                        -- makes the text scrollable
}
```

**Role 2: Full-screen click-to-dismiss backdrop** (the more common pattern):

```
text
{
    name    "BuffBot_Backdrop"
    enabled "BuffBot_IsOpen()"
    action  "BuffBot_Close()"                   -- click to dismiss
    on escape                                   -- or press Escape

    rectangle 1
    rectangle opacity 100                       -- dark overlay

    area 0 0 99999 99999                        -- covers entire screen
}
```

#### `template` — Reusable Instance Prototype

Templates are not rendered directly. They define a prototype element that can be
instantiated multiple times at runtime via `Infinity_InstanceAnimation`. See §6 for the
full pattern.

```
template
{
    button
    {
        enabled     "MyTemplate_Tick()"
        tooltip lua "MyTemplate_Tooltip()"
        action      "MyTemplate_Click()"
    }
    name "MY_TEMPLATE_NAME"
}
```

### 1.3 The `lua` Keyword **[SRC]**

Any property that accepts a value can use the `lua` keyword to evaluate a Lua expression
at render time:

```
bam lua      "myGlobalVar"              -- reads Lua global variable
text lua     "GetText()"                -- calls a Lua function
frame lua    "myTable[idx].frame"       -- table access
enabled      "CheckEnabled()"           -- 'enabled' implicitly uses Lua (no 'lua' keyword)
enabled      true                       -- or a literal boolean
```

The `lua` keyword means "evaluate this string as a Lua expression each frame." Without
`lua`, the value is a static literal. The `enabled` and `action` properties are
exceptions — they always evaluate as Lua even without the `lua` keyword. **[INF]**

**Quoting is optional for some properties.** Verified from ui.menu: `bam GUIOSTLL` (no
quotes) and `bam "GUIOSTLL"` both work. Similarly, `var currentBookSpell` (bare global
name) and `var "currentBookSpell"` (quoted) are equivalent. BAM resrefs, `highlightgroup`
names, and `var` targets commonly appear unquoted in `ui.menu`. **[SRC: ui.menu]**

### 1.4 Property Reference Table

Verified from `ui.menu` (22,850 lines) and `B3Spell.menu` (372 lines).

| Property | Elements | Source | Description |
|----------|----------|--------|-------------|
| `name` | all | ui.menu | String ID for `Infinity_SetArea` / `EEex_Menu_Find` lookups |
| `enabled` | all | ui.menu | Lua expression, `true`, or `false`; false = hidden and non-interactive |
| `area` | all | ui.menu | `x y w h` in pixels; `-1` = fill available; can be partial (set rest at runtime) |
| `align` | label, edit | ui.menu | `center center` etc. — element alignment within parent |
| **Actions** | | | |
| `action` | button, text, edit, slider, list | ui.menu | Left-click Lua callback. In `edit`: `return` value controls input acceptance. In `list`: `cellNumber`/`rowNumber` available. |
| `actionAlt` / `actionalt` | button, list | ui.menu, BSME | Right-click callback (case-insensitive) |
| `actionHold` | button | ui.menu | Called repeatedly while button is held down |
| `actionDrag` | handle | BSME | Called during drag; `motionX`/`motionY` globals set |
| `on escape` | button, text | ui.menu | Also fires this element's action on Escape key |
| **BAM Graphics** | | | |
| `bam` / `bam lua` | label, button, slider | ui.menu | BAM resref — static (`bam GUIOSTLL`), variable (`bam lua "var"`), or function (`bam lua "fn()"`) |
| `sequence` / `sequence lua` | label, button, slider | ui.menu | BAM animation sequence index |
| `frame` / `frame lua` | label, button, slider | ui.menu | BAM frame within sequence |
| `scaleToClip` | label, button, slider | ui.menu | Stretch graphic to fill element area |
| **Icon Display** | | | |
| `icon lua` | label | BSME | Spell/item icon resref from Lua function |
| `count lua` | label | BSME | Integer count overlay (memorization count, spell uses) |
| `greyscale lua` | label, button | ui.menu | If true, render in greyscale |
| `useOverlayTint` | label, button | BSME | If true, apply the `overlayTint` color |
| `overlayTint` | label, button | BSME | `R G B` integers for disabled/tint overlay |
| `usealpha lua` | label | ui.menu | Use alpha channel for transparency |
| **Visual Fills** | | | |
| `rectangle` | label, text | ui.menu | Filled rectangle; integer selects color/style (0–7) |
| `rectangle opacity` | label, text | ui.menu | Overlay opacity (100 = light dim, 200 = dark) |
| `fill` | label | ui.menu | `R G B A` solid fill (0–255 each) |
| `mosaic` | label, slider | ui.menu | Tiled mosaic background resref |
| **Text Properties** | | | |
| `text` / `text lua` | label, button | ui.menu | Display text — static strref token or Lua variable/function |
| `text style` | label, button, edit | ui.menu | Style name: `"normal"`, `"button"`, `"edit"`, `"title"`, `"label"`, `"normal_parchment"` |
| `text align` | label, text | ui.menu | `left\|center\|right` `top\|center\|bottom` |
| `text font` | label | BSME | Font resource name override (e.g., `"MODESTOM"`) |
| `text color` / `text color lua` | label | ui.menu | Static color code (`B`, `C`, `D`, `3`, `'$'`, `'5'`) or Lua function |
| `text shadow` / `text shadow lua` | label | ui.menu | `1` = enable drop shadow; or Lua function for dynamic shadow |
| `text point` | label | ui.menu | Font point size override (e.g., `10`, `12`, `14`) |
| `text upper` | label, button | ui.menu | Force text to uppercase |
| `text useFontZoom` | label | BSME | `0` = disable UI zoom scaling on text |
| `pad` | button | BSME | `left top right bottom` text padding |
| **Tooltips** | | | |
| `tooltip lua` | button, slider | ui.menu | Hover tooltip text from Lua variable or function |
| `tooltip force lua` | button | ui.menu | If true, show tooltip even without hover |
| `tooltip force top` | button | ui.menu | Force tooltip to appear above element |
| **Interactivity** | | | |
| `clickable lua` | button | ui.menu | If false, button is visible but non-interactive (greyed out). Unlike `enabled` which hides the element entirely. |
| `highlightgroup` | button | ui.menu | Mutual-highlight group name — only one button in the group appears "active" |
| `ignoreEvents` | label | ui.menu | Element does not consume mouse events (click-through) |
| **List Properties** | | | |
| `var` | list, edit | ui.menu | Lua global variable name for selected row / input text |
| `table` | list | ui.menu | Lua global table variable name for row data |
| `rowheight` | list | ui.menu | Pixel height per row (vertical list) |
| `rowwidth` | list | ui.menu | Pixel width per item (horizontal list) |
| `scrollbar` | list, text | ui.menu | Scrollbar BAM resref |
| `scrollbar clunkyScroll` | list | BSME | Scroll step size in pixels |
| `hidehighlight` | list | BSME | Suppress default row selection highlight |
| `sound` | list | ui.menu | Click sound effect (`""` = silent) |
| `column` | list | ui.menu | Column definition block (contains `width` + element) |
| `width` | column | ui.menu | Percentage of list width (integer, 0–100) |
| **Slider Properties** | | | |
| `position` | slider | BSME | Lua global variable name for slider position |
| `settings lua` | slider | BSME | Returns number of slider steps |
| `sliderBackground` | slider | BSME | Track background BAM resref |
| **Edit Properties** | | | |
| `maxlines` | edit | BSME | Maximum line count |
| **Menu-Level** | | | |
| `modal` | menu | ui.menu | Flag — menu is always modal |
| `modal lua` | menu | BSME | Lua expression — conditionally modal |
| `ignoreesc` | menu | BSME | Flag — Escape key does not close menu |
| `onopen` | menu | ui.menu | Lua callback when menu opens (can be multi-line) |
| `onclose` | menu | ui.menu | Lua callback when menu closes |
| `align` | menu | ui.menu | `left\|center\|right` `top\|center\|bottom` menu positioning |

---

## 2. Lua ↔ .menu Binding

### 2.1 Data Flow: Lua → Menu **[SRC]**

The `.menu` file reads Lua state via the `lua` keyword. The engine re-evaluates these
expressions **every frame** (or every render pass). This means you communicate data to the
UI by setting Lua global variables:

```lua
-- In your Lua file:
buffbot_panelTitle = "BuffBot — Long Buffs"
buffbot_spellTable = {}   -- will be populated dynamically

function BuffBot_IsVisible()
    return buffbot_isOpen
end
```

```
-- In your .menu file:
label
{
    text lua "buffbot_panelTitle"
    enabled  "BuffBot_IsVisible()"
    area 10 10 300 30
}
```

**Key insight**: there is no explicit "bind" or "subscribe" call. The engine polls Lua
globals and function returns on each render frame. This is simple but means expensive
computations should be cached in variables rather than computed in every `lua` expression.

### 2.2 Data Flow: Menu → Lua (Callbacks) **[SRC]**

User interactions trigger Lua functions specified in `action`, `actionAlt`, and
`actionDrag` properties:

```lua
-- In Lua:
function BuffBot_OnCastAll()
    -- user clicked the "Cast All" button
    BuffBot_StartCasting()
end

function BuffBot_OnSpellToggle()
    -- rowNumber is set automatically by the list widget
    local spell = buffbot_spellTable[rowNumber]
    spell.enabled = not spell.enabled
end
```

```
-- In .menu:
button { action "BuffBot_OnCastAll()"   area 10 50 100 30 }

list
{
    table "buffbot_spellTable"
    column
    {
        button { action "BuffBot_OnSpellToggle()" }
    }
}
```

### 2.3 Auto-Set Global Variables **[SRC: ui.menu, BSME]**

The engine automatically sets certain Lua globals before evaluating expressions in
specific contexts:

| Variable | Set By | Type | Description |
|----------|--------|------|-------------|
| `rowNumber` | `list` | integer (1-based) | Current row being rendered/clicked |
| `cellNumber` | `list` action | integer (1-based) | Column index in list `action`/`actionalt` callbacks |
| `instanceId` | `template` | integer | ID of the template instance being rendered/clicked |
| `currentAnimationID` | convention | integer | Set by mod code before `Infinity_InstanceAnimation` to assign a specific ID to new instances (global, not engine-set — but a critical BSME convention) |
| `motionX` | `handle` | number | Horizontal drag delta during `actionDrag` |
| `motionY` | `handle` | number | Vertical drag delta during `actionDrag` |

### 2.4 The `enabled` and `clickable lua` Properties **[SRC: ui.menu, BSME]**

Two distinct properties control interactivity:

- **`enabled`** — controls both **visibility** and interactivity. When false, the element
  is not rendered at all and cannot receive clicks.
- **`clickable lua`** — controls only **interactivity** while keeping the element visible.
  When false, the button appears greyed out but is still drawn. **[SRC: ui.menu]**

This distinction matters for BuffBot: use `enabled` to show/hide entire panels (tab
switching), but use `clickable lua` for buttons that should appear disabled (e.g., "Cast
Now" when no spells are selected).

`enabled` controls visibility and interactivity. When the Lua expression returns
false/nil/0, the element is not rendered and cannot receive clicks:

```lua
buffbot_isOpen = false

function BuffBot_Open()
    buffbot_isOpen = true
end

function BuffBot_Close()
    buffbot_isOpen = false
end
```

```
-- The entire panel's content is gated by this:
label { enabled "buffbot_isOpen"  text lua "buffbot_panelTitle"  area 10 10 300 30 }
button { enabled "buffbot_isOpen"  action "BuffBot_Close()"  area 310 10 20 20 }
```

This is the primary mechanism for showing/hiding UI sections — no need to push/pop menus
for internal tab switching. Just toggle a Lua boolean and all gated elements appear or
disappear.

---

## 3. Creating a Custom Panel — Step by Step

### 3.1 Files Needed **[SRC]**

Based on BSME's architecture, a custom panel requires:

| File | Purpose |
|------|---------|
| `BuffBot.menu` | Menu layout definitions (the `.menu` DSL) |
| `M_BuffBot.lua` | Core logic: data structures, callbacks, instance management |
| `BuffBot_Init.lua` | Initialization: menu loading, hook registration, event listeners |
| `setup-buffbot.tp2` | WeiDU installer: copies files to `override/` |

### 3.2 The Initialization Chain **[SRC]**

The menu system loads in a specific order. BuffBot hooks into this chain:

```
Game Launch
  └─ Engine loads UI.menu (the master menu file)
  └─ EEex patches are applied
  └─ EEex fires: EEex_Menu_AddMainFileLoadedListener callbacks
       └─ BuffBot_Init.lua registers here
       └─ EEex_Menu_LoadFile("BuffBot")    -- loads BuffBot.menu into the engine
       └─ BuffBot hooks actionbar / registers key listener
       └─ BuffBot panel is now available via Infinity_PushMenu("BUFFBOT_MAIN")
```

### 3.3 Initialization Code Pattern **[SRC]**

```lua
-- BuffBot_Init.lua

-- This runs after all standard menu files are loaded
EEex_Menu_AddMainFileLoadedListener(function()

    -- 1. Load our menu file (makes BUFFBOT_MAIN available)
    EEex_Menu_LoadFile("BuffBot")

    -- 2. Load our main logic file
    Infinity_DoFile("M_BuffBot")

    -- 3. Hook a keyboard shortcut to open the panel
    EEex_Key_AddPressedListener(function(key)
        if key == EEex_Key_GetFromName("F11") then
            if Infinity_IsMenuOnStack("BUFFBOT_MAIN") then
                Infinity_PopMenu("BUFFBOT_MAIN")
            else
                Infinity_PushMenu("BUFFBOT_MAIN")
            end
        end
    end)

    -- 4. Re-inject after resolution changes
    EEex_Menu_AddWindowSizeChangedListener(function(w, h)
        BuffBot_OnResolutionChange(w, h)
    end)
end)
```

### 3.4 Menu Push/Pop Lifecycle **[DOC]** **[SRC]**

```lua
-- Open the panel (pushes onto the display stack):
Infinity_PushMenu("BUFFBOT_MAIN")
-- → triggers the menu's onopen handler
-- → all elements with enabled=true become visible

-- Close the panel:
Infinity_PopMenu("BUFFBOT_MAIN")
-- → triggers the menu's onclose handler
-- → all elements are removed from display

-- Check if open:
if Infinity_IsMenuOnStack("BUFFBOT_MAIN") then
    -- panel is currently visible
end
```

Multiple menus can be on the stack simultaneously. They layer on top of each other. The
topmost menu receives input first.

### 3.5 WeiDU Installation **[SRC]**

```
// setup-buffbot.tp2

BACKUP ~buffbot/backup~
AUTHOR ~...~

BEGIN @0
REQUIRE_PREDICATE (MOD_IS_INSTALLED ~EEex.tp2~ ~0~) @1  // require EEex

// Copy Lua files to override
COPY ~buffbot/lua/BuffBot_Init.lua~ ~override/BuffBot_Init.lua~
COPY ~buffbot/lua/M_BuffBot.lua~    ~override/M_BuffBot.lua~

// Copy menu file with variable substitution
COPY ~buffbot/menu/BuffBot.menu~    ~override/BuffBot.menu~ EVALUATE_BUFFER

// Copy BAM graphics
COPY ~buffbot/bam~                  ~override~

// Register our init Lua file so EEex loads it
// Method: append to EEex's startup listener list
// (Exact mechanism depends on EEex version — may need APPEND to a 2DA or Lua file)
```

**Note**: The exact mechanism for getting `BuffBot_Init.lua` loaded at startup is
**[UNC]**. BSME uses `B3SpelEx.lua` which is loaded via EEex's module system. BuffBot may
need to register as an EEex module or use `Infinity_DoFile` from a patched startup script.
This requires EEex version-specific testing.

### 3.6 BSME's Approach (Canonical Example) **[SRC]**

BSME's files map to this pattern:

| BSME File | Role | BuffBot Equivalent |
|-----------|------|--------------------|
| `B3Spell.menu` | Menu layout | `BuffBot.menu` |
| `M_B3Spel.lua` | Core logic (2565 lines) | `M_BuffBot.lua` |
| `B3SpelEx.lua` | Init + EEex hooks | `BuffBot_Init.lua` |
| `B3SplWei.lua` | WeiDU-generated constants | (optional) |

BSME's init flow:

```lua
-- B3SpelEx.lua (loaded as an EEex component)
function B3Spell_InstallActionbarEnabledHook()
    EEex_Menu_LoadFile("B3Spell")   -- loads B3Spell.menu

    local menu = EEex_Menu_Find("WORLD_ACTIONBAR")

    -- Hook the actionbar's open/close events:
    local hookEvent = function(eventRef, listener)
        local oldFunc = EEex_Menu_GetItemFunction(eventRef) or function() end
        EEex_Menu_SetItemFunction(eventRef, function()
            oldFunc()
            listener()
        end)
    end
    hookEvent(menu.reference_onOpen, B3Spell_OnActionbarOpened)
    hookEvent(menu.reference_onClose, B3Spell_OnActionbarClosed)

    -- Disable actionbar buttons when spell menu is open:
    local item = menu.items
    while item do
        if item.button and item.button.actionBar then
            local enabledRef = item.reference_enabled
            local oldEnable = EEex_Menu_GetItemFunction(enabledRef)
                              or function() return true end
            EEex_Menu_SetItemFunction(enabledRef, function()
                return not B3Spell_ActionbarDisable and oldEnable()
            end)
        end
        item = item.next
    end
end

EEex_Menu_AddMainFileLoadedListener(B3Spell_InstallActionbarEnabledHook)
```

---

## 4. Contingency / Sequencer Menu Pattern

Verified from the actual MAGE menu in `ui.menu` lines 7843–8562.

### 4.1 Architecture: How It Works **[SRC: ui.menu]**

The contingency/sequencer spell selection is **not** a separate menu. It reuses the MAGE
spellbook menu (`name 'MAGE'`) with a mode switch:

```lua
-- Two modes controlled by the global variable bookMode:
bookMode = 0  -- Regular spellbook (memorize/unmemorize)
bookMode = 1  -- Sequencer/Contingency mode (pick spells for sequencer)
```

The menu switches behavior everywhere based on `bookMode`:
- `modal lua "bookMode == 1"` — menu becomes modal in sequencer mode
- Spell lists are populated differently
- Different buttons are shown/hidden via `enabled` checks
- The "Done" button calls `mageScreen:DoneSequencingSpells()` instead of the normal close

### 4.2 How the Menu Is Triggered **[SRC: ui.menu]**

A "Contingency" button in the regular mage book screen opens the contingency viewer:

```
-- In the MAGE menu:
button
{
    area 588 584 236 52
    enabled "bookMode == 0 and (#characters[id].contingencySpells > 0
             or #characters[id].sequencerSpells > 0)"
    bam GUIOSTLR
    text "CONTINGENCY_BUTTON"
    text style "button"
    action "Infinity_PushMenu('MAGE_CONTINGENCY')"
}
```

The actual sequencer spell-picking happens when `bookMode` is set to `1` before the MAGE
menu opens. The engine sets this mode via the actionbar config 28/state 111 mechanism when
a Contingency/Sequencer spell is cast.

### 4.3 Spell Filtering — The Key Pattern **[SRC: ui.menu]**

This is the most relevant code for BuffBot. The `filterContingencyMageSpells()` function
demonstrates how to filter spells from the character's spell lists:

```lua
function filterContingencyMageSpells()
    local out = {}
    -- Filter mage (arcane) spells:
    if characters[id].mageSpells ~= nil
       and characters[id].mageSpells[currentSpellLevel] ~= nil then
        for k,v in pairs(characters[id].mageSpells[currentSpellLevel]) do
            if v.castableCount > 0
               and mageScreen:SpellAllowedForContingency(v.level, v.resref) then
                tableInsert(out, v)
            end
        end
    end
    -- Filter priest (divine) spells:
    if characters[id].priestSpells ~= nil
       and characters[id].priestSpells[currentSpellLevel] ~= nil then
        for k,v in pairs(characters[id].priestSpells[currentSpellLevel]) do
            if v.castableCount > 0
               and mageScreen:SpellAllowedForContingency(v.level, v.resref) then
                tableInsert(out, v)
            end
        end
    end
    return out
end
```

Key data: `characters[id].mageSpells[level]` and `characters[id].priestSpells[level]` are
engine-provided tables. Each entry has: `.resref`, `.castableCount`, `.level`, `.icon`,
`.name` (strref), `.description` (strref), `.index`, `.memorizedCount`, `.masterResref`.

### 4.4 Spell Selection into Sequencer Slots **[SRC: ui.menu]**

When the player clicks a spell in sequencer mode:

```lua
-- In the book spell list's action handler:
if bookMode == 1 and #bottomSpells < #bottomSpellsPlaceHolder then
    mageScreen:SequenceSpell(
        bookSpells[currentBookSpell].resref,
        bookSpells[currentBookSpell].masterResref
    )
end
```

To remove a spell from the sequencer:

```lua
if bookMode == 1 then
    mageScreen:UnSequenceSpell(
        bottomSpells[currentBottomSpell].resref,
        bottomSpells[currentBottomSpell].masterResref
    )
    table.remove(sequencerSpells, currentBottomSpell)
    bottomSpells = sequencerSpells
end
```

Completion check and confirmation:

```lua
function contingencyComplete()
    if showContingency then
        -- Contingency: all slots filled AND condition AND target selected
        return #bottomSpells == #bottomSpellsPlaceHolder
               and (currentContingencyCondition or 0) > 0
               and (currentContingencyTarget or 0) > 0
    else
        -- Sequencer: just all slots filled
        return #bottomSpells == #bottomSpellsPlaceHolder
    end
end

-- Done button action:
if contingencyComplete() then
    mageScreen:DoneSequencingSpells()
else
    mageScreen:CancelSequencingSpells()
end
e:SelectEngine(worldScreen)
```

### 4.5 Contingency-Specific UI: Conditions and Targets **[SRC: ui.menu]**

When `showContingency` is true, additional lists appear for selecting the trigger condition
and target. These use the standard `list` widget pattern:

```
list
{
    area 152 210 262 186
    enabled     "showContingency"
    rowheight   40
    table       "contingencyConditions"          -- engine-provided table
    var         currentContingencyCondition       -- note: no quotes (bare global)
    scrollbar   'GUISCRC'
    action
    "
        contingencyDescription = contingencyConditions[currentContingencyCondition].desc
    "
}

list
{
    area 458 210 240 186
    enabled     "showContingency"
    rowheight   40
    table       "contingencyTargets"             -- engine-provided table
    var         currentContingencyTarget
    scrollbar   'GUISCRC'
    action
    "
        contingencyDescription = contingencyTargets[currentContingencyTarget].desc
    "
}
```

### 4.6 Horizontal Spell Slot Strip **[SRC: ui.menu]**

The bottom of the mage screen shows selected sequencer spells as a horizontal strip using
`rowwidth` instead of `rowheight`:

```
-- Empty slot frames (background placeholders):
list
{
    column { width 100  label { area 0 0 -1 -1  bam "SPELFRMS"  sequence 0  align center center } }
    area 70 654 718 36
    enabled "#bottomSpellsPlaceHolder ~= 0 or bookMode == 1"
    rowwidth 36                                  -- HORIZONTAL list: 36px per item
    table "bottomSpellsPlaceHolder"
}
-- Filled spell icons on top:
list
{
    column { width 100  label { area 0 0 -1 -1  bam lua "bottomSpells[rowNumber].icon"
                                                  align center center
                                                  greyscale lua "bottomSpells[rowNumber].castable == 0" } }
    area 70 654 718 36
    name "memorizedListMage"
    enabled "#bottomSpells ~= 0"
    rowwidth 36
    table "bottomSpells"
    var currentBottomSpell
}
```

### 4.7 BSME's Interception of This System **[SRC: BSME]**

BSME intercepts the actionbar state change to replace the stock spell selection:

```lua
function B3Spell_ActionbarListener(config, state)
    local castConfigs = {
        [21] = true,   -- Cast Spell (regular)
        [23] = true,   -- Special Abilities
        [28] = true,   -- Opcode #214 Internal List (sequencer/contingency)
        [30] = true,   -- Cleric/Mage Spells
    }
    if not castConfigs[config] then return end

    local mode
    if config == 28 then
        mode = B3Spell_Modes.Opcode214
    else
        mode = B3Spell_Modes.Normal
    end

    EEex_Actionbar_RestoreLastState()   -- prevent stock panel
    B3Spell_LaunchSpellMenu(mode, spriteID)
end
EEex_Actionbar_AddListener(B3Spell_ActionbarListener)
```

### 4.8 What BuffBot Can Reuse **[INF]**

| Pattern | Source | BuffBot Application |
|---------|--------|---------------------|
| `characters[id].mageSpells[level]` / `priestSpells` | ui.menu | Alternative spell enumeration to `GetQuickButtons` (but only available when mage screen is open) |
| `mageScreen:SpellAllowedForContingency()` | ui.menu | Model for our `BuffBot_IsBuffSpell()` filter |
| `bookMode` flag for dual-purpose menus | ui.menu | BuffBot preset tabs work the same way — one panel, multiple modes |
| `rowwidth` horizontal list | ui.menu | Could use for horizontal preset tab bar or spell slot preview |
| `contingencyComplete()` pattern | ui.menu | Model for "ready to cast" validation |
| `cellNumber` in list actions | ui.menu | Column-specific click handling in our spell list |
| `mageBookStrings` requirement | ui.menu | Not needed for BuffBot but important to know if we create custom spells |

### 4.9 mageBookStrings Caveat **[SRC: ui.menu]**

For custom contingency/sequencer spells: the engine requires `mageBookStrings` entries in
`bgee.lua` for each spell resref. Without them, accessing `mageBookStrings[resref].tip`
crashes. The entries need `.tip`, `.title`, and `.action` fields:

```lua
mageBookStrings["MYSEQ"] = {
    tip = 12345,      -- strref for description
    title = "TITLE",  -- translation token
    action = "ACTION" -- translation token
}
```

---

## 5. Bubb's Spell Menu Extended — Architecture & Patterns

### 5.1 File Architecture **[SRC]**

| File | Size | Role |
|------|------|------|
| `B3Spell.menu` | ~300 lines | All menu/template definitions. Uses `%Variables%` for install-time customization via WeiDU `EVALUATE_BUFFER`. |
| `M_B3Spel.lua` | ~2565 lines | Core logic: spell data structures, grid layout, instance management, casting. |
| `B3SpelEx.lua` | ~200 lines | EEex hook registration: actionbar listener, menu load, event wiring. |
| `B3SplWei.lua` | generated | WeiDU-generated constants (BAM names, sizes, game variant flags). |

### 5.2 Template-Based Dynamic Grid **[SRC]**

BSME does NOT use the `list` widget for spells. Instead, it uses templates to create a
dynamic grid of spell slots — each spell is three template instances layered on top of each
other:

```
┌─────────────────┐
│  TEMPLATE_Bam   │  ← slot background image
│  ┌───────────┐  │
│  │TEMPLATE_  │  │  ← spell icon with count/greyscale
│  │  Icon     │  │
│  └───────────┘  │
│  TEMPLATE_Action│  ← invisible click target (tooltip, click, right-click)
└─────────────────┘
```

The three templates from the .menu file:

```
template
{
    label
    {
        bam lua   "B3Spell_Menu_TEMPLATE_Bam_Bam()"
        frame lua "B3Spell_Menu_TEMPLATE_Bam_Frame()"
        scaleToClip
    }
    name "B3Spell_Menu_TEMPLATE_Bam"
}

template
{
    label
    {
        icon lua       "B3Spell_Menu_TEMPLATE_Icon_Icon()"
        count lua      "B3Spell_Menu_TEMPLATE_Icon_Count()"
        useOverlayTint "B3Spell_Menu_TEMPLATE_Icon_DisableTint()"
        greyscale lua  "B3Spell_Menu_TEMPLATE_Icon_DisableTint()"
        overlayTint 60 60 60
    }
    name "B3Spell_Menu_TEMPLATE_Icon"
}

template
{
    button
    {
        enabled     "B3Spell_Menu_TEMPLATE_Action_Tick()"
        tooltip lua "B3Spell_Menu_TEMPLATE_Action_Tooltip()"
        action      "B3Spell_Menu_TEMPLATE_Action_Action()"
        actionAlt   "B3Spell_Menu_TEMPLATE_Action_ActionAlt()"
    }
    name "B3Spell_Menu_TEMPLATE_Action"
}
```

### 5.3 Instance Lifecycle **[SRC]**

**Creation:**

```lua
function B3Spell_CreateInstance(menuName, templateName, x, y, w, h)
    local entry = B3Spell_InstanceIDs[menuName][templateName]
    local newID = entry.maxID + 1
    entry.maxID = newID
    local instanceEntry = { ["id"] = newID }
    entry.instanceData[newID] = instanceEntry

    -- Set the ID before engine creates the instance:
    local oldID = currentAnimationID
    currentAnimationID = newID
    Infinity_InstanceAnimation(templateName, nil, x, y, w, h, nil, nil)
    currentAnimationID = oldID

    return instanceEntry
end
```

**Data binding via instanceId:**

```lua
-- Each template callback uses instanceId (auto-set by engine) to find its data:
function B3Spell_Menu_TEMPLATE_Icon_Icon()
    return B3Spell_InstanceIDs["B3Spell_Menu"]["B3Spell_Menu_TEMPLATE_Icon"]
               .instanceData[instanceId].icon
end

function B3Spell_Menu_TEMPLATE_Action_Action()
    local data = B3Spell_InstanceIDs["B3Spell_Menu"]["B3Spell_Menu_TEMPLATE_Action"]
                     .instanceData[instanceId]
    if data.spellData.spellDisabled then return end
    B3Spell_CastSpellData(data.spellData)
end
```

**Positioning (using EEex helper):**

```lua
-- Templates don't have names, so to use Infinity_SetArea we need a temporary alias:
EEex_Menu_StoreTemplateInstance(
    "B3Spell_Menu",                      -- menu name
    "B3Spell_Menu_TEMPLATE_Icon",        -- template name
    iconInstanceData.id,                 -- instance ID
    "B3Spell_StoredInstance"             -- temporary name alias
)
Infinity_SetArea("B3Spell_StoredInstance", newX, newY, newW, newH)
```

**Destruction (full cleanup on refresh):**

```lua
function B3Spell_DestroyInstances(menuName)
    for templateName, entry in pairs(B3Spell_InstanceIDs[menuName] or {}) do
        for i = 1, entry.maxID do
            Infinity_DestroyAnimation(templateName, i)
        end
        entry.maxID = 0
        entry.instanceData = {}
    end
end
```

### 5.4 Spell Data Enumeration **[SRC]**

BSME reads spells from the sprite's quick button arrays:

```lua
function B3Spell_FillFromMemorized()
    B3Spell_SpellListInfo = {}

    local sprite = EEex_GameObject_GetSelected()

    -- Iterate the sprite's quick button data:
    EEex_Utility_IterateCPtrList(quickButtons, function(buttonData)
        local resref = buttonData.m_abilityId.m_res:get()
        local header = EEex_Resource_Demand(resref, "SPL")
        local level  = header.spellLevel  -- 1-9

        local spellData = {
            spellCastableCount = buttonData.m_count,
            spellDescription   = header.genericDescription,
            spellDisabled      = buttonData.m_bDisabled == 1,
            spellIcon          = buttonData.m_icon:get(),
            spellLevel         = level,
            spellName          = Infinity_FetchString(buttonData.m_name),
            spellResref        = resref,
            spellType          = header.itemType,
            -- itemType: 0=Special, 1=Wizard, 2=Priest, 3=Psionic, 4=Innate, 5=Bard Song
        }
        table.insert(levelBucket, spellData)
    end)
end
```

### 5.5 Event-Driven Refresh **[SRC]**

BSME subscribes to engine events to keep the display current:

```lua
-- Spell count changed (one was cast):
EEex_Sprite_AddQuickListsCheckedListener(B3Spell_OnSpellCountChanged)

-- All counts reset (after rest):
EEex_Sprite_AddQuickListCountsResetListener(B3Spell_OnSpellCountsReset)

-- Spell removed from list entirely:
EEex_Sprite_AddQuickListNotifyRemovedListener(B3Spell_OnSpellRemoved)

-- Spell disabled/enabled (e.g., Silence effect):
EEex_Sprite_AddSpellDisableStateChangedListener(B3Spell_OnSpellDisableStateChanged)
```

Each handler triggers a refresh: destroy all instances → re-read spell data → re-create
instances.

### 5.6 Casting **[SRC]**

When the player clicks a spell slot:

```lua
function B3Spell_CastSpellData(spellData)
    -- Close the menu (unless "always open" mode):
    if B3Spell_AlwaysOpen == 0 then
        Infinity_PopMenu("B3Spell_Menu")
    end

    -- Queue the spell for casting via the engine:
    local sprite = EEex_GameObject_Get(B3Spell_SpriteID)
    sprite:ReadySpell(spellData.m_CButtonData, 0)
end
```

`sprite:ReadySpell(buttonData, 0)` is the engine call that queues a spell for casting,
equivalent to the player clicking a spell in the stock UI.

---

## 6. Dynamic List Population

### 6.1 Two Approaches **[SRC]**

The BG:EE UI system offers two ways to display dynamic data:

| Approach | Best For | Complexity |
|----------|----------|------------|
| `list` widget | Scrollable text/icon lists with row selection | Low |
| `template` instances | Custom grid layouts, per-slot interactions | High |

**Recommendation for BuffBot**: Use the `list` widget for the spell configuration list.
It's simpler than BSME's template grid and better suited to BuffBot's needs (a scrollable
list of spells with checkboxes and dropdowns, not a compact icon grid).

### 6.2 List Widget Pattern **[SRC]**

**Step 1 — Define the Lua data table:**

```lua
-- Global table that the list widget reads from.
-- Each entry is a row. The table is 1-indexed.
buffbot_spellTable = {}

function BuffBot_PopulateSpellList(sprite)
    buffbot_spellTable = {}  -- clear

    -- Read all memorized spells:
    local quickButtons = sprite:GetQuickButtons(2, 0)  -- memorized
    EEex_Utility_IterateCPtrList(quickButtons, function(buttonData)
        local resref = buttonData.m_abilityId.m_res:get()

        -- Check if this is a buff (using our classification from spell-system doc):
        if BuffBot_IsBuffSpell(resref) then
            table.insert(buffbot_spellTable, {
                resref  = resref,
                name    = Infinity_FetchString(buttonData.m_name),
                icon    = buttonData.m_icon:get(),
                count   = buttonData.m_count,
                enabled = BuffBot_GetSpellEnabled(sprite, resref),  -- from config
                target  = BuffBot_GetSpellTarget(sprite, resref),   -- from config
            })
        end
    end)

    -- Also read innate abilities:
    local innates = sprite:GetQuickButtons(4, 0)
    EEex_Utility_IterateCPtrList(innates, function(buttonData)
        -- same pattern...
    end)
end
```

**Step 2 — Define the list in .menu:**

```
list
{
    name       "BuffBot_SpellList"
    enabled    "buffbot_isOpen"
    table      "buffbot_spellTable"
    var        "buffbot_selectedSpellRow"
    rowheight  40
    scrollbar  "GUISCRC"

    -- Column 1: Spell icon
    column
    {
        width 10
        label
        {
            area 4 4 32 32
            icon lua "buffbot_spellTable[rowNumber].icon"
            count lua "buffbot_spellTable[rowNumber].count"
        }
    }

    -- Column 2: Spell name
    column
    {
        width 45
        label
        {
            area 0 0 200 40
            text lua "buffbot_spellTable[rowNumber].name"
            text align left center
            text style "normal"
        }
    }

    -- Column 3: Enable/disable checkbox
    column
    {
        width 10
        button
        {
            area 4 4 32 32
            bam "GUICHECK"
            frame lua "BuffBot_GetCheckFrame(rowNumber)"
            action "BuffBot_ToggleSpell(rowNumber)"
        }
    }

    -- Column 4: Target selector button
    column
    {
        width 35
        button
        {
            area 0 4 140 32
            text lua "BuffBot_GetTargetText(rowNumber)"
            text style "button"
            action "BuffBot_OpenTargetPicker(rowNumber)"
        }
    }

    area 10 100 480 350
}
```

**Step 3 — Handle interactions:**

```lua
-- Checkbox toggle:
function BuffBot_ToggleSpell(row)
    local spell = buffbot_spellTable[row]
    spell.enabled = not spell.enabled
    BuffBot_SaveConfig()  -- persist the change
end

-- Checkbox frame (checked vs unchecked):
function BuffBot_GetCheckFrame(row)
    return buffbot_spellTable[row].enabled and 1 or 0
end

-- Target display text:
function BuffBot_GetTargetText(row)
    local target = buffbot_spellTable[row].target
    if target == "self" then return "Self"
    elseif target == "party" then return "Entire Party"
    else return EEex_Sprite_GetName(EEex_Sprite_GetInPortrait(target))
    end
end
```

### 6.3 Template Instance Pattern (BSME-Style Grid) **[SRC]**

For reference, the full template-based pattern is documented in §5.2–5.3 above. Use this
only if you need a custom spatial layout (grid, radial, etc.) that the list widget cannot
express. For BuffBot's scrollable config list, the list widget is sufficient.

### 6.4 Refreshing the List **[INF]**

When spell data changes (character switch, rest, spell cast), clear and repopulate:

```lua
function BuffBot_RefreshSpellList()
    local sprite = BuffBot_GetCurrentSprite()
    if not sprite then return end
    BuffBot_PopulateSpellList(sprite)
    -- The list widget automatically re-renders because it reads
    -- buffbot_spellTable every frame.
end
```

Subscribe to relevant events:

```lua
EEex_Sprite_AddQuickListsCheckedListener(function(sprite)
    if BuffBot_IsCurrentSprite(sprite) then
        BuffBot_RefreshSpellList()
    end
end)

EEex_Sprite_AddQuickListCountsResetListener(function(sprite)
    BuffBot_RefreshSpellList()
end)
```

---

## 7. Interactive Elements — Patterns

### 7.1 Scrollable Selectable List **[SRC]**

See §6.2 for the full pattern. The key properties:

```
list
{
    table "myTable"                     -- Lua global table
    var   "mySelectedRow"               -- Lua global for selected row (1-based index)
    rowheight 35                        -- pixels per row
    scrollbar "GUISCRC"                 -- enables scrollbar with this BAM
    scrollbar clunkyScroll 35           -- scroll step = one row
    hidehighlight                       -- optional: suppress default blue highlight
    area x y w h                        -- total list area
}
```

Reading the selection:

```lua
function BuffBot_GetSelectedSpell()
    local row = buffbot_selectedSpellRow  -- set by the list widget
    if row and row > 0 and row <= #buffbot_spellTable then
        return buffbot_spellTable[row]
    end
    return nil
end
```

### 7.2 Buttons with Icons and Text **[SRC]**

```
button
{
    name    "BuffBot_CastNow"
    enabled "BuffBot_CanCast()"
    action  "BuffBot_DoCastAll()"

    bam "GUIBUTNT"                      -- button background BAM
    frame 0
    scaleToClip

    text lua "BuffBot_GetCastButtonText()"
    text style "button"
    text align center center

    tooltip lua "BuffBot_GetCastTooltip()"

    area 10 460 120 40
}
```

### 7.3 Checkboxes / Toggles **[SRC]** **[INF]**

The engine has no native checkbox element. Checkboxes are buttons with two-state BAM
frames:

```lua
-- Lua state:
buffbot_cheatMode = false

function BuffBot_ToggleCheatMode()
    buffbot_cheatMode = not buffbot_cheatMode
    BuffBot_SaveConfig()
end

function BuffBot_GetCheatCheckFrame()
    return buffbot_cheatMode and 1 or 0
    -- frame 0 = unchecked, frame 1 = checked
end
```

```
-- .menu:
button
{
    name    "BuffBot_CheatToggle"
    action  "BuffBot_ToggleCheatMode()"
    bam     "GUICHECK"                  -- a checkbox-style BAM with 2 frames
    frame lua "BuffBot_GetCheatCheckFrame()"
    scaleToClip
    area 10 420 24 24
}
label
{
    text "Cheat Mode"
    text style "normal"
    text align left center
    area 40 420 120 24
}
```

### 7.4 Dropdowns (Target Selection) **[INF]**

The engine has no native dropdown element. The standard pattern is a button that opens a
sub-menu with the options:

**Main panel button:**

```
-- In BUFFBOT_MAIN menu:
button
{
    name     "BuffBot_TargetButton"
    text lua "BuffBot_GetSelectedTargetName()"
    text style "button"
    action   "Infinity_PushMenu('BUFFBOT_TARGET_PICKER')"
    area 350 460 130 30
}
```

**Sub-menu with options:**

```
menu
{
    name    "BUFFBOT_TARGET_PICKER"
    onopen  "BuffBot_OnTargetPickerOpen()"
    onclose "BuffBot_OnTargetPickerClose()"

    -- Dark backdrop (click to dismiss):
    text
    {
        action "Infinity_PopMenu('BUFFBOT_TARGET_PICKER')"
        on escape
        rectangle 1
        rectangle opacity 50
        area 0 0 99999 99999
    }

    -- Option buttons (positioned near the dropdown button):
    button
    {
        text "Self"
        text style "button"
        action "BuffBot_SetTarget('self'); Infinity_PopMenu('BUFFBOT_TARGET_PICKER')"
        area 350 380 130 25
    }
    button
    {
        text "Entire Party"
        text style "button"
        action "BuffBot_SetTarget('party'); Infinity_PopMenu('BUFFBOT_TARGET_PICKER')"
        area 350 355 130 25
    }
    -- ... more options generated by templates or hardcoded
}
```

For dynamically generated options (party member names), use templates:

```lua
function BuffBot_OnTargetPickerOpen()
    -- Destroy old instances:
    BuffBot_DestroyTargetOptions()

    -- Create one button per party member:
    for i = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(i)
        if sprite then
            local name = EEex_Sprite_GetName(sprite)
            BuffBot_CreateTargetOption(i, name, 350, 380 - (i * 27), 130, 25)
        end
    end
end
```

### 7.5 Tabs / Section Switching **[INF]**

Tabs are implemented as a row of buttons where clicking one changes a state variable.
All content elements are gated by `enabled` checks against that variable.

```lua
-- Tab state:
buffbot_activeTab = 1  -- 1=Long Buffs, 2=Short Buffs, 3=Healing, etc.

function BuffBot_SetTab(tabIndex)
    buffbot_activeTab = tabIndex
    BuffBot_RefreshSpellList()  -- repopulate with filtered spells
end

function BuffBot_IsTab(n)
    return buffbot_activeTab == n
end

-- Tab button frame (highlighted when active):
function BuffBot_GetTabFrame(n)
    return buffbot_activeTab == n and 1 or 0
end
```

```
-- .menu — tab bar:
button
{
    text "Long Buffs"
    text style "button"
    action "BuffBot_SetTab(1)"
    bam "GUIBUTNT"
    frame lua "BuffBot_GetTabFrame(1)"
    area 10 60 100 30
}
button
{
    text "Short Buffs"
    text style "button"
    action "BuffBot_SetTab(2)"
    bam "GUIBUTNT"
    frame lua "BuffBot_GetTabFrame(2)"
    area 115 60 100 30
}
button
{
    text "Healing"
    text style "button"
    action "BuffBot_SetTab(3)"
    bam "GUIBUTNT"
    frame lua "BuffBot_GetTabFrame(3)"
    area 220 60 100 30
}

-- Content gated by tab:
list
{
    enabled "BuffBot_IsTab(1)"
    table "buffbot_longBuffTable"
    -- ... long buffs list
}
list
{
    enabled "BuffBot_IsTab(2)"
    table "buffbot_shortBuffTable"
    -- ... short buffs list
}
```

### 7.6 Text Input **[SRC]**

For naming presets:

```lua
buffbot_presetNameInput = ""

function BuffBot_OnPresetNameKey()
    -- Called on each keystroke. Return 1 to accept, 0 to reject.
    -- Could be used to limit name length or reject invalid characters.
    return 1
end

function BuffBot_ConfirmPresetName()
    local name = buffbot_presetNameInput
    if name ~= "" then
        BuffBot_RenameCurrentPreset(name)
    end
end
```

```
edit
{
    name    "BuffBot_PresetNameEdit"
    enabled "buffbot_isRenaming"
    var     "buffbot_presetNameInput"
    action  "return BuffBot_OnPresetNameKey()"
    text style "edit"
    maxlines 1
    area 10 30 200 24
}
button
{
    enabled "buffbot_isRenaming"
    text "OK"
    action "BuffBot_ConfirmPresetName()"
    area 215 30 40 24
}
```

### 7.7 Sliders **[SRC]**

For priority ordering or other numeric settings:

```lua
buffbot_priorityPos = 0  -- 0-based position

function BuffBot_GetPrioritySteps()
    return #buffbot_spellTable  -- number of steps = number of spells
end

function BuffBot_OnPriorityChange()
    -- buffbot_priorityPos has been updated by the engine
    BuffBot_ReorderSpell(buffbot_selectedSpellRow, buffbot_priorityPos)
end
```

```
slider
{
    name         "BuffBot_PrioritySlider"
    position     "buffbot_priorityPos"
    settings lua "BuffBot_GetPrioritySteps()"
    action       "BuffBot_OnPriorityChange()"
    bam          "SLDRSTAR"
    sliderBackground "SLDRBACK"
    area 10 470 200 16
}
```

---

## 8. Configuration Persistence

### 8.1 Architecture Overview **[SRC]** **[DOC]**

BuffBot needs a tiered persistence strategy. Five mechanisms are available, each suited to
different scopes:

| Tier | Mechanism | Scope | Capacity | Use For |
|------|-----------|-------|----------|---------|
| 1 | EEex Marshal + UDAux | Per-character, in save | Arbitrary Lua table | Full spell config |
| 2 | Sprite Local Variables | Per-character, in save | 32-char name, int/32-char string | BCS-readable flags |
| 3 | Global Variables | Per-playthrough, in save | 32-char name, int/32-char string | Mod version, global state |
| 4 | INI File | Cross-save, global | No practical limit | User preferences |
| 5 | File I/O | External files | No practical limit | Preset export/import |

### 8.2 Tier 1: Marshal Handlers + UDAux (Primary Config Storage) **[SRC]**

This is EEex's mechanism for attaching arbitrary Lua data to characters that persists in
save games. It hooks into the engine's effect list serialization to inject a custom data
block (signature `"X-BIV1.0"`). Requires EEex v0.10.3-alpha+.

**How it works:**

1. `EEex_GetUDAux(sprite)` returns a Lua table attached to the sprite's userdata
   (in-memory only)
2. `EEex_Sprite_AddMarshalHandlers` registers export/import functions that serialize
   the UDAux data into the save game

**BuffBot implementation:**

```lua
-- Register our marshal handlers (called once at init):
EEex_Sprite_AddMarshalHandlers("BuffBot",
    -- EXPORTER: called during save
    function(sprite)
        if EEex.IsMarshallingCopy() then
            return {}  -- skip temporary copies (quicksave previews, etc.)
        end
        local config = EEex_GetUDAux(sprite)["BB_Config"]
        if config then
            return { ["Config"] = config }
        end
        return {}
    end,
    -- IMPORTER: called during load
    function(sprite, read)
        local config = read["Config"]
        if config then
            EEex_GetUDAux(sprite)["BB_Config"] = config
        end
    end
)

-- After a sprite is loaded, apply its restored config:
EEex_Sprite_AddLoadedListener(function(sprite)
    local config = EEex_GetUDAux(sprite)["BB_Config"]
    if config then
        BuffBot_ApplyConfig(sprite, config)
    else
        BuffBot_InitDefaultConfig(sprite)
    end
end)
```

**Config data structure (stored in UDAux):**

```lua
EEex_GetUDAux(sprite)["BB_Config"] = {
    version = 1,
    activePreset = 1,
    presets = {
        [1] = {
            name = "Long Buffs",
            spells = {
                ["SPWI304"] = { enabled = true, target = "party", priority = 1 },
                ["SPPR301"] = { enabled = true, target = "self",  priority = 2 },
                -- ...
            }
        },
        [2] = {
            name = "Short Buffs",
            spells = { ... }
        },
        -- up to 5 presets
    },
    cheatMode = false,
    skipActive = true,
}
```

**Constraints:**
- Data must be serializable (tables, strings, numbers, booleans — no functions, no
  circular references, no userdata)
- The `IsMarshallingCopy()` check prevents data from leaking to temporary copies
- Old versions of Near Infinity (save editor) corrupt saves with EEex's custom block;
  users need the latest version

### 8.3 Tier 2: Sprite Local Variables (BCS-Readable Flags) **[SRC]**

For simple flags that BAF/BCS scripts need to read (e.g., "is BuffBot currently casting
for this character"):

```lua
-- Set a flag on a character:
EEex_Sprite_SetLocalInt(sprite, "BB_CASTING", 1)

-- Read it back:
local isCasting = EEex_Sprite_GetLocalInt(sprite, "BB_CASTING")  -- 0 if unset
```

BCS scripts can read these via `Global("BB_CASTING","LOCALS")`:

```
IF
  Global("BB_CASTING","LOCALS",1)
THEN
  RESPONSE #100
    // BuffBot is casting for this character — don't interrupt
END
```

**Constraints:** Variable names max 32 chars, values are 32-bit integers or 32-char
strings. Too small for full config data — use only for simple flags.

### 8.4 Tier 3: Global Variables (Per-Playthrough State) **[SRC]**

For state that's global to the playthrough (not per-character):

```lua
-- Store in the GAM file (persists with save):
EEex_GameState_SetGlobalInt("BB_MOD_VERSION", 1)
EEex_GameState_SetGlobalInt("BB_CHEAT_GLOBAL", 0)

-- Read back:
local ver = EEex_GameState_GetGlobalInt("BB_MOD_VERSION")  -- 0 if unset
```

**Constraints:** Same 32-char limits as sprite locals. Scope is the entire save game.

### 8.5 Tier 4: INI File (Cross-Save Preferences) **[DOC]**

For user preferences that should persist across all save games:

```lua
-- Read from baldur.ini:
local showTooltips = Infinity_GetINIValue("BuffBot", "ShowTooltips", 1)  -- default 1
local uiScale      = Infinity_GetINIValue("BuffBot", "UIScale", 100)

-- Write to baldur.ini:
Infinity_SetINIValue("BuffBot", "ShowTooltips", 1)
Infinity_SetINIValue("BuffBot", "UIScale", 100)

-- String values:
local lastExport = Infinity_GetINIString("BuffBot", "LastExportPath", "")
```

**Important**: `Infinity_SetINIValue` sets the value in C++ memory. The game writes the
INI to disk on exit. **[DOC]**

### 8.6 Tier 5: File I/O (Preset Export/Import) **[UNC]**

For the export/import feature (CLAUDE.md requirement). Whether standard Lua `io.*` is
available in EEex's Lua environment needs runtime verification.

**If `io` is available:**

```lua
function BuffBot_ExportPreset(presetIndex, filename)
    local preset = BuffBot_GetPreset(presetIndex)
    local data = BuffBot_Serialize(preset)  -- custom serializer to Lua table literal
    local file = io.open(filename, "w")
    if file then
        file:write("return " .. data)
        file:close()
        return true
    end
    return false
end

function BuffBot_ImportPreset(filename)
    local chunk = loadfile(filename)
    if chunk then
        local preset = chunk()
        if BuffBot_ValidatePreset(preset) then
            return preset
        end
    end
    return nil
end
```

**Fallback if `io` is unavailable**: Use `Infinity_DoFile` to load a preset `.lua` file
from the override folder. Export would need to use a different mechanism (possibly
`Infinity_SetINIValue` with a serialized string, or EEex's file writing functions if they
exist). **[UNC]**

### 8.7 Corrections to eeex-api-surface.md §10

The existing `eeex-api-surface.md` contains this in §10:

```lua
-- "EEex Variable System" [UNC]
EEex_Variable_SetInt("buffbot_enabled", 1)
EEex_Variable_GetInt("buffbot_enabled")
```

**This is incorrect.** `EEex_Variable.lua` adds methods to the engine's `CVariableHash`
class — it is not a separate top-level API. There is no `EEex_Variable_SetInt()` function.
The correct functions are:

- `EEex_GameState_SetGlobalInt(name, value)` / `GetGlobalInt(name)` — GAM-stored globals
- `EEex_Sprite_SetLocalInt(sprite, name, value)` / `GetLocalInt(sprite, name)` — CRE-stored locals
- `EEex_GetUDAux(sprite)` + marshal handlers — arbitrary per-character data

---

## 9. Adding Buttons to Existing UI

### 9.1 Option A: Template Injection into Actionbar **[SRC]**

The cleanest approach. Uses EEex to inject a new button directly into the game's
`WORLD_ACTIONBAR` menu without modifying the original menu file.

```lua
-- In BuffBot_Init.lua, after menu load:
EEex_Menu_InjectTemplate(
    "WORLD_ACTIONBAR",       -- target menu name
    "BUFFBOT_ACTIONBAR_BTN", -- template name (defined in BuffBot.menu)
    500, 0, 48, 48           -- x, y, w, h position on the actionbar
)
```

Template definition in BuffBot.menu:

```
template
{
    button
    {
        bam      "BUFFBTN"                      -- BuffBot's custom BAM icon
        frame    0
        scaleToClip
        tooltip  "BuffBot Configuration"
        action   "BuffBot_TogglePanel()"
        enabled  "BuffBot_IsInGame()"
    }
    name "BUFFBOT_ACTIONBAR_BTN"
}
```

**Pros**: No file patching, clean installation/uninstallation, compatible with other mods.
**Cons**: Positioning requires knowing the actionbar layout; may overlap with other mods'
injected buttons. **[INF]**

### 9.2 Option B: Keyboard Shortcut **[SRC]**

```lua
EEex_Key_AddPressedListener(function(key)
    if key == EEex_Key_GetFromName("F11") then
        BuffBot_TogglePanel()
    end
end)

function BuffBot_TogglePanel()
    if Infinity_IsMenuOnStack("BUFFBOT_MAIN") then
        Infinity_PopMenu("BUFFBOT_MAIN")
    else
        BuffBot_RefreshAndOpen()
    end
end
```

**Pros**: Always accessible, no UI collision with other mods.
**Cons**: Not discoverable — player needs to know the key. Best used as a secondary access
method alongside a visible button.

### 9.3 Option C: Castable Ability **[INF]**

Create a special ability (innate spell) that, when cast, opens the BuffBot panel instead
of producing a spell effect. This is the "simplest to implement" option from CLAUDE.md.

```
// In the .tp2 installer:
// Create a special ability SPL file that triggers a Lua callback via opcode
// Add it to each party member's innate ability list

// The SPL's effect would use EEex's custom opcode (#400) to call Lua:
// Opcode 400: EEex_Lua parameter = "BuffBot_TogglePanel()"
```

**Pros**: Works without any actionbar modification, visible in the character's ability list.
**Cons**: Requires a free ability slot, takes a game action to "cast", slightly awkward UX
compared to a dedicated button.

### 9.4 Option D: Hooking an Existing Button **[SRC]**

BSME's approach: intercept the actionbar state change when the player clicks an existing
button (like "Cast Spell") and redirect to a custom panel:

```lua
EEex_Actionbar_AddListener(function(config, state)
    if config == 21 and state == 103 then  -- Cast Spell button
        EEex_Actionbar_RestoreLastState()   -- undo the button press
        Infinity_PushMenu("MY_CUSTOM_MENU") -- open our panel instead
    end
end)
```

**Not recommended for BuffBot**: This replaces existing UI behavior, which would conflict
with BSME and confuse players who expect the Cast Spell button to open the spell menu.
Documented here for completeness.

### 9.5 Recommended Approach for BuffBot **[INF]**

Combine Options A + B:

1. **Primary**: Inject a dedicated BuffBot button into the actionbar via
   `EEex_Menu_InjectTemplate` (visible, discoverable)
2. **Secondary**: Register a keyboard shortcut via `EEex_Key_AddPressedListener`
   (convenient for repeat access)
3. **Fallback**: If actionbar injection proves problematic (position conflicts, UI mod
   incompatibility), fall back to the castable ability approach (Option C)

---

## Appendix A: Key Infinity_* Function Reference

Functions confirmed from BSME source and EEex docs:

```lua
-- Menu stack management:
Infinity_PushMenu("MenuName")               -- open a menu
Infinity_PopMenu("MenuName")                -- close a specific menu
Infinity_IsMenuOnStack("MenuName")          -- → boolean

-- Element positioning:
Infinity_SetArea("ElementName", x, y, w, h) -- nil values leave that component unchanged
Infinity_GetArea("ElementName")             -- → x, y, w, h

-- Template instance management:
Infinity_InstanceAnimation(template, bam, x, y, w, h, list, listIndex) -- create instance
Infinity_DestroyAnimation(templateName, instanceId)                     -- destroy instance

-- Screen info:
Infinity_GetScreenSize()                    -- → screenW, screenH

-- Text measurement:
Infinity_GetContentHeight(font, width, text, pointSize, indent)

-- String table:
Infinity_FetchString(strref)                -- → localized string

-- INI persistence:
Infinity_GetINIValue("Section", "Key", default)    -- → integer
Infinity_SetINIValue("Section", "Key", value)
Infinity_GetINIString("Section", "Key", default)   -- → string

-- Lua file loading:
Infinity_DoFile("ResRef")                   -- loads ResRef.lua from override

-- Time:
Infinity_GetClockTicks()                    -- → milliseconds

-- Feedback:
Infinity_DisplayString("text")              -- on-screen text feedback
```

## Appendix B: EEex_Menu_* Function Reference

Complete list verified from `EEex_Menu.lua` (452 lines) in the game install. **[SRC]**

```lua
-- Coordinate translation:
EEex_Menu_TranslateXYFromGame(gameX, gameY)       -- → uiX, uiY
EEex_Menu_GetMousePos()                            -- → mouseX, mouseY
EEex_Menu_IsCursorWithinRect(x, y, w, h)           -- → boolean
EEex_Menu_IsCursorWithin(menuName, itemName)        -- → boolean

-- Menu / item lookup:
EEex_Menu_Find(menuName, panel, state)              -- → menu userdata | nil
EEex_Menu_GetItem(menuItemName)                     -- → uiItem userdata | nil
EEex_Menu_GetArea(menuName)                         -- → x, y, w, h (of the menu itself)
EEex_Menu_GetUIMenuArea(menu)                       -- → x, y, w, h (from menu userdata)
EEex_Menu_GetItemArea(menuItemName)                 -- → x, y, w, h (screen coords of named item)
EEex_Menu_GetUIItemArea(item)                       -- → x, y, w, h (from item userdata)
EEex_Menu_IsNative(menuName)                        -- → boolean (true if from UI.menu, not dynamic)

-- Event function manipulation:
EEex_Menu_GetItemFunction(funcRef)                  -- → current Lua function
EEex_Menu_SetItemFunction(funcRef, fn)              -- replace with new function
EEex_Menu_GetItemVariant(variant)                   -- → variant value
EEex_Menu_SetItemVariant(variantRefPtr, myVal)      -- set variant value

-- Menu file loading:
EEex_Menu_LoadFile(resref)                          -- loads resref.menu from override
EEex_Menu_Eval(str)                                 -- evaluate Lua string in menu context

-- Template injection:
EEex_Menu_InjectTemplate(menuName, templateName, x, y, w, h)
EEex_Menu_InjectTemplateInstance(menuName, templateName, instanceId, x, y, w, h)
EEex_Menu_DestroyInjectedTemplate(menuName, templateName, instanceId)
EEex_Menu_DestroyAllTemplates(menuName)

-- Template instance management:
EEex_Menu_StoreTemplateInstance(menuName, templateName, instanceID, storeIntoName)
EEex_Menu_SetTemplateArea(menuName, templateName, instanceID, x, y, w, h)

-- Scrollbar control:
EEex_Menu_SetForceScrollbarRender(itemName, value)
EEex_Menu_SetItemExtraScrollbarPad(uiItem, value)

-- Lifecycle listeners:
EEex_Menu_AddBeforeMainFileLoadedListener(fn)       -- before UI.menu loads
EEex_Menu_AddAfterMainFileLoadedListener(fn)        -- after UI.menu loads
EEex_Menu_AddMainFileLoadedListener(fn)             -- CONVENIENCE: after + deferred
EEex_Menu_AddBeforeMainFileReloadedListener(fn)     -- before resolution change reload
EEex_Menu_AddAfterMainFileReloadedListener(fn)      -- after resolution change reload
EEex_Menu_AddWindowSizeChangedListener(fn)          -- on window resize
EEex_Menu_AddTranslationLoadedListener(fn)          -- after language strings loaded

-- Render hooks:
EEex_Menu_AddBeforeListRendersItemListener(listName, fn)
EEex_Menu_AddBeforeUIItemRenderListener(itemName, fn)
```

**Note**: Several internal `Hook_` functions exist (`Hook_CheckSaveMenuItem`,
`Hook_BeforeMainFileLoaded`, `Hook_AfterMainFileLoaded`, `Hook_BeforeListRenderingItem`,
`Hook_OnBeforeUIItemRender`, `Hook_OnWindowSizeChanged`, `Hook_SaveInstanceId`,
`LuaHook_BeforeMenuStackSave`, `Hook_AfterMenuStackRestore`,
`LuaHook_AfterTranslationLoaded`). These are engine callbacks, not intended for direct mod
use. Use the `Add*Listener` versions instead.

## Appendix C: BuffBot-Relevant Event Listeners

```lua
-- Spell list changes:
EEex_Sprite_AddQuickListsCheckedListener(fn)       -- spell count changed
EEex_Sprite_AddQuickListCountsResetListener(fn)    -- counts reset (rest)
EEex_Sprite_AddQuickListNotifyRemovedListener(fn)  -- spell removed
EEex_Sprite_AddSpellDisableStateChangedListener(fn) -- spell enabled/disabled

-- Character lifecycle:
EEex_Sprite_AddLoadedListener(fn)                  -- sprite loaded from save

-- Keyboard:
EEex_Key_AddPressedListener(fn)                    -- key pressed
EEex_Key_GetFromName("F11")                        -- → keycode

-- Actionbar:
EEex_Actionbar_AddListener(fn)                     -- actionbar state change
EEex_Actionbar_RestoreLastState()                  -- undo last state change
EEex_Actionbar_AddButtonsUpdatedListener(fn)       -- buttons refreshed
```
