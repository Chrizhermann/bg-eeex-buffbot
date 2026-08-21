# Full Localization Design

**Date:** 2026-08-21
**Status:** Approved
**Source contribution:** GitHub PR #50 by robovoid

## Problem

BuffBot currently presents player-facing text directly from English Lua and
`.menu` literals. PR #50 contributes a valuable Simplified Chinese catalog,
but it is based on v1.6.1 and translates source by textual replacement. That
approach misses current strings, leaves raw markers after installation, can
break Lua or menu syntax when translations contain source-sensitive
characters, bypasses development deployment, and conflicts with the current
LuaJIT installer lifecycle.

The localization layer must cover current `main`, preserve behavior, remain
safe for arbitrary translated text, and make future language contributions
straightforward.

## Product Contract

- Localize every normal player-facing BuffBot string: WeiDU component names,
  prerequisite and status messages, menu labels, UI text and tooltips, runtime
  feedback, EEex Options, generated innate names, and newly created default
  preset names.
- Keep developer diagnostics, automated/in-game test output, source comments,
  and log-only messages in English.
- Ship a language only when its catalog is complete. English and Simplified
  Chinese must have identical IDs and named placeholders.
- Preserve the exact meaning and control flow of current English behavior.
  Localization must not carry unrelated changes from PR #50.
- Existing saved preset names, user-renamed presets, and imported/exported
  names remain untouched. Newly created defaults use the installed language at
  creation time.
- Raw source or developer deployment remains usable through a complete English
  fallback. A localized player installation uses WeiDU.
- Credit robovoid for the original Chinese contribution and welcome complete
  pull requests for additional languages.

## Considered Approaches

### Direct source-text replacement

This is closest to PR #50 and initially requires the least runtime code. It is
rejected because translated quotes, backslashes, newlines, percent expansion,
or a missed marker can corrupt or partially translate installed Lua/menu
files. It also couples translations to exact English source fragments.

### Separate localized Lua/menu builds

Generating or maintaining one source variant per language avoids runtime TLK
lookups, but duplicates executable source and makes every UI change a
multi-language merge problem. Translator-facing files would also need Lua and
menu escaping knowledge. This is rejected for long-term maintenance.

### TLK-backed runtime localization (selected)

WeiDU resolves plain `.tra` entries into the active game TLK and writes only
numeric ID-to-strref pairs into a BuffBot-owned localization map file. Runtime
code fetches and caches those strings through `Infinity_FetchString`. Menu and
Lua code refer to semantic keys, so translated text is never injected into
executable source.

This uses the engine's normal localization channel, keeps translator files
plain and WeiDU-native, and safely supports punctuation and language-specific
word order.

## Architecture

### Catalogs

`buffbot/lang/english/setup.tra` is the canonical player-facing catalog.
`buffbot/lang/schinese/setup.tra` carries the same numeric IDs. IDs are grouped
by installer, runtime/menu, EEex Options, defaults, and generated innate names.

Every dynamic sentence is a complete template with named placeholders, for
example `Cast {name}` or
`Imported {file} ({presets} presets, {skipped} entries skipped)`. Translators
may reorder placeholders. Sentence fragments are not catalog entries.

Catalog validation rejects duplicate/missing IDs, malformed UTF-8, placeholder
set mismatches, and unreferenced or undefined runtime keys.

### Runtime module

`buffbot/BfBotLoc.lua` defines one namespaced API:

- `BfBot.L10N.Get(key)` returns a cached selected-language value.
- `BfBot.L10N.Format(key, values)` expands named placeholders without `string.format`
  ordering constraints.
- Missing mappings, failed TLK fetches, or source deployments fall back to a
  complete English table and never expose a raw sentinel to the player.

The installer copies this module unchanged and generates a separate numeric
mapping file. It never inserts translated text. `M_BfBot.lua` loads localization immediately
after Core and before the no-LuaJIT notice, Theme, persistence defaults, and UI.

Static `.menu` labels use `text lua` with localization keys. Lua-built labels
and feedback use `Get` or `Format`. `BfBotThm.lua` populates EEex's `uiStrings`
adapter from the same runtime API so the EEex Options tab shares the catalog.
Spell and item names already obtained through engine TLK references remain
unchanged.

### Installer

WeiDU `LANGUAGE` declarations appear after the existing `ALWAYS` block and
before the first component, as required by WeiDU 249. Both existing component
numbers, labels, helper-first declaration order, LuaJIT state detection,
upgrade exception, and uninstall ownership remain unchanged.

The main component resolves every runtime entry independently; it does not
assume contiguous TLK references. Numeric references are written as explicit
catalog-ID-to-strref pairs. The existing eight innate mappings remain
independent and gain localized `.tra` inputs. Installer
component names, predicates, failures, and progress messages use `.tra`
entries normally.

### Persistence

Default Long/Short names and generated `Preset {index}` names are localized
only when a new configuration/preset is created. Stored names are user data,
so later language changes do not rewrite them. Internal category values such as
`long`, `short`, spell resrefs, targets, and schema data stay language-neutral.

### Development and manual deployment

The checked-in runtime module contains the complete English fallback, so
`tools/deploy.sh` and a raw source copy show readable English without TLK
generation. The deploy script copies the new module and continues patching
innate tooltip references for its configured game. README will state that
localized installations require WeiDU.

### Packaging and documentation

The release workflow recursively packages `buffbot/lang/**` and every new
installer support file. A package allowlist test ensures no catalog is omitted.
README gains a localization section that:

- lists supported languages;
- explains the English fallback/manual-install boundary;
- welcomes translation pull requests;
- requires a complete catalog, preserved IDs/placeholders, UTF-8, and passing
  validation;
- credits translators, beginning with robovoid for Simplified Chinese.

## Error Handling

- Catalog defects fail tests before release rather than degrading silently.
- A missing/invalid runtime strref falls back to English for that key.
- An unknown localization key returns a conspicuous but non-crashing English
  fallback marker and records a warning when logging is available.
- Template expansion replaces only known `{identifier}` placeholders. Missing
  values remain visible to tests instead of being silently deleted.
- Localization failures never alter casting, persistence, component ordering,
  or uninstall state.

Two current English assumptions must be removed before claiming Chinese-safe
behavior. Project Image queue protection must identify opcode 236 with image
type 2 (including bounded opcode-146 wrappers), not the English display name.
Export filenames must not collapse every non-ASCII character name to the same
`Unknown.lua`; a collision-safe ASCII party-slot fallback is used when the
sanitized name is empty.

## Verification

Automated coverage will include:

- exact English/Chinese catalog ID and placeholder parity;
- runtime lookup caching, English fallback, reordered named placeholders, and
  missing-key behavior under Lua 5.1-compatible execution;
- source inventory checks for player-facing literals and localization keys;
- `.menu` localization-key integrity and Lua parse/load checks;
- real WeiDU 249 synthetic installs in English and Simplified Chinese;
- fresh install, helper-before-main, upgrade, uninstall, and language-switch
  lifecycle tests without regressing the LuaJIT safety contract;
- no raw sentinel/placeholder in installed output;
- release archive allowlist and install-from-archive validation;
- the complete existing test suite.

Live acceptance will use the existing BG2:EE “Copy Copy” installation. It
already contains `lang/zh_CN/dialog.tlk` and a `SIMSUN` font mapping, so a
separate Steam installation is not required. Test steps will temporarily select
`zh_CN`, install the Chinese BuffBot language, inspect all panels, submenus,
tooltips, runtime messages, EEex Options, normal/large text, and a constrained
resolution, then restore `en_US`. English behavior receives a comparison pass.

## Attribution and PR Handling

The implementation is rebuilt on current `main`. Chinese text derived from PR
#50 retains contributor credit through commit/release attribution. Once the
replacement is verified and released, PR #50 can be closed with a clear summary
of what was incorporated and why the stale implementation was not merged
directly.
