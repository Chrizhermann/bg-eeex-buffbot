# Custom Panel Border Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace BuffBot's plain `rectangle 5` engine border with a custom leather+brass stud 9-slice border using EEex's `RegisterSlicedRect`/`DrawSlicedRect` system.

**Architecture:** Extract border strips from an AI-generated leather+brass image, assemble into a 128x128 PVRZ texture with 9-slice regions (4 corners, 4 edges, 1 center), register with EEex's sliced rect system, and render via a `BeforeUIItemRenderListener` hook on the existing `bbBgFrame` label element. The parchment MOS stays inside; the border wraps around it.

**Tech Stack:** Python 3 + Pillow (image extraction + DXT5 PVRZ conversion), Lua (EEex 9-slice API), .menu DSL (Infinity Engine UI)

---

### Task 1: Create Border Extraction Tool

**Files:**
- Create: `tools/extract_border.py`

This Python script extracts border strips from the AI-generated leather+brass image, assembles them into a 128x128 PVRZ-ready texture, and writes the PVRZ file. It reuses the DXT5 compression functions from `tools/img_to_mos.py`.

**Step 1: Create `tools/extract_border.py`**

```python
#!/usr/bin/env python3
"""Extract border strips from a leather+brass image and create a 9-slice PVRZ texture.

Usage: python3 tools/extract_border.py <source_image> <output_pvrz>

Example:
    python3 tools/extract_border.py leather_border.png buffbot/BFBOTFR.PVRZ

The source image should have a dark leather border with brass corner studs.
The script extracts corner and edge regions, scales them to fit a 128x128
9-slice texture layout, and creates a PVRZ file (DXT5 compressed).

9-slice texture layout (128x128):
+--------+--------+--------+
| TL     | Top    | TR     |  32px tall
| 32x32  | 64x32  | 32x32  |
+--------+--------+--------+
| Left   | Center | Right  |  64px tall
| 32x64  | 64x64  | 32x64  |
+--------+--------+--------+
| BL     | Bottom | BR     |  32px tall
| 32x32  | 64x32  | 32x32  |
+--------+--------+--------+
"""

import struct
import sys
import zlib

from PIL import Image


# --- DXT5 compression (reused from img_to_mos.py) ---

def rgb_to_565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)

def rgb565_to_rgb(c):
    r = ((c >> 11) & 0x1F) * 255 // 31
    g = ((c >> 5) & 0x3F) * 255 // 63
    b = (c & 0x1F) * 255 // 31
    return r, g, b

def color_distance(c1, c2):
    return (c1[0]-c2[0])**2 + (c1[1]-c2[1])**2 + (c1[2]-c2[2])**2

def compress_dxt5_block(pixels_rgba):
    alphas = [p[3] for p in pixels_rgba]
    alpha0 = max(alphas)
    alpha1 = min(alphas)

    if alpha0 == alpha1:
        alpha_bytes = struct.pack('<BB', alpha0, alpha1) + b'\x00\x00\x00\x00\x00\x00'
    else:
        if alpha0 <= alpha1:
            alpha0, alpha1 = max(alpha0, alpha1 + 1), min(alpha0, alpha1)
        interp = [alpha0, alpha1]
        for i in range(6):
            interp.append(((6 - i) * alpha0 + (1 + i) * alpha1 + 3) // 7)
        alpha_idx = []
        for a in alphas:
            best = 0
            best_d = abs(a - interp[0])
            for j in range(1, 8):
                d = abs(a - interp[j])
                if d < best_d:
                    best_d = d
                    best = j
            alpha_idx.append(best)
        bits = 0
        for i in range(16):
            bits |= (alpha_idx[i] & 0x7) << (i * 3)
        alpha_bytes = struct.pack('<BB', alpha0, alpha1)
        alpha_bytes += struct.pack('<HI', bits & 0xFFFF, (bits >> 16) & 0xFFFFFFFF)

    rgbs = [(p[0], p[1], p[2]) for p in pixels_rgba]
    min_c = min(rgbs, key=lambda c: c[0]*0.3 + c[1]*0.6 + c[2]*0.1)
    max_c = max(rgbs, key=lambda c: c[0]*0.3 + c[1]*0.6 + c[2]*0.1)
    color0 = rgb_to_565(*max_c)
    color1 = rgb_to_565(*min_c)
    if color0 < color1:
        color0, color1 = color1, color0
        max_c, min_c = min_c, max_c
    elif color0 == color1:
        if color0 < 0xFFFF:
            color0 += 1
        else:
            color1 -= 1
    c0 = rgb565_to_rgb(color0)
    c1 = rgb565_to_rgb(color1)
    palette = [
        c0, c1,
        tuple((2 * c0[i] + c1[i] + 1) // 3 for i in range(3)),
        tuple((c0[i] + 2 * c1[i] + 1) // 3 for i in range(3)),
    ]
    indices = 0
    for i in range(16):
        best = 0
        best_d = color_distance(rgbs[i], palette[0])
        for j in range(1, 4):
            d = color_distance(rgbs[i], palette[j])
            if d < best_d:
                best_d = d
                best = j
        indices |= (best << (i * 2))
    color_bytes = struct.pack('<HHI', color0, color1, indices)
    return alpha_bytes + color_bytes


def compress_image_dxt5(img):
    w, h = img.size
    assert w % 4 == 0 and h % 4 == 0, f"Dimensions must be multiple of 4, got {w}x{h}"
    pixels = list(img.getdata())
    data = bytearray()
    for by in range(h // 4):
        for bx in range(w // 4):
            block = []
            for dy in range(4):
                for dx in range(4):
                    px = (by * 4 + dy) * w + (bx * 4 + dx)
                    block.append(pixels[px])
            data += compress_dxt5_block(block)
    return bytes(data)


def create_pvrz(img):
    w, h = img.size
    dxt_data = compress_image_dxt5(img)
    pvr3 = struct.pack('<I', 0x03525650)    # version
    pvr3 += struct.pack('<I', 0)             # flags
    pvr3 += struct.pack('<Q', 11)            # DXT5
    pvr3 += struct.pack('<I', 0)             # color space
    pvr3 += struct.pack('<I', 0)             # channel type
    pvr3 += struct.pack('<I', h)             # height
    pvr3 += struct.pack('<I', w)             # width
    pvr3 += struct.pack('<I', 1)             # depth
    pvr3 += struct.pack('<I', 1)             # numSurfaces
    pvr3 += struct.pack('<I', 1)             # numFaces
    pvr3 += struct.pack('<I', 1)             # mipMapCount
    pvr3 += struct.pack('<I', 0)             # metaDataSize
    uncompressed = pvr3 + dxt_data
    compressed = zlib.compress(uncompressed, 9)
    return struct.pack('<I', len(uncompressed)) + compressed


# --- Border extraction ---

def extract_border_regions(img):
    """Extract 9-slice regions from a leather+brass border image.

    The source image is assumed to have a dark leather border around a lighter
    parchment center. We extract:
    - 4 corners (with brass studs) from image corners
    - 4 edge strips from mid-edge positions
    - 1 center fill (dark leather)

    Returns dict mapping region name to PIL Image (RGBA).
    """
    w, h = img.size

    # Estimate border width (~5-6% of image dimensions)
    border_w = int(w * 0.055)
    border_h = int(h * 0.065)
    print(f"  Source: {w}x{h}, estimated border: {border_w}x{border_h}px")

    # Corner regions: square from each corner
    corner_size_x = border_w + 20  # grab a bit extra
    corner_size_y = border_h + 20

    tl = img.crop((0, 0, corner_size_x, corner_size_y))
    tr = img.crop((w - corner_size_x, 0, w, corner_size_y))
    bl = img.crop((0, h - corner_size_y, corner_size_x, h))
    br = img.crop((w - corner_size_x, h - corner_size_y, w, h))

    # Edge strips: mid-section of each border
    mid_x = w // 2
    mid_y = h // 2
    edge_len = int(min(w, h) * 0.15)  # length of edge strip to sample

    top    = img.crop((mid_x - edge_len, 0, mid_x + edge_len, border_h))
    bottom = img.crop((mid_x - edge_len, h - border_h, mid_x + edge_len, h))
    left   = img.crop((0, mid_y - edge_len, border_w, mid_y + edge_len))
    right  = img.crop((w - border_w, mid_y - edge_len, w, mid_y + edge_len))

    # Center: small patch from the border area (dark leather)
    cx = border_w // 2
    cy = border_h // 2
    center = img.crop((cx, cy, cx + 100, cy + 100))

    return {
        'topLeft': tl, 'topRight': tr,
        'bottomLeft': bl, 'bottomRight': br,
        'top': top, 'bottom': bottom,
        'left': left, 'right': right,
        'center': center,
    }


def assemble_9slice(regions):
    """Assemble extracted regions into a 128x128 9-slice texture.

    Layout:
    +--------+--------+--------+
    | TL     | Top    | TR     |  32px tall
    | 32x32  | 64x32  | 32x32  |
    +--------+--------+--------+
    | Left   | Center | Right  |  64px tall
    | 32x64  | 64x64  | 32x64  |
    +--------+--------+--------+
    | BL     | Bottom | BR     |  32px tall
    | 32x32  | 64x32  | 32x32  |
    +--------+--------+--------+
    """
    tex = Image.new('RGBA', (128, 128), (40, 30, 20, 255))

    # Scale and paste each region
    tex.paste(regions['topLeft'].resize((32, 32), Image.LANCZOS), (0, 0))
    tex.paste(regions['top'].resize((64, 32), Image.LANCZOS), (32, 0))
    tex.paste(regions['topRight'].resize((32, 32), Image.LANCZOS), (96, 0))

    tex.paste(regions['left'].resize((32, 64), Image.LANCZOS), (0, 32))
    tex.paste(regions['center'].resize((64, 64), Image.LANCZOS), (32, 32))
    tex.paste(regions['right'].resize((32, 64), Image.LANCZOS), (96, 32))

    tex.paste(regions['bottomLeft'].resize((32, 32), Image.LANCZOS), (0, 96))
    tex.paste(regions['bottom'].resize((64, 32), Image.LANCZOS), (32, 96))
    tex.paste(regions['bottomRight'].resize((32, 32), Image.LANCZOS), (96, 96))

    return tex


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <source_image> <output_pvrz>")
        print(f"Optional: {sys.argv[0]} <source_image> <output_pvrz> --preview <preview.png>")
        sys.exit(1)

    source_path = sys.argv[1]
    output_path = sys.argv[2]
    preview_path = None
    if len(sys.argv) > 4 and sys.argv[3] == '--preview':
        preview_path = sys.argv[4]

    print(f"Loading source: {source_path}")
    img = Image.open(source_path).convert('RGBA')

    print("Extracting border regions...")
    regions = extract_border_regions(img)

    print("Assembling 128x128 9-slice texture...")
    tex = assemble_9slice(regions)

    if preview_path:
        tex.save(preview_path)
        print(f"Preview saved: {preview_path}")

    print("Compressing to PVRZ (DXT5)...")
    pvrz_data = create_pvrz(tex)

    with open(output_path, 'wb') as f:
        f.write(pvrz_data)
    print(f"Written: {output_path} ({len(pvrz_data)} bytes)")


if __name__ == '__main__':
    main()
```

**Step 2: Commit**

```bash
git add tools/extract_border.py
git commit -m "feat(tools): add 9-slice border extractor for custom panel frame"
```

---

### Task 2: Generate Border PVRZ from AI Image

**Files:**
- Read: `tools/extract_border.py` (from Task 1)
- Source image: `C:/Users/chris/Downloads/Generated Image March 08, 2026 - 5_18PM.png`
- Create: `buffbot/BFBOTFR.PVRZ`

**Step 1: Run the extractor with preview**

```bash
python3 tools/extract_border.py \
    "C:/Users/chris/Downloads/Generated Image March 08, 2026 - 5_18PM.png" \
    buffbot/BFBOTFR.PVRZ \
    --preview /tmp/border_preview.png
```

Expected output:
```
Loading source: ...
  Source: 5504x3072, estimated border: 302x199px
Extracting border regions...
Assembling 128x128 9-slice texture...
Preview saved: /tmp/border_preview.png
Compressing to PVRZ (DXT5)...
Written: buffbot/BFBOTFR.PVRZ (NNN bytes)
```

**Step 2: Visually inspect the preview**

Open `/tmp/border_preview.png` and verify:
- 4 corners show brass studs on dark leather
- Edges show leather texture + stitching
- Center is dark leather fill
- No weird artifacts or misaligned regions

**If preview looks bad:** Adjust border estimates in `extract_border_regions()` (tweak `border_w`/`border_h` percentages or corner sizes) and re-run. If the source image fundamentally doesn't extract well, fall back to generating a procedural leather texture.

**Step 3: Commit**

```bash
git add buffbot/BFBOTFR.PVRZ
git commit -m "asset: add leather+brass 9-slice border PVRZ texture"
```

---

### Task 3: Integrate 9-Slice Border in Lua

**Files:**
- Modify: `buffbot/BfBotUI.lua:87-117` (_OnMenusLoaded — add registration + render hook)
- Modify: `buffbot/BfBotUI.lua:140-153` (_Layout — offset border frame)

**Step 1: Add 9-slice registration and render hook in `_OnMenusLoaded`**

In `buffbot/BfBotUI.lua`, after line 116 (`BfBot.UI._initialized = true`), add the 9-slice registration and render hook. Actually, the registration should happen BEFORE the menu is loaded (so it's available when the menu renders). Add it right after `EEex_Menu_LoadFile("BuffBot")` (line 89):

Find this block (lines 87-89):
```lua
function BfBot.UI._OnMenusLoaded()
    -- Load our .menu definitions
    EEex_Menu_LoadFile("BuffBot")
```

After `EEex_Menu_LoadFile("BuffBot")` (line 89), insert:

```lua

    -- Register 9-slice border texture for custom panel frame
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

    -- Render hook: draw 9-slice border instead of engine rectangle
    EEex_Menu_AddBeforeUIItemRenderListener("bbBgFrame", function(item)
        EEex.DrawSlicedRect("BuffBot_Border", { item:getArea() })
    end)
```

**Step 2: Adjust `_Layout` to offset the border frame**

The border frame (`bbBgFrame`) should be slightly larger than the parchment background (`bbBg`) to create the border overhang effect. The border extends 24px on each side.

Find these lines in `_Layout()` (lines 151-153):
```lua
    -- Panel background (parchment + frame)
    Infinity_SetArea("bbBg", px, py, pw, ph)
    Infinity_SetArea("bbBgFrame", px, py, pw, ph)
```

Replace with:
```lua
    -- Panel background (parchment inside, border frame extends 24px beyond)
    Infinity_SetArea("bbBg", px, py, pw, ph)
    local bpad = 24  -- border overhang in pixels
    Infinity_SetArea("bbBgFrame", px - bpad, py - bpad, pw + 2 * bpad, ph + 2 * bpad)
```

**Step 3: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): register 9-slice border and render via EEex hook"
```

---

### Task 4: Update Menu to Use Empty Label for Border

**Files:**
- Modify: `buffbot/BuffBot.menu:56-64` (bbBgFrame label)

**Step 1: Strip rectangle properties from `bbBgFrame`**

The `bbBgFrame` label no longer needs `rectangle` properties — the 9-slice render hook draws the border instead.

Find this block in `BuffBot.menu` (lines 56-64):
```
	-- Panel border (engine-drawn frame on top of parchment)
	label
	{
		name    "bbBgFrame"
		enabled "buffbot_isOpen"
		area 340 50 540 510
		rectangle 5
		rectangle opacity 1
	}
```

Replace with:
```
	-- Panel border (custom 9-slice leather+brass frame via EEex render hook)
	label
	{
		name    "bbBgFrame"
		enabled "buffbot_isOpen"
		area 340 50 540 510
	}
```

**Step 2: Commit**

```bash
git add buffbot/BuffBot.menu
git commit -m "feat(menu): switch bbBgFrame to empty label for 9-slice rendering"
```

---

### Task 5: Update Deploy Script for PVRZ Files

**Files:**
- Modify: `tools/deploy.sh:38-41` (asset copy section)

**Step 1: Add PVRZ file copy glob**

After the MOS copy block (lines 38-41 of `tools/deploy.sh`):

```bash
# Copy asset files (MOS backgrounds, etc.)
for f in "$SRC_DIR"/*.MOS; do
    [ -f "$f" ] && cp "$f" "$OVERRIDE_DIR/$(basename "$f")"
done
```

Add:
```bash
# Copy PVRZ textures (9-slice borders, etc.)
for f in "$SRC_DIR"/*.PVRZ; do
    [ -f "$f" ] && cp "$f" "$OVERRIDE_DIR/$(basename "$f")"
done
```

**Step 2: Commit**

```bash
git add tools/deploy.sh
git commit -m "build(deploy): add PVRZ texture copy to deploy script"
```

---

### Task 6: Deploy and Verify In-Game

**Step 1: Deploy to game**

```bash
bash tools/deploy.sh
```

Verify output includes `BFBOTFR.PVRZ` being copied.

**Step 2: Launch game and test**

1. Launch game via InfinityLoader.exe
2. Load a save game
3. Press F11 to open BuffBot panel
4. Verify:
   - Leather+brass border renders around the parchment panel
   - Corners show brass studs (4 corners, not stretched)
   - Edges show leather texture (stretched to fill horizontal/vertical gaps)
   - Border extends ~24px beyond the parchment on all sides
   - Parchment background still shows inside the border
   - All text remains readable (dark on parchment)
   - All buttons and interactions still work
   - Panel resizes correctly at different resolutions

**Step 3: If border doesn't render or crashes**

Troubleshoot in EEex console:
```lua
-- Check if PVRZ loaded:
Infinity_DisplayString(tostring(EEex.RegisterSlicedRect))
-- Check if render hook fires:
BfBot.UI._RenderBorder = function(item) Infinity_DisplayString("border render called") end
```

If PVRZ not found: verify file is in override directory and resref matches (case-sensitive: `BFBOTFR`).

**Step 4: If border looks bad (wrong proportions, artifacts)**

Re-run the extractor with adjusted parameters or generate a procedural fallback. The 9-slice registration and render hook code stays the same — only the PVRZ file changes.

---

## Task Dependencies

```
Task 1 (Python tool) → Task 2 (Generate PVRZ) → Task 3 (Lua integration)
                                                  Task 4 (Menu update)     → Task 6 (Deploy+Test)
                                                  Task 5 (Deploy script)
```

Tasks 3, 4, 5 are independent of each other but all depend on Task 2.
Task 6 depends on all previous tasks.
