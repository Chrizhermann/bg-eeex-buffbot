# Items + Potions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Goal:** Add support for activated equipped-item abilities and inventory potions as buff sources alongside spells. Configure by resref (durable) — engine picks the slot at use time. Listed-but-disabled by default. Closes (a)+(b) of GitHub issue #21; defers (c) scrolls and (d) wands to follow-ups.

**Architecture:** Extend `BfBotScn.lua` to walk inventory + 3 quickitems and merge `kind="itm"` entries into the existing spell catalog. Schema bump v6→v7 adds the `kind` field. Exec engine branches on `kind` to emit `UseItem("RESREF", target)` BCS for items, `SpellRES` for spells. Pre-flight already-active check uses an extended `leafResrefs` list (collected by recursing op=146 sub-spell chains in `BfBot.Class.GetDuration`) so wrapper potions are detected by the leaf SPL on the target's effect list. UI mixes both kinds in one priority-sortable list with a tinted `itemColor` palette key for item rows.

**Tech Stack:** Lua 5.1 (EEex), `.menu` DSL, WeiDU installer (no build step — deploy via `bash tools/deploy.sh`). Tests run in-game via `BfBot.Test.<Name>()` in the EEex console. Field-path probes use the EEex remote console at `C:\src\private\eeex-remote-console`.

**Reference docs:**
- Design: GitHub issue [#21 comment](https://github.com/Chrizhermann/bg-eeex-buffbot/issues/21#issuecomment-4351690202)
- BG-modding skills: `~/.claude/skills/bg-modding/references/eeex-resources.md`, `eeex-actions.md`, `eeex-sprites.md`, `ie-spell-structure.md`, `ie-targeting.md`
- Prior schema migration pattern: `docs/plans/2026-04-18-spell-lock.md` (v5→v6)

**Branch:** `feat/items-and-potions` (cut from `main`)

---

## Task 1: Cut feature branch

**Files:** none (git only).

**Step 1: Confirm clean working tree on the right branch**

```bash
git status
git log --oneline -5
```

If on `fix/stop-after-reload-crash` or another branch with uncommitted work, stop and ask the user. Otherwise:

**Step 2: Cut branch from main**

```bash
git fetch origin
git checkout -b feat/items-and-potions origin/main
git push -u origin feat/items-and-potions
```

**Step 3: Confirm**

```bash
git branch --show-current
# expected: feat/items-and-potions
```

No commit yet — code starts in Task 2.

---

## Task 2: Probe — inventory iteration

**Goal:** discover the `CGameSprite` field path that exposes the per-slot inventory list. EEex has no Lua-side iterator; only `GetQuickButtons(2|4, false)` is wired (mage+priest, innate). We need direct field access.

**Prerequisite:** game must be running on the world screen with a party. Test character should have at least 1 known potion in inventory and 1 ring/amulet equipped (e.g. give yourself `POTN15` Oil of Speed and `RING06` Ring of the Ram via `CreateItem` first).

**Step 1: Probe candidate field names via remote console**

Run, one at a time, and check which return non-nil with sensible content:

```bash
GAME_DIR='c:/Games/Baldur'\''s Gate II Enhanced Edition modded/override'
PROBE='/c/src/private/eeex-remote-console/tools/eeex-remote.sh'

# Try each candidate field name on the party leader sprite
bash "$PROBE" "$GAME_DIR" '
local sp = EEex_Sprite_GetInPortrait(0)
local names = { "m_aItems", "m_inventory", "m_chunkedInventory", "m_lstItems", "m_items" }
for _, n in ipairs(names) do
    local ok, val = pcall(function() return sp[n] end)
    if ok and val then print(n .. " = " .. tostring(val)) end
end
'
```

**Step 2: For the field that resolves, probe its structure**

If `m_aItems` (most likely) resolves, walk it:

```bash
bash "$PROBE" "$GAME_DIR" '
local sp = EEex_Sprite_GetInPortrait(0)
local list = sp.m_aItems
print("type: " .. tostring(list))
-- Try iteration patterns
pcall(function()
    EEex_Utility_IterateCPtrList(list, function(it)
        local res = it.m_pRes and it.m_pRes:get() or "?"
        local cnt = it.m_count or it.m_amount or "?"
        print("slot: " .. tostring(res) .. " x" .. tostring(cnt))
    end)
end)
'
```

If `EEex_Utility_IterateCPtrList` doesn't apply, try array indexing (`list[0]` / `list:getReference(0)`) — the pattern used by `BfBotExe._ConsumeSpellSlot` for memorized spell levels.

**Step 3: Document the verified field name + iteration pattern**

Record into a temporary note (will become bg-modding-learn entry in Task 18):

```
INVENTORY_FIELD = "m_aItems"  (or whatever resolved)
ITERATION = "EEex_Utility_IterateCPtrList(list, fn)"  (or array indexing)
SLOT_FIELDS = { resref = "m_pRes:get()", count = "m_count" }
QUICKITEM_FIELDS = (probe separately — see Step 4)
```

**Step 4: Probe quickitem slots**

3 quickitem slots are typically in a separate field:

```bash
bash "$PROBE" "$GAME_DIR" '
local sp = EEex_Sprite_GetInPortrait(0)
local names = { "m_quickItems", "m_aQuickItems", "m_quickItemSlot", "m_quickItem" }
for _, n in ipairs(names) do
    local ok, val = pcall(function() return sp[n] end)
    if ok and val then print(n .. " = " .. tostring(val)) end
end
'
```

**Step 5: Commit research note**

No code change. Capture findings in a temporary file (deleted in Task 18 once knowledge is in the bg-modding refs):

Write `tools/items_probe_findings.md` with the 4 verified facts (inventory field, iteration pattern, slot fields, quickitem field). Commit:

```bash
git add tools/items_probe_findings.md
git commit -m "research(items): verify EEex inventory + quickitem field paths

Probed via EEex remote console. Records the exact field names
to be used by BfBotScn._BuildItemCatalog. Folded into
bg-modding/references/eeex-sprites.md in Task 18."
```

---

## Task 3: Probe — UseItem BCS verb + Item:getAbility(i)

**Goal:** confirm `UseItem("RESREF", target)` queues, fires, decrements/destroys correctly; verify whether the suspected typo at `EEex_Resource.lua:165` (`Item_Header_st.sizeof` instead of `Item_ability_st.sizeof`) actually breaks multi-ability item iteration.

**Step 1: Probe `getAbility(0)` on a single-ability potion**

```bash
bash "$PROBE" "$GAME_DIR" '
local h = EEex_Resource_Demand("POTN15", "ITM")
print("abilityCount: " .. tostring(h.abilityCount))
local a = h:getAbility(0)
print("a.target: " .. tostring(a.target))
print("a.featureBlockCount: " .. tostring(a.featureBlockCount))
print("a.startingEffect: " .. tostring(a.startingEffect))
'
```

Expected: abilityCount=1, target=5 (Self), featureBlockCount≥1.

**Step 2: Probe `getAbility(0)` and `getAbility(1)` on a multi-ability item**

`BRAC09` (Bracers of Binding) has 2 abilities. Or use any ITM with `abilityCount > 1` — verify via Near Infinity if uncertain.

```bash
bash "$PROBE" "$GAME_DIR" '
local resref = "BRAC09"  -- adjust if not present in this install
local h = EEex_Resource_Demand(resref, "ITM")
if not h then print("MISSING ITM"); return end
print("abilityCount: " .. h.abilityCount)
for i = 0, h.abilityCount - 1 do
    local a = h:getAbility(i)
    print("ability " .. i .. ": target=" .. a.target
          .. " fbCount=" .. a.featureBlockCount
          .. " startEff=" .. a.startingEffect)
end
'
```

Expected if EEex typo is benign: distinct `startingEffect` values per ability. Expected if typo is real: ability i=1 returns garbage / repeats ability 0 / crashes.

**Step 3: Probe `UseItem` BCS verb**

```bash
bash "$PROBE" "$GAME_DIR" '
local sp = EEex_Sprite_GetInPortrait(0)
EEex_Action_QueueResponseStringOnAIBase("UseItem(\"POTN15\",Myself)", sp)
'
```

In-game: leader should drink Oil of Speed within ~1 second, Haste icon appears, stack count of POTN15 in inventory drops by 1.

**Step 4: Probe `UseItem` on a wand from inventory (NOT in quickslot)**

User claimed "wands can only be used from quickslot". Verify against engine:

```bash
# Move WAND09 (Wand of Heavens) to a regular inventory slot (not quickslot 1-3),
# then attempt to use it
bash "$PROBE" "$GAME_DIR" '
local sp = EEex_Sprite_GetInPortrait(0)
EEex_Action_QueueResponseStringOnAIBase("UseItem(\"WAND09\",Myself)", sp)
'
```

If it works → user's claim is engine-UI only (not a `UseItem` constraint). Record this finding for the deferred scrolls/wands work.
If it fails silently → confirm engine constraint.

**Step 5: Document findings**

Append to `tools/items_probe_findings.md`:

```
ITEM_GETABILITY_OK = true|false (and any caveats)
USEITEM_POTION_OK = true
USEITEM_WAND_FROM_INVENTORY = true|false
EQUIPPED_RING_USE_VERB = "UseItem" or "UseItemAbility" (per probe on RING06)
```

**Step 6: Commit**

```bash
git add tools/items_probe_findings.md
git commit -m "research(items): verify UseItem BCS + Item:getAbility(i) behavior"
```

---

## Task 4: Schema v7 — bump version, migrate, validate

**Files:**
- Modify: `buffbot/BfBotPer.lua` (line ~10 `_SCHEMA_VERSION`, line ~65 `_MakeDefaultSpellEntry`, validator block, migration block)

**Step 1: Bump schema version**

`buffbot/BfBotPer.lua:10`:

```lua
BfBot.Persist._SCHEMA_VERSION = 7
```

**Step 2: Add v6→v7 migration branch**

In `_MigrateConfig`, after the `if fromVersion < 6 then ... end` block, add:

```lua
if fromVersion < 7 then
    -- Add kind = "spl" to all existing spell entries.
    -- Pre-v7 entries are all spells; items appear in v7+ only.
    if config.presets then
        for _, preset in pairs(config.presets) do
            if type(preset) == "table" and type(preset.spells) == "table" then
                for _, entry in pairs(preset.spells) do
                    if type(entry) == "table" and entry.kind == nil then
                        entry.kind = "spl"
                    end
                end
            end
        end
    end
end
```

**Step 3: Add `kind` validator default**

In `_ValidateConfig`'s per-spell-entry block (the `for resref, entry in pairs(preset.spells)` loop), add this near the other field defaults:

```lua
if type(entry.kind) ~= "string" or (entry.kind ~= "spl" and entry.kind ~= "itm") then
    entry.kind = "spl"
end
```

**Step 4: Write migration test**

In `buffbot/BfBotTst.lua`, find `BfBot.Test.PersistMigrate` (or similar). Add a sub-case:

```lua
-- v6→v7: kind field added to all entries
local v6 = {
    v = 6, ap = 1,
    presets = {
        [1] = { name = "P1", cat = "long", qc = 0, spells = {
            ["SPWI304"] = { on = 1, tgt = "s", pri = 1, lock = 0 },
        }},
    },
    opts = { skip = 1 }, ovr = {},
}
local migrated = BfBot.Persist._MigrateConfig(v6, 6)
if migrated.v == 7 and migrated.presets[1].spells["SPWI304"].kind == "spl" then
    _ok("v6→v7 migration sets kind=\"spl\"")
else
    _nok("v6→v7 migration failed: " .. tostring(migrated.presets[1].spells["SPWI304"].kind))
end
```

**Step 5: Run the test in-game**

In EEex console:

```
BfBot.Test.PersistMigrate()
```

Expected: all checks pass including the new v7 case.

**Step 6: Commit**

```bash
git add buffbot/BfBotPer.lua buffbot/BfBotTst.lua
git commit -m "feat(persist): schema v7 adds kind field

Migration sets kind=\"spl\" on all pre-v7 entries.
Validator defaults missing/invalid kind to \"spl\"."
```

---

## Task 5: Rename `_MakeDefaultSpellEntry` → `_MakeDefaultEntry`

**Files:**
- Modify: `buffbot/BfBotPer.lua` (function definition at ~line 65; callers in same file + `BfBotUI.lua`)

**Step 1: Update the definition**

Replace the function around line 65:

```lua
--- Create a default entry for a preset spell or item slot.
-- @param classResult  classification table (may be nil)
-- @param enabled      optional 0 or 1 (default 1)
-- @param kind         "spl" (default) or "itm"
function BfBot.Persist._MakeDefaultEntry(classResult, enabled, kind)
    kind = kind or "spl"
    local tgt = "p"
    if classResult and classResult.defaultTarget == "s" then
        tgt = "s"
    elseif kind == "itm" then
        tgt = "s"  -- items default to self (most are self-drink potions)
    end
    return { kind = kind, on = (enabled == 0) and 0 or 1, tgt = tgt, pri = 999, lock = 0 }
end
```

**Step 2: Update all callers**

Find every occurrence:

```bash
grep -rn "_MakeDefaultSpellEntry" C:/src/private/bg-eeex-buffbot/buffbot/
```

Replace each `_MakeDefaultSpellEntry(args)` with `_MakeDefaultEntry(args)`. No backwards-compat alias — the rule in CLAUDE.md is no compat hacks.

Five expected sites: `BfBotPer.lua:131`, `:140`, `:453`, `:494`, `:518`, plus `BfBotUI.lua:729`. Verify count.

**Step 3: Run validation**

In-game:

```
BfBot.Test.PersistDefault()
BfBot.Test.PersistValidate()
```

Both should pass.

**Step 4: Commit**

```bash
git add buffbot/BfBotPer.lua buffbot/BfBotUI.lua
git commit -m "refactor(persist): _MakeDefaultSpellEntry → _MakeDefaultEntry

Adds kind parameter (default \"spl\"). Items default tgt=\"s\".
All 6 callers updated. No backwards-compat alias."
```

---

## Task 6: ImportConfig — kind-aware filtering

**Files:**
- Modify: `buffbot/BfBotPer.lua` `ImportConfig` function (around line 759)

**Step 1: Find the spell-stripping block**

In `ImportConfig`, the loop currently looks like:

```lua
for resref, _ in pairs(preset.spells) do
    if not castable[resref] then
        table.insert(toRemove, resref)
    end
end
```

**Step 2: Replace with kind-aware filter**

```lua
for resref, entry in pairs(preset.spells) do
    if entry.kind == "itm" then
        -- Keep item entries regardless of current inventory.
        -- Inventory is fluid: player may pick up the item later.
        -- The catalog-driven UI naturally hides item rows when the
        -- resref isn't in inventory now.
    elseif not castable[resref] then
        table.insert(toRemove, resref)
    end
end
```

**Step 3: Test**

Add to `BfBot.Test.PersistImport` (or create if absent):

```lua
-- Items kept even if not in inventory; spells stripped if not castable
local imported = {
    v = 7, ap = 1,
    presets = { [1] = { name = "T", cat = "custom", qc = 0, spells = {
        ["POTN99"]  = { kind = "itm", on = 1, tgt = "s", pri = 1, lock = 0 },
        ["SPWI999"] = { kind = "spl", on = 1, tgt = "s", pri = 2, lock = 0 },
    }}},
    opts = { skip = 1 }, ovr = {},
}
local castable = {}  -- character has neither
-- (test harness should call the filter logic directly; if hard to extract,
--  exercise via ImportConfig with a mock sprite instead)
```

If extracting the filter is awkward, write a smaller test by exporting a fake config to a temp file and importing it. Confirm POTN99 stays, SPWI999 is stripped.

**Step 4: Commit**

```bash
git add buffbot/BfBotPer.lua buffbot/BfBotTst.lua
git commit -m "feat(persist): import keeps item entries regardless of inventory

Spells get stripped if character can't cast them (durable repertoire).
Items stay (inventory is fluid; catalog-driven UI hides absent items)."
```

---

## Task 7: Classifier — collect leafResrefs in GetDuration

**Files:**
- Modify: `buffbot/BfBotCls.lua` `GetDuration` (line 522 area) + `Classify` to attach `leafResrefs` to result

**Step 1: Extend GetDuration to collect leaf resrefs**

`GetDuration` already recurses op=146 sub-spells (depth 2, cycle-guarded). Extend its return contract to also return a list of leaf resrefs:

```lua
function BfBot.Class.GetDuration(header, ability, _depth, _visited, _leafs)
    _depth = _depth or 0
    _visited = _visited or {}
    _leafs = _leafs or {}  -- collected leaf resrefs (the SPLs whose effects carry the buff)
    -- ... existing code ...
    -- when recursing op=146 sub-spell:
    --   add subResref to _leafs at top level (or before recursing further)
    -- when no op=146 found (this header's effects ARE the leaf):
    --   add this header's resref to _leafs (caller passes it via _visited[1] or a new arg)
end
```

The exact placement depends on the existing structure — read lines 522-590 first. Aim for: `_leafs` collects every resref whose feature blocks contribute timed buff effects.

Return signature changes from `(duration, durType)` to `(duration, durType, leafResrefs)`. Update callers in `BfBotScn.lua:59`, `BfBotTst.lua:1907`, `BfBotUI.lua:821`.

**Step 2: Test leaf collection**

In `BfBot.Test.DurationRecursion` (or similar) add:

```lua
-- POTN15 (Oil of Speed) wraps op=146 → SPIN999 (or whatever the leaf is)
local h = EEex_Resource_Demand("POTN15", "ITM")
local a = h:getAbility(0)
local _, _, leafs = BfBot.Class.GetDuration(h, a)
-- Expected: at least one entry in leafs that's an SPL resref (not POTN15)
local ok = false
for _, r in ipairs(leafs) do
    if r:sub(1, 4) ~= "POTN" then ok = true; break end
end
if ok then _ok("POTN15 leaf resref(s) collected: " .. table.concat(leafs, ","))
else _nok("POTN15 leaf resrefs missing or only contain potion resref") end
```

**Step 3: Attach leafResrefs to Classify result**

In `BfBot.Class.Classify`, capture the leaf list and attach:

```lua
local duration, durType, leafResrefs = BfBot.Class.GetDuration(header, ability)
-- ... existing classification logic ...
return {
    isBuff = ...,
    -- existing fields
    leafResrefs = leafResrefs,  -- NEW
}
```

**Step 4: Run tests**

```
BfBot.Test.DurationRecursion()
BfBot.Test.Classifier()
```

Existing assertions should still pass (we only added a return value + field).

**Step 5: Commit**

```bash
git add buffbot/BfBotCls.lua buffbot/BfBotTst.lua buffbot/BfBotScn.lua buffbot/BfBotUI.lua
git commit -m "feat(class): collect op=146 leaf resrefs alongside duration

GetDuration now returns (duration, durType, leafResrefs).
Classify result has class.leafResrefs for use in pre-flight
already-active checks. Wrapper potions (op=146 → SPIN###)
will be detected by the leaf SPL on the target's effect list."
```

---

## Task 8: Scanner — `_BuildItemCatalog` helper

**Files:**
- Modify: `buffbot/BfBotScn.lua` (add new helper, called from `GetCastableSpells`)

**Step 1: Add the helper**

Use the verified field path from Task 2 (placeholder `INVENTORY_FIELD` below — replace with actual). Insert after `_buildCountMap`:

```lua
--- Walk a sprite's inventory + 3 quickitems, classify each item ability
-- with at least one buff opcode, and return a {[resref] = entry} table.
local function _BuildItemCatalog(sprite)
    local items = {}
    local seen = {}

    local function _consider(resref, count)
        if not resref or resref == "" then return end
        if seen[resref] then return end
        if count <= 0 then return end
        seen[resref] = true

        -- Skip BuffBot's own generated SPLs masquerading as items (defensive)
        if resref:sub(1, 4) == "BFBT" then return end

        local hdrOk, header = pcall(EEex_Resource_Demand, resref, "ITM")
        if not hdrOk or not header then return end
        if (header.abilityCount or 0) == 0 then return end  -- passive-only

        for i = 0, header.abilityCount - 1 do
            local aOk, ability = pcall(function() return header:getAbility(i) end)
            if aOk and ability then
                local target = ability.target or 0
                if target == 1 or target == 5 or target == 7 then
                    local cOk, classResult = pcall(BfBot.Class.Classify, resref, header, ability)
                    if cOk and classResult and classResult.isBuff then
                        -- Only the FIRST buff ability per item appears (most items
                        -- have one). Multi-ability items: the first qualifying
                        -- ability wins; document the limitation, future work
                        -- if it bites.
                        local duration, _, leafs = BfBot.Class.GetDuration(header, ability)
                        items[resref] = {
                            resref = resref,
                            kind = "itm",
                            abilityIdx = i,
                            name = _tryStrref(header.spellName) or resref,
                            icon = (function()
                                local ok, ic = pcall(function() return ability.quickSlotIcon:get() end)
                                return (ok and ic) or ""
                            end)(),
                            count = count,
                            level = 0,
                            spellType = 0,
                            duration = duration or 0,
                            durCat = BfBot.Class.GetDurationCategory(duration or 0),
                            isAoE = (classResult.isAoE) and 1 or 0,
                            isSelfOnly = (classResult.isSelfOnly) and 1 or 0,
                            hasVariants = 0,
                            variants = nil,
                            class = classResult,
                            leafResrefs = (leafs and #leafs > 0) and leafs or { resref },
                        }
                        break  -- first buff ability wins
                    end
                end
            end
        end
    end

    -- Walk inventory slots
    local invList = sprite[BfBot.Scan._INVENTORY_FIELD]  -- e.g. sprite.m_aItems
    if invList then
        pcall(function()
            EEex_Utility_IterateCPtrList(invList, function(slot)
                local r = slot.m_pRes and slot.m_pRes:get() or nil
                local c = slot.m_count or 1
                _consider(r, c)
            end)
        end)
    end

    -- Walk 3 quickitem slots
    local qList = sprite[BfBot.Scan._QUICKITEM_FIELD]
    if qList then
        pcall(function()
            EEex_Utility_IterateCPtrList(qList, function(slot)
                local r = slot.m_pRes and slot.m_pRes:get() or nil
                local c = slot.m_count or 1
                _consider(r, c)
            end)
        end)
    end

    return items
end
```

**Important:** `BfBot.Scan._INVENTORY_FIELD` and `BfBot.Scan._QUICKITEM_FIELD` are constants set at the top of the module from Task 2's findings. If iteration via `EEex_Utility_IterateCPtrList` doesn't apply, swap for array indexing using the verified pattern.

**Step 2: Add the constants at the top of the file**

Below the `BfBot.Scan = {}` line (line 9):

```lua
-- Verified 2026-04-30 via remote console. See tools/items_probe_findings.md
-- and ~/.claude/skills/bg-modding/references/eeex-sprites.md (Task 18 update).
BfBot.Scan._INVENTORY_FIELD = "m_aItems"      -- replace with verified name
BfBot.Scan._QUICKITEM_FIELD = "m_aQuickItems" -- replace with verified name
```

**Step 3: Probe-test the helper before integrating**

In EEex console:

```lua
local sp = EEex_Sprite_GetInPortrait(0)
local items = BfBot.Scan._BuildItemCatalog and BfBot.Scan._BuildItemCatalog(sp)  -- only works after exposing
-- Or test the local fn by temporarily promoting to BfBot.Scan._BuildItemCatalog
for r, e in pairs(items or {}) do print(r, e.name, e.count, e.durCat) end
```

Expected: at least the test items (POTN15, RING06) appear with sensible names + durCat.

**Step 4: Commit**

```bash
git add buffbot/BfBotScn.lua
git commit -m "feat(scan): add _BuildItemCatalog walking inventory + quickitems

Uses verified m_aItems / m_aQuickItems field paths (Task 2).
Each item with abilityCount > 0 gets its first buff-classified
ability into the catalog with kind=\"itm\", abilityIdx,
leafResrefs collected for pre-flight already-active checks."
```

---

## Task 9: Scanner — merge items into `GetCastableSpells` + add `kind` to spells

**Files:**
- Modify: `buffbot/BfBotScn.lua` `_buildCatalogEntry` and `GetCastableSpells`

**Step 1: Tag spell entries with `kind = "spl"`**

In `_buildCatalogEntry` (around line 22), the returned table currently has:

```lua
return {
    resref = resref,
    name = name,
    icon = icon,
    count = 0,
    -- ...
}
```

Add `kind = "spl"`:

```lua
return {
    resref = resref,
    kind = "spl",
    name = name,
    -- ... rest unchanged ...
}
```

Also add `leafResrefs = (classResult and classResult.leafResrefs) or { resref }` so spells get the same field.

**Step 2: Merge items at the end of `GetCastableSpells`**

In `GetCastableSpells`, after the count overlay (around line 215), before the cache write:

```lua
-- Merge item catalog
local itemCatalog = _BuildItemCatalog(sprite)
for r, entry in pairs(itemCatalog) do
    if not spells[r] then  -- spells take precedence on hypothetical resref collision
        spells[r] = entry
        count = count + 1
    end
end
```

**Step 3: Test**

In EEex console:

```lua
BfBot.Scan.Invalidate(EEex_Sprite_GetInPortrait(0))
local s, c = BfBot.Scan.GetCastableSpells(EEex_Sprite_GetInPortrait(0))
local items = 0
for _, e in pairs(s) do if e.kind == "itm" then items = items + 1 end end
print("total: " .. c .. " items: " .. items)
```

Expected: items > 0 if test character has items in inventory.

**Step 4: Commit**

```bash
git add buffbot/BfBotScn.lua
git commit -m "feat(scan): merge item catalog into GetCastableSpells

All entries now carry kind=\"spl\"|\"itm\". Spells get
leafResrefs (single-element list = self) for pre-flight
parity with items. Items take a back seat to spells on
hypothetical resref collisions."
```

---

## Task 10: Exec — `_BuildQueue` carries `kind`

**Files:**
- Modify: `buffbot/BfBotExe.lua` `_BuildQueue` (line 175)

**Step 1: Plumb `kind` through the per-entry build**

In the loop that builds `byCaster[casterSlot]` entries (around line 240), add `kind = spellData.kind` and `leafResrefs = spellData.leafResrefs` to the inserted table:

```lua
table.insert(byCaster[casterSlot], {
    casterSlot = casterSlot,
    casterSprite = casterSprite,
    casterName = casterName,
    resref = resref,
    kind = spellData.kind or "spl",         -- NEW
    leafResrefs = spellData.leafResrefs,    -- NEW
    spellName = spellName,
    targetObj = tgt.targetObj,
    targetSlot = tgt.targetSlot,
    targetSprite = tgt.targetSprite,
    targetName = tgt.targetName,
    splstates = splstates,
    isAoE = isAoE,
    cheat = isCheat,
    var = entry.var,
})
```

**Step 2: Bypass cheat tagging for items**

Just before the existing `cheat = isCheat` line (or wherever `isCheat` is computed), add:

```lua
if (spellData.kind or "spl") == "itm" then
    isCheat = false  -- Quick Cast / IA wrapper doesn't apply to UseItem
end
```

**Step 3: Plumb `kind` and `leafResrefs` through `BuildQueueFromPreset` / `BuildQueueForCharacter`**

In `BfBotPer.lua` `BuildQueueFromPreset` (~line 952) and `BuildQueueForCharacter` (~line 1222), the queue entries appended at the end need `kind` and `leafResrefs`:

```lua
table.insert(queue, {
    caster = e.caster,
    spell  = e.spell,
    target = e.target,
    durCat = scanData and scanData.durCat or "short",
    var    = spellCfg and spellCfg.var or nil,
    kind   = scanData and scanData.kind or "spl",         -- NEW
    leafResrefs = scanData and scanData.leafResrefs,      -- NEW
})
```

Then in `_BuildQueue` consume `entry.kind` and `entry.leafResrefs` from `userQueue` instead of from `spellData` (or in addition — pick the one that works cleanly with how the data flows).

**Step 4: Run existing exec tests**

```
BfBot.Test.Exec()
```

Should still pass (spells unchanged behaviorally; items not yet executed).

**Step 5: Commit**

```bash
git add buffbot/BfBotExe.lua buffbot/BfBotPer.lua
git commit -m "feat(exec): plumb kind + leafResrefs through queue building

Queue entries carry kind (\"spl\"|\"itm\") and leafResrefs.
Items bypass cheat/IA tagging. Sets up the cast-verb branch
in _ProcessCasterEntry (next task)."
```

---

## Task 11: Exec — pre-flight uses `leafResrefs`

**Files:**
- Modify: `buffbot/BfBotExe.lua` `_CheckEntry` (line 273 area, look for the `_HasActiveEffect` call around line 332)

**Step 1: Replace single-resref check with list check**

The current code:

```lua
local checkResref = entry.var or entry.resref
if BfBot.Exec._HasActiveEffect(targetSprite, checkResref) then
    -- skip
end
```

Replace with:

```lua
local checkResrefs = entry.leafResrefs or { entry.var or entry.resref }
-- Variants always override: if a variant resref is set, that's the actual effect
if entry.var then checkResrefs = { entry.var } end

local foundActive = nil
for _, r in ipairs(checkResrefs) do
    if BfBot.Exec._HasActiveEffect(targetSprite, r) then
        foundActive = r
        break
    end
end

if foundActive then
    BfBot.Exec._LogEntry("SKIP", label .. " (already active: " .. foundActive .. ")")
    BfBot.Exec._skipCount = BfBot.Exec._skipCount + 1
    return false
end
```

**Step 2: Test with a known wrapper potion**

In-game test (manual):
1. Drink Oil of Speed manually → confirm Haste icon appears
2. Open BuffBot panel, enable Oil of Speed in a preset, Cast Character
3. Expected log: `SKIP ... -> Oil of Speed -> ... (already active: SPIN999)` (or whatever the leaf resref is)

If it skips because of a non-leaf resref (item resref), the leafResrefs collection in Task 7 didn't reach the leaf — debug `BfBot.Class.GetDuration` recursion.

**Step 3: Commit**

```bash
git add buffbot/BfBotExe.lua
git commit -m "feat(exec): pre-flight uses leafResrefs list

Variant override still wins. Otherwise walks the leafResrefs
list — for spells it's a 1-element list (self), for items
it's the op=146 sub-spell chain leaves. Catches Oil of Speed
already active via SPIN-prefixed leaf SPL on effect list."
```

---

## Task 12: Exec — `UseItem` cast path

**Files:**
- Modify: `buffbot/BfBotExe.lua` `_ProcessCasterEntry` (line 348)

**Step 1: Find the cast section**

Around line 410-435 there's the cast block with `entry.var` branch and the normal `SpellRES` path. Add a `kind == "itm"` branch BEFORE the variant-spell branch:

```lua
-- Cast the spell or use the item
local advanceAction = string.format('EEex_LuaAction("BfBot.Exec._Advance(%d)")', slot)

if entry.kind == "itm" then
    -- Items: queue UseItem(resref, target). Engine handles slot lookup,
    -- destruction (potions), and charge decrement (wand-like items).
    local useAction = string.format('UseItem("%s",%s)', entry.resref, entry.targetObj)
    EEex_Action_QueueResponseStringOnAIBase(useAction, entry.casterSprite)
    EEex_Action_QueueResponseStringOnAIBase(advanceAction, entry.casterSprite)
    BfBot.Exec._LogEntry("CAST",
        entry.casterName .. " -> " .. entry.spellName .. " (item) -> " .. entry.targetName)
    BfBot.Exec._castCount = BfBot.Exec._castCount + 1

elseif entry.var then
    -- existing variant path unchanged
    -- ...

else
    -- existing normal SpellRES path unchanged
    -- ...
end
```

**Step 2: Live test — drink Oil of Speed via BuffBot**

1. Reload BuffBot Lua: `Infinity_DoFile("BfBotExe")` in console
2. Open BuffBot panel
3. Confirm Oil of Speed appears (kind=item; though no UI tinting yet — Task 14)
4. Enable it in a preset, set caster + target = Self
5. Press Cast Character
6. Expected: leader drinks one Oil of Speed, Haste applies, stack count drops

**Step 3: Commit**

```bash
git add buffbot/BfBotExe.lua
git commit -m "feat(exec): UseItem(resref,target) BCS path for kind=itm

Engine handles slot lookup + destruction + charge decrement.
Variant spell path unchanged (variants are spell-only).
EEex_LuaAction _Advance chaining preserves parallel execution."
```

---

## Task 13: Theme — `itemColor` palette key

**Files:**
- Modify: `buffbot/BfBotThm.lua` (theme palette tables)

**Step 1: Add `itemColor` to each of the 6 themes**

Open `BfBotThm.lua`, find each theme palette table (`bg2_light`, `bg2_dark`, `sod_light`, `sod_dark`, `bg1_light`, `bg1_dark`). For each, add an `itemColor` entry — a muted bronze tint that contrasts with the theme's `nameColor` (or whatever the spell-name color key is) but still readable.

Suggested defaults (adjust per theme palette aesthetics):

| Theme | itemColor (RGB hex) |
|---|---|
| bg2_light | `0xCD7F32` (bronze) |
| bg2_dark | `0xD9A063` (light bronze) |
| sod_light | `0xB87333` (copper) |
| sod_dark | `0xCC8C49` (light copper) |
| bg1_light | `0xA0522D` (sienna) |
| bg1_dark | `0xC68E5F` (light sienna) |

Exact tints can be tweaked in QA — these are starting values.

**Step 2: Commit**

```bash
git add buffbot/BfBotThm.lua
git commit -m "feat(theme): itemColor palette key for all 6 themes

Bronze/copper/sienna tones distinguishing item rows from
spell rows in the mixed buff list. Tints chosen to read
on each theme background; refine in QA."
```

---

## Task 14: UI — mixed list rendering (`itemColor` + variant column hidden)

**Files:**
- Modify: `buffbot/BfBotUI.lua` (list row rendering — search for the list cell that renders `entry.name` with the spell-name color key)

**Step 1: Find the row render path**

Look for where the spell list row text gets its color. Likely a lua-keyword on the list element in `BuffBot.menu` calling back into `BfBotUI` to compute `text color lua`.

```bash
grep -nE "nameColor|spellName.*color|text color lua" C:/src/private/bg-eeex-buffbot/buffbot/BfBotUI.lua C:/src/private/bg-eeex-buffbot/buffbot/BuffBot.menu
```

**Step 2: Branch on `entry.kind`**

In the row color callback:

```lua
local theme = BfBot.Theme.GetActive()
local color
if entry.kind == "itm" then
    color = theme.itemColor or theme.nameColor  -- fallback if theme didn't get the key
else
    if entry.lock == 1 then
        color = theme.lockedNameColor  -- or whatever the existing locked tint is
    else
        color = theme.nameColor
    end
end
return color
```

If items get locked, lock takes precedence — choose either the locked-color or a `lockedItemColor` hybrid. Simplest: lock-color always wins regardless of kind.

**Step 3: Hide the variant column for items**

In the variant cell render:

```lua
if entry.kind == "itm" then return "" end  -- items have no variants
-- existing variant cell code
```

**Step 4: Manual QA — reload + open panel**

```
Infinity_DoFile("BfBotUI")
```

Open the BuffBot panel, switch to a character with items. Items should render in the bronze tint; variant column blank for those rows.

**Step 5: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): mixed list — itemColor for items, hide variant column

Lock color takes precedence over item/spell color.
Variant column renders empty for kind=itm rows."
```

---

## Task 15: UI — picker sub-sections

**Files:**
- Modify: `buffbot/BfBotUI.lua` (the Add Spell picker — search for the list-population callback)

**Step 1: Find the picker row builder**

```bash
grep -nE "_pickerList|AddSpellPicker|_pickerEntries|picker.*spells" C:/src/private/bg-eeex-buffbot/buffbot/BfBotUI.lua
```

**Step 2: Group entries by kind with section headers**

Build the picker rows as:

```
[Spells]                     ← header row, non-clickable
SPWI103 Identify             ← spell row
SPWI304 Fireball             ← spell row
...
[Items]                      ← header row, non-clickable
POTN15 Oil of Speed          ← item row
RING06 Ring of the Ram       ← item row
```

Implementation: insert a sentinel entry at the top of each group, e.g. `{ resref = "__HEADER_SPL__", name = "[Spells]", isHeader = 1 }`. The row renderer checks `isHeader` and renders the label without click affordances.

**Step 3: Sort within groups**

Existing sort (excluded → top, then by name) stays per-group. New sort key: `(kind == "itm" and 1 or 0, isExcluded ? 0 : 1, name)` — spells before items, excluded before included within each kind, alphabetical within.

**Step 4: Manual QA**

Open BuffBot panel → Add Spell. Picker should now have two labeled sections.

**Step 5: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): picker sub-sections — Spells / Items

Header rows separate the two kinds. Within each section:
excluded (re-add) entries stay at top, then alphabetical."
```

---

## Task 16: BfBotTst — `Items()` test phase

**Files:**
- Modify: `buffbot/BfBotTst.lua` (add new phase, register in RunAll)

**Step 1: Add the Items test phase**

Append at the end of the file's test phase definitions:

```lua
function BfBot.Test.Items()
    _phase("Items + potions support")
    local sprite = EEex_Sprite_GetInPortrait(0)
    if not sprite then _nok("no party member in slot 0"); return end

    -- 1. Scan finds at least one item if test character has any
    BfBot.Scan.Invalidate(sprite)
    local catalog = BfBot.Scan.GetCastableSpells(sprite)
    local itemCount = 0
    local sampleItem = nil
    for r, e in pairs(catalog) do
        if e.kind == "itm" then itemCount = itemCount + 1; sampleItem = e end
    end
    if itemCount > 0 then _ok("scan found " .. itemCount .. " item entries")
    else _info("no items in inventory — populate test character to exercise scan path") end

    -- 2. If we found one, validate the entry shape
    if sampleItem then
        if sampleItem.kind == "itm" then _ok("kind == 'itm'") else _nok("kind missing/wrong") end
        if type(sampleItem.abilityIdx) == "number" then _ok("abilityIdx present") else _nok("abilityIdx missing") end
        if type(sampleItem.leafResrefs) == "table" and #sampleItem.leafResrefs > 0 then
            _ok("leafResrefs populated: " .. table.concat(sampleItem.leafResrefs, ","))
        else _nok("leafResrefs empty") end
        if sampleItem.class and sampleItem.class.isBuff then _ok("classified as buff")
        else _nok("not classified as buff") end
    end

    -- 3. Schema v7 round-trip with item entries
    local cfg = {
        v = 7, ap = 1,
        presets = { [1] = { name = "T", cat = "custom", qc = 0, spells = {
            ["POTN15"] = { kind = "itm", on = 1, tgt = "s", pri = 1, lock = 0 },
        }}},
        opts = { skip = 1 }, ovr = {},
    }
    local validated = BfBot.Persist._ValidateConfig(cfg)
    if validated.presets[1].spells["POTN15"].kind == "itm" then
        _ok("validator preserves kind=itm")
    else _nok("validator clobbered kind") end

    -- 4. Build queue from a preset that contains an item entry
    -- (requires a real preset to be set up; skip if no test fixture)
end
```

**Step 2: Register in RunAll**

Find the `BfBot.Test.RunAll` function and add `BfBot.Test.Items()` to the call list.

**Step 3: Run the suite**

In EEex console (test character with POTN15 + RING06 in inventory):

```
BfBot.Test.RunAll()
```

Expected: all phases including new Items phase pass.

**Step 4: Commit**

```bash
git add buffbot/BfBotTst.lua
git commit -m "test(items): BfBot.Test.Items() phase

Scan-shape, validator round-trip, leafResrefs presence.
Live cast test stays manual (Task 17 QA)."
```

---

## Task 17: Manual QA on representative items

**Goal:** verify end-to-end behavior on real items. Document each test result.

**Test fixtures to set up (via `CreateItem` BCS or starting items):**
- `POTN15` Oil of Speed (Haste wrapper, op=146)
- `POTN14` Potion of Heroism (THAC0 + HP buff, multi-effect)
- `POTN21` Potion of Fire Resistance (resistance buff)
- `RING06` Ring of the Ram (equipped activated, projectile attack — should be classified as offensive and NOT appear in catalog)
- `AMUL19` Amulet of Power (equipped passive — should NOT appear, abilityCount=0 likely)
- `RING23` Ring of Wizardry (passive double-mage-spells — should NOT appear)
- `WAND09` Wand of Heavens (offensive — should NOT appear in catalog)
- A pure-buff equipped activated item if available — verify it appears

**Step 1: Test each fixture**

For each item:
1. Place in test character inventory or equip
2. Reload BuffBot: `Infinity_DoFile("BfBotScn")`
3. Open BuffBot panel for the character
4. Check: does the item appear? Should it?
5. If a buff: enable in preset, Cast Character, observe result, check stack/charges
6. If a buff: cast again, expect SKIP (already-active path)

**Step 2: Document results**

Append findings to `tools/items_probe_findings.md`:

```
| ResRef | Item              | Expected | Actual | Notes |
|--------|-------------------|----------|--------|-------|
| POTN15 | Oil of Speed      | listed   | listed | leafs=[SPIN999], Haste applies, stack -1 |
| POTN14 | Potion of Heroism | listed   | listed | leafs=[SPINxxx], THAC0 applies |
| RING06 | Ring of the Ram   | NOT listed | NOT listed | offensive — classifier rejected |
...
```

**Step 3: Fix any classifier or scanner issues found**

If something appears that shouldn't (or vice versa), debug before continuing. Likely candidates:
- Multi-ability item with wrong ability picked → tighten the ability selection in `_BuildItemCatalog`
- Wrapper SPL chain not reaching the leaf → debug `GetDuration` recursion
- Equipped passive item slipping in → check `header.abilityCount > 0` filter

**Step 4: Commit fixes (if any)**

```bash
git add buffbot/Bf*.lua
git commit -m "fix(items): <specific issue> from QA pass"
```

If no fixes, no commit.

---

## Task 18: bg-modding-learn — capture verified knowledge

**Goal:** persist the in-game discoveries from Tasks 2, 3, 17 into the bg-modding skill references so future sessions don't re-probe.

**Step 1: Invoke bg-modding-learn skill**

Use the skill to record:

1. **In `references/eeex-sprites.md`:** the verified inventory + quickitem field paths and iteration patterns. New section "Inventory Iteration" with the field name, iteration call, slot record fields (resref/count).

2. **In `references/eeex-actions.md`:** confirmation that `UseItem("RESREF", target)` BCS verb queues via `EEex_Action_QueueResponseStringOnAIBase`, works for any inventory slot (not just quickbar), engine handles destruction/charge decrement automatically. Note any quirks found in QA (e.g. wand-from-inventory behavior).

3. **In `references/eeex-resources.md` or `ie-spell-structure.md`:** confirm that `Item_Header_st:getAbility(i)` works (or document the typo if Task 3 found a real bug + the workaround).

**Step 2: Delete the temporary findings file**

```bash
git rm tools/items_probe_findings.md
```

The knowledge now lives in the skill references where it belongs.

**Step 3: Commit project file deletion**

```bash
git add tools/items_probe_findings.md
git commit -m "chore: remove temp probe notes — knowledge in bg-modding refs"
```

(The skill references live outside the project repo, in `~/.claude/skills/bg-modding/references/` — those are committed via a separate dotfiles flow, not this branch.)

---

## Task 19: Version bump + CHANGELOG

**Files:**
- Modify: `buffbot/BfBotCor.lua:9` (`BfBot.VERSION`)
- Modify: `buffbot/setup-buffbot.tp2:3` (`VERSION`)
- Modify: `CHANGELOG.md`

**Step 1: Run the bump tool**

```bash
bash tools/bump-version.sh 1.4.0-alpha
```

Verify it updated both:

```bash
grep -E "VERSION|BfBot.VERSION" buffbot/BfBotCor.lua buffbot/setup-buffbot.tp2
```

**Step 2: CHANGELOG entry**

Prepend to `CHANGELOG.md` under a new `## v1.4.0-alpha (2026-04-30)` heading:

```markdown
## v1.4.0-alpha (2026-04-30)

### Added
- **Items + potions as buff sources** (#21 partial — covers (a) activated equipped-item abilities + (b) inventory potions; (c) scrolls and (d) wands deferred to follow-up issues). Buff potions like Oil of Speed and Potion of Heroism, plus activated abilities on equipped rings/amulets/cloaks/etc., now appear alongside spells in each character's preset list (kind="itm", listed but disabled by default). Engine `UseItem("RESREF", target)` BCS verb does the slot lookup at use time — configure by resref, stack multiple of the same potion in inventory freely. Pre-flight already-active detection follows op=146 wrapper SPL chains so a potion's leaf SPL is checked on the target's effect list.
- **Schema v7** — `kind` field on every preset entry. Auto-migrates v6 saves on load (sets `kind = "spl"`). Items in imported preset configs are kept regardless of current inventory (catalog-driven UI naturally hides absent items).
- **Theme — `itemColor` palette key** — bronze/copper/sienna tints for item rows in the mixed buff list. Variant column hidden for items.
- **Picker sub-sections** — Add Spell picker now groups entries under "Spells" and "Items" headers.

### Changed
- `BfBot.Class.GetDuration` returns a third value (`leafResrefs` — list of SPL resrefs collected through op=146 sub-spell recursion). Pre-flight skip-if-active uses this list.
- `BfBot.Persist._MakeDefaultSpellEntry` renamed to `_MakeDefaultEntry` with new `kind` parameter (default `"spl"`).
```

**Step 3: Commit**

```bash
git add buffbot/BfBotCor.lua buffbot/setup-buffbot.tp2 CHANGELOG.md
git commit -m "release: v1.4.0-alpha — items + potions as buff sources

Closes #21 partial: (a) activated equipped items + (b) inventory potions.
Scrolls + wands deferred to follow-up issues.
Schema v7 (auto-migrates v6 saves)."
```

---

## Task 20: Push + open PR

**Step 1: Push branch**

```bash
git push origin feat/items-and-potions
```

**Step 2: Confirm CI passes**

```bash
gh pr checks --repo Chrizhermann/bg-eeex-buffbot $(git branch --show-current) 2>/dev/null || \
  gh run list --branch feat/items-and-potions --limit 5
```

Expected: `version-check` passes (tp2 VERSION = `v` + `BfBot.VERSION`); `release` workflow doesn't fire on branch push (only on tag).

**Step 3: Open PR**

```bash
gh auth switch --user Chrizhermann
gh pr create --repo Chrizhermann/bg-eeex-buffbot --title "feat(items): activated equipped items + inventory potions (#21 partial)" --body "$(cat <<'EOF'
Closes (a)+(b) of #21. Scrolls + wands deferred to follow-up issues.

## Summary
- New buff sources: activated equipped-item abilities (rings/amulets/etc.) and buff potions from anywhere in inventory.
- Configure by resref, not slot — engine `UseItem(resref, target)` BCS verb does the lookup at use time. Stack multiples freely.
- Listed but disabled by default in new presets.
- Schema bump v6→v7 auto-migrates existing saves.

## Design
Full design: [#21 comment](https://github.com/Chrizhermann/bg-eeex-buffbot/issues/21#issuecomment-4351690202)

## Test plan
- [ ] `BfBot.Test.RunAll()` passes including new `Items()` phase
- [ ] Manual QA — Oil of Speed drinks + applies Haste + decrements stack
- [ ] Manual QA — already-active detection (cast twice → second skips with leaf-resref reason in log)
- [ ] Manual QA — F12 hotkey path executes items same as spells
- [ ] Manual QA — Save → reload → preset preserves kind="itm" entries
- [ ] Manual QA — Combat detection still aborts mid-queue with item entries pending
- [ ] CI: version-check passes
EOF
)"
```

**Step 4: Mark related issue with status comment**

```bash
gh issue comment 21 --repo Chrizhermann/bg-eeex-buffbot --body "PR opened: <PR-url>. Covers (a) activated equipped items + (b) inventory potions. Will open follow-up issues for (c) scrolls and (d) wands once this lands."
```

---

## Acceptance criteria (recap from design)

- ✅ A character with Oil of Speed in inventory + Ring of the Ram equipped sees both in their preset list, kind="itm", default disabled
- ✅ Enabling Oil of Speed in a preset and pressing Cast Character drinks one potion, applies the Haste buff, decrements stack count by 1
- ✅ Pressing Cast Character again with Haste already active skips the entry (already-active detection)
- ✅ F12 hotkey trigger fires the same path
- ✅ Save/reload preserves item entries; export/import works
- ✅ Combat detection still aborts mid-queue
- ✅ Existing spell behavior fully unchanged — `BfBot.Test.RunAll()` passes

---

## Risks (carry-over from design)

| # | Risk | Mitigation |
|---|---|---|
| 1 | Inventory field path differs between BG1EE and BG2EE | Probe both in Task 2 |
| 2 | `Item_Header_st:getAbility(i)` typo at `EEex_Resource.lua:165` | Probe Task 3 step 2; if real, swap to direct pointer arithmetic |
| 3 | `UseItem` BCS doesn't fire mid-queue | Task 3 step 3 verifies; fallback to `UseItemSlot` |
| 4 | Equipped activated turns out to be passive | Document, user disables entry |
