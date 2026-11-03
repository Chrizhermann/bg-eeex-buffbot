"""Answer #117's engine questions in a headless lab game.

Nothing can be cast AT a summon: BuffBot queues BCS action strings, and BCS
names `Myself` and `PlayerN` but not an arbitrary creature. EEex adds
scripting object 117, `EEex_Target("key")`, which resolves at
action-evaluation time from a table on the caster's own UDAux. Whether that
is a usable foundation turns on three things no offline test can answer:

    Q1 land      does a single-target buff queued at `EEex_Target` actually
                 reach an allied summon?
    Q2 nobody    the key resolves to nobody (the branch an expired summon
                 takes). Does the caster's queue still advance, or stall?
    Q3 two keys  two keys, two targets, one caster -- does each cast land on
                 its own? That decides whether one key per caster suffices.

    python -I tools/lab_summon_target.py --out docs/shots/summon-target

Deploy first (`bash tools/deploy.sh`) -- the preflight refuses while the
lab's override differs from `buffbot/`, so a result always describes this
source. Lab mechanics, prerequisites and failure modes:
tools/lab-screenshots.md.
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

PROBE = REPO / "tools/probe_summon_target.lua"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game", type=Path, default=lab.DEFAULT_GAME)
    parser.add_argument("--profile", type=Path, default=lab.DEFAULT_PROFILE)
    parser.add_argument("--save", default=lab.DEFAULT_SAVE)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--campaign", default="soa",
                        choices=("soa", "tob", "tbp"))
    parser.add_argument("--conjure-seconds", type=float, default=16,
                        help="real seconds given to the clone cast")
    parser.add_argument("--cast-seconds", type=float, default=16,
                        help="real seconds given to each buff cast")
    parser.add_argument("--seconds", type=float, default=1200,
                        help="hard limit for the lab game")
    parser.add_argument("--only-q1", action="store_true",
                        help="run the controls and both Q1 trials only. The "
                             "ordinary path's trial then happens while the "
                             "clone is still there: a Project Image expires "
                             "in a few minutes, and in the full order it was "
                             "gone before its turn came.")
    parser.add_argument("--owner",
                        default="Claude Code: BuffBot #117 summon-target probe")
    args = parser.parse_args(argv)

    game, profile, out = (args.game.resolve(), args.profile.resolve(),
                          args.out.resolve())
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
            raise RuntimeError(
                f"{label}: {json.dumps(reply, ensure_ascii=False)}")
        log(f"{label}:\n{value}")
        return str(value)

    def watch(trial: str, seconds: float) -> None:
        """Sample the caster's action slot while a cast runs, so a dropped
        action is distinguishable from a blocked effect."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            console.send(f"sample-{trial}",
                         f'return BfBotProbe117_Sample("{trial}")',
                         timeout=30.0)
            time.sleep(1.5)

    def clear() -> None:
        """Start every trial on a caster that is doing nothing. A blocked
        action otherwise sits in front of the next trial's cast, and that
        trial reports its own question as failed."""
        step("clear", "return BfBotProbe117_Clear()")

    launcher = subprocess.Popen(
        [sys.executable, "-I", str(lab.LAB_TOOLS / "bg_lab_slots.py"), "run",
         str(game), str(profile), str(work / "lab-run.json"),
         str(args.seconds),
         "--owner", args.owner,
         "--purpose", "probe whether a cast can be aimed at a summon",
         "--stop", str(stop)],
        stdout=(work / "launcher.log").open("w", encoding="utf-8"),
        stderr=subprocess.STDOUT)
    log(f"lab game starting (launcher pid {launcher.pid}); "
        f"log {work / 'launcher.log'}")

    error: str | None = None
    verdicts: list[str] = []
    try:
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if launcher.poll() is not None:
                raise RuntimeError(
                    f"the launcher exited early ({launcher.returncode}); "
                    f"see {work / 'launcher.log'}")
            if console.ready_age() is not None:
                break
            time.sleep(1)
        else:
            raise TimeoutError(
                "no remote-console handshake; the game did not come up")
        log("console answers; handshake written")
        lab.wait_for_main_menu(console, time.monotonic() + 180)

        console.call("load", REPO / "tools/lab/lab_load.lua",
                     f"{{folder=[[{args.save}]],campaign='{args.campaign}',"
                     f"status=[[{status.as_posix()}]]}}")
        loaded = lab.wait_for_save(status, {"complete"},
                                  time.monotonic() + 120)
        log(f"save loaded after {loaded['clicks']} clicks: {args.save}")

        # One trivial command first: if even this goes unanswered, the poll
        # host is the problem, not anything the probe does.
        step("alive", 'return "alive"')

        console.call("probe", PROBE, "")
        step("party", "return BfBotProbe117_Party()")

        # A loaded save comes up paused, and `SpellRES` needs casting time to
        # elapse: paused, it holds the action slot forever. The second run of
        # this probe measured that and read it as a targeting failure.
        step("unpause", "return BfBotProbe117_Pause(true)")

        # The clone comes first, because the buff caster must not be the
        # member a Project Image would freeze.
        clone = step("pick-clone", "return BfBotProbe117_PickClone()",
                     timeout=180)
        conjurer = None
        if clone.startswith("conjurer="):
            conjurer = int(clone.split("conjurer=", 1)[1].split()[0])
        else:
            log(f"no clone spell in this party: {clone}")

        avoid = conjurer if conjurer is not None else -1
        picked = step("pick-buff",
                      f"return BfBotProbe117_PickBuff({avoid})", timeout=180)
        if not picked.startswith("caster="):
            raise RuntimeError(f"no single-target buff to cast: {picked}")

        if conjurer is not None:
            step("conjure", "return BfBotProbe117_Conjure()")
            log(f"waiting {args.conjure_seconds:.0f}s for the clone")
            time.sleep(args.conjure_seconds)
        step("summons", "return BfBotProbe117_Summons()")
        # Does the picker offer it? A screenshot cannot show this -- planning
        # a clone does not put one on the field -- so the picker's own row
        # list is read after a real conjure.
        step("picker", "return BfBotProbe117_Picker()", timeout=120)
        step("conjurer", "return BfBotProbe117_Conjurer()")
        step("store-shape", "return BfBotProbe117_StoreShape()")
        step("compiled", "return BfBotProbe117_Compiled()")

        # Q0, both controls first. Without them "nothing happened" cannot be
        # told apart from "this caster cannot cast this spell" -- which is
        # exactly what the first run of this probe got wrong, because it
        # picked a spell the cleric knew but had not memorized.
        for action in ("ReallyForceSpellRES", "SpellRES"):
            clear()
            step(f"control-{action}",
                 f'return BfBotProbe117_Control("{action}")')
            watch(f"control-{action}", args.cast_seconds)
            verdicts.append(step(
                f"result-control-{action}",
                f'return BfBotProbe117_ResultControl("{action}")'))

        # Q1 through the forced path, which answers the mechanism.
        clear()
        step("cast-land-ReallyForceSpellRES",
             'return BfBotProbe117_CastAtClone("ReallyForceSpellRES")')
        watch("land-ReallyForceSpellRES", args.cast_seconds)
        verdicts.append(step(
            "result-land-ReallyForceSpellRES",
            'return BfBotProbe117_ResultLand("ReallyForceSpellRES")'))

        # Q2 and Q3 come BEFORE the ordinary path's trial, because that one
        # jams the caster for good: the fifth run measured a clean Q1 and
        # then two trials that were only looking at the jam it left behind.
        # `virtual_ClearActions(false)` does not get the caster back.
        #
        # The cost of that order is that the clone may expire before the last
        # trial, which is what `--only-q1` is for.
        if not args.only_q1:
            clear()
            step("cast-gone", "return BfBotProbe117_CastAtGone()")
            watch("gone", args.cast_seconds)
            verdicts.append(step("result-gone",
                                 "return BfBotProbe117_ResultGone()"))

            clear()
            step("cast-keys", "return BfBotProbe117_CastTwoKeys()")
            watch("keys", args.cast_seconds * 1.5)
            verdicts.append(step("result-keys",
                                 "return BfBotProbe117_ResultTwoKeys()"))

        # Last, because it does not come back: `SpellRES` at `EEex_Target`
        # holds the action slot forever. Same caster, same spell and same
        # action as the control that landed at `PlayerN`, so the target is
        # the only difference.
        clear()
        step("cast-land-SpellRES",
             'return BfBotProbe117_CastAtClone("SpellRES")')
        watch("land-SpellRES", args.cast_seconds)
        verdicts.append(step(
            "result-land-SpellRES",
            'return BfBotProbe117_ResultLand("SpellRES")'))
        step("clear-after", "return BfBotProbe117_Clear()")
        step("pause-after", "return BfBotProbe117_Pause(false)")

    except Exception as exc:  # noqa: BLE001 - reported, then re-raised below
        error = f"{type(exc).__name__}: {exc}"
        log(f"FAILED: {error}")
    finally:
        log("stopping the lab game")
        stop.write_text("stop\n", encoding="utf-8")
        try:
            launcher.wait(timeout=120)
        except subprocess.TimeoutExpired:
            launcher.kill()

    report = out / "report.json"
    report.write_text(json.dumps(
        {"save": args.save, "error": error, "verdicts": verdicts,
         "steps": steps}, indent=1), encoding="utf-8")
    log(f"report written to {report}")

    if verdicts:
        log("")
        log("=== what this run measured ===")
        for line in verdicts:
            log(line)

    return 1 if error else 0


if __name__ == "__main__":
    raise SystemExit(main())
