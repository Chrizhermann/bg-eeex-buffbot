#!/usr/bin/env python3
"""Convert PNG images to the Infinity Engine's PVRZ format (DXT5 / BC3).

PVRZ wire format:
    uint32 uncompressed_size   (little-endian)
    zlib_deflate(
        PVR3 header (52 bytes):
            uint32 version     = 0x03525650  ('P' 'V' 'R' 3)
            uint32 flags       = 0
            uint64 pixel_fmt   = 11           (DXT5 / BC3)
            uint32 colorspace  = 0            (lRGB)
            uint32 chan_type   = 0            (unsigned byte normalized)
            uint32 height
            uint32 width
            uint32 depth       = 1
            uint32 num_surf    = 1
            uint32 num_faces   = 1
            uint32 num_mipmap  = 1
            uint32 meta_size   = 0
        DXT5 compressed pixel data           (w*h bytes for BC3, 1 byte/pixel)
    )

Usage:
    # Convenience modes — emit all theme PVRZs into buffbot/
    python tools/png_to_pvrz.py --theme sod
    python tools/png_to_pvrz.py --theme bg1

    # Single-file mode — resize to --width/--height (must be multiples of 4),
    # default 512x512.
    python tools/png_to_pvrz.py <input.png> <output.pvrz> \\
        [--width N] [--height N]

Produces (theme modes):
    SOD:  buffbot/MOS9910.PVRZ .. MOS9913.PVRZ (background slices)
          buffbot/BFBOTFR2.PVRZ                (512x512 9-slice border)
    BG1:  buffbot/MOS9920.PVRZ .. MOS9923.PVRZ
          buffbot/BFBOTFR3.PVRZ

The DXT5 compressor here is the same pure-Python implementation used by
tools/img_to_mos.py and tools/extract_border.py.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import zlib
from pathlib import Path

from PIL import Image


# ---------------------------------------------------------------------------
# DXT5 compression (BC3) — pure Python, adapted from tools/img_to_mos.py
# ---------------------------------------------------------------------------

def rgb_to_565(r: int, g: int, b: int) -> int:
    """Convert 8-bit RGB to 16-bit RGB565."""
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def rgb565_to_rgb(c: int) -> tuple[int, int, int]:
    """Convert 16-bit RGB565 back to 8-bit RGB."""
    r = ((c >> 11) & 0x1F) * 255 // 31
    g = ((c >> 5) & 0x3F) * 255 // 63
    b = (c & 0x1F) * 255 // 31
    return r, g, b


def color_distance(c1, c2):
    return (c1[0] - c2[0]) ** 2 + (c1[1] - c2[1]) ** 2 + (c1[2] - c2[2]) ** 2


def compress_dxt5_block(pixels_rgba):
    """Compress a 4x4 block of RGBA pixels to DXT5 (16 bytes)."""
    # --- Alpha block (8 bytes) ---
    alphas = [p[3] for p in pixels_rgba]
    alpha0 = max(alphas)
    alpha1 = min(alphas)

    if alpha0 == alpha1:
        alpha_bytes = struct.pack("<BB", alpha0, alpha1) + b"\x00\x00\x00\x00\x00\x00"
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

        alpha_bytes = struct.pack("<BB", alpha0, alpha1)
        alpha_bytes += struct.pack("<HI", bits & 0xFFFF, (bits >> 16) & 0xFFFFFFFF)

    # --- Color block (8 bytes) ---
    rgbs = [(p[0], p[1], p[2]) for p in pixels_rgba]

    min_c = min(rgbs, key=lambda c: c[0] * 0.3 + c[1] * 0.6 + c[2] * 0.1)
    max_c = max(rgbs, key=lambda c: c[0] * 0.3 + c[1] * 0.6 + c[2] * 0.1)

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
        c0,
        c1,
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

    color_bytes = struct.pack("<HHI", color0, color1, indices)
    return alpha_bytes + color_bytes


def compress_image_dxt5(img: Image.Image) -> bytes:
    """Compress a PIL image to raw DXT5 data.

    Image must be RGBA and have dimensions that are multiples of 4.
    """
    w, h = img.size
    if w % 4 != 0 or h % 4 != 0:
        raise ValueError(
            f"DXT5 requires dimensions to be multiples of 4, got {w}x{h}"
        )

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


# ---------------------------------------------------------------------------
# PVRZ encoder
# ---------------------------------------------------------------------------

def create_pvrz_bytes(img: Image.Image) -> bytes:
    """Encode a PIL image as PVRZ (PVR3 + DXT5, wrapped in uint32 size + zlib).

    Image must be RGBA with dimensions that are multiples of 4.
    """
    w, h = img.size

    dxt_data = compress_image_dxt5(img)

    # PVR3 header (52 bytes)
    pvr3 = struct.pack("<I", 0x03525650)      # version "PVR\x03"
    pvr3 += struct.pack("<I", 0)               # flags
    pvr3 += struct.pack("<Q", 11)              # pixel format = DXT5 (BC3)
    pvr3 += struct.pack("<I", 0)               # colorspace (lRGB)
    pvr3 += struct.pack("<I", 0)               # channel type (ubyte normalized)
    pvr3 += struct.pack("<I", h)               # height
    pvr3 += struct.pack("<I", w)               # width
    pvr3 += struct.pack("<I", 1)               # depth
    pvr3 += struct.pack("<I", 1)               # num surfaces
    pvr3 += struct.pack("<I", 1)               # num faces
    pvr3 += struct.pack("<I", 1)               # num mipmaps
    pvr3 += struct.pack("<I", 0)               # metadata size

    uncompressed = pvr3 + dxt_data
    compressed = zlib.compress(uncompressed, 9)

    return struct.pack("<I", len(uncompressed)) + compressed


def write_pvrz(img: Image.Image, out_path: Path) -> int:
    """Encode and write a PVRZ file. Returns byte count written."""
    data = create_pvrz_bytes(img)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(data)
    return len(data)


def verify_pvrz(path: Path) -> None:
    """Round-trip sanity check: decompress and verify header."""
    with open(path, "rb") as f:
        raw = f.read()
    if len(raw) < 4:
        raise ValueError(f"{path}: file too small")
    (uncompressed_size,) = struct.unpack("<I", raw[:4])
    try:
        decompressed = zlib.decompress(raw[4:])
    except zlib.error as e:
        raise ValueError(f"{path}: zlib decompress failed: {e}") from e
    if len(decompressed) != uncompressed_size:
        raise ValueError(
            f"{path}: uncompressed size mismatch — "
            f"header says {uncompressed_size}, got {len(decompressed)}"
        )
    if len(decompressed) < 52:
        raise ValueError(f"{path}: decompressed payload too small for PVR3 header")
    (version,) = struct.unpack("<I", decompressed[:4])
    if version != 0x03525650:
        raise ValueError(
            f"{path}: bad PVR3 version 0x{version:08x} (expected 0x03525650)"
        )
    (pixel_format,) = struct.unpack("<Q", decompressed[8:16])
    if pixel_format != 11:
        raise ValueError(
            f"{path}: pixel format {pixel_format} (expected 11 / DXT5)"
        )


# ---------------------------------------------------------------------------
# Image preparation helpers
# ---------------------------------------------------------------------------

def load_rgba(path: Path) -> Image.Image:
    """Load a PNG and return it in RGBA mode."""
    if not path.exists():
        raise FileNotFoundError(f"Input PNG not found: {path}")
    img = Image.open(path).convert("RGBA")
    return img


def ensure_multiple_of_4(w: int, h: int) -> None:
    if w % 4 != 0 or h % 4 != 0:
        raise ValueError(
            f"Dimensions must be multiples of 4 for DXT5, got {w}x{h}"
        )


def resize_exact(img: Image.Image, w: int, h: int) -> Image.Image:
    ensure_multiple_of_4(w, h)
    return img.resize((w, h), Image.LANCZOS)


# Background slicing layout — the source is resized to 2048x1152 then split
# into 4 sub-images that fit PVRZ's native 1024-wide pages.
BG_TARGET_W, BG_TARGET_H = 2048, 1152
BG_SLICES = [
    # (slot_idx, left, top, right, bottom)
    (0, 0,    0,    1024, 1024),  # top-left     1024x1024
    (1, 1024, 0,    2048, 1024),  # top-right    1024x1024
    (2, 0,    1024, 1024, 1152),  # bottom-left  1024x128
    (3, 1024, 1024, 2048, 1152),  # bottom-right 1024x128
]


def slice_background(bg_img: Image.Image) -> list[tuple[int, Image.Image]]:
    """Return [(slot_idx, PIL image), ...] for the 4 PVRZ background tiles."""
    resized = bg_img.resize((BG_TARGET_W, BG_TARGET_H), Image.LANCZOS)
    out = []
    for slot, left, top, right, bottom in BG_SLICES:
        tile = resized.crop((left, top, right, bottom))
        out.append((slot, tile))
    return out


# ---------------------------------------------------------------------------
# Theme modes
# ---------------------------------------------------------------------------

# Project root is the parent of tools/ — resolved at runtime.
_SCRIPT_DIR = Path(__file__).resolve().parent
_PROJECT_ROOT = _SCRIPT_DIR.parent


THEMES = {
    # name -> {bg_src, border_src, mos_base (first number), border_out}
    "sod": {
        "bg_src": "assets/themes/sod_background.png",
        "border_src": "assets/themes/sod_border.png",
        "mos_base": 9910,                    # MOS9910..MOS9913
        "border_out": "buffbot/BFBOTFR2.PVRZ",
    },
    "bg1": {
        "bg_src": "assets/themes/bg1_background.png",
        "border_src": "assets/themes/bg1_border.png",
        "mos_base": 9920,                    # MOS9920..MOS9923
        "border_out": "buffbot/BFBOTFR3.PVRZ",
    },
}


def run_theme(theme_name: str) -> None:
    """Convert a named theme's background + border PNGs into PVRZ files."""
    if theme_name not in THEMES:
        raise ValueError(
            f"Unknown theme {theme_name!r}; known: {sorted(THEMES)}"
        )
    cfg = THEMES[theme_name]

    bg_src = _PROJECT_ROOT / cfg["bg_src"]
    border_src = _PROJECT_ROOT / cfg["border_src"]
    mos_base = cfg["mos_base"]
    border_out = _PROJECT_ROOT / cfg["border_out"]
    out_dir = _PROJECT_ROOT / "buffbot"

    print(f"=== theme: {theme_name} ===")
    print(f"  bg_src:     {bg_src}")
    print(f"  border_src: {border_src}")
    print(f"  mos_base:   MOS{mos_base}..MOS{mos_base + 3}")
    print(f"  border_out: {border_out.name}")

    # --- Backgrounds ---
    bg_img = load_rgba(bg_src)
    print(f"  bg source size: {bg_img.size[0]}x{bg_img.size[1]}")
    print(f"  resize target:  {BG_TARGET_W}x{BG_TARGET_H}")
    slices = slice_background(bg_img)
    for slot_idx, tile in slices:
        out_name = f"MOS{mos_base + slot_idx}.PVRZ"
        out_path = out_dir / out_name
        n = write_pvrz(tile, out_path)
        verify_pvrz(out_path)
        print(f"    {out_name}: {tile.size[0]}x{tile.size[1]} -> {n} bytes")

    # --- Border (resize to exactly 512x512) ---
    br_img = load_rgba(border_src)
    print(f"  border source size: {br_img.size[0]}x{br_img.size[1]}")
    br_resized = resize_exact(br_img, 512, 512)
    n = write_pvrz(br_resized, border_out)
    verify_pvrz(border_out)
    print(f"    {border_out.name}: 512x512 -> {n} bytes")

    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Convert PNG images to BG:EE PVRZ (DXT5) textures.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python tools/png_to_pvrz.py --theme sod\n"
            "  python tools/png_to_pvrz.py --theme bg1\n"
            "  python tools/png_to_pvrz.py in.png out.PVRZ\n"
            "  python tools/png_to_pvrz.py in.png out.PVRZ --width 512 --height 512\n"
        ),
    )
    p.add_argument(
        "--theme",
        choices=sorted(THEMES),
        help="Convert all files for a named theme (sod or bg1).",
    )
    p.add_argument("input", nargs="?", help="Input PNG path (single-file mode).")
    p.add_argument("output", nargs="?", help="Output PVRZ path (single-file mode).")
    p.add_argument("--width", type=int, default=None,
                   help="Resize width (must be multiple of 4). Default: 512.")
    p.add_argument("--height", type=int, default=None,
                   help="Resize height (must be multiple of 4). Default: 512.")
    return p


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)

    if args.theme:
        if args.input or args.output:
            print(
                "error: --theme cannot be combined with input/output positional args",
                file=sys.stderr,
            )
            return 2
        try:
            run_theme(args.theme)
        except (FileNotFoundError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        return 0

    # Single-file mode
    if not args.input or not args.output:
        print(
            "error: need either --theme or <input.png> <output.pvrz>",
            file=sys.stderr,
        )
        return 2

    in_path = Path(args.input)
    out_path = Path(args.output)
    width = args.width if args.width is not None else 512
    height = args.height if args.height is not None else 512

    try:
        img = load_rgba(in_path)
        print(f"Input:  {in_path} ({img.size[0]}x{img.size[1]}, {img.mode})")
        img = resize_exact(img, width, height)
        n = write_pvrz(img, out_path)
        verify_pvrz(out_path)
        print(f"Output: {out_path} ({width}x{height}, {n} bytes)")
    except (FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
