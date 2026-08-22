# Full Localization Implementation Plan

> **SUPERSEDED** — The runtime-TLK architecture in this document was replaced by [File-Backed Runtime Localization Correction](./2026-08-22-file-backed-runtime-localization-design.md) after live startup-crash evidence. The body below is preserved as a historical implementation record; use the correction for the current architecture.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Goal:** Add complete English and Simplified Chinese localization to current BuffBot without injecting translations into executable source or regressing installer/runtime safety.

**Architecture:** WeiDU resolves complete `.tra` catalogs into the selected game TLK and writes an ASCII-only numeric ID-to-strref map. `BfBotLoc.lua` maps semantic keys to catalog IDs, fetches/caches selected strings through `Infinity_FetchString`, expands named placeholders, and falls back to checked-in English. Lua and `.menu` code use this central API; persisted user names remain untouched.

**Tech Stack:** WeiDU 249, Lua 5.1/LuaJIT, EEex, Infinity Engine TLK, `.menu` DSL, Python/pytest/lupa, GitHub Actions, PowerShell/Git Bash.

---

### Task 1: Lock the catalog and contribution contract

**Files:**
- Create: `buffbot/lang/english/setup.tra`
- Create: `buffbot/lang/schinese/setup.tra`
- Create: `tests/test_localization.py`
- Reference: `origin/pr-50:buffbot/lang/{english,schinese}/setup.tra`

**Step 1: Write the failing catalog tests**

Add strict-UTF-8 TRA parsing that rejects duplicate/empty IDs and asserts:

```python
def test_all_shipped_catalogs_match_english_ids_and_placeholders():
    english = parse_tra(ROOT / "buffbot/lang/english/setup.tra")
    for catalog_path in shipped_catalogs():
        catalog = parse_tra(catalog_path)
        assert catalog.keys() == english.keys()
        for tra_id in english:
            assert named_placeholders(catalog[tra_id]) == named_placeholders(
                english[tra_id]
            )
```

Also reject legacy `BFBOTUITRA_*`, raw `@NNN`, and unresolved paired
`%variable%` sentinels inside runtime catalog values. Allow installer entries
that intentionally interpolate the documented `%lua_version%` variable.

**Step 2: Run the test to verify RED**

Run: `python -m pytest tests/test_localization.py -q`

Expected: FAIL because neither catalog exists.

**Step 3: Add the complete catalogs**

Create semantic groups for:

- installer component/predicate/progress text;
- eight generated innate names;
- common/menu/UI labels;
- complete named-placeholder templates;
- runtime feedback and stable reason messages;
- default preset names/categories;
- EEex Options labels/descriptions.

Use PR #50's Chinese strings as the starting contribution, correct its known
EEex typos, duplicate Cast Character meaning, missing self-only qualifier,
punctuation/counter issues, and expand it to every current player-facing key.
Do not carry any PR Lua/menu behavior edits.

**Step 4: Run the tests to verify GREEN**

Run: `python -m pytest tests/test_localization.py -q`

Expected: catalog parity tests PASS.

**Step 5: Commit**

```bash
git add buffbot/lang tests/test_localization.py
git commit -m "feat: add complete English and Chinese catalogs" \
  -m "Co-authored-by: robovoid <robovoid_dev@hotmail.com>"
```

### Task 2: Build the TLK-backed runtime localization API

**Files:**
- Create: `buffbot/BfBotLoc.lua`
- Modify: `tests/test_localization.py`
- Modify: `buffbot/M_BfBot.lua`
- Modify: `tools/deploy.sh`

**Step 1: Write failing runtime tests**

Use `lupa.luajit21.LuaRuntime` to load Core plus the proposed localization
module and prove:

- no map/no `io` returns English fallback;
- valid `catalog_id=strref` rows fetch the selected TLK string once per key;
- nil/error/empty/invalid strrefs fall back to English;
- `Format()` permits Chinese placeholder reordering;
- replacement values containing `%` are literal because `gsub` uses a
  function callback;
- a missing template value remains visible;
- an unknown key returns a conspicuous marker and warns once;
- source Lua parses under LuaJIT.

Desired API:

```lua
BfBot.L10N.Get("common.reset")
BfBot.L10N.Format("cast.named", { name = "Imoen" })
BfBot.L10N.StrRef("innate.preset_1")
```

**Step 2: Verify RED**

Run: `python -m pytest tests/test_localization.py -q`

Expected: FAIL because `buffbot/BfBotLoc.lua` and the API are missing.

**Step 3: Implement the minimum runtime module**

Define a registry whose entries contain semantic key, numeric catalog ID, and
English fallback. Read `override/bfbot_l10n.txt` as ASCII
`catalog_id=strref` pairs when `io` exists. Cache fetched strings separately
from the immutable English fallback. Do not execute or evaluate map contents.

Load `BfBotLoc` immediately after `BfBotCor` and before the no-LuaJIT notice,
Theme, persistence, and UI. Add `BfBotLoc.lua` to the deploy copy/verification
lists; a raw deploy deliberately has no generated map and therefore displays
English.

**Step 4: Verify GREEN and baseline behavior**

Run: `python -m pytest tests/test_localization.py tests/test_runtime_compatibility.py -q`

Expected: PASS.

**Step 5: Commit**

```bash
git add buffbot/BfBotLoc.lua buffbot/M_BfBot.lua tools/deploy.sh tests/test_localization.py
git commit -m "feat: add TLK-backed runtime localization"
```

### Task 3: Integrate language selection and mappings into the installer

**Files:**
- Modify: `buffbot/setup-buffbot.tp2`
- Modify: `tests/test_eeex_compatibility_installer.py`
- Modify: `tests/test_localization.py`

**Step 1: Write failing WeiDU language tests**

Extend `BuffBotGame` so synthetic games contain independent
`lang/en_US/dialog.tlk` and `lang/zh_CN/dialog.tlk` files and `run()` accepts:

```python
run_args(mod_language=0, game_language="en_US")
run_args(mod_language=1, game_language="zh_CN")
```

Parameterize a current-v1 fresh install for English and Chinese. Assert that:

- the active TLK receives exactly the selected catalog text;
- the inactive TLK remains byte-identical;
- `override/bfbot_l10n.txt` contains only unique numeric `id=strref` rows;
- each row dereferences to its selected TRA entry;
- mappings are not assumed contiguous;
- installed outputs contain no legacy marker or unresolved WeiDU token;
- helper component still executes before main.

**Step 2: Verify RED**

Run: `python -m pytest tests/test_eeex_compatibility_installer.py -q -k localization`

Expected: FAIL because TP2 has no `LANGUAGE` declarations or runtime map.

**Step 3: Implement WeiDU localization**

Place `LANGUAGE` declarations after the current `ALWAYS ... END` and before the
first component. Convert component names and every player-facing
`REQUIRE_PREDICATE`, `FAIL`, and `PRINT` to TRA references without changing
`DESIGNATED`, `LABEL`, component declaration order, helper ownership, or the
invocation-local legacy-upgrade proof.

Resolve every runtime ID independently with `RESOLVE_STR_REF(@id)` and emit
explicit `id=strref` lines into `override/bfbot_l10n.txt`. Localize the existing
eight innate `RESOLVE_STR_REF` inputs while retaining the separate
`bfbot_strrefs.txt` and its non-contiguous-ref invariant.

Update component-order tests to anchor on stable `LABEL`/`DESIGNATED` semantics
rather than translated display text.

**Step 4: Verify GREEN plus installer lifecycle**

Run: `python -m pytest tests/test_eeex_compatibility_installer.py tests/test_localization.py -q`

Expected: PASS in both languages and both EEex layouts.

**Step 5: Commit**

```bash
git add buffbot/setup-buffbot.tp2 tests/test_eeex_compatibility_installer.py tests/test_localization.py
git commit -m "feat: localize the WeiDU installer"
```

### Task 4: Remove locale-dependent Project Image safety detection

**Files:**
- Modify: `buffbot/BfBotCls.lua`
- Modify: `buffbot/BfBotScn.lua`
- Modify: `buffbot/BfBotPer.lua`
- Modify: `tests/test_runtime_compatibility.py`

**Step 1: Write the failing structural-detection tests**

Build synthetic feature-block seams that prove:

- opcode 236 with parameter 2 equal to `2` is Project Image regardless of
  display name/resref;
- opcode 236 type `1` (Mislead) and `3` (Simulacrum) are not;
- an opcode-146 wrapper reaches a Project Image child within the existing
  depth-2/cycle guard;
- a Chinese-named scan entry carrying `isProjectImage=1` retains one attempt
  and drops all trailing entries;
- a plain English name with no structural flag is not trusted.

**Step 2: Verify RED**

Run: `python -m pytest tests/test_runtime_compatibility.py -q -k project_image`

Expected: FAIL because the current policy matches the English display name.

**Step 3: Implement structural identity**

Add a bounded, cycle-guarded classifier helper that scans direct feature blocks
and opcode-146 child spells for opcode 236/image type 2. Put
`isProjectImage` on the class result and integer scan entry. Copy that flag onto
temporary party/summon queue entries. Make `_ApplyPuppetLockPolicy()` use only
the flag and update comments/log construction accordingly.

Do not hardcode `SPWI703`, a translated display name, or a Spell Revisions
resref.

**Step 4: Verify GREEN**

Run: `python -m pytest tests/test_runtime_compatibility.py tests/test_target_resolution.py -q`

Expected: PASS, including existing owner-lock and summon-chain coverage.

**Step 5: Commit**

```bash
git add buffbot/BfBotCls.lua buffbot/BfBotScn.lua buffbot/BfBotPer.lua tests/test_runtime_compatibility.py
git commit -m "fix: make Project Image safety locale independent"
```

### Task 5: Localize persistence defaults and stabilize reason contracts

**Files:**
- Modify: `buffbot/BfBotPer.lua`
- Modify: `tests/test_runtime_compatibility.py`
- Modify: `tests/test_localization.py`

**Step 1: Write failing persistence tests**

Cover:

- Chinese Long/Short defaults for a genuinely new config;
- existing, imported, inherited, and user-renamed preset names remain exact;
- sparse preset creation uses localized `Preset {index}` only at creation;
- queue/export/import failures return stable reason codes plus structured data,
  not English sentences consumed by UI branching;
- two party members with fully non-ASCII names do not both export as
  `Unknown.lua`; empty ASCII sanitization falls back to `BuffBot-PlayerN`.

**Step 2: Verify RED**

Run: `python -m pytest tests/test_runtime_compatibility.py tests/test_localization.py -q -k "localized or reason or export_filename"`

Expected: FAIL on current English defaults/reasons/filename collision.

**Step 3: Implement the minimum persistence changes**

Use localization only when creating or repairing a missing preset name. Keep
all internal categories/schema fields language-neutral. Return stable reason
identifiers and structured values to display callers; keep developer log text
English. Use the character's stable party index for the ASCII export fallback
when the sanitized display name is empty.

**Step 4: Verify GREEN**

Run: `python -m pytest tests/test_runtime_compatibility.py tests/test_target_resolution.py tests/test_localization.py -q`

Expected: PASS.

**Step 5: Commit**

```bash
git add buffbot/BfBotPer.lua tests/test_runtime_compatibility.py tests/test_localization.py
git commit -m "feat: localize new preset defaults and reason codes"
```

### Task 6: Migrate all player-facing Lua, menu, and EEex Options text

**Files:**
- Modify: `buffbot/BfBotLoc.lua`
- Modify: `buffbot/M_BfBot.lua`
- Modify: `buffbot/BfBotExe.lua`
- Modify: `buffbot/BfBotInn.lua`
- Modify: `buffbot/BfBotUI.lua`
- Modify: `buffbot/BfBotThm.lua`
- Modify: `buffbot/BuffBot.menu`
- Modify: `buffbot/setup-buffbot.tp2`
- Modify: `buffbot/lang/english/setup.tra`
- Modify: `buffbot/lang/schinese/setup.tra`
- Modify: `tests/test_eeex_compatibility_installer.py`
- Modify: `tests/test_localization.py`
- Modify: `tests/test_repeat_ui.py`
- Modify: `tests/test_ui_selection.py`

**Step 1: Write failing source/UI tests**

Add an explicit inventory test that extracts every `L10N.Get/Format` key from
Lua and `.menu`, requires registry/catalog definitions, and rejects alphabetic
static player-facing menu labels except documented symbols. Assert bootstrap
load order and localized `uiStrings`. Add focused behavior tests for clone
possessive templates, titles, delete confirmation, cast labels/reasons, import
summary, repeat tooltips, duration/category labels, targets, statuses, Quick
Cast, and selected variant text.

Extend the complete catalogs and runtime/installer maps with `@452`
`ui.repeat.compact` (`R{count}` / `{count}次`) and `@453`
`ui.lock.compact` (`[L]` / `[锁]`). Keep established English `Cast` labels, but
make picker and no-work feedback factually include both spells and items.
Apply the reviewed Chinese actor wording, game-native `特殊能力` terminology,
Project Image wording, and compact no-space `时` / `分` / `秒` duration forms.

**Step 2: Verify RED**

Run: `python -m pytest tests/test_localization.py tests/test_repeat_ui.py tests/test_ui_selection.py -q`

Expected: FAIL with the current English literals.

**Step 3: Migrate static menu text**

Replace player-facing `text "..."` values with `text lua` calls to semantic
keys. Use complete templates for dynamic titles and the variant picker. Keep
presentational symbols and engine data bindings unchanged.

**Step 4: Migrate Lua display boundaries**

Replace player-facing literals in bootstrap, Exec, Innate, UI, and Theme with
`Get`/`Format`. Translate stable reason codes only at UI/innate display
boundaries. Populate EEex `uiStrings` from localization. Map internal duration
categories before display. Leave engine strref 14007, spell/item names,
developer logs, and in-game test diagnostics untouched.

Add the two new IDs to the checked-in registry and explicit WeiDU runtime map;
the installer/catalog parity tests must continue to derive the exact runtime
ID set and exercise both languages.

**Step 5: Verify GREEN and behavior preservation**

Run: `python -m pytest tests/test_localization.py tests/test_repeat_ui.py tests/test_ui_selection.py tests/test_runtime_compatibility.py tests/test_innate_recharge.py -q`

Expected: PASS with no unrelated UI-control-flow diff.

**Step 6: Commit**

```bash
git add buffbot/M_BfBot.lua buffbot/BfBotLoc.lua buffbot/BfBotExe.lua buffbot/BfBotInn.lua buffbot/BfBotUI.lua buffbot/BfBotThm.lua buffbot/BuffBot.menu buffbot/setup-buffbot.tp2 buffbot/lang tests
git commit -m "feat: localize BuffBot player-facing UI"
```

### Task 7: Make development deployment and release packaging complete

**Files:**
- Create: `tools/build-release.sh`
- Create: `tests/test_release_package.py`
- Modify: `.github/workflows/release.yml`
- Modify: `tools/deploy.sh`
- Modify: `README.md`

**Step 1: Write the failing package/deploy tests**

Test that raw `tools/deploy.sh` copies `BfBotLoc.lua` and remains readable in
English without a numeric map. Define a release builder contract that stages a
supplied installer plus the exact distributable `buffbot/` tree, README, and
CHANGELOG. Assert nested `lang/**`, all Lua/menu/assets/TP2, and no tests/dev
files. Extract the produced ZIP into a synthetic game and perform a real
Chinese WeiDU install.

**Step 2: Verify RED**

Run: `python -m pytest tests/test_release_package.py -q`

Expected: FAIL because the workflow omits language directories and no reusable
builder exists.

**Step 3: Implement reusable packaging**

Add `tools/build-release.sh` and have the release workflow call it instead of
maintaining independent flat extension globs. Preserve the installer-at-root,
`buffbot/` directory, and root docs layout. Keep an explicit test allowlist so
recursive copy cannot leak tests, backups, or local state.

**Step 4: Document localization contributions**

README must list English and Simplified Chinese, state that manual/raw deploy
uses English fallback while localized installs use WeiDU, and welcome language
PRs. Contributor instructions require copying English TRA, complete ID and
named-placeholder parity, UTF-8, validation, and translator credit. Credit
robovoid for Simplified Chinese.

**Step 5: Verify GREEN**

Run: `python -m pytest tests/test_release_package.py tests/test_localization.py -q`

Expected: PASS, including install from the built archive.

**Step 6: Commit**

```bash
git add tools/build-release.sh tools/deploy.sh .github/workflows/release.yml README.md tests/test_release_package.py
git commit -m "build: package and document localization catalogs"
```

### Task 8: Exercise language switching and the complete compatibility matrix

**Files:**
- Modify: `tests/test_eeex_compatibility_installer.py`
- Modify: `CHANGELOG.md`
- Modify if warranted by verified reusable findings: `C:/Users/chris/.agents/skills/bg-modding/references/*`

**Step 1: Write the failing language-switch lifecycle test**

Perform English fresh install, one-invocation forced main uninstall/install in
Chinese, then switch back to English. Verify map replacement, selected/inactive
TLKs, stable reuse without duplicate growth, payload restoration, helper
ownership, and current-v1/released-v1.7.0 upgrade behavior. Do not use a
main-only `--force-install-list 0` as a language switch because WeiDU can treat
it as a no-op.

**Step 2: Verify RED, then implement only missing lifecycle support**

Run: `python -m pytest tests/test_eeex_compatibility_installer.py -q -k language_switch`

Expected: RED until the harness and installed map support switching; after the
minimum correction, PASS.

**Step 3: Run parse and full automated verification**

```powershell
& 'C:\src\private\chriz-bg-rebalance\weidu.exe' --nogame --parse-check TP2 buffbot/setup-buffbot.tp2
python -m pytest -q -p no:cacheprovider
git diff --check
```

Expected: WeiDU parse success, all tests pass, and no whitespace errors.

**Step 4: Update release-facing documentation**

Record complete automated evidence and the still-pending live CJK glyph/layout
boundary in CHANGELOG. Do not claim BG1EE, alternate resolutions, or Chinese
visual acceptance until actually run.

**Step 5: Commit**

```bash
git add tests/test_eeex_compatibility_installer.py CHANGELOG.md
git commit -m "test: verify localization installer lifecycle"
```

### Task 9: Prepare and run live Copy Copy acceptance

**Files:**
- No repository changes until observations require a RED regression.

**Step 1: Verify the live test prerequisites without mutation**

Confirm no Baldur/InfinityLoader process is running, preserve the current
English BuffBot install state, and verify:

```text
C:\Games\Baldur's Gate II Enhanced Edition modded - Copy - Copy\lang\zh_CN\dialog.tlk
C:\Users\chris\OneDrive\Documents\Baldur's Gate II - Enhanced Edition\Baldur.lua
```

The existing configuration contains `Fonts/zh_CN=SIMSUN`; no Steam reinstall
is required.

**Step 2: Install the Chinese catalog through WeiDU**

Use WeiDU 249 with `--language 1 --use-lang zh_CN`, preserving the current
helper/main lifecycle and backups. Temporarily set `Language/Text=zh_CN`, then
launch through InfinityLoader.

**Step 3: Run the visual/runtime matrix**

Inspect main panel, narrow delete label, every submenu, Party/Summons, clone
labels, spell/item sections, repeat and Quick Cast tooltips, variant picker,
imports/exports, runtime errors, EEex Options, normal/large font, and a
constrained resolution. Verify Chinese Project Image tail suppression and a
non-ASCII character export filename. Save/reload once.

**Step 4: Restore English exactly**

Exit the game, reinstall/select English BuffBot strings in `en_US`, restore
`Language/Text=en_US`, and relaunch for a short English comparison pass.

**Step 5: Handle findings test-first**

For every defect, first add a failing automated regression when possible, then
apply the smallest fix and rerun Task 8. If live acceptance passes, record its
exact scope in CHANGELOG and the eventual release notes.

**Step 6: Final review**

Use the requesting-code-review and verification-before-completion guidance.
Check whether Project Image opcode-236 detection or another discovery is both
verified and reusable enough for `bg-modding-learn`; do not add BuffBot-only
policy or unresolved theory.
