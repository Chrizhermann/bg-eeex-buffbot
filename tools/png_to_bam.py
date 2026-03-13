#!/usr/bin/env python3
"""Convert a PNG image to BAM V1 format for BG:EE spell icons.

Usage:
    python tools/png_to_bam.py INPUT.png OUTPUT.BAM [--size 32]

Reads a PNG image (any size, RGBA), resizes to the target size (default 32x32),
quantizes to a 256-color palette with index 0 = transparent (green 0,255,0),
and writes an uncompressed BAM V1 file with a single frame and single cycle.

BAM V1 format (from IESDP / bam_to_png.py):
  - Signature: "BAM V1  " (8 bytes)
  - Header: frame_count(word), cycle_count(byte), transparent_idx(byte),
            frame_entries_off(dword), palette_off(dword), lookup_off(dword)
  - Frame entry: width(word), height(word), center_x(short), center_y(short),
                 data_offset(dword, bit 31 = NOT compressed)
  - Cycle entry: frame_count(word), frame_index(word)
  - Lookup table: frame indices (word per entry)
  - Palette: 256 entries x 4 bytes BGRA (index 0 = transparent color)
  - Frame data: raw palette indices (uncompressed)
"""

import struct
import sys
import argparse
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow required. Install with: pip install Pillow")
    sys.exit(1)


def png_to_bam_v1(input_path, output_path, size=32, alpha_threshold=128):
    """Convert a PNG to a BAM V1 file.

    Args:
        input_path: Path to source PNG (any size, RGBA preferred).
        output_path: Path for output BAM file.
        size: Target icon size in pixels (width = height).
        alpha_threshold: Pixels with alpha < this become transparent.

    Returns:
        True on success.
    """
    # Load and resize
    img = Image.open(input_path).convert("RGBA")
    print(f"  Source: {img.size[0]}x{img.size[1]} RGBA")

    if img.size != (size, size):
        img = img.resize((size, size), Image.LANCZOS)
        print(f"  Resized to {size}x{size} (Lanczos)")

    width, height = img.size
    pixels_rgba = list(img.getdata())  # list of (R, G, B, A) tuples

    # Separate opaque and transparent pixels
    opaque_pixels = []
    alpha_mask = []  # True = transparent
    for r, g, b, a in pixels_rgba:
        if a < alpha_threshold:
            alpha_mask.append(True)
        else:
            alpha_mask.append(False)
            opaque_pixels.append((r, g, b))

    # Quantize opaque pixels to 255 colors (index 0 reserved for transparent)
    if opaque_pixels:
        # Create a temporary image from opaque pixels for quantization
        temp = Image.new("RGB", (len(opaque_pixels), 1))
        temp.putdata(opaque_pixels)
        # Quantize to 255 colors (leaving room for transparent at index 0)
        quantized = temp.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
        quant_palette = quantized.getpalette()  # flat [R,G,B,R,G,B,...] list
        quant_indices = list(quantized.getdata())  # palette indices

        # Build our 256-entry palette: index 0 = transparent, 1-255 = quantized colors
        palette_rgb = [(0, 255, 0)]  # index 0: green = transparent marker
        num_colors = len(quant_palette) // 3
        for i in range(min(num_colors, 255)):
            r = quant_palette[i * 3]
            g = quant_palette[i * 3 + 1]
            b = quant_palette[i * 3 + 2]
            palette_rgb.append((r, g, b))
        # Pad to 256 entries
        while len(palette_rgb) < 256:
            palette_rgb.append((0, 0, 0))
    else:
        # All transparent
        palette_rgb = [(0, 255, 0)] + [(0, 0, 0)] * 255
        quant_indices = []

    # Map each pixel to a palette index
    frame_indices = []
    opaque_idx = 0
    for is_trans in alpha_mask:
        if is_trans:
            frame_indices.append(0)  # transparent
        else:
            # Quantized index is 0-based into the 255-color sub-palette,
            # but our palette has transparent at 0, so shift by +1
            qi = quant_indices[opaque_idx]
            frame_indices.append(qi + 1)
            opaque_idx += 1

    # Build the BAM V1 binary
    TRANS_IDX = 0

    # Layout:
    #   [0x00] Header (24 bytes)
    #   [0x18] Frame entry (12 bytes)
    #   [0x24] Cycle entry (4 bytes)
    #   [0x28] Lookup table entry (2 bytes)
    #   [0x2A] Palette (256 * 4 = 1024 bytes)
    #   [0x42A] Frame data (width * height bytes)

    header_size = 24
    frame_entry_size = 12
    cycle_entry_size = 4
    lookup_entry_size = 2

    frame_entries_off = header_size
    cycle_entries_off = frame_entries_off + frame_entry_size
    lookup_off = cycle_entries_off + cycle_entry_size
    palette_off = lookup_off + lookup_entry_size
    frame_data_off = palette_off + 256 * 4

    # Mark as uncompressed: set bit 31 of data offset
    frame_data_off_flagged = frame_data_off | 0x80000000

    out = bytearray()

    # Header (24 bytes)
    out += b"BAM V1  "                              # signature + version
    out += struct.pack("<H", 1)                      # frame count
    out += struct.pack("<B", 1)                      # cycle count
    out += struct.pack("<B", TRANS_IDX)              # transparent color index
    out += struct.pack("<I", frame_entries_off)       # frame entries offset
    out += struct.pack("<I", palette_off)             # palette offset
    out += struct.pack("<I", lookup_off)              # lookup table offset

    # Frame entry (12 bytes)
    out += struct.pack("<H", width)                  # width
    out += struct.pack("<H", height)                 # height
    out += struct.pack("<h", 0)                      # center X
    out += struct.pack("<h", 0)                      # center Y
    out += struct.pack("<I", frame_data_off_flagged)  # data offset (bit 31 = uncompressed)

    # Cycle entry (4 bytes)
    out += struct.pack("<H", 1)                      # frame count in cycle
    out += struct.pack("<H", 0)                      # index into lookup table

    # Lookup table (2 bytes)
    out += struct.pack("<H", 0)                      # frame index 0

    # Palette (256 entries, 4 bytes each: BGRA)
    for r, g, b in palette_rgb:
        out += struct.pack("BBBB", b, g, r, 0)      # BGRA, alpha=0 in palette

    # Frame data (raw palette indices, uncompressed)
    out += bytes(frame_indices)

    # Write
    with open(output_path, "wb") as f:
        f.write(out)

    total_size = len(out)
    opaque_count = sum(1 for t in alpha_mask if not t)
    trans_count = sum(1 for t in alpha_mask if t)
    print(f"  Output: {output_path}")
    print(f"  BAM V1: {width}x{height}, {total_size} bytes")
    print(f"  Pixels: {opaque_count} opaque, {trans_count} transparent")
    print(f"  Palette: {min(len(set(quant_indices)) + 1, 256) if quant_indices else 1} colors (including transparent)")

    return True


def verify_bam(bam_path):
    """Read back a BAM V1 file and verify its structure.

    Returns True if the file is valid BAM V1 with expected structure.
    """
    with open(bam_path, "rb") as f:
        data = f.read()

    sig = data[:8]
    if sig != b"BAM V1  ":
        print(f"  VERIFY FAIL: bad signature {sig!r}")
        return False

    frame_count = struct.unpack_from("<H", data, 8)[0]
    cycle_count = struct.unpack_from("<B", data, 10)[0]
    trans_idx = struct.unpack_from("<B", data, 11)[0]
    frame_entries_off = struct.unpack_from("<I", data, 12)[0]
    palette_off = struct.unpack_from("<I", data, 16)[0]
    lookup_off = struct.unpack_from("<I", data, 20)[0]

    print(f"  Verify: sig=OK, frames={frame_count}, cycles={cycle_count}, "
          f"trans_idx={trans_idx}")

    if frame_count < 1:
        print("  VERIFY FAIL: no frames")
        return False

    # Read frame 0
    off = frame_entries_off
    w = struct.unpack_from("<H", data, off)[0]
    h = struct.unpack_from("<H", data, off + 2)[0]
    cx = struct.unpack_from("<h", data, off + 4)[0]
    cy = struct.unpack_from("<h", data, off + 6)[0]
    frame_data_off = struct.unpack_from("<I", data, off + 8)[0]

    is_uncompressed = bool(frame_data_off & 0x80000000)
    frame_data_off_clean = frame_data_off & 0x7FFFFFFF

    print(f"  Verify: frame 0 = {w}x{h}, center=({cx},{cy}), "
          f"compressed={'no' if is_uncompressed else 'yes'}")

    # Check we have enough data for the frame
    expected_end = frame_data_off_clean + w * h
    if expected_end > len(data):
        print(f"  VERIFY FAIL: frame data extends beyond file "
              f"({expected_end} > {len(data)})")
        return False

    # Read palette entry 0 (should be transparent color)
    b0, g0, r0, a0 = struct.unpack_from("BBBB", data, palette_off)
    print(f"  Verify: palette[0] = ({r0},{g0},{b0}) (transparent marker)")

    # Count transparent pixels in frame
    frame_bytes = data[frame_data_off_clean:frame_data_off_clean + w * h]
    trans_count = sum(1 for b in frame_bytes if b == trans_idx)
    print(f"  Verify: {trans_count}/{w*h} pixels are transparent "
          f"({100*trans_count//(w*h)}%)")

    print("  Verify: OK")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Convert PNG to BAM V1 for BG:EE spell icons"
    )
    parser.add_argument("input", help="Input PNG file path")
    parser.add_argument("output", help="Output BAM file path")
    parser.add_argument("--size", type=int, default=32,
                        help="Target icon size in pixels (default 32)")
    parser.add_argument("--alpha-threshold", type=int, default=128,
                        help="Alpha threshold for transparency (default 128)")
    parser.add_argument("--no-verify", action="store_true",
                        help="Skip verification of output BAM")
    args = parser.parse_args()

    print(f"Converting {args.input} -> {args.output}")
    ok = png_to_bam_v1(args.input, args.output,
                        size=args.size,
                        alpha_threshold=args.alpha_threshold)

    if ok and not args.no_verify:
        print()
        verify_bam(args.output)


if __name__ == "__main__":
    main()
