# BuffBot Redux

**In-game configurable buff automation for Baldur's Gate: Enhanced Edition.**

Cast all your pre-battle buffs with one click. BuffBot scans each character's spellbook, lets you configure which buffs to cast, in what order, on which targets — then executes the entire sequence automatically across all party members in parallel.

> **Development fork based on v1.10.1.** The recipient-first beta has expanded native spell, item, summon and save/load acceptance in isolated single-player EET copies. See [the compatibility report](docs/compatibility-test-report.md) for tested scope and remaining limits, and `docs/recipient-first-checklist.json` for the checklist.

### Recipient-first beta

BuffBot's redesigned panel works with **stock BG:EE/BG2:EE/EET and UI++**.
Settings → Theme offers Auto, SoD, IWD, BG1 and BG2. Auto follows UI++ when
present and defaults to BG1 otherwise; manual choices affect BuffBot only.
Private control resources come from the supplied design exports. Standard game
fonts are used when UI++ fonts are absent.

A persistent gear button sits beside/above the actionbar, moving above an
expanded message log. Left-click edits plans; right-click opens a named preset
picker. Picking a plan dispatches it directly, without casting an innate or
spending an extra character action. Native casting/combat rules still apply.
Preset innate shortcuts have been retired; old saves lose only those BuffBot
abilities on load. Real spell and kit innates remain available as buff sources.
Expertise's activate/deactivate stance is excluded from automatic discovery;
manual Add can restore it.


The gear menu now supports preset deletion and `.bbp` plan export/import in
`override/bfbot_plans`. Casting defaults to **2x** simulation speed, with
**4x** and **Normal** available in Settings → Casting. Spells and items use
native casting, aura and duration rules; there are no effect-expiry rewrites.
Eligible party members can borrow a unique daily charged item, use it and
return it automatically, sharing its real charges. See
[the feature guide and current limits](docs/plan-management-and-casting-beta.md).

Live allied spellcasters, including Simulacra, Project Images and Devas, also
contribute available casts. They are sources only; recipients remain the six
party members. Missing saved summons stay unavailable until a matching summon
returns. Project Images lock their owners before source allocation.

Right-click the HUD gear to launch a named whole-party preset directly. Preset
innates are retired, including their grants, title updates and recharge hooks.

The **Redux visual interface** ships private controls for all four themes.
Auto follows UI++'s skin when present, or defaults to BG1. Optional matching
fonts use native NORMAL/STONESML fallbacks. UI++ is not required. Compact and
wide layouts use fixed geometry; wide requires its full 1920×1080 canvas.
See [visual review and native screenshots](docs/visual-review/review.md) for
validation, design deviations and experimental-beta limitations. The review gallery
is provided in the source checkout and separate review bundle.

F11 and the BuffBot button open the **Buffs** dashboard. The top row contains
**Buffs**, **Order**, and **Summary**, with a preset dropdown and
**+** on the right. There is no title banner or separate recipient editor.
Click a recipient cell to toggle a buff; **Party** schedules one party-wide cast.
The dashboard packs eligible recipients into a portrait strip, omitting invalid
targets and empty placeholders. A planned recipient whose source becomes
unavailable stays visible with a warning so the assignment can be removed.
The redesigned table labels **Name**, **Uses**, **Duration** and **Recipients**,
with spell icons at the left and **Clear** at the right.
Uses means free / total. The row's duration is the full compatible source range,
including weaker sources before any uses are reserved. Each portrait shows its
actual assigned or next-cast duration. Eligible portraits remain visible when
uses run out; the uses field gets a subtle warning and blocked clicks spend nothing. Party buffs use one stacked-portrait **Party** toggle
in the recipient area and schedule one cast. To apply a targeted buff to several
characters, select their portraits individually. **Clear** removes the row's
assignments. Character tabs filter the same list,
and party-wide spells remain available in those focused views.
The small **Search** field at the top filters spell names as you type; **X** clears
it. Changing or clearing search returns the list to the top. Click **Name** or
**Duration** to sort, then click again to reverse direction.
The active header shows an arrow. Duration ranges sort by their longest value;
unknown/unavailable durations stay last. Browser sorting does not alter cast order. Values update in place while editing;
rows keep their positions until you click a sort header, switch recipient/preset,
refresh sources, or reopen the panel. Clicking an open dropdown's trigger again
closes it.

**Summary** groups spell icons and names under recipient portraits, with caster
and duration columns. **Order** shows numbered casts, spell icons, recipients,
casters and durations. Inline up/down arrow buttons move a cast; **X** removes it.
Both views have a caster dropdown on each planned buff. It shows the assigned
caster, offers **Auto** or an explicit preference, and greys out unavailable
choices with their reasons. Auto prefers longer duration, then effective caster level.
The allocator
can move an earlier automatic assignment to another eligible caster when that
preserves a source required by a later recipient.

Native sorcerer/shaman level slots and physical item charge counters are
reserved across the whole plan. Available uses are shown as unreserved/total.
Empty or unknown sources are filtered from the dashboard; planned entries remain
visible when a source disappears or an item runs out. Click a spell name for its
sources, durations, and **Hide**. Selection spells such as Spell Immunity show
each discovered variant as its own named row and icon. Different recipients can
choose different schools, and multiple schools can be planned for one recipient
when enough parent uses remain. All variant rows reserve the same underlying
parent spell/level pool. **Clear** affects only that variant's assignments;
**Hide spell and all variants** hides the parent family without deleting requests.
The source popup names the selected variant and explains its shared uses.
Hidden spells remain in the plan and
summary; **Hidden** restores them. **Add spell / item** includes known abilities
the classifier missed. These browser choices save with the party plans.
Dropdowns and modals have a distinct
outline and an offset shadow to distinguish them from the planner background.
Only identical spell resources or identical item power identities are combined;
same-name variants remain separate. Self-only and party-wide restrictions still
apply. Expected duration is an estimate from resource metadata, not a guarantee
of identical strength, kit behavior, or every conditional effect.

The [upstream compatibility audit](docs/recipient-upstream-compatibility.md)
distinguishes retained upstream features from features still available only in
**Options → Caster editor**. The recipient dashboard does not yet replace every
legacy workflow.

Improved invisible recipients carry a warning because the engine can reject
targeted casts on them. Put invisibility after other targeted buffs when needed.
The execution log counts issued actions; an issued action does not prove an
effect landed. The live check verified effects and prepared-slot consumption
separately. The tested SPIN137 innate remained available after use, so its counts
were not used as evidence of spell-slot consumption.

The isolated EET checks verified Gargoyle Boots charge consumption, active-buff
skipping, and restoration after an equipment swap. Darkfire's Improved Haste
works from inventory without ammunition. The verified BG2EE native inventory
check now handles item usability; other engines retain the conservative fallback.
Unique daily charged backpack items support cross-character borrowing and return.
Child spell effects can arrive after the executor finishes issuing item actions.

Choose a preset or **Off** from **After rest** to control automatic casting after
a completed standard eight-hour party rest. This selection is independent of
the preset being edited. It starts off and is stored in the save with the party plans.
The mod waits for the world to be controllable, uses the selected casting speed, and
keeps your active editing preset and pause state. Interrupted rests, individual
spell restoration, and loading a save do not trigger it. Combat cancels a pending
run; unavailable requests skip the entire rest plan. Special shortened rests and
other mods' rest replacements need separate compatibility checks.

The gear menu contains preset management, casting speed, refresh, legacy
import, and **Caster editor**.
**Caster editor** opens the original interface. **Import caster preset** copies
the matching legacy preset into an empty party plan, retaining caster choices
and leaving the originals intact. Party plans save separately in EEex saves.
Settings → **Preset abilities...** chooses which PCs receive all numbered shortcuts (one, several, or none). Multiplayer retains legacy character routing. Party-plan casting excludes
5E-converted sources and does not auto-join summons. Independent casters overlap;
physical item loans retain transfer/use/return boundaries. Native time advances
at the selected speed, so existing buffs, delayed effects and fatigue follow the
engine clock. A lightweight speed audit is written to
`buffbot_fast_forward_audit.jsonl`. Order offers Smart order, Long first and Undo.
Smart order puts incoming targeted buffs before invisibility on their recipient;
self and party casts may follow. Only the invisibility cast waits for those
prior targeted casts, leaving unrelated casters independent.
New planner text uses English fallbacks in
the other language catalogs pending translation.

> **BuffBot requires EEex v0.11.0-alpha or later. EEex v1 is recommended.**

[![BuffBot Showcase](https://img.youtube.com/vi/9fjnUKG1tfQ/maxresdefault.jpg)](https://www.youtube.com/watch?v=9fjnUKG1tfQ)

## Features

- **Dynamic buff-source scanning** — discovers buff spells from memorized, innate, HLA, and kit sources, plus the F8 Use Item buff powers of identified equipment and potions carried by party members. No hardcoded spell or item lists
- **Items and potions** — configure each item power independently, including powers beyond the first ability and items carried in the backpack. Item rows are visually distinct and disabled by default; BuffBot finds the current stack or equipped copy when casting
- **In-game config panel** — per-character tabs, scrollable buff list with enable/disable, duration display, target assignment, per-entry R1–R5 repeat counts, priority ordering, sort-by-duration, and row locks
- **Up to 8 presets** — independent buff configurations per character (Long Buffs, Short Buffs, Boss Fight, Undead Prebuff, etc.) with create/rename/delete
- **Summons and clones as casters** — configure Project Images, Simulacra, and other allied spellcasting summons in a dedicated Summons view; cast one summon alone or let configured summons join Cast All
- **Quick Cast mode** — per-preset 3-state toggle (Off / Long only / All) for fast casting via Improved Alacrity. Long mode fast-casts only long-duration buffs, then casts short buffs normally. 5E casters still pause while that mod refreshes their spell slots
- **F12 innate abilities** — each party character gets one innate per preset in their special abilities, triggering party-character buffing directly from gameplay without opening the panel
- **Skip active buffs** — detects already-active buffs via spell state + effect list checks, including wrapper potion leaf spells. No wasted spell slots, stacks, or charges
- **Manual override** — the Add picker can include spells or supported activated item powers the classifier missed and recover removed spells or items, grouped into separate sections
- **Config export/import** — export a character's full setup to a file, import onto any character across saves or between players
- **Save game persistence** — configuration saved per-character in EEex save games. Survives save/load automatically
- **Subwindow selection spells** — pre-configure which variant to cast for spells like Protection from Elemental Energy, and BuffBot bypasses the popup. Converted 5E casters must cast these spells manually
- **Experimental 5E Spellcasting compatibility** — use normal spell names and presets while [5E Spellcasting](https://github.com/UnearthedArcana/5E_spellcasting) handles preparation and shared spell slots. See the [current state and limitations](#5e-spellcasting-experimental)
- **Mod-friendly** — tested with SCS, Spell Revisions, and kit mods. Reads spell data dynamically, so mod-added spells show up automatically

### Casting speed

In Settings → Casting, **Fast-forward 2x** is the default. Choose it to run normal spell/item actions with the whole simulation accelerated. **4x** is experimental; a temporary 30 FPS render ceiling now gives the simulation room to run faster, while preserving lower existing limits. This mode performs no duration edits; it restores the previous simulation rate when the plan finishes or is interrupted. Old Balanced settings migrate to 2x; explicit Normal and fast-forward preferences are retained. Balanced Quick Cast and its observer/expiry adjustment module have been removed. See [the feature guide](docs/plan-management-and-casting-beta.md#native-fast-forward-casting-alternative-beta-mode) for measurements and limits.

## Requirements

- **BG:EE**, **BG2:EE**, or **EET**
- **[EEex](https://github.com/Bubb13/EEex)** v0.11.0-alpha or later, with LuaJIT active (v1 recommended)

EEex v0.11 and v1 have full BuffBot feature parity. LuaJIT must be active before BuffBot's main component installs. You can enable it through EEex's LuaJIT / Experimental option, or install BuffBot's **EEex LuaJIT Support** helper first. The main component validates the actual loader configuration and DLLs, so LuaJIT activated externally by EEex is accepted without requiring ownership by BuffBot.

EEex v0.11 keeps its internal Lua files in `override/`. When using v0.11, install EEex and BuffBot late in the mod order — after generalized biffing and any later file-replacement step — so those files cannot be consumed or replaced.

Do not assume an arbitrary save can be downgraded to v0.11 after EEex v1 and other EEex mods have written it; that downgrade is not guaranteed safe.

<details>
<summary><strong>For the curious: how EEex tiers and LuaJIT layouts interact</strong></summary>

EEex v1's Minimal and Full tiers leave LuaJIT off by default; Experimental enables it. BuffBot checks the loader state and required DLLs instead of relying on EEex component numbers. Its helper enables or repairs LuaJIT when needed, using `LuaVersionExternal=5.1` for v0.11's older layout and `LuaVersionExternal=5.1-LuaJIT` for v1's newer layout. The helper makes no file changes when the matching runtime is already active.

</details>

## Languages

- English
- Simplified Chinese (简体中文)
- Italian (Italiano)
- German (Deutsch)
- French (Français)
- Spanish (Español)
- Polish (Polski)
- Russian (Русский)
- Brazilian Portuguese (Português do Brasil)

The WeiDU installer asks which BuffBot translation to use and copies the selected UTF-8 catalog to `override/bfbot_l10n.tra`. BuffBot reads directly from that file for its UI, options, defaults, and player feedback; no BuffBot-owned UI string is fetched from the game TLK. Only the eight generated F12 innate names remain TLK-backed because SPL resources require numeric strrefs: WeiDU resolves catalog entries `@200` through `@207` and records them in `bfbot_strrefs.txt`.

In a source checkout, the raw development deploy (`tools/deploy.sh`) has two explicit paths. When `override/bfbot_l10n.tra` and `override/bfbot_strrefs.txt` both exist, it preserves an existing `override/bfbot_l10n.tra` together with its innate references, preserves both files byte-for-byte, and skips TLK patching entirely. If the catalog exists without the reference file, the helper stops before copying runtime files and asks you to reinstall BuffBot with WeiDU. When no selected catalog exists, the clean English-fallback path patches only `lang/en_US/dialog.tlk` with the English F12 names and generates `bfbot_strrefs.txt`, leaving the root and other language TLKs untouched. This fallback requires Python 3 and an existing `lang/en_US/dialog.tlk`; it also refuses an unsafe catalog or reference path. If a prerequisite is missing, the helper refuses the fallback before copying files. An obsolete `bfbot_l10n.txt` alone is preserved but does not select localized deployment.

All catalogs and installer paths have automated coverage. Live validation in the Copy Copy BG2:EE + EEex installation loaded a game and opened BuffBot successfully; user screenshots confirmed readable CJK labels and acceptable panel layout at the tested resolution/font. The Italian contributor tested the translated UI and buff casting in game. The six new catalogs began as AI-authored translations; the German catalog has since been reviewed by the German-speaking maintainer. None has yet been validated in-game, and native-speaker corrections remain welcome. The broader interaction/casting matrix and alternate resolutions/fonts remain pending, along with the compatibility boundaries listed in the changelog.

## Installation

### WeiDU (recommended)

1. Download the [latest release](https://github.com/zach-hopkins/bg-eeex-buffbot/releases) and extract it into your game directory
2. Run `setup-buffbot.exe` (or use your preferred WeiDU launcher)
3. Select **BuffBot: EEex LuaJIT Support** first if EEex did not already activate LuaJIT
4. Select **BuffBot: In-Game Buff Automation** after LuaJIT is active

For **Project Infinity**, explicitly select both BuffBot components and place **EEex LuaJIT Support** (component 1) before **In-Game Buff Automation** (component 0). Project Infinity does not infer that prerequisite from the component name. If EEex already activated the exact matching LuaJIT runtime, selecting only the main component is also valid.

**Updating an existing BuffBot install:** select or reinstall both BuffBot components together. Older releases recorded the main component before the helper, so updating only main makes WeiDU temporarily remove LuaJIT support and the safety check rejects that pass. The helper is restored safely, but the main component is left uninstalled; if this already happened, run setup again to install main.

For **EET**, BuffBot can be installed after `EET_end`; EEex and LuaJIT must be ready first. With EEex v0.11, keep EEex and BuffBot after generalized biffing or later file-replacement steps as noted above.

**Uninstall:** remove **In-Game Buff Automation** first, then remove **EEex LuaJIT Support** if BuffBot installed it. The helper restores the exact loader files that preceded its installation. LuaJIT owned by EEex is left unchanged when BuffBot's helper made no changes.

### Manual Development Copy

Raw/manual copying is a development-only path from a source checkout, not the normal release installation. Only use it when EEex LuaJIT is already active, because it bypasses the prerequisite check. Copy the runtime Lua, menu, BAM, MOS, and PVRZ files from `buffbot/` to your game's `override/` directory. The deploy helper treats a pre-existing `bfbot_l10n.tra` plus `bfbot_strrefs.txt` as one WeiDU-owned localized pair: it preserves both and does not patch any TLK. A catalog without its reference file is refused as inconsistent installer state. With no catalog, the runtime uses English fallback text and the helper patches only the English TLK to create the eight F12 innate references. Copying files manually without either a coherent WeiDU pair or that fallback patch may leave the innate names blank; players should use WeiDU for complete localized strings.

## Usage

### Opening the Panel

- **Actionbar button** — appears to the right of the action bar
- **F11** — keyboard shortcut
- **Right-click actionbar button** — choose a named whole-party preset without an extra innate action

### Basic Workflow

1. Open the panel with F11 or the gear.
2. Select a preset: fresh plans have empty Pre-Battle Buffs and Wake Up Buffs lists.
3. Find a buff and click the recipients who need it; sources are assigned automatically.
4. Use Order to move casts, choose casters, or apply Smart order/Long first.
5. Use Summary to check each recipient's coverage.
6. Click Cast, or right-click the HUD gear to run a named plan.
7. Settings → Casting offers Fast-forward 2x (Recommended), 4x and Normal.
8. After Rest initially points to the empty Wake Up Buffs list; populate it to automate waking preparation.

The remaining per-caster controls below describe the retained **Caster editor**.
Preset innate shortcuts are retired in both interfaces.

### Presets

- Default presets auto-populate from scanned sources: long/permanent spells are enabled in preset 1, short spells in preset 2, and items are present but disabled
- Create new presets for specific situations (up to 8 per character)
- Each preset is fully independent — own spell list, targets, repeat counts, priorities, and Quick Cast setting
- Newly recruited companions inherit the protagonist's current preset slots, names, and categories when BuffBot first configures them; their own spells and items start disabled and Quick Cast starts Off

### Repeat Casts

Each spell or item row shows R1–R5. Click its repeat cell to increase the count, or select the row and use **Repeat: N**: left-click increases and right-click decreases. Both controls wrap between 1 and 5 and remain editable when the source currently has zero uses.

Repeats are target-major. With targets A and B at R2, BuffBot attempts A, A, B, B. A party-wide AoE at R2 is cast twice total, not twice per party member. Every repeat rechecks availability, target state, and active effects. A spell attempt consumes one available use and follows normal aura/casting rules; an item attempt consumes a stack or charge and follows normal item-use rules. Quick Cast applies only to spells. Skipped attempts consume nothing.

### Items and Potions

BuffBot scans identified items in a party character's equipment, quick slots, and backpack. Each supported buff power from **F8 Use Item** gets its own row, including secondary powers on weapons. Powers keep their configuration when the item moves between slots. Exhausted powers remain visible with zero uses; the engine handles normal charges, consumption, and recharge rules.

Buff detection follows immediate opcode-146 child spells through two links,
including item powers that contain only a spell wrapper and visual effects.
The item's targeting rules and charge counters remain authoritative. Missing,
cyclic, delayed, or deeper delivery chains are left for manual inclusion through
**Add**. Supported powers that are not recognized as buffs also appear in Add;
they are not automatically added to presets. Scrolls, wands, and container
contents remain outside this discovery path.

In **EEex options → BuffBot → Inventory item use**, choose:

- **Use from inventory** (default) — activate the chosen power from its current slot.
- **Equip, use, and restore** — temporarily equip carried gear, activate the chosen power, then restore the previous equipment. Potions are consumed directly in either mode.

Automatic swapping skips chest armor, gear the character cannot wear, and items with conditional usability restrictions. It also skips ambiguous equipment copies with the same item resource; equip the desired copy manually to use it. Unfinished swaps are recorded in the save for recovery after interruption or loading. If the relevant equipment has changed manually, BuffBot leaves it alone instead of overwriting the change.

Scrolls, wands, and items inside containers or Bags of Holding remain unsupported. The expanded item support has been inspected offline against BG2:EE 2.6.6.0; deployment and in-game acceptance on BG:EE/BG2:EE are still pending.

### Summons and Clones

1. Create the allied summon or clone, then open BuffBot and switch from **Party** to **Summons**.
2. Select the live summon tab and enable the spells it should cast. Those enabled rows are its cast selection; there is no separate pre-cast queue checkbox.
3. Use **Cast (this summon)** to run only that summon, or **Cast All** to run the party preset and every configured live summon together. A configured summon created during the run joins automatically.
4. To create multiple ordinary summons, set R2–R5 on the summoning spell in its caster's party preset. Project Image is always limited to one attempt for owner-lock safety. Repeat counts in a summon tab instead control spells cast by that summon.

Clone presets are stored by owner identity and are reused when that owner's clone is created again. On first open they seed from the owner's matching preset, limited to spells the clone can cast. To disable automatic participation globally, set `SummonsJoinCast = 0` under `[BuffBot]` in `baldur.ini`.

Items are party-only in this release. Summon and clone presets remain spell-only even if a copied creature carries or inherits equipment.

Project Image locks its owner while active. BuffBot limits the Project Image cast itself to one attempt, skips locked owners, and drops owner entries placed after it so they cannot fire later as delayed casts. Put anything the owner must cast before Project Image earlier in the priority order. Redux retires copied BuffBot shortcuts as well; summon spells remain available as casting sources.

### Export / Import

- Click **Export** to save a character's entire config (all presets + overrides) to a file
- Click **Import** to load a config from any exported file onto the current character
- Spells the target character doesn't have are silently skipped
- Files are saved in `override/bfbot_presets/` — share them with other players or use across playthroughs

## 5E Spellcasting (experimental)

Starting with **v1.9.0-alpha**, BuffBot can work with the existing [5E Spellcasting mod](https://github.com/UnearthedArcana/5E_spellcasting). Install 5E Spellcasting before BuffBot, prepare spells through 5E's own interface, then rest. BuffBot detects the mod automatically; there is no separate compatibility component. This adds compatibility with that mod, not a separate implementation of 5e casting in EEex.

Your spells appear under their normal names. Available casts come from 5E's shared pool for that spell level, so spending one level-2 slot also reduces the availability of other level-2 spells. A short pause between casts is expected, including with Quick Cast: 5E schedules a one-second spell-list refresh, and BuffBot waits for casting to become available again.

**Current state:** a user playtest with BG2:EE 2.6.6, EEex 1.2.0 with LuaJIT, and 5E Spellcasting 2.7.2 confirmed that a short arcane buff preset with Quick Cast runs responsively after a performance fix. The logs also show active-buff skips. The release has 535 passing automated tests, but this is not a complete in-game compatibility test.

- **Cast variant-selection spells manually** on converted casters; BuffBot skips them even if a variant is configured.
- **Wider testing is still needed:** shared-slot exhaustion and rest/preparation changes, divine and multiclass/dual-class casters, mod-added spells, summons/clones, BG:EE, and EET.
- **Existing presets:** entries that directly referenced an old internal `D5Z...I` casting ability must be replaced with the spell's normal entry. During an unfinished dual-class conversion or preparation step, BuffBot may leave affected spells unavailable; it will not spend ordinary memorization slots as a fallback.

Feedback is welcome. The [5E tester guide](docs/5e-spellcasting.md) has a short checklist and explains which logs to include in a bug report.

## Known Limitations

The following limitations remain:

- **Panel visuals** — functional but unpolished. The layout works, the aesthetics don't win awards
- **Spell Revisions sub-spells** — some SR spells (Barkskin, Dispelling Screen) deliver effects via sub-spells, so the classifier may show them as ambiguous. Use "Add Spell" to manually include them
- **Windows only for export/import listing** — the file picker uses Windows `dir /b` for directory listing. The core export/import file I/O works on any platform, but the picker won't list files on macOS/Linux
- **Deferred item sources** — scrolls, wands, and items inside containers or Bags of Holding are not scanned yet
- **Automatic equipment swaps** — chest armor, unusable or conditionally usable gear, and ambiguous duplicate equipment copies require manual equipping; see [Items and Potions](#items-and-potions)
- **5E Spellcasting support is experimental** — basic BG2:EE casting has been user-tested; the [limitations and wider testing needs](#5e-spellcasting-experimental) above still apply

## Testing & Bug Reports

BuffBot includes a built-in test suite. In the in-game console (the BG:EE / BG2:EE console — toggle with Ctrl-Space when `CLUAConsole=1` is set in `baldur.ini`):

```
BfBot.Test.RunAll()         -- full test suite (600+ assertions)
BfBot.Test.ExportImport()   -- export/import tests
BfBot.UI.Toggle()           -- open/close config panel
```

Log files are written to the game directory: `buffbot_test.log`, `buffbot_exec.log`.

For 5E Spellcasting reports, also run `BfBot.FiveE.Diagnose()` in the console and include `buffbot_5e.log` and `WeiDU.log`. See the [5E tester guide](docs/5e-spellcasting.md#reporting-a-problem).

**Reporting bugs:** please open an issue at [GitHub Issues](https://github.com/zach-hopkins/bg-eeex-buffbot/issues) with:
- Game version (BG:EE / BG2:EE / EET) and EEex version
- Steps to reproduce
- Mod list (especially SCS, Spell Revisions, kit mods)
- Output from `BfBot.Test.RunAll()` if relevant

## AI-Assisted Development

BuffBot was built with significant assistance from [Claude Code](https://claude.ai/code) (Anthropic's AI coding tool). The architecture, code, tests, and documentation were developed collaboratively between a human developer and AI.

The code is fully open source — judge it on its merits. If you have concerns about AI-assisted mods, that's understandable; the source is there for review.

## Contributing

Found a bug? Have a feature idea? [Open an issue](https://github.com/zach-hopkins/bg-eeex-buffbot/issues) on GitHub.

### Adding a Language

Language pull requests are welcome. BuffBot accepts complete catalogs so players never see a half-translated panel:

1. Copy `buffbot/lang/english/setup.tra` to `buffbot/lang/<language>/setup.tra`. Choose a safe lowercase folder name that starts with a letter and uses only `a-z`, `0-9`, and underscores.
2. Set `@113` to that exact folder name. This directory marker is non-translatable.
3. Translate every other value while preserving the exact `@` IDs, all comments, all named placeholders such as `{name}`, and every WeiDU token such as `%lua_version%`. Do not add or omit entries.
4. Keep the file UTF-8 and preserve the existing one-line tilde grammar (`@123 = ~Text~`).
5. Add the matching `LANGUAGE` stanza to `buffbot/setup-buffbot.tp2`. The release package manifest is derived from the `LANGUAGE` declarations, and the tests reject missing or undeclared catalogs.
6. Run `python -m pytest tests/test_localization.py tests/test_release_package.py -q` (and ideally the full test suite) before opening the PR.
7. Include the translator credit you would like shown in the README and release notes.

### Developer Setup

For iterative development without running WeiDU each time:

```bash
# Set your game path (one-time setup)
echo 'BGEE_DIR="/path/to/your/game"' > tools/deploy.conf

# Deploy to game override
bash tools/deploy.sh
```

Requires Python 3 only for the clean English-fallback TLK patch (innate ability tooltip names). Localized WeiDU state is preserved without invoking the patcher.

### Repo Structure

```
bg-eeex-buffbot/
├── buffbot/              # Mod source files (copied to override/)
│   ├── setup-buffbot.tp2 # WeiDU installer
│   ├── M_BfBot.lua       # Bootstrap (auto-loaded by EEex)
│   ├── BfBotCor.lua      # Core namespace, logging, field resolution, caches
│   ├── BfBotLoc.lua      # File-backed UTF-8 localization with English fallback
│   ├── BfBotCls.lua      # Buff classifier (opcode scoring)
│   ├── BfBotScn.lua      # Spellbook scanner (known spells iterators)
│   ├── BfBot5e.lua       # Optional 5E Spellcasting compatibility
│   ├── BfBotExe.lua      # Execution engine (parallel per-caster)
│   ├── BfBotPer.lua      # Persistence (marshal handlers, presets, export/import)
│   ├── BfBotInn.lua      # Retired-shortcut cleanup and legacy helper spells
│   ├── BfBotUI.lua       # Config panel logic
│   ├── BfBotTst.lua      # Test suite (600+ assertions)
│   ├── BuffBot.menu      # UI definitions (.menu DSL)
│   └── lang/             # Complete WeiDU translation catalogs
├── tools/                # Dev utilities
│   ├── deploy.sh         # Copy files to game override
│   └── patch_tlk.py      # TLK patcher for innate tooltips
├── docs/                 # Design docs and analysis
└── README.md
```

## Credits

- **[EEex](https://github.com/Bubb13/EEex)** by Bubb — makes this entire mod possible
- **[Bubble Buffs](https://github.com/factubsio/BubbleBuffs)** by factubsio — original inspiration (Pathfinder: WotR)
- **[5E Spellcasting](https://github.com/UnearthedArcana/5E_spellcasting)** by subtledoctor — the casting system used by BuffBot's experimental 5E compatibility
- **Endarire** — encouragement and the request for 5E Spellcasting compatibility
- **[robovoid](https://github.com/robvoid)** — original Simplified Chinese translation in [PR #50](https://github.com/Chrizhermann/bg-eeex-buffbot/pull/50); the implementation was reworked on BuffBot's current localization architecture
- **[Sauler89](https://github.com/Sauler89)** — Italian translation
- **OpenAI Codex** — initial AI-authored German, French, Spanish, Polish, Russian, and Brazilian Portuguese translations; German reviewed by the maintainer
- **[Claude Code](https://claude.ai/code)** by Anthropic — AI development assistant

## License

[MIT](LICENSE)


Fresh party plans start with two empty lists: **Pre-Battle Buffs** (selected)
and **Wake Up Buffs**. After Rest is enabled for Wake Up Buffs. An empty rest list
does nothing silently; existing saved lists and rest preferences are preserved.
