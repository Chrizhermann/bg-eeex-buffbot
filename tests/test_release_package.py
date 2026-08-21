from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path
from zipfile import ZipFile

import pytest
from lupa.luajit21 import LuaRuntime

from tests.ie_formats import write_minimal_tlk
from tests.test_eeex_compatibility_installer import (
    BuffBotGame,
    _assert_installed,
    _read_l10n_map,
    _read_tlk_strings,
    _weidu,
)
from tests.test_localization import CATALOG_SCHEMA, parse_tra


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "tools/build-release.sh"
DEPLOY_SCRIPT = ROOT / "tools/deploy.sh"
WORKFLOW = ROOT / ".github/workflows/release.yml"
README = ROOT / "README.md"
TP2_PATH = ROOT / "buffbot/setup-buffbot.tp2"
VERSION = "v1.7.4-alpha"

# This is deliberately explicit: recursive packaging must not silently publish
# a backup, generated map, local state, or a future development-only file.
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
    assert "raw development deploy" in normalized
    assert "English fallback".casefold() in normalized
    assert "source checkout" in normalized
    assert "development-only" in normalized
    assert "f12 innate tooltip names" in normalized
    assert "language pull requests are welcome" in normalized
    assert "buffbot/lang/english/setup.tra" in source
    assert "lowercase" in normalized
    assert "complete catalog" in normalized
    assert "exact `@` IDs" in source
    assert "semantic" in normalized
    assert "named placeholder" in normalized
    assert "WeiDU token".casefold() in normalized
    assert "UTF-8" in source
    assert "one-line" in normalized and "tilde" in normalized
    assert "python -m pytest tests/test_localization.py" in source
    assert "`LANGUAGE` stanza" in source
    assert "package manifest" in normalized
    assert "translator credit" in normalized
    assert "robovoid" in normalized
    assert "[robovoid](https://github.com/robvoid)" in source
    assert "#50" in source


def test_raw_deploy_is_explicitly_english_without_generated_map(
    tmp_path: Path,
) -> None:
    game = tmp_path / "synthetic-game"
    override = game / "override"
    override.mkdir(parents=True)
    tlk = game / "lang/en_US/dialog.tlk"
    write_minimal_tlk(tlk)

    result = subprocess.run(
        [_bash(), "tools/deploy.sh", _shell_path(game)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "English fallback" in result.stdout
    assert (override / "BfBotLoc.lua").read_bytes() == (
        ROOT / "buffbot/BfBotLoc.lua"
    ).read_bytes()
    assert not (override / "bfbot_l10n.txt").exists()

    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("BfBot = {}; io = nil")
    runtime.execute((override / "BfBotLoc.lua").read_text(encoding="utf-8"))
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "Reset"
    assert runtime.eval('BfBot.L10N.Get("default.preset.long")') == "Long Buffs"


def test_raw_deploy_preserves_and_reports_existing_weidu_map(
    tmp_path: Path,
) -> None:
    game = tmp_path / "synthetic-localized-game"
    override = game / "override"
    override.mkdir(parents=True)
    write_minimal_tlk(game / "lang/en_US/dialog.tlk")
    map_path = override / "bfbot_l10n.txt"
    original_map = b"300=12345\n"
    map_path.write_bytes(original_map)

    result = subprocess.run(
        [_bash(), _shell_path(DEPLOY_SCRIPT), _shell_path(game)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "preserving existing WeiDU localization map" in result.stdout
    assert "English fallback" not in result.stdout
    assert map_path.read_bytes() == original_map


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
    assert version.returncode == 0
    assert "WeiDU version 24900" in version.stdout + version.stderr

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
    catalog, _ = parse_tra(game.root / "buffbot/lang/schinese/setup.tra")
    strings = _read_tlk_strings(game.schinese_tlk)
    mapping = _read_l10n_map(game.override / "bfbot_l10n.txt")
    runtime_ids = {
        catalog_id
        for catalog_id, semantic_key in CATALOG_SCHEMA.items()
        if not semantic_key.startswith("installer.")
    }
    assert set(mapping) == runtime_ids
    for catalog_id, strref in mapping.items():
        assert strings[strref] == catalog[catalog_id]
