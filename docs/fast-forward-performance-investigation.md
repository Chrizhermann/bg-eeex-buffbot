# Fast-forward speed and unintended serial casting

20 October 2026. Native tests use the disposable EET spell lab. The user's
recording is `2026-10-20 21-47-41.mp4` (35.88 seconds). The personal installation
is unchanged. The user's running test game was not reloaded or stopped.

## Findings

Two separate problems explain the reported behavior:

1. A real scheduler regression serialized normal/fast-forward plans containing
   a shared item. It is fixed.
2. The earlier speed plateau was not a demonstrated hard engine cap. Rendering
   consumed enough of the update loop's budget to impede faster simulation.
   A temporary render ceiling unlocks a substantial 4x-mode gain in this lab.

## Why casting became one at a time

The shared-item coordinator receives the entire queue when any entry requires
borrowing gear. Its `startEntry()` batched independent entries only when
`run.qcMode == 3` (Balanced Quick Cast). Fast-forward deliberately calls the
normal executor (`qcMode == 0`) so it does not use acceleration helpers or
duration edits. Consequently, that coordinator dispatched a single entry,
waited for it, and then dispatched the next—even when they had different casters.

This matches the video and the user's execution log, which repeatedly reports
`Starting Execution: 1 entries` and `1 casters working in parallel` for ordinary
spells. A plan with no loan bypassed this coordinator and could still run in
parallel; that is why the original simple fast-forward acceptance missed it.

`BfBotShr.lua` now groups independent native actions in normal mode as well.
Balanced timing-model barriers no longer impose global waits on normal casting.
Each native caster sequence still waits for its own action/aura rules. Physical
loans retain their real transfer/use/return boundary. This is not permission to
cast two ordinary spells simultaneously with one caster or bypass aura rules.

Native acceptance uses a five-entry plan with two casters before a loan and two
after it. Both normal and fast-forward produce batches of **2 / 1 / 2**, five
casts, zero skips, boots returned to slot 22, no remaining journal and restored
simulation rate. Callbacks from the short lane arrive before the other lane
finishes, rather than forcing every source through one global sequence.

Evidence: [native concurrency records](visual-review/evidence/fast-concurrency-native.json).

## Why 4x previously resembled 2x

The speed control changes `EEex_CChitin.TIMER_UPDATES_PER_SECOND`. Normal rate
30 corresponds to approximately 15 game ticks per real second. Requested rates
60 and 120 aim for approximately 30 and 60 game ticks per real second.

The local EEex `uncap_fps.cpp` source separates full simulation updates from
render updates, but they still share the main loop and execution budget.
Late full updates affect subsequent scheduling. Rendering is not free just
because the simulation rate is independently configurable.

The EEex UI's AI-speed option accepts up to 90; its startup configuration check
resets a stored value above 90. That is a configuration guard, not proof that a
temporary runtime value of 120 is ignored. The runtime tests read back 120 and
can achieve close to its intended rate after reducing rendering work.

### Controls, not just plan completion time

The initial valid idle samples with ordinary rendering were:

| Requested update rate | VSync on: game ticks/s | VSync off: game ticks/s |
|---:|---:|---:|
| 30 | 14.79 | 14.75 |
| 60 | 28.30 | 28.39 |
| 90 | 33.60 | 33.20 |
| 120 | 33.47 | 33.68 |

Changing the EEex busy-wait threshold from 1 to 0 also left rates 90/120 around
33 game ticks/s. Bringing the private game to the foreground did not remove
the plateau. Those results do not support blaming VSync alone, the tested
sleep threshold alone, or background-window status alone.

Native per-update logic samples were generally below 1 ms in the background
control, and about 2.6–2.9 ms in the foreground control. These fields are rounded
and sampled on game-tick changes; they are not complete CPU/GPU profiles.
EEex's built-in graphs separately showed render work commonly around 10–30 ms.
The profiler window adds overhead and is excluded from the final cast benchmark.

### The successful intervention

Using EEex's existing render limiter, independently of simulation rate:

| Requested update rate | Render ceiling | Observed game ticks/s |
|---:|---:|---:|
| 120 | 60 FPS | 51.20 |
| 120 | 30 FPS | 57.19 |
| 120 | 15 FPS | 58.24 |
| 60 | 30 FPS | 29.74 |

This demonstrates that the tested installation can run substantially faster
than the earlier plateau. Reducing render frequency leaves room for the native
simulation. It does not prove which portion of rendering—UI Lua, drawing,
driver behavior or presentation—dominates on every installation. Multiple game
processes were running, so these are session-specific measurements.

The 15 FPS control adds little over 30 while visibly reducing animation cadence.
We therefore use 30 as the temporary fast-forward ceiling. A player's existing
lower enabled ceiling is preserved. We do not change VSync, driver settings,
permanent graphics preferences, EEex files or the engine binary.

Early diagnostic attempts sampled a paused world and yielded zero game-time
progress. They were discarded. The valid matrices explicitly record unpaused
state and positive game-time progress.

Evidence:

- [Rate and VSync matrix](visual-review/evidence/fast-rate-diagnostic.json)
- [Sleep-threshold matrix](visual-review/evidence/fast-sleep-diagnostic.json)
- [Foreground control](visual-review/evidence/fast-rate-foreground.json)
- [Render-ceiling control](visual-review/evidence/fast-render-cap-diagnostic.json)

## Shipping behavior and actual casting comparison

`BfBotFst.lua` captures the existing numeric FPS limit and its enabled state,
temporarily enables a ceiling of 30 FPS (or a lower pre-existing enabled limit),
and restores both afterward. Restoration does not overwrite an independently
changed setting. Missing optional render controls leave the underlying speed
mode functional. The existing completion, Stop, combat and lifecycle cleanup
paths release this temporary setting along with simulation speed.

The same three-cast, two-caster plan with the shipping implementation:

| Mode | Wall time | Game ticks | Casts / skips |
|---|---:|---:|---:|
| Normal | 9.076 s | 133 | 3 / 0 |
| Requested 2x | 4.740 s | 133 | 3 / 0 |
| Requested 4x | 2.576 s | 133 | 3 / 0 |

That is approximately **1.9x** and **3.5x** realized speedup. Both accelerated
runs read back successful restoration of simulation rate and render settings.
Native component lifetimes and the same game-time progression remain intact;
there is no Quick Cast helper or duration compensation in these runs.

Evidence: [casting comparison](visual-review/evidence/fast-render-cap-casting-native.json).

## Recommendation and limits

Keep 2x as the conservative starting choice. 4x is now a meaningful option in
the tested installation, rather than a nearly equivalent setting. Neither is a
universal performance guarantee: heavier areas, scripts, effects and hardware
can change the achieved rate. Existing saves retain their selected mode.

The native engine still processes the normal work. We reduce unnecessary render
work; we do not manufacture extra CPU capacity or remove native casting waits.
The physical loan boundary remains deliberately serialized. This pass does not
claim globally optimal just-in-time scheduling, a full GPU profile or a new
guarantee for every periodic/delayed effect and campaign event.


## Final verification

Full regression: **1,214 passed, five deselected** (Windows symbolic-link privileges). Separate checks after adding this report to the release allowlist: **27 passed, five deselected**. Native Stop/combat controls also read back restoration of the original numeric render limit and disabled flag; the recorded hostile response was 46 ms. The final native readback is rate 30, render limit 144 disabled, busy-wait threshold 1, no active fast run, loan or recovery journal.
