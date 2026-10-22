"""BuffBot may only use EEex_* globals that the pinned EEex release defines.

BuffBot v1.10.0 called EEex_Sprite_DisplayStringHead, which no EEex release
defines; a pcall hid the error and the combat-stop notice never appeared
(bg-eeex-buffbot#76). tests/fixtures/eeex-globals-v1.3.1.txt lists what EEex
v1.3.1 defines. It is generated from the EEex source at that tag by
tools/eeex_globals.py, which documents how to regenerate it.
"""

from __future__ import annotations

import faulthandler
import importlib.util
from pathlib import Path
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]
GLOBALS_FILE = ROOT / "tests/fixtures/eeex-globals-v1.3.1.txt"

_spec = importlib.util.spec_from_file_location(
    "eeex_globals", ROOT / "tools/eeex_globals.py"
)
eeex_globals = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(eeex_globals)

# EEex_* names BuffBot may use although EEex v1.3.1 does not define them,
# each with the reason. Only for deliberate, guarded probes (for example of a
# newer EEex function behind `type(...) == "function"`). Stale entries fail.
ALLOWED_UNDEFINED: dict[str, str] = {
    "EEex_CChitin": (
        "Optional generated native class binding used by EEex's own UncapFPS adapter; "
        "not enumerated in the pinned Lua/loader export list. Fast-forward probes it "
        "under pcall, validates the numeric rate, and declines without a binding."
    ),
}


@pytest.fixture(scope="module")
def scanner():
    return eeex_globals.LuaGlobalScanner()


@pytest.fixture(scope="module")
def pinned() -> dict[str, list[str]]:
    return eeex_globals.read_globals_file(GLOBALS_FILE)[1]


def test_pinned_list_is_generated_from_eeex_v1_3_1() -> None:
    meta, names = eeex_globals.read_globals_file(GLOBALS_FILE)

    assert meta == {
        "tag": "v1.3.1",
        "commit": "a6d21abe44e20509f5d0259ccc6c7e7f9d12b285",
    }
    assert (meta["tag"], meta["commit"]) == (
        eeex_globals.PINNED_TAG, eeex_globals.PINNED_COMMIT)
    assert list(names) == sorted(names)
    # Exactly what the generator writes (no hand edits).
    defined = {name: set(sources) for name, sources in names.items()}
    assert eeex_globals.format_globals_file(
        defined, meta["tag"], meta["commit"]
    ) == GLOBALS_FILE.read_text(encoding="utf-8")


def test_pinned_list_has_both_sources_and_none_of_the_missing_names(pinned) -> None:
    sources = {source for files in pinned.values() for source in files}
    assert pinned["EEex_Sprite_GetInPortrait"] == ["copy/EEex_scripts/EEex_Sprite.lua"]
    assert pinned["EEex_Active"] == ["copy/EEex_scripts/EEex_Main.lua"]
    assert pinned["EEex_BAnd"] == ["loader/InfinityLoaderDLL.dll"]
    assert pinned["EEex_NewUD"] == ["loader/LuaBindingsCore.dll"]
    assert {"loader/InfinityLoaderDLL.dll", "loader/LuaBindingsCore.dll"} <= sources
    assert sum(1 for files in pinned.values() if files[0].startswith("copy/")) > 800

    for name in (
        "EEex_Sprite_DisplayStringHead",  # never existed (#76)
        "EEex_GetCurrentArea",
        "EEex_Area_GetCurrent",
        "EEex_Main",  # loader script names, not globals
        "EEex_EarlyMain",
        "EEex_Utility_AugmentIterator",  # only inside a --[[ ]] comment
        "EEex_Sprite_Hook_CheckBlockWeaponHit",  # removed after v1.2.0
    ):
        assert name not in pinned, name


def test_buffbot_uses_only_eeex_globals_the_pinned_release_defines(
    scanner, pinned
) -> None:
    used = eeex_globals.eeex_references(eeex_globals.buffbot_sources(ROOT), scanner)
    undefined = {
        name: sorted(places) for name, places in used.items() if name not in pinned
    }

    unexpected = {
        name: places for name, places in undefined.items()
        if name not in ALLOWED_UNDEFINED
    }
    assert not unexpected, (
        "BuffBot uses EEex globals that EEex v1.3.1 does not define:\n"
        + "\n".join(f"  {name}: {', '.join(places)}"
                    for name, places in sorted(unexpected.items()))
    )
    stale = sorted(set(ALLOWED_UNDEFINED) - set(undefined))
    assert not stale, f"ALLOWED_UNDEFINED names no longer needed: {stale}"


def test_scan_covers_every_shipped_module_and_its_eeex_surface(scanner) -> None:
    paths = eeex_globals.buffbot_sources(ROOT)
    names = {path.name for path in paths}
    assert {"M_BfBot.lua", "BfBotCor.lua", "BfBotExe.lua", "BfBotTst.lua",
            "BuffBot.menu"} <= names

    used = eeex_globals.eeex_references(paths, scanner)
    assert {
        "EEex_Active",                      # M_BfBot.lua guard
        "EEex_Sprite_GetInPortrait",
        "EEex_BAnd",                        # loader native
        "EEex_NewUD", "EEex_FreeUD",        # LuaBindingsCore natives
        "EEex_RunWithStackManager",
        "EEex_Area_GetVisible",             # BfBotTst area probe
        "EEex_EngineGlobal_CBaldurChitin",  # rawget(_G, "...") lookups
    } <= set(used)
    assert "EEex_Sprite_DisplayStringHead" not in used
    assert "BfBotPer.lua (name string)" in used["EEex_EngineGlobal_CBaldurChitin"]


def test_scan_sees_reads_writes_and_name_strings_but_not_comments(
    scanner, tmp_path
) -> None:
    source = tmp_path / "Sample.lua"
    source.write_text(
        """
-- EEex_InLineComment()
--[[ EEex_InBlockComment() ]]
local text = "calls EEex_InsideText() in a sentence"
local action = 'EEex_LuaAction("BfBot.Exec._Advance([[p0]])")'
local EEex_LocalAlias = EEex_RealRead
local function EEex_LocalFunction() end
EEex_Written = EEex_LocalAlias
local lookup = rawget(_G, "EEex_ByName") or _G.EEex_ByField
pcall(function() EEex_InsidePcall() end)
""",
        encoding="utf-8",
    )
    menu = tmp_path / "Sample.menu"
    menu.write_text('enabled "EEex_FromMenu() ~= nil"\n', encoding="utf-8")

    used = eeex_globals.eeex_references([source, menu], scanner)

    assert set(used) == {
        "EEex_RealRead", "EEex_Written", "EEex_ByName", "EEex_ByField",
        "EEex_InsidePcall", "EEex_FromMenu",
    }
    assert used["EEex_RealRead"] == {"Sample.lua (read)"}
    assert used["EEex_Written"] == {"Sample.lua (write)"}
    assert used["EEex_ByName"] == {"Sample.lua (name string)"}
    assert used["EEex_ByField"] == {"Sample.lua (name string)"}
    assert used["EEex_FromMenu"] == {"Sample.menu (menu)"}


def test_a_call_to_a_missing_eeex_function_is_reported(scanner, pinned, tmp_path) -> None:
    source = tmp_path / "Regression.lua"
    source.write_text(
        "pcall(function()\n"
        "    EEex_Sprite_DisplayStringHead(EEex_Sprite_GetInPortrait(0), 'x')\n"
        "end)\n",
        encoding="utf-8",
    )
    used = eeex_globals.eeex_references([source], scanner)
    assert {name for name in used if name not in pinned} == {
        "EEex_Sprite_DisplayStringHead"
    }


def test_uncompilable_lua_fails_the_scan(scanner, tmp_path) -> None:
    source = tmp_path / "Broken.lua"
    source.write_text("function EEex_Broken(\n", encoding="utf-8")
    # LuaJIT raises the parse error as a handled SEH exception, which
    # Windows' faulthandler would print as a "fatal exception".
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        with pytest.raises(eeex_globals.LuaCompileError, match="Broken.lua"):
            eeex_globals.eeex_references([source], scanner)
    finally:
        if suppress_fault_handler:
            faulthandler.enable()


def _fake_eeex_tree(root: Path, prefix: str = "EEex_") -> Path:
    eeex = root / "EEex"
    scripts = eeex / "copy" / "EEex_scripts"
    scripts.mkdir(parents=True)
    (scripts / "EEex_Sample.lua").write_text(
        """
function EEex_Defined() end
EEex_Table = {}
function EEex_Table.method() end
function EEex_Table:other() end
local function EEex_LocalFunction() end
local EEex_LocalValue = 1
--[[
function EEex_Commented() end
]]
local text = "EEex_InString = 1"
local function init() EEex_SetInsideFunction = 1 end
""",
        encoding="utf-8",
    )
    (eeex / "copy" / "override").mkdir()
    (eeex / "copy" / "override" / "M___EEex.lua").write_text(
        "EEex_Bootstrap = true\nEEex_Defined = EEex_Defined\n", encoding="utf-8")
    loader = eeex / "loader"
    loader.mkdir()
    (loader / "InfinityLoader.ini").write_text(
        f'[General]\n; comment\nLuaGlobalsPrefix={prefix}\nScriptFolder=EEex_scripts\n',
        encoding="utf-8",
    )
    (loader / "InfinityLoaderDLL.dll").write_bytes(
        b"MZ\x00{}BAnd\x00{}ReadU8\x00junk{}NotAString\x00\x00{}Main\x00"
        b"\x00{}EarlyMain\x00\x00{}1Digit\x00"
    )
    (loader / "LuaBindingsCore.dll").write_bytes(b"\x00{}NewUD\x00\x00{}FreeUD\x00")
    return eeex


def test_generator_reads_lua_global_sets_and_loader_natives(scanner, tmp_path) -> None:
    defined = eeex_globals.defined_globals(_fake_eeex_tree(tmp_path), scanner)

    assert defined == {
        "EEex_Defined": {"copy/EEex_scripts/EEex_Sample.lua", "copy/override/M___EEex.lua"},
        "EEex_Table": {"copy/EEex_scripts/EEex_Sample.lua"},
        "EEex_SetInsideFunction": {"copy/EEex_scripts/EEex_Sample.lua"},
        "EEex_Bootstrap": {"copy/override/M___EEex.lua"},
        "EEex_BAnd": {"loader/InfinityLoaderDLL.dll"},
        "EEex_ReadU8": {"loader/InfinityLoaderDLL.dll"},
        "EEex_NewUD": {"loader/LuaBindingsCore.dll"},
        "EEex_FreeUD": {"loader/LuaBindingsCore.dll"},
    }


def test_generator_uses_the_configured_loader_prefix(scanner, tmp_path) -> None:
    natives = eeex_globals.loader_native_globals(_fake_eeex_tree(tmp_path, '"Ext_"'))
    assert set(natives) == {"Ext_BAnd", "Ext_ReadU8", "Ext_NewUD", "Ext_FreeUD"}


def test_generator_refuses_a_loader_dll_without_name_templates(scanner, tmp_path) -> None:
    eeex = _fake_eeex_tree(tmp_path)
    (eeex / "loader" / "LuaBindingsCore.dll").write_bytes(b"MZ\x00nothing\x00")
    with pytest.raises(ValueError, match="LuaBindingsCore.dll"):
        eeex_globals.defined_globals(eeex, scanner)


def test_generator_round_trips_through_the_file_format(scanner, tmp_path) -> None:
    defined = eeex_globals.defined_globals(_fake_eeex_tree(tmp_path), scanner)
    path = tmp_path / "globals.txt"
    path.write_text(
        eeex_globals.format_globals_file(defined, "v9.9.9", "f" * 40),
        encoding="utf-8",
    )
    meta, names = eeex_globals.read_globals_file(path)
    assert meta == {"tag": "v9.9.9", "commit": "f" * 40}
    assert {name: set(files) for name, files in names.items()} == defined


def test_generator_refuses_another_commit_or_a_modified_checkout(tmp_path) -> None:
    repo = tmp_path / "eeex"
    repo.mkdir()

    def git(*args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t",
             "-c", "commit.gpgsign=false", *args],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    git("init", "-q")
    (repo / "file.txt").write_text("one\n", encoding="utf-8")
    git("add", "file.txt")
    git("commit", "-q", "-m", "init")
    head = git("rev-parse", "HEAD")

    eeex_globals.verify_checkout(repo, head)
    with pytest.raises(eeex_globals.CheckoutError, match="expected"):
        eeex_globals.verify_checkout(repo, "0" * 40)
    (repo / "extra.lua").write_text("EEex_Extra = 1\n", encoding="utf-8")
    with pytest.raises(eeex_globals.CheckoutError, match="local changes"):
        eeex_globals.verify_checkout(repo, head)
