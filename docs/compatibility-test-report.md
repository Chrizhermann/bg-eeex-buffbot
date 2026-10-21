# Independent compatibility testing — 20 October 2026

This pass uses disposable EET game copies and copied saves. The personal
installation and Infinity UI++ files are unchanged. The user's running game
was left open. Commands run through a private native Lua harness, without
requiring mouse or keyboard control.

## Implemented

- Allied summons contribute casting sources, including Simulacrum, Project
  Image and Deva. The six party members remain the only recipients.
- Sources retain their actual caster level, duration, charges and native
  casting identity. Each live summon has a separate pool and execution lane.
  Project Image locks its owner before allocation. Missing pinned summons
  remain unavailable; a replacement clone resolves from its owner/type key.
- A caster-centered friendly area projectile can be a single Party row even
  when its SPL header says self. Recognition uses PROJECTL/PRO targeting
  metadata, rather than an English spell-name exception. Existing self-target
  requests migrate without changing their order or caster preference.
- Forced variants consume the shared sorcerer/shaman level pool correctly.
  Native remove/regrant innate behavior is retained.
- Manual Add includes scrolls and wands. Item recognition follows bounded
  child resources. All child-spell levels are checked for interactive pickers;
  those item powers require manual use before any charge or equipment action.
- Equipment returns use inverse equipment swaps or guarded stock inventory
  moves. They never issue an equipment action into a backpack. Native inventory
  and usability routines use portrait order, including parties whose joining
  order differs. Scripted non-droppable copies are rejected before swapping.
- External EFF graphs receive bounded duration inspection. Temporary conjured
  item lifetimes are explicitly conservative; they are not falsely marked exact.
- After Rest waits while any Redux panel, dropdown or dialog is open.

## Native spell and summon results

| Test | Observed result |
|---|---|
| Installed SPL metadata | 6,282 resources, 13,751 ability headers, zero classification errors |
| Installed ITM metadata | 4,281 resources; combined initial SPL/ITM audit examined 5,873 ability headers without classification errors |
| Imported cleric, druid and shaman fixtures | 48 two-cast cases; 96 casts, zero skips |
| Effect expiry corrections | 1,358 writes; every write read back successfully; independent final effect scans found zero expiry mismatches |
| Timing profiles in the 48-case run | 40 exact, eight conservative |
| Sorcerer/shaman shared pools | Two casts reduce all same-level alternatives from three uses to one; four requests for three uses reserve one unavailable request |
| Sorcerer Spell Immunity variant | One selected-school cast, zero skips; every same-level alternative drops from two uses to one |
| Three summoned sources | Three casts, zero skips; Simulacrum Aid 2→1 and Deva Remove Fear 5→4; Project Image retains the installed innate's native remove/regrant behavior; six recipients and nine casters |
| Summon area delivery | One Protection From Evil 10′ Radius cast, zero skips; effects on all six party recipients; 24 verified expiry corrections |
| Completed rest with summons | Actual rest removes temporary summons; six recipients/casters remain; pinned missing summon unavailable; no accidental automatic cast |
| Replacement clone | New object ID resolves through the same saved owner/type key; queued runtime ID matches the replacement |
| Presets and popups | Delete/cancel/last-preset/rest cleanup, new-preset import/export and legacy import pass native callbacks; BG1 wide captures included |
| Rest and open Redux menus | Main panel, dropdown and dialog each block safe-world execution; closing restores eligibility |

The imported fixtures use test-populated spellbooks. They exercise native
class/resource semantics, not a claim that each tested spell belongs to every
class's normal learnable list. The full resource scan is structural coverage;
it does not mean 6,282 spells were cast. Case aliases were normalized before
the final scan. One missing SPL identifier (`CDDETECT`) and a non-resource ITM
marker filename (`DW#MARKER_FILE`) are recorded separately and excluded from
the decoded totals.

Five conjured-weapon cases produced no attributable timed sprite component:
Flame Blade, Spiritual Hammer, Beast Claw, Moonblade and Star Metal Cudgel.
Their temporary weapon lifetime is not adjusted by the sprite-effect ledger.
One additional gap was the Barkskin follow-up in the Champion's Strength case,
where native casting restrictions prevented an attributable new effect. The
audit records these gaps. No effect is manufactured to conceal a missing cast.

## Item and recovery results

The item matrix starts a fresh disposable process and copied save per power.
It checks native eligibility, real activation, consumption/effects, equipment
return and the recovery journal. Failed fixture setups and safe refusals are
kept in the evidence, alongside follow-up tests; they are not counted as passes.

Across 171 powers from 167 distinct items, 167 powers have an observed native
activation with consumption or matching effects. Four powers are verified
manual-only exclusions: the two Undead Grafts and the two non-droppable
scripted Darkfire copies. Follow-ups include legal hand/loadout preparation
and different eligible casters where the original fixture had a conflict.
The final fresh-process controls repeat the ordinary Darkfire bows, boots,
amulets and special exclusions with the shipping code. No native crash occurred
in the 171-power run after the equipment-return fix.

**One caster-specific issue remains open:** Headband of the Devout activates
and restores on Jan, but the Haer'Dalis control stalls in the native child
`ForceSpell` action after spending its charge. The 20-second test stops with
equipment cleanup still waiting. This is retained as a failed control, even
though another caster succeeds; it is not certified compatible on Haer'Dalis.
Stirv's Wrangler also demonstrates why self-incapacitation matters: its
Resilient Sphere prevents the caster executing queued cleanup when cast on
itself. Casting it on another recipient passes and restores the item normally.

Purposeful sharing was retested after the inventory fix: Keldorn and Anomen
each receive the installed Gargoyle Boots Stoneskin child effect, two charges
are spent, the boots return to Keldorn's original slot 22, and both item/loan
journals clear. Native GiveItem may replace a CItem object, so pointer equality
is not used to claim physical continuity across owners. Charge conservation,
unique-resource custody and inventory layout are checked instead. A same-owner
stock inventory round trip separately verifies the identical native CItem pointer.

Stop and a spawned hostile creature both cancel a held loan before activation,
return the boots to slot 22 and preserve both charges. Saving during the actual
loan, terminating only that private test process and loading in a fresh process
also returns the item without spending a charge or restarting the plan.

Two Undead Graft powers select different child-spell headers at higher levels.
Their interactive versions are now detected and refused before movement/use.
COMPB20/COMPB21 are scripted non-droppable Darkfire copies; the ordinary BOW20/
BOW21 versions are droppable. The former require manual equipment, because the
normal engine refuses to remove them after equipping. This is deliberately
different from treating a legal inventory power as unavailable.

## Remaining boundaries

- Conjured weapon expiry, effects delivered beyond the observation window and
  refreshed-in-place effects are not guaranteed to balance. Limited-support
  markers and audit gaps remain visible. Exact vanilla equivalence is not claimed.
- Interactive item selection requires manual use. Normal spell variants remain
  supported independently, including different recipients choosing different schools.
- Headband of the Devout on Haer'Dalis retains the native child-action stall
  described above. Self-incapacitating item casts can also defer cleanup.
- Sharing is for unique, loose, identified, rechargeable multi-charge items.
  Equipped-owner loans, duplicate copies and summon inventory loans/swaps remain
  unsupported. Unsafe or non-droppable equipment changes are refused.
- The inventory bridge is pinned to checked BG2EE 2.6.6 executable signatures;
  unknown engines fail closed. This is single-player EET acceptance, not native
  BG1EE, IWDEE, multiplayer or every-mod certification.
- Full campaign wilderness ambush/inn/story-cutscene scenarios remain outside
  this test pass. Completed rest, failed rest, save/load, combat and open-menu
  guards have separate acceptance evidence/regressions.
- F12 now routes to shared party presets in single player; see the feature
  guide and the separate party-innate native evidence. Multiplayer keeps the
  character route. The dashboard has no repeat-count editor; imported repeats
  are retained.

In the source checkout and review bundle, machine-readable totals, per-case
exceptions and raw native observations are in
`visual-review/evidence/compatibility-acceptance.json` and the adjacent
`compatibility/` evidence folder. The checklist records remaining boundaries
separately from completed acceptance checks.
