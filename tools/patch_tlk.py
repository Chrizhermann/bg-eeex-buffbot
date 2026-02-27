#!/usr/bin/env python3
"""patch_tlk.py — Append BuffBot innate ability names to dialog.tlk

Usage: python3 patch_tlk.py <dialog.tlk path> <strrefs output path>

Idempotent: checks if BuffBot strings already exist before patching.
Writes the base strref (first added entry) to the output file.

TLK V1 format:
  Header (18 bytes): sig(4) ver(4) lang(2) str_count(4) str_data_offset(4)
  Entry (26 bytes):  flags(2) sound(8) volvar(4) pitchvar(4) offset(4) length(4)
  String data:       raw text at str_data_offset
"""

import struct
import sys
import os
import shutil

STRINGS = [
    "BuffBot 1",
    "BuffBot 2",
    "BuffBot 3",
    "BuffBot 4",
    "BuffBot 5",
]

MARKER = "BuffBot 1"  # check last entries for this to detect prior patching

HEADER_SIZE = 18
ENTRY_SIZE = 26


def read_header(data):
    sig = data[0:4]
    ver = data[4:8]
    if sig != b"TLK " or ver != b"V1  ":
        raise ValueError(f"Not a valid TLK V1 file (sig={sig}, ver={ver})")
    lang = struct.unpack_from("<H", data, 8)[0]
    str_count = struct.unpack_from("<I", data, 10)[0]
    str_data_offset = struct.unpack_from("<I", data, 14)[0]
    return lang, str_count, str_data_offset


def read_entry(data, index, str_data_offset):
    offset = HEADER_SIZE + index * ENTRY_SIZE
    flags = struct.unpack_from("<H", data, offset)[0]
    text_offset = struct.unpack_from("<I", data, offset + 18)[0]
    text_length = struct.unpack_from("<I", data, offset + 22)[0]
    text = ""
    if flags & 1 and text_length > 0:
        start = str_data_offset + text_offset
        text = data[start:start + text_length].decode("utf-8", errors="replace")
    return text


def is_already_patched(data, str_count, str_data_offset):
    """Check if the last few entries contain our marker string."""
    check_count = min(10, str_count)
    for i in range(str_count - check_count, str_count):
        text = read_entry(data, i, str_data_offset)
        if text == MARKER:
            return True
    return False


def find_existing_base_strref(data, str_count, str_data_offset):
    """If already patched, find the strref of the first BuffBot entry."""
    for i in range(str_count - 10, str_count):
        if i < 0:
            continue
        text = read_entry(data, i, str_data_offset)
        if text == MARKER:
            return i
    return None


def patch_tlk(tlk_path, strrefs_path):
    with open(tlk_path, "rb") as f:
        data = bytearray(f.read())

    lang, str_count, str_data_offset = read_header(data)
    print(f"  dialog.tlk: {str_count} strings, {len(data)} bytes")

    if is_already_patched(data, str_count, str_data_offset):
        base = find_existing_base_strref(data, str_count, str_data_offset)
        print(f"  Already patched (base strref = {base}). Skipping.")
        with open(strrefs_path, "w") as sf:
            sf.write(str(base) + "\n")
        return

    # Backup original
    backup_path = tlk_path + ".bfbot_backup"
    if not os.path.exists(backup_path):
        shutil.copy2(tlk_path, backup_path)
        print(f"  Backup saved to {backup_path}")

    # Split file into: header + entries + string_data
    entries_end = HEADER_SIZE + str_count * ENTRY_SIZE
    header = data[:HEADER_SIZE]
    entries = data[HEADER_SIZE:entries_end]
    string_data = data[str_data_offset:]

    # Current string data length (for new entry offsets)
    existing_str_data_len = len(string_data)

    # Build new entries and string data
    new_entries = bytearray()
    new_string_data = bytearray()
    new_data_offset = existing_str_data_len

    base_strref = str_count  # first new strref

    for s in STRINGS:
        text_bytes = s.encode("utf-8")
        # Entry: flags=1 (has text), sound=8 zero bytes, volvar=0, pitchvar=0, offset, length
        entry = struct.pack("<H", 1)           # flags: has text
        entry += b"\x00" * 8                   # sound resref
        entry += struct.pack("<I", 0)          # volume variance
        entry += struct.pack("<I", 0)          # pitch variance
        entry += struct.pack("<I", new_data_offset)  # offset into string data
        entry += struct.pack("<I", len(text_bytes))   # string length
        new_entries += entry
        new_string_data += text_bytes
        new_data_offset += len(text_bytes)

    # Update header
    new_str_count = str_count + len(STRINGS)
    new_str_data_offset = HEADER_SIZE + new_str_count * ENTRY_SIZE

    new_header = header[:10]
    new_header += struct.pack("<I", new_str_count)
    new_header += struct.pack("<I", new_str_data_offset)

    # Assemble: header + old entries + new entries + old string data + new string data
    output = bytes(new_header) + bytes(entries) + bytes(new_entries) + bytes(string_data) + bytes(new_string_data)

    with open(tlk_path, "wb") as f:
        f.write(output)

    print(f"  Patched: added {len(STRINGS)} strings (strrefs {base_strref}-{base_strref + len(STRINGS) - 1})")
    print(f"  New total: {new_str_count} strings, {len(output)} bytes")

    # Write base strref for Lua to read
    with open(strrefs_path, "w") as sf:
        sf.write(str(base_strref) + "\n")
    print(f"  Base strref written to {strrefs_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <dialog.tlk> <strrefs_output>")
        sys.exit(1)

    tlk_path = sys.argv[1]
    strrefs_path = sys.argv[2]

    if not os.path.exists(tlk_path):
        print(f"ERROR: {tlk_path} not found")
        sys.exit(1)

    print("Patching dialog.tlk with BuffBot innate names...")
    patch_tlk(tlk_path, strrefs_path)
    print("Done.")
