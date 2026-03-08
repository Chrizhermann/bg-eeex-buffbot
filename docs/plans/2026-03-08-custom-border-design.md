# Custom Panel Border Design

## Summary

Replace BuffBot's plain `rectangle 5` engine border with a custom leather+brass stud 9-slice border using EEex's `RegisterSlicedRect`/`DrawSlicedRect` system. The parchment MOS background stays inside; the border wraps around it.

## Problem

The current `rectangle 5` border is a thin engine-drawn procedural frame. It looks generic and doesn't match the BG2 aesthetic. The parchment background texture is already working well, but the border cheapens the overall look.

## Solution

Use EEex's 9-slice rendering system to draw a custom border frame from a PVRZ texture. This is the same system EEex uses for its own options panel (`X-OPTBOX.PVRZ` + `EEex.RegisterSlicedRect`).

### Source Material

Extract border strips from the first AI-generated leather+brass image (`Generated Image March 08, 2026 - 5_18PM.png`, 5504x3072). The image has a dark leather border with brass corner studs and stitching detail.

### 9-Slice System

The PVRZ texture contains 9 regions:
- 4 corners (fixed size, no stretch)
- 4 edges (stretch along one axis)
- 1 center (stretch both axes, but we won't use it — parchment MOS fills the interior)

Each region is defined by pixel coordinates in the `RegisterSlicedRect` call.

### Architecture

1. **Python extractor** (`tools/extract_border.py`) — crops border strips from the source image, assembles a 128x128 PVRZ-ready texture with 9-slice regions, converts to DXT5 PVRZ format
2. **PVRZ file** — `BFBOTFR.PVRZ` (single 128x128 page, ~2KB compressed) deployed to game override
3. **Lua registration** — `EEex.RegisterSlicedRect("BuffBot_Border", {...})` in `BfBotUI.lua` during init
4. **Render hook** — `EEex_Menu_AddBeforeUIItemRenderListener` on the `bbBgFrame` label element
5. **Menu change** — `bbBgFrame` becomes an empty label (remove `rectangle` properties), sized slightly larger than `bbBg` to create the border overhang

### Layout

```
Panel area at 80% screen:     parchment MOS (bbBg)
Border area at ~83% screen:   9-slice border (bbBgFrame)
Border overhang:              ~24px per side
```

The border frame element is 48px wider and taller than the parchment, offset by -24px on each side.

### PVRZ Texture Layout (128x128)

```
+--------+--------+--------+
| TL     | Top    | TR     |  (32px tall)
| 32x32  | 64x32  | 32x32  |
+--------+--------+--------+
| Left   | Center | Right  |  (64px tall)
| 32x64  | 64x64  | 32x64  |
+--------+--------+--------+
| BL     | Bottom | BR     |  (32px tall)
| 32x32  | 64x32  | 32x32  |
+--------+--------+--------+
```

Corners include brass studs. Edges show leather texture + stitching. Center can be transparent/dark (not rendered — parchment fills interior).

### Registration Call

```lua
EEex.RegisterSlicedRect("BuffBot_Border", {
    ["topLeft"]     = {  0,  0, 32, 32 },
    ["top"]         = { 32,  0, 64, 32 },
    ["topRight"]    = { 96,  0, 32, 32 },
    ["right"]       = { 96, 32, 32, 64 },
    ["bottomRight"] = { 96, 96, 32, 32 },
    ["bottom"]      = { 32, 96, 64, 32 },
    ["bottomLeft"]  = {  0, 96, 32, 32 },
    ["left"]        = {  0, 32, 32, 64 },
    ["center"]      = { 32, 32, 64, 64 },
    ["dimensions"]  = { 128, 128 },
    ["resref"]      = "BFBOTFR",
    ["flags"]       = 0,
})
```

### Render Hook

```lua
function BfBot.UI._RenderBorder(item)
    EEex.DrawSlicedRect("BuffBot_Border", { item:getArea() })
end

EEex_Menu_AddBeforeUIItemRenderListener("bbBgFrame", BfBot.UI._RenderBorder)
```

### Deploy

`tools/deploy.sh` already copies `*.MOS` from `buffbot/`. Add PVRZ copy:
```bash
for f in "$SRC_DIR"/*.PVRZ; do
    [ -f "$f" ] && cp "$f" "$OVERRIDE_DIR/$(basename "$f")"
done
```

### Fallback

If the extracted border looks bad (artifacts, wrong proportions), generate a new clean border texture from scratch using Python (procedural leather + brass circles). The 9-slice integration code stays the same — only the texture content changes.

## Files Changed

- Create: `tools/extract_border.py` — border extraction + PVRZ conversion
- Create: `buffbot/BFBOTFR.PVRZ` — 9-slice border texture
- Modify: `buffbot/BfBotUI.lua` — register sliced rect, add render hook, adjust layout
- Modify: `buffbot/BuffBot.menu` — strip rectangle properties from bbBgFrame
- Modify: `tools/deploy.sh` — add PVRZ copy glob

## Success Criteria

- Border renders around the parchment panel at all supported resolutions
- Leather texture and brass studs visible in corners
- Border scales cleanly (edges stretch, corners don't)
- No visual artifacts or gaps between border and parchment
- Existing text readability preserved (dark text on parchment)
