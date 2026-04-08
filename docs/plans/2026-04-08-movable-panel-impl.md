# Movable & Resizable Panel — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the BuffBot config panel draggable and resizable with INI-persisted position/size.

**Architecture:** Two `.menu` `handle` elements (title bar drag + bottom-right resize) with `actionDrag` callbacks read engine `motionX`/`motionY` globals, update in-memory geometry, and call `_Layout()`. Geometry persisted to INI on panel close. `_Layout()` modified to use stored geometry instead of always computing 80%-centered.

**Tech Stack:** Lua (.menu callbacks), IE `.menu` DSL (handle elements), INI persistence via `Infinity_GetINIValue`/`Infinity_SetINIValue`

**Design doc:** `docs/plans/2026-04-08-movable-panel-design.md`

---

### Task 0: Create feature branch

**Step 1: Create and switch to branch**

```bash
git checkout -b feature/movable-panel
```

**Step 2: Verify**

```bash
git branch --show-current
```

Expected: `feature/movable-panel`

---

### Task 1: Add INI defaults and `_LoadLayout()` / `_SaveLayout()`

**Files:**
- Modify: `buffbot/BfBotPer.lua:15-22` (add 4 INI defaults)
- Modify: `buffbot/BfBotUI.lua:7-15` (add state vars)
- Modify: `buffbot/BfBotUI.lua` (add _LoadLayout/_SaveLayout before _OnMenusLoaded)

**Step 1: Add INI defaults**

In `buffbot/BfBotPer.lua`, add four keys to `_INI_DEFAULTS` (line 15-22):

```lua
BfBot.Persist._INI_DEFAULTS = {
    LongThreshold = 300,
    DefaultPreset = 1,
    HotkeyCode    = 87,
    ShowTooltips  = 1,
    ConfirmCast   = 0,
    CombatInterrupt = 1,
    PanelX        = 0,    -- 0 = use default (centered)
    PanelY        = 0,
    PanelW        = 0,    -- 0 = use default (80% of screen)
    PanelH        = 0,
}
```

**Step 2: Add state variables and layout functions**

In `buffbot/BfBotUI.lua`, after the existing state variables (line ~15), add:

```lua
-- Panel geometry (nil = use default 80%-centered)
BfBot.UI._panelX = nil
BfBot.UI._panelY = nil
BfBot.UI._panelW = nil
BfBot.UI._panelH = nil

-- Minimum panel dimensions (widest button row ~420px + padding)
BfBot.UI._MIN_W = 550
BfBot.UI._MIN_H = 350
```

Before the `_OnMenusLoaded` function (around line 180), add:

```lua
-- ============================================================
-- Layout Persistence (INI-backed panel position/size)
-- ============================================================

--- Load saved panel geometry from INI. Values of 0 mean "use default".
function BfBot.UI._LoadLayout()
    local x = BfBot.Persist.GetPref("PanelX")
    local y = BfBot.Persist.GetPref("PanelY")
    local w = BfBot.Persist.GetPref("PanelW")
    local h = BfBot.Persist.GetPref("PanelH")
    BfBot.UI._panelX = (x ~= 0) and x or nil
    BfBot.UI._panelY = (y ~= 0) and y or nil
    BfBot.UI._panelW = (w ~= 0) and w or nil
    BfBot.UI._panelH = (h ~= 0) and h or nil
end

--- Save current panel geometry to INI.
function BfBot.UI._SaveLayout()
    BfBot.Persist.SetPref("PanelX", BfBot.UI._panelX or 0)
    BfBot.Persist.SetPref("PanelY", BfBot.UI._panelY or 0)
    BfBot.Persist.SetPref("PanelW", BfBot.UI._panelW or 0)
    BfBot.Persist.SetPref("PanelH", BfBot.UI._panelH or 0)
end
```

**Step 3: Call `_LoadLayout()` in `_OnMenusLoaded()`**

In `_OnMenusLoaded()`, after the debug mode load (line ~264) and before `BfBot.UI._initialized = true`:

```lua
    -- Load saved panel geometry from INI
    BfBot.UI._LoadLayout()
```

**Step 4: Call `_SaveLayout()` in `_OnClose()`**

In `_OnClose()` (line ~412), add save call:

```lua
function BfBot.UI._OnClose()
    buffbot_isOpen = false
    BfBot.UI._SaveLayout()
end
```

**Step 5: Commit**

```bash
git add buffbot/BfBotPer.lua buffbot/BfBotUI.lua
git commit -m "feat(ui): add panel geometry state vars + INI load/save (#24)"
```

---

### Task 2: Modify `_Layout()` to use stored geometry

**Files:**
- Modify: `buffbot/BfBotUI.lua:290-296` (first 7 lines of `_Layout()`)

**Step 1: Replace hardcoded 80% centered with stored-or-default**

Change `_Layout()` lines 290-296 from:

```lua
function BfBot.UI._Layout()
    local sw, sh = Infinity_GetScreenSize()
    if not sw or not sh then return end
    local pw = math.floor(sw * 0.8)
    local ph = math.floor(sh * 0.8)
    local px = math.floor((sw - pw) / 2)
    local py = math.floor((sh - ph) / 2)
```

To:

```lua
function BfBot.UI._Layout()
    local sw, sh = Infinity_GetScreenSize()
    if not sw or not sh then return end
    local pw = BfBot.UI._panelW or math.floor(sw * 0.8)
    local ph = BfBot.UI._panelH or math.floor(sh * 0.8)
    local px = BfBot.UI._panelX or math.floor((sw - pw) / 2)
    local py = BfBot.UI._panelY or math.floor((sh - ph) / 2)
```

**Step 2: Add handle positioning at end of `_Layout()`**

After the status line `Infinity_SetArea("bbStatus", ...)` (line ~381), add:

```lua
    -- Drag handle covers title bar area
    Infinity_SetArea("bbDragHandle", px, py, pw, 35)

    -- Resize handle at bottom-right corner
    Infinity_SetArea("bbResizeHandle", px + pw - 20, py + ph - 20, 20, 20)

    -- Reset button in title bar (right-aligned, 50px wide)
    Infinity_SetArea("bbReset", px + pw - 60, py + 5, 50, 24)
```

**Step 3: Update section comment**

Change line 287-288 from:

```lua
-- Dynamic Layout (resize panel to ~80% of screen on open)
```

To:

```lua
-- Dynamic Layout (user-stored or default 80% of screen)
```

**Step 4: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): _Layout() uses stored geometry + positions handles (#24)"
```

---

### Task 3: Add drag and resize callback functions

**Files:**
- Modify: `buffbot/BfBotUI.lua` (add functions before Panel Open/Close section, ~line 384)

**Step 1: Add `_OnDrag()`, `_OnResize()`, `_ResetLayout()`**

Insert before the "Panel Open/Close" section comment (line ~384):

```lua
-- ============================================================
-- Drag & Resize Handlers (called by .menu handle elements)
-- ============================================================

--- Called per-frame during title bar drag. Moves the panel.
function BfBot.UI._OnDrag()
    local dx = motionX or 0
    local dy = motionY or 0
    if dx == 0 and dy == 0 then return end

    local sw, sh = Infinity_GetScreenSize()
    if not sw or not sh then return end

    -- Current geometry (read from state or compute default)
    local pw = BfBot.UI._panelW or math.floor(sw * 0.8)
    local ph = BfBot.UI._panelH or math.floor(sh * 0.8)
    local px = (BfBot.UI._panelX or math.floor((sw - pw) / 2)) + dx
    local py = (BfBot.UI._panelY or math.floor((sh - ph) / 2)) + dy

    -- Clamp to screen (keep fully on-screen)
    px = math.max(0, math.min(px, sw - pw))
    py = math.max(0, math.min(py, sh - ph))

    BfBot.UI._panelX = px
    BfBot.UI._panelY = py
    BfBot.UI._Layout()
end

--- Called per-frame during bottom-right corner drag. Resizes the panel.
function BfBot.UI._OnResize()
    local dx = motionX or 0
    local dy = motionY or 0
    if dx == 0 and dy == 0 then return end

    local sw, sh = Infinity_GetScreenSize()
    if not sw or not sh then return end

    local pw = (BfBot.UI._panelW or math.floor(sw * 0.8)) + dx
    local ph = (BfBot.UI._panelH or math.floor(sh * 0.8)) + dy

    -- Enforce minimums
    pw = math.max(BfBot.UI._MIN_W, pw)
    ph = math.max(BfBot.UI._MIN_H, ph)

    -- Clamp to screen (panel must fit from current position)
    local px = BfBot.UI._panelX or math.floor((sw - pw) / 2)
    pw = math.min(pw, sw - px)
    ph = math.min(ph, sh - (BfBot.UI._panelY or math.floor((sh - ph) / 2)))

    -- Recalculate py clamp after ph change
    local py = BfBot.UI._panelY or math.floor((sh - ph) / 2)
    ph = math.min(ph, sh - py)

    BfBot.UI._panelW = pw
    BfBot.UI._panelH = ph

    -- Regenerate MOS if panel + border exceeds current texture
    local bpad = 24
    local needW = pw + 2 * bpad + 64
    local needH = ph + 2 * bpad + 64
    if not BfBot.UI._mosW or needW > BfBot.UI._mosW
       or not BfBot.UI._mosH or needH > BfBot.UI._mosH then
        BfBot.UI._GenerateBgMOS()
    end

    BfBot.UI._Layout()
end

--- Reset panel to default 80%-centered layout.
function BfBot.UI._ResetLayout()
    BfBot.UI._panelX = nil
    BfBot.UI._panelY = nil
    BfBot.UI._panelW = nil
    BfBot.UI._panelH = nil
    BfBot.Persist.SetPref("PanelX", 0)
    BfBot.Persist.SetPref("PanelY", 0)
    BfBot.Persist.SetPref("PanelW", 0)
    BfBot.Persist.SetPref("PanelH", 0)
    BfBot.UI._Layout()
end
```

**Step 2: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): add _OnDrag/_OnResize/_ResetLayout handlers (#24)"
```

---

### Task 4: Add handle elements and reset button to `.menu`

**Files:**
- Modify: `buffbot/BuffBot.menu:54-83` (insert handle elements + reset button in BUFFBOT_MAIN)

**Step 1: Add drag handle after the title label**

After the `bbTitle` label block (line ~83, after the closing `}` of the title label), insert:

```
	-- Title bar drag handle (invisible — covers title area for dragging)
	handle
	{
		name       "bbDragHandle"
		actionDrag "BfBot.UI._OnDrag()"
		area 340 55 540 35
	}
```

**Step 2: Add resize handle**

Right after the drag handle, insert:

```
	-- Bottom-right resize handle (small grip area)
	handle
	{
		name       "bbResizeHandle"
		actionDrag "BfBot.UI._OnResize()"
		area 860 540 20 20
	}
```

**Step 3: Add reset button**

Right after the resize handle, insert:

```
	-- Reset layout button (right side of title bar)
	text
	{
		name    "bbReset"
		enabled "buffbot_isOpen"
		action  "BfBot.UI._ResetLayout()"
		text    "Reset"
		text style "normal"
		text color lua "{180, 160, 130}"
		text align center center
		area 820 55 50 24
	}
```

Note: All `area` values are placeholders — `_Layout()` repositions everything dynamically.

**Step 4: Commit**

```bash
git add buffbot/BuffBot.menu
git commit -m "feat(ui): add drag/resize handle elements + reset button to .menu (#24)"
```

---

### Task 5: Update resolution change handler for clamping

**Files:**
- Modify: `buffbot/BfBotUI.lua:255-260` (WindowSizeChangedListener)

**Step 1: Add clamping logic to resolution change handler**

Replace the existing listener (lines 255-260):

```lua
    EEex_Menu_AddWindowSizeChangedListener(function(w, h)
        BfBot.UI._GenerateBgMOS()
        if buffbot_isOpen then
            BfBot.UI._Layout()
        end
    end)
```

With:

```lua
    EEex_Menu_AddWindowSizeChangedListener(function(w, h)
        BfBot.UI._GenerateBgMOS()
        -- Clamp stored geometry to new screen bounds
        if BfBot.UI._panelW or BfBot.UI._panelH then
            local sw, sh = w, h
            local pw = BfBot.UI._panelW
            local ph = BfBot.UI._panelH
            if pw and pw > sw then BfBot.UI._panelW = nil end
            if ph and ph > sh then BfBot.UI._panelH = nil end
            local cpw = BfBot.UI._panelW or math.floor(sw * 0.8)
            local cph = BfBot.UI._panelH or math.floor(sh * 0.8)
            if BfBot.UI._panelX and BfBot.UI._panelX + cpw > sw then
                BfBot.UI._panelX = math.max(0, sw - cpw)
            end
            if BfBot.UI._panelY and BfBot.UI._panelY + cph > sh then
                BfBot.UI._panelY = math.max(0, sh - cph)
            end
        end
        if buffbot_isOpen then
            BfBot.UI._Layout()
        end
    end)
```

**Step 2: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): clamp panel geometry on resolution change (#24)"
```

---

### Task 6: Add unit tests

**Files:**
- Modify: `buffbot/BfBotTst.lua` (add MovablePanel test section)

**Step 1: Add test function**

Add at the end of the test file, before the final `RunAll` function (search for `function BfBot.Test.RunAll`):

```lua
-- ============================================================
-- Movable Panel tests
-- ============================================================

function BfBot.Test.MovablePanel()
    _reset()
    P("== MovablePanel ==")

    -- Test 1: Default layout (no stored values)
    BfBot.UI._panelX = nil
    BfBot.UI._panelY = nil
    BfBot.UI._panelW = nil
    BfBot.UI._panelH = nil
    local sw, sh = Infinity_GetScreenSize()
    local defW = math.floor(sw * 0.8)
    local defH = math.floor(sh * 0.8)
    local defX = math.floor((sw - defW) / 2)
    local defY = math.floor((sh - defH) / 2)
    BfBot.UI._Layout()
    local bx, by, bw, bh = Infinity_GetArea("bbBg")
    _check(bx == defX, "default X = centered (" .. tostring(bx) .. " == " .. tostring(defX) .. ")")
    _check(by == defY, "default Y = centered (" .. tostring(by) .. " == " .. tostring(defY) .. ")")
    _check(bw == defW, "default W = 80% screen (" .. tostring(bw) .. " == " .. tostring(defW) .. ")")
    _check(bh == defH, "default H = 80% screen (" .. tostring(bh) .. " == " .. tostring(defH) .. ")")

    -- Test 2: Stored position used
    BfBot.UI._panelX = 100
    BfBot.UI._panelY = 50
    BfBot.UI._panelW = 800
    BfBot.UI._panelH = 600
    BfBot.UI._Layout()
    bx, by, bw, bh = Infinity_GetArea("bbBg")
    _check(bx == 100, "stored X applied (" .. tostring(bx) .. ")")
    _check(by == 50,  "stored Y applied (" .. tostring(by) .. ")")
    _check(bw == 800, "stored W applied (" .. tostring(bw) .. ")")
    _check(bh == 600, "stored H applied (" .. tostring(bh) .. ")")

    -- Test 3: Drag handle positioned on title bar
    local hx, hy, hw, hh = Infinity_GetArea("bbDragHandle")
    _check(hx == 100, "drag handle X = panel X (" .. tostring(hx) .. ")")
    _check(hy == 50,  "drag handle Y = panel Y (" .. tostring(hy) .. ")")
    _check(hw == 800, "drag handle W = panel W (" .. tostring(hw) .. ")")

    -- Test 4: Resize handle at bottom-right
    local rx, ry, rw, rh = Infinity_GetArea("bbResizeHandle")
    _check(rx == 100 + 800 - 20, "resize handle X = bottom-right (" .. tostring(rx) .. ")")
    _check(ry == 50 + 600 - 20,  "resize handle Y = bottom-right (" .. tostring(ry) .. ")")
    _check(rw == 20, "resize handle W = 20 (" .. tostring(rw) .. ")")

    -- Test 5: Reset clears stored values
    BfBot.UI._ResetLayout()
    _check(BfBot.UI._panelX == nil, "reset clears X")
    _check(BfBot.UI._panelY == nil, "reset clears Y")
    _check(BfBot.UI._panelW == nil, "reset clears W")
    _check(BfBot.UI._panelH == nil, "reset clears H")
    bx, by, bw, bh = Infinity_GetArea("bbBg")
    _check(bx == defX, "reset restores default X (" .. tostring(bx) .. ")")
    _check(bw == defW, "reset restores default W (" .. tostring(bw) .. ")")

    -- Test 6: _OnResize enforces minimum width
    BfBot.UI._panelX = 100
    BfBot.UI._panelY = 50
    BfBot.UI._panelW = 600
    BfBot.UI._panelH = 400
    motionX = -200  -- shrink by 200px → 400 < MIN_W(550)
    motionY = 0
    BfBot.UI._OnResize()
    _check(BfBot.UI._panelW >= BfBot.UI._MIN_W,
        "resize enforces min W (" .. tostring(BfBot.UI._panelW) .. " >= " .. tostring(BfBot.UI._MIN_W) .. ")")

    -- Test 7: _OnResize enforces minimum height
    BfBot.UI._panelW = 600
    BfBot.UI._panelH = 400
    motionX = 0
    motionY = -200  -- shrink by 200px → 200 < MIN_H(350)
    BfBot.UI._OnResize()
    _check(BfBot.UI._panelH >= BfBot.UI._MIN_H,
        "resize enforces min H (" .. tostring(BfBot.UI._panelH) .. " >= " .. tostring(BfBot.UI._MIN_H) .. ")")

    -- Test 8: _OnDrag clamps to screen
    BfBot.UI._panelW = 800
    BfBot.UI._panelH = 600
    BfBot.UI._panelX = sw - 100  -- near right edge
    BfBot.UI._panelY = 50
    motionX = 200  -- try to push off screen
    motionY = 0
    BfBot.UI._OnDrag()
    _check(BfBot.UI._panelX + 800 <= sw,
        "drag clamps X to screen (" .. tostring(BfBot.UI._panelX) .. " + 800 <= " .. tostring(sw) .. ")")

    -- Test 9: _OnDrag clamps Y to >= 0
    BfBot.UI._panelX = 100
    BfBot.UI._panelY = 10
    motionX = 0
    motionY = -50  -- try to push above screen
    BfBot.UI._OnDrag()
    _check(BfBot.UI._panelY >= 0,
        "drag clamps Y >= 0 (" .. tostring(BfBot.UI._panelY) .. ")")

    -- Clean up: restore defaults
    motionX = nil
    motionY = nil
    BfBot.UI._ResetLayout()

    return _summary("MovablePanel")
end
```

**Step 2: Add `MovablePanel` to `RunAll`**

Find `function BfBot.Test.RunAll()` and add the call alongside existing tests:

```lua
    allOk = BfBot.Test.MovablePanel() and allOk
```

**Step 3: Commit**

```bash
git add buffbot/BfBotTst.lua
git commit -m "test: add MovablePanel unit tests (#24)"
```

---

### Task 7: Update CLAUDE.md and CHANGELOG

**Files:**
- Modify: `CLAUDE.md` (update Dynamic Panel Sizing bullet)
- Modify: `CHANGELOG.md` (add entry)

**Step 1: Update CLAUDE.md**

Find the "Dynamic Panel Sizing" bullet and update to mention movability:

> - **Dynamic Panel Sizing** (`BfBot.UI._Layout`) — panel covers ~80% of screen by default, centered, computed via `Infinity_GetScreenSize()` + `Infinity_SetArea()`. All elements named for dynamic positioning. Parchment background MOS generated at runtime (`_GenerateBgMOS`) by tiling existing PVRZ blocks to match screen size — supports ultrawide, 4K, and arbitrary resolutions. Resolution changes handled via `EEex_Menu_AddWindowSizeChangedListener`. **Movable and resizable** — title bar `handle` element for drag, bottom-right corner for resize. Position/size persisted to INI (`PanelX`/`PanelY`/`PanelW`/`PanelH`). Minimum 550x350px. Reset button restores default. Stored geometry clamped on resolution change.

**Step 2: Add CHANGELOG entry**

Add a new version entry at the top:

```markdown
## v1.3.4-alpha (2026-04-08)

### Added
- **Movable panel** — drag the title bar to reposition the config panel (#24)
- **Resizable panel** — drag the bottom-right corner to resize (#24)
- **Reset Layout button** — restores default 80%-centered panel
- Panel position/size persisted to baldur.ini across sessions
- Screen clamping on resolution change
```

**Step 3: Commit**

```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "docs: update CLAUDE.md + CHANGELOG for movable panel (#24)"
```

---

### Task 8: Deploy and in-game test

**Step 1: Deploy**

```bash
bash tools/deploy.sh
```

**Step 2: In-game verification checklist**

1. Open panel (F11) — default 80% centered as before
2. Drag title bar — panel moves smoothly
3. Release — panel stays at new position
4. Close and reopen — position preserved
5. Drag bottom-right corner — panel resizes, spell list grows/shrinks
6. Resize below minimum — clamped at 550x350
7. Click "Reset" — snaps back to centered 80%
8. Close and reopen — default position (reset persisted)
9. Move to edge, change resolution — panel clamped to fit
10. Run `BfBot.Test.MovablePanel()` — all tests pass
11. Run `BfBot.Test.RunAll()` — no regressions
