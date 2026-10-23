# Selective fork improvements: validation record

Date: 2026-10-21; cleanup completed 2026-10-22 (Asia/Seoul). Scope: the unreleased working tree based on v1.10.0.

## Follow-up: EET / Spell Revisions / SCS / modpack without component 430

Completed 2026-10-22 at 01:07 KST. Chris explicitly selected the normal modpack
without experimental Scroll component 430. BG:EE and 5E are outside this task's
scope. This is a new, bounded full-stack result; it does not accept or fix 430.

Evidence directory (`FULL`):
`%USERPROFILE%\.codex\artifacts\buffbot-native-20261021\fullstack-no430`.
The original private full-stack clone was retained. WeiDU regularly removed the
last-installed 430, then reinstalled component 650 from the verified alpha.13
package and all six successors. Current complete BuffBot sources were staged
before that cascade. All 437 remaining components retained their order;
`install-verification.json` passed 484 checks. No runtime guard was disabled.
The banking identity query subsequently confirmed three healthy distinct actors.

All 43 BuffBot package inputs remain identical to the earlier 1130-test state.
No further BuffBot product change was needed. The fixture preserves all three
embedded CREs from the original full-stack save; only private-area references
and positions were changed. The actual installed SR spells/items were used,
with native level-18 caster data and the same baseline before each comparison.

| Mode | Casts / skips | Game ticks | Wall time |
| --- | --- | --- | --- |
| Normal | 8 / 0 | 313 | 20,866 ms |
| 2x | 8 / 0 | 311 | 10,429 ms |
| 4x | 8 / 0 | 311 | 5,279 ms |

The independent core review passed all 101 per-run checks and four comparisons;
seven deliberately corrupted observations were rejected. Every mode consumed
the same six spell memorization entries, one POTN06 unit (3→2), and one AMUL15
charge (5→4). Native durations matched the installed SR data: Mage Armor 2400s;
Mirror Image, Protection from Evil, Bless and Shield 300s; Aid 1080s; potion
600s; Sanctuary 36s. Sanctuary expired by +852/+850/+850 ticks; Bless remained
on all three party members through +1100. Rates 60/120 returned to 30 and stayed
there through observation. Small native phase differences remain; this is one
comparison per mode, not a timing distribution.

Additional native cases cover pause/resume, Stop/restart, stored QC Long/All,
24→48→24, preservation of an external rate 47, occupied equipment swap and Stop
during item use, visible enemy entry, popup, dialogue, load and main-menu exit.
Swap post-states directly prove an empty recovery journal, original AMUL26/
AMUL15 slots and weapon 35/ability 0. SR variants SPWI422→SPWI319 took 122 game
ticks in Normal and 4x, used native action191, delivered the child effect and
decremented only the parent's available flag (including 3→2). The actual load
completed into save 47; the actual exit reached START with WORLD absent and rate 30.
The independent extension review passed 238 checks across 14 final cases and
confirmed all 16 installed resource hashes.
See `core-review.md`, `extensions-independent-review.json` and their raw cases.

Nine fresh renderer screenshots and receipts were independently checked at
1024×768 and 1920×1080. They show the actual Done/Stopped status, all three tabs,
Normal/2x/4x, stored QC2 with suspension, named presets and filtered row identity
(Mirror Image canonical2→visible1). No concrete layout defect was found.

Harness failures are retained rather than counted as successes: the initial
intro-only screen correctly refused loading; a malformed popup-close expression
did not execute; EET dialogue hid the Remote Console's polling menu. A private
WORLD_DIALOG observation widget then captured stopped/rate30/paused state.
Its first cleanup attempt preceded EET's population of reply choices; the final
helper waits for the sole fixture reply. `dialogue-4-final.json`,
`dialogue-final-state.json`, `dialogue-reply.json` and `exit-post-state.json`
are the final evidence. The reply receipt records the chosen marker immediately
before the native reply handler; it is not a closed-dialog post-state. The
subsequent accepted world-state exit case corroborates return to the world.
BuffBot files and Remote Console guards were unchanged.
Unexecuted requests were archived only after their owned game processes stopped.

All three quiet runs ended with no guard trip, audio peak 0, unchanged pointer
clipping and no surviving job processes. The last slot was released at 01:07 KST.
The private lab/profile are retained, stopped. Production and foreign WIP are
untouched. The recurring EEex 2DA finalizer warning remains a separate unresolved
warning; these runs do not diagnose it. No release, commit or push was performed.
`final-evidence-manifest.json` records final source, installed-file and evidence
hashes, preserved foreign worktree files, and stopped-lab checks.

### Component 430 follow-up

Live GitHub provenance verification found Latest still alpha.13 (2026-10-20).
Its released CBMScroll.dll SHA256 `dad1b982…ffaeea` is byte-identical to the
original failed lab DLL. The newer CString-witness redesign exists only as
uncommitted modpack work, with a stale packaged DLL/build manifest. The old
address registry missed inline native action destruction; later address reuse
then caused the false lifetime conflict even for ordinary BuffBot actions.
This belongs to `chriz-bg-modpack`, not to BuffBot's executor.

The foreign worktree was preserved. Its snapshot is isolated at
`%USERPROFILE%\.codex\worktrees\buffbot-scroll-fix\chriz-bg-modpack`.
Executing the previously skipped 2.7.3 witness-emulation tests exposed one wrong
test refcount expectation (3 instead of 2), corrected only in that own snapshot;
both target-version cases now pass. This is offline instruction emulation,
not native game acceptance. The remaining transport-signature review, inline
queue/cancel/reuse coverage, fresh DLL/build manifest and real 430 gameplay
validation are still required before that candidate can be accepted.
Detailed evidence: `%USERPROFILE%\.codex\artifacts\buffbot-scroll-20261022`
(`430-provenance.md`, `review-findings.md`, `witness-273-corrected.txt`).

## Earlier clean-baseline validation

The new local session checked its actual permissions successfully: the central
coordination directory, disposable game clones and redirected Documents profiles
are writable. Git Bash and Windows symlink checks also work. Real hidden-desktop
labs have now run through the unchanged coordination/quiet runners, with native
actions, resource/effect observations and renderer screenshots. The earlier
access restrictions below are historical, not the current blocker.

**The bounded BG2:EE 2.7.3.0 / EEex 1.3.1 native matrix passed after product
corrections.** Normal/2x/4x, two active casters, spell/item resources, buff expiry,
configured variants, equipment restoration, interruptions and late joins have
actual engine evidence. Final screenshots and quiet-runner cleanup are complete.
This earlier result alone did not establish full-stack compatibility; the
subsequent without-430 result is recorded above. No commit or release is authorized.
All implementation changes remain uncommitted; preserve unrelated existing work.

Local evidence root (`ROOT`):
`%USERPROFILE%\.codex\artifacts\buffbot-native-20261021`.
`CLEAN` means its `clean` subdirectory. Reports and their input hashes delimit
the tested state; a prior passing run does not validate later edits automatically.

| Evidence | Established result | Boundary |
| --- | --- | --- |
| `ROOT/offline-tests-final-restore-fix.txt`; `ROOT/release-validation.md` | Final complete suite **1130 passed in 80.16s**, including release/installer checks | Offline actions are mocked; native evidence is separate. |
| `ROOT/ui/ui-report.md`; `CLEAN/final-ui-*.png` | Search/filter identity, speed controls, named HUD presets, real panel/HUD/innate starts; final fresh-process panel/search/HUD at 1024×768 and 1920×1080 | Innate backend tested, not a physical F12 keystroke. Final HUD reference is `final-ui-hud-world.png`. |
| `CLEAN/open-mixed-independent-summary.json`; `open-mixed-1/2/4.json` | 8 casts/0 skips each, six spell debits, potion/amulet each one charge, Bless on all three party members; observed through +680 ticks | 371/372/375 execution ticks; small native approach/cast-phase differences remain. |
| `CLEAN/extension-independent-review.md` and `.json` | Variant casting/aura, pause, Stop/restart, stored QC, baseline24, external rate, popup/dialogue, visible enemy, load, world exit and late ally reviewed independently | Each case has its own observation window; no broad mod-stack acceptance. |
| `CLEAN/swap-crash-analysis.md`; `final-swap-occupied-4.json`; `final-swap-empty-4.json`; `open-swap-stop-4.json` | Integrated product: occupied/empty swaps each 8/0, exact slots/charges preserved through +680; Stop restores equipment and rate | Direct empty-journal/weapon-selection proof is `swap-stop-recovery.json`; final runtime receipt additionally confirms no journal after the empty-slot full run. |
| `CLEAN/final-evidence-manifest.json`; `native-run-4.json` | Final source/installed/evidence hashes; final lab stopped, slot released, zero audio peak, no guard trip or remaining job process | Other users' labs/worktrees were not touched. |
| `ROOT/native-blockers.md` | Original EET/SR/SCS/modpack failure traced to experimental foreign lifetime hooks | Still unresolved; the clean baseline does not erase it. |

The clean baseline is a separate copy of the unmodified local BG2:EE 2.7.3.0
Steam installation with EEex 1.3.1, BuffBot and Remote Console installed. It does
not contain SR/SCS/EET/5E or the experimental modpack hooks. No existing component
was disabled to obtain it. Its provenance is in `CLEAN/README.md`.

### Fixture boundary: original terrain 0 versus corrected open floor

The original baseline hash begins `b691a477…`. Its three actors were later found
on terrain 0. The old three-mode result is retained as evidence of the observed
self/selected-target effects, native resource changes and simulation timing. It
must not be used as proof that all three party members receive AoE buffs or that
spawned enemies are natively visible. The observer captured Bless only on its
caster in that comparison.

The corrected open-floor baseline is `000000012-BuffBot Open Floor`, with
BALDUR.GAM SHA-256
`d1d961d12b966c6f9203867ff296d76273e279d3e2e8e42e88849b4dabdcd915`.
Its provenance and positions are in `CLEAN/active-baseline.json`. The independently
reviewed core comparison now establishes:

| Mode | Completed casts / skips | Execution game ticks | Execution wall time | Observation |
| --- | --- | --- | --- | --- |
| Normal | 8 / 0 | 371 | 24,739 ms | Through +680 ticks |
| 2x | 8 / 0 | 372 | 12,477 ms | Through +680 ticks |
| 4x | 8 / 0 | 375 | 6,347 ms | Through +680 ticks |

Each run consumed the same six spell memorization entries and one charge each
from POTN06 and AMUL15. Bless reached all three party members. The four-tick
spread includes the cleric's native approach and SPPR107 cast start; do not claim
identical game duration. The complete observations and cross-checks are in
`CLEAN/open-mixed-independent-review.json` and its summary. Enemy visibility and
interruption remain separate tests, not an inference from this AoE result.

For reference only, the completed old comparison measured 342 game ticks in
all three modes and 22737/11428/5726ms wall time (about 1.99x/3.97x). Native rates
were 30/60/120 during execution and 30 at completion through the +600-tick end.
Both casters' observed resource-debit grid and effect lifetimes matched apart
from a one-tick start phase. This is one repetition per mode, not a broad timing
distribution or an assertion of identical randomized effect payloads.

### Product defects found in native validation

- Classifier: an opcode 214 variant selector could override a detected stance's
  automatic exclusion. The toggle guard now remains authoritative; manual
  inclusion remains available.
- Status label: the open panel could remain at cached `Casting...` after a real
  completed run. `bbStatus` now renders the existing `_GetStatusText()` getter.
  A native open-panel run visibly reached `Done`. Initial hot-reload pictures
  establish status only; the final fresh-process `final-ui-panel-done.png`,
  `final-ui-search.png` and `final-ui-wide.png` show the complete correct layout.
- Configured variants: native action 181 (`ReallyForceSpellRES`) bypassed normal
  casting time/aura in both Normal and accelerated modes. The correction uses
  action 191 (`SpellNoDecRES`) and debits only availability bit 0 of the selected
  parent memorization. Other flags remain intact. Reviewed Normal/4x runs show
  native casting time, subsequent aura pacing, one parent debit and the actual
  selected child effects. `open-variant-flags3-4.json` also confirms flags 3→2,
  preserving the other bit while the unmemorized child is actually delivered.
- Item swapping: TRUECLASS stat 152=`0x4000` has no ordinary KITLIST row. The
  scanner now maps it to usability mask `0x4000`, preserving explicit no-kit
  bans and all other eligibility guards. AMUL15's mask 2 is not a TRUECLASS ban.
  The subsequent native crash (`CLEAN/native-run-3.json`, Crash1) was separately
  traced to the 2.7.3.0 `XEquipItem` destination 18 indexing `m_quickItems[3]`
  and overwriting `m_sName`. The same swap in the inverse direction avoids that
  native defect. If the original equipment slot is empty and the source backpack
  slot is 18, an empty resref lets the native first-free-backpack path restore it.
  Private candidates were followed by final integrated-product retests:
  `final-swap-occupied-4` (374 ticks/6352ms) and `final-swap-empty-4`
  (376 ticks/6345ms), each 8 casts/0 skips and observed through +680 ticks.
  `open-swap-stop-4` stopped during use at +220, restored rate30 and original
  equipment; a separate API probe confirmed an empty journal and original weapon
  selection. No validation or item-identity guard was removed.

Native built-in `RunAll()` also exposed fixture issues: inherited search/QC
preferences, Project Image assumptions and a fixed reference-install duration.
The fixtures now isolate/restore relevant state and read the actual child-spell
layout. The UI lab's final RunAll passed with its search and FastForward 4 retained.
Its warnings (one caster, absent items/variants and other live probes) remain;
many phases are synthetic even when run inside the game.

### Completed interruption and compatibility matrix

| Case | Actual native result |
| --- | --- |
| `variant-pause-4` | 1501ms paused with unchanged game tick, cast timer and resources; resumed only by the harness, then completed and restored30. |
| `variant-stop-4`; `mixed-stop-restart-4` | Stop restores30; the already-running cast may finish but no later chain step starts. Immediate restart ignores the previous run's delayed callbacks. |
| `preset-qc-long-2`; `preset-qc-all-4` | Saved QC1/2 preserved; no QC helper action/effect; ordinary game-time aura spacing. |
| `preset-baseline24-2`; `mixed-external-4` | 24→48→24; an independently changed rate47 is retained instead of overwritten. |
| `mixed-modal-4`; `mixed-dialogue-4` | Native popup/dialogue stops acceleration and restores30; dialogue pause remains. These finish at the transition, not after a long tail observation. |
| `open-enemy-entry-4` | Native visible-enemy counts become1 for all three party members; combat stop and rate30 at +23, no later chain steps through +180. |
| `open-load-4`; `load-post-state.json` | Actual queued Load UI completes; subsequent snapshot has baseline resources, idle actions, no active Fast run and rate30. No claim of continuous observation during loading. |
| `open-exit-corrected-4`; `exit-post-state.json` | Actual Options→Quit→MainMenu sequence completes; WORLD disappears, START_MAIN is present, Fast is inactive, rate30. |
| `open-late-ally-4` | Native allied creature joins; two real additional spell actions/debits/effects, total10/0, 353ticks/5998ms, rate30 through +680. EA4 is established by fixture bytes; native ally scan establishes the accepted EA band, not a logged exact EA value. |

Buff duration checks compare actual effect sources and absolute expiry at equal
game time, not only displayed labels. Bless naturally expires during observation;
longer buffs remain with expected remaining time. These are bounded observations
of the listed spells, not a complete catalogue or repeated statistical timing study.

Final screenshots are native renderer captures from the hidden desktop. The fresh
1024×768 panel shows three tabs, ten rows, Speed4x, suspended QC and actual `Done`;
the case-insensitive search image shows only Armor. The wide panel and named HUD
popup are readable at 1920×1080. An intermediate HUD image (`final-ui-hud.png`)
exposed a stale START_MAIN layer left by the private start harness; it is retained
as diagnostic evidence. After removing that layer, `final-ui-hud-world.png` shows
the popup over the actual world. No BuffBot fix was inferred from that harness issue.

Other invalid or failed harness attempts remain explicit: `mixed-equip-4` passed
the invalid mode `equip` and therefore demonstrates inventory use only; the valid
mode is `swap`. The first exit attempt supplied a label instead of the required
save hash and was rejected before any exit action (`exit-harness-revision-error.json`).
The corrected exit case above is the acceptance evidence. The original private
area startup failure was corrected by registering its master area before testing.

The final runner (`CLEAN/native-run-4.json`) ended after1333.6s with
`tripped=false`, `guard_error=null`, audio peak0, unchanged pointer clipping and
`left_in_job=[]`; slot1 was released at2026-10-22 00:00 KST. All owned labs are
stopped. Production game files, user saves and unrelated WIP were not deployed to
or modified. `final-evidence-manifest.json` captures the final product hashes and
evidence. The final executor was force-loaded from the repository source during
the tests, then copied to the lab's disk before shutdown; the runtime receipt names
the source and confirms final rate30, readable character name and no swap journal.

### Remaining limitations

- The 430-inclusive stack remains unaccepted. The explicitly selected stack
  without430 is covered above; this does not erase the earlier 430 failure.
- BG:EE and experimental 5E acceleration are outside the current task. Broader
  untested mod combinations are not implied by the bounded full-stack cases.
- No exhaustive item/spell catalogue, natural damage-induced casting-failure
  matrix, in-progress swap save/reload cycle or multiplayer run was performed.
  Save/reload journal recovery and multiplayer refusal have offline coverage.
- An earlier EEex 2DA finalizer warning (`Destruct` missing) remains unexplained;
  it is separate from the proven XEquipItem array overwrite and is not declared fixed.
- No commit, push, deployment to the production install or release was performed.

## Historical offline snapshot before this local continuation

Command: `python -m pytest -p no:faulthandler tests -q --tb=short`

Result: **1004 passed, 19 failed, 9 setup errors** in 71.59 seconds.
All 28 unsuccessful cases are in `test_release_package.py`:

- 23 cases cannot start Git Bash: exit `3221225794` (`0xC0000142`), with no
  shell output. This prevents the release/deploy shell checks from running.
- Five cases cannot create their required symlinks: Windows error 1314.

At that earlier checkpoint these cases were unverified; they were not skipped or
weakened. The current session subsequently ran them, as recorded above. The remaining
tests, including direct WeiDU installer checks, passed. The three new combination
suites contribute **242 passing cases**: 74 execution, 126 UI/start-path and 42
buff/item-detection cases. All 14 runtime Lua modules also compile with LuaJIT;
`git diff --check` reports no whitespace errors.

## Historical evidence and limits

The automated checks execute the actual Lua modules through LuaJIT, with synthetic
EEex records and mocked native actions. They establish queue, dispatch, identity,
and cleanup behavior. They do not establish actual engine speed, spell/aura timing,
native charge consumption, rendered layout, or compatibility with every mod setup.

No game was launched or deployed to during that earlier test pass. The quiet lab manager's
read-only status showed five free slots, but that session could not write its required
central coordination directory or the separate Documents game profile. The prescribed
runner and coordination mechanism were kept intact. It produced no screenshots.
The continuation verified write access to `%USERPROFILE%\.codex\coordination` and
the disposable lab's own `Documents/<engine_name>` profile, in addition to its
game clone. The existing profile folder is redirected through OneDrive on this PC.

The existing target lab contains engine 2.7.3.0 and EEex 1.3.1. Its EEex source
confirms the simulation-rate property, game-time field, destroyed-session listener,
and generic modal predicate used by the implementation. This is source evidence,
not native execution evidence.

## Offline combination coverage

| Area | Variations | Assertions |
| --- | --- | --- |
| Start paths | Party panel, character panel, HUD preset, F12; Normal/2x/4x; QC Off/Long/All; one/six party members | Correct preset queue, saved QC retained, acceleration suppresses QC, refusal does not fall back to QC |
| Execution | Two casters; mixed short/long spells and items; repetitions; already active effects; nonstandard baseline speed | Manual order retained, live availability rechecked, unchanged caller queue, original rate restored |
| Interruption | Stop/restart, stale and duplicate callbacks, combat, dialogue, world exit, load callback, watchdog, long pause | No old callback advances a new run; rate released on termination; pause remains resumable |
| Failed startup | Missing module, unsupported rate, missing engine state, throwing dispatcher, partial/clamped rate write, temporarily unavailable restoration | No unintended QC fallback; partial rate write rolled back; failed restoration retains ownership and blocks another start |
| Items and active buffs | One/two child levels; caster/fixed levels; case variations; shared SPLSTATE; independent powers; exhausted/interactive powers | Correct metadata and source identity; distinct item powers remain separate; preflight preserves charges |
| Search and presets | Empty/no-match query, filtered edits, different preset owners, busy/stale menus | Filtering preserves the complete preset queue; actions address the intended row/owner |

The repeatable additions are `test_fast_forward_matrix.py`,
`test_quick_access_matrix.py`, and `test_buff_detection_matrix.py`, plus focused
regressions in `test_fast_forward.py` and existing executor tests.

An additional read-only data smoke check decoded eight actual lab items and their
linked SPLs: AMUL15, AMUL26, BDCLCK05, BDROBE01, BDSHLD02, BDSTAF03, BOOT12, BRAC16.
Seven were classified as buffs; BDROBE01 remained a supported manual candidate.
This used synthetic sprite/charge records and was not a live item-use test.

## Earlier implementation defects fixed offline

- Give execution callbacks unique tokens so a stopped run's queued callback cannot
  advance or prematurely complete a new run. Reject duplicate callbacks too.
- Remove the unconditional two-minute wall deadline. The executor's existing
  game-time progress watchdog still handles stalled casts, including rate cleanup.
- Refuse accelerated F12 starts when the speed module is absent or incomplete,
  rather than falling back to saved Quick Cast or a raw nil-call error.
- Roll back the actual rate observed after a failed startup write, including
  simulated setter clamping and write-before-error behavior. Native setter clamping
  itself has not been demonstrated.
- Check the engine-wide modal predicate when exposed by EEex, alongside existing
  named-menu and input-mode guards. Older bindings retain those latter guards.

## Native workflow and original acceptance checklist

Continuation handoff: the user has explicitly authorized these background game
tests. Preserve the current uncommitted implementation and existing unrelated
files. Use the completed-case evidence and limitations above; offline success alone
does not establish additional native cases. Check actual current access rather than inheriting old session assumptions.

Use a disposable, muted, hidden-desktop lab through `bg_lab_slots.py` and
`lab_quiet_run.py`, with its own engine name and Documents profile. Use the same
prepared save for each comparison and reload it before each run.

Read the authoritative lab instructions at
`%USERPROFILE%\.codex\coordination\README.md` and the bg-modding skill first.
The runners are in
`%USERPROFILE%\.codex\artifacts\next-batch-20261013\lab-tools`.
A historical full-stack source template is
`%USERPROFILE%\CEBG-Tests\EEex131-Lab-20261018b\game`; its experimental hooks
are now a documented blocker, not a clean baseline. Inspect current state before
cloning. Use a separate clone/profile, not Chris's live game. Check for
pending remote commands before launching. Establish the necessary write access
and native-process permissions before preparing or launching the lab, retaining
all central coordination and quiet-runner guards.

1. Compare Normal with QC Off against 2x and 4x, holding preset order, targets and
   starting resources constant. Record wall duration, game ticks, spell slots,
   item charges and remaining effect times. Compare effects at equal game time.
2. Repeat with saved QC Long/All and verify acceleration suspends it without
   modifying the stored setting. Include two simultaneous casters, single-target
   and party buffs, item powers and configured spell variants.
3. Exercise pause/resume, manual Stop followed immediately by restart, enemy entry,
   dialogue, loading and leaving the world screen. Inspect both the simulation
   rate and any still-pending native actions after each transition.
4. Test inventory use and temporary equipment swaps, summons/late joins, and the
   experimental 5E wrapper/refresh path separately. The old `ReallyForceSpellRES`
   variant path was a reproduced defect; evaluate the corrected action 191 path
   against actual native time, resource flags and delivered effects.
5. Capture the search row, speed control and named preset menu at normal and wide
   resolutions using the engine's `Infinity_TakeScreenshot()` on the hidden desktop.

Native acceleration has the bounded measured evidence recorded above. The listed
configuration limits remain separate from the completed clean-BG2 matrix.
