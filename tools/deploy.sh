#!/bin/bash
set -e

# tools/deploy.sh — Copy BuffBot files to game override for dev testing
# Usage:
#   bash tools/deploy.sh /path/to/game      # explicit path
#   BGEE_DIR=/path/to/game bash tools/deploy.sh  # env var
#   (or set BGEE_DIR in tools/deploy.conf)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/buffbot"

# Precedence: $1 (positional arg) > $BGEE_DIR (env var) > deploy.conf (local default).
# Source deploy.conf only if BGEE_DIR isn't already set in the environment, so env-var
# overrides for test installs (e.g. BGEE_DIR=".../- Copy - Copy") aren't clobbered.
[ -z "$BGEE_DIR" ] && [ -f "$SCRIPT_DIR/deploy.conf" ] && source "$SCRIPT_DIR/deploy.conf"

GAME_DIR="${1:-${BGEE_DIR:?Set BGEE_DIR in tools/deploy.conf or pass game dir as argument}}"
OVERRIDE_DIR="$GAME_DIR/override"
CATALOG_PATH="$OVERRIDE_DIR/bfbot_l10n.tra"

# Verify source files exist
for f in M_BfBot.lua BfBotCor.lua BfBotLoc.lua BfBotThm.lua BfBotCls.lua BfBotScn.lua BfBot5e.lua BfBotExe.lua BfBotFst.lua BfBotMp.lua BfBotPer.lua BfBotInn.lua BfBotUI.lua BfBotTst.lua BuffBot.menu; do
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

# The WeiDU-selected catalog is installer-owned: keep it, never write it.
# Without one the runtime uses its English fallback text. BuffBot writes no
# TLK, so a deploy never touches one. A catalog path that is not a regular
# file is refused before copying anything: the runtime would silently fall
# back to English while this script claims the catalog is in use.
DEPLOY_LOCALIZATION_MODE="english_fallback"
if [ -e "$CATALOG_PATH" ] || [ -L "$CATALOG_PATH" ]; then
    if [ ! -f "$CATALOG_PATH" ]; then
        echo "ERROR: override/bfbot_l10n.tra exists but is not a regular file." >&2
        exit 1
    fi
    DEPLOY_LOCALIZATION_MODE="preserve_weidu"
fi

echo "Deploying BuffBot to: $OVERRIDE_DIR"
if [ "$DEPLOY_LOCALIZATION_MODE" = "preserve_weidu" ]; then
    echo "Runtime UI language: preserving existing WeiDU-selected runtime catalog"
else
    echo "Runtime UI language: English fallback (no WeiDU-selected runtime catalog)"
fi

# Copy source files
for f in M_BfBot.lua BfBotCor.lua BfBotLoc.lua BfBotThm.lua BfBotCls.lua BfBotScn.lua BfBot5e.lua BfBotExe.lua BfBotFst.lua BfBotMp.lua BfBotPer.lua BfBotInn.lua BfBotUI.lua BfBotTst.lua BuffBot.menu; do
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


# Copy BAM files (spell icons, actionbar icon, etc.)
for f in "$SRC_DIR"/*.BAM; do
    [ -f "$f" ] && cp "$f" "$OVERRIDE_DIR/$(basename "$f")"
done

# Copy themed control art. The BFB*.BAM files are BAM V2, so their pixels live
# in the numbered PVRZ pages beside them — both must land in override/.
for f in "$SRC_DIR"/visual/*; do
    [ -f "$f" ] && cp "$f" "$OVERRIDE_DIR/$(basename "$f")"
done

# Create presets directory for config export/import
mkdir -p "$OVERRIDE_DIR/bfbot_presets"

# Copy diagnostic tools (optional, for development)
if [ -f "$SCRIPT_DIR/probe_clone.lua" ]; then
    cp "$SCRIPT_DIR/probe_clone.lua" "$OVERRIDE_DIR/probe_clone.lua"
fi

echo ""
echo "Done. Files deployed:"
ls -la "$OVERRIDE_DIR"/M_BfBot.lua "$OVERRIDE_DIR"/BfBot*.lua "$OVERRIDE_DIR"/BuffBot.menu

echo ""
echo "To test in-game:"
echo "  1. Launch game via InfinityLoader.exe"
echo "  2. Load a save game"
echo "  3. Open the in-game console (Ctrl-Space; needs CLUAConsole=1 in baldur.ini)"
echo "  4. Type: BfBot.Test.RunAll()"
echo ""
echo "UI panel:"
echo "  BfBot.UI.Toggle()  or  F11 key"
