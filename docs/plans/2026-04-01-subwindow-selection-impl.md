# Subwindow Selection Spells — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Detect spells with opcode 214 (subwindow selection), let users pre-configure the variant in the UI, and cast the variant directly while properly consuming the parent spell's slot.

**Architecture:** Scanner detects opcode 214 and reads the referenced 2DA to discover variants. Persistence stores the selected variant resref (`var` field). Execution engine consumes the parent slot via `m_flags` manipulation and casts the variant via `ReallyForceSpellRES`. UI shows a Variant button/picker for these spells, gating enable on variant selection.

**Tech Stack:** Lua (EEex bridge), .menu DSL, EEex C++ userdata (CCreatureFileMemorizedSpell, m_flags)

**Design doc:** `docs/plans/2026-04-01-subwindow-selection-design.md`

---

### Task 1: Detect opcode 214 and parse variant 2DA in classifier

**Files:**
- Modify: `buffbot/BfBotCls.lua` (add `_DetectVariants` helper, call from `Classify`)
- Modify: `buffbot/BfBotScn.lua` (propagate `hasVariants`/`variants` to scan entry)
- Test: `buffbot/BfBotTst.lua` (add structural tests)

**Context:**
- Opcode 214 triggers the selection subwindow. Its `resource` field references a 2DA.
- The 2DA format is: `2DA V1.0\n****\n         ResRef   Type\nLabel  resref  N`
- Each row's `resref` is a castable sub-spell SPL.
- Field access: `fb[BfBot._fields.fb_opcode]` for opcode, `fb[BfBot._fields.fb_res]:get()` for resource.
- 2DA loading: `EEex_Resource_Demand(res, "2DA")` returns a userdata — need to investigate parsing API.
- Sub-spell SPL: `EEex_Resource_Demand(resref, "SPL")` for name/icon.
- In-game verified: SPWI422 → opcode 214 → DVWI426.2DA → {SPWI319, SPWI320, SPWI512, SPWI517}.

**Step 1: Add `_DetectVariants` to `BfBotCls.lua`**

Add after `ScoreOpcodes` function (~line 410). This helper walks feature blocks looking for opcode 214, then parses the 2DA to build a variants array.

```lua
--- Detect opcode 214 (Select Spell) and parse the referenced 2DA for variants.
--- Returns nil if no opcode 214 found, or a variants array:
---   {{label="ProFire", resref="SPWI319", name="Protection from Fire", icon="..."}, ...}
function BfBot.Class._DetectVariants(header, ability)
    local op214Res = nil

    BfBot.Class._IterateFeatureBlocks(header, ability, function(fb, _)
        local opcode = fb[BfBot._fields.fb_opcode]
        if opcode == 214 then
            local ok, res = pcall(function() return fb[BfBot._fields.fb_res]:get() end)
            if ok and res and res ~= "" then
                op214Res = res
                return true  -- stop iteration
            end
        end
    end)

    if not op214Res then return nil end

    -- Load the 2DA resource
    local ok2da, tda = pcall(EEex_Resource_Demand, op214Res, "2DA")
    if not ok2da or not tda then
        BfBot._Warn("Variant 2DA not found: " .. op214Res)
        return nil
    end

    -- Parse 2DA rows. EEex 2DA userdata may support iteration or we
    -- need to use EEex_Resource_GetAtRow / raw text parsing.
    -- Implementation will depend on what API is available (investigate at impl time).
    local variants = {}
    -- ... parse rows, for each: load sub-spell SPL for name/icon ...
    return variants
end
```

**IMPORTANT**: The 2DA parsing API needs investigation. EEex may expose `C2DArray` methods (e.g., `GetAt(row, col)`, `m_nRows`) or we may need raw text parsing. Test in remote console first:
```
bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "<override>" 'local t = EEex_Resource_Demand("DVWI426","2DA") -- inspect metatable'
```

**Step 2: Integrate into `Classify`**

In `BfBot.Class.Classify` (~line 526), after computing all scores and before caching, call `_DetectVariants`:

```lua
-- Detect opcode 214 variants
local variants = BfBot.Class._DetectVariants(header, ability)
if variants and #variants > 0 then
    result.hasVariants = true
    result.variants = variants
    -- If parent scores too low as buff (only has infrastructure opcodes),
    -- inherit buff status: at least one variant is a buff → parent is a buff
    if not result.isBuff then
        result.isBuff = true
        result.isAmbiguous = false
    end
else
    result.hasVariants = false
    result.variants = nil
end
```

**Step 3: Propagate to scan entry**

In `BfBotScn.lua` `_buildCatalogEntry` (~line 23), after setting `isAoE`/`isSelfOnly`, add:

```lua
local hasVariants = (classResult and classResult.hasVariants) and 1 or 0
local variants = (classResult and classResult.variants) or nil

return {
    -- ... existing fields ...
    hasVariants = hasVariants,
    variants = variants,
}
```

**Step 4: Write tests**

Add `BfBot.Test.SubwindowDetection()` to `BfBotTst.lua`. Tests:
1. `_DetectVariants` function exists and is callable
2. Load SPWI422 SPL, call `_DetectVariants` → returns non-nil array
3. Array has 4 entries (fire/cold/elec/acid) if SPWI422 is available
4. Each entry has `resref` and `name` fields
5. Load a non-variant spell (SPWI305 or similar), call `_DetectVariants` → returns nil
6. `Classify("SPWI422", ...)` result has `hasVariants == true`
7. Scan entry for SPWI422 has `hasVariants == 1`

**Step 5: Run tests, fix any issues**

Run: `BfBot.Test.SubwindowDetection()` in EEex console
Expected: All tests pass

**Step 6: Commit**

```bash
git add buffbot/BfBotCls.lua buffbot/BfBotScn.lua buffbot/BfBotTst.lua
git commit -m "feat(scan): detect opcode 214 variant spells and parse 2DA (#20)"
```

---

### Task 2: Add variant field to persistence and queue building

**Files:**
- Modify: `buffbot/BfBotPer.lua` (add `GetSpellVariant`/`SetSpellVariant`, modify `BuildQueueFromPreset`)
- Test: `buffbot/BfBotTst.lua` (add persistence round-trip tests)

**Context:**
- Per-spell config: `{on, tgt, pri, tgtUnlock, var}` — `var` is new, optional string (variant resref).
- No schema bump needed (additive field).
- `BuildQueueFromPreset` at line 869 builds queue entries. Must pass `var` through.
- Queue entry format: `{caster, spell, target, durCat, var}`.

**Step 1: Add accessors to `BfBotPer.lua`**

After `GetTgtUnlock`/`SetTgtUnlock` (~line 436):

```lua
--- Get the selected variant resref for a spell in a preset.
--- @return string|nil: variant resref, or nil if not set
function BfBot.Persist.GetSpellVariant(sprite, presetIndex, resref)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset or not preset.spells or not preset.spells[resref] then return nil end
    return preset.spells[resref].var
end

--- Set the selected variant resref for a spell in a preset.
function BfBot.Persist.SetSpellVariant(sprite, presetIndex, resref, variantResref)
    local preset = BfBot.Persist.GetPreset(sprite, presetIndex)
    if not preset then return end
    if not preset.spells[resref] then
        preset.spells[resref] = BfBot.Persist._MakeDefaultSpellEntry(nil)
    end
    preset.spells[resref].var = variantResref  -- string or nil to clear
end
```

**Step 2: Modify `BuildQueueFromPreset`**

In `BuildQueueFromPreset` (~line 908-916), when appending to queue, include `var`:

```lua
for _, e in ipairs(entries) do
    local scanData = castable[e.spell]
    local spellCfg = preset.spells[e.spell]
    table.insert(queue, {
        caster = e.caster,
        spell  = e.spell,
        target = e.target,
        durCat = scanData and scanData.durCat or "short",
        var    = spellCfg and spellCfg.var or nil,
    })
end
```

**Step 3: Write tests**

Add to `BfBot.Test.SubwindowDetection()` or new section:
1. `SetSpellVariant` / `GetSpellVariant` round-trip: set "SPWI319", get back "SPWI319"
2. `SetSpellVariant` with nil clears the field
3. `GetSpellVariant` on spell without `var` returns nil
4. `BuildQueueFromPreset` with a variant spell includes `var` in queue entry (requires a character with the spell available — may be structural only)

**Step 4: Run tests, commit**

```bash
git add buffbot/BfBotPer.lua buffbot/BfBotTst.lua
git commit -m "feat(persist): add variant field to spell config and queue building (#20)"
```

---

### Task 3: Add `_ConsumeSpellSlot` and variant execution path

**Files:**
- Modify: `buffbot/BfBotExe.lua` (add `_ConsumeSpellSlot`, modify `_ProcessCasterEntry`, modify `_CheckEntry`)
- Test: `buffbot/BfBotTst.lua`

**Context:**
- Memorized spells: `sprite.m_memorizedSpellsMage:getReference(level)` (0-based level index)
- Each entry: `spell.m_spellId:get()` → resref, `spell.m_flags` → 1 (available) / 0 (cast), **writable**
- Priest: `sprite.m_memorizedSpellsPriest:getReference(level)`
- Innate: `sprite.m_memorizedSpellsInnate:getReference(0)` (all innates at index 0)
- Spell level from SPL header: `header.spellLevel` (1-based, subtract 1 for array index)
- Resref prefix convention: `SPWI` = mage, `SPPR` = priest, else = innate
- `ReallyForceSpellRES` for variant cast, `EEex_LuaAction` for advance callback (same as normal path)

**Step 1: Add `_ConsumeSpellSlot` to `BfBotExe.lua`**

Add after `_HasActiveEffect` (~line 50):

```lua
--- Programmatically consume one spell slot for a given spell resref.
--- Sets m_flags = 0 on the first available memorized entry matching the resref.
--- @param sprite userdata: the casting sprite
--- @param resref string: the parent spell resref to consume
--- @return boolean: true if slot consumed, false if no available slot found
function BfBot.Exec._ConsumeSpellSlot(sprite, resref)
    if not sprite or not resref then return false end

    -- Determine spell list and level
    local prefix = resref:sub(1, 4):upper()
    local listField
    if prefix == "SPWI" then
        listField = "m_memorizedSpellsMage"
    elseif prefix == "SPPR" then
        listField = "m_memorizedSpellsPriest"
    else
        listField = "m_memorizedSpellsInnate"
    end

    -- Get spell level from SPL header (1-based in header, 0-based in array)
    local levelIndex = 0
    local hdrOk, header = pcall(EEex_Resource_Demand, resref, "SPL")
    if hdrOk and header then
        levelIndex = (header.spellLevel or 1) - 1
    end
    -- Innates are all at index 0
    if listField == "m_memorizedSpellsInnate" then levelIndex = 0 end

    -- Find and consume
    local consumed = false
    local ok = pcall(function()
        local memList = sprite[listField]
        if not memList then return end
        local levelList = memList:getReference(levelIndex)
        if not levelList then return end
        EEex_Utility_IterateCPtrList(levelList, function(spell)
            if consumed then return true end  -- already found one
            local sid = spell.m_spellId:get()
            if sid == resref and spell.m_flags == 1 then
                spell.m_flags = 0
                consumed = true
                return true  -- stop iteration
            end
        end)
    end)

    return ok and consumed
end
```

**Step 2: Modify `_CheckEntry` for variant skip detection**

In `_CheckEntry` (~line 294), when checking `_HasActiveEffect`, use the variant resref if present:

```lua
-- Effect list check — use variant resref for variant spells (variant produces the buff)
local checkResref = entry.var or entry.resref
if BfBot.Exec._HasActiveEffect(targetSprite, checkResref) then
    BfBot.Exec._LogEntry("SKIP", label .. " (already active)")
    BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
    return false
end
```

**Step 3: Modify `_ProcessCasterEntry` for variant casting path**

In `_ProcessCasterEntry` (~line 357-367), add variant branch before the normal cast:

```lua
if entry.var then
    -- Variant spell path: consume parent slot, cast variant directly
    if not BfBot.Exec._ConsumeSpellSlot(entry.casterSprite, entry.resref) then
        BfBot.Exec._LogEntry("SKIP",
            entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName
            .. " (no slot for variant)")
        BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
        BfBot.Exec._ProcessCasterEntry(slot, index + 1)
        return
    end
    local varAction = string.format('ReallyForceSpellRES("%s",%s)', entry.var, entry.targetObj)
    local advanceAction = string.format('EEex_LuaAction("BfBot.Exec._Advance(%d)")', slot)
    EEex_Action_QueueResponseStringOnAIBase(varAction, entry.casterSprite)
    EEex_Action_QueueResponseStringOnAIBase(advanceAction, entry.casterSprite)
    BfBot.Exec._LogEntry("CAST",
        entry.casterName .. " -> " .. entry.spellName .. " [" .. entry.var .. "] -> " .. entry.targetName)
    BfBot.Exec._castCount = BfBot.Exec._castCount + 1
else
    -- Normal path (existing code, unchanged)
    local spellAction = string.format('SpellRES("%s",%s)', entry.resref, entry.targetObj)
    local advanceAction = string.format('EEex_LuaAction("BfBot.Exec._Advance(%d)")', slot)
    EEex_Action_QueueResponseStringOnAIBase(spellAction, entry.casterSprite)
    EEex_Action_QueueResponseStringOnAIBase(advanceAction, entry.casterSprite)
    BfBot.Exec._LogEntry("CAST",
        entry.casterName .. " -> " .. entry.spellName .. " -> " .. entry.targetName)
    BfBot.Exec._castCount = BfBot.Exec._castCount + 1
end
```

**Step 4: Add safety skip for unconfigured variant spells**

At the top of `_ProcessCasterEntry`, after the `_CheckEntry` call (~line 334):

```lua
-- Safety: variant spell with no variant configured → skip
local scanData = BfBot.Scan.GetCastableSpells(entry.casterSprite)
local spellScan = scanData and scanData[entry.resref]
if spellScan and spellScan.hasVariants == 1 and not entry.var then
    BfBot.Exec._LogEntry("SKIP",
        entry.casterName .. " -> " .. entry.spellName .. " (no variant configured)")
    BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
    BfBot.Exec._ProcessCasterEntry(slot, index + 1)
    return
end
```

**Step 5: Write tests**

Add to `BfBot.Test.SubwindowDetection()`:
1. `_ConsumeSpellSlot` function exists and is callable
2. Structural: verify variant branch exists in `_ProcessCasterEntry` (check function string or simply verify no errors with a mock-like test)
3. `_CheckEntry` uses `entry.var` for active effect check when present

**Step 6: Run tests, commit**

```bash
git add buffbot/BfBotExe.lua buffbot/BfBotTst.lua
git commit -m "feat(exec): variant spell slot consumption and direct cast (#20)"
```

---

### Task 4: Add variant picker UI

**Files:**
- Modify: `buffbot/BfBotUI.lua` (add variant picker functions, modify toggle gate)
- Modify: `buffbot/BuffBot.menu` (add BUFFBOT_VARIANTS sub-menu, add variant button set)
- Test: `buffbot/BfBotTst.lua`

**Context:**
- Current row 1 buttons at y=434: Enable(350,120) | Target(476,160) | Up(642,48) | Down(694,48) | Delete(740,130)
- Two button sets in .menu: normal (shown when `not buffbot_selectedHasVariants`) and variant (shown when `buffbot_selectedHasVariants`), with squeezed widths.
- BUFFBOT_VARIANTS sub-menu: simple list, icon+name, single selection.
- Enable gate: `ToggleSpell` must check `hasVariants` + `var` before enabling.
- Global: `buffbot_selectedHasVariants` (0/1), `buffbot_variantTable` (array for list), `buffbot_variantHeader` (header text).

**Step 1: Add Lua globals and variant state**

In `BfBotUI.lua`, near the top where globals are initialized:

```lua
buffbot_selectedHasVariants = 0
buffbot_variantTable = {}
buffbot_variantHeader = ""
```

**Step 2: Update `_Refresh` to populate variant info**

In `_Refresh`, when building `buffbot_spellTable` entries, include `hasVariants` and `variants` from scan data. Also set `buffbot_selectedHasVariants` based on current selection.

**Step 3: Add variant picker functions**

```lua
function BfBot.UI.OpenVariantsForSelected()
    -- Get selected spell's variants from scan data
    -- Populate buffbot_variantTable
    -- Push BUFFBOT_VARIANTS menu
end

function BfBot.UI.SelectVariant(row)
    -- Set the variant via SetSpellVariant
    -- Update buffbot_spellTable entry
    -- Pop BUFFBOT_VARIANTS menu
end

function BfBot.UI._VariantBtnText()
    -- Return "Variant: Fire" or "Variant: (none)"
end
```

**Step 4: Modify `ToggleSpell` for enable gate**

In `ToggleSpell` (~line 518), before toggling enable, check:

```lua
function BfBot.UI.ToggleSpell(row)
    local entry = buffbot_spellTable[row]
    if not entry or entry.castable == 0 then return end

    -- Enable gate: variant spell without variant selected → open picker instead
    if entry.hasVariants == 1 and entry.on == 0 and not entry.var then
        BfBot.UI.OpenVariants(row)
        return
    end

    -- ... existing toggle logic ...
end
```

**Step 5: Add BUFFBOT_VARIANTS sub-menu to BuffBot.menu**

Model after BUFFBOT_SPELLPICKER or BUFFBOT_TARGETS. Simple list with icon + name columns. Click to select + done.

**Step 6: Add dual button layout to BuffBot.menu**

Duplicate the Enable/Target/Up/Down/Delete buttons with `enabled` guards:
- Normal set: `enabled "buffbot_selectedHasVariants == 0 or buffbot_selectedHasVariants == nil"`
- Variant set: `enabled "buffbot_selectedHasVariants == 1"` with squeezed widths and added Variant button

**Step 7: Write tests**

1. `OpenVariantsForSelected` exists and is callable
2. `SelectVariant` exists and is callable
3. `_VariantBtnText` returns expected text
4. `buffbot_selectedHasVariants` global is set correctly on refresh

**Step 8: Run tests, commit**

```bash
git add buffbot/BfBotUI.lua buffbot/BuffBot.menu buffbot/BfBotTst.lua
git commit -m "feat(ui): add variant picker for opcode 214 spells (#20)"
```

---

### Task 5: Integrate tests into RunAll and update CLAUDE.md

**Files:**
- Modify: `buffbot/BfBotTst.lua` (integrate `SubwindowDetection` into `RunAll`)
- Modify: `CLAUDE.md` (add subwindow selection documentation)

**Step 1: Add Phase 11 to `RunAll`**

In `RunAll()` (~line 1284), after Combat Safety:

```lua
-- Phase 11: Subwindow Selection
local subwinOk = BfBot.Test.SubwindowDetection()
P("")
```

Update the summary block to include the new phase.
Update the return to include `subwinOk`.

**Step 2: Update CLAUDE.md**

Add "Subwindow Selection" bullet to Current Phase list. Add execution engine details about variant path. Add `BfBot.Test.SubwindowDetection()` to test commands. Document the opcode 214 detection mechanism, variant persistence, and slot consumption pattern.

**Step 3: Commit**

```bash
git add buffbot/BfBotTst.lua CLAUDE.md
git commit -m "docs: add subwindow selection details to CLAUDE.md and tests (#20)"
```

---

### Task 6: Deploy, run tests, and verify in-game

**Step 1: Deploy**

```bash
bash tools/deploy.sh
```

**Step 2: Run all tests**

In EEex console: `BfBot.Test.RunAll()`
Expected: All phases pass including Phase 11 (Subwindow Detection)

**Step 3: Run subwindow-specific tests**

In EEex console: `BfBot.Test.SubwindowDetection()`
Expected: All individual tests pass

**Step 4: Manual in-game verification** (deferred to when character has SPWI422 memorized)

- Open BuffBot panel (F11)
- Find Protection from Elemental Energy in spell list
- Verify variant button appears
- Select Fire variant
- Enable the spell
- Cast via BuffBot
- Verify: Protection from Fire effects applied, no subwindow, slot consumed

**Step 5: Commit any fixes from testing**
