# BuffBot

An in-game configurable buff automation mod for Baldur's Gate: Enhanced Edition (BG:EE) and Baldur's Gate II: Enhanced Edition (BG2:EE).

## Overview

BuffBot dynamically reads party spellbooks and lets the player configure buff casting sequences through an in-game UI. Instead of hardcoded spell lists, the mod scans each party member's currently memorized and known spells in real time, presenting only what's actually available.

Key features (planned):

- **Dynamic spellbook scanning** — automatically discovers available buff spells from party members
- **In-game configuration UI** — select which spells to cast, on which targets, and under what conditions
- **Long/short buff split** — separate pre-dungeon buffs from pre-combat buffs
- **Button-triggered casting** — player stays in control of when buffs are applied

## Dependencies

- [EEex](https://github.com/Bubb13/EEex) — extends the Infinity Engine with Lua scripting access to engine internals

## Inspiration

Inspired by [Bubble Buffs](https://www.nexusmods.com/pathfinderkingmaker/mods/195) from Pathfinder: Kingmaker.

## Status

Early development. Not yet playable.

## Repo Structure

```
buffbot-bgee/
├── docs/       # Analysis docs, design notes, reference material
├── src/        # Mod source (Lua, .menu, .BAF, .tp2, etc.)
├── tools/      # Helper scripts and utilities
├── CLAUDE.md   # Project context for Claude Code sessions
├── README.md
└── .gitignore
```
