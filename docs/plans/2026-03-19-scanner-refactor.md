# Scanner Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace GetQuickButtons-based scanner with known spells iterators as the primary catalog source, add `isAoE`/`isSelfOnly` to scan entries.

**Architecture:** Three known spells iterators build a complete catalog of every spell in the character's spellbook. GetQuickButtons provides slot counts as an overlay. Consumers get richer data (targeting flags, exhausted spell metadata) with simpler code paths.

**Tech Stack:** EEex Lua, IE engine SPL headers, BfBot module system

---

### Task 1: Add `isSelfOnly` to classifier

**Files:**
- Modify: `buffbot/BfBotCls.lua:477-495` (IsAoE/GetDefaultTarget section)
- Modify: `buffbot/BfBotCls.lua:519-611` (Classify function)

**Step 1: Add `IsSelfOnly` helper function**

In `BfBotCls.lua`, after the `IsAoE` function (line 484), add:

```lua
--- Determine if a spell is self-only (cannot target others).
--- Target type 5 = caster, 7 = caster (instant/default).
function BfBot.Class.IsSelfOnly(ability)
    local targetType = ability.actionType
    return (targetType == 5 or targetType == 7)
end
```

**Step 2: Add `isSelfOnly` to Classify result**

In the `Classify` function, add `isSelfOnly` wherever `isAoE` is set. There are two locations:

1. In the override branch (~line 545), after `result.isAoE = ...`:
```lua
result.isSelfOnly = BfBot.Class.IsSelfOnly(ability)
```

2. In the normal path (~line 603), after `result.isAoE = ...`:
```lua
result.isSelfOnly = BfBot.Class.IsSelfOnly(ability)
```

**Step 3: Commit**

```bash
git add buffbot/BfBotCls.lua
git commit -m "feat(class): add isSelfOnly to classification result (#17)"
```

---

### Task 2: Rewrite scanner with known spells iterators

**Files:**
- Modify: `buffbot/BfBotScn.lua` (rewrite `GetCastableSpells`, remove dead code)

This is the core change. Replace the entire `GetCastableSpells` implementation and remove `GetSpellMetadata`.

**Step 1: Replace `_buildSpellEntry` with `_buildCatalogEntry`**

The new builder takes iterator-provided data (resref, ability from iterator, header from EEex_Resource_Demand) instead of button data. It handles the Spell Revisions strref 9999999 gotcha.

Replace `_buildSpellEntry` (lines 9-74) with:

```lua
--- Safe strref lookup — skips invalid/dummy strrefs (0, -1, 0xFFFFFFFF, SR's 9999999).
local function _tryStrref(strref)
    if not strref or strref == 0xFFFFFFFF or strref == -1
       or strref == 0 or strref == 9999999 then
        return nil
    end
    local ok, fetched = pcall(Infinity_FetchString, strref)
    if ok and fetched and fetched ~= "" then return fetched end
    return nil
end

--- Internal: Build a catalog entry from known spells iterator data + SPL header.
local function _buildCatalogEntry(sprite, resref, header, ability)
    -- Name: try genericName (unidentified, 0x08) first — Spell Revisions
    -- puts the real name there and sets identifiedName (0x0C) to dummy 9999999.
    local name = _tryStrref(header.genericName)
                 or _tryStrref(header.identifiedName)
                 or resref

    -- Spell type from header
    local spellType = header.itemType or 0

    -- Icon from ability
    local icon = ""
    if ability then
        local ok, abilIcon = pcall(function()
            return ability.quickSlotIcon:get()
        end)
        if ok and abilIcon and abilIcon ~= "" then
            icon = abilIcon
        end
    end

    -- Classify
    local classResult = nil
    if header and ability then
        local ok, result = pcall(BfBot.Class.Classify, resref, header, ability)
        if ok then
            classResult = result
        else
            BfBot._Warn("Classification failed for " .. resref .. ": " .. tostring(result))
        end
    end

    -- Duration (per caster level)
    local duration = 0
    local durCat = "instant"
    if header and ability then
        duration = BfBot.Class.GetDuration(header, ability)
        durCat = BfBot.Class.GetDurationCategory(duration)
    end

    -- Targeting flags (mirrored from classification for flat access)
    local isAoE = (classResult and classResult.isAoE) and 1 or 0
    local isSelfOnly = (classResult and classResult.isSelfOnly) and 1 or 0

    return {
        resref = resref,
        name = name,
        icon = icon,
        count = 0,          -- filled in by count overlay
        level = header.spellLevel or 0,
        spellType = spellType,
        duration = duration,
        durCat = durCat,
        isAoE = isAoE,
        isSelfOnly = isSelfOnly,
        class = classResult,
    }
end
```

**Step 2: Add `_buildCountMap` helper**

This extracts slot counts from GetQuickButtons into a flat lookup table. Add after `_buildCatalogEntry`:

```lua
--- Internal: Build {[resref] = count} from GetQuickButtons.
--- type: 2 = wizard+priest, 4 = innate.
local function _buildCountMap(sprite)
    local counts = {}

    local function processButtons(btnType)
        local ok, buttonList = pcall(function()
            return sprite:GetQuickButtons(btnType, false)
        end)
        if not ok or not buttonList then return end

        local iterOk, iterErr = pcall(function()
            EEex_Utility_IterateCPtrList(buttonList, function(bd)
                local resOk, resref = pcall(function()
                    return bd.m_abilityId.m_res:get()
                end)
                if not resOk or not resref or resref == "" then return end

                local bdCount = 0
                pcall(function() bdCount = bd.m_count end)
                if bdCount <= 0 then bdCount = 1 end

                counts[resref] = (counts[resref] or 0) + bdCount
            end)
        end)

        -- Always free the list
        pcall(EEex_Utility_FreeCPtrList, buttonList)

        if not iterOk then
            BfBot._Warn("Count map iteration failed: " .. tostring(iterErr))
        end
    end

    processButtons(2)  -- wizard + priest
    processButtons(4)  -- innate

    return counts
end
```

**Step 3: Rewrite `GetCastableSpells`**

Replace the entire `GetCastableSpells` function (lines 78-272) with:

```lua
--- Scan all known spells for a party member.
--- Returns a table keyed by resref and total spell count.
--- Uses known spells iterators as primary catalog, GetQuickButtons for counts.
function BfBot.Scan.GetCastableSpells(sprite)
    if not sprite then return {}, 0 end

    -- Check scan cache
    local spriteID = nil
    local ok, id = pcall(function() return sprite.m_id end)
    if ok and id then
        spriteID = id
        local cached = BfBot._cache.scan[spriteID]
        if cached then
            return cached.spells, cached.count
        end
    end

    local spells = {}
    local count = 0
    local seen = {}

    -- Phase 1: Build catalog from known spells iterators
    local iterators = {
        { fn = "EEex_Sprite_GetKnownMageSpellsWithAbilityIterator",   name = "mage" },
        { fn = "EEex_Sprite_GetKnownPriestSpellsWithAbilityIterator", name = "priest" },
        { fn = "EEex_Sprite_GetKnownInnateSpellsWithAbilityIterator", name = "innate" },
    }

    for _, iter in ipairs(iterators) do
        local iterFn = _G[iter.fn]
        if not iterFn then
            BfBot._Warn("Iterator not available: " .. iter.fn)
            goto nextIter
        end

        local iterOk, iterErr = pcall(function()
            for lvl, idx, resref, ability in iterFn(sprite) do
                if resref and resref ~= "" and not seen[resref] then
                    -- Skip BuffBot's own generated innates
                    if resref:sub(1, 4) ~= "BFBT" then
                        seen[resref] = true

                        -- Load SPL header for classification + metadata
                        local hdrOk, header = pcall(EEex_Resource_Demand, resref, "SPL")
                        if hdrOk and header then
                            -- Use caster-level-appropriate ability if available
                            local casterLevel = 1
                            local clOk, cl = pcall(function()
                                return sprite:getCasterLevelForSpell(resref, true)
                            end)
                            if clOk and cl and cl > 0 then
                                casterLevel = cl
                            end

                            local levelAbility = header:getAbilityForLevel(casterLevel)
                            -- Fall back to iterator-provided ability, then ability index 0
                            local useAbility = levelAbility or ability
                            if not useAbility then
                                useAbility = header:getAbility(0)
                            end

                            if useAbility then
                                local entry = _buildCatalogEntry(sprite, resref, header, useAbility)
                                spells[resref] = entry
                                count = count + 1
                            end
                        end
                    end
                end
            end
        end)

        if not iterOk then
            BfBot._Warn(iter.name .. " iterator failed: " .. tostring(iterErr))
        end

        ::nextIter::
    end

    -- Phase 2: Overlay slot counts from GetQuickButtons
    local countMap = _buildCountMap(sprite)
    for resref, slotCount in pairs(countMap) do
        if spells[resref] then
            spells[resref].count = slotCount
        end
        -- Note: spells in countMap but NOT in known iterators are engine-internal
        -- or temporary — silently ignored (not part of the character's spellbook).
    end

    -- Cache results
    if spriteID then
        BfBot._cache.scan[spriteID] = {
            spells = spells,
            count = count,
        }
    end

    return spells, count
end
```

**Step 4: Remove dead code**

Delete `GetSpellMetadata` function (lines 307-358 in current file) and `GetSpellInfo` function (lines 360-393) — both are superseded. `GetSpellInfo` is only used in tests and can be replaced by reading from `GetCastableSpells` results.

Check if `GetSpellInfo` is used anywhere:

```bash
grep -rn "GetSpellInfo" buffbot/
```

If only in tests, remove it. If used elsewhere, keep it but update it.

**Step 5: Commit**

```bash
git add buffbot/BfBotScn.lua
git commit -m "feat(scan): rewrite scanner with known spells iterators (#17)

Primary catalog from GetKnownMage/Priest/InnateSpellsWithAbilityIterator.
GetQuickButtons demoted to slot count overlay. Removes GetSpellMetadata,
processButtonList, and broken disabled-pass code paths.
Adds isAoE/isSelfOnly to scan entries."
```

---

### Task 3: Update consumers, clean up, add tests

**Files:**
- Modify: `buffbot/BfBotUI.lua:354-399` (_Refresh steps 5-7)
- Modify: `buffbot/BfBotPer.lua:838,1088` (BuildQueueFromPreset, BuildQueueForCharacter)
- Modify: `buffbot/BfBotTst.lua` (update override tests, add scanner validation)

**Step 1: Update BfBotUI._Refresh**

In `_Refresh()` step 6 (auto-merge), remove the `scan.count > 0` gate. Change line 364 from:
```lua
        if not preset.spells[resref] and scan.class and scan.class.isBuff
           and scan.count > 0 and ovr ~= -1 then
```
to:
```lua
        if not preset.spells[resref] and scan.class and scan.class.isBuff
           and ovr ~= -1 then
```

In `_Refresh()` step 7 (build spell table), remove the `GetSpellMetadata` fallback. Replace lines 383-399 with:
```lua
        if scan then
            name = scan.name
            icon = scan.icon
            count = scan.count
            isCastable = (count > 0) and 1 or 0
            dur = scan.duration
            durCat = scan.durCat
        end
        -- No else branch needed: catalog from known spells iterators always
        -- has metadata. If spell is missing from catalog, it's truly gone
        -- from the spellbook (e.g., dual-class lockout) — show resref defaults.
```

Note: also remove the `not scan.disabled` check from `isCastable` — the `disabled` field no longer exists. `count > 0` is sufficient.

**Step 2: Update BfBotPer queue builders**

In `BuildQueueFromPreset` (~line 838), change:
```lua
                if scanData and scanData.count > 0 and not scanData.disabled then
```
to:
```lua
                if scanData and scanData.count > 0 then
```

In `BuildQueueForCharacter` (~line 1088), same change:
```lua
                if scanData and scanData.count > 0 and not scanData.disabled then
```
to:
```lua
                if scanData and scanData.count > 0 then
```

**Step 3: Update BfBotTst**

In `BuildTestQueue` (~line 945), change:
```lua
            if data.class and data.class.isBuff and data.count > 0 and not data.disabled then
```
to:
```lua
            if data.class and data.class.isBuff and data.count > 0 then
```

Add a new scanner validation test to verify `isAoE`/`isSelfOnly` are present and the iterator-based scan returns more spells than the old approach. Add after the existing `Override` test:

```lua
function BfBot.Test.ScannerRefactor()
    P("=== Scanner: Iterator-based catalog ===")
    _reset()

    local sprite = EEex_Sprite_GetInPortrait(0)
    if not sprite then
        _nok("No sprite in slot 0")
        return _summary("ScannerRefactor")
    end

    -- Test 1: Scan returns spells
    BfBot.Scan.Invalidate(sprite)
    local spells, count = BfBot.Scan.GetCastableSpells(sprite)
    _check(count > 0, "Scan returned " .. count .. " known spells")

    -- Test 2: Entries have isAoE and isSelfOnly fields (0/1 integers)
    local hasFlags = true
    local sample = nil
    for resref, entry in pairs(spells) do
        sample = entry
        if type(entry.isAoE) ~= "number" or type(entry.isSelfOnly) ~= "number" then
            hasFlags = false
            _nok("Missing isAoE/isSelfOnly on " .. resref
                 .. " (isAoE=" .. type(entry.isAoE)
                 .. " isSelfOnly=" .. type(entry.isSelfOnly) .. ")")
            break
        end
    end
    if hasFlags then _ok("All entries have isAoE/isSelfOnly (integer)") end

    -- Test 3: Self-only spells have isSelfOnly=1 and isAoE=0
    local foundSelf = false
    for resref, entry in pairs(spells) do
        if entry.isSelfOnly == 1 then
            foundSelf = true
            _check(entry.isAoE == 0,
                   "Self-only spell " .. entry.name .. " has isAoE=0")
            break
        end
    end
    if not foundSelf then _warning("No self-only spell found for validation") end

    -- Test 4: Exhausted spells (count=0) still have name and icon
    local foundExhausted = false
    for resref, entry in pairs(spells) do
        if entry.count == 0 and entry.class and entry.class.isBuff then
            foundExhausted = true
            _check(entry.name ~= resref,
                   "Exhausted " .. resref .. " has name: " .. entry.name)
            _check(entry.icon ~= "",
                   "Exhausted " .. resref .. " has icon: " .. entry.icon)
            break
        end
    end
    if not foundExhausted then
        _warning("No exhausted buff spell found (all have slots? cast some first)")
    end

    -- Test 5: Classification result has isSelfOnly field
    for resref, entry in pairs(spells) do
        if entry.class then
            _check(entry.class.isSelfOnly ~= nil,
                   "Classification has isSelfOnly for " .. resref)
            break
        end
    end

    return _summary("ScannerRefactor")
end
```

Add `ScannerRefactor` to the `RunAll` function (find where tests are called in sequence and add it).

**Step 4: Check `GetSpellInfo` usage**

Search for `GetSpellInfo` in all files. If only used in tests, remove the test usage or replace with `GetCastableSpells` lookup. If used in production code, update it.

**Step 5: Deploy and test**

```bash
bash tools/deploy.sh
```

Then in-game EEex console:
```lua
BfBot.Test.RunAll()
```

Verify:
- All existing tests still pass (scanner, classifier, override, persist, exec, quick cast)
- New `ScannerRefactor` test passes
- Exhausted spells show name+icon in the UI panel (F11)
- Self-only spell entries have `isSelfOnly=1`
- Spell count is larger than before (all known spells, not just memorized)

**Step 6: Commit all consumer changes**

```bash
git add buffbot/BfBotUI.lua buffbot/BfBotPer.lua buffbot/BfBotTst.lua
git commit -m "feat(scan): update consumers for iterator-based scanner (#17)

Remove disabled field checks, GetSpellMetadata fallback, count>0 gate
on auto-merge. Add ScannerRefactor test for isAoE/isSelfOnly validation."
```

---

### Post-implementation

After all tasks pass:
- Close GitHub issue #17
- Update CLAUDE.md scanner description
- Update memory with scanner refactor status
