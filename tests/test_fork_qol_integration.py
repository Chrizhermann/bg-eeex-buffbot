"""Behavior at the boundaries between item discovery, execution and shortcuts."""

import pytest
from lupa.luajit21 import LuaRuntime

from test_runtime_compatibility import exec_lua


@pytest.mark.parametrize("quick_mode", [0, 2])
def test_pending_rate_restore_blocks_normal_and_quick_cast_before_new_work(
    exec_lua: LuaRuntime, quick_mode: int,
) -> None:
    exec_lua.globals().quick_mode = quick_mode
    facts = exec_lua.execute(
        """
        BfBot.Exec._state = 'idle'
        local run = {original=30,applied=60,releaseReason='stopped'}
        BfBot.Fast = {run=run}
        local opened, built = 0, 0
        BfBot._OpenLogAppend = function() opened=opened+1 end
        BfBot.Exec._BuildQueue = function() built=built+1;return nil,'empty',{} end
        local queue = {{spell='BUFF',cheat=1}}
        local accepted, reason = BfBot.Exec.Start(queue,quick_mode,1)
        return {accepted=accepted,reason=reason,opened=opened,built=built,
            idle=BfBot.Exec.GetState()=='idle',owner=BfBot.Fast.run==run,
            unchanged=queue[1].spell=='BUFF' and queue[1].cheat==1}
        """
    )
    assert facts["accepted"] is False
    assert facts["reason"] == "reason.exec.fast_unavailable"
    assert facts["opened"] == facts["built"] == 0
    assert facts["idle"] and facts["owner"] and facts["unchanged"]


def test_item_that_becomes_interactive_is_skipped_before_equipping_or_using(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local row = {
            kind='itm', count=2, name='Choose a power', itemResref='CHOICE',
            abilityIdx=1, requiresChoice=0, class={splstates={}},
        }
        local sprites = BfBot_TestQueueWorld({ITEM=row})
        local grouped = assert(BfBot.Exec._BuildQueue({{
            caster=0, spell='ITEM', target='self',
        }}, 2))
        BfBot.Exec._casters.p0 = {
            ref={kind='party', slot=0}, queue=grouped.p0, name='A',
            index=0, done=false, cheatApplied=false,
        }
        BfBot.Exec._activeCasters = 1
        BfBot.Exec._state = 'running'
        BfBot.Exec._ResolveCasterForStep = function() return sprites[1] end
        local queued, itemAttempts = 0, 0
        EEex_Action_QueueResponseStringOnAIBase = function() queued=queued+1 end
        BfBot.Exec._QueueItem = function() itemAttempts=itemAttempts+1 end
        -- A fresh scan may select another child ability after a level change.
        -- The preflight must use that current row, not only the original queue.
        row.requiresChoice = 1
        BfBot.Exec._ProcessCasterEntry('p0',1)
        return {
            queued=queued, itemAttempts=itemAttempts, count=row.count,
            skipped=BfBot.Exec._skipCount, cast=BfBot.Exec._castCount,
            state=BfBot.Exec.GetState(),
        }
        """
    )
    assert facts["queued"] == facts["itemAttempts"] == facts["cast"] == 0
    assert facts["skipped"] == 1
    assert facts["count"] == 2
    assert facts["state"] == "done"


@pytest.mark.parametrize("accelerated", [False, True])
def test_late_join_obeys_native_fast_forward_even_with_own_quick_cast_preset(
    exec_lua: LuaRuntime, accelerated: bool,
) -> None:
    exec_lua.globals().accelerated = accelerated
    facts = exec_lua.execute(
        """
        BfBot_TestQueueWorld({BUFF={count=2,name='Buff',class={splstates={}}}})
        BfBot.Fast = {run=accelerated and {} or nil}
        BfBot.Exec._state='running'
        BfBot.Exec._qcMode=2
        local dispatched
        BfBot.Exec._ProcessCasterEntry=function(key) dispatched=key end
        local attached=BfBot.Exec._AttachCaster({oid=200,name='A'},{{
            casterRef={kind='summon',oid=200,name='A'}, spell='BUFF',
            target='self',cheat=1,rep=2,
        }})
        local caster=BfBot.Exec._casters.s200
        return {
            attached=attached,dispatched=dispatched,
            first=caster.queue[1].cheat,second=caster.queue[2].cheat,
            boundary=caster.cheatBoundary,count=#caster.queue,
        }
        """
    )
    assert facts["attached"]
    assert facts["dispatched"] == "s200"
    assert facts["count"] == 2
    assert facts["first"] is not accelerated
    assert facts["second"] is not accelerated
    assert facts["boundary"] == (0 if accelerated else 2)


@pytest.mark.parametrize("exit_method, expected_state, expected_reason", [
    ("Stop", "stopped", "stopped"),
    ("_HardReset", "idle", "execution reset"),
    ("_ForceComplete", "done", "execution timeout"),
    ("_Complete", "done", "complete"),
])
def test_executor_exit_restores_speed_and_recovery_runs_at_original_rate(
    exec_lua: LuaRuntime, exit_method: str, expected_state: str,
    expected_reason: str,
) -> None:
    exec_lua.globals().exit_method = exit_method
    facts = exec_lua.execute(
        """
        local rate, restoredReason, completionState = 60,nil,nil
        local recoveryRates={}
        BfBot.Fast={run={}}
        BfBot.Fast.Reset=function(reason)
            if BfBot.Fast.run then
                rate,restoredReason=30,reason
                BfBot.Fast.run=nil
            end
        end
        BfBot.Fast.CheckDone=function()
            completionState=BfBot.Exec.GetState()
            if completionState~='running' then BfBot.Fast.Reset('complete') end
        end
        BfBot.Exec._RecoverItemSwaps=function()
            recoveryRates[#recoveryRates+1]=rate
        end
        BfBot.Exec._state='running'
        BfBot.Exec[exit_method]('watchdog')
        return {
            state=BfBot.Exec.GetState(),rate=rate,reason=restoredReason,
            released=BfBot.Fast.run==nil,completionState=completionState,
            recoveryCount=#recoveryRates,recoveryRate=recoveryRates[1],
        }
        """
    )
    assert facts["state"] == expected_state
    assert facts["rate"] == 30
    assert facts["reason"] == expected_reason
    assert facts["released"]
    if exit_method in ("Stop", "_ForceComplete"):
        assert facts["recoveryCount"] == 1
        assert facts["recoveryRate"] == 30
    if exit_method == "_Complete":
        assert facts["completionState"] == "done"


def test_stale_completion_uses_hard_reset_and_releases_acceleration(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local reason
        BfBot.Fast={run={},Reset=function(value) reason=value;BfBot.Fast.run=nil end}
        BfBot.Exec._state='running'
        BfBot.Exec._casters.p0={ref={kind='party',slot=0},name='Former companion'}
        EEex_Sprite_GetInPortrait=function() return nil end
        BfBot.Exec._Complete()
        return {state=BfBot.Exec.GetState(),reason=reason,released=BfBot.Fast.run==nil}
        """
    )
    assert facts["state"] == "idle"
    assert facts["reason"] == "execution reset"
    assert facts["released"]
