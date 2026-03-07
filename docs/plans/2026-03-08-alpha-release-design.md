# Alpha Release Packaging Design

## Goal

Package BuffBot v1.0.0-alpha for public distribution — GitHub Release, player-facing README, Gibberlings3 forum post. Honest about AI-assisted development.

## Version

**v1.0.0-alpha** — feature-complete alpha. The "1.0" signals a real, usable mod (not a proof-of-concept). The "alpha" suffix sets expectations: works but rough edges remain (placeholder icons, visual polish pending).

- Bump `setup-buffbot.tp2` VERSION to `v1.0.0-alpha`
- Git tag `v1.0.0-alpha`
- GitHub Release with auto-generated source zip

## README Overhaul

Rewrite README.md for players (not developers). Structure:

1. **Hero** — one-line pitch, alpha status note
2. **Screenshot** — placeholder (`<!-- TODO: add screenshots -->`) for panel, spell list, picker
3. **Features** — bullet list with brief descriptions
4. **Requirements** — BG:EE/BG2:EE/EET + EEex v0.11.0+
5. **Installation** — WeiDU (primary) + manual fallback
6. **Usage** — opening the panel, workflow, presets, quick cast, export/import
7. **Known Limitations (Alpha)** — placeholder innate icons, panel visual polish, SR sub-spell edge cases, Windows-only export/import (io.popen uses `dir /b`)
8. **Testing & Bug Reports** — console commands, what to include
9. **AI Transparency** — matter-of-fact note about Claude Code assistance (see section below)
10. **Contributing** — issue tracker link, developer setup (deploy.sh), repo structure
11. **Credits** — EEex (Bubb), BubbleBuffs inspiration, Claude Code / Anthropic

Move developer-only content (CLAUDE.md explanation, detailed repo structure) into the Contributing section or trim.

## AI Transparency

Both README and forum post include an honest, non-apologetic note:

> **AI-Assisted Development**: BuffBot was built with significant assistance from [Claude Code](https://claude.ai/claude-code) (Anthropic's AI coding tool). The architecture, code, tests, and documentation were developed collaboratively between a human developer and AI. The code is fully open source — judge it on its merits. If you have concerns about AI-assisted mods, that's understandable; the source is there for review.

Tone: factual, transparent, not defensive. Acknowledge some people won't like it, but don't apologize for it.

## G3 Forum Post

Gibberlings3 → "Mods in Progress" section.

**Title**: `[BG2:EE/EET] BuffBot v1.0.0-alpha — In-Game Buff Automation`

**Structure**:
1. What it does (2-3 sentences)
2. Screenshot placeholder
3. Feature highlights (5-6 bullets, not exhaustive)
4. Requirements
5. Download (GitHub Release link)
6. Installation (WeiDU one-liner)
7. How to use (brief)
8. Known limitations
9. AI transparency note (same as README, maybe shorter)
10. Bug reports / feedback (GitHub Issues link)

Saved to `docs/forum-post-g3.md` for copy-paste.

**Tone**: enthusiastic modder sharing a passion project. "I built this because I wanted it, here it is, tell me what breaks." Not corporate, not overly formal.

## GitHub Release

- Tag: `v1.0.0-alpha`
- Title: `BuffBot v1.0.0-alpha`
- Body: condensed feature list, install instructions, known limitations, links to issue tracker and forum post
- Asset: GitHub auto-generates source zip from tag (no manual packaging needed)

## CHANGELOG.md

```markdown
# Changelog

## v1.0.0-alpha (2026-03-08)

Initial public alpha release.

### Features
- Dynamic spellbook scanning (memorized, innate, HLAs, kit abilities)
- In-game config panel with per-character tabs and up to 8 presets
- Parallel per-caster execution engine with skip detection
- Quick Cast mode (Off / Long only / All) for instant casting
- F12 innate abilities per preset per character
- Manual spell override (Add Spell / Remove)
- Config export/import across saves and characters
- Save game persistence via EEex marshal handlers
- 129 automated tests

### Known Limitations
- Innate ability icons are placeholder (Stoneskin icon)
- Panel visual design is functional but unpolished
- Spell Revisions sub-spell pattern (Barkskin, Dispelling Screen) may need manual override
- Export/import directory listing uses Windows `dir /b` (no macOS/Linux support)
```

## Decisions

- **v1.0.0-alpha over v0.1.0-alpha** — feature set warrants 1.0, alpha suffix manages expectations
- **G3 only** (no Beamdog/Reddit) — primary modding community, can cross-post later
- **AI transparency upfront** — honest, non-defensive, source is open
- **Screenshots deferred** — prep everything, user adds screenshots before posting
- **No separate CONTRIBUTING.md** — fold developer info into README Contributing section to keep file count low
