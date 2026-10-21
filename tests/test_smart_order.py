"""Duration-aware ordering, dependency fences and reversible UI edits."""
import pytest
from test_party_planner import lua
from test_party_dashboard import dashboard


def test_long_first_keeps_permanent_before_long_before_short(lua):
    assert lua.execute("""
      local s=snapshot();source(s,'SHORT','A',12,'s',1);source(s,'LONG','A',3600,'l',1);source(s,'PERM','A',-1,'p',1)
      local short,long,perm=request('SHORT','A','A'),request('LONG','A','A'),request('PERM','A','A')
      local original={short,long,perm};local sorted,changed=P.SortRequests(s,original,'long')
      return changed and sorted[1]==perm and sorted[2]==long and sorted[3]==short and original[1]==short
    """)


def test_smart_order_uses_casting_cost_instead_of_blind_long_first(lua):
    assert lua.execute("""
      local s=snapshot();source(s,'LONG_FAST','A',100,'l',1);source(s,'SHORT_SLOW','A',90,'s',1)
      local long,short=request('LONG_FAST','A','A'),request('SHORT_SLOW','A','A')
      local function timing(source)return {release=source.row.resref=='LONG_FAST' and 4 or 300,aura=false}end
      local smart,changed=P.SortRequests(s,{long,short},'smart',timing)
      local simple=P.SortRequests(s,{long,short},'long',timing)
      return changed and smart[1]==short and simple[1]==long and smart[2]==long
    """)


def test_smart_order_starts_from_global_long_first_and_keeps_pins_intact(lua):
    assert lua.execute("""
      local s=snapshot();source(s,'SHORT','A',12,'s',1);source(s,'OTHER','B',60,'o',1);source(s,'LONG','A',600,'l',1)
      local short,other,long=request('SHORT','A','A'),request('OTHER','B','B'),request('LONG','A','A')
      local sorted,changed=P.SortRequests(s,{short,other,long},'smart')
      return changed and sorted[1]==long and sorted[2]==other and sorted[3]==short
        and short.source=='A' and other.source=='B' and long.source=='A'
    """)


@pytest.mark.parametrize('kind',["unknown","missing","disabled"])
def test_unknown_or_unavailable_rows_move_after_known_durations(lua,kind):
    lua.globals().anchor_kind=kind
    assert lua.execute("""
      local s=snapshot();source(s,'SHORT','A',12,'s',1);source(s,'LONG','A',600,'l',1)
      source(s,'ANCHOR','A',anchor_kind=='unknown' and 0 or 60,'a',1)
      local a=request('ANCHOR','A','A');if anchor_kind=='missing' then a.source='GONE' elseif anchor_kind=='disabled' then a.on=0 end
      local short,long=request('SHORT','A','A'),request('LONG','A','A')
      local sorted,changed=P.SortRequests(s,{short,a,long},'long')
      return changed and sorted[1]==long and sorted[2]==short and sorted[3]==a
    """)


@pytest.mark.parametrize('mode',['long','smart'])
@pytest.mark.parametrize('kind',['helper','loan'])
def test_helper_spells_and_loans_do_not_anchor_sorting(lua,mode,kind):
    lua.globals().sort_mode=mode;lua.globals().entry_kind=kind
    assert lua.execute("""
      local s=snapshot();source(s,'HASTE','A',186,'h',1)
      local boots=source(s,'BOOTS','A',3600,'b',1)
      source(s,'BLUR','A',264,'u',1);source(s,'SANITY','A',2880,'s',1)
      if entry_kind=='loan' then boots.itemOwner='OWNER' end
      local haste,boot,blur,sanity=request('HASTE','A','A'),request('BOOTS','A','A'),request('BLUR','A','A'),request('SANITY','A','A')
      local function timing(source)return {barrier=source.row.resref=='HASTE',release=64}end
      local sorted,changed=P.SortRequests(s,{haste,boot,blur,sanity},sort_mode,timing)
      if sort_mode=='long' then return changed and sorted[1]==boot and sorted[2]==sanity and sorted[3]==blur and sorted[4]==haste end
      return changed and sorted[1]~=haste and sorted[4]==haste and (sorted[1]==boot or sorted[1]==sanity)
    """)


def test_real_modifier_preserves_affected_caster_sequence_without_freezing_other_casters(lua):
    assert lua.execute("""
      local s=snapshot();source(s,'SHORT','A',12,'s',1);local mod=source(s,'SPEED','A',20,'m',1)
      source(s,'LONG','A',600,'l',1);source(s,'OTHER','B',3600,'o',1)
      local short,speed,long,other=request('SHORT','A','A'),request('SPEED','A','A'),request('LONG','A','A'),request('OTHER','B','B')
      local function timing(source)return {barrier=source==mod,prerequisite=source==mod}end
      local sorted=P.SortRequests(s,{short,speed,long,other},'long',timing)
      return sorted[1]==other and sorted[2]==short and sorted[3]==speed and sorted[4]==long
    """)


def test_equal_timing_score_still_gives_smart_a_clean_long_first_baseline(lua):
    assert lua.execute("""
      local s=snapshot();source(s,'SHORT','A',60,'s',1);source(s,'LONG','B',600,'l',1)
      local a,b=request('SHORT','A','A'),request('LONG','B','B')
      local sorted,changed=P.SortRequests(s,{a,b},'smart')
      return changed and sorted[1]==b and sorted[2]==a
    """)


def test_equal_duration_sort_is_stable_and_noop(lua):
    assert lua.execute("""
      local s=snapshot();source(s,'A','A',60,'a',1);source(s,'B','A',60,'b',1)
      local a,b=request('A','A','A'),request('B','A','A')
      local sorted,changed=P.SortRequests(s,{a,b},'smart')
      return not changed and sorted[1]==a and sorted[2]==b
    """)


def test_manual_order_sort_and_undo_restore_exact_requests_and_selection(dashboard):
    assert dashboard.execute("""
      local s=snapshot();source(s,'SHORT','A',12,'s',1);source(s,'LONG','A',600,'l',1)
      setup(s,{request('SHORT','A','A'),request('LONG','A','A')})
      local first,second=U.preset.requests[1],U.preset.requests[2];U.request=first
      U.SortOrder('smart');assert(U.preset.requests[1]==second and bbPartyRequestSelection==2 and U.CanUndoOrder())
      U.UndoOrder();return U.preset.requests[1]==first and U.preset.requests[2]==second
        and bbPartyRequestSelection==1 and not U.CanUndoOrder()
    """)


def test_undo_is_invalidated_by_manual_move_and_sort_does_not_run_during_casting(dashboard):
    assert dashboard.execute("""
      local s=snapshot();source(s,'SHORT','A',12,'s',1);source(s,'LONG','A',600,'l',1)
      setup(s,{request('SHORT','A','A'),request('LONG','A','A')});U.SortOrder('long')
      U.request=U.preset.requests[1];U.Move(1);assert(not U.CanUndoOrder())
      local first=U.preset.requests[1];BfBot.Exec.GetState=function()return 'running'end
      U.SortOrder('smart');return first==U.preset.requests[1] and not U.CanSortOrder()
    """)


def test_phase_model_matches_aura_and_just_in_time_release(lua):
    assert lua.execute("""
      local ages=P.CastAges({{caster='A',release=64},{caster='B',release=24},
        {caster='A',release=44},{boundary=true},{caster='B',release=14}})
      return ages[1]==94 and ages[2]==90 and ages[3]==14 and ages[5]==0
    """)


def test_dependency_boundaries_do_not_reset_a_casters_aura(lua):
    assert lua.execute("""
      local ages,finish=P.CastAges({{caster='A',release=4},{boundary=true},{caster='A',release=4}})
      return finish==104 and ages[1]==100 and ages[3]==0
    """)


def test_jit_does_not_delay_preparation_to_align_intermediate_casts(lua):
    assert lua.execute("""
      local ages,finish=P.CastAges({{caster='A',release=64},{caster='B',release=24},
        {boundary=true},{caster='B',release=14}})
      return finish==114 and ages[1]==14 and ages[2]==90 and ages[4]==0
    """)


@pytest.mark.parametrize('delivery',['single','party','item','variant'])
def test_smart_places_invisibility_after_other_caster_targeted_buffs(lua,delivery):
 lua.globals().delivery=delivery
 assert lua.execute("""
 local s=snapshot()
 local invis=source(s,'INVIS','A',3600,'i',1)
 source(s,'ARMOR','B',60,'a',1)
 if delivery=='party' then invis.aoe=true;invis.row.isAoE=1 end
 if delivery=='item' then invis.row.kind='itm' end
 P.DeliversInvisibility=function(row,var)return row==invis.row and (delivery~='variant' or var=='CHILD') end
 local i=request('INVIS',delivery=='party' and 'party' or 'A','A',delivery=='variant' and 'CHILD' or nil)
 local a=request('ARMOR','A','B')
 local sorted=P.SortRequests(s,{i,a},'smart')
 return sorted[1]==a and sorted[2]==i
 """)


def test_invisible_recipient_can_still_self_cast_and_receive_party_buffs(lua):
 assert lua.execute("""
 local s=snapshot();local invis=source(s,'INVIS','A',3600,'i',1)
 source(s,'SELF','A',60,'s',1);local party=source(s,'PARTY','B',120,'p',1,{aoe=true})
 P.DeliversInvisibility=function(row)return row==invis.row end
 local i,a,p=request('INVIS','A','A'),request('SELF','A','A'),request('PARTY','party','B')
 local sorted=P.SortRequests(s,{a,p,i},'smart')
 return sorted[1]==i
 """)


def test_invisibility_detection_reads_children_variants_items_and_external_effects(lua):
 assert lua.execute("""
 Item_effect_st={sizeof=1};local effects={};local resources={}
 EEex_UDToPtr=function(h)return h.ptr end
 EEex_PtrToUD=function(ptr)return effects[ptr]end
 EEex_Resource_Demand=function(res,kind)return resources[kind..':'..res]end
 local function spell(res,ptr,op,child)
  local a={startingEffect=0,effectCount=1};local h={ptr=ptr,effectsOffset=0,castingStartingEffect=0,castingEffectCount=0}
  h.getAbilityForLevel=function()return a end;resources['SPL:'..res]=h
  effects[ptr]={effectID=op,res=child or ''}
  return h,a
 end
 spell('INVIS',100,20);spell('PARENT',200,146,'INVIS');spell('VISIBLE',300,17)
 resources['EFF:EXT']={m_effectId=20,m_res=''};spell('EXTERNAL',400,177,'EXT')
 local h,a=spell('ITEM',500,20);resources['ITM:BOOT']=h
 BfBot.Scan={_GetItemAbility=function()return a end}
 assert(P.DeliversInvisibility({kind='spl',resref='PARENT'}))
 assert(not P.DeliversInvisibility({kind='spl',resref='VISIBLE'}))
 assert(P.DeliversInvisibility({kind='spl',resref='VISIBLE'},'INVIS'))
 assert(not P.DeliversInvisibility({kind='spl',resref='INVIS'},'VISIBLE'))
 return P.DeliversInvisibility({kind='itm',itemResref='BOOT'}) and P.DeliversInvisibility({kind='spl',resref='EXTERNAL'})
 """)
