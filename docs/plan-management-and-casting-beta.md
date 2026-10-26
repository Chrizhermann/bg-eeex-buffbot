# Plan management and casting beta

## Beta 4: usable plans and clearer counts

Uses remains free-to-add / total available now. A 0/1 row with its one use assigned
is valid and has no warning. Hovering the count shows free, available and reserved
uses. The warning marks enabled planned requests without an assigned source,
including missing casters, empty pools and invalid targets; disabled requests do
not contribute. Variant rows report only their own unavailable requests.

Queue construction retains available decisions in order instead of rejecting a
plan for one unavailable request. The Cast button, HUD picker and completed-rest
dispatch all print the unavailable request count in the game message log. Missing
entries remain saved. An all-unavailable plan reports its skips and starts no run.
Queue-size limits and Project Image safety validation still apply.

Upstream main at `287ad0b` selectively adopted Redux controls/fast-forward into
the original per-caster editor. It displays native counts as xN, not reserved-use
fractions, and does not contain the recipient planner's warning predicate.

The beta 4 check uses a copied 25 October quicksave and matching current EET/EEex
resources. The older private game's EEex build cannot safely load this newer save.

Implemented and tested in the isolated single-player EET copy on 20 October
2026. The personal installation and Infinity UI++ files are unchanged.

## Themes and direct HUD shortcuts

The redesigned panel no longer depends on UI++ resources. BuffBot ships private
BAM controls built from the supplied design exports for all four skins, including
popup rails and scrollbars. It never installs or overwrites RG-prefixed assets.
It references optional UI++ fonts by name; stock NORMAL/STONESML fonts are the
fallback. Durations retain the text font role.

Settings → Theme chooses Auto, SoD, IWD, BG1 or BG2 and saves with party settings.
Auto follows RgUISkin 0–3 when present; otherwise it uses BG1. Manual choices do
not write UI++ globals or configuration. Skin lookup during menu parsing uses
cached values and never accesses a party before the game is initialized.

The persistent HUD gear works with stock and UI++ actionbars. Its position is
clamped to the logical screen and docked beside the visible bottom controls. Left-click
opens the editor; right-click toggles a compact named preset menu. Clicking a list
starts the full party plan directly, using the selected speed and fresh source
availability. There is no selected-PC innate activation or extra spell/aura cost.
Underlying buff spells still take their native actions. Busy, missing and replaced
plans are rejected; Esc/outside click closes the picker. Preset innates and their
recipient selector are removed. Old characters are cleaned on load through native
opcode 172, limited to BFBT{slot}{preset} resources, including spent and duplicate
entries. No normal spell, kit ability or saved preset is removed. A saved obsolete
shortcut action is harmless and cannot start a plan.

The installed C0FIG02 Expertise selector and its activation/deactivation children
are manual-only in automatic discovery. Explicit saved requests and manual Add
remain available; other item and spell discovery rules are unchanged.

## Presets

Right-click the persistent gear to choose a named whole-party preset. The picker
starts the plan directly with its assigned casters, summon sources, item handling
and casting speed; no character casts a trigger ability. Busy, replaced, empty or
unavailable plans are rejected. Editing selection is not changed by dispatch.
Numbered BuffBot innates and their recipient settings are retired.

The gear menu contains **Delete preset**, **Export plan**, **Import plan** and
**Casting** (Fast-forward 2x (Recommended), 4x, Normal).

Deletion requires its own confirmation, keeps at least one preset, and disables
After Rest when its selected preset is deleted. It preserves the other presets.
The confirmation checks that the preset has not changed since the dialog opened.

Exports are `.bbp` files in `override/bfbot_plans` under the game directory.
Copy someone else's `.bbp` into that folder to make it appear in Import plan.
Export chooses a fresh filename. Import creates a new preset in a free slot;
it never overwrites a preset and reports when all eight slots are occupied.
Names, recipient identities, caster preferences, variants, enabled state and
cast order round-trip. Missing characters or sources remain visible for review.
The format is bounded, versioned data: files are parsed, never executed as Lua.

## Casting speed and audit

The recipient planner defaults to 2x native simulation speed. Settings → Casting
also offers 4x and Normal. The same selection applies to manual, After Rest and
preset ability launches. Explicit Normal/4x/2x settings survive loading; retired
Balanced settings migrate to 2x.

Balanced Quick Cast, BfBotBal.lua, effect observers, duration rewriting, deferred
impact observation, balance markers, per-component audit and dispatch pacing have
been removed from the runtime and distribution. The retained original caster
editor still has its upstream unbalanced Quick Cast helpers for compatibility;
the recipient planner never enables them.

Native actions consume slots and charges, play animations and enforce casting
time and aura rules. The whole world clock advances at the selected speed, so
buff durations, existing effects, delayed fatigue and AI all use normal game time.
Fast-forward temporarily limits rendered FPS to 30, retaining a lower existing
cap, and restores previous rate/render settings when finished or stopped. Combat,
load/exit, dialogs and execution timeout also restore them. A small run-level
speed audit remains in `buffbot_fast_forward_audit.jsonl`.

Manual movement is not currently a clean per-caster cancellation signal. A player
command may replace a caster's native queued actions, including its completion
callback. Other casters continue; the interrupted chain does not reliably resume.
After 450 game ticks without progress (30 simulated seconds), the executor's
watchdog ends a stalled run and restores speed. Item completion has separate
recovery for lost callbacks, and item loans keep a persistent return journal.
Already applied buffs remain; spent resources follow native engine behavior.
Use Stop before taking direct control when an immediate clean stop is needed.

## Order tools

Smart order places invisibility after buffs from another caster that target the
same recipient. Self and party casts are exempt. Detection follows opcode 20
through spell, selected variant, item and bounded child/EFF graphs. During native
parallel execution, an invisibility action waits only for preceding targeted
casts on its affected recipient(s), rather than blocking independent casters.
Long first remains the simple duration sort; manual order is not rewritten.


The Order tab has **Smart order**, **Long first** and **Undo**. They run only on
an explicit click; assigning buffs does not silently reorder the plan.

Smart order uses assigned caster durations, current casting-time modifiers and
aura estimates. It starts with longer buffs first, then makes bounded adjacent
improvements to the worst retained fraction of a finite buff, breaking ties by
the total retained fraction. Slow casts can therefore precede a longer but fast
spell when that better preserves the shortest-lived buff. It compares the final
reassigned plan against the Long first baseline and accepts only an estimated improvement.
This is a heuristic, not a proof of globally optimal scheduling.

Long first gives the simpler descending-duration order, with permanent buffs
first. Helper-spell execution fences and item loans can move freely as complete
rows; they no longer split the sort into fixed sections. Unknown or unavailable
entries move after known durations. Both tools retain recipients, variants and
explicit caster preferences. Proven casting modifiers preserve relative order
on affected casters; unrelated casters remain free to move. Automatic sources can rebalance through
the existing allocator; a sort is rejected if it makes a previously available
request unavailable. No spell or resource is spent by sorting.

Undo restores the exact prior request order. Subsequent additions, removals or
manual moves invalidate it. Caster preference edits remain intact when undoing a
sort. Manual Up/Down remains available for personal priorities;
the UI displays a spell summary, while the engine retains each component's native duration.

## Purposeful item sharing

Eligible recipients gain sources for a unique loose rechargeable item elsewhere
in the party. They all reserve the **same physical charge pool**. A self-only
item ability remains self-only: the recipient borrows and uses the item.

This first implementation supports identified, nonstackable daily rechargeable
powers with at least two maximum charges, from a backpack slot. It rejects
duplicate loose copies, consumables, curses/undroppable flags, full recipient
backpacks and characters in another area. Eligibility uses the native inventory
`CInfGame::CheckItemUsable` routine, including the engine's conditional usability
path. Its executable metadata and function signatures are checked before calling;
unknown engines do not receive sharing aliases. Ordinary item behavior remains.

A loan waits for the preceding independent batch and completes its transfer,
cast and return before the following batch. Independent casters otherwise run
concurrently, with each caster retaining the saved order. Each
loan uses engine GiveItem actions, the existing inventory/equipment activation
path, equipment restoration, return to the original owner and repositioning to
the original backpack slot. It never creates a replacement item from a resource.

A validated return journal is saved before transfer. Stop, combat and loading
discard the remaining run and return the item when the recorded state is safe.
If a character disappears, gear changes, a duplicate appears or the original
slot is occupied, automatic return pauses and reports the problem. The journal
is retained; the mod does not overwrite gear or manufacture another copy.
Actual disk-save/load interruption combinations and the broader conditional
usability matrix are covered by the follow-up report; equipped-owner loans and
duplicate physical copies remain outside this beta.

Equipment returns use the original equipment item's inverse swap, or guarded
native inventory moves when the original equipment slot was empty. Backpack
slots are never passed to the engine's equipment action. On supported BG2EE
2.6.6 builds this also restores the owner's original backpack position. Unknown
engine signatures fail closed and ask for manual equipment handling.

## Summoned casters

Live allied spellcasters, including Simulacra, Project Images and Devas, join the
available sources and caster picker. They never join the recipient tabs or
portrait strips: those remain the six party members. Ordinary self-only spells
from summons are excluded because they cannot cover a party recipient.
Caster-centered friendly area projectiles, such as Protection From Evil 10′
Radius, appear as a single Party cast. Actual engine range still determines
who receives the effect.

Each live summon has its own resources and casting lane. The original caster
is unavailable while its Project Image locks casting. A saved clone preference
uses its owner and clone type, and resolves a newly created clone on the next
snapshot. A missing or expired pinned summon stays unavailable; the planner
does not silently spend another caster's slots. Simultaneous matching summons
keep separate physical resource pools even when their display labels match.

Summon equipment swaps and loans are not supported. Already-equipped powers
and ordinary potions keep the existing execution path. Temporary equipment
must be equipped manually before planning a summon cast.

## Broader discovery

Item recognition follows bounded immediate child spells rather than an item
whitelist. Scrolls and wands are available through manual Add without flooding
the automatic browser. Powers that open an additional selection menu require
manual use and are refused before equipment movement or charge consumption.
These include the installed Undead Graft powers. This does not alter the normal
spell-variant rows, whose parent spell-slot reservations remain automatic.

Shared spontaneous pools are reserved per spell level. Selected variants from
sorcerers and shamans consume one level use across all their alternatives,
rather than allowing each alternative its own fictitious supply. Installed
innate abilities that deliberately remove and regrant themselves retain that
native behavior.

## Historical prototype verification (retired balancing implementation)

Native evidence is under `docs/visual-review/evidence` in the source checkout
(the `evidence` folder in the review bundle):

| Check | Result |
|---|---|
| Export/list/read/import/delete | Passed in the native Lua runtime; deletion disabled the test rest preset |
| Normal direct casts, aura cleansing | 64 ticks between two casts |
| Normal casts with four-segment speed bonus | 24 ticks between casts |
| Accelerated casts | Approximately 3–5 ticks per direct cast in these probes |
| Compensation | Eight new components corrected; final expiries retained the 64-tick reference separation |
| Mixed direct / Bless / direct | Saved order retained; quick releases took 3 and 5 ticks, Bless took 92 ticks normally; only the direct components were corrected |
| Mixed borrowed item | Boots cast normally between spells; following direct cast accelerated, one charge spent, owner slot 22 restored, no journal/helper remained |
| Two independent casters | Same-tick start verified; all three casts accelerated, twelve components corrected with individual 20-minute / 15-minute lifetimes |
| Installed-metadata sorting regression | Sixteen screenshot-matching requests now sort globally: both one-hour Boots, 48-minute mental protections, 40-minute Girdle, then shorter spells; synthetic availability only, no casts or item transfers |
| Native smart order and Undo | Short Bless moved after long Protection From Fire; Undo restored the original requests |
| Native expiry write | Shortened component expired after 31 ticks; another component kept its expiry |
| Native item eligibility | A character below Darkfire's strength requirement was rejected; restoring strength restored eligibility |
| Gargoyle Boots loan | Keldorn and Anomen each used it; two charges consumed; item returned to owner slot 22; no journal remained |
| Helper cleanup | Original casting-speed bonus remained; BuffBot's helper was absent after cleanup |

Automated tests additionally cover malformed imports, slot exhaustion, stale
deletion, shared-use allocation, changed effect identities, unsupported timing,
load teardown, queued-transfer cancellation, return recovery and occupied slots.
The new menu entries and deletion/import dialogs have native captures and
callback checks. The [independent compatibility report](compatibility-test-report.md)
records the expanded class/item matrix, effect-expiry verification, recovery
checks and remaining limits.


### Preset shortcut recipients

**Settings → Preset abilities...** selects one, several, or no PCs. Each selected PC receives all numbered preset shortcuts and can start the entire party plan. Selections stay open for multiple changes, save with the party state, and follow character identity when portraits move. Existing saves initially select all PCs. Summons do not receive these shortcuts. The main Cast button works regardless of this setting.


## Native fast-forward casting (historical measurements)

Settings → Casting now offers Fast-forward 2x (default), Fast-forward 4x and
Normal. Old Balanced preferences migrate to 2x; explicit native choices persist. The selected mode also applies to After Rest and the
numbered party-preset shortcuts. Use **2x** as the conservative starting point.
The multiplier is requested simulation speed, not a guaranteed wall-time gain.

Fast-forward temporarily changes `EEex_CChitin.TIMER_UPDATES_PER_SECOND` and
runs the existing executor in normal mode. There is no Quick Cast helper,
clock jump or duration correction. Native spell actions, slots, aura waits,
projectiles, delayed effects and item actions remain in the engine. Existing
buffs, summons and world timers advance naturally along with everything else.
This does not make normal item actions interruptible or cure their known stalls.

The original rate is restored on completion, Stop, combat, leaving the world,
dialogue/cutscene/popups, execution reset, load/exit or a two-minute wall-time
limit. Live safety checks run on a 50 ms wall-time cadence (actual callback
latency depends on engine responsiveness), rather than every uncapped rendered
frame. A changed speed value is not overwritten by cleanup. Speed is not saved
as an active session and no pause/unpause action is injected by this module.
Single-player only; there is no Tactical Time integration or dependency.
Item loans retain their existing custody boundaries and recovery handling.

Native evidence in `visual-review/evidence/fast-forward-*.json` compares the
same three-cast, two-caster plan at normal rate 30, requested rate 60 and
requested rate 120. After reducing guard overhead, the measurements were:

| Mode | Wall time | Game ticks | Casts / skips |
|---|---:|---:|---:|
| Normal | 8.890 s | 130 | 3 / 0 |
| Requested 2x | 4.995 s | 132 | 3 / 0 |
| Requested 4x | 4.954 s | 133 | 3 / 0 |

The approximately 1.8x realized gain is specific to this loaded EET lab session;
other game processes were also running. The two fast cases restored rate 30,
had no Quick Cast helper and retained corresponding native effect lifetimes
within a few game ticks. Timing progression was not skipped. The initial
unthrottled guard measurements are retained separately: approximately 9.1 s,
7.1 s and 7.2 s. Requested 4x provided no useful gain in this test, so it is
an experimental option rather than the recommendation. No frame-rate or
hardware-wide performance guarantee follows from these measurements.

A mixed native test activates Gargoyle Boots for Keldorn and Anomen, spends
two physical charges, returns the item to its original slot, clears the return
journal and casts manually included Haste. Native Haste projectiles then deliver effects to all
six party members after allowing three further game seconds. Completion restores
normal simulation immediately; it does not wait for every projectile/long-lived
effect to finish. This is native delivery evidence, not a full fatigue-expiry
or long-running periodic-damage acceptance matrix.

Native Stop restored rate 30 immediately; spawning a hostile creature restored rate 30 and stopped the plan with a measured 68 ms guard response. Load/reset, menus, altered speed and failed starts have automated lifecycle checks; a full native load-during-acceleration test remains pending.

The native Haste follow-up also records its haste and delayed opcode-93 fatigue effects with identical remaining deadlines on all six PCs (2,028 ticks in that snapshot). This verifies aligned native scheduling at that point; the test did not wait through the full expiry.


### Rendering and concurrency follow-up (supersedes the initial speed plateau)

The earlier near-identical 2x/4x measurements were real, but do not establish an
engine cap. Rate, VSync, sleep-threshold and foreground tests isolate a rendering
budget issue in this session. Fast-forward now temporarily enables an EEex
render ceiling of 30 FPS (or preserves a lower existing limit), independently
of the simulation rate. Original enabled/disabled and numeric limit values are
restored on completion/interruption; normal gameplay and VSync are unchanged.
Missing optional render controls retain functional speed control without this
optimization. No engine or UI++ files are patched.

The latest identical three-cast native plan took **9.076 s normal, 4.740 s at
requested 2x, and 2.576 s at requested 4x**. Each used 133 game ticks, consumed
three casts with zero skips, and left no Quick Cast helper. Both fast cases
read back successful speed and render-limit restoration. This is roughly 1.9x
and 3.5x realized speedup in the tested session, not a universal guarantee.

A separate regression affected any normal/fast-forward plan containing a loan:
the shared-item coordinator grouped independent entries only in Balanced mode.
It now groups normal actions too. Normal actions do not inherit global timing-
model fences; native aura/casting rules still apply per caster. Real physical
loans retain custody boundaries. A native five-cast loan-containing plan now
runs batches of **two independent entries / one loan / two independent entries**
in both normal and fast-forward modes, with five casts, zero skips, return to
slot 22, no recovery journal and the original rate restored.

See [the investigation](fast-forward-performance-investigation.md) and raw
`fast-rate-*`, `fast-sleep-*`, `fast-render-cap-*` and
`fast-concurrency-native.json` evidence. The earlier measurements remain as
historical evidence, not the current expected result.


## Retired preset abilities

The direct HUD picker replaces BuffBot's numbered innate shortcuts. Runtime
shortcut generation, grant/regrant reconciliation, title tokens, recharge hooks,
deferred innate dispatch and the Settings recipient selector have been removed.
The old recipient setting is ignored when loading a plan. The small BfBotInn.lua
module now contains save-upgrade cleanup and the original caster editor's two
invisible helper spells only; these helpers are never character abilities.

The installer retains its existing eight reserved legacy label references for
backward-compatible install/language rollback. They are no longer read at runtime
or used to create abilities. This does not require an installation change or TLK
edit to upgrade the test copy's runtime. UI++ is still optional: its skin value,
optional matching fonts and toolbar geometry are read; its files/settings are
never modified. All frame/control art is BuffBot-owned.


Fresh party plans start with two empty lists: **Pre-Battle Buffs** (selected)
and **Wake Up Buffs**. After Rest is enabled for Wake Up Buffs. An empty rest list
does nothing silently; existing saved lists and rest preferences are preserved.


## Saved ordering modes (beta.2)

Smart order, Long first and Custom are persistent per-preset modes. Their active
buttons use the same selected artwork/frame as the top tabs. New presets default
to Smart order, including the empty starter lists; older saved/imported presets
without a mode migrate to Custom, preserving their order.

Adding/removing buffs, changing variants/enabled requests or changing a preferred
caster updates an automatic mode during the normal UI refresh. A cached signature
skips unchanged calculations; no sort loop runs every frame. Replenished prepared
entries (including spent copies), shared spontaneous capacities and rechargeable
item maxima are used only in an isolated ordering snapshot. Execution, live-use
counters and casting validation continue to use real current resources. Known
but unprepared spells do not acquire fictitious copies. Daily items with zero
charges retain their ordering metadata without gaining live charges.

Each request saves a manual position separately. Custom restores those positions;
new requests append, deleted requests disappear, and caster/recipient/variant
choices are shared across modes. Manual movement selects Custom and records the
new manual sequence. Undo restores both the previous mode and order. Selecting a
mode works even on empty/one-buff lists and even if the order already matches.

Opening/refreshing the editor and launching an automatic preset also check for
meaningful source changes while idle. A run in progress is never reordered.
Plan export format 2 carries mode/manual positions; format 1 imports remain
supported as Custom. Older mod versions cannot read the new export format.
