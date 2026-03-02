# Classifier False Positive Reduction — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce false positive buff classifications by adding self-referencing opcode discounts, a substance check gate, selfReplace penalty, and BFBT prefix filtering — all as generic heuristics with no hardcoded resref lists.

**Architecture:** Two changes to `BfBot.Class` (scoring + classification), one to `BfBot.Scan` (prefix filter), test updates. The classifier already scores opcodes and tracks selfReplace; we extend the opcode loop to detect self-referencing 318/324, track a `hasSubstantive` flag, and add post-score gates in `Classify`.

**Tech Stack:** Lua (EEex runtime), .menu files (unchanged), in-game test suite (`BfBot.Test.RunAll()`)

**Design doc:** `docs/plans/2026-03-03-classifier-false-positives-design.md`

---

### Task 1: Modify ScoreOpcodes — self-ref discount + hasSubstantive + expand selfReplace

**Files:**
- Modify: `src/BfBotCls.lua:322-372` (ScoreOpcodes function)

**Context:** `ScoreOpcodes` iterates all feature blocks, sums opcode scores, extracts SPLSTATEs, and detects selfReplace (opcode 321 only). We need to:
1. Detect self-referencing opcode 318/324 (resource field matches spell's own resref) and skip their +2 score
2. Expand selfReplace detection to include opcode 318 self-ref (toggle mechanism)
3. Track `hasSubstantive` — true if any positive-scoring opcode that isn't "soft" (17 Healing, 171 Give Ability) contributed
4. Make opcode 321 self-ref check case-insensitive (consistency with new 318/324 check)
5. Return `hasSubstantive` in the extras table

**Step 1: Replace the ScoreOpcodes function**

Replace `src/BfBotCls.lua` lines 320-372 with:

```lua
--- Step 3: Scan all feature blocks and compute opcode score.
--- Also extracts SPLSTATE IDs, self-replace flag, AoE signals,
--- and whether any substantive buff opcode contributed.
--- "Soft" opcodes (17=Healing, 171=Give Ability) score normally
--- but don't count as substantive evidence of a buff.
--- Self-referencing opcodes 318/324 (anti-stacking / toggle
--- infrastructure) are discounted to 0 instead of +2.
function BfBot.Class.ScoreOpcodes(header, ability, resref)
    local score = 0
    local splstates = {}
    local selfReplace = false
    local fbAoE = false
    local hasSubstantive = false

    -- Soft opcodes: positive score but not substantive buff effects
    local SOFT_OPCODES = {[17] = true, [171] = true}

    local resrefUpper = resref and resref:upper() or nil

    BfBot.Class._IterateFeatureBlocks(header, ability, function(fb, _)
        local opcode = fb[BfBot._fields.fb_opcode]
        if not opcode then return end

        -- Check for self-referencing protection/immunity opcodes
        local isSelfRef = false
        if (opcode == 318 or opcode == 324) and resrefUpper then
            local ok, resVal = pcall(function()
                return fb[BfBot._fields.fb_res]:get()
            end)
            if ok and resVal and resVal:upper() == resrefUpper then
                isSelfRef = true
                -- opcode 318 self-ref = toggle mechanism (like stances)
                if opcode == 318 then
                    selfReplace = true
                end
            end
        end

        -- Opcode scoring (skip self-referencing 318/324)
        local opScore = BfBot.Class._OPCODE_SCORES[opcode]
        if opScore then
            if isSelfRef then
                -- Don't add score for self-referencing protection/immunity
                -- (SCS anti-stacking or mod toggle infrastructure)
            else
                score = score + opScore
                -- Track substantive buff opcodes (positive, non-soft)
                if opScore > 0 and not SOFT_OPCODES[opcode] then
                    hasSubstantive = true
                end
            end
        end

        -- Extract SPLSTATE IDs from opcodes 282 and 328
        if opcode == 282 or opcode == 328 then
            local stateID = fb[BfBot._fields.fb_param2]
            if stateID and stateID > 0 then
                table.insert(splstates, stateID)
            end
        end

        -- Detect self-replace: opcode 321 (Remove Effects by Resource)
        -- targeting the spell's own resref
        if opcode == 321 and resrefUpper then
            local ok, resVal = pcall(function()
                return fb[BfBot._fields.fb_res]:get()
            end)
            if ok and resVal and resVal:upper() == resrefUpper then
                selfReplace = true
            end
        end

        -- AoE signal from feature block target type
        local fbTarget = fb[BfBot._fields.fb_target]
        if fbTarget then
            -- 4 = everyone, 6 = caster's group
            if fbTarget == 4 or fbTarget == 6 then
                fbAoE = true
            end
        end
    end)

    return score, {
        splstates = splstates,
        selfReplace = selfReplace,
        fbAoE = fbAoE,
        hasSubstantive = hasSubstantive,
    }
end
```

**Step 2: Commit**

```bash
git add src/BfBotCls.lua
git commit -m "feat(classifier): self-ref opcode discount + hasSubstantive tracking"
```

---

### Task 2: Modify Classify — selfReplace penalty + substance check

**Files:**
- Modify: `src/BfBotCls.lua:473-548` (Classify function)

**Context:** `Classify` computes targeting, MSECTYPE, and opcode scores, then applies a threshold (>=3 = buff, <=-3 = not, between = ambiguous). We add:
1. Store `hasSubstantive` from ScoreOpcodes extras
2. A selfReplace penalty of -8 applied to the total score (before threshold)
3. A substance check after threshold: if classified as buff but `hasSubstantive == false`, override to non-buff

**Step 1: Replace the Classify function**

Replace `src/BfBotCls.lua` lines 468-548 with:

```lua
-- ============================================================
-- Main Classification Function
-- ============================================================

--- Full classification of a spell. Returns a ClassResult table.
--- Results are cached by resref (SPL data does not change in-session).
function BfBot.Class.Classify(resref, header, ability)
    -- Check cache
    local cached = BfBot._cache.class[resref]
    if cached then return cached end

    local result = {}
    result.msectype = header.secondaryType or 0

    -- Check user override
    local override = BfBot.Class.GetOverride(resref)
    if override ~= nil then
        result.isBuff = override
        result.isAmbiguous = false
        result.overridden = true
        result.score = override and 10 or -10
        result.targetScore = 0
        result.msecScore = 0
        result.opcodeScore = 0
        result.selfReplacePenalty = 0
        result.splstates = {}
        result.selfReplace = false
        result.hasSubstantive = true
        result.noSubstance = false
        result.friendlyFlag = false

        -- Still compute duration, AoE, defaultTarget (useful regardless)
        result.duration, _ = BfBot.Class.GetDuration(header, ability)
        result.durCat = BfBot.Class.GetDurationCategory(result.duration)
        result.isAoE = BfBot.Class.IsAoE(ability, false)
        result.defaultTarget = BfBot.Class.GetDefaultTarget(ability, result.isAoE)

        BfBot._cache.class[resref] = result
        return result
    end

    result.overridden = false
    result.noSubstance = false

    -- Step 1: Targeting score
    result.targetScore, result.friendlyFlag = BfBot.Class.ScoreTargeting(ability)

    -- Step 2: MSECTYPE score
    result.msecScore = BfBot.Class.ScoreMSECTYPE(header)

    -- Step 3: Opcode score + extract metadata
    local opcodeExtras
    result.opcodeScore, opcodeExtras = BfBot.Class.ScoreOpcodes(header, ability, resref)
    result.splstates = opcodeExtras.splstates
    result.selfReplace = opcodeExtras.selfReplace
    result.hasSubstantive = opcodeExtras.hasSubstantive

    -- selfReplace penalty: toggle/stance spells are not prebuffs
    result.selfReplacePenalty = result.selfReplace and -8 or 0

    -- Total score
    result.score = result.targetScore + result.msecScore
        + result.opcodeScore + result.selfReplacePenalty

    -- Step 4: Threshold
    if result.score >= 3 then
        result.isBuff = true
        result.isAmbiguous = false
    elseif result.score <= -3 then
        result.isBuff = false
        result.isAmbiguous = false
    else
        -- Ambiguous: lean buff if score >= 0
        result.isAmbiguous = true
        result.isBuff = (result.score >= 0)
    end

    -- Step 5: Substance check
    -- If score passed threshold but no substantive buff opcode
    -- contributed, the score came entirely from targeting/MSECTYPE/
    -- infrastructure. Not a real buff.
    if result.isBuff and not result.hasSubstantive then
        result.isBuff = false
        result.isAmbiguous = true
        result.noSubstance = true
    end

    -- Duration
    result.duration, _ = BfBot.Class.GetDuration(header, ability)
    result.durCat = BfBot.Class.GetDurationCategory(result.duration)

    -- AoE
    result.isAoE = BfBot.Class.IsAoE(ability, opcodeExtras.fbAoE)

    -- Default target
    result.defaultTarget = BfBot.Class.GetDefaultTarget(ability, result.isAoE)

    -- Cache and return
    BfBot._cache.class[resref] = result
    return result
end
```

**Step 2: Commit**

```bash
git add src/BfBotCls.lua
git commit -m "feat(classifier): selfReplace penalty + substance check gate"
```

---

### Task 3: Add BFBT prefix filter in scanner

**Files:**
- Modify: `src/BfBotScn.lua:97` (inside processButtonList, after resref extraction)

**Context:** After extracting the resref from a button entry, skip any spell whose resref starts with `"BFBT"`. This filters BuffBot's own generated innate abilities.

**Step 1: Add the filter**

In `src/BfBotScn.lua`, after line 97 (`if not resOk or not resref or resref == "" then return end`), insert:

```lua
                -- Skip BuffBot's own generated innates
                if resref:sub(1, 4) == "BFBT" then return end
```

**Step 2: Commit**

```bash
git add src/BfBotScn.lua
git commit -m "feat(scanner): filter out BuffBot's own BFBT innate spells"
```

---

### Task 4: Update tests — VerifyKnownSpells + DumpFeatureBlocks diagnostic

**Files:**
- Modify: `src/BfBotTst.lua:529-551` (VerifyKnownSpells expectations list)
- Modify: `src/BfBotTst.lua:438-458` (DumpClassification output)
- Modify: `src/BfBotTst.lua:508-516` (DumpFeatureBlocks score annotation)

**Context:** Add false positive spells as `expected = false` entries in VerifyKnownSpells. Update DumpClassification and DumpFeatureBlocks to display new fields (hasSubstantive, selfReplacePenalty, noSubstance, self-ref detection).

**Step 1: Update VerifyKnownSpells expectations**

Replace the `expectations` table in `src/BfBotTst.lua` (lines 529-551) with:

```lua
    local expectations = {
        -- Definite buffs
        { "SPWI305", true,  "Haste" },
        { "SPWI408", true,  "Stoneskin" },
        { "SPPR101", true,  "Bless" },
        { "SPPR107", true,  "Protection from Evil" },
        { "SPWI114", true,  "Shield" },
        { "SPWI212", true,  "Mirror Image" },
        { "SPPR409", true,  "Death Ward" },
        { "SPPR508", true,  "Chaotic Commands" },
        { "SPWI613", true,  "Improved Haste" },
        { "SPWI108", true,  "Armor" },
        { "SPPR201", true,  "Aid" },
        { "SPPR207", true,  "Barkskin" },
        -- Definite non-buffs
        { "SPWI304", false, "Fireball" },
        { "SPWI211", false, "Stinking Cloud" },
        { "SPWI112", false, "Magic Missile" },
        { "SPWI509", false, "Animate Dead" },
        { "SPWI503", false, "Cloudkill" },
        { "SPWI116", false, "Chromatic Orb" },
        -- Former false positives: traps (no substantive opcodes)
        { "SPCL412", false, "Set Snare" },
        { "SPCL910", false, "Set Spike Trap" },
        -- Former false positives: setup spells (no substantive opcodes)
        { "SPIN141", false, "Contingency" },
        { "SPIN142", false, "Chain Contingency" },
        -- Former false positives: pure heals (only op=17 soft)
        { "SPIN101", false, "Cure Light Wounds" },
        { "SPPR212", false, "Slow Poison" },
        -- Former false positives: offensive (324 self-ref discount)
        { "SPCL311", false, "Charm Animal" },
        -- Former false positives: stances (318 self-ref -> selfReplace)
        -- These are mod-specific; will be skipped if SPL not found:
        { "C0FIG01", false, "Power Attack (stance)" },
        { "SPCL922", false, "Tracking" },
        -- Edge cases (no expectation — just log the result)
        { "SPWI317", nil,   "Remove Magic" },
        { "SPCL908", nil,   "War Cry" },
        { "SPWI523", nil,   "Fireburst" },
    }
```

**Step 2: Update DumpClassification output**

In `src/BfBotTst.lua`, after line 456 (`P("  selfReplace: " .. tostring(result.selfReplace))`), add:

```lua
    P("  hasSubstantive: " .. tostring(result.hasSubstantive))
    P("  noSubstance: " .. tostring(result.noSubstance))
    if result.selfReplacePenalty and result.selfReplacePenalty ~= 0 then
        P("  selfReplacePenalty: " .. tostring(result.selfReplacePenalty))
    end
```

Also update the scoring summary at line 444 to include selfReplacePenalty:

Replace line 445:
```lua
    P("  TOTAL SCORE: " .. tostring(result.score))
```
With:
```lua
    P("  TOTAL SCORE: " .. tostring(result.score)
        .. (result.selfReplacePenalty and result.selfReplacePenalty ~= 0
            and (" (incl selfReplace " .. result.selfReplacePenalty .. ")")
            or ""))
```

**Step 3: Update DumpFeatureBlocks score annotation**

In `src/BfBotTst.lua`, update the score annotation in DumpFeatureBlocks (lines 508-512) to show self-ref detection:

Replace:
```lua
        local score = BfBot.Class._OPCODE_SCORES[opcode] or 0
        local scoreStr = ""
        if score > 0 then scoreStr = " [+" .. score .. "]"
        elseif score < 0 then scoreStr = " [" .. score .. "]"
        end
```

With:
```lua
        local score = BfBot.Class._OPCODE_SCORES[opcode] or 0
        local scoreStr = ""
        -- Detect self-referencing 318/324 for annotation
        local isSelfRef = false
        if (opcode == 318 or opcode == 324) and resref then
            local selfUpper = resref:upper()
            if resVal and resVal:upper() == selfUpper then
                isSelfRef = true
            end
        end
        if isSelfRef then
            scoreStr = " [+" .. score .. " SELF-REF→0]"
        elseif score > 0 then
            scoreStr = " [+" .. score .. "]"
        elseif score < 0 then
            scoreStr = " [" .. score .. "]"
        end
```

**Step 4: Commit**

```bash
git add src/BfBotTst.lua
git commit -m "test: update classifier tests for false positive reduction"
```

---

### Task 5: Deploy and verify in-game

**Files:** None (deployment + testing)

**Step 1: Deploy to game**

```bash
bash tools/deploy.sh
```

**Step 2: In-game verification**

Restart game (or reload) and run in EEex console:

```lua
BfBot.Test.RunAll()
```

**Expected results:**
- CheckFields: PASS (unchanged)
- VerifyKnownSpells: PASS — all new `false` expectations should pass (Set Snare, Contingency, Cure Light Wounds, Charm Animal, stances, Tracking now classified as non-buff)
- ScanAll: PASS — buff counts should be noticeably lower per character (traps, setup spells, heals, stances removed)
- Persistence: PASS (unchanged)
- Quick Cast: PASS (unchanged)

**Step 3: Spot-check with DumpClassification**

Run diagnostics on a few key spells to verify scoring details:

```lua
BfBot._OpenLogAppend()
BfBot.Test.DumpClassification("SPCL412")
BfBot.Test.DumpClassification("SPIN141")
BfBot.Test.DumpClassification("C0FIG01")
BfBot.Test.DumpClassification("SPIN101")
BfBot.Test.DumpClassification("SPWI305")
BfBot._CloseLog()
```

Expected: SPCL412/SPIN141/C0FIG01/SPIN101 show `isBuff: false`, SPWI305 shows `isBuff: true`.

**Step 4: Commit deploy script changes if any, push**

```bash
git push
```
