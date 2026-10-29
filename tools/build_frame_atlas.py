#!/usr/bin/env python3
"""Build the panel's 9-slice frame atlases from Pecca's rail and corner art.

    python -I tools/build_frame_atlas.py              # write all three
    python -I tools/build_frame_atlas.py --preview out/   # also dump PNGs

One atlas per accent (`BFBOTFR` BG1, `BFBOTFR2` BG2, `BFBOTFR3` SoD), each
256x128 and laid out the way `BfBot.UI` registers it:

    +--------+------------+--------+
    | 38x28  |  180x28    | 38x28  |   corners and the horizontal rail
    +--------+------------+--------+
    | 38x72  |  180x72    | 38x72  |   the vertical rails; centre is empty
    +--------+------------+--------+
    | 38x28  |  180x28    | 38x28  |
    +--------+------------+--------+

Two things here are read off the art rather than assumed, because assuming
them is what shipped a panel with its bottom corners facing outward. The
accent names above come from the games' own box and title art, which is what
the parchments were cut from -- BG1 brown leather, BG2 blue-teal, SoD red.
Do not re-derive them from a UI resource; that shipped them wrong twice
(#102).

* **The cycle is the skin**, in the same order every BuffBot BAM uses it --
  0 BG:EE, 1 IWD, 2 SoD, 3 BG2. BuffBot has no IWD accent.
* **`BFBCORN` carries the two *diagonal* corners**, not a corner and a state:
  frame 0 is the top-left, frame 1 the bottom-right. The other two are those
  mirrored horizontally. Mirroring frame 0 downwards instead, or using frame
  1 as the bottom-left, turns the ornament outward -- which is how it looked
  in game.

The rails are ten-pixel strips whose visible line sits in the last four
(rows 6..9 of `BFBRAH`, columns 6..9 of `BFBRAV`). A corner's own line runs
along its outer edge, so only that four-pixel line is taken, flush with the
atlas edge; laying the whole strip down instead leaves the frame open at
every corner.
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
VISUAL = ROOT / "buffbot" / "visual"

# accent -> (atlas resref, skin cycle)
ATLASES = {
    "bg1": ("BFBOTFR", 3),
    "bg2": ("BFBOTFR2", 2),
    "sod": ("BFBOTFR3", 0),
}

ATLAS_W, ATLAS_H = 256, 128
CORNER_W, CORNER_H = 38, 28
RAIL = 4                      # the visible line inside a ten-pixel strip
RAIL_AT = slice(6, 10)


def _load(module: str, path: Path):
    spec = importlib.util.spec_from_file_location(module, path)
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[module] = loaded
    spec.loader.exec_module(loaded)
    return loaded


bam = _load("bfbot_bam", ROOT / "tools" / "extract_bamv2.py")
pvrz = _load("bfbot_pvrz", ROOT / "tools" / "png_to_pvrz.py")


def frames_of(resref: str, cycle: int) -> list[Image.Image]:
    """Every frame of one cycle of a BAM V2 in buffbot/visual, as RGBA."""
    frames, blocks, cycles = bam.parse_bam_v2((VISUAL / f"{resref}.BAM").read_bytes())
    pages: dict[int, Image.Image | None] = {}
    for page, *_ in blocks:
        if page not in pages:
            page_file = VISUAL / f"MOS{page:05d}.PVRZ"
            pages[page] = (
                bam.decode_pvrz(page_file.read_bytes()) if page_file.exists() else None
            )
    count, first = cycles[cycle]
    return [
        bam.render_bam_v2_frame(frames[first + index], blocks, pages)
        for index in range(count)
    ]


# Three pure-yellow pixels sit in the middle of the BG2 bottom corner's
# boss -- (255, 235, 49), a colour that appears nowhere else in any of the
# eight corner frames, in art that is otherwise muted gold and slate. It is
# a marker left in the source, and it lands on both bottom corners of the
# default theme. The BAM is left alone; the atlas paints those pixels from
# the ring above and below them.
STRAY = (255, 235, 49)


def repair_stray(piece: Image.Image) -> Image.Image:
    """Blend out single-colour marker pixels, column by column."""
    piece = piece.copy()
    px = piece.load()
    for x in range(piece.width):
        runs, start = [], None
        for y in range(piece.height):
            stray = px[x, y][:3] == STRAY and px[x, y][3] > 0
            if stray and start is None:
                start = y
            elif not stray and start is not None:
                runs.append((start, y - 1))
                start = None
        if start is not None:
            runs.append((start, piece.height - 1))
        for first, last in runs:
            above = px[x, first - 1] if first > 0 else None
            below = px[x, last + 1] if last + 1 < piece.height else None
            if above is None or below is None:
                continue
            span = last - first + 2
            for index, y in enumerate(range(first, last + 1), start=1):
                t = index / span
                px[x, y] = tuple(
                    round(above[c] * (1 - t) + below[c] * t) for c in range(4)
                )
    return piece


def build(cycle: int) -> Image.Image:
    atlas = Image.new("RGBA", (ATLAS_W, ATLAS_H), (0, 0, 0, 0))

    top_left, bottom_right = (repair_stray(f) for f in frames_of("BFBCORN", cycle))
    for piece, xy in (
        (top_left, (0, 0)),
        (top_left.transpose(Image.FLIP_LEFT_RIGHT), (ATLAS_W - CORNER_W, 0)),
        (bottom_right.transpose(Image.FLIP_LEFT_RIGHT), (0, ATLAS_H - CORNER_H)),
        (bottom_right, (ATLAS_W - CORNER_W, ATLAS_H - CORNER_H)),
    ):
        if piece.size != (CORNER_W, CORNER_H):
            raise SystemExit(f"BFBCORN cycle {cycle}: expected a "
                             f"{CORNER_W}x{CORNER_H} corner, got {piece.size}")
        atlas.paste(piece, xy)

    # A slice from the middle of each rail: they are uniform, and the engine
    # stretches whatever is here across the edge anyway.
    edge_w = ATLAS_W - 2 * CORNER_W
    edge_h = ATLAS_H - 2 * CORNER_H

    horizontal = frames_of("BFBRAH", cycle)[0]
    start = (horizontal.width - edge_w) // 2
    line = horizontal.crop((start, RAIL_AT.start, start + edge_w, RAIL_AT.stop))
    atlas.paste(line, (CORNER_W, 0))
    atlas.paste(line.transpose(Image.FLIP_TOP_BOTTOM), (CORNER_W, ATLAS_H - RAIL))

    vertical = frames_of("BFBRAV", cycle)[0]
    start = (vertical.height - edge_h) // 2
    line = vertical.crop((RAIL_AT.start, start, RAIL_AT.stop, start + edge_h))
    atlas.paste(line, (0, CORNER_H))
    atlas.paste(line.transpose(Image.FLIP_LEFT_RIGHT), (ATLAS_W - RAIL, CORNER_H))

    return atlas


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", type=Path,
                        help="also write each atlas as a PNG into this directory")
    parser.add_argument("--accent", choices=sorted(ATLASES), action="append",
                        help="build only this accent (repeatable)")
    args = parser.parse_args(argv)

    wanted = args.accent or sorted(ATLASES)
    if args.preview:
        args.preview.mkdir(parents=True, exist_ok=True)

    for accent in wanted:
        resref, cycle = ATLASES[accent]
        atlas = build(cycle)
        written = pvrz.write_pvrz(atlas, ROOT / "buffbot" / f"{resref}.PVRZ")
        print(f"{accent:4s} -> {resref}.PVRZ  (skin cycle {cycle}, {written} bytes)")
        if args.preview:
            atlas.save(args.preview / f"{resref}.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
