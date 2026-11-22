# BuffBot Localization & Translation Guide

## Supported Languages (9 catalogs)

- English (`english`)
- Simplified Chinese (`schinese` — 简体中文)
- Italian (`italian` — Italiano)
- German (`german` — Deutsch)
- French (`french` — Français)
- Spanish (`spanish` — Español)
- Polish (`polish` — Polski)
- Russian (`russian` — Русский)
- Brazilian Portuguese (`brazilian_portuguese` — Português do Brasil)

## Runtime Localization Architecture

The WeiDU installer asks which BuffBot translation to use and copies the selected UTF-8 catalog to `override/bfbot_l10n.tra`. BuffBot reads directly from that file for its UI, options, defaults, and player feedback. It fetches none of its own strings from the game TLK and adds none to it. Earlier versions wrote the eight F12 preset innate names into the TLK; WeiDU leaves appended strings in place on uninstall, so an upgraded installation keeps those, unused.

In a source checkout, the raw development deploy (`tools/deploy.sh`) keeps an existing WeiDU-selected `override/bfbot_l10n.tra` byte-for-byte; without one, BuffBot uses its built-in English fallback. The deploy never touches a TLK, and it stops before copying anything when `override/bfbot_l10n.tra` exists but is not a regular file. Leftover `bfbot_strrefs.txt` and obsolete `bfbot_l10n.txt` files are left alone and unused.

## Validation Status

All catalogs and installer paths have automated coverage. Live validation in a copied BG2:EE + EEex installation loaded a game and opened BuffBot successfully; user screenshots confirmed readable CJK labels and acceptable panel layout at the tested resolution/font. The Italian contributor tested the translated UI and buff casting in game. The six new catalogs began as AI-authored translations; the German catalog has since been reviewed by the German-speaking maintainer. None has yet been validated in-game, and native-speaker corrections remain welcome. The broader interaction/casting matrix and alternate resolutions/fonts remain pending, along with the compatibility boundaries listed in `CHANGELOG.md`.

## Adding a Language (Contributor Guide)

Language pull requests are welcome. BuffBot accepts complete catalogs so players never see a half-translated panel:

1. Copy `buffbot/lang/english/setup.tra` to `buffbot/lang/<language>/setup.tra`. Choose a safe lowercase folder name that starts with a letter and uses only `a-z`, `0-9`, and underscores.
2. Set `@113` to that exact folder name. This directory marker is non-translatable.
3. Translate every other value while preserving the exact `@` IDs, all comments, all named placeholders such as `{name}`, and every WeiDU token such as `%lua_version%`. Do not add or omit entries.
4. Keep the file UTF-8 and preserve the existing one-line tilde grammar (`@123 = ~Text~`).
5. Add the matching `LANGUAGE` stanza to `buffbot/setup-buffbot.tp2`. The release package manifest is derived from the `LANGUAGE` declarations, and the tests reject missing or undeclared catalogs.
6. Run `python -m pytest tests/test_localization.py tests/test_release_package.py -q` (and ideally the full test suite) before opening the PR.
7. Include the translator credit you would like shown in the README and release notes.
