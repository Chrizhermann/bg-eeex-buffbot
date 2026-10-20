"""Dashboard actions must preserve the planner's real recipient/pool constraints."""
from pathlib import Path

import pytest

from test_party_planner import lua  # shared pure Lua allocation fixture

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def dashboard(lua):
    lua.execute((ROOT / 'buffbot/BfBotPUI.lua').read_text(encoding='utf-8'))
    lua.execute('''
        U=BfBot.PartyUI
        BfBot.Scan={InvalidateAll=function() scans=scans+1 end}
        BfBot.Exec={GetState=function() return 'idle' end}
        scans=0; pushed={}
        Infinity_PushMenu=function(name) pushed[#pushed+1]=name end
        Infinity_PopMenu=function() end
        function setup(s,requests)
            s.order={s.actors.A,s.actors.B}
            s.actors.A.key='A';s.actors.B.key='B'
            s.actors.A.rows={};s.actors.B.rows={}
            state=P.Validate({presets={{name='Test',requests=requests or {}}}})
            P.GetState=function() return state end
            P.Snapshot=function() return s end
            U.Refresh()
        end
        function findrow(key)
            for i,r in ipairs(bbPartyRows) do
                if r.key==key then bbPartyRowSelection=i;return r end
            end
        end
    ''')
    return lua


def test_everyone_preserves_existing_source_locks_and_adds_only_missing(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'BUFF','A',120,'a',1);source(s,'BUFF','B',60,'b',1)
        setup(s,{request('BUFF','A','A')})
        assert(findrow('BUFF').everyone)
        U.DashboardClick(4)
        assert(#U.preset.requests==2 and U.preset.requests[1].source=='A')
        assert(U.plan.missing==0 and U.plan.used.a==1 and U.plan.used.b==1)
        findrow('BUFF');U.DashboardClick(4)
        return #U.preset.requests==2 and scans==1
    ''')


def test_everyone_checks_shared_pools_across_other_spell_rows(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'BUFF','A',60,'level',2);source(s,'OTHER','A',60,'level',2)
        setup(s,{request('OTHER','A')})
        local row=findrow('BUFF');assert(not row.everyone)
        U.DashboardClick(4)
        return #U.preset.requests==1 and U.plan.used.level==1
    ''')


def test_everyone_not_available_for_self_only_dead_or_pinned_infeasible_targets(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'SELF','A',60,'a',6,{selfOnly=true})
        setup(s);assert(not findrow('SELF').everyone)
        U.DashboardClick(6)
        assert(#U.preset.requests==0 and U.DashboardCell(bbPartyRowSelection,2)==nil)
        U.CoverageClick(4)
        assert(bbPartyFeedback=='Self only')
        s.actors.B.alive=false
        source(s,'TARGET','A',60,'t',6)
        U.Refresh(false)
        return not findrow('TARGET').everyone
    ''')


def test_bulk_add_can_coexist_with_an_unrelated_already_unavailable_request(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'BUFF','A',60,'a',2)
        setup(s,{request('GONE','A')})
        assert(findrow('BUFF').everyone)
        U.DashboardClick(4)
        return #U.preset.requests==3 and U.plan.missing==1
            and U.plan.decisions[1].request.group=='GONE'
    ''')


def test_toggles_use_selected_row_not_render_time_row_number(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'FIRST','A',60,'a',2);source(s,'LAST','A',60,'b',2)
        setup(s);findrow('FIRST');rowNumber=2
        U.DashboardClick(6)
        return U.preset.requests[1].group=='FIRST'
            and U.preset.requests[1].target=='B'
    ''')


def test_party_buffs_are_visible_in_individual_filters_but_still_cast_once(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'BLESS','A',60,'a',2,{aoe=true})
        source(s,'SELF','B',60,'b',1,{selfOnly=true})
        setup(s);U.SetRecipient(1)
        assert(findrow('BLESS') and not findrow('SELF'))
        findrow('BLESS');U.DashboardClick(5);assert(#U.preset.requests==0)
        findrow('BLESS');U.DashboardClick(4)
        findrow('BLESS')
        return #U.preset.requests==1 and U.preset.requests[1].target=='party'
            and U.plan.used.a==1
    ''')


def test_no_empty_unknown_or_spent_sources_in_default_browser(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'GOOD','A',60,'a',1)
        source(s,'SPENT','A',60,'b',0)
        source(s,'UNKNOWN','A',60,'c',1,{reason='Unknown caster'})
        setup(s)
        return #bbPartyRows==1 and bbPartyRows[1].key=='GOOD'
    ''')


def test_exhausted_planned_item_and_missing_resource_stay_removable(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'GEAR','A',60,'boots',0,{selfOnly=true})
        setup(s,{request('GEAR','A'),request('GONE','B')})
        assert(findrow('GEAR').cells[1].checked and U.plan.missing==2)
        U.DashboardClick(5);assert(U.plan.missing==1)
        findrow('GONE');U.DashboardClick(5)
        return #U.preset.requests==0 and U.plan.missing==0
    ''')


def test_hiding_keeps_assignments_and_summary_and_marshal_state(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',2)
        setup(s,{request('BUFF','A')})
        U.OpenChoices('sources','BUFF')
        bbPartyChoiceSelection=#bbPartyChoices;U.Choose()
        assert(#bbPartyRows==0 and #U.preset.requests==1)
        local found=false
        for _,r in ipairs(bbPartySummary) do if r.request then found=true end end
        local saved=P.Validate(U.state)
        return found and saved.hidden.BUFF==1 and #saved.presets[1].requests==1
    ''')


def test_explicitly_hidden_spells_can_be_restored(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',1)
        setup(s);U.state.hidden.BUFF=1;U.Refresh(false)
        U.OpenChoices('hidden');bbPartyChoiceSelection=1;U.Choose()
        return #bbPartyRows==1 and U.state.hidden.BUFF==nil
    ''')


def test_search_and_view_changes_do_not_erase_assignments(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'FIRST','A',60,'a',1);source(s,'SECOND','B',60,'b',1)
        setup(s,{request('FIRST','A')})
        bbPartyQuery='second';U.FilterDashboard()
        assert(#bbPartyRows==1 and bbPartyRows[1].key=='SECOND')
        U.SetView('summary');U.SetView('dashboard');bbPartyQuery='';U.FilterDashboard()
        return #bbPartyRows==2 and #U.preset.requests==1 and scans==1
    ''')


def test_clearing_checkbox_removes_imported_repeats_together(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',3)
        setup(s,{request('BUFF','B'),request('BUFF','B')})
        findrow('BUFF');U.DashboardClick(6)
        return #U.preset.requests==0
    ''')


def test_compact_coverage_matrix_uses_the_same_plan_and_single_party_cast(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',2)
        source(s,'BLESS','A',60,'b',1,{aoe=true})
        setup(s);findrow('BUFF');U.CoverageClick(4)
        assert(U.preset.requests[1].target=='B')
        local row=findrow('BUFF');assert(U.CoverageText(bbPartyRowSelection,2)=='[x]')
        findrow('BLESS');U.DashboardClick(4)
        findrow('BLESS')
        assert(U.CoverageText(bbPartyRowSelection,1)=='[x] Party')
        U.CoverageClick(3)
        return #U.preset.requests==2 and bbPartyFeedback=='Party-wide cast'
    ''')


def test_manual_browser_flags_are_validated_without_boolean_marshal_values(dashboard):
    assert dashboard.execute('''
        local x=P.Validate({hidden={a=1,b=true,c=-1},include={['spl:OTHER']=1,b=true}})
        local y=P.Validate(x)
        return y.hidden.a==1 and y.hidden.b==nil and y.hidden.c==nil
            and y.include['spl:OTHER']==1 and y.include.b==nil
    ''')


def test_manual_include_enters_real_snapshot_without_bypassing_source_rules(dashboard):
    assert dashboard.execute('''
        local owner={m_id=1,m_typeAI={m_Class=2}}
        local saved=P.Validate(nil)
        BfBot.Persist={_GetProtagonist=function() return owner end}
        EEex_GetUDAux=function() return {BBParty=saved} end
        EEex_Sprite_GetInPortrait=function(slot) if slot==0 then return owner end end
        EEex_Sprite_GetCharacterIndex=function() return 0 end
        BfBot._GetDeathVar=function() return '' end
        BfBot._GetName=function() return 'A' end
        BfBot.Exec._IsAlive=function() return true end
        BfBot.Scan.GetCastableSpells=function()
            return {ODD={kind='spl',resref='ODD',name='Odd spell',class={isBuff=false},
                count=2,spellType=1,level=1,isSelfOnly=1,duration=60}}
        end
        assert(P.Snapshot().groups['spl:ODD']==nil)
        saved.include['spl:ODD']=1
        local snap=P.Snapshot()
        local group=snap.groups['spl:ODD']
        return group and #group.sources==1 and group.sources[1].selfOnly
            and P.Assign(snap,{request('spl:ODD','party')}).missing==1
    ''')


def test_everyone_respects_request_limit_without_partial_add(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',256)
        local req={};for i=1,255 do req[i]=request('BUFF','A') end
        setup(s,req)
        assert(findrow('BUFF').everyone)
        U.DashboardClick(4)
        assert(#U.preset.requests==256)
        source(s,'OTHER','A',60,'b',2);U.Refresh(false)
        return not findrow('OTHER').everyone and #U.preset.requests==256
    ''')


def test_dashboard_packs_recipients_and_clicks_the_visible_identity(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'SELF','B',60,'b',1,{selfOnly=true})
        setup(s);findrow('SELF')
        assert(U.DashboardCell(bbPartyRowSelection,1).target=='B')
        assert(U.DashboardCell(bbPartyRowSelection,2)==nil)
        assert(U.CellText(bbPartyRowSelection,1)=='[ ] B')
        assert(U.CellText(bbPartyRowSelection,2)=='')
        -- Coverage still maps its first column to A, second column to B.
        assert(U.CoverageText(bbPartyRowSelection,1)=='-')
        assert(U.CoverageText(bbPartyRowSelection,2)=='[ ]')
        U.DashboardClick(5)
        return #U.preset.requests==1 and U.preset.requests[1].target=='B'
    ''')


def test_packed_dashboard_retains_unavailable_planned_recipient_and_portrait(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'ITEM','B',60,'b',0,{selfOnly=true})
        setup(s,{request('ITEM','B')});findrow('ITEM')
        U.Portrait=function(slot) return slot==1 and 'B_PORTRAIT' or 'A_PORTRAIT' end
        assert(U.DashboardCell(bbPartyRowSelection,1).target=='B')
        assert(U.CellText(bbPartyRowSelection,1)=='[!] B')
        assert(U.CellPortrait(bbPartyRowSelection,1)=='B_PORTRAIT')
        U.DashboardClick(5)
        return #U.preset.requests==0
    ''')


def test_packed_strip_respects_recipient_filter_and_no_invisible_click_targets(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',2)
        setup(s);U.SetRecipient(2);findrow('BUFF')
        assert(U.DashboardCell(bbPartyRowSelection,1).target=='B')
        assert(U.DashboardCell(bbPartyRowSelection,2)==nil)
        U.DashboardClick(6);assert(#U.preset.requests==0)
        U.DashboardClick(5)
        return U.preset.requests[1].target=='B'
    ''')


def test_popups_have_separate_frame_shadow_and_content_geometry(dashboard):
    assert dashboard.execute('''
        Infinity_GetScreenSize=function() return 1280,720 end
        EEex_Menu_GetItemArea=function() return 1000,50,174,30 end
        local areas={}
        Infinity_SetArea=function(name,x,y,w,h) areas[name]={x,y,w,h} end
        U.choiceMode='presets';bbPartyChoices={{name='Test'}}
        U.PopupLayout(false)
        local bg,top,left,shadow=areas.bpChoicesBg,areas.bpChoicesTop,areas.bpChoicesLeft,areas.bpChoicesShadow
        assert(top[2]<bg[2] and top[3]>bg[3] and left[1]<bg[1])
        assert(shadow[1]>bg[1] and shadow[2]>bg[2])
        assert(bg[1]==1000 and bg[2]==82)
        U.PopupLayout(true)
        return areas.bpRenameTop[2]<areas.bpRenameBg[2]
            and areas.bpRenameRight[1]==areas.bpRenameBg[1]+areas.bpRenameBg[3]
    ''')
