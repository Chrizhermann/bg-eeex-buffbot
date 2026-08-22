# File-Backed Runtime Localization Correction

**Date:** 2026-08-22
**Status:** Approved
**Parent scope:** `docs/plans/2026-08-21-full-localization-design.md`

## Problem

The original localization design resolved every player-facing runtime string
into the selected game TLK and loaded those strings with
`Infinity_FetchString`. Live BG2:EE + EEex v1.2 validation disproved the
assumed safety boundary.

The first candidate launch called `Infinity_FetchString(103592)` while the
`M_BfBot.lua` chunk was loading and crashed natively with `0xC0000005`. A
test-first correction deferred TLK access to
`EEex_Menu_AddAfterMainFileLoadedListener`, but two further launches failed on
the same first lookup. The recovered dump shows the original access violation
inside the engine binding, followed by Windows fail-fast `0xC0000409` while
dispatching the corrupted exception state. Lua `pcall` cannot contain either
failure.

The selected Chinese TLK contains strref 103592, and that strref works once the
world screen is active. The English TLK ends immediately before it. A control
launch with only `bfbot_l10n.txt` hidden reached the world screen, displayed
Chinese engine strings correctly, and opened BuffBot through its English
fallback. The crash therefore belongs to native runtime TLK access during
startup, not the Chinese catalog, fonts, menu, or general game-language setup.

## Decision

BuffBot will not use `Infinity_FetchString` for UI, options, defaults, or
player feedback. WeiDU will copy the selected UTF-8 `.tra` catalog into the
override directory, and `BfBotLoc.lua` will read the selected text directly
through LuaJIT I/O.

The engine TLK remains the correct owner for the eight generated F12 innate
spell names because SPL resources store numeric strrefs. Those eight existing
`bfbot_strrefs.txt` mappings remain unchanged.

This decision replaces only the native runtime-TLK sections of the parent
design and implementation plan. The catalog, UI, persistence, packaging,
translation-contribution, and acceptance scopes remain in force.

## Considered Approaches

### Copy and parse the selected `.tra` catalog (selected)

Each catalog reserves non-translatable `@113` as its exact safe directory
name. After WeiDU activates the newly selected TRA table, the main component
captures that marker with `OUTER_SPRINT bfbot_selected_language @113` and
copies `buffbot/lang/%bfbot_selected_language%/setup.tra` to
`override/bfbot_l10n.tra`.

The marker is necessary because WeiDU 249 can restore the previously installed
raw `%LANGUAGE%` value while replaying an uninstall during a same-process
language switch, even though the newly selected TRA table is already active.
The runtime parser accepts the project's already validated one-line grammar,
`@ID = ~text~`, and indexes only registered runtime IDs.

This keeps the checked-in `.tra` catalogs canonical, avoids a second string
generator, matches EEex's own use of direct UTF-8 Lua strings, and removes all
native startup fetches.

### Generate an encoded runtime data file

WeiDU could generate an ASCII-safe hex or escaped-Lua catalog. This would give
the runtime a purpose-built format, but would duplicate catalog serialization
logic in the installer and create another escaping/validation boundary. It is
unnecessary for the enforced one-line UTF-8 catalogs.

### Defer TLK fetching again

Fetching only after the world screen would avoid the observed startup window,
but options, static menu state, and early feedback need strings sooner. It
would also preserve a native-crash path that `pcall` cannot protect. This
approach is rejected.

## Architecture and Data Flow

1. The selected WeiDU language still controls installer text and the eight
   innate TLK strings.
2. During main-component installation, WeiDU captures the selected catalog's
   non-translatable directory marker with
   `OUTER_SPRINT bfbot_selected_language @113`, then byte-copies
   `buffbot/lang/%bfbot_selected_language%/setup.tra` to
   `override/bfbot_l10n.tra`.
3. `M_BfBot.lua` loads `BfBotLoc.lua` immediately after Core, as before.
4. `BfBotLoc.lua` reads the copied file once, parses supported ID/value rows,
   and stores only IDs present in its registry.
5. `BfBot.L10N.Get(key)` returns the selected file value or the checked-in
   English fallback. It never calls `Infinity_FetchString`.
6. `Format` and `Reason` continue to operate on the same semantic-key API, so
   UI, `.menu`, persistence, and feedback callers do not change.

The obsolete 163-entry `RESOLVE_STR_REF` block and generated
`bfbot_l10n.txt` ID-to-strref map are removed. This also prevents unnecessary
TLK growth: only the eight engine-owned innate names are appended.

Language switching remains a WeiDU reinstall operation. Reinstalling the main
component replaces `bfbot_l10n.tra` with the newly selected catalog while
preserving the existing helper ownership and component-order safety rules.

## Parser and Failure Contract

- Input must be valid bytes for the shipped UTF-8 catalog and use one
  `@digits = ~text~` entry per line.
- Catalog entry `@113` must equal its safe lowercase directory name exactly
  and is metadata, not translator-facing text.
- An optional UTF-8 BOM is not required by shipped files; malformed or
  unsupported rows are ignored at runtime and rejected by repository tests.
- Only registered runtime IDs are retained. Installer-only and innate-only IDs
  cannot alter runtime lookup behavior.
- Duplicate IDs, missing IDs, interior tildes, empty values, invalid UTF-8, and
  placeholder mismatches remain release-blocking catalog-test failures.
- Missing I/O, a missing catalog, a malformed row, or an absent runtime ID
  falls back independently to the checked-in English value.
- Unknown semantic keys retain the existing conspicuous warning marker.
- Early fallback values are safe and deterministic; there is no activation
  state, delayed refresh, or native exception boundary.

Raw/developer deployment continues to work in English when no selected file is
present. If a prior WeiDU-selected `bfbot_l10n.tra` exists, the deploy script
must preserve it and report that preservation rather than silently deleting
installer-owned state.

## Installer, Packaging, and Uninstall

- Add `override/bfbot_l10n.tra` to the main component's installed outputs.
- Remove creation of `override/bfbot_l10n.txt` and all 163 runtime
  `RESOLVE_STR_REF` calls.
- Keep `bfbot_strrefs.txt` and its eight innate references unchanged.
- Main uninstall removes/restores the copied runtime catalog through normal
  WeiDU backup ownership.
- The source release continues shipping every full `buffbot/lang/**` catalog;
  no additional generated runtime file is packaged.
- Package and install-from-ZIP tests must prove that a selected catalog is
  copied byte-exactly from the immutable package source.

## Verification

Automated validation must include:

- a poisoned `Infinity_FetchString` that fails if any localization lookup
  calls it;
- exact English and Chinese file-backed lookup, formatting, reason, missing
  file, malformed-row, unknown-ID, and no-I/O fallback tests;
- real WeiDU 249 English and Chinese installs that copy the exact selected
  catalog and mutate only the selected TLK for the eight innate names;
- current and released-v1.7 component-order, upgrade, uninstall, and
  English-to-Chinese-to-English lifecycle matrices;
- package manifest, packaged Chinese install, raw-deploy preservation, WeiDU
  parse, source inventory, and complete-suite checks;
- controlled RED evidence for the old numeric-map/native-fetch contract.

Live acceptance resumes only after a corrected reinstall. The first gate is a
Chinese launch through the unchanged full theme/options/menu path. Then the
existing joint matrix covers the BuffBot panel and submenus, fonts and layout,
F12 names/casting, Project Image behavior, non-ASCII export/import,
save/reload, and final byte-checked English restoration. No successful
fallback-control observation is reported as localized BuffBot acceptance.

## Knowledge Boundary

The reusable engine finding is: `Infinity_FetchString` from `M_` loading and
even an `EEex_Menu_AddAfterMainFileLoadedListener` can crash natively for a
newly selected language's appended strref; Lua `pcall` is not a containment
boundary. Record this in the BG-modding knowledge base only after the
file-backed correction has passed a full live Chinese launch.
