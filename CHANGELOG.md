# Changelog

## Unreleased

### Fixed
- Active preset selections 6–8 now survive config validation and save import; invalid or missing selections reset safely to preset 1. (#52, #58)

### Installer
- **BuffBot's main component now fails before changing the TLK or override when the exact EEex LuaJIT loader state is not active.** The error directs normal and Project Infinity users to enable EEex LuaJIT or install BuffBot's helper first, preventing a successful-looking main-only install with an unusable loader state. (#36, #62)
- **The existing LuaJIT helper is declared before the main component while retaining its historical component ID 1 (main remains 0).** Selecting both in one WeiDU run activates or repairs LuaJIT before main validation; an exact runtime activated externally by EEex is accepted without a BuffBot component-ownership requirement.

### Testing
- Added synthetic v0.11/v1 coverage for inactive main-only rollback, externally-owned active state, combined helper/main ordering, safe wrong-order recovery, the required two-component legacy update, recoverable main-only update rejection, and legacy helper/main uninstall ownership.

## v1.7.1-alpha (2026-08-20)

### Fixed
- **Preset targets now survive character display-name changes.** BuffBot still resolves exact current display names first, then falls back to the character's stable, case-insensitive death variable when the stored name is stale. This applies consistently to Cast Character, Cast All, and allied-summon queue construction. (#51)
- **An unresolved single-character target can no longer become a party-wide cast.** Stale or unknown single names now produce no queue entry, matching the existing safe behavior for unresolved names inside multi-target lists. Valid members of a partially stale target list remain in their original order.

### Diagnostics and compatibility
- When every configured target for an otherwise castable spell is unavailable, the queue builder now records a diagnostic naming the caster and spell. Existing presets and exports require no migration or schema change; protagonist targets continue to use their display name because CHARNAME normally has no usable death variable.

### Testing
- The automated suite passes **256 tests**, including exact-name precedence, case-insensitive death-variable fallback, empty and `None` handling, unknown single targets, partial multi-target lists, party and summon caster shapes, repeats, and build-skip plumbing across all three queue builders.
- Live BG2:EE 2.6.6.0 + EEex 1.2.0 validation passed on the disposable test install: Imoen was temporarily renamed to Mione while a preset retained `Imoen`; BuffBot resolved Player2, built one Armor attempt, and completed the real cast on Mione. An unknown stored target built zero attempts, and the temporary name/config changes were restored. BG1EE and the broader compatibility matrix were not re-exercised in this pass.

## v1.7.0-alpha (2026-08-20)

### Added
- **Activated equipped items and inventory potions can now be configured as buff sources alongside spells.** BuffBot scans equipped/body and weapon slots, the three curated quickitem/fill slots, and potions anywhere in the backpack. Item rows are keyed by ITM resref, tinted separately in the mixed list, and start disabled in every new preset. The engine resolves the current slot or stack at cast time through `UseItem`, so moving or stacking a configured item does not break the preset. (#21)
- **Item-aware execution and active-effect checks.** Item attempts bypass Quick Cast, independently recheck charges/stacks and active effects at R1–R5, and follow opcode-146 sub-spell references when a wrapper item applies its lasting effect through a child SPL. The same queue path is used by Cast Character, Cast All, and generated F12 preset innates.
- **Picker item section and theme support.** Removed item rows can be recovered under a separate Items subsection; item rows use the new `itemColor` key across all six themes and never show spell-variant controls.

### Persistence and compatibility
- **Config schema v10 adds `kind="spl"|"itm"` to party preset entries.** Schema-v9 saves migrate lazily by tagging missing party kinds as spells. The migration also preserves development saves written by the earlier item-v8 branch while retaining main's summon and repeat migrations. Summon presets remain kindless and spell-only.
- Imported item entries remain stored while the item is absent and reappear when reacquired; the UI hides the absent row without deleting its settings. Items remain party-only: summon discovery, clone seeding, and summon queue construction reject item rows.

### Safety and scope
- `UseItem` can select only ability 0, so BuffBot admits an item only when ability 0 itself is a classified buff with a supported target. Higher-index weapon buffs remain excluded and tracked in #53. SPL and ITM classifier caches are source-qualified so a same-resref spell can never admit an unsafe item ability.
- Scrolls, wands, container contents, and inventory search remain deferred. Scroll and wand categories are rejected even in quickitem slots; backpack non-potions are rejected even though the engine could use them by resref.

### Testing
- The automated suite passes **249 tests**, including both schema-v8 lineages, v9→v10 migration, summon/item isolation, same-resref cache collisions, item repeats, fresh-sprite execution, picker recovery, deferred categories, duplicate stacks, and absent-item persistence.
- Live BG2:EE 2.6.6.0 + EEex 1.2.0 validation passed on the disposable test install: integrated `BfBot.Test.RunAll()`, default-disabled rows, quickslot and backpack potion consumption, equipped-item charges, active-effect skipping, R2 rechecks, Quick Cast bypass, generated F12 execution, marshal/export/import round trips, party-only scanning, and combat interruption with an item still pending. BG1EE and the broader EEex compatibility matrix were not re-exercised in this pass.

## v1.6.4-alpha (2026-08-20)

### Fixed
- **Spell-row selection no longer disappears during event-driven spellbook refreshes.** BuffBot now tracks the selected spell by resource reference plus the exact caster, preset, and Party/Summons context, then restores its current row and variant state after count or list rebuilds. Selection clears safely when the spell disappears or the user changes context instead of transferring to whichever spell occupies the old numeric row. (#67)
- **Selection-dependent actions remain anchored to the intended spell across refreshes and reordering.** Target and variant dialogs retain the parent spell identity, Sort by Duration follows the selected spell, and repeat, lock, priority, target, variant, and remove actions cannot drift onto another row during a native list-widget update.

### Performance and compatibility
- **Quick-list events rebuild only the relevant visible caster while preserving per-sprite cache invalidation.** Internal `BFBT` events and unrelated sprites no longer cause unnecessary visible refreshes. Listener registration is idempotent across F5/menu reloads and dispatches through the current BuffBot namespace after a development hot reload.

### Testing
- Added an in-game `SelectionRefresh` phase and automated coverage for reordered rebuilds, disappearance and exact-caster replacement, Party/Summons context switches, target and variant anchors, duration sorting, one-frame widget clobbers, event filtering, and listener reloads. The full automated suite passes (232 tests). The #67 patch also passed the in-game suite and manual unpaused selection checks on BG2:EE 2.6.6.0 with EEex v1.2.0 before integration with the v1.6.3 changes.

## v1.6.3-alpha (2026-08-19)

### Added
- **Per-spell repeat counts from R1 through R5 are available for party and summon presets.** Click the repeat cell in a spell row to increase it, or use the selected row's **Repeat: N** button: left-click increases and right-click decreases, with wrap-around in both directions. Repeat settings remain editable while a spell has zero available uses.
- **Repeat execution is target-major and preserves spell priority.** At R2, targets A and B run as A, A, B, B. A party-wide AoE at R2 casts twice total rather than twice for every party member.

### Safety and compatibility
- **Every repeat is independently checked before casting.** BuffBot rechecks spell availability, target state, and active effects each time. An attempt that reaches the cast path consumes one available use and observes normal aura and casting time unless the preset's Quick Cast mode applies; attempts skipped for no remaining use, a dead caster or target, or an active buff consume nothing. Ordinary summoning spells can continue while uses remain, but repeats never grant free casts.
- **Project Image remains owner-lock safe.** Its retained queue entry is forced to one attempt even if configured higher, and entries after it are still dropped rather than delayed until the image expires.
- **F12 preset innates now recharge in place without a per-use ability re-grant.** An EEex quick-list listener restores only availability bit 0 on the consumed memorized entry, preserving every other flag and avoiding the `AddSpecialAbility` ability-gained feedback path. Generated `BFBT{slot}{preset}.SPL` files now contain only the opcode-402 dispatch. Initial grants and structural reconciliation remain unchanged. (#64)
- **The new recharge listener is bounded to the matching party portrait and the engine's single innate memorization container.** Copied Project Image/Simulacrum innates remain excluded, listener registration is idempotent across new and legacy module reloads, and `BFBTRM` remains responsible for missing grants and duplicate/orphan cleanup without restoring opcode 171.

### Persistence
- **Config schema v9 stores bounded repeat counts in both party and summon spell entries.** v8 saves migrate lazily across both subtrees, while missing, non-integer, non-finite, or out-of-range values reset to R1. Downgrading a save after schema v9 has written it is unsupported.

### Testing
- Added automated runtime compatibility and queue coverage for schema migration, strict normalization, target-major and AoE expansion, spell-use and active-effect rechecks, Quick Cast, variants, late summons, cancellation, and Project Image safety. Dedicated UI tests cover wrapping, party/summon write routing, menu bindings, and minimum-size geometry. Innate recharge coverage checks all 48 generated preset spells, all 48 remover effects, flag preservation, duplicate handling, listener reloads, rejection paths, and every preset-execution outcome. The full pytest suite passes (195 tests).

## v1.6.2-alpha (2026-08-19)

### Improved
- **The Add Spell picker now surfaces spells with the most currently available casts first.** Previously removed spells retain recovery precedence; within each group, spells sort by available count descending, then localized name and resource reference for deterministic ties. Known spells with zero available casts remain selectable. Preset priority and cast order are unchanged. (#63)

### Testing
- Added an in-game `SpellPickerSort` phase covering recovery precedence, descending counts, nil-as-zero handling, localized-name ordering, deterministic resource-reference ties, and exact ties. The full automated suite passes, and the picker behavior was verified live on BG2:EE 2.6.6.0 with EEex v1.2.0.

## v1.6.1-alpha (2026-07-20)

### Compatibility
- **Restored EEex v0.11.0-alpha support with full BuffBot feature parity.** EEex v1 remains recommended. The installer now detects the EEex bootstrap, required Lua API, and one complete old or new script layout instead of relying on version-specific WeiDU component IDs.
- **LuaJIT setup follows the detected EEex layout.** BuffBot recognizes the legacy `5.1` loader used by v0.11 and the `5.1-LuaJIT` loader used by v1, while validating and repairing incomplete loader state when the required files are available.
- **Save downgrade boundary.** Downgrading an arbitrary save to v0.11 after EEex v1 and other EEex mods have written it is unsupported.

### Safety
- **Marshal-safe, non-mutating persistence export.** BuffBot now exports a sanitized copy of its saved configuration, converting booleans and dropping unsupported values, keys, and cyclic branches without modifying the live UDAux table.
- **Checked EEex callback boundaries.** BuffBot-owned event callbacks now contain Lua errors, preserve successful return values, and deduplicate repeated diagnostics instead of allowing failures to propagate through EEex.

### Testing
- **Synthetic installer coverage now exercises v0.11 and v1 acceptance, with v0.10 explicitly serving as the rejection floor.** The matrix also covers incomplete and ambiguous layouts, LuaJIT activation and repair, rollback, uninstall, and component-number independence.

## v1.6.0-alpha (2026-07-19)

### Added
- **Allied summons and clones can now cast BuffBot presets.** Project Images, Simulacra, and other allied non-party spellcasters with castable spellbooks appear in a new **Summons** view. Each stable summon identity has its own per-preset spell selection, targets, priority order, and Quick Cast setting. Use **Cast (this summon)** for a standalone run; configured live summons also join **Cast All** automatically.
- **Mid-run late join.** A summon created by an active party preset can attach to that same run as soon as it finishes spawning. Verified live with Imoen casting Project Image: the image joined, cast Stoneskin and Strength from its own preset, and the run completed with 3/3 casts and no skips.
- **Clone preset seeding.** Opening a clone identity for the first time seeds its preset from the owner's same-index preset, filtered to spells the live clone can cast. Subsequent edits belong to the summon identity and persist in the protagonist's save data.

### Safety and compatibility
- **Project Image owner-lock protection.** The engine prevents a Project Image's owner from acting while the image exists; queued actions otherwise become delayed "zombie casts" after expiry. BuffBot skips already-locked owners and drops owner entries ordered after a Project Image cast without reordering the user's priorities.
- Summon detection is structural and mod-friendly: alive, allied (`EA` 2–30), not a party portrait, and possessing a castable spellbook. Object IDs are resolved fresh by ID + name before every action, allegiance is revalidated, and vanished summons complete their chains cleanly instead of waiting for the watchdog.
- Multiplayer summon support is conservative pending a two-machine probe: clones join only when their owner is locally controlled; ownerless summons use the host-control heuristic. Set `[BuffBot] SummonsJoinCast = 0` in `baldur.ini` to disable automatic summon participation.

### Persistence
- **Config schema v8** adds per-identity summon presets under the protagonist's `summons` table. Existing saves upgrade lazily on first access. Downgrading a save after it has been written by schema v8 is unsupported.

### Known limitation
- Copied BuffBot F12 innates on clones do not route reliably to the clone and are deferred to follow-up work (#60). Configure and cast summons through the Summons view or let them join Cast All.

## v1.5.0-alpha (2026-07-05)

### Added
- **Multiplayer support — BuffBot no longer hangs on "casting" and only buffs the characters you control** (reported by Jester on Discord). In multiplayer each player controls a subset of the party. BuffBot queues each cast as `SpellRES(...)` + `EEex_LuaAction("BfBot.Exec._Advance(slot)")` on the caster's action list — but `EEex_Action_QueueResponseStringOnAIBase` inserts into the **local, non-networked** copy of that list (`virtual_InsertAction`). A character controlled by another player never runs that chain, so its `_Advance` callback never fires, `_activeCasters` never reaches 0, and the status stayed stuck on "casting" forever. Two-part fix:
  - **Caster filter (`BfBot.Mp.IsLocallyControlled`)**: BuffBot now only issues casts to characters the local machine controls. A character is locally controlled iff its entry in the engine control map (`CInfGame.m_multiPlayerSettings.m_pnCharacterControlledByPlayer`, indexed by join order) equals this machine's `CNetwork.m_idLocalPlayer` — the DirectPlay player **ID**, verified in-game (the player *number* `m_nLocalPlayer` does **not** match). Single-player short-circuits on `m_bConnectionEstablished == 0`, so single-player behavior is unchanged. All engine reads are `pcall`-guarded and degrade to "controllable" on any failure. Applied at all three caster-enumeration sites (`BuildQueueFromPreset`, `BuildQueueForCharacter`, and the exec engine's `_BuildQueue` as a final guard); buff **targets** stay full-party, so you can still buff a teammate's character. Pressing "Cast <name>" on a character another player controls now shows a clear message instead of doing nothing.
  - **Control mode override** (`baldur.ini [BuffBot]`, per-machine): `MpControlMode = auto` (default, engine detection) | `manual` (`MpControlNames`, a comma-separated list of the characters you control) | `all` (disable filtering). The manual fallback covers any edge case where auto-detection misbehaves.

### Fixed
- **Watchdog: a stuck buff run can no longer lock the UI on "casting" forever.** `BfBot.Exec` now tracks forward progress in **game time** (`_lastProgressGameTime` from `m_worldTime.m_gameTime`, bumped on every queued cast and every advance); `_SafetyTick` force-completes a run that has made no progress across `_WATCHDOG_TIMEOUT_GAMETICKS` (~30s of game time) via a new `_ForceComplete`, which strips orphaned `BFBTCH` cheat buffs and resets to idle — re-resolving each sprite from its portrait slot so it never dereferences a freed `CGameSprite` (same safety discipline as the #38 stale-state recovery). Game time (not wall-clock) is deliberate: it **freezes while the game is paused**, so pausing mid-buff never trips the watchdog and kills a healthy run. This is the unconditional safety net beneath the multiplayer caster filter: even if a caster chain wedges for any reason, the UI recovers instead of stranding the player on the Stop button.

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
