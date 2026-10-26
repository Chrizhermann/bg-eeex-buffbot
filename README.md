# BuffBot Redux

**In-game buff automation for Baldur's Gate: Enhanced Edition.**

Pick the buffs your party needs, then cast the whole list with one click. BuffBot finds who can cast each spell and lets party members cast at the same time.

This is a **single-player beta fork of [BuffBot v1.10.1](https://github.com/Chrizhermann/bg-eeex-buffbot)**. Redux puts the person getting a buff first. The original caster editor is still available for its extra controls.

## Features

- **One party list** — see your buffs in one place. Click a portrait to give that person a buff. A **Party** button adds one party-wide cast.
- **Automatic caster choice** — BuffBot picks an eligible caster, usually favoring a longer duration. You can choose a caster yourself. Shared spells and item charges are counted together, so the plan cannot spend the same use twice.
- **Clear spell choices** — see icons, uses and durations. Spell Immunity's schools have separate rows, but spend the same spell slots.
- **Up to eight saved lists** — create, rename, delete, export and import plans. Your plans stay with your save.
- **Helpful cast order** — Smart Order puts long buffs first, considers casting time, and puts spells aimed at someone before that person's invisibility. It updates as you edit the plan. Custom keeps your own order.
- **Faster preparation** — normal spell and item actions run at **2x speed** by default. Casting rules, spell slots, buff timers and delayed effects still use the game's own clock.
- **After-rest buffs** — choose a list to cast after a completed rest. Interrupted rests do not trigger it.
- **Item powers** — use supported powers from carried gear and potions. For eligible daily-use gear, a party member can borrow it, use it and return it. The real charges are spent.
- **Summon casters** — live allied casters, such as Simulacra and Project Images, can supply spells. Buff targets remain the six party members.
- **Four themes** — SoD, IWD, BG1 and BG2. Infinity UI++ is optional. Auto follows its theme if installed; otherwise BuffBot uses BG1.

## Requirements

- **BG:EE, BG2:EE or EET**.
- **[EEex](https://github.com/Bubb13/EEex) v0.11.0-alpha or later**, with LuaJIT active. EEex v1 is recommended.

Redux has been tested mainly in copied single-player BG2:EE/EET installs. Multiplayer and every game/mod combination have not been checked.

## Languages

The installer offers English, Simplified Chinese, Italian, German, French, Spanish, Polish, Russian and Brazilian Portuguese. Some new Redux text still uses English fallback text.

<details>
<summary>Translation status and file details</summary>

WeiDU copies the selected UTF-8 catalog to `override/bfbot_l10n.tra`. BuffBot reads directly from it; no BuffBot-owned UI string is fetched from the game TLK. The installer still keeps `bfbot_strrefs.txt` for compatibility with older F12 innate resources. Redux no longer grants those shortcuts.

The six new catalogs began as AI-authored translations. The German catalog has since been reviewed by the maintainer; none has yet been validated in-game. Native-speaker corrections remain welcome. Earlier Chinese user screenshots confirmed readable CJK labels at the tested resolution/font; alternate resolutions/fonts remain pending. Italian was tested by its contributor. These checks do not mean every new Redux label has been translated or reviewed.

</details>

## Installation

1. Download the install ZIP from [Releases](https://github.com/zach-hopkins/bg-eeex-buffbot/releases). Extract it into your game folder.
2. Run **setup-buffbot.exe**.
3. If LuaJIT is not active, install **BuffBot: EEex LuaJIT Support** first.
4. Install **BuffBot: In-Game Buff Automation**.
5. Start the game through **InfinityLoader.exe**.

When updating, select or reinstall both BuffBot components together. If EEex already provides the matching LuaJIT runtime, only the main component is needed. In Project Infinity, put the LuaJIT helper before the main component when using both.

For EET, BuffBot can go after `EET_end`. With EEex v0.11, install EEex and BuffBot after generalized biffing and later steps that replace files. Do not downgrade an existing EEex v1 save just to use this mod.

To uninstall, remove the main component first, then the LuaJIT helper if you used it.

## Usage

### Open and cast

- Press **F11** or left-click the **gear beside the action bar** to open BuffBot.
- Right-click the gear and pick a saved list to cast it directly. This does not add an innate-ability action before the plan.

### Make a list

1. Choose a list at the top right, or click **+** to make one.
2. In **Buffs**, find a spell and click the portraits of the people who need it. Click again to remove it. **Clear** removes that row's choices.
3. Use the search box or a character tab to narrow the list. Click **Name** or **Duration** to sort the browser. This does not change casting order.
4. Open **Order** to choose the cast order or a preferred caster.
5. Open **Summary** to check which buffs each person will get.
6. Click **Cast**.

**Uses** shows free uses / total uses. For example, **0/1** means one use is available and already reserved by your plan. Hover over the count for a breakdown. A warning appears only when a planned cast has no usable source. Portraits stay visible when uses run out, so you can move a buff from one person to another. Self-only spells stay self-only. A duration range means the available casters can give different durations; each portrait shows its assigned or next-cast duration.

If a planned spell is unavailable, BuffBot skips it and casts the rest. The game message log shows how many planned casts were skipped. Missing entries stay in your saved list so they can work again after you rest or restore their source.

BuffBot skips buffs it recognizes as already active. Some effects and modded spells are harder to detect. Use **Add spell / item** if a power is missing, or **Hide** to tidy the browser. Hidden entries already in a plan stay planned.

### Choose an order

- **Smart Order**: long buffs first, with casting time and invisibility taken into account. It updates when you add, remove or change buffs.
- **Long First**: sort by duration, longest first. It also updates as you edit.
- **Custom**: restore your saved manual order. Use the up/down buttons to move a cast; moving one selects Custom.
- **Undo**: undo the last order-mode change when available.

The active mode is highlighted and saved with the list. Automatic ordering treats prepared spells and daily charges as replenished, so spending a spell does not shuffle the list. **Casting still checks your real remaining uses.** Existing lists start in Custom to preserve their order; new lists start in Smart Order.

### Set up wake-up buffs

Fresh installs start with two empty lists: **Pre-Battle Buffs** and **Wake Up Buffs**. **After Rest** starts on Wake Up Buffs. Add spells to that list to use it; an empty list quietly does nothing.

The After Rest picker can use any list, or **Off**. It is separate from the list you are editing. Existing saves keep their lists and rest choice.

After a completed standard eight-hour rest, BuffBot waits until the party can act. Combat cancels a pending run. Unavailable casts are skipped and counted in the message log; the rest of the list still runs. Shortened rests and other mods' rest systems need more testing.

### Casting speed and interruptions

In **Settings → Casting**, choose **Fast-forward 2x (Recommended)**, **4x**, or **Normal**. 4x is experimental and may not be faster on every setup. BuffBot restores the old speed when casting ends or stops.

Time really passes faster during the plan. Existing buffs, fatigue and delayed effects follow that time too. Redux's party planner no longer uses Balanced Quick Cast or rewrites buff expiry times.

Independent casters can act together. A shared item or a spell that must come before invisibility may need to wait. Combat and lost player control can stop casting. Moving someone yourself may interrupt their current spell; their chain does not reliably resume. Let the plan finish before giving new orders when possible.

### Items, summons and saved plans

BuffBot scans supported powers on identified carried items, including backpack gear. Darkfire Bow's Improved Haste and Gargoyle Boots are supported. Item borrowing checks whether the borrower can use the gear, shares its charges, and tries to return it safely. Unsafe swaps, ambiguous copies and interactive item choices may need manual use.

Summons must already exist to supply spells to a party plan. A missing saved summon makes its casts unavailable until a matching summon returns. Project Image also prevents its owner from casting while the image is active. Summon equipment borrowing is not supported.

Use the gear menu to **export/import** a party plan as a `.bbp` file in `override/bfbot_plans`. Exports keep targets, caster choices, variants and order mode. They do not grant missing spells or items; those casts stay unavailable.

## Known Limitations

- **Single-player first.** Multiplayer behavior has not received the same testing.
- **5E Spellcasting:** converted casters are excluded from the new party planner. The retained **Settings → Caster editor** has the original experimental support; see the [5E guide](docs/5e-spellcasting.md).
- **Extra legacy controls:** repeats, row locks and some summon workflows remain in the Caster editor. Its per-character lists and exports are separate from party plans.
- **Missing powers:** automatic discovery does not cover every modded effect. Container contents are not scanned. Scrolls, wands and unusual powers may need manual inclusion/use; automatic coverage is not promised.
- **Item safety:** chest armor, restricted gear, duplicate copies and some child-spell powers can need manual handling. See the [compatibility report](docs/compatibility-test-report.md) for tested exceptions.
- **Estimates:** displayed durations do not capture every kit bonus or conditional effect. A cast appearing in the log does not prove its effect landed.
- **Platform/UI:** file pickers use Windows directory listing. Other platforms and all resolutions/fonts have not been checked.

For more detail, see the [feature guide](docs/plan-management-and-casting-beta.md), [comparison with original BuffBot](docs/buffbot-original-vs-redux.md), and [visual review](docs/visual-review/review.md). Source-only review material is also available in the separate review download.

## Testing & Bug Reports

Please [open an issue on this fork](https://github.com/zach-hopkins/bg-eeex-buffbot/issues) with your game/EEex versions, mod list, steps to repeat the problem, and a screenshot or log if useful.

In the game console, `BfBot.Test.RunAll()` runs the built-in checks. Logs include `buffbot_test.log`, `buffbot_exec.log` and `buffbot_fast_forward_audit.jsonl`. For legacy 5E problems, run `BfBot.FiveE.Diagnose()` and include `buffbot_5e.log` and `WeiDU.log`.

## Contributing

Language pull requests are welcome. Translate a complete catalog from `buffbot/lang/english/setup.tra`; preserve IDs, placeholders and installer tokens. Use a safe lowercase folder name, set `@113` to it, and add its `LANGUAGE` stanza in `buffbot/setup-buffbot.tp2`. Keep UTF-8 and the existing one-line tilde format. Include your preferred translator credit.

Run `python -m pytest tests/test_localization.py tests/test_release_package.py -q` before submitting a language change.

<details>
<summary>Development-only deployment</summary>

From a source checkout with EEex LuaJIT already active, run `bash tools/deploy.sh /path/to/game`. Players should use WeiDU instead.

The raw development deploy preserves an existing `override/bfbot_l10n.tra` together with `override/bfbot_strrefs.txt`: it preserves both files byte-for-byte and skips TLK patching. If the catalog lacks its reference file, it stops before copying runtime files; reinstall BuffBot with WeiDU to repair the pair.

With no selected catalog, the English fallback patches only `lang/en_US/dialog.tlk`, leaving other language TLKs untouched. It requires Python 3 and an existing `lang/en_US/dialog.tlk`; if prerequisites fail, it refuses the fallback before copying files. The retained references belong to old installer compatibility, not active preset shortcuts. An obsolete `bfbot_l10n.txt` alone is preserved but does not select localized deployment.

</details>

## AI-Assisted Development

Original BuffBot was developed with Claude Code; Redux was developed with OpenAI Codex. Human choices and AI assistance shaped the code and tests. The source and test evidence are open for review.

## Credits

- **[Chrizhermann](https://github.com/Chrizhermann)** — original BuffBot, the base for this fork.
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
