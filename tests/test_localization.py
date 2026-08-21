from __future__ import annotations

import re
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
LANG_ROOT = ROOT / "buffbot" / "lang"

ENTRY_RE = re.compile(r"^@(\d+)\s*=\s*~([^~]*)~\s*$")
EMPTY_ID_RE = re.compile(r"^@\s*=", re.ASCII)
SEMANTIC_COMMENT_RE = re.compile(r"^//\s*([a-z][a-z0-9_.]*)\s*$")
NAMED_PLACEHOLDER_RE = re.compile(r"\{([a-z][a-z0-9_]*)\}")
WEIDU_SENTINEL_RE = re.compile(r"%([A-Za-z_][A-Za-z0-9_]*)%")


# Catalog IDs are deliberately grouped so the later Lua registry and WeiDU
# id-to-strref map can be audited against translator-facing semantic comments.
# Task 2 must derive or validate its runtime registry from this machine-readable
# schema (or these same catalog comments), not introduce an uncontrolled fourth
# hand-maintained copy of the ID/key contract.
CATALOG_SCHEMA = {
    # Installer strings (100-199)
    100: "installer.component.luajit",
    101: "installer.require.game",
    102: "installer.require.eeex",
    103: "installer.luajit.already_active",
    104: "installer.luajit.missing_ini",
    105: "installer.luajit.missing_dlls",
    106: "installer.luajit.invalid_general",
    107: "installer.luajit.installing",
    108: "installer.luajit.required_version",
    109: "installer.luajit.installed",
    110: "installer.luajit.postcondition_failed",
    111: "installer.component.main",
    112: "installer.main.luajit_required",
    # Independently resolved innate names (200-207)
    200: "innate.preset_1",
    201: "innate.preset_2",
    202: "innate.preset_3",
    203: "innate.preset_4",
    204: "innate.preset_5",
    205: "innate.preset_6",
    206: "innate.preset_7",
    207: "innate.preset_8",
    # Common and static menu labels (300-399)
    300: "common.buffbot",
    301: "common.party",
    302: "common.summons",
    303: "common.self",
    304: "common.none",
    305: "common.reset",
    306: "common.rename",
    307: "common.new",
    308: "common.add_spell",
    309: "common.remove",
    310: "common.export",
    311: "common.import",
    312: "common.up",
    313: "common.down",
    314: "common.sort",
    315: "common.delete_preset",
    316: "common.delete_preset_compact",
    317: "common.stop",
    318: "common.close",
    319: "common.all_party",
    320: "common.clear",
    321: "common.done",
    322: "common.unlock_targeting",
    323: "common.ok",
    324: "common.cancel",
    325: "common.delete",
    326: "common.select",
    327: "common.enable",
    328: "common.disable",
    329: "common.target",
    330: "common.variant",
    331: "common.spells",
    332: "common.items",
    # Dynamic UI text and complete templates (400-499)
    400: "ui.tooltip.configuration",
    401: "ui.no_allied_summons",
    402: "ui.title.preset",
    403: "ui.title.summons",
    404: "ui.title.summon_preset",
    405: "ui.clone.mislead",
    406: "ui.clone.project_image",
    407: "ui.clone.simulacrum",
    408: "ui.clone.generic",
    409: "ui.cast.all",
    410: "ui.cast.character",
    411: "ui.cast.named",
    412: "ui.cast.summon",
    413: "ui.qualifier.self_only",
    414: "ui.qualifier.party_wide",
    415: "ui.rename_preset_title",
    416: "ui.add_spell_title",
    417: "ui.add_to_buff_list",
    418: "ui.import_config_title",
    419: "ui.select_variant_title",
    420: "ui.delete_preset_confirm",
    421: "ui.variant.selected",
    422: "ui.target.selected",
    423: "ui.repeat.label",
    424: "ui.repeat.spell_tooltip",
    425: "ui.repeat.item_tooltip",
    426: "ui.target.player",
    427: "ui.target.multiple",
    428: "ui.status.casting",
    429: "ui.status.casting_quick_long",
    430: "ui.status.casting_quick_all",
    431: "ui.status.done",
    432: "ui.status.stopped",
    433: "ui.quick_cast.off",
    434: "ui.quick_cast.long",
    435: "ui.quick_cast.all",
    436: "ui.quick_cast.tooltip_unavailable",
    437: "ui.quick_cast.tooltip_off",
    438: "ui.quick_cast.tooltip_long",
    439: "ui.quick_cast.tooltip_all",
    440: "ui.duration.permanent",
    441: "ui.duration.instant",
    442: "ui.duration.hours_minutes",
    443: "ui.duration.hours",
    444: "ui.duration.minutes_seconds",
    445: "ui.duration.minutes",
    446: "ui.duration.seconds",
    447: "ui.category.permanent",
    448: "ui.category.long",
    449: "ui.category.short",
    450: "ui.category.instant",
    451: "ui.category.unknown",
    # Player feedback and stable reason text (500-599)
    500: "feedback.no_luajit",
    501: "feedback.combat_stopped",
    502: "feedback.cast_timeout",
    503: "feedback.party_changed_after_run",
    504: "feedback.party_changed_refreshing",
    505: "feedback.no_spells_with_reason",
    506: "feedback.innate_error",
    507: "feedback.no_spells_preset",
    508: "feedback.character_remote_control",
    509: "feedback.character_project_image_locked",
    510: "feedback.no_spells_character",
    511: "feedback.no_summon_selected",
    512: "feedback.no_spells_summon",
    513: "feedback.no_spells_summon_with_reason",
    514: "feedback.no_additional_spells",
    515: "feedback.export_success",
    516: "feedback.export_failed",
    517: "feedback.no_exported_configs",
    518: "feedback.import_success",
    519: "feedback.import_failed",
    520: "reason.exec.empty_queue",
    521: "reason.exec.no_valid_entries",
    522: "reason.exec.already_running",
    523: "reason.export.luajit_required",
    524: "reason.export.no_sprite",
    525: "reason.export.no_config",
    526: "reason.export.cannot_open_file",
    527: "reason.import.luajit_required",
    528: "reason.import.no_sprite",
    529: "reason.import.no_filename",
    530: "reason.import.invalid_filename",
    531: "reason.import.cannot_open_file",
    532: "reason.import.empty_file",
    533: "reason.import.parse_error",
    534: "reason.import.exec_error",
    535: "reason.import.invalid_data",
    536: "reason.queue.invalid_summon",
    537: "reason.queue.no_summon_preset",
    538: "reason.queue.caster_resolver_unavailable",
    539: "reason.queue.summon_gone",
    540: "reason.queue.summon_scan_failed",
    541: "reason.queue.no_castable_summon_spells",
    542: "reason.queue.no_preset_index",
    543: "reason.queue.no_castable_preset_spells",
    544: "reason.queue.missing_slot_or_preset",
    545: "reason.queue.no_sprite_in_slot",
    546: "reason.queue.not_locally_controlled",
    547: "reason.queue.no_config_for_slot",
    548: "reason.queue.no_preset_for_slot",
    549: "reason.queue.scan_failed_for_slot",
    550: "reason.queue.project_image_locked",
    551: "reason.queue.no_castable_spells_for_slot",
    # Defaults created for new data only (600-699)
    600: "default.preset.long",
    601: "default.preset.short",
    602: "default.preset.indexed",
    # EEex Options strings: exactly thirteen (700-712)
    700: "options.tab",
    701: "options.dark_mode",
    702: "options.dark_mode_description",
    703: "options.color_scheme",
    704: "options.color_scheme_description",
    705: "options.color_scheme_bg2",
    706: "options.color_scheme_sod",
    707: "options.color_scheme_bg1",
    708: "options.text_size",
    709: "options.text_size_description",
    710: "options.text_size_small",
    711: "options.text_size_medium",
    712: "options.text_size_large",
}


def parse_tra(path: Path) -> tuple[dict[int, str], dict[int, str]]:
    """Parse BuffBot's intentionally strict, one-entry-per-line TRA subset."""
    text = path.read_bytes().decode("utf-8", errors="strict")
    entries: dict[int, str] = {}
    semantics: dict[int, str] = {}
    pending_semantic: str | None = None

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        semantic_match = SEMANTIC_COMMENT_RE.fullmatch(line)
        if semantic_match:
            if pending_semantic is not None:
                raise ValueError(f"{path}:{line_number}: semantic comment has no entry")
            pending_semantic = semantic_match.group(1)
            continue
        if line.startswith("//"):
            continue
        if EMPTY_ID_RE.match(line):
            raise ValueError(f"{path}:{line_number}: empty TRA id")

        entry_match = ENTRY_RE.fullmatch(line)
        if not entry_match:
            raise ValueError(f"{path}:{line_number}: unsupported TRA syntax")
        tra_id = int(entry_match.group(1))
        value = entry_match.group(2)
        if tra_id in entries:
            raise ValueError(f"{path}:{line_number}: duplicate TRA id @{tra_id}")
        if not value.strip():
            raise ValueError(f"{path}:{line_number}: empty value for @{tra_id}")
        if pending_semantic is None:
            raise ValueError(f"{path}:{line_number}: @{tra_id} lacks a semantic comment")
        if pending_semantic in semantics.values():
            raise ValueError(
                f"{path}:{line_number}: duplicate semantic key {pending_semantic}"
            )
        entries[tra_id] = value
        semantics[tra_id] = pending_semantic
        pending_semantic = None

    if pending_semantic is not None:
        raise ValueError(f"{path}: trailing semantic comment has no entry")
    if not entries:
        raise ValueError(f"{path}: catalog is empty")
    return entries, semantics


def named_placeholders(value: str) -> set[str]:
    return set(NAMED_PLACEHOLDER_RE.findall(value))


def validate_named_placeholders(value: str) -> None:
    remainder = NAMED_PLACEHOLDER_RE.sub("", value)
    if "{" in remainder or "}" in remainder:
        raise ValueError("malformed named placeholder")


def shipped_catalogs() -> list[Path]:
    return sorted(LANG_ROOT.glob("*/setup.tra"))


def test_parser_rejects_malformed_utf8_duplicate_empty_ids_and_empty_values(
    tmp_path: Path,
):
    bad_utf8 = tmp_path / "bad-utf8.tra"
    bad_utf8.write_bytes(b"// key\n@1 = ~\xff~\n")
    with pytest.raises(UnicodeDecodeError):
        parse_tra(bad_utf8)

    duplicate = tmp_path / "duplicate.tra"
    duplicate.write_text("// one\n@1 = ~One~\n// two\n@1 = ~Two~\n", encoding="utf-8")
    with pytest.raises(ValueError, match="duplicate TRA id @1"):
        parse_tra(duplicate)

    empty_id = tmp_path / "empty-id.tra"
    empty_id.write_text("// key\n@ = ~Missing~\n", encoding="utf-8")
    with pytest.raises(ValueError, match="empty TRA id"):
        parse_tra(empty_id)

    empty_value = tmp_path / "empty-value.tra"
    empty_value.write_text("// key\n@1 = ~~\n", encoding="utf-8")
    with pytest.raises(ValueError, match="empty value"):
        parse_tra(empty_value)

    whitespace_value = tmp_path / "whitespace-value.tra"
    whitespace_value.write_text("// key\n@1 = ~   ~\n", encoding="utf-8")
    with pytest.raises(ValueError, match="empty value"):
        parse_tra(whitespace_value)

    interior_tilde = tmp_path / "interior-tilde.tra"
    interior_tilde.write_text("// key\n@1 = ~first~ second~\n", encoding="utf-8")
    with pytest.raises(ValueError, match="unsupported TRA syntax"):
        parse_tra(interior_tilde)


def test_all_shipped_catalogs_match_english_ids_semantics_and_placeholders():
    english_path = LANG_ROOT / "english" / "setup.tra"
    english, english_semantics = parse_tra(english_path)
    assert english_semantics == CATALOG_SCHEMA

    catalogs = shipped_catalogs()
    shipped_languages = {path.parent.name for path in catalogs}
    required_languages = {"english", "schinese"}
    assert not required_languages - shipped_languages, (
        f"missing required catalog(s): {sorted(required_languages - shipped_languages)}"
    )
    for catalog_path in catalogs:
        catalog, semantics = parse_tra(catalog_path)
        assert catalog.keys() == english.keys()
        assert semantics == english_semantics
        for tra_id in english:
            assert named_placeholders(catalog[tra_id]) == named_placeholders(
                english[tra_id]
            ), f"named placeholder mismatch in {catalog_path} @{tra_id}"


def test_catalog_values_contain_no_legacy_or_unresolved_sentinels():
    for catalog_path in shipped_catalogs():
        catalog, semantics = parse_tra(catalog_path)
        for tra_id, value in catalog.items():
            assert "BFBOTUITRA_" not in value, f"legacy marker in {catalog_path} @{tra_id}"
            assert not re.search(r"@\d+", value), f"raw TRA ref in {catalog_path} @{tra_id}"

            sentinels = set(WEIDU_SENTINEL_RE.findall(value))
            allowed = (
                {"lua_version"}
                if semantics[tra_id] == "installer.luajit.required_version"
                else set()
            )
            missing = allowed - sentinels
            unexpected = sentinels - allowed
            assert not missing, (
                f"missing required WeiDU sentinel(s) in {catalog_path} @{tra_id}: "
                f"{sorted(missing)}"
            )
            assert not unexpected, (
                f"unexpected WeiDU sentinel(s) in {catalog_path} @{tra_id}: "
                f"{sorted(unexpected)}"
            )


@pytest.mark.parametrize(
    "value",
    [
        "Unmatched opening brace {name",
        "Unmatched closing brace name}",
        "Doubled braces {{name}}",
    ],
)
def test_named_placeholder_validation_rejects_unmatched_and_doubled_braces(
    value: str,
):
    with pytest.raises(ValueError, match="malformed named placeholder"):
        validate_named_placeholders(value)


def test_catalog_named_placeholders_are_well_formed():
    for catalog_path in shipped_catalogs():
        catalog, _ = parse_tra(catalog_path)
        for tra_id, value in catalog.items():
            try:
                validate_named_placeholders(value)
            except ValueError as error:
                raise AssertionError(
                    f"malformed named placeholder in {catalog_path} @{tra_id}"
                ) from error
