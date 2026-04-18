# BuffBot — Project Context for Claude Code

## What This Is

BuffBot is a mod for Baldur's Gate: Enhanced Edition (BG:EE) and BG2:EE that provides in-game configurable buff automation. It depends on [EEex](https://github.com/Bubb13/EEex) for Lua access to engine internals. Inspired by [Bubble Buffs (BUBBLES)](https://github.com/factubsio/BubbleBuffs) from Pathfinder: Wrath of the Righteous.

## Current Phase

Alpha — core features working, UI functional, testing in progress:

- **Spell Scanner + Buff Classifier** (`BfBot.Scan` + `BfBot.Class`) — iterator-based catalog (known spells iterators as primary source, GetQuickButtons for slot counts only). Scan entries include `isAoE`/`isSelfOnly` (0/1 integer) targeting flags. Exhausted spells retain name/icon/classification. SR strref 9999999 handled. 52+ unit tests passing.
- **Execution Engine** (`BfBot.Exec`) — parallel per-caster casting via `EEex_LuaAction` chaining, with pre-flight skip checks (SPLSTATE + effect list fallback, dead caster/target, no slot). Tested with 6 casters casting 105 spells in parallel, skip detection confirmed working across multiple runs.
- **Persistence** (`BfBot.Persist`) — per-character config saved in EEex save games via marshal handlers (`EEex_Sprite_AddMarshalHandlers`), global preferences via INI. Auto-populates presets from scanner, builds execution queues from saved presets. Preset create/delete/rename implemented.
- **Configuration UI** (`BfBot.UI`) — in-game config panel (~80% screen, dynamically sized) with character tabs, dynamic preset tabs (up to 8), scrollable spell list with checkbox/icon/name/duration/count/target columns, target picker sub-menu, preset create/delete/rename, cast/stop buttons. Actionbar button + F11 hotkey access. Panel renders and opens in-game; interaction testing in progress.

- **Innate Abilities** (`BfBot.Innate`) — per-preset F12 innate abilities for each party member. Runtime SPL generation with opcode 402 (Invoke Lua) + opcode 171 (re-grant). TLK patching via `tools/patch_tlk.py` for tooltip names ("BuffBot 1"–"BuffBot 5"). Correct character/preset targeting via CGameEffect field access. Verified working in-game.

- **Quick Cast / Cheat Mode** (`BfBot.Exec` + `BfBot.Persist` + `BfBot.UI`) — per-preset 3-state toggle (Off/Long/All). Applies temporary Improved Alacrity + casting speed reduction via runtime-generated BFBTCH.SPL. IA covers the entire queue — user spell priority always respected, no reordering by duration. Cycling button with color-coded text (uses `text` element, not `button`). Works through both UI Cast button and F12 innate abilities. Verified working in-game.

- **Manual Cast Order** (`BfBot.UI`) — Move Up/Down buttons for reordering spells within presets. Per-character, per-preset. Priority renumbered contiguously (1, 2, 3, ...) after each move. Selection follows the moved spell. Verified working in-game.

- **Auto-Merge New Spells** (`BfBot.UI._Refresh`) — New buff spells gained from leveling up or memorization changes are automatically merged into existing presets (disabled, at bottom of list) when the panel refreshes. No longer requires starting a new game to see new spells.

- **Manual Spell Override** (`BfBot.UI` + `BfBot.Persist`) — "Add Spell" picker sub-menu for including non-buff spells, "Remove" button for excluding false positives. Classification-level overrides stored per-character in `config.ovr`, synced to classifier on load. Schema v5.

- **Duration Column** (`BfBot.UI` + `BfBot.Scan` + `BfBot.Class`) — spell list shows per-caster-level buff duration in mixed format (e.g. `1h 30m`, `5m`, `Perm`, `Inst`). Duration computed per-sprite in scan entry (not shared classification cache). `GetDuration()` prefers timed effects over permanent — fixes spells with permanent infrastructure opcodes (326 Apply Effects, 48 Cure Intoxication) coexisting with real timed buffs.

- **Dynamic Panel Sizing** (`BfBot.UI._Layout`) — panel covers ~80% of screen by default, centered, computed via `Infinity_GetScreenSize()` + `Infinity_SetArea()`. All elements named for dynamic positioning. Parchment background MOS generated at runtime (`_GenerateBgMOS`) by tiling existing PVRZ blocks to match screen size — supports ultrawide, 4K, and arbitrary resolutions. Resolution changes handled via `EEex_Menu_AddWindowSizeChangedListener`. **Movable and resizable** — title bar `handle` element for drag, bottom-right corner for resize via `actionDrag` callbacks with engine `motionX`/`motionY` globals. Position/size persisted to INI (`PanelX`/`PanelY`/`PanelW`/`PanelH`). Minimum 550x350px. Reset button restores default. Stored geometry clamped on resolution change.

- **Config Export/Import** (`BfBot.Persist` + `BfBot.UI`) — Export a character's full config (all presets + overrides) to `override/bfbot_presets/<CharName>.lua`. Import from any exported file via picker sub-menu. Spells not in the target character's spellbook silently dropped on import. Uses `io.open`/`io.popen`/`os.execute` for file I/O and directory listing (all verified working in EEex).

- **Combat Safety** (`BfBot.Exec`) — combat detection via `countAllOfTypeStringInRange("[ENEMY]", 400)` on party leader, queue interruption in `_Advance()`, paranoid BFBTCH safety net via `.menu` tick every ~2s. `CombatInterrupt` INI pref (default on). Safety net NOT toggleable. Verified working in-game.

- **Subwindow Selection** (`BfBot.Class._DetectVariants` + `BfBot.Exec._ConsumeSpellSlot` + `BfBot.UI`) — opcode 214 detection in scanner, 2DA variant discovery, slot consumption via m_flags, variant picker UI. Implementation complete, in-game verification pending.

Next: Post-MVP features — clones/summons as casters (#19), subwindow selection spells (#20), non-spell buff sources (#21). Analysis documents are in `docs/`, mod source in `buffbot/`, deploy via `bash tools/deploy.sh`. Test all modules: `BfBot.Test.RunAll()` in EEex console. Test persistence only: `BfBot.Test.Persist()`. Test execution: `BfBot.Test.Exec()`. Test Quick Cast: `BfBot.Test.QuickCast()`. Test overrides: `BfBot.Test.Override()`. Test scanner refactor: `BfBot.Test.ScannerRefactor()`. Test export/import: `BfBot.Test.ExportImport()`. Test target picker: `BfBot.Test.TargetPicker()`. Test combat safety: `BfBot.Test.CombatSafety()`. Test subwindow detection: `BfBot.Test.SubwindowDetection()`. Toggle UI: `BfBot.UI.Toggle()` or F11.

### Execution Engine Details
- **Parallel per-caster**: Each caster gets their own sub-queue and `_Advance(slot)` LuaAction chain. All casters start simultaneously.
- **Skip detection**: SPLSTATE as fast negative (if none of spell's SPLSTATEs active → definitely not buffed, skip effect list walk), then authoritative effect list check (`sprite.m_timedEffectList` + `effect.m_sourceRes:get()` matching) for positive SPLSTATE or spells without SPLSTATEs. Logs `"splstate false positive caught"` when SPLSTATE was active but effect list disagrees.
- **Queue format**: `{caster=0-5, spell="RESREF", target="self"|"all"|1-6}`
- **CRITICAL: PlayerN is join order** — BCS `Player1`-`Player6` uses `m_characters` (join order), NOT portrait order. `_ResolveTargets` maps via `EEex_Sprite_GetCharacterIndex(sprite)` to get the correct PlayerN for each target. Never use portrait index as PlayerN.
- **Quick Cast (cheat mode)**: `BfBot.Exec.Start(queue, qcMode)` accepts optional qcMode (0=off, 1=long only, 2=all). User spell priority always respected — no reordering by duration category ("list order is king"). IA toggles on/off per entry based on cheat flag: when qcMode=1, BFBTCH applied before long/permanent entries and BFBTCR before short entries; when qcMode=2, BFBTCH covers everything. Cleanup on Stop()/_Complete() removes lingering BFBTCH.
- **Combat detection**: `_DetectCombat()` checks `sprite:countAllOfTypeStringInRange("[ENEMY]", 400)` on party leader. Same range as rest prevention (SPAWN_RANGE). Called from `_Advance()` between spells. Gated by `CombatInterrupt` INI pref (default 1).
- **Safety net**: `_SafetyTick()` runs via `.menu` `enabled` tick on BUFFBOT_ACTIONBAR (always active on world screen). Rate-limited to ~2s via `Infinity_GetClockTicks()`. When exec state is NOT "running", scans all party members for orphaned BFBTCH effects and removes via BFBTCR. NOT toggleable.
- **Variant spells**: Queue entries with `var` field take a different path: `_ConsumeSpellSlot()` sets `m_flags = 0` on the parent spell's memorized entry, then `ReallyForceSpellRES(variant, target)` applies the variant directly. No subwindow ever opens. `_CheckEntry` uses variant resref for active effect check. Safety skip if `hasVariants` but no `var` configured.
- **API**: `BfBot.Exec.Start(queue, qcMode)`, `BfBot.Exec.Stop()`, `BfBot.Exec.GetState()`, `BfBot.Exec.GetLog()`
- **Log file**: `buffbot_exec.log` in game directory (append mode)

### Persistence Details
- **Per-character config**: stored in `EEex_GetUDAux(sprite)["BB"]` via marshal handlers. Survives save/load automatically.
- **Marshal handler name**: `"BuffBot"` — registered via `EEex_Sprite_AddMarshalHandlers` in `BfBot.Persist.Init()` (called at M_ load time)
- **CRITICAL: No booleans in config** — EEex marshal only supports number/string/table values. Booleans cause `EEex_Error()` and crash saves. All boolean-like fields use `1`/`0`.
- **Config schema** (v5): `{v=5, ap=1, presets={[1]={name,cat,qc=0,spells={[resref]={on,tgt,pri,tgtUnlock}}}, [2]={...}}, opts={skip=1}, ovr={[resref]=1|-1}}` — `tgt` can be `"s"`, `"p"`, a character name string, or a table of name strings (`{"Branwen","Ajantis"}`) for ordered priority targeting. Legacy slot strings (`"1"`-`"6"`) also accepted and lazily converted to names. `tgtUnlock` (optional, 0/1) overrides targeting type lock for modded spells. `qc` is per-preset Quick Cast mode (0=off, 1=long only, 2=all). `ovr` stores classification overrides (1=include, -1=exclude).
- **Auto-population**: `_CreateDefaultConfig` scans castable spells, sorts by duration, puts ALL buff spells into BOTH default presets. Preset 1 ("Long Buffs") has long/permanent enabled + rest disabled; Preset 2 ("Short Buffs") has short enabled + rest disabled. Enabled spells get low priorities (cast first), disabled get high. Instant spells included but disabled in both.
- **Queue building**: `BuildQueueFromPreset(idx)` walks all party members, filters to enabled+castable spells, maps targets (`"s"->"self"`, `"p"->"all"`, `"N"->tonumber(N)`, table→one entry per slot), returns queue for `BfBot.Exec.Start()`
- **INI preferences**: cross-save global settings in `baldur.ini` section `[BuffBot]` via `Infinity_GetINIValue`/`Infinity_SetINIValue`
- **API**: `GetConfig`, `SetConfig`, `GetPreset`, `GetActivePreset`, `SetActivePreset`, `SetSpellEnabled`, `SetSpellTarget`, `SetSpellPriority`, `GetSpellConfig`, `GetTgtUnlock`, `SetTgtUnlock`, `GetOpt`, `SetOpt`, `BuildQueueFromPreset`, `GetPref`, `SetPref`, `RenamePreset`, `CreatePreset`, `DeletePreset`, `GetQuickCast`, `SetQuickCast`, `SetQuickCastAll`, `GetOverrides`, `SetOverride`, `ExportConfig`, `ListExports`, `ImportConfig`, `_ResolveNameToSlot`
- **End-to-end verified**: `BuildQueueFromPreset(1)` → 52 entries → `Exec.Start()` → 6 casters casting in parallel. Use `BfBot.Exec.Start(BfBot.Persist.BuildQueueFromPreset(1))` in console (avoid `local` — EEex console scopes each line separately).
- **Preset management**: `RenamePreset(sprite, idx, name)`, `CreatePreset(sprite, name)` (up to 5, populates with union of all existing spells disabled), `DeletePreset(sprite, idx)` (refuses to delete last preset, returns 1 on success not boolean)
- **Future Persist APIs (not built yet)**: `CopyPreset`, `RefreshPresets` — nice-to-have for preset management
- **Save game scope**: BG:EE saves are NOT character-bound or playthrough-bound — just game state snapshots. Config is per-character per-save via UDAux, which covers the core use case.
- **Export/Import**: `ExportConfig(sprite)` serializes full config to `override/bfbot_presets/<CharName>.lua`. `ListExports()` uses `io.popen('dir /b ...')` to enumerate available files. `ImportConfig(sprite, filename)` loads via `loadstring`, validates/migrates, filters spells not in target's spellbook, syncs overrides. Directory created by WeiDU installer (`MKDIR`) and lazily via `os.execute("mkdir ...")` on first export.

### Configuration UI Details
- **Files**: `buffbot/BfBotUI.lua` (Lua logic, ~710 lines), `buffbot/BuffBot.menu` (.menu DSL definitions, ~655 lines)
- **Init chain**: `M_BfBot.lua` → `Infinity_DoFile("BfBotUI")` → `EEex_Menu_AddAfterMainFileLoadedListener` → `BfBot.UI._OnMenusLoaded()` (loads .menu, injects actionbar button, registers F11 hotkey + sprite listeners)
- **Panel access**: Actionbar button via `EEex_Menu_InjectTemplate("WORLD_ACTIONBAR", "BUFFBOT_BTN", ...)` + F11 via `EEex_Key_AddPressedListener`
- **Panel background**: Dark rectangle via `rectangle 5` + `rectangle opacity 200` (NOT BAM — stretched BAMs look terrible)
- **Character tabs**: 6 button slots, visibility gated by `buffbot_charNames[N]` (populated from party)
- **Preset tabs**: 5 button slots (dynamic) + "Rename" + "New" buttons. Visibility gated by `buffbot_presetNames[N]`. Delete button below list (disabled when only 1 preset remains).
- **Spell list**: `.menu` `list` widget with label-only columns: checkbox text `[X]/[ ]`, spell icon, name (color-coded), memorized count, target text. Data source: `buffbot_spellTable` (Lua global array). Row selection via `var "buffbot_selectedRow"`.
- **CRITICAL `.menu` limitation**: `button` elements inside `list > column` blocks do NOT respond to clicks. Only `label` elements work. Toggle uses list-level `action` with `cellNumber` guard instead.
- **Interaction model**: Click checkbox or icon column (cellNumber <= 2) to toggle enable/disable directly. Click name/count/target columns to select the row for target changes via the "Target: ..." button below the list. External "Enable/Disable" button also works as secondary toggle method. **IMPORTANT**: `rowNumber` in list `action` callbacks is stale (last render pass value) — always use `buffbot_selectedRow` (the `var` binding) which is correctly set at click time.
- **Target picker**: BUFFBOT_TARGETS sub-menu with visually reorderable list. Each row has two click zones: checkbox (`[X]`/`[ ]`, toggles include/exclude) and name (selects row, `> ` prefix on selected). Up/Down visually reorders rows — display order IS cast priority. Checked targets shown at top in priority order, unchecked below. Self/All Party quick-set buttons, Clear/Done buttons. **Lock gating**: self-only spells locked to "Self", AoE locked to "Party" (based on `isAoE`/`isSelfOnly` scan flags). "Unlock Targeting" button overrides lock via `tgtUnlock=1` on spell config (for modded spells). **Name-based storage**: targets stored as character names (e.g., `{"Branwen","Ajantis"}`) instead of slot numbers. Dual-format: old slot strings ("1"-"6") accepted and lazily converted to names in `_Refresh()`. Resolution via `_ResolveNameToSlot(name)` at cast time. **State**: `buffbot_pickerOrder` (display array), `buffbot_pickerChecked` (name→1 map), `buffbot_tgtPickerSel` (selected row). Functions: `PickerToggle`, `PickerSelect`, `PickerSelf`, `PickerAllParty`, `PickerMoveUp/Down`, `PickerClear`, `PickerDone`, `PickerUnlock`.
- **Cast/Stop**: Cast builds queue from active preset via `BuildQueueFromPreset()` → `Exec.Start(queue, qcMode)`. Stop calls `Exec.Stop()`. qcMode read from preset's `qc` field via `GetQuickCast()`.
- **Quick Cast button**: `text` element (not `button` — BAM backgrounds override `text color lua`). Click cycles Off→Long→All→Off via `CycleQuickCast()` → `SetQuickCastAll()`. Color-coded text: white (Off), yellow (Long), red/orange (All). Uses `rectangle 5` + `rectangle opacity 160` for dark background.
- **Manual cast order**: Move Up/Down buttons (area 642/694, y=434, 48px wide) between Target and Delete Preset buttons. `MoveSpellUp()`/`MoveSpellDown()` swap entries in `buffbot_spellTable`, then `_RenumberPriorities()` writes contiguous `pri` values (1, 2, 3, ...) back via `SetSpellPriority()`. `_CanMoveUp()`/`_CanMoveDown()` gate button enabled state. Selection follows the moved spell.
- **Auto-merge new spells**: `_Refresh()` step 6 checks scanner results for buff spells not yet in the current preset and auto-adds them (disabled, `pri = maxPri + 1`). Ensures leveling up or memorization changes are reflected without needing a fresh config.
- **Auto-refresh**: Sprite listeners (`QuickListsChecked`, `QuickListCountsReset`, `QuickListNotifyRemoved`) invalidate scan cache then refresh. Tab switches use cached data (no invalidation).
- **No booleans**: All UI code interacting with Persist uses 0/1 integers, never true/false. `ToggleSpell` passes integer `newState` directly.
- **Shared utility**: `BfBot._GetName(sprite)` — safe character name getter used by both Exec and UI modules
- **In-game status**: Panel renders correctly, all interaction verified working — character/preset tabs, spell toggle, target picker, preset create/delete/rename, cast/stop, Move Up/Down reordering.

### Innate Abilities Details (VERIFIED IN-GAME)
- **Per-preset innates**: Each character gets 1 innate per configured preset in F12/special abilities
- **SPL files**: `BFBT{slot}{preset}.SPL` (6 slots x 8 presets) + `BFBTCH.SPL` (cheat buff) + `BFBTCR.SPL` (cheat remover) + `BFBTRM.SPL` (innate remover), all generated at runtime by `_EnsureSPLFiles()` during M_ load
- **SPL structure**: 250 bytes — Header (114) + 1 ability (40, self/instant) + 2 features (48 each: opcode 402 + opcode 171)
- **Opcode 402 (EEex Invoke Lua)**: Calls global `BFBOTGO(param1, param2, special)`, wrapped in `pcall` to prevent engine "panic" display on Lua errors. Logs to `buffbot_innate.log`. `param1` is CGameEffect userdata — access slot via `param1.m_effectAmount`, preset via `param1.m_dWFlags`. Self-heals stale party slots via `RefreshAll()`. Maps to `BuildQueueForCharacter(slot, preset)` + `Exec.Start(queue, qcMode)`. Reads preset's `qc` field via `GetQuickCast()` and passes through to execution engine.
- **Opcode 171 (Give Innate)**: Re-grants self after cast (standard IE repeatable innate pattern)
- **Grant/Revoke**: `AddSpecialAbility` via `QueueResponseStringOnAIBase` for granting. Revoke uses `ReallyForceSpellRES("BFBTRM",Myself)` — a runtime-generated SPL with opcode 172 (Remove Innate) effects for all BFBT resrefs. Old approach used `RemoveSpellRES` which silently failed (not in INSTANT.IDS), causing innate accumulation and save corruption. See "Innate Accumulation Save Corruption (FIXED)" below.
- **Tooltip names**: TLK patched at deploy time by `tools/patch_tlk.py`. Appends "BuffBot 1"–"BuffBot 5" to `dialog.tlk`. Base strref written to `override/bfbot_strrefs.txt`, read by `_BuildSPL` at M_ load for SPL name fields (offsets 0x0008, 0x000C).
- **Icon**: `SPWI218B` (Stoneskin button BAM) — placeholder, custom BAM post-MVP
- **Spell level**: Set to preset index (1-5) for separate F12 lines
- **Party slot encoding**: Slot (0-5) baked into opcode 402 param1, preset (1-5) into param2. Stale if party rearranged — `RefreshAll()` on party change.
- **Grant lifecycle**: Innates persist in save games (engine saves known spells) and opcode 171 re-grants after each use. No lazy grant on session start — innates are only granted when (1) config is first created (`_CreateDefaultConfig`), or (2) presets are created/deleted (`Refresh` flow). `_HasInnate(sprite, resref)` uses `EEex_Sprite_GetKnownInnateSpellsIterator` to check for duplicates.
- **BFBTRM.SPL** (innate remover): Header (114) + 1 ability (40, self/instant) + 48 effects (opcode 172, one per BFBT{slot}{preset} resref). Each opcode 172 removes one known innate matching the resource field. Applied 5 times per Revoke to clean up accumulated innates from old saves.
- **API**: `BfBot.Innate.Grant()`, `.Revoke(slot)`, `.Refresh(slot)`, `.RefreshAll()`, `._HasInnate(sprite, resref)`, `._EnsureSPLFiles()`, `._BuildSPL(slot, preset)`, `._BuildRemoverSPL()`

### Manual Spell Override Details (GitHub #1)
- **Storage**: `config.ovr = {[resref] = 1 (include) | -1 (exclude)}` — per-character, persists in saves via schema v5
- **Include flow**: "Add Spell" → picker shows non-buff castable spells + previously-excluded spells (for accidental-Remove undo) → select → `SetOverride(resref, 1)` → cache invalidation → auto-merge adds to preset on next refresh (disabled, at bottom). Excluded spells sort to the top of the picker.
- **Exclude flow**: "Remove" button → `SetOverride(resref, -1)` → removed from ALL presets → auto-merge skips excluded spells. Reversible via the Add Spell picker.
- **Visual**: Manually included spells shown with light blue name `{150, 200, 255}`
- **Sync**: Overrides loaded from config into `BfBot.Class.SetOverride()` during marshal import
- **UI**: BUFFBOT_SPELLPICKER sub-menu with scrollable list (icon, name, durCat, count), "Add to Buff List" + "Cancel" buttons
- **API**: `BfBot.Persist.GetOverrides(sprite)`, `BfBot.Persist.SetOverride(sprite, resref, value)`

### Quick Cast / Cheat Mode Details
- **Per-preset toggle**: `qc` field on each preset (0=off, 1=long only, 2=all). Set via `SetQuickCast(sprite, idx, val)` or `SetQuickCastAll(idx, val)` for party-wide.
- **BFBTCH.SPL** (cheat buff): 250 bytes — Header (114) + 1 ability (40, self/instant) + 2 effects (48 each). Effect 1: opcode 188 (Aura Cleansing / Improved Alacrity, param1=0 param2=1), 300s duration. Effect 2: opcode 189 (Casting Time Modifier, param1=10), 300s duration. Params verified against real IA spell SPWI921 and game-wide opcode 189 usage.
- **BFBTCR.SPL** (cheat remover): 202 bytes — Header (114) + 1 ability (40, self/instant) + 1 effect (48). Effect 1: opcode 321 (Remove Effects by Resource), resource = "BFBTCH".
- **Cast order**: User-set `pri` is always respected, regardless of Quick Cast mode. No reordering by duration category. When qcMode=1, IA toggles on/off per entry (BFBTCH before long/permanent, BFBTCR before short). When qcMode=2, IA covers everything.
- **Schema migration v3→v4**: Migrates old global `opts.cheat` (0/1) to per-preset `qc` field (cheat=1 → qc=2 on all presets, cheat=0 → qc=0). Removes `opts.cheat`.
- **UI cycling button**: `CycleQuickCast()` cycles 0→1→2→0 via `SetQuickCastAll()`. Color-coded: white=Off `{200,200,200}`, yellow=Long `{230,200,60}`, red/orange=All `{230,100,60}`.
- **Innate passthrough**: `BFBOTGO` handler reads `GetQuickCast(sprite, presetIdx)` and passes to `Exec.Start(queue, qcMode)`.
- **Design doc**: `docs/plans/2026-02-28-cheat-mode-design.md`

### Config Export/Import Details (GitHub #2)
- **File format**: Full character config serialized as a Lua file in `override/bfbot_presets/`. Format: `BfBot._import = {v=5, ap=N, presets={...}, opts={...}, ovr={...}}`
- **Export**: `ExportConfig(sprite)` → sanitizes character name for filename → `_Serialize()` recursive table serializer (handles number/string/table, converts booleans to 1/0, sorts keys) → writes to `override/bfbot_presets/<SafeName>.lua`. Overwrites silently on re-export.
- **Import**: `ImportConfig(sprite, filename)` → `io.open` + `loadstring` → validates via `_ValidateConfig` + `_MigrateConfig` → filters spells not in target character's spellbook via `GetCastableSpells` → stores to UDAux → syncs overrides to classifier. Returns `true, presetCount, skippedCount` or `false, errorMsg`.
- **Directory listing**: `ListExports()` uses `io.popen('dir /b "override\\bfbot_presets\\*.lua" 2>nul')` to enumerate available files. Returns `{name, filename}` array. No index file or manifest needed.
- **Directory creation**: WeiDU `MKDIR` at install time + lazy `os.execute("mkdir ...")` on first export.
- **UI**: Export/Import buttons on the config panel. Import opens BUFFBOT_IMPORT picker sub-menu (scrollable list of available configs, Import/Cancel buttons). Feedback via `Infinity_DisplayString`.
- **Design doc**: `docs/plans/2026-03-08-config-export-import-design.md`

### Subwindow Selection (Opcode 214) Details
- **Detection**: `BfBot.Class._DetectVariants(header, ability)` walks feature blocks for opcode 214. When found, reads the 2DA resource via `EEex_Resource_Load2DA()`, iterates rows to build variant array `{label, resref, name, icon}`.
- **2DA format**: Column 0 = sub-spell resref, row label = variant label (e.g., "ProFire").
- **Classification**: Parent spells with opcode 214 promoted to `isBuff = true` if they score too low on their own.
- **Scan entry**: `hasVariants` (0/1 integer), `variants` (array or nil).
- **Config**: `var` field on per-spell config (string resref or nil). No schema version bump.
- **Slot consumption**: `_ConsumeSpellSlot(sprite, resref)` — determines spell list from resref prefix (SPWI→mage, SPPR→priest, else→innate), gets level from SPL header, iterates `sprite.m_memorizedSpells*:getReference(level)`, sets `m_flags = 0` on first available match.
- **UI**: Variant button conditionally replaces normal button layout for variant spells. BUFFBOT_VARIANTS sub-menu for selection. Enable gate: cannot enable variant spell without selecting a variant first.
- **In-game verified**: SPWI422 (Protection from Elemental Energy) → DVWI426.2DA → {SPWI319 fire, SPWI320 cold, SPWI512 elec, SPWI517 acid}.

### Known Issue: Old Save Configs Missing Spells
Save games created before commit 706f31e have preset configs where Long Buffs only contains long/permanent spells and Short Buffs only contains short spells (each preset missing the other category). The code was fixed in 706f31e to distribute ALL buff spells to both presets, but `_CreateDefaultConfig` only runs when no config exists — existing saves retain the old incomplete config. **Mitigated**: Auto-merge in `_Refresh()` adds missing buff spells (disabled, at bottom) when the panel opens, producing the same result as a fresh config.

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

### Spell Toggle Not Persisting (FIXED)
`SetSpellEnabled` used `enabled and 1 or 0` which always stored `1` because **Lua treats `0` as truthy**. Disabling a spell appeared to work visually (immediate `entry.on = newState` update) but reverted on next `_Refresh()` when the persist value was read back. **Fix**: `(enabled == 1) and 1 or 0`. Never use `x and 1 or 0` for integer 0/1 → use `(x == 1) and 1 or 0`.

### Innate Grant Spam on Session Start (FIXED)
`Grant()` fired on every session start via lazy trigger in `_OnSpellListChanged`. Since innates persist in save games (engine saves known spells) and opcode 171 re-grants after each use, this was redundant. Worse, if `EEex_Sprite_GetKnownInnateSpellsIterator` wasn't ready during early load, `_HasInnate` returned false and innates were re-added as duplicates. **Fix**: removed lazy grant entirely. Innates now only granted when config is first created (`_CreateDefaultConfig`) or presets are created/deleted (`Refresh` flow).

### Innate Accumulation Save Corruption (FIXED)
`Revoke()` used `RemoveSpellRES` via `QueueResponseStringOnAIBase` to remove innates before re-granting. But `RemoveSpellRES` is NOT in INSTANT.IDS and silently fails when queued — actions either get dropped or never execute. Meanwhile, `AddSpecialAbility` (used by Grant/Refresh) IS reliable, so every preset refresh added new innates without removing old ones. Over time, characters accumulated 3x+ their expected innate count (e.g., 18 instead of 6). The bloated known/memorized spell lists corrupted CRE data, causing NULL pointer dereferences during rest (crash at Baldur.exe+0x364209). `Refresh()` also lacked the `_HasInnate()` duplicate guard, compounding the issue. **Fix**: (1) Built `BFBTRM.SPL` — a runtime-generated SPL with 48 opcode 172 (Remove Innate) effects, one per possible BFBT{slot}{preset} resref. (2) Rewrote `Revoke()` to apply BFBTRM via `ReallyForceSpellRES` (5 passes to clean up accumulated innates from old saves). (3) Opcode 172 fires as a spell effect, bypassing the broken action queue path entirely.

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
- **Quick Cast / cheat mode (implemented)**: per-preset 3-state toggle (Off/Long/All). Applies BFBTCH.SPL (opcode 188 Improved Alacrity + opcode 189 Casting Time Modifier param1=10) via `ReallyForceSpellRES`. IA covers the entire queue for both qc=1 and qc=2 — user spell priority always respected, no reordering by duration. Spell slots still consumed
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

## Domain Knowledge (on-demand skills)

BG modding domain knowledge lives in a consolidated knowledge base at `~/.claude/skills/bg-modding/references/` (~16 .md files). Two skills provide access:

- **`bg-modding`** — read skill. Reads INDEX.md to route to the right reference file(s). Covers EEex API, Infinity Engine spells/opcodes, .menu DSL, WeiDU, SCS compatibility, and cross-cutting gotchas.
- **`bg-modding-learn`** — write skill. Records new discoveries (gotchas, API corrections, verified patterns) into the appropriate reference file.

Invoke `bg-modding` when working on any BG mod code. Invoke `bg-modding-learn` after verifying new knowledge through in-game testing.

## Key References

- EEex source: https://github.com/Bubb13/EEex
- IESDP (Infinity Engine file format docs): https://gibberlings3.github.io/iesdp/
- WeiDU documentation: https://weidu.org/
- Near Infinity (IE file browser/editor): https://github.com/NearInfinityBrowser/NearInfinity
- BubbleBuffs (inspiration): https://github.com/factubsio/BubbleBuffs
