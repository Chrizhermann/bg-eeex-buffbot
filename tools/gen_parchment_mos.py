#!/usr/bin/env python3
"""Generate a parchment-textured MOS v1 file for BuffBot panel background.

Usage: python3 tools/gen_parchment_mos.py [width] [height] [output_path]
Defaults: 1024 896 buffbot/BFBOTBG.MOS

MOS v1 format: 64x64 palettized tiles with per-tile 256-color palettes.
"""

import math
import random
import struct
import sys

def generate_parchment_rgb(w, h, seed=42):
    """Generate a parchment-style texture as flat RGB array."""
    random.seed(seed)

    # Base parchment color (warm tan)
    base_r, base_g, base_b = 185, 165, 130

    pixels = []  # flat list of (r, g, b)

    # Pre-generate noise layers at different scales
    # Simple value noise using grid interpolation
    def make_noise_grid(cols, rows):
        return [[random.uniform(-1, 1) for _ in range(cols + 1)] for _ in range(rows + 1)]

    # Multiple octaves for natural-looking texture
    grid_coarse = make_noise_grid(8, 8)    # large blotches
    grid_medium = make_noise_grid(16, 16)  # medium detail
    grid_fine   = make_noise_grid(32, 32)  # fine grain

    def sample_grid(grid, x_norm, y_norm, cols, rows):
        """Bilinear interpolation on a noise grid."""
        fx = x_norm * cols
        fy = y_norm * rows
        ix = min(int(fx), cols - 1)
        iy = min(int(fy), rows - 1)
        dx = fx - ix
        dy = fy - iy
        v00 = grid[iy][ix]
        v10 = grid[iy][min(ix + 1, cols)]
        v01 = grid[min(iy + 1, rows)][ix]
        v11 = grid[min(iy + 1, rows)][min(ix + 1, cols)]
        v0 = v00 + (v10 - v00) * dx
        v1 = v01 + (v11 - v01) * dx
        return v0 + (v1 - v0) * dy

    for y in range(h):
        yn = y / h
        for x in range(w):
            xn = x / w

            # Combine noise octaves
            n_coarse = sample_grid(grid_coarse, xn, yn, 8, 8) * 20
            n_medium = sample_grid(grid_medium, xn, yn, 16, 16) * 10
            n_fine   = sample_grid(grid_fine,   xn, yn, 32, 32) * 5

            noise = n_coarse + n_medium + n_fine

            # Vignette (darken edges)
            edge_x = min(x, w - 1 - x) / (w * 0.3)
            edge_y = min(y, h - 1 - y) / (h * 0.3)
            edge = min(edge_x, edge_y, 1.0)
            vignette = 0.65 + 0.35 * edge  # darkens to 65% at edges

            # Slight warm color variation
            color_shift = sample_grid(grid_coarse, xn * 1.7 + 0.3, yn * 1.3 + 0.5, 8, 8) * 8

            r = int(max(0, min(255, (base_r + noise + color_shift) * vignette)))
            g = int(max(0, min(255, (base_g + noise - abs(color_shift) * 0.3) * vignette)))
            b = int(max(0, min(255, (base_b + noise * 0.7 - color_shift * 0.5) * vignette)))

            pixels.append((r, g, b))

    return pixels


def build_mos_v1(w, h, pixels):
    """Build a MOS v1 binary from pixel data."""
    cols = math.ceil(w / 64)
    rows = math.ceil(h / 64)
    num_tiles = cols * rows

    # For each tile, we need:
    #   - 256-color palette (256 * 4 bytes BGRA = 1024 bytes)
    #   - Pixel data (tile_w * tile_h bytes, padded to 4-byte boundary)

    palette_offset = 24  # right after header

    tile_data = []  # list of (palette_bytes, pixel_bytes) per tile

    for ty in range(rows):
        for tx in range(cols):
            # Tile bounds
            x0 = tx * 64
            y0 = ty * 64
            tw = min(64, w - x0)
            th = min(64, h - y0)

            # Collect unique colors in this tile
            tile_colors = []
            for ly in range(th):
                for lx in range(tw):
                    px_idx = (y0 + ly) * w + (x0 + lx)
                    tile_colors.append(pixels[px_idx])

            # Build palette: median-cut or just take unique colors
            # For parchment, colors are similar — simple approach: collect uniques
            unique = list(set(tile_colors))
            if len(unique) > 256:
                # Quantize: sort by luminance and sample 256
                unique.sort(key=lambda c: c[0] * 0.3 + c[1] * 0.6 + c[2] * 0.1)
                step = len(unique) / 256
                unique = [unique[int(i * step)] for i in range(256)]

            # Build color -> index map
            palette = unique + [(0, 0, 0)] * (256 - len(unique))
            color_to_idx = {}
            for i, c in enumerate(palette):
                if c not in color_to_idx:
                    color_to_idx[c] = i

            # Write palette (BGRA format)
            pal_bytes = bytearray()
            for r, g, b in palette:
                pal_bytes += struct.pack('BBBB', b, g, r, 0)  # BGRA

            # Write pixel indices
            pix_bytes = bytearray()
            for ly in range(th):
                for lx in range(tw):
                    px_idx = (y0 + ly) * w + (x0 + lx)
                    color = pixels[px_idx]
                    if color in color_to_idx:
                        pix_bytes.append(color_to_idx[color])
                    else:
                        # Find nearest color in palette
                        best_idx = 0
                        best_dist = 999999
                        for i, pc in enumerate(palette):
                            d = (color[0]-pc[0])**2 + (color[1]-pc[1])**2 + (color[2]-pc[2])**2
                            if d < best_dist:
                                best_dist = d
                                best_idx = i
                        pix_bytes.append(best_idx)

            # Pad pixel data to 4-byte boundary
            while len(pix_bytes) % 4 != 0:
                pix_bytes.append(0)

            tile_data.append((pal_bytes, pix_bytes))

    # Calculate offsets
    # Layout: header | palettes (all) | pixel data (all) | offset table
    all_palettes_size = num_tiles * 1024
    pixel_data_offset = palette_offset + all_palettes_size

    # Build offset table (offsets to each tile's pixel data from file start)
    offset_table = []
    current_offset = pixel_data_offset
    for pal_b, pix_b in tile_data:
        offset_table.append(current_offset)
        current_offset += len(pix_b)

    # Assemble file
    header = struct.pack('<4s4sHHHHII',
        b'MOS ', b'V1  ',
        w, h,
        cols, rows,
        64,
        palette_offset
    )

    data = bytearray(header)

    # All palettes
    for pal_b, pix_b in tile_data:
        data += pal_b

    # All pixel data
    for pal_b, pix_b in tile_data:
        data += pix_b

    # Offset table
    for off in offset_table:
        data += struct.pack('<I', off)

    return bytes(data)


def main():
    w = int(sys.argv[1]) if len(sys.argv) > 1 else 1024
    h = int(sys.argv[2]) if len(sys.argv) > 2 else 896
    output = sys.argv[3] if len(sys.argv) > 3 else 'buffbot/BFBOTBG.MOS'

    # Round up to 64-pixel multiples for clean tiles
    w = math.ceil(w / 64) * 64
    h = math.ceil(h / 64) * 64

    print(f"Generating {w}x{h} parchment texture...")
    pixels = generate_parchment_rgb(w, h)

    print(f"Building MOS v1 ({math.ceil(w/64)}x{math.ceil(h/64)} tiles)...")
    mos_data = build_mos_v1(w, h, pixels)

    with open(output, 'wb') as f:
        f.write(mos_data)

    print(f"Written {len(mos_data)} bytes to {output}")


if __name__ == '__main__':
    main()
