# File-Backed Runtime Localization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Goal:** Replace BuffBot's startup-unsafe native TLK lookups with a selected UTF-8 runtime catalog while retaining TLK ownership only for generated innate SPL names.

**Architecture:** WeiDU copies `buffbot/lang/%LANGUAGE%/setup.tra` byte-for-byte to `override/bfbot_l10n.tra`. `BfBotLoc.lua` parses registered one-line `@ID = ~text~` entries through LuaJIT I/O and serves them through the existing semantic-key API, falling back per key to checked-in English without ever calling `Infinity_FetchString`.

**Tech Stack:** WeiDU 249, Lua 5.1/LuaJIT, EEex, UTF-8 `.tra`, Python/pytest/lupa, PowerShell, ProcDump/cdb, Git.

---

### Task 1: Replace the native-fetch runtime with a file-backed catalog

**Files:**
- Modify: `tests/test_localization.py:313-680`
- Modify: `tests/test_localization.py:800-828`
- Modify: `buffbot/BfBotLoc.lua:171-262`
- Modify: `buffbot/BfBotLoc.lua:331-338`
- Modify: `buffbot/BfBotUI.lua:747-760`

**Step 1: Replace the localization test fixture with a selected-catalog fixture**

Change `localization_runtime()` to pass catalog text to an `io.open` stub that
accepts only `override/bfbot_l10n.tra`. Support explicit open failure and
`io=nil`; remove the `activate` parameter.

```python
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
        test_open_count = 0
        test_fetch_count = 0
        BfBot._Warn = function(_) end
        Infinity_FetchString = function(...)
            test_fetch_count = test_fetch_count + 1
            error("runtime localization must not call Infinity_FetchString")
        end
        if test_catalog_text == nil then
            io = nil
        else
            io = { open = function(path, mode)
                test_open_count = test_open_count + 1
                assert(path == "override/bfbot_l10n.tra")
                assert(mode == "r")
                if not test_open_succeeds then return nil end
                return {
                    read = function(_, format)
                        assert(format == "*a")
                        return test_catalog_text
                    end,
                    close = function() end,
                }
            end }
        end
        """
    )
    runtime.execute(localization_source())
    return runtime
```

**Step 2: Write the runtime RED tests**

Replace numeric-map/fetch/activation tests with these contracts:

```python
def test_selected_utf8_catalog_is_loaded_without_native_tlk_access():
    runtime = localization_runtime(
        "@305 = ~重置~\n@404 = ~{preset}：{summon}~\n"
    )
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "重置"
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "重置"
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


def test_catalog_parser_ignores_unsupported_unknown_and_empty_rows_per_key():
    runtime = localization_runtime(
        "\n".join([
            "// comment",
            "@305 = ~重置~",
            "@9999 = ~ignored~",
            "@306 = ~~",
            "@307 = ~contains ~ tilde~",
            "not a TRA row",
        ])
    )
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "重置"
    assert runtime.eval('BfBot.L10N.Get("common.rename")') == "Rename"
    assert runtime.eval('BfBot.L10N.Get("common.new")') == "New"
    assert runtime.globals().test_fetch_count == 0


def test_catalog_values_are_data_and_never_executed_as_lua():
    runtime = localization_runtime(
        '@305 = ~"; test_catalog_code_executed = 1; --~\n'
    )
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == (
        '"; test_catalog_code_executed = 1; --'
    )
    assert runtime.globals().test_catalog_code_executed is None


@pytest.mark.parametrize("catalog_text,open_succeeds", [(None, True), ("", False)])
def test_missing_io_or_catalog_uses_complete_english_fallback(
    catalog_text, open_succeeds
):
    runtime = localization_runtime(
        catalog_text, open_succeeds=open_succeeds
    )
    assert runtime.eval('BfBot.L10N.Get("common.reset")') == "Reset"
    assert runtime.globals().test_fetch_count == 0


def test_localization_source_has_no_native_fetch_or_activation_boundary():
    loc = LOC_PATH.read_text(encoding="utf-8")
    ui = UI_PATH.read_text(encoding="utf-8")
    assert "Infinity_FetchString" not in loc
    assert "L10N.Activate" not in loc
    assert "L10N.Activate" not in ui
    assert "_l10nTlkReady" not in loc
```

Retain and adapt the existing `Format`, `Reason`, unknown-key, registry parity,
bootstrap-order, and arbitrary quote/percent/non-ASCII tests to use `.tra`
rows rather than `id=strref` rows. Remove `StrRef` tests; that internal API no
longer has a runtime owner.

**Step 3: Run the runtime tests to verify RED**

Run:

```powershell
python -m pytest tests/test_localization.py -q -k "selected_utf8 or catalog_parser or missing_io_or_catalog or no_native_fetch"
```

Expected: FAIL because current `BfBotLoc.lua` opens `bfbot_l10n.txt`, parses
numeric strrefs, and contains `Infinity_FetchString` plus `Activate`.

**Step 4: Implement the minimal file parser**

Replace `_strrefs` / `_LoadStrRefMap` with a selected-value table loaded once:

```lua
local _selectedById = {}

local function _LoadSelectedCatalog()
    if type(io) ~= "table" or type(io.open) ~= "function" then return end
    local openOK, handle = pcall(io.open, "override/bfbot_l10n.tra", "r")
    if not openOK or not handle then return end
    local readOK, content = pcall(function() return handle:read("*a") end)
    pcall(function() handle:close() end)
    if not readOK or type(content) ~= "string" then return end

    for line in content:gmatch("[^\r\n]+") do
        local idText, value = line:match("^%s*@(%d+)%s*=%s*~([^~]+)~%s*$")
        local catalogId = idText and tonumber(idText) or nil
        if catalogId and _registryById[catalogId]
                and _selectedById[catalogId] == nil then
            _selectedById[catalogId] = value
        end
    end
end

_LoadSelectedCatalog()
```

Make `Get` cache `_selectedById[entry.id] or entry.fallback`. Remove
`Activate`, `_l10nTlkReady`, all calls to `Infinity_FetchString`, and
`BfBot.L10N.StrRef`. Remove the deferred activation/static-refresh block from
`_OnMenusLoaded`; the four existing top-level UI values are already initialized
after `BfBotLoc.lua` loads.

**Step 5: Run focused and compatibility tests to verify GREEN**

Run:

```powershell
python -m pytest tests/test_localization.py tests/test_runtime_compatibility.py tests/test_innate_recharge.py tests/test_repeat_counts.py tests/test_selection_refresh.py -q
```

Expected: all selected tests PASS and the poisoned native function is never
called.

**Step 6: Keep the runtime change staged as an atomic installer chain**

Do not commit or hand off this intermediate state: runtime now expects
`bfbot_l10n.tra`, while the old installer still emits `bfbot_l10n.txt`. Proceed
directly to Task 2 and commit runtime plus installer together after collection
and the complete affected suite are green.

### Task 2: Make WeiDU install the selected UTF-8 catalog

**Files:**
- Modify: `tests/test_localization.py:839-882`
- Modify: `tests/test_eeex_compatibility_installer.py:20-305`
- Modify: `tests/test_eeex_compatibility_installer.py:712-797`
- Modify: `tests/test_release_package.py:1-20`
- Modify: `tests/test_release_package.py:380-505`
- Create: `tests/fixtures/setup-buffbot-map-backed-v1.7.4-alpha.tp2`
- Modify: `buffbot/setup-buffbot.tp2:325-503`
- Modify: `buffbot/setup-buffbot.tp2:505-519`
- Modify: `buffbot/setup-buffbot.tp2:547-714`

**Step 1: Write the installer RED contract**

Change the static contract to require:

```python
assert re.search(
    r"COPY\s+~buffbot/lang/%LANGUAGE%/setup\.tra~\s+"
    r"~override/bfbot_l10n\.tra~",
    source,
)
assert "bfbot_l10n.generated" not in source
assert "bfbot_l10n.txt" not in source
assert "bfbot_l10n_" not in source
resolved = re.findall(r"RESOLVE_STR_REF\(@(\d+)\)", source)
assert resolved == [str(i) for i in range(200, 208)]
```

Change `MAIN_OUTPUT_FILES` from `bfbot_l10n.txt` to `bfbot_l10n.tra`. Replace
`_assert_runtime_map_dereferences_selected_catalog()` with:

```python
def _assert_selected_runtime_catalog(game: BuffBotGame, directory: str) -> None:
    expected = ROOT / "buffbot" / "lang" / directory / "setup.tra"
    installed = game.override / "bfbot_l10n.tra"
    assert installed.read_bytes() == expected.read_bytes()
    assert not (game.override / "bfbot_l10n.txt").exists()
```

For English and Chinese real-WeiDU install cases, assert the selected catalog
is byte-exact and that the active TLK contains exactly the eight selected
innate strings from IDs 200–207, not every runtime UI string.

Parse `bfbot_strrefs.txt` as exactly eight valid in-range integers and assert
positional correctness, not only set equality:

```python
refs = [int(row) for row in (game.override / "bfbot_strrefs.txt").read_text().splitlines()]
assert len(refs) == 8
assert all(0 <= ref < len(active_strings) for ref in refs)
assert [active_strings[ref] for ref in refs] == [catalog[i] for i in range(200, 208)]
```

Add a direct ownership case: preseed `override/bfbot_l10n.tra` with unrelated
bytes, install main and prove the selected catalog replaced it, then uninstall
main and prove the preimage returns byte-for-byte. This distinguishes normal
WeiDU restoration from mere deletion.

Add a migration fixture copied exactly from the pre-correction map-backed
candidate TP2. Install its component 0 so WeiDU owns
`override/bfbot_l10n.txt`, replace the TP2 with current, and force a genuine
uninstall/install in one invocation. Assert the old map is removed, the
selected `.tra` is byte-exact, only the eight innate refs are current, and a
final uninstall restores the fixture baseline. This is required before using
the same transition in Copy Copy.

Adapt `test_release_package.py` in this task as well: remove its import/use of
`_read_l10n_map` and make the packaged Chinese install compare the installed
`.tra` bytes plus the eight positional innate refs. Task 2 must leave the full
test suite collection-safe; do not defer a broken import to Task 3.

**Step 2: Run the installer tests to verify RED**

Run:

```powershell
python -m pytest tests/test_localization.py tests/test_eeex_compatibility_installer.py -q -k "installer_localization or selects_one_tlk"
```

Expected: FAIL because current TP2 emits the numeric map and resolves 163
runtime strings.

**Step 3: Simplify the TP2**

Keep only the eight existing innate statements:

```weidu
OUTER_SET bfbot_strref_1 = RESOLVE_STR_REF(@200)
...
OUTER_SET bfbot_strref_8 = RESOLVE_STR_REF(@207)
```

Delete every `bfbot_l10n_* = RESOLVE_STR_REF(...)` line and the inlined
`bfbot_l10n.generated` map. Add this copy next to `BfBotLoc.lua`:

```weidu
COPY ~buffbot/lang/%LANGUAGE%/setup.tra~ ~override/bfbot_l10n.tra~
```

Use plain `COPY` with no `EVALUATE_BUFFER`: the selected UTF-8 bytes, including
the literal installer-only `%lua_version%` placeholder, must remain exact.

Do not change helper/main component numbers, declarations, gates, or
invocation-local upgrade proof.

**Step 4: Verify real WeiDU English and Chinese installation**

Run:

```powershell
python -m pytest tests/test_localization.py tests/test_eeex_compatibility_installer.py -q -k "localization or selects_one_tlk"
```

Expected: all selected cases PASS for en_US/zh_CN and EEex v0.11/v1.

**Step 5: Run collection and the complete affected group**

Run:

```powershell
python -m pytest --collect-only -q
python -m pytest tests/test_localization.py tests/test_eeex_compatibility_installer.py tests/test_release_package.py tests/test_runtime_compatibility.py -q
```

Expected: collection and all affected tests PASS.

**Step 6: Commit the atomic runtime + installer correction**

```powershell
git add -- buffbot/BfBotLoc.lua buffbot/BfBotUI.lua buffbot/setup-buffbot.tp2 tests/test_localization.py tests/test_eeex_compatibility_installer.py tests/test_release_package.py tests/fixtures/setup-buffbot-map-backed-v1.7.4-alpha.tp2
git commit -m "fix: load selected runtime catalog without native TLK calls"
```

### Task 3: Rewrite language-switch and package acceptance around file ownership

**Files:**
- Modify: `tests/test_eeex_compatibility_installer.py:799-1225`
- Modify: `tests/test_eeex_compatibility_installer.py:1300-1920`
- Modify: `tests/test_release_package.py:160-505` (only remaining lifecycle/deploy assertions)
- Modify: `tools/deploy.sh:19-24`

**Step 1: Write lifecycle and package RED assertions**

Across the current helper→main and released-v1.7 main→helper matrices, replace
numeric-map assertions with selected catalog bytes:

```python
english_runtime = (ROOT / "buffbot/lang/english/setup.tra").read_bytes()
chinese_runtime = (ROOT / "buffbot/lang/schinese/setup.tra").read_bytes()

assert (game.override / "bfbot_l10n.tra").read_bytes() == english_runtime
# after Chinese reinstall
assert (game.override / "bfbot_l10n.tra").read_bytes() == chinese_runtime
# after English return
assert (game.override / "bfbot_l10n.tra").read_bytes() == english_runtime
```

Derive same-TLK growth from the unique union of catalog IDs 200–207 only. Keep
the sentinel, inactive/root TLK, helper loader/DLL, static-payload, backup,
language-field, component-order, and byte-exact return assertions. Exclude
`bfbot_l10n.tra` and `bfbot_strrefs.txt` only where a snapshot intentionally
compares language-neutral payload.

For uninstall, assert the selected catalog is removed/restored by the main
component and no obsolete `bfbot_l10n.txt` remains. For the release archive,
install Chinese with WeiDU 249, compare the installed runtime file to the
packaged `buffbot/lang/schinese/setup.tra`, and dereference only the eight
innate TLK references.

Update deploy tests for two paths:

```python
assert "bfbot_l10n.tra" in deploy_source
assert "preserving existing WeiDU-selected runtime catalog" in deploy_source
assert "English fallback" in deploy_source
```

The raw deploy must never copy a source `setup.tra` into override and must not
delete an existing installer-owned runtime catalog.

**Step 2: Run the affected tests to verify RED**

Run:

```powershell
python -m pytest tests/test_eeex_compatibility_installer.py tests/test_release_package.py -q -k "language_switch or package or deploy or uninstall"
```

Expected: FAIL on old map/TLK-growth assumptions and deploy messaging.

**Step 3: Adapt helpers, matrices, and deploy messaging**

Use one helper for exact source/installed catalog comparison. Keep every
existing real-WeiDU lifecycle operation and transcript proof; change only the
runtime localization artifact and expected TLK string set. In `deploy.sh`,
check `override/bfbot_l10n.tra`, preserve it, and describe clean raw deployment
as English fallback without a selected catalog.

**Step 4: Run the complete installer/package group**

Run:

```powershell
python -m pytest tests/test_eeex_compatibility_installer.py tests/test_release_package.py tests/test_localization.py -q
bash -n tools/deploy.sh
bash -n tools/build-release.sh
```

Expected: all tests and both shell syntax checks PASS.

**Step 5: Commit**

```powershell
git add -- tests/test_eeex_compatibility_installer.py tests/test_release_package.py tools/deploy.sh
git commit -m "test: verify file-backed localization lifecycle"
```

### Task 4: Update player documentation and release evidence

**Files:**
- Modify: `README.md:47-75`
- Modify: `README.md:150-203`
- Modify: `CHANGELOG.md:3-18`
- Modify: `docs/plans/2026-08-21-full-localization-design.md:1-8`
- Modify: `docs/plans/2026-08-21-full-localization.md:1-10`
- Reference: `docs/plans/2026-08-22-file-backed-runtime-localization-design.md`

**Step 1: Add documentation assertions**

Extend the existing README/package tests to require these truthful concepts:

- localized WeiDU installs copy the selected UTF-8 catalog;
- raw deploy uses English fallback unless it preserves an existing
  WeiDU-selected catalog;
- F12 innate names remain TLK-backed;
- language contributors still preserve IDs, placeholders, UTF-8, the TP2
  `LANGUAGE` stanza, and package tests.

**Step 2: Run the documentation tests to verify RED**

Run:

```powershell
python -m pytest tests/test_release_package.py tests/test_localization.py -q -k "readme or documentation"
```

Expected: FAIL on references to the old numeric TLK map.

**Step 3: Update README and CHANGELOG**

Remove claims that all runtime strings are resolved/fetched through the game
TLK. Document the file-backed runtime catalog and innate-only TLK boundary.
Replace the failed post-main-menu deferral claim with the native-crash
regression and file-backed protection. Do not claim completed Chinese visual
acceptance yet. Refresh the automated test count only after Task 5's final run.

Add a prominent banner to both 2026-08-21 historical localization documents
stating that their runtime-TLK architecture is superseded by
`2026-08-22-file-backed-runtime-localization-design.md`; preserve their
historical tasks rather than rewriting them. Add a repository-wide assertion
that stale phrases such as `numeric localization map` and `TLK-backed runtime
localization` do not describe current UI behavior, while allowing explicit
innate-only TLK documentation.

**Step 4: Verify documentation and diff hygiene**

Run:

```powershell
python -m pytest tests/test_release_package.py tests/test_localization.py -q -k "readme or documentation"
git diff --check
```

Expected: PASS; only normal Windows LF/CRLF notices may appear.

**Step 5: Commit**

```powershell
git add -- README.md CHANGELOG.md tests/test_release_package.py tests/test_localization.py docs/plans/2026-08-21-full-localization-design.md docs/plans/2026-08-21-full-localization.md
git commit -m "docs: explain file-backed runtime localization"
```

### Task 5: Verify, redeploy, and resume joint Chinese acceptance

**Files:**
- Potentially modify after evidence: `CHANGELOG.md`
- Modify after successful live proof: `CLAUDE.md` (current tracked project guidance)
- Potentially update after successful live proof: BG-modding EEex UI/filesystem reference through `bg-modding-learn`
- Live target: `C:/Games/Baldur's Gate II Enhanced Edition modded - Copy - Copy`
- Baseline: `C:/Users/chris/.codex/live-validation/buffbot-l10n-20260822-061415`

**Step 1: Run final automated verification**

Run:

```powershell
python -m pytest -q -p no:cacheprovider
git diff --check
```

Run the exact WeiDU 249 parse check:

```powershell
& 'C:/src/private/chriz-bg-rebalance/weidu.exe' --nogame --parse-check TP2 buffbot/setup-buffbot.tp2
```

Confirm the exact passing count, then update the single CHANGELOG count if
needed and rerun the full suite.

Expected: zero failures, clean diff, and a parseable TP2.

**Step 2: Obtain independent code and spec review**

Review the runtime parser, installer ownership, lifecycle tests, package
artifact, documentation, and the removal of every localization-owned native
fetch. Resolve all Critical/Important findings test-first, rerun focused and
full verification, and commit follow-ups without amending reviewed commits.

**Step 3: Restore the live diagnostic artifact before WeiDU owns it**

With `Baldur.exe` and `InfinityLoader.exe` fully closed, verify these exact
states inside the Copy Copy game override:

```text
override/bfbot_l10n.txt.diagnostic-off
override/bfbot_l10n.txt (absent)
```

Proceed only if `.diagnostic-off` exists and the installed `.txt` is absent.
If both or neither exist, stop and investigate. Hash the diagnostic-off file
before moving it and require SHA-256
`7D23CA63614921EF2812D553EE31C30BE89D25DD4AC604677FBE780F77EA988D`,
then move it to the installed path and verify the destination has the same
hash. Immediately perform the corrected WeiDU reinstall so the old component
can uninstall its owned map normally. Preserve all crash artifacts, the
baseline snapshot, and `weidu_external/backup/buffbot`; stage only explicit
release source and payload files, never overlay or delete installer backup
state. After the reinstall, require both old map names to be absent.

**Step 4: Stage and reinstall the Chinese candidate**

Stage candidate release sources byte-exactly into the game's `buffbot/`
directory. From the game cwd, use the explicit verified WeiDU 249 executable
and current TP2 to reinstall main component 0 only; this preserves the already
normalized helper-first stack and does not reinstall the helper:

```powershell
$buffbotGame = (Resolve-Path -LiteralPath 'C:\Games\Baldur''s Gate II Enhanced Edition modded - Copy - Copy').Path
if ($buffbotGame -ne 'C:\Games\Baldur''s Gate II Enhanced Edition modded - Copy - Copy') { throw 'Unexpected game target' }
Set-Location -LiteralPath $buffbotGame
& 'C:/src/private/chriz-bg-rebalance/weidu.exe' '.\buffbot\setup-buffbot.tp2' --game $buffbotGame --force-uninstall-list 0 --force-install-list 0 --language 1 --use-lang zh_CN --no-exit-pause --quick-log --noautoupdate
```

Require genuine removal/install transcript markers. Verify:

- active log order remains helper(1) then main(0), both language 1;
- `override/bfbot_l10n.tra` equals the Chinese source catalog byte-for-byte;
- obsolete `override/bfbot_l10n.txt` is absent;
- `bfbot_strrefs.txt` dereferences exactly eight Chinese innate names;
- the eight current refs dereference correctly; do not expect the selected TLK
  to shrink because earlier candidate strings are stable WeiDU residue;
- inactive/root TLKs, InfinityLoader.ini, lua51.dll, LuaProvider.dll,
  EEexRemote, and unrelated override state retain their expected bytes, and
  any active-TLK delta is explainable from the immediate pre-reinstall state.

**Step 5: Perform the first live startup gate together**

Snapshot current WER report/crash-directory state and arm ProcDump for an
unhandled Baldur exception before launching. Launch through
`InfinityLoader.exe` with the Chinese game setting. Require the
main menu and world screen to remain responsive with no new InfinityLoader or
WER crash; optionally confirm remote-console readiness and one file-backed
catalog value. Open BuffBot and verify that normal UI labels—not only game
spell names—are Chinese. If startup fails, preserve the new artifacts, stop,
and return to crash forensics; do not retry blindly or continue the matrix.

**Step 6: Complete the approved live matrix**

Together verify:

- main panel, rename/new/delete confirmation, target, add, import, variants,
  and Summons views;
- Simplified Chinese glyphs, clipping, compact repeat/lock labels, durations,
  tooltips, themes, and Small/Medium/Large text sizes at representative
  resolutions;
- F12 innate names, recharge, Cast Character, Cast All, and Project Image
  owner-lock behavior;
- non-ASCII preset export/import filename and content handling;
- save/reload and area transition without lost names or duplicate innates.

Record only the cases actually observed.

**Step 7: Record the verified reusable engine finding**

After the corrected Chinese launch succeeds, invoke `bg-modding-learn` and add
the narrow verified rule for BG2EE 2.6.6 + EEex 1.2: config selected zh_CN,
but the native path exposed stale en_US state where the requested appended ref
was one-past-end; `Infinity_FetchString` crashed during both `M_` loading and
`AddAfterMainFileLoadedListener`, and `pcall` could not contain the C++ access
violation. A main-file-loaded listener proves UI.menu loading, not that the
selected TLK is active. Do not claim an untested translation-loaded listener
is safe. Record the file-backed UTF-8 UI-catalog replacement in the existing
`gotchas.md` / `eeex-ui.md` route.

Also add the project invariant: BuffBot-owned runtime UI text comes from
`override/bfbot_l10n.tra`; never native-fetch BuffBot-owned UI strrefs; engine
spell/item names and the eight generated F12 resource names remain legitimate
TLK users. Do not blanket-ban `Infinity_FetchString`.

**Step 8: Restore English byte-safely**

Close both processes. Reinstall main with:

```powershell
$buffbotGame = (Resolve-Path -LiteralPath 'C:\Games\Baldur''s Gate II Enhanced Edition modded - Copy - Copy').Path
if ($buffbotGame -ne 'C:\Games\Baldur''s Gate II Enhanced Edition modded - Copy - Copy') { throw 'Unexpected game target' }
Set-Location -LiteralPath $buffbotGame
& 'C:/src/private/chriz-bg-rebalance/weidu.exe' '.\buffbot\setup-buffbot.tp2' --game $buffbotGame --force-uninstall-list 0 --force-install-list 0 --language 0 --use-lang en_US --no-exit-pause --quick-log --noautoupdate
```

Restore the original `Baldur.lua` from the baseline snapshot byte-for-byte,
restore its original read-only attribute, and verify `weidu.conf` is `en_US`.
Verify English catalog bytes, innate refs, loader/DLL hashes, EEexRemote, and
unrelated state. Main-only reinstall intentionally leaves helper component 1
logged with language 1 while main component 0 returns to language 0; accept
that mixed log language as functionally correct rather than mutating the helper
only for cosmetic normalization. Launch once and jointly confirm the English
panel.

**Step 9: Commit evidence-only updates**

Update the CHANGELOG with the final automated count and exact live acceptance
boundary, then run the full suite and diff check once more.

```powershell
git add -- CHANGELOG.md CLAUDE.md
git commit -m "test: record live Chinese localization acceptance"
```

Do not merge, push, tag, release, or close PR #50 in this task unless the user
separately authorizes publication after validation.
