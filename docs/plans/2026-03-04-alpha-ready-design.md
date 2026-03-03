# Alpha-Ready: Preset Fixes + Distribution + README

**Date**: 2026-03-04
**Status**: Approved

## Goal

Make BuffBot alpha-ready for distribution to the hardcore BG modding community (SCS, Ascension, SR players). Fix blocking preset bugs, create a proper WeiDU installer, and write a README that tells testers what they're getting and how to use it.

## Part 1: Preset Bug Fixes

Fix 4 of 5 identified preset management bugs. Defer bug #4 (CreatePreset target re-classification inconsistency) as a known issue.

### Bug #1: Delete active preset leaves UI stale
**Problem**: `DeleteCurrentPreset()` picks a fallback preset from the current character only. Switching to another character tab can show a blank spell list if `_presetIdx` doesn't exist in that character's config.
**Fix**: After deletion, scan config for first valid preset index and update both `BfBot.UI._presetIdx` and `config.ap`.

### Bug #2: `config.ap` stale after deletion
**Problem**: `DeletePreset()` only resets `config.ap` when it equals the deleted index. If the active preset is deleted via a different code path, `config.ap` can reference a nil preset.
**Fix**: In `DeletePreset()`, always validate `config.ap` after deletion — if it points to nil, reset to first valid preset.

### Bug #3: UI `_presetIdx` drifts from persistence
**Problem**: `_presetIdx` is only clamped in `_Refresh()`. Other functions (`Cast()`, `_BuildSpellTable()`) can operate on stale indices.
**Fix**: Add defensive clamping at the top of `Cast()` and `_BuildSpellTable()` — if `_presetIdx` doesn't exist in config, reset to `config.ap` or first valid.

### Bug #5: No validation at Cast time
**Problem**: If preset is invalid when Cast is clicked, `BuildQueueFromPreset()` returns nil with no user feedback.
**Fix**: Guard in `Cast()` — if queue is nil or empty after clamping, show feedback via `Infinity_DisplayString("BuffBot: No spells to cast in this preset")` and return early.

### Deferred: Bug #4 (CreatePreset target re-classification)
`CreatePreset()` re-classifies targets from SPL data while `CreatePresetAll()` copies existing targets. Inconsistent but only affects users who manually override targets then create new presets. Document as known issue.

## Part 2: WeiDU .tp2 Installer

Create `setup-buffbot.tp2` at repo root following ArtisansKitpack/EEex conventions.

### Repo restructure
Rename `src/` to `buffbot/` so the repo structure matches WeiDU's `%MOD_FOLDER%` convention. Alpha testers can clone the repo directly into their game directory and run the installer.

### .tp2 structure
- `BACKUP ~weidu_external/backup/buffbot~`
- `REQUIRE_PREDICATE` for BG:EE/BG2:EE/EET
- `REQUIRE_PREDICATE` for EEex installed (`MOD_IS_INSTALLED ~EEex/EEex.tp2~ ~0~`)
- `RESOLVE_STR_REF(~BuffBot N~)` x5 for TLK strings (replaces `patch_tlk.py` for installation)
- Copy all 11 files to override (10 Lua + 1 .menu)
- Write base strref to `override/bfbot_strrefs.txt` via inlined file + `EVALUATE_BUFFER`
- No `.tra` files for alpha — inline English strings
- Uninstall: automatic via WeiDU (deletes copied files, restores TLK)

### patch_tlk.py retained
Keep `tools/patch_tlk.py` for dev deploys via `deploy.sh` (faster iteration than running WeiDU). The .tp2 path is for end-user installation.

## Part 3: deploy.sh Update

### Configuration chain
```
# Source local config if present (gitignored)
[ -f "$(dirname "$0")/deploy.conf" ] && source "$(dirname "$0")/deploy.conf"
GAME_DIR="${1:-${BGEE_DIR:?Set BGEE_DIR or pass game dir as argument}}"
```

Priority: CLI argument > `deploy.conf` > `BGEE_DIR` env var > error.

### deploy.conf (gitignored)
```bash
BGEE_DIR="c:/Games/Baldur's Gate II Enhanced Edition modded"
```

### Path updates
All `src/` references become `buffbot/` (follows from Part 2 rename).

## Part 4: README Rewrite

Target: ~120 lines, alpha-appropriate.

### Structure
1. **Title + one-liner** — BuffBot, in-game buff automation for BG:EE/BG2:EE
2. **Features** — implemented features: dynamic scanning, config UI, presets (up to 5), Quick Cast, F12 innates, skip-active-buff, save persistence
3. **Requirements** — EEex (note tested version), BG:EE / BG2:EE / EET
4. **Installation** — WeiDU: extract into game dir, run setup-buffbot
5. **Usage** — panel access (actionbar button / F11 / F12), basic workflow
6. **Testing / Bug Reports** — `BfBot.Test.RunAll()`, GitHub issues link
7. **Developer Setup** — deploy.sh, BGEE_DIR, deploy.conf
8. **Known Issues** — preset target inconsistency, old save config gaps, Barkskin SR edge case
9. **License** — MIT

## Scope

- **In scope**: 4 bug fixes, .tp2 creation, src/ → buffbot/ rename, deploy.sh update, deploy.conf + .gitignore, README rewrite, CLAUDE.md path updates
- **Out of scope**: new features, test additions, custom innate icons, export/import, i18n
- **Deferred known issue**: Bug #4 (CreatePreset target re-classification)
