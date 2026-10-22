> Historical research: this prototype was removed on 2026-10-20. The recipient planner now uses native casting at 2x/4x/Normal speed.

# Balanced Quick Cast: offline feasibility checkpoint

Update, 20 October: the scoped direct-spell runtime beta is now implemented and
native-tested. See [the current feature guide](plan-management-and-casting-beta.md).
The remainder of this document preserves the earlier offline checkpoint and its
broader research questions; statements about an uninstalled model describe that
checkpoint, not the current direct-spell beta.

Reviewed 2026-10-19 against this fork and the EEex Lua scripts installed in the
isolated EET copy. No game windows, input, casts, rest events, live effect writes,
or installation changes were used for this checkpoint.

**Recommendation:** pursue a narrowly supported, visibly accelerated casting
beta. The scheduling and accounting are tractable. Universal duration correction
is substantially harder than the scheduler, and is not established by this audit.
Keep normal casting available for unsupported plans until the engine gates below
pass. Do not remove normal-mode support or advertise a balanced default yet.

## What exists now

- The recipient planner assigns concrete casters and reserves uses, then builds
  the existing executor queue. Recipient `Cast()` currently passes quick-cast
  mode **0**. No compensated quick mode is enabled in the new interface.
- The retained executor already has parallel per-caster queues and toggles its
  quick-cast helper around eligible spells. Items explicitly bypass this helper.
- `BFBTCH` is generated with opcode 188 aura cleansing and opcode 189 casting-time
  reduction. It is removed with `BFBTCR`. Cleanup also runs on stop/watchdog/orphan
  paths. This gives us a reusable acceleration mechanism, not proof of balanced
  durations or preserved presentation for every spell/variant.
- Ordinary spells use `SpellRES`; variants debit a parent slot and issue
  `ReallyForceSpellRES` for the selected child. These paths must be measured
  separately. Merely reaching `_Advance` is not proof that a projectile landed.
- Active-buff checking walks timed effects by source resource, optionally with
  opcode/state signatures. This answers an existence question. It does not
  identify a new effect instance or prove that it belongs to this run.
- The scanner's displayed duration comes from the maximum qualifying gameplay
  duration in a bounded resource walk. A single cast may create several effects
  with different durations. The display value cannot be written back to every
  effect as its duration.

Source anchors:

| Local source | Relevant behavior |
| --- | --- |
| `buffbot/BfBotPUI.lua`, `CanCast` / `Cast` | Fresh validation and normal recipient queue |
| `buffbot/BfBotExe.lua`, `_BuildQueue` / `_ProcessCasterEntry` | Per-caster ordering, item exclusion, helper toggles, variant path |
| `buffbot/BfBotExe.lua`, `_GetGameTime` / `_HasActiveEffect` / `_HasActiveStateMarker` | Game clock and existing effect discovery |
| `buffbot/BfBotInn.lua`, `_BuildCheatSPL` / `_BuildCheatRemoverSPL` | Existing accelerated casting helper and remover |
| `buffbot/BfBotCls.lua`, `GetDuration` | Maximum-duration catalog summary, not per-instance lifetime |
| Installed `EEex_scripts/EEex_GameObject.lua`, `EEex_GameObject_ApplyEffect` | Documented effect source ID/resource and duration inputs |
| Installed `EEex_scripts/B3EffMen.lua`, effect-list iteration | Source resource/type, timing mode and caster-level reads |
| Installed `EEex_scripts/EEex_Opcode.lua`, lists-resolved listeners | Candidate observation callbacks; not a per-cast ownership guarantee |

The installed EEex scripts provide evidence for observable fields and callback
availability. They do **not**, by themselves, prove that mutating an active
effect's expiry in a callback updates every engine subsystem safely. The expiry
representation, timing flags, write lifecycle and removal semantics are separate
native acceptance gates. No new engine API is assumed or added by this prototype.

## Independent-caster schedule

The prototype in `tools/research/balanced_timing.lua` accepts **measured integer
ticks**, not guessed casting-time formulas. For each cast it takes:

- start-to-release time;
- start-to-next-action-ready time, including relevant aura/animation gates;
- release-to-delivery time.

An optional measured initial-ready time per caster accounts for a pre-existing
aura/action gate. The schedule cannot start that caster before it is ready.
Missing initial-ready data defaults to an idle caster, an explicit modeling
assumption rather than a guarantee about the current game state.

For each caster, retain the request order and start each next action when the
previous action's supplied ready interval ends. The lane finishes when all of
its effect deliveries have arrived. Translate each independent lane so its
last delivery reaches a common finish.

Example, using seconds only to make the example readable:

| Caster | Local cast completions | Start offset | Aligned completions |
| --- | --- | --- | --- |
| Mage | 10, 20, 30 | 0 | 10, 20, 30 |
| Cleric | 5, 10 | 20 | 25, 30 |

An early projectile can arrive after a later self buff. Completion therefore
uses delivery, not merely the last spell release. No trailing cooldown is added
to preparation time when no further buff needs to be cast. The final aura state
still matters to what the player can do next; reproducing that state is a
separate engine/balance question, not a reason to age buffs an extra round.

This model is linear in requests and caster lanes. It rejects items and explicit
dependencies rather than claiming an optimal result for them. A shared item,
movement, a prerequisite buff, or an earlier spell that changes later casting
speed breaks the assumption of independent, fixed-cost lanes. Source assignment
must happen before timing; an explicit caster change requires a new schedule.

The mathematical result is optimal within this fixed independent-lane model.
It is not proof of globally optimal gameplay or a calibrated engine simulation.

## Correct duration accounting

For one finite **effect instance** produced by this run, define:

- `D`: that effect's original lifetime;
- `T`: normal reference preparation finish;
- `v`: reference delivery time for this effect;
- `F`: actual accelerated preparation finish;
- `a`: actual delivery time for this effect.

Then:

```text
virtualAge       = T - v
realAge          = F - a
idealRemaining   = max(0, D - virtualAge)
currentRemaining = max(0, D - realAge)
expiryShift      = idealRemaining - currentRemaining
```

Before expiration clamps matter, `expiryShift = realAge - virtualAge`.
Subtracting `virtualAge` from the already-aged remaining lifetime would count
real elapsed time twice.

Example: a 100-second buff should have aged 20 seconds in the normal schedule,
but has already aged 3 seconds while the accelerated animation sequence ran.
It currently has 97 seconds; the correct target is 80, so subtract **17**, not
20. For the cleric's last buff in a just-in-time reference, virtual age is zero.
If it really landed five seconds before the animated run ended, exact agreement
requires adding those five seconds back to that **new** effect.

The prototype exposes both policies:

1. Exact arithmetic for a still-live, attributed new effect, including extension
   when explicitly allowed. Engine-safe extension still needs proof.
2. Conservative correction that never extends. It records that remaining time
   differs from the ideal result instead of calling it exact equivalence.

Unattributed/pre-existing effects are untouched, as requested. They age only
through actual game time. Permanent effects are untouched. Delayed/unknown timing
modes are rejected. Expired effects are never recreated to repair the result.
An effect that would already have expired by the reference finish has zero target
remaining time; correctly removing its gameplay effects needs native proof.

Use the game clock throughout. Wall time, UI time and pauses are not appropriate
units. The seconds/ticks conversion, expiry units and wrap behavior must be
verified at the native boundary rather than inferred from the catalog's seconds.

## The ownership problem

A final loop over all effects whose resource name matches a planned spell is
unsafe. It could alter a buff already active before the run, a cast by another
actor, a later repeat, or a child effect that arrived after a callback. Source
resource + source object ID helps narrow candidates but does not uniquely identify
one cast. The same caster can cast the same spell twice.

Before any effect writes, build an observation-only ledger:

1. Allocate a transient run ID and cast ID after final source/target resolution.
2. Record numeric identities and plain data before/after each delivery window.
   Re-resolve sprites each time; do not retain effect/sprite userdata across
   callbacks, save/load or waits.
3. Observe actual effect arrivals, removals and replacement behavior, including
   AoE recipients and immediate child spells. Map each to a single cast token
   only when unambiguous. Do not assume a pointer remains stable or is never reused.
4. Prove that existing instances survive unchanged when the same spell is cast
   again, or detect replacement and decline correction when ownership is unclear.
5. Stop observations on stop/load/death and handle late projectiles explicitly.
   If the run aborts, no duration mutation has happened during this observation phase.

After the ledger is proven, test a separate adjustment adapter on a tiny supported
set. A table diff may be sufficient for some direct effects; callback ordering,
pointer reuse, replace/refresh behavior and deferred children prevent declaring
it universally safe from source inspection alone.

## Recommended beta boundary

First candidate: single-player party spells using the existing accelerated
action path, with finite direct effects, verified ownership and delivery, fixed
casting-speed state during the sequence, and a complete supported plan. Preserve
the current visible engine casting/effect path where native comparison confirms
it. Do not replace normal spells with bulk raw effect application.

Initially exclude duration rewriting for item transfers, item uses, 5E wrappers,
summons/clones, delayed/repeating triggers, sequencers/contingencies, external EFF
graphs, transformations and effects with irreversible/periodic side effects.
These are conservative research exclusions, not claims that all are impossible.
Party-wide delivery and immediate child spells should be measured before adding
them. Spell Immunity's forced-child action requires its own timing/presentation
check before it joins the beta.

If any requested cast is unsupported, use a clear whole-plan normal-casting
fallback for the first beta. Mixing compensated and ordinary lanes introduces
another reference-timeline problem; silently skipping adjustment is not balanced.
Manual user overrides should remain available; unsupported reasons must be concise.

Do not infer safe correction from automatic buff classification. A spell can be
useful as a buff while also healing, damaging, spawning objects, changing gear,
removing effects, changing casting speed, or scheduling work later. Lifetime
rewriting alone cannot undo those events or reproduce what expired earlier.

## Ordering and “smart” suggestions

Keep explicit user order. Long-duration-first is a reasonable starting heuristic
for independent ordinary buffs, not a general optimality theorem. Timing costs,
prerequisites and caster-specific resources can change the result. Also, the
automatic source that maximizes duration may be slower or needed elsewhere; do
not quietly turn the existing allocator into a joint schedule optimizer.

A later smart-order suggestion can operate on each caster lane and show predicted
remaining duration. It should not be confused with the browser's duration sort.
Self-buffs that change casting speed or caster level require stage-by-stage
recomputation or exclusion; reading one pre-run stat does not cover them.

## Engineering cost and next gates

| Work | Assessment | Current evidence |
| --- | --- | --- |
| Independent lane scheduling / JIT alignment | Small and bounded | Offline Lua model and regression cases |
| Per-effect arithmetic including actual time | Small | Offline cases cover double-aging, extension, expiration and preservation |
| Normal timing adapter, Vecna/Amulet/IA state | Moderate; engine-dependent | Not calibrated; no raw casting-time formula adopted |
| Attribution and lifetime mutation for simple direct spells | Main uncertainty; moderate research effort | Read APIs exist; safe ownership/writes unproved |
| All modded spells/items and special side effects | Large compatibility effort | Outside initial beta |

There is no evidence here that this needs an expensive optimization solver or
high continuous CPU usage. There is also no native performance measurement for
the proposed observer. Avoid scanning every creature/effect on every render or
global lists-resolved event: filter to active run participants and bounded
delivery windows, then measure actual callback volume and cost.

Native session, when convenient:

1. Observe ordinary casts and accelerated casts, without rewriting effects.
   Record start, release, next-ready and delivery against game ticks, along with
   effect identity/fields and spell-use consumption.
2. Compare no speed gear, Vecna, Amulet of Power, their combination, existing IA,
   and a two-caster 30/10-style plan. Record animation continuity separately from
   action completion. Measure residual aura after helper cleanup.
3. Test a repeated same-spell cast with a pre-existing copy, direct versus child
   delivery, a projectile, mixed-duration components and party-wide recipients.
4. Prove one finite effect's shortening/expiration and, separately, extension.
   Check actual gameplay state, not just a changed numeric field or an icon.
5. Test pause, stop, combat interruption, save/load and late delivery. Re-scan and
   rebuild if availability skips change the actual executed set; the reference
   plan must not count a spell that was never cast as an elapsed preparation cost.
6. Only then connect the adapter to normal planner execution behind an explicit
   experimental setting and unsupported-plan fallback.

## Checkpoint result

The audit and dry-run mathematics are complete for this checkpoint. Engine
feasibility remains in progress. The prototype is intentionally outside the
installed `buffbot/` payload and is not loaded by bootstrap or release scripts.
Nothing in current gameplay or GUI behavior changes as a result of this work.

### Observation-tool follow-up

The pure ledger and explicit native-read adapter now exist outside the installed
payload. See `balanced-observer-protocol.md` for their contracts and future usage.
Their 40 mocked/offline regressions pass; the combined timing/observer/planner/rest
selection passes 130 tests. They preserve baselines, expose matching uncertainty,
bound retention and reject incomplete/context-changing observations. They never
claim ownership or mutate effects. No native sample was taken for this follow-up;
the measurement, attribution and lifetime-write gates above remain open.
