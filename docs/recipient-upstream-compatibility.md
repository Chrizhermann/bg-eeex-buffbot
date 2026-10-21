Update, 20 October: preset deletion, recipient-plan import/export, scoped Balanced Quick Cast and unique daily-item sharing are implemented. See [the current feature guide](plan-management-and-casting-beta.md); the table below reflects the current beta. Expanded native evidence is in [the independent compatibility report](compatibility-test-report.md).

# Recipient dashboard compatibility audit

Reviewed against the locally checked-out upstream `v1.10.1` tag
(`c1f2eb6cea3b555024853d8e99fc55dc5bd372d7`), including its README, scanner,
classifier, persistence, executor, menu and variant picker. This is a source and
regression audit with selected live EET checks, not a claim that every upstream
feature has native acceptance on every game/mod combination.

The installed catalog also exposes variants for Shapechange, Polymorph Self,
Rapid Shot, Expertise and Power Attack; Spell Immunity is not its only selection
spell. Their variant rows use the same generic implementation. The live casting
acceptance below specifically exercises Spell Immunity.

## Variant regression fixed

Upstream discovers opcode-214 selection menus through their 2DA resources; this
is generic support, not a hardcoded Spell Immunity exception. Its README also
names Protection from Elemental Energy as an example. The original picker stores
the selected child resource while the executor spends a parent spell use and
casts that child. Active-effect checking uses the child resource.

The recipient GUI previously used one selected variant per displayed parent
row, and its existing-request lookup compared only parent and recipient. This
made one school's assignment look selected in other schools and prevented
independent editing. The allocator already stored a variant per request.

The dashboard now expands discovered children into separate rows. UI identity,
preview, toggles, repeat removal and Clear compare parent + recipient + variant.
Requests retain the existing `{group,target,source,var,on}` save format and
reserve the original parent's pools. Summary, Order and icons identify the
selected child. Unsupported or missing saved choices remain visible and
removable rather than silently switching to another school.

Source popups name the chosen variant, show caster-specific child durations and
free/total uses, explain shared parent uses, and explicitly label hiding the
whole spell family. Hiding does not delete requests. The original variant path remains, with a correction to shared-level slot
consumption for sorcerer and shaman selected variants.

## Feature comparison

| Upstream capability | Recipient dashboard / retained path | Remaining boundary |
| --- | --- | --- |
| Dynamic spell, innate, HLA and kit scans | Reuses upstream scanner/classifier; combines concrete sources behind recipient rows. | Installed resource metadata still governs discovery. Manual Add remains available. |
| Selection spells | Separate child rows; shared parent resources; per-recipient choices; child names/icons/durations. | Missing child metadata is blocked. No unsupported 5E variant casting is enabled. |
| Identified item powers and potions | Reuses item execution and inventory/swap preferences; reserves physical charge pools. | Unique daily backpack items support guarded loans and native usability checks. Scrolls/wands use manual Add. Interactive item pickers and unsafe gear exchanges require manual use. |
| Skip active buffs, interrupt in combat, live source revalidation | Same executor and global preferences, with added planned identity/item-slot checks. | Issuing an action alone does not prove delivery; live checks inspect effects and consumption separately. |
| Target restrictions | Recipient previews enforce parent self-only/party restrictions. | Target unlocking remains a legacy-editor feature. Conditional effects can still require manual judgment. |
| Ordering and locks | Explicit Order view and source preferences; browser sorting never changes cast order. | Smart order, Long first and Undo are available in Order; legacy row locks remain in the caster editor. |
| R1â€“R5 repeats | Legacy imports preserve repeated requests and their variants. | Dashboard toggles represent coverage; there is no new repeat-count editor. Unselecting a cell removes its repeated requests together. |
| Quick Cast (Off / Long / All) | Original modes remain in the caster editor. | Recipient plans default to Balanced Quick Cast with per-component expiry correction and timing audit; uncertain graphs remain visibly conservative or unbalanced. |
| Summons, Project Images and Simulacra | Live allied summons and clones contribute guarded recipient-plan sources; Project Image locks its owner before allocation. | Six party recipients only; summon backpack swaps/loans require manual handling. |
| F12 preset innates | Single-player numbered innates launch shared party presets from PCs selected in Settings → Preset abilities, with immediate recharge and deferred native dispatch. | Multiplayer retains the original character route; numbered labels map to the preset picker. |
| Export/import files | Recipient .bbp export/import creates new presets and preserves request fields; native legacy import verified. | Bounded data format, eight-preset limit; no executable Lua imports. |
| Presets and save data | Separate `BuffBotParty` v1 handler; existing `BuffBot` handler and legacy presets retained. | New panel has create, rename and confirmed deletion with last-preset/rest safeguards. |
| Experimental 5E Spellcasting | Original implementation and regression tests retained in caster editor. | Recipient planner explicitly excludes converted 5E pools until their semantics are verified. |
| Multiplayer | Original local-control checks and legacy routes retained. | Recipient plans intentionally target single player first. |
| Installer, localization and game variants | Existing installer and runtime localization retained; new text registered with English fallback in every catalog. | New beta text still needs translation. Native acceptance here is single-player EET, not a new BG1EE/BG2EE or multiplayer certification. |
| Themes and panel controls | Legacy panel remains accessible through Options â†’ Caster editor. | Redux has compact/wide Inventory Redux frame layouts and four UI++ skins, with BG1 fallback and the retained non-UI++ panel. Legacy move/resize controls remain in the caster editor. |

`BfBotPer.lua` and `BfBotInn.lua` remain unchanged from the upstream tag. The
legacy menu prefix is preserved except for an added rest polling label; changes to `BfBotUI.lua` redirect the main
opening route and extend manual item discovery. Their original variant picker,
repeat, summon, export/import and quick-cast functions remain available.

## Verification

See `recipient-dashboard-acceptance.json` for current suite counts and copied-game
evidence. Regressions cover different schools on different casters, multiple
schools on one recipient, shared-use exhaustion, variant-specific Clear and
repeat removal, save/queue retention, unavailable choices, source-popup wording,
and search resetting both native list scrollbars.

The new panel is therefore not yet a complete replacement for every upstream
workflow. Selection-spell support is fixed here; the explicitly listed legacy
features should remain visible in the checklist rather than being described as
full dashboard parity.

Live acceptance cast Abjuration on Simmeon and Divination on Jan. Both child
effects were present and each parent count fell from 2 to 1. Searching from a
native scrollbar position of 2000 reset it to 0. Final suite: 783 passed, with
five existing Windows symbolic-link privilege tests deselected.
