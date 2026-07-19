from __future__ import annotations

import hashlib
import struct
from collections.abc import Iterable
from pathlib import Path


RESOURCE_TYPES = {"ARE": 1010}
ONE_EMPTY_STRING_TLK = (
    struct.pack("<8sHII", b"TLK V1  ", 0, 1, 0x2C)
    + struct.pack("<H8siiII", 0, b"\0" * 8, 0, 0, 0, 0)
)


def write_minimal_tlk(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(ONE_EMPTY_STRING_TLK)


def write_minimal_bg2ee_key_biff(root: Path) -> Path:
    """Write OH6000.ARE in one uncompressed BIFF and index it in chitin.key."""
    resref = "OH6000"
    payload = b"synthetic BG2EE marker"
    resource_type = RESOURCE_TYPES["ARE"]
    bif_relative = Path("DATA/BFBOTST.BIF")
    bif_path = root / bif_relative
    bif_path.parent.mkdir(parents=True, exist_ok=True)

    table_offset = 0x14
    payload_offset = table_offset + 0x10
    bif_path.write_bytes(
        struct.pack("<4s4sIII", b"BIFF", b"V1  ", 1, 0, table_offset)
        + struct.pack("<IIIHH", 0, payload_offset, len(payload), resource_type, 0)
        + payload
    )

    encoded_bif_name = (str(bif_relative).replace("/", "\\") + "\0").encode(
        "ascii"
    )
    bif_table_offset = 0x18
    resource_table_offset = bif_table_offset + 0x0C
    names_offset = resource_table_offset + 0x0E
    key = bytearray(
        struct.pack(
            "<4s4sIIII",
            b"KEY ",
            b"V1  ",
            1,
            1,
            bif_table_offset,
            resource_table_offset,
        )
    )
    key.extend(
        struct.pack(
            "<IIHH",
            bif_path.stat().st_size,
            names_offset,
            len(encoded_bif_name),
            0,
        )
    )
    key.extend(
        struct.pack(
            "<8sHI",
            resref.encode("ascii").ljust(8, b"\0"),
            resource_type,
            0,
        )
    )
    key.extend(encoded_bif_name)
    (root / "chitin.key").write_bytes(key)
    return bif_path


def tree_hashes(root: Path, relative_paths: Iterable[str | Path]) -> dict[str, str]:
    """Hash named files/trees; preserve absence and reject case collisions."""
    result: dict[str, str] = {}
    for relative in relative_paths:
        relative = Path(relative)
        path = root / relative
        paths = (
            sorted(candidate for candidate in path.rglob("*") if candidate.is_file())
            if path.is_dir()
            else [path]
        )
        for candidate in paths:
            key = candidate.relative_to(root).as_posix().casefold()
            if key in result:
                raise AssertionError(f"case-colliding synthetic file: {key}")
            result[key] = (
                hashlib.sha256(candidate.read_bytes()).hexdigest()
                if candidate.is_file()
                else "<missing>"
            )
    return result
