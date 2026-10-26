"""Check in a quiet lab game that BfBot.Test.RunAll() leaves the player's state.

`run` takes a lab slot, starts the lab game hidden and muted, loads one of its
saves from the main menu, works through --steps (one Remote Console request
each), then stops the game and releases the slot. It uses the helpers of
tools/lab_screenshots.py, so the same prerequisites apply (tools/lab-screenshots.md).

    python -I tools/lab_runall_check.py run --game G --profile P --out OUT \
        --save "000000011-RunAll Restore Fixture" \
        --steps "wait:5,snapshot:before,runall:runall,wait:20,snapshot:after,save:000000012-RunAll Restore After"
    python -I tools/lab_runall_check.py compare OUT/before.json OUT/after.json

Steps, run in order once the save is loaded:
  fixture          give the party non-default BuffBot state: presets, quick cast,
                   locks, repeats, target tables, an include override, panel
                   geometry, font size and the leader's own export -> fixture.txt
  snapshot:NAME    the player-owned state -> NAME.json (tools/lab/lab_state.lua)
  runall:NAME      BfBot.Test.RunAll() -> NAME.log
  wait:SECONDS     let queued actions run
  save:FOLDER      SaveGame(1), then copy the save it wrote to FOLDER in the profile
  probe_ini        how this engine's baldur.ini calls behave -> probe-ini.txt

`compare` exits 0 when both snapshots are identical. --ignore-identity leaves
out the table identities, which a reload always replaces.
"""

from __future__ import annotations

import argparse
import difflib
import importlib.util
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("lab_screenshots", REPO / "tools/lab_screenshots.py")
shots = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(shots)
log = shots.log
STATE = REPO / "tools/lab/lab_state.lua"
# All BG2:EE installs without a profile of their own save here; a lab save
# must never land in it.
SHARED_SAVES = Path.home() / "OneDrive/Documents/Baldur's Gate II - Enhanced Edition/save"


def folders(path: Path) -> dict[str, int]:
    if not path.is_dir():
        return {}
    out = {}
    for p in path.iterdir():
        if p.is_dir():
            newest = max([f.stat().st_mtime_ns for f in p.iterdir() if f.is_file()]
                         or [p.stat().st_mtime_ns])
            out[p.name] = newest
    return out


def state_call(console, label: str, arguments: str, timeout: float = 60.0) -> str:
    reply = console.call(label, STATE, arguments, timeout)
    return str(reply.get("returnValue", ""))


def do_save(console, profile: Path, target_name: str) -> dict:
    save_dir = profile / "save"
    before = folders(save_dir)
    shared_before = folders(SHARED_SAVES)
    log(state_call(console, "save", "{cmd='save'}"))
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        changed = [n for n, m in folders(save_dir).items()
                   if before.get(n) != m and n != target_name]
        if changed:
            fresh = save_dir / sorted(changed)[0]
            sav = fresh / "BALDUR.SAV"
            if sav.is_file():
                size = sav.stat().st_size
                time.sleep(3)
                if sav.stat().st_size == size and size > 0:
                    break
        time.sleep(0.5)
    else:
        raise TimeoutError("the game wrote no save")
    if folders(SHARED_SAVES) != shared_before:
        raise RuntimeError("the shared BG2:EE save folder changed during the lab save")
    target = save_dir / target_name
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(fresh, target)
    log(f"saved {fresh.name} -> copied to {target.name}")
    return {"written": fresh.name, "named": target.name,
            "files": sorted(p.name for p in target.iterdir())}


def run(args: argparse.Namespace) -> int:
    game, profile, out = args.game.resolve(), args.profile.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    work = out / ".run"
    work.mkdir(exist_ok=True)
    stop = work / "stop.flag"
    stop.unlink(missing_ok=True)
    status = work / "load-status.json"
    status.unlink(missing_ok=True)

    shots.preflight(game, profile)
    shots.prepare_profile(game, profile)
    console = shots.Console(game / "override", work / "console")
    for stale in ("eeex_remote_ready.json", "eeex_remote_result.json"):
        (game / "override" / stale).unlink(missing_ok=True)
    launcher = subprocess.Popen(
        [sys.executable, "-I", str(shots.LAB_TOOLS / "bg_lab_slots.py"), "run", str(game),
         str(profile), str(work / "lab-run.json"), str(args.seconds), "--owner", args.owner,
         "--purpose", "check that BfBot.Test.RunAll restores player state", "--stop", str(stop)],
        stdout=(work / "launcher.log").open("w", encoding="utf-8"), stderr=subprocess.STDOUT)
    log(f"lab game starting (launcher pid {launcher.pid})")

    results: list[dict] = []
    error = None
    try:
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if launcher.poll() is not None:
                raise RuntimeError(f"launcher exited early ({launcher.returncode})")
            if console.ready_age() is not None:
                break
            time.sleep(1)
        else:
            raise TimeoutError("no remote-console handshake")
        shots.wait_for_main_menu(console, time.monotonic() + 180)
        console.call("load", REPO / "tools/lab/lab_load.lua",
                     f"{{folder=[[{args.save}]],campaign='soa',status=[[{status.as_posix()}]]}}")
        loaded = shots.wait_for_save(status, {"complete"}, time.monotonic() + 120)
        log(f"save loaded after {loaded['clicks']} clicks: {args.save}")
        time.sleep(3)
        outlua = out.as_posix()
        for step in [s.strip() for s in args.steps.split(",") if s.strip()]:
            kind, _, name = step.partition(":")
            log(f"step {step}")
            if kind == "probe_ini":
                text = state_call(console, "probe_ini", f"{{cmd='probe_ini',out=[[{outlua}]]}}")
            elif kind == "fixture":
                text = state_call(console, "fixture", f"{{cmd='fixture',out=[[{outlua}]]}}", 120)
            elif kind == "snapshot":
                text = state_call(console, f"snapshot-{name}",
                                  f"{{cmd='snapshot',name=[[{name}]],out=[[{outlua}]]}}", 120)
            elif kind == "runall":
                text = state_call(console, f"runall-{name}",
                                  f"{{cmd='runall',name=[[{name}]],out=[[{outlua}]]}}", 600)
            elif kind == "save":
                text = json.dumps(do_save(console, profile, name))
            elif kind == "wait":
                time.sleep(float(name))
                text = f"waited {name}s"
            else:
                raise ValueError(f"unknown step {step}")
            log(text[:4000])
            results.append({"step": step, "result": text})
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
        log((work / "launcher.log").read_text(encoding="utf-8", errors="replace").strip()[-1500:])
    lab_run = work / "lab-run.json"
    record = json.loads(lab_run.read_text(encoding="utf-8")) if lab_run.exists() else None
    report = {"game": game.as_posix(), "profile": profile.as_posix(), "save": args.save,
              "steps": results, "error": error, "lab_run": record}
    (out / "report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    record = record or {}
    log(f"guard tripped={record.get('tripped')} audio_peak={record.get('max_job_audio_peak')} "
        f"left_in_job={record.get('left_in_job')}")
    return 1 if error else 0


def flatten(snapshot: dict, ignore_identity: bool) -> dict[str, str]:
    flat: dict[str, str] = {}
    for slot, member in sorted(snapshot.get("members", {}).items()):
        for key, value in sorted(member.items()):
            if not (ignore_identity and key == "table"):
                flat[f"members.{slot}.{key}"] = value
    for key, value in sorted(snapshot.get("ini", {}).items()):
        flat[f"ini.{key}"] = value
    for name, body in sorted(snapshot.get("files", {}).items()):
        flat[f"files.{name}"] = body
    for key, value in sorted(snapshot.get("memory", {}).items()):
        if not (ignore_identity and key == "overridesTable"):
            flat[f"memory.{key}"] = value
    return flat


def compare(args: argparse.Namespace) -> int:
    a = flatten(json.loads(args.before.read_text(encoding="utf-8")), args.ignore_identity)
    b = flatten(json.loads(args.after.read_text(encoding="utf-8")), args.ignore_identity)
    lines: list[str] = []
    for key in sorted(set(a) | set(b)):
        va, vb = a.get(key, "<missing>"), b.get(key, "<missing>")
        if va == vb:
            continue
        if "\n" in va or "\n" in vb:
            lines.extend(difflib.unified_diff(va.splitlines(), vb.splitlines(),
                                              f"before:{key}", f"after:{key}", lineterm="", n=1))
        else:
            lines.append(f"{key}: {va[:300]} -> {vb[:300]}")
    summary = f"{len(set(a) | set(b))} fields compared; {'DIFFERENT' if lines else 'IDENTICAL'}"
    text = summary + "".join("\n" + line for line in lines) + "\n"
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    sys.stdout.write(text)
    return 1 if lines else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run", help="drive one lab game through --steps")
    r.add_argument("--game", type=Path, required=True)
    r.add_argument("--profile", type=Path, required=True)
    r.add_argument("--save", required=True, help="save folder name in the lab profile")
    r.add_argument("--out", type=Path, required=True)
    r.add_argument("--steps", required=True)
    r.add_argument("--seconds", type=float, default=900, help="lab time limit")
    r.add_argument("--owner", default="Claude Code: BuffBot RunAll restore check")
    c = sub.add_parser("compare", help="compare two snapshots")
    c.add_argument("before", type=Path)
    c.add_argument("after", type=Path)
    c.add_argument("--ignore-identity", action="store_true")
    c.add_argument("--out", type=Path)
    args = ap.parse_args()
    return run(args) if args.command == "run" else compare(args)


if __name__ == "__main__":
    raise SystemExit(main())
