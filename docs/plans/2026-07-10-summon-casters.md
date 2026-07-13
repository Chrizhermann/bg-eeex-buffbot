# Summons & Clones as Casters — Implementation Plan (issue #19)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.
>
> **Project-rule note:** the *design* record for this feature is the approved issue comment
> <https://github.com/Chrizhermann/bg-eeex-buffbot/issues/19#issuecomment-4932594923> (CLAUDE.md: design lives in
> GitHub issues). This file is the execution runbook for the plan tooling; it lives on the feature branch only.

**Goal:** Let allied clones (Project Image / Simulacrum) and, generically, any allied spellcasting summon act as additional BuffBot casters, with first-class per-identity preset config, a "Summons" view switch in the panel, joint + standalone firing, and mid-run late-join.

**Architecture:** Casters stop being portrait slots: a caster reference (`"p<slot>"` / `"s<objectID>"`) with a central live-sprite resolver replaces slot keying in the exec engine (freed-pointer discipline per issue #38, object-ID based for summons). Detection is structural (allied + not-party + has castable spells, from the live area). Config is keyed by summon *identity* (clone→owner, summon→scriptname/CRE-resref) under a new `summons` table in the protagonist's schema-v8 config, same shape as character presets so the existing UI/list code is reused via a view switch.

**Tech Stack:** EEex Lua (BG2:EE), `.menu` UI DSL, EEex remote console for headless testing, in-game test suite (`BfBot.Test.RunAll()`).

**Key references while implementing:** invoke the `bg-modding` skill; read `eeex-sprites.md`, `eeex-actions.md`, `gotchas.md` (marshal-no-booleans, Lua-0-truthy, PlayerN join order, sprite `==` unreliable, pcall masks structural errors — log inside every pcall).

**Conventions for every task:**
- Deploy: `bash tools/deploy.sh` (after Task 1 this targets the TEST install `modded - Copy - Copy`).
- Reload one module in the running game: **`Infinity_DoFile` serves a memory cache and does NOT reread disk** (verified again 2026-07-11; see `eeex-filesystem.md`). Force-reload via the documented `io.open` + `loadstring` pattern: `forceLoad("override/BfBotXxx.lua")` sent through the remote console — or ask the user for a game restart when many modules changed / listener re-registration is a concern (Persist.Init/Innate.Init must not run twice).
- Remote console (game must be on world screen, unpaused; single-line Lua only, no heredocs — CRLF breaks loadstring):
  `bash /c/src/private/eeex-remote-console/tools/eeex-remote.sh "c:/Games/Baldur's Gate II Enhanced Edition modded - Copy - Copy/override" '<lua>'`
- After every deploy+run, read `buffbot_test.log` / `buffbot_exec.log` / `buffbot_innate.log` in the game dir directly (never ask for console screenshots).
- **Save-file hygiene (learned Task 6):** BOTH installs share the Documents save dir (OneDrive-redirected) — a quicksave on the test install clobbers the active playthrough's quicksave slot. Any save/load checkpoint uses a DEDICATED named save slot ("BFBT-TEST"), never quicksave. Any synthetic config written for verification must be removed from live config AND the verification save must be re-saved clean (or deleted) before the task closes.
- Every commit message ends with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and the session link footer per harness config.
- All config values are numbers/strings/tables — **no booleans** in anything that reaches UDAux marshal.
- Bracketed placeholders were filled in place by Task 2's probe session (2026-07-11) — see Task 2 Step 3 for the canonical findings record.

---

### Task 1: Feature branch + test-install deploy target

**Files:**
- Modify: `tools/deploy.conf` (gitignored — local only)

**Step 1:** `git checkout -b feat/summon-casters` (from up-to-date `main`).

**Step 2:** ⚠️ **USER CHECKPOINT** — confirm deploy target. `deploy.conf` currently points at the ACTIVE PLAYTHROUGH (`.../modded`). Per project rule, never deploy there. Ask the user to confirm switching it to the test install, then set:
`BGEE_DIR="c:/Games/Baldur's Gate II Enhanced Edition modded - Copy - Copy"`

**Step 3:** Verify the test install has the remote console mod: check `<BGEE_DIR>/override/M_EEexRC.lua` exists; if not, copy it from `C:/src/private/eeex-remote-console/` per that repo's install instructions.

**Step 4:** Sanity round-trip: deploy current main (`bash tools/deploy.sh`), user starts the game on a test save (world screen), then
`bash .../eeex-remote.sh "<override>" 'return tostring(BfBot.VERSION)'` → expect current version string.

**Step 5:** Commit nothing yet (deploy.conf is gitignored). Branch exists.

---

### Task 2: Phase-0 probe session (fills all placeholders)

**Files:**
- Create: `tools/probe_summons.lua` (checked in as a dev tool)
- Modify: THIS PLAN (replace placeholders), memory/bg-modding references via `bg-modding-learn` skill

**Purpose:** verify every engine fact the design depends on, BEFORE production code. Run against a save where the user has summoned: a **Project Image**, a **Simulacrum**, a **Planetar**, and (if available) a **familiar**. ⚠️ **USER CHECKPOINT** — user stages this save (active playthrough install is fine for probing: probes are read-only Lua via remote console, no deploy).

**Step 1:** Write `tools/probe_summons.lua` — a single function `BfBotProbe()` returning one report string. Core (validate/adjust the area-iteration form empirically — the 2026-03 session verified the path but the exact snippet wasn't preserved):

```lua
function BfBotProbe()
    local out = {}
    local function add(fmt, ...) table.insert(out, string.format(fmt, ...)) end
    local leader = EEex_Sprite_GetInPortrait(0)
    if not leader then return "no leader" end
    local area = leader.m_pArea
    -- m_lVertSort values are object IDs, NOT pointers (never EEex_PtrToUD them)
    local ok, err = pcall(function()
        EEex_Utility_IterateCPtrList(area.m_lVertSort, function(v)
            local id = tonumber(v) or (v and v.m_objectID) -- probe which form works
            local obj = id and EEex_GameObject_Get(id)
            if obj and EEex_GameObject_IsSprite(obj, false) then
                local s = EEex_GameObject_CastUserType(obj)
                local otype = pcall(function() return s.m_objectType end) and s.m_objectType or -1
                if otype == 49 then
                    add("name=%s script=%s portrait=%d id=%s",
                        tostring(BfBot._GetName(s)), tostring(s.m_scriptName:get()),
                        EEex_Sprite_GetPortraitIndex(s), tostring(id))
                    -- EA:
                    pcall(function() add("  EA=%d", s.m_typeAI.m_EnemyAlly) end)
                    -- candidate summon/puppet/owner fields (log existence + value):
                    for _, f in ipairs({"m_puppetType","m_nPuppetType","m_puppetMaster",
                        "m_puppetMasterId","m_summonerID","m_summonedBy","m_resref","m_cres"}) do
                        pcall(function() add("  %s=%s", f, tostring(s[f])) end)
                    end
                    -- gender byte (SUMMONED marker) via base stats:
                    pcall(function() add("  gender=%s", tostring(s.m_baseStats.m_gender)) end)
                end
            end
        end)
    end)
    if not ok then add("ITER ERROR: %s", tostring(err)) end
    return table.concat(out, "\n")
end
```

**Step 2:** Load + run via remote console:
`... 'Infinity_DoFile("probe_summons") return BfBotProbe()'`
(copy `probe_summons.lua` into the game override manually for the probe; it is a dev tool, not deployed by deploy.sh).

**Step 3:** Probe results — VERIFIED 2026-07-11 live session (BG2:EE active-playthrough install, EEex v0.11.x
(no `EEex_scripts/`), BuffBot 1.4.0-alpha deployed there, LuaJIT 2.1, SR installed; PI/Sim caster = Imoen L19,
Planetar via Evandra's HLA innate):

- `EA_ALLY_VALUES` = **accept EA 2..30** — verified: PI clone EA=4 (ALLY), Simulacrum EA=4, Planetar EA=4;
  party members EA=2 (PC — excluded by the `portrait == -1` filter, not by EA); neutral townsfolk EA=128.
  Familiar: `UNVERIFIED: no familiar in the party/area — fallback: EA.IDS FAMILIAR=3 sits inside the 2..30 band`.
- `CLONE_MARKER` = **clone-side derived stat 139 `PUPPETMASTERTYPE` (stats.ids): 2=Project Image, 3=Simulacrum**
  (verified both; 1=Mislead per IESDP opcode 83, untested — no Mislead in party). Structural flag:
  `sprite.m_bInCopy == true` / `m_nCopyParent ~= -1` (party baseline: `false`/`-1`). scriptName is **"COPY" for
  BOTH PI and Simulacrum** — it identifies "some clone" but does NOT distinguish the two; use stat 139.
  ⚠️ Owner-side stats 140 `PUPPETTYPE`/141 `PUPPETID` are set **only while a PI-type puppet lives** (Sim leaves
  them 0/-1) — always read the CLONE side. EEex v0.11 has NO `m_puppetType`/`m_puppetMaster` field bindings;
  field discovery via `getmetatable(sprite)[".get"]` enumeration.
- `OWNER_FIELD` = **`sprite.m_nCopyParent`** (owner object ID; verified == owner sprite id and == clone-side
  `getStat(138)` `PUPPETMASTERID` for both PI and Simulacrum). Resolve owner via `EEex_GameObject_Get`.
- `SIMULACRUM_SCRIPTNAME` = **"COPY"** (same as Project Image — see CLONE_MARKER).
- `CRE_RESREF_FIELD` = **`sprite.m_resref`** (CResRef, read via `:get()`). True CRE resref for
  resource-spawned summons (Planetar → `"PLANGOOD"`); ⚠️ for save-baked creatures (party members and their
  clones) the engine replaces the FIRST character with `*` (`*MOEN1`) — treat `*`-prefixed values as
  save-instance, not a usable resref.
- `ITER_FORM` = **`EEex_Utility_IterateCPtrList(area.m_lVertSort, function(v) ... end)` where `v` is a plain
  Lua number — the object ID itself.** Use `EEex_GameObject_Get(v)` → `EEex_GameObject_IsSprite(obj, false)`
  → `EEex_GameObject_CastUserType(obj)`. (Never `EEex_PtrToUD` — IDs, not pointers.)
- `PLANETAR_QUEUE_OK` = **YES** — `EEex_Action_QueueResponseStringOnAIBase('SpellRES("SPPR101",Myself)',
  planetar)` started casting with its own `plangood` script active (t+3s: `EEex_Sprite_GetCastTimer`=83,
  `m_currentActionId`... `curActionID=31` Spell); no script interrupt observed. Planetar had 21 castable priest
  spells via `GetQuickButtons(2,false)` (works on non-party sprites; free with `EEex_Utility_FreeCPtrList`).
- `CLONE_HAS_BFBT_INNATES` = **YES structurally** — PI clone AND Simulacrum copy the owner's complete known-innate
  list (14/14 exact match, verified on both clone types). Caveat: the staged caster (Imoen) had no BuffBot preset,
  hence no BFBT innate to copy — BFBT-specific presence is inferred from wholesale innate copying, not directly
  observed. (Other members carried `BFBT{slot}2`, so SPL resources existed for the 402 test.)
- `402_SOURCE_ID_OK` = **YES** — capture-only `BFBOTGO` hook + queued `ReallyForceSpellRES("BFBT02",Myself)` on
  the PI clone fired the opcode-402 handler with `param1.m_sourceId == 146671805` (the CLONE's object id, not the
  owner's), `m_effectAmount`(slot)=0 and `m_dWFlags`(preset)=2 preserved, `m_sourceTarget`=clone id.
- `MP_RULE` = conservative fallback as designed, **no 2-machine probe yet**: SP → always locally controlled;
  MP → clone joins iff owner sprite resolves AND `BfBot.Mp.IsLocallyControlled(owner)`; ownerless summon
  (`m_nCopyParent == -1`) → joins iff `IsLocallyControlled(EEex_Sprite_GetInPortrait(0))`-equivalent host
  heuristic. Document the limitation in code + CHANGELOG.

**Operational findings that affect later tasks (same session):**
- **Clones/summons are short-lived on this install** (SR-scale durations): PI ≈ 105 s, Simulacrum < 2 min,
  Planetar ≈ 2 min. Object IDs are fresh per spawn (three casts → three distinct ids). Fresh-resolve discipline
  (Task 3 `_ResolveCaster`) is mandatory; anything keyed on oid must expect rapid churn.
- **An active Project Image LOCKS its owner**: queued BCS actions on the owner do NOT execute while the PI
  puppet lives — they stay queued and fire after the puppet expires (observed: queued Simulacrum executed
  ~2 min later, right after PI expiry). Simulacrum does NOT lock the owner. Exec-engine implication (Tasks 4/7/11):
  if a preset casts PI, subsequent owner entries stall until the clone dies — the per-caster watchdog must treat
  a puppet-locked owner as busy-not-stuck (or the plan should order PI last for the owner).
- `Infinity_DoFile` cannot load files ADDED to `override/` mid-session (resource index is built at launch) —
  it silently no-ops. Load ad-hoc probe code via the remote console's `@file` mode instead; re-`DoFile` of
  files present at launch works as documented.
- `EEex_Sprite_GetKnownInnateSpellsWithAbilityIterator` yields `(level, idx, resref, abilityUD)` — 4 values.
- Gender byte binding is `m_baseStats.m_sex` (no `m_gender`); clone keeps the owner's value (2), Planetar sex=4 —
  NOT a usable summon marker here.
- Spell resrefs on this SR install: Project Image `SPWI703`, Simulacrum `SPWI804` (vanilla slots intact),
  Summon Planetar HLA innate = `SPWI923` (relocated — never assume vanilla `SPWI911`).

**Step 4:** Persist verified findings via `bg-modding-learn` (new facts → `eeex-sprites.md` / `gotchas.md`) and paste the probe summary as an issue #19 comment.

**Step 5:** Commit: `git add tools/probe_summons.lua docs/plans/ && git commit -m "chore(summon): phase-0 engine probes for summon casters (#19)"`

---

### Task 3: Caster-key helpers + SummonCasters test-phase skeleton (TDD)

**Files:**
- Modify: `buffbot/BfBotExe.lua` (new helpers near top, after state block ~line 25)
- Modify: `buffbot/BfBotTst.lua` (new phase function + RunAll wiring at `BfBot.Test.RunAll()` ~line 2727)

**Step 1 — failing tests first.** Add `BfBot.Test.SummonCasters()` to BfBotTst.lua, first assertions:

```lua
function BfBot.Test.SummonCasters()
    P("=== Phase: Summon Casters ===")
    local pass, fail = 0, 0
    local function chk(cond, label)
        if cond then pass = pass + 1 P("  OK  " .. label)
        else fail = fail + 1 P("  FAIL " .. label) end
    end
    -- caster key round-trip
    chk(BfBot.Exec._CasterKey({kind="party", slot=3}) == "p3", "party key")
    chk(BfBot.Exec._CasterKey({kind="summon", oid=4711}) == "s4711", "summon key")
    local r = BfBot.Exec._ParseCasterKey("p3")
    chk(r and r.kind == "party" and r.slot == 3, "parse party")
    r = BfBot.Exec._ParseCasterKey("s4711")
    chk(r and r.kind == "summon" and r.oid == 4711, "parse summon")
    chk(BfBot.Exec._ParseCasterKey("x9") == nil, "parse invalid")
    -- resolver: party slot 0 resolves to the leader sprite
    local s = BfBot.Exec._ResolveCaster({kind="party", slot=0})
    chk(s ~= nil and EEex_Sprite_GetPortraitIndex(s) == 0, "resolve party leader")
    -- resolver: bogus summon oid resolves nil, never errors
    chk(BfBot.Exec._ResolveCaster({kind="summon", oid=999999999, name="ZZZ"}) == nil, "resolve dead oid nil")
    P(string.format("SummonCasters: %d passed, %d failed", pass, fail))
    return fail == 0
end
```

Wire into `RunAll()` after the SpellLockPersist phase, same pattern as existing phases.

**Step 2:** Deploy, reload (`Infinity_DoFile("BfBotTst")`), run:
`... 'Infinity_DoFile("BfBotTst") return tostring(BfBot.Test.SummonCasters())'`
Expected: **FAIL** (helpers undefined) — confirm in `buffbot_test.log`.

**Step 3 — implement helpers** in BfBotExe.lua:

```lua
--- Caster reference <-> canonical string key ("p<slot>" party, "s<objectID>" summon).
function BfBot.Exec._CasterKey(ref)
    if ref.kind == "party" then return "p" .. ref.slot end
    return "s" .. ref.oid
end

function BfBot.Exec._ParseCasterKey(key)
    if type(key) ~= "string" then return nil end
    local slot = key:match("^p(%d)$")
    if slot then return { kind = "party", slot = tonumber(slot) } end
    local oid = key:match("^s(%d+)$")
    if oid then return { kind = "summon", oid = tonumber(oid) } end
    return nil
end

--- Resolve a caster ref to a LIVE sprite or nil. Never returns cached userdata.
--- Party: portrait re-resolution (issue-#38 discipline). Summon: object-ID lookup
--- + type/name sanity so a recycled ID never masquerades as our caster.
function BfBot.Exec._ResolveCaster(ref)
    if not ref then return nil end
    if ref.kind == "party" then
        return EEex_Sprite_GetInPortrait(ref.slot)
    end
    local sprite = nil
    pcall(function()
        local obj = EEex_GameObject_Get(ref.oid)
        if obj and EEex_GameObject_IsSprite(obj, false) then
            local s = EEex_GameObject_CastUserType(obj)
            if ref.name and BfBot._GetName(s) ~= ref.name then return end
            sprite = s
        end
    end)
    return sprite
end
```

**Step 4:** Deploy, reload BfBotExe + BfBotTst, re-run phase. Expected: **all OK, return true**. Read `buffbot_test.log` to confirm.

**Step 5:** Commit: `feat(summon): caster reference keys + live-sprite resolver (#19)`

---

### Task 4: Exec engine on caster keys (behavior-neutral for party)

**Files:**
- Modify: `buffbot/BfBotExe.lua` — every `_casters[slot]` site: `_BuildQueue` (~201), `_ProcessCasterEntry` (~392), `_Advance` (~487), `Start` (~636), `_IsStateStale` (~548), `_StripCheatBuffs` (~568), `_SafetyTick` orphan sweep (~811)

**Mechanical switch, no new features:**

1. Queue entries gain `casterRef` (party refs built from existing slot input `{kind="party", slot=casterSlot}`); `byCaster` and `BfBot.Exec._casters` keyed by `_CasterKey(ref)`.
2. Each caster record stores `ref` (plus existing `name`); `caster.sprite` field is REMOVED — every engine call inside `_ProcessCasterEntry`, `_CheckEntry`, cheat toggling resolves fresh: `local sprite = BfBot.Exec._ResolveCaster(caster.ref); if not sprite then <mark caster done, decrement _activeCasters, maybe _Complete(); return> end`. Pass the resolved sprite down (entry.casterSprite stays only as build-time data for scan lookups inside `_BuildQueue`; exec-time code never dereferences it).
3. `_Advance(slot)` → `_Advance(key)`; the queued action becomes
   `string.format("EEex_LuaAction(\"BfBot.Exec._Advance('%s')\")", key)` (single quotes inside the BCS string).
4. `_IsStateStale`: party refs check name-vs-portrait as today; summon refs are IGNORED here (their staleness is per-step resolver-nil → clean caster completion, not whole-run reset).
5. `_StripCheatBuffs` + `_SafetyTick` sweep: iterate `_casters`, resolve via `_ResolveCaster`, queue BFBTCR only on live sprites. The existing party-portrait sweep loop in `_SafetyTick` stays (covers party); add resolved summon casters of the current/last run.
6. `Stop()` / `_HardReset()` unchanged semantics.

**Tests:**
- Extend `SummonCasters` phase: build a party-only queue via `BfBot.Persist.BuildQueueFromPreset(1)`, assert `BfBot.Exec._BuildQueue(queue, 0)` groups under keys matching `^p%d$`.
- Regression: full `RunAll()` must stay green (Exec, QuickCast, CombatSafety phases exercise the engine).
- ⚠️ **USER CHECKPOINT** — manual in-game party cast (normal + Quick Cast) on the test install; verify `buffbot_exec.log` shows the usual plan/CAST/DONE flow.

Run: deploy → `... 'Infinity_DoFile("BfBotExe") Infinity_DoFile("BfBotTst") return tostring(BfBot.Test.RunAll())'` → expect `true`; then manual check.

**Commit:** `refactor(summon): exec engine keyed by caster refs, fresh-resolve every step (#19)`

---

### Task 5: Structural summon detection (`BfBot.Scan.GetAlliedSummons`)

**Files:**
- Modify: `buffbot/BfBotScn.lua` (new section after `ScanParty`, ~line 245)
- Modify: `buffbot/BfBotCor.lua` (add `BfBot._cache.summons = nil` init alongside scan cache)
- Test: `buffbot/BfBotTst.lua` SummonCasters phase

**Step 1 — failing tests:**
```lua
-- detection returns a table (empty OK) and every entry is shaped right
local summons = BfBot.Scan.GetAlliedSummons()
chk(type(summons) == "table", "GetAlliedSummons returns table")
for _, e in ipairs(summons) do
    chk(type(e.oid) == "number" and type(e.identity) == "string"
        and e.kind ~= nil and type(e.name) == "string", "summon entry shape: " .. tostring(e.identity))
end
-- identity derivation is pure and testable without live summons:
chk(BfBot.Scan._SummonIdentity({scriptName="PLANGOOD", creResref="DEVAGO"}) == "plangood", "identity: scriptname")
chk(BfBot.Scan._SummonIdentity({scriptName="", creResref="DEVAGO"}) == "cre:devago", "identity: cre fallback")
chk(BfBot.Scan._SummonIdentity({scriptName="COPY", ownerName="Edwin"}) == "clone:Edwin", "identity: clone")
```

**Step 2 — implement.** Filters, in order, all pcall-guarded with warn-on-error (never silent):
1. iterate current area via `EEex_Utility_IterateCPtrList(area.m_lVertSort, fn)` — callback value IS the object
   ID (plain number) → `EEex_GameObject_Get(id)` → `EEex_GameObject_IsSprite(obj, false)` → `CastUserType` (probe-verified)
2. alive (`EEex_BAnd(state, 0xFC0) == 0`)
3. `EEex_Sprite_GetPortraitIndex(s) == -1`
4. EA in 2..30 (probe: clones + Planetar are EA=4 ALLY; familiar=3 per EA.IDS unverified)
5. `select(2, BfBot.Scan.GetCastableSpells(s)) > 0`

Each hit → `{oid, sprite, name, kind = "clone"|"summon" (clone iff `m_bInCopy`/`m_nCopyParent ~= -1`; PI-vs-Sim via clone-side `getStat(139)`: 2=PI, 3=Sim), identity = _SummonIdentity(...), ownerName (clones: resolve `m_nCopyParent` → sprite → name)}`. `_SummonIdentity`: clone → `"clone:" .. ownerKey (DV-else-name — reuse the resolution helper from the stale-name fix when it lands; name until then)`; else scriptName lowered; else `"cre:" .. m_resref:get()` lowered (skip `*`-prefixed save-instance values); else `"name:" .. name`. Cache in `BfBot._cache.summons` with `Infinity_GetClockTicks()` TTL ~2000ms; `BfBot.Scan.InvalidateSummons()` clears (called on panel open + view switch).

**Step 3:** Deploy, run phase (no summons staged → empty-table branch green; identity unit tests green). Then ⚠️ user stages the PI-clone save → re-run, confirm the clone appears with `kind="clone"`, correct owner. Read `buffbot_test.log`.

**Commit:** `feat(summon): structural allied-summon detection with identity keys (#19)`

---

### Task 6: Schema v8 + summon config accessors + clone seeding

**Files:**
- Modify: `buffbot/BfBotPer.lua` — schema constant + `_Refresh` migration (find the v5→v6 lazy-migration block for the pattern), new accessor section near `GetConfig` (~line 404)
- Test: SummonCasters phase

**Step 1 — failing tests** (pure-Lua, no live summons needed):
```lua
-- v7 -> v8 migration adds summons table (protagonist config)
-- NOTE: v7 is already taken on this branch (spell-lock); summons bump is v8
local cfg = BfBot.Persist.GetConfig(EEex_Sprite_GetInPortrait(0))
chk(cfg.v == 8, "schema v8")
local prot = BfBot.Persist._GetProtagonistConfig()
chk(prot and type(prot.summons) == "table", "protagonist summons table")
-- accessor creates + seeds lazily; summon (non-clone) seeds empty
local sp = BfBot.Persist.GetSummonPreset("plangood", 1)
chk(sp and type(sp.spells) == "table" and next(sp.spells) == nil, "summon seeds empty")
-- clone seeding is a pure function: filter owner's preset to clone's castable set
local ownerPreset = { spells = { SPWI305 = {on=1,tgt="p",pri=1}, SPWI999 = {on=1,tgt="s",pri=2} } }
local cloneCastable = { SPWI305 = {count=1} }
local seeded = BfBot.Persist._SeedCloneSpells(ownerPreset, cloneCastable)
chk(seeded.SPWI305 and seeded.SPWI305.on == 1 and seeded.SPWI999 == nil, "clone seed filters to castable")
```

**Step 2 — implement:**
- `_GetProtagonist()`: loop portraits 0-5, return sprite with `EEex_Sprite_GetCharacterIndex(sprite) == 0`.
- Migration in `_Refresh`: `if config.v == 7 then config.v = 8; config.summons = config.summons or {} end` (summons table lives in every config but only the protagonist's is read — simplest uniform bump; document that).
- `GetSummonPreset(identity, presetIdx, seedCtx)` → `prot.summons[identity].presets[presetIdx]`, creating `{qc=0, spells={}}` lazily; when creating for a clone identity and `seedCtx = {ownerSprite=…, cloneSprite=…}` is given, `spells = _SeedCloneSpells(ownerPreset, GetCastableSpells(cloneSprite))` (deep-copy on/tgt/pri/var).
- `_SeedCloneSpells(ownerPreset, cloneCastable)` pure function as tested.
- Export/import: include `summons` in the exported table (find the export serializer; it already walks the config — verify nested tables of this depth marshal + export cleanly; the marshaler is number/string/table-safe by construction).

**Step 3:** Deploy, reload BfBotPer + BfBotTst, run phase → green. Save + reload the game once, re-run `chk(cfg.v == 7 …)` to prove the marshal round-trip survives.

**Commit:** `feat(summon): schema v8 — per-identity summon presets on protagonist config, clone seeding (#19)`

---

### Task 7: Queue building — standalone + preset sweep + INI kill-switch

**Files:**
- Modify: `buffbot/BfBotPer.lua` — `BuildQueueFromPreset` (~954), new `BuildQueueForSummon`, `_INI_DEFAULTS` (+`SummonsJoinCast=1`)
- Modify: `buffbot/BfBotExe.lua` — `_BuildQueue` accepts summon caster entries (`entry.casterRef` already supported from Task 4; add the summon-side sprite resolution + the conservative MP rule from Task 2 findings / Task 13)
- Test: SummonCasters phase

**Step 1 — failing tests** (inject a fake summon so no live game state needed):
```lua
-- BuildQueueForSummon produces caster refs "s<oid>" honoring on/pri/tgt
-- (test seam: BfBot.Persist.BuildQueueForSummon(summonEntry, presetIdx) takes the
--  detection-entry table, so tests can hand-craft one pointing at a party sprite's
--  oid — a party sprite IS a valid CGameSprite for scan purposes.)
local leader = EEex_Sprite_GetInPortrait(0)
local fake = { oid = leader.m_id, sprite = leader, name = BfBot._GetName(leader),
               kind = "summon", identity = "test:fake" }
BfBot.Persist.GetSummonPreset("test:fake", 1).spells["SPWI305"] = {on=1, tgt="s", pri=1}
local q = BfBot.Persist.BuildQueueForSummon(fake, 1)
-- leader may not know SPWI305 — assert structure not castability:
chk(q == nil or (q[1] and q[1].casterRef and q[1].casterRef.kind == "summon"), "summon queue caster ref")
-- cleanup test identity afterwards
```
Plus: `GetPref("SummonsJoinCast") == 1` default; with pref set 0, `BuildQueueFromPreset` output contains no `kind=="summon"` refs even when `GetAlliedSummons` is stubbed to return one (stub via temporary function swap inside the test, restore after).

**Step 2 — implement:**
- `BuildQueueForSummon(summonEntry, presetIdx)`: scan `summonEntry.sprite` (fresh `GetCastableSpells`), walk `GetSummonPreset(identity, presetIdx).spells` exactly like the per-character builder (reuse `_ResolveConfigTarget` with `casterRef={kind="summon", oid=…, name=…}` instead of slot; `tgt="s"` → self, names → PlayerN as today).
- `BuildQueueFromPreset(N)`: after the party loop, if `GetPref("SummonsJoinCast") == 1`, for each `GetAlliedSummons()` entry passing the MP rule (Task 13; SP short-circuits true) with a non-empty enabled preset-N table, append `BuildQueueForSummon(...)` entries.
- **Puppet-lock policy (from probe — an active Project Image engine-locks its owner; queued owner actions become delayed "zombie casts" firing at image expiry):**
  1. A live PI-type clone (stat 139 == 2) of owner X exists at build time → **skip ALL of owner X's entries** with logged SKIP `"<owner> puppet-locked by Project Image — cast again after the image expires"`. The clone casts instead; queuing the owner would zombie.
  2. Owner's own chain contains a PI-type summon cast with entries AFTER it (user priority order is never reordered — project invariant): entries after the PI entry are **dropped at build time** with logged SKIP `"entries after Project Image skipped — owner locked while image is active"`; entries before it run normally; the PI cast itself runs (late-join then attaches the fresh clone). Detect "spell summons a PI-type clone" pragmatically: resref == the known PI spell on this install is NOT assumable (SR relocation) — instead flag at runtime: if after an owner's cast the owner acquires `m_bInCopy` children… too fragile for v1; instead detect at build time by spell name match ("project image", case-insensitive) via the scan entry's name, and document the limitation (modded PI-alikes that lock without the name won't be caught; their trailing entries fire delayed — watchdog still completes the run).
  3. Simulacrum locks nothing — no special handling.
- Exec `_BuildQueue`: summon entries resolve caster sprite via `_ResolveCaster` at build time for the scan checks; skip with logged SKIP if gone.
- **Allegiance re-validation (Task 5 review carry-forward):** detection entries reflect allegiance AT SWEEP TIME only. Queue build re-classifies via `ClassifySummonSprite` (not the cached entry); and the per-step summon resolve in exec extends its gone-check with an EA-band re-read (cheap field) so a charm breaking / summon turning hostile mid-run ends its chain instead of receiving buffs.
- **Gone-summon sweep (Task 4 review condition I1):** a summon destroyed mid-cast takes its queued `EEex_LuaAction` advance with it — the per-step gone path never fires and the run stalls until the 30s watchdog (whose WARN text blames multiplayer). In `_SafetyTick`'s `state=="running"` branch, BEFORE the watchdog check, sweep summon-kind not-done casters and `_FinishGoneCaster` any whose ref resolves nil → ≤2s clean completion with a correct DONE summary. Summon-only — party slots stay per-step. Soften `_FinishGoneCaster`'s comment ("never stall *indefinitely*") and generalize the watchdog WARN text (no longer only an MP symptom).

**Step 3:** Deploy, run phase → green (fail-first observed in between).

**Commit:** `feat(summon): summon queues — standalone builder, preset sweep, INI kill-switch (#19)`

---

### Task 8: Live-clone standalone execution ⚠️ USER CHECKPOINT

No new code — end-to-end verification of Tasks 3–7 with a real Project Image on the test install:

1. User stages: mage with PI memorized, casts PI, world screen.
2. Configure via console for now (UI lands in Task 10):
   `... 'local s = BfBot.Scan.GetAlliedSummons()[1] BfBot.Persist.GetSummonPreset(s.identity, 1, {ownerSprite=EEex_Sprite_GetInPortrait(0), cloneSprite=s.sprite}) return s.identity'` → expect `clone:<OwnerName>` and seeded spells.
3. `... 'local s = BfBot.Scan.GetAlliedSummons()[1] local q = BfBot.Persist.BuildQueueForSummon(s, 1) return tostring(q and #q)'` → entry count > 0.
4. `... '<same> BfBot.Exec.Start(q, 0) return "started"'` → clone visibly casts, party untouched.
5. Read `buffbot_exec.log`: plan lists the clone by name, CAST lines, DONE. Kill the clone mid-run once (attack it) → run completes cleanly via resolver-nil (no 30s watchdog wait, no errors).
6. Reload-a-save-mid-clone-run once → `_SafetyTick` recovers to idle, no crash (issue-#38 regression for the new path).

**Commit** (only if fixes were needed): `fix(summon): live-clone execution findings (#19)`

---

### Task 9: UI selection refactor (`_GetSelectedSprite`) — behavior-neutral

**Files:**
- Modify: `buffbot/BfBotUI.lua` — add helper near `_charSlot` (~line 22); replace all ~28 `EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)` call sites (lines 645, 680, 919, 1061, 1111, 1147, 1189, 1205, 1222, 1344, 1468, 1518, 1538, 1573, 1611, 1676, 1785, 1840, 1849, 1858, 1867, …grep to catch all)

```lua
--- Current view's selected sprite: party tab (portrait slot) or summon tab (live resolve).
--- Always a fresh resolve — never cache the return across frames.
function BfBot.UI._GetSelectedSprite()
    if BfBot.UI._view == "summons" then
        local e = BfBot.UI._SelectedSummon()   -- Task 10; returns nil until then
        return e and BfBot.Exec._ResolveCaster({kind="summon", oid=e.oid, name=e.name}) or nil
    end
    return EEex_Sprite_GetInPortrait(BfBot.UI._charSlot)
end
```
(`BfBot.UI._view` defaults `"party"`; `_SelectedSummon` stub returns nil.) Also route the slot-validity fallback at line 645 through the helper (nil → reset to party slot 0).

**Test:** full `RunAll()` (SubwindowDetection/TargetPicker phases touch UI paths) + manual panel smoke: tabs, spell list, target picker, cast — unchanged. ⚠️ quick user look.

**Commit:** `refactor(summon): UI selected-sprite behind view-aware helper (#19)`

---

### Task 10: Summons view — button, tab source, paging, empty state ⚠️ USER CHECKPOINT

**Files:**
- Modify: `buffbot/BfBotUI.lua` — view state (`_view`, `_summonPage`, `_summonSel`, `_summonList` refresh from `GetAlliedSummons` on open/switch), `_SelectedSummon()`, tab-row data provider, per-char cast handler variant calling `BuildQueueForSummon`
- Modify: `buffbot/BuffBot.menu` — "Summons"/"Party" toggle button next to the tab row; prev/next page buttons + "1/2" label with `enabled`-style visibility lua (only when `#list > 6`); empty-state label "No allied summons detected"
- Test: SummonCasters phase + manual

**Implementation notes (follow existing tab-row patterns in BuffBot.menu / BfBotUI):**
- Tab labels in summon view: summon display name (+ owner for clones: `Edwin's Image`); selection sets `_summonSel` (identity-stable: reselect by identity after list refresh, not row index — `rowNumber` staleness gotcha).
- Switching views: `BfBot.Scan.InvalidateSummons()`, reset page, keep `_presetIdx` shared.
- Clone tabs opening for the first time on preset N call `GetSummonPreset(identity, N, seedCtx)` → seeded list appears pre-configured.
- Cast button label in summon view: "Cast (this summon)"; handler = `BuildQueueForSummon(selected, _presetIdx)` → `Exec.Start`.
- A live summon vanishing while viewed: `_GetSelectedSprite()` nil → view shows empty state / falls back to party view on next tick (reuse line-645 pattern).

**Tests:** phase asserts pure bits (page math: `_SummonPageSlice(list, page)` returns ≤6 with correct offsets; label composition for clone vs summon). Manual: user runs through view switch, seeding, standalone cast, paging (spawn >6 castable allies via console if feasible, else skip paging visual), empty state.

**Review hand-offs (recorded 2026-07-14; Task 9 review conditions + Task 7 residuals — all REQUIRED here):**
1. `SetChar` (BfBotUI ~903) must set `_view = "party"` — otherwise clicking a portrait tab while in summons view changes the slot without leaving the view.
2. Selection-adjacent slot reads the Task 9 helper deliberately does not cover — make them view-aware: `CastCharacter`'s `BuildQueueForCharacter(BfBot.UI._charSlot, …)` (~1249; in summons view route to `BuildQueueForSummon(selected, _presetIdx)`), `_CastCharLabel` (~1265), `_IsCharSelected` (~1316), `_CanCastAll`'s `slot ~= _charSlot` skip (~1337).
3. `_SelectedSummon()` entries MUST always carry `name` — `_resolveSummon`'s anti-oid-recycle guard (BfBotExe ~54) is conditional on `ref.name`; a nameless entry silently degrades to oid-only matching. Treat `name` as mandatory in the summon list model (refuse to list nameless entries).
4. From Task 7 residuals (#19 comment): a build returning nil due to puppet-lock should surface a distinct reason string in the panel (pattern: the existing "not locally controlled" reason near ~1229) instead of the generic "no castable spells"; and surface build-time SKIP lines in the panel log view (`Exec.Start` currently resets `_log` an instant after the builder logs them — file-only today).
5. `GetAlliedSummons()` returns CACHE-OWNED tables — copy before sorting/mutating for `_summonList`.

**Commit:** `feat(summon): summons view — tab-row switch, paging, seeded clone tabs, standalone cast (#19)`

---

### Task 11: Late-join listener ⚠️ USER CHECKPOINT

**Files:**
- Modify: `buffbot/BfBotExe.lua` — `_AttachCaster(summonEntry, presetIdx)` (insert caster record, `_activeCasters += 1`, log "late-join", `_ProcessCasterEntry(key, 1)`), listener registration in `M_BfBot.lua`/init path via `EEex_Sprite_AddLoadedListener`
- Test: SummonCasters phase (attach path unit-ish) + live scenario

**Listener body (guards in this order, all cheap-first):**
```lua
EEex_Sprite_AddLoadedListener(function(sprite)
    if BfBot.Exec._state ~= "running" then return end
    if BfBot.Exec._runPresetIdx == nil then return end          -- set by Start()
    -- NOT a bare pcall: check the result and BfBot._Warn on failure (silent-pcall landmine —
    -- a structurally broken listener would silently disable late-join forever).
    local ok, err = pcall(function()
        if EEex_Sprite_GetPortraitIndex(sprite) ~= -1 then return end
        -- structural filter reused (single-sprite form of GetAlliedSummons):
        local e = BfBot.Scan.ClassifySummonSprite(sprite)        -- nil if not allied castable summon
        if not e then return end
        local key = "s" .. e.oid
        if BfBot.Exec._casters[key] then return end              -- already attached
        local q = BfBot.Persist.BuildQueueForSummon(e, BfBot.Exec._runPresetIdx)
        if not q or #q == 0 then return end
        BfBot.Exec._AttachCaster(e, q)
    end)
end)
```
Requires: `Start()` records `_runPresetIdx` (pass presetIdx through from the preset-driven entry points; console-built raw queues pass nil → late-join inert, correct). Extract the per-sprite filter from Task 5's loop into `ClassifySummonSprite(sprite)` so area sweep and listener share it. Listener fires for area transitions/save loads too — the `_state=="running"` + structural guards make those no-ops; a save-load mid-run additionally hits `_IsStateStale` first (reset → not running).

**Live test:** preset with Project Image as priority-1 self entry + party buffs; one Cast press → owner casts PI → clone spawns → log shows `late-join: Edwin's Image (…entries)` → clone casts its seeded list in the same run. Also verify: loading a save while idle triggers nothing (log clean).

**Commit:** `feat(summon): late-join — summons spawning mid-run attach as casters (#19)`

---

### Task 12: Clone F12 innates (probe verdict: `402_SOURCE_ID_OK` = **YES** → task is a GO)

**Files:**
- Modify: `buffbot/BfBotInn.lua` — `BFBOTGO` (~line 643)

If probe said yes: before the owner-queue branch, resolve `param1.m_sourceId` → sprite; if it is a live summon (`ClassifySummonSprite`), run `BuildQueueForSummon(e, presetIdx)` + `Exec.Start` instead of `BuildQueueForCharacter(slot, …)`; keep the re-grant `AddSpecialAbility` targeting the OWNER slot exactly as today (the clone's copy vanishes with the clone; never re-grant onto the clone). If probe said no: skip task, note in issue.

**Test:** live — press a BFBT innate on the clone's bar → only the clone casts; `buffbot_innate.log` shows the summon branch. Owner F12 unchanged (regression).

**Commit:** `feat(summon): clone-cast BFBT innates run the clone's own list (#19)`

---

### Task 13: Multiplayer rule

**Files:**
- Modify: `buffbot/BfBotMp.lua` (+`BfBot.Mp.IsSummonLocallyControlled(summonEntry)`), call sites in `BuildQueueFromPreset` sweep + late-join guard

Per the MP rule recorded in Task 2 Step 3 (conservative default, **no 2-machine probe yet**): SP → always true; MP → clone true iff owner sprite resolves and `IsLocallyControlled(owner)`; ownerless summon → true iff `IsLocallyControlled(EEex_Sprite_GetInPortrait(0))`-equivalent host heuristic — document the limitation in code and CHANGELOG ("MP summon support is conservative pending 2-machine probe", mirroring the existing MP-probe workflow).

**Test:** phase asserts SP short-circuit true; MP behavior flagged for the next 2-machine session (tracked in issue #19 like the existing MP filter work).

**Commit:** `feat(summon): conservative multiplayer gate for summon casters (#19)`

---

### Task 14: Full regression, docs, close-out

1. Full `RunAll()` green on the test install; read all three logs.
2. ⚠️ **USER CHECKPOINT** — final manual pass: party-only regression, clone standalone, joint fire, late-join, view UX.
3. `CHANGELOG.md`: `v1.6.0-alpha — summons & clones as casters` (feature summary, MP caveat, schema v8 note: saves upgrade lazily, downgrade unsupported). NO `--prerelease` flag on any release (project rule).
4. `CLAUDE.md`: add module-facts (schema v8 shape, `GetAlliedSummons` filters, caster-key format) to the invariants section — short. Note: CLAUDE.md still says "Config schema v6" — it is v7 on this branch already (spell-lock); correct it while there.
5. `bg-modding-learn`: record any further verified findings from Tasks 8–13.
6. Issue #19: comment "implemented on feat/summon-casters @ <sha>, verified scenarios: …", tick the body's task list.
7. PR `feat/summon-casters` → `main` (personal account `Chrizhermann`), body ends with the standard generated-with footer. Merge + release only on user go-ahead.

**Commit:** `docs(summon): changelog v1.6.0-alpha + invariants for summon casters (#19)`

---

## Task dependency graph

```
T1 ─ T2 ─┬─ T3 ─ T4 ─┬─────────────┬─ T7 ─ T8 ─ T11 ─ T12
         │           │             │
         ├─ T5 ──────┤ (T7 needs T5+T6+T4)
         ├─ T6 ──────┘
         └─ T9 ─ T10 (T10 also needs T5+T6)
T13 needs T5.  T14 needs everything.
```
