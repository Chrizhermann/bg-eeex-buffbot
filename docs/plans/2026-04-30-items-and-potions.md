# Items + Potions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Goal:** Add support for activated equipped-item abilities and inventory potions as buff sources alongside spells. Configure by resref (durable) — engine picks the slot at use time. Listed-but-disabled by default. Closes (a)+(b) of GitHub issue #21; defers (c) scrolls and (d) wands to follow-ups.

**Architecture:** Extend `BfBotScn.lua` to walk inventory + 3 quickitems and merge `kind="itm"` entries into the existing spell catalog. Schema bump v9→v10 adds `kind` to party preset entries; summon presets remain spell-only. Exec branches on `kind` to emit `UseItem("RESREF", target)` BCS for items and `SpellRES` for spells. Pre-flight already-active checks use `leafResrefs` collected through op=146 sub-spell chains so wrapper potions are detected by the leaf SPL on the target's effect list. UI mixes both kinds in one priority-sortable list with a tinted `itemColor` palette key for item rows.

**Tech Stack:** Lua 5.1 (EEex), `.menu` DSL, WeiDU installer (no build step — deploy via `bash tools/deploy.sh`). Tests run in-game via `BfBot.Test.<Name>()` in the EEex console. Field-path probes use the EEex remote console at `C:\src\private\eeex-remote-console`.

**Reference docs:**
- Design: GitHub issue [#21 comment](https://github.com/Chrizhermann/bg-eeex-buffbot/issues/21#issuecomment-4351690202)
- BG-modding skills: `~/.claude/skills/bg-modding/references/eeex-resources.md`, `eeex-actions.md`, `eeex-sprites.md`, `ie-spell-structure.md`, `ie-targeting.md`
- Prior schema migration pattern: `docs/plans/2026-04-18-spell-lock.md` (v5→v6)

**Branch:** `feat/items-and-potions` (cut from `main`)

---

## Post-merge amendment note (2026-06-15)

This plan was authored pre-merge. The `feat/items-and-potions` branch has since been merged with `main` (now at **v1.4.1-alpha, schema v7**). The plan has been re-pinned accordingly:

- **Schema target is now v8** (current state is v7) and **release target is v1.4.2-alpha** (current is v1.4.1-alpha). All fixture literals and migration branches shifted up one (v6→v7 became v7→v8; "current" fixtures are now `v=7`, "new" fixtures `v=8`).
- **Task 15 resolved to option (b):** items auto-merge into the main preset list *disabled by default* (the already-approved "listed but disabled" UX — items are NOT excluded from the `BfBotPer.lua` auto-merge). The picker's `[Items]` sub-section scopes to items the user has explicitly REMOVED/excluded (`ovr == -1`), mirroring the excluded-buff-spell re-add affordance (v1.3.10 picker).
- **Probe / deploy target is the `…modded - Copy - Copy` test install** — never the active playthrough (probes mutate game state).
- **Innate, scanner, and exec layers confirmed stable post-merge** — anchors in those tasks were audited and hold; GetDuration core, `bump-version.sh` form, and the PROBE CLI path also hold.

---

## Post-merge amendment note (2026-08-20)

The branch was merged again with `main` at **v1.6.4-alpha, schema v9**. This amendment supersedes the 2026-06-15 schema/release pins and any older copy-paste commands below:

- **Schema target is v10** and **release target is v1.7.0-alpha**. This is the approved minor bump for the first source expansion beyond spells. The item migration is now v9→v10 and adds `kind="spl"` only to party entries that lack a kind. Summon presets remain spell-only and kindless. The migrator also preserves item-v8 development saves while supplying the summons shape added by main's colliding v8 lineage.
- **Items are party-only.** `GetCastableSpells` is shared with summon discovery, so `_BuildItemCatalog` returns empty for non-party sprites and clone seeding filters item entries. This is the selected items × summon-presets policy.
- **Main's R1–R5 repeat setting applies to items.** Each attempt independently rechecks availability and active effects; an item attempt consumes a stack or charge and never receives Quick Cast.
- **Scrolls and wands remain deferred** and are explicitly rejected by ITM category even in quickitem slots. Containers/Bags of Holding and inventory search remain deferred. #53 remains open: `UseItem` fires ability 0, so higher-index weapon buffs stay excluded.
- **SPL and ITM classifier caches are source-separated.** A same-resref SPL must never lend its buff verdict to an ITM ability.
- **Task 15 is complete** (commit `7fa5231`): the picker has separate spell/item sections, and excluded items can be re-added only through the current character's persisted override.
- **Do not use `Infinity_DoFile` for reload QA.** It serves cached Lua. Deploy while the game and loader are closed, then restart through InfinityLoader for this multi-module integration.

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

**Target install — IMPORTANT:** all probes and deploys in this plan run against the **`…modded - Copy - Copy` test install**, NEVER the active playthrough. Probes mutate game state (queue actions, drink potions, decrement stacks) — pointing them at the active install corrupts a real save.

**Deploy before in-game work:**

```bash
BGEE_DIR="C:/Games/Baldur's Gate II Enhanced Edition modded - Copy - Copy" bash tools/deploy.sh
```

(deploy.sh precedence: explicit arg > `BGEE_DIR` env > active `deploy.conf`.) Re-run this deploy before any `BfBot.*` probe once code changes start landing (Task 8 onward) so the running game has the latest Lua.

**Prerequisite:** game must be running on the world screen with a party on the `- Copy - Copy` install. Set up the manual item fixtures on the test character via `CreateItem` (used across Tasks 2, 3, 17):

- `POTN15` Oil of Speed (Haste wrapper, op=146)
- `POTN14` Potion of Heroism
- `POTN21` Potion of Fire Resistance
- `RING06` Ring of the Ram (equipped activated, offensive)
- `AMUL19` Amulet of Power (equipped passive)
- `RING23` Ring of Wizardry (passive)
- `BRAC09` (multi-ability item, for the `getAbility(i)` check)
- `WAND09` Wand of Heavens (non-quickslot wand test)

**Step 1: Probe candidate field names via remote console**

Run, one at a time, and check which return non-nil with sensible content. (Each Bash snippet is a fresh shell — `GAME_DIR` and `PROBE` are re-declared at the top of every snippet below.)

```bash
GAME_DIR='c:/Games/Baldur'\''s Gate II Enhanced Edition modded - Copy - Copy/override'
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
GAME_DIR='c:/Games/Baldur'\''s Gate II Enhanced Edition modded - Copy - Copy/override'
PROBE='/c/src/private/eeex-remote-console/tools/eeex-remote.sh'

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
GAME_DIR='c:/Games/Baldur'\''s Gate II Enhanced Edition modded - Copy - Copy/override'
PROBE='/c/src/private/eeex-remote-console/tools/eeex-remote.sh'

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
GAME_DIR='c:/Games/Baldur'\''s Gate II Enhanced Edition modded - Copy - Copy/override'
PROBE='/c/src/private/eeex-remote-console/tools/eeex-remote.sh'

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
GAME_DIR='c:/Games/Baldur'\''s Gate II Enhanced Edition modded - Copy - Copy/override'
PROBE='/c/src/private/eeex-remote-console/tools/eeex-remote.sh'

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
GAME_DIR='c:/Games/Baldur'\''s Gate II Enhanced Edition modded - Copy - Copy/override'
PROBE='/c/src/private/eeex-remote-console/tools/eeex-remote.sh'

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
GAME_DIR='c:/Games/Baldur'\''s Gate II Enhanced Edition modded - Copy - Copy/override'
PROBE='/c/src/private/eeex-remote-console/tools/eeex-remote.sh'

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

## Task 4: Schema v10 — bump version, migrate, validate

**Files:**
- Modify: `buffbot/BfBotPer.lua` (`_SCHEMA_VERSION`; default config stamp; party-entry validator; migration chain)

**Step 1: Bump schema version**

Main is schema v9. Bump to 10 — the party-entry `kind` field is schema **v10**:

```lua
BfBot.Persist._SCHEMA_VERSION = 10
```

**Step 2: Add v9→v10 migration branch**

In `_MigrateConfig`, leave the existing migration chain intact. Insert the item branch after the v9 repeat migration and before the current-version stamp:

```lua
if fromVersion < 10 then
    -- Add kind="spl" to legacy party entries that lack kind.
    -- Preserve kind from the colliding item-v8 development lineage.
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

In `_ValidateConfig`'s per-entry loop at BfBotPer.lua:199 (`for resref, entry in pairs(preset.spells)`), insert the kind default **after the lock default (after line 225, before :226)**, alongside the other field defaults:

```lua
if type(entry.kind) ~= "string" or (entry.kind ~= "spl" and entry.kind ~= "itm") then
    entry.kind = "spl"
end
```

**Step 4: Write migration test**

In `buffbot/BfBotTst.lua`, find `BfBot.Test.Persist()` (BfBotTst.lua:2730 — the consolidated persistence phase). Add a sub-case:

```lua
-- v9→v10: kind field added to party entries only
local v9 = {
    v = 9, ap = 1,
    presets = {
        [1] = { name = "P1", cat = "long", qc = 0, spells = {
            ["SPWI304"] = { on = 1, tgt = "s", pri = 1, lock = 0 },
        }},
    },
    opts = { skip = 1 }, ovr = {},
}
local migrated = BfBot.Persist._MigrateConfig(v9, 9)
if migrated.v == 10 and migrated.presets[1].spells["SPWI304"].kind == "spl" then
    _ok("v9→v10 migration sets party kind=\"spl\"")
else
    _nok("v9→v10 migration failed: " .. tostring(migrated.presets[1].spells["SPWI304"].kind))
end
```

**Step 5: Run the test in-game**

In EEex console:

```
BfBot.Test.Persist()
```

Expected: all checks pass including the new v10 case.

**Step 6: Commit**

```bash
git add buffbot/BfBotPer.lua buffbot/BfBotTst.lua
git commit -m "feat(persist): schema v10 adds party kind field

Migration sets missing party kind to \"spl\" on pre-v10 entries.
Validator defaults missing/invalid kind to \"spl\"."
```

---

## Task 5: Rename `_MakeDefaultSpellEntry` → `_MakeDefaultEntry`

**Files:**
- Modify: `buffbot/BfBotPer.lua` (function definition at line 49; callers in same file + `BfBotUI.lua`)

**Step 1: Update the definition**

Replace the function at line 49:

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

Five expected sites in `BfBotPer.lua`: `:115`, `:124`, `:457`, `:498`, `:522`, plus `BfBotUI.lua:727`. Verify count (6).

**Step 3: Run validation**

In-game (the persistence checks are consolidated into one phase):

```
BfBot.Test.Persist()
```

Should pass.

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
- Modify: `buffbot/BfBotPer.lua` `ImportConfig` function (line 763; strip loop at 828-832, inside the `if castable then` guard at :826, drained at 833-836)

**Step 1: Find the spell-stripping block**

In `ImportConfig`, the loop at 828-832 currently looks like this (note the loop variable is `_` — it will become `entry` in Step 2 so we can read `entry.kind`):

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

Add to `BfBot.Test.ExportImport()` (BfBotTst.lua:1040):

```lua
-- Items kept even if not in inventory; spells stripped if not castable
local imported = {
    v = 10, ap = 1,
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

`GetDuration` (signature `(header, ability, _depth, _visited)` at :522) already recurses op=146 sub-spells (depth 2, cycle-guarded; recursion at :535-554, returns 2 values at :581-587). Add a `_leafs` accumulator that collects **ONLY** the op=146 `subRes` resrefs encountered during recursion, and thread it into the recursive self-call at :543. GetDuration has **no top-level resref of its own** — do NOT add the header's own resref:

```lua
function BfBot.Class.GetDuration(header, ability, _depth, _visited, _leafs)
    _depth = _depth or 0
    _visited = _visited or {}
    _leafs = _leafs or {}  -- collected op=146 sub-spell leaf resrefs
    -- ... existing code ...
    -- at the op=146 branch (:535-554), before/at the recursive self-call (:543):
    --   table.insert(_leafs, subRes)   -- the op=146 sub-spell resref
    --   BfBot.Class.GetDuration(subHeader, subAbility, _depth + 1, _visited, _leafs)
end
```

Return signature changes from `(duration, durType)` to `(duration, durType, leafResrefs)`. Adding a 3rd return value is safe — every existing caller takes only the first value: `BfBotScn.lua:59`, `BfBotTst.lua:454` and `:1967`, `BfBotUI.lua:819`. **No caller change needed.**

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

`Classify` (BfBotCls.lua:656) does NOT currently call `GetDuration`, and it returns at **two** sites — the override early-return at :696 and the normal return at :776. Compute the leaf list **once** near the top of `Classify`, then set `result.leafResrefs` BEFORE **both** returns. (If you only set it before the normal return, overridden items get `nil` leafs and already-active detection breaks.)

```lua
-- near the top of Classify (Classify doesn't otherwise call GetDuration):
local _, _, leafResrefs = BfBot.Class.GetDuration(header, ability)
-- ... existing classification logic ...
-- BEFORE the override early-return at :696:
result.leafResrefs = leafResrefs
-- AND BEFORE the normal return at :776:
result.leafResrefs = leafResrefs
```

**Step 4: Run tests**

```
BfBot.Test.DurationRecursion()
BfBot.Test.VerifyKnownSpells()
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

> Scanner anchors verified stable post-merge (audit 2026-06-15).

> **Probe-verified 2026-07-03/05** (folded into the `bg-modding` references): there is NO separate
> quickitem field — one array `sprite.m_equipment.m_items`, slot ranges decide the category.
> Count/charges and ability-target have no named fields (raw offsets below). EEex's
> `Item_Header_st:getAbility(i)` has a confirmed stride bug for i ≥ 1. `UseItem` always fires
> ability 0, so admission must classify ability 0 only; #53 tracks higher-index selection.

**Step 1: Add the constants + ability helper at the top of the module**

Below the `BfBot.Scan = {}` line (line 9):

```lua
-- Inventory access — all verified 2026-07-03 via remote console on BG2EE.
BfBot.Scan._SLOT_EQUIP_MAX = 17   -- 0-17 equipped body slots (10 = FIST pseudo-item)
BfBot.Scan._SLOT_QUICK_MIN = 18   -- 18-20 quickitem slots 1-3
BfBot.Scan._SLOT_QUICK_MAX = 20
BfBot.Scan._SLOT_PACK_MAX  = 34   -- 21-34 backpack
BfBot.Scan._SLOT_WEAPON_MIN = 35  -- 35-38 equipped weapon slots
BfBot.Scan._SLOT_WEAPON_MAX = 38
BfBot.Scan._ITEM_COUNT_OFF = 0x1C -- CItem: count/charges u16 (no named field)
BfBot.Scan._ABIL_TARGET_OFF = 0xC -- Item_ability_st: target byte (no named field)
BfBot.Scan._CAT_POTION = 9        -- Item_Header_st.itemType
BfBot.Scan._CAT_SCROLL = 11       -- deferred by issue #21
BfBot.Scan._CAT_WAND = 35         -- deferred by issue #21

--- Get item ability i via manual pointer arithmetic.
-- Item_Header_st:getAbility(i) is BUGGED in EEex (stride uses header sizeof=114
-- instead of ability sizeof=56) — garbage for i >= 1. Verified 2026-07-03 on STAF11.
function BfBot.Scan._GetItemAbility(header, i)
    return EEex_PtrToUD(
        EEex_UDToPtr(header) + header.abilityOffset + Item_ability_st.sizeof * i,
        "Item_ability_st")
end
```

**Step 2: Add the catalog helper**

Insert after `_buildCountMap`:

```lua
--- Walk a party sprite's inventory (equipped 0-17, quickitems 18-20,
-- backpack 21-34, equipped weapons 35-38) and return item catalog entries.
-- Scrolls/wands remain deferred even in quickslots; backpack admits potions only.
local function _BuildItemCatalog(sprite)
    local items = {}

    local partyOk, portrait = pcall(EEex_Sprite_GetPortraitIndex, sprite)
    if not partyOk or type(portrait) ~= "number" or portrait == -1 then
        return items
    end

    local function _consider(resref, count, allowAnyCat)
        if not resref or resref == "" then return end
        if count <= 0 then return end

        -- Skip BuffBot's own generated resrefs (defensive)
        if resref:sub(1, 4) == "BFBT" then return end

        local hdrOk, header = pcall(EEex_Resource_Demand, resref, "ITM")
        if not hdrOk or not header then return end
        if (header.abilityCount or 0) == 0 then return end  -- passive-only
        local itemType = header.itemType or 0
        if itemType == BfBot.Scan._CAT_SCROLL
            or itemType == BfBot.Scan._CAT_WAND then return end
        if not allowAnyCat and itemType ~= BfBot.Scan._CAT_POTION then
            return  -- backpack: potions only
        end

        if items[resref] then
            items[resref].count = items[resref].count + count
            return
        end

        local aOk, ability = pcall(BfBot.Scan._GetItemAbility, header, 0)
        if aOk and ability then
            local target = EEex_ReadU8(EEex_UDToPtr(ability) + BfBot.Scan._ABIL_TARGET_OFF)
            if target == 1 or target == 5 or target == 7 then
                local cOk, classResult = pcall(
                    BfBot.Class.Classify, resref, header, ability, "itm")
                if cOk and classResult
                    and (classResult.isBuff or classResult.overridden) then
                        local duration, _, leafs = BfBot.Class.GetDuration(header, ability)
                        -- ITM naming: identifiedName FIRST (genericName is the
                        -- unidentified "Potion"/"Ring" — reverse of the SR spell rule)
                        local name = _tryStrref(header.identifiedName)
                                     or _tryStrref(header.genericName)
                                     or resref
                        local icon = ""
                        pcall(function() icon = ability.quickSlotIcon:get() end)
                        items[resref] = {
                            resref = resref,
                            kind = "itm",
                            abilityIdx = 0,
                            name = name,
                            icon = icon,
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
                end
            end
        end
    end

    -- Single walk over the one real inventory array. items:get(i) → CItem|nil.
    local ok = pcall(function()
        local arr = sprite.m_equipment.m_items
        for slot = 0, BfBot.Scan._SLOT_WEAPON_MAX do
            local it = arr:get(slot)
            if it then
                local resref = nil
                pcall(function() resref = it.pRes.resref:get() end)
                if resref and resref ~= "FIST" then
                    local count = EEex_ReadU16(EEex_UDToPtr(it) + BfBot.Scan._ITEM_COUNT_OFF)
                    local allowAnyCat = slot <= BfBot.Scan._SLOT_QUICK_MAX
                        or slot >= BfBot.Scan._SLOT_WEAPON_MIN
                    _consider(resref, count, allowAnyCat)
                end
            end
        end
    end)
    if not ok then
        BfBot._Warn("Item catalog walk failed")
    end

    return items
end
```

**Classifier caveat to verify while here:** `BfBot.Class.Classify` was written for SPL headers — it may read SPL-only header fields (e.g. `secondaryType` for the MSECTYPE fast path, `spellLevel`). On `Item_Header_st` those can be nil; a nil-arithmetic error inside the pcall would silently skip the item. When the probe-test below shows a missing expected item, check classify errors first (temporarily replace pcall with direct call to surface the error) and guard the SPL-only reads with `or 0` / nil-checks in `BfBotCls.lua` as needed.

**Step 3: Probe-test the helper before integrating**

Deploy (`BGEE_DIR="C:/Games/Baldur's Gate II Enhanced Edition modded - Copy - Copy" bash tools/deploy.sh`) while the game and loader are closed, restart through InfinityLoader, load the disposable test save to the world screen, then use the remote console:

```lua
local sp = EEex_Sprite_GetInPortrait(0)
-- temporarily expose: BfBot.Scan._BuildItemCatalog = _BuildItemCatalog (or test inline)
local items = BfBot.Scan._BuildItemCatalog(sp)
local out = {}
for r, e in pairs(items or {}) do table.insert(out, r .. ":" .. e.name .. " x" .. e.count .. " " .. e.durCat) end
return table.concat(out, " | ")
```

Expected on the prepared test save (leader has quickslot potions + backpack rings):
- Buff potions in quickslots 18-20 appear with identified names and correct counts
- `RING05` (Sandthief's Ring, backpack) does NOT appear — backpack non-potions filtered
- `WAND09`/`WAND10` (backpack wands) do NOT appear — backpack filter again
- After manually equipping RING05 (ring slot) + re-scan: RING05 appears (op20 invisibility → isBuff)

**Step 4: Commit**

```bash
git add buffbot/BfBotScn.lua
git commit -m "feat(scan): add _BuildItemCatalog — single m_equipment.m_items walk

Slot rules: equipped/body + quickitems 0-20, backpack 21-34
potions only, and weapon slots 35-38. Scrolls and wands are excluded
by category in every slot. Only ability 0 is admitted because UseItem
always fires ability 0; its target must be 1, 5, or 7 and classify as
a buff (or be this character's persisted exclusion for picker recovery).
Duplicate eligible stacks aggregate counts. Raw count/ability offsets
and the EEex getAbility stride workaround live in the bg-modding refs.
Entries carry kind=itm, abilityIdx=0, and leafResrefs."
```

---

## Task 9: Scanner — merge items into `GetCastableSpells` + add `kind` to spells

**Files:**
- Modify: `buffbot/BfBotScn.lua` `_buildCatalogEntry` and `GetCastableSpells`

**Step 1: Tag spell entries with `kind = "spl"`**

In `_buildCatalogEntry` (function at line 23; the return table is at lines 71-85, with the doc comment at line 22), the returned table currently has:

```lua
return {
    resref = resref,
    name = name,
    icon = icon,
    count = 0,
    -- ...
}
```

Add `kind = "spl",` right after `resref = resref,` (:72):

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

> Exec anchors verified stable post-merge (audit 2026-06-15).

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

In `BfBotPer.lua` `BuildQueueFromPreset` (function at line 952; insert window 994-1000) and `BuildQueueForCharacter` (function at line 1223; insert window 1265-1271) — `scanData` is in scope in both — the queue entries appended at the end need `kind` and `leafResrefs`:

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
- Modify: `buffbot/BfBotExe.lua` `_CheckEntry` (decl of `checkResref` at :331; `_HasActiveEffect` call at :332; splstate-false-positive INFO log at :340, inside block :338-341)

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

**Also fix the second use of the old variable.** `checkResref` was referenced not only at :332 but also at :340 — the splstate-false-positive INFO log inside the block at :338-341. Renaming the local to `checkResrefs` (a list) leaves :340 referencing a now-undefined single resref. Update :340 to log `table.concat(checkResrefs, ",")` instead. Without this, the SCS shared-SPLSTATE path hits a concat-on-`nil` crash (uncaught, surfaced from :372).

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

1. Deploy while the game and loader are closed, then restart through InfinityLoader (do not use cached `Infinity_DoFile`)
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

Palette colors in `BfBotThm.lua` are `"{R, G, B}"` strings (0-255), **not** hex — `_parseColor` (BfBotUI.lua:1748-1752) parses the brace form and won't accept hex. The spell-name color key is **`text`**; the locked-row key is **`spellLocked`** (there is no `nameColor` / `lockedNameColor`).

For each of the 6 palette tables (`bg2_light`, `bg2_dark`, `sod_light`, `sod_dark`, `bg1_light`, `bg1_dark`), insert an `itemColor` entry **immediately after that palette's `lockInactive` key** (lines 70, 92, 114, 136, 158, 180 respectively) — a muted bronze/copper/sienna tint that contrasts with `text` but stays readable:

| Theme | `itemColor` |
|---|---|
| bg2_light | `"{205, 127, 50}"` (bronze) |
| bg2_dark | `"{217, 160, 99}"` (light bronze) |
| sod_light | `"{184, 115, 51}"` (copper) |
| sod_dark | `"{204, 140, 73}"` (light copper) |
| bg1_light | `"{160, 82, 45}"` (sienna) |
| bg1_dark | `"{198, 142, 95}"` (light sienna) |

Exact tints can be tweaked in QA — these are starting values.

**Also document the key** in the Palette Key Glossary (BfBotThm.lua:6-40) — add an `itemColor — spell-name tint for item (kind="itm") rows` line near the other generic text-color entries.

**Step 2: Commit**

```bash
git add buffbot/BfBotThm.lua
git commit -m "feat(theme): itemColor palette key for all 6 themes

Bronze/copper/sienna tones distinguishing item rows from
spell rows in the mixed buff list. Tints chosen to read
on each theme background; refine in QA."
```

---

## Task 14: UI — mixed list rendering (`itemColor` for item rows)

**Files:**
- Modify: `buffbot/BfBotUI.lua` `BfBot.UI._SpellNameColor` (BfBotUI.lua:1746-1753)

**Step 1: Find the row render path**

Row color is computed in `BfBot.UI._SpellNameColor(row)` (BfBotUI.lua:1746-1753). It reads palette keys via `BfBot.UI._T(key)` (which looks up `BfBot.Theme._active[key]`, BfBotThm.lua:195-199) and converts with `_parseColor`. There is **no** `BfBot.Theme.GetActive()` and **no** `theme.nameColor` — do not reference those.

**Step 2: Branch on `entry.kind` in `_SpellNameColor`**

Insert an item branch **before** the existing lock check at :1751, guarded on `entry.lock ~= 1` so a locked item still falls through to `spellLocked` (lock precedence):

```lua
function BfBot.UI._SpellNameColor(row)
    local entry = buffbot_spellTable[row]
    if not entry then return _parseColor(BfBot.UI._T("text")) end
    if entry.castable == 0 then return _parseColor(BfBot.UI._T("textMuted")) end
    if entry.ovr == 1 then return _parseColor(BfBot.UI._T("textAccent")) end
    if entry.kind == "itm" and entry.lock ~= 1 then        -- NEW: item tint
        return _parseColor(BfBot.UI._T("itemColor"))
    end
    if entry.lock == 1 then return _parseColor(BfBot.UI._T("spellLocked")) end
    return _parseColor(BfBot.UI._T("text"))
end
```

**Step 3: Verify items auto-hide the variant buttons (there is NO variant column)**

The spell list (BuffBot.menu:374-478) has 7 columns, **none** for variants — so there is nothing to hide in the row render. Variants are surfaced as swapped action **buttons** (BuffBot.menu:620-708) gated on `buffbot_selectedHasVariants`. Verify that item entries carry `hasVariants = 0` (set in Task 8's `_BuildItemCatalog`) — that makes the variant button layout auto-collapse for item rows. No code change here beyond that confirmation.

**Step 4: Manual QA — reload + open panel**

Deploy while the game and loader are closed, restart through InfinityLoader, and load the disposable test save. Do not use `Infinity_DoFile`; it does not reread changed modules from disk.

Open the BuffBot panel, switch to a character with items. Items should render in the bronze tint; selecting an item row shows no variant swap buttons.

**Step 5: Commit**

```bash
git add buffbot/BfBotUI.lua
git commit -m "feat(ui): mixed list — itemColor tint for item rows

_SpellNameColor returns itemColor for unlocked kind=itm rows.
Lock color still takes precedence (spellLocked). Items carry
hasVariants=0 so the variant buttons auto-hide."
```

---

## Task 15: UI — picker sub-sections (re-add removed spells / items)

**Files:**
- Modify: `buffbot/BfBotUI.lua` (`_BuildPickerList` at :1460, `AddPickedSpell` at :1510)
- Modify: `buffbot/BuffBot.menu` (`BUFFBOT_SPELLPICKER` at :1277, name column at :1296)

**Scoping (locked decision — option b):** Items auto-merge into the main preset list *disabled by default* (the approved "listed but disabled" UX). Items are **not** excluded from the `BfBotPer.lua` auto-merge — they appear in the main list like any buff. Therefore the picker's `[Items]` sub-section scopes **only to items the user has explicitly REMOVED/excluded** (`ovr == -1`), exactly mirroring how removed buff *spells* are re-added via the picker (the v1.3.10 affordance). The picker already implements this for spells: at `_BuildPickerList` :1479 it does `goto nextSpell` on `scan.class.isBuff` **except** when `ovr == -1`. Items (kind="itm", classified as buffs) ride the **same** path — they only surface in the picker after the user removes them. Verify/mirror this existing path; do **not** add a parallel one.

**Step 1: Find the picker row builder**

`BfBot.UI._BuildPickerList` (BfBotUI.lua:1460) populates `buffbot_pickerSpells`; `BfBot.UI.OpenSpellPicker` (:1500) pushes `BUFFBOT_SPELLPICKER`; `BfBot.UI.AddPickedSpell` (:1510) adds the selected row. (The plan's old `_pickerList` / `AddSpellPicker` / `_pickerEntries` names do not exist.)

**Step 2: Tag picker entries with `kind`**

In the `table.insert(buffbot_pickerSpells, {...})` at :1481, add `kind = scan.kind` so the renderer and sort can distinguish item rows from spell rows:

```lua
table.insert(buffbot_pickerSpells, {
    resref   = resref,
    kind     = scan.kind,                 -- NEW: "spl" | "itm"
    name     = scan.name or resref,
    icon     = scan.icon or "",
    durCat   = scan.durCat or "?",
    count    = scan.count or 0,
    excluded = (ovr == -1) and 1 or 0,
})
```

**Step 3: Group with section headers + sort**

After the existing population loop, inject sentinel header rows and re-sort so removed spells and removed items land under labeled sections:

```
[Spells]                     ← header row (isHeader=1), non-clickable
SPWI304 Fireball             ← removed spell row
...
[Items]                      ← header row (isHeader=1), non-clickable
POTN15 Oil of Speed          ← removed item row
```

Implementation: insert sentinels like `{ resref = "__HEADER_SPL__", name = "[Spells]", isHeader = 1 }` / `{ ... name = "[Items]", isHeader = 1 }` at the top of each group. Sort key: spells before items (`kind == "itm" and 1 or 0`), then the existing within-group order (excluded → top, alphabetical), keeping each header immediately above its group. Only emit a header if its group is non-empty.

**Step 4: Render + click-guard the header rows**

- **Color the header rows.** Add a `text color lua` callback to the `BUFFBOT_SPELLPICKER` name column (BuffBot.menu:1296) that returns the `headerSub` palette tint for `isHeader` rows and the normal tint otherwise — so section labels read as headers, not selectable spells.
- **No-op clicks on headers.** Guard `AddPickedSpell` (BfBotUI.lua:1511) at the top:

```lua
function BfBot.UI.AddPickedSpell()
    local entry = buffbot_pickerSpells[buffbot_pickerSelected]
    if not entry or entry.isHeader then return end   -- NEW: ignore header rows
    -- ... existing body ...
```

**Step 5: Manual QA**

Open BuffBot panel → remove a buff spell and an item from the list → Add Spell. The picker should show a `[Spells]` section with the removed spell and an `[Items]` section with the removed item; clicking a header does nothing; clicking a row re-adds it.

**Step 6: Commit**

```bash
git add buffbot/BfBotUI.lua buffbot/BuffBot.menu
git commit -m "feat(ui): picker sub-sections — re-add removed spells / items

Items auto-merge into the main list (disabled by default); the
picker [Items] section scopes to user-removed items (ovr==-1),
mirroring the excluded-buff re-add path. Picker entries carry
kind; header rows are tinted (headerSub) and ignore clicks."
```

---

## Task 16: BfBotTst — `Items()` test phase

**Files:**
- Modify: `buffbot/BfBotTst.lua` (add new phase, register in RunAll)

**Step 1: Add the Items test phase**

Use the **real** harness helpers (BfBotTst.lua:26-49): `_ok` / `_nok` / `_warning` / `_check` / `_summary` / `_reset`. There is **no** `_phase` and **no** `_info`. Every phase opens with `_reset()` (so the pass/fail counters don't bleed from the prior phase) and ends **each** exit path with `return _summary("Items")` — see the pattern at :2742. Append at the end of the file's test phase definitions:

```lua
function BfBot.Test.Items()
    _reset()
    P("=== Items + potions support ===")
    local sprite = EEex_Sprite_GetInPortrait(0)
    if not sprite then _nok("no party member in slot 0"); return _summary("Items") end

    -- 1. Scan finds at least one item if test character has any
    BfBot.Scan.Invalidate(sprite)
    local catalog = BfBot.Scan.GetCastableSpells(sprite)
    local itemCount = 0
    local sampleItem = nil
    for r, e in pairs(catalog) do
        if e.kind == "itm" then itemCount = itemCount + 1; sampleItem = e end
    end
    if itemCount > 0 then _ok("scan found " .. itemCount .. " item entries")
    else _warning("no items in inventory — populate test character to exercise scan path") end

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

    -- 3. Schema v10 round-trip with item entries
    local cfg = {
        v = 10, ap = 1,
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

    return _summary("Items")
end
```

**Step 2: Wire into RunAll**

`BfBot.Test.RunAll` is **not** a simple call-list — it threads a per-phase boolean through a return chain (block :2507-2623). Make three edits:

1. **Run the phase** — alongside the other `local <x>Ok = BfBot.Test.<X>()` calls, add:
   ```lua
   local itemsOk = BfBot.Test.Items()
   P("")
   ```
2. **Summary line** — in the summary block (:2598-2618), add:
   ```lua
   P("  Items: "..(itemsOk and "PASS" or "FAIL"))
   ```
3. **Return chain** — append `and itemsOk` to the aggregate return at :2622.

**Step 3: Run the suite**

In the EEex console, use a test character carrying a confirmed admitted buff
potion and an equipped ability-0 buff item, identified by displayed name on the
test install. Keep Ring of the Ram as an explicit negative/offensive fixture:

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

**Test fixtures to set up (via `CreateItem` BCS or starting items):** identify
them by displayed name because this modded install shifts vanilla resrefs.

- `POTN14` Oil of Speed, `POTN15` Red Potion, `POTN21` Potion of Clarity
- `POTN02` Potion of Fire Resistance (placed in a true backpack slot)
- `RING05` Sandthief's Ring, `RING39` Ring of Gaxx, `BRAC16` Bracers of Blinding Strike
- `RING06`, `AMUL19`, `RING23` passive-item negatives on this install
- `WAND11` and `SCRL07` deferred-category negatives
- `STAF11` Staff of the Magi, whose ability 0 is a melee attack while its buffs
  sit at higher indices (#53 negative)

**Step 1: Test each fixture**

For each item:
1. Place in test character inventory or equip
2. Invalidate the selected sprite's scan cache (`BfBot.Scan.Invalidate(sprite)`); after code changes, deploy closed and restart through InfinityLoader instead of using `Infinity_DoFile`
3. Open BuffBot panel for the character
4. Check: does the item appear? Should it?
5. If a buff: enable in preset, Cast Character, observe result, check stack/charges
6. If a buff: cast again, expect SKIP (already-active path)

**Step 2: Document results**

Capture the QA evidence in the PR test plan and test-install logs. If the live
pass uncovers a new, reusable engine fact, invoke `bg-modding-learn` and record
that fact directly in the appropriate shared reference:

**Completed 2026-08-20 on BG2EE 2.6.6.0 + EEex 1.2.0, disposable
`...modded - Copy - Copy` install:**

| Fixture | Live result |
|---|---|
| Integrated suite | `BfBot.Test.RunAll()` true; SummonCasters 250 pass, Items 19 pass, no failures/warnings in either phase |
| New preset | Six existing item rows were `kind="itm"`, `on=0`, `rep=1` |
| Oil of Speed (`POTN14`) | Cast Character consumed 3→2 and applied the active effect; immediate second cast skipped as already active and stayed at 2 |
| Potion of Clarity (`POTN21`) R2 | 3→2; attempt 1 cast and attempt 2 rechecked/skipped the newly active effect; QC=All never applied to the item |
| Bracers of Blinding Strike (`BRAC16`) | Equipped-slot charge 1→0 and effect active |
| Generated innate `BFBT03` | Normal engine `SpellRES` reached `BFBOTGO`, Red Potion 5→4, and the innate remained present/available |
| Backpack Potion of Fire Resistance (`POTN02`) | Cataloged and consumed from slot 22; effect active |
| Persistence | Loaded an existing schema-v10 item config; exact marshal callback restored `itm→itm`; external export/import restored 3 presets with 0 skips; exhausted `BRAC16` stayed persisted while hidden from rows |
| Combat abort | With a controlled positive detection seam, `RING05` fired 1→0, the chain stopped, and pending `RING39` stayed 1/unfired |
| Negative scope | Passive `RING06`/`AMUL19`/`RING23`, backpack `WAND11`, `SCRL07`, and STAF11 ability 0 stayed excluded |
| Party-only policy | A live non-party Duergar (`portrait=-1`) produced 0 item rows |
| Reacquisition | Newly acquired backpack `POTN03` auto-merged as `kind="itm"`, `on=0`, `rep=1` and became visible |

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

**Goal:** persist verified, reusable engine discoveries so future sessions do
not re-probe them. The known Task 2/3 findings were folded into
`eeex-resources.md` and `eeex-actions.md` on 2026-08-20, and the temporary probe
file was removed. After Task 17, record only genuinely new live-QA findings.

**Step 1: Invoke bg-modding-learn skill**

If Task 17 produces new reusable knowledge, use the skill to record it in the
relevant reference. In particular, check whether QA adds anything beyond the
already-recorded facts:

1. **In `references/eeex-resources.md`:** inventory and quickitem field paths,
slot/count offsets, ability access, and same-resref SPL/ITM cache separation.

2. **In `references/eeex-actions.md`:** `UseItem("RESREF", target)` queueing,
any-slot lookup, automatic consumption/charge handling, and its ability-0-only
limitation.

3. **In another reference only if Task 17 proves an additional engine quirk.**

If Task 17 yields no new reusable engine fact, mark this task complete with no
additional file change. The shared skill references live outside this project
repo and use their separate dotfiles flow.

**Result 2026-08-20:** no new engine-level fact was discovered beyond the
already-folded Task 2/3 probes. The only QA defect was a BuffBot-specific
synthetic summon test seam; it was fixed and regression-covered in commit
`1f96934`.

---

## Task 19: Version bump + CHANGELOG

**Files:**
- Modify: `buffbot/BfBotCor.lua:9` (`BfBot.VERSION`)
- Modify: `buffbot/setup-buffbot.tp2:3` (`VERSION`)
- Modify: `CHANGELOG.md`

**Step 1: Run the bump tool**

Current state after the 2026-08-20 merge is v1.6.4-alpha. The approved #21 release plan uses a minor bump for the first source expansion beyond spells, so the target is v1.7.0-alpha. CI `version-check` remains enforced (tp2 `VERSION` must equal `v` + `BfBot.VERSION`).

```bash
bash tools/bump-version.sh 1.7.0-alpha
```

Verify it updated both:

```bash
grep -E "VERSION|BfBot.VERSION" buffbot/BfBotCor.lua buffbot/setup-buffbot.tp2
```

**Step 2: CHANGELOG entry**

Prepend to `CHANGELOG.md` under a new `## v1.7.0-alpha (2026-08-20)` heading:

```markdown
## v1.7.0-alpha (2026-08-20)

### Added
- **Items + potions as buff sources** (#21 — activated equipped-item abilities + inventory potions; scrolls, wands, containers, and search remain deferred). Buff potions like Oil of Speed and Potion of Heroism, plus activated abilities on equipped rings/amulets/cloaks/etc., now appear alongside spells in each character's preset list (kind="itm", listed but disabled by default). Engine `UseItem("RESREF", target)` BCS verb does the slot lookup at use time — configure by resref, stack multiple of the same potion in inventory freely. Pre-flight already-active detection follows op=146 wrapper SPL chains so a potion's leaf SPL is checked on the target's effect list.
- **Schema v10** — `kind` field on party preset entries. Auto-migrates v9 saves on load (sets missing party `kind = "spl"`); summon presets remain spell-only. Items in imported preset configs are kept regardless of current inventory and reappear when reacquired.
- **Theme — `itemColor` palette key** — bronze/copper/sienna tints for item rows in the mixed buff list. Variant swap buttons auto-hide for item rows (`hasVariants = 0`).
- **Picker sub-sections** — the Add Spell picker groups *removed* spells and *removed* items under "Spells" and "Items" headers, for re-adding.

### Changed
- `BfBot.Class.GetDuration` returns a third value (`leafResrefs` — list of op=146 sub-spell leaf resrefs collected during recursion). Pre-flight skip-if-active uses this list.
- `BfBot.Persist._MakeDefaultSpellEntry` renamed to `_MakeDefaultEntry` with new `kind` parameter (default `"spl"`).
```

**Step 3: Commit**

```bash
git add buffbot/BfBotCor.lua buffbot/setup-buffbot.tp2 CHANGELOG.md
git commit -m "release: v1.7.0-alpha — items + potions as buff sources

Implements #21: (a) activated equipped items + (b) inventory potions.
Scrolls + wands deferred to follow-up issues.
Schema v10 (auto-migrates v9 saves; summons stay spell-only)."
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

Use `Closes #21` only after Task 17 passes in full. If any acceptance check is
still outstanding, use `Refs #21` and keep the PR draft until the live evidence
is complete. Never claim or close #53.

```bash
gh auth switch --user Chrizhermann
gh pr create --repo Chrizhermann/bg-eeex-buffbot --title "feat(items): activated equipped items + inventory potions" --body "$(cat <<'EOF'
Closes #21 by implementing its approved (a)+(b) scope. Scrolls, wands, containers, and search remain deferred; #53 remains open.

## Summary
- New buff sources: activated equipped-item abilities (rings/amulets/etc.) and buff potions from anywhere in inventory.
- Configure by resref, not slot — engine `UseItem(resref, target)` BCS verb does the lookup at use time. Stack multiples freely.
- Listed but disabled by default in new presets.
- Schema bump v9→v10 auto-migrates existing saves; items remain party-only and summon presets stay spell-only.

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

- [x] A character with buff potions plus equipped ability-0 buff items sees them as `kind="itm"`, default disabled; passive, wand, scroll, and higher-index-only STAF11 fixtures remain absent
- [x] Enabling Oil of Speed in a preset and invoking Cast Character drinks one potion, applies Haste, and decrements the stack by 1
- [x] Invoking Cast Character again with Haste already active skips the entry
- [x] The generated F12 innate (`BFBT03`) fires the same item queue path and remains available
- [x] A saved schema-v10 item config loads; exact marshal and external export/import round trips preserve item entries
- [x] Combat detection aborts mid-queue with the pending item untouched
- [x] Existing spell behavior remains green — integrated `BfBot.Test.RunAll()` passes

---

## Risks (carry-over from design)

| # | Risk | Mitigation |
|---|---|---|
| 1 | Inventory field path differs between BG1EE and BG2EE | Probe both in Task 2 |
| 2 | `Item_Header_st:getAbility(i)` typo at `EEex_Resource.lua:165` | Probe Task 3 step 2; if real, swap to direct pointer arithmetic |
| 3 | `UseItem` BCS doesn't fire mid-queue | Task 3 step 3 verifies; fallback to `UseItemSlot` |
| 4 | Equipped activated turns out to be passive | Document, user disables entry |
