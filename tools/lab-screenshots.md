# Screenshots of the panel from a running lab game

`tools/lab_screenshots.py` starts a disposable lab game hidden and muted, loads one
of its saves, opens the BuffBot panel and captures it once per theme:

```bash
python -I tools/lab_screenshots.py --out /tmp/shots --enable 1,2,3,4,5 --lock 3
```

About 35 seconds for all six themes, start to stopped game. The PNGs land in
`--out` as `<theme>.png` (1920×1080), next to a `report.json` with the guard result
and, per shot, the receipt the game returned: owner, preset, and the visible rows
with their on/lock state. `--out/.run/` keeps the launcher log and every console
exchange — that is where a failed run is diagnosed.

Useful flags: `--themes bg2_light,bg1_dark` (default: all six), `--save` (folder
name in the lab profile), `--slot` / `--preset` (which tab), `--query` (search box),
`--enable` / `--lock` (canonical spell rows), `--resolution` (default 1920x1080),
`--hold` (stop at the main menu and keep the game alive so Lua can be sent by hand
— how the recipe below was worked out).

## The recipe, and why each step is what it is

- **Lab only.** Never Chriz's game (`~/Games/Chriz Easy BG`) or its profile. The lab
  game starts only through `bg_lab_slots.py`, which takes one of five slots and
  launches through `lab_quiet_run.py`: hidden desktop, muted profile, job object,
  guards. A plain `Start-Process` gives a visible window that catches his mouse and
  plays sound. No runs while he works or streams. Background:
  `~/.claude/skills/bg-modding/references/bg-labs.md`.
- **The console answers at the main menu.** The EEex Remote Console pushes its
  polling element onto `START` and `WORLD_ACTIONBAR`; in this lab `cebg_qa_menu.py`
  has additionally injected `EEexRemote.Poll()` into `START_MAIN`, `START_SP`,
  `LOAD`, `SAVE`, `SAVE_NEWSAVE` and the popups, so the game can be driven on every
  screen the load path touches.
- **The save is loaded by clicking, not by calling.** A native
  `loadScreen:LoadGame()` from the console's render callback crashes the process.
  `tools/lab/lab_load.lua` drives the game's own buttons with `Infinity_ClickItem`
  (queued SDL events), following the item-randomiser lab's `FLPRQA.lua`.
- **BG2:EE opens on the campaign screen (`START`), not on `START_MAIN`.** Its three
  logos carry no `name`, so the SoA logo is found by its BAM and checked against its
  stock rect before being clicked.
- **Single Player has to be clicked, not replaced by a menu push.** Its action is
  `startEngine:SetEngineState(1)` plus `Infinity_TransitionMenu('START_SP')`. The
  engine state is what matters: pushing `START_SP` without it leaves the load button
  bouncing back to the campaign screen instead of opening `LOAD`. The transition,
  on the other hand, sometimes settles back on `START`, so the runner pushes
  `START_SP` itself if it has not appeared.
- **Progress is read off the menu stack, not off `Infinity_GetCurrentScreenName()`.**
  The console's own `EEEX_REMOTE` menu is usually the current screen, so a
  `screen == name` gate never matches.
- **A queued click needs the menu drawn first.** Two frames is not enough —
  `SETTLE_FRAMES = 15` (half a second) between steps made it reliable.
- **Loading from the main menu leaves `START`/`START_MAIN`/`START_SP` on the stack**
  under the world, where they show through in a screenshot. The runner pops them.
- **Two phases per shot.** `Infinity_TakeScreenshot()` captures the frame drawn
  next, so `tools/lab/lab_shot.lua` prepares the panel in one request and queues the
  shot in a second one, at least 20 frames later.
- **The theme is applied with the panel closed**, then the panel is opened, so each
  shot shows a panel built under that theme. (Switching with the panel open renders
  identically — checked 2026-10-25 — so this is belt and braces.)
- **`Infinity_SetScreenSize(1920,1080)`** gives readable PNGs. With Scale UI on, the
  logical UI size becomes 1365×768 while the PNG is 1920×1080. The new size only
  reads back in a later console request.
- **Nothing is written back.** Panel state and the enabled/locked rows live in memory
  only; the game is never saved, so the lab's save folders stay as they are.
  `BfBot.Theme.Apply` does write the theme to the lab's `baldur.ini`.

## Prerequisites

The script refuses the run and names what is missing. In short:

- Every file in `buffbot/` must be byte-identical in the lab's `override/` — the
  script checks this, because a stale lab silently photographs an old build (it
  happened: the lab was on 1.10.1 while the branch was 1.11.0). Run
  `bash tools/deploy.sh` first, with the game stopped (a running game locks
  `dialog.tlk`).
- The lab needs its own `engine_name` with the matching `Documents/<engine_name>`
  profile, `steam_api64.dll` renamed to `.bgse-disabled`, EEex with LuaJIT and the
  EEex Remote Console installed.
- `override/UI.MENU` must carry the QA button names `BFQA_SINGLE`,
  `FLPR_QA_START_LOAD`, `FLPR_QA_LOAD_CONFIRM`, `FLPR_QA_LOAD_BACK`. They are not
  stock: `cebg_qa_menu.py` in the lab tools adds them, together with the extra poll
  elements. A rebuilt lab, or a mod that replaces `UI.MENU`, loses both.
- The save must hold a party member in `--slot` with a BuffBot preset `--preset`.

## When it goes wrong

- A console timeout right after a new engine call usually means the game died, not
  that it was on the wrong screen. Check `.run/launcher.log` and the process list;
  never resend blind.
- `LAB_LOAD_TIMEOUT:<step>` in `.run/load-status.json` names the step that never
  advanced, and `clicks` says how far it got. `--hold` plus hand-sent Lua is the way
  to find out why.
- `LAB_LOAD_SAVE_MISSING:...` lists the save names the LOAD screen actually offered.
- `SHOT_WAIT_FOR_RENDER` means fewer than 20 frames passed between the two phases;
  the hidden game runs at low priority, so the pause may need raising.

## Current lab

`~/CEBG-Tests/BuffBot-Dev/game`, `engine_name = "BuffBot Dev"`, profile
`~/OneDrive/Documents/BuffBot Dev`, BG2:EE 2.7.3.0 + EEex 1.3.1, four prepared
saves. Those are the script's defaults. `000000010-BuffBot Clean Baseline` has a
three-caster party; portrait slot 0 is a mage with ten rows in preset 1.
