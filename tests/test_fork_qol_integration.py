"""Behavior at the boundaries between item discovery, execution and shortcuts."""

import pytest
from lupa.luajit21 import LuaRuntime

from test_innate_recharge import innate_lua
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


@pytest.mark.parametrize("speed", [0, 2, 4])
@pytest.mark.parametrize("quick_cast", [0, 1, 2])
def test_f12_uses_global_speed_or_preserves_its_original_quick_cast_mode(
    innate_lua: LuaRuntime, speed: int, quick_cast: int,
) -> None:
    innate_lua.globals().speed = speed
    innate_lua.globals().quick_cast = quick_cast
    facts = innate_lua.execute(
        """
        local queue={{tag='first'},{tag='second'}}
        local sprite={}
        local path,mode,preset,received,drains,displays=nil,nil,nil,nil,0,0
        EEex_Sprite_GetInPortrait=function(slot) if slot==0 then return sprite end end
        BfBot._Display=function() displays=displays+1 end
        BfBot.Exec={
            GetState=function() return 'idle' end,
            Start=function(q,m,p) path,received,mode,preset='normal',q,m,p end,
        }
        BfBot.Fast={Start=function(q,m,p)
            path,received,mode,preset='fast',q,m,p
            return true
        end}
        BfBot.Persist={
            BuildQueueForCharacter=function(slot,index)
                assert(slot==0 and index==2)
                return queue
            end,
            DrainBuildSkips=function() drains=drains+1 end,
            GetQuickCast=function(who,index)
                assert(who==sprite and index==2)
                return quick_cast
            end,
            GetPref=function(name) assert(name=='FastForward');return speed end,
        }
        BFBOTGO({m_effectAmount=0,m_dWFlags=2},nil,nil)
        return {path=path,mode=mode,preset=preset,sameQueue=received==queue,
            drains=drains,displays=displays}
        """
    )
    assert facts["path"] == ("fast" if speed else "normal")
    assert facts["mode"] == (speed if speed else quick_cast)
    assert facts["preset"] == 2
    assert facts["sameQueue"]
    assert facts["drains"] == 1
    assert facts["displays"] == 0


def test_f12_refused_fast_forward_reports_failure_without_quick_cast_fallback(
    innate_lua: LuaRuntime,
) -> None:
    facts = innate_lua.execute(
        """
        local normalStarts,fastStarts,displays=0,0,{}
        EEex_Sprite_GetInPortrait=function() return {} end
        BfBot._Display=function(message) displays[#displays+1]=message end
        BfBot.Exec={
            GetState=function() return 'idle' end,
            Start=function() normalStarts=normalStarts+1 end,
        }
        BfBot.Fast={Start=function()
            fastStarts=fastStarts+1
            return false,'reason.exec.empty_queue',{}
        end}
        BfBot.Persist={
            BuildQueueForCharacter=function() return {{spell='BUFF'}} end,
            GetQuickCast=function() return 2 end,
            GetPref=function() return 4 end,
        }
        BFBOTGO({m_effectAmount=0,m_dWFlags=1},nil,nil)
        return {normal=normalStarts,fast=fastStarts,displayCount=#displays}
        """
    )
    assert facts["normal"] == 0
    assert facts["fast"] == 1
    assert facts["displayCount"] == 1
