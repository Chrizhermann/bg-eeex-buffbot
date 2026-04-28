#!/bin/bash
# tools/bump-version.sh — bump version in setup-buffbot.tp2 and BfBotCor.lua atomically
#
# Usage:
#   bash tools/bump-version.sh 1.3.14-alpha
#   bash tools/bump-version.sh 1.3.13.1-alpha
#
# Pass the new version WITHOUT leading 'v'. The script writes:
#   buffbot/setup-buffbot.tp2  →  VERSION ~v<version>~
#   buffbot/BfBotCor.lua       →  BfBot.VERSION = "<version>"
#
# Does not commit, tag, or write CHANGELOG. Review with `git diff` first.

set -euo pipefail

NEW_VERSION="${1:-}"
if [[ -z "$NEW_VERSION" ]]; then
    cat <<EOF
Usage: $0 <version>
  e.g. $0 1.3.14-alpha
       $0 1.3.13.1-alpha

Pass version WITHOUT leading 'v' — script writes both forms correctly.
EOF
    exit 1
fi

if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9]+)?$ ]]; then
    echo "ERROR: version must look like 1.3.14-alpha or 1.3.13.1-alpha (no v-prefix)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TP2="$ROOT_DIR/buffbot/setup-buffbot.tp2"
COR="$ROOT_DIR/buffbot/BfBotCor.lua"

for f in "$TP2" "$COR"; do
    [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }
done

OLD_TP2=$(grep -E '^VERSION ~' "$TP2" | sed -E 's/^VERSION ~([^~]+)~.*$/\1/')
OLD_COR=$(grep -E '^BfBot\.VERSION = "' "$COR" | sed -E 's/^BfBot\.VERSION = "([^"]+)".*$/\1/')

echo "Bumping versions:"
echo "  setup-buffbot.tp2:  $OLD_TP2  ->  v$NEW_VERSION"
echo "  BfBotCor.lua:       $OLD_COR  ->  $NEW_VERSION"

perl -i -pe 's/^VERSION ~[^~]+~/VERSION ~v'"$NEW_VERSION"'~/' "$TP2"
perl -i -pe 's/^BfBot\.VERSION = "[^"]+"/BfBot.VERSION = "'"$NEW_VERSION"'"/' "$COR"

NEW_TP2=$(grep -E '^VERSION ~' "$TP2" | sed -E 's/^VERSION ~([^~]+)~.*$/\1/')
NEW_COR=$(grep -E '^BfBot\.VERSION = "' "$COR" | sed -E 's/^BfBot\.VERSION = "([^"]+)".*$/\1/')

if [[ "$NEW_TP2" != "v$NEW_VERSION" ]]; then
    echo "ERROR: tp2 update failed: got '$NEW_TP2'" >&2
    exit 1
fi
if [[ "$NEW_COR" != "$NEW_VERSION" ]]; then
    echo "ERROR: BfBotCor update failed: got '$NEW_COR'" >&2
    exit 1
fi

echo ""
echo "Done. Next steps:"
echo "  1. Add a CHANGELOG.md entry for v$NEW_VERSION"
echo "  2. git diff           # review"
echo "  3. git commit -am \"release: v$NEW_VERSION — ...\""
echo "  4. git tag v$NEW_VERSION && git push origin main --tags"
echo "  5. gh release create v$NEW_VERSION --notes \"...\"   # triggers packaging workflow"
