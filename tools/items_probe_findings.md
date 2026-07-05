# Items + Potions — In-Game Probe Findings (Plan Tasks 2 + 3)

Verified 2026-07-03 on BG2EE test install (`modded - Copy - Copy`), EEex remote console,
branch `feat/items-and-potions` (post-merge, v1.4.1-alpha code base).
This file is temporary: folded into `~/.claude/skills/bg-modding/references/` in Task 18, then deleted.

## Task 2 — Inventory access

- **Field chain: `sprite.m_equipment.m_items`** — the only inventory field.
  (`m_inventory`, `m_aItems`, `m_chunkedInventory`, `m_lstItems`, `m_items`,
  `m_quickItems`, `m_aQuickItems` all nil on CGameSprite.)
- `m_items` is a fixed-array usertype: **`items:get(i)` → CItem | nil** (nil = empty slot).
  `items:getReference(i)` returns the slot address (always non-nil) — not what we want.
- **Slot layout** (empirically confirmed on BG2EE):
  - `0-17` equipped body slots (slot 10 = FIST pseudo-item; `m_equipment.m_selectedWeapon == 10` when unarmed)
  - `18-20` quickitem slots 1-3 (CreateItem auto-fills these for potions before backpack)
  - `21-36` backpack (16 slots)
  - `37+` magic-weapon etc. — skip
  - Body-slot sub-mapping differs from classic IESDP CRE docs: **rings land at 7-8**
    (verified 2026-07-05 by equipping via UI), not the documented 4-5. Only the three
    RANGES above matter for BuffBot; don't rely on classic per-slot indices within 0-17.
- **CItem named fields**: `pRes` (CResItem → `pRes.resref:get()` = resref, `pRes.pHeader` = Item_Header_st),
  `m_wear` (+0x18), `m_flags` (+0x20; 1 = identified).
- **Count/charges have NO named field.** Raw read:
  `EEex_ReadU16(EEex_UDToPtr(item) + 0x1C)`
  Universal across categories — verified against CreateItem-set values:
  potion stack (3/5/3), ring charges (10), wand charges (10).
- Item category: `pRes.pHeader.itemType` — 9=potion, 10=ring, 35=wand, 1=amulet, 6=bracers.
- `GetQuickButtons(0|1|3, false)` return **empty** for items (only 2=spells, 4=innates are wired).
  Items are NOT reachable via quick-button data — the m_items walk is the only path.
- **Name lookup for ITMs: `identifiedName` first**, then `genericName`.
  (genericName = unidentified name — "Potion", "Ring". This is the REVERSE of the
  SR spell workaround in `BfBotScn._tryStrref` order, which tries genericName first.)

## Task 3 — Item resources

- **CONFIRMED EEex BUG — `Item_Header_st:getAbility(i)` stride typo**
  (`EEex_Resource.lua:165` uses `Item_Header_st.sizeof` (114) instead of `Item_ability_st.sizeof` (56)).
  - `getAbility(0)` correct (offset 0); `getAbility(i≥1)` returns garbage.
  - Live proof (STAF11, 3 abilities): eeex a1 = `qst83/rng0/fx38/se1/icWI902B` (icon is a
    misaligned read into "SPWI902B"); manual a1 = `qst3/rng25/fx2/se36/icSPWI308B`.
    Manual values tile perfectly: a0 se=27 fx=9 → a1 se=36 fx=2 → a2 se=38 fx=1.
  - **Use manual arithmetic**:
    `EEex_PtrToUD(EEex_UDToPtr(h) + h.abilityOffset + Item_ability_st.sizeof * i, "Item_ability_st")`
  - TODO: file upstream EEex issue.
- **Item_ability_st named fields** (live-verified): `quickSlotType` (attack type; 3=magical),
  `type` (flags word; bit 10 = friendly — matches `BfBot._fields.friendly_flags`), `range`,
  `effectCount`, `startingEffect`, `quickSlotIcon:get()`, `actionType`.
  **No named target field** — raw: `EEex_ReadU8(EEex_UDToPtr(ability) + 0xC)`
  (verified: wand=1 living, ring/potion=5 self).
- **Item_effect_st field names on ITM = same as SPL** — `BfBot._fields` maps carry over unchanged:
  `effectID` (opcode), `res:get()` (NOT `resource`), `durationType`, `duration`, `effectAmount`,
  `dwFlags`, `targetType`, `special`. Header effect table offset: `h.effectsOffset` (same name as SPL).
- **Direct-effect AND op=146 wrapper items both exist**:
  - Direct: POTN14 (op16 haste…), POTN21 (321/328/296 — modded-style), RING05 (op20), RING39 (op20; op16)
  - Wrapper: STAF11 a1 = `146:SPWI308` + `146:SPWI304`, a2 = `146:staf11`
  → the leafResrefs recursion (plan Task 7) is both needed and sufficient for items.
- **SPL/ITM resref collision is REAL**: `staf11.SPL` exists (cast by STAF11.ITM a2 via op146).
  The catalog `kind` field + spells-win-on-collision merge rule are load-bearing.
- Classification caveat: an ability that is ONLY op146s scores 0 (classifier doesn't recurse
  sub-spells for scoring) — same known limitation as SR Barkskin; manual override UI covers it.

## Task 3 — UseItem BCS verb

- `UseItem("RESREF", target)` via `EEex_Action_QueueResponseStringOnAIBase`: **works**.
- **Works from ANY slot for ANY category** (all live-fired):
  - potion @ quickslot 19: stack 5→4, 5 effects landed
  - wand @ backpack 26: charges 5→4
  - scroll @ backpack 29: consumed (slot emptied), 43 effects landed
  - **UNEQUIPPED ring @ backpack 27: fired!** charges 3→2, invisibility landed
- → "wands/scrolls only from quickslot" is a **UI-only restriction**; the engine does not enforce it.
  BuffBot's scanner slot-filter is therefore mandatory game-balance enforcement:
  non-potion activatables must be in slots 0-17 (equipped) or 18-20 (quickitem) to be listed.
- Engine auto-handles all bookkeeping (stack decrement, charge decrement, scroll/empty-stack
  destruction). No BuffBot-side accounting; pre-flight rescan sees fresh counts.
- **Effect sourcing**: `eff.m_sourceRes` = the ITEM resref for direct-effect items
  (POTN15 ×5, SCRL07 ×43, RING05 ×1 all sourced by item resref).
  → `_HasActiveEffect(sprite, itemResref)` works as-is for direct items;
  op146 wrappers additionally need leafResrefs (sub-spell effects carry the sub-spell resref).
- `UseItem` is **NOT in INSTANT.IDS** → action-queue only (matches the planned exec path with
  `EEex_LuaAction` advance chaining).
- Remote-console quirk: return strings containing `"` break the result JSON (returnValue silently
  dropped) — sanitize probe output.

## Design deltas for Task 8 (scanner) — supersedes plan constants

1. **No `_INVENTORY_FIELD` / `_QUICKITEM_FIELD` constants** — single `m_equipment.m_items` walk
   with slot-range rules:
   - slots 0-17 (equipped): include activatable abilities of any category
   - slots 18-20 (quickitems): include any usable category
   - slots 21-36 (backpack): include **cat 9 potions only**
2. Count: `EEex_ReadU16(EEex_UDToPtr(item) + 0x1C)` — add named constant (e.g. `BfBot.Scan._ITEM_COUNT_OFF = 0x1C`).
3. Ability access: manual-arithmetic helper (stride bug) — never `Item_Header_st:getAbility(i)` for i ≥ 1.
4. Ability target: `EEex_ReadU8(EEex_UDToPtr(ability) + 0xC)`.
5. ITM naming: identifiedName first.
6. Skip FIST + empty slots; skip `BFBT` prefix (defensive).

## Fixture notes for Task 17 QA (this install)

- RING06 / AMUL19 / RING23 / BRAC09 are **passive** here (abilityCount 0) — not activatable fixtures.
- Good fixtures: **RING05** Sandthief's Ring (self op20 invis, charges), **RING39** Ring of Gaxx
  (2 abilities: invis + haste — multi-ability equipped test), BRAC16 Bracers of Blinding Strike,
  WAND11 Wand of the Heavens (offensive — classifier must reject), STAF11 Staff of the Magi
  (3 abilities, op146 wrappers, stride regression check).
- Identify fixtures by NAME in QA, not assumed resref (modded install shifts things —
  POTN14 carries op16 haste here).
