# Subwindow Selection Spells — Design Document

> **GitHub Issue**: #20 — Handle spells that require subwindow selection

## Problem

Some buff spells use opcode 214 ("Select Spell") to open a selection subwindow mid-cast, requiring the player to choose a variant before the effect is applied. When BuffBot queues these spells via `SpellRES`, the subwindow opens and blocks the execution queue.

**Examples**: Protection from Elemental Energy (SPWI422), AK stances (Power Attack, Expertise, Rapid Shot, Mimicry).

**Hard requirements**:
1. No subwindow must ever appear during BuffBot execution
2. Spell slots must be properly consumed (no cheating)
3. If a variant spell somehow reaches execution without a configured variant, it must be skipped — never block

## Mechanism (Verified In-Game)

**Opcode 214** in a spell's feature block triggers the subwindow. Its `resource` field references a **2DA file** that lists variant sub-spells.

Example — SPWI422 (Protection from Elemental Energy):
- 1 ability, 1 feature block: `opcode=214, resource=DVWI426`
- `DVWI426.2DA`:
  ```
  2DA V1.0
  ****
           ResRef   Type
  ProFire  spwi319  3
  ProCold  spwi320  3
  ProElec  spwi512  3
  ProAcid  spwi517  3
  ```
- Each variant is a full SPL file castable via `ReallyForceSpellRES`

**Slot consumption**: `sprite.m_memorizedSpellsMage:getReference(level)` (or `Priest`/`Innate`) gives memorized spell entries. Each has `m_spellId:get()` (resref) and **writable** `m_flags` (1=available, 0=cast). Setting `m_flags = 0` programmatically consumes the slot.

## Approach: Pre-Configure Variant + Direct Cast + Manual Slot Consumption

### 1. Detection & Variant Discovery (Scanner/Classifier)

**Where**: `BfBotScn.lua` / `BfBotCls.lua`

During classification, after walking feature blocks, detect opcode 214:
1. Read the 2DA resource from the feature block's `res` field
2. Parse the 2DA rows: `{label, resref, type}` per row
3. For each variant resref, load sub-spell SPL header for name + icon
4. Store on scan entry: `variants = {{label, resref, name, icon}, ...}`
5. Set `hasVariants = 1` flag on scan entry (0/1 integer)

**Classifier impact**: Parent spells with opcode 214 may score low on buff opcodes (only infrastructure opcode). Ensure classification accounts for this — inherit buff status from variants if parent scores too low.

### 2. Config Storage (Persistence)

**Where**: `BfBotPer.lua`

Add optional `var` field to per-spell config:
```lua
spells = {
    ["SPWI422"] = {on=1, tgt="s", pri=5, var="SPWI319"}
}
```

- `var` — selected variant sub-spell resref. Only present for opcode-214 spells.
- Nil/missing `var` on a variant spell → "no variant selected" → skipped in execution.
- No schema version bump — additive optional field. Existing configs work unchanged.

**Auto-population**: Variant spells added to presets with `var = nil`, disabled. User must select variant to enable.

**Queue building**: `BuildQueueFromPreset` passes `var` field through to execution queue entries.

**Export/Import**: `var` serializes naturally. On import, unknown variant resrefs treated as unknown spells — silently dropped.

### 3. Execution Engine (Slot Consumption + Variant Cast)

**Where**: `BfBotExe.lua`

New helper `_ConsumeSpellSlot(sprite, resref)`:
1. Determine spell type from resref prefix: `SPWI` → mage, `SPPR` → priest, else → innate
2. Get spell level from SPL header → 0-based index into memorized array
3. Iterate `sprite.m_memorizedSpells*:getReference(level)`, find first entry where `m_spellId:get() == resref` and `m_flags == 1`
4. Set `m_flags = 0`
5. Return true/false

Modified `_ProcessCasterEntry` flow:
```
if entry.var then
    -- Variant spell path
    if not _ConsumeSpellSlot(casterSprite, entry.resref) then
        log SKIP "no slot"
        recurse to next
        return
    end
    queue ReallyForceSpellRES(entry.var, target)
    queue EEex_LuaAction advance
else
    -- Normal path (unchanged)
    queue SpellRES(entry.resref, target)
    queue EEex_LuaAction advance
end
```

**Skip detection**: `_CheckEntry` uses the **variant resref** (not parent) for `_HasActiveEffect` check, since the variant produces the actual buff effects.

**Cast pacing**: `ReallyForceSpellRES` applies the variant instantly (no cast animation on parent). Variant spells cast faster than normal. Acceptable — the sub-spell's own projectile/effects still play.

### 4. UI — Variant Picker

**Where**: `BfBotUI.lua` + `BuffBot.menu`

**Dual button layout**: Two sets of row-1 buttons in .menu with `enabled` visibility guards:

Normal spells (unchanged):
```
Enable(120) | Target(160) | Up(48) | Down(48) | Delete(130)
  350          476           642       694        740
```

Variant spells (squeezed):
```
Enable(90) | Target(110) | Variant(110) | Up(44) | Down(44) | Delete(102)
  350         444           558            672       720        768
```

- **Target button**: works normally for all spells. Self-only shows "Self" (locked).
- **Variant button**: shows current variant name or "(none)". Click opens `BUFFBOT_VARIANTS` sub-menu.
- **BUFFBOT_VARIANTS sub-menu**: list with icon + name columns. Click to select. Done button closes.

**Enable gate**: Attempting to enable a variant spell with `var == nil` opens the variant picker instead of toggling. Once a variant is selected, enable works normally.

### 5. Safety & Edge Cases

- **No variant configured**: Execution engine skips with WARN log. UI prevents enabling without variant (defense in depth).
- **Parent spell enabled without variant flow**: Exec detects `hasVariants` on scan entry + missing `var` → skip. No subwindow ever.
- **Slot consumption failure**: `_ConsumeSpellSlot` returns false → skip as "no slot".
- **Broken variant resref**: Scanner excludes variants whose SPL can't be loaded.
- **Config migration**: None needed. `var` field is additive/optional.
- **Quick Cast**: Variant spells respect QC mode. BFBTCH applied normally. `cheat` tagging uses parent's `durCat`.

### 6. Testing

**Unit tests** (`BfBot.Test.SubwindowSpells()`):
1. Opcode 214 detection on SPWI422 → `hasVariants == 1`, 4 variants
2. 2DA parsing → correct resrefs and names
3. `var` field persistence round-trip
4. Enable gate blocks enable without variant
5. Queue building includes `var` field
6. `_ConsumeSpellSlot` structural test (exists, callable)
7. Execution takes variant path when `entry.var` present
8. Skip on missing variant → logged as SKIP

**In-game verification** (manual):
- Memorize SPWI422, configure Fire variant, cast via BuffBot
- Verify: Protection from Fire applied, no subwindow, slot consumed, scanner count decrements
