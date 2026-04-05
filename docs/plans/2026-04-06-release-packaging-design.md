# Release Packaging Design

## Problem

Releases ship as GitHub auto-generated source archives with no WeiDU installer binary. Standard BG mod convention requires `setup-<modname>.exe` (WeiDU binary, renamed) in the release archive so players can double-click to install.

## Solution

GitHub Actions workflow (`.github/workflows/release.yml`) triggered on release publish. Downloads WeiDU from WeiDUorg/weidu, renames to `setup-buffbot.exe`, packages with mod files, uploads as release asset.

## Release Archive Layout

Flat — player extracts directly into game directory:

```
setup-buffbot.exe      ← WeiDU binary (renamed)
setup-buffbot.tp2      ← installer script
buffbot/               ← mod files (.lua, .menu, .BAM, .MOS, .PVRZ)
README.md
CHANGELOG.md
```

## WeiDU Version

Pinned in workflow env vars (`WEIDU_TAG`, `WEIDU_ASSET`). Currently v249.00 amd64. Bump by editing two lines.

## Workflow

1. Trigger: `release: types: [published]`
2. Checkout repo at release tag
3. Download + extract WeiDU Windows binary
4. Rename `weidu.exe` → `setup-buffbot.exe`
5. Stage: tp2, buffbot/, README, CHANGELOG
6. Zip and upload as release asset (`buffbot-<tag>.zip`)

## Excluded from Release

`docs/`, `tools/`, `local_assets_deletemeafter/`, `.gitignore`, `CLAUDE.md`, `.github/` — dev-only.

## Decisions

- **GitHub Actions over local script** — eliminates "forgot to package WeiDU" failure mode
- **Trigger on release publish, not tag push** — lets you write release notes first
- **Flat zip, no wrapper folder** — matches BG mod convention (extract into game dir)
- **WeiDU v249 amd64** — proven stable, EEex requires 64-bit Windows anyway
- **`--clobber` on upload** — safe to re-run workflow if packaging needs a fix
