#!/bin/bash
# Build the player-facing BuffBot release archive from an explicit allowlist.
#
# Usage:
#   bash tools/build-release.sh /path/to/setup-buffbot.exe /path/to/buffbot-v1.2.3.zip

set -euo pipefail

usage() {
    echo "Usage: $0 INSTALLER_PATH OUTPUT_ZIP" >&2
    exit 2
}

[ "$#" -eq 2 ] || usage
INSTALLER="$1"
OUTPUT="$2"
[ -f "$INSTALLER" ] || { echo "ERROR: installer not found: $INSTALLER" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
OUTPUT="$OUTPUT_DIR/$(basename "$OUTPUT")"

if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
else
    echo "ERROR: release packaging requires Python 3" >&2
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

"$PYTHON_BIN" - "$REPO_DIR" "$INSTALLER" "$OUTPUT" "$STAGING" <<'PY'
import os
import json
import hashlib
import re
import shutil
import sys
import tempfile
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

repo = Path(sys.argv[1]).resolve()
installer = Path(sys.argv[2]).resolve()
output_argument = Path(sys.argv[3])
if output_argument.is_symlink():
    raise SystemExit("ERROR: output ZIP must not be a symlink")
output = output_argument.parent.resolve() / output_argument.name
staging = Path(sys.argv[4]).resolve()

root_files = (
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    "docs/5e-spellcasting.md",
    "docs/plan-management-and-casting-beta.md",
    "docs/buffbot-original-vs-redux.md",
    "docs/compatibility-test-report.md",
    "docs/fast-forward-performance-investigation.md",
    "buffbot/BfBotVA.json",
    "buffbot/BfBotVA.txt",
)
buffbot_files = (
    "setup-buffbot.tp2",
    "M_BfBot.lua",
    "BfBotCor.lua",
    "BfBotLoc.lua",
    "BfBotThm.lua",
    "BfBotCls.lua",
    "BfBotScn.lua",
    "BfBot5e.lua",
    "BfBotExe.lua",
    "BfBotMp.lua",
    "BfBotPer.lua",
    "BfBotPln.lua",
    "BfBotIO.lua",
    "BfBotShr.lua",
    "BfBotFst.lua",
    "BfBotRst.lua",
    "BfBotPUI.lua",
    "BfBotVD.lua",
    "BfBotVis.lua",
    "BfBotRx.menu",
    "BfBotInn.lua",
    "BfBotUI.lua",
    "BfBotTst.lua",
    "BuffBot.menu",
    "BFBOTAB.BAM",
    "BFBOTIB.BAM",
    "BFBOTBG.MOS",
    "BFBOTFR.PVRZ",
    "BFBOTFR2.PVRZ",
    "BFBOTFR3.PVRZ",
    "MOS9900.PVRZ",
    "MOS9901.PVRZ",
    "MOS9902.PVRZ",
    "MOS9903.PVRZ",
    "MOS9910.PVRZ",
    "MOS9911.PVRZ",
    "MOS9912.PVRZ",
    "MOS9913.PVRZ",
    "MOS9920.PVRZ",
    "MOS9921.PVRZ",
    "MOS9922.PVRZ",
    "MOS9923.PVRZ",
)
allowed_suffixes = {".tp2", ".lua", ".menu", ".bam", ".mos", ".pvrz"}


def fail(message):
    raise SystemExit("ERROR: " + message)


def reject_casefold_collisions(paths):
    seen = {}
    for path in sorted(paths):
        folded = path.casefold()
        prior = seen.get(folded)
        if prior is not None and prior != path:
            fail(f"case-insensitive path collision: {prior} and {path}")
        seen[folded] = path


if not installer.is_file():
    fail(f"installer not found: {installer}")
if installer == output:
    fail("installer and output ZIP must be different files")

buffbot_root = repo / "buffbot"
expected_top = {f"buffbot/{name}" for name in buffbot_files}
actual_top = {
    f"buffbot/{path.name}"
    for path in buffbot_root.iterdir()
    if path.is_file() and path.suffix.casefold() in allowed_suffixes
}
reject_casefold_collisions(actual_top)

missing_top = sorted(expected_top - actual_top)
if missing_top:
    fail("missing required release file(s): " + ", ".join(missing_top))
unexpected_top = sorted(actual_top - expected_top)
if unexpected_top:
    fail("unexpected release file(s): " + ", ".join(unexpected_top))

tp2_path = repo / "buffbot/setup-buffbot.tp2"
try:
    tp2 = tp2_path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    fail(f"cannot read buffbot/setup-buffbot.tp2: {error}")

language_count = len(re.findall(r"(?m)^[ \t]*LANGUAGE[ \t]*$", tp2))
language_rows = re.findall(
    r"(?m)^[ \t]*LANGUAGE[ \t]*\r?\n"
    r"[ \t]*~[^~\r\n]*~[ \t]*\r?\n"
    r"[ \t]*~([a-z0-9_-]+)~[ \t]*\r?\n"
    r"[ \t]*~(buffbot/lang/([a-z0-9_-]+)/setup\.tra)~[ \t]*$",
    tp2,
)
if not language_rows or len(language_rows) != language_count:
    fail("every TP2 LANGUAGE declaration must use a lowercase buffbot/lang folder")

catalog_files = []
for language_name, relative, folder in language_rows:
    if language_name != folder:
        fail(f"TP2 LANGUAGE name/folder mismatch: {language_name} != {folder}")
    catalog_files.append(relative)
reject_casefold_collisions(catalog_files)
if len(set(catalog_files)) != len(catalog_files):
    fail("duplicate TP2 LANGUAGE catalog declaration")

lang_root = repo / "buffbot/lang"
actual_catalogs = {
    path.relative_to(repo).as_posix()
    for path in lang_root.rglob("*")
    if path.is_file()
}
reject_casefold_collisions(actual_catalogs)
declared_catalogs = set(catalog_files)
missing_catalogs = sorted(declared_catalogs - actual_catalogs)
if missing_catalogs:
    fail("missing required release file(s): " + ", ".join(missing_catalogs))
unexpected_catalogs = sorted(actual_catalogs - declared_catalogs)
if unexpected_catalogs:
    fail("unexpected release file(s): " + ", ".join(unexpected_catalogs))

visual_manifest = json.loads((buffbot_root / 'BfBotVA.json').read_text(encoding='utf-8'))
visual_names = visual_manifest['files']
if not visual_names or len(visual_names) != len(set(visual_names)):
    fail('invalid visual resource allowlist')
visual_sources = []
for name in visual_names:
    if not re.fullmatch(r'[A-Z0-9]{1,8}\.(?:BAM|PVRZ)', name):
        fail('invalid visual resource name: ' + name)
    source = buffbot_root / 'visual' / name
    if not source.is_file() or source.is_symlink():
        fail('missing required visual resource: ' + name)
    if hashlib.sha256(source.read_bytes()).hexdigest() != visual_manifest['sha256'][name]:
        fail('visual resource hash mismatch: ' + name)
    visual_sources.append('buffbot/visual/' + name)
actual_visual = {p.name for p in (buffbot_root / 'visual').iterdir()}
if actual_visual != set(visual_names):
    fail('unexpected visual resource file(s): ' + ', '.join(sorted(actual_visual - set(visual_names))))
release_sources = [*root_files, *sorted(expected_top), *sorted(declared_catalogs), *visual_sources]
reject_casefold_collisions(release_sources)
for relative in release_sources:
    source = repo / relative
    if not source.is_file() or source.is_symlink():
        fail(f"missing required release file: {relative}")
    destination = staging / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)

shutil.copy2(installer, staging / "setup-buffbot.exe")
archive_members = ["setup-buffbot.exe", *release_sources]

# Write beside the destination and atomically replace only the final path. This
# avoids partial archives and cannot follow a symlink introduced after the
# initial rejection check.
temporary_fd, temporary_name = tempfile.mkstemp(
    prefix=f".{output.name}.", suffix=".tmp", dir=output.parent
)
os.close(temporary_fd)
temporary_output = Path(temporary_name)
try:
    with ZipFile(temporary_output, "w", compression=ZIP_DEFLATED) as archive:
        for relative in sorted(archive_members):
            archive.write(staging / relative, relative)
    if output.is_symlink():
        fail("output ZIP must not be a symlink")
    os.replace(temporary_output, output)
finally:
    if temporary_output.exists():
        temporary_output.unlink()
PY

FILE_COUNT="$(find "$STAGING" -type f | wc -l | tr -d ' ')"
echo "Built BuffBot release: $OUTPUT ($FILE_COUNT files)"
