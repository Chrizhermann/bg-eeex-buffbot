#!/bin/bash
# tools/deploy.sh — Copy BuffBot files to game override for testing
# Usage: bash tools/deploy.sh

SRC_DIR="c:/src/private/bg-eeex-buffbot/src"
GAME_DIR="c:/Games/Baldur's Gate II Enhanced Edition modded/override"

echo "Deploying BuffBot to game override..."

# Verify source files exist
for f in M_BfBot.lua BfBotCor.lua BfBotUI.lua BfBotTst.lua BuffBot.menu; do
    if [ ! -f "$SRC_DIR/$f" ]; then
        echo "ERROR: $SRC_DIR/$f not found"
        exit 1
    fi
done

# Verify game override directory exists
if [ ! -d "$GAME_DIR" ]; then
    echo "ERROR: Game override directory not found: $GAME_DIR"
    exit 1
fi

# Copy files
cp "$SRC_DIR/M_BfBot.lua"   "$GAME_DIR/M_BfBot.lua"
cp "$SRC_DIR/BfBotCor.lua"  "$GAME_DIR/BfBotCor.lua"
cp "$SRC_DIR/BfBotUI.lua"   "$GAME_DIR/BfBotUI.lua"
cp "$SRC_DIR/BfBotTst.lua"  "$GAME_DIR/BfBotTst.lua"
cp "$SRC_DIR/BuffBot.menu"  "$GAME_DIR/BuffBot.menu"

# Patch dialog.tlk with BuffBot innate ability names (idempotent)
LANG_DIR="$(dirname "$GAME_DIR")/lang/en_US"
TOOLS_DIR="$(dirname "$0")"
if [ -f "$LANG_DIR/dialog.tlk" ]; then
    if command -v python3 &> /dev/null; then
        python3 "$TOOLS_DIR/patch_tlk.py" "$LANG_DIR/dialog.tlk" "$GAME_DIR/bfbot_strrefs.txt"
    elif command -v python &> /dev/null; then
        python "$TOOLS_DIR/patch_tlk.py" "$LANG_DIR/dialog.tlk" "$GAME_DIR/bfbot_strrefs.txt"
    else
        echo "WARNING: Python not found. Innate ability names will be blank."
        echo "  Install Python 3 and re-run deploy.sh to add names."
    fi
else
    echo "WARNING: dialog.tlk not found at $LANG_DIR/dialog.tlk"
fi

echo ""
echo "Done. Files deployed:"
ls -la "$GAME_DIR"/M_BfBot.lua "$GAME_DIR"/BfBotCor.lua "$GAME_DIR"/BfBotUI.lua "$GAME_DIR"/BfBotTst.lua "$GAME_DIR"/BuffBot.menu

echo ""
echo "To test in-game:"
echo "  1. Launch game via InfinityLoader.exe"
echo "  2. Load a save game"
echo "  3. Open EEex Lua console"
echo "  4. Type: BfBot.Test.RunAll()"
echo ""
echo "Individual test functions:"
echo "  BfBot.Test.CheckFields()                 -- verify field names"
echo "  BfBot.Test.ScanAll()                     -- scan all party spells"
echo "  BfBot.Test.Classify('SPWI305')           -- classify one spell"
echo "  BfBot.Test.VerifyKnownSpells()           -- classification self-test"
echo "  BfBot.Test.DumpFeatureBlocks('SPWI305')  -- dump feature blocks"
echo ""
echo "Persistence:"
echo "  BfBot.Test.Persist()                     -- config save/load tests"
echo ""
echo "Execution engine:"
echo "  BfBot.Test.Exec()                        -- auto-discover & cast buffs"
echo "  BfBot.Test.ExecLog()                     -- review execution log"
echo "  BfBot.Test.ExecStop()                    -- stop mid-execution"
echo "  BfBot.Exec.Stop()                        -- stop (no log print)"
echo ""
echo "UI panel:"
echo "  BfBot.UI.Toggle()                        -- open/close config panel"
echo "  F11 key                                  -- toggle panel (in-game)"
echo ""
echo "Innate abilities:"
echo "  BFBT*.SPL files are auto-generated on first game start"
echo "  F12 (special abilities) shows per-preset innates for each character"
echo "  BfBot.Innate.Grant()                     -- re-grant innates to party"
echo "  BfBot.Innate.RefreshAll()                -- revoke + re-grant all"
