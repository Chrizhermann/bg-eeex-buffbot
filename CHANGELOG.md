# Changelog

## v1.12.4 (2026-10-29) — the right names, and room to breathe

Two findings from one live playthrough, both about the panel rather than what
it casts: every colour scheme was named after the wrong game, and the footer
huddled in the middle of a panel it had room to spread across. No save schema
change, no shipped asset byte changes, and nothing about casting moves.

### Fixed
- **Every colour scheme carried the wrong game's name** (#102). Reported from
  a live playthrough: the scheme called Siege of Dragonspear gave the panel
  blue-teal leather, and the one called Baldur's Gate gave it red. All three
  names were on the wrong art, and had been since the first theme release.

  The three parchments are the games' own book covers, which is how the
  mapping is settled: BG1 is brown tooled leather with brass hinges, BG2 is
  blue-teal leather in a gold frame, SoD is black and red. So BG1 takes the
  warm parchment the panel has always worn by default, BG2 the blue-teal set
  (`BFBOTBG2`/`BFBOTFR2`), SoD the red one (`BFBOTBG3`/`BFBOTFR3`), each with
  the matching chrome skin — warm stone, cold steel, red marble.

  No shipped asset byte changes and a saved `[BuffBot]Theme` keeps working;
  it now renders the game it names. The default still opens on the warm
  parchment every install has shown since v1.0 — that art is BG1's, so the
  default moved with it rather than turning every existing panel blue-teal.

  **What a player sees:** the look stays, the name under it changes. If you
  never touched the Color Scheme radio, your panel is the same parchment it
  always was, but the radio now reads Baldur's Gate where it read Baldur's
  Gate II. Nothing moved; the label you never picked did. If you *had* picked
  a scheme, it keeps your choice and finally shows that game's colours.

  The old names had been copied into six places, so each accent's text
  colours, parchment pages and chrome skin are now pinned together and a
  comment at the mapping says where the names come from. They do **not** come
  from the engine's UI art: the in-game side panel `GUIWLSP` runs the other
  way round (BG:EE's is blue slate, BG2:EE's is tan), and deriving the mapping
  from engine resources is what got it wrong twice.

### Changed
- **The footer uses the panel instead of huddling in the middle of it.**
  Reported from a live playthrough: *"jetzt aktuell ist alles so crammed in
  der Mitte und ich finde das nicht mehr so übersichtlich"* — the buttons
  should sit further apart, grouped so that what belongs together looks like
  it does. The footer bar was capped at 980px and centred, so on a 2048px
  panel four sparse rows sat in a 980px island under a spell table using the
  full width, and inside each row the groups were a flat 28px apart however
  wide the panel grew — too little to read as groups at all. The bar now
  takes the table's width, and the room a row does not need is shared out:
  each seam between two groups takes a full share, each of the two outer
  margins half a share, so the groups separate as the panel grows and
  nothing ends up flush against the parchment. A share is capped at 22% of
  the bar, because an uncapped one opens a canyon between the only two
  groups of a short row; past the cap the leftover returns to the margins
  and the run stays centred. At the 550px minimum nothing changes: there is
  no room to share, and the seam falls back to its old 28px.

### Lab
- **The footer was judged on real shots, not a schematic**
  (`tools/lab_screenshots.py`, hidden lab on BG2:EE 2.7.3.0 + EEex v1.3.1,
  2560×1440, panel 2048×1152, save "BuffBot Clean Baseline"). Each footer
  row was captured under this change and under v1.12.3 for the same panel, so
  the comparison is one variable wide, and the maintainer signed the result
  off from those shots.
  The three colour schemes were captured the same way, each with its chrome,
  which is how the swapped names were confirmed to be only names: the art in
  every shot is byte-identical to v1.12.3's.
- Measured seams on that panel, read off the layout rather than the image:
  on 2048px the add and cast rows separate their two groups by 446px where
  they had 28, and the edit row its three by 416px each. At the 550px minimum
  every one of them is 28px again, and the controls inside a group stay 6px
  apart at every size.
- The full automated suite passes **1618 tests**, one of them new for this
  release and written because the lab caught what the offline suite could not:
  the in-game Theming phase pins one palette's title colour by its literal
  value, and the rename moved that colour to another palette. The phase failed
  headless while all 1617 offline tests were green, so an offline test now
  reads `BfBotTst.lua` and holds the two together, whatever the names are next
  time. With the phase corrected the in-game suite is green headless in the
  same lab: all 28 phases pass, 0 failures.
- Not checked in game: switching the colour scheme while the panel is already
  open — every shot was taken on a panel built under its own theme, and a
  repaint in place is a separate case — and the footer at the 550px minimum,
  where the fallback to the old 28px seam is the layout's own arithmetic
  rather than something measured on screen.

## v1.12.3 (2026-10-29) — a friendly mage is not a summon

One detection defect, reported from a live BG2 game: the Summons view handed
the player a quest NPC's spellbook. The filter knew whether a creature was
alive, outside the party, friendly and able to cast — but never whether
anybody in the party had conjured it.

### Fixed
- **BuffBot offered a friendly NPC's spellbook as if he were a summon.**
  Reported from a live BG2 game in the Underdark: standing next to Vithal, the
  quest mage of the elemental-portal errand, the Summons view listed him as a
  caster and cast his spells — Time Stop among them — for a party that cannot
  command him anywhere else in the game. The detection filter asked four
  questions (alive, not in the party, allied EA 2–30, at least one castable
  spell) and never the one that separates a summon from an ally: did anybody
  in the party conjure this creature? Vithal answers all four the same way a
  Planetar does. So does a charmed or dominated enemy, whose EA CHARMED(6) and
  CONTROLLED(5) sit inside the same band. The sweep now requires an engine
  linkage as well: a clone's `m_nCopyParent` / `m_bInCopy`, or the engine's own
  SUMMONED_BY object (`m_lSummonedBy.m_Instance`), with EEex's marshalled
  summoner UUID as the save/load fallback — and the owner chain has to reach a
  party member, so a Simulacrum's Planetar still counts while an elemental
  Vithal summoned for himself does not. Where the link cannot be resolved at
  all (summoner dead, or an engine build that does not expose the fields) the
  creature is kept: the filter never hides the player's own summons to make a
  point. A sprite that was conjured moments ago has not had its linkage set
  yet, so the mid-run late-join path retries such a verdict within its budget
  instead of dropping the summon.

### Lab
- **The linkage was measured, not assumed** (`tools/lab_summon_origin.py`,
  headless lab on 2.7.3.0 + EEex 1.3.1, save "BuffBot Clean Baseline"). The
  probe casts a summoning spell it discovers in the game's own resources and
  then spawns the SAME creature file with `CreateCreatureObject`, so the only
  difference left between the two is the summoning itself. `wizeye.CRE` from
  SPWI425: summoned → `m_lSummonedBy.m_Instance` = the caster's object id,
  EEex's UDAux summoner UUID set, owner chain resolves to a portrait slot,
  accepted as a caster. The same file created → `m_Instance` **-1** (not 0,
  which is what the first draft expected), no UUID, rejected. Both sit at EA 4
  with portrait index -1, which is precisely why the EA band could not tell
  them apart. Party members read -1 as well, so a PC is never mistaken for
  something conjured. Not separately exercised: an item charge or an HLA as
  the summoning source (all opcode 67, the same engine path), and surviving a
  save/load, where the UUID is the fallback.
- The full automated suite passes **1595 tests**, 16 of them new for this
  filter, and the in-game suite is green headless in the same lab: all 28
  phases pass, including two new cases that read the linkage off a live party
  leader — the one thing a stubbed test cannot show.
- Not checked in game: an item charge or an HLA as the summoning source, and a
  save/load with a summon standing in the area.

## v1.12.2 (2026-10-29) — the way out of the Summons view

One layout defect, reported from a live game as a panel in which switching
between Summons and Party worked once and then not again, character tabs that
did not react, and row labels that did not stay the same while buttons were
pressed. All of it follows from a single control in the wrong place, and none
of it depends on the EEex version.

### Fixed
- **The view toggle sat under the summon row's own controls, so the panel
  could not leave the Summons view.** The character row is shared by both
  views: the summon tabs, the paging cluster and the full-width
  "No allied summons detected" label are all placed inside `rowW`, which is
  the row's width *minus* the toggle's own slot. v1.11.0 pinned the toggle to
  that slot at the right edge and nothing could reach it. v1.12.0 moved it
  left, snug against the last character name, straight in among the controls
  the other view enables. On a 1075×621 panel the label then covered 81 of the
  toggle's 100 px with a party of five and all 100 px with a party of one to
  four, with the paging buttons on top as well — a six-character party was the
  only one that pushed the toggle back to the right, which is why a full-party
  lab never saw it. Every other symptom follows: the character tabs are gated
  on the party view and about twenty handlers return early in the Summons
  view, so a panel that cannot switch back looks dead throughout, and two
  enabled text items in one rectangle is also why the row's caption changed
  under the mouse. The toggle keeps its reserved slot again.
- **Tab areas went stale when the party or the preset list changed size.**
  Tab widths are sized for the tabs that exist and a slot past the count is
  parked on the last real tab, but `_Layout` ran only on open, drag and
  resize. A companion who joined while the panel was open got a tab still
  parked on the previous last one — two live tabs stacked, the lower one
  unclickable. The refresh now notices a changed count and lays the rows out
  again.

### Testing
- The full automated suite passes **1579 tests**. New: the view toggle is
  checked against every item of both views' tabs at five panel sizes and ten
  party/preset counts, the summon tabs against their paging cluster, and a
  party or preset list that changes size after the layout must come back with
  tab areas that do not stack. 37 of the 50 toggle cases fail against v1.12.1.
- In game, BG2:EE 2.7.3.0 with EEex v1.3.1: the in-game suite passes all 28
  phases, and the new `tools/lab/lab_rowprobe.lua` measures the row in the
  running engine and round-trips the switches that live in it. It reports
  `coversToggle=none` with this release and `coversToggle=bbS1,bbSEmpty` with
  v1.12.1's module reloaded into the same session, so the check can fail.
- Not checked in game: a click on the toggle itself. The probe calls
  `ToggleView` directly, which proves the function and the geometry but not
  the engine's hit testing; and the six dialogs, whose controls have fixed
  areas.

Everything else is as in v1.12.1.

## v1.12.1 (2026-10-27) — the panel's controls, where they belong

Three layout defects, all found after v1.12.0 went out and all reported from
a live game as controls sitting in the wrong place, overlapping, and not
reacting to a click. None of them depends on the EEex version.

### Fixed
- **Captions stayed their own size while their plates shrank.** A footer row
  that does not fit narrows every plate in it by one factor, but the captions
  are separate items drawn at the font's own size and centred, so they kept
  their width. At the 550px minimum "Down" printed across "Up" and "Sort",
  "Order: Manual" and "Quick Cast: Suspended" ran past their plates, and
  "Delete Preset" was cut off by the panel edge — and a click landed on
  whatever plate was really under the text, which is the neighbour or nothing.
  Each caption now takes the share of its size that its plate kept, down to a
  floor of six points. The scale lives in the per-render listener, because
  that listener rewrites every item's point size immediately before it is
  drawn: a scaled point written anywhere else survives exactly one frame.
- **Reserved tab slots left the panel.** The character and preset rows size
  themselves to the tabs that exist but place all six and all eight slots,
  since an unfilled slot is only disabled, not removed. Sized for two and
  placed for eight, the spare slots marched off the parchment — on a
  1075×621 panel with five presets, slots 7 and 8 sat at x 1148..1491 while
  the panel ended at 1175: outside it, under the frame, over whatever stands
  beside the panel. v1.11.0 divided the row by the fixed six slots and never
  did this; v1.12.0 divided by the visible count without carrying that into
  the placing. A slot past the count is now parked on the last real tab.
- **The quick-preset menu left its captions behind.** It opens wherever the
  mouse is and moved its eight rows, but not the labels that carry their
  text, so those kept the area the `.menu` gives them while the buttons
  travelled. Both go through the same pairing the main panel uses now.

### Testing
- The full automated suite passes **1520 tests**. New: `tests/test_panel_geometry.py`
  runs the real `_Layout` at five panel sizes and four party/preset counts and
  checks that no control leaves the panel, that nothing in a row overlaps, that
  the footer rows do not grow into each other, that every caption is moved by
  whatever moves its control, and that the scale a row reports is exactly what
  its plate lost. Ten of its checks fail against v1.12.0. Seven more drive the
  caption scale through the real render path — register the listeners, draw the
  item, read the point — over scaling, restoring full size when the panel grows
  again, the six-point floor, the text-size preference, and a factor that makes
  no sense.
- **Lab check, BG2:EE 2.7.3.0 with EEex v1.3.1** (quiet dev lab): the panel
  shot at 1075×621 and at the 550×350 minimum, before and after. The three
  footer rows and both tab rows sit inside the panel at both sizes, and every
  caption is inside its own plate. `tools/lab_screenshots.py` grew a
  `--font-size` flag for it, and the shot receipt now reports each caption's
  scale beside its plate width.
- Not checked in game: the six dialogs, whose controls have fixed areas in the
  `.menu` and are not covered by the footer's scaling, and the tab rows with
  six long character names on a narrow panel.

## v1.12.0 (2026-10-27) — Icewind Dale, Pecca's chrome and the shared plan model

### Added
- **Icewind Dale: Enhanced Edition support.** Both installer components accept IWD:EE (`GAME_IS ~bgee bg2ee eet iwdee~`), and the installer's wrong-game message names it in all nine languages. Nothing in the scan, classifier or casting paths needed IWD-specific code; what did differ is listed under Fixed. See the README's [Icewind Dale section](README.md#icewind-dale-enhanced-edition) for what was tested.
- **A preset can order its own casts, if you ask it to.** Each party preset now carries a cast-order toggle beside Up / Down / Sort: *Order: Manual*, the default and what every preset has done until now, or *Order: Duration*, which casts the longest-lasting buffs first so a sixty-turn Stoneskin is not spent waiting behind a five-round Blur. Locked rows keep their place, equal durations keep the order you gave them, and the toggle follows the preset index across the whole party — the same contract Quick Cast has, because "Pre-Battle" has to mean one thing in one party. It is a view, not a sort: nothing writes your priorities back, so switching it off hands your own order straight back, and Up, Down and Sort grey out while it is on rather than editing an order the preset is not using. The spell list shows the order the cast will actually run in, and both party queue builders rank through the same `BfBot.Persist.OrderByDuration`, so what the list shows and what the party casts can never drift apart. Presets saved before this exist keep working untouched — off is stored as absence, so there is no migration. The Summons view is unaffected.
- **The shared plan model** — the allocation layer both panel views will sit on, ported from Zach Hopkins' BuffBot Redux with thanks (#81, step 2). A *request* says what a recipient should receive; it names no sprite, no object ID and no reserved spell use, so every preview and every run plans a fresh snapshot of the live party. The caster view reads those requests grouped by who casts them, the recipient view (step 3) by who receives them — one plan, two projections, so an edit in either place is the same edit. **Nothing in the panel changes yet**: this release only adds the layer and its tests.
- **The allocator picks the better caster.** When two party members know the same buff, the longer duration wins, then the higher caster level, then a stable key so the same plan comes out the same way twice. A variant's own duration counts, not the opcode-214 wrapper's (#82). If serving one recipient greedily would leave another request with no caster at all, the earlier recipient is moved to its second choice instead of the later request failing.
- **Resource pools are honest about spontaneous casters.** A sorcerer with four level-3 spells and two level-3 slots has two casts, not eight: every spell of one level shares a pool, and a pool's capacity is the smallest count its sources report, never their sum. Shamans share on the priest side. Prepared casters and innates spend the specific memorized resource, each inventory copy of an item carries its own charges, and every live summon copy keeps its own uses even though the saved preference is shared.
- **Radial party delivery is recognized.** Chant, Protection from Evil 10' and the other prayers whose ability says "caster" while their projectile covers a 10-foot area are now read from `PROJECTL.IDS` and the PRO header, so one cast is planned instead of one per party member. The targeting flags the per-caster view uses are deliberately unchanged; only the plan model reads the new `radialParty` flag. An unreadable projectile fails closed to an ordinary self-cast.
- **Migration from the per-character presets**, which keeps the caster lock, the variant, the repeat count, the target unlock and the player's own priority. A repeat of three reserves three uses while the panel still shows one row. The old presets are read, never consumed, so a half-finished schema move loses nothing. A configured spell the character no longer knows, or a recipient who left the party, refuses the migration by name rather than quietly producing a shorter plan.
- Scan rows now carry `casterLevel`, which the plan model needs to prefer the stronger caster.
- **Re-cast buffs that are nearly over instead of skipping them.** A long buff that survives a rest with a tiny remainder was treated as "already active" and never renewed. BuffBot now reads how much of a running buff is actually left and casts it again when that is below a threshold. (#84)
- **"Refresh buffs that are nearly over"** in EEex options: off by default, or under 1 minute, 5 minutes, or 1 hour left. The threshold applies to every path that starts a run. `baldur.ini` takes any value in seconds under `[BuffBot] RefreshBelow`; the list offers the common ones.
- **An active-buff toggle in the panel**, beside the status line: *Active: Skip* (default), *Active: Refresh Low*, *Active: Force All*. It belongs to the run, not to a preset: nothing is written to the save, and a game restart returns to Skip.
- **Force All is an unconditional override.** It is independent of the threshold — it works with the option off, ignores whatever value is configured, and also re-casts buffs that never expire, which no time threshold can reach. Wasted spell slots are accepted deliberately: a vanilla Stoneskin runs twelve hours, long buffs routinely survive a rest, and re-casting one or two unnecessarily beats guessing wrong. There is no confirmation prompt and no heuristic that softens it. Every other precondition stays in force: a dead caster or target, a spent slot, a missing variant, an interactive item and a live Project Image still refuse the cast.
- Skip and refresh decisions now name the remaining lifetime in `buffbot_exec.log`, so "why was this skipped" is answerable from the log.
- The toggle also applies to the 2x/4x fast-forward runs added in v1.11.0: simulation speed changes how long a run takes, never which buffs it skips.
- The policy lives in `BfBot.Exec`, not in the panel, so `BfBot.Exec.SetForceMode(2)` works from the console without opening BuffBot — and the panel rebuild in #81 only has to re-place one button.
- **Every route that starts a run carries the selection.** Buffing after a rest is the case this was reported for, and the panel keeps showing *Active: Force All* while it is set, so a run started with the panel shut means what the panel says. The Cast buttons and the actionbar gear's preset menu all go through one entry point; only a raw console queue runs on the `RefreshBelow` option alone.
- `buffbot_exec.log` now uses the same `1h 6m` / `5m 0s` scale as the panel's Dur column. It used to print flat minutes, so a log line reading `threshold 60m 0s` sat next to an option labelled *Under 1 hour left* and looked like a different number.

### Deliberately not ported
- **The fork's automatic reordering heuristics.** Its smart/long order engine reorders casts by measured retained duration, on its own. The standing decision here is that the player's order is respected unless they say otherwise, so what shipped instead is the opt-in toggle above: off for every preset, longest-duration-first when switched on, and never written back over the player's own order.
- **A second save subtree.** The fork keeps `BuffBotParty` beside `BuffBot`; two stores mean two truths for one buff, and the player has to learn which screen owns which setting. The requests will live in the existing subtree at schema v11 (the next step).
- **Player-facing prose inside the planner.** Rejections come back as the plain identifiers in `BfBot.Plan.REASON`, so the wording is written and reviewed where the player reads it rather than buried in the allocator.

### Changed
- **Captions moved off the buttons.** `STONESML`, the engine's button typeface, has no lower case, and `ITEM_BUTTON` ignores a button's own point size — so every caption in BuffBot read `ADD SPELL/ITEM` at a fixed size, whatever the font-size preference said. Each of the 78 captions now lives in a paired `<name>_t` label in the NORMAL face, which `_Layout` keeps on the button's own area. The two status toggles that have to stay text items (only a text item takes an `action` together with `text color lua`) gained a `<name>_b` plate drawn underneath, so they wear the same chrome as the rest instead of a pale `rectangle 5` chip. The Reset button in the title bar got the same treatment.
- **The footer is one toolbar, centred.** Its four rows used to pin their groups to the panel's two edges, which looked deliberate at the 550px minimum and fell apart as the panel grew: three buttons at the far left, two at the far right, and a hand's width of empty parchment between them. Each row is now a single centred run of groups. The widths are the captions' natural sizes, which add up to more than the minimum can hold, so a row that does not fit shrinks every width in it by the same factor — crowded captions at the minimum are accepted, controls growing into each other are not. The active-buff toggle is centred with them instead of hanging alone at the right.
- **Footer buttons grey out instead of disappearing.** Remove, Repeat, Enable, Target, Up, Down, Sort, Delete Preset and Stop were hidden whenever they could not be used, which left holes in the bar and moved their neighbours around as the selection changed. They now stay in place and grey out through `clickable lua`, with the caption dimming alongside the plate. `enabled` is left to decide only whether a control belongs on screen at all — the wrong view, or the variant row standing in for the normal one.
- **The target picker shows the party greyed while targeting is locked.** Locked is the default for every entry, so the dialog opened holding a header and two buttons in 400 pixels of parchment. Self, All Party and the six member rows are now shown unavailable, which is also what "Unlock Targeting" then refers to. Their checkboxes are the same art the spell list uses, with the greyed tick for the locked state, and the member rows lost their pale chips.
- **The panel's buttons, tabs and scrollbars now use Pecca's art instead of the engine's carved stone** (#81, the half of step 1 that was missing). The art shipped in the previous release but nothing drew it: all 80 buttons still named `GUIOSTUL` and every list still scrolled with `GUISCRC`. Eighty buttons now ask a helper which plate to draw — the wide plate for a captioned button, the tab plate for the character, summon and preset tabs, the broader plate behind Cast and Cast Character — and all four lists scroll with the themed bar. Each piece has one cycle per skin, so the chrome follows the theme the way the parchment and checkboxes already did.
- A tab's "this one is open" frame comes from the art in use: Pecca's tab marks it with the skin's accent outline, the game's own button (stone `GUIOSTUL`, or IWD:EE's `GUIBUTMT`) with its pressed frame. Nothing hard-codes either number. Plain buttons no longer force a frame at all, so the engine keeps running their hover and press states.
- The chrome art is checked for separately from the row art (checkboxes, lock glyph). A partial install degrades per group instead of all at once, and a missing piece turns the whole chrome set off rather than mixing Pecca's tabs with stone buttons — half a theme reads as a broken install. Without the art, or on an engine with no resource lookup at all, every button falls back to the game's own button art: the stone `GUIOSTUL`, or `GUIBUTMT` on IWD:EE.
- Draw the panel frame with Pecca's thin rail and corner wedges instead of the generated leather border. The frame is the same 9-slice: corner at its native size, a slice of the rail stretched along each edge, so it still fits any panel size and resolution. It now draws on top of the parchment rather than behind it, because a thin frame with a transparent middle no longer needs to hide under it, and that keeps the whole corner visible. All eight panels follow, including the quick-preset menu. The corner pieces are two per skin — `BFBCORN` frame 0 is the top corner, frame 1 the bottom one — and the rails are cropped to the four-pixel line inside their ten-pixel strips, so the line meets the corner's own edge instead of running six pixels below it and leaving the corner open.
- **Repeat counts now repeat buffs under Force All.** Every repeat attempt goes through the active-buff check, so before this a `Repeat: 2` buff cast once and skipped the rest. With Force All the active check is off and the configured count is used in full. Each attempt still consumes a spell slot or charge. Skip and Refresh Low are unaffected.
- No save-schema version change. Existing presets, including repeat counts and summon presets, remain compatible, and the cast-order toggle above is stored as absence while it is off.

### Removed
- **F12 preset innates.** BuffBot no longer gives each party member a special ability per preset. They caused too many problems. On 2.7.3.0 with EEex v1.3.1 they were not granted after loading a save, because the party loads before its members take their portrait slots (verified on BG2:EE save loads and on IWD:EE new games and loads). The generated spells required a character level equal to the preset number, so preset 2 silently did nothing for a level-1 character (verified on IWD:EE). Clones copied them without routing the preset to the clone, they used a placeholder icon, and their names were the only strings BuffBot wrote into the game's TLK. To buff without the panel, right-click the actionbar gear and choose a preset.
  - Saves from earlier versions still carry the abilities. About two seconds after loading, BuffBot removes them from every party member, once per member and game, applying one opcode 172 effect per copy directly instead of queueing an action, so the removal also works while paused and during a run. A companion who joins later is handled the same way, and a member who leaves and rejoins is checked again. Until then, clicking a leftover ability does nothing. Failures are written to the log. The game's own record statistics can still name an old F12 ability among a character's favourite spells; BuffBot leaves them alone.
  - The installer no longer appends the eight innate names to the TLK and no longer copies `BFBOTIB.BAM` or `bfbot_strrefs.txt`. Strings an earlier version appended stay in the TLK, unused, because WeiDU does not remove appended strings on uninstall. `BFBT{slot}{preset}.SPL` and `BFBTRM.SPL` files an earlier version wrote into `override` are left in place and never cast.
  - `tools/patch_tlk.py` is gone: the development deploy needs no Python and never touches a TLK.
  - Catalog entries `@200`–`@207` (the innate names) and `@503`–`@506` (F12 feedback) are removed in all nine languages, and the LuaJIT warning `@500` no longer mentions F12.

### Fixed
- **Panel buttons on IWD:EE.** IWD:EE ships a `GUIOSTUL.BAM`, but its frames are unrelated texture fragments, so every plain panel button drew one. Where the panel falls back to the game's own buttons because the chrome art is missing, it now uses the running game's button BAM (`GUIBUTMT` on IWD:EE, unchanged `GUIOSTUL` elsewhere), chosen at runtime by `BfBot.Theme.ButtonBam()`. With the art, every game draws Pecca's plates.
- **Text size on IWD:EE.** Live rescaling mapped fixed BG2:EE font names to base sizes, so IWD:EE's `POSTANTI` and `SHERWOOD` text never rescaled. The map is now derived from the fonts the running game's styles actually use. A font that two BuffBot styles share at different sizes stays at its load-time size, with a warning in the log.
- **In-game test suite on IWD:EE.** `RefreshThreshold` probed with portrait-icon effects on the party leader, which fails on a leader whose own effects prevent that icon (IWD:EE's Enrage does); it now uses the first party member that can hold the probe and warns if none can. Prayer is found by its `SPELL.IDS` symbol (IWD:EE: `SPPR316`, where `SPPR327` is Storm Shell), the variant-spell check falls back to Spell Immunity when `SPWI422` has no variant table, and the item-ability check also accepts IWD:EE's Staff of the Hanged Man. On BG2:EE the tests resolve to the same spells as before, except that a clean install now runs the variant check on Spell Immunity instead of skipping it.
- **The panel's border was see-through along every edge.** The frame rect was inflated 14 pixels past the parchment on all four sides, a leftover from the generated leather border, which filled its rect opaquely and drew behind. Pecca's frame is the opposite: a thin rail lying flush with the atlas edge over a transparent middle. Inflated, the rail left the panel and what showed in the fifteen pixels between the parchment edge and the rail was whatever stood behind the panel — the action bar, the sidebar, the floor. The frame now draws on the panel's own rect, so the rail sits on the panel edge and the corner bosses on its corners, which is what the 9-slice is built for. All eight panels, the quick-preset menu included; a test pins each frame to its background.
- The resize hint no longer draws under the corner boss. `///` marked the bottom-right corner back when that corner was bare parchment; with the frame on its own rect the boss lands on exactly that 20×20 spot, and the two drew over each other. The hint is kept for an install without the frame art. The drag target is its own 80×48 handle and is unchanged either way.
- **The panel's bottom corners faced the wrong way, and two themes wore the wrong frame.** `BFBCORN` holds the two *diagonal* corners — frame 0 the top-left, frame 1 the bottom-right — not a corner and a state. Building the bottom pair from frame 1 unmirrored put the bottom-right ornament at the bottom-left and the other way round, so both swept outward instead of running along the rail. The accent-to-skin mapping was swapped the same way the control art's was, which put BG:EE's wine-red wedge on SoD's slate panel and SoD's gold triangle on BG:EE's red one. Three pure-yellow pixels in the middle of the BG2 bottom boss — a marker left in the source art, present in none of the other seven corner frames — are painted out of the atlas; the BAM itself is untouched.
- `tools/build_frame_atlas.py` builds the three frame atlases from the rail and corner BAMs. They were assembled by hand before, which is how the mapping above could be wrong with nothing to check it against; the builder documents what it reads off the art, and a test rebuilds the atlases and compares each shipped corner against all four candidates.
- **SoD and BG:EE wore each other's chrome.** The skin index into the control art was assumed, not read: skin 0 is BG:EE's red marble with gold filigree and a round socket, 1 is IWD's plain wood, 2 is SoD's cold steel with a square socket, 3 is BG2's dark stone. BuffBot mapped SoD to 0 and BG:EE to 2, so the SoD theme drew red marble buttons on slate and the BG:EE theme drew steel on red. The plate cycles and the `BFBCHK<skin>` files share that order, so the checkboxes were swapped with them.
- **Three list columns were unreadable on every dark panel.** Duration, Uses and Target carried no color of their own, so they fell back to the `normal_parchment` style's dark ink — which is right on BG2's parchment and invisible on the stone backgrounds the other four themes use. They and eight other labels now take the active theme's text color. The item tint on the two stone *light* themes was mixed for parchment as well, and printed rust on rust.
- **The lock glyph was all but invisible.** `BFBGLYPH` is light line art meant for the dark plates; on parchment it was a cream outline on cream. A locked row now draws it inside the checkbox column's own empty socket, which is the right size and the same visual language.
- The spell list is a whole number of rows at every panel height. It took whatever height was left over, and drew the last row clipped — a spell name sliced by the parchment edge. The leftover pixels go above the footer, where they are air.
- Theme colors never reached the screen. `text color lua` hands the engine one packed number, which it unpacks as alpha<<24 | blue<<16 | green<<8 | red — blue and red the other way round from the usual 0xAARRGGBB, as EEex's own `EEex_Options_Private_UnpackColor` shows. BuffBot returned the palette's `"{R, G, B}"` string instead, at 35 places in the menu and through every Lua color callback, so each label fell back to its style's default and all six palettes rendered the same near-black text — unreadable on the two light themes whose background is dark. `BfBot.UI._T` now returns the packed number and caches it per shade; `BfBot.UI._TRaw` still gives the authored string for callers that want the components.
- Dark mode darkens again. The eight veils drew with `rectangle 5`, and `rectangle N` picks a style rather than a color: style 5 tints warm, so switching to dark laid a warm film over the parchment and swallowed its texture instead of dimming it. They now use style 1, the same one the full-screen click-to-close dimmer has always used. The two light themes that carry a 60 veil of their own are dimmed neutrally by the same change.
- Variant spells (opcode 214 "spell menu" spells such as Protection from Elemental Energy) no longer refuse every target but Self. Their targeting was read from the selection wrapper the engine casts on the caster, while BuffBot actually casts the chosen variant directly — so the target picker locked the row to "(Self-only)" even when the variant targets a single creature. The picker, and the AoE decision during execution, now follow the selected variant. (#82)
- The Summons view can unlock targeting. A spell the classifier reports as self-only or party-wide disables every control in the target picker, and the Unlock button existed only in the party view, so such a row was a permanent dead end — which hit every variant spell. Summon spell entries now carry the same optional `tgtUnlock` field as party entries, and a clone seeded from its owner inherits the owner's unlock along with the copied targets.
- Closing the target picker with "Done" while the row is still locked no longer replaces the stored target with the classifier's default. Nothing in a locked picker can express a target, so there is no intent to save.
- **`BfBot.Test.RunAll()` no longer changes the player's own BuffBot setup.** The in-game suite drives the real persistence API on the loaded party, and a run that passed every phase replaced the leader's presets with defaults, imported a test export over the second party member, deleted the leader's own export in `override/bfbot_presets`, reset the saved panel position and size, dropped the font size to medium and left `BB_TestKey`, `MpControlMode` and `RefreshBelow` in `baldur.ini`. Every phase that writes player state now works on deep copies of each party member's config and item-swap journal and of the classifier overrides, and the player's own tables go back afterwards, also when a check fails or a phase raises. The `[BuffBot]` keys in `baldur.ini`, the font size and the panel geometry return to their exact earlier values, removing a key the player never had; the export test keeps the bytes of both files it writes and restores or removes them. The leftover F12 innate phase removes its own test grant from the leader also when one of its cases raises. A value that cannot be restored fails the run with a message naming it. The guard covers `RunAll()` as a whole and each writing phase when run on its own.

### Known limitations
- A genuine area buff cast by a summon covers whatever stands near the *summon*, not the party, because the engine centers it on the caster. The picker still labels that case "(Party-wide)". Unlock the row and pick party members individually when the summon is not standing with the party.
- The in-game suite's `baldur.ini` restore is exact only where the engine has `Infinity_GetINIString` and `Infinity_RemoveINIEntry`, as BG2:EE and IWD:EE 2.7.3.0 do (both probed in a lab). Without `Infinity_GetINIString` it can only compare the numbers it reads back: string preferences cannot be read there at all, and a key the player never had comes back holding its default. Without `Infinity_RemoveINIEntry` a key a test created stays, and the run reports it as a restore failure.
- When `override/bfbot_presets` did not exist before, the export test leaves the empty folder behind. BuffBot creates it on the first export anyway.
- **Under 1 hour is a wide net, not a small top-up.** Durations are the ones the panel's Dur column shows, so a vanilla Stoneskin at 1h is already below that threshold the moment it is cast, and every run will cast it again. The option description and the README say so.
- The threshold is a *time* threshold. Stoneskin's real resource is its skins (opcode 218), so "timer still running, no skins left" is not covered; a charge-aware check needs its own work.
- A buff whose remaining lifetime cannot be read — a permanent effect, or one still inside its delay — keeps the old behaviour and is skipped. Only Force All reaches it; no threshold value can.
- `config.opts.skip` in the save schema is still unused. This release carries the threshold in `baldur.ini` instead of reviving that field; removing it needs a migration decision and is tracked in #84.

### Testing
- **The in-game suite is green on `main` with everything merged**: 28 phases, 0 failures, through `tools/lab_ingame_tests.py` (quiet lab `BuffBot-Dev`, BG2:EE 2.7.3.0 with EEex v1.3.1, guards clean). Its first run on the merged tree was not — see the plan-model note below — which is what the gate is for.
- The Plan Model phase asked for a full house. It builds one request per buff group from a source that exists and has a use left, then required all of them to be allocated. On a real party they are not all servable: the pools are finite and shared, and a self-only source cannot stand in for another caster's, so a group whose first source is spent by an earlier request finds no substitute. On the dev lab's party that is Spell Immunity, 16 of 17. The phase now checks what is actually invariant — every request gets a decision, and every refusal names a reason from `BfBot.Plan.REASON`, which is where step 3's catalog keys come from — instead of a count the allocator never promised.
- **IWD:EE support and the F12 removal:** the full automated suite passes **1224 tests**. New here: installing both components on IWD:EE, the LuaJIT helper on IWD:EE's EEex layout, rejecting a game outside the supported set, the engine button BAM per `engine_mode` and the menu's lack of a hardcoded `GUIOSTUL` (since the merge below: neither the menu nor the chrome helpers name an engine button BAM), font maps derived from BG2:EE and IWD:EE styles (including shared and differently cased fonts), the in-game refresh probe moving off a party leader who blocks it, and the removal of leftover F12 innates (one permanent opcode 172 per copy, once per member and game, again after leaving and rejoining, recorded before a failed removal, one warning when the innates cannot be read or a copy stays, no LuaJIT I/O needed, the click stub). The installer tests now assert that BuffBot changes no TLK on install, upgrade, language switch or uninstall. Gone with the feature: the F12 routes of the quick-access matrix, the innate grant and recharge tests, and the TLK patcher's deploy checks.
- **Lab check, IWD:EE 2.7.3.0 with EEex v1.3.1** and Bubb's Spell Menu Extended v5.2, two quiet labs, run before the F12 innates were removed. Lab A: BuffBot's helper activated LuaJIT. Lab B: EEex's own LuaJIT component did, and the helper detected it and changed nothing. Both: `RunAll` passed all 27 phases. Lab A: panel with IWD button art, a run skipped an already active Armor, configuration restored by a main-menu load and by an in-game reload over a changed in-memory state, and removing **In-Game Buff Automation** left LuaJIT in place. Lab B: Cast All clicked in the panel cast Bless, a stock save and in-game reload restored the saved configuration byte for byte over a changed one, and the refresh-threshold phase passed 34/34 with the leader blocking the probe icon.
- **Lab check, BG2:EE 2.7.3.0 with EEex v1.3.1** (clone of the dev lab, before the removal): the panel kept the stock `GUIOSTUL` buttons, the theming checks mapped `NORMAL`/`STONESML`/`REALMS` to 12/14/18 as before, and `RunAll` passed all 27 phases.
- **Lab check of the F12 removal, IWD:EE 2.7.3.0 with EEex v1.3.1** (Lab B). The previous build was upgraded the way a player does it: this branch's release archive extracted over it, then both components reinstalled through WeiDU. WeiDU succeeded, `BFBOTIB.BAM` and `bfbot_strrefs.txt` were gone, the new catalog was in place, and the English TLK stayed byte-identical, its eight old innate names included. The save that carried two innates per member: all six members lost them as the load finished, with one log line each, and neither the known nor the memorized list kept a copy. Saved and reloaded in game: nothing left and nothing removed again. The same old save loaded again in the same session, where the members keep their object ids: its innates were removed again, because the game-destroyed listener had cleared the record. `RunAll` passed all 27 phases (`LegacyInnateCleanup` 16/16), and preset 1, started through the functions behind the actionbar gear's preset menu, ran to *Done*. That save's record statistics still name two old innates as favourite spells.
- **Lab check of the F12 removal, BG2:EE 2.7.3.0 with EEex v1.3.1** (Lab C, raw deploy). A save written by the previous build with two innates per member (twelve entries in the known and memorized lists) lost all of them right after loading with this build, and the game saved afterwards holds no `BFBT` reference at all. `RunAll` passed all 27 phases (`LegacyInnateCleanup` 13/13), and preset 1, started the same way, had both casters cast Armor and Shield. The second caster cast only because the `RunAll()` run just before had imported a test export over that member's config, which #95 fixed; in the save itself only the leader's preset holds those spells, and after the merge below only the leader casts them. The TLKs stayed unchanged.
- **After merging `main` into the IWD:EE branch** (the chrome art, the cast-order toggle, the `RunAll()` restore and the plan model) the full automated suite passes **1463 tests**. New or adapted with the merge: each chrome helper falls back to the running game's own button per `engine_mode` (`GUIBUTMT` on IWD:EE, `GUIOSTUL` elsewhere) and none names an engine BAM itself; the leftover F12 innate phase leaves the player's state as it was, removes its own test grant from the leader also when one of its cases raises, removes only leftovers the safety tick has not reached yet, and leaves a leftover it cannot probe with untouched; and the IWD:EE refresh-probe tests run against a stub that now has what the restore needs.
- **Lab check after the merge, IWD:EE 2.7.3.0 with EEex v1.3.1** (Lab B). The merged build's release archive was extracted over the previous one and both components reinstalled through WeiDU: the English TLK stayed byte-identical, and all 213 mod files in `override` match the build. The panel draws Pecca's plates and tabs; with the chrome art switched off it draws IWD:EE's own `GUIBUTMT` and marks the open tabs with its pressed frame, with no texture fragments. `RunAll()` passed all 28 phases (Plan Model 14/14, `LegacyInnateCleanup` 16/16, `RefreshThreshold` 34/34). With the lab fixture of `tools/lab/lab_state.lua` applied (extra presets, locks, repeats, an export), all 64 compared fields of player state were identical before and 20 seconds after `RunAll()`; IWD:EE's `baldur.ini` calls behave as BG2:EE's. After an in-game reload, preset 1 from the actionbar gear's menu functions ran exactly as before the merge: Protection From Evil cast, the second attempt skipped for want of a slot, *Done*.
- **Lab check after the merge, BG2:EE 2.7.3.0 with EEex v1.3.1** (Lab C, raw deploy). The save carrying two leftover F12 innates per member lost all of them on load, one log line per member. The panel draws Pecca's plates, and the stone `GUIOSTUL` with the art switched off. Preset 1 cast Armor and Shield and skipped Spell Immunity, which has no variant configured. With the fixture applied, all 46 compared fields were identical before and 20 seconds after `RunAll()`. 27 of 28 phases passed; Plan Model failed one check (#98, under Known limitations). Both labs ran through the quiet runner: guards clean, no audio, slot released.
- Not checked in game: BG:EE, EET, a BG new game, a BG companion joining from dialogue, IWD:EE UI mods (LeUI-IWDEE, Infinity UI++), SCS for IWD:EE, IWD NPC mods, Heart of Winter and Trials of the Luremaster areas, multiplayer, and removing **EEex LuaJIT Support** on IWD:EE.
- **The in-game suite now runs headless**, through `tools/lab_ingame_tests.py`: it takes a lab slot, starts the game hidden and muted, loads a save, sends `BfBot.Test.RunAll()` and copies `buffbot_test.log` out. It was the one gate that had to be typed into the console by hand, which is why it was the one that got skipped — and it had gone red without anyone noticing. **All 27 phases pass on `main`** (149 checks in Theming alone, 0 fail; the 9 warnings are all resources this clean install does not carry, such as Contingency and Prayer).
- The Theming phase was asserting against whichever palette happened to be active, with `bg2_light`'s own title colour hard-coded, so it failed on any other theme. It now sets the palette it is asserting about and puts the player's back. Its required-key list was hand-kept and had gone stale in both directions — still demanding `reset` long after that key was dropped, and never learning the ones the chrome work added. The key set is read off the default palette instead, and each palette is also checked for keys the default lacks.
- The full automated suite passes **1389 tests**. New since the chrome landed: that each footer button carries its state gate as `clickable` and not as `enabled`, and that its caption greys with it; that no footer row overlaps or leaves the panel at five panel widths from the 550px minimum to 1600; that the list is a whole number of rows at five panel heights; that the skin index matches the art's own order and every mapped skin ships its checkbox file; and that the target picker hides nothing for being locked while all four of its entry points and its row color refuse to act while it is. For the frame: each shipped corner is matched against all four candidates — the two source frames and their mirrors — and has to be the right one by a wide margin, because DXT5 costs up to 50 on a single pixel where gold meets slate inside one block.
- **Seen in a running game** (quiet lab `BuffBot-Dev`, BG2:EE 2.7.3.0 with EEex v1.3.1, 1920x1080): the panel was captured at 550x350, 560x380, 860x600, 900x620, 1090x730 and 1340x750, in all six themes, and with the target picker and the spell picker open. Captions fit their plates from 860 up and crowd without overlapping at the minimum; the footer holds together at every width; the search field, the lock glyph and the greyed controls read in all six themes. Lab guards clean, no audio, nothing left in the job.
- The chrome's own 19 tests: that no button names the engine art directly, that every one picks its plate through a helper and selects the skin's cycle, that the tabs use the tab plate and mark the open one through the frame helper, that no other button forces a frame, that all four lists scroll with the themed bar and that the installer and release builder both require it, plus each helper's fallback, the cached presence check, a partial install, an engine without a resource lookup, and a throwing lookup that must not cache an answer.
- The full automated suite passes **1381 tests**, 66 of them new for the plan model: the allocator's augmenting path, every rejection cause, pool keys for prepared, spontaneous, item and summon casters, repeat expansion and its ceiling, the catalog policy, radial detection and its caching and fail-closed path, the queue shape the executor already accepts, a refused partial plan, and migration of per-character presets including priority order, named targets, area and radial targets, and the two refusal cases.
- `BfBot.Test.PlanModel()` is a new in-game phase inside `BfBot.Test.RunAll()`. It plans the real party read-only and checks what no offline test can: that the snapshot sees the live party, that no pool claims more uses than the scan reports, that every allocated request is servable and no pool is overspent, and that the live preset migrates without losing an entry. It first ran in game with the IWD:EE merge below: 14/14 on IWD:EE, and one failed check on BG2:EE for a party with Spell Immunity memorized, a bug in the phase's own requests (#98).
- The full automated suite also passed **1315 tests** after merging v1.12.0, 15 of them new for #82, including the variant target shape read from the sub-spell, the parent verdict kept when a variant SPL cannot be read, the Summons-view unlock-and-save path, the locked-Done no-write guard, summon-schema validation of `tgtUnlock`, clone seeding, and `all` expansion for a party-wide variant.
- Offline evidence from the reference install: 247 of its 249 opcode-214 abilities have ability target type 5 or 7 (caster), while the variants they select are single-creature or party-wide spells. `SPWI422` → `DVWI426` → `SPWI319`/`SPWI320`/`SPWI512`/`SPWI517`, all single-creature.
- **Lab check, BG2:EE 2.7.3.0 with EEex v1.3.1** (quiet lab `BuffBot-Summons`, guards clean, 335 s run, on v1.10.1 plus this branch — before the v1.12.0 merge below): a real allied Djinni summoned in game offered exactly one buff row, Ghost Armor, which the classifier reports as self-only — the dead end as reported. The picker opened locked "(Self-only)", Unlock then cleared the lock and wrote `tgtUnlock = 1` into the **summon** preset, the chosen party member was stored as `{Zorl}` and survived a view refresh, and the resulting queue read `Ghost Armor -> Player3 (Zorl)` from caster ref `summon/139462735`. For the variant half, read from real resources through the mod's own code: a real opcode-214 parent (`SPWI510` Spell Immunity, ability target type 7) reports self-only and stays locked, all eight of its variants are genuinely self-only and stay locked, while the real variant sub-spells of the reported spell (`SPWI319`/`SPWI320`/`SPWI512`/`SPWI517`) report target type 1 and unlock the row, after which confirming the picker stored the picked party members and resolved them into per-member queue entries.
- Not verified in game: the reported spell's own menu form (`SPWI422` as an opcode-214 parent does not exist in a clean install — only in a modded one), and an actual cast landing on the target. **The merged state has not been checked in game**: the lab run predates the v1.12.0 merge, the lab still holds the pre-merge build, and it was deliberately not re-run — the behaviour under test is covered by the automated suite, and the reported spell's menu form does not exist in a clean lab, so a repeat run could not have shown anything new.
- With the `RunAll()` fix the full automated suite passes **1394 tests**. The 79 new ones in `tests/test_runall_restores_player_state.py` run the real phases under LuaJIT against a party with two configured members, one of them in the middle of an item swap, a member without a config, classifier overrides, its own `baldur.ini` values and two export files, and compare all of it before and after: the same tables, the same content, the same bytes, and nothing queued on a sprite except the Quick Cast remover. They cover every phase that writes player state, with variants for a preference or an export the player never had and for a raise injected after the first write, the whole `RunAll()` over the shipped phases, and the guard's own failure paths. With `main`'s `BfBotTst.lua` at least one of them fails for each of these phases. Structural checks pin that each writing phase runs guarded, that the phases left unguarded reach no writer, and that every `[BuffBot]` key BuffBot writes is one the guard keeps.
- **Lab check of the `RunAll()` fix, BG2:EE 2.7.3.0 with EEex v1.3.1** (disposable clone `BuffBot-RunAllRestore-20261026` with its own profile; quiet runner, guards clean, no audio): a save with three configured party members — renamed and added presets, Quick Cast, an active preset, locks, repeats, a target table with unlock, an include override, a moved and resized panel, font size 3 and the leader's own export. On `main`, a `RunAll()` that passed all 27 phases replaced the leader's and the second member's configs, deleted the leader's `Zyntris.lua`, set `PanelX`–`PanelH` to -1, created `BB_TestKey`, `MpControlMode` and `RefreshBelow`, and dropped the font size to 2. With the fix all 27 phases pass and all 47 compared fields — each member's serialized config and its table identity, item-swap journal and BuffBot innates, every `[BuffBot]` key including the absent ones, the export's bytes, the overrides and their table, font size, palette and panel geometry — are identical before and 20 seconds after `RunAll()`. After saving and reloading, the 43 fields that outlive a reload are identical again, and so are the export file and the `[BuffBot]` keys the engine wrote back to `Baldur.lua`. Run twice, the second time through the new `tools/lab_runall_check.py`.
- Not checked in game for the `RunAll()` fix: BG:EE and EET, a save with an unfinished item swap (offline only), and the `baldur.ini` fallback for an engine without `Infinity_GetINIString`.
- The failed-UDAux-read contract (#42): a read that raises hands back nothing, creates no defaults and warns once with the character's name; a character with no config yet still gets defaults, silently. Three checks beside the marshal-scrub coverage that closed #59.
- The threshold work brought the suite to **1300 tests** at the time, with 116 new checks covering the per-timing-mode duration reader, the longest-readable-deadline fold, threshold resolution and validation, Force All as a flag that outranks every threshold and reaches permanent effects, the preconditions Force must *not* weaken, `_CheckEntry` for spells, state markers and multi-ability items, the plumbing through both the normal and the accelerated start path, and the panel toggle.
- A new in-game phase `BfBot.Test.RefreshThreshold()` applies one tagged effect per timing mode to the party leader, reads each one back, exercises the threshold, the force flag and the skip decision, and removes the probes again. It runs inside `BfBot.Test.RunAll()` and passes 34/34.
- **Lab check, BG2:EE 2.7.3.0 with EEex v1.3.1** (disposable clone, own save profile): the in-game phase passed 28/28. End to end on Protection From Normal Weapons, with 1m 42s left: with the option off the log read `SKIP ... (already active: SPWI511, 1m 42s left)`, and with the threshold at one hour `INFO ... (refreshing: SPWI511, 1m 36s left, threshold 1h)` followed by the cast. Force All cast a fully active Shield again. Live vanilla Armor was measured too, and it is why the fold prefers readable deadlines: its `op174` sits in timing mode 7 forever beside three mode-4096 effects with the real 45-minute deadline.
- **Engine measurements** behind the reader, recorded in the knowledge base: on an applied effect, encoded timing modes 0, 10 and 4096 all become mode 4096 with an absolute deadline in game ticks; 1 and 9 stay permanent; 3 becomes 6 and 4 becomes 7 while the delay runs, where the stored value is the end of the *delay*, not of the buff. A live `m_durationType` must not be masked with `0xFF` — that would turn 4096 into 0.
- **Re-checked after merging v1.11.0**, same lab: the full `BfBot.Test.RunAll()` passes all 27 phases, the refresh phase 34/34. Force All was confirmed to survive the accelerated start path live — with the rate at 2x, `Exec.Start` received force mode 2 — so simulation speed does not change what a run skips.
- **Force All verified live as an override, with the option off** (`RefreshBelow=0`) on a permanent effect, the case no threshold can reach:

  ```
  # Active: Skip          SKIP: Zyntris -> Summon Djinni (already active: SPWI718, permanent)
  # Active: Refresh Low   SKIP: Zyntris -> Summon Djinni (already active: SPWI718, permanent)
  # Active: Force All     INFO: Zyntris -> Summon Djinni (refreshing: SPWI718, permanent, force all)
  ```

  The lab's `[BuffBot]` settings and the force selection were restored afterwards.
- The in-game phase now wraps everything that writes `baldur.ini` or applies a live effect in a `pcall`, and removes the probe effects and restores `RefreshBelow` unconditionally. Verified in the lab by injecting a failure mid-phase: `RefreshBelow` came back as the player's own 45, no probe effect was left on the protagonist, and the phase reported a failure instead of a pass. F12 was driven through its real opcode-402 handler with the selection at 0, 1 and 2 and carried each one into `Exec.Start`, and into `Fast.Start` at 2x. It runs inside `RunAll()`, so an error in the middle could previously have left a permanent portrait-icon effect on the protagonist and `RefreshBelow` at a clamped maximum — "re-cast everything, always" with no visible cause. A failure inside the guarded part now fails the phase instead of being counted as a pass.
- Also fixed while here: the Target Picker phase required a second party member to exist but not to have a *different* display name. On a save with two members called the same thing, a name-based target legitimately resolves both to the first slot, and the phase failed on correct behaviour. It now picks a member with a distinct name and warns when there is none. Unrelated to this feature; the underlying ambiguity — two party members sharing a display name cannot both be targeted by name — is filed as #87.
- Not checked in game: the EEex options entry and the panel toggle clicked by hand, BG:EE, EET, the Force All interaction with Quick Cast, summon casters, and item powers with a measured remaining duration. Two log-only corrections — the threshold's wording and suppressing the SPLSTATE false-positive notice on a refresh — have automated coverage but were not re-run in the lab.

## v1.11.0 (2026-10-24) — selective BuffBot Redux improvements

Adapted from [Zach Hopkins' BuffBot Redux](https://github.com/zach-hopkins/bg-eeex-buffbot), with thanks and credit. Character-based presets, manual cast priorities and the classic BG presentation remain the primary workflow.

- Match active-effect resource names without case sensitivity, preserving the source/opcode/state checks that distinguish shared SPLSTATE markers.
- Add a named preset picker on right-clicking the HUD gear and keep its position within the screen. Existing F12 abilities remain available.
- Add buff-name search without changing stored priorities or which enabled buffs a preset casts.
- Discover item buff powers delivered through bounded immediate child spells and retain supported classifier misses for manual Add. Powers requiring an interactive spell picker remain manual-only; scrolls and wands remain outside discovery.
- Use the applicable caster level when estimating child-spell durations, including fixed levels supplied by opcode 146.
- Add optional 2x/4x temporary simulation speed. Normal remains the default. Accelerated runs retain the existing spell/item execution paths and suspend Quick Cast for that run, including late-joining summons. Saved Quick Cast settings and rendering/FPS preferences are preserved.
- Restore temporary speed on completion, stop, combat, unsafe UI state, load/exit and timeout. Multiplayer acceleration is unavailable.
- Ignore delayed or duplicate execution callbacks from an earlier run after Stop/restart, including across module reloads.
- Preserve healthy long and paused runs; stalled execution uses the existing game-time progress watchdog.
- Refuse accelerated F12 starts if the speed module is unavailable, and roll back partial speed writes when startup fails.

- Fix configured spell variants bypassing casting time and aura: use the normal no-decrement cast action and consume only the parent's availability bit, preserving other memorization flags.
- Fix wearable items being rejected for characters without a kit. Explicit no-kit restrictions and other eligibility checks remain enforced.
- Restore temporarily equipped items through the inverse exchange, avoiding a native BG2:EE 2.7.3.0 first-backpack-slot overwrite that could corrupt the character name and crash the game. Empty equipment slots and interrupted restores are covered.
- Keep detected stances excluded from automatic buffs even when they expose a variant picker, and refresh the panel's completion status while it remains open.

- Draw the enable and lock cells with real artwork instead of `[X]` and `[L]`, in the style of the active theme (BG2, SoD or BG1). The artwork comes from Zach Hopkins' BuffBot Redux and derives from Pecca's Infinity UI++, used with permission — see [ATTRIBUTION](ATTRIBUTION.md), whose terms it keeps. Infinity UI++ is not required and none of its files are touched. An install without `buffbot/visual` still shows the text markers.
- Label the spell list's columns. The headers are captions only: the row order is the cast order, so sorting stays the explicit Sort button and stored priorities are never rewritten behind your back. Translated in all nine catalogs.

Tooling: the EEex globals scanner now collects only name-shaped string constants, so a byte-range Lua pattern such as the search field's `[\194-\223][\128-\191]` no longer breaks the scan. `EEex_CChitin` is recorded as an EEex.dll binding type that the generator cannot list; EEex v1.3.1 writes `EEex_CChitin.TIMER_UPDATES_PER_SECOND` itself in `EEex_UncapFPS.lua`, and BuffBot's access is guarded and fails closed.

Validation: **1166 automated tests pass**, including installer/release checks. Hidden native BG2:EE 2.7.3.0 / EEex 1.3.1 labs verified Normal/2x/4x with two simultaneous casters, spell/item consumption, buff expiry, variants, temporary equipment swaps, interruptions, late-joining allies and rate restoration. The subsequent EET/SR/SCS/modpack matrix also passed with experimental Scroll component 430 uninstalled and the published alpha.13 banking fix installed; Normal/2x/4x took 20.866/10.429/5.279 s with the same resource consumption. Nine fresh full-stack screenshots cover search, status, speed and HUD presets at 1024×768 and 1920×1080. The 430-inclusive configuration remains unaccepted; BG:EE and 5E are outside this task's scope. Not checked in game: the column headers and the control artwork, both added after those labs. The artwork is drawn only when all five control BAMs resolve and the text markers return otherwise, and the checkbox frames were re-authored at the list's 36-pixel row scale, which only a running game confirms. See [the validation record](docs/validation-fork-qol.md) for measurements and limits.

## v1.10.1 (2026-10-20)

### Fixed
- The party leader now shows the "Combat detected - casting stopped" and "casting timed out" notices over their head. BuffBot called `EEex_Sprite_DisplayStringHead`, which no EEex release defines, and a `pcall` hid the error, so both notices were always lost; stopping itself worked. The notices now use the engine's overhead text message with the translated text. If that message cannot be queued, the notice goes to the message log and a one-time error names the cause. (#76)
- The `BfBot.Probe` area probe tries `EEex_Area_GetVisible` and `EngineGlobals.g_pBaldurChitin` instead of three globals that never existed.

### Testing
- A new check fails when BuffBot's Lua or menu code uses an `EEex_*` global that EEex v1.3.1 does not define. `tools/eeex_globals.py` generates the list of defined names from the EEex v1.3.1 source. Every EEex global BuffBot now uses also exists in EEex v1.2.0 and v0.11.0-alpha.
- The full automated suite passes **673 tests**.
- **Lab check, EET 2.7.3.0 with EEex v1.3.1:** with the fixed core loaded at runtime, `BfBot._DisplayOverhead` made the engine attach a floating text object over the party leader with the exact combat-stop notice, in English and in German with UTF-8 characters. `EEex_Sprite_DisplayStringHead` is nil there. Not checked in game: a real combat stop during a buff run, the drawn text on screen, EEex v1.2.0, BG:EE and BG2:EE outside EET, and the in-game `BfBot.Test` suite.

## v1.10.0 (2026-10-06)

### Added
- Discover each F8 Use Item buff power on identified carried items, including secondary weapon abilities and backpack equipment. Each power has its own configuration and available-use count; existing spell and item presets remain supported.
- **Inventory item use** in EEex options: use powers from inventory by default, or equip, use, and restore wearable gear. Potions are consumed directly in either mode, with normal engine charge and consumption rules.
- Save unfinished equipment swaps for recovery after interruption or loading. Recovery checks the expected equipment before restoring it, preserving intervening manual changes.

### Limitations
- Automatic swaps exclude chest armor, unusable or conditionally usable gear, and ambiguous copies sharing an item resource. Equip the desired item manually in these cases. Scrolls, wands, and container contents remain deferred.

### Testing
- The full automated suite passes **652 tests**, including per-ability scanning, charge selection, the EEex setting, equipment eligibility, interrupted exchanges, save/load recovery, and existing installer/release-package checks. Built-in item tests now check all ability indices, carried sources, and precise queue identities.
- Offline inspection of BG2:EE 2.6.6.0 confirmed the native equipment-swap behavior and ability charge-counter selection.
- No deployment or live-game validation has been performed for this change. BG:EE/BG2:EE acceptance, including interrupted swaps and save/load recovery, remains pending; the maintainer explicitly deferred playtesting until after release.

## v1.9.0 (2026-09-27)

### Stable release
- BuffBot graduates from alpha with the existing v1.9.0-alpha functionality. This release updates version numbers and documentation; it makes no gameplay or save-format changes.
- Existing presets remain compatible. Install the update through WeiDU using the normal two-component update procedure in the README.
- 5E Spellcasting compatibility remains explicitly experimental, with the same documented limitations and playtest coverage.

### Testing
- The full automated suite passes **535 tests**, including installer and release-package checks.
- No new in-game testing was performed for this version-and-documentation release. Existing playtest evidence and compatibility limits are unchanged.

## v1.9.0-alpha (2026-09-21)

### Added
- **Experimental 5E Spellcasting compatibility.** With subtledoctor's [5E Spellcasting](https://github.com/UnearthedArcana/5E_spellcasting) installed, converted casters use normal spell names and presets while 5E handles preparation and shared spell slots. BuffBot casts through 5E's own abilities, hides their duplicate internal entries, and waits for the spell-list refresh between casts. Basic BG2:EE casting has been user-tested; wider compatibility remains experimental. (#27)
- **`BfBot.FiveE.Diagnose()`** — console command that writes a 5E report (mapping table, per-character states, wrappers, and row availability) to `buffbot_5e.log` for bug reports.
- **5E documentation and tester guide** — the README describes the current state, expected delay, and limitations; the release archive includes [a short playtest checklist](docs/5e-spellcasting.md).

### Compatibility
- Converted casters skip spells that open a variant selection popup (for example Protection from Elemental Energy); cast those manually. Unavailable spells are left out when building a preset's cast list. If a queued spell becomes unavailable, its skip message explains whether it is unprepared or has no casts left at its level.
- When the prepared spell and the spell actually cast differ, BuffBot uses the delivered spell's targeting and classification while preserving the visible spell's name and manual include/exclude choice. Delayed 5E refresh callbacks from a stopped run cannot resume a later run.
- A preset entry that pointed at a `d5z<N>i` wrapper innate (only reachable through the Add picker's non-buff section before this change) stops casting — enable the real spell instead.
- No save-schema change; all 5E data is derived at scan time.

### Fixed
- **Avoid repeated spell-list work during 5E casts.** Notifications from 5E removing and restoring casting abilities now schedule one panel refresh instead of rebuilding the open panel for every change. Generated 5E casting abilities also bypass normal buff analysis, which previously followed their large internal helper spells.

### Testing
- The full automated suite passes **535 tests**, including 46 new regressions covering the mapping table, wrapper validation, shared pools, unprepared and exhausted rows, the strip/regrant window, mixed-family indices, delivered-spell targeting and Project Image identity, manual overrides, stop/restart callbacks, the wrapper cast path, helper-scan avoidance, and batched panel refreshes.
- **User playtest:** BG2:EE 2.6.6 with EEex 1.2.0/LuaJIT and 5E Spellcasting 2.7.2. After the performance correction, the user reported that a short arcane buff preset with Quick Cast worked well, with a small pause between casts. Logs show completed runs and active-buff skips. 5E's scheduled one-second refresh still applies; BuffBot's readiness checks can add a little extra time.
- Exact shared-slot consumption/exhaustion, rest and preparation changes, divine and multiclass/dual-class casters, mod-added spells, clones, BG:EE, EET, and the in-game `BfBot.Test.RunAll()` suite were not fully playtested for this release. Automated coverage does not replace those checks.

## v1.8.4-alpha (2026-09-10)

### Fixed
- **Unidentified items stay hidden in BuffBot.** Inventory scans now check each item's identification flag before reading its name or abilities. Unidentified potions and equipment cannot appear in preset lists or the Add picker, including through saved settings or classification overrides. Mixed stacks count only identified copies; items become visible after identification and the next panel refresh.

### Testing
- The full automated suite passes **489 tests**, including 32 new regressions covering inventory regions, combined item flags, mixed stacks, unavailable identification flags, saved settings, and visibility after identification or replacement by unidentified copies.
- In-game validation is pending. BG1EE, BG2EE, and the in-game `BfBot.Test.RunAll()` suite were not run for this fix.

## v1.8.3-alpha (2026-08-31)

### Fixed
- **Unavailable or exhausted spells in preset lists remain configurable.** Rows with no current cast availability stay greyed out, but their checkboxes can now be enabled or disabled for a later rest or any other availability change. Casting still requires live availability; this changes preset editing only.

### Testing
- The full automated suite passes **457 tests**, including a regression that toggles a count-zero spell both on and off while preserving its muted presentation and unavailable state.
- **Live BG2:EE validation:** the deployed fix kept an unavailable spell greyed out while allowing both enable and disable actions; the user confirmed the behavior works.
- BG1EE, the broader compatibility matrix, and the in-game `BfBot.Test.RunAll()` suite were not rerun for this release.

## v1.8.2-alpha (2026-08-26)

### Fixed
- **Active-buff detection no longer confuses permanent administrative residue with a live spell on heavily modded installs.** For spells that declare opcode-282/328 state markers, BuffBot now confirms an active buff using the matching source resource, marker opcode, and state ID. This fixes later Free Action casts being skipped when Klatu component 2070 leaves a permanent `SPPR403` opcode-101 effect and SCS Detectable Spells shares state 67 with another protection. (#69)

### Compatibility
- The fix is resource-driven rather than specific to Free Action. Marker identity is tracked separately for wrapper parents, opcode-146 children, opcode-214 variants, and caster-level-specific abilities. Markerless spells retain the existing source-effect fallback, item behavior is unchanged, and the save schema is unchanged.

### Testing
- The full automated suite passes **456 tests**, including opcode-282/328 markers, same-source residue, shared states from other resources, wrapper and child spells, variants, caster-level-dependent abilities, markerless spells, items, and queue metadata propagation.
- **Live BG2:EE validation:** BuffBot cast Free Action normally and skipped it while its own marker remained active. After resting, Klatu's permanent opcode-101 residue remained while Free Action's marker expired. With Death Ward independently activating shared state 67, BuffBot correctly cast Free Action again (`Cast: 1 | Skipped: 0`).
- The reporter's complete BG:EE/GOG/EEex v1.0 mod stack, BG1EE, the broader compatibility matrix, a three-recipient queue, and the full in-game `BfBot.Test.RunAll()` suite were not rerun for this release.

## v1.8.1-alpha (2026-08-25)

### Added
- **BuffBot now ships nine complete language catalogs.** Italian, German, French, Spanish, Polish, Russian, and Brazilian Portuguese join English and Simplified Chinese. Italian was contributed and tested in game by Sauler89; the six other new catalogs began as AI-authored translations, with German reviewed by the German-speaking maintainer. Native-speaker corrections remain welcome. (#71, #72)
- **WeiDU and release packaging cover every shipped language.** All nine installer selections publish the matching UTF-8 runtime catalog while retaining TLK ownership only for the eight generated F12 innate names. The release archive includes every declared catalog and rejects missing, undeclared, or case-colliding language paths.

### Compatibility and scope
- This release adds catalogs, installer declarations, packaging coverage, and documentation only. It does not change runtime Lua, menu behavior, persistence, or the config schema.

### Testing
- The full automated suite passes **450 tests**. Coverage validates catalog parity, semantic keys and placeholders, all nine WeiDU language selections, same-process language switching, exact catalog/TLK ownership, and packaged-archive installs for every non-English language.
- The Italian contributor tested the translated UI and buff casting in game. The new German, French, Spanish, Polish, Russian, and Brazilian Portuguese catalogs have not been validated in game or at alternate resolutions/fonts. German received native-speaker review; the other five still await native-speaker review.

## v1.8.0-alpha (2026-08-22)

### Added
- **BuffBot is fully localizable and ships complete English and Simplified Chinese catalogs.** The selected language now covers the WeiDU installer, generated F12 innate names, every player-facing panel and runtime message, EEex Options, and default names for genuinely new presets. Existing saved, imported, inherited, and user-renamed preset names remain unchanged.
- **Runtime UI localization is file-backed.** WeiDU copies the selected UTF-8 catalog byte-for-byte to `override/bfbot_l10n.tra`; Lua reads UI, options, defaults, and player feedback directly from that file with per-key English fallback. Only the eight generated F12 SPL names remain TLK-backed through catalog entries `@200`–`@207` and `bfbot_strrefs.txt`.
- **Localization-aware release packaging and contribution guidance.** Release archives retain complete nested language catalogs, the reusable builder is covered by an extracted-archive Chinese install, and the README welcomes complete language PRs with exact ID/placeholder validation and translator credit. The Simplified Chinese catalog builds on [robovoid's PR #50](https://github.com/Chrizhermann/bg-eeex-buffbot/pull/50).

### Compatibility and safety
- **A native startup crash drove the file-backed correction.** The first BuffBot-owned UI `Infinity_FetchString` call crashed during `M_BfBot.lua` loading and again after deferral to the main-file-loaded listener; Lua `pcall` could not contain the engine access violation. Runtime localization no longer crosses that native boundary.
- **Project Image queue safety no longer depends on an English spell name or vanilla resref.** BuffBot identifies Project Image structurally from opcode 236 image type 2, including bounded opcode-146 child spells, while leaving Mislead and Simulacrum distinct.
- **Persistence/UI failure handling uses stable internal reason codes with localized display text.** Character names containing no ASCII filename characters now receive collision-safe `BuffBot-PlayerN.lua` export names instead of colliding as `Unknown.lua`.
- **Language switching preserves installer ownership and payload state.** Current helper-first installs switch the main component in one forced uninstall/install pass. Upgraded v1.7.0 main-first stacks safely switch by selecting both installed components together, as documented in the README.

### Testing
- The full automated suite passes **408 tests**. Coverage includes real WeiDU 249 English and Simplified Chinese synthetic installs across EEex v0.11 and v1, byte-exact selected catalogs, innate-only active-TLK changes, inactive/root TLK stability, current and released-v1.7 lifecycle switching, pre-existing catalog ownership restoration, the map-backed candidate migration, raw-deploy preservation, unsafe-path rejection, and installation from the packaged Chinese archive.
- **Live validation (2026-08-22):** On the Copy Copy BG2:EE + EEex installation, the corrected Simplified Chinese build loaded a game and opened BuffBot successfully. User screenshots confirmed readable CJK labels and acceptable panel layout at the tested resolution/font. Some captions appeared small: Text Size scales titles, lists, and clickable text, while classic stone-button captions remain at the engine's default size. Automated English startup and runtime restoration were also verified; there was no explicit English visual sign-off.
- Still pending: the full interaction/casting matrix, real Project Image behavior, non-ASCII import/export, save/reload and area-transition persistence, BG1EE, EET, alternate resolutions/fonts, the Project Infinity frontend, and WeiDU versions other than 249.

## v1.7.4-alpha (2026-08-21)

### Fixed
- New companions now inherit the protagonist's exact preset slots, names, and categories when BuffBot creates their first config. Their own discovered spells and items populate those presets disabled, Quick Cast starts off, sparse/deleted slots stay sparse, and returning companions with an existing personal config are never overwritten. (#41)

### Testing
- The full automated suite passes **297 tests**, including canonical protagonist selection, sparse preset indices, disabled recruit entries, empty scans, existing-config preservation, non-party exclusion, source isolation, and the loaded-listener path with EEex-style fresh sprite wrappers. Live BG2:EE + EEex acceptance in the Copy Copy installation confirmed normal dialogue recruitment, matching preset/F12 structure, disabled defaults, and save/reload stability.

## v1.7.3-alpha (2026-08-21)

### Fixed
- Portrait reordering no longer leaves stale slot-bound F12 preset innates. Reconciliation now purges old-slot entries and restores only the character's current-slot buttons; stale clicks are rejected and refreshed before they can run the preset for the old slot's new occupant. (#57)

### Testing
- The full automated suite passes **291 tests**, including stale-slot rejection, purge-before-regrant reconciliation, deferred refresh during active runs, retry after refresh failure, and unchanged matching-party/non-party paths.
- Manual BG2:EE + EEex acceptance in the Copy Copy game installation confirmed the portrait-reorder case is fixed.

## v1.7.2-alpha (2026-08-21)

### Fixed
- Active preset selections 6–8 now survive config validation and save import; invalid or missing selections reset safely to preset 1. (#52, #58)

### Installer
- **BuffBot's main component now fails before changing the TLK or override when the exact EEex LuaJIT loader state is not active.** The error directs normal and Project Infinity users to enable EEex LuaJIT or install BuffBot's helper first, preventing a successful-looking main-only install with an unusable loader state. (#36, #62)
- **The existing LuaJIT helper is declared before the main component while retaining its historical component ID 1 (main remains 0).** Selecting both in one WeiDU run activates or repairs LuaJIT before main validation; an exact runtime activated externally by EEex is accepted without a BuffBot component-ownership requirement.

### Testing
- The full automated suite passes **284 tests**, including synthetic EEex v0.11/v1 coverage for inactive main-only rollback, externally-owned active state, combined helper/main ordering, safe wrong-order recovery, the required two-component legacy update, recoverable main-only update rejection, legacy helper/main uninstall ownership, and active-preset validation/import.
- On a disposable fresh BG2:EE copy with EEex 1.2.0, released v1.6.1 main-only without LuaJIT reproduced the loader/game process exit. The current main-only install rejected the unsafe state without changing product files, helper-plus-main launched successfully, uninstall restored the loader and DLL state exactly, and the historical two-component upgrade succeeded. The reporter's complete megamod stack was not reproduced.

## v1.7.1-alpha (2026-08-20)

### Fixed
- **Preset targets now survive character display-name changes.** BuffBot still resolves exact current display names first, then falls back to the character's stable, case-insensitive death variable when the stored name is stale. This applies consistently to Cast Character, Cast All, and allied-summon queue construction. (#51)
- **An unresolved single-character target can no longer become a party-wide cast.** Stale or unknown single names now produce no queue entry, matching the existing safe behavior for unresolved names inside multi-target lists. Valid members of a partially stale target list remain in their original order.

### Diagnostics and compatibility
- When every configured target for an otherwise castable spell is unavailable, the queue builder now records a diagnostic naming the caster and spell. Existing presets and exports require no migration or schema change; protagonist targets continue to use their display name because CHARNAME normally has no usable death variable.

### Testing
- The automated suite passes **256 tests**, including exact-name precedence, case-insensitive death-variable fallback, empty and `None` handling, unknown single targets, partial multi-target lists, party and summon caster shapes, repeats, and build-skip plumbing across all three queue builders.
- Live BG2:EE 2.6.6.0 + EEex 1.2.0 validation passed on the disposable test install: Imoen was temporarily renamed to Mione while a preset retained `Imoen`; BuffBot resolved Player2, built one Armor attempt, and completed the real cast on Mione. An unknown stored target built zero attempts, and the temporary name/config changes were restored. BG1EE and the broader compatibility matrix were not re-exercised in this pass.

## v1.7.0-alpha (2026-08-20)

### Added
- **Activated equipped items and inventory potions can now be configured as buff sources alongside spells.** BuffBot scans equipped/body and weapon slots, the three curated quickitem/fill slots, and potions anywhere in the backpack. Item rows are keyed by ITM resref, tinted separately in the mixed list, and start disabled in every new preset. The engine resolves the current slot or stack at cast time through `UseItem`, so moving or stacking a configured item does not break the preset. (#21)
- **Item-aware execution and active-effect checks.** Item attempts bypass Quick Cast, independently recheck charges/stacks and active effects at R1–R5, and follow opcode-146 sub-spell references when a wrapper item applies its lasting effect through a child SPL. The same queue path is used by Cast Character, Cast All, and generated F12 preset innates.
- **Picker item section and theme support.** Removed item rows can be recovered under a separate Items subsection; item rows use the new `itemColor` key across all six themes and never show spell-variant controls.

### Persistence and compatibility
- **Config schema v10 adds `kind="spl"|"itm"` to party preset entries.** Schema-v9 saves migrate lazily by tagging missing party kinds as spells. The migration also preserves development saves written by the earlier item-v8 branch while retaining main's summon and repeat migrations. Summon presets remain kindless and spell-only.
- Imported item entries remain stored while the item is absent and reappear when reacquired; the UI hides the absent row without deleting its settings. Items remain party-only: summon discovery, clone seeding, and summon queue construction reject item rows.

### Safety and scope
- `UseItem` can select only ability 0, so BuffBot admits an item only when ability 0 itself is a classified buff with a supported target. Higher-index weapon buffs remain excluded and tracked in #53. SPL and ITM classifier caches are source-qualified so a same-resref spell can never admit an unsafe item ability.
- Scrolls, wands, container contents, and inventory search remain deferred. Scroll and wand categories are rejected even in quickitem slots; backpack non-potions are rejected even though the engine could use them by resref.

### Testing
- The automated suite passes **249 tests**, including both schema-v8 lineages, v9→v10 migration, summon/item isolation, same-resref cache collisions, item repeats, fresh-sprite execution, picker recovery, deferred categories, duplicate stacks, and absent-item persistence.
- Live BG2:EE 2.6.6.0 + EEex 1.2.0 validation passed on the disposable test install: integrated `BfBot.Test.RunAll()`, default-disabled rows, quickslot and backpack potion consumption, equipped-item charges, active-effect skipping, R2 rechecks, Quick Cast bypass, generated F12 execution, marshal/export/import round trips, party-only scanning, and combat interruption with an item still pending. BG1EE and the broader EEex compatibility matrix were not re-exercised in this pass.

## v1.6.4-alpha (2026-08-20)

### Fixed
- **Spell-row selection no longer disappears during event-driven spellbook refreshes.** BuffBot now tracks the selected spell by resource reference plus the exact caster, preset, and Party/Summons context, then restores its current row and variant state after count or list rebuilds. Selection clears safely when the spell disappears or the user changes context instead of transferring to whichever spell occupies the old numeric row. (#67)
- **Selection-dependent actions remain anchored to the intended spell across refreshes and reordering.** Target and variant dialogs retain the parent spell identity, Sort by Duration follows the selected spell, and repeat, lock, priority, target, variant, and remove actions cannot drift onto another row during a native list-widget update.

### Performance and compatibility
- **Quick-list events rebuild only the relevant visible caster while preserving per-sprite cache invalidation.** Internal `BFBT` events and unrelated sprites no longer cause unnecessary visible refreshes. Listener registration is idempotent across F5/menu reloads and dispatches through the current BuffBot namespace after a development hot reload.

### Testing
- Added an in-game `SelectionRefresh` phase and automated coverage for reordered rebuilds, disappearance and exact-caster replacement, Party/Summons context switches, target and variant anchors, duration sorting, one-frame widget clobbers, event filtering, and listener reloads. The full automated suite passes (232 tests). The #67 patch also passed the in-game suite and manual unpaused selection checks on BG2:EE 2.6.6.0 with EEex v1.2.0 before integration with the v1.6.3 changes.

## v1.6.3-alpha (2026-08-19)

### Added
- **Per-spell repeat counts from R1 through R5 are available for party and summon presets.** Click the repeat cell in a spell row to increase it, or use the selected row's **Repeat: N** button: left-click increases and right-click decreases, with wrap-around in both directions. Repeat settings remain editable while a spell has zero available uses.
- **Repeat execution is target-major and preserves spell priority.** At R2, targets A and B run as A, A, B, B. A party-wide AoE at R2 casts twice total rather than twice for every party member.

### Safety and compatibility
- **Every repeat is independently checked before casting.** BuffBot rechecks spell availability, target state, and active effects each time. An attempt that reaches the cast path consumes one available use and observes normal aura and casting time unless the preset's Quick Cast mode applies; attempts skipped for no remaining use, a dead caster or target, or an active buff consume nothing. Ordinary summoning spells can continue while uses remain, but repeats never grant free casts.
- **Project Image remains owner-lock safe.** Its retained queue entry is forced to one attempt even if configured higher, and entries after it are still dropped rather than delayed until the image expires.
- **F12 preset innates now recharge in place without a per-use ability re-grant.** An EEex quick-list listener restores only availability bit 0 on the consumed memorized entry, preserving every other flag and avoiding the `AddSpecialAbility` ability-gained feedback path. Generated `BFBT{slot}{preset}.SPL` files now contain only the opcode-402 dispatch. Initial grants and structural reconciliation remain unchanged. (#64)
- **The new recharge listener is bounded to the matching party portrait and the engine's single innate memorization container.** Copied Project Image/Simulacrum innates remain excluded, listener registration is idempotent across new and legacy module reloads, and `BFBTRM` remains responsible for missing grants and duplicate/orphan cleanup without restoring opcode 171.

### Persistence
- **Config schema v9 stores bounded repeat counts in both party and summon spell entries.** v8 saves migrate lazily across both subtrees, while missing, non-integer, non-finite, or out-of-range values reset to R1. Downgrading a save after schema v9 has written it is unsupported.

### Testing
- Added automated runtime compatibility and queue coverage for schema migration, strict normalization, target-major and AoE expansion, spell-use and active-effect rechecks, Quick Cast, variants, late summons, cancellation, and Project Image safety. Dedicated UI tests cover wrapping, party/summon write routing, menu bindings, and minimum-size geometry. Innate recharge coverage checks all 48 generated preset spells, all 48 remover effects, flag preservation, duplicate handling, listener reloads, rejection paths, and every preset-execution outcome. The full pytest suite passes (195 tests).

## v1.6.2-alpha (2026-08-19)

### Improved
- **The Add Spell picker now surfaces spells with the most currently available casts first.** Previously removed spells retain recovery precedence; within each group, spells sort by available count descending, then localized name and resource reference for deterministic ties. Known spells with zero available casts remain selectable. Preset priority and cast order are unchanged. (#63)

### Testing
- Added an in-game `SpellPickerSort` phase covering recovery precedence, descending counts, nil-as-zero handling, localized-name ordering, deterministic resource-reference ties, and exact ties. The full automated suite passes, and the picker behavior was verified live on BG2:EE 2.6.6.0 with EEex v1.2.0.

## v1.6.1-alpha (2026-07-20)

### Compatibility
- **Restored EEex v0.11.0-alpha support with full BuffBot feature parity.** EEex v1 remains recommended. The installer now detects the EEex bootstrap, required Lua API, and one complete old or new script layout instead of relying on version-specific WeiDU component IDs.
- **LuaJIT setup follows the detected EEex layout.** BuffBot recognizes the legacy `5.1` loader used by v0.11 and the `5.1-LuaJIT` loader used by v1, while validating and repairing incomplete loader state when the required files are available.
- **Save downgrade boundary.** Downgrading an arbitrary save to v0.11 after EEex v1 and other EEex mods have written it is unsupported.

### Safety
- **Marshal-safe, non-mutating persistence export.** BuffBot now exports a sanitized copy of its saved configuration, converting booleans and dropping unsupported values, keys, and cyclic branches without modifying the live UDAux table.
- **Checked EEex callback boundaries.** BuffBot-owned event callbacks now contain Lua errors, preserve successful return values, and deduplicate repeated diagnostics instead of allowing failures to propagate through EEex.

### Testing
- **Synthetic installer coverage now exercises v0.11 and v1 acceptance, with v0.10 explicitly serving as the rejection floor.** The matrix also covers incomplete and ambiguous layouts, LuaJIT activation and repair, rollback, uninstall, and component-number independence.

## v1.6.0-alpha (2026-07-19)

### Added
- **Allied summons and clones can now cast BuffBot presets.** Project Images, Simulacra, and other allied non-party spellcasters with castable spellbooks appear in a new **Summons** view. Each stable summon identity has its own per-preset spell selection, targets, priority order, and Quick Cast setting. Use **Cast (this summon)** for a standalone run; configured live summons also join **Cast All** automatically.
- **Mid-run late join.** A summon created by an active party preset can attach to that same run as soon as it finishes spawning. Verified live with Imoen casting Project Image: the image joined, cast Stoneskin and Strength from its own preset, and the run completed with 3/3 casts and no skips.
- **Clone preset seeding.** Opening a clone identity for the first time seeds its preset from the owner's same-index preset, filtered to spells the live clone can cast. Subsequent edits belong to the summon identity and persist in the protagonist's save data.

### Safety and compatibility
- **Project Image owner-lock protection.** The engine prevents a Project Image's owner from acting while the image exists; queued actions otherwise become delayed "zombie casts" after expiry. BuffBot skips already-locked owners and drops owner entries ordered after a Project Image cast without reordering the user's priorities.
- Summon detection is structural and mod-friendly: alive, allied (`EA` 2–30), not a party portrait, and possessing a castable spellbook. Object IDs are resolved fresh by ID + name before every action, allegiance is revalidated, and vanished summons complete their chains cleanly instead of waiting for the watchdog.
- Multiplayer summon support is conservative pending a two-machine probe: clones join only when their owner is locally controlled; ownerless summons use the host-control heuristic. Set `[BuffBot] SummonsJoinCast = 0` in `baldur.ini` to disable automatic summon participation.

### Persistence
- **Config schema v8** adds per-identity summon presets under the protagonist's `summons` table. Existing saves upgrade lazily on first access. Downgrading a save after it has been written by schema v8 is unsupported.

### Known limitation
- Copied BuffBot F12 innates on clones do not route reliably to the clone and are deferred to follow-up work (#60). Configure and cast summons through the Summons view or let them join Cast All.

## v1.5.0-alpha (2026-07-05)

### Added
- **Multiplayer support — BuffBot no longer hangs on "casting" and only buffs the characters you control** (reported by Jester on Discord). In multiplayer each player controls a subset of the party. BuffBot queues each cast as `SpellRES(...)` + `EEex_LuaAction("BfBot.Exec._Advance(slot)")` on the caster's action list — but `EEex_Action_QueueResponseStringOnAIBase` inserts into the **local, non-networked** copy of that list (`virtual_InsertAction`). A character controlled by another player never runs that chain, so its `_Advance` callback never fires, `_activeCasters` never reaches 0, and the status stayed stuck on "casting" forever. Two-part fix:
  - **Caster filter (`BfBot.Mp.IsLocallyControlled`)**: BuffBot now only issues casts to characters the local machine controls. A character is locally controlled iff its entry in the engine control map (`CInfGame.m_multiPlayerSettings.m_pnCharacterControlledByPlayer`, indexed by join order) equals this machine's `CNetwork.m_idLocalPlayer` — the DirectPlay player **ID**, verified in-game (the player *number* `m_nLocalPlayer` does **not** match). Single-player short-circuits on `m_bConnectionEstablished == 0`, so single-player behavior is unchanged. All engine reads are `pcall`-guarded and degrade to "controllable" on any failure. Applied at all three caster-enumeration sites (`BuildQueueFromPreset`, `BuildQueueForCharacter`, and the exec engine's `_BuildQueue` as a final guard); buff **targets** stay full-party, so you can still buff a teammate's character. Pressing "Cast <name>" on a character another player controls now shows a clear message instead of doing nothing.
  - **Control mode override** (`baldur.ini [BuffBot]`, per-machine): `MpControlMode = auto` (default, engine detection) | `manual` (`MpControlNames`, a comma-separated list of the characters you control) | `all` (disable filtering). The manual fallback covers any edge case where auto-detection misbehaves.

### Fixed
- **Watchdog: a stuck buff run can no longer lock the UI on "casting" forever.** `BfBot.Exec` now tracks forward progress in **game time** (`_lastProgressGameTime` from `m_worldTime.m_gameTime`, bumped on every queued cast and every advance); `_SafetyTick` force-completes a run that has made no progress across `_WATCHDOG_TIMEOUT_GAMETICKS` (~30s of game time) via a new `_ForceComplete`, which strips orphaned `BFBTCH` cheat buffs and resets to idle — re-resolving each sprite from its portrait slot so it never dereferences a freed `CGameSprite` (same safety discipline as the #38 stale-state recovery). Game time (not wall-clock) is deliberate: it **freezes while the game is paused**, so pausing mid-buff never trips the watchdog and kills a healthy run. This is the unconditional safety net beneath the multiplayer caster filter: even if a caster chain wedges for any reason, the UI recovers instead of stranding the player on the Stop button.

### Internal
- New module `BfBotMp.lua` (`BfBot.Mp`) hosts multiplayer control detection and `BfBot.Mp.Probe()`, a `pcall`-guarded diagnostic that dumps the engine's multiplayer ownership fields for host+client comparison. Registered in `M_BfBot`, `setup-buffbot.tp2`, and `tools/deploy.sh`.
- New in-game tests: `BfBot.Test.Watchdog()` (8 assertions) and `BfBot.Test.Mp()` (7 assertions), wired into `BfBot.Test.RunAll()`. Verified in a live BG2:EE multiplayer host session: auto-detection keeps the host's own party, and manual-mode simulation confirms the filter correctly splits a party by ownership.

## v1.4.1-alpha (2026-05-24)

### Fixed
- **Deleting a preset left an orphan F12 innate behind** (#47, reported by MrFishHead on Discord). `BfBot.Innate.Refresh`'s lightweight branch iterated only the **config's** preset list to add missing entries — it never iterated the **sprite's** known-innate list to remove BFBT entries whose preset had been deleted. After a `DeletePreset` call, `BFBT{slot}{deletedIdx}` stayed in the F12 menu indefinitely. Rather than patch the gap with another condition, the whole innate-grant subsystem was refactored: 3 helpers (`_HasInnate`, `_MaxAccumulation`, `_HasOrphans`), the heavy/light bifurcation, and the dead `Grant()` function are replaced by one pure planner `BfBot.Innate._PlanReconciliation(sprite, slot, config)` plus a thin `Refresh(slot)` orchestrator. One iterator walk diffs actual-vs-desired and either revokes-all+regrants on any mismatch (duplicate **or** orphan) or grants-missing-only on clean state. Also pulls an inline `AddSpecialAbility` loop out of `BfBotPer._CreateDefaultConfig` (was leaking innate-grant mechanics into the persistence layer) and guards against UDAux-write failure to prevent re-entry recursion. New `BfBot.Test.PlanReconciliation` suite has 9 cases including a synchronous end-to-end opcode-172 removal via `EEex_GameObject_ApplyEffect` that proves the cleanup mechanism actually removes orphans from the sprite's known-innate list (no manual integration test needed).
- **Presets 6, 7, and 8 showed "Invalid: <number>" as their F12 innate name** (#48). When `MAX_PRESETS` went from 5 to 8 in `a51804e`, the WeiDU installer was not updated — only strrefs 1-5 were registered, and the Lua side used `_baseStrref + (preset - 1)` arithmetic that assumed contiguity. `setup-buffbot.tp2` now registers all 8 strrefs and writes each as its own line in `bfbot_strrefs.txt`; Lua reads them as an array indexed by preset. WeiDU does not guarantee contiguous strrefs across upgrades (existing strings keep their old strrefs while new ones get appended), so the array approach is more robust than the old arithmetic.

## v1.4.0-alpha (2026-05-21)

### Changed
- **EEex v1.0.0+ is now required.** BuffBot's tp2 fails fast on older EEex via a new `REQUIRE_PREDICATE (FILE_EXISTS ~EEex_scripts/EEex_Sprite.lua~)` — v1.0.0 moved EEex's Lua scripts from `EEex/` to game-root `EEex_scripts/`, making that path a reliable version marker. Pre-v1.0.0 installs hit a clear error message instead of silently breaking at runtime against API changes (the old iterator pattern, `EEex_Sprite_LuaHook_OnAfterEffectListUnmarshalled` hook, etc.) Upgrade EEex from https://github.com/Bubb13/EEex/releases before installing.
- **Innate grant migrated from polling to event-driven** — `BfBot.Innate.Init` now registers `EEex_Sprite_AddLoadedListener` so innates are granted/refreshed the moment each party sprite finishes loading (new game, save load, area transition, party join). The listener fires from `EEex_Sprite_LuaHook_OnAfterEffectListUnmarshalled` — i.e. after marshal restoration, so `EEex_GetUDAux` already has the user's saved config when `Refresh` queries it. Replaces the legacy one-shot `_startupCleanupDone` polling in `BfBot.Exec._SafetyTick` (which waited up to 2 seconds after world-screen entry before granting). Self-heals old accumulation via the existing `Refresh` bifurcation; new-joiner innates now grant on the next load tick instead of after the next safety-tick window.

### Removed
- **`BfBot.Persist._SanitizeValues`** — booleans-to-0/1 sanitizer that protected pre-v1.0.0 EEex marshal handlers from crashes. EEex v1.0.0 marshal handles booleans natively, so the sanitize call sites in `_ValidateConfig` and the export/import path are gone. BuffBot's schema continues to use integer 0/1 by design (consistency, avoids Lua's `0 == false` pitfalls), and `_hasBooleans` schema-consistency checks in the test suite stay in place.

### Internal
- README: Requirements section updated to "EEex v1.0.0+, any tier" with a collapsible explainer covering how BuffBot's installer activates LuaJIT on Minimal/Full tiers. Removed the stale v1.3.9 update banner.

## v1.3.16-alpha (2026-05-17)

### Fixed
- **Character tabs and the Cast button showed raw `^0xRRGGBBAA<NAME>` text** when [Tweaks Anthology's "Colorize NPC Names and Tooltips"](https://gibberlings3.github.io/Documentation/readmes/readme-cdtweaks.html) component is installed. cdtweaks rewrites NPC name strrefs to wrap them in IE color escapes (`^0xAABBGGRR<name>^-`). The engine's main renderer parses the escape; `text lua "..."` bindings in `.menu` files do not, so the prefix leaked as literal text in BuffBot's tabs, buttons, and target picker. The protagonist was unaffected because player-typed names are not strref-based. `BfBot._GetName` now strips the escape unconditionally via a new `BfBot._StripColorEscape` helper (no-op on installs without cdtweaks). Schema migration v6 → v7 walks all `preset.spells[*].tgt` entries and strips the prefix from previously-saved target names too — existing configs self-heal on first load. 13 new test assertions in `BfBot.Test.NameStrip` cover full prefix+suffix wraps, lowercase-hex variants, mid-string, multi-word names, single tgt + table tgt + `'s'`/`'p'` sentinels.

- **Save loads spammed "ability granted" toasts; preset create/delete froze the game for ~10 seconds, sometimes crashed.** All three symptoms shared a root cause: `BfBot.Innate.Revoke` queued **50 × `ReallyForceSpellRES("BFBTRM", Myself)`** per slot regardless of need (= 300 queued BCS actions per `RefreshAll`). The 50× was scaffolding from the v1.3.9-alpha legacy-migration cleanup and had become permanent overhead. Worse, `BfBot.Innate._HasInnate` was using the wrong EEex iterator pattern (`iter:hasNext()` instead of `for ... in iter`), the error was silently swallowed by `pcall`, and the function always returned `false` — so `Grant()` re-added every BFBT innate on every save load, accumulating duplicates that the 50× revoke then had to clean up. Two fixes:
  - New `BfBot.Innate._MaxAccumulation(sprite)` counts actual BFBT duplicates via the correct for-style iterator; `Revoke` now queues only `count + 1` passes (capped at 50). On clean saves: 0 passes. Iterator pattern in `_HasInnate` and the `BfBot.Test.Innate` diagnostic corrected.
  - `BfBot.Innate.Refresh` bifurcates: when accumulation > 1, queue revoke then **unconditionally** queue re-grants (revokes will clear before grants run); when accumulation ≤ 1, skip revoke and only grant the missing ones. Prevents the race where `_HasInnate` would be checked while revokes were still pending in the BCS queue (which would suppress the grant).

### Internal
- `tools/deploy.sh` now honors `BGEE_DIR` env var over `tools/deploy.conf`, so `BGEE_DIR=… bash tools/deploy.sh` targets a test install without editing the conf file.
- `.gitattributes` pins `*.sh` to LF endings, preventing `core.autocrlf=true` on Windows from breaking `bash tools/deploy.sh` after fresh checkouts.
- `tools/bump-version.sh` documents the `gh release create … --latest` flag and warns against `--prerelease` (every BuffBot release should be eligible for the GitHub "Latest" badge).

## v1.3.15-alpha (2026-04-30)

### Fixed
- **"Cast All" greyed out when the selected character has no preset spells** — the gate fed both action buttons via `BfBot.UI._CanCast()`, which only checked the current character's spell table. On characters with nothing configured for the active preset (e.g. Safana on a buff preset), Cast All was disabled even though other party members had spells in the same preset. Cast All now uses a new `BfBot.UI._CanCastAll()` that mirrors `BuildQueueFromPreset`'s cross-party scope: it falls through to the other portrait slots when the current character is empty. Cast Character keeps the original char-scoped gate.
- **Crash when pressing Stop after reloading a save mid-cast** (#38) — reported by sov_ on Discord. After loading a save while a buff queue was running, only the Stop button was enabled; clicking it triggered an access violation. `BfBot.Exec._casters[].sprite` cached `CGameSprite` userdata from the pre-reload party, and the post-reload save freed those C++ objects — calling `EEex_Action_QueueResponseStringOnAIBase` on the stale userdata segfaulted at the engine level (and `pcall` does not catch C++ access violations). Stop and `_Complete` now re-resolve the caster sprite from the current portrait slot in their cleanup loops, so they never dereference the freed pointer; `BFBTCR` is a no-op on targets without an active `BFBTCH`, so the cleanup is safe even when the slot now holds a different character. A new `_IsStateStale` heuristic compares cached caster names against the live portrait names and proactively hard-resets execution state from `_SafetyTick` when party composition changed across the reload, so the Cast / Cast Character buttons re-enable themselves on the next safety tick instead of leaving the user stuck pressing Stop. Covered by `BfBot.Test.StaleState` (8 assertions).

## v1.3.14-alpha (2026-04-28)

### Fixed
- **tp2 VERSION mismatch in v1.3.13-alpha** — the WeiDU `setup-buffbot.tp2` shipped with `VERSION ~v1.3.12-alpha~` despite the release being v1.3.13-alpha. Cosmetic only (visible in WeiDU install output, no functional impact), reported by Born2BSalty. Re-released as v1.3.14-alpha with the version line corrected and CI guards added so it can't happen again: `release.yml` now fails packaging if the release tag, tp2 VERSION, and `BfBot.VERSION` disagree, and a new `version-check.yml` fails every PR/push if the tp2 VERSION ≠ `v` + `BfBot.VERSION`. `tools/bump-version.sh` updates both files atomically.

## v1.3.13-alpha (2026-04-27)

### Added
- **Panel themes** — six selectable color schemes (Baldur's Gate 2 / Siege of Dragonspear / Baldur's Gate 1, each in light or dark mode) configurable in-game under a new "BuffBot" tab in the EEex Options menu. Theme switches apply live without reopening the panel. The default `bg2_light` preserves the v1.3.12 look pixel-for-pixel.
- **Text size scaling** — Small / Medium / Large in the same EEex Options tab. Title, spell-row text, list cells, and clickable text elements (Quick Cast, Reset) resize live. The character-tab and action-button captions stay at engine-default size — IE's BAM-button render path ignores `text.point` regardless of font, and Bubb's mods accept the same constraint.
- **EEex Options integration** — three settings (Dark Mode, Color Scheme, Text Size) under the new BuffBot tab. Persisted in `baldur.ini` under `[BuffBot]` as `Theme` (string) and `FontSize` (number).

### Fixed
- **Border PVRZ transparency on SOD / BG1 themes** — the new border PVRZs were generated from RGB-mode source PNGs with no alpha channel, so the 9-slice frame rendered an opaque white box around the panel. The PNG → PVRZ tool now chroma-keys white-ish backgrounds with a strict 240 threshold + corner flood-fill at 200, then zeros RGB on low-alpha pixels post-resize so DXT5 doesn't bleed white into antialiased edges.

## v1.3.12-alpha (2026-04-19)

### Fixed
- **Duration shown as "Inst" or "Perm" for spells with sub-spell delivery** (#33) — hierarchical spells like Prayer and Chaos of Battle deliver their real effects through opcode 146 (Cast Spell) into a sub-spell. The classifier was only reading the parent SPL, which had no timed effects of its own, so the duration column showed `Inst`. `BfBot.Class.GetDuration` now recurses into op=146 sub-spells (depth-limited, cycle-guarded) and reports the max duration across parent and children. Prayer now shows 30s, Chaos of Battle shows 60s, and the same pattern (including SR Barkskin) works correctly for duration.

## v1.3.11-alpha (2026-04-19)

### Added
- **Spell Position Lock** — pin a spell's row in a preset so it stays put when you press Sort by Duration. Locked spells also can't be reordered by Move Up/Down, and those buttons skip past locked rows when moving unlocked spells around. Click the new `[ ]` column on the right of the spell list to toggle — it flips to `[L]` in gold, and the spell name takes a warm gold-brown tint so locked rows are visible at a glance. Lock state persists in the save game (schema v6). Existing saves migrate automatically (`lock=0` for all pre-existing spells).

## v1.3.10-alpha (2026-04-18)

### Fixed
- **Remove button was not reversible** — once a spell was removed from the buff list, it was also hidden from the Add Spell picker, so an accidental Remove click had no recovery path. The picker now includes previously-excluded spells and sorts them to the top for easy undo. Clicking the spell in the picker flips the override back to "include" and auto-merge restores it to the preset.

## v1.3.9-alpha (2026-04-11)

### Fixed
- **CRITICAL: F12 innate ability accumulation** — each use of an F12 innate added a duplicate known spell entry via opcode 171 (Give Innate). Over time (and especially after resting), characters accumulated dozens of copies (37+ reported). This corrupts the CRE spell list and can crash the engine on rest.
  - **Root cause**: opcode 171 unconditionally adds to both the known AND memorized spell lists on every application. The "re-grant after cast" pattern creates unbounded accumulation.
  - **Fix**: removed opcode 171 from all BFBT SPLs. Replaced with opcode 172 (Remove Innate) for post-cast cleanup + Lua-side `AddSpecialAbility` re-grant with duplicate guard.
  - **Backwards compatible**: existing saves with accumulated innates are automatically cleaned up on first session load (one-time startup cleanup via `RefreshAll` with 50-pass `Revoke`).
  - All innate grant paths now check `_HasInnate` before calling `AddSpecialAbility` to prevent future duplicates.

## v1.3.8-alpha (2026-04-11)

### Fixed
- **WeiDU packaging** — moved `setup-buffbot.tp2` inside the `buffbot/` mod folder (standard convention). Fixes compatibility with mod managers and automated installers (BiG World Setup, Project Infinity, etc.) that expect the tp2 inside the mod folder.

## v1.3.7-alpha (2026-04-10)

### Added
- **Sort by Duration button** — one-click reorder of the current preset's spell list by duration (permanent > long > short > instant). Persists immediately. Available in both normal and variant button layouts.

## v1.3.4-alpha (2026-04-08)

### Added
- **Movable panel** -- drag the title bar to reposition the config panel (#24)
- **Resizable panel** -- drag the bottom-right corner to resize (#24)
- **Reset Layout button** -- restores default 80%-centered panel
- Panel position/size persisted to baldur.ini across sessions
- Screen clamping on resolution change

## v1.3.3-alpha (2026-04-06)

### Bug Fix
- Panel rendering broken on ultrawide / non-standard resolutions (#25) — parchment background MOS was a fixed 2048x1152 image, leaving a black gap on ultrawides (3440x1440+). Now generates the MOS at runtime by tiling existing PVRZ blocks to match the actual screen size. Also handles resolution changes mid-session.

## v1.3.2-alpha (2026-04-06)

### Bug Fix
- LuaJIT auto-installer was never actually installing LuaJIT — `INDEX_BUFFER` matched a documentation comment in `InfinityLoader.ini` instead of the actual setting, causing the component to always skip with "LuaJIT is already active"
- Replaced with `COUNT_REGEXP_INSTANCES` using `^` line anchor to match only actual INI setting lines
- Verified working on both EEex stable (v0.11.0-alpha) and devel branches

## v1.3.1-alpha (2026-04-05)

### Installer
- LuaJIT auto-detection and installation — BuffBot installer now checks for EEex LuaJIT and installs it from EEex's own files if missing
- Fixes crash on EEex devel branch when LuaJIT component not selected (`io` global nil at BfBotInn.lua:12)

### Runtime
- Graceful degradation without LuaJIT — core features (scanning, config, casting) work; F12 innates, Quick Cast, Export/Import, and logging disabled with clear warning message

## v1.3.0-alpha (2026-04-02)

### Features
- Subwindow selection spells (opcode 214) — variant picker for spells like Protection from Elemental Energy (#20)
  - Auto-detects opcode 214 in spell feature blocks, parses the referenced 2DA for variant sub-spells
  - Variant picker sub-menu: select which sub-spell (Fire, Cold, Electricity, Acid, etc.) to cast
  - Enable gate: cannot enable a variant spell without selecting a variant first
  - Execution engine consumes parent spell slot via `m_flags` manipulation, casts variant directly via `ReallyForceSpellRES` — no subwindow ever opens
  - Active buff skip detection uses variant resref (the variant produces the buff effects)
  - Safety skip for variant spells with no variant configured
  - Dual button layout: variant spells show squeezed button row with Variant button; normal spells unchanged
  - 20 new tests (200+ total)

## v1.2.2-alpha (2026-03-27)

### Features
- Target picker redesign: ordered priority list with fallback chain (#18)
  - Click party members to assign cast priority (1st, 2nd, 3rd...) — skip detection falls through to next target
  - "All Party" populates all members in portrait order for reordering
  - Move Up/Down buttons for priority reordering within the picker
  - Self-only and AoE spells locked to appropriate target by default, with "Unlock Targeting" override for modded spells
  - Name-based target storage — targets survive party rearrangement (old slot-based saves converted automatically)
  - `tgtUnlock` per-spell field for overriding targeting type lock

## v1.2.1-alpha (2026-03-27)

### Bug Fixes
- **CRITICAL**: Fix innate ability accumulation that corrupted save files and crashed on rest
  - `RemoveSpellRES` silently fails when queued (not in INSTANT.IDS) — innates were never removed
  - Each preset refresh added new innates without removing old ones, causing 3x+ accumulation
  - Bloated spell lists corrupted CRE data, causing NULL pointer crash during rest
  - Fix: new `BFBTRM.SPL` with opcode 172 (Remove Innate) applied via `ReallyForceSpellRES`
  - Existing accumulated innates cleaned up automatically (5-pass revoke on next refresh)

## v1.2.0-alpha (2026-03-19)

### Features
- Scanner refactor: known spells iterators as primary catalog source instead of GetQuickButtons (#17)
  - All known spells now visible (including exhausted/unmemorized) — no more disappearing spells
  - Spell Revisions strref 9999999 handled correctly (names display properly)
  - Scan entries include `isAoE` and `isSelfOnly` targeting flags (preparation for #18)
  - Simplified architecture: 394 → 254 lines, removed 3 dead code paths

### Bug Fixes
- F12 innate abilities no longer display "panic" on Lua errors — BFBOTGO wrapped in pcall (#9)
  - Self-healing: stale party slot detection triggers automatic RefreshAll
  - Errors logged to `buffbot_innate.log` for debugging
- Exhausted spells (0 remaining slots) now show name and icon in spell list (#8)

## v1.1.0-alpha (2026-03-08)

### Features
- Custom leather+brass panel border using EEex's 9-slice rendering system
- Parchment texture background for main panel and all popup sub-menus (target picker, rename, spell picker, import)
- Text colors updated for parchment readability

### Installer
- WeiDU installer now copies visual assets (MOS, PVRZ) alongside Lua/menu files

## v1.0.0-alpha (2026-03-08)

Initial public alpha release.

### Features
- Dynamic spellbook scanning — discovers buff spells from all sources (memorized, innate, HLAs, kit abilities) in real time
- In-game config panel with per-character tabs, scrollable spell list, target assignment, priority ordering
- Up to 8 independent presets per character with create/rename/delete
- Parallel per-caster execution engine with active buff skip detection (SPLSTATE + effect list)
- Quick Cast mode — per-preset 3-state toggle (Off / Long only / All) for instant casting via Improved Alacrity
- F12 innate abilities — per-preset innate in each character's special abilities
- Manual spell override — "Add Spell" picker to include non-buff spells, "Remove" to exclude false positives
- Config export/import — export a character's full config to a file, import onto any character across saves or between players
- Save game persistence via EEex marshal handlers
- Works with SCS, Spell Revisions, kit mods, and other spell-adding mods automatically
- 129 automated tests

### Known Limitations
- Innate ability icons are placeholder (Stoneskin icon)
- Panel visual design is functional but unpolished
- Spell Revisions sub-spell pattern (Barkskin, Dispelling Screen) may need manual override via "Add Spell"
- Export/import directory listing uses Windows `dir /b` command (no macOS/Linux support yet)
