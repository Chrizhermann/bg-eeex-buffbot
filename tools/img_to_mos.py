#!/usr/bin/env python3
"""Convert a PNG/JPG/BMP image to MOS v2 + PVRZ files for BG:EE.

Usage: python3 tools/img_to_mos.py <input_image> <output_mos> <pvrz_dir> [page_start]

Example:
    python3 tools/img_to_mos.py parchment.png buffbot/BFBOTBG.MOS override/ 9900

Creates:
    buffbot/BFBOTBG.MOS          (MOS v2 header)
    override/MOS9900.PVRZ        (texture page 0)
    override/MOS9901.PVRZ        (texture page 1, if needed)
"""

import math
import struct
import sys
import zlib

from PIL import Image


# --- DXT5 compression (BC3) ---

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
        alpha_indices = 0  # all index 0
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


def create_pvrz(img, page_num):
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


def create_mos_v2(width, height, blocks):
    """Create a MOS v2 file.

    blocks: list of (page, src_x, src_y, block_w, block_h, dst_x, dst_y)
    """
    num_blocks = len(blocks)
    block_offset = 24  # right after header

    header = struct.pack('<4s4sIIII',
        b'MOS ', b'V2  ',
        width, height,
        num_blocks,
        block_offset
    )

    block_data = bytearray()
    for page, sx, sy, bw, bh, dx, dy in blocks:
        block_data += struct.pack('<IIIIIII', page, sx, sy, bw, bh, dx, dy)

    return header + block_data


def main():
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <input_image> <output_mos> <pvrz_dir> [page_start]")
        sys.exit(1)

    input_path = sys.argv[1]
    output_mos = sys.argv[2]
    pvrz_dir = sys.argv[3]
    page_start = int(sys.argv[4]) if len(sys.argv) > 4 else 9900

    PVRZ_SIZE = 1024  # each PVRZ page is 1024x1024

    # Load and resize image
    img = Image.open(input_path).convert('RGBA')
    orig_w, orig_h = img.size
    print(f"Input: {orig_w}x{orig_h}")

    # Target size: 1536x864 covers 1920x1080 at 80%
    # Round up to multiple of 4 for DXT
    target_w = 1536
    target_h = 864

    img = img.resize((target_w, target_h), Image.LANCZOS)
    print(f"Resized to: {target_w}x{target_h}")

    # Split into 1024x1024 PVRZ pages
    pages_x = math.ceil(target_w / PVRZ_SIZE)
    pages_y = math.ceil(target_h / PVRZ_SIZE)
    print(f"PVRZ pages needed: {pages_x}x{pages_y} = {pages_x * pages_y}")

    blocks = []
    page_idx = 0

    for py in range(pages_y):
        for px in range(pages_x):
            src_x = px * PVRZ_SIZE
            src_y = py * PVRZ_SIZE
            block_w = min(PVRZ_SIZE, target_w - src_x)
            block_h = min(PVRZ_SIZE, target_h - src_y)

            # Round block dims up to multiple of 4 for DXT
            tex_w = (block_w + 3) // 4 * 4
            tex_h = (block_h + 3) // 4 * 4

            # PVRZ texture must be the full tex size
            # (BG:EE seems to use 1024x1024 pages)
            pvrz_w = max(tex_w, 4)
            pvrz_h = max(tex_h, 4)

            # Create tile image (padded to pvrz dims)
            tile = Image.new('RGBA', (pvrz_w, pvrz_h), (0, 0, 0, 255))
            crop = img.crop((src_x, src_y, src_x + block_w, src_y + block_h))
            tile.paste(crop, (0, 0))

            page_num = page_start + page_idx
            pvrz_path = f"{pvrz_dir}/MOS{page_num:04d}.PVRZ"

            print(f"  Page {page_num}: {pvrz_w}x{pvrz_h} (block {block_w}x{block_h} at dst {src_x},{src_y})")

            pvrz_data = create_pvrz(tile, page_num)
            with open(pvrz_path, 'wb') as f:
                f.write(pvrz_data)
            print(f"    Written: {pvrz_path} ({len(pvrz_data)} bytes)")

            blocks.append((page_num, 0, 0, block_w, block_h, src_x, src_y))
            page_idx += 1

    # Create MOS v2
    mos_data = create_mos_v2(target_w, target_h, blocks)
    with open(output_mos, 'wb') as f:
        f.write(mos_data)
    print(f"\nMOS written: {output_mos} ({len(mos_data)} bytes)")
    print(f"Total PVRZ pages: {page_idx}")


if __name__ == '__main__':
    main()
