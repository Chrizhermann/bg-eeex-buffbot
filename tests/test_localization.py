from __future__ import annotations

import faulthandler
import re
import sys
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LANG_ROOT = ROOT / "buffbot" / "lang"
LOC_PATH = ROOT / "buffbot" / "BfBotLoc.lua"
MAIN_PATH = ROOT / "buffbot" / "M_BfBot.lua"
DEPLOY_PATH = ROOT / "tools" / "deploy.sh"
TP2_PATH = ROOT / "buffbot" / "setup-buffbot.tp2"

ENTRY_RE = re.compile(r"^@(\d+)\s*=\s*~([^~]*)~\s*$")
EMPTY_ID_RE = re.compile(r"^@\s*=", re.ASCII)
SEMANTIC_COMMENT_RE = re.compile(r"^//\s*([a-z][a-z0-9_.]*)\s*$")
NAMED_PLACEHOLDER_RE = re.compile(r"\{([a-z][a-z0-9_]*)\}")
WEIDU_SENTINEL_RE = re.compile(r"%([A-Za-z_][A-Za-z0-9_]*)%")
WEIDU_PLACEHOLDER_CONTRACT = {108: {"lua_version"}}


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


def weidu_placeholders(value: str) -> set[str]:
    return set(WEIDU_SENTINEL_RE.findall(value))


def validate_weidu_placeholder_contract(catalog: dict[int, str]) -> None:
    for tra_id, value in catalog.items():
        expected = WEIDU_PLACEHOLDER_CONTRACT.get(tra_id, set())
        actual = weidu_placeholders(value)
        if actual != expected:
            raise ValueError(
                f"WeiDU placeholder mismatch at @{tra_id}: "
                f"expected {sorted(expected)}, got {sorted(actual)}"
            )


def shipped_catalogs() -> list[Path]:
    return sorted(LANG_ROOT.glob("*/setup.tra"))


def runtime_catalog_contract() -> dict[int, tuple[str, str]]:
    english, semantics = parse_tra(LANG_ROOT / "english" / "setup.tra")
    return {
        tra_id: (semantics[tra_id], english[tra_id])
        for tra_id in english
        if not semantics[tra_id].startswith("installer.")
    }


def localization_source() -> str:
    assert LOC_PATH.is_file(), "BfBotLoc.lua is missing"
    return LOC_PATH.read_text(encoding="utf-8")


def localization_runtime(
    map_text: str | None = None,
    fetch_source: str | None = None,
) -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.globals().test_map_text = map_text
    runtime.execute(
        """
        BfBot = {}
        test_warnings = {}
        BfBot._Warn = function(message)
            test_warnings[#test_warnings + 1] = message
        end

        if test_map_text == nil then
            io = nil
        else
            test_open_count = 0
            io = {
                open = function(path, mode)
                    test_open_count = test_open_count + 1
                    assert(path == "override/bfbot_l10n.txt")
                    assert(mode == "r")
                    local closed = false
                    return {
                        read = function(self, format)
                            assert(not closed)
                            assert(format == "*a")
                            return test_map_text
                        end,
                        close = function(self)
                            assert(not closed)
                            closed = true
                        end,
                    }
                end,
            }
        end
        """
    )
    if fetch_source is not None:
        runtime.execute(fetch_source)
    runtime.execute(localization_source())
    return runtime


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
            assert weidu_placeholders(catalog[tra_id]) == weidu_placeholders(
                english[tra_id]
            ), f"WeiDU placeholder mismatch in {catalog_path} @{tra_id}"


@pytest.mark.parametrize(
    "bad_value",
    (
        "Required LuaVersionExternal",
        "Required LuaVersionExternal: %runtime_version%",
    ),
    ids=("omitted", "renamed"),
)
def test_weidu_placeholder_contract_rejects_omitted_or_renamed_required_token(
    bad_value: str,
):
    with pytest.raises(ValueError, match=r"WeiDU placeholder mismatch at @108"):
        validate_weidu_placeholder_contract({108: bad_value})


def test_catalog_values_contain_no_legacy_or_unresolved_sentinels():
    for catalog_path in shipped_catalogs():
        catalog, _ = parse_tra(catalog_path)
        validate_weidu_placeholder_contract(catalog)
        for tra_id, value in catalog.items():
            assert "BFBOTUITRA_" not in value, f"legacy marker in {catalog_path} @{tra_id}"
            assert not re.search(r"@\d+", value), f"raw TRA ref in {catalog_path} @{tra_id}"


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


def test_runtime_registry_exactly_matches_non_installer_catalog_contract():
    runtime = localization_runtime()
    registry = runtime.globals().BfBot.L10N._Registry

    actual: dict[int, tuple[str, str]] = {}
    for key, entry in registry.items():
        tra_id = entry["id"]
        assert tra_id not in actual, f"duplicate runtime catalog id {tra_id}"
        actual[tra_id] = (key, entry["fallback"])

    assert actual == runtime_catalog_contract()


def test_raw_runtime_without_io_or_map_uses_english_fallback():
    runtime = localization_runtime()

    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "Reset"
    assert runtime.eval('BfBot.L10N.StrRef("common.reset")') is None


def test_valid_map_fetches_selected_tlk_string_only_once_per_key():
    runtime = localization_runtime(
        "305=1234\n",
        """
        test_fetch_count = 0
        Infinity_FetchString = function(strref)
            test_fetch_count = test_fetch_count + 1
            assert(strref == 1234)
            return "重置"
        end
        """,
    )

    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "重置"
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "重置"
    assert runtime.globals().test_fetch_count == 1
    assert runtime.globals().test_open_count == 1


def test_engine_invalid_strref_sentinel_uses_cached_english_fallback():
    runtime = localization_runtime(
        "305=1234\n",
        """
        test_fetch_count = 0
        Infinity_FetchString = function(strref)
            test_fetch_count = test_fetch_count + 1
            return "Invalid: " .. tostring(strref)
        end
        """,
    )

    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "Reset"
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "Reset"
    assert runtime.globals().test_fetch_count == 1


def test_failed_empty_and_invalid_map_resolutions_cache_english_fallbacks():
    runtime = localization_runtime(
        "\n".join(
            [
                "300=900",
                "301=901",
                "302=902",
                "303=not_a_strref",
                "304=904",
                "305=-1",
                "306=1.5",
                "307=999999999999999999999999999999999999999",
            ]
        ),
        """
        test_fetch_counts = {}
        Infinity_FetchString = function(strref)
            test_fetch_counts[strref] = (test_fetch_counts[strref] or 0) + 1
            if strref == 900 then return nil end
            if strref == 901 then error("synthetic TLK failure") end
            if strref == 902 then return "" end
            if strref == 904 then return 17 end
            error("invalid strref reached fetch: " .. tostring(strref))
        end
        """,
    )

    expected = {
        "common.buffbot": "BuffBot",
        "common.party": "Party",
        "common.summons": "Summons",
        "common.self": "Self",
        "common.none": "None",
        "common.reset": "Reset",
        "common.rename": "Rename",
        "common.new": "New",
    }
    # A deliberately raised LuaJIT error is contained by BfBotLoc's pcall, but
    # Windows reports the handled SEH transition through pytest's faulthandler.
    suppress_fault_handler = sys.platform == "win32" and faulthandler.is_enabled()
    if suppress_fault_handler:
        faulthandler.disable()
    try:
        for key, fallback in expected.items():
            get = runtime.globals().BfBot.L10N.Get
            assert get(key) == fallback
            assert get(key) == fallback
    finally:
        if suppress_fault_handler:
            faulthandler.enable()

    assert runtime.eval("test_fetch_counts[900]") == 1
    assert runtime.eval("test_fetch_counts[901]") == 1
    assert runtime.eval("test_fetch_counts[902]") == 1
    assert runtime.eval("test_fetch_counts[904]") == 1
    assert runtime.eval("test_fetch_counts[-1]") is None


def test_format_reorders_named_placeholders_and_preserves_literal_percent_values():
    runtime = localization_runtime(
        "404=1200\n",
        """
        Infinity_FetchString = function(strref)
            assert(strref == 1200)
            return "{preset}：{summon}"
        end
        """,
    )

    formatted = runtime.globals().BfBot.L10N.Format(
        "ui.title.summon_preset",
        runtime.table_from({"summon": "分身 100%", "preset": "%Boss%"}),
    )
    assert formatted == "%Boss%：分身 100%"


def test_format_keeps_missing_template_values_visible():
    runtime = localization_runtime()

    formatted = runtime.globals().BfBot.L10N.Format(
        "ui.title.summon_preset",
        runtime.table_from({"summon": "Clone"}),
    )
    assert formatted == "BuffBot - Clone - {preset}"


def test_unknown_key_returns_marker_and_warns_only_once_when_available():
    runtime = localization_runtime()
    get = runtime.globals().BfBot.L10N.Get

    marker = get("unknown.player_text")
    assert "unknown.player_text" in marker
    assert "missing" in marker.lower()
    assert get("unknown.player_text") == marker
    assert runtime.eval("#test_warnings") == 1

    runtime.execute("BfBot._Warn = nil")
    assert "another.unknown" in get("another.unknown")


def test_strref_returns_only_valid_mapped_numeric_references():
    runtime = localization_runtime("200=42\n201=-2\n202=not_a_number\n")
    strref = runtime.globals().BfBot.L10N.StrRef

    assert strref("innate.preset_1") == 42
    assert strref("innate.preset_2") is None
    assert strref("innate.preset_3") is None
    assert strref("unknown.player_text") is None


def test_map_content_is_parsed_as_data_and_never_executed():
    runtime = localization_runtime(
        "305=77\nBfBot.localization_map_was_executed=1\n",
        "Infinity_FetchString = function(_) return 'Mapped Reset' end",
    )

    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "Mapped Reset"
    assert runtime.eval("BfBot.localization_map_was_executed") is None


def test_runtime_module_compiles_under_luajit21():
    runtime = LuaRuntime(unpack_returned_tuples=True)
    compile_chunk = runtime.eval(
        "function(source) local chunk, err = loadstring(source); return chunk, err end"
    )

    chunk, error = compile_chunk(localization_source())
    assert chunk is not None, error


def test_bootstrap_loads_core_then_localization_before_all_consumers():
    source = MAIN_PATH.read_text(encoding="utf-8")

    core_pos = source.index('Infinity_DoFile("BfBotCor")')
    loc_pos = source.index('Infinity_DoFile("BfBotLoc")')
    no_luajit_pos = source.index("if BfBot._noIO then")
    theme_pos = source.index('Infinity_DoFile("BfBotThm")')
    assert core_pos < loc_pos < no_luajit_pos < theme_pos


def test_deploy_verifies_and_copies_runtime_localization_module():
    source = DEPLOY_PATH.read_text(encoding="utf-8")
    file_loops = re.findall(r"for f in ([^;]+); do", source)

    assert len(file_loops) >= 2
    assert "BfBotLoc.lua" in file_loops[0].split()
    assert "BfBotLoc.lua" in file_loops[1].split()


def test_installer_localization_contract_uses_catalog_refs_and_explicit_sparse_map():
    source = TP2_PATH.read_text(encoding="utf-8")
    language_pos = source.index("LANGUAGE")
    helper_label_pos = source.index("LABEL ~BuffBot-LuaJIT~")

    assert source.index("ALWAYS") < language_pos < helper_label_pos
    assert source[:language_pos].rstrip().endswith("END")
    assert "~buffbot/lang/english/setup.tra~" in source
    assert "~buffbot/lang/schinese/setup.tra~" in source
    assert "BEGIN @100" in source
    assert "BEGIN @111" in source
    expected_installer_ref_counts = {
        100: 1,
        101: 2,
        102: 2,
        **{catalog_id: 1 for catalog_id in range(103, 113)},
    }
    english, _ = parse_tra(LANG_ROOT / "english" / "setup.tra")
    for catalog_id in range(100, 113):
        assert (
            source.count(f"@{catalog_id}")
            == expected_installer_ref_counts[catalog_id]
        )
        assert english[catalog_id] not in source

    runtime_ids = {
        catalog_id
        for catalog_id, semantic_key in CATALOG_SCHEMA.items()
        if not semantic_key.startswith("installer.")
    }
    resolved_ids = {
        int(catalog_id)
        for catalog_id in re.findall(r"RESOLVE_STR_REF\(@(\d+)\)", source)
    }
    emitted_ids = {
        int(catalog_id)
        for catalog_id in re.findall(
            r"(?m)^(\d+)=%bfbot_l10n_\d+%$", source
        )
    }
    assert runtime_ids <= resolved_ids
    assert emitted_ids == runtime_ids
    assert "COPY ~buffbot/BfBotLoc.lua~" in source
