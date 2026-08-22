from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from zipfile import ZipFile

import pytest

from tests.ie_formats import write_minimal_tlk
from tests.test_eeex_compatibility_installer import (
    BuffBotGame,
    _assert_installed,
    _assert_weidu_249,
    _read_innate_strrefs,
    _read_tlk_strings,
    _write_tlk_strings,
    _weidu,
)
from tests.test_localization import localization_runtime, parse_tra


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "tools/build-release.sh"
DEPLOY_SCRIPT = ROOT / "tools/deploy.sh"
WORKFLOW = ROOT / ".github/workflows/release.yml"
README = ROOT / "README.md"
TP2_PATH = ROOT / "buffbot/setup-buffbot.tp2"
VERSION = "v1.7.4-alpha"

# This is deliberately explicit: recursive packaging must not silently publish
# a backup, installer-generated state, local state, or a future development-only file.
BUFFBOT_RELEASE_FILES = {
    "buffbot/BFBOTAB.BAM",
    "buffbot/BFBOTBG.MOS",
    "buffbot/BFBOTFR.PVRZ",
    "buffbot/BFBOTFR2.PVRZ",
    "buffbot/BFBOTFR3.PVRZ",
    "buffbot/BFBOTIB.BAM",
    "buffbot/BfBotCls.lua",
    "buffbot/BfBotCor.lua",
    "buffbot/BfBotExe.lua",
    "buffbot/BfBotInn.lua",
    "buffbot/BfBotLoc.lua",
    "buffbot/BfBotMp.lua",
    "buffbot/BfBotPer.lua",
    "buffbot/BfBotScn.lua",
    "buffbot/BfBotThm.lua",
    "buffbot/BfBotTst.lua",
    "buffbot/BfBotUI.lua",
    "buffbot/BuffBot.menu",
    "buffbot/MOS9900.PVRZ",
    "buffbot/MOS9901.PVRZ",
    "buffbot/MOS9902.PVRZ",
    "buffbot/MOS9903.PVRZ",
    "buffbot/MOS9910.PVRZ",
    "buffbot/MOS9911.PVRZ",
    "buffbot/MOS9912.PVRZ",
    "buffbot/MOS9913.PVRZ",
    "buffbot/MOS9920.PVRZ",
    "buffbot/MOS9921.PVRZ",
    "buffbot/MOS9922.PVRZ",
    "buffbot/MOS9923.PVRZ",
    "buffbot/M_BfBot.lua",
    "buffbot/lang/english/setup.tra",
    "buffbot/lang/schinese/setup.tra",
    "buffbot/setup-buffbot.tp2",
}
ARCHIVE_FILES = {
    "setup-buffbot.exe",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    *BUFFBOT_RELEASE_FILES,
}


def _bash() -> str:
    if os.name == "nt":
        git_bash = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / (
            "Git/bin/bash.exe"
        )
        if git_bash.is_file():
            return str(git_bash)
    result = shutil.which("bash")
    if result is None:
        pytest.fail("bash is required for release/deploy tests")
    return result


def _shell_path(path: Path) -> str:
    return path.resolve().as_posix()


def _shell_output_path(path: Path) -> str:
    return (path.parent.resolve() / path.name).as_posix()


def _run_raw_deploy(
    game: Path,
    *,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [_bash(), _shell_path(DEPLOY_SCRIPT), _shell_path(game)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
        check=False,
    )


def _write_deploy_sentinel_tlk(path: Path, label: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _write_tlk_strings(
        path,
        (f"{label} sentinel", *(f"{label} existing innate {i}" for i in range(1, 9))),
    )


def _read_deploy_strrefs(override: Path) -> list[int]:
    rows = (override / "bfbot_strrefs.txt").read_text(encoding="ascii").splitlines()
    assert len(rows) == 8
    assert all(re.fullmatch(r"\d+", row) for row in rows)
    return [int(row) for row in rows]


def _write_command_shim(directory: Path, name: str, command: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    shim = directory / name
    shim.write_text(f"#!/bin/sh\n{command}\n", encoding="ascii")
    shim.chmod(0o755)
    return shim


def _shim_path(directory: Path) -> str:
    return f"{_shell_path(directory)}:/usr/bin"


def _python_forward_command() -> str:
    executable = Path(sys.executable).resolve().as_posix()
    return f"exec {shlex.quote(executable)} \"$@\""


def _run_builder(
    installer: Path,
    output: Path,
    *,
    repo_root: Path = ROOT,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            _bash(),
            _shell_path(repo_root / "tools/build-release.sh"),
            _shell_path(installer),
            _shell_output_path(output),
        ],
        cwd=repo_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
        check=False,
    )


@pytest.fixture
def release_archive(tmp_path: Path) -> Path:
    installer = tmp_path / "installer input/setup-buffbot.exe"
    installer.parent.mkdir()
    shutil.copy2(_weidu(), installer)
    output = tmp_path / "release output" / f"buffbot-{VERSION}.zip"
    result = _run_builder(installer, output)
    assert result.returncode == 0, result.stdout + result.stderr
    assert output.is_file()
    return output


def _archive_file_names(archive: Path) -> list[str]:
    with ZipFile(archive) as zipped:
        return sorted(
            info.filename for info in zipped.infolist() if not info.is_dir()
        )


def _copy_release_source(tmp_path: Path) -> Path:
    repo = tmp_path / "release source"
    (repo / "tools").mkdir(parents=True)
    shutil.copy2(BUILD_SCRIPT, repo / "tools/build-release.sh")
    shutil.copytree(ROOT / "buffbot", repo / "buffbot")
    for name in ("README.md", "CHANGELOG.md", "LICENSE"):
        shutil.copy2(ROOT / name, repo / name)
    return repo


def _fixture_installer(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"synthetic setup-buffbot.exe\0")
    return path


def test_release_builder_produces_exact_byte_preserving_allowlist(
    release_archive: Path,
) -> None:
    names = _archive_file_names(release_archive)
    assert len(names) == 38
    assert len(names) == len({name.casefold() for name in names})
    assert set(names) == ARCHIVE_FILES
    assert all("\\" not in name for name in names)
    assert all(not name.startswith("/") and ".." not in Path(name).parts for name in names)

    with ZipFile(release_archive) as zipped:
        assert zipped.testzip() is None
        assert zipped.read("setup-buffbot.exe") == _weidu().read_bytes()
        for relative in sorted(ARCHIVE_FILES - {"setup-buffbot.exe"}):
            assert zipped.read(relative) == (ROOT / relative).read_bytes()

    assert not any(
        re.search(
            r"(?:^|/)(?:tests?|docs/plans|backup|__pycache__|\.pytest_cache)(?:/|$)",
            name,
            re.IGNORECASE,
        )
        for name in names
    )
    assert not any(
        Path(name).name.casefold() in {"bfbot_l10n.txt", "bfbot_strrefs.txt"}
        or name.casefold().endswith((".bak", ".backup", "~"))
        for name in names
    )


def test_release_builder_resolves_relative_output_before_staging(
    tmp_path: Path,
) -> None:
    output = tmp_path / "relative output/buffbot.zip"
    result = subprocess.run(
        [
            _bash(),
            _shell_path(BUILD_SCRIPT),
            _shell_path(_weidu()),
            "relative output/buffbot.zip",
        ],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert set(_archive_file_names(output)) == ARCHIVE_FILES


def test_release_builder_rejects_missing_required_source(tmp_path: Path) -> None:
    repo = _copy_release_source(tmp_path)
    (repo / "buffbot/BfBotUI.lua").unlink()
    output = tmp_path / "missing.zip"

    result = _run_builder(
        _fixture_installer(tmp_path / "setup-buffbot.exe"),
        output,
        repo_root=repo,
    )

    transcript = result.stdout + result.stderr
    assert result.returncode != 0
    assert "missing required release file" in transcript
    assert "buffbot/BfBotUI.lua" in transcript
    assert not output.exists()


def test_release_builder_rejects_unexpected_matching_source(tmp_path: Path) -> None:
    repo = _copy_release_source(tmp_path)
    (repo / "buffbot/Accidental.lua").write_text(
        "-- must not ship\n", encoding="ascii"
    )
    output = tmp_path / "unexpected.zip"

    result = _run_builder(
        _fixture_installer(tmp_path / "setup-buffbot.exe"),
        output,
        repo_root=repo,
    )

    transcript = result.stdout + result.stderr
    assert result.returncode != 0
    assert "unexpected release file" in transcript
    assert "buffbot/Accidental.lua" in transcript
    assert not output.exists()


def test_release_builder_rejects_casefold_path_collisions(tmp_path: Path) -> None:
    repo = _copy_release_source(tmp_path)
    (repo / "buffbot/SS.lua").write_text("-- collision A\n", encoding="ascii")
    (repo / "buffbot/ß.lua").write_text("-- collision B\n", encoding="ascii")
    output = tmp_path / "collision.zip"

    result = _run_builder(
        _fixture_installer(tmp_path / "setup-buffbot.exe"),
        output,
        repo_root=repo,
    )

    assert result.returncode != 0
    assert "case-insensitive path collision" in result.stdout + result.stderr
    assert not output.exists()


def test_release_builder_rejects_existing_output_symlink_without_touching_target(
    tmp_path: Path,
) -> None:
    victim = tmp_path / "victim.zip"
    victim_bytes = b"do not overwrite through a symlink\n"
    victim.write_bytes(victim_bytes)
    output = tmp_path / "buffbot.zip"
    output.symlink_to(victim)
    link_target = os.readlink(output)

    result = _run_builder(
        _fixture_installer(tmp_path / "setup-buffbot.exe"),
        output,
    )

    assert result.returncode != 0
    assert "output ZIP must not be a symlink" in result.stdout + result.stderr
    assert output.is_symlink()
    assert os.readlink(output) == link_target
    assert victim.read_bytes() == victim_bytes


def test_release_builder_rejects_dangling_output_symlink(tmp_path: Path) -> None:
    missing_target = tmp_path / "missing-victim.zip"
    output = tmp_path / "buffbot.zip"
    output.symlink_to(missing_target)
    link_target = os.readlink(output)

    result = _run_builder(
        _fixture_installer(tmp_path / "setup-buffbot.exe"),
        output,
    )

    assert result.returncode != 0
    assert "output ZIP must not be a symlink" in result.stdout + result.stderr
    assert output.is_symlink()
    assert os.readlink(output) == link_target
    assert not missing_target.exists()


def test_release_workflow_delegates_packaging_and_keeps_version_guards() -> None:
    source = WORKFLOW.read_text(encoding="utf-8")

    assert 'TP2_VERSION=$(grep -E \'^VERSION ~\'' in source
    assert 'COR_VERSION=$(grep -E \'^BfBot\\.VERSION = "\'' in source
    assert 'if [ "$TP2_VERSION" != "$RELEASE_TAG" ]' in source
    assert 'if [ "$COR_VERSION" != "$TAG_NOV" ]' in source
    release_expression = "${{ github.event.release.tag_name }}"
    assert source.count(release_expression) == 1
    assert f"RELEASE_TAG: {release_expression}" in source
    assert 'TAG="${{' not in source
    assert "bash tools/build-release.sh" in source
    assert "/tmp/setup-buffbot.exe" in source
    assert '"/tmp/buffbot-${RELEASE_TAG}.zip"' in source
    assert "--installer" not in source
    assert "--output" not in source
    assert "cp buffbot/*.lua" not in source
    assert "cp buffbot/*.PVRZ" not in source


def test_catalog_folders_exactly_match_tp2_language_declarations() -> None:
    source = TP2_PATH.read_text(encoding="utf-8")
    declared = {
        match.group(1)
        for match in re.finditer(
            r"(?m)^\s*~(buffbot/lang/[a-z0-9_-]+/setup\.tra)~\s*$",
            source,
        )
    }
    actual = {
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "buffbot/lang").rglob("*")
        if path.is_file()
    }

    assert len(re.findall(r"(?m)^LANGUAGE\s*$", source)) == len(declared)
    assert declared == actual


def test_readme_documents_language_selection_and_complete_catalog_prs() -> None:
    source = README.read_text(encoding="utf-8")
    normalized = source.casefold()

    assert "## Languages" in source
    assert "English" in source
    assert "Simplified Chinese" in source
    assert "weiDU".casefold() in normalized
    assert "selected UTF-8 catalog".casefold() in normalized
    assert "`override/bfbot_l10n.tra`" in source
    assert "reads directly" in normalized
    assert "no BuffBot-owned UI string is fetched from the game TLK".casefold() in normalized
    assert "raw development deploy" in normalized
    assert "English fallback".casefold() in normalized
    assert "preserves an existing `override/bfbot_l10n.tra`" in source
    assert "`override/bfbot_strrefs.txt`" in source
    assert "preserves both files byte-for-byte" in normalized
    assert "skips TLK patching".casefold() in normalized
    assert "stops before copying runtime files" in normalized
    assert "reinstall BuffBot with WeiDU".casefold() in normalized
    assert "patches only `lang/en_US/dialog.tlk`".casefold() in normalized
    assert "other language TLKs untouched".casefold() in normalized
    assert "requires Python 3 and an existing `lang/en_US/dialog.tlk`" in source
    assert "refuses the fallback before copying files" in normalized
    assert "source checkout" in normalized
    assert "development-only" in normalized
    assert "f12 innate" in normalized
    assert "innate references" in normalized
    assert "only the eight generated F12 innate names".casefold() in normalized
    assert "`@200` through `@207`" in source
    assert "`bfbot_strrefs.txt`" in source
    assert "Copy Copy" in source
    assert "readable CJK labels" in source
    assert "tested resolution/font" in source
    assert "alternate resolutions/fonts remain pending" in normalized
    assert "live in-game Chinese glyph and layout acceptance is still pending".casefold() not in normalized
    assert "language pull requests are welcome" in normalized
    assert "buffbot/lang/english/setup.tra" in source
    assert "safe lowercase folder name" in normalized
    assert "`a-z`, `0-9`, and underscores" in source
    assert "complete catalog" in normalized
    assert "exact `@` IDs" in source
    assert "all comments" in normalized
    assert "named placeholder" in normalized
    assert "WeiDU token".casefold() in normalized
    assert "`@113`" in source
    assert "exact folder name" in normalized
    assert "non-translatable" in normalized
    assert "UTF-8" in source
    assert "one-line" in normalized and "tilde" in normalized
    assert "python -m pytest tests/test_localization.py" in source
    assert "tests/test_release_package.py" in source
    assert "`LANGUAGE` stanza" in source
    assert "package manifest is derived from the `language` declarations" in normalized
    assert "translator credit" in normalized
    assert "robovoid" in normalized
    assert "[robovoid](https://github.com/robvoid)" in source
    assert "#50" in source
    assert (
        "An obsolete `bfbot_l10n.txt` alone is preserved but does not select "
        "localized deployment."
    ) in source


def test_raw_deploy_leaves_runtime_catalog_absent_and_reports_english_fallback(
    tmp_path: Path,
) -> None:
    game = tmp_path / "synthetic-game"
    override = game / "override"
    override.mkdir(parents=True)
    english_tlk = game / "lang/en_US/dialog.tlk"
    chinese_tlk = game / "lang/zh_CN/dialog.tlk"
    root_tlk = game / "dialog.tlk"
    _write_deploy_sentinel_tlk(english_tlk, "English")
    _write_deploy_sentinel_tlk(chinese_tlk, "Chinese")
    _write_deploy_sentinel_tlk(root_tlk, "Root")
    english_before = english_tlk.read_bytes()
    chinese_before = chinese_tlk.read_bytes()
    root_before = root_tlk.read_bytes()

    result = _run_raw_deploy(game)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "English fallback" in result.stdout
    assert "preserving existing WeiDU-selected runtime catalog" not in result.stdout
    assert (override / "BfBotLoc.lua").read_bytes() == (
        ROOT / "buffbot/BfBotLoc.lua"
    ).read_bytes()
    assert not (override / "bfbot_l10n.tra").exists()
    assert not (override / "bfbot_l10n.txt").exists()
    assert english_tlk.read_bytes() != english_before
    assert chinese_tlk.read_bytes() == chinese_before
    assert root_tlk.read_bytes() == root_before

    english_catalog, _ = parse_tra(ROOT / "buffbot/lang/english/setup.tra")
    english_strings = _read_tlk_strings(english_tlk)
    refs = _read_deploy_strrefs(override)
    assert all(0 <= ref < len(english_strings) for ref in refs)
    assert [english_strings[ref] for ref in refs] == [
        english_catalog[catalog_id] for catalog_id in range(200, 208)
    ]

    runtime = localization_runtime()
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "Reset"
    assert runtime.eval('BfBot.L10N.Get("default.preset.long")') == "Long Buffs"


def test_raw_deploy_preserves_selected_chinese_catalog_and_obsolete_map(
    tmp_path: Path,
) -> None:
    game = tmp_path / "synthetic localized game"
    override = game / "override"
    override.mkdir(parents=True)
    english_tlk = game / "lang/en_US/dialog.tlk"
    chinese_tlk = game / "lang/zh_CN/dialog.tlk"
    root_tlk = game / "dialog.tlk"
    _write_deploy_sentinel_tlk(english_tlk, "English localized")
    _write_deploy_sentinel_tlk(chinese_tlk, "Chinese localized")
    _write_deploy_sentinel_tlk(root_tlk, "Root localized")
    source_catalog = ROOT / "buffbot/lang/schinese/setup.tra"
    catalog_path = override / "bfbot_l10n.tra"
    selected_reset = "部署保留测试重置"
    selected_catalog_text, replacement_count = re.subn(
        r"(?m)^@305 = ~[^~]+~$",
        f"@305 = ~{selected_reset}~",
        source_catalog.read_text(encoding="utf-8"),
    )
    assert replacement_count == 1
    selected_catalog = (
        selected_catalog_text.rstrip("\r\n")
        + "\n// installer-owned preservation sentinel\n"
    ).encode("utf-8")
    assert selected_catalog != source_catalog.read_bytes()
    catalog_path.write_bytes(selected_catalog)
    selected_entries, _ = parse_tra(catalog_path)
    _write_tlk_strings(
        chinese_tlk,
        (
            "Chinese localized sentinel",
            *(selected_entries[catalog_id] for catalog_id in range(200, 208)),
        ),
    )
    obsolete_map_path = override / "bfbot_l10n.txt"
    obsolete_map = b"300=12345\n"
    obsolete_map_path.write_bytes(obsolete_map)
    strrefs_path = override / "bfbot_strrefs.txt"
    selected_strrefs = b"1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n"
    strrefs_path.write_bytes(selected_strrefs)
    preserved_tlks = {
        english_tlk: english_tlk.read_bytes(),
        chinese_tlk: chinese_tlk.read_bytes(),
        root_tlk: root_tlk.read_bytes(),
    }

    result = _run_raw_deploy(game)

    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        "preserving existing WeiDU-selected runtime catalog and innate references"
        in result.stdout
    )
    assert "skipping TLK patching" in result.stdout
    assert "Patching dialog.tlk" not in result.stdout
    assert "English fallback" not in result.stdout
    assert catalog_path.read_bytes() == selected_catalog
    assert strrefs_path.read_bytes() == selected_strrefs
    assert obsolete_map_path.read_bytes() == obsolete_map
    assert all(path.read_bytes() == before for path, before in preserved_tlks.items())
    assert not any(path.with_name(path.name + ".bfbot_backup").exists() for path in preserved_tlks)

    preserved_chinese_strings = _read_tlk_strings(chinese_tlk)
    preserved_refs = _read_deploy_strrefs(override)
    assert [preserved_chinese_strings[ref] for ref in preserved_refs] == [
        selected_entries[catalog_id] for catalog_id in range(200, 208)
    ]
    assert selected_entries[305] == selected_reset
    assert list(selected_entries.values()).count(selected_reset) == 1
    runtime = localization_runtime(catalog_path.read_text(encoding="utf-8"))
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == selected_reset


def test_raw_deploy_rejects_selected_catalog_without_innate_references_before_writes(
    tmp_path: Path,
) -> None:
    game = tmp_path / "synthetic inconsistent localized game"
    override = game / "override"
    override.mkdir(parents=True)
    catalog_path = override / "bfbot_l10n.tra"
    selected_catalog = (ROOT / "buffbot/lang/schinese/setup.tra").read_bytes()
    catalog_path.write_bytes(selected_catalog)
    existing_runtime = override / "BfBotLoc.lua"
    runtime_sentinel = b"installer-owned runtime sentinel\r\n"
    existing_runtime.write_bytes(runtime_sentinel)

    english_tlk = game / "lang/en_US/dialog.tlk"
    chinese_tlk = game / "lang/zh_CN/dialog.tlk"
    root_tlk = game / "dialog.tlk"
    _write_deploy_sentinel_tlk(english_tlk, "English inconsistent")
    _write_deploy_sentinel_tlk(chinese_tlk, "Chinese inconsistent")
    _write_deploy_sentinel_tlk(root_tlk, "Root inconsistent")
    preserved_tlks = {
        english_tlk: english_tlk.read_bytes(),
        chinese_tlk: chinese_tlk.read_bytes(),
        root_tlk: root_tlk.read_bytes(),
    }

    result = _run_raw_deploy(game)

    transcript = result.stdout + result.stderr
    assert result.returncode != 0
    assert "bfbot_strrefs.txt" in transcript
    assert "Reinstall BuffBot with WeiDU" in transcript
    assert catalog_path.read_bytes() == selected_catalog
    assert existing_runtime.read_bytes() == runtime_sentinel
    assert not (override / "M_BfBot.lua").exists()
    assert not (override / "bfbot_presets").exists()
    assert all(path.read_bytes() == before for path, before in preserved_tlks.items())
    assert not any(path.with_name(path.name + ".bfbot_backup").exists() for path in preserved_tlks)


def test_raw_deploy_does_not_treat_obsolete_map_as_selected_localization(
    tmp_path: Path,
) -> None:
    game = tmp_path / "synthetic-obsolete-map-game"
    override = game / "override"
    override.mkdir(parents=True)
    write_minimal_tlk(game / "lang/en_US/dialog.tlk")
    obsolete_map_path = override / "bfbot_l10n.txt"
    obsolete_map = b"305=12345\n"
    obsolete_map_path.write_bytes(obsolete_map)

    result = _run_raw_deploy(game)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "English fallback" in result.stdout
    assert "preserving existing WeiDU-selected runtime catalog" not in result.stdout
    assert obsolete_map_path.read_bytes() == obsolete_map
    assert not (override / "bfbot_l10n.tra").exists()

    runtime = localization_runtime()
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "Reset"


def test_raw_deploy_propagates_english_tlk_patcher_failure(tmp_path: Path) -> None:
    game = tmp_path / "synthetic invalid tlk game"
    override = game / "override"
    override.mkdir(parents=True)
    english_tlk = game / "lang/en_US/dialog.tlk"
    english_tlk.parent.mkdir(parents=True)
    invalid_tlk = b"not a TLK V1 file\r\n"
    english_tlk.write_bytes(invalid_tlk)

    result = _run_raw_deploy(game)

    transcript = result.stdout + result.stderr
    assert result.returncode != 0
    assert "Failed to patch English fallback TLK" in transcript
    assert "Done. Files deployed:" not in transcript
    assert english_tlk.read_bytes() == invalid_tlk


def test_raw_deploy_rejects_missing_english_tlk_before_copying_payload(
    tmp_path: Path,
) -> None:
    game = tmp_path / "synthetic missing English TLK game"
    override = game / "override"
    override.mkdir(parents=True)
    existing_runtime = override / "BfBotLoc.lua"
    runtime_sentinel = b"preflight runtime sentinel\r\n"
    existing_runtime.write_bytes(runtime_sentinel)

    result = _run_raw_deploy(game)

    transcript = result.stdout + result.stderr
    assert result.returncode != 0
    assert "English fallback requires" in transcript
    assert "lang/en_US/dialog.tlk" in transcript
    assert existing_runtime.read_bytes() == runtime_sentinel
    assert not (override / "M_BfBot.lua").exists()
    assert not (override / "bfbot_presets").exists()
    assert not (override / "bfbot_strrefs.txt").exists()
    assert "Done. Files deployed:" not in transcript


def test_raw_deploy_rejects_symlinked_english_tlk_before_writes(
    tmp_path: Path,
) -> None:
    game = tmp_path / "synthetic symlinked English TLK game"
    override = game / "override"
    override.mkdir(parents=True)
    existing_runtime = override / "BfBotLoc.lua"
    runtime_sentinel = b"symlinked TLK runtime sentinel\r\n"
    existing_runtime.write_bytes(runtime_sentinel)

    victim = tmp_path / "outside dialog.tlk"
    _write_deploy_sentinel_tlk(victim, "Outside victim")
    victim_before = victim.read_bytes()
    english_tlk = game / "lang/en_US/dialog.tlk"
    english_tlk.parent.mkdir(parents=True)
    english_tlk.symlink_to(victim)

    result = _run_raw_deploy(game)

    transcript = result.stdout + result.stderr
    assert result.returncode != 0
    assert "lang/en_US/dialog.tlk" in transcript
    assert "regular non-symlink file" in transcript
    assert existing_runtime.read_bytes() == runtime_sentinel
    assert not (override / "M_BfBot.lua").exists()
    assert not (override / "bfbot_presets").exists()
    assert not (override / "bfbot_strrefs.txt").exists()
    assert english_tlk.is_symlink()
    assert victim.read_bytes() == victim_before
    assert "Done. Files deployed:" not in transcript


def test_raw_deploy_rejects_missing_python_before_copying_payload(
    tmp_path: Path,
) -> None:
    game = tmp_path / "synthetic missing Python game"
    override = game / "override"
    override.mkdir(parents=True)
    existing_runtime = override / "BfBotLoc.lua"
    runtime_sentinel = b"python preflight runtime sentinel\r\n"
    existing_runtime.write_bytes(runtime_sentinel)
    english_tlk = game / "lang/en_US/dialog.tlk"
    _write_deploy_sentinel_tlk(english_tlk, "Missing Python")
    tlk_before = english_tlk.read_bytes()
    shims = tmp_path / "failing Python shims"
    _write_command_shim(shims, "python3", "exit 37")
    _write_command_shim(shims, "python", "exit 38")
    env = os.environ.copy()
    env["PATH"] = _shim_path(shims)

    result = _run_raw_deploy(game, env=env)

    transcript = result.stdout + result.stderr
    assert result.returncode != 0
    assert "English fallback requires Python 3" in transcript
    assert existing_runtime.read_bytes() == runtime_sentinel
    assert not (override / "M_BfBot.lua").exists()
    assert not (override / "bfbot_presets").exists()
    assert not (override / "bfbot_strrefs.txt").exists()
    assert english_tlk.read_bytes() == tlk_before
    assert "Done. Files deployed:" not in transcript


def test_raw_deploy_falls_back_to_valid_python_when_python3_is_unusable(
    tmp_path: Path,
) -> None:
    game = tmp_path / "synthetic broken python3 game"
    override = game / "override"
    override.mkdir(parents=True)
    english_tlk = game / "lang/en_US/dialog.tlk"
    _write_deploy_sentinel_tlk(english_tlk, "Broken python3")
    shims = tmp_path / "mixed Python shims"
    _write_command_shim(shims, "python3", "exit 39")
    _write_command_shim(shims, "python", _python_forward_command())
    env = os.environ.copy()
    env["PATH"] = _shim_path(shims)

    result = _run_raw_deploy(game, env=env)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "English fallback" in result.stdout
    refs = _read_deploy_strrefs(override)
    strings = _read_tlk_strings(english_tlk)
    assert [strings[ref] for ref in refs] == [f"BuffBot {i}" for i in range(1, 9)]


def test_raw_deploy_stops_on_payload_copy_failure_before_tlk_mutation(
    tmp_path: Path,
) -> None:
    game = tmp_path / "synthetic copy failure game"
    override = game / "override"
    override.mkdir(parents=True)
    existing_runtime = override / "BfBotLoc.lua"
    runtime_sentinel = b"copy failure runtime sentinel\r\n"
    existing_runtime.write_bytes(runtime_sentinel)
    copy_trap = override / "M_BfBot.lua/M_BfBot.lua"
    copy_trap.mkdir(parents=True)
    english_tlk = game / "lang/en_US/dialog.tlk"
    _write_deploy_sentinel_tlk(english_tlk, "Copy failure")
    tlk_before = english_tlk.read_bytes()

    result = _run_raw_deploy(game)

    transcript = result.stdout + result.stderr
    assert result.returncode != 0
    assert existing_runtime.read_bytes() == runtime_sentinel
    assert copy_trap.is_dir()
    assert not (override / "BfBotCor.lua").exists()
    assert not (override / "bfbot_presets").exists()
    assert not (override / "bfbot_strrefs.txt").exists()
    assert english_tlk.read_bytes() == tlk_before
    assert "Patching dialog.tlk" not in transcript
    assert "Done. Files deployed:" not in transcript


@pytest.mark.parametrize("path_kind", ["symlink", "directory"])
def test_raw_deploy_rejects_unsafe_fallback_strrefs_path_before_writes(
    tmp_path: Path,
    path_kind: str,
) -> None:
    game = tmp_path / f"synthetic unsafe strrefs {path_kind} game"
    override = game / "override"
    override.mkdir(parents=True)
    existing_runtime = override / "BfBotLoc.lua"
    runtime_sentinel = b"unsafe strrefs runtime sentinel\r\n"
    existing_runtime.write_bytes(runtime_sentinel)
    english_tlk = game / "lang/en_US/dialog.tlk"
    _write_deploy_sentinel_tlk(english_tlk, f"Unsafe strrefs {path_kind}")
    tlk_before = english_tlk.read_bytes()
    strrefs_path = override / "bfbot_strrefs.txt"
    victim = tmp_path / f"strrefs {path_kind} victim.txt"
    victim_bytes = b"must not be overwritten\r\n"
    if path_kind == "symlink":
        victim.write_bytes(victim_bytes)
        strrefs_path.symlink_to(victim)
    else:
        strrefs_path.mkdir()

    result = _run_raw_deploy(game)

    transcript = result.stdout + result.stderr
    assert result.returncode != 0
    assert "bfbot_strrefs.txt" in transcript
    assert "regular non-symlink file" in transcript
    assert existing_runtime.read_bytes() == runtime_sentinel
    assert not (override / "M_BfBot.lua").exists()
    assert not (override / "bfbot_presets").exists()
    assert english_tlk.read_bytes() == tlk_before
    if path_kind == "symlink":
        assert strrefs_path.is_symlink()
        assert victim.read_bytes() == victim_bytes
    else:
        assert strrefs_path.is_dir()
    assert "Done. Files deployed:" not in transcript


@pytest.mark.parametrize("path_kind", ["dangling_symlink", "directory"])
def test_raw_deploy_rejects_nonregular_catalog_path_before_writes(
    tmp_path: Path,
    path_kind: str,
) -> None:
    game = tmp_path / f"synthetic unsafe catalog {path_kind} game"
    override = game / "override"
    override.mkdir(parents=True)
    existing_runtime = override / "BfBotLoc.lua"
    runtime_sentinel = b"unsafe catalog runtime sentinel\r\n"
    existing_runtime.write_bytes(runtime_sentinel)
    catalog_path = override / "bfbot_l10n.tra"
    if path_kind == "dangling_symlink":
        catalog_path.symlink_to(tmp_path / "missing selected catalog.tra")
    else:
        catalog_path.mkdir()
    english_tlk = game / "lang/en_US/dialog.tlk"
    _write_deploy_sentinel_tlk(english_tlk, f"Unsafe catalog {path_kind}")
    tlk_before = english_tlk.read_bytes()

    result = _run_raw_deploy(game)

    transcript = result.stdout + result.stderr
    assert result.returncode != 0
    assert "bfbot_l10n.tra" in transcript
    assert "not a regular file" in transcript
    assert existing_runtime.read_bytes() == runtime_sentinel
    assert not (override / "M_BfBot.lua").exists()
    assert not (override / "bfbot_presets").exists()
    assert not (override / "bfbot_strrefs.txt").exists()
    assert english_tlk.read_bytes() == tlk_before
    assert "Done. Files deployed:" not in transcript


def test_built_archive_installs_simplified_chinese_with_weidu_249(
    release_archive: Path,
    tmp_path: Path,
) -> None:
    version = subprocess.run(
        [str(_weidu()), "--version"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
        check=False,
    )
    _assert_weidu_249(version)

    game = BuffBotGame(tmp_path / "game", "v1")
    before = game.snapshot()
    shutil.rmtree(game.root / "buffbot")
    with ZipFile(release_archive) as zipped:
        zipped.extractall(game.root)

    process = subprocess.run(
        [
            str(game.root / "setup-buffbot.exe"),
            r".\buffbot\setup-buffbot.tp2",
            "--game",
            str(game.root),
            "--force-install-list",
            "1",
            "0",
            "--language",
            "1",
            "--use-lang",
            "zh_CN",
            "--no-exit-pause",
            "--quick-log",
            "--noautoupdate",
        ],
        cwd=game.root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
        check=False,
    )
    _assert_installed(game, process)

    assert game.lang_tlk.read_bytes() == before.lang_tlk
    assert game.root_tlk.read_bytes() == before.root_tlk
    assert game.schinese_tlk.read_bytes() != before.schinese_tlk
    packaged_catalog = game.root / "buffbot/lang/schinese/setup.tra"
    catalog, _ = parse_tra(packaged_catalog)
    assert (game.override / "bfbot_l10n.tra").read_bytes() == (
        packaged_catalog.read_bytes()
    )
    assert not (game.override / "bfbot_l10n.txt").exists()

    strings = _read_tlk_strings(game.schinese_tlk)
    refs = _read_innate_strrefs(game)
    assert all(0 <= strref < len(strings) for strref in refs)
    assert [strings[strref] for strref in refs] == [
        catalog[catalog_id] for catalog_id in range(200, 208)
    ]
    assert strings[0] == ""
    expected_innate_strings = {
        catalog[catalog_id] for catalog_id in range(200, 208)
    }
    assert len(strings) == 1 + len(expected_innate_strings)
    assert set(strings[1:]) == expected_innate_strings
