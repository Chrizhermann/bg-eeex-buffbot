# Changelog

## v1.0.0-alpha (2026-03-08)

Initial public alpha release.

### Features
- Dynamic spellbook scanning — discovers buff spells from all sources (memorized, innate, HLAs, kit abilities) in real time
- In-game config panel with per-character tabs, scrollable spell list, target assignment, priority ordering
- Up to 8 independent presets per character with create/rename/delete
- Parallel per-caster execution engine with active buff skip detection (SPLSTATE + effect list)
- Quick Cast mode — per-preset 3-state toggle (Off / Long only / All) for instant casting via Improved Alacrity
- F12 innate abilities — per-preset innate in each character's special abilities
- Manual spell override — "Add Spell" picker to include non-buff spells, "Remove" to exclude false positives
- Config export/import — export a character's full config to a file, import onto any character across saves or between players
- Save game persistence via EEex marshal handlers
- Works with SCS, Spell Revisions, kit mods, and other spell-adding mods automatically
- 129 automated tests

### Known Limitations
- Innate ability icons are placeholder (Stoneskin icon)
- Panel visual design is functional but unpolished
- Spell Revisions sub-spell pattern (Barkskin, Dispelling Screen) may need manual override via "Add Spell"
- Export/import directory listing uses Windows `dir /b` command (no macOS/Linux support yet)
