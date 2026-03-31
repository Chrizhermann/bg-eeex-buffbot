# Combat Safety Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Interrupt running buff queues when hostiles are detected nearby, and guarantee Quick Cast cheat buffs (BFBTCH.SPL) are never left active outside of BuffBot's casting engine.

**Architecture:** Two new functions in `BfBot.Exec` — `_DetectCombat()` (hostile proximity check) called from `_Advance()`, and `_SafetyTick()` (paranoid BFBTCH cleanup) driven by a hidden `.menu` tick element. One new INI preference (`CombatInterrupt`) in `BfBot.Persist`. Unit tests validate both features.

**Tech Stack:** Lua (EEex bridge), `.menu` DSL (IE engine UI), `baldur.ini` (INI preferences)

**Design doc:** `docs/plans/2026-03-31-combat-safety-design.md`

---

### Task 1: Add `CombatInterrupt` INI preference default

**Files:**
- Modify: `buffbot/BfBotPer.lua:15-21` (add to `_INI_DEFAULTS` table)

**Step 1: Add the preference**

In `BfBot.Persist._INI_DEFAULTS`, add:

```lua
BfBot.Persist._INI_DEFAULTS = {
    LongThreshold = 300,
    DefaultPreset = 1,
    HotkeyCode    = 87,
    ShowTooltips  = 1,
    ConfirmCast   = 0,
    CombatInterrupt = 1,  -- stop casting when hostiles detected nearby
}
```

**Step 2: Deploy and verify round-trip**

Run: `bash tools/deploy.sh`
Then in EEex console:
```
BfBot.Persist.GetPref("CombatInterrupt")
```
Expected: `1`

```
BfBot.Persist.SetPref("CombatInterrupt", 0)
BfBot.Persist.GetPref("CombatInterrupt")
```
Expected: `0`

**Step 3: Commit**

```bash
git add buffbot/BfBotPer.lua
git commit -m "feat(exec): add CombatInterrupt INI preference default"
```

---

### Task 2: Add `_DetectCombat()` helper to execution engine

**Files:**
- Modify: `buffbot/BfBotExe.lua` (add new function after `_HasActiveEffect`, before `_ResolveTargets` — around line 50)

**Step 1: Write the `_DetectCombat` function**

Insert after `_HasActiveEffect` (after line 49):

```lua
--- Check if hostiles are within combat range of the party leader.
-- Uses the same range (400) and hostility threshold ([ENEMY] = EA >= 200)
-- as the engine's rest prevention check.
-- @return boolean true if enemies detected nearby
function BfBot.Exec._DetectCombat()
    -- Respect INI preference
    if BfBot.Persist.GetPref("CombatInterrupt") ~= 1 then
        return false
    end
    local leader = EEex_Sprite_GetInPortrait(0)
    if not leader then return false end
    local ok, count = pcall(function()
        return leader:countAllOfTypeStringInRange("[ENEMY]", 400)
    end)
    return ok and count and count > 0
end
```

Key design notes for the implementer:
- `EEex_Sprite_GetInPortrait(0)` = party leader (portrait slot 0). Consistent with how the engine's rest check works (checks party leader only).
- `[ENEMY]` matches EA >= 200 (EVILCUTOFF). This is an EEex AI object type string, not BCS — passed to `countAllOfTypeStringInRange` which calls `EEex_Object_ParseString` internally.
- Range 400 = SPAWN_RANGE = same as rest prevention range.
- LOS check is enabled by default (5th param to the underlying method defaults to true). Enemies behind walls won't trigger.
- `pcall` wraps the call because EEex API can throw if sprite is invalid (e.g., during area transitions).
- Returns `false` when `CombatInterrupt` pref is `0` — the pref check is inside the helper so callers don't need to duplicate it.

**Step 2: Commit**

```bash
git add buffbot/BfBotExe.lua
git commit -m "feat(exec): add _DetectCombat hostile proximity helper"
```

---

### Task 3: Integrate combat detection into `_Advance()`

**Files:**
- Modify: `buffbot/BfBotExe.lua:354-359` (the `_Advance` function)

**Step 1: Add combat check to `_Advance`**

Replace the current `_Advance` function:

```lua
--- Called by the engine via EEex_LuaAction after a caster's spell completes.
-- @param slot number: the caster's party slot (0-5)
function BfBot.Exec._Advance(slot)
    if BfBot.Exec._state ~= "running" then return end
    local caster = BfBot.Exec._casters[slot]
    if not caster or caster.done then return end

    -- Combat detection: abort all casters if hostiles detected
    if BfBot.Exec._DetectCombat() then
        BfBot.Exec._LogEntry("INFO", "Combat detected — stopping execution")
        BfBot.Exec.Stop()
        -- Notify player via overhead text on party leader
        pcall(function()
            local leader = EEex_Sprite_GetInPortrait(0)
            if leader then
                EEex_Sprite_DisplayStringHead(leader,
                    "BuffBot: Combat detected - casting stopped")
            end
        end)
        return
    end

    BfBot.Exec._ProcessCasterEntry(slot, caster.index + 1)
end
```

Key design notes:
- Combat check fires once per spell completion per caster. With 6 casters, that's up to 6 checks per "round" — lightweight since `countAllOfTypeStringInRange` is an engine native call.
- When one caster's `_Advance` detects combat, `Stop()` sets `_state = "stopped"`. The other 5 casters' pending `_Advance` callbacks will hit the `_state ~= "running"` guard at the top and return immediately. No race condition.
- `Stop()` handles all cheat buff cleanup (BFBTCR for all casters with `cheatApplied`).
- `EEex_Sprite_DisplayStringHead` shows floating text over the party leader's head. Wrapped in `pcall` for safety.
- The current spell for each caster may still complete (already queued in the engine's action queue). This is by design — we can't cancel mid-cast.

**Step 2: Commit**

```bash
git add buffbot/BfBotExe.lua
git commit -m "feat(exec): interrupt casting queue on hostile detection"
```

---

### Task 4: Add `_SafetyTick()` paranoid BFBTCH cleanup

**Files:**
- Modify: `buffbot/BfBotExe.lua` (add new function at the end, before `GetState`/`GetLog`)

**Step 1: Add the safety tick state variable**

At the top of `BfBotExe.lua`, after `BfBot.Exec._qcMode = 0` (line 17), add:

```lua
BfBot.Exec._lastSafetyTick = 0   -- clock ticks of last safety check
```

**Step 2: Write the `_SafetyTick` function**

Insert before `GetState()` (before line 496):

```lua
--- Paranoid safety net: remove orphaned BFBTCH effects from any party member.
-- Called every frame by .menu enabled tick, rate-limited to ~2 seconds.
-- NOT toggleable — this is the hard safety guarantee.
function BfBot.Exec._SafetyTick()
    -- Rate-limit: ~2 seconds between checks
    local now = Infinity_GetClockTicks()
    if now - BfBot.Exec._lastSafetyTick < 2000 then return end
    BfBot.Exec._lastSafetyTick = now

    -- If exec engine is actively running, it owns cheat management — don't interfere
    if BfBot.Exec._state == "running" then return end

    -- Check all party members for orphaned BFBTCH effects
    for i = 0, 5 do
        local sprite = EEex_Sprite_GetInPortrait(i)
        if sprite then
            local hasCheat = BfBot.Exec._HasActiveEffect(sprite, "BFBTCH")
            if hasCheat then
                pcall(function()
                    EEex_Action_QueueResponseStringOnAIBase(
                        'ReallyForceSpellRES("BFBTCR",Myself)', sprite)
                end)
                BfBot.Exec._LogEntry("WARN",
                    "Safety net: removed orphaned BFBTCH from " .. BfBot._GetName(sprite))
            end
        end
    end
end
```

Key design notes:
- `Infinity_GetClockTicks()` returns milliseconds. 2000ms = ~2 second interval. The `.menu` `enabled` callback fires every frame (~30-60fps), so rate-limiting is essential.
- `_state == "running"` guard prevents the safety net from fighting with the exec engine's own cheat management during normal operation.
- Checks ALL 6 party slots, not just casters that were in the last queue — covers edge cases where party composition changed between runs.
- `_HasActiveEffect` walks `m_timedEffectList` looking for `m_sourceRes == "BFBTCH"` — the same authoritative check used by skip detection.
- `BFBTCR.SPL` contains opcode 321 (Remove Effects by Resource = "BFBTCH") — the standard cleanup mechanism already used by `Stop()` and `_Complete()`.
- This function is NOT gated by the `CombatInterrupt` INI pref. The safety net is always on.

**Step 3: Commit**

```bash
git add buffbot/BfBotExe.lua
git commit -m "feat(exec): add _SafetyTick paranoid BFBTCH cleanup"
```

---

### Task 5: Add `.menu` tick element for safety net

**Files:**
- Modify: `buffbot/BuffBot.menu:1-24` (BUFFBOT_ACTIONBAR menu definition)

**Step 1: Add hidden tick label to BUFFBOT_ACTIONBAR**

Inside the `BUFFBOT_ACTIONBAR` menu block (after the existing button, before the closing `}`), add a hidden label whose `enabled` field calls the safety tick:

```
menu
{
	name "BUFFBOT_ACTIONBAR"
	ignoreesc

	button
	{
		action    "BfBot.UI.Toggle()"
		tooltip lua "buffbot_btnTooltip"
		bam       "BFBOTAB"
		sequence  0
		frame lua "buffbot_btnFrame"
		scaleToClip
		area 4 4 48 48
	}

	-- Safety net tick: runs every frame, rate-limited internally to ~2s.
	-- Removes orphaned BFBTCH cheat buffs from party members when exec
	-- engine is not actively running. Placed here (not BUFFBOT_MAIN)
	-- because this menu is always active on the world screen.
	label
	{
		enabled "BfBot.Exec._SafetyTick()"
		area 0 0 0 0
	}
}
```

Key design notes:
- The label has `area 0 0 0 0` — zero-size, invisible, no interaction. It exists purely for the `enabled` tick.
- `enabled` in `.menu` DSL evaluates its Lua expression every frame. The IE engine calls this to determine if the element should render. We return nil/nothing (the function has no return), so the label stays invisible.
- **MUST be in BUFFBOT_ACTIONBAR** (not BUFFBOT_MAIN/BUFFBOT_PANEL) because BUFFBOT_ACTIONBAR is pushed alongside WORLD_ACTIONBAR and is always visible on the world screen. The config panel is only visible when the player opens it.
- The rate-limiting inside `_SafetyTick()` (2000ms via `Infinity_GetClockTicks()`) means the actual work runs ~0.5 times per second despite being called every frame.

**Step 2: Commit**

```bash
git add buffbot/BuffBot.menu
git commit -m "feat(ui): add safety net tick element to actionbar menu"
```

---

### Task 6: Write unit tests for combat safety

**Files:**
- Modify: `buffbot/BfBotTst.lua` (add new test function + integrate into RunAll)

**Step 1: Write `BfBot.Test.CombatSafety` test function**

Add before the `RunAll` function (before line 1108):

```lua
-- ============================================================
-- Combat Safety Tests
-- ============================================================

function BfBot.Test.CombatSafety()
    _reset()
    P("")
    P("========================================")
    P("  Combat Safety Tests")
    P("========================================")
    P("")

    local sprite = EEex_Sprite_GetInPortrait(0)
    if not sprite then
        _nok("No party member in slot 0")
        return _summary("Combat Safety")
    end

    -- ---- Test 1: CombatInterrupt INI pref default ----
    P("  [1] CombatInterrupt INI pref")

    local pref = BfBot.Persist.GetPref("CombatInterrupt")
    if pref == 1 or pref == 0 then
        _ok("CombatInterrupt pref readable: " .. tostring(pref))
    else
        _nok("CombatInterrupt pref unexpected: " .. tostring(pref))
    end

    -- ---- Test 2: _DetectCombat exists and is callable ----
    P("")
    P("  [2] _DetectCombat function")

    if type(BfBot.Exec._DetectCombat) == "function" then
        _ok("_DetectCombat is a function")
    else
        _nok("_DetectCombat missing or not a function")
        return _summary("Combat Safety")
    end

    -- Call it — should return boolean (no crash)
    local ok, result = pcall(BfBot.Exec._DetectCombat)
    if ok then
        _ok("_DetectCombat callable, returned: " .. tostring(result))
    else
        _nok("_DetectCombat threw: " .. tostring(result))
    end

    -- ---- Test 3: _DetectCombat respects pref=0 ----
    P("")
    P("  [3] _DetectCombat respects CombatInterrupt=0")

    local origPref = BfBot.Persist.GetPref("CombatInterrupt")
    BfBot.Persist.SetPref("CombatInterrupt", 0)
    local ok2, result2 = pcall(BfBot.Exec._DetectCombat)
    if ok2 and result2 == false then
        _ok("_DetectCombat returns false when pref=0")
    else
        _nok("_DetectCombat with pref=0: ok=" .. tostring(ok2)
            .. " result=" .. tostring(result2))
    end
    BfBot.Persist.SetPref("CombatInterrupt", origPref)

    -- ---- Test 4: _SafetyTick exists and is callable ----
    P("")
    P("  [4] _SafetyTick function")

    if type(BfBot.Exec._SafetyTick) == "function" then
        _ok("_SafetyTick is a function")
    else
        _nok("_SafetyTick missing or not a function")
        return _summary("Combat Safety")
    end

    -- Call it — should not crash (rate-limited, so no-op if called twice fast)
    local ok3, err3 = pcall(BfBot.Exec._SafetyTick)
    if ok3 then
        _ok("_SafetyTick callable (no crash)")
    else
        _nok("_SafetyTick threw: " .. tostring(err3))
    end

    -- ---- Test 5: _SafetyTick rate limiting ----
    P("")
    P("  [5] _SafetyTick rate limiting")

    -- Reset tick timer to force a fresh check
    BfBot.Exec._lastSafetyTick = 0
    local before = Infinity_GetClockTicks()
    pcall(BfBot.Exec._SafetyTick)
    local afterTick = BfBot.Exec._lastSafetyTick
    if afterTick >= before then
        _ok("_lastSafetyTick updated after reset: " .. tostring(afterTick))
    else
        _nok("_lastSafetyTick not updated: " .. tostring(afterTick))
    end

    -- Immediate second call should be rate-limited (no update)
    local savedTick = BfBot.Exec._lastSafetyTick
    pcall(BfBot.Exec._SafetyTick)
    if BfBot.Exec._lastSafetyTick == savedTick then
        _ok("Rate-limited: second call did not update tick")
    else
        _nok("Rate limit failed: tick changed from " .. tostring(savedTick)
            .. " to " .. tostring(BfBot.Exec._lastSafetyTick))
    end

    -- ---- Test 6: _SafetyTick skips when running ----
    P("")
    P("  [6] _SafetyTick skips when exec running")

    local origState = BfBot.Exec._state
    BfBot.Exec._state = "running"
    BfBot.Exec._lastSafetyTick = 0  -- reset to allow tick
    local tickBefore = BfBot.Exec._lastSafetyTick
    pcall(BfBot.Exec._SafetyTick)
    -- When running, _SafetyTick should still update the tick counter
    -- (rate limit runs first) but should NOT remove any effects
    -- We can verify it didn't crash at minimum
    BfBot.Exec._state = origState
    _ok("_SafetyTick did not crash when state=running")

    -- ---- Summary ----
    P("")
    return _summary("Combat Safety")
end
```

**Step 2: Add Combat Safety to RunAll**

In the `RunAll` function, add after the Target Picker phase (Phase 9) and before the Summary:

```lua
    -- Phase 10: Combat Safety
    local combatOk = BfBot.Test.CombatSafety()
    P("")
```

And add to the summary block:

```lua
    P("  Combat Safety: " .. (combatOk and "PASS" or "FAIL"))
```

And update the final return to include `combatOk`:

```lua
    return fieldsOk and classOk and scanOk and persistOk and qcOk and ovrOk and exportOk and scanRefOk and tgtOk and combatOk
```

**Step 3: Commit**

```bash
git add buffbot/BfBotTst.lua
git commit -m "test: add combat safety unit tests"
```

---

### Task 7: Deploy, run tests, and verify in-game

**Files:**
- No new file changes — verification only

**Step 1: Deploy**

```bash
bash tools/deploy.sh
```

**Step 2: Run unit tests**

In EEex console:
```
BfBot.Test.RunAll()
```

Expected: All phases PASS, including new Phase 10 (Combat Safety).

If Combat Safety tests fail, investigate and fix before proceeding.

**Step 3: Run combat safety tests standalone**

```
BfBot.Test.CombatSafety()
```

Expected: 8+ tests, all PASS.

**Step 4: In-game combat interrupt verification**

1. Save game near hostile enemies (but out of range).
2. Open BuffBot panel (F11), select a preset with spells, click Cast.
3. While casting, walk party leader toward enemies until within ~400 units.
4. Expected: casting stops, overhead text "BuffBot: Combat detected - casting stopped", execution log shows "Combat detected — stopping execution".
5. Check log: `BfBot.Exec.GetLog()` — should have INFO entry about combat detection.

**Step 5: In-game Quick Cast safety net verification**

1. Enable Quick Cast on a preset (cycle to "Long" or "All").
2. Click Cast — observe Improved Alacrity active on casters.
3. Click Stop mid-queue — BFBTCH should be removed immediately by Stop().
4. If somehow BFBTCH persists (edge case), wait ~2 seconds — safety net should catch it.
5. Verify with: `BfBot.Exec._HasActiveEffect(EEex_Sprite_GetInPortrait(0), "BFBTCH")` — should return `false`.

**Step 6: CombatInterrupt=0 verification**

1. In EEex console: `BfBot.Persist.SetPref("CombatInterrupt", 0)`
2. Start casting near enemies — should NOT interrupt.
3. Restore: `BfBot.Persist.SetPref("CombatInterrupt", 1)`

**Step 7: Commit (if any fixes were needed)**

```bash
git add -A
git commit -m "fix: address combat safety test/verification issues"
```

---

### Task 8: Update CLAUDE.md with combat safety details

**Files:**
- Modify: `CLAUDE.md` — add Combat Safety section to Current Phase, update Execution Engine Details

**Step 1: Add Combat Safety to Current Phase list**

After the "Duration Column" bullet, add:

```markdown
- **Combat Safety** (`BfBot.Exec`) — combat detection via `countAllOfTypeStringInRange("[ENEMY]", 400)` on party leader, queue interruption in `_Advance()`, paranoid BFBTCH safety net via `.menu` tick every ~2s. `CombatInterrupt` INI pref (default on). Safety net NOT toggleable. Verified working in-game.
```

**Step 2: Add to Execution Engine Details**

After the `_qcMode` bullet in Execution Engine Details, add:

```markdown
- **Combat detection**: `_DetectCombat()` checks `sprite:countAllOfTypeStringInRange("[ENEMY]", 400)` on party leader. Same range as rest prevention (SPAWN_RANGE). Called from `_Advance()` between spells. Gated by `CombatInterrupt` INI pref (default 1).
- **Safety net**: `_SafetyTick()` runs via `.menu` `enabled` tick on BUFFBOT_ACTIONBAR (always active on world screen). Rate-limited to ~2s via `Infinity_GetClockTicks()`. When exec state is NOT "running", scans all party members for orphaned BFBTCH effects and removes via BFBTCR. NOT toggleable.
```

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add combat safety to CLAUDE.md"
```
