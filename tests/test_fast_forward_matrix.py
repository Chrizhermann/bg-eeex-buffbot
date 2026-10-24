"""Cross-module execution matrix; native action completion is simulated, not timed.

Fast, Exec queue building, preflight, active-effect detection, item dispatch and
chain callbacks are real Lua. Only the native engine boundary and scan inventory
are synthetic. These tests cannot establish actual game-clock speed or fairness.
"""

from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime

from test_runtime_compatibility import EXEC_SOURCE, exec_lua


FAST_SOURCE = (Path(__file__).resolve().parents[1] / "buffbot/BfBotFst.lua").read_text(
    encoding="utf-8"
)


@pytest.fixture
def matrix_lua(exec_lua: LuaRuntime) -> LuaRuntime:
    exec_lua.execute("""
        bit = require('bit')
        EEex_BAnd = bit.band
        wall = 1000
        menus, lifecycle, commands, pending, debits = {}, {}, {}, {}, {}
        prefs = {CombatInterrupt=0, ItemUseMode='direct', FastForward=1}
        BfBot.Persist.GetPref = function(key) return prefs[key] end
        BfBot.Persist.GetItemSwap = function() return nil end
        worldScreen = {}
        e = {GetActiveEngine=function() return worldScreen end}
        EEex_CChitin = {TIMER_UPDATES_PER_SECOND=30}
        EngineGlobals = {g_pBaldurChitin={
            cNetwork={m_bConnectionEstablished=0},
            m_pObjectGame={m_gameSave={m_inputMode=1},m_worldTime={m_gameTime=500}},
        }}
        Infinity_GetClockTicks = function() return wall end
        Infinity_IsMenuOnStack = function(menu) return menus[menu] or 0 end
        EEex_GameState_AddDestroyedListener = function(fn)
            lifecycle[#lifecycle+1]=fn
        end
        EEex_Trigger_EvalConditionalStringAsAIBase = function(_,sprite)
            return sprite.combat
        end
        EEex_Utility_IterateCPtrList = function(effects,fn)
            for _, effect in ipairs(effects) do if fn(effect) then break end end
        end
        party = {}
        for slot=0,1 do
            local sprite = {name='Caster'..slot,m_id=100+slot,
                m_baseStats={m_generalState=0},m_timedEffectList={},
                enemies=0,combat=0,slot=slot,book={}}
            sprite.countAllOfTypeStringInRange = function(self) return self.enemies end
            sprite.getSpellState = function() return false end
            for _,ref in ipairs({'SHORT','LONG','ITEM'}) do
                sprite.book[ref]={name=ref,count=2,kind=ref=='ITEM' and 'itm' or 'spl',
                    class={splstates={}},itemSlot=5,abilityIdx=0,itemResref='ITEM'}
            end
            party[slot+1]=sprite
            commands[slot+1],pending[slot+1],debits[slot+1]={},{},{}
        end
        EEex_Sprite_GetInPortrait = function(slot) return party[slot+1] end
        EEex_Sprite_GetCharacterIndex = function(sprite) return sprite.slot end
        BfBot.Scan.GetCastableSpells = function(sprite) return sprite.book end
        BfBot.Scan.Invalidate = function() end
        EEex_Action_QueueResponseStringOnAIBase = function(action,sprite)
            local index=sprite.slot+1
            table.insert(commands[index],action)
            table.insert(pending[index],action)
        end
        function addActive(sprite,ref)
            table.insert(sprite.m_timedEffectList,{m_sourceRes={get=function() return ref end}})
        end
        function makeQueue()
            local queue={}
            -- Deliberately short before long: speed must not impose duration sorting.
            for slot=0,1 do
                for _,ref in ipairs({'SHORT','ITEM','LONG'}) do
                    queue[#queue+1]={caster=slot,spell=ref,target='self',
                        durCat=ref=='LONG' and 'long' or 'short',rep=1}
                end
            end
            return queue
        end
        function startAt(speed,qc,queue)
            queue=queue or makeQueue()
            if speed==1 then return BfBot.Exec.Start(queue,qc,3) end
            return BfBot.Fast.Start(queue,speed,3)
        end
        function drainOne(slot)
            local index=slot+1
            local action=table.remove(pending[index],1)
            if not action then return false end
            local ref=action:match('^SpellRES%("([^"]+)"')
            if action:match('^UseItemSlotAbility%(') then ref='ITEM' end
            if ref then
                local row=assert(party[index].book[ref])
                assert(row.count>0,'engine debit would underflow')
                row.count=row.count-1
                debits[index][ref]=(debits[index][ref] or 0)+1
                addActive(party[index],ref:lower())
            end
            local callback=action:match('^EEex_LuaAction%("(.*)"%)$')
            if callback then assert(loadstring(callback))() end
            return true
        end
        function drainAll()
            for iteration=1,100 do
                local a,b=drainOne(0),drainOne(1)
                if not a and not b then return end
            end
            error('action queue did not settle')
        end
        function signature(slot,helpers)
            local result={}
            for _,action in ipairs(commands[slot+1]) do
                if not action:find('EEex_LuaAction',1,true)
                    and (helpers or not action:find('BFBTC',1,true)) then
                    result[#result+1]=action
                end
            end
            return table.concat(result,';')
        end
    """)
    exec_lua.execute(FAST_SOURCE)
    return exec_lua


@pytest.mark.parametrize("speed", [1, 2, 4])
@pytest.mark.parametrize("quick_cast", [0, 1, 2])
@pytest.mark.parametrize("baseline", [20, 30])
@pytest.mark.parametrize("already_active", [False, True])
def test_two_casters_mixed_spells_items_preserve_order_debits_and_active_skips(
    matrix_lua: LuaRuntime, speed: int, quick_cast: int, baseline: int,
    already_active: bool,
) -> None:
    lua = matrix_lua
    lua.globals().baseline = baseline
    lua.globals().speed = speed
    lua.globals().quick_cast = quick_cast
    lua.globals().already_active = already_active
    facts = lua.execute("""
        EEex_CChitin.TIMER_UPDATES_PER_SECOND=baseline
        -- Preset/config data is a separate object and must remain unchanged.
        savedPreset={qc=quick_cast}
        original=makeQueue()
        if already_active then addActive(party[2],'sHoRt') end
        assert(startAt(speed,savedPreset.qc,original))
        local during=EEex_CChitin.TIMER_UPDATES_PER_SECOND
        local mode=BfBot.Exec._qcMode
        local bothStarted=#commands[1]>0 and #commands[2]>0
        drainAll()
        local noHelper=true
        for slot=0,1 do
            if signature(slot,true):find('BFBTCH',1,true) then noHelper=false end
        end
        return {state=BfBot.Exec.GetState(),during=during,
            rate=EEex_CChitin.TIMER_UPDATES_PER_SECOND,mode=mode,
            released=BfBot.Fast.run==nil,bothStarted=bothStarted,noHelper=noHelper,
            first=signature(0),second=signature(1),qc=savedPreset.qc,
            cast=BfBot.Exec._castCount,skip=BfBot.Exec._skipCount,
            firstShort=party[1].book.SHORT.count,secondShort=party[2].book.SHORT.count,
            firstLong=party[1].book.LONG.count,secondLong=party[2].book.LONG.count,
            firstItem=party[1].book.ITEM.count,secondItem=party[2].book.ITEM.count,
            untouched=original[1].spell=='SHORT' and original[1].cheat==nil
                and original[2].spell=='ITEM' and original[3].spell=='LONG',
        }
    """)
    expected = 'SpellRES("SHORT",Myself);UseItemSlotAbility(Myself,5,0);SpellRES("LONG",Myself)'
    assert facts["state"] == "done"
    assert facts["during"] == baseline * speed
    assert facts["rate"] == baseline
    assert facts["mode"] == (quick_cast if speed == 1 else 0)
    assert facts["released"] and facts["bothStarted"] and facts["untouched"]
    assert facts["qc"] == quick_cast
    assert facts["noHelper"] is (speed != 1 or quick_cast == 0)
    assert facts["first"] == expected
    assert facts["second"] == (expected.split(";", 1)[1] if already_active else expected)
    assert facts["cast"] == (5 if already_active else 6)
    assert facts["skip"] == (1 if already_active else 0)
    assert facts["firstShort"] == facts["firstLong"] == facts["secondLong"] == 1
    assert facts["firstItem"] == facts["secondItem"] == 1
    assert facts["secondShort"] == (2 if already_active else 1)


@pytest.mark.parametrize("speed", [2, 4])
@pytest.mark.parametrize("exit_kind,expected_reason", [
    ("manual", "stopped"),
    ("enemy", "combat"),
    ("combat_counter", "combat"),
    ("dialogue", "menu"),
    ("world_exit", "outside world"),
    ("load", "load or exit"),
    ("watchdog", "execution timeout"),
])
def test_partial_multi_caster_run_releases_rate_without_dispatching_more_entries(
    matrix_lua: LuaRuntime, speed: int, exit_kind: str, expected_reason: str,
) -> None:
    lua = matrix_lua
    lua.globals().speed = speed
    lua.globals().exit_kind = exit_kind
    facts = lua.execute("""
        assert(startAt(speed,2))
        -- Finish first spell on both sprites; leave their callbacks queued.
        assert(drainOne(0) and drainOne(1))
        if exit_kind=='manual' then BfBot.Exec.Stop()
        elseif exit_kind=='enemy' then party[2].enemies=1;BfBot.Fast.Tick()
        elseif exit_kind=='combat_counter' then party[2].combat=1;BfBot.Fast.Tick()
        elseif exit_kind=='dialogue' then menus.WORLD_DIALOG=1;BfBot.Fast.Tick()
        elseif exit_kind=='world_exit' then e.GetActiveEngine=function() return {} end;BfBot.Fast.Tick()
        elseif exit_kind=='load' then
            lifecycle[1]()
            -- Destruction discards engine queues; the host resets execution separately.
            pending={{},{}}
            BfBot.Exec._HardReset()
        elseif exit_kind=='watchdog' then BfBot.Exec._ForceComplete('test watchdog')
        end
        drainAll()
        return {rate=EEex_CChitin.TIMER_UPDATES_PER_SECOND,
            released=BfBot.Fast.run==nil,reason=BfBot.Fast.lastAudit.reason,
            first=signature(0),second=signature(1),
            firstItem=party[1].book.ITEM.count,secondLong=party[2].book.LONG.count}
    """)
    assert facts["released"] and facts["rate"] == 30
    assert facts["reason"] == expected_reason
    assert facts["first"] == facts["second"] == 'SpellRES("SHORT",Myself)'
    assert facts["firstItem"] == facts["secondLong"] == 2


@pytest.mark.parametrize("speed", [2, 4])
@pytest.mark.parametrize("entry_cheat", [0, 1, True])
def test_precomputed_entry_cheat_never_survives_accelerated_queue(
    matrix_lua: LuaRuntime, speed: int, entry_cheat: int | bool,
) -> None:
    lua = matrix_lua
    lua.globals().speed = speed
    lua.globals().entry_cheat = entry_cheat
    facts = lua.execute("""
        local queue=makeQueue()
        for _,entry in ipairs(queue) do entry.cheat=entry_cheat end
        assert(startAt(speed,2,queue))
        drainAll()
        return {unchanged=queue[1].cheat==entry_cheat,
            helper=signature(0,true):find('BFBTCH',1,true)~=nil,
            rate=EEex_CChitin.TIMER_UPDATES_PER_SECOND,state=BfBot.Exec.GetState()}
    """)
    assert facts["unchanged"] and not facts["helper"]
    assert facts["rate"] == 30 and facts["state"] == "done"


@pytest.mark.parametrize("speed", [2, 4])
@pytest.mark.parametrize("failure", ["missing_spell", "dispatch_exception"])
def test_real_executor_start_failure_releases_rate(
    matrix_lua: LuaRuntime, speed: int, failure: str,
) -> None:
    lua = matrix_lua
    lua.globals().speed = speed
    lua.globals().failure = failure
    facts = lua.execute("""
        local queue=makeQueue()
        if failure=='missing_spell' then
            for _,entry in ipairs(queue) do entry.spell='MISSING' end
        else
            EEex_Action_QueueResponseStringOnAIBase=function() error('injected native failure') end
        end
        local accepted,reason=startAt(speed,2,queue)
        return {accepted=accepted,reason=reason,
            rate=EEex_CChitin.TIMER_UPDATES_PER_SECOND,released=BfBot.Fast.run==nil,
            running=BfBot.Exec.GetState()=='running'}
    """)
    assert facts["accepted"] is False
    assert facts["reason"] == (
        "reason.exec.no_valid_entries" if failure == "missing_spell"
        else "reason.exec.fast_unavailable"
    )
    assert facts["rate"] == 30 and facts["released"] and not facts["running"]


@pytest.mark.parametrize("speed", [2, 4])
@pytest.mark.parametrize("pause_ms", [30000, 120000, 600000])
def test_pause_freezes_game_progress_and_resumes_without_arbitrary_timeout(
    matrix_lua: LuaRuntime, speed: int, pause_ms: int,
) -> None:
    lua = matrix_lua
    lua.globals().speed = speed
    lua.globals().pause_ms = pause_ms
    facts = lua.execute("""
        assert(startAt(speed,2))
        local initialTick=EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_worldTime.m_gameTime
        -- While paused, the engine executes no native actions and game time
        -- stays still; the world UI's wall-clock guard continues to run.
        wall=wall+pause_ms
        BfBot.Fast.Tick()
        local pausedState=BfBot.Exec.GetState()
        local pausedRate=EEex_CChitin.TIMER_UPDATES_PER_SECOND
        local frozen=EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_worldTime.m_gameTime==initialTick
        drainAll()
        return {pausedState=pausedState,pausedRate=pausedRate,frozen=frozen,
            rate=EEex_CChitin.TIMER_UPDATES_PER_SECOND,state=BfBot.Exec.GetState(),
            reason=BfBot.Fast.lastAudit.reason,wall=BfBot.Fast.lastAudit.wallMs,
            firstItem=party[1].book.ITEM.count}
    """)
    assert facts["frozen"]
    assert facts["rate"] == 30
    assert facts["wall"] == pause_ms
    assert facts["pausedState"] == "running"
    assert facts["pausedRate"] == 30 * speed
    assert facts["state"] == "done" and facts["reason"] == "complete"
    assert facts["firstItem"] == 1


@pytest.mark.parametrize("reload_module", [False, True])
@pytest.mark.parametrize("first_speed,next_speed", [(1, 1), (2, 4), (4, 1)])
def test_stopped_run_callback_cannot_advance_new_run(
    matrix_lua: LuaRuntime, first_speed: int, next_speed: int, reload_module: bool,
) -> None:
    lua = matrix_lua
    lua.globals().first_speed = first_speed
    lua.globals().next_speed = next_speed
    lua.globals().reload_source = EXEC_SOURCE if reload_module else None
    facts = lua.execute("""
        assert(startAt(first_speed,0))
        -- The cast completed; its advance callback has not yet run.
        assert(drainOne(0) and drainOne(1))
        BfBot.Exec.Stop()
        if reload_source then assert(loadstring(reload_source))() end
        assert(startAt(next_speed,0))
        local before=BfBot.Exec._casters.p0.index
        local commandsBefore=#commands[1]
        assert(drainOne(0))
        local after=BfBot.Exec._casters.p0.index
        local commandsAfter=#commands[1]
        drainAll()
        return {before=before,after=after,commandsBefore=commandsBefore,
            commandsAfter=commandsAfter,state=BfBot.Exec.GetState(),
            rate=EEex_CChitin.TIMER_UPDATES_PER_SECOND}
    """)
    assert facts["after"] == facts["before"]
    assert facts["commandsAfter"] == facts["commandsBefore"]
    assert facts["state"] == "done" and facts["rate"] == 30


@pytest.mark.parametrize("summon", [False, True])
def test_duplicate_or_missing_advance_token_cannot_skip_a_step(
    matrix_lua: LuaRuntime, summon: bool,
) -> None:
    lua = matrix_lua
    lua.globals().summon = summon
    facts = lua.execute("""
        local key,queue='p0',makeQueue()
        if summon then
            local sprite={name='Summon',slot=2,m_id=77,m_typeAI={m_EnemyAlly=4},
                book=party[1].book,m_baseStats={m_generalState=0},m_timedEffectList={}}
            commands[3],pending[3],debits[3]={},{},{}
            EEex_GameObject_Get=function(oid) if oid==77 then return sprite end end
            EEex_GameObject_IsSprite=function() return true end
            EEex_GameObject_CastUserType=function(value) return value end
            key='s77'
            queue={{casterRef={kind='summon',oid=77,name='Summon'},spell='SHORT',target='self'},
                {casterRef={kind='summon',oid=77,name='Summon'},spell='LONG',target='self'}}
        end
        assert(startAt(4,0,queue))
        local token=BfBot.Exec._casters[key].advanceToken
        BfBot.Exec._Advance(key,token)
        local caster=BfBot.Exec._casters[key]
        local index,expectedToken=caster.index,caster.advanceToken
        BfBot.Exec._Advance(key,token)
        BfBot.Exec._Advance(key)
        return {sameStep=caster.index==index,retainedToken=caster.advanceToken==expectedToken,
            freshToken=expectedToken~=token,running=BfBot.Exec.GetState()=='running'}
    """)
    assert facts["sameStep"] and facts["retainedToken"] and facts["freshToken"]
    assert facts["running"]
