# Alpha-Ready Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix blocking preset bugs, create WeiDU .tp2 installer, and prepare BuffBot for alpha distribution.

**Architecture:** Fix 4 preset management bugs (defensive clamping + validation), rename `src/` → `buffbot/` for WeiDU convention, create `setup-buffbot.tp2` with native TLK patching, update `deploy.sh` for configurable game paths, rewrite README for alpha testers.

**Tech Stack:** Lua (BG:EE/EEex), WeiDU (.tp2), Bash (deploy.sh), Markdown (README)

---

### Task 0: Fix preset bugs in BfBotPer.lua and BfBotUI.lua

**Files:**
- Modify: `src/BfBotPer.lua:621-646` (DeletePreset)
- Modify: `src/BfBotUI.lua:147-194` (_Refresh clamp)
- Modify: `src/BfBotUI.lua:407-427` (DeleteCurrentPreset)
- Modify: `src/BfBotUI.lua:433-441` (Cast)

**Step 1: Fix `DeletePreset` to always validate `config.ap` (Bug #2)**

In `BfBotPer.lua`, the `DeletePreset` function only resets `config.ap` when `config.ap == presetIndex`. Change it to always validate after deletion:

```lua
--- Delete a preset by index. Refuses to delete the last remaining preset.
--- Returns 1 on success, nil on failure.
function BfBot.Persist.DeletePreset(sprite, presetIndex)
    local config = BfBot.Persist.GetConfig(sprite)
    if not config then return nil end

    -- Count existing presets
    local count = 0
    for i = 1, 5 do
        if config.presets[i] then count = count + 1 end
    end
    if count <= 1 then return nil end  -- can't delete last preset

    if not config.presets[presetIndex] then return nil end
    config.presets[presetIndex] = nil

    -- Always validate config.ap points to an existing preset
    if not config.presets[config.ap] then
        for i = 1, 5 do
            if config.presets[i] then
                config.ap = i
                break
            end
        end
    end

    return 1  -- integer, not boolean
end
```

The change: `config.ap == presetIndex` guard removed. Now validates `config.ap` unconditionally after deletion.

**Step 2: Add `_ClampPresetIdx` helper to BfBotUI.lua (Bug #3)**

Add after the Internal State section (after line 15):

```lua
--- Ensure _presetIdx points to a valid preset for the given config.
-- Returns the clamped index (also sets BfBot.UI._presetIdx).
function BfBot.UI._ClampPresetIdx(config)
    if config and config.presets and config.presets[BfBot.UI._presetIdx] then
        return BfBot.UI._presetIdx  -- already valid
    end
    -- Fall back to config.ap, then first valid preset
    if config and config.presets then
        if config.ap and config.presets[config.ap] then
            BfBot.UI._presetIdx = config.ap
            return config.ap
        end
        for i = 1, 5 do
            if config.presets[i] then
                BfBot.UI._presetIdx = i
                return i
            end
        end
    end
    BfBot.UI._presetIdx = 1
    return 1
end
```

**Step 3: Update `_Refresh` to use `_ClampPresetIdx` (Bug #1/#3)**

Replace lines 185-188 in `BfBotUI.lua`:

Old:
```lua
    -- 4. Clamp preset index to valid range
    if not config.presets[BfBot.UI._presetIdx] then
        BfBot.UI._presetIdx = config.ap or 1
    end
```

New:
```lua
    -- 4. Clamp preset index to valid range
    BfBot.UI._ClampPresetIdx(config)
```

**Step 4: Update `DeleteCurrentPreset` to use `_ClampPresetIdx` (Bug #1)**

Replace lines 407-427 in `BfBotUI.lua`:

```lua
--- Delete the current preset for all party members and switch to nearest.
function BfBot.UI.DeleteCurrentPreset()
    local result = BfBot.Persist.DeletePresetAll(BfBot.UI._presetIdx)
    if result then
        -- Clamp to first valid preset for the current character
        local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
        if sprite then
            local config = BfBot.Persist.GetConfig(sprite)
            BfBot.UI._ClampPresetIdx(config)
        end
        BfBot.Innate.RefreshAll()
        BfBot.UI._Refresh()
    end
end
```

**Step 5: Add validation guard in `Cast` (Bug #5)**

Replace lines 433-441 in `BfBotUI.lua`:

```lua
function BfBot.UI.Cast()
    -- Validate preset index before building queue
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if sprite then
        local config = BfBot.Persist.GetConfig(sprite)
        BfBot.UI._ClampPresetIdx(config)
    end

    local queue = BfBot.Persist.BuildQueueFromPreset(BfBot.UI._presetIdx)
    if not queue or #queue == 0 then
        Infinity_DisplayString("BuffBot: No spells to cast in this preset")
        return
    end
    local qcMode = sprite and BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx) or 0
    BfBot.Exec.Start(queue, qcMode)
    buffbot_status = BfBot.UI._GetStatusText()
end
```

**Step 6: Verify in-game**

Deploy and test:
1. Open panel, create 3rd preset, delete preset 2 → should switch to valid preset, spell list populated
2. Delete the currently active preset → should switch cleanly
3. Switch character tabs after deletion → should show correct spells
4. Click Cast with all spells disabled → should show "No spells to cast" message

**Step 7: Commit**

```bash
git add src/BfBotPer.lua src/BfBotUI.lua
git commit -m "fix(presets): defensive clamping for preset index after deletion

- DeletePreset always validates config.ap (not just when deleting active)
- New _ClampPresetIdx helper prevents stale UI preset index
- Cast() validates preset + shows feedback on empty queue
- Fixes blank spell list after preset deletion + tab switch"
```

---

### Task 1: Rename src/ to buffbot/

**Files:**
- Rename: `src/` → `buffbot/`

**Step 1: Rename the directory**

```bash
git mv src buffbot
```

**Step 2: Verify files moved correctly**

```bash
ls buffbot/
```

Expected: All 11 source files (M_BfBot.lua, BfBotCor.lua, BfBotCls.lua, BfBotScn.lua, BfBotExe.lua, BfBotPer.lua, BfBotInn.lua, BfBotUI.lua, BfBotTst.lua, BuffBot.menu, .gitkeep)

**Step 3: Commit**

```bash
git add -A
git commit -m "refactor: rename src/ to buffbot/ for WeiDU convention

%MOD_FOLDER% resolves to 'buffbot' from setup-buffbot.tp2.
Repo structure now matches install structure — clone into game dir and run setup."
```

---

### Task 2: Create setup-buffbot.tp2

**Files:**
- Create: `setup-buffbot.tp2` (repo root)

**Step 1: Write the .tp2 file**

```weidu
BACKUP ~weidu_external/backup/buffbot~
AUTHOR ~Chrizhermann (github.com/Chrizhermann/bg-eeex-buffbot)~
VERSION ~v0.1.0-alpha~

BEGIN ~BuffBot: In-Game Buff Automation~
DESIGNATED 0
LABEL ~BuffBot-Main~

// ---- Prerequisites ----
REQUIRE_PREDICATE (GAME_IS ~bgee bg2ee eet~)
  ~BuffBot requires BG:EE, BG2:EE, or EET.~

REQUIRE_PREDICATE (MOD_IS_INSTALLED ~EEex/EEex.tp2~ ~0~)
  ~BuffBot requires EEex. Install EEex first: https://github.com/Bubb13/EEex~

// ---- TLK strings for innate ability tooltips ----
OUTER_SET bfbot_strref_1 = RESOLVE_STR_REF(~BuffBot 1~)
OUTER_SET bfbot_strref_2 = RESOLVE_STR_REF(~BuffBot 2~)
OUTER_SET bfbot_strref_3 = RESOLVE_STR_REF(~BuffBot 3~)
OUTER_SET bfbot_strref_4 = RESOLVE_STR_REF(~BuffBot 4~)
OUTER_SET bfbot_strref_5 = RESOLVE_STR_REF(~BuffBot 5~)

// ---- Copy mod files to override ----
COPY ~buffbot/M_BfBot.lua~   ~override~
COPY ~buffbot/BfBotCor.lua~  ~override~
COPY ~buffbot/BfBotCls.lua~  ~override~
COPY ~buffbot/BfBotScn.lua~  ~override~
COPY ~buffbot/BfBotExe.lua~  ~override~
COPY ~buffbot/BfBotPer.lua~  ~override~
COPY ~buffbot/BfBotInn.lua~  ~override~
COPY ~buffbot/BfBotUI.lua~   ~override~
COPY ~buffbot/BfBotTst.lua~  ~override~
COPY ~buffbot/BuffBot.menu~  ~override~

// ---- Write base strref for Lua innate tooltip lookup ----
<<<<<<<< .../buffbot-inlined/bfbot_strrefs.txt
%bfbot_strref_1%
>>>>>>>>
COPY ~.../buffbot-inlined/bfbot_strrefs.txt~ ~override/bfbot_strrefs.txt~
  EVALUATE_BUFFER
```

**Step 2: Verify syntax**

Review against ArtisansKitpack patterns:
- `BACKUP` uses `weidu_external/backup/` convention ✓
- `REQUIRE_PREDICATE` for game type and EEex ✓
- `RESOLVE_STR_REF` deduplicates on reinstall ✓
- Inlined file with `EVALUATE_BUFFER` for strref ✓
- All 10 source files + 1 .menu copied ✓
- No `.tra` files (inline English for alpha) ✓

**Step 3: Commit**

```bash
git add setup-buffbot.tp2
git commit -m "feat: add WeiDU installer (setup-buffbot.tp2)

Native TLK patching via RESOLVE_STR_REF (no Python dependency).
Requires EEex installed. Copies all mod files to override.
Uninstall handled automatically by WeiDU."
```

---

### Task 3: Update deploy.sh and create deploy.conf

**Files:**
- Modify: `tools/deploy.sh`
- Create: `tools/deploy.conf` (user's local copy, gitignored)
- Modify: `.gitignore`

**Step 1: Update .gitignore**

Add to end of `.gitignore`:

```
# Local dev config (contains user-specific game path)
tools/deploy.conf
```

**Step 2: Update deploy.sh**

Replace entire file with:

```bash
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
```

**Step 3: Create deploy.conf for local use**

```bash
# tools/deploy.conf — Local game path (gitignored)
BGEE_DIR="c:/Games/Baldur's Gate II Enhanced Edition modded"
```

**Step 4: Commit**

```bash
git add tools/deploy.sh .gitignore
git commit -m "refactor: make deploy.sh configurable, remove hardcoded game path

Game dir via: CLI arg > tools/deploy.conf > BGEE_DIR env var.
deploy.conf is gitignored for user-specific paths."
```

Note: Do NOT `git add tools/deploy.conf` — it's gitignored for a reason.

---

### Task 4: Write README.md

**Files:**
- Modify: `README.md`

**Step 1: Write the alpha README**

```markdown
# BuffBot

In-game configurable buff automation for Baldur's Gate: Enhanced Edition (BG:EE / BG2:EE / EET). Scans party spellbooks dynamically and casts buff sequences with one click.

**Status: Alpha** — core features working, UI functional. Bug reports welcome via [GitHub Issues](https://github.com/Chrizhermann/bg-eeex-buffbot/issues).

## Features

- **Dynamic spellbook scanning** — discovers buff spells from all sources (memorized, innate, HLAs, kit abilities) in real time
- **In-game config panel** — per-character tabs, scrollable spell list with enable/disable, target assignment, priority ordering
- **Up to 5 presets** — independent buff configurations per character (Long Buffs, Short Buffs, Boss Fight, etc.) with create/rename/delete
- **Quick Cast mode** — per-preset 3-state toggle (Off / Long only / All) for instant casting via Improved Alacrity
- **F12 innate abilities** — per-preset innate in each character's special abilities, trigger buffing directly from gameplay
- **Skip active buffs** — detects already-active buffs via SPLSTATE + effect list and skips them (configurable)
- **Save game persistence** — config saved per-character in EEex save games via marshal handlers
- **Mod-friendly** — works with SCS, Spell Revisions, kit mods, and other spell-adding mods automatically

## Requirements

- **BG:EE**, **BG2:EE**, or **EET**
- **[EEex](https://github.com/Bubb13/EEex)** — tested with EEex v0.11.0-alpha. Earlier versions may work if they support `EEex_Sprite_AddMarshalHandlers`

## Installation

### WeiDU (recommended)

1. Download or clone this repo into your game directory
2. Run `setup-buffbot.exe` (or use your WeiDU launcher)
3. Select "BuffBot: In-Game Buff Automation" when prompted

Uninstall: re-run the setup and choose uninstall. WeiDU removes all files and restores TLK automatically.

### Manual

Copy all files from `buffbot/` to your game's `override/` directory. Innate ability tooltips require TLK patching (see Developer Setup below).

## Usage

### Opening the Panel

- **Actionbar button** — appears to the right of the action bar
- **F11** — keyboard shortcut (configurable via `baldur.ini` `[BuffBot]` section)
- **F12 innates** — per-preset abilities in each character's special abilities

### Basic Workflow

1. Open the panel (F11 or actionbar button)
2. Select a character tab
3. Select a preset tab (default: "Long Buffs" / "Short Buffs")
4. Enable/disable spells with the checkbox column
5. Set targets for each spell (Self, Party, or specific character)
6. Click **Cast** to start buffing (or use F12 innate for that preset)
7. Quick Cast button cycles Off → Long → All for fast casting

### Presets

- Default presets auto-populate from scanned spells: long/permanent buffs enabled in preset 1, short buffs in preset 2
- Create new presets for specific situations (up to 5 per character)
- Each preset is independent — own spell list, targets, quick cast setting
- Presets are shared across all party members (create/delete/rename applies to all)

## Testing & Bug Reports

In the EEex Lua console:

```
BfBot.Test.RunAll()         -- full test suite
BfBot.Test.Persist()        -- persistence tests
BfBot.Test.Exec()           -- execution engine test
BfBot.Test.QuickCast()      -- quick cast test
BfBot.UI.Toggle()           -- open/close config panel
```

Log files are written to the game directory: `buffbot_test.log`, `buffbot_exec.log`.

Please report issues at [GitHub Issues](https://github.com/Chrizhermann/bg-eeex-buffbot/issues) with:
- Game version (BG:EE / BG2:EE / EET) and EEex version
- Steps to reproduce
- Output from `BfBot.Test.RunAll()` if relevant

## Known Issues

- **Preset target inconsistency** — creating a new preset re-classifies spell targets from SPL data, which may differ from user overrides in existing presets
- **Old save configs** — saves created before v0.1.0 may have incomplete preset configs (each preset only has its category's spells). Start a new game or manually enable missing spells
- **Spell Revisions Barkskin** — classified as ambiguous (SR delivers AC via sub-spell). Manual enable in config works
- **Innate icon** — placeholder (Stoneskin icon). Custom BAM planned

## Developer Setup

For iterative development without running WeiDU each time:

```bash
# Set your game path (one-time setup)
echo 'BGEE_DIR="/path/to/your/game"' > tools/deploy.conf

# Deploy to game override
bash tools/deploy.sh

# Or pass path directly
bash tools/deploy.sh "/path/to/your/game"
```

Requires Python 3 for TLK patching (innate ability tooltip names).

## Repo Structure

```
bg-eeex-buffbot/
├── buffbot/              # Mod source files (copied to override)
│   ├── M_BfBot.lua       # Bootstrap (auto-loaded by EEex)
│   ├── BfBotCor.lua      # Namespace, logging, shared utilities
│   ├── BfBotCls.lua      # Buff classifier (opcode scoring)
│   ├── BfBotScn.lua      # Spellbook scanner
│   ├── BfBotExe.lua      # Execution engine (parallel per-caster)
│   ├── BfBotPer.lua      # Persistence (marshal handlers, presets)
│   ├── BfBotInn.lua      # F12 innate abilities (runtime SPL gen)
│   ├── BfBotUI.lua       # Config panel logic
│   ├── BfBotTst.lua      # Test suite
│   └── BuffBot.menu      # UI definitions (.menu DSL)
├── tools/                # Dev utilities
│   ├── deploy.sh         # Copy files to game override
│   └── patch_tlk.py      # TLK patcher for innate tooltips
├── docs/                 # Design docs and analysis
├── setup-buffbot.tp2     # WeiDU installer
├── CLAUDE.md             # Project context for Claude Code
├── LICENSE               # MIT
└── README.md
```

## Inspiration

Originally inspired by [Bubble Buffs](https://github.com/factubsio/BubbleBuffs) from Pathfinder: Wrath of the Righteous, adapted for the Infinity Engine's spell system and BG's per-character spellbook model.

## License

[MIT](LICENSE)
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README for alpha release

Features, requirements, installation (WeiDU + manual), usage guide,
testing instructions, known issues, dev setup, repo structure."
```

---

### Task 5: Update CLAUDE.md path references

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update all src/ references to buffbot/**

Find and replace `src/` → `buffbot/` in CLAUDE.md for file path references. Key locations:

- "mod source in `src/`" → "mod source in `buffbot/`"
- All file listings: `src/BfBotUI.lua` → `buffbot/BfBotUI.lua`, etc.
- "deploy via `bash tools/deploy.sh`" stays the same (correct path)
- Repo Layout section: `src/` → `buffbot/`

Also update:
- Status to say "Alpha" instead of "Implementation in progress"
- Add mention of setup-buffbot.tp2

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md paths (src/ → buffbot/) and alpha status"
```

---

### Task 6: Update memory file

**Files:**
- Modify: `~/.claude/projects/C--src-private-bg-eeex-buffbot/memory/MEMORY.md`

**Step 1: Update path references**

Update all `src/` references to `buffbot/` in the Implementation Status section and any other path references.

Add note about WeiDU installer and alpha status.

**Step 2: No commit needed** (memory files are not in the repo)

---

### Task 7: Clean up untracked files and final commit

**Files:**
- Review: `nul` (untracked, likely Windows artifact)
- Review: `tools/probe_clone.lua` (untracked dev tool)

**Step 1: Handle untracked files**

```bash
# nul is a Windows artifact — delete it
rm nul

# probe_clone.lua — add to .gitignore or commit
# (dev diagnostic tool, useful for alpha testers)
```

**Step 2: Verify clean state**

```bash
git status
git log --oneline -10
```
