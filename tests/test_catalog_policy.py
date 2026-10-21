"""Recipient browser defaults must not mistake offensive discovery for intent."""
from pathlib import Path
import pytest
from lupa.luajit21 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]


@pytest.fixture
def lua():
    runtime=LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("jit.off();BfBot={Persist={}}")
    runtime.execute((ROOT/'buffbot/BfBotPln.lua').read_text(encoding='utf-8'))
    runtime.execute("""
        P=BfBot.Plan
        sprite={m_typeAI={m_Class=19},m_id=10}
        state=P.Validate({presets={{name='Everyday',requests={}}, {name='Rest',requests={}}}})
        aux={BBParty=state}
        rows={DEBUFF={resref='DEBUFF',kind='spl',name='Debuff',count=4,level=2,spellType=1,
            duration=60,isAoE=0,isSelfOnly=0,class={isBuff=true,msectype=11}},
            BUFF={resref='BUFF',kind='spl',name='Buff',count=4,level=2,spellType=1,
            duration=60,isAoE=0,isSelfOnly=0,class={isBuff=true,msectype=2}}}
        EEex_Sprite_GetInPortrait=function(i) if i==0 then return sprite end end
        EEex_Sprite_GetCharacterIndex=function() return 0 end
        EEex_GetUDAux=function() return aux end
        BfBot._GetName=function() return 'Mage' end
        BfBot.Persist._GetProtagonist=function() return sprite end
        BfBot.Persist.GetPref=function() return 'inventory' end
        BfBot.Exec={_IsAlive=function() return true end,GetState=function() return 'idle' end}
        BfBot.Scan={GetCastableSpells=function() return rows end,InvalidateAll=function() end}
    """)
    return runtime


@pytest.mark.parametrize('category',[4,10,11])
def test_offensive_categories_do_not_enter_the_default_catalog_despite_positive_score(lua,category):
    lua.globals().category=category
    assert not lua.execute("return P.IsAutomaticBuff({kind='spl',class={isBuff=true,score=100,msectype=category}})")


@pytest.mark.parametrize('flag',['overridden','isSelfOnly','friendlyFlag'])
def test_positive_override_self_and_friendly_casts_preserve_explicit_signals(lua,flag):
    lua.globals().flag=flag
    assert lua.execute("local c={isBuff=true,msectype=11};c[flag]=true;return P.IsAutomaticBuff({kind='spl',class=c})")


@pytest.mark.parametrize('category',[0,1,2,3,5,6,7,8,9,12,13,199])
def test_other_categories_retain_the_existing_classifier_decision(lua,category):
    lua.globals().category=category
    assert lua.execute("return P.IsAutomaticBuff({kind='spl',class={isBuff=true,msectype=category}})")


def test_item_graph_discovery_policy_is_unchanged(lua):
    assert lua.execute("return P.IsAutomaticBuff({kind='itm',class={isBuff=true,msectype=11}})")


@pytest.mark.parametrize('category',[11,35])
def test_consumable_scrolls_and_wand_charges_require_deliberate_inclusion(lua,category):
    lua.globals().category=category
    assert lua.execute('''
      local row={kind='itm',itemType=category,class={isBuff=true}}
      assert(not P.IsAutomaticBuff(row));row.class.overridden=true
      return P.IsAutomaticBuff(row)
    ''')


def test_negative_overrides_and_missing_classification_are_not_reenabled(lua):
    assert lua.execute("""
        return not P.IsAutomaticBuff(nil) and not P.IsAutomaticBuff({})
            and not P.IsAutomaticBuff({kind='spl',class={isBuff=false,overridden=true,isSelfOnly=true}})
    """)


def test_filtered_rows_stay_in_known_abilities_and_still_reserve_spontaneous_pools(lua):
    assert lua.execute("""
        rows.DEBUFF.count=2
        local s=P.Snapshot()
        return s.groups['spl:DEBUFF']==nil and s.groups['spl:BUFF']~=nil
            and s.order[1].rows.DEBUFF==rows.DEBUFF
            and s.pools['protagonist:level:1:2']==2
    """)


@pytest.mark.parametrize('preset',[1,2,8])
def test_existing_requests_in_other_and_rest_presets_keep_intended_sources(lua,preset):
    lua.globals().preset=preset
    assert lua.execute("""
        state.presets[preset]={name='Saved',requests={{group='spl:DEBUFF',target='protagonist',on=1}}}
        state.rest={on=1,preset=preset}
        local s=P.Snapshot()
        local plan=P.Assign(s,state.presets[preset].requests)
        return s.groups['spl:DEBUFF']~=nil and plan.missing==0 and plan.used['protagonist:level:1:2']==1
    """)


def test_disabled_old_request_does_not_seed_default_browser(lua):
    assert lua.execute("""
        state.presets[2].requests={{group='spl:DEBUFF',target='protagonist',on=0}}
        return P.Snapshot().groups['spl:DEBUFF']==nil
    """)


def test_saved_request_does_not_bypass_an_incomplete_or_negative_classifier(lua):
    assert lua.execute("""
        rows.DEBUFF.class.isBuff=false
        state.presets[1].requests={{group='spl:DEBUFF',target='protagonist',on=1}}
        return P.Snapshot().groups['spl:DEBUFF']==nil
    """)


def test_manual_include_still_supports_counterintuitive_abilities(lua):
    assert lua.execute("""
        rows.DEBUFF.class.isBuff=false;state.include['spl:DEBUFF']=1
        return P.Snapshot().groups['spl:DEBUFF']~=nil
    """)


def test_native_add_flow_can_restore_a_filtered_spell_without_global_classifier_override(lua):
    lua.execute((ROOT/'buffbot/BfBotPUI.lua').read_text(encoding='utf-8'))
    assert lua.execute("""
        Infinity_PushMenu=function() end;Infinity_PopMenu=function() end
        local U=BfBot.PartyUI;U.Refresh(false)
        assert(U.snapshot.groups['spl:DEBUFF']==nil)
        U.OpenChoices('add')
        local index
        for i,c in ipairs(bbPartyChoices) do if c.value=='spl:DEBUFF' then index=i end end
        assert(index);bbPartyChoiceSelection=index;U.Choose()
        return state.include['spl:DEBUFF']==1 and U.snapshot.groups['spl:DEBUFF']~=nil
            and rows.DEBUFF.class.isBuff and rows.DEBUFF.class.overridden==nil
    """)


def test_item_selection_dialogues_do_not_seed_automatic_buff_browser(lua):
    assert lua.execute('''
      return not P.IsAutomaticBuff({kind='itm',requiresChoice=true,class={isBuff=true}})
    ''')


@pytest.mark.parametrize('res',['C0FIG02','C0FIG02A','C0FIG02B','C0FIG02C'])
def test_expertise_stance_is_manual_only(lua,res):
 lua.globals().res=res
 assert lua.execute("return not P.IsAutomaticBuff({resref=res,kind='spl',class={isBuff=true,isSelfOnly=true}})")


def test_expertise_can_still_be_manually_added(lua):
 assert lua.execute("""
 rows.C0FIG02={resref='C0FIG02',kind='spl',name='Expertise',count=1,level=0,spellType=4,
  duration=-1,isAoE=0,isSelfOnly=1,class={isBuff=true,isSelfOnly=true}}
 assert(not P.Snapshot().groups['spl:C0FIG02'])
 state.include['spl:C0FIG02']=1
 return P.Snapshot().groups['spl:C0FIG02']~=nil
 """)
