"""Answer the one #101 question offline tests cannot, in a headless lab game.

The filter now accepts a summon caster only when the engine says somebody in
the party conjured it. That rests on `m_lSummonedBy` actually being set for
every summon path on this build -- if some path leaves it empty, the player's
own summons silently vanish from the panel. A lab answers it with an exact
A/B: the SAME creature file, once summoned by a real spell out of the party's
own spellbook, once spawned by CreateCreature.

    python -I tools/lab_summon_origin.py --out docs/shots/summon-origin

Deploy first (`bash tools/deploy.sh`) -- the preflight refuses while the lab's
override differs from `buffbot/`, so a result always describes this source.
Lab mechanics, prerequisites and failure modes: tools/lab-screenshots.md.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
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


lab = _load("lab_screenshots", REPO / "tools/lab_screenshots.py")
log = lab.log

PROBE = REPO / "tools/probe_summon_origin.lua"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game", type=Path, default=lab.DEFAULT_GAME)
    parser.add_argument("--profile", type=Path, default=lab.DEFAULT_PROFILE)
    parser.add_argument("--save", default=lab.DEFAULT_SAVE)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--campaign", default="soa", choices=("soa", "tob", "tbp"))
    parser.add_argument("--cast-seconds", type=float, default=20,
                        help="real seconds given to the summoning spell")
    parser.add_argument("--seconds", type=float, default=900,
                        help="hard limit for the lab game")
    parser.add_argument("--owner", default="Claude Code: BuffBot summon-origin probe")
    args = parser.parse_args(argv)

    game, profile, out = args.game.resolve(), args.profile.resolve(), args.out.resolve()
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

    steps: list[dict] = []

    def step(label: str, code: str, timeout: float = 30.0) -> str:
        reply = console.send(label, code, timeout=timeout)
        value = reply.get("returnValue")
        steps.append({"step": label, "status": reply.get("status"),
                      "value": value, "output": reply.get("output")})
        if reply.get("status") != "ok":
            raise RuntimeError(f"{label}: {json.dumps(reply, ensure_ascii=False)}")
        log(f"{label}:\n{value}")
        return str(value)

    launcher = subprocess.Popen(
        [sys.executable, "-I", str(lab.LAB_TOOLS / "bg_lab_slots.py"), "run",
         str(game), str(profile), str(work / "lab-run.json"), str(args.seconds),
         "--owner", args.owner,
         "--purpose", "probe the summon-origin linkage", "--stop", str(stop)],
        stdout=(work / "launcher.log").open("w", encoding="utf-8"),
        stderr=subprocess.STDOUT)
    log(f"lab game starting (launcher pid {launcher.pid}); log {work / 'launcher.log'}")

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

        console.call("probe", PROBE, "")
        step("before", "return BfBotProbe101_Dump()")

        # The fallback walks ~900 spell names through the resource manager.
        found = step("find-summon-spell", "return BfBotProbe101_FindSummonSpell()",
                     timeout=180)
        parts = dict(piece.split("=", 1) for piece in found.split()
                     if "=" in piece) if found.startswith("slot=") else {}
        if not parts:
            log("no summoning spell in this save's spellbooks — "
                "the A/B cannot run here")
        else:
            slot, resref, cre = parts["slot"], parts["resref"], parts["cre"]
            step("cast", f'return BfBotProbe101_Cast({slot}, "{resref}")')
            log(f"waiting {args.cast_seconds:.0f}s for the spell to resolve")
            time.sleep(args.cast_seconds)
            step("after-summon", "return BfBotProbe101_Dump()")

            step("create-control", f'return BfBotProbe101_Create("{cre}")')
            time.sleep(6)
            step("after-create", "return BfBotProbe101_Dump()")
    except Exception as problem:  # noqa: BLE001 - recorded, then the lab is stopped
        error = f"{type(problem).__name__}: {problem}"
        log("FAILED " + error)
    finally:
        log("stopping the lab game")
        stop.write_text("stop\n", encoding="utf-8")
        try:
            launcher.wait(timeout=180)
        except subprocess.TimeoutExpired:
            launcher.kill()
            log("the launcher had to be killed")

    report = {"game": game.as_posix(), "profile": profile.as_posix(),
              "save": args.save, "error": error, "steps": steps}
    (out / "summon-origin.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    readable = [f"# summon-origin probe ({args.save})", ""]
    for entry in steps:
        readable += [f"## {entry['step']}", "", str(entry["value"]), ""]
    (out / "summon-origin.txt").write_text("\n".join(readable), encoding="utf-8")
    log(f"report written to {out / 'summon-origin.txt'}")
    return 1 if error else 0


if __name__ == "__main__":
    raise SystemExit(main())
