# BuffBot Redux visual redesign — implementation review

2026-10-20. Development beta based on upstream v1.10.1.

The latest build also adds preset deletion, data-only plan import/export,
concurrent mixed-execution Balanced Quick Cast, smart-order controls and unique
daily-item sharing. The
[feature guide](../plan-management-and-casting-beta.md) records native evidence
and beta limits. These new options/dialogs await user visual review; the gallery
continues to show the earlier visual-design checkpoints.

Open [the native screenshot gallery](index.html). The gallery includes the staged
checkpoints, final SoD and BG1 pages and popups, IWD/BG2 skins, wide pages, empty
states, native fallback and edge-placement examples. Matching supplied design
boards can be expanded beneath the captures. Screenshot bytes are original;
the capture manifest records their dimensions and SHA-256 hashes.

## User-reported fixes after the first beta

The 20 October feedback supersedes the original boards in these respects:

- The SoD X moves 33 logical pixels right and eight up onto the outer corner,
  following the inventory reference. The left dragon is replaced by joined
  native frame rails so the tabs remain clear. Other skins retain their corners.
- Empty mouse clicks are absorbed on the main panel, menus and dialogs. Escape
  uses a zero-size keyboard target; visible Close/X controls remain explicit.
  Native tests exercised blank footer, inside-dialog and outside-dialog clicks.
  The game keyboard queue closed the top dialog and preserved the main panel;
  see `evidence/fix-escape.json`.
- Buffs, Summary and Order rows are four logical pixels taller. Caster menu
  anchors use the matching new row height; the native Order picker was checked.
- The supplied SoD interior had baked inventory border fragments at its bottom.
  BuffBot samples only its clean interior and continues the clean bottom rail
  through the gold/weight-plate regions in its private corner copies. UI++ files
  and the supplied design tree remain untouched.
- Footer Add/Hidden/Cast bounds are placed from right to left with 12px gaps;
  Add gets 170 compact / 190 wide pixels. This fixes overlap in the wide layout.

The gallery's **User-reported fixes** section contains compact and maximized-wide
captures. Earlier captures remain as historical comparison. The latest copied
session was preserved in `scratch/buffbot-session-before-ui-fixes-2026-10-20`.
The test-only automatic startup harness is retired for subsequent normal launches.

## Stable-browser follow-up

The next feedback requested fixed row positions during edits, upfront duration
ranges, retained exhausted-pool recipients, repeat-click dropdown dismissal and
removal of the black exterior rectangle. These are implemented:

- The browser caches row ranks. Values change immediately; ranks are rebuilt
  on explicit column sorting, recipient/preset changes, source refresh and reopen.
  Search preserves relative order. New/restored rows append until re-sorted.
- Shared pure planner helpers define recipient legality, duration and source
  preference for both allocation and browsing. The row includes every compatible
  caster duration with a nonzero source pool, without subtracting reservations.
  The portrait retains its assigned/next-cast duration. This fixes Death Ward's
  initial misleading 20m-only preview when 15m sources also exist.
- Target legality is separate from reservation availability. Unchecked eligible
  recipients remain visible at zero free uses, with forecast durations. The uses
  cell receives a low-opacity red fill and warning glyph. A blocked click returns
  the existing reason and does not add a request or spend a use.
- Dropdown surfaces repeat their trigger hit region above the click shield;
  clicking it closes the dropdown. Explicit no-op shield actions absorb blank
  clicks. The opaque full-canvas fill was removed; the frame/interior remain.

Automated cases cover stable sorting with changing values, the range before and
following reservation, filtered exhausted rows, pool swapping without overspend,
self/dead-recipient legality, all three dropdown triggers and warning clearance.
A separate native profile loaded the real 17-request Rest List and showed Death
Ward at 0/4 with all six portraits and its 15–20m range. The saved review image
shows the exterior canvas removed. The user's original dialogue session was
left running. Visual confirmation of the final dropdown/interaction changes is
handed to the user; no final native-click walkthrough is claimed for this follow-up.

## Implementation

`BfBotRx.menu` defines one main menu, one anchored-menu surface and one dialog
surface. The main menu has Buffs, Summary and Order, one preset selector, New,
Options, Close and the existing footer actions. `BfBotVis.lua` adapts the existing
PartyUI/planner state; it does not replace assignment, reservations or execution.
`BfBotVD.lua` contains generated frame geometry, glyph cycles and theme tokens.
The generators and explicit resource manifest are included in the repository.

Every clickable list element has a separate column. Native clicks dispatch via
`cellNumber` and the list's selected-row variable. `rowNumber` is used only while
drawing cells, never as the click action's row identity.

| List | Dispatch |
|---|---|
| Buffs | 1–4 source details; 5–10 packed eligible recipients; 11 Clear |
| Summary | 3 caster picker; 5 remove one request; headings ignore clicks |
| Order | 2/3 details; 5 caster; 7 Up; 8 Down; 9 remove one request |
| Add / Hidden | Only cell 3 Add / Restore changes the catalog |
| Preset / Options / Rest / Caster | One choice per row; existing choice kinds |

Party has one chip and reserves one cast. Individual recipients stay independent.
Shared variant pools and per-source durations are unchanged. Qualifier lines,
source details, automatic/pinned casters and selected-unavailable recipients remain.
Only one new popup is open at once. Anchored menus have no native modal scrim;
dialogs use native modal dimming and centered bounds.

## All seven design open items

| Item | Answer and evidence |
|---|---|
| 1. Cell API / decimal widths | `cellNumber` plus the selected-row global works in native clicks. Decimal column widths crashed the native parser in a disposable probe; the identical integer form loaded. Used integration §4's integer-percentage fallback with the last column taking the remainder. Headers derive from the same geometry. |
| 2. BAM names | `BFBARROW`: cycles 0 Up / 1 Down, frames 0 normal / 1 pressed. `BFBGLYPH`: one cycle per supplied glyph; exact cycle map in `BfBotVA.json`. No Unicode control glyphs. Generated art uses 89 BAM resources and PVRZ pages 88700–88835. |
| 3. UI++ fallback | The redesigned interface requires the referenced UI++ BAM families, popup MOS rails and RGFONT/RGTRAJ fonts. If any is absent, the existing functional recipient interface opens. UI++ is optional. Native fallback was exercised by disabling availability in the copied session; automated tests cover absent and partial resource sets. No UI++ installation files are changed or bundled as controls/fonts. |
| 4. Fonts | Installed UI++ uses `RGFONT` for readable names, durations and notes, and `RGTRAJ` for headings, tabs and buttons. Durations always use RGFONT. Private style/color entries leave the existing UI++ styles intact. The native font palette is AABBGGRR; colors were checked in game. |
| 5. Keyboard / hover | No per-cell keyboard navigation exists in the current planner. P11 focus/per-cell-hover rings are omitted as permitted; selected/error states do not depend on hover. Escape has an explicit native button binding. See native keyboard evidence below. |
| 6. Running / Stop | The executor exposes idle/running/done/stopped and a real Stop operation. The existing panel closes when casting starts; reopening can expose the existing Stop condition. No new progress UI, interruption explanation or restart policy is introduced. P5/P6 remain unimplemented. |
| 7. Long names | UTF-8-safe chip shortening preserves at most 11 compact / 20 wide characters, with the full name in the native tooltip. Native French/German examples and automated accented-character tests pass. Duplicate-name qualifiers remain separate from the title. Variant names retain their school rather than ellipsizing it away. Full translated-language catalog review remains a localization task; the synthetic names are labelled as such. |

## Walkthrough

The repeatable review fixture uses the copied game's real spell/item resources,
portraits, eligible sources and durations. It creates review presets only in the
isolated test state. Empty Add/Hidden screenshots deliberately use empty display
tables; they are layout states, not claims about the real party's inventory.

| Step | Result |
|---|---|
| 1. Everyday requests | Bless Party, Barkskin Keldorn and Improved Haste Jan render with selected chips and reservations. Eight-request fixture has no unavailable assignments. |
| 2. Two immunity schools | Simmeon Abjuration and Jan Divination remain separate requests. Eight rows share the parent capacity. Native Clear on Abjuration changes shared free uses from 3/5 to 4/5 and preserves Jan's Divination. |
| 3. Filter / search / sort | Jan filtering preserves requests. Native scrollbar was set below the top; search restored `.scrollbar.top` to 0. Sorting twice preserved all seven remaining requests. |
| 4. Summary | Party appears first; Haer'Dalis shows no individual buffs; Jan has three. Portraits, icons, caster and durations render correctly. |
| 5. Order / caster | A native Down click moved only its request. Native caster-cell click opened the intended picker. Choosing Jan changed Improved Haste from Auto Haer'Dalis 3.3m to Jan 3.1m. First/last movement guards work. |
| 6. Remove / Clear / Hide | Native Clear removes only the selected variant's recipients. Native Hide removes the entire family from browsing while keeping the saved request. Native Restore returns all eight variants and the remaining selected request. Single-request removal and heading guards also pass regression tests. |
| 7. Rest independence | Editing Everyday and After Rest remain separate. Off is first and selecting it does not change the edited preset. Naming Cancel and invalid Save preserve current behavior. |
| 8. Popups / edges | All current popup types captured in SoD and BG1 at a 1280×720 client. Rest flips above its bottom-left trigger. Options clamps near the right edge. The caster picker flips above a synthetic bottom-right anchor with all borders/options inside the panel. |
| 9. Empty / unavailable | Search, Summary, Order, Add and Hidden empty states render with recovery guidance. A missing pin stays explicit, with reason text, warning and red ring; Cast disappears under the existing rule. |
| 10. Native themes | SoD, IWD, BG1 and BG2 rendered from game resources; all wide pages captured at 1920×1080. BG1 is the nil/unknown-skin fallback. Missing UI++ routes to the existing interface. |

Native assertion evidence is in `evidence/manual-1792500000103.json`. Earlier
failed fixture assertions are retained as diagnostic history; resource IDs were
normalized to uppercase before the successful repeat. They are not product failures.

## Deviations and engine fallbacks

1. **Fit threshold:** wide requires at least 1920×1080 logical pixels, rather than
   only height ≥1000. A maximized 1080p window provided 1920×1009 and clipped the
   prescribed 1080px frame. The existing compact canvas is centered until wide
   fits. This retains both fixed designs, avoids stretching columns and keeps
   the controls/frame visible. Native resize and fullscreen screenshots cover it.
2. **Integer column percentages:** the documented fallback replaces decimal
   widths. Native header/cell boundaries use the same integer percentages.
3. **Font rasterization:** native font sizes are rounded to whole points; tracking,
   CSS gradients, inset glows and shadows are approximated by the prescribed
   native controls/fills. Durations retain lowercase units. No replacement font
   files are installed.
4. **Native UI scaling:** a 1280×720 client in this UI++ installation reports a
   1365×768 logical viewport and scales it to the client. The 1280×720 compact
   canvas is centered in that viewport. Captures retain the original window
   chrome and pixels; no rescaling/cropping is presented as native evidence.
5. **Source range:** the current planner exposes self-only classification but not
   a numeric range. Details show Self where known and a dash otherwise. No range
   or coverage guarantee is fabricated.
6. **Unknown duration:** existing zero-duration ambiguity remains “Instant/unknown”.
   Permanent and known finite durations retain their existing distinction.
7. **Scrim / rail rendering:** dialogs use native modal dimming. UI++ MOS rails
   have six transparent leading pixels; the renderer offsets/clips them at
   native resolution. This avoids stretched rail artifacts.
8. **Control keyboard target:** invisible dismissal targets use native buttons
   instead of text widgets. Their visual appearance remains transparent.
9. **Texture allocation:** generated GPU pages use transparent power-of-two
   padding up to 1024px; visible frame geometry is unchanged. The binary layout
   follows [IESDP BAM V2](https://gibberlings3.github.io/iesdp/file_formats/ie_formats/bam_v2.htm)
   and [PVRZ](https://gibberlings3.github.io/iesdp/file_formats/ie_formats/pvrz.htm).

P1–P11 were not adopted. The user-requested wide layout implements P12. Current
Cast hiding, naming behavior, ordinary execution, shared pools and all other
behavior contracts remain the default. No balanced Quick Cast, cross-character
item passing or equipment automation was added by this visual change.

## Validation and remaining limits

- Final complete regression suite: **938 passed, 5 deselected**. The five
  deselections require Windows symlink privileges. Includes LuaJIT, synthetic
  WeiDU 249 install/uninstall and release/deploy tests.
- Focused planner/dashboard/visual repeat after the stable-browser
  follow-up: **118 passed**. Resource tests check exact hashes, BAM frame/cycle/block
  references, PVRZ sizes and power-of-two texture allocation.
- Native Escape passed through the game keyboard queue: the top popup closed, its state cleared, and the main panel remained open. Evidence: `evidence/native-escape.json`.
- A raw native duplicate push increased stack depth from 22 to 23. The corrected open guard kept depth at 22 through 100 repeated opens; the toolbar toggle closed and reopened correctly. Evidence: `evidence/native-stack.json`.
- The final native Cast click closed the panel and executed Jan’s Improved Haste on Keldorn; the game log showed both the cast and Hasted effect. See `walkthrough-cast-closes-panel.jpg` in the gallery.
- Earlier synthetic stress sessions crashed in native drawing code. Diagnostic
  harnesses were corrected to avoid render-callback menu changes, numeric-zero
  stack-check mistakes, duplicate main-panel pushes, and stale hot-loaded menu definitions. The production toggle now recognizes the new panel, and its Open operation is idempotent. A later clean
  input-driven session passed ordinary/shared dialog repeats, skin changes,
  errors, live resizing, maximized-fit and fullscreen-wide review. These checks
  do not conclusively attribute every earlier crash or certify a long soak.
  The build remains an experimental beta; crash history is not erased.
- The installed EEex build logs a pre-existing C2DArray cleanup error (`EEex_Resource.lua:334`, missing `Destruct`). The saved completed-rest log from before this redesign contains the same warning. This remains unresolved; EEex files were not patched. Evidence: `evidence/eeex-cleanup-warning.json`.
- Native testing used single-player EET / BG2EE 2.6.6.0 with UI++ and EEex.
  This does not establish BG1EE/IWDEE or multiplayer runtime acceptance.
- The personal game and UI++ installation files were not modified. Only the
  isolated copied game/profile received deployment and review fixtures. PC
  master output was muted before testing and is left muted.

## Concurrent casting and Order tools

Independent casters now overlap within dependency phases. Native Anomen and
Jaheira casts began on the same game tick, all three direct casts accelerated,
and twelve new components received compensation. Shared-item loans and known
casting dependencies and unresolved helper resources retain barriers. Earlier supported buffs age
across later phases in the reference model.

Order adds Smart order, Long first and Undo above the column headers. The native
QA plan moved short Bless after long Protection From Fire; Undo restored the
original request objects and order. Captures use an isolated, namespaced menu
copy to avoid duplicate widget names during live reload; its source geometry,
art, fonts and actions match the shipped menu. No screenshot pixels were edited.
The lab screenshot with duplicate widget names was discarded as a harness artifact.

The duration sort is an explicit bounded heuristic, using assigned durations,
normal casting costs and aura. It does not claim a global optimum or silently
replace later manual ordering.

## Sorting follow-up

The screenshot report exposed overly broad sorting restrictions. Long first now
sorts the whole plan by assigned duration; helper-spell execution fences and
borrowed-item rows are movable. Smart order starts from that global baseline
and accepts timing improvements rather than preserving arbitrary caster slots.
Only proven casting-modifier prerequisites retain affected-caster precedence.
The tooltip is now: "Long first, with casting times considered to maximize buff duration."

A native read-only test used the installed metadata for sixteen rows from the
reported list with synthetic availability. No spells, charges or transfers were
executed. Both one-hour Boots moved first, followed by 48-minute mental buffs,
the 40-minute Girdle and shorter spells. Long first had no duration inversions;
Smart order made small timing changes among Improved Haste casts. Native evidence:
`evidence/sort-separation-native.txt`. Existing toolbar geometry is unchanged.

## Mixed execution timing audit follow-up

Helper/variant/projectile delivery alone no longer creates a global wait.
Known casting modifiers, Project Image, unresolved resources and physical item
loans retain safety fences. Normal spells still use native actions.
The audit persists independently of the per-batch execution log and records
actual elapsed time, modeled ages, original/expected/read-back expiry values,
verification, skipped components and observed normal effects across the party.
A three-game-second observation window catches late projectile impacts without
blocking completion or writing normal effects.
See `evidence/timing-concurrency-audit.jsonl` and its independent native final
scan in `evidence/timing-concurrency-native.json`. No GUI changes in this step.

The projectile follow-up observed Protection From Evil effects on all six
party slots after completion, with unchanged absolute expiry values. An earlier
four-action run verified two native Improved Haste casters starting on the same
tick. The final follow-up correctly skipped Keldorn's already-active Improved
Haste; this was an existing-buff guard, not a failed cast. The private lab ended
with no execution, item journal, acceleration helper or coverage observer left.

## All non-item spells quick-cast; expanded duration balance

Acceleration is independent of duration eligibility. Items retain native
activation; spells including variants, party buffs and projectiles use the
original helper. The observer now balances new finite gameplay components
across all six recipients, parent/selected-variant and child resources, including
late projectile impacts. Uncertain graphs and ambiguous repeated delivery use
no-extension conservative correction. Effect-address reuse across spell
resources keeps separate ownership records; unchanged pre-existing effects are
protected.

Native evidence: `evidence/all-spell-acceptance.json`. Twelve casts completed
with zero skips; all 272 expiry writes passed read-back and independent final
live-effect checks. Five named buff families now use the full component model.
Protection From Evil and Remove Fear were adjusted across all six recipients.
A separate test correctly observed fewer recipients while an existing Spell
Immunity blocked incoming buffs; no effect was fabricated to fill that gap.

The small ASCII `*` appears beside incomplete/limited spell names, with hover
text explaining no balance or conservative balance. Real Aura of Flaming Death
metadata demonstrated its limited trigger handling on all three pages in BG1.
The temporary one-request UI plan was display-only; it spent no resources and
was never saved. Captures use the existing namespaced review adapter, matching
shipping geometry and resource names. Native tooltip functions were asserted;
physical mouse hover rendering remains available for user confirmation.
Twenty-five visible catalog rows retained limited classifications; the catalog
and reasons are in `evidence/all-spell-ui-markers.txt`. Unknown timing engines,
external EFF/conditional graphs, very late impacts and refreshed-in-place
components remain bounded/explicit limitations. Final lab cleanup found no
execution, item journal, acceleration helper or late observer. No personal
installation or UI++ file was changed.

## Casting performance follow-up

The observer previously rescanned every earlier cast against every party effect,
walked a target list again for each component correction, and opened/closed the
audit file per row. Indexed snapshots and relevant-source/resource fast paths
replace those loops; normal item coverage shares the index. Expiry writes use
local snapshot handles, while retained baselines remain plain data. Audit writes
are batched at cast/poll/end/reset boundaries. Late polls run at most every three
game ticks, with immediate cast-callback observation and no repeat paused scans.

Quick-cast dispatch has a two-game-tick minimum gap (typically three ticks/0.2s
including native resume scheduling). Casters remain independent; no normal round
or aura wait is introduced. Preflight is rechecked after a wait, and nonce guards
reject stale callbacks. Items, normal casting and legacy quick-cast modes keep
their behavior. Actual elapsed presentation time remains included once in balance.

`evidence/casting-performance-acceptance.json` contains the five-run median
40-cast/1,000-existing-effect stress comparison: 92.8% fewer effect-list visits,
about 10.6x less Lua time and identical final expiry checksums across 320 writes.
Native five-cast party/projectile acceptance verified 108 expiry writes against
independent final effects, with all six recipients for both radial/party buffs,
three-tick dispatch gaps and a measured 5ms maximum observer snapshot. These are
observer/benchmark measurements, not certification of whole-engine FPS. No GUI
geometry or art changed. The timing audit remains enabled and adds dispatch and
performance rows for further diagnosis.

## Independent class, item and summon follow-up

The [compatibility report](../compatibility-test-report.md) records the native
resource sweep, imported class fixtures, summoned casting sources and item
activation/recovery matrix. Evidence is in `evidence/compatibility/` and the
aggregate `evidence/compatibility-acceptance.json`. The 1,358 timed-effect writes
all read back correctly and matched independent final native scans. Summons
remain caster sources only; six party recipients are preserved.

Inventory return uses inverse gear swaps or guarded stock inventory exchanges,
with canonical resource identity and launcher-aware hand checks. Native completed
rest, stopped/combat-interrupted loans and actual fresh-process save/load recovery
are covered. Four interactive/non-droppable powers require manual use. The
Headband of the Devout / Haer'Dalis child-action stall remains explicitly open;
its successful Jan control does not erase the failed caster-specific test.

No layout or art changed during this pass. BG1 wide preset option/delete/import
captures supplement the existing four-skin review. The personal install and UI++
files remain untouched.


### Shared preset innate shortcuts

Native opcode-402 tests launch shared preset 2 from Keldorn while the editor remains on preset 1. Anomen and Jaheira both cast and spend their own uses. Two simultaneous shortcut activations produce one external launch; shortcuts recharge without rest or duplication. Creation/deletion and Settings recipient selection reconcile six PCs correctly (one selected: 2/0/0/0/0/0; none: all zero; all: two each). Recipient controls have callback and persistence tests; the new dialog has not had a screenshot review. Evidence: `evidence/party-innate-*.json`.

Final shortcut regression: **1,195 passed, 5 deselected** (Windows symlink privilege cases).


### Native fast-forward alternative

Settings / Casting adds Normal, Balanced Quick Cast, requested 2x and requested
4x. The new mode runs normal native actions with temporary simulation speed;
no helper or expiry edits. Existing saves retain their mode. Native probes:
three casts / zero skips at each rate; approximately 8.890 / 4.995 / 4.954 s;
corresponding effect lifetimes within a few ticks; rate 30 restored. The mixed
probe spends two Boots charges, returns slot 22 and clears its journal; manually
included Haste reaches all six after native projectiles. Native Stop and spawned
hostile controls restore speed (combat control: 68 ms). Guard work is limited to
a 50 ms cadence. Requested 4x adds no useful benefit in this session; recommend
2x. Full fatigue expiration, extended periodic effects and native load-during-
acceleration remain separate acceptance work. New Casting dialog screenshot
review is pending. Raw evidence: `evidence/fast-forward-*.json`.

Final fast-forward regression: **1,210 passed, 5 deselected** (Windows symlink privilege cases). The generated CChitin binding is optional and explicitly guarded; missing bindings refuse fast-forward without changing the rate.


### Rendering and normal-mode concurrency investigation

The recorded one-at-a-time behavior was reproduced in the shared-item coordinator:
normal mode did not form independent batches. It now does, without inheriting
Balanced timing-model fences. Native loan-containing normal and fast plans both
passed 2/1/2 batches, five casts, zero skips, item return and empty journal.
Rate/VSync/sleep/foreground/render-ceiling controls ruled out a hard 2x limit in
this session. Native profiler graphs showed render work commonly around 10–30 ms.
A temporary EEex render ceiling of 30 FPS unlocks faster logic: the identical
three-cast test now takes 9.076 s normal / 4.740 s requested 2x / 2.576 s requested
4x, with 133 game ticks each. Completion, Stop and hostile-creature controls read
back restored speed and render settings. Normal and persistent graphics settings
are unchanged. Prior plateau measurements remain historical evidence.

See `fast-render-*`, `fast-concurrency-native.json`, `fast-rate-*` and
`fast-sleep-diagnostic.json` evidence, plus `fast-forward-performance-investigation.md`
in the review bundle. Full regression: **1,214 passed, 5 deselected**; focused
render/mode/API checks pass. New dialog screenshot review remains pending.

Release packaging follow-up including the performance report: **27 passed, five deselected**. Final native readback confirms restored rate 30 / render limit 144 disabled, with no active fast run, loan or journal.


## 2026-10-20 native casting and standalone UI follow-up

Balanced Quick Cast has been removed from runtime/bootstrap/installer/release.
The recipient mode selector is 2x (default), 4x and Normal. Existing native choices
persist; old Balanced settings migrate. Native TLK resolution verified renamed
list titles. Native invisibility ordering completed the incoming targeted cast
before invisibility began, with two casts, no skips and restored simulation rate.

All four private skins opened in an isolated stock BG2EE/EEex game without UI++.
Auto chose BG1; text/display roles used NORMAL/STONESML. Buffs, Summary, Order and
the Theme dialog were inspected. The HUD preset picker was checked with stock and
UI++ actionbars at the right/bottom edges. UI++ has an oversized decorative bar;
its old off-screen placement is now clamped. Expanded stock message logs are also
avoided. See the additional captures in `standalone/` and native JSON evidence.
These captures supplement the original 83 screenshots and do not replace them.

Final regression: **1,071 passed, 5 Windows symlink privilege cases deselected**. Additional release/deploy checks: **27 passed, 5 deselected**. Retired balancing tests were removed with the retired implementation; prior prototype results remain historical evidence.

The existing user test process was preserved. Its open dialog.tlk blocks the final name-token install; coherent prior string references were restored. Close that process and run `Launch BuffBot Redux.cmd` in the test-game directory to finish installation and launch. The launcher rejects the running game before making changes.


### Bottom-bar HUD follow-up (23:11)

The gear docks beside the actual bottom controls in stock UI and UI++, rather
than floating over an expanded message log. UI++ placement uses the final named
bottom-toolbar control; right-aligned toolbars use the free space to their left.
Preset labels use event-transparent, explicitly inset captions inside the plates.
Native stock and UI++ captures: `standalone/stock-hud-docked.jpg` and
`standalone/ui-plus-hud-docked.jpg`. Focused HUD/localization checks: 64 passed.
The earlier above-log positioning described above is superseded by this change.


### Final Redux beta: 1.10.1-redux-beta.1

Tabs are Buffs → Order → Summary. Fresh plans contain empty Pre-Battle Buffs and
Wake Up Buffs lists, with After Rest enabled for Wake Up Buffs; an empty list is
a silent no-op. The speed option reads Fast-forward 2x (Recommended). Existing
saved plans/rest choices remain unchanged. Numbered preset abilities, their
recipient selector, grants, recharge and title updates are retired. Native tests
removed duplicate/stale shortcuts while preserving 10 real innate abilities.

984 distinct automated tests were verified; five Windows symlink-privilege cases
were deselected. The final full run had 983 passes and one archive-byte race
because documentation changed after fixture creation. Its exact failed test and
71 related/current checks passed in the 72-test rerun. See
`evidence/final-beta-validation.json` and `evidence/retired-innate-native.json`.
The preceding innate screenshots and title-install note are historical and no
longer describe the current UI or a pending prerequisite.
