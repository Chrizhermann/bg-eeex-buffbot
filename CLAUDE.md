# BuffBot — Project Context for Claude Code

## What This Is

BuffBot is a mod for Baldur's Gate: Enhanced Edition (BG:EE) and BG2:EE that provides in-game configurable buff automation. It depends on [EEex](https://github.com/Bubb13/EEex) for Lua access to engine internals. Inspired by [Bubble Buffs (BUBBLES)](https://github.com/factubsio/BubbleBuffs) from Pathfinder: Wrath of the Righteous.

## Current Phase

Alpha — core features working, UI functional, testing in progress:

- **Spell Scanner + Buff Classifier** (`BfBot.Scan` + `BfBot.Class`) — 52 unit tests passing
- **Execution Engine** (`BfBot.Exec`) — parallel per-caster casting via `EEex_LuaAction` chaining, with pre-flight skip checks (SPLSTATE + effect list fallback, dead caster/target, no slot). Tested with 6 casters casting 105 spells in parallel, skip detection confirmed working across multiple runs.
- **Persistence** (`BfBot.Persist`) — per-character config saved in EEex save games via marshal handlers (`EEex_Sprite_AddMarshalHandlers`), global preferences via INI. Auto-populates presets from scanner, builds execution queues from saved presets. Preset create/delete/rename implemented.
- **Configuration UI** (`BfBot.UI`) — in-game config panel with character tabs, dynamic preset tabs (up to 5), scrollable spell list with checkbox/icon/name/count/target columns, target picker sub-menu, preset create/delete/rename, cast/stop buttons. Actionbar button + F11 hotkey access. Panel renders and opens in-game; interaction testing in progress.

- **Innate Abilities** (`BfBot.Innate`) — per-preset F12 innate abilities for each party member. Runtime SPL generation with opcode 402 (Invoke Lua) + opcode 171 (re-grant). TLK patching via `tools/patch_tlk.py` for tooltip names ("BuffBot 1"–"BuffBot 5"). Correct character/preset targeting via CGameEffect field access. Verified working in-game.

- **Quick Cast / Cheat Mode** (`BfBot.Exec` + `BfBot.Persist` + `BfBot.UI`) — per-preset 3-state toggle (Off/Long/All). Applies temporary Improved Alacrity + casting speed reduction via runtime-generated BFBTCH.SPL. Two-pass queue splitting for mixed presets (long buffs fast, short buffs normal). Cycling button with color-coded text (uses `text` element, not `button`). Works through both UI Cast button and F12 innate abilities. Verified working in-game.

Next: Complete in-game verification of UI interaction (toggle, target, preset management), then post-MVP features (export/import, actionbar button polish, custom innate icons). Analysis documents are in `docs/`, mod source in `buffbot/`, deploy via `bash tools/deploy.sh`. Test all modules: `BfBot.Test.RunAll()` in EEex console. Test persistence only: `BfBot.Test.Persist()`. Test execution: `BfBot.Test.Exec()`. Test Quick Cast: `BfBot.Test.QuickCast()`. Toggle UI: `BfBot.UI.Toggle()` or F11.

### Execution Engine Details
- **Parallel per-caster**: Each caster gets their own sub-queue and `_Advance(slot)` LuaAction chain. All casters start simultaneously.
- **Skip detection**: SPLSTATE as fast negative (if none of spell's SPLSTATEs active → definitely not buffed, skip effect list walk), then authoritative effect list check (`sprite.m_timedEffectList` + `effect.m_sourceRes:get()` matching) for positive SPLSTATE or spells without SPLSTATEs. Logs `"splstate false positive caught"` when SPLSTATE was active but effect list disagrees.
- **Queue format**: `{caster=0-5, spell="RESREF", target="self"|"all"|1-6}`
- **Quick Cast (cheat mode)**: `BfBot.Exec.Start(queue, qcMode)` accepts optional qcMode (0=off, 1=long only, 2=all). Entries tagged with `cheat` flag based on qcMode and spell `durCat`. When qcMode=1, cheat entries sorted first per caster (two-pass split). BFBTCH.SPL (Improved Alacrity + casting speed reduction) applied before first cheat entry via `ReallyForceSpellRES`. BFBTCR.SPL (opcode 321 remove by resource) applied at cheat/normal boundary. Cleanup on Stop() removes lingering BFBTCH.
- **API**: `BfBot.Exec.Start(queue, qcMode)`, `BfBot.Exec.Stop()`, `BfBot.Exec.GetState()`, `BfBot.Exec.GetLog()`
- **Log file**: `buffbot_exec.log` in game directory (append mode)

### Persistence Details
- **Per-character config**: stored in `EEex_GetUDAux(sprite)["BB"]` via marshal handlers. Survives save/load automatically.
- **Marshal handler name**: `"BuffBot"` — registered via `EEex_Sprite_AddMarshalHandlers` in `BfBot.Persist.Init()` (called at M_ load time)
- **CRITICAL: No booleans in config** — EEex marshal only supports number/string/table values. Booleans cause `EEex_Error()` and crash saves. All boolean-like fields use `1`/`0`.
- **Config schema** (v4): `{v=4, ap=1, presets={[1]={name,cat,qc=0,spells={[resref]={on,tgt,pri}}}, [2]={...}}, opts={skip=1}}` — `tgt` can be a string (`"s"`, `"p"`, `"1"`-`"6"`) or a table of slot strings (`{"1","3","5"}`) for multi-target assignment. `qc` is per-preset Quick Cast mode (0=off, 1=long only, 2=all).
- **Auto-population**: `_CreateDefaultConfig` scans castable spells, sorts by duration, puts ALL buff spells into BOTH default presets. Preset 1 ("Long Buffs") has long/permanent enabled + rest disabled; Preset 2 ("Short Buffs") has short enabled + rest disabled. Enabled spells get low priorities (cast first), disabled get high. Instant spells included but disabled in both.
- **Queue building**: `BuildQueueFromPreset(idx)` walks all party members, filters to enabled+castable spells, maps targets (`"s"->"self"`, `"p"->"all"`, `"N"->tonumber(N)`, table→one entry per slot), returns queue for `BfBot.Exec.Start()`
- **INI preferences**: cross-save global settings in `baldur.ini` section `[BuffBot]` via `Infinity_GetINIValue`/`Infinity_SetINIValue`
- **API**: `GetConfig`, `SetConfig`, `GetPreset`, `GetActivePreset`, `SetActivePreset`, `SetSpellEnabled`, `SetSpellTarget`, `SetSpellPriority`, `GetSpellConfig`, `GetOpt`, `SetOpt`, `BuildQueueFromPreset`, `GetPref`, `SetPref`, `RenamePreset`, `CreatePreset`, `DeletePreset`, `GetQuickCast`, `SetQuickCast`, `SetQuickCastAll`
- **End-to-end verified**: `BuildQueueFromPreset(1)` → 52 entries → `Exec.Start()` → 6 casters casting in parallel. Use `BfBot.Exec.Start(BfBot.Persist.BuildQueueFromPreset(1))` in console (avoid `local` — EEex console scopes each line separately).
- **Preset management**: `RenamePreset(sprite, idx, name)`, `CreatePreset(sprite, name)` (up to 5, populates with union of all existing spells disabled), `DeletePreset(sprite, idx)` (refuses to delete last preset, returns 1 on success not boolean)
- **Future Persist APIs (not built yet)**: `CopyPreset`, `RefreshPresets` — nice-to-have for preset management
- **Save game scope**: BG:EE saves are NOT character-bound or playthrough-bound — just game state snapshots. Config is per-character per-save via UDAux, which covers the core use case.

### Configuration UI Details
- **Files**: `buffbot/BfBotUI.lua` (Lua logic, ~550 lines), `buffbot/BuffBot.menu` (.menu DSL definitions, ~620 lines)
- **Init chain**: `M_BfBot.lua` → `Infinity_DoFile("BfBotUI")` → `EEex_Menu_AddAfterMainFileLoadedListener` → `BfBot.UI._OnMenusLoaded()` (loads .menu, injects actionbar button, registers F11 hotkey + sprite listeners)
- **Panel access**: Actionbar button via `EEex_Menu_InjectTemplate("WORLD_ACTIONBAR", "BUFFBOT_BTN", ...)` + F11 via `EEex_Key_AddPressedListener`
- **Panel background**: Dark rectangle via `rectangle 5` + `rectangle opacity 200` (NOT BAM — stretched BAMs look terrible)
- **Character tabs**: 6 button slots, visibility gated by `buffbot_charNames[N]` (populated from party)
- **Preset tabs**: 5 button slots (dynamic) + "Rename" + "New" buttons. Visibility gated by `buffbot_presetNames[N]`. Delete button below list (disabled when only 1 preset remains).
- **Spell list**: `.menu` `list` widget with label-only columns: checkbox text `[X]/[ ]`, spell icon, name (color-coded), memorized count, target text. Data source: `buffbot_spellTable` (Lua global array). Row selection via `var "buffbot_selectedRow"`.
- **CRITICAL `.menu` limitation**: `button` elements inside `list > column` blocks do NOT respond to clicks. Only `label` elements work. Toggle uses list-level `action` with `cellNumber` guard instead.
- **Interaction model**: Click checkbox or icon column (cellNumber <= 2) to toggle enable/disable directly. Click name/count/target columns to select the row for target changes via the "Target: ..." button below the list. External "Enable/Disable" button also works as secondary toggle method. **IMPORTANT**: `rowNumber` in list `action` callbacks is stale (last render pass value) — always use `buffbot_selectedRow` (the `var` binding) which is correctly set at click time.
- **Target picker**: BUFFBOT_TARGETS sub-menu with Self/Party + per-player buttons. **Multi-target mode**: when spell has count > 1, picker switches to checkbox toggle mode ([X]/[ ] per character) with a Done button. `BfBot.UI.PickTarget(value)` handles both single-select (auto-close) and multi-select (toggle) modes.
- **Cast/Stop**: Cast builds queue from active preset via `BuildQueueFromPreset()` → `Exec.Start(queue, qcMode)`. Stop calls `Exec.Stop()`. qcMode read from preset's `qc` field via `GetQuickCast()`.
- **Quick Cast button**: `text` element (not `button` — BAM backgrounds override `text color lua`). Click cycles Off→Long→All→Off via `CycleQuickCast()` → `SetQuickCastAll()`. Color-coded text: white (Off), yellow (Long), red/orange (All). Uses `rectangle 5` + `rectangle opacity 160` for dark background.
- **Auto-refresh**: Sprite listeners (`QuickListsChecked`, `QuickListCountsReset`, `QuickListNotifyRemoved`) invalidate scan cache then refresh. Tab switches use cached data (no invalidation).
- **No booleans**: All UI code interacting with Persist uses 0/1 integers, never true/false. `ToggleSpell` passes integer `newState` directly.
- **Shared utility**: `BfBot._GetName(sprite)` — safe character name getter used by both Exec and UI modules
- **In-game status**: Panel renders correctly, character/preset tabs work, spell list populates. Interaction (toggle, target, preset create/delete) deployed but awaiting final in-game verification.

### Innate Abilities Details (VERIFIED IN-GAME)
- **Per-preset innates**: Each character gets 1 innate per configured preset in F12/special abilities
- **32 SPL files**: `BFBT{slot}{preset}.SPL` (6 slots x 5 presets) + `BFBTCH.SPL` (cheat buff) + `BFBTCR.SPL` (cheat remover), all generated at runtime by `_EnsureSPLFiles()` during M_ load
- **SPL structure**: 250 bytes — Header (114) + 1 ability (40, self/instant) + 2 features (48 each: opcode 402 + opcode 171)
- **Opcode 402 (EEex Invoke Lua)**: Calls global `BFBOTGO(param1, param2, special)`. `param1` is CGameEffect userdata — access slot via `param1.m_effectAmount`, preset via `param1.m_dWFlags`. Maps to `BuildQueueForCharacter(slot, preset)` + `Exec.Start(queue, qcMode)`. Reads preset's `qc` field via `GetQuickCast()` and passes through to execution engine.
- **Opcode 171 (Give Innate)**: Re-grants self after cast (standard IE repeatable innate pattern)
- **Grant/Revoke**: `AddSpecialAbility` / `RemoveSpellRES` via `QueueResponseStringOnAIBase` (NOT instant — these are not in INSTANT.IDS)
- **Tooltip names**: TLK patched at deploy time by `tools/patch_tlk.py`. Appends "BuffBot 1"–"BuffBot 5" to `dialog.tlk`. Base strref written to `override/bfbot_strrefs.txt`, read by `_BuildSPL` at M_ load for SPL name fields (offsets 0x0008, 0x000C).
- **Icon**: `SPWI218B` (Stoneskin button BAM) — placeholder, custom BAM post-MVP
- **Spell level**: Set to preset index (1-5) for separate F12 lines
- **Party slot encoding**: Slot (0-5) baked into opcode 402 param1, preset (1-5) into param2. Stale if party rearranged — `RefreshAll()` on party change.
- **Lazy grant**: First sprite event in `BfBot.UI._OnSpellListChanged` triggers `Grant()` once per session
- **API**: `BfBot.Innate.Grant()`, `.Revoke(slot)`, `.Refresh(slot)`, `.RefreshAll()`, `._EnsureSPLFiles()`, `._BuildSPL(slot, preset)`

### Quick Cast / Cheat Mode Details
- **Per-preset toggle**: `qc` field on each preset (0=off, 1=long only, 2=all). Set via `SetQuickCast(sprite, idx, val)` or `SetQuickCastAll(idx, val)` for party-wide.
- **BFBTCH.SPL** (cheat buff): 250 bytes — Header (114) + 1 ability (40, self/instant) + 2 effects (48 each). Effect 1: opcode 188 (Aura Cleansing / Improved Alacrity, param1=0 param2=1), 300s duration. Effect 2: opcode 189 (Casting Time Modifier, param1=10), 300s duration. Params verified against real IA spell SPWI921 and game-wide opcode 189 usage.
- **BFBTCR.SPL** (cheat remover): 202 bytes — Header (114) + 1 ability (40, self/instant) + 1 effect (48). Effect 1: opcode 321 (Remove Effects by Resource), resource = "BFBTCH".
- **Two-pass queue splitting** (qcMode=1): Entries tagged with `cheat` flag based on durCat. Cheat entries sorted first per caster. `cheatBoundary` computed per caster. BFBTCH applied before first cheat entry, BFBTCR applied when crossing boundary to normal entries. Robust to skipped entries (boundary/apply conditions use flags, not index matching).
- **Schema migration v3→v4**: Migrates old global `opts.cheat` (0/1) to per-preset `qc` field (cheat=1 → qc=2 on all presets, cheat=0 → qc=0). Removes `opts.cheat`.
- **UI cycling button**: `CycleQuickCast()` cycles 0→1→2→0 via `SetQuickCastAll()`. Color-coded: white=Off `{200,200,200}`, yellow=Long `{230,200,60}`, red/orange=All `{230,100,60}`.
- **Innate passthrough**: `BFBOTGO` handler reads `GetQuickCast(sprite, presetIdx)` and passes to `Exec.Start(queue, qcMode)`.
- **Design doc**: `docs/plans/2026-02-28-cheat-mode-design.md`

### Future: Config Export/Import (post-MVP)
Shareable preset templates need file-based storage outside save games:
- `BfBot.Persist.ExportPreset(sprite, presetIndex, filename)` — write preset to file
- `BfBot.Persist.ImportPreset(sprite, presetIndex, filename)` — load preset from file
- Could support a "template library" of built-in presets (e.g., "Standard Prebuff", "Boss Fight")
- Defer to post-MVP after config UI is working

### Known Issue: Old Save Configs Missing Spells
Save games created before commit 706f31e have preset configs where Long Buffs only contains long/permanent spells and Short Buffs only contains short spells (each preset missing the other category). The code was fixed in 706f31e to distribute ALL buff spells to both presets, but `_CreateDefaultConfig` only runs when no config exists — existing saves retain the old incomplete config. **To fix**: redeploy (`bash tools/deploy.sh`) and start a new game, or build a config migration that merges missing buff spells into existing presets (future task: merge missing spells in `GetConfig` or via schema version bump in `_MigrateConfig`).

### Classifier False Positive Reduction (IMPLEMENTED)
Three generic heuristics added to reduce false positives (no hardcoded resref lists):
1. **Self-ref opcode discount**: opcodes 318/324 referencing the spell's own resref (SCS anti-stacking infrastructure) score 0 instead of +2. Fixes: Charm Animal, Fireburst, War Cry inflation.
2. **Substance check**: spells passing the score threshold must have at least one substantive buff opcode (stat boost, protection, immunity, etc.). Opcodes 17 (Healing) and 171 (Give Ability) are "soft" — score normally but don't satisfy substance. Fixes: Set Snare, Contingency, Alchemy, Tracking.
3. **Toggle penalty**: opcode 318 self-ref (toggle/stance pattern) gets -8 penalty. Opcode 321 self-ref (normal buff refresh/remove-and-reapply) is NOT penalized. Fixes: Power Attack, Tracking stances.

**Known remaining edge case**: Spell Revisions Barkskin — SR delivers AC bonus via sub-spell (opcode 146), leaving the main SPL with only infrastructure opcodes. Classified as AMB (ambiguous, leaning buff) instead of definitive BUFF. Manual override via config UI will handle this (GitHub issue #1).

**Scanner filter**: `BFBT` prefix filter in `BfBot.Scan.GetCastableSpells` — skips BuffBot's own generated innate SPLs.

### isAoE False Positives and Wrong Default Targets (FIXED)
Three unreliable signals caused many single-target spells (Death Ward, Regeneration, Regenerate Critical Wounds, etc.) to be classified as AoE: `actionCount == 0` (many IE single-target spells have count 0), `fbAoE` from SCS feature blocks (SPLSTATE setters with broad target types), and `actionType == 1` heuristics. Additionally, `GetDefaultTarget` ignored its `isAoE` parameter, defaulting all non-self spells to "party". **Fix**: `IsAoE` now only trusts ability header target types 3 (everyone except caster) and 4 (everyone). `GetDefaultTarget` returns "p" only for AoE spells, "s" for single-target. Schema migration v1→v2 re-evaluates existing config targets.

### SPLSTATE Skip False Positive (FIXED)
Modded spells can share SPLSTATEs. Example: Death Ward (splstate 8) was skipped via splstate 67 (Berserker Rage's state) because SCS Death Ward's feature blocks also set splstate 67. **Fix**: SPLSTATE is now used only as a fast negative (if none active → spell definitely absent, skip effect list walk). Positive SPLSTATE results fall through to the authoritative effect list check (`_HasActiveEffect`), which matches on the actual spell resref. Diagnostic `INFO` log entries mark caught false positives (`"splstate false positive caught"`).

### Quick Cast BFBTCH Opcode Params Wrong (FIXED)
Two bugs in `_BuildCheatSPL()` caused Quick Cast to have no effect (or make casting slower): (1) opcode 188 (Improved Alacrity) had param1/param2 swapped — should be param1=0, param2=1 (matching real IA spell SPWI921); (2) opcode 189 (Casting Time Modifier) had param1=-10 (negative = slower) — should be param1=+10 (positive = faster, matching all real game spells using opcode 189). Also changed `ApplySpellRES` → `ReallyForceSpellRES` in BfBotExe.lua for reliable delivery of runtime-generated SPLs.

### Quick Cast Button Text Unreadable (FIXED)
`text color lua` does NOT work on `button` elements with `bam` backgrounds — the BAM overrides text rendering, so all three Quick Cast states showed the same brownish color. First attempted a label overlay on top of the button — but labels absorb mouse clicks in the IE engine, blocking button interaction. **Fix**: replaced with a `text` element which supports both `action` and `text color lua`, using `rectangle 5` + `rectangle opacity 160` for a dark clickable background.

## Tech Stack

- **WeiDU** — mod installer/patcher (setup-buffbot.tp2)
- **Lua + .menu files** — UI and core logic, via EEex's Lua bridge to the Infinity Engine
- **BAF/BCS** — AI scripts (BAF = source, BCS = compiled). May be used for AI-script-triggered buffing
- **2DA** — tabular data files used by the engine for lookups
- **SPL files / opcodes** — spell definitions; opcodes determine spell effects (buffs, protections, stat boosts, etc.)

## User Experience Design

### Panel Access (resolved)
- **Primary**: Dedicated actionbar button via `EEex_Menu_InjectTemplate("WORLD_ACTIONBAR", ...)` — avoids conflicts with BSME
- **Secondary**: F11 keyboard shortcut (configurable) via `EEex_Key_AddPressedListener`
- **Tertiary**: Per-preset innate abilities in F12/special abilities — one per preset per character, triggers buffing directly

### Config Panel
- **Per-character tabs** (confirmed) — select a party member, see their available buff spells, configure each one. This is the right model for BG where spell lists have minimal overlap across party members (unlike Pathfinder where casters share many buffs). Hardcore players (SCS/Ascension/Insane) think in per-character detail
- **Preset tabs** — secondary axis; within a character, switch between presets to configure different buff sets
- Spells are populated dynamically from the character's current state (memorized spells, innate abilities, HLAs, kit abilities, Bard Song, etc.)
- No hardcoded spell lists — if a character has it, it shows up; if they swap it out, it disappears
- **Future**: a global/party-wide overview view showing all characters' buffs at once can be added post-MVP as an enhancement

### Spell Classification
- **Auto-detect + manual override** — mod classifies spells as buffs based on SPL targeting type (friendly/self) and effect opcodes (stat boosts, protections, immunities, etc.). Player can manually include/exclude edge cases
- Must handle mod-added spells (SCS, Spell Revisions, kit mods) gracefully since it reads spell data dynamically

### Presets
- **Up to 5 fully independent presets** with copy/duplicate functionality (MVP), expandable beyond 5 post-MVP
- Default auto-populated presets: "Long Buffs" (preset 1) and "Short Buffs" (preset 2)
- Each preset is a completely separate configuration (own spell list, targets, order)
- **Design for situational presets**: not just Long/Short — players should be able to create "Undead Prebuff", "Dragon Fight", "Fire Resistance Stack", etc. The UI must make creating, naming, and switching presets easy
- **Fast preset switching**: selecting a different preset to cast should be minimal clicks (2 max from gameplay). Post-MVP: consider preset selector on actionbar or cycle button next to Cast

### Targeting
- **Smart defaults** based on spell targeting type: party-wide buffs -> party, self-only -> caster
- **Per-spell override** — player can assign a specific party member as the target for any buff

### Casting Behavior
- **Normal mode (default)**: real-time sequential casting. Buffs are queued and cast in order, engine handles pacing (aura cooldown, casting speed, Improved Alacrity, etc.). Player can interrupt. Default order: longest duration first, or custom order set by player
- **Quick Cast / cheat mode (implemented)**: per-preset 3-state toggle (Off/Long/All). Applies BFBTCH.SPL (opcode 188 Improved Alacrity + opcode 189 casting speed -10) via `ApplySpellRES`. When qc=1 (Long), only spells with durCat "permanent"/"long" (>=300s) get fast casting; short spells cast normally via two-pass queue splitting. When qc=2 (All), everything casts fast. Spell slots still consumed
- Can trigger for all party members or a single character

### Buff Overlap
- **Configurable**: option to skip buffs already active on the target, or recast regardless. Skip is the default

### Spell Slot Exhaustion
- **Skip + notify**: if a character runs out of spell slots mid-queue, skip that buff and display a character notification (DisplayStringHead or similar)

### Items
- Equipped item abilities (e.g., activated item effects) should be available in the config alongside spells/abilities
- Potions, wands, and scrolls are out of scope for MVP but can be added later

### Persistence
- **Save game integration**: config saved per-playthrough with the save game
- **External export/import**: presets can be exported to files and imported across playthroughs

### Party Changes
- Config is tied to the character (by character identity, not party slot)
- If a character leaves the party, their config persists silently
- If they rejoin, config is restored automatically
- Rematching config to a different character is possible but requires explicit player confirmation with a warning

## BG-Specific Considerations

- **BG1 vs BG2 spell cap**: BG1 caps at spell level 5, BG2 goes to 9 + HLAs. Mod must work for both
- **Multi-class/dual-class**: characters can have multiple spellbooks (e.g., Fighter/Mage/Cleric has arcane + divine). Scan all spellbooks
- **Dual-class transitions**: temporarily lose access to original class abilities until new class surpasses. Respect this
- **Spell stacking rules**: BG has specific non-stacking rules (e.g., two Haste effects don't stack). "Skip active buffs" needs to understand this via active effect detection
- **Aura cooldown**: 6 seconds between spells in BG2. Let the engine handle this, don't try to manage timing
- **Sequencers/Contingencies**: out of scope for MVP
- **Mod compatibility**: dynamic spell scanning means it should work with spell mods (SCS, Spell Revisions, etc.) automatically

## Repo Layout

- `docs/` — analysis documents, reference material, design notes
- `buffbot/` — mod source files (Lua, .menu, .tp2, etc.)
- `tools/` — helper scripts and utilities

## Global Rules (auto-loaded in all sessions)

These files in `~/.claude/rules/` contain verified EEex/IE gotchas and patterns. They apply to any BG:EE mod project and are loaded automatically:

- `~/.claude/rules/eeex-api-quick-ref.md` — EEex Lua API patterns (sprites, spells, effects, persistence, actions, UI)
- `~/.claude/rules/eeex-gotchas.md` — verified bugs and corrections (data types, API mismatches, opcode params, .menu UI quirks)
- `~/.claude/rules/menu-parser-rules.md` — .menu file parser rules that cause crashes if violated (7 rules)

When discovering new gotchas or API corrections through in-game testing, update the relevant rules file so the knowledge persists across all sessions and projects.

## Key References

- EEex source: https://github.com/Bubb13/EEex
- IESDP (Infinity Engine file format docs): https://gibberlings3.github.io/iesdp/
- WeiDU documentation: https://weidu.org/
- Near Infinity (IE file browser/editor): https://github.com/NearInfinityBrowser/NearInfinity
- BubbleBuffs (inspiration): https://github.com/factubsio/BubbleBuffs
