"""Recognize friendly caster-centered projectiles without spell-name overrides."""
from pathlib import Path
import pytest
from lupa.luajit21 import LuaRuntime
from test_party_planner import lua as planner

ROOT=Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('target,kind,flags,radius,expected',[
    (5,3,0xD0,171,True), (7,3,0xC0,80,True),
    (1,3,0xC0,171,False), (5,2,0xC0,171,False),
    (5,3,0x40,171,False), (5,3,0,171,False), (5,3,0xC0,0,False),
])
def test_projectile_structure_controls_party_delivery(target,kind,flags,radius,expected):
    r=LuaRuntime(unpack_returned_tuples=True);r.execute('BfBot={}')
    r.execute((ROOT/'buffbot/BfBotCls.lua').read_text(encoding='utf-8'))
    r.globals().kind=kind;r.globals().flags=flags;r.globals().radius=radius;r.globals().target=target
    assert r.execute('''
      local calls=0
      EEex_Resource_LoadIDS=function(name,array)
        assert(name=='PROJECTL' and array)
        return {getLine=function(_,id)assert(id==368);return 'MODAREA'end}
      end
      EEex_Resource_Demand=function(res,t)
        assert(res=='MODAREA' and t=='PRO');calls=calls+1;return {m_wFileType=kind}
      end
      EEex_UDToPtr=function()return 1000 end
      EEex_ReadU16=function(p)return p==1000+0x1F8 and flags or radius end
      local ability={actionType=target,missileType=369}
      local result=BfBot.Class.IsRadialParty(ability)
      assert(BfBot.Class.IsRadialParty(ability)==result and calls<=1)
      return result
    ''') is expected


def test_radial_request_upgrade_keeps_caster_order_variant_and_disabled_state(planner):
    assert planner.execute('''
      local s={groups={RADIAL={sources={{actor='CLERIC',row={radialParty=true}}}},
        SELF={sources={{actor='CLERIC',row={}}}}}}
      local requests={{group='RADIAL',target='CLERIC',on=0,var='SCHOOL'},
        {group='SELF',target='CLERIC',on=1},
        {group='RADIAL',target='party',on=1},
        {group='RADIAL',target='CLERIC',source='OTHER',on=1}}
      P.NormalizeRadialRequests(s,requests);P.NormalizeRadialRequests(s,requests)
      return #requests==4 and requests[1].target=='party' and requests[1].source=='CLERIC'
        and requests[1].on==0 and requests[1].var=='SCHOOL'
        and requests[2].target=='CLERIC' and requests[3].source==nil
        and requests[4].target=='CLERIC' and requests[4].source=='OTHER'
    ''')

from test_runtime_compatibility import exec_lua


def test_executor_keeps_radial_party_as_one_caster_centered_cast(exec_lua):
    assert exec_lua.execute('''
      BfBot_TestQueueWorld({RADIAL={count=1,name='Radial',class={isAoE=false},
        radialParty=true,isAoE=1,isSelfOnly=0}},2)
      local by,total=BfBot.Exec._BuildQueue({{caster=0,spell='RADIAL',target='all'}},0)
      return total==1 and #by.p0==1 and by.p0[1].targetObj=='Myself'
    ''')
