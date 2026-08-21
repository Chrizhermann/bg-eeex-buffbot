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

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/buffbot"

cp "$INSTALLER" "$STAGING/setup-buffbot.exe"
cp "$REPO_DIR/README.md" "$STAGING/README.md"
cp "$REPO_DIR/CHANGELOG.md" "$STAGING/CHANGELOG.md"

# Only distributable top-level mod formats are admitted. Generated runtime
# maps, backups, tests, local configuration, and other development state do
# not match this allowlist.
while IFS= read -r -d '' SOURCE; do
    cp "$SOURCE" "$STAGING/buffbot/$(basename "$SOURCE")"
done < <(
    find "$REPO_DIR/buffbot" -maxdepth 1 -type f \
        \( -name '*.tp2' -o -name '*.lua' -o -name '*.menu' \
           -o -name '*.BAM' -o -name '*.MOS' -o -name '*.PVRZ' \) \
        -print0
)

# Translation catalogs are the only recursively packaged source. Preserve
# their language-directory layout so WeiDU LANGUAGE paths remain valid.
for REQUIRED in english schinese; do
    [ -f "$REPO_DIR/buffbot/lang/$REQUIRED/setup.tra" ] || {
        echo "ERROR: required catalog missing: buffbot/lang/$REQUIRED/setup.tra" >&2
        exit 1
    }
done
while IFS= read -r -d '' SOURCE; do
    RELATIVE="${SOURCE#"$REPO_DIR/buffbot/"}"
    mkdir -p "$STAGING/buffbot/$(dirname "$RELATIVE")"
    cp "$SOURCE" "$STAGING/buffbot/$RELATIVE"
done < <(
    find "$REPO_DIR/buffbot/lang" -mindepth 2 -maxdepth 2 -type f \
        -name 'setup.tra' -print0
)

if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
else
    echo "ERROR: release packaging requires Python 3" >&2
    exit 1
fi

rm -f "$OUTPUT"
(cd "$STAGING" && "$PYTHON_BIN" - "$OUTPUT" <<'PY'
import sys
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

output = Path(sys.argv[1])
with ZipFile(output, "w", compression=ZIP_DEFLATED) as archive:
    for source in sorted(path for path in Path(".").rglob("*") if path.is_file()):
        archive.write(source, source.as_posix())
PY
)

FILE_COUNT="$(find "$STAGING" -type f | wc -l | tr -d ' ')"
echo "Built BuffBot release: $OUTPUT ($FILE_COUNT files)"
