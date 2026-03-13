#!/usr/bin/env python3
"""Convert one or more PNG images to a BAM V1 file.

Supports multi-frame BAMs with a single cycle. Handles palette quantization
(256 colors, index 0 = transparent green), optional resize, and produces
uncompressed (raw) frame data.

Usage:
    python tools/png_to_bam.py -o output.BAM [--size WxH] input1.png [input2.png ...]

Examples:
    # Actionbar button: 2 frames (normal + pressed), 40x40
    python tools/png_to_bam.py -o buffbot/BFBOTAB.BAM --size 40x40 normal.png pressed.png

    # Single-frame icon at original size
    python tools/png_to_bam.py -o icon.BAM sprite.png

BAM V1 format (IESDP):
    Signature:     "BAM V1  " (8 bytes)
    Header:        frame_count(H), cycle_count(B), trans_idx(B),
                   frame_entries_off(I), palette_off(I), lookup_off(I)
    Frame entries:  width(H), height(H), center_x(h), center_y(h), data_off(I)
                   (bit 31 of data_off SET = uncompressed/raw)
    Palette:       256 x 4 bytes BGRA
    Cycle entries: frame_count(H), first_frame_idx(H)
    Lookup table:  frame indices (H each)
    Frame data:    raw palette indices (width * height bytes per frame)
"""

import argparse
import struct
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow required. Install with: pip install Pillow")
    sys.exit(1)


def quantize_images(images, transparent_color=(0, 255, 0)):
    """Quantize multiple PIL Images to a shared 256-color palette.

    Index 0 is reserved for the transparent color.
    Returns (palette_bgra_list[256], list_of_index_arrays).
    """
    # Combine all images into one for unified quantization
    total_width = sum(img.width for img in images)
    max_height = max(img.height for img in images)
    combined = Image.new("RGB", (total_width, max_height), transparent_color)
    x_offset = 0
    for img in images:
        combined.paste(img, (x_offset, 0))
        x_offset += img.width

    # Quantize to 255 colors (reserve slot 0 for transparent)
    quantized = combined.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
    raw_palette = quantized.getpalette()  # flat list [R, G, B, R, G, B, ...]

    # Build BGRA palette: slot 0 = transparent green, slots 1..255 = quantized colors
    palette_bgra = [(0, 255, 0, 0)]  # index 0: transparent (BGRA)
    num_quantized = len(raw_palette) // 3
    for i in range(min(num_quantized, 255)):
        r = raw_palette[i * 3]
        g = raw_palette[i * 3 + 1]
        b = raw_palette[i * 3 + 2]
        palette_bgra.append((b, g, r, 0))  # BGRA, alpha byte unused (always 0)
    # Pad to 256 entries
    while len(palette_bgra) < 256:
        palette_bgra.append((0, 0, 0, 0))

    # Map each original image's pixels to quantized indices (shifted by +1)
    index_arrays = []
    x_offset = 0
    for img in images:
        indices = []
        for y in range(img.height):
            for x in range(img.width):
                # Get the quantized pixel from the combined image
                qi = quantized.getpixel((x_offset + x, y))
                # Shift by 1 because index 0 is reserved for transparent
                indices.append(qi + 1)
        index_arrays.append(indices)
        x_offset += img.width

    return palette_bgra, index_arrays


def build_bam_v1(frames_info, palette_bgra, index_arrays):
    """Build a BAM V1 binary blob.

    frames_info: list of (width, height) tuples
    palette_bgra: list of 256 (B, G, R, A) tuples
    index_arrays: list of flat lists of palette indices (one per frame)

    Returns bytes.
    """
    frame_count = len(frames_info)
    cycle_count = 1  # single cycle containing all frames
    trans_idx = 0    # palette index 0 = transparent

    # Layout computation
    # Header: 8 (sig) + 16 (fields) = 24 bytes
    header_size = 24
    # Frame entries: 12 bytes each
    frame_entries_off = header_size
    frame_entries_size = frame_count * 12
    # Palette: 256 * 4 = 1024 bytes
    palette_off = frame_entries_off + frame_entries_size
    palette_size = 256 * 4
    # Cycle entries: 4 bytes each (frame_count(H) + first_frame_idx(H))
    cycle_off = palette_off + palette_size
    cycle_size = cycle_count * 4
    # Lookup table: frame_count * 2 bytes
    lookup_off = cycle_off + cycle_size
    lookup_size = frame_count * 2
    # Frame data starts after lookup table
    frame_data_start = lookup_off + lookup_size

    # Calculate frame data offsets
    frame_data_offsets = []
    offset = frame_data_start
    for i, (w, h) in enumerate(frames_info):
        # Bit 31 set = uncompressed (raw)
        frame_data_offsets.append(offset | 0x80000000)
        offset += w * h

    total_size = offset

    # Build the binary
    buf = bytearray(total_size)

    # Signature
    buf[0:8] = b'BAM V1  '

    # Header fields
    struct.pack_into('<H', buf, 8, frame_count)
    struct.pack_into('<B', buf, 10, cycle_count)
    struct.pack_into('<B', buf, 11, trans_idx)
    struct.pack_into('<I', buf, 12, frame_entries_off)
    struct.pack_into('<I', buf, 16, palette_off)
    struct.pack_into('<I', buf, 20, lookup_off)

    # Frame entries
    for i, (w, h) in enumerate(frames_info):
        off = frame_entries_off + i * 12
        struct.pack_into('<H', buf, off, w)       # width
        struct.pack_into('<H', buf, off + 2, h)   # height
        struct.pack_into('<h', buf, off + 4, 0)   # center x
        struct.pack_into('<h', buf, off + 6, 0)   # center y
        struct.pack_into('<I', buf, off + 8, frame_data_offsets[i])

    # Palette
    for i, (b, g, r, a) in enumerate(palette_bgra):
        off = palette_off + i * 4
        buf[off] = b
        buf[off + 1] = g
        buf[off + 2] = r
        buf[off + 3] = a

    # Cycle entries: 1 cycle with all frames
    struct.pack_into('<H', buf, cycle_off, frame_count)  # frame count in cycle
    struct.pack_into('<H', buf, cycle_off + 2, 0)        # first lookup index

    # Lookup table
    for i in range(frame_count):
        struct.pack_into('<H', buf, lookup_off + i * 2, i)

    # Frame data (raw palette indices)
    data_offset = frame_data_start
    for i, indices in enumerate(index_arrays):
        for idx_val in indices:
            buf[data_offset] = idx_val
            data_offset += 1

    return bytes(buf)


def main():
    parser = argparse.ArgumentParser(
        description="Convert PNG images to BAM V1 (multi-frame, single cycle)"
    )
    parser.add_argument(
        "inputs", nargs="+", help="Input PNG files (one per frame, in order)"
    )
    parser.add_argument(
        "-o", "--output", required=True, help="Output BAM file path"
    )
    parser.add_argument(
        "--size", default=None,
        help="Resize to WxH (e.g. 40x40). Uses Lanczos resampling."
    )
    args = parser.parse_args()

    # Parse size
    target_size = None
    if args.size:
        try:
            w, h = args.size.split("x")
            target_size = (int(w), int(h))
        except ValueError:
            print(f"ERROR: Invalid size format '{args.size}'. Use WxH (e.g. 40x40)")
            sys.exit(1)

    # Load and resize images
    images = []
    for path in args.inputs:
        p = Path(path)
        if not p.exists():
            print(f"ERROR: File not found: {path}")
            sys.exit(1)
        img = Image.open(p).convert("RGB")
        if target_size:
            img = img.resize(target_size, Image.LANCZOS)
        images.append(img)
        print(f"  Frame {len(images) - 1}: {p.name} -> {img.width}x{img.height}")

    # Verify all frames are the same size
    widths = set(img.width for img in images)
    heights = set(img.height for img in images)
    if len(widths) > 1 or len(heights) > 1:
        print("ERROR: All frames must be the same size after resize.")
        sys.exit(1)

    # Quantize to shared palette
    print("Quantizing to 256 colors...")
    palette_bgra, index_arrays = quantize_images(images)

    # Build BAM
    frames_info = [(img.width, img.height) for img in images]
    bam_data = build_bam_v1(frames_info, palette_bgra, index_arrays)

    # Write output
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(bam_data)

    print(f"\nWrote {out_path} ({len(bam_data)} bytes)")
    print(f"  Frames: {len(images)}, Size: {images[0].width}x{images[0].height}")
    print(f"  Cycle: 1 (frames 0..{len(images) - 1})")


if __name__ == "__main__":
    main()
