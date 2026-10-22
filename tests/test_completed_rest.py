"""Completed-rest recognition and one-shot execution using production Lua."""
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def lua():
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("BfBot={Persist={}}")
    for name in ("BfBotPln.lua", "BfBotRst.lua"):
        runtime.execute((ROOT / "buffbot" / name).read_text(encoding="utf-8"))
    runtime.execute("""
        R=BfBot.Rest; P=BfBot.Plan
        function sample(time,stamp,complete,event,clock,owner)
            return {time=time,stamp=stamp,complete=complete,partyRested=event,
                clock=clock or time,owner=owner or 1}
        end
        state=P.Validate({rest={on=1,preset=1}})
        state.presets[1].requests={{group='BUFF',target='protagonist',on=1}}
        P.GetState=function()return state end
        P.Snapshot=function()return {groups={},pools={},actors={}}end
        P.BuildQueue=function()return {{spell='BUFF'}}end
        BfBot.Scan={InvalidateAll=function()end}
        calls,notices=0,{}
        BfBot.Exec={GetState=function()return 'idle'end,
            Start=function()calls=calls+1;return true end,
            _NotifyLeader=function(text)notices[#notices+1]=text end}
        now=100000;Infinity_GetClockTicks=function()return now end
        R.Sample=function()return sample(now,90000,true,true,now)end
        R.SafeWorld=function()return true end
        R.Combat=function()return false end
        function pending()
            R.previous=sample(now,90000,true,true,now)
            R.pending={preset=1,clock=now-1000}
        end
    """)
    return runtime


def test_load_only_seeds_baseline(lua):
    assert not lua.execute("return R.Observe(sample(50000,49999,true,true))")


@pytest.mark.parametrize("complete,event", [(False, True), (False, False)])
def test_clock_jump_needs_full_party_evidence(lua, complete, event):
    lua.globals().complete, lua.globals().event = complete, event
    assert not lua.execute("R.Observe(sample(100,50,true,false));return R.Observe(sample(36099,36099,complete,event))")


def test_completed_rest_is_recognized_once(lua):
    assert lua.execute("""
        R.Observe(sample(100,50,true,false))
        local first=R.Observe(sample(36099,36099,true,true))
        return first and not R.Observe(sample(36100,36099,true,true))
    """)


def test_consumed_native_event_and_poll_latency_do_not_lose_rest(lua):
    assert lua.execute("""
        R.Observe(sample(100,50,true,false))
        return R.Observe(sample(36110,36099,true,false))
    """)


def test_adjacent_engine_tick_rewind_preserves_rest_candidate(lua):
    assert lua.execute("""
        R.Observe(sample(100,50,true,false))
        R.Observe(sample(36099,50,false,false))
        return R.Observe(sample(36098,36099,true,false))
    """)


@pytest.mark.parametrize("advance,expected", [(35997, True), (35998, True), (35996, False)])
def test_native_rest_clock_endpoints(lua, advance, expected):
    lua.globals().advance = advance
    assert lua.execute("""
        R.Observe(sample(100,50,true,false))
        return R.Observe(sample(100+advance,100+advance,true,false))
    """) == expected


@pytest.mark.parametrize("oldest,expected", [(36098, True), (50, False)])
def test_party_timestamps_can_differ_but_every_member_must_be_fresh(lua, oldest, expected):
    lua.globals().oldest = oldest
    assert lua.execute("""
        R.Observe(sample(100,50,true,false))
        local s=sample(36099,36099,true,false);s.oldestStamp=oldest
        return R.Observe(s)
    """) == expected


def test_interrupted_rest_with_old_event_does_not_fire(lua):
    assert not lua.execute("R.Observe(sample(100,50,true,true));return R.Observe(sample(36099,50,true,true))")


def test_individual_rest_or_spell_restoration_does_not_fire(lua):
    assert not lua.execute("R.Observe(sample(100,50,true,true));return R.Observe(sample(101,101,true,true))")


def test_deferred_restoration_survives_pause(lua):
    assert lua.execute("""
        R.Observe(sample(100,50,true,false,0))
        R.Observe(sample(36099,50,false,false,100))
        return R.Observe(sample(36100,36099,true,true,600000))
    """)


@pytest.mark.parametrize("time,owner", [(50, 1), (36100, 2)])
def test_rewind_or_owner_replacement_discards_candidate(lua, time, owner):
    lua.globals().nextTime, lua.globals().nextOwner = time, owner
    assert not lua.execute("""
        R.Observe(sample(100,50,true,false));R.Observe(sample(36099,50,false,false))
        return R.Observe(sample(nextTime,nextTime,true,true,60000,nextOwner))
    """)


def test_stale_candidate_expires_by_game_time(lua):
    assert not lua.execute("""
        R.Observe(sample(100,50,true,false));R.Observe(sample(36099,50,false,false))
        return R.Observe(sample(37100,36099,true,true))
    """)


def test_pending_rest_starts_once_without_switching_active_preset(lua):
    assert lua.execute("pending();state.active=2;R.Tick();now=now+500;R.Tick();return calls==1 and state.active==2 and R.pending==nil")


@pytest.mark.parametrize("setup", [
    "state.rest.on=0", "state.rest.preset=2", "R.pending.clock=now-120001",
    "BfBot.Mp={_IsMpSession=function()return true end}",
    "BfBot.Exec.GetState=function()return 'running'end",
    "BfBot.Exec.GetState=function()return 'running'end;R.SafeWorld=function()return false end",
])
def test_disabled_expired_multiplayer_or_busy_never_starts(lua, setup):
    lua.execute("pending();" + setup + ";R.Tick()")
    assert lua.eval("calls==0 and R.pending==nil")


def test_combat_cancels_automatic_casting(lua):
    lua.execute("pending();R.Combat=function()return true end;R.Tick()")
    assert lua.eval("calls==0 and R.pending==nil and notices[1]=='Rest plan skipped: combat'")


def test_modal_world_defers_then_runs_once(lua):
    assert lua.execute("""
        pending();R.SafeWorld=function()return false end;R.Tick()
        local waiting=R.pending~=nil and calls==0
        now=now+500;R.SafeWorld=function()return true end;R.Tick()
        return waiting and calls==1 and R.pending==nil
    """)


def test_unavailable_plan_is_not_retried(lua):
    assert lua.execute("""
        pending();P.BuildQueue=function()return nil end;R.Tick()
        now=now+500;R.Tick()
        return calls==0 and R.pending==nil and #notices==1
    """)


def test_fresh_config_defaults_to_wake_up_and_rejects_missing_preset(lua):
    assert lua.execute("return P.Validate(nil).rest.on==1 and P.Validate({rest={on=1,preset=8}}).rest.on==0")


def test_config_roundtrip_uses_marshal_safe_values(lua):
    assert lua.execute("""
        local x=P.Validate({active=2,rest={on=1,preset=1}})
        local y=P.Validate(x)
        return y.rest.on==1 and y.rest.preset==1 and y.active==2
    """)


def test_ui_toggle_selects_current_plan_and_disables(lua):
    lua.execute((ROOT / "buffbot/BfBotPUI.lua").read_text(encoding="utf-8"))
    assert lua.execute("""
        state.active=2;BfBot.PartyUI.ToggleRest()
        local enabled=state.rest.on==1 and state.rest.preset==2
        BfBot.PartyUI.ToggleRest()
        return enabled and state.rest.on==0
    """)

@pytest.mark.parametrize("menu", ["BUFFBOT_RX", "BUFFBOT_RX_POPMENU", "BUFFBOT_RX_DIALOG"])
def test_redux_panel_and_popups_defer_rest_casting(menu):
    r = LuaRuntime(unpack_returned_tuples=True)
    r.execute("BfBot={Exec={}}")
    r.execute((ROOT / "buffbot/BfBotRst.lua").read_text(encoding="utf-8"))
    r.globals().openMenu = menu
    assert r.execute('''
        worldScreen={};e={GetActiveEngine=function()return worldScreen end}
        EngineGlobals={g_pBaldurChitin={m_pObjectGame={m_gameSave={m_inputMode=1}}}}
        EEex_Sprite_GetInPortrait=function()return nil end
        Infinity_IsMenuOnStack=function(name)return name==openMenu end
        assert(not BfBot.Rest.SafeWorld())
        openMenu=nil
        return BfBot.Rest.SafeWorld()
    ''')


def test_fresh_lists_are_empty_and_existing_preferences_stay_unchanged(lua):
    assert lua.execute("""
        local s=P.Validate(nil)
        assert(s.active==1 and s.presets[1].name=='Pre-Battle Buffs')
        assert(s.presets[2].name=='Wake Up Buffs' and #s.presets[1].requests==0 and #s.presets[2].requests==0)
        assert(s.rest.on==1 and s.rest.preset==2)
        s.presets[1].name='My old list';s.rest.on=0;s.rest.preset=1
        local saved=P.Validate(s)
        return saved.presets[1].name=='My old list' and saved.rest.on==0 and saved.rest.preset==1
    """)


def test_empty_rest_preset_is_a_silent_noop(lua):
    assert lua.execute("""
        pending();state.presets[1].requests={};R.Tick();now=now+500;R.Tick()
        return calls==0 and R.pending==nil and #notices==0
    """)
