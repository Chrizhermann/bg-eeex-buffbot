> Historical research: this prototype was removed on 2026-10-20. The recipient planner now uses native casting at 2x/4x/Normal speed.

# Balanced Quick Cast: observation-only tools

Checkpoint: 2026-10-19. These development tools are tested offline and are not
installed, hooked, or loaded by BuffBot. This document describes a future
controlled native session; it is not evidence that one has occurred.

## Purpose and boundary

Collect plain snapshots that let us investigate:

- what effects were already present before a cast;
- when new effect records were first observed, including immediate child spells;
- whether source ID, source resource and recipient narrow the possible cast;
- where repeated casts, changed records and reused addresses remain ambiguous;
- raw action IDs and raw effect timing fields, without assuming their meaning.

The observer does not cast spells, change effects, install engine hooks, draw
UI, write files, infer aura readiness, or prove effect ownership. It never emits
`owned=true` or a duration correction. Its export always reports
`ownershipProven=false` and `mutationsPerformed=0`.

## Files

| File | Role |
| --- | --- |
| `tools/research/balanced_capture.lua` | Explicit synchronous native read adapter |
| `tools/research/balanced_observer.lua` | Pure ledger over plain snapshots and explicit markers |
| `tools/research/balanced_timing.lua` | Independent scheduling/arithmetic model; not wired to observer output |
| `tests/test_balanced_observer.py` | Mocked native reads and pure ledger regressions |

Loading the files only returns module tables. No function executes until the
caller invokes it. The release builder, installer and bootstrap do not reference
these tools. No research code was copied to either game installation for this
checkpoint.

## Captured data

`Capture(epoch)` requires a nonempty caller-supplied load-generation token. It
returns:

```lua
{
  epoch = "load-generation-1", tick = gameTick, complete = true,
  actors = {
    { id = objectId, slot = portraitSlot, name = displayName,
      actionId = rawCurrentActionId,
      effects = {
        { token = numericAddressAsString,
          sourceId = sourceObjectId, sourceRes = sourceResource,
          opcode = rawOpcode, timing = rawTiming,
          rawDuration = rawDurationField,
          param1 = rawAmount, param2 = rawFlags,
          sourceType = rawSourceType, resource = rawResource }
      }
    }
  }, errors = {}
}
```

The address is an opaque observation token. It is never converted back to a
pointer or dereferenced later. There is no promise that an address is stable or
unique over time. All sprite/effect userdata stays local to the synchronous read;
exports contain only strings, numbers, booleans and tables.

Unnamed administrative effects stay in the baseline with an empty source
resource. They cannot match a cast's required nonempty resource set. Raw timing
and duration values are retained without converting them into remaining seconds
or deciding whether they encode an absolute expiration.

The action ID read is supported by usage of `m_curAction.m_actionID` in the
installed `EEex_Sprite.lua`. The effect fields match existing installed EEex and
workspace diagnostic reads. This is source evidence for the read approach, not
native acceptance of this adapter. A Lua `pcall` does not prevent a native access
violation: invoke capture only on a valid game-thread/world-state boundary,
resolve fresh objects, and never run against freed userdata.

If required APIs or fields are unavailable, any read fails, the effect cap is
exceeded, or the clock changes during the synchronous capture, the result has
`complete=false` and an error. Partial data is diagnostic only and cannot seed or
advance a ledger. No guessing or silently dropping an unreadable effect.

## Session operations

`New(runId, baseline)` copies a complete validated baseline into a pure session.
Subsequent input mutation cannot alter the stored evidence.

`BeginCast(spec)` describes an **observation window**, not an engine action:

```lua
{
  id = "cast-1", sourceId = actualCasterObjectId,
  targets = {actualRecipientObjectId},
  resources = {"PARENT", "CHILD"},
  tick = latestSnapshotTick
}
```

The actor IDs must exist in the observed party. The resources must be the exact
parent/child resources under investigation, not broad spell-name matches. Each
window needs a unique ID and a same-tick baseline. Source assignment and resource
discovery remain the planner/scanner's responsibility. Self-only and AoE rules
are not reimplemented by this research ledger.

`Sample(snapshot)` copies a complete observation, stores it and returns deltas:

- `newly_observed`: a token absent from the preceding snapshot;
- `changed_or_reused`: the same token with a changed semantic fingerprint;
- `removed`: a previously observed token is no longer present.

Duration-only changes are retained in the raw sample, but do not count as a new
effect: the raw field might naturally count down or mean something else.

Each new/changed record includes the matching cast-window IDs, recipient, interval
`[fromTick,toTick]`, ambiguity flag and reason. This is a sampling interval, not an
exact arrival timestamp. Matching uses caster object ID, source resource and
recipient. Resources are compared case-insensitively.

Even a unique matching window has `ownership="unproved"`. A record might have
been replaced at the same address with the same fingerprint between samples;
another subsystem might have cast the same resource. A snapshot diff cannot
exclude those cases.

`Phase(castId, label, tick)` records an explicit controller-supplied `release`,
`ready` or `closed` observation at the latest sampled tick. It does not detect the
event itself. Release must be marked before ready/closed. Closing a delivery
window does not forbid recording a later aura-ready marker. Candidate filtering
retains any window that overlaps the full sampling interval, including a window
closed between snapshots. It does not falsely discard a possible cast merely
because the final sample is later than the close time.

Do not feed these window-open/phase labels or first-observed delivery times into
the scheduling model as exact engine measurements without establishing their
meaning and precision. In particular, queuing `SpellRES` is not cast start;
following it with `_Advance` is not successful effect delivery.

`Stop(reason)` is terminal. `Export()` returns a deep copy of baseline, raw
samples, cast markers, deltas and status. It does not serialize or write a file;
the existing controlled diagnostic harness may serialize that plain export.

## Conservative limits and invalidation

- At most six observed party actors, 256 cast windows and 32 resources per window.
- At most 4,096 effects per full snapshot, 512 stored snapshots, 32,768 retained
  effect records in total and 2,048 deltas per session.
- Reject sparse lists, duplicate actors/slots/tokens, invalid numeric fields,
  missing targets, duplicate cast IDs and markers without a current baseline.
- Stop on a changed epoch, clock rollback, changed party identity, incomplete
  sample or evidence budget exhaustion. No partial sample is committed on failure.
- Reappearing tokens and changed existing tokens remain explicitly ambiguous.

These are bounded research captures, not a production every-frame observer. A
large party effect list may exhaust the retention budget quickly. Collect short
focused samples around one/few casts; do not increase limits to hide that issue.
Actual native callback cost and collection cadence remain unmeasured.

The controller **must** advance the epoch on load and stop the session before
save/load, stop/combat abort or scene changes. A fixed epoch supplied manually
cannot detect a reload that reuses the same IDs, names and clock values. The
current tools deliberately do not install lifecycle or render listeners. A future
controller needs explicit, tested lifecycle integration before unattended use.

## Future controlled native procedure

1. Use the isolated copy and a known copied save. Verify the world is valid and
   the observer is invoked at the appropriate game-thread boundary. Load the two
   module factories through the diagnostic harness, with no automatic installer.
2. Capture and export a baseline without casting. Confirm all fields/types and
   the clock are read correctly; compare with the existing effect viewer.
3. Start one short ledger. Sample immediately before the legitimate normal
   executor queues one chosen spell; open the exact observation window. The
   observer itself must not issue the action.
4. Observe action transitions and effect-list changes. Only mark release/ready
   when independently verified. Do not guess aura state from an idle action ID.
5. Stop and export. Compare a known pre-existing buff, a new direct buff, a
   repeated cast, a wrapper child and a projectile in separate sessions.
6. Repeat the same cases under the retained accelerated cast path. Compare spell
   usage, animations, action timing, delivery intervals and effect components.
7. Validate load/abort invalidation in a separate session. No lifetime writes
   belong to any of these steps.

When these observations establish a reliable delivery/ownership method, design
the separate duration adapter. Until then the observation-only tools are not a
permission or a mechanism to alter buffs.
