# BuffBot — Project Context for Claude Code

## What This Is

BuffBot is a mod for Baldur's Gate: Enhanced Edition (BG:EE) and BG2:EE that provides in-game configurable buff automation. It depends on [EEex](https://github.com/Bubb13/EEex) for Lua access to engine internals. Inspired by [Bubble Buffs (BUBBLES)](https://github.com/factubsio/BubbleBuffs) from Pathfinder: Wrath of the Righteous.

## Current Phase

Implementation in progress — all core modules implemented, UI rendering in-game (testing in progress):

- **Spell Scanner + Buff Classifier** (`BfBot.Scan` + `BfBot.Class`) — 52 unit tests passing
- **Execution Engine** (`BfBot.Exec`) — parallel per-caster casting via `EEex_LuaAction` chaining, with pre-flight skip checks (SPLSTATE + effect list fallback, dead caster/target, no slot). Tested with 6 casters casting 105 spells in parallel, skip detection confirmed working across multiple runs.
- **Persistence** (`BfBot.Persist`) — per-character config saved in EEex save games via marshal handlers (`EEex_Sprite_AddMarshalHandlers`), global preferences via INI. Auto-populates presets from scanner, builds execution queues from saved presets. Preset create/delete/rename implemented.
- **Configuration UI** (`BfBot.UI`) — in-game config panel with character tabs, dynamic preset tabs (up to 5), scrollable spell list with checkbox/icon/name/count/target columns, target picker sub-menu, preset create/delete/rename, cast/stop buttons. Actionbar button + F11 hotkey access. Panel renders and opens in-game; interaction testing in progress.

- **Innate Abilities** (`BfBot.Innate`) — per-preset F12 innate abilities for each party member. Runtime SPL generation with opcode 402 (Invoke Lua) + opcode 171 (re-grant). TLK patching via `tools/patch_tlk.py` for tooltip names ("BuffBot 1"–"BuffBot 5"). Correct character/preset targeting via CGameEffect field access. Verified working in-game.

Next: Complete in-game verification of UI interaction (toggle, target, preset management), then post-MVP features (cheat mode, export/import, actionbar button polish, custom innate icons). Analysis documents are in `docs/`, mod source in `src/`, deploy via `bash tools/deploy.sh`. Test all modules: `BfBot.Test.RunAll()` in EEex console. Test persistence only: `BfBot.Test.Persist()`. Test execution: `BfBot.Test.Exec()`. Toggle UI: `BfBot.UI.Toggle()` or F11.

### Execution Engine Details
- **Parallel per-caster**: Each caster gets their own sub-queue and `_Advance(slot)` LuaAction chain. All casters start simultaneously.
- **Skip detection**: SPLSTATE as fast negative (if none of spell's SPLSTATEs active → definitely not buffed, skip effect list walk), then authoritative effect list check (`sprite.m_timedEffectList` + `effect.m_sourceRes:get()` matching) for positive SPLSTATE or spells without SPLSTATEs. Logs `"splstate false positive caught"` when SPLSTATE was active but effect list disagrees.
- **Queue format**: `{caster=0-5, spell="RESREF", target="self"|"all"|1-6}`
- **API**: `BfBot.Exec.Start(queue)`, `BfBot.Exec.Stop()`, `BfBot.Exec.GetState()`, `BfBot.Exec.GetLog()`
- **Log file**: `buffbot_exec.log` in game directory (append mode)

### Persistence Details
- **Per-character config**: stored in `EEex_GetUDAux(sprite)["BB"]` via marshal handlers. Survives save/load automatically.
- **Marshal handler name**: `"BuffBot"` — registered via `EEex_Sprite_AddMarshalHandlers` in `BfBot.Persist.Init()` (called at M_ load time)
- **CRITICAL: No booleans in config** — EEex marshal only supports number/string/table values. Booleans cause `EEex_Error()` and crash saves. All boolean-like fields use `1`/`0`.
- **Config schema** (v1): `{v=1, ap=1, presets={[1]={name,cat,spells={[resref]={on,tgt,pri}}}, [2]={...}}, opts={skip=1,cheat=0}}` — `tgt` can be a string (`"s"`, `"p"`, `"1"`-`"6"`) or a table of slot strings (`{"1","3","5"}`) for multi-target assignment
- **Auto-population**: `_CreateDefaultConfig` scans castable spells, sorts by duration, puts ALL buff spells into BOTH default presets. Preset 1 ("Long Buffs") has long/permanent enabled + rest disabled; Preset 2 ("Short Buffs") has short enabled + rest disabled. Enabled spells get low priorities (cast first), disabled get high. Instant spells included but disabled in both.
- **Queue building**: `BuildQueueFromPreset(idx)` walks all party members, filters to enabled+castable spells, maps targets (`"s"->"self"`, `"p"->"all"`, `"N"->tonumber(N)`, table→one entry per slot), returns queue for `BfBot.Exec.Start()`
- **INI preferences**: cross-save global settings in `baldur.ini` section `[BuffBot]` via `Infinity_GetINIValue`/`Infinity_SetINIValue`
- **API**: `GetConfig`, `SetConfig`, `GetPreset`, `GetActivePreset`, `SetActivePreset`, `SetSpellEnabled`, `SetSpellTarget`, `SetSpellPriority`, `GetSpellConfig`, `GetOpt`, `SetOpt`, `BuildQueueFromPreset`, `GetPref`, `SetPref`, `RenamePreset`, `CreatePreset`, `DeletePreset`
- **End-to-end verified**: `BuildQueueFromPreset(1)` → 52 entries → `Exec.Start()` → 6 casters casting in parallel. Use `BfBot.Exec.Start(BfBot.Persist.BuildQueueFromPreset(1))` in console (avoid `local` — EEex console scopes each line separately).
- **Preset management**: `RenamePreset(sprite, idx, name)`, `CreatePreset(sprite, name)` (up to 5, populates with union of all existing spells disabled), `DeletePreset(sprite, idx)` (refuses to delete last preset, returns 1 on success not boolean)
- **Future Persist APIs (not built yet)**: `CopyPreset`, `RefreshPresets` — nice-to-have for preset management
- **Save game scope**: BG:EE saves are NOT character-bound or playthrough-bound — just game state snapshots. Config is per-character per-save via UDAux, which covers the core use case.

### Configuration UI Details
- **Files**: `src/BfBotUI.lua` (Lua logic, ~510 lines), `src/BuffBot.menu` (.menu DSL definitions, ~600 lines)
- **Init chain**: `M_BfBot.lua` → `Infinity_DoFile("BfBotUI")` → `EEex_Menu_AddAfterMainFileLoadedListener` → `BfBot.UI._OnMenusLoaded()` (loads .menu, injects actionbar button, registers F11 hotkey + sprite listeners)
- **Panel access**: Actionbar button via `EEex_Menu_InjectTemplate("WORLD_ACTIONBAR", "BUFFBOT_BTN", ...)` + F11 via `EEex_Key_AddPressedListener`
- **Panel background**: Dark rectangle via `rectangle 5` + `rectangle opacity 200` (NOT BAM — stretched BAMs look terrible)
- **Character tabs**: 6 button slots, visibility gated by `buffbot_charNames[N]` (populated from party)
- **Preset tabs**: 5 button slots (dynamic) + "Rename" + "New" buttons. Visibility gated by `buffbot_presetNames[N]`. Delete button below list (disabled when only 1 preset remains).
- **Spell list**: `.menu` `list` widget with label-only columns: checkbox text `[X]/[ ]`, spell icon, name (color-coded), memorized count, target text. Data source: `buffbot_spellTable` (Lua global array). Row selection via `var "buffbot_selectedRow"`.
- **CRITICAL `.menu` limitation**: `button` elements inside `list > column` blocks do NOT respond to clicks. Only `label` elements work. Toggle uses list-level `action` with `cellNumber` guard instead.
- **Interaction model**: Click checkbox or icon column (cellNumber <= 2) to toggle enable/disable directly. Click name/count/target columns to select the row for target changes via the "Target: ..." button below the list. External "Enable/Disable" button also works as secondary toggle method. **IMPORTANT**: `rowNumber` in list `action` callbacks is stale (last render pass value) — always use `buffbot_selectedRow` (the `var` binding) which is correctly set at click time.
- **Target picker**: BUFFBOT_TARGETS sub-menu with Self/Party + per-player buttons. **Multi-target mode**: when spell has count > 1, picker switches to checkbox toggle mode ([X]/[ ] per character) with a Done button. `BfBot.UI.PickTarget(value)` handles both single-select (auto-close) and multi-select (toggle) modes.
- **Cast/Stop**: Cast builds queue from active preset via `BuildQueueFromPreset()` → `Exec.Start()`. Stop calls `Exec.Stop()`.
- **Auto-refresh**: Sprite listeners (`QuickListsChecked`, `QuickListCountsReset`, `QuickListNotifyRemoved`) invalidate scan cache then refresh. Tab switches use cached data (no invalidation).
- **No booleans**: All UI code interacting with Persist uses 0/1 integers, never true/false. `ToggleSpell` passes integer `newState` directly.
- **Shared utility**: `BfBot._GetName(sprite)` — safe character name getter used by both Exec and UI modules
- **In-game status**: Panel renders correctly, character/preset tabs work, spell list populates. Interaction (toggle, target, preset create/delete) deployed but awaiting final in-game verification.

### Innate Abilities Details (VERIFIED IN-GAME)
- **Per-preset innates**: Each character gets 1 innate per configured preset in F12/special abilities
- **30 SPL files**: `BFBT{slot}{preset}.SPL` (6 slots x 5 presets), generated at runtime by `_EnsureSPLFiles()` during M_ load
- **SPL structure**: 250 bytes — Header (114) + 1 ability (40, self/instant) + 2 features (48 each: opcode 402 + opcode 171)
- **Opcode 402 (EEex Invoke Lua)**: Calls global `BFBOTGO(param1, param2, special)`. `param1` is CGameEffect userdata — access slot via `param1.m_effectAmount`, preset via `param1.m_dWFlags`. Maps to `BuildQueueForCharacter(slot, preset)` + `Exec.Start(queue)`.
- **Opcode 171 (Give Innate)**: Re-grants self after cast (standard IE repeatable innate pattern)
- **Grant/Revoke**: `AddSpecialAbility` / `RemoveSpellRES` via `QueueResponseStringOnAIBase` (NOT instant — these are not in INSTANT.IDS)
- **Tooltip names**: TLK patched at deploy time by `tools/patch_tlk.py`. Appends "BuffBot 1"–"BuffBot 5" to `dialog.tlk`. Base strref written to `override/bfbot_strrefs.txt`, read by `_BuildSPL` at M_ load for SPL name fields (offsets 0x0008, 0x000C).
- **Icon**: `SPWI218B` (Stoneskin button BAM) — placeholder, custom BAM post-MVP
- **Spell level**: Set to preset index (1-5) for separate F12 lines
- **Party slot encoding**: Slot (0-5) baked into opcode 402 param1, preset (1-5) into param2. Stale if party rearranged — `RefreshAll()` on party change.
- **Lazy grant**: First sprite event in `BfBot.UI._OnSpellListChanged` triggers `Grant()` once per session
- **API**: `BfBot.Innate.Grant()`, `.Revoke(slot)`, `.Refresh(slot)`, `.RefreshAll()`, `._EnsureSPLFiles()`, `._BuildSPL(slot, preset)`

### Future: Config Export/Import (post-MVP)
Shareable preset templates need file-based storage outside save games:
- `BfBot.Persist.ExportPreset(sprite, presetIndex, filename)` — write preset to file
- `BfBot.Persist.ImportPreset(sprite, presetIndex, filename)` — load preset from file
- Could support a "template library" of built-in presets (e.g., "Standard Prebuff", "Boss Fight")
- Defer to post-MVP after config UI is working

### Known Classifier Issues (to address in config UI / classifier tuning)
The buff classifier (`BfBot.Class.Classify`) is too generous — these categories score as false-positive buffs:
- **Heals/cures**: Cure Light Wounds, Slow Poison, Cure Disease, Neutralize Poison — instant heals, not buffs
- **Traps**: Set Spike/Exploding/Time Trap, Set Snare — thief HLAs
- **Offensive**: Charm Animal/Person, War Cry, Fireburst — hostile spells
- **Summons**: Summon Planetar, Elemental Prince Call
- **Utility/crafting**: Alchemy (Mage), Scribe Scrolls (Mage), Tracking, Magical Stone
- **Setup spells**: Contingency, Chain Contingency, Simbul's Spell Trigger/Sequencer/Matrix
- **Shapeshifts**: Black Bear, Brown Bear, Wolf, Natural Form — debatable

These false positives don't affect the execution engine (it casts whatever it's given). The config UI's manual override will handle edge cases. Classifier heuristic improvements are a separate task.

### SPLSTATE Skip False Positive (FIXED)
Modded spells can share SPLSTATEs. Example: Death Ward (splstate 8) was skipped via splstate 67 (Berserker Rage's state) because SCS Death Ward's feature blocks also set splstate 67. **Fix**: SPLSTATE is now used only as a fast negative (if none active → spell definitely absent, skip effect list walk). Positive SPLSTATE results fall through to the authoritative effect list check (`_HasActiveEffect`), which matches on the actual spell resref. Diagnostic `INFO` log entries mark caught false positives (`"splstate false positive caught"`).

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
- **Cheat mode (option)**: instant or near-instant casting, bypassing normal timing. Spell slots still consumed
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
- `src/` — mod source files (Lua, .menu, .BAF, .tp2)
- `tools/` — helper scripts and utilities

## Key References

- EEex source: https://github.com/Bubb13/EEex
- IESDP (Infinity Engine file format docs): https://gibberlings3.github.io/iesdp/
- WeiDU documentation: https://weidu.org/
- Near Infinity (IE file browser/editor): https://github.com/NearInfinityBrowser/NearInfinity
- BubbleBuffs (inspiration): https://github.com/factubsio/BubbleBuffs
