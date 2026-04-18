# Changelog

## v1.3.10-alpha (2026-04-18)

### Fixed
- **Remove button was not reversible** — once a spell was removed from the buff list, it was also hidden from the Add Spell picker, so an accidental Remove click had no recovery path. The picker now includes previously-excluded spells and sorts them to the top for easy undo. Clicking the spell in the picker flips the override back to "include" and auto-merge restores it to the preset.

## v1.3.9-alpha (2026-04-11)

### Fixed
- **CRITICAL: F12 innate ability accumulation** — each use of an F12 innate added a duplicate known spell entry via opcode 171 (Give Innate). Over time (and especially after resting), characters accumulated dozens of copies (37+ reported). This corrupts the CRE spell list and can crash the engine on rest.
  - **Root cause**: opcode 171 unconditionally adds to both the known AND memorized spell lists on every application. The "re-grant after cast" pattern creates unbounded accumulation.
  - **Fix**: removed opcode 171 from all BFBT SPLs. Replaced with opcode 172 (Remove Innate) for post-cast cleanup + Lua-side `AddSpecialAbility` re-grant with duplicate guard.
  - **Backwards compatible**: existing saves with accumulated innates are automatically cleaned up on first session load (one-time startup cleanup via `RefreshAll` with 50-pass `Revoke`).
  - All innate grant paths now check `_HasInnate` before calling `AddSpecialAbility` to prevent future duplicates.

## v1.3.8-alpha (2026-04-11)

### Fixed
- **WeiDU packaging** — moved `setup-buffbot.tp2` inside the `buffbot/` mod folder (standard convention). Fixes compatibility with mod managers and automated installers (BiG World Setup, Project Infinity, etc.) that expect the tp2 inside the mod folder.

## v1.3.7-alpha (2026-04-10)

### Added
- **Sort by Duration button** — one-click reorder of the current preset's spell list by duration (permanent > long > short > instant). Persists immediately. Available in both normal and variant button layouts.

## v1.3.4-alpha (2026-04-08)

### Added
- **Movable panel** -- drag the title bar to reposition the config panel (#24)
- **Resizable panel** -- drag the bottom-right corner to resize (#24)
- **Reset Layout button** -- restores default 80%-centered panel
- Panel position/size persisted to baldur.ini across sessions
- Screen clamping on resolution change

## v1.3.3-alpha (2026-04-06)

### Bug Fix
- Panel rendering broken on ultrawide / non-standard resolutions (#25) — parchment background MOS was a fixed 2048x1152 image, leaving a black gap on ultrawides (3440x1440+). Now generates the MOS at runtime by tiling existing PVRZ blocks to match the actual screen size. Also handles resolution changes mid-session.

## v1.3.2-alpha (2026-04-06)

### Bug Fix
- LuaJIT auto-installer was never actually installing LuaJIT — `INDEX_BUFFER` matched a documentation comment in `InfinityLoader.ini` instead of the actual setting, causing the component to always skip with "LuaJIT is already active"
- Replaced with `COUNT_REGEXP_INSTANCES` using `^` line anchor to match only actual INI setting lines
- Verified working on both EEex stable (v0.11.0-alpha) and devel branches

## v1.3.1-alpha (2026-04-05)

### Installer
- LuaJIT auto-detection and installation — BuffBot installer now checks for EEex LuaJIT and installs it from EEex's own files if missing
- Fixes crash on EEex devel branch when LuaJIT component not selected (`io` global nil at BfBotInn.lua:12)

### Runtime
- Graceful degradation without LuaJIT — core features (scanning, config, casting) work; F12 innates, Quick Cast, Export/Import, and logging disabled with clear warning message

## v1.3.0-alpha (2026-04-02)

### Features
- Subwindow selection spells (opcode 214) — variant picker for spells like Protection from Elemental Energy (#20)
  - Auto-detects opcode 214 in spell feature blocks, parses the referenced 2DA for variant sub-spells
  - Variant picker sub-menu: select which sub-spell (Fire, Cold, Electricity, Acid, etc.) to cast
  - Enable gate: cannot enable a variant spell without selecting a variant first
  - Execution engine consumes parent spell slot via `m_flags` manipulation, casts variant directly via `ReallyForceSpellRES` — no subwindow ever opens
  - Active buff skip detection uses variant resref (the variant produces the buff effects)
  - Safety skip for variant spells with no variant configured
  - Dual button layout: variant spells show squeezed button row with Variant button; normal spells unchanged
  - 20 new tests (200+ total)

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
