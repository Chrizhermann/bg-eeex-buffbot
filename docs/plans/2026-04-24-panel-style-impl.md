# Panel Style / Theme Customization — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship 6 selectable panel themes (BG2/SOD/BG1 × light/dark) plus text size control, surfaced in EEex Options tab and persisted in baldur.ini — while preserving current v1.3.12-alpha appearance by default.

**Architecture:** New `BfBotThm.lua` module holds 6 palette tables and a `_T(key)` accessor. BuffBot.menu is migrated to reference the accessor and custom `bb_*` text styles (deep-copied from engine styles at init). Dark mode is an opacity-configurable rectangle overlay. Borders use 3 pre-registered SlicedRects swapped via `_T('borderResref')`. Background MOS is regenerated per theme. Settings live in `[BuffBot]` INI section under `Theme` + `FontSize` keys.

**Tech Stack:** Lua + .menu DSL, EEex API (`EEex.RegisterSlicedRect`, `EEex_Options_AddTab`, `styles[]` global), Pillow (PNG→PVRZ pipeline), WeiDU (installer), existing BfBot modules.

**Design doc:** `docs/plans/2026-04-24-panel-style-design.md` — read this first.

**Conventions:**
- In-game testing via EEex remote console: `bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" "<lua>"`
- Deploy: `bash tools/deploy.sh`
- Hot reload: `Infinity_DoFile("BfBotX")` (no restart needed)
- Full test run: `BfBot.Test.RunAll()`
- Game must be on world screen for remote console / hot reload

---

## Task 0: Create feature branch

**Files:** none (git ops only)

**Step 1: Verify clean working tree**

Run: `git status`
Expected: untracked files are allowed; no modified tracked files on main

**Step 2: Create and switch to feature branch**

Run: `git checkout -b feat/panel-themes`
Expected: `Switched to a new branch 'feat/panel-themes'`

**Step 3: Commit current state marker (empty)**

No commit needed — task only reserves the branch. Proceed to Task 1.

---

## Task 1: PNG → PVRZ conversion tool

**Files:**
- Create: `tools/png_to_pvrz.py`
- Create: `buffbot/BFBOTBG2.PVRZ` (output — committed binary)
- Create: `buffbot/BFBOTFR2.PVRZ` (output)
- Create: `buffbot/BFBOTBG3.PVRZ` (output)
- Create: `buffbot/BFBOTFR3.PVRZ` (output)

**Step 1: Verify Pillow availability**

Run: `python -c "from PIL import Image; print(Image.__version__)"`
Expected: version number, no error. If error: `pip install Pillow`

**Step 2: Write the conversion script**

Create `tools/png_to_pvrz.py`. The PVRZ format expected by the engine:

```
uint32 uncompressed_size
zlib_deflate(
    PVR3 header (52 bytes) {
        uint32 version = 0x03525650  ('PVR\3')
        uint32 flags = 0
        uint64 pixel_format = 11  (DXT5)
        uint32 colorspace = 0  (lRGB)
        uint32 channel_type = 0  (unsigned byte normalized)
        uint32 height
        uint32 width
        uint32 depth = 1
        uint32 num_surfaces = 1
        uint32 num_faces = 1
        uint32 num_mipmaps = 1
        uint32 metadata_size = 0
    }
    DXT5 compressed pixel data (height * width bytes for DXT5)
)
```

DXT5 is tricky to encode manually. Use Pillow's `tobytes("raw", "RGBA")` and a pure-Python DXT5 encoder. Reference: https://github.com/NearInfinityBrowser/NearInfinity source for encoding logic, or use `texture2ddecoder` package if available.

Script interface:
```
python tools/png_to_pvrz.py <input.png> <output.pvrz> [--width N --height N]
```
- For borders: `--width 512 --height 512` (auto-resize)
- For backgrounds: slice at `(0,0,1024,1024)`, `(1024,0,2048,1024)`, `(0,1024,1024,1152)`, `(1024,1024,2048,1152)` and emit 4 PVRZ files

Add a convenience mode:
```
python tools/png_to_pvrz.py --theme sod  # converts SOD files
python tools/png_to_pvrz.py --theme bg1  # converts BG1 files
```

**Step 3: Convert SOD assets**

Run: `python tools/png_to_pvrz.py --theme sod`
Expected: creates `buffbot/BFBOTBG2*.PVRZ` (4 files if background slicing) and `buffbot/BFBOTFR2.PVRZ`

**Step 4: Convert BG1 assets**

Run: `python tools/png_to_pvrz.py --theme bg1`
Expected: creates `buffbot/BFBOTBG3*.PVRZ` and `buffbot/BFBOTFR3.PVRZ`

**Step 5: Verify PVRZ files readable by engine**

Deploy and test in-game:
```bash
bash tools/deploy.sh
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
local ok, err = pcall(function()
    EEex.RegisterSlicedRect("test_bg1_border", {
        topLeft={0,0,128,128}, top={128,0,256,128}, topRight={384,0,128,128},
        right={384,128,128,256}, bottomRight={384,384,128,128}, bottom={128,384,256,128},
        bottomLeft={0,384,128,128}, left={0,128,128,256}, center={128,128,256,256},
        dimensions={512,512}, resref="BFBOTFR3", flags=0,
    })
end)
return ok and "registered" or tostring(err)
'
```
Expected output: `"registered"` (not an error)

**Step 6: Commit**

```bash
git add tools/png_to_pvrz.py buffbot/*.PVRZ
git commit -m "feat(tools): png_to_pvrz converter + generated SOD/BG1 PVRZs"
```

---

## Task 2: Theme module skeleton + palette data

**Files:**
- Create: `buffbot/BfBotThm.lua`
- Modify: `buffbot/M_BfBot.lua` (add DoFile line)

**Step 1: Write the new module with palette tables**

Create `buffbot/BfBotThm.lua`:

```lua
-- BfBotThm.lua — Theme palettes + accessor.
-- Loaded after BfBotCor but before BfBotUI (UI references _T).
BfBot = BfBot or {}
BfBot.Theme = BfBot.Theme or {}

-- Six palettes keyed as <accent>_<mode>.
-- Each palette is flat; _T(key) reads from the active palette.
BfBot.Theme._palettes = {
    bg2_light = {
        overlay      = 0,
        borderResref = "BFBOTFR",
        bgResref     = "BFBOTBG",
        -- Generic
        title        = "{50, 30, 10}",
        text         = "{50, 30, 10}",
        textMuted    = "{140, 130, 120}",
        textAccent   = "{40, 80, 160}",
        -- Specific menu regions
        grip         = "{120, 100, 70}",
        reset        = "{180, 160, 130}",
        headerSub    = "{120, 90, 20}",
        lockText     = "{150, 120, 80}",
        spellLocked  = "{100, 70, 20}",
        -- Picker
        pickerSel    = "{255, 255, 150}",
        pickerOn     = "{220, 220, 220}",
        pickerOff    = "{140, 140, 140}",
        -- QuickCast
        qcOff        = "{80, 60, 40}",
        qcLong       = "{160, 120, 20}",
        qcAll        = "{180, 60, 30}",
        -- Lock column
        lockActive   = "{230, 200, 60}",
        lockInactive = "{120, 100, 80}",
    },
    bg2_dark = {
        overlay      = 160,
        borderResref = "BFBOTFR",
        bgResref     = "BFBOTBG",
        title        = "{230, 200, 150}",
        text         = "{210, 190, 160}",
        textMuted    = "{130, 120, 105}",
        textAccent   = "{130, 180, 240}",
        grip         = "{180, 150, 110}",
        reset        = "{200, 180, 150}",
        headerSub    = "{220, 180, 100}",
        lockText     = "{180, 160, 120}",
        spellLocked  = "{230, 190, 110}",
        pickerSel    = "{255, 240, 140}",
        pickerOn     = "{210, 200, 180}",
        pickerOff    = "{130, 120, 110}",
        qcOff        = "{160, 140, 110}",
        qcLong       = "{230, 200, 80}",
        qcAll        = "{240, 120, 70}",
        lockActive   = "{250, 220, 90}",
        lockInactive = "{150, 135, 115}",
    },
    sod_light = {
        overlay      = 60,
        borderResref = "BFBOTFR2",
        bgResref     = "BFBOTBG2",
        title        = "{220, 230, 240}",
        text         = "{220, 225, 235}",
        textMuted    = "{150, 160, 170}",
        textAccent   = "{140, 200, 240}",
        grip         = "{180, 190, 210}",
        reset        = "{200, 210, 225}",
        headerSub    = "{170, 200, 220}",
        lockText     = "{170, 180, 200}",
        spellLocked  = "{200, 220, 240}",
        pickerSel    = "{255, 255, 180}",
        pickerOn     = "{230, 235, 245}",
        pickerOff    = "{140, 150, 165}",
        qcOff        = "{130, 140, 160}",
        qcLong       = "{200, 200, 90}",
        qcAll        = "{240, 130, 80}",
        lockActive   = "{240, 220, 110}",
        lockInactive = "{130, 140, 160}",
    },
    sod_dark = {
        overlay      = 180,
        borderResref = "BFBOTFR2",
        bgResref     = "BFBOTBG2",
        title        = "{200, 220, 235}",
        text         = "{190, 210, 225}",
        textMuted    = "{130, 145, 155}",
        textAccent   = "{120, 190, 240}",
        grip         = "{160, 180, 200}",
        reset        = "{180, 200, 220}",
        headerSub    = "{160, 200, 230}",
        lockText     = "{160, 170, 190}",
        spellLocked  = "{180, 210, 235}",
        pickerSel    = "{255, 250, 170}",
        pickerOn     = "{220, 230, 245}",
        pickerOff    = "{130, 145, 160}",
        qcOff        = "{130, 140, 165}",
        qcLong       = "{220, 220, 90}",
        qcAll        = "{240, 120, 70}",
        lockActive   = "{240, 220, 110}",
        lockInactive = "{130, 145, 165}",
    },
    bg1_light = {
        overlay      = 60,
        borderResref = "BFBOTFR3",
        bgResref     = "BFBOTBG3",
        title        = "{230, 200, 160}",
        text         = "{220, 195, 160}",
        textMuted    = "{160, 140, 120}",
        textAccent   = "{240, 180, 100}",
        grip         = "{200, 170, 130}",
        reset        = "{220, 195, 170}",
        headerSub    = "{230, 180, 90}",
        lockText     = "{190, 160, 120}",
        spellLocked  = "{240, 190, 100}",
        pickerSel    = "{255, 240, 140}",
        pickerOn     = "{230, 215, 195}",
        pickerOff    = "{150, 135, 120}",
        qcOff        = "{150, 130, 105}",
        qcLong       = "{220, 190, 80}",
        qcAll        = "{240, 130, 80}",
        lockActive   = "{250, 220, 100}",
        lockInactive = "{160, 140, 120}",
    },
    bg1_dark = {
        overlay      = 180,
        borderResref = "BFBOTFR3",
        bgResref     = "BFBOTBG3",
        title        = "{240, 200, 130}",
        text         = "{220, 190, 150}",
        textMuted    = "{150, 130, 110}",
        textAccent   = "{240, 170, 90}",
        grip         = "{190, 165, 125}",
        reset        = "{220, 190, 150}",
        headerSub    = "{230, 175, 80}",
        lockText     = "{180, 150, 115}",
        spellLocked  = "{240, 180, 90}",
        pickerSel    = "{255, 240, 140}",
        pickerOn     = "{220, 205, 180}",
        pickerOff    = "{140, 125, 110}",
        qcOff        = "{140, 120, 100}",
        qcLong       = "{225, 190, 75}",
        qcAll        = "{240, 120, 65}",
        lockActive   = "{255, 220, 95}",
        lockInactive = "{150, 135, 115}",
    },
}

-- Active palette reference; defaults to bg2_light (pixel-match current behavior).
BfBot.Theme._active = BfBot.Theme._palettes.bg2_light

--- Resolve a color key for the active theme. Returns magenta on missing key
-- to flag bugs visibly in-game during development.
function BfBot.UI_T_PENDING_MOVE(key)
    local v = BfBot.Theme._active[key]
    if v == nil then return "{255, 0, 255}" end
    return v
end
```

Note: `BfBot.UI._T` is added in Task 3 once `BfBot.UI` exists. For now the accessor lives as a placeholder to assert the module loads.

**Step 2: Wire the module into the bootstrap**

Modify `buffbot/M_BfBot.lua` — add one line between `BfBotCor` and `BfBotCls`:

```lua
Infinity_DoFile("BfBotCor")
Infinity_DoFile("BfBotThm")  -- NEW: theme palettes, before anything that reads them
Infinity_DoFile("BfBotCls")
```

**Step 3: Deploy and sanity-check module loads**

Run:
```bash
bash tools/deploy.sh
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
Infinity_DoFile("BfBotThm")
return type(BfBot.Theme._palettes) .. "/" .. tostring(BfBot.Theme._active.overlay)
'
```
Expected: `"table/0"` (active palette is bg2_light with overlay=0)

**Step 4: Commit**

```bash
git add buffbot/BfBotThm.lua buffbot/M_BfBot.lua
git commit -m "feat(theme): BfBotThm module with 6 palette tables"
```

---

## Task 3: _T() accessor + unit tests

**Files:**
- Modify: `buffbot/BfBotThm.lua` (promote accessor to `BfBot.UI._T`)
- Modify: `buffbot/BfBotTst.lua` (add `BfBot.Test.Theming`)
- Modify: `buffbot/BfBotTst.lua` (register in `RunAll`)

**Step 1: Write failing test**

Append to `buffbot/BfBotTst.lua` (before `BfBot.Test.RunAll`):

```lua
-- ============================================================
-- BfBot.Test.Theming — Theme module unit tests (issue #32)
-- ============================================================
function BfBot.Test.Theming()
    P("==== Test: Theming ====")
    local pass = 0
    local fail = 0

    local function check(label, cond)
        if cond then pass = pass + 1; P("  PASS: " .. label)
        else fail = fail + 1; P("  FAIL: " .. label) end
    end

    -- _T returns valid color for known key in default palette
    check("_T('title') returns string on default palette",
        type(BfBot.UI._T("title")) == "string" and BfBot.UI._T("title"):find("^{"))

    -- Unknown key returns magenta sentinel
    check("_T(unknown) returns magenta",
        BfBot.UI._T("nonexistent") == "{255, 0, 255}")

    -- Every palette has all 19 required keys
    local required = {"overlay","borderResref","bgResref","title","text","textMuted","textAccent",
                      "grip","reset","headerSub","lockText","spellLocked","pickerSel","pickerOn",
                      "pickerOff","qcOff","qcLong","qcAll","lockActive","lockInactive"}
    for paletteName, palette in pairs(BfBot.Theme._palettes) do
        for _, key in ipairs(required) do
            check(paletteName .. " has " .. key, palette[key] ~= nil)
        end
    end

    P(string.format("  %d pass / %d fail", pass, fail))
    return fail == 0
end
```

**Step 2: Promote placeholder to real accessor**

In `buffbot/BfBotThm.lua` rename `BfBot.UI_T_PENDING_MOVE` to `BfBot.UI._T`. `BfBot.UI` doesn't exist yet at module load time, so do:

```lua
BfBot.UI = BfBot.UI or {}   -- pre-create namespace; BfBotUI.lua will extend it
function BfBot.UI._T(key)
    local v = BfBot.Theme._active[key]
    if v == nil then return "{255, 0, 255}" end
    return v
end
```

**Step 3: Hook test into RunAll**

Modify `buffbot/BfBotTst.lua` `RunAll` — add phase between "Duration Recursion" and the summary block:

```lua
    -- Phase 14: Theming (issue #32)
    local themingOk = BfBot.Test.Theming()
    P("")
```

And in the summary:
```lua
    P("  Theming: " .. (themingOk and "PASS" or "FAIL"))
```

And in the return:
```lua
    return ... and themingOk
```

**Step 4: Deploy and run test**

```bash
bash tools/deploy.sh
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
Infinity_DoFile("BfBotThm")
Infinity_DoFile("BfBotTst")
return BfBot.Test.Theming()
'
```
Expected: `true` returned, all checks pass in output

**Step 5: Commit**

```bash
git add buffbot/BfBotThm.lua buffbot/BfBotTst.lua
git commit -m "feat(theme): _T accessor + Theming test phase"
```

---

## Task 4: Custom text style registration

**Files:**
- Modify: `buffbot/BfBotThm.lua` (add `_RegisterStyles`, `_RefreshStyles`)
- Modify: `buffbot/BfBotUI.lua` (call `_RegisterStyles` in `_OnMenusLoaded`)

**Step 1: Study engine style structure**

Run to inspect a known style:
```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
if styles and styles["normal"] then
    local s = styles["normal"]
    return string.format("font=%s point=%s color=%s",
        tostring(s.font), tostring(s.point), tostring(s.color))
end
return "styles[normal] missing"
'
```
Expected: Something like `font=NORMAL point=12 color=<number>` or similar. Record the shape.

**Step 2: Write style registration**

Add to `buffbot/BfBotThm.lua`:

```lua
-- Base sizes for our custom styles (tuned for BuffBot panel density)
BfBot.Theme._BASE_POINTS = {
    bb_normal           = 12,
    bb_button           = 14,
    bb_title            = 18,
    bb_normal_parchment = 12,
    bb_edit             = 12,
}
BfBot.Theme._STYLE_PARENTS = {
    bb_normal           = "normal",
    bb_button           = "button",
    bb_title            = "title",
    bb_normal_parchment = "normal_parchment",
    bb_edit             = "edit",
}
-- Font size multiplier: 1=small, 2=medium (default), 3=large
BfBot.Theme._SIZE_MULT = { [1] = 0.85, [2] = 1.0, [3] = 1.20 }
BfBot.Theme._fontSize = 2

--- Register bb_* custom styles by deep-copying engine styles. Called once at init.
function BfBot.Theme._RegisterStyles()
    if not styles then return end
    if not EEex or not EEex.DeepCopy then return end
    for bbName, parent in pairs(BfBot.Theme._STYLE_PARENTS) do
        if styles[parent] and not styles[bbName] then
            styles[bbName] = EEex.DeepCopy(styles[parent])
        end
    end
    BfBot.Theme._RefreshStyles()
end

--- Re-apply current font size to bb_* styles. Called on theme change + font size change.
function BfBot.Theme._RefreshStyles()
    if not styles then return end
    local mult = BfBot.Theme._SIZE_MULT[BfBot.Theme._fontSize] or 1.0
    for bbName, basePt in pairs(BfBot.Theme._BASE_POINTS) do
        if styles[bbName] then
            styles[bbName].point = math.floor(basePt * mult)
        end
    end
end
```

**Step 3: Call at menu-loaded time**

Modify `buffbot/BfBotUI.lua` — find `function BfBot.UI._OnMenusLoaded()` and add near the top:

```lua
function BfBot.UI._OnMenusLoaded()
    BfBot.Theme._RegisterStyles()  -- NEW: register bb_* styles before menu renders
    ... existing body ...
end
```

**Step 4: Deploy and verify styles exist**

```bash
bash tools/deploy.sh
```

Reload game (or hot-reload via `Infinity_DoFile("BfBotThm")` + `Infinity_DoFile("BfBotUI")` + close/open a menu to trigger OnMenusLoaded), then:

```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
BfBot.Theme._RegisterStyles()
return styles["bb_normal"] and styles["bb_button"] and styles["bb_title"] and "all registered" or "missing"
'
```
Expected: `"all registered"`

**Step 5: Commit**

```bash
git add buffbot/BfBotThm.lua buffbot/BfBotUI.lua
git commit -m "feat(theme): register bb_* custom styles with font size scaling"
```

---

## Task 5: Migrate .menu text styles to bb_*

**Files:**
- Modify: `buffbot/BuffBot.menu` (~65 `text style "X"` replacements)

**Step 1: Automated replacement**

Run these commands in sequence (order matters — longer match first):
```bash
cd /c/src/private/bg-eeex-buffbot
sed -i 's/text style "normal_parchment"/text style "bb_normal_parchment"/g' buffbot/BuffBot.menu
sed -i 's/text style "normal"/text style "bb_normal"/g' buffbot/BuffBot.menu
sed -i 's/text style "button"/text style "bb_button"/g' buffbot/BuffBot.menu
sed -i 's/text style "title"/text style "bb_title"/g' buffbot/BuffBot.menu
sed -i 's/text style "edit"/text style "bb_edit"/g' buffbot/BuffBot.menu
```

**Step 2: Verify count**

Run: `grep -c 'text style "bb_' buffbot/BuffBot.menu`
Expected: ~65 (all style references rewritten)

Run: `grep 'text style "' buffbot/BuffBot.menu | grep -v bb_ | head`
Expected: empty (no leftover engine styles)

**Step 3: Deploy and verify panel still renders**

```bash
bash tools/deploy.sh
```

In game: open BuffBot panel (F11). Expected: panel renders with identical appearance to before (since `bb_*` styles are deep copies of engine styles with same base point sizes).

If panel is blank or text missing: `bb_*` styles were not registered before panel opened. Close panel, run `BfBot.Theme._RegisterStyles()` in console, reopen panel.

**Step 4: Commit**

```bash
git add buffbot/BuffBot.menu
git commit -m "refactor(menu): migrate text styles to bb_* custom styles"
```

---

## Task 6: Migrate .menu hardcoded colors to _T() calls

**Files:**
- Modify: `buffbot/BuffBot.menu` (10 hardcoded color replacements)

**Step 1: Replace each hardcoded color with semantic _T call**

Use `Edit` tool on each line (ordered by file position):

| Line ~80  | Find: `text color lua "{50, 30, 10}"` (title) | Replace: `text color lua "BfBot.UI._T('title')"` |
| Line ~100 | Find: `text color lua "{120, 100, 70}"` | Replace: `text color lua "BfBot.UI._T('grip')"` |
| Line ~121 | Find: `text color lua "{180, 160, 130}"` | Replace: `text color lua "BfBot.UI._T('reset')"` |
| Line ~813 | Find: `text color lua "{120, 90, 20}"` | Replace: `text color lua "BfBot.UI._T('headerSub')"` |
| Line ~824 | Find: `text color lua "{150, 120, 80}"` | Replace: `text color lua "BfBot.UI._T('lockText')"` |
| Line ~1093 | Find: `text color lua "{50, 30, 10}"` (rename label) | Replace: `text color lua "BfBot.UI._T('title')"` |
| Line ~1104 | Find: `text color lua "{50, 30, 10}"` (rename edit) | Replace: `text color lua "BfBot.UI._T('text')"` |
| Line ~1170 | Find: `text color lua "{50, 30, 10}"` (import header) | Replace: `text color lua "BfBot.UI._T('title')"` |
| Line ~1295 | Find: `text color lua "{50, 30, 10}"` (config header) | Replace: `text color lua "BfBot.UI._T('title')"` |
| Line ~1385 | Find: `text color lua "{50, 30, 10}"` (variant header) | Replace: `text color lua "BfBot.UI._T('title')"` |

Note: each `{50, 30, 10}` replacement needs enough surrounding context in the `old_string` to be unique in the file.

**Step 2: Verify no hardcoded RGB colors remain in .menu**

Run: `grep 'text color lua "{' buffbot/BuffBot.menu | head`
Expected: empty (all colors now go through `_T`)

**Step 3: Deploy and verify default theme renders identically**

```bash
bash tools/deploy.sh
```

In game: open panel. Expected: appearance identical to pre-migration (default palette `bg2_light` maps `_T('title')` to `{50,30,10}` etc.).

**Step 4: Test a color change live**

```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
BfBot.Theme._active = BfBot.Theme._palettes.bg2_dark
return "applied dark"
'
```
Expected: title text in open panel visibly shifts to `{230,200,150}` within 1 frame. Reset to light: set `_active` back to `bg2_light`.

**Step 5: Commit**

```bash
git add buffbot/BuffBot.menu
git commit -m "refactor(menu): replace hardcoded colors with _T() theme lookups"
```

---

## Task 7: Migrate Lua color functions to theme

**Files:**
- Modify: `buffbot/BfBotUI.lua` (4 color functions)

**Step 1: Replace `_SpellNameColor` body**

Find in BfBotUI.lua (~line 1626):

```lua
function BfBot.UI._SpellNameColor(row)
    local entry = buffbot_spellTable[row]
    if not entry then return {50, 30, 10} end
    if entry.castable == 0 then return {140, 130, 120} end
    if entry.ovr == 1 then return {40, 80, 160} end
    if entry.lock == 1 then return {100, 70, 20} end
    return {50, 30, 10}
end
```

Replace with:

```lua
-- Helper: parse "{R, G, B}" string → {R, G, B} table (engine accepts either shape).
-- We keep the function contract returning a table because rowNumber callbacks are
-- called from .menu with table return.
local function _parseColor(s)
    local r, g, b = s:match("^%{(%d+),%s*(%d+),%s*(%d+)%}$")
    return { tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0 }
end

function BfBot.UI._SpellNameColor(row)
    local entry = buffbot_spellTable[row]
    if not entry then return _parseColor(BfBot.UI._T("text")) end
    if entry.castable == 0 then return _parseColor(BfBot.UI._T("textMuted")) end
    if entry.ovr == 1 then return _parseColor(BfBot.UI._T("textAccent")) end
    if entry.lock == 1 then return _parseColor(BfBot.UI._T("spellLocked")) end
    return _parseColor(BfBot.UI._T("text"))
end
```

**Step 2: Replace `_PickerRowColor`**

Find (~line 928):
```lua
function BfBot.UI._PickerRowColor(row)
    if row == buffbot_tgtPickerSel then
        return "{255, 255, 150}"
    end
    local name = buffbot_pickerOrder[row]
    if name and buffbot_pickerChecked[name] then
        return "{220, 220, 220}"
    end
    return "{140, 140, 140}"
end
```

Replace with:
```lua
function BfBot.UI._PickerRowColor(row)
    if row == buffbot_tgtPickerSel then
        return BfBot.UI._T("pickerSel")
    end
    local name = buffbot_pickerOrder[row]
    if name and buffbot_pickerChecked[name] then
        return BfBot.UI._T("pickerOn")
    end
    return BfBot.UI._T("pickerOff")
end
```

**Step 3: Replace `_QuickCastColor`**

Find (~line 1732):
```lua
function BfBot.UI._QuickCastColor()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return {80, 60, 40} end
    local qc = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    if qc == 1 then return {160, 120, 20} end
    if qc == 2 then return {180, 60, 30} end
    return {80, 60, 40}
end
```

Replace with:
```lua
function BfBot.UI._QuickCastColor()
    local sprite = EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
    if not sprite then return _parseColor(BfBot.UI._T("qcOff")) end
    local qc = BfBot.Persist.GetQuickCast(sprite, BfBot.UI._presetIdx)
    if qc == 1 then return _parseColor(BfBot.UI._T("qcLong")) end
    if qc == 2 then return _parseColor(BfBot.UI._T("qcAll")) end
    return _parseColor(BfBot.UI._T("qcOff"))
end
```

**Step 4: Replace `_LockColor`**

Find (~line 1650):
```lua
function BfBot.UI._LockColor(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.lock == 1 then return {230, 200, 60} end
    return {120, 100, 80}
end
```

Replace with:
```lua
function BfBot.UI._LockColor(row)
    local entry = buffbot_spellTable[row]
    if entry and entry.lock == 1 then return _parseColor(BfBot.UI._T("lockActive")) end
    return _parseColor(BfBot.UI._T("lockInactive"))
end
```

**Step 5: Deploy and sanity-check**

```bash
bash tools/deploy.sh
```

Hot-reload `BfBotUI` and confirm panel still renders normally on default theme:
```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" 'Infinity_DoFile("BfBotUI"); return "ok"'
```
Open/close panel, expect no regressions.

**Step 6: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "refactor(ui): migrate 4 color functions to _T() theme lookups"
```

---

## Task 8: Font size live refresh

**Files:**
- Modify: `buffbot/BfBotThm.lua` (add `_SetFontSize`)

**Step 1: Add setter with validation**

Append to `BfBotThm.lua`:

```lua
function BfBot.Theme._SetFontSize(n)
    n = tonumber(n) or 2
    if n < 1 then n = 1 end
    if n > 3 then n = 3 end
    BfBot.Theme._fontSize = n
    BfBot.Theme._RefreshStyles()
end

function BfBot.Theme._GetFontSize()
    return BfBot.Theme._fontSize
end
```

**Step 2: Add unit tests to Theming phase**

Extend `BfBot.Test.Theming` in BfBotTst.lua:

```lua
    -- Font size setter/getter round-trip
    BfBot.Theme._SetFontSize(1)
    check("SetFontSize(1) stores small", BfBot.Theme._GetFontSize() == 1)
    BfBot.Theme._SetFontSize(3)
    check("SetFontSize(3) stores large", BfBot.Theme._GetFontSize() == 3)
    BfBot.Theme._SetFontSize(99)
    check("SetFontSize(99) clamps to 3", BfBot.Theme._GetFontSize() == 3)
    BfBot.Theme._SetFontSize(2)  -- restore default
    
    -- bb_* style point size reflects font size setting
    if styles and styles.bb_normal then
        check("bb_normal.point = 12 at default size", styles.bb_normal.point == 12)
        BfBot.Theme._SetFontSize(3)
        check("bb_normal.point = 14 at large", styles.bb_normal.point == math.floor(12 * 1.20))
        BfBot.Theme._SetFontSize(2)
    end
```

**Step 3: Deploy and run test phase**

```bash
bash tools/deploy.sh
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
Infinity_DoFile("BfBotThm"); Infinity_DoFile("BfBotTst")
BfBot.Theme._RegisterStyles()
return BfBot.Test.Theming()
'
```
Expected: `true`

**Step 4: In-game visual verification**

Open panel. Call `BfBot.Theme._SetFontSize(3)` in console, open a new menu (rename or picker) — text should be visibly larger. Call `_SetFontSize(1)` — smaller. Reset to `2`.

**Step 5: Commit**

```bash
git add buffbot/BfBotThm.lua buffbot/BfBotTst.lua
git commit -m "feat(theme): font size live refresh with clamping"
```

---

## Task 9: Dark mode overlay labels

**Files:**
- Modify: `buffbot/BuffBot.menu` (add 6 overlay labels, one per menu)
- Modify: `buffbot/BfBotUI.lua` (`_Layout()` to position the main overlay)

**Step 1: Add overlay label to BUFFBOT_MAIN**

In `buffbot/BuffBot.menu`, find the `BUFFBOT_MAIN` menu block. After the background mosaic label (named something like `bbBg`) but before all content labels, add:

```
-- Dark mode overlay (between background and content). Invisible at overlay=0.
label
{
    name    "bbDarkOverlay"
    enabled "buffbot_isOpen"
    rectangle 5
    rectangle opacity lua "BfBot.Theme._active.overlay"
    area 340 55 540 510
}
```

Verify z-order: the label must come AFTER `bbBg` and BEFORE any text/buttons so it sits on top of the MOS but under content. Use Grep to confirm the order:

```bash
grep -n 'name.*"bb' buffbot/BuffBot.menu | head -20
```

**Step 2: Add overlay to 5 sub-menus**

Same pattern in: `BUFFBOT_TGTPICK`, `BUFFBOT_RENAME`, `BUFFBOT_SPELLPICK`, `BUFFBOT_IMPORT`, `BUFFBOT_VARIANT`. Each gets its own overlay label:

```
label
{
    name    "bbDarkOverlayTgt"    -- unique per menu
    enabled "buffbot_isOpen"
    rectangle 5
    rectangle opacity lua "BfBot.Theme._active.overlay"
    area <same area as the menu's bbTgtBg etc.>
}
```

Use suffix `Ren`, `Pick`, `Imp`, `Var` for the other 4. Position each after the menu's background mosaic, before content.

**Step 3: Position main overlay in _Layout**

Modify `buffbot/BfBotUI.lua` `_Layout()` function. Find where `Infinity_SetArea("bbBg", ...)` is called, and right after add:

```lua
Infinity_SetArea("bbDarkOverlay", px, py, pw, ph)
```

(The sub-menu overlays are fixed-position and don't need `_Layout` adjustments.)

**Step 4: Deploy and test**

```bash
bash tools/deploy.sh
```

Game on world screen:
```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
BfBot.Theme._active = BfBot.Theme._palettes.bg2_dark
return "dark applied"
'
```

Open panel. Expected: parchment dimmed noticeably. Open rename dialog — also dimmed. Reset:

```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
BfBot.Theme._active = BfBot.Theme._palettes.bg2_light
return "light applied"
'
```

**Step 5: Commit**

```bash
git add buffbot/BuffBot.menu buffbot/BfBotUI.lua
git commit -m "feat(theme): dark mode overlay labels (6 menus)"
```

---

## Task 10: Dynamic border rendering (3 SlicedRects)

**Files:**
- Modify: `buffbot/BfBotUI.lua` (register 3 SlicedRects, update render hook)

**Step 1: Find existing border registration**

Find in `buffbot/BfBotUI.lua` — search for `RegisterSlicedRect` and `BuffBot_Border`:

```bash
grep -n "RegisterSlicedRect\|BuffBot_Border" buffbot/BfBotUI.lua
```

**Step 2: Refactor to register 3 borders**

Replace the single `EEex.RegisterSlicedRect("BuffBot_Border", { ... resref = "BFBOTFR" ... })` block with a loop:

```lua
local BORDER_RESREFS = { "BFBOTFR", "BFBOTFR2", "BFBOTFR3" }
for _, resref in ipairs(BORDER_RESREFS) do
    pcall(function()
        EEex.RegisterSlicedRect("BuffBot_Border_" .. resref, {
            topLeft     = { 0,   0,   128, 128 },
            top         = { 128, 0,   256, 128 },
            topRight    = { 384, 0,   128, 128 },
            right       = { 384, 128, 128, 256 },
            bottomRight = { 384, 384, 128, 128 },
            bottom      = { 128, 384, 256, 128 },
            bottomLeft  = { 0,   384, 128, 128 },
            left        = { 0,   128, 128, 256 },
            center      = { 128, 128, 256, 256 },
            dimensions  = { 512, 512 },
            resref      = resref,
            flags       = 0,
        })
    end)
end
```

**Step 3: Update render hooks to use active theme's borderResref**

Find every `EEex.DrawSlicedRect("BuffBot_Border", ...)` call and replace with:

```lua
EEex.DrawSlicedRect("BuffBot_Border_" .. BfBot.Theme._active.borderResref, { item:getArea() })
```

There should be 6 hook callbacks (bbBgFrame, bbTgtFrame, bbRenFrame, bbPickFrame, bbImpFrame, bbVarFrame).

**Step 4: Deploy and test**

```bash
bash tools/deploy.sh
```

Restart game (border registration is done at menu-load time; hot reload may not re-run it cleanly).

```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
BfBot.Theme._active = BfBot.Theme._palettes.sod_light
return "sod applied"
'
```

Open panel. Expected: steel border (not leather). Switch to `bg1_light` — copper/wood border. Reset to `bg2_light`.

If new borders don't render: verify `BFBOTFR2.PVRZ` / `BFBOTFR3.PVRZ` exist in `override/` after deploy.

**Step 5: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(theme): dynamic border rendering with 3 SlicedRects"
```

---

## Task 11: Background MOS regeneration per theme

**Files:**
- Modify: `buffbot/BfBotUI.lua` (`_GenerateBgMOS` accepts theme)

**Step 1: Parameterize block sources by theme**

Find `_GenerateBgMOS` in BfBotUI.lua (~line 112). Currently the `blocks` table is hardcoded to PVRZ pages `0x26AC-0x26AF` (MOS9900-9903).

New PVRZ pages: we need to know what pages the engine assigns to `BFBOTBG2.PVRZ` (and split pieces if sliced) and `BFBOTBG3.PVRZ`. These are defined by the filename's trailing digits. For a single 2048x1152 source we'd need 4 files named like `BG2BG00.PVRZ` etc.

Design decision: instead of slicing into 4 files, treat the SOD/BG1 background as a SINGLE PVRZ tile of dimensions matching the panel. Resize the source PNG to e.g. 1024x1024 during conversion. Then the block list becomes:

```lua
local blocksByTheme = {
    BFBOTBG  = {  -- default: existing 4-tile layout
        { page = 0x26AC, w = 1024, h = 1024, ox = 0,    oy = 0    },
        { page = 0x26AD, w = 1024, h = 1024, ox = 1024, oy = 0    },
        { page = 0x26AE, w = 1024, h = 128,  ox = 0,    oy = 1024 },
        { page = 0x26AF, w = 1024, h = 128,  ox = 1024, oy = 1024 },
    },
    BFBOTBG2 = {  -- SOD: single tile (PVRZ page set by filename)
        { page = <sod_page>, w = 1024, h = 1024, ox = 0, oy = 0 },
        -- Tile expansion handled by base-tile loop if we make base tile 1024x1024
    },
    BFBOTBG3 = { ... },
}
```

Simpler approach: keep 4-tile base for BG2 but for new themes use a 2048x1152 single-file slice into 4 blocks at convert time — matching existing layout. That way the block list structure is identical across themes, just pointing at different PVRZ pages.

Query the engine for the PVRZ page of the new files:

```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
-- PVRZ filename "BG2BG00.PVRZ" maps to a page number. The engine derives page from the
-- file basename minus "MOS" prefix convention. Inspect via EEex_Resource_Demand or by
-- reading the PVRZ header bytes. TODO: determine exact mechanism.
return "page-query-TBD"
'
```

If page numbers are derived from the filename (e.g. `MOS9900` → 0x26AC = 9900 in hex-decimal confusion — actually `9900 / 4 + 0x2400 = 0x26AC` looks like PVRZ-page = file-number formula), then naming new PVRZs like `MOS9910-9913` for SOD and `MOS9920-9923` for BG1 makes the page math trivial.

**Step 2: Rename/regenerate PVRZ files with MOS-compatible numbering**

Update `tools/png_to_pvrz.py` to output files named:
- BG2 (existing): `MOS9900.PVRZ` - `MOS9903.PVRZ`
- SOD: `MOS9910.PVRZ` - `MOS9913.PVRZ`
- BG1: `MOS9920.PVRZ` - `MOS9923.PVRZ`

Re-run converter:
```bash
python tools/png_to_pvrz.py --theme sod
python tools/png_to_pvrz.py --theme bg1
```

**Step 3: Update block tables in _GenerateBgMOS**

```lua
local BLOCKS_BY_THEME = {
    BFBOTBG  = {
        { page = 0x26AC, w = 1024, h = 1024, ox = 0,    oy = 0    },
        { page = 0x26AD, w = 1024, h = 1024, ox = 1024, oy = 0    },
        { page = 0x26AE, w = 1024, h = 128,  ox = 0,    oy = 1024 },
        { page = 0x26AF, w = 1024, h = 128,  ox = 1024, oy = 1024 },
    },
    BFBOTBG2 = {  -- MOS9910-9913
        { page = 0x26B6, w = 1024, h = 1024, ox = 0,    oy = 0    },
        { page = 0x26B7, w = 1024, h = 1024, ox = 1024, oy = 0    },
        { page = 0x26B8, w = 1024, h = 128,  ox = 0,    oy = 1024 },
        { page = 0x26B9, w = 1024, h = 128,  ox = 1024, oy = 1024 },
    },
    BFBOTBG3 = {  -- MOS9920-9923
        { page = 0x26C0, w = 1024, h = 1024, ox = 0,    oy = 0    },
        { page = 0x26C1, w = 1024, h = 1024, ox = 1024, oy = 0    },
        { page = 0x26C2, w = 1024, h = 128,  ox = 0,    oy = 1024 },
        { page = 0x26C3, w = 1024, h = 128,  ox = 1024, oy = 1024 },
    },
}
```

Verify the page formula: `0x2400 + (file_number / 4)` — run a quick test:
```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
-- use a PVRZ test or dump to verify page mapping. Alternatively check Near Infinity.
return "TBD"
'
```

Modify `_GenerateBgMOS` to accept theme:
```lua
function BfBot.UI._GenerateBgMOS(themeBgResref)
    themeBgResref = themeBgResref or BfBot.Theme._active.bgResref
    local blocks = BLOCKS_BY_THEME[themeBgResref] or BLOCKS_BY_THEME.BFBOTBG
    ...existing logic using `blocks` instead of hardcoded table...
    -- Write to override/<themeBgResref>.MOS instead of BFBOTBG.MOS
    local f = io.open("override/" .. themeBgResref .. ".MOS", "wb")
    ...
end
```

Track generated MOSes separately:
```lua
BfBot.UI._mosW = BfBot.UI._mosW or {}
BfBot.UI._mosH = BfBot.UI._mosH or {}
-- indexed by themeBgResref
```

**Step 4: Update .menu mosaic references**

In `buffbot/BuffBot.menu`, every `mosaic "BFBOTBG"` becomes dynamic. `.menu` doesn't support `mosaic lua`, so we can't switch at runtime via mosaic. Instead, generate ALL 3 MOS files at init time, then use 3 mosaic labels in the menu with `enabled` gating:

```
label
{
    name    "bbBg_bg2"
    enabled "BfBot.Theme._active.bgResref == 'BFBOTBG'"
    mosaic "BFBOTBG"
    area 340 55 540 510
}
label
{
    name    "bbBg_sod"
    enabled "BfBot.Theme._active.bgResref == 'BFBOTBG2'"
    mosaic "BFBOTBG2"
    area 340 55 540 510
}
label
{
    name    "bbBg_bg1"
    enabled "BfBot.Theme._active.bgResref == 'BFBOTBG3'"
    mosaic "BFBOTBG3"
    area 340 55 540 510
}
```

All 3 are positioned via `Infinity_SetArea` in `_Layout()`.

Do the same for the 5 sub-menus.

**Step 5: Generate all MOSes at init**

In BfBotUI.lua, find where `_GenerateBgMOS()` is called (once at init). Change to:

```lua
for _, resref in ipairs({"BFBOTBG", "BFBOTBG2", "BFBOTBG3"}) do
    BfBot.UI._GenerateBgMOS(resref)
end
```

**Step 6: Deploy and test all 3 backgrounds**

```bash
bash tools/deploy.sh
```

Restart game. In-game console:
```lua
-- BG2 (default)
BfBot.Theme._active = BfBot.Theme._palettes.bg2_light; Infinity_DoFile("BfBotUI")  
-- SOD
BfBot.Theme._active = BfBot.Theme._palettes.sod_light
-- BG1
BfBot.Theme._active = BfBot.Theme._palettes.bg1_light
```

Open panel, expected: background changes per theme.

**Step 7: Commit**

```bash
git add buffbot/BfBotUI.lua buffbot/BuffBot.menu tools/png_to_pvrz.py buffbot/*.PVRZ
git commit -m "feat(theme): per-theme background MOS generation + mosaic gating"
```

---

## Task 12: INI persistence for Theme + FontSize

**Files:**
- Modify: `buffbot/BfBotPer.lua` (extend `_INI_DEFAULTS`)
- Modify: `buffbot/BfBotThm.lua` (add Load/Save to INI)
- Modify: `buffbot/BfBotUI.lua` (call Load at init)

**Step 1: Extend INI defaults**

Modify `buffbot/BfBotPer.lua` lines 14-26:

```lua
BfBot.Persist._INI_DEFAULTS = {
    LongThreshold = 300,
    DefaultPreset = 1,
    HotkeyCode    = 87,
    ShowTooltips  = 1,
    ConfirmCast   = 0,
    CombatInterrupt = 1,
    PanelX        = -1,
    PanelY        = -1,
    PanelW        = -1,
    PanelH        = -1,
    Theme         = "bg2_light",   -- NEW: palette key
    FontSize      = 2,             -- NEW: 1/2/3
}
```

Note: existing `GetPref` may default to numeric return. Check that it handles string values too:

```bash
grep -n "function BfBot.Persist.GetPref\|function BfBot.Persist.SetPref" buffbot/BfBotPer.lua
```

Verify `GetPref("Theme")` returns a string and `SetPref("Theme", "sod_light")` persists it. Adjust if the INI layer is number-only (may need `GetPrefString`).

**Step 2: Add Load/Save in theme module**

Append to `buffbot/BfBotThm.lua`:

```lua
function BfBot.Theme._LoadFromINI()
    local name = BfBot.Persist.GetPref("Theme") or "bg2_light"
    if type(name) ~= "string" then name = "bg2_light" end
    local palette = BfBot.Theme._palettes[name]
    if palette then
        BfBot.Theme._active = palette
    end
    BfBot.Theme._fontSize = BfBot.Persist.GetPref("FontSize") or 2
    BfBot.Theme._RefreshStyles()
end

function BfBot.Theme._SaveToINI()
    for name, palette in pairs(BfBot.Theme._palettes) do
        if palette == BfBot.Theme._active then
            BfBot.Persist.SetPref("Theme", name)
            break
        end
    end
    BfBot.Persist.SetPref("FontSize", BfBot.Theme._fontSize)
end

--- Apply a palette by name + persist.
function BfBot.Theme.Apply(name)
    local palette = BfBot.Theme._palettes[name]
    if not palette then return false end
    BfBot.Theme._active = palette
    BfBot.Theme._RefreshStyles()
    BfBot.Theme._SaveToINI()
    return true
end
```

**Step 3: Call _LoadFromINI at init**

Modify `buffbot/BfBotUI.lua` `_OnMenusLoaded`:

```lua
function BfBot.UI._OnMenusLoaded()
    BfBot.Theme._RegisterStyles()
    BfBot.Theme._LoadFromINI()   -- NEW: restore saved theme on startup
    ...existing body...
end
```

**Step 4: Deploy and verify persistence round-trip**

```bash
bash tools/deploy.sh
```

Game world screen:
```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
BfBot.Theme.Apply("sod_light")
return "applied, check baldur.ini"
'
```

Then:
```bash
grep -A5 '^\[BuffBot\]' "c:/Games/Baldur's Gate II Enhanced Edition modded/baldur.ini"
```

Expected: `Theme=sod_light` present.

Restart game, check SOD still active:
```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" 'return BfBot.Theme._active.borderResref'
```
Expected: `"BFBOTFR2"`.

Reset to default:
```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" 'BfBot.Theme.Apply("bg2_light"); return "restored"'
```

**Step 5: Commit**

```bash
git add buffbot/BfBotPer.lua buffbot/BfBotThm.lua buffbot/BfBotUI.lua
git commit -m "feat(theme): INI persistence for Theme + FontSize"
```

---

## Task 13: EEex Options API discovery (SPIKE)

**Files:** none — this is pure investigation.

**Step 1: Read the EEex Options source**

The live source is at `c:/Games/Baldur's Gate II Enhanced Edition modded/override/EEex_Options.lua`. Read lines 4940-5100 (around the `EEex_Options_AddTab` and `EEex_Options_Register` definitions).

Specifically look for:
- Signature of `EEex_Options_AddTab(label, displayEntriesProvider)` — what shape must `displayEntriesProvider` return?
- Constructors for option types: toggle, dropdown, keybind, slider
- How the tab is rendered (template instance? list?)
- Where the "label" field text comes from — strref? Plain string? Translation key?

Document findings in a throwaway file at `docs/plans/2026-04-24-eeex-options-api.md`.

**Step 2: Observe existing reference implementations**

Look at how other mods use it:
- `B3Timer.lua` (Timer tab)
- `B3Scale.lua` (UI scale tab)
- `B3EffMen.lua` (Effect Menu tab)

Find them:
```bash
ls -la "c:/Games/Baldur's Gate II Enhanced Edition modded/override/" | grep -iE "B3|EEex_"
```

Copy the shape of toggle + dropdown construction from one of these. Record in notes.

**Step 3: Build a minimal proof-of-concept**

Write a temp Lua snippet in the remote console that adds a 1-option tab:

```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" '
local ok, err = pcall(function()
    EEex_Options_AddTab("BuffBot_Test", function()
        return { ...shape derived from step 1... }
    end)
end)
return ok and "tab registered" or tostring(err)
'
```

Open the EEex Options menu in-game (via game Options → EEex Options or keybind). Expected: "BuffBot_Test" tab visible. If not visible / if error: iterate on the shape.

**Step 4: Document the API**

Update the design doc's "Open Implementation Questions" section to reflect verified API shape. Copy discovery notes into a new reference file `~/.claude/skills/bg-modding/references/eeex-options.md` via the bg-modding-learn skill, since this knowledge will be useful for future mod work.

**Step 5: No commit** — investigation only. Knowledge recorded in design doc notes file.

---

## Task 14: EEex Options tab integration

**Files:**
- Modify: `buffbot/BfBotThm.lua` (add `_RegisterOptionsTab`)
- Modify: `buffbot/M_BfBot.lua` or `BfBotUI.lua` (call registration at right time)

**Step 1: Add tab registration function**

Using API shape from Task 13, add to `BfBotThm.lua`:

```lua
function BfBot.Theme._RegisterOptionsTab()
    if not EEex_Options_AddTab then return end  -- EEex options not available
    EEex_Options_AddTab("BuffBot", function()
        return {
            -- Dark Mode toggle
            {
                type = "toggle",  -- or whatever discovery shows
                label = "Dark Mode",
                get = function() return BfBot.Theme._IsDark() end,
                set = function(v) BfBot.Theme._SetDarkMode(v) end,
            },
            -- Color Scheme dropdown
            {
                type = "dropdown",
                label = "Color Scheme",
                options = {"Baldur's Gate 2", "Siege of Dragonspear", "Baldur's Gate 1"},
                get = function() return BfBot.Theme._GetAccentIndex() end,
                set = function(i) BfBot.Theme._SetAccent(i) end,
            },
            -- Text Size dropdown
            {
                type = "dropdown",
                label = "Text Size",
                options = {"Small", "Medium", "Large"},
                get = function() return BfBot.Theme._GetFontSize() end,
                set = function(v) BfBot.Theme._SetFontSize(v); BfBot.Theme._SaveToINI() end,
            },
        }
    end)
end
```

**Step 2: Add helpers for dark/accent split**

In `BfBotThm.lua`:

```lua
function BfBot.Theme._IsDark()
    -- Active palette name ends in "_dark"
    for name, palette in pairs(BfBot.Theme._palettes) do
        if palette == BfBot.Theme._active then
            return name:match("_dark$") ~= nil and 1 or 0
        end
    end
    return 0
end

function BfBot.Theme._SetDarkMode(dark)
    local accent = BfBot.Theme._GetAccentName()
    local suffix = (dark == 1 or dark == true) and "_dark" or "_light"
    BfBot.Theme.Apply(accent .. suffix)
end

function BfBot.Theme._GetAccentName()
    -- Active palette accent prefix (bg2/sod/bg1)
    for name, palette in pairs(BfBot.Theme._palettes) do
        if palette == BfBot.Theme._active then
            return name:match("^(%w+)_")
        end
    end
    return "bg2"
end

function BfBot.Theme._GetAccentIndex()
    local accent = BfBot.Theme._GetAccentName()
    return ({bg2=1, sod=2, bg1=3})[accent] or 1
end

function BfBot.Theme._SetAccent(idx)
    local accent = ({[1]="bg2", [2]="sod", [3]="bg1"})[idx] or "bg2"
    local suffix = (BfBot.Theme._IsDark() == 1) and "_dark" or "_light"
    BfBot.Theme.Apply(accent .. suffix)
end
```

**Step 3: Register tab at startup**

In `BfBotUI.lua` `_OnMenusLoaded`:

```lua
BfBot.Theme._RegisterOptionsTab()
```

Note: register AFTER `_LoadFromINI` so the tab callbacks reflect persisted state on first open.

**Step 4: Deploy and verify tab**

```bash
bash tools/deploy.sh
```

Restart game. Open Options menu → EEex Options → look for "BuffBot" tab. Expected: 3 controls (Dark Mode toggle, Color Scheme dropdown, Text Size dropdown). Toggle Dark Mode and confirm panel dims in real time.

**Step 5: Commit**

```bash
git add buffbot/BfBotThm.lua buffbot/BfBotUI.lua
git commit -m "feat(theme): EEex Options tab with 3 controls (#32)"
```

---

## Task 15: Installer updates

**Files:**
- Modify: `buffbot/setup-buffbot.tp2`

**Step 1: Add PVRZ copy lines**

Modify the "Copy visual assets" section of `setup-buffbot.tp2`:

```weidu
// ---- Copy visual assets (parchment background, border texture, icons) ----
COPY ~buffbot/BFBOTIB.BAM~  ~override~
COPY ~buffbot/BFBOTBG.MOS~  ~override~
COPY ~buffbot/MOS9900.PVRZ~ ~override~
COPY ~buffbot/MOS9901.PVRZ~ ~override~
COPY ~buffbot/MOS9902.PVRZ~ ~override~
COPY ~buffbot/MOS9903.PVRZ~ ~override~
COPY ~buffbot/BFBOTFR.PVRZ~ ~override~
// Theme assets (issue #32)
COPY ~buffbot/MOS9910.PVRZ~ ~override~
COPY ~buffbot/MOS9911.PVRZ~ ~override~
COPY ~buffbot/MOS9912.PVRZ~ ~override~
COPY ~buffbot/MOS9913.PVRZ~ ~override~
COPY ~buffbot/BFBOTFR2.PVRZ~ ~override~
COPY ~buffbot/MOS9920.PVRZ~ ~override~
COPY ~buffbot/MOS9921.PVRZ~ ~override~
COPY ~buffbot/MOS9922.PVRZ~ ~override~
COPY ~buffbot/MOS9923.PVRZ~ ~override~
COPY ~buffbot/BFBOTFR3.PVRZ~ ~override~
COPY ~buffbot/BfBotThm.lua~ ~override~  // NEW module
COPY ~buffbot/BFBOTAB.BAM~  ~override~
```

Add `BfBotThm.lua` to the Lua module copy list (near the other `COPY ~buffbot/BfBotX.lua~` lines at the top).

**Step 2: Test installer fresh**

Simulate fresh install:
```bash
cd "c:/Games/Baldur's Gate II Enhanced Edition modded"
weidu --uninstall setup-buffbot 0 1 2>&1 | tail
weidu --install setup-buffbot 0 1 2>&1 | tail
```

Expected: no missing file errors, all COPY operations succeed.

Verify in override:
```bash
ls "c:/Games/Baldur's Gate II Enhanced Edition modded/override/" | grep -iE "BFBOT|MOS99[012]"
```
Expected: all 17 visual files present.

**Step 3: Commit**

```bash
git add buffbot/setup-buffbot.tp2
git commit -m "feat(installer): copy new theme PVRZ files + BfBotThm module"
```

---

## Task 16: In-game verification pass

**Files:** none (manual testing)

**Step 1: Full regression test**

```bash
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded/override" 'return BfBot.Test.RunAll()'
```
Expected: `true`. All 15 phases PASS (14 pre-existing + new Theming).

**Step 2: Walk through the design doc's verification checklist**

For each of the 12 items in `docs/plans/2026-04-24-panel-style-design.md` "In-game verification checklist":
1. Execute the verification
2. Mark as ✅ or ❌
3. If ❌, open a sub-issue or fix immediately

Specifically:
- Cycle through all 6 themes (3 accents × 2 modes) via Options panel. Confirm visual distinction.
- Open each sub-menu (rename, target picker, spell picker, import, variant) in each theme. Confirm text readable.
- Change text size to Small, Medium, Large. Confirm all text elements scale.
- Close game, reopen, confirm saved theme/size persist.
- Drag panel to new position, switch theme, confirm position preserved.
- Change screen resolution, confirm theme preserved.

**Step 3: Fix any issues found**

If magenta debug colors appear → missing palette key in one of the 6 palettes. Add missing key + commit.
If text unreadable in any theme → tweak palette color, commit.

**Step 4: Commit any fixes found**

```bash
git add ...
git commit -m "fix(theme): address verification findings — <specific thing>"
```

---

## Task 17: Documentation + release

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CLAUDE.md` (document theme system)
- Modify: `README.md` (if theme support is user-facing)
- Modify: `buffbot/setup-buffbot.tp2` (bump VERSION)
- Modify: `buffbot/BfBotCor.lua` (bump `BfBot.VERSION` string)

**Step 1: Bump version to v1.3.13-alpha**

Update VERSION in both:
- `buffbot/setup-buffbot.tp2` line 3: `VERSION ~v1.3.13-alpha~`
- `buffbot/BfBotCor.lua`: the `BfBot.VERSION` string

**Step 2: Add CHANGELOG entry**

Prepend to `CHANGELOG.md`:

```markdown
## v1.3.13-alpha (2026-04-24)

### Added
- **Panel themes** (#32) — three campaign-themed color schemes (BG2/SOD/BG1) each with light and dark variants, plus text size control (Small/Medium/Large). Settings live in the EEex Options menu under the "BuffBot" tab and persist in `baldur.ini`. Default is BG2 light, matching prior appearance pixel-perfect. Dark mode applies a configurable opacity overlay over the panel background. SOD adds a steel/industrial border and dark blue-teal background; BG1 adds a dark copper/wood border and crimson background. All text rendering paths (title, buttons, list columns, sub-menus) respect the active theme including the previously-fixed rename input.
```

**Step 3: Update CLAUDE.md**

Add a bullet under "Project-Specific Invariants & Gotchas":

```markdown
- **Theme system**: `BfBotThm.lua` holds 6 palettes keyed `<accent>_<mode>` (accent ∈ bg2/sod/bg1, mode ∈ light/dark). `BfBot.UI._T(key)` reads from `BfBot.Theme._active`; missing keys return magenta `"{255,0,255}"` (visible debug). `.menu` uses `bb_*` custom text styles (deep-copied from engine styles) for font-size scaling. Border rendering swaps between 3 pre-registered `SlicedRect` instances via `_T('borderResref')`. Background MOS is generated per theme (BFBOTBG/BFBOTBG2/BFBOTBG3) and selected via `.menu` mosaic label `enabled` gates. Settings in `[BuffBot]` INI section: `Theme=<palette>`, `FontSize=<1|2|3>`.
```

**Step 4: Push branch and open PR**

```bash
git push -u origin feat/panel-themes
gh pr create --title "feat(ui): customizable panel themes (#32)" --body "$(cat <<'EOF'
## Summary
- 6 themes: BG2/SOD/BG1 x light/dark, selectable via EEex Options tab
- Text size scaling (Small/Medium/Large)
- All text and border rendering paths migrated through `BfBot.UI._T()` accessor
- Default preserves current v1.3.12 appearance pixel-perfect

## Test plan
- [ ] `BfBot.Test.RunAll()` passes
- [ ] Each of 6 themes renders cleanly (no magenta debug colors)
- [ ] Text readable in all themes and sizes
- [ ] Theme persists across game restart
- [ ] Theme preserves across resolution change

Closes #32

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

**Step 5: Merge PR and tag release**

After review:
```bash
git checkout main
git pull
git tag v1.3.13-alpha
git push origin v1.3.13-alpha
gh release create v1.3.13-alpha --generate-notes
```

**Step 6: Commit docs before PR**

```bash
git add CHANGELOG.md CLAUDE.md buffbot/setup-buffbot.tp2 buffbot/BfBotCor.lua
git commit -m "chore(release): v1.3.13-alpha — panel themes"
```

---

## Risks & Escape Hatches

- **PVRZ page numbering unverified** (Task 11): if the page formula assumption is wrong, backgrounds won't render. Mitigation: in Task 11 Step 3, extract actual page numbers from the existing `MOS9900.PVRZ` header bytes first before assigning new numbers.
- **EEex Options API shape unknown** (Task 13): if `EEex_Options_AddTab` signature differs from our design, Task 14 blocks until Task 13 concludes. Mitigation: Task 13 is a pure investigation task with no code changes; worst case, tab is exposed via BuffBot's own panel instead of EEex's.
- **Border symmetry in AI-generated frames**: if the new borders look broken when stretched, cap the panel's minimum width/height to avoid corners crashing together, OR edit the border PNGs to force symmetric corner regions before re-converting to PVRZ.
