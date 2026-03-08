#!/bin/bash
# tools/deploy.sh — Copy BuffBot files to game override for dev testing
# Usage:
#   bash tools/deploy.sh /path/to/game      # explicit path
#   BGEE_DIR=/path/to/game bash tools/deploy.sh  # env var
#   (or set BGEE_DIR in tools/deploy.conf)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/buffbot"

# Source local config if present (gitignored — contains user's game path)
[ -f "$SCRIPT_DIR/deploy.conf" ] && source "$SCRIPT_DIR/deploy.conf"

GAME_DIR="${1:-${BGEE_DIR:?Set BGEE_DIR in tools/deploy.conf or pass game dir as argument}}"
OVERRIDE_DIR="$GAME_DIR/override"

echo "Deploying BuffBot to: $OVERRIDE_DIR"

# Verify source files exist
for f in M_BfBot.lua BfBotCor.lua BfBotCls.lua BfBotScn.lua BfBotExe.lua BfBotPer.lua BfBotInn.lua BfBotUI.lua BfBotTst.lua BuffBot.menu; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        echo "ERROR: $SRC_DIR/$f not found"
        exit 1
    fi
done

# Verify game override directory exists
if [ ! -d "$OVERRIDE_DIR" ]; then
    echo "ERROR: Game override directory not found: $OVERRIDE_DIR"
    exit 1
fi

# Copy source files
for f in M_BfBot.lua BfBotCor.lua BfBotCls.lua BfBotScn.lua BfBotExe.lua BfBotPer.lua BfBotInn.lua BfBotUI.lua BfBotTst.lua BuffBot.menu; do
    cp "$SRC_DIR/$f" "$OVERRIDE_DIR/$f"
done

# Copy asset files (MOS backgrounds, etc.)
for f in "$SRC_DIR"/*.MOS; do
    [ -f "$f" ] && cp "$f" "$OVERRIDE_DIR/$(basename "$f")"
done

# Copy PVRZ textures (9-slice borders, etc.)
for f in "$SRC_DIR"/*.PVRZ; do
    [ -f "$f" ] && cp "$f" "$OVERRIDE_DIR/$(basename "$f")"
done

# Create presets directory for config export/import
mkdir -p "$OVERRIDE_DIR/bfbot_presets"

# Copy diagnostic tools (optional, for development)
if [ -f "$SCRIPT_DIR/probe_clone.lua" ]; then
    cp "$SCRIPT_DIR/probe_clone.lua" "$OVERRIDE_DIR/probe_clone.lua"
fi

# Patch dialog.tlk with BuffBot innate ability names (idempotent)
LANG_DIR="$GAME_DIR/lang/en_US"
if [ -f "$LANG_DIR/dialog.tlk" ]; then
    if command -v python3 &> /dev/null; then
        python3 "$SCRIPT_DIR/patch_tlk.py" "$LANG_DIR/dialog.tlk" "$OVERRIDE_DIR/bfbot_strrefs.txt"
    elif command -v python &> /dev/null; then
        python "$SCRIPT_DIR/patch_tlk.py" "$LANG_DIR/dialog.tlk" "$OVERRIDE_DIR/bfbot_strrefs.txt"
    else
        echo "WARNING: Python not found. Innate ability names will be blank."
        echo "  Install Python 3 and re-run deploy.sh to add names."
    fi
else
    echo "WARNING: dialog.tlk not found at $LANG_DIR/dialog.tlk"
fi

echo ""
echo "Done. Files deployed:"
ls -la "$OVERRIDE_DIR"/M_BfBot.lua "$OVERRIDE_DIR"/BfBot*.lua "$OVERRIDE_DIR"/BuffBot.menu

echo ""
echo "To test in-game:"
echo "  1. Launch game via InfinityLoader.exe"
echo "  2. Load a save game"
echo "  3. Open EEex Lua console"
echo "  4. Type: BfBot.Test.RunAll()"
echo ""
echo "UI panel:"
echo "  BfBot.UI.Toggle()  or  F11 key"
