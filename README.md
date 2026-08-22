# BuffBot

**In-game configurable buff automation for Baldur's Gate: Enhanced Edition.**

Cast all your pre-battle buffs with one click. BuffBot scans each character's spellbook, lets you configure which buffs to cast, in what order, on which targets — then executes the entire sequence automatically across all party members in parallel.

> **Alpha Release** — fully functional but rough around the edges. [Bug reports and feedback welcome.](https://github.com/Chrizhermann/bg-eeex-buffbot/issues)

> **BuffBot requires EEex v0.11.0-alpha or later. EEex v1 is recommended.**

[![BuffBot Showcase](https://img.youtube.com/vi/9fjnUKG1tfQ/maxresdefault.jpg)](https://www.youtube.com/watch?v=9fjnUKG1tfQ)

## Features

- **Dynamic buff-source scanning** — discovers buff spells from memorized, innate, HLA, and kit sources, plus activated equipped items, quickitems, and potions carried by party members. No hardcoded spell or item lists
- **Items and potions** — configure party-held buff items by resref, independent of their current slot. Item rows are visually distinct and disabled by default; BuffBot finds the current stack or equipped copy when casting
- **In-game config panel** — per-character tabs, scrollable buff list with enable/disable, duration display, target assignment, per-entry R1–R5 repeat counts, priority ordering, sort-by-duration, and row locks
- **Up to 8 presets** — independent buff configurations per character (Long Buffs, Short Buffs, Boss Fight, Undead Prebuff, etc.) with create/rename/delete
- **Summons and clones as casters** — configure Project Images, Simulacra, and other allied spellcasting summons in a dedicated Summons view; cast one summon alone or let configured summons join Cast All
- **Quick Cast mode** — per-preset 3-state toggle (Off / Long only / All) for instant casting via Improved Alacrity. Long mode fast-casts only long-duration buffs, then casts short buffs normally
- **F12 innate abilities** — each party character gets one innate per preset in their special abilities, triggering party-character buffing directly from gameplay without opening the panel
- **Skip active buffs** — detects already-active buffs via spell state + effect list checks, including wrapper potion leaf spells. No wasted spell slots, stacks, or charges
- **Manual override** — the Add picker can include spells the classifier missed and recover removed spells or items, grouped into separate sections
- **Config export/import** — export a character's full setup to a file, import onto any character across saves or between players
- **Save game persistence** — configuration saved per-character in EEex save games. Survives save/load automatically
- **Subwindow selection spells** — spells like Protection from Elemental Energy that normally open a selection popup are handled seamlessly. Pre-configure which variant to cast, and BuffBot bypasses the popup entirely
- **Mod-friendly** — tested with SCS, Spell Revisions, and kit mods. Reads spell data dynamically, so mod-added spells show up automatically

## Requirements

- **BG:EE**, **BG2:EE**, or **EET**
- **[EEex](https://github.com/Bubb13/EEex)** v0.11.0-alpha or later, with LuaJIT active (v1 recommended)

EEex v0.11 and v1 have full BuffBot feature parity. LuaJIT must be active before BuffBot's main component installs. You can enable it through EEex's LuaJIT / Experimental option, or install BuffBot's **EEex LuaJIT Support** helper first. The main component validates the actual loader configuration and DLLs, so LuaJIT activated externally by EEex is accepted without requiring ownership by BuffBot.

EEex v0.11 keeps its internal Lua files in `override/`. When using v0.11, install EEex and BuffBot late in the mod order — after generalized biffing and any later file-replacement step — so those files cannot be consumed or replaced.

Do not assume an arbitrary save can be downgraded to v0.11 after EEex v1 and other EEex mods have written it; that downgrade is not guaranteed safe.

<details>
<summary><strong>For the curious: how EEex tiers and LuaJIT layouts interact</strong></summary>

EEex v1's Minimal and Full tiers leave LuaJIT off by default; Experimental enables it. BuffBot checks the loader state and required DLLs instead of relying on EEex component numbers. Its helper enables or repairs LuaJIT when needed, using `LuaVersionExternal=5.1` for v0.11's older layout and `LuaVersionExternal=5.1-LuaJIT` for v1's newer layout. The helper makes no file changes when the matching runtime is already active.

</details>

## Languages

- English
- Simplified Chinese (简体中文)

The WeiDU installer asks which BuffBot translation to use and copies the selected UTF-8 catalog to `override/bfbot_l10n.tra`. BuffBot reads directly from that file for its UI, options, defaults, and player feedback; no BuffBot-owned UI string is fetched from the game TLK. Only the eight generated F12 innate names remain TLK-backed because SPL resources require numeric strrefs: WeiDU resolves catalog entries `@200` through `@207` and records them in `bfbot_strrefs.txt`.

In a source checkout, the raw development deploy (`tools/deploy.sh`) has two explicit paths. When `override/bfbot_l10n.tra` and `override/bfbot_strrefs.txt` both exist, it preserves an existing `override/bfbot_l10n.tra` together with its innate references, preserves both files byte-for-byte, and skips TLK patching entirely. If the catalog exists without the reference file, the helper stops before copying runtime files and asks you to reinstall BuffBot with WeiDU. When no selected catalog exists, the clean English-fallback path patches only `lang/en_US/dialog.tlk` with the English F12 names and generates `bfbot_strrefs.txt`, leaving the root and other language TLKs untouched. This fallback requires Python 3 and an existing `lang/en_US/dialog.tlk`; it also refuses an unsafe catalog or reference path. If a prerequisite is missing, the helper refuses the fallback before copying files. An obsolete `bfbot_l10n.txt` alone is preserved but does not select localized deployment.

The catalogs and Chinese installer path have automated coverage. Live validation in the Copy Copy BG2:EE + EEex installation loaded a game and opened BuffBot successfully; user screenshots confirmed readable CJK labels and acceptable panel layout at the tested resolution/font. The broader interaction/casting matrix and alternate resolutions/fonts remain pending, along with the compatibility boundaries listed in the changelog.

## Installation

### WeiDU (recommended)

1. Download the [latest release](https://github.com/Chrizhermann/bg-eeex-buffbot/releases) and extract it into your game directory
2. Run `setup-buffbot.exe` (or use your preferred WeiDU launcher)
3. Select **BuffBot: EEex LuaJIT Support** first if EEex did not already activate LuaJIT
4. Select **BuffBot: In-Game Buff Automation** after LuaJIT is active

For **Project Infinity**, explicitly select both BuffBot components and place **EEex LuaJIT Support** (component 1) before **In-Game Buff Automation** (component 0). Project Infinity does not infer that prerequisite from the component name. If EEex already activated the exact matching LuaJIT runtime, selecting only the main component is also valid.

**Updating an existing BuffBot install:** select or reinstall both BuffBot components together. Older releases recorded the main component before the helper, so updating only main makes WeiDU temporarily remove LuaJIT support and the safety check rejects that pass. The helper is restored safely, but the main component is left uninstalled; if this already happened, run setup again to install main.

For **EET**, BuffBot can be installed after `EET_end`; EEex and LuaJIT must be ready first. With EEex v0.11, keep EEex and BuffBot after generalized biffing or later file-replacement steps as noted above.

**Uninstall:** remove **In-Game Buff Automation** first, then remove **EEex LuaJIT Support** if BuffBot installed it. The helper restores the exact loader files that preceded its installation. LuaJIT owned by EEex is left unchanged when BuffBot's helper made no changes.

### Manual Development Copy

Raw/manual copying is a development-only path from a source checkout, not the normal release installation. Only use it when EEex LuaJIT is already active, because it bypasses the prerequisite check. Copy the runtime Lua, menu, BAM, MOS, and PVRZ files from `buffbot/` to your game's `override/` directory. The deploy helper treats a pre-existing `bfbot_l10n.tra` plus `bfbot_strrefs.txt` as one WeiDU-owned localized pair: it preserves both and does not patch any TLK. A catalog without its reference file is refused as inconsistent installer state. With no catalog, the runtime uses English fallback text and the helper patches only the English TLK to create the eight F12 innate references. Copying files manually without either a coherent WeiDU pair or that fallback patch may leave the innate names blank; players should use WeiDU for complete localized strings.

## Usage

### Opening the Panel

- **Actionbar button** — appears to the right of the action bar
- **F11** — keyboard shortcut
- **F12 innates** — per-preset abilities in each character's special abilities

### Basic Workflow

1. Open the panel (F11 or actionbar button)
2. Select a character tab at the top
3. Select a preset tab (default: "Long Buffs" / "Short Buffs")
4. Enable/disable spells and items with the checkbox column (items start disabled)
5. Set targets for each entry (Self, Party, or a specific character)
6. Set each entry's repeat count from R1 to R5
7. Reorder entries with the Up/Down buttons
8. Click **Cast** to start buffing — or use the F12 innate for that preset
9. **Quick Cast** button cycles Off → Long → All for fast casting

### Presets

- Default presets auto-populate from scanned sources: long/permanent spells are enabled in preset 1, short spells in preset 2, and items are present but disabled
- Create new presets for specific situations (up to 8 per character)
- Each preset is fully independent — own spell list, targets, repeat counts, priorities, and Quick Cast setting
- Newly recruited companions inherit the protagonist's current preset slots, names, and categories when BuffBot first configures them; their own spells and items start disabled and Quick Cast starts Off

### Repeat Casts

Each spell or item row shows R1–R5. Click its repeat cell to increase the count, or select the row and use **Repeat: N**: left-click increases and right-click decreases. Both controls wrap between 1 and 5 and remain editable when the source currently has zero uses.

Repeats are target-major. With targets A and B at R2, BuffBot attempts A, A, B, B. A party-wide AoE at R2 is cast twice total, not twice per party member. Every repeat rechecks availability, target state, and active effects. A spell attempt consumes one available use and follows normal aura/casting rules; an item attempt consumes a stack or charge and follows normal item-use rules. Quick Cast applies only to spells. Skipped attempts consume nothing.

### Summons and Clones

1. Create the allied summon or clone, then open BuffBot and switch from **Party** to **Summons**.
2. Select the live summon tab and enable the spells it should cast. Those enabled rows are its cast selection; there is no separate pre-cast queue checkbox.
3. Use **Cast (this summon)** to run only that summon, or **Cast All** to run the party preset and every configured live summon together. A configured summon created during the run joins automatically.
4. To create multiple ordinary summons, set R2–R5 on the summoning spell in its caster's party preset. Project Image is always limited to one attempt for owner-lock safety. Repeat counts in a summon tab instead control spells cast by that summon.

Clone presets are stored by owner identity and are reused when that owner's clone is created again. On first open they seed from the owner's matching preset, limited to spells the clone can cast. To disable automatic participation globally, set `SummonsJoinCast = 0` under `[BuffBot]` in `baldur.ini`.

Items are party-only in this release. Summon and clone presets remain spell-only even if a copied creature carries or inherits equipment.

Project Image locks its owner while active. BuffBot limits the Project Image cast itself to one attempt, skips locked owners, and drops owner entries placed after it so they cannot fire later as delayed casts. Put anything the owner must cast before Project Image earlier in the priority order. Copied BuffBot F12 innates on clones are not supported; use the Summons panel actions instead.

### Export / Import

- Click **Export** to save a character's entire config (all presets + overrides) to a file
- Click **Import** to load a config from any exported file onto the current character
- Spells the target character doesn't have are silently skipped
- Files are saved in `override/bfbot_presets/` — share them with other players or use across playthroughs

## Known Limitations (Alpha)

This is an alpha release. Everything works, but some things are unfinished:

- **Placeholder innate icons** — F12 abilities use the Stoneskin icon. Custom icons are planned
- **Panel visuals** — functional but unpolished. The layout works, the aesthetics don't win awards
- **Spell Revisions sub-spells** — some SR spells (Barkskin, Dispelling Screen) deliver effects via sub-spells, so the classifier may show them as ambiguous. Use "Add Spell" to manually include them
- **Windows only for export/import listing** — the file picker uses Windows `dir /b` for directory listing. The core export/import file I/O works on any platform, but the picker won't list files on macOS/Linux
- **Clone F12 innates** — clones copy their owner's BuffBot innate icons, but activating those copies does not reliably route the preset to the clone. Use the Summons view or Cast All
- **Deferred item sources** — scrolls, wands, and items inside containers or Bags of Holding are not scanned yet
- **Equipped weapon activations** — `UseItem` currently fires ability 0 only, so weapon buffs stored at a higher ability index remain excluded (#53)

## Testing & Bug Reports

BuffBot includes a built-in test suite. In the in-game console (the BG:EE / BG2:EE console — toggle with Ctrl-Space when `CLUAConsole=1` is set in `baldur.ini`):

```
BfBot.Test.RunAll()         -- full test suite (600+ assertions)
BfBot.Test.ExportImport()   -- export/import tests
BfBot.UI.Toggle()           -- open/close config panel
```

Log files are written to the game directory: `buffbot_test.log`, `buffbot_exec.log`.

**Reporting bugs:** please open an issue at [GitHub Issues](https://github.com/Chrizhermann/bg-eeex-buffbot/issues) with:
- Game version (BG:EE / BG2:EE / EET) and EEex version
- Steps to reproduce
- Mod list (especially SCS, Spell Revisions, kit mods)
- Output from `BfBot.Test.RunAll()` if relevant

## AI-Assisted Development

BuffBot was built with significant assistance from [Claude Code](https://claude.ai/code) (Anthropic's AI coding tool). The architecture, code, tests, and documentation were developed collaboratively between a human developer and AI.

The code is fully open source — judge it on its merits. If you have concerns about AI-assisted mods, that's understandable; the source is there for review.

## Contributing

Found a bug? Have a feature idea? [Open an issue](https://github.com/Chrizhermann/bg-eeex-buffbot/issues) on GitHub.

### Adding a Language

Language pull requests are welcome. BuffBot accepts complete catalogs so players never see a half-translated panel:

1. Copy `buffbot/lang/english/setup.tra` to `buffbot/lang/<language>/setup.tra`. Choose a safe lowercase folder name that starts with a letter and uses only `a-z`, `0-9`, and underscores.
2. Set `@113` to that exact folder name. This directory marker is non-translatable.
3. Translate every other value while preserving the exact `@` IDs, all comments, all named placeholders such as `{name}`, and every WeiDU token such as `%lua_version%`. Do not add or omit entries.
4. Keep the file UTF-8 and preserve the existing one-line tilde grammar (`@123 = ~Text~`).
5. Add the matching `LANGUAGE` stanza to `buffbot/setup-buffbot.tp2`. The release package manifest is derived from the `LANGUAGE` declarations, and the tests reject missing or undeclared catalogs.
6. Run `python -m pytest tests/test_localization.py tests/test_release_package.py -q` (and ideally the full test suite) before opening the PR.
7. Include the translator credit you would like shown in the README and release notes.

### Developer Setup

For iterative development without running WeiDU each time:

```bash
# Set your game path (one-time setup)
echo 'BGEE_DIR="/path/to/your/game"' > tools/deploy.conf

# Deploy to game override
bash tools/deploy.sh
```

Requires Python 3 only for the clean English-fallback TLK patch (innate ability tooltip names). Localized WeiDU state is preserved without invoking the patcher.

### Repo Structure

```
bg-eeex-buffbot/
├── buffbot/              # Mod source files (copied to override/)
│   ├── setup-buffbot.tp2 # WeiDU installer
│   ├── M_BfBot.lua       # Bootstrap (auto-loaded by EEex)
│   ├── BfBotCor.lua      # Core namespace, logging, field resolution, caches
│   ├── BfBotLoc.lua      # File-backed UTF-8 localization with English fallback
│   ├── BfBotCls.lua      # Buff classifier (opcode scoring)
│   ├── BfBotScn.lua      # Spellbook scanner (known spells iterators)
│   ├── BfBotExe.lua      # Execution engine (parallel per-caster)
│   ├── BfBotPer.lua      # Persistence (marshal handlers, presets, export/import)
│   ├── BfBotInn.lua      # F12 innate abilities (runtime SPL generation)
│   ├── BfBotUI.lua       # Config panel logic
│   ├── BfBotTst.lua      # Test suite (600+ assertions)
│   ├── BuffBot.menu      # UI definitions (.menu DSL)
│   └── lang/             # Complete WeiDU translation catalogs
├── tools/                # Dev utilities
│   ├── deploy.sh         # Copy files to game override
│   └── patch_tlk.py      # TLK patcher for innate tooltips
├── docs/                 # Design docs and analysis
└── README.md
```

## Credits

- **[EEex](https://github.com/Bubb13/EEex)** by Bubb — makes this entire mod possible
- **[Bubble Buffs](https://github.com/factubsio/BubbleBuffs)** by factubsio — original inspiration (Pathfinder: WotR)
- **[robovoid](https://github.com/robvoid)** — original Simplified Chinese translation in [PR #50](https://github.com/Chrizhermann/bg-eeex-buffbot/pull/50); the implementation was reworked on BuffBot's current localization architecture
- **[Claude Code](https://claude.ai/code)** by Anthropic — AI development assistant

## License

[MIT](LICENSE)
