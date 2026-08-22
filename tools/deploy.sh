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
STRREFS_PATH="$OVERRIDE_DIR/bfbot_strrefs.txt"
PATCH_TLK_SCRIPT="$SCRIPT_DIR/patch_tlk.py"
ENGLISH_TLK="$GAME_DIR/lang/en_US/dialog.tlk"

# Verify source files exist
for f in M_BfBot.lua BfBotCor.lua BfBotLoc.lua BfBotThm.lua BfBotCls.lua BfBotScn.lua BfBotExe.lua BfBotMp.lua BfBotPer.lua BfBotInn.lua BfBotUI.lua BfBotTst.lua BuffBot.menu; do
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

# Treat the WeiDU-selected catalog and its generated innate references as one
# installer-owned state. Refuse an incomplete pair before copying anything.
DEPLOY_LOCALIZATION_MODE="english_fallback"
PATCH_TLK_PYTHON=""
if [ -e "$CATALOG_PATH" ] || [ -L "$CATALOG_PATH" ]; then
    if [ ! -f "$CATALOG_PATH" ]; then
        echo "ERROR: override/bfbot_l10n.tra exists but is not a regular file." >&2
        exit 1
    fi
    if [ ! -f "$STRREFS_PATH" ]; then
        echo "ERROR: Found override/bfbot_l10n.tra but override/bfbot_strrefs.txt is missing." >&2
        echo "Reinstall BuffBot with WeiDU to restore the selected catalog and innate references before running raw deploy." >&2
        exit 1
    fi
    DEPLOY_LOCALIZATION_MODE="preserve_weidu"
else
    if [ -L "$STRREFS_PATH" ] || { [ -e "$STRREFS_PATH" ] && [ ! -f "$STRREFS_PATH" ]; }; then
        echo "ERROR: English fallback requires override/bfbot_strrefs.txt to be absent or a regular non-symlink file." >&2
        exit 1
    fi
    if [ ! -f "$PATCH_TLK_SCRIPT" ]; then
        echo "ERROR: English fallback TLK patcher is missing: $PATCH_TLK_SCRIPT" >&2
        exit 1
    fi
    if [ -L "$ENGLISH_TLK" ] || [ ! -f "$ENGLISH_TLK" ]; then
        echo "ERROR: English fallback requires lang/en_US/dialog.tlk to be a regular non-symlink file: $ENGLISH_TLK" >&2
        exit 1
    fi
    for python_candidate in python3 python; do
        if command -v "$python_candidate" > /dev/null 2>&1; then
            candidate_path="$(command -v "$python_candidate")"
            if "$candidate_path" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' > /dev/null 2>&1; then
                PATCH_TLK_PYTHON="$candidate_path"
                break
            fi
        fi
    done
    if [ -z "$PATCH_TLK_PYTHON" ]; then
        echo "ERROR: English fallback requires Python 3 (python3 or python)." >&2
        exit 1
    fi
fi

echo "Deploying BuffBot to: $OVERRIDE_DIR"
if [ "$DEPLOY_LOCALIZATION_MODE" = "preserve_weidu" ]; then
    echo "Runtime UI language: preserving existing WeiDU-selected runtime catalog and innate references; skipping TLK patching"
else
    echo "Runtime UI language: English fallback (no WeiDU-selected runtime catalog)"
fi

# Copy source files
for f in M_BfBot.lua BfBotCor.lua BfBotLoc.lua BfBotThm.lua BfBotCls.lua BfBotScn.lua BfBotExe.lua BfBotMp.lua BfBotPer.lua BfBotInn.lua BfBotUI.lua BfBotTst.lua BuffBot.menu; do
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
# Copy BAM files (spell icons, etc.)
for f in "$SRC_DIR"/*.BAM; do
    [ -f "$f" ] && cp "$f" "$OVERRIDE_DIR/$(basename "$f")"
done

# Create presets directory for config export/import
mkdir -p "$OVERRIDE_DIR/bfbot_presets"

# Copy diagnostic tools (optional, for development)
if [ -f "$SCRIPT_DIR/probe_clone.lua" ]; then
    cp "$SCRIPT_DIR/probe_clone.lua" "$OVERRIDE_DIR/probe_clone.lua"
fi

# A clean raw deploy is intentionally an English-only development fallback.
# A coherent WeiDU-selected pair keeps both files and every TLK untouched.
if [ "$DEPLOY_LOCALIZATION_MODE" = "english_fallback" ]; then
    if ! "$PATCH_TLK_PYTHON" "$PATCH_TLK_SCRIPT" "$ENGLISH_TLK" "$STRREFS_PATH"; then
        echo "ERROR: Failed to patch English fallback TLK: $ENGLISH_TLK" >&2
        exit 1
    fi
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
