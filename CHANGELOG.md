# Changelog

## v1.5.0-alpha (2026-07-05)

### Added
- **Multiplayer support — BuffBot no longer hangs on "casting" and only buffs the characters you control** (reported by Jester on Discord). In multiplayer each player controls a subset of the party. BuffBot queues each cast as `SpellRES(...)` + `EEex_LuaAction("BfBot.Exec._Advance(slot)")` on the caster's action list — but `EEex_Action_QueueResponseStringOnAIBase` inserts into the **local, non-networked** copy of that list (`virtual_InsertAction`). A character controlled by another player never runs that chain, so its `_Advance` callback never fires, `_activeCasters` never reaches 0, and the status stayed stuck on "casting" forever. Two-part fix:
  - **Caster filter (`BfBot.Mp.IsLocallyControlled`)**: BuffBot now only issues casts to characters the local machine controls. A character is locally controlled iff its entry in the engine control map (`CInfGame.m_multiPlayerSettings.m_pnCharacterControlledByPlayer`, indexed by join order) equals this machine's `CNetwork.m_idLocalPlayer` — the DirectPlay player **ID**, verified in-game (the player *number* `m_nLocalPlayer` does **not** match). Single-player short-circuits on `m_bConnectionEstablished == 0`, so single-player behavior is unchanged. All engine reads are `pcall`-guarded and degrade to "controllable" on any failure. Applied at all three caster-enumeration sites (`BuildQueueFromPreset`, `BuildQueueForCharacter`, and the exec engine's `_BuildQueue` as a final guard); buff **targets** stay full-party, so you can still buff a teammate's character. Pressing "Cast <name>" on a character another player controls now shows a clear message instead of doing nothing.
  - **Control mode override** (`baldur.ini [BuffBot]`, per-machine): `MpControlMode = auto` (default, engine detection) | `manual` (`MpControlNames`, a comma-separated list of the characters you control) | `all` (disable filtering). The manual fallback covers any edge case where auto-detection misbehaves.

### Fixed
- **Watchdog: a stuck buff run can no longer lock the UI on "casting" forever.** `BfBot.Exec` now tracks forward progress (`_lastProgressTick`, bumped on every queued cast and every advance); `_SafetyTick` force-completes a run that has made no progress for 30s (`_WATCHDOG_TIMEOUT_MS`) via a new `_ForceComplete`, which strips orphaned `BFBTCH` cheat buffs and resets to idle — re-resolving each sprite from its portrait slot so it never dereferences a freed `CGameSprite` (same safety discipline as the #38 stale-state recovery). This is the unconditional safety net beneath the multiplayer caster filter: even if a caster chain wedges for any reason, the UI recovers instead of stranding the player on the Stop button.

### Internal
- New module `BfBotMp.lua` (`BfBot.Mp`) hosts multiplayer control detection and `BfBot.Mp.Probe()`, a `pcall`-guarded diagnostic that dumps the engine's multiplayer ownership fields for host+client comparison. Registered in `M_BfBot`, `setup-buffbot.tp2`, and `tools/deploy.sh`.
- New in-game tests: `BfBot.Test.Watchdog()` (8 assertions) and `BfBot.Test.Mp()` (7 assertions), wired into `BfBot.Test.RunAll()`. Verified in a live BG2:EE multiplayer host session: auto-detection keeps the host's own party, and manual-mode simulation confirms the filter correctly splits a party by ownership.

## v1.4.1-alpha (2026-05-24)

### Fixed
- **Deleting a preset left an orphan F12 innate behind** (#47, reported by MrFishHead on Discord). `BfBot.Innate.Refresh`'s lightweight branch iterated only the **config's** preset list to add missing entries — it never iterated the **sprite's** known-innate list to remove BFBT entries whose preset had been deleted. After a `DeletePreset` call, `BFBT{slot}{deletedIdx}` stayed in the F12 menu indefinitely. Rather than patch the gap with another condition, the whole innate-grant subsystem was refactored: 3 helpers (`_HasInnate`, `_MaxAccumulation`, `_HasOrphans`), the heavy/light bifurcation, and the dead `Grant()` function are replaced by one pure planner `BfBot.Innate._PlanReconciliation(sprite, slot, config)` plus a thin `Refresh(slot)` orchestrator. One iterator walk diffs actual-vs-desired and either revokes-all+regrants on any mismatch (duplicate **or** orphan) or grants-missing-only on clean state. Also pulls an inline `AddSpecialAbility` loop out of `BfBotPer._CreateDefaultConfig` (was leaking innate-grant mechanics into the persistence layer) and guards against UDAux-write failure to prevent re-entry recursion. New `BfBot.Test.PlanReconciliation` suite has 9 cases including a synchronous end-to-end opcode-172 removal via `EEex_GameObject_ApplyEffect` that proves the cleanup mechanism actually removes orphans from the sprite's known-innate list (no manual integration test needed).
- **Presets 6, 7, and 8 showed "Invalid: <number>" as their F12 innate name** (#48). When `MAX_PRESETS` went from 5 to 8 in `a51804e`, the WeiDU installer was not updated — only strrefs 1-5 were registered, and the Lua side used `_baseStrref + (preset - 1)` arithmetic that assumed contiguity. `setup-buffbot.tp2` now registers all 8 strrefs and writes each as its own line in `bfbot_strrefs.txt`; Lua reads them as an array indexed by preset. WeiDU does not guarantee contiguous strrefs across upgrades (existing strings keep their old strrefs while new ones get appended), so the array approach is more robust than the old arithmetic.

## v1.4.0-alpha (2026-05-21)

### Changed
- **EEex v1.0.0+ is now required.** BuffBot's tp2 fails fast on older EEex via a new `REQUIRE_PREDICATE (FILE_EXISTS ~EEex_scripts/EEex_Sprite.lua~)` — v1.0.0 moved EEex's Lua scripts from `EEex/` to game-root `EEex_scripts/`, making that path a reliable version marker. Pre-v1.0.0 installs hit a clear error message instead of silently breaking at runtime against API changes (the old iterator pattern, `EEex_Sprite_LuaHook_OnAfterEffectListUnmarshalled` hook, etc.) Upgrade EEex from https://github.com/Bubb13/EEex/releases before installing.
- **Innate grant migrated from polling to event-driven** — `BfBot.Innate.Init` now registers `EEex_Sprite_AddLoadedListener` so innates are granted/refreshed the moment each party sprite finishes loading (new game, save load, area transition, party join). The listener fires from `EEex_Sprite_LuaHook_OnAfterEffectListUnmarshalled` — i.e. after marshal restoration, so `EEex_GetUDAux` already has the user's saved config when `Refresh` queries it. Replaces the legacy one-shot `_startupCleanupDone` polling in `BfBot.Exec._SafetyTick` (which waited up to 2 seconds after world-screen entry before granting). Self-heals old accumulation via the existing `Refresh` bifurcation; new-joiner innates now grant on the next load tick instead of after the next safety-tick window.

### Removed
- **`BfBot.Persist._SanitizeValues`** — booleans-to-0/1 sanitizer that protected pre-v1.0.0 EEex marshal handlers from crashes. EEex v1.0.0 marshal handles booleans natively, so the sanitize call sites in `_ValidateConfig` and the export/import path are gone. BuffBot's schema continues to use integer 0/1 by design (consistency, avoids Lua's `0 == false` pitfalls), and `_hasBooleans` schema-consistency checks in the test suite stay in place.

### Internal
- README: Requirements section updated to "EEex v1.0.0+, any tier" with a collapsible explainer covering how BuffBot's installer activates LuaJIT on Minimal/Full tiers. Removed the stale v1.3.9 update banner.

## v1.3.16-alpha (2026-05-17)

### Fixed
- **Character tabs and the Cast button showed raw `^0xRRGGBBAA<NAME>` text** when [Tweaks Anthology's "Colorize NPC Names and Tooltips"](https://gibberlings3.github.io/Documentation/readmes/readme-cdtweaks.html) component is installed. cdtweaks rewrites NPC name strrefs to wrap them in IE color escapes (`^0xAABBGGRR<name>^-`). The engine's main renderer parses the escape; `text lua "..."` bindings in `.menu` files do not, so the prefix leaked as literal text in BuffBot's tabs, buttons, and target picker. The protagonist was unaffected because player-typed names are not strref-based. `BfBot._GetName` now strips the escape unconditionally via a new `BfBot._StripColorEscape` helper (no-op on installs without cdtweaks). Schema migration v6 → v7 walks all `preset.spells[*].tgt` entries and strips the prefix from previously-saved target names too — existing configs self-heal on first load. 13 new test assertions in `BfBot.Test.NameStrip` cover full prefix+suffix wraps, lowercase-hex variants, mid-string, multi-word names, single tgt + table tgt + `'s'`/`'p'` sentinels.

- **Save loads spammed "ability granted" toasts; preset create/delete froze the game for ~10 seconds, sometimes crashed.** All three symptoms shared a root cause: `BfBot.Innate.Revoke` queued **50 × `ReallyForceSpellRES("BFBTRM", Myself)`** per slot regardless of need (= 300 queued BCS actions per `RefreshAll`). The 50× was scaffolding from the v1.3.9-alpha legacy-migration cleanup and had become permanent overhead. Worse, `BfBot.Innate._HasInnate` was using the wrong EEex iterator pattern (`iter:hasNext()` instead of `for ... in iter`), the error was silently swallowed by `pcall`, and the function always returned `false` — so `Grant()` re-added every BFBT innate on every save load, accumulating duplicates that the 50× revoke then had to clean up. Two fixes:
  - New `BfBot.Innate._MaxAccumulation(sprite)` counts actual BFBT duplicates via the correct for-style iterator; `Revoke` now queues only `count + 1` passes (capped at 50). On clean saves: 0 passes. Iterator pattern in `_HasInnate` and the `BfBot.Test.Innate` diagnostic corrected.
  - `BfBot.Innate.Refresh` bifurcates: when accumulation > 1, queue revoke then **unconditionally** queue re-grants (revokes will clear before grants run); when accumulation ≤ 1, skip revoke and only grant the missing ones. Prevents the race where `_HasInnate` would be checked while revokes were still pending in the BCS queue (which would suppress the grant).

### Internal
- `tools/deploy.sh` now honors `BGEE_DIR` env var over `tools/deploy.conf`, so `BGEE_DIR=… bash tools/deploy.sh` targets a test install without editing the conf file.
- `.gitattributes` pins `*.sh` to LF endings, preventing `core.autocrlf=true` on Windows from breaking `bash tools/deploy.sh` after fresh checkouts.
- `tools/bump-version.sh` documents the `gh release create … --latest` flag and warns against `--prerelease` (every BuffBot release should be eligible for the GitHub "Latest" badge).

## v1.3.15-alpha (2026-04-30)

### Fixed
- **"Cast All" greyed out when the selected character has no preset spells** — the gate fed both action buttons via `BfBot.UI._CanCast()`, which only checked the current character's spell table. On characters with nothing configured for the active preset (e.g. Safana on a buff preset), Cast All was disabled even though other party members had spells in the same preset. Cast All now uses a new `BfBot.UI._CanCastAll()` that mirrors `BuildQueueFromPreset`'s cross-party scope: it falls through to the other portrait slots when the current character is empty. Cast Character keeps the original char-scoped gate.
- **Crash when pressing Stop after reloading a save mid-cast** (#38) — reported by sov_ on Discord. After loading a save while a buff queue was running, only the Stop button was enabled; clicking it triggered an access violation. `BfBot.Exec._casters[].sprite` cached `CGameSprite` userdata from the pre-reload party, and the post-reload save freed those C++ objects — calling `EEex_Action_QueueResponseStringOnAIBase` on the stale userdata segfaulted at the engine level (and `pcall` does not catch C++ access violations). Stop and `_Complete` now re-resolve the caster sprite from the current portrait slot in their cleanup loops, so they never dereference the freed pointer; `BFBTCR` is a no-op on targets without an active `BFBTCH`, so the cleanup is safe even when the slot now holds a different character. A new `_IsStateStale` heuristic compares cached caster names against the live portrait names and proactively hard-resets execution state from `_SafetyTick` when party composition changed across the reload, so the Cast / Cast Character buttons re-enable themselves on the next safety tick instead of leaving the user stuck pressing Stop. Covered by `BfBot.Test.StaleState` (8 assertions).

## v1.3.14-alpha (2026-04-28)

### Fixed
- **tp2 VERSION mismatch in v1.3.13-alpha** — the WeiDU `setup-buffbot.tp2` shipped with `VERSION ~v1.3.12-alpha~` despite the release being v1.3.13-alpha. Cosmetic only (visible in WeiDU install output, no functional impact), reported by Born2BSalty. Re-released as v1.3.14-alpha with the version line corrected and CI guards added so it can't happen again: `release.yml` now fails packaging if the release tag, tp2 VERSION, and `BfBot.VERSION` disagree, and a new `version-check.yml` fails every PR/push if the tp2 VERSION ≠ `v` + `BfBot.VERSION`. `tools/bump-version.sh` updates both files atomically.

## v1.3.13-alpha (2026-04-27)

### Added
- **Panel themes** — six selectable color schemes (Baldur's Gate 2 / Siege of Dragonspear / Baldur's Gate 1, each in light or dark mode) configurable in-game under a new "BuffBot" tab in the EEex Options menu. Theme switches apply live without reopening the panel. The default `bg2_light` preserves the v1.3.12 look pixel-for-pixel.
- **Text size scaling** — Small / Medium / Large in the same EEex Options tab. Title, spell-row text, list cells, and clickable text elements (Quick Cast, Reset) resize live. The character-tab and action-button captions stay at engine-default size — IE's BAM-button render path ignores `text.point` regardless of font, and Bubb's mods accept the same constraint.
- **EEex Options integration** — three settings (Dark Mode, Color Scheme, Text Size) under the new BuffBot tab. Persisted in `baldur.ini` under `[BuffBot]` as `Theme` (string) and `FontSize` (number).

### Fixed
- **Border PVRZ transparency on SOD / BG1 themes** — the new border PVRZs were generated from RGB-mode source PNGs with no alpha channel, so the 9-slice frame rendered an opaque white box around the panel. The PNG → PVRZ tool now chroma-keys white-ish backgrounds with a strict 240 threshold + corner flood-fill at 200, then zeros RGB on low-alpha pixels post-resize so DXT5 doesn't bleed white into antialiased edges.

## v1.3.12-alpha (2026-04-19)

### Fixed
- **Duration shown as "Inst" or "Perm" for spells with sub-spell delivery** (#33) — hierarchical spells like Prayer and Chaos of Battle deliver their real effects through opcode 146 (Cast Spell) into a sub-spell. The classifier was only reading the parent SPL, which had no timed effects of its own, so the duration column showed `Inst`. `BfBot.Class.GetDuration` now recurses into op=146 sub-spells (depth-limited, cycle-guarded) and reports the max duration across parent and children. Prayer now shows 30s, Chaos of Battle shows 60s, and the same pattern (including SR Barkskin) works correctly for duration.

## v1.3.11-alpha (2026-04-19)

### Added
- **Spell Position Lock** — pin a spell's row in a preset so it stays put when you press Sort by Duration. Locked spells also can't be reordered by Move Up/Down, and those buttons skip past locked rows when moving unlocked spells around. Click the new `[ ]` column on the right of the spell list to toggle — it flips to `[L]` in gold, and the spell name takes a warm gold-brown tint so locked rows are visible at a glance. Lock state persists in the save game (schema v6). Existing saves migrate automatically (`lock=0` for all pre-existing spells).

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
