"""Item completions leave native equipment traversal before touching sprites."""
from pathlib import Path
import pytest
from lupa.luajit21 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture
def runtime():
    r=LuaRuntime(unpack_returned_tuples=True)
    r.execute('BfBot={};calls={}')
    r.execute((ROOT/'buffbot/BfBotExe.lua').read_text(encoding='utf-8'))
    r.execute('''
      E=BfBot.Exec;E._state='running';E._casters={p0={},p1={}}
      E._Advance=function(key)calls[#calls+1]=key end
      EEex_Sprite_GetInPortrait=function()error('Native callback must not resolve sprites')end
    ''')
    return r

def test_native_completion_only_marks_ready_then_each_lane_advances_once(runtime):
    assert runtime.execute('''
      E._MakeItemAdvance('p0',E._casters.p0);E._MakeItemAdvance('p1',E._casters.p1)
      E._ItemAdvanceReady('p0',E._casters.p0.itemAdvanceToken)
      E._ItemAdvanceReady('p1',E._casters.p1.itemAdvanceToken)
      assert(#calls==0);E.PumpItemAdvances();E.PumpItemAdvances()
      return #calls==2 and calls[1]~=calls[2]
    ''')

def test_old_callback_cannot_advance_replacement_run_in_same_caster_slot(runtime):
    assert runtime.execute('''
      E._MakeItemAdvance('p0',E._casters.p0);local old=E._casters.p0.itemAdvanceToken
      E._casters.p0={};E._MakeItemAdvance('p0',E._casters.p0)
      E._ItemAdvanceReady('p0',old);E.PumpItemAdvances()
      return #calls==0 and not E._casters.p0.itemAdvanceReady
    ''')

def test_stopped_and_non_world_states_do_not_continue_items(runtime):
    assert runtime.execute('''
      E._MakeItemAdvance('p0',E._casters.p0)
      E._ItemAdvanceReady('p0',E._casters.p0.itemAdvanceToken)
      E._state='stopped';E.PumpItemAdvances();assert(#calls==0)
      E._state='running';worldScreen={};e={GetActiveEngine=function()return 'store'end}
      E.PumpItemAdvances();assert(#calls==0)
      e.GetActiveEngine=function()return worldScreen end;E.PumpItemAdvances()
      return #calls==1
    ''')


def test_recipient_caster_guard_uses_stable_identity_without_native_name_read(runtime):
    assert runtime.execute('''
      local sprite={key='dv:CASTER'}
      BfBot.Plan={ActorKey=function(s)return s.key end}
      BfBot._GetName=function()error('Display names are not identity guards')end
      E._ResolveCaster=function()return sprite end
      EEex_Sprite_GetInPortrait=function()return sprite end
      local caster={ref={kind='party',slot=0},plannedActor='dv:CASTER',name='Old display name'}
      E._casters={p0=caster}
      assert(E._ResolveCasterForStep(caster)==sprite and not E._IsStateStale())
      sprite.key='dv:REPLACEMENT'
      return E._ResolveCasterForStep(caster)==nil and E._IsStateStale()
    ''')



def test_summon_inventory_exchange_is_rejected_before_party_only_callbacks(runtime):
    assert runtime.execute('''
      BfBot.Persist={GetItemSwap=function()return nil end,GetPref=function()return 'swap'end}
      BfBot.Scan={_PlanItemSwap=function()error('Party inventory exchange only')end}
      E._LogEntry=function()end
      return not E._QueueItem('s12',{ref={kind='summon',oid=12}},
        {spellName='Item'},{kind='itm',itemSlot=18,itemType=4},{},'advance')
    ''')
