#!/usr/bin/env python3
"""Extract BAM V1 spell icons to PNG files for AI art reference.

Usage:
    python tools/bam_to_png.py [--gamedir PATH] [--output DIR] [--bif RESREF...]

Reads BAM V1 files from game override/ and extracts frame 0 as PNG.
Also supports extracting from BIF archives via chitin.key for vanilla icons.
"""

import struct
import zlib
import os
import sys
import argparse
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow required. Install with: pip install Pillow")
    sys.exit(1)


def read_bam_v1(data):
    """Parse a BAM V1 file and return (frames, palette, transparent_idx).
    Each frame is (width, height, pixels) where pixels is list of palette indices.
    """
    sig = data[:8]

    # Handle BAMC (compressed BAM)
    if sig[:4] == b'BAMC':
        uncomp_size = struct.unpack_from('<I', data, 8)[0]
        data = zlib.decompress(data[12:])
        sig = data[:8]

    if sig != b'BAM V1  ':
        raise ValueError(f"Not a BAM V1 file: {sig!r}")

    frame_count = struct.unpack_from('<H', data, 8)[0]
    cycle_count = struct.unpack_from('<B', data, 10)[0]
    trans_idx = struct.unpack_from('<B', data, 11)[0]
    frame_entries_off = struct.unpack_from('<I', data, 12)[0]
    palette_off = struct.unpack_from('<I', data, 16)[0]
    lookup_off = struct.unpack_from('<I', data, 20)[0]

    # Read palette (256 entries, BGRA format)
    palette = []
    for i in range(256):
        off = palette_off + i * 4
        b, g, r, a = struct.unpack_from('BBBB', data, off)
        palette.append((r, g, b, a))

    # Read frames
    frames = []
    for i in range(frame_count):
        off = frame_entries_off + i * 12
        w = struct.unpack_from('<H', data, off)[0]
        h = struct.unpack_from('<H', data, off + 2)[0]
        cx = struct.unpack_from('<h', data, off + 4)[0]
        cy = struct.unpack_from('<h', data, off + 6)[0]
        frame_data_off = struct.unpack_from('<I', data, off + 8)[0]

        # IESDP: bit 31 SET = NOT compressed (raw). Bit 31 CLEAR = RLE compressed.
        is_rle = not bool(frame_data_off & 0x80000000)
        frame_data_off &= 0x7FFFFFFF

        pixels = []
        if is_rle:
            # RLE compressed
            pos = frame_data_off
            total = w * h
            while len(pixels) < total:
                if pos >= len(data):
                    break
                byte = data[pos]
                pos += 1
                if byte == trans_idx:
                    if pos >= len(data):
                        pixels.append(byte)
                        break
                    count = data[pos]
                    pos += 1
                    if count == 0:
                        pixels.append(trans_idx)
                    else:
                        pixels.extend([trans_idx] * (count + 1))
                else:
                    pixels.append(byte)
        else:
            # Uncompressed
            total = w * h
            pixels = list(data[frame_data_off:frame_data_off + total])

        frames.append((w, h, pixels))

    return frames, palette, trans_idx


def frame_to_image(frame, palette, trans_idx):
    """Convert a BAM frame to a PIL Image with transparency."""
    w, h, pixels = frame
    if w == 0 or h == 0:
        return Image.new('RGBA', (1, 1), (0, 0, 0, 0))

    img = Image.new('RGBA', (w, h))
    for y in range(h):
        for x in range(w):
            idx = y * w + x
            if idx < len(pixels):
                pi = pixels[idx]
                if pi == trans_idx:
                    img.putpixel((x, y), (0, 0, 0, 0))
                else:
                    r, g, b, a = palette[pi]
                    img.putpixel((x, y), (r, g, b, 255))
            else:
                img.putpixel((x, y), (0, 0, 0, 0))
    return img


def read_chitin_key(gamedir):
    """Parse chitin.key and return {resref_upper: (bif_index, locator)} for BAM resources."""
    key_path = os.path.join(gamedir, 'chitin.key')
    with open(key_path, 'rb') as f:
        data = f.read()

    sig = data[:8]
    if sig != b'KEY V1  ':
        raise ValueError(f"Not a KEY file: {sig!r}")

    bif_count = struct.unpack_from('<I', data, 8)[0]
    res_count = struct.unpack_from('<I', data, 12)[0]
    bif_off = struct.unpack_from('<I', data, 16)[0]
    res_off = struct.unpack_from('<I', data, 20)[0]

    # Read BIF entries
    bifs = []
    for i in range(bif_count):
        off = bif_off + i * 12
        flen = struct.unpack_from('<I', data, off)[0]
        fname_off = struct.unpack_from('<I', data, off + 4)[0]
        fname_len = struct.unpack_from('<H', data, off + 8)[0]
        fname = data[fname_off:fname_off + fname_len].rstrip(b'\x00').decode('ascii')
        # Normalize path separators
        fname = fname.replace('\\', '/')
        bifs.append(fname)

    # Read resource entries: {resref -> (bif_index, tileset_index, resource_index)}
    resources = {}
    for i in range(res_count):
        off = res_off + i * 14
        resref = data[off:off + 8].rstrip(b'\x00').decode('ascii').upper()
        res_type = struct.unpack_from('<H', data, off + 8)[0]
        locator = struct.unpack_from('<I', data, off + 10)[0]

        # type 0x3EB = BAM, 0x3E8 = BMP (EE uses this for BAMC spell icons too)
        if res_type in (0x3EB, 0x3E8):
            bif_idx = locator >> 20
            res_idx = locator & 0x3FFF
            resources[resref] = (bif_idx, res_idx)

    return bifs, resources


def extract_from_bif(gamedir, bif_path, res_idx):
    """Extract a single resource from a BIF archive."""
    full_path = os.path.join(gamedir, bif_path)
    with open(full_path, 'rb') as f:
        data = f.read()

    sig = data[:8]
    if sig == b'BIFFV1  ':
        file_count = struct.unpack_from('<I', data, 8)[0]
        entries_off = struct.unpack_from('<I', data, 16)[0]
        for i in range(file_count):
            off = entries_off + i * 16
            f_locator = struct.unpack_from('<I', data, off)[0]
            f_offset = struct.unpack_from('<I', data, off + 4)[0]
            f_size = struct.unpack_from('<I', data, off + 8)[0]
            f_type = struct.unpack_from('<H', data, off + 12)[0]
            f_idx = f_locator & 0x3FFF

            if f_idx == res_idx and f_type in (0x3EB, 0x3E8):  # BAM or BMP/BAMC
                return data[f_offset:f_offset + f_size]

    return None


def main():
    parser = argparse.ArgumentParser(description='Extract BAM V1 icons to PNG')
    parser.add_argument('--gamedir', default="c:/Games/Baldur's Gate II Enhanced Edition modded",
                        help='Game installation directory')
    parser.add_argument('--output', default='tools/icon_reference',
                        help='Output directory for PNGs')
    parser.add_argument('--scale', type=int, default=4,
                        help='Upscale factor (default 4x, so 32px -> 128px)')
    parser.add_argument('resrefs', nargs='*',
                        help='Specific resrefs to extract (e.g. SPWI218B). If empty, extracts a curated set.')
    args = parser.parse_args()

    outdir = Path(args.output)
    outdir.mkdir(parents=True, exist_ok=True)

    # Curated set of iconic buff spell icons if none specified
    if not args.resrefs:
        args.resrefs = [
            # Wizard buffs (well-known icons)
            'SPWI218B',  # Stoneskin (current placeholder)
            'SPWI304C',  # Haste
            'SPWI308C',  # Protection from Fire (or variant)
            'SPWI402C',  # Stoneskin (level 4)
            'SPWI519C',  # Spell Immunity
            'SPWI602C',  # Protection from Magic Weapons
            'SPWI620C',  # Contingency
            'SPWI710C',  # Spell Sequencer / Project Image
            'SPWI920C',  # Chain Contingency
            'SPWI921C',  # Improved Alacrity
            # Priest buffs
            'SPPR103C',  # Bless
            'SPPR207C',  # Chant
            'SPPR301C',  # Dispel Magic (for contrast)
            'SPPR407C',  # Death Ward
            'SPPR503C',  # Chaotic Commands
            # Innate / misc
            'SPWI112C',  # Shield
            'SPWI205C',  # Mirror Image
            'SPWI302C',  # Protection from Normal Missiles
        ]

    # Step 1: Check override directory for direct BAM files
    override_dir = os.path.join(args.gamedir, 'override')

    # Step 2: Parse chitin.key for BIF-archived resources
    print("Parsing chitin.key...")
    bifs, bam_resources = read_chitin_key(args.gamedir)
    print(f"  Found {len(bam_resources)} BAM resources in key")

    extracted = 0
    for resref in args.resrefs:
        resref_upper = resref.upper()
        bam_data = None

        # Try override first
        for ext in ['.BAM', '.bam']:
            path = os.path.join(override_dir, resref_upper + ext)
            if os.path.exists(path):
                with open(path, 'rb') as f:
                    bam_data = f.read()
                print(f"  {resref_upper}: found in override/")
                break
            # Try lowercase
            path = os.path.join(override_dir, resref.lower() + ext)
            if os.path.exists(path):
                with open(path, 'rb') as f:
                    bam_data = f.read()
                print(f"  {resref_upper}: found in override/ (lowercase)")
                break

        # Try BIF archive
        if bam_data is None and resref_upper in bam_resources:
            bif_idx, res_idx = bam_resources[resref_upper]
            bif_path = bifs[bif_idx]
            print(f"  {resref_upper}: extracting from {bif_path}...")
            bam_data = extract_from_bif(args.gamedir, bif_path, res_idx)

        if bam_data is None:
            print(f"  {resref_upper}: NOT FOUND (skipping)")
            continue

        try:
            frames, palette, trans_idx = read_bam_v1(bam_data)
            if not frames:
                print(f"  {resref_upper}: no frames (skipping)")
                continue

            img = frame_to_image(frames[0], palette, trans_idx)

            # Save original size
            orig_path = outdir / f"{resref_upper}.png"
            img.save(str(orig_path))

            # Save upscaled (nearest neighbor for pixel art)
            if args.scale > 1:
                w, h = img.size
                scaled = img.resize((w * args.scale, h * args.scale), Image.NEAREST)
                scaled_path = outdir / f"{resref_upper}_{args.scale}x.png"
                scaled.save(str(scaled_path))

            print(f"  {resref_upper}: {img.size[0]}x{img.size[1]} -> saved ({orig_path.name})")
            extracted += 1

        except Exception as e:
            print(f"  {resref_upper}: ERROR - {e}")

    print(f"\nDone! Extracted {extracted} icons to {outdir}/")
    if extracted > 0:
        print(f"  Original (32x32): {outdir}/*.png")
        print(f"  Upscaled ({32*args.scale}x{32*args.scale}): {outdir}/*_{args.scale}x.png")


if __name__ == '__main__':
    main()
