#!/usr/bin/env python3
"""Extract BAM V2 (PVRZ-based) frames to PNG files.

BAM V2 files store pixel data in PVRZ texture atlases. Each frame references
one or more rectangular regions in PVRZ pages, which contain zlib-compressed
PVR3 textures with DXT5 (BC3) pixel data.

Usage:
    python tools/extract_bamv2.py [--gamedir PATH] [--output DIR] [--scale N]

Extracts actionbar button icons (GUIBTACT.BAM) and other BAM V2 files
from BG2:EE game data.
"""

import struct
import zlib
import os
import sys
import io
import argparse
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow required. Install with: pip install Pillow")
    sys.exit(1)


# ---------------------------------------------------------------------------
# BIF archive handling
# ---------------------------------------------------------------------------

def read_chitin_key(gamedir):
    """Parse chitin.key and return (bif_paths, resource_map).

    resource_map: {(resref_upper, type_code): (bif_index, resource_index)}
    """
    key_path = os.path.join(gamedir, "chitin.key")
    with open(key_path, "rb") as f:
        data = f.read()

    if data[:8] != b"KEY V1  ":
        raise ValueError(f"Not a KEY file: {data[:8]!r}")

    bif_count = struct.unpack_from("<I", data, 8)[0]
    res_count = struct.unpack_from("<I", data, 12)[0]
    bif_off = struct.unpack_from("<I", data, 16)[0]
    res_off = struct.unpack_from("<I", data, 20)[0]

    bifs = []
    for i in range(bif_count):
        off = bif_off + i * 12
        fname_off = struct.unpack_from("<I", data, off + 4)[0]
        fname_len = struct.unpack_from("<H", data, off + 8)[0]
        fname = data[fname_off:fname_off + fname_len].rstrip(b"\x00").decode("ascii")
        fname = fname.replace("\\", "/")
        bifs.append(fname)

    resources = {}
    for i in range(res_count):
        off = res_off + i * 14
        resref = data[off:off + 8].rstrip(b"\x00").decode("ascii").upper()
        res_type = struct.unpack_from("<H", data, off + 8)[0]
        locator = struct.unpack_from("<I", data, off + 10)[0]
        bif_idx = locator >> 20
        res_idx = locator & 0x3FFF
        resources[(resref, res_type)] = (bif_idx, res_idx)

    return bifs, resources


def extract_from_bif(data_or_path, res_idx, expected_type=None):
    """Extract a single resource from a BIF archive.

    data_or_path: either bytes (BIF data) or a file path string.
    """
    if isinstance(data_or_path, (str, Path)):
        with open(data_or_path, "rb") as f:
            data = f.read()
    else:
        data = data_or_path

    if data[:8] != b"BIFFV1  ":
        raise ValueError(f"Not a BIF file: {data[:8]!r}")

    file_count = struct.unpack_from("<I", data, 8)[0]
    entries_off = struct.unpack_from("<I", data, 16)[0]

    for i in range(file_count):
        off = entries_off + i * 16
        f_locator = struct.unpack_from("<I", data, off)[0]
        f_offset = struct.unpack_from("<I", data, off + 4)[0]
        f_size = struct.unpack_from("<I", data, off + 8)[0]
        f_type = struct.unpack_from("<H", data, off + 12)[0]
        f_idx = f_locator & 0x3FFF

        if f_idx == res_idx:
            if expected_type is not None and f_type != expected_type:
                continue
            return data[f_offset:f_offset + f_size]

    return None


# ---------------------------------------------------------------------------
# PVRZ decoding
# ---------------------------------------------------------------------------

def decode_pvrz(pvrz_data):
    """Decode a PVRZ file into a PIL Image.

    PVRZ format:
      - 4 bytes: decompressed size (uint32 LE)
      - remainder: zlib-compressed PVR3 data

    PVR3 format:
      - 52-byte header
      - DXT5 pixel data

    Returns a PIL RGBA Image.
    """
    decomp_size = struct.unpack_from("<I", pvrz_data, 0)[0]
    pvr_data = zlib.decompress(pvrz_data[4:])

    # Parse PVR3 header
    version = struct.unpack_from("<I", pvr_data, 0)[0]
    if version != 0x03525650:
        raise ValueError(f"Not PVR3 format: version=0x{version:08X}")

    pixel_format = struct.unpack_from("<Q", pvr_data, 8)[0]
    height = struct.unpack_from("<I", pvr_data, 24)[0]
    width = struct.unpack_from("<I", pvr_data, 28)[0]
    meta_size = struct.unpack_from("<I", pvr_data, 48)[0]

    # Map PVR3 pixel format to DDS FourCC
    # PVR3: 7=DXT1, 9=DXT3, 11=DXT5
    format_map = {7: b"DXT1", 9: b"DXT3", 11: b"DXT5"}
    if pixel_format not in format_map:
        raise ValueError(f"Unsupported PVR3 pixel format: {pixel_format}")

    fourcc = format_map[pixel_format]
    block_size = 8 if fourcc == b"DXT1" else 16

    # Extract pixel data
    pixel_data = pvr_data[52 + meta_size:]

    # Create a DDS file in memory for Pillow to decode
    dds_data = _make_dds(width, height, fourcc, block_size, pixel_data)

    img = Image.open(io.BytesIO(dds_data))
    return img


def _make_dds(width, height, fourcc, block_size, pixel_data):
    """Create a DDS file from raw DXT compressed data."""
    flags = 0x1 | 0x2 | 0x4 | 0x1000 | 0x80000  # CAPS|HEIGHT|WIDTH|PIXELFORMAT|LINEARSIZE
    linear_size = max(1, ((width + 3) // 4)) * max(1, ((height + 3) // 4)) * block_size

    header = struct.pack(
        "<4s"   # magic "DDS "
        "I"     # header size (124)
        "I"     # flags
        "I"     # height
        "I"     # width
        "I"     # pitch/linear size
        "I"     # depth
        "I"     # mip count
        "44s"   # reserved1[11]
        "I"     # ddpf size (32)
        "I"     # ddpf flags (FOURCC=0x4)
        "4s"    # ddpf fourcc
        "I"     # RGB bit count
        "I"     # R mask
        "I"     # G mask
        "I"     # B mask
        "I"     # A mask
        "I"     # caps (TEXTURE=0x1000)
        "I"     # caps2
        "I"     # caps3
        "I"     # caps4
        "I",    # reserved2
        b"DDS ",
        124, flags, height, width, linear_size,
        0, 0,
        b"\x00" * 44,
        32, 0x4, fourcc,
        0, 0, 0, 0, 0,
        0x1000,
        0, 0, 0, 0
    )
    return header + pixel_data


# ---------------------------------------------------------------------------
# BAM V2 parsing
# ---------------------------------------------------------------------------

def parse_bam_v2(data):
    """Parse a BAM V2 file.

    Returns (frames, data_blocks, cycles) where:
      frames: [(width, height, centerX, centerY, dbIndex, dbCount), ...]
      data_blocks: [(pvrzPage, srcX, srcY, srcW, srcH, dstX, dstY), ...]
      cycles: [(frame_count, frame_index_offset), ...]
    """
    if data[:8] != b"BAM V2  ":
        raise ValueError(f"Not BAM V2: {data[:8]!r}")

    frame_count = struct.unpack_from("<I", data, 8)[0]
    cycle_count = struct.unpack_from("<I", data, 12)[0]
    block_count = struct.unpack_from("<I", data, 16)[0]
    frame_off = struct.unpack_from("<I", data, 20)[0]
    cycle_off = struct.unpack_from("<I", data, 24)[0]
    block_off = struct.unpack_from("<I", data, 28)[0]

    frames = []
    for i in range(frame_count):
        off = frame_off + i * 12
        w = struct.unpack_from("<H", data, off)[0]
        h = struct.unpack_from("<H", data, off + 2)[0]
        cx = struct.unpack_from("<h", data, off + 4)[0]
        cy = struct.unpack_from("<h", data, off + 6)[0]
        db_idx = struct.unpack_from("<h", data, off + 8)[0]
        db_cnt = struct.unpack_from("<h", data, off + 10)[0]
        frames.append((w, h, cx, cy, db_idx, db_cnt))

    blocks = []
    for i in range(block_count):
        off = block_off + i * 28
        page = struct.unpack_from("<I", data, off)[0]
        sx = struct.unpack_from("<I", data, off + 4)[0]
        sy = struct.unpack_from("<I", data, off + 8)[0]
        sw = struct.unpack_from("<I", data, off + 12)[0]
        sh = struct.unpack_from("<I", data, off + 16)[0]
        dx = struct.unpack_from("<I", data, off + 20)[0]
        dy = struct.unpack_from("<I", data, off + 24)[0]
        blocks.append((page, sx, sy, sw, sh, dx, dy))

    cycles = []
    for i in range(cycle_count):
        off = cycle_off + i * 4
        fc = struct.unpack_from("<H", data, off)[0]
        fi = struct.unpack_from("<H", data, off + 2)[0]
        cycles.append((fc, fi))

    return frames, blocks, cycles


def render_bam_v2_frame(frame, blocks, pvrz_cache):
    """Render a single BAM V2 frame to a PIL Image.

    frame: (width, height, centerX, centerY, dbIndex, dbCount)
    blocks: full data block list from parse_bam_v2
    pvrz_cache: dict {page_number: PIL.Image}

    Returns PIL RGBA Image.
    """
    w, h, cx, cy, db_idx, db_cnt = frame

    if w == 0 or h == 0:
        return Image.new("RGBA", (1, 1), (0, 0, 0, 0))

    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    for i in range(db_cnt):
        block = blocks[db_idx + i]
        page, sx, sy, sw, sh, dx, dy = block

        if page not in pvrz_cache:
            print(f"    WARNING: PVRZ page {page} not loaded, skipping block")
            continue

        pvrz_img = pvrz_cache[page]

        # Crop the region from the PVRZ texture
        region = pvrz_img.crop((sx, sy, sx + sw, sy + sh))

        # Paste into the frame at the destination position
        img.paste(region, (dx, dy))

    return img


# ---------------------------------------------------------------------------
# Resource loading
# ---------------------------------------------------------------------------

class GameResourceLoader:
    """Load game resources from override directories and BIF archives."""

    def __init__(self, gamedir):
        self.gamedir = gamedir
        self.bifs, self.resources = read_chitin_key(gamedir)
        self._bif_cache = {}  # bif_path -> bytes
        self._pvrz_cache = {}  # page_number -> PIL.Image

    def _get_bif_data(self, bif_path):
        """Load BIF data with caching."""
        if bif_path not in self._bif_cache:
            full_path = os.path.join(self.gamedir, bif_path)
            with open(full_path, "rb") as f:
                self._bif_cache[bif_path] = f.read()
        return self._bif_cache[bif_path]

    def load_resource(self, resref, res_type):
        """Load a resource by resref and type code.

        Checks override directories first, then BIF archives.
        Returns bytes or None.
        """
        resref_upper = resref.upper()

        # Check override directories (in priority order)
        search_dirs = [
            os.path.join(self.gamedir, "override"),
            os.path.join(self.gamedir, "EET", "SoD_GUI"),
        ]

        # Map type codes to file extensions
        ext_map = {
            0x3EB: ".BAM",
            0x404: ".PVRZ",
            0x3EE: ".MOS",
        }
        ext = ext_map.get(res_type, "")

        for d in search_dirs:
            path = os.path.join(d, resref_upper + ext)
            if os.path.exists(path):
                with open(path, "rb") as f:
                    return f.read()
            # Try lowercase
            path = os.path.join(d, resref.lower() + ext.lower())
            if os.path.exists(path):
                with open(path, "rb") as f:
                    return f.read()

        # Check BIF archives
        key = (resref_upper, res_type)
        if key in self.resources:
            bif_idx, res_idx = self.resources[key]
            bif_path = self.bifs[bif_idx]
            bif_data = self._get_bif_data(bif_path)
            return extract_from_bif(bif_data, res_idx)

        return None

    def load_bam(self, resref):
        """Load a BAM file. Returns bytes or None."""
        return self.load_resource(resref, 0x3EB)

    def load_pvrz_image(self, page_number):
        """Load and decode a PVRZ page, returning a PIL Image. Cached."""
        if page_number not in self._pvrz_cache:
            resref = f"MOS{page_number:04d}"
            pvrz_data = self.load_resource(resref, 0x404)
            if pvrz_data is None:
                print(f"  ERROR: Could not find PVRZ page {page_number} ({resref})")
                return None
            self._pvrz_cache[page_number] = decode_pvrz(pvrz_data)
        return self._pvrz_cache[page_number]

    def preload_pvrz_pages(self, pages):
        """Preload a set of PVRZ pages."""
        for page in pages:
            if page not in self._pvrz_cache:
                img = self.load_pvrz_image(page)
                if img:
                    print(f"  Loaded PVRZ page {page}: {img.size[0]}x{img.size[1]}")


def get_pvrz_pages_for_bam(frames, blocks):
    """Get all unique PVRZ page numbers referenced by a BAM V2."""
    pages = set()
    for w, h, cx, cy, db_idx, db_cnt in frames:
        for i in range(db_cnt):
            page = blocks[db_idx + i][0]
            pages.add(page)
    return pages


# ---------------------------------------------------------------------------
# Actionbar icon name mapping
# ---------------------------------------------------------------------------

# Known GUIBTACT frame indices and their meanings (from BG2:EE SoD GUI).
# 76 frames total at 54x54 pixels each (except a few narrow ones at 35x54).
#
# Frames 0-24: First set of 25 unique action button icons (normal state).
# These correspond to action IDs used in the game's actionbar UI code.
#
# Frames 25-75: Additional icons in groups of 3 states each:
#   normal, greyed/pressed, highlighted (gold or red border)
# These are SoD/EET-specific actionbar icons for additional actions.
#
# Identified by visual inspection of extracted frames:
GUIBTACT_FRAME_NAMES = {
    # --- Original 25 action icons (frames 0-24) ---
    0: "guard",
    1: "attack",
    2: "talk",
    3: "cast_spell",
    4: "use_item",
    5: "special_ability",
    6: "stealth",
    7: "thieving",
    8: "turn_undead",
    9: "stop",
    10: "quick_item_1",
    11: "quick_item_2",
    12: "quick_item_3",
    13: "quick_spell_1",
    14: "quick_spell_2",
    15: "quick_spell_3",
    16: "quick_weapon_1",
    17: "quick_weapon_2",
    18: "quick_weapon_3",
    19: "quick_weapon_4",
    20: "bard_song",
    21: "find_traps",
    22: "select_all",
    23: "formation",
    24: "ai_toggle",
    # --- SoD/EET extended icons (frames 25-75), groups of 3 ---
    # Group: Bard Song (harp icon)
    25: "bard_song_normal",
    26: "bard_song_greyed",
    27: "bard_song_pressed",
    28: "bard_song_highlighted",
    # Group: Shaman Dance (half-face icon)
    29: "shaman_dance_highlighted",
    30: "shaman_dance_normal",
    31: "shaman_dance_greyed",
    # Group: Formation/Move (4 arrows icon)
    32: "formation2_highlighted",
    33: "formation2_pressed",
    34: "formation2_normal",
    35: "formation2_greyed",
    36: "formation2_highlighted2",
    37: "formation2_highlighted3",
    # Group: Polymorph/Shapeshift (animal icon)
    38: "polymorph_highlighted",
    39: "polymorph_pressed",
    40: "polymorph_normal",
    41: "polymorph_greyed",
    42: "polymorph_highlighted2",
    # Group: Arrow Right (narrow, 35x54)
    43: "arrow_right_normal",
    44: "arrow_right_greyed",
    45: "arrow_right_highlighted",
    # Group: Quick Loot / Container (chest icon, narrow 35x54)
    46: "quick_loot_normal",
    47: "quick_loot_greyed",
    48: "quick_loot_highlighted",
    49: "quick_loot_highlighted2",
    # Group: Clairvoyance/Night (stars+moon icon)
    50: "clairvoyance_normal",
    51: "clairvoyance_greyed",
    52: "clairvoyance_highlighted",
    # Group: Sparkle/Special (4-point star icon)
    53: "special_star_normal",
    54: "special_star_greyed",
    55: "special_star_highlighted",
    # Group: Dismiss/Cancel (crossed tools icon)
    56: "dismiss_highlighted",
    57: "dismiss_pressed",
    58: "dismiss_normal",
    59: "dismiss_greyed",
    60: "dismiss_highlighted2",
    61: "dismiss_greyed2",
    # Group: Arrow Left (dagger/blade, narrow)
    62: "arrow_left_highlighted",
    63: "arrow_left_pressed",
    64: "arrow_left_normal",
    65: "arrow_left_greyed",
    66: "arrow_left_highlighted2",
    # Group: Play (triangle arrow icon, narrow)
    67: "play_normal",
    68: "play_greyed",
    69: "play_highlighted",
    # Group: Scroll (parchment icon)
    70: "scroll_normal",
    71: "scroll_greyed",
    72: "scroll_highlighted",
    # Group: Shapeshift/Wildshape (dancing figure icon)
    73: "shapeshift_normal",
    74: "shapeshift_greyed",
    75: "shapeshift_highlighted",
}


# ---------------------------------------------------------------------------
# Main extraction logic
# ---------------------------------------------------------------------------

def extract_bam_v2(loader, bam_resref, bam_search_dirs, outdir, scale=4,
                   frame_names=None, label=None):
    """Extract all frames from a BAM V2 file to PNG.

    bam_search_dirs: list of directories to check for the BAM file
    """
    label = label or bam_resref

    # Find and load BAM file
    bam_data = None
    for d in bam_search_dirs:
        path = os.path.join(d, bam_resref + ".BAM")
        if os.path.exists(path):
            with open(path, "rb") as f:
                bam_data = f.read()
            print(f"  Found {bam_resref}.BAM in {d}")
            break

    if bam_data is None:
        # Try via BIF
        bam_data = loader.load_bam(bam_resref)
        if bam_data:
            print(f"  Found {bam_resref}.BAM in BIF archive")

    if bam_data is None:
        print(f"  ERROR: {bam_resref}.BAM not found")
        return 0

    # Check format
    sig = bam_data[:8]
    if sig != b"BAM V2  ":
        print(f"  SKIP: {bam_resref} is not BAM V2 (sig={sig!r})")
        return 0

    # Parse BAM V2
    frames, blocks, cycles = parse_bam_v2(bam_data)
    print(f"  {bam_resref}: {len(frames)} frames, {len(blocks)} data blocks, {len(cycles)} cycles")

    if not frames:
        return 0

    # Show frame dimensions
    sizes = set((f[0], f[1]) for f in frames)
    print(f"  Frame sizes: {sorted(sizes)}")

    # Preload required PVRZ pages
    pages = get_pvrz_pages_for_bam(frames, blocks)
    print(f"  PVRZ pages needed: {sorted(pages)}")
    loader.preload_pvrz_pages(pages)

    # Create output subdirectory
    sub_outdir = Path(outdir) / label
    sub_outdir.mkdir(parents=True, exist_ok=True)

    # Render and save each frame
    extracted = 0
    for i, frame in enumerate(frames):
        w, h = frame[0], frame[1]
        if w == 0 or h == 0:
            continue

        # Build the PVRZ cache dict for this frame's pages
        pvrz_dict = {}
        for j in range(frame[5]):  # db_cnt
            page = blocks[frame[4] + j][0]
            img = loader.load_pvrz_image(page)
            if img:
                pvrz_dict[page] = img

        frame_img = render_bam_v2_frame(frame, blocks, pvrz_dict)

        # Generate filename
        if frame_names and i in frame_names:
            name = f"{i:03d}_{frame_names[i]}"
        else:
            name = f"{i:03d}"

        # Save original
        orig_path = sub_outdir / f"{name}.png"
        frame_img.save(str(orig_path))

        # Save upscaled
        if scale > 1:
            scaled = frame_img.resize(
                (w * scale, h * scale), Image.NEAREST
            )
            scaled_path = sub_outdir / f"{name}_{scale}x.png"
            scaled.save(str(scaled_path))

        extracted += 1

    print(f"  Extracted {extracted} frames to {sub_outdir}/")
    return extracted


def extract_bam_v1_frames(bam_path, outdir, scale=4, label=None):
    """Extract all frames from a BAM V1 file using the existing parser logic."""
    label = label or Path(bam_path).stem

    with open(bam_path, "rb") as f:
        data = f.read()

    sig = data[:8]
    # Handle BAMC
    if sig[:4] == b"BAMC":
        data = zlib.decompress(data[12:])
        sig = data[:8]

    if sig != b"BAM V1  ":
        print(f"  SKIP: {label} is not BAM V1 (sig={sig!r})")
        return 0

    frame_count = struct.unpack_from("<H", data, 8)[0]
    trans_idx = struct.unpack_from("<B", data, 11)[0]
    frame_entries_off = struct.unpack_from("<I", data, 12)[0]
    palette_off = struct.unpack_from("<I", data, 16)[0]

    # Read palette
    palette = []
    for i in range(256):
        off = palette_off + i * 4
        b, g, r, a = struct.unpack_from("BBBB", data, off)
        palette.append((r, g, b, a))

    sub_outdir = Path(outdir) / label
    sub_outdir.mkdir(parents=True, exist_ok=True)

    extracted = 0
    for fi in range(frame_count):
        off = frame_entries_off + fi * 12
        w = struct.unpack_from("<H", data, off)[0]
        h = struct.unpack_from("<H", data, off + 2)[0]
        frame_data_off = struct.unpack_from("<I", data, off + 8)[0]

        is_rle = not bool(frame_data_off & 0x80000000)
        frame_data_off &= 0x7FFFFFFF

        if w == 0 or h == 0:
            continue

        pixels = []
        if is_rle:
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
            pixels = list(data[frame_data_off:frame_data_off + w * h])

        img = Image.new("RGBA", (w, h))
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

        name = f"{fi:03d}"
        orig_path = sub_outdir / f"{name}.png"
        img.save(str(orig_path))

        if scale > 1:
            scaled = img.resize((w * scale, h * scale), Image.NEAREST)
            scaled_path = sub_outdir / f"{name}_{scale}x.png"
            scaled.save(str(scaled_path))

        extracted += 1

    print(f"  {label}: {frame_count} frames, extracted {extracted} to {sub_outdir}/")
    return extracted


def main():
    parser = argparse.ArgumentParser(description="Extract BAM V2 actionbar icons to PNG")
    parser.add_argument("--gamedir",
                        default="c:/Games/Baldur's Gate II Enhanced Edition modded",
                        help="Game installation directory")
    parser.add_argument("--output", default="tools/icon_reference/actionbar",
                        help="Output directory for PNGs")
    parser.add_argument("--scale", type=int, default=4,
                        help="Upscale factor (default 4x nearest-neighbor)")
    args = parser.parse_args()

    outdir = Path(args.output)
    outdir.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("BAM V2 Actionbar Icon Extractor")
    print("=" * 60)

    # Initialize resource loader
    loader = GameResourceLoader(args.gamedir)
    print(f"Game directory: {args.gamedir}")

    search_dirs = [
        os.path.join(args.gamedir, "override"),
        os.path.join(args.gamedir, "EET", "SoD_GUI"),
    ]

    total = 0

    # -----------------------------------------------------------------------
    # BAM V2 files from EET/SoD_GUI
    # -----------------------------------------------------------------------
    print("\n--- BAM V2 files (EET/SoD_GUI) ---")

    bamv2_files = [
        ("GUIBTACT", GUIBTACT_FRAME_NAMES, "GUIBTACT_actionbar_icons"),
        ("GUIBTBUT", None, "GUIBTBUT_actionbar_buttons"),
        ("GUIBUTMT", None, "GUIBUTMT"),
        ("GUIBUTNS", None, "GUIBUTNS"),
        ("GUIBUTNT", None, "GUIBUTNT"),
        ("GUIBUTST", None, "GUIBUTST"),
        ("GUIBUTWS", None, "GUIBUTWS"),
        ("GUIBUTWT", None, "GUIBUTWT"),
    ]

    for resref, names, label in bamv2_files:
        print(f"\nExtracting {resref}...")
        n = extract_bam_v2(loader, resref, search_dirs, str(outdir),
                           scale=args.scale, frame_names=names, label=label)
        total += n

    # -----------------------------------------------------------------------
    # BAM V1 files (BSME buttons from override)
    # -----------------------------------------------------------------------
    print("\n--- BAM V1 files (BSME/override) ---")

    bamv1_files = [
        "B3INMRK", "B3NUM", "B3SLOT", "B3SLOTD", "B3SLOTG", "B3SLOTGD",
        "B3TAURA", "B3TBACKG", "B3TCONTI", "B3TMODAL",
    ]

    override_dir = os.path.join(args.gamedir, "override")
    for resref in bamv1_files:
        path = os.path.join(override_dir, resref + ".BAM")
        if os.path.exists(path):
            print(f"\nExtracting {resref}...")
            n = extract_bam_v1_frames(path, str(outdir), scale=args.scale, label=resref)
            total += n

    # -----------------------------------------------------------------------
    # Also look for other actionbar/GUI BAMs in EET/SoD_GUI
    # -----------------------------------------------------------------------
    print("\n--- Other GUI BAMs (EET/SoD_GUI) ---")

    other_bams = [
        "CBUTT", "GUMPBUTX", "INVBUT", "ROUNDBUT", "STARTBUT",
        "GUIPFC", "GUIPRC", "GUIPRTC", "GUISCRC", "GUISCRP",
        "GUISTBBC", "GUIGOLD",
    ]

    eet_dir = os.path.join(args.gamedir, "EET", "SoD_GUI")
    for resref in other_bams:
        path = os.path.join(eet_dir, resref + ".BAM")
        if os.path.exists(path):
            with open(path, "rb") as f:
                sig = f.read(8)
            if sig == b"BAM V2  ":
                print(f"\nExtracting {resref} (BAM V2)...")
                n = extract_bam_v2(loader, resref, search_dirs, str(outdir),
                                   scale=args.scale, label=resref)
                total += n
            elif sig == b"BAM V1  " or sig[:4] == b"BAMC":
                print(f"\nExtracting {resref} (BAM V1)...")
                n = extract_bam_v1_frames(path, str(outdir),
                                          scale=args.scale, label=resref)
                total += n

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------
    print("\n" + "=" * 60)
    print(f"Total frames extracted: {total}")
    print(f"Output directory: {outdir.resolve()}")
    print(f"Scale: {args.scale}x nearest-neighbor")
    print("=" * 60)


if __name__ == "__main__":
    main()
