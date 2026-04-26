# Panel Style / Theme Customization — Design

**Issue:** #32
**Status:** Design (pending implementation)
**Baseline:** v1.3.12-alpha

## Problem

BuffBot's parchment + leather panel style is too bright for some users. Extended play sessions and varied ambient lighting call for a way to change the panel appearance. The rename preset input also had readability issues on parchment (already patched with a hardcoded dark color in `0acd85f`; this design migrates that fix into the theme system).

## Goals

- Let users switch between visually distinct panel themes, each evoking one of the three BG campaigns (BG2, SOD, BG1)
- Support a Dark Mode toggle layered on top of each theme
- Support text size scaling for readability
- All text rendered by BuffBot must respect the active theme (no unthemed elements)
- Settings surfaced in EEex's existing Options menu (familiar location for users)
- Settings persist across sessions via `baldur.ini`
- Live switching — no game restart required

## Non-Goals

- Full per-element color customization (color picker)
- Custom font face selection (engine only supports predefined fonts)
- Themes for EEex-owned UI (actionbar, spellbook) — out of scope
- Animation/transition effects between theme changes

## Current State Inventory

### Color sources (BuffBot.menu — line numbers per v1.3.12-alpha)

| Location | Hardcoded value | Semantic role |
|---|---|---|
| Line 80 | `{50, 30, 10}` | Panel title |
| Line 100 | `{120, 100, 70}` | Resize grip |
| Line 121 | `{180, 160, 130}` | Reset button |
| Line 813 | `{120, 90, 20}` | Target picker header |
| Line 824 | `{150, 120, 80}` | Lock state text |
| Line 1093 | `{50, 30, 10}` | Rename label |
| Line 1104 | `{50, 30, 10}` | Rename edit field (from `0acd85f`) |
| Line 1170 | `{50, 30, 10}` | Import header |
| Line 1295 | `{50, 30, 10}` | Export/config header |
| Line 1385 | `{50, 30, 10}` | Variant header |

### Color functions (BfBotUI.lua)

| Function | Branches | Values |
|---|---|---|
| `_SpellNameColor` | 5 | default `{50,30,10}`, unavailable `{140,130,120}`, override `{40,80,160}`, locked `{100,70,20}`, fallback `{50,30,10}` |
| `_PickerRowColor` | 3 | selected `{255,255,150}`, checked `{220,220,220}`, unchecked `{140,140,140}` |
| `_QuickCastColor` | 3 | off `{80,60,40}`, long `{160,120,20}`, all `{180,60,30}` |
| `_LockColor` | 2 | locked `{230,200,60}`, unlocked `{120,100,80}` |

### Text styles used

`title`, `button`, `normal`, `normal_parchment`, `edit` — 5 engine styles, ~65 element references.

### Assets

- **Background**: `BFBOTBG.MOS` generated at runtime by `_GenerateBgMOS()` from 4 PVRZ tiles (MOS9900-9903, leather+brass parchment)
- **Border**: `BFBOTFR.PVRZ` 512x512 leather+brass frame rendered via 9-slice (`RegisterSlicedRect` + `DrawSlicedRect`)

## Approach

### Three game-themed palettes × two modes = six themes

| Theme | Background | Border | Text palette |
|---|---|---|---|
| **BG2** (current) | Warm parchment | Ornate gold/leather vines | Dark brown on light |
| **SOD** | Dark blue-teal | Steel/angular riveted | Cool tones |
| **BG1** | Dark crimson/mahogany | Dark copper/wood gothic | Warm muted tones |

Each palette has a Light and Dark variant. Dark mode is implemented as a **dark rectangle overlay** between the background MOS and the panel content (opacity ~160); no alternate dark backgrounds needed.

### Theme data structure

A flat palette table per theme combination, six total. The `_T(key)` accessor reads from the active palette with a magenta fallback for missing keys (debug visibility during development).

Semantic keys defined (19 total):
- `overlay` (rectangle opacity 0-255, 0 = no darkening)
- `borderResref` (PVRZ file: BFBOTFR / BFBOTFR2 / BFBOTFR3)
- `bgResref` (background MOS identifier — drives `_GenerateBgMOS` tile selection)
- `title`, `text`, `textMuted`, `textAccent` (general text palette)
- `grip`, `reset`, `headerSub`, `lockText` (specific menu regions)
- `spellLocked` (warm tint for locked rows — replaces hardcoded `{100,70,20}`)
- `pickerSel`, `pickerOn`, `pickerOff` (target picker rows)
- `qcOff`, `qcLong`, `qcAll` (QuickCast colors)
- `lockActive`, `lockInactive` (lock column `[L]`/`[ ]` colors)

### Three settings in EEex Options tab

1. **Dark Mode** — toggle (off/on)
2. **Color Scheme** — dropdown (BG2 / SOD / BG1)
3. **Text Size** — dropdown (Small / Medium / Large)

Settings are composed into a composite palette key (e.g., `sod_dark`) stored in `baldur.ini` as `Theme=sod_dark`. Font size stored separately as `FontSize=2`.

## Component Architecture

### New module: BfBotThm.lua

- `BfBot.Theme._palettes` — 6 palette tables
- `BfBot.Theme._active` — reference to current palette
- `BfBot.Theme.Apply(paletteName)` — swap active palette, refresh styles, save to INI
- `BfBot.Theme._RefreshStyles()` — rebuild `bb_*` custom text styles with current point size and color
- `BfBot.Theme._GetDarkMode()`, `_SetDarkMode(bool)` — toggle dark/light within current accent
- `BfBot.Theme._GetAccent()`, `_SetAccent(idx)` — change accent, preserving dark/light mode
- `BfBot.Theme._GetFontSize()`, `_SetFontSize(1-3)` — change size, refresh styles
- `BfBot.UI._T(key)` — accessor for use in .menu `text color lua` expressions

### Custom text styles

Register at init by deep-copying existing engine styles:
- `bb_normal` ← `normal`
- `bb_button` ← `button`
- `bb_title` ← `title`
- `bb_normal_parchment` ← `normal_parchment`
- `bb_edit` ← `edit`

These styles get their `point` size scaled by font size multiplier (0.85 / 1.0 / 1.20) and their default color overridden per theme. All references in BuffBot.menu migrate from engine style names to `bb_*` style names.

### Menu changes

- **All hardcoded `text color lua "{R,G,B}"`** → `text color lua "BfBot.UI._T('keyName')"` (10 locations)
- **All 4 color functions** now read from `BfBot.Theme._active` instead of hardcoded returns
- **All `text style "xxx"`** → `text style "bb_xxx"` (~65 locations)
- **New overlay labels** added to BUFFBOT_MAIN and 5 sub-menus (rename, target picker, spell picker, import, variant)

### Border rendering changes

Register 3 `SlicedRect` instances at init, one per accent:
- `BuffBot_Border_BFBOTFR` (BG2 default)
- `BuffBot_Border_BFBOTFR2` (SOD)
- `BuffBot_Border_BFBOTFR3` (BG1)

The `BeforeUIItemRenderListener` for the 6 border labels (`bbBgFrame`, `bbTgtFrame`, etc.) reads the active theme's `borderResref` and draws the matching sliced rect.

### Background MOS generation

`_GenerateBgMOS()` already generates a resolution-appropriate MOS from PVRZ tiles. Extend it to accept a theme parameter that selects tile sources:
- BG2: current MOS9900-9903 tiles
- SOD: new tiles (generated from `sod_background.png`)
- BG1: new tiles (generated from `bg1_background.png`)

On theme change, regenerate the MOS with new tiles.

## Assets

Four new source images in `assets/themes/` (already added):
- `sod_background.png` — dark blue-teal seamless texture
- `sod_border.png` — steel/angular decorative frame
- `bg1_background.png` — dark crimson seamless texture
- `bg1_border.png` — dark copper/wood decorative frame

### PVRZ conversion pipeline

New tool `tools/png_to_pvrz.py`:
1. Read PNG via Pillow
2. Resize borders to exactly 512x512 if needed
3. For backgrounds: slice into 1024x1024 + 1024x128 blocks matching MOS tile layout
4. Encode each block to DXT5
5. Wrap with PVR3 header + zlib compress
6. Write `.PVRZ` files to `buffbot/data/`

Resulting PVRZ files committed to repo so installer doesn't need Python.

### Installer changes

`setup-buffbot.tp2` copies the new PVRZ files alongside existing BG2 assets:
- `BFBOTBG2.PVRZ` (SOD background)
- `BFBOTFR2.PVRZ` (SOD border)
- `BFBOTBG3.PVRZ` (BG1 background)
- `BFBOTFR3.PVRZ` (BG1 border)

## Persistence

New INI keys under `[BuffBot]`:

| Key | Values | Default |
|---|---|---|
| `Theme` | `bg2_light` / `bg2_dark` / `sod_light` / `sod_dark` / `bg1_light` / `bg1_dark` | `bg2_light` |
| `FontSize` | `1` / `2` / `3` | `2` |

`BfBot.Persist._INI_DEFAULTS` extended with both keys. Default `bg2_light` preserves current appearance for all existing users. No migration needed.

## EEex Options Integration

Register a `"BuffBot"` tab via `EEex_Options_AddTab()` at init. The tab exposes three controls:

```lua
EEex_Options_AddTab("BuffBot", function()
    return {
        { type = "toggle",   label = "Dark Mode", ... },
        { type = "dropdown", label = "Color Scheme", options = {"BG2 (Parchment)", "SOD (Steel)", "BG1 (Crimson)"}, ... },
        { type = "dropdown", label = "Text Size", options = {"Small", "Medium", "Large"}, ... },
    }
end)
```

Exact `EEex_Options_Register` API shape will be verified against `EEex_Options.lua` during implementation.

## Live Switching

Colors are polled every frame via `_T()` — they update automatically on palette swap. Styles require explicit refresh via `_RefreshStyles()` (mutating the global `styles` table). Background MOS needs regeneration (same path as the existing resolution-change handler). Borders auto-update because the render hook reads `_T('borderResref')` every frame.

No panel reload required. Visible within one frame.

## Testing

### Unit tests (BfBotTst.lua — new phase `BfBot.Test.Theming()`)

- `_T()` returns valid color for every known key across all 6 palettes
- `Apply(paletteName)` mutates `_active` correctly
- `_SetDarkMode` toggles between light/dark variants while preserving accent
- `_SetAccent(idx)` changes accent while preserving dark/light
- `_SetFontSize(n)` updates style points correctly
- Unknown palette key returns magenta sentinel (no crash)
- INI round-trip: save theme, reload, `_active` matches

### In-game verification checklist

- [ ] All 6 theme combinations render without magenta debug colors
- [ ] BG2 theme matches current v1.3.12 appearance pixel-perfect
- [ ] SOD theme shows steel border + blue-teal background
- [ ] BG1 theme shows copper/wood border + crimson background
- [ ] Dark mode overlay applies to main panel AND all 5 sub-menus
- [ ] Text remains readable in all 6 themes (no white-on-white, no black-on-black)
- [ ] Rename input readable in all themes
- [ ] Text size changes visibly affect all buttons, labels, lists
- [ ] Theme change takes effect immediately without panel reload
- [ ] EEex Options tab shows 3 controls with correct current values
- [ ] Settings persist across game restart
- [ ] Resolution change mid-session preserves theme

## Open Implementation Questions

1. **Exact `EEex_Options_Register` API shape** — toggle/dropdown constructors need verification against `EEex_Options.lua` source
2. **Background seamlessness** — AI-generated backgrounds may show tile seams when tiled; decide during implementation whether to run through a seamless-blending tool

## Out of Scope / Future Work

- Custom user-defined palettes beyond the 6 presets
- Per-sub-menu theme overrides
- Font face selection (engine limitation)
- Animation/fade transitions between themes

## Risks

- **Style refresh timing**: mutating `styles[name].point` mid-frame may cause one frame of mis-sized text (acceptable)
- **MOS regeneration cost**: ~50ms on theme change due to PVRZ decode + re-encode; only runs on theme change, not per-frame
- **9-slice rendering for new borders**: AI-generated borders may have non-symmetric corners that look odd when stretched; mitigate by verifying 128-pixel border-width symmetry before converting to PVRZ
