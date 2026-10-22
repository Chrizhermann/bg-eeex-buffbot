#!/usr/bin/env python3
"""eeex_globals.py — EEex Lua globals: what a pinned EEex release defines and
which ones BuffBot uses.

BuffBot once called EEex_Sprite_DisplayStringHead, which no EEex release
defines, inside a pcall that hid the error (bg-eeex-buffbot#76).
tests/test_eeex_globals.py uses this module to fail whenever BuffBot's
shipped Lua or menu code uses an EEex_* global that the pinned EEex release
does not define.

Regenerate the pinned list from the EEex source:

    git clone https://github.com/Bubb13/EEex.git <eeex>
    git -C <eeex> checkout --detach a6d21abe44e20509f5d0259ccc6c7e7f9d12b285
    python tools/eeex_globals.py generate <eeex>

`check <eeex>` rebuilds the list in memory and fails when the committed file
differs. Both commands refuse a checkout at another commit or with local
changes. `--tag`/`--commit` select another release for comparisons.
Requires lupa (tests/requirements.txt).

Defined names come from two places in the EEex tree:

* Lua: every global assignment of an EEex_* name in EEex/copy/**/*.lua. The
  files are compiled with LuaJIT (via lupa), never run, and the GSET
  instructions in the bytecode are read, so locals, comments and strings
  resolve exactly as the compiler sees them.
* Loader natives: InfinityLoaderDLL.dll and LuaBindingsCore.dll register
  their functions as LuaGlobalsPrefix (InfinityLoader.ini) + name and keep
  each name as a NUL-terminated "{}Name" format string. Main and EarlyMain
  are the loader's script names (EEex_Main.lua, EEex_EarlyMain.lua), not
  globals.

Names that only EEex.dll or LuaBindings.dll register (generated binding
types and enums such as EEex_MatchObjectFlags) are not listed: a string scan
cannot tell them from names those DLLs only read. BuffBot uses none of them;
one it starts to use fails the test until its source is added here.

BuffBot's uses are read the same way from its compiled Lua: global reads and
writes (GGET/GSET) plus string constants that are exactly an EEex_* name,
which covers _G.EEex_X, _G["EEex_X"] and rawget(_G, "EEex_X"); table keys
spelled like an EEex global count too. In .menu files, whose Lua sits inside
quoted attributes, every EEex_* word counts.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PINNED_TAG = "v1.3.1"
PINNED_COMMIT = "a6d21abe44e20509f5d0259ccc6c7e7f9d12b285"

# Loader DLLs whose "{}Name" strings are prefixed Lua globals.
LOADER_NATIVE_DLLS = ("InfinityLoaderDLL.dll", "LuaBindingsCore.dll")
# "{}Name" strings the loader passes to callScriptFile, not to lua_setglobal.
LOADER_SCRIPT_NAMES = frozenset({"Main", "EarlyMain"})

EEEX_NAME = re.compile(r"EEex_[A-Za-z0-9_]+")
_TEMPLATE = re.compile(rb"(?<=\x00)\{\}([A-Za-z][A-Za-z0-9_]*)\x00")
_PREFIX_LINE = re.compile(r"^\s*LuaGlobalsPrefix\s*=\s*(\S*)\s*$", re.M)

# Runs inside LuaJIT. Opcode numbers for GGET/GSET are probed instead of
# hard-coded, so a LuaJIT build with another bytecode numbering still works.
_ANALYZER = r"""
local jutil = require("jit.util")
local band, rshift = bit.band, bit.rshift

local function constant(f, ins)
    return jutil.funck(f, -rshift(ins, 16) - 1)
end

local function probe(source, name)
    local f = assert(loadstring(source, "=probe"))
    for pc = 1, 1000000000 do
        local ins = jutil.funcbc(f, pc)
        if not ins then break end
        if constant(f, ins) == name then return band(ins, 0xff) end
    end
    error("no instruction references " .. name)
end

local GGET = probe("return bfbot_probe_get", "bfbot_probe_get")
local GSET = probe("bfbot_probe_set = 1", "bfbot_probe_set")
assert(GGET ~= GSET, "GGET/GSET probes resolved to one opcode")

return function(source, chunkname)
    local fn, err = loadstring(source, "=" .. chunkname)
    if not fn then return false, err end
    local gets, sets, strings = {}, {}, {}
    local function addString(value)
        if type(value) == "string" then strings[#strings + 1] = value end
    end
    local function walk(f)
        for pc = 1, 1000000000 do
            local ins = jutil.funcbc(f, pc)
            if not ins then break end
            local op = band(ins, 0xff)
            if op == GGET then
                gets[#gets + 1] = constant(f, ins)
            elseif op == GSET then
                sets[#sets + 1] = constant(f, ins)
            end
        end
        for n = -1, -1000000000, -1 do
            local k = jutil.funck(f, n)
            if k == nil then break end
            if type(k) == "proto" then
                walk(k)
            elseif type(k) == "table" then
                -- Template of a table constructor: its constant keys/values.
                for key, value in pairs(k) do
                    addString(key)
                    addString(value)
                end
            else
                addString(k)
            end
        end
    end
    walk(fn)
    return true, { gets = gets, sets = sets, strings = strings }
end
"""


class LuaCompileError(ValueError):
    pass


class LuaGlobalScanner:
    """Compiles Lua chunks with LuaJIT and reports their global accesses."""

    def __init__(self) -> None:
        from lupa.luajit21 import LuaRuntime

        self._runtime = LuaRuntime(unpack_returned_tuples=True)
        # The bytecode walks would only make LuaJIT record (and abort) traces.
        self._runtime.execute("jit.off()")
        self._analyze = self._runtime.execute(_ANALYZER)

    def scan(self, source: str, chunkname: str) -> dict[str, set[str]]:
        """Return {"gets", "sets", "strings"} name sets for one chunk."""
        ok, result = self._analyze(source, chunkname)
        if not ok:
            raise LuaCompileError(f"{chunkname}: {result}")
        return {
            key: set(result[key].values()) for key in ("gets", "sets", "strings")
        }


def _add(table: dict[str, set[str]], name: str, source: str) -> None:
    table.setdefault(name, set()).add(source)


def read_lua_globals_prefix(ini_path: Path) -> str:
    match = _PREFIX_LINE.search(ini_path.read_text(encoding="utf-8", errors="replace"))
    if not match:
        raise ValueError(f"{ini_path}: no LuaGlobalsPrefix setting")
    return match.group(1).strip('"')


def lua_defined_globals(
    eeex_dir: Path, scanner: LuaGlobalScanner | None = None
) -> dict[str, set[str]]:
    """EEex_* names assigned as globals by the Lua under <eeex_dir>/copy."""
    scanner = scanner or LuaGlobalScanner()
    copy_dir = eeex_dir / "copy"
    paths = sorted(copy_dir.rglob("*.lua"), key=lambda p: p.as_posix())
    if not paths:
        raise ValueError(f"{copy_dir}: no Lua files")
    defined: dict[str, set[str]] = {}
    for path in paths:
        rel = path.relative_to(eeex_dir).as_posix()
        uses = scanner.scan(path.read_text(encoding="utf-8"), rel)
        for name in uses["sets"]:
            if EEEX_NAME.fullmatch(name):
                _add(defined, name, rel)
    return defined


def loader_native_globals(eeex_dir: Path) -> dict[str, set[str]]:
    """Prefixed functions registered by the loader DLLs under <eeex_dir>/loader."""
    loader_dir = eeex_dir / "loader"
    prefix = read_lua_globals_prefix(loader_dir / "InfinityLoader.ini")
    defined: dict[str, set[str]] = {}
    for dll in LOADER_NATIVE_DLLS:
        path = loader_dir / dll
        names = {m.decode("ascii") for m in _TEMPLATE.findall(path.read_bytes())}
        names -= LOADER_SCRIPT_NAMES
        if not names:
            raise ValueError(f"{path}: no '{{}}Name' global templates found")
        for name in names:
            _add(defined, prefix + name, path.relative_to(eeex_dir).as_posix())
    return defined


def defined_globals(
    eeex_dir: Path, scanner: LuaGlobalScanner | None = None
) -> dict[str, set[str]]:
    """All EEex_* globals the EEex tree defines, with their defining files.

    eeex_dir is the EEex/ folder of an EEex checkout.
    """
    defined = lua_defined_globals(eeex_dir, scanner)
    for name, sources in loader_native_globals(eeex_dir).items():
        for source in sources:
            _add(defined, name, source)
    return defined


def format_globals_file(defined: dict[str, set[str]], tag: str, commit: str) -> str:
    lines = [
        f"# EEex_* Lua globals defined by EEex {tag}",
        f"# tag: {tag}",
        f"# commit: {commit}",
        "# source: https://github.com/Bubb13/EEex",
        "# generated by tools/eeex_globals.py; do not edit by hand. Regenerate:",
        "#   python tools/eeex_globals.py generate <EEex checkout at that commit>",
        "# format: name<TAB>defining files, relative to EEex/",
    ]
    for name in sorted(defined):
        lines.append(name + "\t" + " ".join(sorted(defined[name])))
    return "\n".join(lines) + "\n"


def read_globals_file(path: Path) -> tuple[dict[str, str], dict[str, list[str]]]:
    """Return ({tag, commit}, {name: defining files}) from a generated list."""
    meta: dict[str, str] = {}
    names: dict[str, list[str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            key, sep, value = line[1:].strip().partition(": ")
            if sep and key in ("tag", "commit"):
                meta[key] = value.strip()
            continue
        if not line.strip():
            continue
        name, _, sources = line.partition("\t")
        if not EEEX_NAME.fullmatch(name) or not sources:
            raise ValueError(f"{path}: malformed line {line!r}")
        if name in names:
            raise ValueError(f"{path}: duplicate name {name}")
        names[name] = sources.split(" ")
    return meta, names


def buffbot_sources(root: Path = ROOT) -> list[Path]:
    """BuffBot's shipped Lua and menu files."""
    mod = root / "buffbot"
    return sorted(mod.glob("*.lua")) + sorted(mod.glob("*.menu"))


def eeex_references(
    paths: list[Path], scanner: LuaGlobalScanner | None = None
) -> dict[str, set[str]]:
    """EEex_* globals used by the given Lua/menu files: {name: {"file (how)"}}."""
    scanner = scanner or LuaGlobalScanner()
    used: dict[str, set[str]] = {}
    for path in paths:
        source = path.read_text(encoding="utf-8")
        if path.suffix == ".menu":
            for name in EEEX_NAME.findall(source):
                _add(used, name, f"{path.name} (menu)")
            continue
        uses = scanner.scan(source, path.name)
        # Global names are string constants too; label only the other strings.
        name_strings = uses["strings"] - uses["gets"] - uses["sets"]
        for names, label in ((uses["gets"], "read"), (uses["sets"], "write"),
                             (name_strings, "name string")):
            for name in names:
                if EEEX_NAME.fullmatch(name):
                    _add(used, name, f"{path.name} ({label})")
    return used


class CheckoutError(ValueError):
    pass


def verify_checkout(checkout: Path, commit: str) -> None:
    """Refuse a checkout at another commit or with local changes."""
    def git(*args: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(checkout), *args], capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise CheckoutError(f"{checkout}: git {' '.join(args)} failed: "
                                f"{result.stderr.strip()}")
        return result.stdout.strip()

    head = git("rev-parse", "HEAD")
    if head != commit:
        raise CheckoutError(f"{checkout} is at {head}, expected {commit}")
    if git("status", "--porcelain", "--untracked-files=all"):
        raise CheckoutError(f"{checkout} has local changes")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="List the EEex_* globals an EEex release defines.")
    parser.add_argument("command", choices=("generate", "check"))
    parser.add_argument("checkout", type=Path, help="EEex git checkout")
    parser.add_argument("--tag", default=PINNED_TAG)
    parser.add_argument("--commit", default=PINNED_COMMIT)
    parser.add_argument("--output", type=Path,
                        help="default: tests/fixtures/eeex-globals-<tag>.txt")
    args = parser.parse_args(argv)

    output = args.output or ROOT / "tests" / "fixtures" / f"eeex-globals-{args.tag}.txt"
    try:
        verify_checkout(args.checkout, args.commit)
    except CheckoutError as exc:
        print(exc, file=sys.stderr)
        return 2
    defined = defined_globals(args.checkout / "EEex")
    rendered = format_globals_file(defined, args.tag, args.commit)
    if args.command == "generate":
        output.write_text(rendered, encoding="utf-8", newline="\n")
        print(f"wrote {output} ({len(defined)} names)")
        return 0
    current = output.read_text(encoding="utf-8") if output.exists() else ""
    if current != rendered:
        print(f"{output} differs from EEex {args.tag} ({args.commit})", file=sys.stderr)
        return 1
    print(f"{output} matches EEex {args.tag} ({args.commit}, {len(defined)} names)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
