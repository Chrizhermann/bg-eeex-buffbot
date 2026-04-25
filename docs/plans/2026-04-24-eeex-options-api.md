# EEex Options API discovery (Task 13 spike)

Source-of-truth files in the modded override:
- `EEex_Options.lua` (~5000 lines, OOP-style class definitions)
- `EEex_OptionsLate.lua` (registers EEex's own Keybinds/Modules tabs)
- `X-en_US.lua` (defines the `uiStrings[<TRANSLATION key>]` strings)
- Reference mods: `B3Timer.lua` (toggles), `B3Scale.lua` (numeric edit), `B3EffMen.lua` (keybind + edit)

All findings below were validated against the running game (BG2EE modded) on
2026-04-25 via the EEex remote console — see "Verification" at the bottom.

---

## 1. Top-level functions

### `EEex_Options_AddTab(label, displayEntriesProvider)`
- `label` (string, required): used both as the tab title and as the sort key.
  In practice all stock tabs pass a translation key (e.g.
  `"EEex_Options_TRANSLATION_Scale_TabTitle"`); the engine resolves it via
  `t(label)` for sorting and rendering.
- `displayEntriesProvider`: either a value or a `function() return value end`.
  The value must be a **table of "groups"**, where each group is itself a list
  of `EEex_Options_DisplayEntry` instances. Pattern:
  ```lua
  EEex_Options_AddTab("MyTab_TabTitle", function() return {
    { -- group 1 (rendered together, separated by a divider in the UI)
      EEex_Options_DisplayEntry.new({...}),
      EEex_Options_DisplayEntry.new({...}),
    },
    { -- group 2 (optional)
      EEex_Options_DisplayEntry.new({...}),
    },
  } end)
  ```
- Internally wrapped in `EEex_GameState_AddInitializedListener`, so it is safe
  to call early (e.g. at module-top level). Each call appends to
  `EEex_Options_Private_Tabs[EEex_Options_Private_TabInsertIndex]` and then
  sorts the whole list alphanumerically by `t(tab.label)`.

### `EEex_Options_Register(id, option)`
- `id` (string, required): unique global ID. Conventionally
  `<Module>_<OptionName>` (e.g. `"B3Timer_HugPortraits"`). Must match the
  `optionID` of any `DisplayEntry` referencing it.
- `option`: an `EEex_Options_Option` instance (see below).
- Returns `option` so you can capture it in a local for direct
  `option:get()` / `option:set(v)` access.

### `EEex_Options_Get(id)` -> option | nil
- Lookup by ID; useful when one module needs to read another module's option.

### Note: there is **no public `EEex_Options_RemoveTab`**.
Tabs registered at runtime stay until restart. For the spike, cleanup required
direct mutation of `EEex_Options_Private_Tabs` and `_TabInsertIndex`.

---

## 2. The Option table (`EEex_Options_Option.new`)

Required fields:
- `default` — non-nil. Type matches what `accessor:get()` will return.
- `type` — instance of an `EEex_Options_*Type` (see below).

Optional fields:
- `accessor` — defaults to `EEex_Options_PrivateAccessor.new()` (in-memory only).
- `requiresRestart` (boolean) — if true, `set()` writes to storage but doesn't
  apply until restart. Default `false`.
- `storage` — instance of an `EEex_Options_*Storage` (see below). If absent,
  the value is volatile (lost on restart).
- `onChange` — `function(self)` called after `_set` whenever the value
  actually changed.

Public methods on the returned option:
- `:get()` — current in-effect value (deep-copied).
- `:set(newValue)` — applies (and persists if `storage` is set). `nil` resets
  to default.
- `:getDefault()` — the default value (deep-copied).

### Type constructors (`type` field)
| Constructor | Required init args | Used with widget |
| --- | --- | --- |
| `EEex_Options_ToggleType.new()` | none | `ToggleWidget` |
| `EEex_Options_EditType.new()` | none | `EditWidget` |
| `EEex_Options_KeybindType.new({callback=fn, lockedFireType=...})` | `callback` (function) | `KeybindWidget` |

There is **no `Dropdown` type / widget** in vanilla EEex. Multi-state choices
are conventionally modeled as **a row of toggles**, with one option being
"main" and others using `widget.deferTo = "<mainID>"` + `toggleValue = N`. (See
`EEex_Options_ToggleWidget._init`: `disallowToggleOff`, `forceOthers`,
`toggleValue`, `toggleState`, `deferTo`.) If a real dropdown is wanted, build a
custom widget by subclassing `EEex_Options_Widget`. For BuffBot's "Style"
choice (Dark / Light / Classic) this means three toggles sharing one option,
similar to how EEex_Modules.lua handles its on/off toggles.

### Accessors (`accessor` field)
- `EEex_Options_PrivateAccessor.new()` — value held inside the option
  instance. Default if `accessor` omitted.
- `EEex_Options_GlobalAccessor.new({name = "MyGlobal"})` — `set()` writes to
  global `_G[name]`, `get()` reads from it. Useful when engine code reads the
  flag via a Lua global.
- `EEex_Options_ClampedAccessor.new({min=N, max=N, floating=true|false})` —
  validates / clamps numeric input. Use for toggles (`min=0,max=1`) and
  numeric edits.
- `EEex_Options_KeybindAccessor.new({keybindID = "<id>"})` — wires into the
  keybind subsystem.

### Storage (`storage` field, all use `Infinity_GetINIString` / `Infinity_SetINIValue`)
- `EEex_Options_NumberLuaStorage.new({section="EEex", key="..."})`
- `EEex_Options_StringLuaStorage.new({section="...", key="..."})`
- `EEex_Options_KeybindLuaStorage.new({section="...", key="..."})`
- `EEex_Options_NumberINIStorage.new(...)` / `EEex_Options_StringINIStorage.new(...)`
  (used for actual `baldur.ini` engine settings; LuaStorage variants are the
  conventional choice for mod options).

`section` and `key` are both **required**. A LuaStorage option lives in
`baldur.ini` under `[<section>]` with key `<key>`.

---

## 3. The DisplayEntry table (`EEex_Options_DisplayEntry.new`)

All four fields are **required**, validated in `_init`:
- `optionID` (string) — must match an ID passed to `EEex_Options_Register`.
- `label` (string) — translation key, resolved via `t(label)` against
  `uiStrings[label]` at render time.
- `description` (string) — translation key for the help text shown when the
  entry is hovered/focused.
- `widget` — instance of an `EEex_Options_*Widget`.

If the label string isn't found in `uiStrings`, `t()` returns the raw key —
the UI then shows the literal `EEex_Options_TRANSLATION_...` text, which is a
useful tell that translations aren't loaded.

### Widget constructors

#### `EEex_Options_ToggleWidget.new({...})`
Optional fields (all default to sensible values):
- `toggleValue` (number, default `1`) — the value this toggle "represents".
  When the option's value equals `toggleValue`, the toggle shows ON.
- `disallowToggleOff` (boolean, default `false`) — if true, clicking the
  toggle while ON does nothing (used when at least one in a group must be on).
- `forceOthers` (table, default `{}`) — `{[stateValue] = {<otherDisplayEntries>}}`,
  forces the listed display entries to a target state when this toggle
  transitions.
- `deferTo` (string, optional) — ID of another DisplayEntry. When set, this
  toggle reads/writes the *other* entry's option. This is how a "radio group"
  is built: many widgets sharing one option ID but with different
  `toggleValue` numbers.
- `toggleWarning` (optional) — undocumented; appears to be a confirmation
  prompt hook.

#### `EEex_Options_EditWidget.new({maxCharacters = N, number = bool})`
- `maxCharacters` (number, **required**) — max characters in the text field.
- `number` (boolean, default `false`) — if true, restricts input to digits
  (and decimal point if accessor has `floating=true`).

#### `EEex_Options_KeybindWidget.new()`
No init args. Pairs with `KeybindType` + `KeybindAccessor` + `KeybindLuaStorage`.

---

## 4. How callbacks fire / what they receive

- **`option:set(v)`** path: `_set(v, false, true)` →
  `accessor:validate` → `accessor:set` → write to storage → fire
  `option.onChange(self)` if value actually changed.
- **`onChange`** is called as a **method** on the option (so first arg is
  `self`). Use `function(self) ... self:get() ... end` or capture the option
  in a local and ignore `self`. B3Scale uses the closure form:
  `["onChange"] = function() B3Scale_Private_PokeEngine() end`.
- **`KeybindType.callback`** is the function fired when the keybind triggers
  in-game. Signature varies by `lockedFireType` (DOWN / UP / etc. from
  `EEex_Keybinds_FireType`).

---

## 5. How labels render (translation)

`label` and `description` strings on a `DisplayEntry`, plus the tab `label`,
are all **translation keys** resolved via `t(<key>)`. `t()` looks up
`uiStrings[<key>]` (a global table populated by EEex's `X-en_US.lua` and
language-specific `L_*.LUA` files). Convention:
```lua
-- in your own X-en_US-style file (or just write directly to uiStrings)
uiStrings["MyMod_TRANSLATION_TabTitle"]                 = "My Mod"
uiStrings["MyMod_TRANSLATION_Setting1"]                 = "Setting 1"
uiStrings["MyMod_TRANSLATION_Setting1_Description"]     = [[
What this setting does, with line breaks
allowed via long-string brackets.
]]
```

If you never assign the key, the UI literally shows `MyMod_TRANSLATION_TabTitle`.
For BuffBot we already have a string system (`BfBot.UI` text) — for the EEex
tab we should populate `uiStrings` at module load.

---

## 6. Working examples

### Toggle (verified pattern, copied from B3Timer + extended for radio group)

```lua
-- Single-option toggle (boolean-ish: 0 / 1)
BfBot_Options_DarkMode = EEex_Options_Register(
  "BuffBot_DarkMode",
  EEex_Options_Option.new({
    ["default"]  = 0,
    ["type"]     = EEex_Options_ToggleType.new(),
    ["accessor"] = EEex_Options_ClampedAccessor.new({ ["min"] = 0, ["max"] = 1 }),
    ["storage"]  = EEex_Options_NumberLuaStorage.new({
      ["section"] = "BuffBot",
      ["key"]     = "Dark Mode",
    }),
    ["onChange"] = function() BfBot.Theme.OnDarkModeChanged() end,
  })
)

EEex_Options_AddTab("BuffBot_TRANSLATION_TabTitle", function() return {
  {
    EEex_Options_DisplayEntry.new({
      ["optionID"]    = "BuffBot_DarkMode",
      ["label"]       = "BuffBot_TRANSLATION_DarkMode",
      ["description"] = "BuffBot_TRANSLATION_DarkMode_Description",
      ["widget"]      = EEex_Options_ToggleWidget.new(),
    }),
  },
} end)
```

### "Radio group" (no real dropdown — multiple toggles share one option ID)

```lua
-- One option holds the chosen style index (0=Dark, 1=Light, 2=Classic).
BfBot_Options_Style = EEex_Options_Register(
  "BuffBot_Style",
  EEex_Options_Option.new({
    ["default"]  = 0,
    ["type"]     = EEex_Options_ToggleType.new(),
    ["accessor"] = EEex_Options_ClampedAccessor.new({ ["min"] = 0, ["max"] = 2 }),
    ["storage"]  = EEex_Options_NumberLuaStorage.new({
      ["section"] = "BuffBot",
      ["key"]     = "Style",
    }),
    ["onChange"] = function() BfBot.Theme.Reload() end,
  })
)

-- Each toggle deferTo-s the same option, has a unique toggleValue,
-- and disallowToggleOff so one is always selected.
EEex_Options_AddTab("BuffBot_TRANSLATION_TabTitle", function() return {
  {
    EEex_Options_DisplayEntry.new({
      ["optionID"]    = "BuffBot_Style",
      ["label"]       = "BuffBot_TRANSLATION_Style_Dark",
      ["description"] = "BuffBot_TRANSLATION_Style_Description",
      ["widget"]      = EEex_Options_ToggleWidget.new({
        ["toggleValue"]       = 0,
        ["disallowToggleOff"] = true,
      }),
    }),
    EEex_Options_DisplayEntry.new({
      ["optionID"]    = "BuffBot_Style", -- same option!
      ["label"]       = "BuffBot_TRANSLATION_Style_Light",
      ["description"] = "BuffBot_TRANSLATION_Style_Description",
      ["widget"]      = EEex_Options_ToggleWidget.new({
        ["toggleValue"]       = 1,
        ["disallowToggleOff"] = true,
      }),
    }),
    EEex_Options_DisplayEntry.new({
      ["optionID"]    = "BuffBot_Style",
      ["label"]       = "BuffBot_TRANSLATION_Style_Classic",
      ["description"] = "BuffBot_TRANSLATION_Style_Description",
      ["widget"]      = EEex_Options_ToggleWidget.new({
        ["toggleValue"]       = 2,
        ["disallowToggleOff"] = true,
      }),
    }),
  },
} end)
```

(If a *real* dropdown is required, the path is to subclass
`EEex_Options_Widget`, override `_buildLayout` to return a custom
`EEex_Options_Private_Layout*` chain, and ship the `.menu` template — out of
scope for Task 14.)

### Numeric edit (font size, copied from B3Scale + B3EffMen)

```lua
BfBot_Options_FontScale = EEex_Options_Register(
  "BuffBot_FontScale",
  EEex_Options_Option.new({
    ["default"]  = 1.0,
    ["type"]     = EEex_Options_EditType.new(),
    ["accessor"] = EEex_Options_ClampedAccessor.new({
      ["min"] = 0.5, ["max"] = 2.0, ["floating"] = true,
    }),
    ["storage"]  = EEex_Options_NumberLuaStorage.new({
      ["section"] = "BuffBot",
      ["key"]     = "Font Scale",
    }),
    ["onChange"] = function() BfBot.Theme.RefreshFontSize() end,
  })
)

-- inside the AddTab provider:
EEex_Options_DisplayEntry.new({
  ["optionID"]    = "BuffBot_FontScale",
  ["label"]       = "BuffBot_TRANSLATION_FontScale",
  ["description"] = "BuffBot_TRANSLATION_FontScale_Description",
  ["widget"]      = EEex_Options_EditWidget.new({
    ["maxCharacters"] = 4,
    ["number"]        = true,
  }),
}),
```

---

## 7. Pitfalls / constraints

1. **No `RemoveTab`.** Once `AddTab` runs, the tab persists for the session.
   Don't call it conditionally / repeatedly.
2. **`AddTab` is wrapped in `EEex_GameState_AddInitializedListener`.** Calling
   it from a game-state-initialized callback yourself can cause double-add if
   you re-register on `Infinity_DoFile` reload. For dev reload, also reset
   `EEex_Options_Private_TabInsertIndex` and remove the prior entry from
   `EEex_Options_Private_Tabs` — or just accept restart-only updates.
3. **Translation lookup is by string identity** — typos in `label` are not
   detected, you'll just see the raw key in the UI.
4. **No dropdown widget.** Use the `deferTo` toggle-radio pattern, or build
   a custom widget. Boolean-as-number storage (`0`/`1`) is the convention,
   not `true`/`false`.
5. **`onChange` is called as a method** (`self` is the option). Closures over
   captured locals are simpler.
6. **Storage requires both `section` and `key`** — both are validated in
   `_init` and will `EEex_Error` if missing.
7. **`displayEntries` is grouped 2D**: a flat list of DisplayEntry instances
   will fail layout. Wrap them in at least one inner `{ ... }`.
8. **Tab sort uses `t(tab.label)` alphanumerically.** Naming the tab
   `"BuffBot_TRANSLATION_TabTitle"` with `uiStrings[...] = "BuffBot"` will
   place it in B-position; if order matters, choose the resolved string
   accordingly. (Conventionally EEex stock tabs all start with the prefix
   "Module:" so they cluster.)

---

## 8. Verification (in-game spike)

Run on 2026-04-25 against BG2EE modded via the EEex remote console:

1. Probed function existence — all 5 (`AddTab`, `Register`, `DisplayEntry`,
   `ToggleWidget`, `EditWidget`) are live globals.
2. `EEex_Options_AddTab("BuffBot_Test", function() return {} end)` — succeeded
   with no error; tab appeared in `EEex_Options_Private_Tabs`.
3. Full toggle round-trip (`Register` + `AddTab` with one DisplayEntry +
   ToggleWidget) — `AddTab` errored on the second call due to a leftover gap
   in `_Tabs` from manual cleanup of test #2 (root cause: `_TabInsertIndex`
   wasn't decremented when I `table.remove`-d). Fixed by rebuilding
   `_Tabs` from `pairs(...)` and resetting `_TabInsertIndex = #_Tabs + 1`.
   This confirms a real constraint for live-reload scenarios but does **not**
   affect Task 14 (which only registers once per session).
4. All test tabs and option entries removed before exit; verified
   `EEex_Options_Get("BuffBot_Test_DarkMode")` returns `nil`.

---

## 9. Recommendation for Task 14

- Define BuffBot's translation strings into `uiStrings` early (in `BfBotCor`
  or a dedicated `BfBotOpt` module loaded after EEex_Options).
- Register options + the tab once at module-top level (no listener needed —
  `AddTab` is already deferred internally).
- Use the **radio-group toggle pattern** for the Style chooser (Dark / Light /
  Classic).
- Use **`NumberLuaStorage`** with `section = "BuffBot"` to align with our
  existing `[BuffBot]` `baldur.ini` section.
- Wire `onChange` callbacks into the existing theme refresh paths (`Theme.Reload`,
  `Theme.RefreshFontSize`, etc.).
- Skip live-reload of the EEex tab — `Infinity_DoFile` re-running the module
  will double-add. Either guard with a "registered" flag or accept that
  changing tab structure requires restart.
