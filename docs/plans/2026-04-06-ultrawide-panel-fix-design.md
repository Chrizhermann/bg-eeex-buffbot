# Ultrawide Panel Rendering Fix (#25)

## Problem

BFBOTBG.MOS is a fixed 2048x1152 image (4 PVRZ blocks). At resolutions where 80% of screen width exceeds 2048px (e.g., 3440x1440 ultrawide), the parchment background stops short — visible black gap between parchment edge and 9-slice border frame. The border adapts fine (9-slice stretches), but the MOS renders at native pixel size.

## Solution

Generate BFBOTBG.MOS at runtime, sized to the actual screen, by tiling the existing 4 PVRZ blocks (MOS9900-9903) in a grid. MOS V2 is just a tiny header + block offsets — actual pixel data stays in the PVRZ files.

## Current MOS V2 Layout (136 bytes, 4 blocks)

```
MOS9900 (1024x1024) @ (0,0)      | MOS9901 (1024x1024) @ (1024,0)
MOS9902 (1024x128)  @ (0,1024)   | MOS9903 (1024x128)  @ (1024,1024)
```

= 2048x1152 parchment tile. PVRZ pages 9900-9903 (0x26AC-0x26AF).

## Algorithm

1. `Infinity_GetScreenSize()` → compute `pw = floor(sw * 0.8)`, `ph = floor(sh * 0.8)`
2. Tile repeats: `tilesX = ceil(pw / 2048)`, `tilesY = ceil(ph / 1152)`
3. Write MOS V2: 24-byte header + `tilesX * tilesY * 4` block entries (28 bytes each)
4. Each tile repeat references the same 4 PVRZ pages at target offset `(tx*2048, ty*1152)`

### MOS V2 Binary Format

Header (24 bytes):
- `"MOS V2  "` (8 bytes signature)
- `uint32 LE` width, height, numBlocks, offsetToBlocks (=24)

Block entry (28 bytes each):
- `uint32 LE` pvrzPage, sourceX, sourceY, width, height, targetX, targetY

## Init Timing

In `_OnMenusLoaded()`, BEFORE `EEex_Menu_LoadFile("BuffBot")`:

```
M_BfBot.lua → listeners registered
  → _OnMenusLoaded()
    → _GenerateBgMOS()        ← NEW: writes override/BFBOTBG.MOS
    → EEex_Menu_LoadFile()    ← menu picks up correctly-sized MOS
    → RegisterSlicedRect()
    → render hooks, hotkey, etc.
```

## Resolution Change

`EEex_Menu_AddWindowSizeChangedListener` → regenerate MOS + call `_Layout()`.

## File Changes

| File | Change |
|---|---|
| `BfBotUI.lua` | Add `_GenerateBgMOS()` (~30 lines), call from `_OnMenusLoaded` before menu load, add window-size-changed listener |
| `BuffBot.menu` | No change — `mosaic "BFBOTBG"` stays |
| `setup-buffbot.tp2` | No change — still deploys static MOS + PVRZ as baseline |

## Graceful Degradation

When `BfBot._noIO` is set (no LuaJIT), skip MOS generation. The deployed static 2048x1152 MOS works for standard resolutions. Ultrawide without LuaJIT gets the existing black gap — acceptable since LuaJIT is effectively required.

## Edge Cases

- **Tile seams**: Parchment is organic/uniform — seams at 2048/1152 boundaries should be nearly invisible. Can address with seamless source texture later if needed.
- **Resolution change**: Listener regenerates MOS + re-layouts. Engine should pick up new file on next render.
- **Very small screens**: `tilesX/Y = 1` → generates same 4-block MOS as the static version.
