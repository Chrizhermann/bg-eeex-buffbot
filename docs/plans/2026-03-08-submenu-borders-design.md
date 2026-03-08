# Sub-Menu Parchment + Border Design

**Goal:** Apply the same leather+brass border and parchment background to all 4 popup sub-menus for visual consistency with the main panel.

**Approach:** Reuse existing assets (BFBOTBG.MOS, BFBOTFR.PVRZ, BuffBot_Border 9-slice rect). Add render hooks for each sub-menu's border label. No new MOS/PVRZ files needed — the PVRZs are already loaded when the main panel is open.

## Sub-Menus

| Menu | Current Size | Border Pad | Content |
|------|-------------|------------|---------|
| BUFFBOT_TARGETS | 160x290 | 24px | Target picker buttons |
| BUFFBOT_RENAME | 260x90 | 24px | Text input + OK/Cancel |
| BUFFBOT_SPELLPICKER | 400x380 | 24px | Spell list + Add/Cancel |
| BUFFBOT_IMPORT | 320x300 | 24px | Config list + Import/Cancel |

## Changes Per Menu

1. Insert bare named `label` (border hook) BEFORE background label
2. Replace `rectangle 5` + `rectangle opacity 200` with `mosaic "BFBOTBG"`
3. Register `BeforeUIItemRenderListener` for each border label → `DrawSlicedRect("BuffBot_Border", ...)`
4. Update text colors to dark browns (`{50, 30, 10}`) and text styles to `normal_parchment`

## Border label naming convention

- `bbTgtFrame` — BUFFBOT_TARGETS
- `bbRenFrame` — BUFFBOT_RENAME
- `bbPickFrame` — BUFFBOT_SPELLPICKER
- `bbImpFrame` — BUFFBOT_IMPORT
