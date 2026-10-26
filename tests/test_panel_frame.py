"""The panel's 9-slice frame atlases carry the right corners, the right way up.

Two bugs shipped here, and neither could fail a test that only reads source:
the bottom corners were the *other* diagonal, so their ornament pointed out
of the panel instead of along the rail, and the accent-to-skin mapping was
swapped, so SoD's slate panel wore BG:EE's wine-red wedge. Both are visible
only in the pixels, so that is what this reads.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

PIL = pytest.importorskip("PIL.Image", reason="Pillow is needed to read the art")
from PIL import Image  # noqa: E402  (after the skip)

ROOT = Path(__file__).resolve().parents[1]


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


bam = _load("bfbot_test_bam", ROOT / "tools" / "extract_bamv2.py")
builder = _load("bfbot_test_frame", ROOT / "tools" / "build_frame_atlas.py")

# Where each corner sits in the 256x128 atlas, as BfBot.UI registers it.
CORNERS = {
    "topLeft": (0, 0),
    "topRight": (218, 0),
    "bottomLeft": (0, 100),
    "bottomRight": (218, 100),
}
W, H = builder.CORNER_W, builder.CORNER_H


def _variants(top_left: Image.Image, bottom_right: Image.Image) -> dict[str, Image.Image]:
    """The four things a corner slot could plausibly hold."""
    return {
        "topLeft": top_left,
        "topRight": top_left.transpose(Image.FLIP_LEFT_RIGHT),
        "bottomRight": bottom_right,
        "bottomLeft": bottom_right.transpose(Image.FLIP_LEFT_RIGHT),
    }


def _distance(a: Image.Image, b: Image.Image) -> float:
    """Mean per-channel difference over the pixels the candidate paints.

    DXT5 costs up to ~50 on a single pixel where warm gold meets cold slate
    inside one 4x4 block, so this never asks for equality -- only that the
    right candidate is the closest one by a wide margin.
    """
    pa, pb = a.convert("RGBA").load(), b.convert("RGBA").load()
    total, count = 0, 0
    for y in range(H):
        for x in range(W):
            if pb[x, y][3] < 200:
                continue
            total += sum(abs(pa[x, y][c] - pb[x, y][c]) for c in range(3)) / 3
            count += 1
    assert count, "the candidate corner is empty"
    return total / count


@pytest.mark.parametrize("accent", sorted(builder.ATLASES))
def test_every_frame_corner_is_the_one_that_belongs_there(accent: str) -> None:
    resref, cycle = builder.ATLASES[accent]
    atlas = bam.decode_pvrz((ROOT / "buffbot" / f"{resref}.PVRZ").read_bytes())
    assert atlas.size == (builder.ATLAS_W, builder.ATLAS_H)

    top_left, bottom_right = (
        builder.repair_stray(frame) for frame in builder.frames_of("BFBCORN", cycle)
    )
    candidates = _variants(top_left, bottom_right)

    for slot, (x, y) in CORNERS.items():
        drawn = atlas.crop((x, y, x + W, y + H))
        scores = {name: _distance(drawn, piece) for name, piece in candidates.items()}
        best = min(scores, key=scores.get)
        assert best == slot, f"{resref} {slot} holds {best}: {scores}"
        # And not by a hair: a mirrored corner scores an order worse.
        runner_up = min(score for name, score in scores.items() if name != slot)
        assert scores[slot] * 4 < runner_up, f"{resref} {slot}: {scores}"


def test_each_accent_draws_its_own_skin() -> None:
    """The frame follows the same skin order as every other BuffBot BAM."""
    from test_panel_chrome import CONTROL_SKINS

    assert {accent: cycle for accent, (_, cycle) in builder.ATLASES.items()} == (
        CONTROL_SKINS
    )


def test_the_shipped_atlases_are_what_the_builder_makes() -> None:
    """Hand-edited art drifts; this keeps the PVRZ and tools/ in step."""
    for accent, (resref, cycle) in builder.ATLASES.items():
        shipped = bam.decode_pvrz((ROOT / "buffbot" / f"{resref}.PVRZ").read_bytes())
        rebuilt = bam.decode_pvrz(builder.pvrz.create_pvrz_bytes(builder.build(cycle)))
        assert shipped.tobytes() == rebuilt.tobytes(), accent
