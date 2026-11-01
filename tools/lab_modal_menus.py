"""Ask a running game what it calls a modal menu (issue #104).

`BfBot.Fast.Safe` names eight menus and asks `Infinity_IsMenuOnStack` about
each, with `EngineGlobals.popupActive()` as an engine-wide backstop that EEex
1.2.0 does not bind. A parse of BG2:EE's `UI.MENU` says those eight cannot be
the modal set: the file declares 50 modal menus, two of the eight names are
not menu names at all, and three more are not modal. Before replacing a list
with a walk, the walk has to be shown to work:

    python -I tools/lab_modal_menus.py --out docs/shots/modal-menus

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

PROBE = REPO / "tools/probe_modal_menus.lua"


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
    parser.add_argument("--seconds", type=float, default=600,
                        help="hard limit for the lab game")
    parser.add_argument("--owner",
                        default="Claude Code: BuffBot modal-menu probe")
    args = parser.parse_args(argv)

    game = args.game.resolve()
    profile = args.profile.resolve()
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

    steps: list[dict] = []

    def step(label: str, code: str, timeout: float = 60.0) -> str:
        reply = console.send(label, code, timeout=timeout)
        value = reply.get("returnValue")
        steps.append({"step": label, "status": reply.get("status"),
                      "value": value, "output": reply.get("output")})
        if reply.get("status") != "ok":
            raise RuntimeError(
                f"{label}: {json.dumps(reply, ensure_ascii=False)}")
        log(f"{label}:\n{value}")
        return str(value)

    launcher = subprocess.Popen(
        [sys.executable, "-I", str(lab.LAB_TOOLS / "bg_lab_slots.py"), "run",
         str(game), str(profile), str(work / "lab-run.json"),
         str(args.seconds), "--owner", args.owner,
         "--purpose", "probe what the engine calls a modal menu",
         "--stop", str(stop)],
        stdout=(work / "launcher.log").open("w", encoding="utf-8"),
        stderr=subprocess.STDOUT)
    log(f"lab game starting (launcher pid {launcher.pid}); "
        f"log {work / 'launcher.log'}")

    error: str | None = None
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

        console.call("probe", PROBE, "")
        # 1. Is the flag reachable at all, and under what name?
        step("fields", "return BfBotProbeModal_Fields()")
        # 2. Does the walk find a set, and how big is it?
        step("list", "return BfBotProbeModal_List()")
        # 3. What the eight shipped names resolve to on this build.
        step("shipped-names", "return BfBotProbeModal_Missing()")
        # 4. The quiet world screen: nothing modal should be up, and this
        #    build's popupActive has to agree, or the walk is not equivalent.
        step("on-stack-quiet", "return BfBotProbeModal_OnStack()")
        # 5. The case that decides it: a real modal open, both answers read.
        #    A quiet screen agreeing proves nothing -- both say "no" there.
        for modal in ("POPUP_TWOBUTTON", "OPTIONS_GAMEPLAY", "CHARACTER"):
            step(f"positive-{modal}",
                 f'return BfBotProbeModal_Positive("{modal}")')
        # 6. The shipped guard against the real engine: quiet screen permits,
        #    modal refuses -- and the same with popupActive taken away, which
        #    is the state EEex 1.2.0 leaves it in (#104).
        for modal in ("POPUP_TWOBUTTON", "CHARACTER", "OPTIONS_GAMEPLAY"):
            step(f"guard-{modal}",
                 f'return BfBotProbeModal_Guard("{modal}")')
            step(f"guard-no-popup-{modal}",
                 f'return BfBotProbeModal_GuardWithoutPopup("{modal}")')
        # 7. What a guard sweep costs, since it would run on every check.
        step("cost", "return BfBotProbeModal_Cost(50)")
    except Exception as problem:  # noqa: BLE001 - recorded, then lab stopped
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
    (out / "modal-menus.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    readable = [f"# modal-menu probe ({args.save})", ""]
    for entry in steps:
        readable += [f"## {entry['step']}", "", str(entry["value"]), ""]
    (out / "modal-menus.txt").write_text("\n".join(readable),
                                         encoding="utf-8")
    log(f"report written to {out / 'modal-menus.txt'}")
    return 1 if error else 0


if __name__ == "__main__":
    raise SystemExit(main())
