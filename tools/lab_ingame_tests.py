"""Run BuffBot's in-game test suite from a quiet lab game, headless.

`BfBot.Test.RunAll()` is the only check that exercises the real engine --
spell data, the spellbook scan, the marshal, the innate reconciliation -- and
until now it had to be typed into the in-game console by hand, which is why it
is the gate that gets skipped. This runs it the same way the screenshot tool
takes its shots: take a lab slot, start the game hidden and muted, load a save
from the main menu, send one Lua call, then copy `buffbot_test.log` out.

    python -I tools/lab_ingame_tests.py --out docs/shots/ingame

Deploy first (`bash tools/deploy.sh`) -- the preflight refuses while the lab's
override differs from `buffbot/`, so a green run always describes this source.

Everything lab-related goes through the shared tools unchanged; see
tools/lab-screenshots.md for the prerequisites and the known failure modes.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# The lab machinery is the screenshot tool's; only what we do once the world
# screen is up differs.
lab = _load("lab_screenshots", REPO / "tools/lab_screenshots.py")
log = lab.log


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game", type=Path, default=lab.DEFAULT_GAME)
    parser.add_argument("--profile", type=Path, default=lab.DEFAULT_PROFILE)
    parser.add_argument("--save", default=lab.DEFAULT_SAVE,
                        help="save folder name in the lab profile")
    parser.add_argument("--out", type=Path, required=True,
                        help="where buffbot_test.log and the report are copied")
    parser.add_argument("--call", default="BfBot.Test.RunAll()",
                        help="the Lua to run on the world screen; a single phase "
                             "such as BfBot.Test.Persist() also works")
    parser.add_argument("--campaign", default="soa", choices=("soa", "tob", "tbp"))
    parser.add_argument("--run-seconds", type=float, default=600,
                        help="how long the suite itself may take")
    parser.add_argument("--seconds", type=float, default=1200,
                        help="hard limit for the lab game")
    parser.add_argument("--owner", default="Claude Code: BuffBot in-game suite")
    args = parser.parse_args(argv)

    game, profile = args.game.resolve(), args.profile.resolve()
    # Resolved for the same reason the screenshot tool resolves its own: the
    # game writes the journal files itself, from the game folder.
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    work = out / ".run"
    work.mkdir(exist_ok=True)
    stop = work / "stop.flag"
    stop.unlink(missing_ok=True)
    status = work / "load-status.json"
    status.unlink(missing_ok=True)

    lab.preflight(game, profile)
    lab.prepare_profile(game, profile)

    console = lab.Console(game / "override", work / "console")
    for stale in ("eeex_remote_ready.json", "eeex_remote_result.json"):
        (game / "override" / stale).unlink(missing_ok=True)

    # A log from an earlier run must not be mistaken for this one's.
    test_log = game / "buffbot_test.log"
    test_log.unlink(missing_ok=True)

    launcher = subprocess.Popen(
        [sys.executable, "-I", str(lab.LAB_TOOLS / "bg_lab_slots.py"), "run",
         str(game), str(profile), str(work / "lab-run.json"), str(args.seconds),
         "--owner", args.owner,
         "--purpose", "run BuffBot's in-game test suite", "--stop", str(stop)],
        stdout=(work / "launcher.log").open("w", encoding="utf-8"),
        stderr=subprocess.STDOUT)
    log(f"lab game starting (launcher pid {launcher.pid}); log {work / 'launcher.log'}")

    verdict: str | None = None
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
        lab.wait_for_main_menu(console, time.monotonic() + 180)

        console.call("load", REPO / "tools/lab/lab_load.lua",
                     f"{{folder=[[{args.save}]],campaign='{args.campaign}',"
                     f"status=[[{status.as_posix()}]]}}")
        loaded = lab.wait_for_save(status, {"complete"}, time.monotonic() + 120)
        log(f"save loaded after {loaded['clicks']} clicks: {args.save}")

        log(f"running {args.call} (up to {args.run_seconds:.0f}s)")
        # The suite returns false on a failing phase and raises on a broken one;
        # both are answers, so the reply is read rather than asserted.
        reply = console.send("suite", f"""
local ok, result = pcall(function() return {args.call} end)
if not ok then return "error: " .. tostring(result) end
if result == false then return "fail" end
if result == true then return "pass" end
return "returned: " .. tostring(result)
""", timeout=args.run_seconds)
        if reply.get("status") != "ok":
            raise RuntimeError(f"the suite did not answer: "
                               f"{json.dumps(reply, ensure_ascii=False)}")
        verdict = str(reply.get("returnValue"))
        log(f"suite says: {verdict} (after {reply.get('_seconds')}s)")
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

    copied = None
    if test_log.is_file():
        copied = out / "buffbot_test.log"
        shutil.copy2(test_log, copied)
        log(f"log copied to {copied} ({copied.stat().st_size // 1024} KiB)")
    else:
        log("the game wrote no buffbot_test.log")

    report = {"game": game.as_posix(), "profile": profile.as_posix(),
              "save": args.save, "call": args.call, "verdict": verdict,
              "log": copied.as_posix() if copied else None, "error": error,
              "lab_run": json.loads((work / "lab-run.json").read_text(encoding="utf-8"))
              if (work / "lab-run.json").exists() else None}
    (out / "report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    run = report["lab_run"] or {}
    log(f"guard tripped={run.get('tripped')} audio_peak={run.get('max_job_audio_peak')} "
        f"left_in_job={run.get('left_in_job')}")
    return 0 if (verdict == "pass" and not error) else 1


if __name__ == "__main__":
    raise SystemExit(main())
