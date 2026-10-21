"""Summons contribute real resources without becoming recipient targets."""
from pathlib import Path
import pytest
from test_party_planner import lua
ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture
def summons(lua):
    lua.execute('''
      owner={name='Anomen',m_id=1,m_typeAI={m_Class=3},portrait=0}
      clone={name='Anomen',m_id=12,m_nCopyParent=1,m_typeAI={m_Class=3},portrait=-1}
      entries={{oid=12,name='Anomen',identity='clone:Anomen',kind='clone',cloneType=3}}
      objects={[1]=owner,[12]=clone}
      function EEex_Sprite_GetInPortrait(n)if n==0 then return owner end end
      function EEex_Sprite_GetPortraitIndex(s)return s.portrait end
      function EEex_Sprite_GetCharacterIndex(s)return s==owner and 0 or -1 end
      function EEex_GameObject_Get(id)return objects[id]end
      function EEex_GameObject_IsSprite(s)return s~=nil end
      function EEex_GameObject_CastUserType(s)return s end
      BfBot._GetName=function(s)return s.name end
      BfBot.Exec={_IsAlive=function()return true end,
        _ResolveCaster=function(ref)return objects[ref.oid]end}
      BfBot.Persist.GetPref=function()return 'inventory'end
      BfBot.Scan={GetAlliedSummons=function()return entries end,
        ClassifySummonSprite=function(s)
          if s.hostile then return nil end
          for _,e in ipairs(entries)do if e.oid==s.m_id then return e end end
        end,
        GetCastableSpells=function(s)return {
          WARD={kind='spl',resref='WARD',name='Ward',count=s==clone and 2 or 1,
            duration=s==clone and 120 or 60,casterLevel=10,spellType=2,level=4,
            class={isBuff=true},isSelfOnly=0,isAoE=0},
          SELF={kind='spl',resref='SELF',name='Self',count=1,spellType=2,level=1,
            duration=60,class={isBuff=true},isSelfOnly=1,isAoE=0}}
        end}
    ''')
    return lua

def test_clone_adds_independent_pool_and_can_cast_on_party(summons):
    assert summons.execute('''
      local s=P.Snapshot();assert(#s.order==1 and #s.casters==2)
      local plan=P.Assign(s,{{group='spl:WARD',target='protagonist',on=1}})
      local d=plan.decisions[1];assert(d.source.casterRef.kind=='summon')
      local q=P.BuildQueue(s,{{group='spl:WARD',target='protagonist',on=1}})
      return q[1].casterRef.oid==12 and q[1].target==1 and d.duration==120
        and s.pools['protagonist:spell:WARD']==1
        and s.pools['summon:clone:protagonist:3:spawn:12:spell:WARD']==2
    ''')

def test_summon_is_never_an_eligible_recipient_or_self_source_for_owner(summons):
    assert summons.execute('''
      local s=P.Snapshot();local key=P.CasterKey(clone)
      return P.Assign(s,{{group='spl:WARD',target=key}}).missing==1
        and P.Assign(s,{{group='spl:SELF',target='protagonist',source=key}}).missing==1
        and s.actors[key]==nil and #s.groups['spl:SELF'].sources==1
    ''')

def test_saved_choice_survives_respawn_but_missing_clone_is_unavailable(summons):
    assert summons.execute('''
      local key=P.CasterKey(clone);local request={group='spl:WARD',target='protagonist',source=key}
      entries={};objects[12]=nil
      assert(P.Assign(P.Snapshot(),{request}).missing==1)
      clone.m_id=55;objects[55]=clone
      entries={{oid=55,name='Anomen',identity='clone:Anomen',kind='clone',cloneType=3}}
      local s=P.Snapshot();local q=P.BuildQueue(s,{request})
      return P.CasterKey(clone)==key and q[1].casterRef.oid==55
        and P.Validate({presets={{requests={request}}}}).presets[1].requests[1].source==key
    ''')

def test_hostile_sources_fail_closed_and_duplicate_copies_have_separate_pools(summons):
    assert summons.execute('''
      clone.hostile=true;assert(#P.Snapshot().casters==1);clone.hostile=nil
      local second={name='Anomen',m_id=13,m_nCopyParent=1,m_typeAI={m_Class=3},portrait=-1}
      objects[13]=second;entries[2]={oid=13,name='Anomen',identity='clone:Anomen',kind='clone',cloneType=3}
      local key=P.CasterKey(clone);local s=P.Snapshot()
      local requests={};for i=1,3 do requests[i]={group='spl:WARD',target='protagonist',source=key}end
      local p=P.Assign(s,requests)
      return p.missing==0 and p.decisions[1].source.pool~=p.decisions[3].source.pool
        and s.pools['summon:clone:protagonist:3:spawn:13:spell:WARD']==1
    ''')

def test_generic_summon_uses_its_own_stable_identity(summons):
    assert summons.execute('''
      entries[1]={oid=12,name='Planetar',identity='cre:planetar',kind='summon'}
      return P.CasterKey(clone)=='summon:cre:planetar'
    ''')


def test_project_image_owner_is_unavailable_before_source_assignment(summons):
    assert summons.execute('''
      entries[1].cloneType=2
      local s=P.Snapshot();assert(s.actors.protagonist.projectImageLocked)
      local p=P.Assign(s,{{group='spl:WARD',target='protagonist'}})
      return p.missing==0 and p.decisions[1].source.casterRef.kind=='summon'
        and P.Assign(s,{{group='spl:WARD',target='protagonist',source='protagonist'}}).missing==1
    ''')



def test_caster_centered_party_buff_remains_available_from_summon(summons):
    assert summons.execute('''
      local get=BfBot.Scan.GetCastableSpells
      BfBot.Scan.GetCastableSpells=function(actor)
        local rows=get(actor);rows.SELF.isAoE=1;rows.SELF.isSelfOnly=0;rows.SELF.radialParty=true
        return rows
      end
      local s=P.Snapshot();local key=P.CasterKey(clone)
      local assigned=P.Assign(s,{{group='spl:SELF',target='party',source=key}})
      return assigned.missing==0 and assigned.decisions[1].source.casterRef.kind=='summon'
    ''')
