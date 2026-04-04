# LuaJIT Requirement — Design Document

**Date:** 2026-04-05
**Issue:** EEex devel branch users without LuaJIT get `attempt to index global 'io' (a nil value)` at BfBotInn.lua:12
**Status:** Approved

## Problem

BuffBot uses `io.open`, `io.popen`, and `os.execute` extensively for file I/O (runtime SPL generation, logging, config export/import). These are standard Lua libraries but are NOT loaded by the BG:EE engine's built-in Lua 5.2 state. They are only available when EEex's LuaJIT component is installed, which sets `LuaPatchMode=REPLACE_INTERNAL_WITH_EXTERNAL` in `InfinityLoader.ini` and calls `luaL_openlibs()`.

The LuaJIT component is optional in EEex. On stable (v0.11.0-alpha) it's component 1 (easy to select). On the devel branch, it was moved to component 8 under the "Experimental" QUICK_MENU tier — users selecting "Minimal" or "Full" skip it. This causes BuffBot to crash at load time.

## Solution

Two-layer approach: WeiDU installer component that installs LuaJIT if missing, plus runtime degradation if `io` is still unavailable.

### Layer 1: WeiDU Installer Component

New component in `setup-buffbot.tp2` (DESIGNATED 1, label `BuffBot-LuaJIT`):

1. Read `InfinityLoader.ini` — check if `LuaPatchMode=REPLACE_INTERNAL_WITH_EXTERNAL`
2. If yes → print "LuaJIT already installed, skipping." → done
3. If no → check `EEex/loader/LuaJIT/lua51.dll` exists
4. If files exist:
   - Copy `EEex/loader/LuaJIT/lua51.dll` and `EEex/loader/LuaJIT/LuaProvider.dll` to game root
   - Detect `LuaVersionExternal` value from `EEex/EEex.tp2` (pattern match the REPLACE_TEXTUALLY line)
   - Fallback to `5.1` if detection fails
   - Patch `InfinityLoader.ini`: set `LuaPatchMode`, `LuaLibrary`, `LuaVersionExternal`
   - Print message explaining this is normally an EEex component
5. If files don't exist → FAIL with message directing user to reinstall EEex with LuaJIT (requires EEex v0.10.0-alpha+)

#### INI Values

| Key | Value | Source |
|---|---|---|
| `LuaPatchMode` | `REPLACE_INTERNAL_WITH_EXTERNAL` | Hardcoded (structural constant) |
| `LuaLibrary` | `lua51.dll` | Hardcoded (LuaJIT DLL name) |
| `LuaVersionExternal` | Detected from EEex.tp2 | Fallback: `5.1` |

#### Detection of LuaVersionExternal

Read `EEex/EEex.tp2` as text, search for the pattern `LuaVersionExternal=\).*~ ~\1<VALUE>~`. Extract `<VALUE>`. Known values: `5.1` (stable), `5.1-LuaJIT` (devel). If pattern not found or file unreadable, use `5.1`.

#### EEex LuaJIT File Paths (verified both branches)

- Source: `EEex/loader/LuaJIT/LuaProvider.dll`, `EEex/loader/LuaJIT/lua51.dll`
- Target: game root (`.`)
- Path identical on stable (v0.10.0-alpha+) and devel

### Layer 2: Runtime Degradation

If `io` is nil at runtime despite installer efforts (manual install, INI reverted, edge case), BuffBot degrades gracefully instead of crashing.

#### Detection

In `M_BfBot.lua`, after `if not EEex_Active then return end`:

```lua
if not io then
    BfBot._noIO = true
end
```

One-time warning displayed when menus are ready:
> "BuffBot: LuaJIT not detected. F12 innates, Quick Cast, Export/Import, and logging are disabled. Install EEex LuaJIT component to enable all features."

#### Feature Matrix

| Feature | Needs `io`? | Behavior without `io` |
|---|---|---|
| Spell scanning + classification | No | Full functionality |
| Config panel (UI) | No | Full functionality |
| Persistence (save/load) | No | Full functionality |
| Execution engine (casting via UI) | No | Full functionality |
| Target picker | No | Full functionality |
| Innate abilities (F12) | Yes | Disabled, buttons hidden |
| Quick Cast | Yes | Disabled, button hidden |
| Logging | Yes | No file logging, in-game display only |
| Export/Import | Yes | Disabled, returns error message |
| Test suite (SPL tests) | Yes | SPL verification tests skipped |

#### Guard Implementation

- `BfBotCor.lua` — `_OpenLog`/`_OpenLogAppend` return early. `_Print` only does `Infinity_DisplayString` (no file). `os.date` guarded.
- `BfBotInn.lua` — Module-level strref read guarded. `_EnsureSPLFiles()` skips. `Grant`/`Revoke`/`Refresh` become no-ops.
- `BfBotPer.lua` — `ExportConfig`/`ImportConfig`/`ListExports` return error strings.
- `BfBotUI.lua` — Quick Cast, Export, Import buttons hidden/disabled when `_noIO`.
- `BfBotTst.lua` — SPL file verification test skipped.

## Files Changed

| File | Change |
|---|---|
| `setup-buffbot.tp2` | Add LuaJIT component (DESIGNATED 1) |
| `M_BfBot.lua` | Add `io` check, set `BfBot._noIO` flag |
| `BfBotCor.lua` | Guard `io.open`/`os.date` in logging |
| `BfBotInn.lua` | Guard strref read, SPL writing, innate operations |
| `BfBotPer.lua` | Guard export/import/listing |
| `BfBotUI.lua` | Hide/disable io-dependent UI elements |
| `BfBotTst.lua` | Skip SPL file tests |
| `README.md` | Add LuaJIT to requirements, explain installer |
| `CHANGELOG.md` | Document the change |

Files NOT modified: `BfBotCls.lua`, `BfBotScn.lua`, `BfBotExe.lua` (no `io` usage).

## Follow-up

GitHub issue: Automated compatibility check against EEex stable repo — periodic verification that our LuaJIT detection and INI values still match EEex's current installer.
