# Movable & Resizable Panel — Design Doc

**Issue:** #24 — Configurable and movable UI panel
**Date:** 2026-04-08

## Problem

The BuffBot config panel is fixed at 80% of screen, centered. Users want to reposition and resize it to fit their UI setup, especially with other mods present.

## Solution

Make the panel movable (title bar drag) and resizable (bottom-right corner drag) using the `.menu` `handle` element with `actionDrag` callbacks. Persist position/size to INI. All existing relative layout math in `_Layout()` continues to work — it already derives everything from `px, py, pw, ph`.

## Drag Mechanics

### Move (title bar)

- `handle` element `bbDragHandle` covering the title bar area
- `actionDrag "BfBot.UI._OnDrag()"` reads engine-provided `motionX`/`motionY` globals
- Applies deltas to stored `_panelX`, `_panelY`
- Calls `_Layout()` to reposition all elements

### Resize (bottom-right corner)

- `handle` element `bbResizeHandle` (20x20px) at bottom-right corner
- `actionDrag "BfBot.UI._OnResize()"` reads `motionX`/`motionY`
- Applies deltas to stored `_panelW`, `_panelH`
- Calls `_Layout()` to resize all elements

### Constraints

- **Minimum size:** 550px wide, 350px tall (widest button row ~420px + padding; header + footer + ~50px spell list)
- **Screen clamping:** Panel stays fully on-screen after each drag. Title bar always grabbable (30px minimum visible at top).
- **MOS regeneration:** `_OnResize()` calls `_GenerateBgMOS()` if panel + border exceeds current MOS dimensions.

### Reset to Default

- Small "Reset" button in title bar (right-aligned)
- `_ResetLayout()` clears stored values to nil, clears INI prefs, calls `_Layout()`
- Reverts to 80%-centered default behavior

## Persistence

### Storage

- INI keys `PanelX`, `PanelY`, `PanelW`, `PanelH` in `[BuffBot]` section of `baldur.ini`
- Uses existing `GetPref`/`SetPref` pattern
- Global (not per-save) — UI layout is a user preference

### Default Sentinel

- When INI values are 0 or absent, fall back to 80%-centered computation
- First launch and "Reset Layout" both produce default behavior (no INI values)

### Write Timing

- `_SaveLayout()` called from `_OnClose()` (when panel closes)
- During drag, only in-memory state updates — no disk thrashing

### Resolution Change

- Existing `WindowSizeChangedListener` already calls `_Layout()`
- On resolution change, clamp stored values to new screen bounds
- If panel no longer fits, reset to defaults

## .menu Changes

Two new `handle` elements in `BUFFBOT_MAIN`:

```
handle
{
    name "bbDragHandle"
    area 0 0 100 30
    actionDrag "BfBot.UI._OnDrag()"
}

handle
{
    name "bbResizeHandle"
    area 0 0 20 20
    actionDrag "BfBot.UI._OnResize()"
}
```

Both positioned dynamically by `_Layout()`. No visual chrome changes to existing elements.

A new "Reset" button in the title bar area (text element, right-aligned).

## Lua Changes

### New State Variables

- `BfBot.UI._panelX`, `_panelY`, `_panelW`, `_panelH` — current geometry, loaded from INI on init

### Modified `_Layout()`

```lua
local pw = BfBot.UI._panelW or math.floor(sw * 0.8)
local ph = BfBot.UI._panelH or math.floor(sh * 0.8)
local px = BfBot.UI._panelX or math.floor((sw - pw) / 2)
local py = BfBot.UI._panelY or math.floor((sh - ph) / 2)
```

Rest unchanged — all positioning already relative to these four values.

### New Functions (~40-50 lines)

- `_OnDrag()` — read motionX/motionY, update _panelX/_panelY, clamp, call _Layout()
- `_OnResize()` — read motionX/motionY, update _panelW/_panelH, enforce minimums, clamp, _GenerateBgMOS() if needed, call _Layout()
- `_ResetLayout()` — clear _panelX/Y/W/H to nil, clear INI prefs, call _Layout()
- `_SaveLayout()` — write _panelX/Y/W/H to INI via SetPref
- `_LoadLayout()` — read from INI into state vars, called once in _OnMenusLoaded()

## Edge Cases

- **Sub-menus (target picker, spell picker, import picker):** Remain centered on screen, not relative to moved panel.
- **Full-screen overlay click-to-close:** Stays full-screen, independent of panel position.
- **Actionbar button:** Unaffected — positioned relative to actionbar.
- **Spell list minimum height:** At minimum panel height (350px), spell list shows ~4-5 rows (~122px).

## Reference

- BSME `B3Spell_Menu_SelectSlotArea` — uses same `handle` + `actionDrag` + `motionX`/`motionY` pattern
- B3EffectMenu — uses `Infinity_SetOffset` for repositioning (different approach, less suitable here since we reposition individual elements via `Infinity_SetArea`)
- `.menu` DSL `handle` element: `actionDrag` callback, engine sets `motionX`/`motionY` globals per frame

## Files Changed

- `buffbot/BfBotUI.lua` — new drag/resize functions, modified _Layout(), _LoadLayout()/_SaveLayout()
- `buffbot/BuffBot.menu` — two handle elements, reset button
- `buffbot/BfBotTst.lua` — unit tests for clamp logic, min size enforcement
