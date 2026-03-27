# Changelog

## v1.2.2-alpha (2026-03-27)

### Features
- Target picker redesign: ordered priority list with fallback chain (#18)
  - Click party members to assign cast priority (1st, 2nd, 3rd...) — skip detection falls through to next target
  - "All Party" populates all members in portrait order for reordering
  - Move Up/Down buttons for priority reordering within the picker
  - Self-only and AoE spells locked to appropriate target by default, with "Unlock Targeting" override for modded spells
  - Name-based target storage — targets survive party rearrangement (old slot-based saves converted automatically)
  - `tgtUnlock` per-spell field for overriding targeting type lock

## v1.2.1-alpha (2026-03-27)

### Bug Fixes
- **CRITICAL**: Fix innate ability accumulation that corrupted save files and crashed on rest
  - `RemoveSpellRES` silently fails when queued (not in INSTANT.IDS) — innates were never removed
  - Each preset refresh added new innates without removing old ones, causing 3x+ accumulation
  - Bloated spell lists corrupted CRE data, causing NULL pointer crash during rest
  - Fix: new `BFBTRM.SPL` with opcode 172 (Remove Innate) applied via `ReallyForceSpellRES`
  - Existing accumulated innates cleaned up automatically (5-pass revoke on next refresh)

## v1.2.0-alpha (2026-03-19)

### Features
- Scanner refactor: known spells iterators as primary catalog source instead of GetQuickButtons (#17)
  - All known spells now visible (including exhausted/unmemorized) — no more disappearing spells
  - Spell Revisions strref 9999999 handled correctly (names display properly)
  - Scan entries include `isAoE` and `isSelfOnly` targeting flags (preparation for #18)
  - Simplified architecture: 394 → 254 lines, removed 3 dead code paths

### Bug Fixes
- F12 innate abilities no longer display "panic" on Lua errors — BFBOTGO wrapped in pcall (#9)
  - Self-healing: stale party slot detection triggers automatic RefreshAll
  - Errors logged to `buffbot_innate.log` for debugging
- Exhausted spells (0 remaining slots) now show name and icon in spell list (#8)

## v1.1.0-alpha (2026-03-08)

### Features
- Custom leather+brass panel border using EEex's 9-slice rendering system
- Parchment texture background for main panel and all popup sub-menus (target picker, rename, spell picker, import)
- Text colors updated for parchment readability

### Installer
- WeiDU installer now copies visual assets (MOS, PVRZ) alongside Lua/menu files

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
