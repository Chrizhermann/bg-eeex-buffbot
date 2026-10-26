"""Screenshots of the BuffBot panel from a quiet lab game.

One run: take a lab slot, start the lab game hidden and muted, load one of its
saves from the main menu, then capture the panel once per theme and copy the PNGs
out of the lab profile. Stops the game and releases the slot at the end.

    python -I tools/lab_screenshots.py --out docs/shots/pecca-frame

Everything lab-related goes through the shared tools, unchanged:
`bg_lab_slots.py` takes the slot and starts the game through `lab_quiet_run.py`
(hidden desktop, muted profile, job object, guards). Never start a lab game any
other way -- a visible window catches the mouse and plays sound.

The game is driven through the EEex Remote Console: Lua goes into
`<game>/override/eeex_remote_cmd.lua`, the reply comes back as
`eeex_remote_result.json`. The console answers from the main menu too, so the
save is loaded through the game's own buttons (see tools/lab/lab_load.lua).

See tools/lab-screenshots.md for the prerequisites and the known failure modes.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
LAB_TOOLS = Path.home() / ".codex/artifacts/next-batch-20261013/lab-tools"
CHRIZ_GAME = Path.home() / "Games/Chriz Easy BG"

DEFAULT_GAME = Path.home() / "CEBG-Tests/BuffBot-Dev/game"
DEFAULT_PROFILE = Path.home() / "OneDrive/Documents/BuffBot Dev"
DEFAULT_SAVE = "000000010-BuffBot Clean Baseline"
THEMES = ("bg2_light", "bg2_dark", "sod_light", "sod_dark", "bg1_light", "bg1_dark")

# The save is loaded by clicking the game's own buttons; these names must be in
# the lab's override/UI.MENU (cebg_qa_menu.py in the lab tools adds them).
QA_BUTTONS = ("BFQA_SINGLE", "FLPR_QA_START_LOAD", "FLPR_QA_LOAD_CONFIRM", "FLPR_QA_LOAD_BACK")


def log(message: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {message}", flush=True)


class Console:
    """One request at a time against the lab's EEex Remote Console."""

    def __init__(self, override: Path, journal: Path):
        self.override = override
        self.journal = journal
        self.journal.mkdir(parents=True, exist_ok=True)

    def ready_age(self) -> float | None:
        path = self.override / "eeex_remote_ready.json"
        if not path.exists():
            return None
        return time.time() - path.stat().st_mtime

    def send(self, label: str, code: str, timeout: float = 20.0) -> dict:
        cmd = self.override / "eeex_remote_cmd.lua"
        result = self.override / "eeex_remote_result.json"
        for pending in (cmd, self.override / "eeex_remote_cmd.lua.run"):
            if pending.exists():
                raise RuntimeError(f"a command is already pending: {pending.name}")
        request = uuid.uuid4().hex
        tmp = self.override / f"eeex_remote_cmd.tmp.{os.getpid()}"
        tmp.write_text(f"--@id={request}\n{code}", encoding="utf-8", newline="\n")
        result.unlink(missing_ok=True)
        os.replace(tmp, cmd)
        sent = time.time()
        reply: dict | None = None
        while time.time() - sent < timeout:
            if result.exists():
                try:
                    body = result.read_text(encoding="utf-8")
                except OSError:
                    body = ""
                if body:
                    data = json.loads(body)
                    result.unlink(missing_ok=True)
                    if data.get("id") in (None, request):
                        reply = data
                        break
            time.sleep(0.1)
        if reply is None:
            # A timeout right after a new engine call can mean the game died.
            # Never resend; the caller stops the run.
            reply = {"status": "timeout", "claimed": not cmd.exists()}
        reply["_seconds"] = round(time.time() - sent, 2)
        stamp = datetime.now(timezone.utc).strftime("%H%M%S.%f")[:-3]
        (self.journal / f"{stamp}-{label}.json").write_text(
            json.dumps({"label": label, "code": code, "reply": reply}, indent=1, ensure_ascii=False),
            encoding="utf-8")
        return reply

    def lua(self, label: str, code: str, timeout: float = 20.0) -> dict:
        reply = self.send(label, code, timeout)
        if reply.get("status") != "ok":
            raise RuntimeError(f"{label}: {json.dumps(reply, ensure_ascii=False)}")
        return reply

    def call(self, label: str, script: Path, arguments: str, timeout: float = 20.0) -> dict:
        return self.lua(label, f"return assert(loadfile([[{script.as_posix()}]]))({arguments})", timeout)


def preflight(game: Path, profile: Path) -> None:
    problems = []
    if game.resolve() == CHRIZ_GAME.resolve() or CHRIZ_GAME.resolve() in game.resolve().parents:
        problems.append(f"{game} is inside Chriz's own game; labs only")
    if not (game / "InfinityLoader.exe").is_file():
        problems.append(f"no InfinityLoader.exe in {game}")
    if (game / "steam_api64.dll").exists():
        problems.append("steam_api64.dll is active (rename it to .bgse-disabled)")
    for pending in ("eeex_remote_cmd.lua", "eeex_remote_cmd.lua.run"):
        if (game / "override" / pending).exists():
            problems.append(f"a remote command is pending: override/{pending}")
    if not (game / "override/M_EEexRC.lua").is_file():
        problems.append("the EEex Remote Console is not installed in this lab")
    if not (game / "override/M_BfBot.lua").is_file():
        problems.append("BuffBot is not installed in this lab (run tools/deploy.sh)")
    stale = [p.name for p in sorted((REPO / "buffbot").glob("*"))
             if p.is_file() and p.suffix.lower() in (".lua", ".menu", ".mos", ".bam", ".pvrz", ".tra")
             and ((game / "override" / p.name).read_bytes() if (game / "override" / p.name).is_file()
                  else None) != p.read_bytes()]
    if stale:
        problems.append(f"{len(stale)} of buffbot/'s files differ in the lab's override "
                        f"({', '.join(stale[:6])}{', ...' if len(stale) > 6 else ''}) "
                        "-- run `bash tools/deploy.sh` first")
    menu = (game / "override/UI.MENU").read_text(encoding="utf-8", errors="replace")
    missing = [name for name in QA_BUTTONS if name not in menu]
    if missing:
        problems.append("override/UI.MENU lacks the QA button names " + ", ".join(missing)
                        + " -- re-apply cebg_qa_menu.py from the lab tools")
    engine = (game / "engine.lua").read_text(encoding="utf-8", errors="replace")
    if f'"{profile.name}"' not in engine:
        problems.append(f"engine.lua does not name the profile {profile.name!r}")
    if problems:
        raise SystemExit("not ready:\n  " + "\n  ".join(problems))


# The game comes up in its intro movie and reaches the main menu only a while
# later, so the first screen the console reports is not the one we can click on.
SCREEN_PROBE = """
local seen = {}
for _, name in ipairs({"START", "START_MAIN", "START_SP", "WORLD_ACTIONBAR", "LOAD",
                       "START_OPTIONS", "POPUP_TWOBUTTON", "POPUP_FOURBUTTON"}) do
    local v = Infinity_IsMenuOnStack(name)
    if v ~= nil and v ~= false and v ~= 0 then seen[#seen + 1] = name end
end
return Infinity_GetCurrentScreenName() .. "|" .. table.concat(seen, ",")
"""


def prepare_profile(game: Path, profile: Path) -> None:
    """Make sure the lab profile is muted and windowed, through the quiet runner.

    `lab_quiet_run.py prepare` also refuses while any BG game runs anywhere, which
    since the parallel slots includes another agent's lab -- so it only runs when
    this profile actually still needs the quiet options. Waiting for the own lab is
    `bg_lab_slots.py`'s job.
    """
    spec = importlib.util.spec_from_file_location("lab_quiet_run", LAB_TOOLS / "lab_quiet_run.py")
    quiet = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(quiet)
    _, options = quiet.profile_options(profile)
    missing = {key: want for key, want in quiet.GAME_OPTIONS.items() if options.get(key) != want}
    if not missing:
        log("lab profile is already muted and windowed")
        return
    log(f"lab profile needs the quiet options {sorted(missing)}; running prepare")
    subprocess.run([sys.executable, "-I", str(LAB_TOOLS / "lab_quiet_run.py"),
                    "prepare", str(game), str(profile)], check=True)


def wait_for_main_menu(console: Console, deadline: float) -> str:
    """Wait until a start screen we can click is on the stack, logging what we see."""
    last = None
    while time.monotonic() < deadline:
        state = console.lua("screen", SCREEN_PROBE).get("returnValue", "")
        if state != last:
            log(f"  screen: {state}")
            last = state
        stack = state.split("|", 1)[1].split(",") if "|" in state else []
        if "START_MAIN" in stack or "START_SP" in stack or "START" in stack:
            return state
        time.sleep(2)
    raise TimeoutError(f"no start screen reached; last seen {last}")


def wait_for_save(path: Path, want: set[str], deadline: float) -> dict:
    last = {}
    while time.monotonic() < deadline:
        if path.exists():
            try:
                last = json.loads(path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError, PermissionError):
                time.sleep(0.1)
                continue
            if last.get("status") == "failed":
                raise RuntimeError(f"loading the save failed: {last}")
            if last.get("status") in want:
                return last
        time.sleep(0.2)
    raise TimeoutError(f"the save did not load in time; last status {last}")


def new_screenshot(folder: Path, before: dict[str, int], deadline: float) -> Path:
    while time.monotonic() < deadline:
        fresh = [p for p in folder.glob("*.png")
                 if p.is_file() and before.get(p.name) != p.stat().st_mtime_ns]
        if fresh:
            if len(fresh) != 1:
                raise RuntimeError(f"expected one new screenshot, got {[p.name for p in fresh]}")
            size = fresh[0].stat().st_size
            time.sleep(0.25)
            if size and fresh[0].stat().st_size == size:
                return fresh[0]
        time.sleep(0.15)
    raise TimeoutError("the engine wrote no screenshot; do not resend blind, check the game first")


def capture(console: Console, shot: Path, scrnshot: Path, out: Path, theme: str,
            prepare_args: str, panel: tuple[int, int] | None = None) -> dict:
    before = {p.name: p.stat().st_mtime_ns for p in scrnshot.glob("*") if p.is_file()}
    label = theme if panel is None else f"{theme}-{panel[0]}x{panel[1]}"
    size = "" if panel is None else f",panelW={panel[0]},panelH={panel[1]}"
    receipt = console.call(f"prepare-{label}", shot,
                           f"{{phase='prepare',theme='{theme}',{prepare_args}{size}}}")
    # The capture phase itself refuses to shoot too early; this is just the wait.
    time.sleep(1.5)
    console.call(f"capture-{label}", shot, "{phase='capture'}")
    native = new_screenshot(scrnshot, before, time.monotonic() + 20)
    target = out / f"{label}.png"
    shutil.copy2(native, target)
    log(f"  {label}: {target.name} ({target.stat().st_size // 1024} KiB, from {native.name})")
    return {"theme": theme, "panel": list(panel) if panel else None,
            "png": target.as_posix(), "native": native.as_posix(),
            "receipt": receipt.get("returnValue")}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game", type=Path, default=DEFAULT_GAME)
    parser.add_argument("--profile", type=Path, default=DEFAULT_PROFILE)
    parser.add_argument("--save", default=DEFAULT_SAVE, help="save folder name in the lab profile")
    parser.add_argument("--out", type=Path, required=True, help="where the PNGs are copied")
    parser.add_argument("--themes", default=",".join(THEMES))
    parser.add_argument("--slot", type=int, default=0, help="portrait slot whose tab is shown")
    parser.add_argument("--preset", type=int, default=1)
    parser.add_argument("--enable", default="", help="canonical spell rows to switch on, e.g. 1,2,3")
    parser.add_argument("--lock", type=int, help="canonical spell row to lock")
    parser.add_argument("--query", default="")
    parser.add_argument("--dialog", default="", choices=("", "targets", "picker", "rename"),
                        help="open one of BuffBot's dialogs on top of the panel")
    parser.add_argument("--dialog-row", type=int, default=1,
                        help="canonical spell row the dialog opens for")
    parser.add_argument("--panels", default="",
                        help="panel sizes to shoot per theme, e.g. 560x420,900x650; "
                             "empty keeps whatever size the lab profile saved")
    parser.add_argument("--resolution", default="1920x1080",
                        help="window size to request before capturing; empty keeps the lab's own")
    parser.add_argument("--hold", action="store_true",
                        help="stop at the main menu and keep the game alive for hand-sent Lua")
    parser.add_argument("--campaign", default="soa", choices=("soa", "tob", "tbp"),
                        help="which campaign logo to click on BG2:EE's start screen")
    parser.add_argument("--seconds", type=float, default=600, help="hard limit for the lab game")
    parser.add_argument("--owner", default="Claude Code: BuffBot UI screenshots")
    args = parser.parse_args()

    game, profile, out = args.game.resolve(), args.profile.resolve(), args.out
    themes = [t.strip() for t in args.themes.split(",") if t.strip()]
    out.mkdir(parents=True, exist_ok=True)
    work = out / ".run"
    work.mkdir(exist_ok=True)
    stop = work / "stop.flag"
    stop.unlink(missing_ok=True)
    status = work / "load-status.json"
    status.unlink(missing_ok=True)
    scrnshot = profile / "ScrnShot"
    scrnshot.mkdir(exist_ok=True)

    preflight(game, profile)
    prepare_profile(game, profile)

    console = Console(game / "override", work / "console")
    # A handshake or reply left by an earlier run must not be mistaken for this one's.
    for stale in ("eeex_remote_ready.json", "eeex_remote_result.json"):
        (game / "override" / stale).unlink(missing_ok=True)
    launcher = subprocess.Popen(
        [sys.executable, "-I", str(LAB_TOOLS / "bg_lab_slots.py"), "run", str(game), str(profile),
         str(work / "lab-run.json"), str(args.seconds), "--owner", args.owner,
         "--purpose", "capture the BuffBot panel for a UI review", "--stop", str(stop)],
        stdout=(work / "launcher.log").open("w", encoding="utf-8"), stderr=subprocess.STDOUT)
    log(f"lab game starting (launcher pid {launcher.pid}); log {work / 'launcher.log'}")

    shots: list[dict] = []
    error: str | None = None
    try:
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if launcher.poll() is not None:
                raise RuntimeError(f"the launcher exited early ({launcher.returncode}); "
                                   f"see {work / 'launcher.log'}")
            if console.ready_age() is not None:
                break
            time.sleep(1)
        else:
            raise TimeoutError("no remote-console handshake; the game did not come up")
        log("console answers; handshake written")
        wait_for_main_menu(console, time.monotonic() + 180)

        if args.hold:
            # Keep the lab at its main menu so Lua can be sent by hand, e.g. while
            # working out what a start screen is called. Ends on the stop file.
            log(f"holding the lab game; override {game / 'override'}")
            log(f"create {stop} to end it")
            while not stop.exists() and time.monotonic() < deadline + args.seconds:
                time.sleep(1)
            return 0

        console.call("load", REPO / "tools/lab/lab_load.lua",
                     f"{{folder=[[{args.save}]],campaign='{args.campaign}',"
                     f"status=[[{status.as_posix()}]]}}")
        loaded = wait_for_save(status, {"complete"}, time.monotonic() + 120)
        log(f"save loaded after {loaded['clicks']} clicks: {args.save}")

        if args.resolution:
            width, height = (int(n) for n in args.resolution.lower().split("x"))
            console.lua("resize", f"Infinity_SetScreenSize({width},{height}) return true")
            # The new size only reads back in a later request, and with Scale UI on
            # the logical size stays smaller than the PNG (1920x1080 -> 1365x768).
            time.sleep(0.5)
            logical = console.lua("size", "local w, h = Infinity_GetScreenSize() "
                                          "return w .. 'x' .. h").get("returnValue")
            log(f"window set to {width}x{height}; logical UI size {logical}")

        enable = "{" + args.enable + "}" if args.enable else "{}"
        lock = f",lock={args.lock}" if args.lock else ""
        dialog = (f",dialog='{args.dialog}',dialogRow={args.dialog_row}"
                  if args.dialog else "")
        prepare_args = (f"slot={args.slot},preset={args.preset},enable={enable}{lock},"
                        f"query=[[{args.query}]]{dialog}")
        panels: list[tuple[int, int] | None] = [None]
        if args.panels:
            panels = [tuple(int(n) for n in size.lower().split("x"))
                      for size in args.panels.split(",") if size.strip()]
        shot = REPO / "tools/lab/lab_shot.lua"
        for theme in themes:
            for panel in panels:
                shots.append(capture(console, shot, scrnshot, out, theme,
                                     prepare_args, panel))
    except Exception as problem:  # noqa: BLE001 - recorded, then the lab is stopped regardless
        error = f"{type(problem).__name__}: {problem}"
        log("FAILED " + error)
    finally:
        log("stopping the lab game")
        stop.write_text("stop\n", encoding="utf-8")
        try:
            launcher.wait(timeout=180)
        except subprocess.TimeoutExpired:
            log("the launcher did not stop in time; leaving it and its slot alone")
        log((work / "launcher.log").read_text(encoding="utf-8", errors="replace").strip()[-2000:])

    report = {"game": game.as_posix(), "profile": profile.as_posix(), "save": args.save,
              "themes": themes, "shots": shots, "error": error,
              "lab_run": json.loads((work / "lab-run.json").read_text(encoding="utf-8"))
              if (work / "lab-run.json").exists() else None}
    (out / "report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    run = report["lab_run"] or {}
    log(f"guard tripped={run.get('tripped')} audio_peak={run.get('max_job_audio_peak')} "
        f"left_in_job={run.get('left_in_job')}")
    log(f"{len(shots)} screenshots in {out}")
    return 1 if error else 0


if __name__ == "__main__":
    raise SystemExit(main())
