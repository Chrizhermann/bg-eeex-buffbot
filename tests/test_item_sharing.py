"""Physical loans, charge conservation and recovery with queued engine actions."""
from pathlib import Path
import pytest
from lupa.luajit21 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture
def sharing():
    r=LuaRuntime(unpack_returned_tuples=True)
    r.execute('''
      jit.off();bit=require('bit');clock=0;actions={};warnings={};state={};area={ptr=100}
      actors={};for slot=0,1 do
        local a={key=slot==0 and 'OWNER' or 'BORROWER',slot=slot,items={},m_pArea=area,alive=true}
        a.m_equipment={m_items={get=function(_,n)return a.items[n]end}}
        actors[slot]=a
      end
      function item(res,count)
        return {pRes={resref={get=function()return res end}},m_flags=1,m_wear=7,m_useCount1=count,m_useCount2=0,m_useCount3=0}
      end
      actors[0].items[22]=item('BOOT12',2)
      function EEex_Sprite_GetInPortrait(slot)return actors[slot]end
      function EEex_Sprite_GetCharacterIndex(a)return a.slot end
      function EEex_UDToPtr(x)return x.ptr end
      function Infinity_GetClockTicks()return clock end
      function EEex_Action_QueueResponseStringOnAIBase(action,a)actions[#actions+1]={action=action,actor=a}end
      function EEex_Trigger_EvalConditionalStringAsAIBase(_,a)
        for _,v in ipairs(actions)do if v.actor==a then return false end end;return true
      end
      BfBot={Plan={ActorKey=function(a)return a.key end,GetState=function()return state end},
        Scan={InvalidateAll=function()end,_NativeCanWearItem=function()return true end,
          NativeBackpackMovesAvailable=function()return true end,
          _NativeMoveToBackpack=function(a,src,dest)
            assert(a.items[src] and not a.items[dest]);a.items[dest]=a.items[src];a.items[src]=nil;return true
          end},
        Persist={GetItemSwap=function(a)return a.swap end},
        _Warn=function(s)warnings[#warnings+1]=s end,Exec={_state='done',_castCount=0,_skipCount=0,
          _IsAlive=function(a)return a.alive end,_NotifyLeader=function()end}}
      function BfBot.Exec.Start(queue)
        local a=actors[queue[1].caster];assert(a.items[queue[1].plannedItemSlot])
        a.items[queue[1].plannedItemSlot].m_useCount1=a.items[queue[1].plannedItemSlot].m_useCount1-1
        BfBot.Exec._state='running';BfBot.Exec._castCount=1;BfBot.Exec._skipCount=0;return true
      end
      function BfBot.Exec.Stop()BfBot.Exec._state='stopped'end
      function BfBot.Exec._CasterKey(ref)return ref.kind=='party' and ('p'..ref.slot) or ('s'..ref.oid)end
      function BfBot.Exec._ResolveCaster(ref)return actors[ref.slot]end
      function drain()
        local v=table.remove(actions,1);if not v then return end
        local res,to=v.action:match('GiveItem%("(%w+)",Player(%d)%)')
        if res then
          local dest=actors[tonumber(to)-1];local source,object
          for slot,i in pairs(v.actor.items)do if i.pRes.resref:get()==res then source,object=slot,i;break end end
          if object then for n=18,33 do if not dest.items[n]then dest.items[n]=object;v.actor.items[source]=nil;break end end end
        else
          local res,slot=v.action:match('XEquipItem%("(%w+)",Myself,(%d+),1%)');assert(res)
          for n,i in pairs(v.actor.items)do if i.pRes.resref:get()==res then
            local old=v.actor.items[tonumber(slot)];v.actor.items[tonumber(slot)]=i;v.actor.items[n]=old;break
          end end
        end
      end
      function step()clock=clock+101;BfBot.Share.Tick()end
      function loan()return {{caster=1,plannedActor='BORROWER',plannedItemSlot=22,itemOwner='OWNER',sharedItem='BOOT12',spell='BOOT12',target='self'}}end
    ''')
    r.execute((ROOT/'buffbot/BfBotShr.lua').read_text(encoding='utf-8'))
    return r

def test_roundtrip_consumes_one_charge_and_restores_original_pack_slot(sharing):
    assert sharing.execute('''
      assert(BfBot.Share.Start(loan()));assert(state.transfer and #actions==1)
      drain();step();assert(BfBot.Exec._state=='running' and actors[1].items[18].m_useCount1==1)
      BfBot.Exec._state='done';step();drain();step();drain();step()
      return not BfBot.Share.run and not state.transfer and not next(actors[1].items)
        and actors[0].items[22].m_useCount1==1 and actors[0].items[22].m_wear==7
    ''')


def test_shared_item_alias_casts_as_borrower_with_borrower_timing_lane(sharing):
    assert sharing.execute('''
      BfBot.Share.CanBorrow=function()return true end
      EEex_Resource_Demand=function()return {}end
      BfBot.Scan._GetItemAbility=function()return {}end
      BfBot.Class={GetDuration=function()return 60 end}
      local source={id='physical',actor='OWNER',slot=0,casterName='Owner',
        casterRef={kind='party',slot=0},lane='OWNER',row={itemResref='BOOT12',abilityIdx=0}}
      local recipient={key='BORROWER',slot=1,name='Borrower',sprite={}}
      local snapshot={groups={boots={sources={source}}},order={recipient}}
      BfBot.Share.AddSources(snapshot)
      local alias=snapshot.groups.boots.sources[2]
      return alias.actor=='BORROWER' and alias.casterRef.slot==1
        and alias.lane=='BORROWER' and alias.itemOwner=='OWNER'
        and source.casterRef.slot==0
    ''')

def test_stop_before_forward_transfer_does_not_discard_return_journal(sharing):
    assert sharing.execute('''
      BfBot.Share.Start(loan());BfBot.Share.Stop();step()
      assert(state.transfer and actors[0].items[22])
      drain();step();drain();step();drain();step()
      return state.transfer==nil and BfBot.Share.run==nil and actors[0].items[22].m_useCount1==2
    ''')

def test_loaded_loan_returns_without_recasting(sharing):
    assert sharing.execute('''
      BfBot.Share.Start(loan());drain();step();assert(actors[1].items[18].m_useCount1==1)
      state.transfer=BfBot.Share.ValidateJournal(state.transfer);BfBot.Share.run=nil;BfBot.Exec._state='idle'
      step();drain();step();drain();step()
      return state.transfer==nil and actors[0].items[22].m_useCount1==1
    ''')

def test_occupied_original_slot_preserves_item_and_journal_without_spam(sharing):
    assert sharing.execute('''
      BfBot.Share.Start(loan());drain();step();BfBot.Exec._state='done'
      actors[0].items[22]=item('OTHER',1);step();step();step()
      assert(state.transfer and actors[1].items[18] and #actions==0 and #warnings==1)
      actors[0].items[22]=nil;step();drain();step();drain();step()
      return state.transfer==nil and actors[0].items[22].m_useCount1==1
    ''')

@pytest.mark.parametrize('change',[
    "actors[1].alive=false",
    "actors[1].m_pArea={ptr=999}",
    "actors[1].items[18].m_flags=9",
    "actors[1].items[18].m_wear=8",
    "actors[1].items[18].m_useCount1=9",
    "actors[0].items[19]=item('BOOT12',2)",
])
def test_changed_or_ambiguous_gear_is_never_recreated_or_transferred(sharing,change):
    sharing.execute('BfBot.Share.Start(loan());drain();step();BfBot.Exec._state="done"')
    sharing.execute(change)
    assert sharing.execute('step();return state.transfer~=nil and #actions==0 and actors[1].items[18]~=nil')

@pytest.mark.parametrize('field,value',[('item',"'BAD\"'"),('owner',"'BORROWER'"),('pack','17'),('pack','22.5'),('flags','-1'),('wear','65536'),('counts','{2,-1,0}')])
def test_invalid_recovery_records_are_rejected(sharing,field,value):
    sharing.execute('BfBot.Share.Start(loan())')
    assert sharing.execute(f'state.transfer.{field}={value};return BfBot.Share.ValidateJournal(state.transfer)==nil')

@pytest.fixture
def eligible(sharing):
    sharing.execute('''
      header={ptr=1000};ability={ptr=2000};maxCharges,depletion,stack,flags=2,3,1,4
      function EEex_Resource_Demand()return header end
      function EEex_ReadU16(p)return ({[2034]=maxCharges,[2036]=depletion,[1056]=stack})[p]or 0 end
      function EEex_ReadU32()return flags end
      BfBot.Scan._GetItemAbility=function()return ability end
      source={actor='OWNER',selfOnly=true,itemSlot=22,row={kind='itm',itemResref='BOOT12',abilityIdx=0}}
      recipient={key='BORROWER',sprite=actors[1],alive=true,controlled=true}
    ''')
    return sharing

def test_daily_gear_requires_actual_engine_permission(eligible):
    assert eligible.execute('''
      assert(BfBot.Share.CanBorrow(source,recipient))
      BfBot.Scan._NativeCanWearItem=function()return false end
      assert(not BfBot.Share.CanBorrow(source,recipient))
      BfBot.Scan._NativeCanWearItem=function()return nil,'unsupported engine'end
      return not BfBot.Share.CanBorrow(source,recipient)
    ''')

@pytest.mark.parametrize('change',[
    'maxCharges=1','depletion=1','stack=2','flags=16','flags=0','actors[0].items[22].m_flags=9',
    'source.itemSlot=3','recipient.controlled=false','recipient.ambiguous=true',
    "actors[1].m_pArea={ptr=99}",'for n=18,33 do actors[1].items[n]=item("OTHER",1)end',
])
def test_unsafe_or_consumable_sources_never_become_borrow_candidates(eligible,change):
    eligible.execute(change)
    assert eligible.eval('not BfBot.Share.CanBorrow(source,recipient)')




def test_mixed_shared_item_passes_mode_through_loan_and_returns_before_next_spell(sharing):
    assert sharing.execute("""
      local start=BfBot.Exec.Start;local modes={}
      BfBot.Exec.Start=function(q,mode)modes[#modes+1]=mode;return start(q)end
      BfBot.Share.Start(loan(),0);drain();step();assert(modes[1]==0)
      BfBot.Exec._state='done';step();drain();step();drain();step()
      return not BfBot.Share.run and not state.transfer and actors[0].items[22].m_useCount1==1
    """)



def test_empty_ordered_run_preserves_empty_queue_error(sharing):
    assert sharing.execute("local ok,why=BfBot.Share.Start({},3);return not ok and why=='reason.exec.empty_queue' and not BfBot.Share.run")


def test_normal_casting_batches_independent_sources_before_shared_item(sharing):
    assert sharing.execute('''
      local batches={}
      BfBot.Exec.Start=function(q,mode)
        assert(mode==0);local names={};for _,e in ipairs(q)do names[#names+1]=e.spell end
        batches[#batches+1]=table.concat(names,',')
        BfBot.Exec._state='running';BfBot.Exec._castCount=#q;BfBot.Exec._skipCount=0;return true
      end
      local q={{caster=0,spell='FIRST'},{caster=1,spell='SECOND'},{caster=0,spell='THIRD'}}
      q[4]=loan()[1]
      assert(BfBot.Share.Start(q,0));assert(batches[1]=='FIRST,SECOND,THIRD' and not state.transfer)
      BfBot.Exec._state='done';step()
      return #batches==1 and state.transfer~=nil and BfBot.Share.run.index==4
    ''')



@pytest.mark.parametrize('resource',['AC#MGBT1','!BOOT','A+B-1'])
def test_mod_resource_symbols_survive_loan_journal_roundtrip(sharing,resource):
    sharing.globals().res=resource
    assert sharing.execute('''
      BfBot.Share.Start(loan());state.transfer.item=res
      return BfBot.Share.ValidateJournal(state.transfer).item==res
    ''')
