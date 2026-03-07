# Config Export/Import Design

GitHub issue: #2

## Goal

Let users export a character's full BuffBot config (all presets + overrides) to a file and import it onto any character, even across saves or between players.

## Architecture

Full character config serialized as a Lua file in `override/bfbot_presets/`. Export uses character name as filename. Import lists available files via `io.popen("dir /b ...")`, shows a picker sub-menu, loads the selected config, runs it through existing validation/migration, and filters out spells the target character doesn't have.

## File Format

Location: `override/bfbot_presets/<CharacterName>.lua`

```lua
BfBot._import = {
    v = 5,
    ap = 1,
    presets = {
        [1] = {name="Long Buffs", cat="long", qc=0, spells={["SPWI219"]={on=1,tgt="s",pri=1}, ...}},
        [2] = {name="Boss Fight", cat="short", qc=2, spells={...}},
    },
    opts = {skip=1},
    ovr = {["SPWI112"]=1},
}
```

Directory created at install time (WeiDU `MKDIR`) and lazily via `os.execute("mkdir ...")` on first export.

## Export Flow

1. User selects character tab, clicks **Export** button
2. Config serialized to `override/bfbot_presets/<CharName>.lua`
3. Overwrites existing file silently (no confirmation)
4. Feedback: `Infinity_DisplayString("BuffBot: Exported config as '<CharName>'")`

## Import Flow

1. User selects character tab, clicks **Import** button
2. `io.popen('dir /b "override\\bfbot_presets\\*.lua" 2>nul')` lists available files
3. If no files found: feedback message, no picker
4. Picker sub-menu (BUFFBOT_IMPORT) shows available configs
5. User selects one, clicks confirm
6. File loaded via `io.open` + `loadstring` into `BfBot._import`
7. Config run through `_ValidateConfig` + `_MigrateConfig`
8. Config applied to selected character — replaces all presets and overrides
9. Spells not in character's spellbook silently dropped from each preset
10. Feedback: `"BuffBot: Imported '<name>' (N presets, M spells skipped)"`

## UI Layout

Export and Import buttons on the y=402 row (alongside Add Spell / Remove):

```
[Add Spell 120px] [Remove 120px] ... [Export 100px] [Import 100px]
```

BUFFBOT_IMPORT sub-menu: same pattern as BUFFBOT_SPELLPICKER (dark overlay, scrollable list, confirm/cancel buttons).

## Error Handling

- **Missing directory**: Lazy `os.execute("mkdir ...")` before write
- **Write failure**: `Infinity_DisplayString` error message
- **Corrupt/invalid file**: `loadstring` fails, skip with error message
- **Schema mismatch**: Existing `_MigrateConfig` handles old versions
- **Missing spells**: Silently dropped, count shown in feedback

## Filesystem APIs (Verified 2026-03-08)

All standard Lua file/OS functions work in EEex:
- `io.open` — read/write files
- `io.popen` — run shell commands, read output (directory listing)
- `os.execute` — run shell commands (mkdir)
- `os.remove` — delete files
- `os.rename` — rename files

Paths relative to game directory.

## Testing

- `BfBot.Test.ExportImport()` — export config, import to different character, verify presets transferred and missing spells dropped
- Added to `BfBot.Test.RunAll()`

## Decisions

- **Full character config** (not single preset) — simpler, covers main use case
- **Character name as filename** — no text input needed, overwrite on re-export
- **Replace on import** (not merge) — matches "load this setup" mental model
- **No versioning** — validate spells exist on import, skip what's missing
- **No confirmation dialogs** — keep it simple for alpha
