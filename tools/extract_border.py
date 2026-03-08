#!/usr/bin/env python3
"""Extract border strips from a source image and create a 512x512 PVRZ texture
for EEex's 9-slice rendering system.

Usage:
    python3 tools/extract_border.py <source_image> <output_pvrz> [--preview <path>]

Example:
    python3 tools/extract_border.py border.png buffbot/BFBOTFR.PVRZ --preview preview.png

The 9-slice layout (512x512):
    +----------+----------+----------+
    | TL       | Top      | TR       |  128px tall
    | 128x128  | 256x128  | 128x128  |
    +----------+----------+----------+
    | Left     | Center   | Right    |  256px tall
    | 128x256  | 256x256  | 128x256  |  (center = transparent)
    +----------+----------+----------+
    | BL       | Bottom   | BR       |  128px tall
    | 128x128  | 256x128  | 128x128  |
    +----------+----------+----------+
"""

import argparse
import struct
import sys
import zlib

from PIL import Image


# ---------------------------------------------------------------------------
# DXT5 / PVRZ compression (copied from tools/img_to_mos.py)
# ---------------------------------------------------------------------------

def rgb_to_565(r, g, b):
    """Convert 8-bit RGB to 16-bit RGB565."""
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def rgb565_to_rgb(c):
    """Convert 16-bit RGB565 back to 8-bit RGB."""
    r = ((c >> 11) & 0x1F) * 255 // 31
    g = ((c >> 5) & 0x3F) * 255 // 63
    b = (c & 0x1F) * 255 // 31
    return r, g, b


def color_distance(c1, c2):
    return (c1[0]-c2[0])**2 + (c1[1]-c2[1])**2 + (c1[2]-c2[2])**2


def compress_dxt5_block(pixels_rgba):
    """Compress a 4x4 block of RGBA pixels to DXT5 (16 bytes).

    pixels_rgba: list of 16 (R, G, B, A) tuples, row-major order.
    Returns: 16 bytes.
    """
    # --- Alpha block (8 bytes) ---
    alphas = [p[3] for p in pixels_rgba]
    alpha0 = max(alphas)
    alpha1 = min(alphas)

    if alpha0 == alpha1:
        # All same alpha
        alpha_bytes = struct.pack('<BB', alpha0, alpha1) + b'\x00\x00\x00\x00\x00\x00'
    else:
        # 8-level interpolation (alpha0 > alpha1)
        if alpha0 <= alpha1:
            alpha0, alpha1 = max(alpha0, alpha1 + 1), min(alpha0, alpha1)

        # Generate interpolated alphas
        interp = [alpha0, alpha1]
        for i in range(6):
            interp.append(((6 - i) * alpha0 + (1 + i) * alpha1 + 3) // 7)

        # Find best index for each pixel
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

        # Pack 16 3-bit indices into 48 bits (6 bytes)
        bits = 0
        for i in range(16):
            bits |= (alpha_idx[i] & 0x7) << (i * 3)

        alpha_bytes = struct.pack('<BB', alpha0, alpha1)
        alpha_bytes += struct.pack('<HI', bits & 0xFFFF, (bits >> 16) & 0xFFFFFFFF)

    # --- Color block (8 bytes) ---
    rgbs = [(p[0], p[1], p[2]) for p in pixels_rgba]

    # Find min/max colors (by luminance)
    min_c = min(rgbs, key=lambda c: c[0]*0.3 + c[1]*0.6 + c[2]*0.1)
    max_c = max(rgbs, key=lambda c: c[0]*0.3 + c[1]*0.6 + c[2]*0.1)

    color0 = rgb_to_565(*max_c)
    color1 = rgb_to_565(*min_c)

    # Ensure color0 > color1 for 4-color mode
    if color0 < color1:
        color0, color1 = color1, color0
        max_c, min_c = min_c, max_c
    elif color0 == color1:
        # Nudge to avoid degenerate case
        if color0 < 0xFFFF:
            color0 += 1
        else:
            color1 -= 1

    # Generate 4 interpolated colors
    c0 = rgb565_to_rgb(color0)
    c1 = rgb565_to_rgb(color1)
    palette = [
        c0,
        c1,
        tuple((2 * c0[i] + c1[i] + 1) // 3 for i in range(3)),
        tuple((c0[i] + 2 * c1[i] + 1) // 3 for i in range(3)),
    ]

    # Find best index for each pixel
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
    """Compress a PIL Image to DXT5 data. Image must be RGBA, dimensions multiple of 4."""
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
    """Create a PVRZ file from a PIL Image (must be RGBA, dims multiple of 4)."""
    w, h = img.size

    # DXT5 compress
    dxt_data = compress_image_dxt5(img)

    # PVR3 header (52 bytes)
    pvr3 = struct.pack('<I', 0x03525650)    # version "PVR\x03"
    pvr3 += struct.pack('<I', 0)             # flags
    pvr3 += struct.pack('<Q', 11)            # pixel format = DXT5 (BC3)
    pvr3 += struct.pack('<I', 0)             # color space (linear)
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

    # PVRZ wrapper: uint32 uncompressed_size + zlib data
    pvrz = struct.pack('<I', len(uncompressed)) + compressed
    return pvrz


# ---------------------------------------------------------------------------
# Border extraction and 9-slice assembly
# ---------------------------------------------------------------------------

# 9-slice slot dimensions in the 512x512 output
CORNER = 128
EDGE = 256
TOTAL = 512  # CORNER + EDGE + CORNER = 512

# Border width estimates as fraction of source image dimensions
BORDER_X_FRAC = 0.055  # ~5.5% of width
BORDER_Y_FRAC = 0.065  # ~6.5% of height


def extract_border_regions(img):
    """Extract 9 regions from the source image for 9-slice assembly.

    Returns a dict with keys:
        tl, top, tr, left, center, right, bl, bottom, br
    Each value is a PIL Image crop from the source.
    """
    w, h = img.size
    bx = int(w * BORDER_X_FRAC)  # border width in pixels
    by = int(h * BORDER_Y_FRAC)  # border height in pixels

    print(f"Source: {w}x{h}, border estimate: {bx}px x {by}px")

    # Mid-point coordinates for edge strip sampling
    mid_x = w // 2
    mid_y = h // 2

    # Edge strip sample width — take a generous strip from the middle of each
    # edge so we get a representative section of the leather + stitching.
    # We use the same size as the border dimension for the "thin" axis,
    # and a larger sample for the "long" axis to capture texture variety.
    edge_sample_w = bx * 4  # horizontal sample width for top/bottom strips
    edge_sample_h = by * 4  # vertical sample height for left/right strips

    regions = {}

    # --- Corners (from image corners, include brass studs) ---
    regions['tl'] = img.crop((0, 0, bx, by))
    regions['tr'] = img.crop((w - bx, 0, w, by))
    regions['bl'] = img.crop((0, h - by, bx, h))
    regions['br'] = img.crop((w - bx, h - by, w, h))

    # --- Edge strips (from mid-edge positions) ---
    # Top edge: full border height, sampled from horizontal center
    top_x0 = mid_x - edge_sample_w // 2
    regions['top'] = img.crop((top_x0, 0, top_x0 + edge_sample_w, by))

    # Bottom edge
    regions['bottom'] = img.crop((top_x0, h - by, top_x0 + edge_sample_w, by + (h - by)))

    # Left edge: full border width, sampled from vertical center
    left_y0 = mid_y - edge_sample_h // 2
    regions['left'] = img.crop((0, left_y0, bx, left_y0 + edge_sample_h))

    # Right edge
    regions['right'] = img.crop((w - bx, left_y0, w, left_y0 + edge_sample_h))

    # --- Center (dark leather fill, sampled from image center) ---
    # Take a square sample from the center
    center_size = min(bx * 4, by * 4, w // 4, h // 4)
    cx0 = mid_x - center_size // 2
    cy0 = mid_y - center_size // 2
    regions['center'] = img.crop((cx0, cy0, cx0 + center_size, cy0 + center_size))

    for name, region in regions.items():
        rw, rh = region.size
        print(f"  {name:8s}: {rw}x{rh}")

    return regions


def assemble_9slice(regions):
    """Scale all regions to fit the 128x128 9-slice layout and paste them.

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

    Returns: 128x128 RGBA PIL Image.
    """
    # Start with fully transparent image
    output = Image.new('RGBA', (TOTAL, TOTAL), (0, 0, 0, 0))

    # Target sizes for each slot: (width, height)
    slot_sizes = {
        'tl':     (CORNER, CORNER),   # 128x128
        'top':    (EDGE,   CORNER),   # 256x128
        'tr':     (CORNER, CORNER),   # 128x128
        'left':   (CORNER, EDGE),     # 128x256
        'center': (EDGE,   EDGE),     # 256x256 (stays transparent)
        'right':  (CORNER, EDGE),     # 128x256
        'bl':     (CORNER, CORNER),   # 128x128
        'bottom': (EDGE,   CORNER),   # 256x128
        'br':     (CORNER, CORNER),   # 128x128
    }

    # Paste positions for each slot: (x, y)
    slot_positions = {
        'tl':     (0,                0),
        'top':    (CORNER,           0),
        'tr':     (CORNER + EDGE,    0),
        'left':   (0,                CORNER),
        'center': (CORNER,           CORNER),
        'right':  (CORNER + EDGE,    CORNER),
        'bl':     (0,                CORNER + EDGE),
        'bottom': (CORNER,           CORNER + EDGE),
        'br':     (CORNER + EDGE,    CORNER + EDGE),
    }

    for name in slot_sizes:
        if name == 'center':
            continue  # Leave center transparent — parchment MOS shows through
        target_w, target_h = slot_sizes[name]
        pos_x, pos_y = slot_positions[name]

        # Scale the extracted region to the target slot size
        scaled = regions[name].resize((target_w, target_h), Image.LANCZOS)
        output.paste(scaled, (pos_x, pos_y))

    return output


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Extract border strips from a source image and create '
                    'a 512x512 PVRZ texture for 9-slice rendering.')
    parser.add_argument('source_image',
                        help='Path to the source border image (PNG/JPG)')
    parser.add_argument('output_pvrz',
                        help='Path for the output PVRZ file')
    parser.add_argument('--preview', metavar='PATH', default=None,
                        help='Save a preview PNG of the 128x128 texture')
    args = parser.parse_args()

    # Load source image
    print(f"Loading: {args.source_image}")
    img = Image.open(args.source_image).convert('RGBA')
    print(f"  Size: {img.size[0]}x{img.size[1]}")

    # Extract border regions
    print("\nExtracting border regions...")
    regions = extract_border_regions(img)

    # Assemble 9-slice texture
    print("\nAssembling 512x512 9-slice texture...")
    texture = assemble_9slice(regions)
    print(f"  Output: {texture.size[0]}x{texture.size[1]}")

    # Optional preview
    if args.preview:
        texture.save(args.preview)
        print(f"\nPreview saved: {args.preview}")

    # Convert to PVRZ
    print("\nCompressing to PVRZ (DXT5)...")
    pvrz_data = create_pvrz(texture)

    with open(args.output_pvrz, 'wb') as f:
        f.write(pvrz_data)
    print(f"PVRZ written: {args.output_pvrz} ({len(pvrz_data)} bytes)")


if __name__ == '__main__':
    main()
