# LuaJIT Requirement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make BuffBot handle missing LuaJIT gracefully — install it during WeiDU setup if possible, degrade at runtime if not.

**Architecture:** Two layers. (1) A new WeiDU component (DESIGNATED 1) detects whether LuaJIT is active, and if not, copies the DLLs from EEex's own install folder and patches the INI. (2) A runtime `BfBot._noIO` flag gates all `io`/`os` usage so the mod loads and works (minus innates, quick cast, export/import, logging) even without LuaJIT.

**Tech Stack:** WeiDU (.tp2), Lua

---

### Task 0: Add LuaJIT installer component to setup-buffbot.tp2

**Files:**
- Modify: `setup-buffbot.tp2`

**Step 1: Add the new component after the main component**

Insert a new component block (DESIGNATED 1, label `BuffBot-LuaJIT`) after the existing main component. This component:
1. Requires EEex main to be installed
2. Reads `InfinityLoader.ini` — if `LuaPatchMode=REPLACE_INTERNAL_WITH_EXTERNAL` already set, prints skip message and exits
3. Checks `EEex/loader/LuaJIT/lua51.dll` exists — if not, FAILs with instructions
4. Detects `LuaVersionExternal` value by reading `EEex/EEex.tp2` and pattern-matching
5. Copies DLLs from `EEex/loader/LuaJIT/` to game root
6. Patches `InfinityLoader.ini` with `LuaPatchMode`, `LuaLibrary`, `LuaVersionExternal`

```tp2
// ============================================================
// Component 1: EEex LuaJIT (required for full functionality)
// ============================================================
BEGIN ~BuffBot: EEex LuaJIT Support (auto-detected)~
DESIGNATED 1
LABEL ~BuffBot-LuaJIT~

REQUIRE_PREDICATE (GAME_IS ~bgee bg2ee eet~)
  ~BuffBot requires BG:EE, BG2:EE, or EET.~

REQUIRE_PREDICATE (MOD_IS_INSTALLED ~EEex/EEex.tp2~ ~0~ OR MOD_IS_INSTALLED ~EEex/EEex.tp2~ ~1~)
  ~BuffBot requires EEex. Install EEex first: https://github.com/Bubb13/EEex~

// Check if LuaJIT is already active
OUTER_SET luajit_active = 0
ACTION_IF FILE_EXISTS ~InfinityLoader.ini~ THEN BEGIN
  COPY - ~InfinityLoader.ini~ ~InfinityLoader.ini~
    PATCH_IF (INDEX_BUFFER (~LuaPatchMode=REPLACE_INTERNAL_WITH_EXTERNAL~) >= 0) THEN BEGIN
      SET luajit_active = 1
    END
  BUT_ONLY
END

ACTION_IF (luajit_active = 1) THEN BEGIN
  PRINT ~LuaJIT is already active. Skipping installation.~
END ELSE BEGIN
  // Check if EEex ships the LuaJIT files
  ACTION_IF NOT FILE_EXISTS ~EEex/loader/LuaJIT/lua51.dll~ THEN BEGIN
    FAIL ~EEex LuaJIT files not found at EEex/loader/LuaJIT/. Please reinstall EEex (v0.10.0-alpha or later) with the LuaJIT / Experimental component selected, or upgrade EEex.~
  END

  // Detect LuaVersionExternal from EEex's own tp2
  OUTER_SPRINT lua_version ~5.1~
  ACTION_IF FILE_EXISTS ~EEex/EEex.tp2~ THEN BEGIN
    COPY - ~EEex/EEex.tp2~ ~EEex/EEex.tp2~
      PATCH_IF (INDEX_BUFFER (~5.1-LuaJIT~) >= 0) THEN BEGIN
        SPRINT lua_version ~5.1-LuaJIT~
      END
    BUT_ONLY
  END

  PRINT ~Installing EEex LuaJIT component (normally installed by EEex setup).~
  PRINT ~Detected LuaVersionExternal: %lua_version%~

  // Copy DLLs from EEex's own install folder
  COPY ~EEex/loader/LuaJIT/lua51.dll~        ~lua51.dll~
  COPY ~EEex/loader/LuaJIT/LuaProvider.dll~  ~LuaProvider.dll~

  // Patch InfinityLoader.ini
  COPY ~InfinityLoader.ini~ ~InfinityLoader.ini~
    REPLACE_TEXTUALLY ~^\(LuaPatchMode=\).*~ ~\1REPLACE_INTERNAL_WITH_EXTERNAL~
    REPLACE_TEXTUALLY ~^\(LuaLibrary=\).*~ ~\1lua51.dll~
    REPLACE_TEXTUALLY ~^\(LuaVersionExternal=\).*~ ~\1%lua_version%~
  BUT_ONLY

  PRINT ~LuaJIT installed successfully. BuffBot will have full functionality.~
END
```

**Step 2: Update the main component's EEex check**

The main component (DESIGNATED 0) currently checks `MOD_IS_INSTALLED ~EEex/EEex.tp2~ ~0~`. This works for stable (where main is component 0) but NOT for devel (where main is component 1). Update to check both:

```tp2
REQUIRE_PREDICATE (MOD_IS_INSTALLED ~EEex/EEex.tp2~ ~0~ OR MOD_IS_INSTALLED ~EEex/EEex.tp2~ ~1~)
  ~BuffBot requires EEex. Install EEex first: https://github.com/Bubb13/EEex~
```

**Step 3: Verify the .tp2 is valid**

Run: `grep -n "BEGIN\|DESIGNATED\|LABEL\|REQUIRE" setup-buffbot.tp2`
Expected: Two BEGIN blocks, DESIGNATED 0 and 1, both with LABEL and REQUIRE lines.

**Step 4: Commit**

```bash
git add setup-buffbot.tp2
git commit -m "feat(installer): add LuaJIT auto-detection and installation component"
```

---

### Task 1: Add runtime io guard in M_BfBot.lua and BfBotCor.lua

**Files:**
- Modify: `buffbot/M_BfBot.lua:4` (after EEex_Active check)
- Modify: `buffbot/BfBotCor.lua:24-50` (logging functions)

**Step 1: Add `_noIO` flag in M_BfBot.lua**

After line 4 (`if not EEex_Active then return end`), add:

```lua
BfBot = BfBot or {}
if not io then
    BfBot._noIO = 1
    EEex_Menu_AddAfterMainFileLoadedListener(function()
        Infinity_DisplayString("BuffBot: LuaJIT not detected. F12 innates, Quick Cast, Export/Import, and logging are disabled. Install EEex LuaJIT component for full functionality.")
    end)
end
```

Note: uses `1` not `true` (EEex marshal boolean gotcha, and consistency with the rest of the codebase).

**Step 2: Guard logging functions in BfBotCor.lua**

In `_OpenLog()` (line 24):
```lua
function BfBot._OpenLog()
    if BfBot._noIO then return end
    local h, err = io.open(BfBot._logFile, "w")
    if h then
        BfBot._logHandle = h
        h:write("=== BuffBot Log " .. (os.date and os.date("%Y-%m-%d %H:%M:%S") or "?") .. " ===\n")
    end
end
```

In `_OpenLogAppend()` (line 41):
```lua
function BfBot._OpenLogAppend(filename)
    if BfBot._noIO then return false end
    BfBot._CloseLog()
    local fname = filename or BfBot._logFile
    local h, err = io.open(fname, "a")
    if h then
        BfBot._logHandle = h
        h:write("\n=== BuffBot Log " .. (os.date and os.date("%Y-%m-%d %H:%M:%S") or "?") .. " ===\n")
    end
    return h ~= nil
end
```

`_Print`, `_Display`, `_CloseLog` don't need changes — they only use `BfBot._logHandle` which will be nil when `_noIO` is set, so the file-writing branches are already dead. The `Infinity_DisplayString` paths still work.

**Step 3: Commit**

```bash
git add buffbot/M_BfBot.lua buffbot/BfBotCor.lua
git commit -m "feat(runtime): add _noIO flag and guard logging for missing LuaJIT"
```

---

### Task 2: Guard BfBotInn.lua — strref read, SPL writing, innate operations

**Files:**
- Modify: `buffbot/BfBotInn.lua:11-16` (module-level strref read)
- Modify: `buffbot/BfBotInn.lua:337` (`_EnsureSPLFiles`)
- Modify: `buffbot/BfBotInn.lua:401` (`Grant`)
- Modify: `buffbot/BfBotInn.lua:520` (`Revoke`)
- Modify: `buffbot/BfBotInn.lua:533` (`Refresh`)
- Modify: `buffbot/BfBotInn.lua:549` (`RefreshAll`)
- Modify: `buffbot/BfBotInn.lua:561` (`_InnateLog`)

**Step 1: Guard module-level strref read (line 11-16)**

Replace:
```lua
BfBot.Innate._baseStrref = nil
local _sf = io.open("override/bfbot_strrefs.txt", "r")
if _sf then
    BfBot.Innate._baseStrref = tonumber(_sf:read("*l"))
    _sf:close()
end
```

With:
```lua
BfBot.Innate._baseStrref = nil
if io then
    local _sf = io.open("override/bfbot_strrefs.txt", "r")
    if _sf then
        BfBot.Innate._baseStrref = tonumber(_sf:read("*l"))
        _sf:close()
    end
end
```

**Step 2: Guard `_EnsureSPLFiles` (line 337)**

Add early return at the top of the function:
```lua
function BfBot.Innate._EnsureSPLFiles()
    if BfBot._noIO then return 0 end
    -- ... rest unchanged
```

**Step 3: Guard `Grant`, `Revoke`, `Refresh`, `RefreshAll`**

Add early return to each:
```lua
function BfBot.Innate.Grant()
    if BfBot._noIO then return end
    -- ... rest unchanged

function BfBot.Innate.Revoke(slot)
    if BfBot._noIO then return end
    -- ... rest unchanged

function BfBot.Innate.Refresh(slot)
    if BfBot._noIO then return end
    -- ... rest unchanged

function BfBot.Innate.RefreshAll()
    if BfBot._noIO then return end
    -- ... rest unchanged
```

**Step 4: Guard `_InnateLog` (line 561)**

```lua
local function _InnateLog(msg)
    if not io then return end
    local logf = io.open("buffbot_innate.log", "a")
    if logf then
        logf:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), msg))
        logf:close()
    end
end
```

**Step 5: Commit**

```bash
git add buffbot/BfBotInn.lua
git commit -m "feat(innate): guard all io usage for graceful LuaJIT degradation"
```

---

### Task 3: Guard BfBotPer.lua — export/import/listing

**Files:**
- Modify: `buffbot/BfBotPer.lua:630-631` (`_EnsurePresetsDir`)
- Modify: `buffbot/BfBotPer.lua:634-671` (`ExportConfig`)
- Modify: `buffbot/BfBotPer.lua:675-689` (`ListExports`)
- Modify: `buffbot/BfBotPer.lua:696-729` (`ImportConfig`)

**Step 1: Guard all four functions**

```lua
function BfBot.Persist._EnsurePresetsDir()
    if not os then return end
    os.execute('mkdir "' .. BfBot.Persist._PRESETS_DIR .. '" 2>nul')
end

function BfBot.Persist.ExportConfig(sprite)
    if BfBot._noIO then return false, "LuaJIT required for export" end
    -- ... rest unchanged

function BfBot.Persist.ListExports()
    if BfBot._noIO then return {} end
    -- ... rest unchanged

function BfBot.Persist.ImportConfig(sprite, filename)
    if BfBot._noIO then return false, "LuaJIT required for import" end
    -- ... rest unchanged
```

**Step 2: Commit**

```bash
git add buffbot/BfBotPer.lua
git commit -m "feat(persist): guard export/import for graceful LuaJIT degradation"
```

---

### Task 4: Hide io-dependent UI elements when _noIO

**Files:**
- Modify: `buffbot/BuffBot.menu` (3 elements: bbExp, bbImp, bbQC — `enabled` lines)

**Step 1: Update enabled conditions**

For `bbExp` (line 433):
```menu
enabled "buffbot_isOpen and not BfBot._noIO"
```

For `bbImp` (line 446):
```menu
enabled "buffbot_isOpen and not BfBot._noIO"
```

For `bbQC` (line 657):
```menu
enabled "buffbot_isOpen and not BfBot._noIO"
```

This hides the buttons entirely when `_noIO` is set, since disabled elements in the IE .menu system are not rendered.

**Step 2: Commit**

```bash
git add buffbot/BuffBot.menu
git commit -m "feat(ui): hide Quick Cast, Export, Import buttons when LuaJIT missing"
```

---

### Task 5: Guard BfBotTst.lua — skip SPL file tests

**Files:**
- Modify: `buffbot/BfBotTst.lua:2258-2274` (SPL file check in innate diagnostics)

**Step 1: Guard the SPL file verification block**

Wrap the `io.open` block (lines 2258-2274):
```lua
    -- Check SPL files on disk
    if BfBot._noIO then
        P("[BuffBot] SPL file check skipped (no io — LuaJIT not installed)")
    else
        local splFound, splMissing = 0, 0
        for slot = 0, 5 do
            for preset = 1, BfBot.MAX_PRESETS do
                local resref = string.format("BFBT%d%d", slot, preset)
                local path = "override/" .. resref .. ".SPL"
                local f = io.open(path, "rb")
                if f then
                    local size = f:seek("end")
                    f:close()
                    splFound = splFound + 1
                else
                    splMissing = splMissing + 1
                end
            end
        end
        P(string.format("[BuffBot] SPL files on disk: %d found, %d missing", splFound, splMissing))
    end
    P("")
```

**Step 2: Commit**

```bash
git add buffbot/BfBotTst.lua
git commit -m "feat(test): skip SPL file verification when LuaJIT missing"
```

---

### Task 6: Update README and CHANGELOG

**Files:**
- Modify: `README.md:25-30` (requirements section)
- Modify: `README.md:36-39` (installation section)
- Modify: `CHANGELOG.md` (add entry at top)

**Step 1: Update README requirements**

Replace lines 25-30:
```markdown
## Requirements

- **BG:EE**, **BG2:EE**, or **EET**
- **[EEex](https://github.com/Bubb13/EEex)** v0.10.0-alpha or later (with LuaJIT component recommended)

EEex is required for Lua access to engine internals. The BuffBot installer will automatically set up the EEex LuaJIT component if it's not already installed. Without LuaJIT, BuffBot runs in reduced mode (no F12 innates, Quick Cast, export/import, or log files).
```

**Step 2: Update README installation**

After "Select BuffBot when prompted", add a note:
```markdown
3. The installer automatically detects and installs EEex LuaJIT if needed. If you see a "LuaJIT Support" component, accept it for full functionality.
```

**Step 3: Add CHANGELOG entry**

Add at top of CHANGELOG.md, before the v1.3.0-alpha entry:
```markdown
## v1.3.1-alpha (2026-04-05)

### Installer
- LuaJIT auto-detection and installation — BuffBot installer now checks for EEex LuaJIT and offers to install it from EEex's own files if missing
- Fixes crash on EEex devel branch when LuaJIT component not selected (`io` global nil)

### Runtime
- Graceful degradation without LuaJIT — core features (scanning, config, casting) work; F12 innates, Quick Cast, Export/Import, and logging disabled with clear warning message
```

**Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: update README requirements and CHANGELOG for LuaJIT support"
```

---

### Task 7: Create GitHub issue for EEex compatibility monitoring

**Files:** None (GitHub issue only)

**Step 1: Create the issue**

```bash
gh issue create \
  --title "Automated EEex compatibility check" \
  --body "Periodic check against EEex stable/devel repos to verify:
- LuaJIT file paths (EEex/loader/LuaJIT/) still match our installer
- INI values (LuaPatchMode, LuaLibrary, LuaVersionExternal) still match
- Component labels (B3-EEex-LuaJIT) haven't changed
- No new Lua environment restrictions introduced

Could be a GitHub Action that runs weekly or on EEex release tags." \
  --label "enhancement"
```

**Step 2: Commit** — N/A (issue only)
