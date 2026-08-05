# BuffBot — Project Context for Claude Code

## What This Is

BuffBot is a mod for Baldur's Gate: Enhanced Edition (BG:EE) and BG2:EE that provides in-game configurable buff automation. It depends on [EEex](https://github.com/Bubb13/EEex) for Lua access to engine internals. Inspired by [Bubble Buffs (BUBBLES)](https://github.com/factubsio/BubbleBuffs) from Pathfinder: Wrath of the Righteous.

## Current Phase

Alpha — all MVP features implemented and verified in-game. See `CHANGELOG.md` for the release timeline and `gh issue list --repo Chrizhermann/bg-eeex-buffbot` for open work.

### Modules

- `M_BfBot.lua` — entry point loaded by WeiDU via M_ prefix
- `BfBotCor.lua` — namespace, version, logging utilities
- `BfBotCls.lua` — spell classifier (scoring, targeting, duration, variants, overrides)
- `BfBotScn.lua` — per-sprite spellbook scan (iterator-based, cached)
- `BfBotExe.lua` — parallel per-caster execution, skip detection, combat safety
- `BfBotPer.lua` — persistence (UDAux marshal, presets, INI, export/import)
- `BfBotInn.lua` — per-preset F12 innate abilities (runtime SPL generation)
- `BfBotUI.lua` + `BuffBot.menu` — in-game config panel (movable, resizable, dynamic ~80% screen)
- `BfBotTst.lua` — in-game test suite (`BfBot.Test.RunAll()` in in-game console)
- `setup-buffbot.tp2` — WeiDU installer (under `buffbot/`)
- `tools/deploy.sh` — dev deploy (copies to `<game>/override/`, patches TLK)
- `tools/patch_tlk.py` — appends BuffBot innate tooltip names to `dialog.tlk`

## Design Decisions (do not second-guess without asking)

- **Per-character tabs** are the primary axis — BG spell lists barely overlap across party members (unlike PF:WoTR). Presets are the secondary axis.
- **Dynamic spellbook scan, no hardcoded spell lists** — the mod works with SCS / Spell Revisions / kit mods by reading spell data at runtime.
- **Skip active buffs by default** via SPLSTATE fast-negative + effect-list fallback.
- **Config lives in save games** (per-character, via UDAux marshal). Global prefs in `baldur.ini` section `[BuffBot]`. External export/import via `override/bfbot_presets/*.lua`.
- **Normal mode is engine-paced**; Quick Cast / Cheat Mode is a per-preset 3-state toggle (Off / Long only / All) that applies runtime `BFBTCH.SPL` (Improved Alacrity + casting-speed reduction).
- **User spell priority is always respected** — no automatic reordering by duration category.
- **Must support both BG1EE and BG2EE** — BG1 caps at spell level 5, BG2 reaches level 9 + HLAs. Aura cooldown is 6s; let the engine pace it.
- **Dynamic spellbook only** — potions, wands, scrolls, sequencers/contingencies are out of scope for MVP.

## Project-Specific Invariants & Gotchas

Generic IE / EEex / .menu gotchas (Lua 0-truthy, opcode 188/189 params, marshal-no-booleans, PlayerN join order, button-in-list, `text color lua` + BAM, `rowNumber` stale in list callbacks, `countAllOfTypeStringInRange` SPAWN_RANGE=400, `.menu` `enabled` as periodic tick, etc.) live in `~/.claude/skills/bg-modding/references/` — invoke the `bg-modding` skill to pull them in. Project-specific rules:

- **Marshal handler name**: `"BuffBot"`, registered in `BfBot.Persist.Init()`. Do NOT rename — every existing save breaks.
- **Config schema v8**: `{v=8, ap, presets=[{name,cat,qc,spells={[resref]={on,tgt,pri,tgtUnlock,lock}}}], opts={skip}, ovr={[resref]=1|-1}, summons={[identity]={presets={[n]={qc,spells={[resref]={on,tgt,pri}}}}}}}`. `tgt` = `"s"` / `"p"` / character name / ordered table of names. Legacy slot strings (`"1"`-`"6"`) lazily convert to names in `_Refresh`. Only the protagonist's `summons` subtree is read/written; older saves migrate lazily.
- **Summon caster identity and filtering**: `BfBot.Scan.GetAlliedSummons()` returns alive, non-party sprites with allied EA 2–30 and at least one castable spell, keyed stably as clone-owner / script name / CRE resref / display-name fallback. Returned cache tables are read-only; copy before sorting. Re-resolve by object ID + name and revalidate allegiance before acting.
- **Caster refs and keys**: execution records use `{kind="party",slot=N}` → `pN` or `{kind="summon",oid=N,name=S}` → `sN`. Never persist summon object IDs or sprite userdata; IDs are fresh per spawn and every exec step resolves again.
- **Project Image lock policy**: a live PI locks its owner. Skip all owner entries while its PI exists, and drop (never reorder) owner entries after a Project Image cast. Copied BuffBot F12 innates on clones are not supported in v1.6.0-alpha; use the Summons view / Cast All paths.
- **BuffBot-generated resrefs**: `BFBT{slot}{preset}` (6 × 8 = 48 innates), `BFBTCH` / `BFBTCR` (quick-cast buff/remover), `BFBTRM` (innate remover). `BfBot.Scan.GetCastableSpells` filters the `BFBT` prefix so the mod never scans its own SPLs.
- **Up to 8 presets** via `BfBot.MAX_PRESETS`.
- **Innate re-grant pattern**: opcode 172 cleanup via runtime `BFBTRM.SPL` + Lua-side `AddSpecialAbility`. Reconciliation in a single pass via `BfBot.Innate._PlanReconciliation` + `BfBot.Innate.Refresh` — one iterator walk diffs actual-vs-desired and either revokes-all+regrants on any mismatch or grants-missing-only. Do NOT add opcode 171 back (caused the rest-crash accumulation bug, `CHANGELOG.md` v1.3.9-alpha). Do NOT reintroduce per-helper iterator walks (`_HasInnate`, `_MaxAccumulation`, `_HasOrphans`) — those were folded into the planner in v1.4.1-alpha.
- **Sub-spell duration**: `BfBot.Class.GetDuration` recurses through op=146 `res` with depth limit 2 + cycle guard, so hierarchical spells (Prayer, Chaos of Battle, Chant, SR Barkskin) report real durations instead of `Inst` (#33).
- **SPLSTATE is fast-negative only**: positive SPLSTATE → fall through to `_HasActiveEffect` (effect-list match on resref). Modded spells share SPLSTATEs (SCS), so positive matches aren't trustworthy for skip.
- **Scan cache invalidation** on panel open + sprite listeners (`QuickListsChecked`, `QuickListCountsReset`, `QuickListNotifyRemoved`). Tab switches reuse the cache.
- **Classifier false-positive fixes already in place**: self-ref opcode discount (318/324 → 0), substance check (must have ≥ 1 real buff opcode besides 17/171), toggle penalty (op=318 self-ref → −8). SR Barkskin stays AMB because classification scoring doesn't recurse sub-spells — expected, handled via manual override UI.
- **Party index vs portrait index**: `EEex_Sprite_GetInPortrait(slot)` returns the sprite for portrait slot 0-5; BCS `PlayerN` / `_ResolveTargets` needs the join-order index from `EEex_Sprite_GetCharacterIndex(sprite)`. These are NOT the same.

## Tech Stack

- **WeiDU** — mod installer/patcher (`setup-buffbot.tp2`)
- **Lua + .menu files** — core logic + UI via EEex's bridge to the Infinity Engine
- **SPL files / opcodes** — spell definitions
- **2DA** — tabular lookups (variants, MSECTYPE, etc.)

## Repo Layout

- `buffbot/` — mod source (Lua, .menu, .tp2)
- `tools/` — helper scripts (`deploy.sh`, `patch_tlk.py`, etc.)
- `docs/` — analysis docs, design plans, forum posts
- `CHANGELOG.md` — per-release notes

## Workflow

- **Deploy**: `bash tools/deploy.sh` (reads `tools/deploy.conf` for game dir).
- **Reload in running game**: `Infinity_DoFile` serves a memory cache and does NOT reread disk (verified 2026-04-19, re-confirmed 2026-07-11). Force-reload a changed module from disk via the `io.open`+`loadstring` pattern in `eeex-filesystem.md` (`forceLoad("override/BfBotX.lua")`, e.g. through the remote console); restart the game instead when many modules changed or init/listener re-registration is a concern.
- **Tests**: `BfBot.Test.RunAll()` in the in-game console on the world screen. Individual phases exist for each module (e.g. `Persist`, `Exec`, `QuickCast`, `DurationRecursion`).
- **Remote console** (headless testing): `bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "<game>/override" "<lua>"`. Game must be on the world screen.
- **Branch vs main**: small code change → main; bigger work → feature branch. Design in GitHub issues, not `docs/plans/`.

## Domain Knowledge (on-demand skills)

BG modding domain knowledge lives at `~/.claude/skills/bg-modding/references/` (~16 .md files). Two skills provide access:

- **`bg-modding`** — read: routes from `INDEX.md` to the relevant reference files (EEex API, IE spells/opcodes, .menu DSL, WeiDU, SCS compatibility, cross-cutting gotchas).
- **`bg-modding-learn`** — write: records new discoveries into the appropriate reference file.

Invoke `bg-modding` for any BG modding code work. Invoke `bg-modding-learn` after verifying new knowledge in-game.

## Key References

- EEex source: https://github.com/Bubb13/EEex
- IESDP (Infinity Engine file format docs): https://gibberlings3.github.io/iesdp/
- WeiDU documentation: https://weidu.org/
- Near Infinity (IE file browser/editor): https://github.com/NearInfinityBrowser/NearInfinity
- BubbleBuffs (inspiration): https://github.com/factubsio/BubbleBuffs
