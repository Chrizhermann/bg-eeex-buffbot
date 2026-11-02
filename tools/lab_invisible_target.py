"""Answer #113's one engine question in a headless lab game.

Does a BuffBot cast still reach a recipient who has been made invisible?
BuffBot queues `ReallyForceSpellRES(res, PlayerN)` rather than clicking a
target, so the engine's targeting restriction may or may not apply at all --
and if it does, which state imposes it decides what #113 has to order.

    python -I tools/lab_invisible_target.py --out docs/shots/invisible-target

Four trials, each with its own recipient so no state has to be removed:
`visible` (the control), `invisible` (op20 p2=0), `improved` (op20 p2=1) and
`sanctuary` (op153). A trial reports whether the effect count from the cast
spell rose, and what the caster's action slot held while it ran.

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

PROBE = REPO / "tools/probe_invisible_target.lua"
STATES = ("visible", "invisible", "improved", "sanctuary")
# Only the states this run has a clean recipient for actually run; see --state-a.


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
    parser.add_argument("--cast-seconds", type=float, default=14,
                        help="real seconds given to each cast")
    parser.add_argument("--seconds", type=float, default=1200,
                        help="hard limit for the lab game")
    parser.add_argument("--state-a", default="improved",
                        choices=("invisible", "improved", "sanctuary"),
                        help="the state tested on the first clean recipient")
    parser.add_argument("--state-b", default="sanctuary",
                        choices=("", "invisible", "improved", "sanctuary"),
                        help="the state tested on the second, or '' for none")
    parser.add_argument("--owner",
                        default="Claude Code: BuffBot #113 invisible-target probe")
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
            raise RuntimeError(f"{label}: {json.dumps(reply, ensure_ascii=False)}")
        log(f"{label}:\n{value}")
        return str(value)

    launcher = subprocess.Popen(
        [sys.executable, "-I", str(lab.LAB_TOOLS / "bg_lab_slots.py"), "run",
         str(game), str(profile), str(work / "lab-run.json"), str(args.seconds),
         "--owner", args.owner,
         "--purpose", "probe whether a force-cast reaches an invisible ally",
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

        # One trivial command first: if even this is claimed and unanswered,
        # the poll host is the problem, not anything the probe does.
        step("alive", 'return "alive"')

        console.call("probe", PROBE, "")
        party = step("party", "return BfBotProbe113_Party()")
        slots = [int(line.split("slot=", 1)[1].split()[0])
                 for line in party.splitlines() if "slot=" in line]
        if len(slots) < 2:
            raise RuntimeError(f"this save has {len(slots)} party member(s); "
                               "the probe needs a caster and a recipient")

        # The caster is chosen first: a three-member save has no slots to
        # spare, and assigning recipients first once left only a member with
        # nothing single-target to cast.
        picked = step("pick-cast", "return BfBotProbe113_PickCast()",
                      timeout=180)
        if not picked.startswith("caster="):
            raise RuntimeError(f"no spell to cast: {picked}")
        caster = int(picked.split("caster=", 1)[1].split()[0])

        # An applied state is never removed, so each one needs a recipient
        # that is still clean -- otherwise the confirmation read cannot tell
        # whether the application took, which is exactly how the fourth run
        # came to report a verdict about improved invisibility while the
        # sprite was only plainly invisible.
        #
        # With three party members there is one caster and two clean slots, so
        # two applied states per run. `visible` applies nothing, so it shares
        # a slot with the state tested there.
        free = [s for s in slots if s != caster]
        first, second = free[0], (free[1] if len(free) > 1 else None)
        recipients = {"visible": first, args.state_a: first}
        if second is not None and args.state_b:
            recipients[args.state_b] = second
        log(f"caster slot {caster}; {args.state_a} on slot {first}; "
            f"{args.state_b or 'nothing'} on slot {second}")

        # Which spell each state will be applied with, before any trial runs:
        # a state with no verified spell cannot be tested, and the run should
        # say that up front rather than report a verdict about a state that was
        # never on. The fourth run of this probe reported LANDED for improved
        # invisibility while the sprite was only plainly invisible.
        spells = step("state-spells", "return BfBotProbe113_FindStateSpells()",
                      timeout=120)
        # A state whose named candidates do not deliver the opcode gets the
        # sweep rather than more guessed resrefs. Sanctuary needed it: neither
        # SPPR104 nor SPPR103 delivers opcode 153 on this install.
        for line in spells.splitlines():
            name = line.split()[0] if line.split() else ""
            if name in recipients and " NONE " in line:
                opcode, param2 = {"invisible": (20, 0), "improved": (20, 1),
                                  "sanctuary": (153, -1)}[name]
                step(f"sweep-{name}",
                     f'return BfBotProbe113_SweepFor("{name}",{opcode},{param2})',
                     timeout=300)

        for state in STATES:
            slot = recipients.get(state)
            if slot is None:
                log(f"{state}: no free recipient in this party, skipped")
                verdicts.append(f"{state:<10} skipped (no spare recipient)")
                continue
            step(f"state-{state}",
                 f'return BfBotProbe113_SetState("{state}",{slot})')
            time.sleep(4)  # the applied spell has to resolve before it is read
            step(f"confirm-{state}",
                 f'return BfBotProbe113_ConfirmState("{state}")')
            step(f"cast-{state}", f'return BfBotProbe113_Cast("{state}")')
            sample_until = time.monotonic() + args.cast_seconds
            while time.monotonic() < sample_until:
                console.send(f"sample-{state}",
                             f'return BfBotProbe113_Sample("{state}")',
                             timeout=20)
                time.sleep(1.5)
            verdicts.append(step(f"result-{state}",
                                 f'return BfBotProbe113_Result("{state}")'))

        step("project-image", "return BfBotProbe113_ProjectImage()")
    except Exception as problem:  # noqa: BLE001 - recorded, then the lab stops
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
              "save": args.save, "error": error, "steps": steps,
              "verdicts": verdicts}
    (out / "invisible-target.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    readable = [f"# #113 invisible-target probe ({args.save})", ""]
    if verdicts:
        readable += ["## verdicts", ""] + [f"    {v}" for v in verdicts] + [""]
    for entry in steps:
        if entry["step"].startswith("sample-"):
            continue
        readable += [f"## {entry['step']}", "", str(entry["value"]), ""]
    (out / "invisible-target.txt").write_text("\n".join(readable),
                                              encoding="utf-8")
    log(f"report written to {out / 'invisible-target.txt'}")
    return 1 if error else 0


if __name__ == "__main__":
    raise SystemExit(main())
