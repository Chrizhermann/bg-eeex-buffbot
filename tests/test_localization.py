from __future__ import annotations

import hashlib
import re
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LANG_ROOT = ROOT / "buffbot" / "lang"
LOC_PATH = ROOT / "buffbot" / "BfBotLoc.lua"
MAIN_PATH = ROOT / "buffbot" / "M_BfBot.lua"
DEPLOY_PATH = ROOT / "tools" / "deploy.sh"
TP2_PATH = ROOT / "buffbot" / "setup-buffbot.tp2"
PERSIST_PATH = ROOT / "buffbot" / "BfBotPer.lua"
EXEC_PATH = ROOT / "buffbot" / "BfBotExe.lua"
INNATE_PATH = ROOT / "buffbot" / "BfBotInn.lua"
UI_PATH = ROOT / "buffbot" / "BfBotUI.lua"
THEME_PATH = ROOT / "buffbot" / "BfBotThm.lua"
MENU_PATH = ROOT / "buffbot" / "BuffBot.menu"
CHANGELOG_PATH = ROOT / "CHANGELOG.md"
FULL_LOCALIZATION_DESIGN_PATH = (
    ROOT / "docs/plans/2026-08-21-full-localization-design.md"
)
FULL_LOCALIZATION_PLAN_PATH = ROOT / "docs/plans/2026-08-21-full-localization.md"
FILE_BACKED_DESIGN_PATH = (
    ROOT / "docs/plans/2026-08-22-file-backed-runtime-localization-design.md"
)
FILE_BACKED_PLAN_PATH = (
    ROOT / "docs/plans/2026-08-22-file-backed-runtime-localization.md"
)

ENTRY_RE = re.compile(r"^@(\d+)\s*=\s*~([^~]*)~\s*$")
EMPTY_ID_RE = re.compile(r"^@\s*=", re.ASCII)
SEMANTIC_COMMENT_RE = re.compile(r"^//\s*([a-z][a-z0-9_.]*)\s*$")
NAMED_PLACEHOLDER_RE = re.compile(r"\{([a-z][a-z0-9_]*)\}")
WEIDU_SENTINEL_RE = re.compile(r"%([A-Za-z_][A-Za-z0-9_]*)%")
WEIDU_PLACEHOLDER_CONTRACT = {108: {"lua_version"}}


# Catalog IDs are deliberately grouped so the Lua registry and selected catalog
# can be audited against translator-facing semantic comments.
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
    113: "installer.catalog_directory",
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
    452: "ui.repeat.compact",
    453: "ui.lock.compact",
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
        if not semantics[tra_id].startswith(("installer.", "innate."))
    }


def localization_source() -> str:
    assert LOC_PATH.is_file(), "BfBotLoc.lua is missing"
    return LOC_PATH.read_text(encoding="utf-8")


def localization_runtime(
    catalog_text: str | None = None,
    *,
    open_succeeds: bool = True,
) -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.globals().test_catalog_text = catalog_text
    runtime.globals().test_open_succeeds = open_succeeds
    runtime.execute(
        """
        BfBot = {}
        test_warnings = {}
        test_open_count = 0
        test_fetch_count = 0
        BfBot._Warn = function(message)
            test_warnings[#test_warnings + 1] = message
        end
        Infinity_FetchString = function(...)
            test_fetch_count = test_fetch_count + 1
            error("runtime localization must not call Infinity_FetchString")
        end

        if test_catalog_text == nil then
            io = nil
        else
            io = {
                open = function(path, mode)
                    test_open_count = test_open_count + 1
                    assert(path == "override/bfbot_l10n.tra")
                    assert(mode == "r")
                    if not test_open_succeeds then return nil end
                    local closed = false
                    return {
                        read = function(self, format)
                            assert(not closed)
                            assert(format == "*a")
                            return test_catalog_text
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


def test_text_size_descriptions_disclose_fixed_engine_button_captions():
    english, _ = parse_tra(ROOT / "buffbot/lang/english/setup.tra")
    chinese, _ = parse_tra(ROOT / "buffbot/lang/schinese/setup.tra")

    assert "all panel text" not in english[709].lower()
    assert "stone-button captions remain at the engine's default size" in english[
        709
    ].lower()
    assert "close and reopen" not in english[709].lower()
    assert "石质按钮上的文字" in chinese[709]
    assert "引擎默认字号" in chinese[709]
    assert "关闭并重新打开" not in chinese[709]


def test_catalog_directory_metadata_is_safe_and_matches_its_language_folder():
    for catalog_path in shipped_catalogs():
        catalog, semantics = parse_tra(catalog_path)
        directory = catalog[113]

        assert semantics[113] == "installer.catalog_directory"
        assert directory == catalog_path.parent.name
        assert re.fullmatch(r"[a-z][a-z0-9_]*", directory, re.ASCII)


def test_reviewed_english_and_chinese_ui_wording_is_exact():
    english, _ = parse_tra(LANG_ROOT / "english" / "setup.tra")
    chinese, _ = parse_tra(LANG_ROOT / "schinese" / "setup.tra")

    assert english[308] == "Add Spell/Item"
    assert english[416] == "Add Spell or Item to Buff List"
    assert english[452] == "R{count}"
    assert english[453] == "[L]"
    for tra_id in (505, 507, 510, 514, 543, 551):
        assert "spell" in english[tra_id].lower()
        assert "item" in english[tra_id].lower()

    assert chinese[308] == "添加法术/物品"
    assert chinese[409] == "全部执行"
    assert chinese[410] == "执行：当前角色"
    assert chinese[411] == "执行：{name}"
    assert chinese[412] == "执行：当前召唤物"
    assert chinese[428] == "执行中……"
    assert chinese[429] == "执行中（快速施法：仅长效）……"
    assert chinese[430] == "执行中（快速施法：全部）……"
    assert chinese[442] == "{hours}时{minutes}分"
    assert chinese[443] == "{hours}时"
    assert chinese[444] == "{minutes}分{seconds}秒"
    assert chinese[445] == "{minutes}分"
    assert chinese[446] == "{seconds}秒"
    assert chinese[452] == "{count}次"
    assert chinese[453] == "[锁]"
    for tra_id in (500, 504, 506):
        assert "特殊能力" in chinese[tra_id]
        assert "天生能力" not in chinese[tra_id]
    for tra_id in (509, 550):
        assert "本体受投影术限制" in chinese[tra_id]
    for tra_id in (505, 507, 510, 514, 543, 551):
        assert "法术" in chinese[tra_id]
        assert "物品" in chinese[tra_id]


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


def test_runtime_registry_exactly_matches_runtime_only_catalog_contract():
    runtime = localization_runtime()
    registry = runtime.globals().BfBot.L10N._Registry

    actual: dict[int, tuple[str, str]] = {}
    for key, entry in registry.items():
        tra_id = entry["id"]
        assert tra_id not in actual, f"duplicate runtime catalog id {tra_id}"
        actual[tra_id] = (key, entry["fallback"])

    assert actual == runtime_catalog_contract()


def test_innate_only_catalog_rows_are_not_registered_or_runtime_addressable():
    runtime = localization_runtime(
        "@200 = ~poisoned runtime innate name~\n@305 = ~Selected Reset~\n"
    )

    assert runtime.eval('BfBot.L10N._Registry["innate.preset_1"]') is None
    unknown = runtime.eval('BfBot.L10N.Get("innate.preset_1")')
    assert "innate.preset_1" in unknown
    assert "missing" in unknown.lower()
    assert "poisoned runtime innate name" not in unknown
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "Selected Reset"
    assert runtime.globals().test_open_count == 1
    assert runtime.globals().test_fetch_count == 0


def test_selected_utf8_catalog_is_loaded_and_cached_without_native_tlk_access():
    runtime = localization_runtime(
        "@305 = ~重置~\n@404 = ~{preset}：{summon}~\n"
    )

    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "重置"
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "重置"
    assert runtime.eval('BfBot.L10N.Get("ui.title.summon_preset")') == (
        "{preset}：{summon}"
    )
    assert runtime.globals().test_open_count == 1
    assert runtime.globals().test_fetch_count == 0


@pytest.mark.parametrize("catalog_path", shipped_catalogs())
def test_runtime_serves_every_registered_value_from_each_shipped_catalog(
    catalog_path: Path,
):
    catalog, _ = parse_tra(catalog_path)
    runtime = localization_runtime(catalog_path.read_text(encoding="utf-8"))
    registry = runtime.globals().BfBot.L10N._Registry

    seen = 0
    for key, entry in registry.items():
        assert runtime.globals().BfBot.L10N.Get(key) == catalog[entry["id"]]
        seen += 1

    assert seen == len(runtime_catalog_contract())
    assert runtime.globals().test_open_count == 1
    assert runtime.globals().test_fetch_count == 0


def test_catalog_parser_ignores_unknown_empty_malformed_and_interior_tilde_rows():
    runtime = localization_runtime(
        "\n".join(
            (
                "// comment",
                "@305 = ~重置~",
                "@305 = ~second value must lose~",
                "@9999 = ~ignored~",
                "@306 = ~   ~",
                "@307 = ~contains ~ tilde~",
                "@308 = ~valid value~ trailing",
                "@309 = valid value without delimiters",
                "@310 = ~~",
                "not a TRA row",
            )
        )
    )

    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "重置"
    assert runtime.eval('BfBot.L10N.Get("common.rename")') == "Rename"
    assert runtime.eval('BfBot.L10N.Get("common.new")') == "New"
    assert runtime.eval('BfBot.L10N.Get("common.add_spell")') == "Add Spell/Item"
    assert runtime.eval('BfBot.L10N.Get("common.remove")') == "Remove"
    assert runtime.eval('BfBot.L10N.Get("common.export")') == "Export"
    assert runtime.globals().test_open_count == 1
    assert runtime.globals().test_fetch_count == 0


@pytest.mark.parametrize(
    ("catalog_text", "open_succeeds"),
    ((None, True), ("", False), ("", True)),
    ids=("io-missing", "open-failed", "empty-catalog"),
)
def test_missing_io_or_catalog_uses_complete_english_fallback(
    catalog_text: str | None,
    open_succeeds: bool,
):
    runtime = localization_runtime(catalog_text, open_succeeds=open_succeeds)
    registry = runtime.globals().BfBot.L10N._Registry

    for key, entry in registry.items():
        assert runtime.globals().BfBot.L10N.Get(key) == entry["fallback"]

    assert runtime.globals().test_open_count == (0 if catalog_text is None else 1)
    assert runtime.globals().test_fetch_count == 0


def test_format_reorders_named_placeholders_and_preserves_literal_percent_values():
    runtime = localization_runtime(
        "@404 = ~{preset}：{summon}~\n"
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


def test_reason_formatter_localizes_registered_codes_and_preserves_legacy_prose():
    runtime = localization_runtime()
    reason = runtime.globals().BfBot.L10N.Reason

    assert reason(
        "reason.queue.no_preset_for_slot",
        runtime.table_from({"preset": 3, "slot": 1}),
    ) == "no preset 3 for slot 1"
    assert reason(
        "reason.import.cannot_open_file",
        runtime.table_from({"error": "denied 100%"}),
    ) == "cannot open file: denied 100%"
    assert reason("legacy hot-reload prose", runtime.table()) == (
        "legacy hot-reload prose"
    )
    assert reason(None, runtime.table()) is None

    missing_detail = reason(
        "reason.queue.no_preset_for_slot", runtime.table_from({"slot": 1})
    )
    assert "{preset}" not in missing_detail
    assert "reason.queue.no_preset_for_slot" in missing_detail

    unknown = reason("reason.future.unknown", runtime.table())
    assert "reason.future.unknown" in unknown
    assert "missing" in unknown.lower()


def test_reason_registry_recognizer_and_producers_have_exact_parity():
    runtime = localization_runtime()
    registry = runtime.globals().BfBot.L10N._Registry
    registered = {
        key for key in registry.keys() if key.startswith("reason.")
    }

    localization_source = LOC_PATH.read_text(encoding="utf-8")
    reason_map = re.search(
        r"local _reasonKeys = \{(?P<body>.*?)\n\}",
        localization_source,
        re.DOTALL,
    )
    assert reason_map is not None
    recognized_pairs = re.findall(
        r'\["(reason\.[a-z0-9_.]+)"\]\s*=\s*'
        r'"(reason\.[a-z0-9_.]+)"',
        reason_map.group("body"),
    )
    recognized = {code for code, _ in recognized_pairs}
    assert len(recognized_pairs) == len(recognized)
    assert all(code == key for code, key in recognized_pairs)

    producer_pattern = re.compile(
        r'\breturn\s+(?:nil|false)\s*,\s*'
        r'["\'](reason\.[a-z0-9_.]+)["\']'
    )
    produced = set()
    for path in (PERSIST_PATH, EXEC_PATH):
        produced.update(
            producer_pattern.findall(path.read_text(encoding="utf-8"))
        )

    assert len(registered) == 32
    assert registered == recognized == produced


def test_catalog_values_are_returned_literally_and_never_executed_as_lua():
    runtime = localization_runtime(
        '@305 = ~"; test_catalog_code_executed = 1; --~\n'
    )

    assert runtime.eval('BfBot.L10N.Get("common.reset")') == (
        '"; test_catalog_code_executed = 1; --'
    )
    assert runtime.globals().test_catalog_code_executed is None
    assert runtime.globals().test_fetch_count == 0


def test_runtime_module_compiles_under_luajit21():
    runtime = LuaRuntime(unpack_returned_tuples=True)
    compile_chunk = runtime.eval(
        "function(source) local chunk, err = loadstring(source); return chunk, err end"
    )

    chunk, error = compile_chunk(localization_source())
    assert chunk is not None, error


def test_persistence_public_failures_use_catalog_reason_codes():
    source = PERSIST_PATH.read_text(encoding="utf-8")
    returned_failure_codes = set(
        re.findall(r'return\s+(?:false|nil),\s*"([^"]+)"', source)
    )
    expected_failure_codes = {
        CATALOG_SCHEMA[tra_id] for tra_id in range(523, 552)
    }

    assert returned_failure_codes == expected_failure_codes


def test_bootstrap_loads_core_then_localization_before_all_consumers():
    source = MAIN_PATH.read_text(encoding="utf-8")

    assert "file-backed localization with English fallback" in source
    core_pos = source.index('Infinity_DoFile("BfBotCor")')
    loc_pos = source.index('Infinity_DoFile("BfBotLoc")')
    no_luajit_pos = source.index("if BfBot._noIO then")
    theme_pos = source.index('Infinity_DoFile("BfBotThm")')
    assert core_pos < loc_pos < no_luajit_pos < theme_pos


def test_localization_source_has_no_native_fetch_or_activation_boundary():
    loc = LOC_PATH.read_text(encoding="utf-8")
    ui = UI_PATH.read_text(encoding="utf-8")

    assert "Infinity_FetchString" not in loc
    assert "L10N.Activate" not in loc
    assert "L10N.Activate" not in ui
    assert "_l10nTlkReady" not in loc
    assert "_l10nTlkReady" not in ui
    assert "BfBot.L10N.StrRef" not in loc


def test_deploy_verifies_and_copies_runtime_localization_module():
    source = DEPLOY_PATH.read_text(encoding="utf-8")
    file_loops = re.findall(r"for f in ([^;]+); do", source)

    assert source.startswith("#!/bin/bash\nset -e\n")
    assert len(file_loops) >= 2
    assert "BfBotLoc.lua" in file_loops[0].split()
    assert "BfBotLoc.lua" in file_loops[1].split()
    assert "bfbot_l10n.tra" in source
    assert "preserving existing WeiDU-selected runtime catalog" in source
    assert "English fallback" in source
    assert "setup.tra" not in source
    assert 'PATCH_TLK_SCRIPT="$SCRIPT_DIR/patch_tlk.py"' in source
    assert '[ ! -f "$PATCH_TLK_SCRIPT" ]' in source


def test_installer_localization_contract_copies_selected_catalog_and_resolves_only_innates():
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

    assert source.count("@113") == 1
    assert "OUTER_SPRINT bfbot_selected_language @113" in source
    resolved_ids = re.findall(r"RESOLVE_STR_REF\(@(\d+)\)", source)
    assert resolved_ids == [str(catalog_id) for catalog_id in range(200, 208)]
    selected_copy = re.search(
        r"COPY\s+~buffbot/lang/%bfbot_selected_language%/setup\.tra~\s+"
        r"~override/bfbot_l10n\.tra~",
        source,
    )
    assert selected_copy is not None
    following_copy = source.index("COPY ~buffbot/BfBotCls.lua~", selected_copy.end())
    assert "EVALUATE_BUFFER" not in source[selected_copy.start():following_copy]
    assert "bfbot_l10n.generated" not in source
    assert "bfbot_l10n.txt" not in source
    assert "bfbot_l10n_" not in source
    assert "COPY ~buffbot/BfBotLoc.lua~" in source


def test_localization_documentation_describes_the_selected_directory_marker():
    design = FILE_BACKED_DESIGN_PATH.read_text(encoding="utf-8")
    plan = FILE_BACKED_PLAN_PATH.read_text(encoding="utf-8")

    for source in (design, plan):
        assert "@113" in source
        assert "OUTER_SPRINT" in source
        assert "%bfbot_selected_language%" in source
        assert "non-translatable" in source.casefold()
        assert "WeiDU 249" in source
        assert "%LANGUAGE%" in source
        assert "same-process" in source.casefold()


def test_file_backed_plan_documentation_names_real_tests_and_truthful_atomic_stage_set():
    source = FILE_BACKED_PLAN_PATH.read_text(encoding="utf-8")
    task_1 = source.split("### Task 1:", 1)[1].split("### Task 2:", 1)[0]
    task_2 = source.split("### Task 2:", 1)[1].split("### Task 3:", 1)[0]

    assert "tests/test_repeat_ui.py" in task_1
    assert "tests/test_ui_selection.py" in task_1
    assert "tests/test_repeat_counts.py" not in task_1
    assert "tests/test_selection_refresh.py" not in task_1

    assert "buffbot/M_BfBot.lua" in task_2
    assert "buffbot/lang/english/setup.tra" in task_2
    assert "buffbot/lang/schinese/setup.tra" in task_2
    assert "buffbot/BfBotUI.lua" not in task_2


def test_historical_localization_documentation_uses_banners_not_rewrites():
    design = FULL_LOCALIZATION_DESIGN_PATH.read_text(encoding="utf-8")
    plan = FULL_LOCALIZATION_PLAN_PATH.read_text(encoding="utf-8")

    for source in (design, plan):
        opening = "\n".join(source.splitlines()[:8])
        assert "**SUPERSEDED**" in opening
        assert "2026-08-22-file-backed-runtime-localization-design.md" in opening
        assert "historical" in opening.casefold()

    old_architecture = "TLK-backed " + "runtime localization"
    assert f"### {old_architecture} (selected)" in design
    assert f"### Task 2: Build the {old_architecture} API" in plan


def test_current_facing_localization_sections_state_file_and_tlk_ownership():
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    languages = readme.split("## Languages", 1)[1].split("## Installation", 1)[0]
    assert "`override/bfbot_l10n.tra`" in languages
    assert "no BuffBot-owned UI string is fetched from the game TLK" in languages
    assert "Only the eight generated F12 innate names remain TLK-backed" in languages

    changelog = CHANGELOG_PATH.read_text(encoding="utf-8")
    unreleased = changelog.split("## Unreleased", 1)[1].split("\n## ", 1)[0]
    assert "Runtime UI localization is file-backed" in unreleased
    assert "`override/bfbot_l10n.tra`" in unreleased
    assert "Only the eight generated F12 SPL names remain TLK-backed" in unreleased

    design = FILE_BACKED_DESIGN_PATH.read_text(encoding="utf-8")
    decision = design.split("## Decision", 1)[1].split("## Considered Approaches", 1)[0]
    normalized_decision = " ".join(decision.split())
    assert "will not use `Infinity_FetchString` for UI" in normalized_decision
    assert "selected UTF-8 `.tra` catalog" in normalized_decision
    assert "eight generated F12 innate spell names" in normalized_decision

    plan = FILE_BACKED_PLAN_PATH.read_text(encoding="utf-8")
    summary = plan.split("---", 1)[0]
    assert "selected UTF-8 runtime catalog" in summary
    assert "retaining TLK ownership only for generated innate SPL names" in summary


def test_unreleased_changelog_records_final_automated_and_live_boundary():
    source = CHANGELOG_PATH.read_text(encoding="utf-8")
    unreleased = source.split("## Unreleased", 1)[1].split("\n## ", 1)[0]
    normalized = unreleased.casefold()

    assert "native startup crash" in normalized
    assert "infinity_fetchstring" in normalized
    assert "file-backed" in normalized
    assert "override/bfbot_l10n.tra" in normalized
    assert "@200" in unreleased and "@207" in unreleased
    assert "bfbot_strrefs.txt" in normalized
    assert "WeiDU 249" in unreleased
    assert "map-backed candidate migration" in normalized
    assert "ownership" in normalized and "restor" in normalized
    assert "full automated suite passes **408 tests**" in normalized
    assert "live validation (2026-08-22)" in normalized
    assert "copy copy" in normalized
    assert "readable cjk" in normalized
    assert "tested resolution/font" in normalized
    assert "stone-button captions" in normalized
    assert "engine's default size" in normalized
    assert "automated english startup" in normalized
    assert "no explicit english visual sign-off" in normalized
    assert "still pending" in normalized
    for pending in (
        "interaction/casting matrix",
        "project image",
        "non-ascii import/export",
        "save/reload",
        "area-transition",
        "bg1ee",
        "eet",
        "alternate resolutions",
        "project infinity",
    ):
        assert pending in normalized


def test_all_literal_runtime_localization_keys_exist_and_dynamic_calls_are_explicit():
    runtime_keys = {
        semantic_key
        for semantic_key, _ in runtime_catalog_contract().values()
    }
    assert not any(
        key.startswith(("installer.", "innate.")) for key in runtime_keys
    )
    sources = {
        path: path.read_text(encoding="utf-8")
        for path in (
            MAIN_PATH,
            EXEC_PATH,
            INNATE_PATH,
            UI_PATH,
            THEME_PATH,
            MENU_PATH,
            PERSIST_PATH,
        )
    }
    literal_call = re.compile(
        r"BfBot\.L10N\.(?:Get|Format)\(\s*(['\"])([a-z][a-z0-9_.]*)\1"
    )
    any_call = re.compile(r"BfBot\.L10N\.(?:Get|Format)\(\s*([^\s,)]+)")

    used_keys: set[str] = set()
    for path, source in sources.items():
        used_keys.update(match.group(2) for match in literal_call.finditer(source))
        for match in any_call.finditer(source):
            first_arg = match.group(1)
            assert first_arg[:1] in {'"', "'"}, (
                f"dynamic localization key in {path}: {first_arg}; "
                "use a literal key or an explicit checked mapping"
            )

    assert used_keys <= runtime_keys
    assert {
        "feedback.no_luajit",
        "feedback.combat_stopped",
        "feedback.cast_timeout",
        "ui.title.preset",
        "ui.title.summons",
        "ui.title.summon_preset",
        "ui.delete_preset_confirm",
        "ui.repeat.compact",
        "ui.lock.compact",
        "options.text_size_large",
    } <= used_keys


def test_menu_has_no_static_alphabetic_player_labels_or_legacy_markers():
    source = MENU_PATH.read_text(encoding="utf-8")
    static_text = re.compile(r'(?m)^\s*text\s+(["\'])(.*?)\1\s*$')
    allowed_symbols = {"///", "<", ">"}

    for match in static_text.finditer(source):
        value = match.group(2)
        assert value in allowed_symbols or not re.search(r"[A-Za-z]", value), (
            f"static player-facing menu label is not localized: {value!r}"
        )
    assert "BFBOTUITRA_" not in source
    assert not re.search(r"(?<![A-Za-z0-9_])@\d+", source)


def test_menu_localization_does_not_change_actions_layout_or_list_structure():
    source = MENU_PATH.read_text(encoding="utf-8")
    normalized = "\n".join(
        line
        for line in source.splitlines()
        if not re.match(r"^\s*(?:text|tooltip)\b", line)
    ) + "\n"
    assert hashlib.sha256(normalized.encode("utf-8")).hexdigest() == (
        "bc9e7d88c60706d1eca3e393be8f8807d4c08a27d1fba709d18fadab93865380"
    )


def _menu_block(source: str, name: str) -> str:
    marker = f'name    "{name}"'
    marker_pos = source.index(marker)
    start = source.rfind("\nmenu\n{", 0, marker_pos)
    end = source.find("\nmenu\n{", marker_pos)
    assert start >= 0
    return source[start : end if end >= 0 else len(source)]


def test_spell_picker_name_column_keeps_dynamic_color_binding():
    picker = _menu_block(
        MENU_PATH.read_text(encoding="utf-8"), "BUFFBOT_SPELLPICKER"
    )
    name_expression = (
        'text lua "buffbot_pickerSpells[rowNumber] and '
        'buffbot_pickerSpells[rowNumber].name or \'\'"'
    )
    name_pos = picker.index(name_expression)
    label_end = picker.index("\n\t\t\t}", name_pos)
    name_label = picker[name_pos:label_end]

    assert (
        'text color lua "BfBot.UI._PickerNameColor(rowNumber)"'
        in name_label
    )


def test_spell_picker_count_expression_is_nil_safe_for_header_rows():
    picker = _menu_block(
        MENU_PATH.read_text(encoding="utf-8"), "BUFFBOT_SPELLPICKER"
    )
    count_expressions = re.findall(
        r'(?m)^\s*text lua "([^"\n]*buffbot_pickerSpells\[rowNumber\]'
        r'\.count[^"\n]*)"\s*$',
        picker,
    )
    assert len(count_expressions) == 1

    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        "buffbot_pickerSpells = { { isHeader = 1 } }; rowNumber = 1"
    )
    assert runtime.eval(count_expressions[0]) == ""

    runtime.execute("buffbot_pickerSpells[1] = { count = 3 }")
    assert runtime.eval(count_expressions[0]) == "x3"


def test_menu_lua_text_tooltip_action_and_enabled_chunks_compile_under_luajit():
    source = MENU_PATH.read_text(encoding="utf-8")
    runtime = LuaRuntime(unpack_returned_tuples=True)
    compile_chunk = runtime.eval(
        "function(source) local chunk, err = loadstring(source); return chunk, err end"
    )
    expression_props = re.findall(
        r'(?m)^\s*(?:text\s+lua|tooltip\s+lua|enabled|clickable\s+lua)\s+"([^"]*)"',
        source,
    )
    statement_props = re.findall(
        r'(?m)^\s*(?:action|actionAlt|actionDrag|onopen|onclose)\s+"([^"]*)"',
        source,
    )
    assert expression_props
    assert statement_props
    for expression in expression_props:
        chunk, error = compile_chunk("return " + expression)
        assert chunk is not None, f"menu expression failed to compile: {expression}: {error}"
    for statements in statement_props:
        chunk, error = compile_chunk(statements)
        assert chunk is not None, f"menu action failed to compile: {statements}: {error}"


def test_known_player_display_sinks_use_localization_not_raw_reason_codes():
    main = MAIN_PATH.read_text(encoding="utf-8")
    execution = EXEC_PATH.read_text(encoding="utf-8")
    innate = INNATE_PATH.read_text(encoding="utf-8")
    ui = UI_PATH.read_text(encoding="utf-8")

    assert 'Infinity_DisplayString("BuffBot:' not in main
    assert 'EEex_Sprite_DisplayStringHead(leader,\n                    "BuffBot:' not in execution
    assert 'BfBot._Display("BuffBot:' not in innate
    # ToggleDebug is an intentionally untranslated developer diagnostic.
    ui_without_debug = re.sub(
        r'BfBot\._Display\("BuffBot: Debug mode "[^\n]+', "", ui
    )
    assert 'BfBot._Display("BuffBot:' not in ui_without_debug
    assert 'Infinity_DisplayString("BuffBot:' not in ui
    assert 'reason == "not locally controlled"' not in ui
    assert 'reason == "puppet-locked"' not in ui
    assert '"empty queue"' not in execution
    assert '"no valid entries after expansion"' not in execution
    assert 'return false, "already running"' not in execution


def test_all_thirteen_eeex_options_strings_come_from_runtime_localization():
    source = THEME_PATH.read_text(encoding="utf-8")
    expected = {
        CATALOG_SCHEMA[catalog_id] for catalog_id in range(700, 713)
    }
    assignments = re.findall(
        r"uiStrings\.[A-Za-z0-9_]+\s*=\s*"
        r"BfBot\.L10N\.Get\(\s*['\"]([a-z][a-z0-9_.]*)['\"]\s*\)",
        source,
    )
    actual = set(assignments)
    assert len(assignments) == 13
    assert actual == expected


def test_per_frame_menu_text_helpers_use_precomputed_or_cached_templates():
    source = UI_PATH.read_text(encoding="utf-8")
    for helper in (
        "_VariantBtnText",
        "_TargetBtnText",
        "_RepeatButtonText",
        "_RepeatTooltip",
    ):
        start = source.index(f"function BfBot.UI.{helper}(")
        end = source.find("\nfunction BfBot.UI.", start + 1)
        body = source[start : end if end >= 0 else len(source)]
        assert "BfBot.L10N.Format" not in body, (
            f"{helper} is evaluated every frame; precompute or cache its template"
        )
