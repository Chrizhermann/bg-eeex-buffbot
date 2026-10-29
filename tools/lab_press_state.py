"""Ask a live game the two questions issue #103 cannot answer offline.

The footer buttons draw Pecca's pressed frame, which is nearly the normal
picture; the tabs force the loud selected frame. Drawing the loud frame while
a button is held needs two things the `.menu` DSL does not offer:

1. a readable "this button is being held" signal, and
2. a frame we write being the frame the engine actually draws.

This reads every field the LuaBindings expose around a button, then forces a
frame on one of them and photographs the result. A held button cannot be
staged headlessly -- nothing in EEex synthesises a mouse press -- so question 1
is answered as far as readability goes, and the picture answers question 2.

    python -I tools/lab_press_state.py --out docs/shots/press-state

Deploy first (`bash tools/deploy.sh`): the preflight refuses while the lab's
override differs from `buffbot/`, so a result always describes this source.
Lab mechanics, prerequisites and failure modes: tools/lab-screenshots.md.
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


lab = _load("lab_screenshots", REPO / "tools/lab_screenshots.py")
log = lab.log

PROBE = REPO / "tools/probe_press_state.lua"
SHOT = REPO / "tools/lab/lab_shot.lua"
# One of each kind of chrome button: a footer plate, the cast plate, a
# character tab and the close button. Each is measured inside its own
# rectangle, because a diff of the whole screen is mostly the game animating.
SUBJECTS = ("bbAdd", "bbCast", "bbC0", "bbC1", "bbP2", "bbClose")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game", type=Path, default=lab.DEFAULT_GAME)
    parser.add_argument("--profile", type=Path, default=lab.DEFAULT_PROFILE)
    parser.add_argument("--save", default=lab.DEFAULT_SAVE)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--theme", default="bg1_light")
    parser.add_argument("--campaign", default="soa", choices=("soa", "tob", "tbp"))
    parser.add_argument("--seconds", type=float, default=600)
    parser.add_argument("--owner", default="Claude Code: BuffBot press-state probe")
    args = parser.parse_args(argv)

    game, profile, out = args.game.resolve(), args.profile.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    work = out / ".run"
    work.mkdir(exist_ok=True)
    stop = work / "stop.flag"
    stop.unlink(missing_ok=True)
    status = work / "load-status.json"
    status.unlink(missing_ok=True)
    scrnshot = profile / "ScrnShot"
    scrnshot.mkdir(exist_ok=True)

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
         "--purpose", "probe the button press state", "--stop", str(stop)],
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

        # The panel has to be open before any of its items exist.
        console.call("open", SHOT, f"{{phase='prepare',theme='{args.theme}',"
                                   "slot=0,preset=1}")
        time.sleep(1.0)

        console.call("probe", PROBE, "")
        step("fields", "return BfBotProbePress_Sweep()")
        areas = {name: _area(step(f"area-{name}",
                                  f'return BfBotProbePress_Area("{name}")'))
                 for name in SUBJECTS}
        for name, box in areas.items():
            log(f"{name} occupies {box}")

        # Two shots of an unchanged screen first: the game animates while it
        # runs, so a difference only means something above this floor.
        control_a = _capture(console, scrnshot, out, "control-a")
        time.sleep(1.0)
        control_b = _capture(console, scrnshot, out, "control-b")
        floors = {name: _diff(control_a, control_b, box)
                  for name, box in areas.items()}
        for name, floor in floors.items():
            log(f"animation floor inside {name}: {floor}")

        step("cost", "return BfBotProbePress_Cost(740)")

        step("hold-all", "return BfBotProbePress_HoldAll(true)")
        time.sleep(1.0)
        held = _capture(console, scrnshot, out, "held")
        for name, box in areas.items():
            changed = _diff(control_b, held, box)
            log(f"{name} while held: {changed} (floor {floors[name]})")
            steps.append({"step": f"held-{name}", "value": changed,
                          "floor": floors[name]})
        step("release-all", "return BfBotProbePress_HoldAll(false)")
        time.sleep(1.0)
        back = _capture(console, scrnshot, out, "released")
        for name, box in areas.items():
            log(f"{name} after release: {_diff(control_b, back, box)}")
    except Exception as problem:  # noqa: BLE001 - recorded, then the lab is stopped
        error = f"{type(problem).__name__}: {problem}"
        log("FAILED " + error)
    finally:
        log("stopping the lab game")
        stop.write_text("stop\n", encoding="utf-8")
        try:
            launcher.wait(timeout=120)
        except subprocess.TimeoutExpired:
            launcher.kill()

    (out / "press-state.json").write_text(
        json.dumps({"error": error, "subjects": list(SUBJECTS), "steps": steps},
                   indent=2, ensure_ascii=False), encoding="utf-8")
    log(f"journal written to {out / 'press-state.json'}")
    return 1 if error else 0


def _area(reply: str) -> tuple[int, int, int, int]:
    """Parse "area=x,y,w,h" into a crop box."""
    if not reply.startswith("area="):
        raise RuntimeError(f"the probe did not report an area: {reply}")
    x, y, w, h = (int(piece) for piece in reply[len("area="):].split(","))
    return x, y, x + w, y + h


def _diff(first: Path, second: Path, box: tuple[int, int, int, int]) -> dict:
    """How much two shots differ inside one rectangle."""
    from PIL import Image, ImageChops

    a = Image.open(first).convert("RGB").crop(box)
    b = Image.open(second).convert("RGB").crop(box)
    delta = ImageChops.difference(a, b)
    worst = max(channel[1] for channel in delta.getextrema())
    pixels = delta.convert("L").getdata()
    changed = sum(1 for value in pixels if value > 8)
    return {"maxDelta": worst,
            "changedPixels": changed,
            "share": round(changed / max(1, len(pixels)), 4)}


def _capture(console, scrnshot: Path, out: Path, label: str) -> Path:
    """One screenshot, named, through the engine's own capture."""
    before = {p.name: p.stat().st_mtime_ns for p in scrnshot.glob("*") if p.is_file()}
    console.send(f"shoot-{label}", "Infinity_TakeScreenshot() return 'queued'")
    native = lab.new_screenshot(scrnshot, before, time.monotonic() + 20)
    target = out / f"{label}.png"
    shutil.copy2(native, target)
    return target


if __name__ == "__main__":
    raise SystemExit(main())
