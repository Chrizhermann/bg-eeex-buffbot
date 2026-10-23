"""Behavioral tests for temporary native-speed casting; no engine timing claims."""
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


SOURCE = (Path(__file__).resolve().parents[1] / "buffbot/BfBotFst.lua").read_text(encoding="utf-8")


@pytest.fixture
def lua():
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("""
        bit = require('bit')
        wall = 1000
        state = 'idle'
        stopped = 0
        callbacks = {}
        warnings = {}
        menus = {}
        worldScreen = {}
        e = { GetActiveEngine = function() return worldScreen end }
        EEex_CChitin = { TIMER_UPDATES_PER_SECOND = 30 }
        EEex = { UncapFPS_FPSLimit = 144, UncapFPS_FPSLimitEnabled = true }
        EngineGlobals = { g_pBaldurChitin = {
            cNetwork = { m_bConnectionEstablished = 0 },
            m_pObjectGame = {
                m_gameSave = { m_inputMode = 1 },
                m_worldTime = { m_gameTime = 500 },
            },
        } }
        BfBot = {
            Exec = {
                GetState = function() return state end,
                _IsAlive = function(s) return s.alive end,
                Start = function(queue, quick, preset)
                    state = 'running'
                    startedQueue, startedQuick, startedPreset = queue, quick, preset
                    return true
                end,
                Stop = function()
                    stopped = stopped + 1
                    state = 'idle'
                    BfBot.Fast.Reset('stopped')
                end,
            },
            Persist = { GetPref = function() return 0 end },
            _Warn = function(text) table.insert(warnings, text) end,
        }
        party = {
            { alive = true, enemies = 0, combat = false },
            { alive = true, enemies = 0, combat = 0 },
        }
        for _, s in ipairs(party) do
            s.countAllOfTypeStringInRange = function(self, kind, range)
                assert(kind == '[ENEMY]' and range == 400)
                return self.enemies
            end
        end
        EEex_Sprite_GetInPortrait = function(slot) return party[slot + 1] end
        EEex_Trigger_EvalConditionalStringAsAIBase = function(trigger, sprite)
            assert(trigger == 'CombatCounterGT(0)')
            return sprite.combat
        end
        Infinity_GetClockTicks = function() return wall end
        Infinity_IsMenuOnStack = function(menu) return menus[menu] or 0 end
        EEex_GameState_AddDestroyedListener = function(fn) table.insert(callbacks, fn) end
        queue = { { spell = 'A', cheat = 1 }, { spell = 'B', cheat = true } }
    """)
    runtime.execute(SOURCE)
    return runtime


@pytest.mark.parametrize("multiplier", [2, 4])
def test_native_queue_preserves_order_and_original_without_quick_cast(lua, multiplier):
    lua.execute(f"assert(BfBot.Fast.Start(queue, {multiplier}, 3))")
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 30 * multiplier
    assert lua.eval("startedQuick") == 0
    assert lua.eval("startedPreset") == 3
    assert lua.eval("startedQueue[1].spell .. startedQueue[2].spell") == "AB"
    assert lua.eval("startedQueue[1].cheat == 0 and startedQueue[2].cheat == 0")
    assert lua.eval("queue[1].cheat == 1 and queue[2].cheat == true")
    assert lua.eval("EEex.UncapFPS_FPSLimit") == 144
    lua.execute("state = 'idle'; wall = 9000; EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_worldTime.m_gameTime = 620; BfBot.Fast.Tick()")
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 30
    assert lua.eval("BfBot.Fast.lastAudit.gameTicks") == 120
    assert lua.eval("BfBot.Fast.lastAudit.restored")
    assert lua.eval("BfBot.Fast.run == nil")


@pytest.mark.parametrize("prepare,reason", [
    ("party[2].enemies = 1", "combat"),
    ("party[2].combat = 1", "combat"),
    ("menus.WORLD_DIALOG = 1", "menu"),
    ("EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_gameSave.m_inputMode = 0", "dialogue or cutscene"),
    ("sidebarsGreyed = 1", "dialogue or cutscene"),
    ("e.GetActiveEngine = function() return {} end", "outside world"),
    ("EngineGlobals.g_pBaldurChitin.cNetwork.m_bConnectionEstablished = 1", "multiplayer"),
])
def test_abort_restores_before_stop_even_with_combat_preference_off(lua, prepare, reason):
    lua.execute("assert(BfBot.Fast.Start(queue, 2)); observedRate = nil; BfBot.Exec.Stop = function() observedRate = EEex_CChitin.TIMER_UPDATES_PER_SECOND; stopped = stopped + 1; state = 'idle' end")
    lua.execute(prepare + "; BfBot.Fast.Tick()")
    assert lua.eval("observedRate") == 30
    assert lua.eval("stopped") == 1
    assert lua.eval("BfBot.Fast.lastAudit.reason") == reason


@pytest.mark.parametrize("prepare", [
    "EngineGlobals = nil",
    "EngineGlobals.g_pBaldurChitin.cNetwork.m_bConnectionEstablished = nil",
    "party[1].enemies = nil",
    "party[1].combat = nil",
    "EEex_CChitin = nil",
    "EEex_GameState_AddDestroyedListener = nil",
    "EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_worldTime.m_gameTime = nil",
    "Infinity_IsMenuOnStack = nil",
])
def test_uninspectable_engine_cannot_start(lua, prepare):
    lua.execute(prepare)
    accepted, code, _ = lua.eval("BfBot.Fast.Start(queue, 2)")
    assert accepted is False
    assert code == "reason.exec.fast_unavailable"
    assert lua.eval("BfBot.Fast.run == nil and state == 'idle'")


def test_numeric_zero_flags_are_safe(lua):
    lua.execute("sidebarsGreyed = 0; party[1].combat = 0; assert(BfBot.Fast.Start(queue, 2))")
    assert lua.eval("state") == "running"


@pytest.mark.parametrize("popup_value", ["true", "1", "nil"])
def test_generic_modal_or_unknown_modal_state_cannot_start(lua, popup_value):
    lua.execute(f"EngineGlobals.popupActive = function() return {popup_value} end")
    accepted, code, _ = lua.eval("BfBot.Fast.Start(queue, 2)")
    assert accepted is False
    assert code == "reason.exec.fast_unavailable"
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 30


@pytest.mark.parametrize("popup_value", ["false", "0"])
def test_generic_modal_guard_accepts_both_engine_boolean_forms(lua, popup_value):
    lua.execute(f"""
        EngineGlobals.popupActive = function() return {popup_value} end
        assert(BfBot.Fast.Start(queue, 2))
        EngineGlobals.popupActive = function() return 1 end
        BfBot.Fast.Tick()
    """)
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 30
    assert lua.eval("stopped") == 1


def test_original_nonstandard_rate_is_restored(lua):
    lua.execute("EEex_CChitin.TIMER_UPDATES_PER_SECOND = 20; assert(BfBot.Fast.Start(queue, 4)); BfBot.Fast.Reset('stopped')")
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 20


def test_external_speed_change_is_never_overwritten(lua):
    lua.execute("assert(BfBot.Fast.Start(queue, 2)); EEex_CChitin.TIMER_UPDATES_PER_SECOND = 45; BfBot.Fast.Tick()")
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 45
    assert lua.eval("stopped") == 1
    assert lua.eval("BfBot.Fast.lastAudit.restored") is False


def test_wall_clock_reset_releases_rate(lua):
    lua.execute("assert(BfBot.Fast.Start(queue, 2)); wall = wall - 1; BfBot.Fast.Tick()")
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 30
    assert lua.eval("BfBot.Fast.lastAudit.reason") == "clock reset"
    assert lua.eval("stopped") == 1


@pytest.mark.parametrize("game_progress", [0, 7200])
def test_elapsed_wall_time_alone_cannot_stop_paused_or_healthy_runs(lua, game_progress):
    lua.execute(f"""
        assert(BfBot.Fast.Start(queue, 2))
        wall = wall + 180000
        EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_worldTime.m_gameTime = 500 + {game_progress}
        BfBot.Fast.Tick()
    """)
    assert lua.eval("state") == "running"
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 60
    assert lua.eval("stopped") == 0


def test_failed_restore_retains_ownership_and_retries(lua):
    lua.execute("""
        assert(BfBot.Fast.Start(queue, 2))
        heldRate = 60
        failRestore = true
        EEex_CChitin = setmetatable({}, {
            __index = function() return heldRate end,
            __newindex = function(_, _, value)
                if failRestore then error('write blocked') end
                heldRate = value
            end,
        })
        assert(BfBot.Fast.Reset('stopped') == false)
        assert(BfBot.Fast.run ~= nil)
        local accepted, code = BfBot.Fast.Start(queue, 2)
        assert(not accepted and code == 'reason.exec.already_running')
        failRestore = false
        state = 'idle'
        BfBot.Fast.Tick()
    """)
    assert lua.eval("heldRate") == 30
    assert lua.eval("BfBot.Fast.run == nil")


def test_failed_read_retains_ownership(lua):
    lua.execute("""
        assert(BfBot.Fast.Start(queue, 2))
        savedTimer = EEex_CChitin
        EEex_CChitin = nil
        assert(BfBot.Fast.Reset('stopped') == false)
        assert(BfBot.Fast.run ~= nil)
        EEex_CChitin = savedTimer
        BfBot.Fast.Tick()
    """)
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 30


@pytest.mark.parametrize("setter_failure", ["clamp", "write_then_throw"])
def test_failed_start_rolls_back_its_own_partial_rate_write(lua, setter_failure):
    lua.globals().setter_failure = setter_failure
    lua.execute("""
        heldRate = 30
        EEex_CChitin = setmetatable({}, {
            __index = function() return heldRate end,
            __newindex = function(_, _, value)
                heldRate = math.min(value, 90)
                if value == 120 and setter_failure == 'write_then_throw' then
                    error('setter failed after mutation')
                end
            end,
        })
    """)
    accepted, reason, _ = lua.eval("BfBot.Fast.Start(queue, 4)")
    assert accepted is False
    assert reason == "reason.exec.fast_unavailable"
    assert lua.eval("heldRate") == 30
    assert lua.eval("state") == "idle"
    assert lua.eval("BfBot.Fast.run == nil")


def test_failed_start_retains_partial_write_until_rollback_succeeds(lua):
    lua.execute("""
        heldRate = 30
        blockRestore = true
        EEex_CChitin = setmetatable({}, {
            __index = function() return heldRate end,
            __newindex = function(_, _, value)
                if value == 30 and blockRestore then error('restore unavailable') end
                heldRate = math.min(value, 90)
            end,
        })
        assert(not BfBot.Fast.Start(queue, 4))
        assert(heldRate == 90 and BfBot.Fast.run.applied == 90)
        assert(BfBot.Fast.run.original == 30)
        assert(not BfBot.Fast.Start(queue, 2))
        blockRestore = false
        BfBot.Fast.Tick()
    """)
    assert lua.eval("heldRate") == 30
    assert lua.eval("BfBot.Fast.run == nil")


def test_lifecycle_release_recovers_two_transient_failures(lua):
    lua.execute("""
        assert(BfBot.Fast.Start(queue, 2))
        heldRate = 60
        writes = 0
        EEex_CChitin = setmetatable({}, {
            __index = function() return heldRate end,
            __newindex = function(_, _, value)
                writes = writes + 1
                if writes <= 2 then error('transient write failure') end
                heldRate = value
            end,
        })
        callbacks[1]()
    """)
    assert lua.eval("writes") == 3
    assert lua.eval("heldRate") == 30
    assert lua.eval("BfBot.Fast.run == nil")
    assert lua.eval("BfBot.Fast.lastAudit.reason") == "load or exit"
    assert lua.eval("BfBot.Fast.lastAudit.restored") is True


def test_lifecycle_release_bounds_failure_and_future_tick_retries(lua):
    lua.execute("""
        assert(BfBot.Fast.Start(queue, 4))
        heldRate = 120
        writes = 0
        blocked = true
        EEex_CChitin = setmetatable({}, {
            __index = function() return heldRate end,
            __newindex = function(_, _, value)
                writes = writes + 1
                if blocked then error('binding unavailable') end
                heldRate = value
            end,
        })
        assert(BfBot.Fast.Release('world controls hidden') == false)
        assert(writes == 3)
        assert(BfBot.Fast.run.releaseAttempts == 3)
        assert(BfBot.Fast.run.releaseFailed == true)
        assert(BfBot.Fast.run.original == 30 and BfBot.Fast.run.applied == 120)
        assert(BfBot.Fast.lastAudit == nil)
        blocked = false
        BfBot.Fast.Tick()
    """)
    assert lua.eval("writes") == 4
    assert lua.eval("heldRate") == 30
    assert lua.eval("BfBot.Fast.run == nil")
    assert lua.eval("BfBot.Fast.lastAudit.reason") == "world controls hidden"


def test_lifecycle_release_does_not_retry_external_owner(lua):
    lua.execute("""
        assert(BfBot.Fast.Start(queue, 2))
        EEex_CChitin.TIMER_UPDATES_PER_SECOND = 45
        assert(BfBot.Fast.Release('world controls hidden'))
    """)
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 45
    assert lua.eval("BfBot.Fast.run == nil")
    assert lua.eval("BfBot.Fast.lastAudit.restored") is False


def test_failed_native_start_restores_and_clears_partial_run(lua):
    lua.execute("BfBot.Exec.Start = function() state = 'running'; error('native failure') end")
    accepted, code, _ = lua.eval("BfBot.Fast.Start(queue, 2)")
    assert accepted is False
    assert code == "reason.exec.fast_unavailable"
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 30
    assert lua.eval("state") == "idle"


def test_rejected_native_start_preserves_its_reason(lua):
    lua.execute("BfBot.Exec.Start = function() return false, 'reason.exec.empty_queue', {} end")
    accepted, code, _ = lua.eval("BfBot.Fast.Start(queue, 2)")
    assert accepted is False
    assert code == "reason.exec.empty_queue"
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 30


def test_destroyed_listener_restores_once_and_survives_module_reload(lua):
    lua.execute("assert(BfBot.Fast.Start(queue, 2)); BfBot.Fast.Init()")
    lua.execute(SOURCE)
    lua.execute("BfBot.Fast.Init(); callbacks[1]()")
    assert lua.eval("#callbacks") == 1
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 30
    assert lua.eval("BfBot.Fast.lastAudit.reason") == "load or exit"


def test_guard_is_throttled_but_completion_is_not(lua):
    lua.execute("""
        assert(BfBot.Fast.Start(queue, 2))
        calls = 0
        BfBot.Fast.Safe = function() calls = calls + 1; return true end
        BfBot.Fast.Tick()
        wall = wall + 10
        BfBot.Fast.Tick()
        state = 'idle'
        BfBot.Fast.Tick()
    """)
    assert lua.eval("calls") == 1
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 30


@pytest.mark.parametrize("rate,multiplier", [(40, 4), (0, 2), (30, 1), (30, 3), (30.5, 2)])
def test_invalid_rate_or_multiplier_does_not_mutate(lua, rate, multiplier):
    lua.execute(f"EEex_CChitin.TIMER_UPDATES_PER_SECOND = {rate}")
    accepted, code, _ = lua.eval(f"BfBot.Fast.Start(queue, {multiplier})")
    assert accepted is False
    assert code == "reason.exec.fast_unavailable"
    assert lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == rate
