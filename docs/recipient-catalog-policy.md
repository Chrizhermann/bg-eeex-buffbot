# Recipient catalog: conservative default selection

Checkpoint: 2026-10-19. Implemented in the repository and tested offline. Not
deployed to the running game or personal installation for this checkpoint.

## Problem and change

The retained classifier scores opcodes, targeting and secondary spell type.
That broad discovery score does not reliably distinguish a stat bonus from a
penalty or bookkeeping/protection effects from a useful preparation spell.
Installed Doom, for example, receives a positive score despite being categorized
as disabling; Greater Malison and several spell-defense removal spells do too.

The recipient browser now uses a separate `Plan.IsAutomaticBuff(row)` policy.
A positive classifier result alone does not automatically put a non-self,
non-friendly spell in the browser when its secondary type is:

- 4: Magic Attack;
- 10: Offensive Damage;
- 11: Disabling.

This is a default-catalog choice, not a claim that the ability has no legitimate
friendly use. It does not interpret modifier signs, hardcode spell names, change
the general opcode classifier or alter the retained legacy caster editor.
Divination Attack (5) is deliberately not filtered by this policy.

Recognized self-only/friendly spells and explicit positive classifier overrides
remain automatic candidates. Item discovery retains its existing bounded graph
policy; this change does not reclassify item powers.

The category mapping is the standard mapping already used by the classifier,
and matches the copied installation's `MSECTYPE.2DA`. Unknown/custom secondary
types retain the previous decision instead of being rejected by inference.

## Explicit intent and compatibility

- All known abilities remain in `actor.rows`, including filtered spells.
- Manual **Add spell / item** can include a filtered or otherwise unrecognized
  spell, without changing the classifier globally. It remains possible to use
  Resilient Sphere or other unusual preparation choices deliberately.
- Existing enabled recipient requests for a still-recognized source remain
  eligible even when the new automatic policy would filter that source. Requests
  from all eight preset positions are considered, including a rest preset that
  differs from the active editing preset. No saved request is deleted.
- This preservation does not bypass a negative/incomplete classifier verdict,
  unavailable source, recipient restrictions, item usability or converted 5E
  pool restrictions. Explicit manual inclusion retains its existing behavior.
- Disabled old requests do not seed the catalog. Hiding and restoring remain
  independent catalog preferences.
- Every known native spell still registers its underlying resource pool before
  catalog filtering. A sorcerer's shared level capacity therefore remains
  conservative across filtered and visible abilities.

There is no new save format or migration. Legacy per-character selections and
the old editor are unchanged. Resource reservation and execution eligibility
still run after catalog selection.

## Installed-resource audit

The reproducible audit adapter is `tools/research/audit_catalog.py`. It reads
loose SPLs and the copied game's English TLK, then runs the production Lua
classifier and new catalog predicate against decoded data.

It reviewed 1,020 loose `SPWI*`, `SPPR*` and `SPIN*` roots with a selected header
at caster level 20. Nineteen formerly automatic candidates are now filtered by
the new catalog policy. These include Doom, Greater Malison, Curse, Lower
Resistance, Pierce Magic, Pierce Shield, Khelben's Warding Whip, Energy Drain and
Resilient Sphere variants. Not all these resources are necessarily available to
the current party; this is a resource audit, not a live 19-row UI count.

Controls include Bless, Champion's Strength, Improved Haste and Fire Shield:
their classifier and automatic-catalog decisions are unchanged. Existing
negative classifications such as Chaos and Flesh to Stone remain negative.

Two selection-menu families are excluded from automatic comparison because the
adapter does not reproduce native 2DA discovery. The audit has no BIF fallback,
does not load saves, does not establish caster availability and does not prove
native bindings or gameplay behavior. The report records input hashes rather
than distributing game resource files.

Reproduce from a configured Python environment with `lupa` installed:

```text
python tools/research/audit_catalog.py <copied-game-root> --output <audit.json>
```

The raw `is_buff` column is the broad classifier result; `automatic_catalog` is
the new default policy. `selection_menu_excluded` identifies the adapter's
variant limitation. The audit does not patch resources or contact a game process.

## Remaining detection work

This deliberately addresses false-positive defaults without broadening discovery.
It does not solve parameter-sensitive classification, dynamically determine
whether every mixed-effect spell is useful, or recursively classify every
wrapper spell. The copied installation's Haste wrapper (`SPWI305`) remains
unrecognized by the broad classifier in this offline adapter, unchanged by this
policy. That is a separate missing-buff investigation; manual Add remains the
current escape hatch. No native tooltip, geometry or visual-theme changes are
part of this checkpoint.

## Evidence and references

`recipient-catalog-policy-acceptance.json` records audit hashes, affected roots,
control cases and test results. The 28 new LuaJIT cases cover category defaults,
positive/negative overrides, self/friendly exceptions, item stability, all-preset
intent, shared pools and the actual Add callbacks with mocked native APIs.

The binary adapter follows the [IESDP SPL V1 format](https://gibberlings3.github.io/iesdp/file_formats/ie_formats/spl_v1.htm).
Opcode semantics have parameter-dependent modes; see the
[IESDP opcode reference](https://gibberlings3.github.io/iesdp/opcodes/bgee.htm).
This policy avoids treating a modifier's sign as a universal benefit test.
