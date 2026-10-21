from pathlib import Path
import pytest
from lupa.luajit21 import LuaRuntime
from test_party_dashboard import dashboard
from test_party_planner import lua

ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture
def fast():
    r=LuaRuntime(unpack_returned_tuples=True)
    r.execute('''
      bit=require('bit');io=nil;wall=100;tick=200;combat=false;multi=false;mode=0x801;menu=0
      EEex_CChitin={TIMER_UPDATES_PER_SECOND=30};worldScreen={};e={GetActiveEngine=function()return worldScreen end}
      EEex={UncapFPS_FPSLimit=144,UncapFPS_FPSLimitEnabled=false}
      EngineGlobals={g_pBaldurChitin={m_pObjectGame={m_worldTime={m_gameTime=tick},m_gameSave={m_inputMode=mode}}}}
      Infinity_GetClockTicks=function()return wall end;Infinity_IsMenuOnStack=function()return menu end
      BfBot={_Warn=function()end,Plan={GetState=function()return state end},Rest={Combat=function()return combat end},
        Mp={_IsMpSession=function()return multi end},Share={},Exec={}}
      state={fastRate=2};running=false;stops=0;notices={}
      BfBot.Exec.GetState=function()return running and 'running' or 'idle'end
      BfBot.Exec.Stop=function()stops=stops+1;running=false end
      BfBot.Exec._NotifyLeader=function(s)notices[#notices+1]=s end
      BfBot.Exec.Start=function(queue,mode,preset)
        assert(mode==0 and queue[1].cheat==0);received=queue;running=true;return true
      end
      EEex_GameState_AddDestroyedListener=function(f)destroyed=f end
    ''')
    r.execute((ROOT/'buffbot/BfBotFst.lua').read_text(encoding='utf-8'))
    r.execute('F=BfBot.Fast;queue={{spell="TEST",cheat=1}};F.Init()')
    return r

def test_native_mode_and_completion_restore_actual_baseline(fast):
    assert fast.execute('''
      EEex_CChitin.TIMER_UPDATES_PER_SECOND=40;assert(F.Start(queue))
      assert(EEex_CChitin.TIMER_UPDATES_PER_SECOND==80 and queue[1].cheat==1)
      wall=600;EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_worldTime.m_gameTime=240
      running=false;F.Tick()
      return EEex_CChitin.TIMER_UPDATES_PER_SECOND==40 and F.lastAudit.restored and F.lastAudit.gameTicks==40
    ''')

@pytest.mark.parametrize('change',[
    'combat=true','menu=1','multi=true',
    'e.GetActiveEngine=function()return{}end',
    'EngineGlobals.g_pBaldurChitin.m_pObjectGame.m_gameSave.m_inputMode=0x1016E',
    'wall=120101'])
def test_interruptions_restore_and_stop(fast,change):
    assert fast.execute('assert(F.Start(queue));'+change+''';F.Tick()
      return EEex_CChitin.TIMER_UPDATES_PER_SECOND==30 and stops==1 and not F.run
    ''')

def test_external_owner_is_not_overwritten(fast):
    assert fast.execute('''
      assert(F.Start(queue));EEex_CChitin.TIMER_UPDATES_PER_SECOND=8;F.Tick()
      return EEex_CChitin.TIMER_UPDATES_PER_SECOND==8 and stops==1 and not F.lastAudit.restored
    ''')

def test_load_releases_once_and_never_toggles_pause(fast):
    assert fast.execute('''
      assert(F.Start(queue));destroyed();destroyed()
      return not F.run and EEex_CChitin.TIMER_UPDATES_PER_SECOND==30
    ''')

def test_failed_start_releases_and_fourfold_is_capped(fast):
    assert fast.execute('''
      state.fastRate=4;EEex_CChitin.TIMER_UPDATES_PER_SECOND=40
      BfBot.Exec.Start=function()assert(EEex_CChitin.TIMER_UPDATES_PER_SECOND==120);return false,'bad' end
      local ok,why=F.Start(queue)
      return not ok and why=='bad' and not F.run and EEex_CChitin.TIMER_UPDATES_PER_SECOND==40
    ''')

def test_bad_queue_and_native_start_exception_do_not_leak_speed(fast):
    assert fast.execute('''
      assert(not F.Start(7) and not F.Start({}) and EEex_CChitin.TIMER_UPDATES_PER_SECOND==30)
      BfBot.Exec.Start=function()error('native start failed')end
      local ok=pcall(F.Start,queue)
      return not ok and not F.run and EEex_CChitin.TIMER_UPDATES_PER_SECOND==30
    ''')

def test_absent_optional_native_binding_declines_safely(fast):
    assert fast.execute('EEex_CChitin=nil;return not F.Start(queue) and not F.run and #notices==1')

def test_temporary_render_cap_and_original_disabled_limit_are_restored(fast):
    assert fast.execute('''
      assert(F.Start(queue));assert(EEex.UncapFPS_FPSLimit==30 and EEex.UncapFPS_FPSLimitEnabled)
      running=false;F.CheckDone()
      return EEex.UncapFPS_FPSLimit==144 and not EEex.UncapFPS_FPSLimitEnabled and F.lastAudit.renderRestored
    ''')

def test_lower_render_limit_is_preserved_and_external_changes_are_not_undone(fast):
    assert fast.execute('''
      EEex.UncapFPS_FPSLimit=20;EEex.UncapFPS_FPSLimitEnabled=true
      assert(F.Start(queue));assert(EEex.UncapFPS_FPSLimit==20)
      EEex.UncapFPS_FPSLimit=24;F.Reset('stopped')
      return EEex.UncapFPS_FPSLimit==24 and EEex.UncapFPS_FPSLimitEnabled and not F.lastAudit.renderRestored
    ''')

def test_missing_optional_render_controls_keep_fast_casting_functional(fast):
    assert fast.execute('EEex=nil;assert(F.Start(queue));F.Reset("stopped");return EEex_CChitin.TIMER_UPDATES_PER_SECOND==30 and not F.run')

def test_guard_is_bounded_by_wall_time_but_detects_combat_within_50ms(fast):
    assert fast.execute('''
      local count=0;BfBot.Rest.Combat=function()count=count+1;return combat end
      assert(F.Start(queue));F.Tick();local before=count
      combat=true;for i=1,500 do F.Tick()end;assert(count==before and F.run)
      wall=wall+50;F.Tick()
      return not F.run and count==before+1 and stops==1 and EEex_CChitin.TIMER_UPDATES_PER_SECOND==30
    ''')

def test_sharing_gaps_keep_speed_until_outer_plan_finishes(fast):
    assert fast.execute('''
      assert(F.Start(queue));BfBot.Share.run={};running=false;F.CheckDone();assert(F.run)
      BfBot.Share.run=nil;F.CheckDone();return not F.run and EEex_CChitin.TIMER_UPDATES_PER_SECOND==30
    ''')

def test_only_native_modes_save_and_select(dashboard):
    assert dashboard.execute('''
      setup(snapshot(),{});U.OpenChoices('casting');assert(#bbPartyChoices==3);bbPartyChoiceSelection=1;U.Choose()
      local saved=P.Validate(U.state);assert(saved.fast==1 and saved.fastRate==2 and saved.quick==0)
      U.OpenChoices('casting');bbPartyChoiceSelection=2;U.Choose();assert(U.state.fastRate==4)
      U.OpenChoices('casting');bbPartyChoiceSelection=3;U.Choose()
      return U.state.fast==0 and U.state.quick==0
    ''')


@pytest.mark.parametrize('saved,fast,rate',[
 ('nil',1,2),('{}',1,2),('{quick=1}',1,2),('{quick=1,fast=0}',1,2),
 ('{quick=0,fast=0}',0,2),('{quick=0}',0,2),
 ('{fast=1,fastRate=4}',1,4),('{fast=1,fastRate=2}',1,2)])
def test_default_migration_and_explicit_native_preferences(lua,saved,fast,rate):
 state=lua.eval('P.Validate('+saved+')')
 assert state['fast']==fast and state['fastRate']==rate and state['quick']==0


def test_retired_balancing_module_is_neither_loaded_nor_shipped():
 assert not (ROOT/'buffbot/BfBotBal.lua').exists()
 for path in ['buffbot/M_BfBot.lua','buffbot/setup-buffbot.tp2','tools/build-release.sh','tools/deploy.sh']:
  assert 'BfBotBal' not in (ROOT/path).read_text(encoding='utf-8')
 for p in (ROOT/'buffbot').glob('*.lua'):
  assert 'BfBot.Balanced' not in p.read_text(encoding='utf-8')


def test_casting_selector_labels_two_times_recommended():
    source=(ROOT/'buffbot/BfBotPUI.lua').read_text(encoding='utf-8')
    assert "'Fast-forward 2x (Recommended)',2" in source
