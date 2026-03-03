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
