# BuffBot and BuffBot Redux: features, changes and tradeoffs

**Beta report — updated 21 October 2026**
**Original baseline:** Chrizhermann/bg-eeex-buffbot v1.10.1, commit `c1f2eb6cea3b555024853d8e99fc55dc5bd372d7`.
**Redux:** zach-hopkins/bg-eeex-buffbot, recipient-first beta.

Original BuffBot organizes preparation around **who casts**. Redux organizes it around **who receives**. Redux retains the original scanning, classification, native action execution and compatibility infrastructure, then adds a shared party planner and a new interface.

The final casting approach is **ordinary native casting with temporary game-speed acceleration**: 2x by default, with 4x and Normal options. Balanced Quick Cast was an intermediate experiment and is removed. Redux does not rewrite buff durations or install effect-observer hooks. Preset innate shortcuts are also removed; right-click the persistent gear to run a named plan directly.

## 1. Original BuffBot

### Feature overview in everyday language

Open a character's page, choose the buffs they should cast, choose targets and priorities, and save a preset. Then run one character's routine or the party's routines together. Multiple characters can cast concurrently.

The original already discovers installed abilities dynamically. It is not merely a hardcoded list of familiar spells.

| Feature | Original behavior |
|---|---|
| Organization | Separate presets belonging to each caster. |
| Spell sources | Prepared spells, innate/kit abilities and high-level abilities. |
| Items | Uses supported item powers from inventory, temporarily handles equipment and restores it. |
| Targets | Self, party and chosen targets, with targeting controls and overrides. |
| Variants | Discovers selection subspells, such as Spell Immunity schools. |
| Casting | Native action queues per caster, including normal and Quick Cast modes. |
| Fine control | Per-caster priorities, repeat counts, locks and target unlocking. |
| Summons | Existing discovery, identity and separate configuration/execution paths. |
| Preset management | Create, rename, delete, export/import and numbered innate shortcuts. |
| Compatibility | Multiplayer ownership handling, experimental 5E Spellcasting support, localization and installer checks. |

### How the original works technically

The scanner reads live spellbooks, innate lists, item abilities and resource metadata. The classifier decides which entries look like buffs, estimates their durations and supplies default targeting. Item powers retain their actual ability index and charge behavior.

Configuration belongs to the caster and saves through the original persistence system. A run expands the caster's enabled entries, repeats, targets and priorities into native action chains. Each caster advances independently using callbacks after actions. The executor handles unavailable/gone casters, equipment restoration and stalled-run recovery.

Original Quick Cast uses helper effects for aura cleansing and reduced casting time around eligible spell entries. The native spell engine still delivers the spell. Skipping preparation leaves more useful remaining duration than normal casting would; the original does not simulate and subtract all skipped preparation time.

Selection spells have a parent/child relationship: a parent supplies the available use and a selected child supplies the chosen effect. Summon support, native resource debits, localization and save handling were upstream capabilities, not inventions of Redux.

### Strongest case for the original

The original is excellent when you think, “Jaheira does these five things and Jan does these four.” Its configuration directly matches the caster's routine. Repeat counts, locks, target overrides and caster-specific Quick Cast choices are readily available. It adds fewer new planning and inventory-custody systems.

Its ordinary Quick Cast is also attractive if convenience matters more than preserving the exact amount of game time that preparation would consume. It can skip work rather than asking the engine to process all normal casting faster.

### Disadvantages and tradeoffs

- Checking one recipient's complete protection requires inspecting multiple caster pages.
- Two characters knowing the same spell still means managing separate source configurations.
- The player coordinates shared needs and scarce uses manually.
- Quick Cast changes the timing advantage of preparation.
- Dynamic discovery can miss indirect item powers or admit abilities that are not useful buffs.

These are workflow tradeoffs, not evidence that the original design was wrong.

## 2. BuffBot Redux

### Feature overview in everyday language

Make one party plan. Choose a buff, click the people who need it, and let Redux find a legal available source. Pick a specific caster when that matters.

The pages appear as **Buffs → Order → Summary**:

- **Buffs:** the combined catalog, recipient portraits, available uses and duration ranges. Filter by character, search by name or explicitly sort the browser.
- **Order:** review casting priorities, choose casters, move/remove requests, or use Long first, Smart order and Undo.
- **Summary:** inspect each recipient's scheduled buffs using portraits, icons, casters and durations.

Left-click the persistent gear to edit. Right-click it to choose a named preset and run the entire party plan without casting an extra innate ability. Fresh plans start with empty **Pre-Battle Buffs** and **Wake Up Buffs** lists. After Rest is enabled for Wake Up Buffs; until it contains casts, resting does nothing silently. Existing saved plans and rest choices are preserved.

| Feature | Current Redux result |
|---|---|
| Party planning | One saved ordered list of requested buffs and recipients. |
| Automatic sources | Prefer better duration/caster level while respecting legality, pinned choices and scarce resources. |
| Shared availability | Reserve prepared uses, spontaneous spell-level slots, variant parent uses and physical item charges. |
| Source details | Retain every source's caster level, duration, item identity and restrictions. |
| Recipient interface | Native icons and portraits, name search, sortable fields, inline Clear and readable recipient coverage. |
| Stable browsing | Values update during edits; rows do not jump merely because an assignment changes a duration. |
| Resource exhaustion | Eligible portraits remain visible when uses run out; availability gets a warning. |
| Variants | Individual subspell rows; different people can request different schools while sharing parent uses. |
| Catalog controls | Conservative discovery plus Add, Hide and Restore for exceptions. |
| Presets | Create, rename, confirmed deletion, legacy import, and data-only export/import. |
| Completed rests | Independently selected After Rest preset with safe-world checks. |
| Casting speed | Native casting at 2x by default; 4x and Normal selectable. |
| Intelligent ordering | Duration/casting-time heuristic plus targeted-buff-before-invisibility constraints. |
| Item sharing | Guarded borrowing and return of supported unique daily multi-charge backpack items. |
| Summoned casters | Allied summons and clones contribute sources; party members remain the recipients. |
| Themes | Auto, SoD, IWD, BG1 and BG2, with private bundled art and native-font fallback. |
| Game shortcut | Direct gear-button preset picker. Numbered BuffBot innate shortcuts are retired. |

### How Redux works technically

`BfBotPln.lua` takes a live snapshot of recipients, casters, legal abilities and resource capacities. A saved request identifies an ability group, recipient, optional source, optional variant and enabled state:

```lua
{ group = "spl:RESOURCE", target = "dv:CHARACTER", source = nil, var = nil, on = 1 }
```

`source = nil` requests automatic assignment. Saved character identity uses stable character keys rather than portrait position alone; execution rechecks live object identity.

The allocator matches requests to concrete sources. It can move an earlier automatic assignment when doing so frees the only legal source for another request. Pinned casters, self-only targeting, shared pools and item restrictions remain constraints. Before casting, a fresh snapshot rejects an incomplete plan; individual actions continue to revalidate during execution.

The party plan saves separately through the `BuffBotParty` marshal handler. The original character configuration, Caster editor and explicit import path remain available. Redux does not replace all upstream persistence or promise that every original fine-control setting has a new recipient-first equivalent.

### Strongest case for Redux

Redux answers the common preparation question: “Who is protected, and who is missing something?” It reduces duplicated configuration, makes scarce uses visible across the whole party, and retains manual caster preferences when quality or predictability matters.

Native accelerated casting has a straightforward timing model: the engine performs the actual casts and advances the world clock. Existing buffs, newly cast buffs, periodic effects and delayed consequences use the same clock. Rest automation, native item sharing and direct HUD dispatch remove more repetitive clicks.

### Disadvantages and tradeoffs

- Allocation, shared reservations, summon identities and item-return recovery add complexity.
- Automatic caster assignment can change when availability or party composition changes.
- Native acceleration speeds the surrounding world too; it is not an isolated preparation timeline.
- Fast-forward still makes the engine perform its normal work. High multipliers can become performance-limited.
- The original Caster editor remains more direct for repeats, locks, target unlocking and converted 5E workflows.
- Native inventory bridges are restricted to validated executable signatures. Unsupported engines do not receive unsafe sharing behavior.
- Testing is strongest for single-player EET plus stock BG2EE/EEex presentation. Full multiplayer, IWDEE and arbitrary mod-stack parity are not established.

## 3. What changed, how and why

### Recipient-first planning and real reservations

**Plain language:** “Give Keldorn Death Ward” replaces finding a cleric's page and configuring that cast there.

**Technical:** the party snapshot and allocator sit between the inherited scanner and executor. Concrete sources retain their own durations and caster levels. Prepared copies, sorcerer/shaman level pools, selection parents and physical item charges reserve against their real shared capacities.

**Why:** two rows showing three uses may actually draw from the same three slots. Combining visible sources must not invent uses or erase meaningful source differences.

Grouping follows actual resource/ability identity, not English names alone. Identically named resources can stay separate with qualifiers. Redux does not claim a general proof that arbitrary spellbook and innate versions are mechanically equivalent. Self-only spells remain self-only.

### A cleaner native interface

**Technical:** `BfBotPUI.lua`, `BfBotRx.menu` and `BfBotVis.lua` implement the party UI. Each clickable list element has its own column; row/cell dispatch uses the engine's selected-row variable and `cellNumber`. Eligible recipient cells pack left, while a party-wide buff gets one Party chip and spends one cast.

The design removes redundant detail/coverage screens, adds search and stable browsing, shows source-duration ranges upfront, and distinguishes exhausted uses from illegal targets. Popups have visible borders and toggling triggers; empty panel space does not dismiss the editor. Footer/frame artifacts and obstructing dragon decoration were corrected. The HUD gear docks beside the bottom toolbar, with explicitly inset preset captions.

**Why:** the browser should explain what can be added, Order should explain execution, and Summary should explain coverage.

### UI++ independence

All four redesigned themes use BuffBot-owned `BFB`/`BV` resources. Infinity UI++ is **not required**. Auto reads `RgUISkin` when available and otherwise uses BG1; Settings can override the theme without changing the game's UI.

The only UI++ integration is its automatic skin indicator, optional matching fonts and toolbar geometry for the gear. Without its fonts, text/display roles use native `NORMAL`/`STONESML`. BuffBot does not install or change UI++ files, globals or settings.

`BFBARROW` supplies actual up/down artwork and `BFBGLYPH` supplies control symbols. Native portraits and spell/item icons replace design stand-ins. Decimal column widths failed native parsing, so columns use the documented integer-percentage fallback. The compact/wide layouts remain fixed rather than stretching every column. Per-cell keyboard navigation was not introduced.

### Individual selection variants

Redux keeps upstream parent/child discovery but makes request identity include the selected child and recipient. Spell Immunity: Abjuration and Divination can appear separately, use child names/icons/durations and consume the same parent resource pool. Spontaneous selected variants debit the shared spell-level pool correctly.

**Why:** a single global choice cannot express two recipients wanting different schools. Generic selection discovery was inherited; its recipient-oriented presentation and reservations changed.

### Better item and buff discovery

Discovery follows bounded child-spell/EFF graphs and item ability metadata, rather than relying on a growing English-name compatibility list. Add/Hide/Restore remain for exceptions and unconventional preparation spells. Expertise's activate/deactivate stance selector is excluded from automatic discovery, while manual inclusion and saved intent remain possible.

Friendly caster-centered area delivery can appear as Party even when the SPL header says self. Recognition uses projectile targeting metadata. This does not move characters into range or guarantee that every party member receives the effect.

### Native accelerated casting replaces Balanced Quick Cast

`BfBotFst.lua` captures the original simulation/render settings, requests 2x or 4x native simulation, temporarily caps rendering at 30 FPS while preserving lower enabled limits, and restores the previous settings when execution ends or stops. No Multiplayer Redux Tactical Time dependency is added.

Spells use normal native actions. Aura cooldown, casting speed modifiers, resource consumption, projectiles, duration, delayed fatigue and existing effects remain the engine's responsibility. Redux neither reconstructs spell effects nor edits expiry timestamps. The direct gear picker avoids an extra trigger action; the actual buffs still require their native actions.

Independent casters run concurrently, each retaining the saved order within its own lane. Real item-loan custody boundaries and proven recipient-specific prerequisites can create waits. Unrelated casters need not wait for a slow spell elsewhere.

**Measured example:** the same native plan took 9.076 seconds at Normal, 4.740 seconds at 2x and 2.576 seconds at 4x, with 133 game ticks in each run. These are observations from the test setup, not guaranteed speedups. Rendering work explained the earlier apparent 2x plateau. Default 2x favors useful acceleration with a lower performance burden.

The earlier Balanced experiment tried to infer normal preparation ages and adjust newly delivered effects afterward. It required attribution, graph inspection and delayed observation. That module, effect hooks, observer polling and duration writes were removed because native time gives simpler, more consistent semantics.

The original Caster editor still retains its upstream Quick Cast modes and invisible helpers for compatibility. Those are separate from the current recipient-plan casting path.

### Smart order and invisibility

Long first sorts known durations descending, placing permanent buffs first. Smart order starts with that baseline, considers casting costs and assigned sources, and performs bounded improvements to retained duration. It is a heuristic, not a guaranteed global optimum. Matching Long first is valid. Undo restores the prior request order.

Incoming targeted buffs precede invisibility on the same recipient. Self and party casts are exempt. Resource inspection recognizes invisibility through supported variants, items, child spells and external effects. A recipient-specific execution wait prevents a faster caster from making the target invisible before an earlier incoming buff finishes; it does not serialize unrelated casters.

Sorting does not spend resources or change browser sort order. Manual movement and explicit caster choices remain available. The small timing estimate used for ordering is read-only and never alters effects.

### Purposeful item sharing

`BfBotShr.lua` exposes eligible unique loose daily rechargeable items as borrower-owned sources, sharing one physical charge pool. Native inventory usability checks determine whether the borrower can actually wear the item.

The initial scope is identified, nonstackable daily powers with at least two maximum charges, held in a backpack. The loan transfers the real item, activates it through the native inventory/equipment path, restores equipment, returns it to its owner and restores its backpack position when safe.

A custody journal is saved before transfer. Stop, combat and load recovery return the item when the recorded state is safe. Curses/undroppable flags, duplicate copies, full backpacks, incompatible areas and unsafe engine signatures are refused. Occupied slots or missing actors can pause automatic recovery; the journal remains. Redux never manufactures a replacement item.

**Why:** sharing legal charges should remove inventory chores without bypassing equip restrictions or silently losing equipment. This is deliberately narrower than sharing every item power.

### Summons as casters

Allied summons and clones contribute legal sources and independent resource pools to the party planner. They are not added as buff recipients. Clone preferences use owner/type identity where supported; absent pinned sources remain unavailable. Project Image prevents allocation that would improperly use its locked owner's casting.

Original BuffBot already supported summons. Redux integrates that capability into recipient requests and shared reservations. Summon equipment loans/swaps remain unsupported.

### Presets, completed rests and direct shortcuts

Party presets support create, rename, confirmed deletion and non-executable export/import. Import creates a new preset and retains existing ones. A separately selected After Rest list waits for a completed standard rest and a safe execution state; loading a save does not replay a previous rest.

The persistent gear opens the editor on left-click and a named preset picker on right-click. Selecting a preset validates current sources and starts the full plan directly. Busy, replaced and unavailable plans are rejected.

Numbered BuffBot preset innates, their recipient settings, grants, recharge callback, title updates and dispatch path are removed. Old characters lose only exact `BFBT[0-5][1-8]` shortcut entries through native opcode 172, including spent/duplicate entries. Their real spell/kit innates and saved presets remain. A saved obsolete shortcut action cannot dispatch a plan.

`BfBotInn.lua` remains as a small compatibility module for upgrade cleanup and the legacy editor's two invisible helper resources; it creates no preset abilities. The installer retains its eight legacy label references for install/language rollback, but runtime no longer reads them.

## 4. Verification and practical limits

Native acceptance used isolated game copies, copied saves and a private Lua harness. The personal installation and Infinity UI++ files were unchanged. Stock BG2EE/EEex and EET/UI++ presentation were checked separately. Automated coverage includes planning, reservations, variants, catalog discovery, item restoration, summons, rest detection, timing controls, localization, deployment and packaging.

Earlier compatibility reports contain results from the removed Balanced prototype. Their expiry-write totals are historical evidence, not current runtime behavior. Current native tests confirmed retirement cleanup, preservation of real abilities/presets, the settings change and the Buffs → Order → Summary arrangement.

Important remaining limits:

- Full multiplayer acceptance and arbitrary mod-stack compatibility are not claimed.
- Interactive item selectors may still require manual use; safe rejection happens before spending charges or changing equipment.
- Shared-item support remains constrained to validated, safe cases; recovery can require the player to restore safe inventory conditions.
- Manually directing a caster can replace its queued action/callback. Other casters continue; a stalled remainder is stopped by the existing watchdog. This is not a comprehensive manual-command cancellation feature.
- Auto classification and duration estimates can be conservative. Actual native delivery still depends on range, target state and engine rules.
- 4x performance depends on the PC, effects and game state. The default is 2x.

The objective comparison is therefore a choice of workflow: original BuffBot emphasizes direct caster routines and detailed per-caster controls; Redux emphasizes recipient coverage and shared planning while retaining native casting semantics.


### Saved ordering update — beta.2

Smart order and Long first are now saved modes, with a selected state matching
the top tabs. They update when requests are added, removed or changed. Full
prepared capacities, including spent copies and daily item maxima, supply a
separate sorting snapshot; actual available uses remain authoritative for casts.
A spent spell therefore keeps its normal planning priority without needing rest.

Custom restores a separately saved manual position on each request; adding a
request appends to that manual sequence, while moving a row selects Custom.
Recipients, preferred casters, variants and enabled choices remain shared across
modes. Undo restores mode and order. Old presets/imports remain Custom; newly
created presets start in Smart order. Export format 2 saves this information and
still reads format 1. Signature caching avoids re-sorting unchanged plans on
ordinary redraws; there is no continuous background sort task.
