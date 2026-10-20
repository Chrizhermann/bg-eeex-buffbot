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


def test_individual_toggles_preserve_source_locks_and_reserve_shared_uses(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'BUFF','A',120,'a',1);source(s,'BUFF','B',60,'b',1)
        setup(s,{request('BUFF','A','A')})
        findrow('BUFF');U.DashboardClick(4)
        assert(#U.preset.requests==1) -- Duration column is informational.
        U.DashboardClick(6)
        assert(#U.preset.requests==2 and U.preset.requests[1].source=='A')
        assert(U.plan.missing==0 and U.plan.used.a==1 and U.plan.used.b==1)
        findrow('BUFF');U.DashboardClick(6)
        return #U.preset.requests==1 and scans==1
    ''')


def test_individual_toggles_respect_pools_reserved_by_other_spells(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'BUFF','A',60,'level',2);source(s,'OTHER','A',60,'level',2)
        setup(s,{request('OTHER','A')})
        findrow('BUFF');U.DashboardClick(5)
        findrow('BUFF');U.DashboardClick(6)
        return #U.preset.requests==2 and U.plan.used.level==2
    ''')


def test_hidden_self_only_target_stays_explained_in_coverage(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'SELF','A',60,'a',6,{selfOnly=true})
        setup(s);findrow('SELF');U.DashboardClick(6)
        assert(#U.preset.requests==0 and U.DashboardCell(bbPartyRowSelection,2)==nil)
        U.CoverageClick(4)
        return bbPartyFeedback=='Self only'
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
        findrow('BLESS');U.DashboardClick(6);assert(#U.preset.requests==0)
        findrow('BLESS');U.DashboardClick(5)
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
        findrow('BLESS');U.DashboardClick(5)
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


def test_individual_toggle_respects_request_limit(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',300)
        local req={};for i=1,256 do req[i]=request('BUFF','A') end
        setup(s,req);findrow('BUFF');U.DashboardClick(6)
        return #U.preset.requests==256 and U.DashboardCell(bbPartyRowSelection,2)==nil
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


def test_durations_follow_assigned_sources_and_recipient_filter(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'BUFF','A',120,'a',1);source(s,'BUFF','B',60,'b',1)
        setup(s,{request('BUFF','A'),request('BUFF','B')});findrow('BUFF')
        assert(U.RowDuration(bbPartyRowSelection)=='1.0m - 2.0m')
        assert(U.CellDuration(bbPartyRowSelection,1)=='2.0m')
        assert(U.CellDuration(bbPartyRowSelection,2)=='1.0m')
        U.SetRecipient(2);findrow('BUFF')
        return U.RowDuration(bbPartyRowSelection)=='1.0m'
            and U.CellDuration(bbPartyRowSelection,1)=='1.0m'
    ''')


def test_party_portrait_toggle_casts_once_and_duration_uses_selected_variant(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'BUFF','A',60,'a',2,{aoe=true,variants={{resref='ALT'}},variantDurations={ALT=180}})
        setup(s);findrow('BUFF')
        U.Portrait=function(slot) return slot==0 and 'PA' or 'PB' end
        assert(U.PartyPortrait(bbPartyRowSelection,1)=='PA')
        assert(U.PartyPortrait(bbPartyRowSelection,2)=='PB')
        assert(U.PartyPortrait(bbPartyRowSelection,3)=='')
        assert(U.PartyText(bbPartyRowSelection)=='[ ] Party')
        assert(U.RowDuration(bbPartyRowSelection)=='3.0m')
        U.DashboardClick(5);findrow('BUFF')
        assert(#U.preset.requests==1 and U.plan.used.a==1)
        assert(U.PartyText(bbPartyRowSelection)=='[x] Party')
        U.DashboardClick(5)
        return #U.preset.requests==0
    ''')


def test_duration_distinguishes_unavailable_unknown_and_permanent(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'PERM','A',-1,'a',1);source(s,'UNKNOWN','A',0,'b',1)
        setup(s,{request('GONE','B')})
        findrow('PERM');assert(U.RowDuration(bbPartyRowSelection)=='Permanent')
        findrow('UNKNOWN');assert(U.RowDuration(bbPartyRowSelection)=='Instant/unknown')
        findrow('GONE')
        return U.RowDuration(bbPartyRowSelection)=='Buff unavailable'
            and U.CellDuration(bbPartyRowSelection,1)==''
    ''')


def test_clear_removes_only_this_rows_assignments(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',2)
        source(s,'OTHER','A',60,'b',1)
        setup(s,{request('BUFF','A'),request('BUFF','B'),request('OTHER','B')})
        findrow('BUFF');U.DashboardClick(11)
        return #U.preset.requests==1 and U.preset.requests[1].group=='OTHER'
    ''')


def test_name_search_is_literal_case_insensitive_and_does_not_match_qualifiers(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'SPELL[1]','A',60,'a',1)
        source(s,'OTHER','A',60,'b',1)
        setup(s);findrow('OTHER').qualifier='SPELL[1]'
        bbPartyQuery='spell[1]';U.FilterDashboard()
        assert(#bbPartyRows==1 and bbPartyRows[1].key=='SPELL[1]')
        bbPartyQuery='not present';U.FilterDashboard();assert(#bbPartyRows==0)
        U.ClearSearch()
        return bbPartyQuery=='' and #bbPartyRows==2
    ''')


def test_name_sort_toggles_and_sorted_click_keeps_request_identity(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'alpha','A',60,'a',2)
        source(s,'Zulu','B',60,'b',2)
        setup(s,{request('alpha','A')})
        assert(bbPartyRows[1].key=='alpha')
        U.SortBy('name');assert(bbPartyRows[1].key=='Zulu')
        assert(U.SortHeading('name')=='Name  v')
        bbPartyRowSelection=1;U.DashboardClick(6)
        assert(U.preset.requests[1].group=='alpha')
        assert(U.preset.requests[2].group=='Zulu' and U.preset.requests[2].target=='B')
        U.SortBy('name')
        return bbPartyRows[1].key=='alpha' and U.SortHeading('name')=='Name  ^'
    ''')


def test_duration_sort_uses_seconds_range_maximum_and_keeps_unknowns_last(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'MINUTE','A',60,'a',1);source(s,'HOUR','A',3600,'b',1)
        source(s,'RANGE','A',120,'c',1);source(s,'RANGE','B',600,'d',1)
        source(s,'PERMANENT','A',-1,'e',1);source(s,'UNKNOWN','A',0,'f',1)
        setup(s,{request('RANGE','A'),request('RANGE','B'),request('GONE','A')})
        U.SortBy('duration')
        assert(bbPartyRows[1].key=='MINUTE' and bbPartyRows[2].key=='RANGE')
        assert(bbPartyRows[3].key=='HOUR' and bbPartyRows[4].key=='PERMANENT')
        assert(bbPartyRows[5].key=='GONE' and bbPartyRows[6].key=='UNKNOWN')
        U.SortBy('duration')
        return bbPartyRows[1].key=='PERMANENT' and bbPartyRows[2].key=='HOUR'
            and bbPartyRows[3].key=='RANGE' and bbPartyRows[4].key=='MINUTE'
            and bbPartyRows[5].key=='GONE' and bbPartyRows[6].key=='UNKNOWN'
    ''')


def test_sort_and_filter_do_not_change_cast_order_and_refresh_keeps_sort(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'LONG','A',600,'a',1);source(s,'SHORT','B',60,'b',1)
        setup(s,{request('LONG','A'),request('SHORT','B')})
        U.SortBy('duration');assert(bbPartyRows[1].key=='SHORT')
        bbPartyQuery='long';U.FilterDashboard();assert(#bbPartyRows==1)
        U.Refresh(false);U.ClearSearch()
        return bbPartyRows[1].key=='SHORT'
            and U.preset.requests[1].group=='LONG' and U.preset.requests[2].group=='SHORT'
    ''')


def test_search_placeholder_cannot_cover_input_and_headers_dispatch_sort():
    menu = (ROOT / 'buffbot/BuffBot.menu').read_text(encoding='utf-8')
    dashboard = menu[menu.index('-- Recipient-first party planner'):]
    assert dashboard.index('name "bpSearchHint"') < dashboard.index('name "bpSearch"')
    assert 'action "BfBot.PartyUI.SortBy(\'name\')"' in dashboard
    assert 'action "BfBot.PartyUI.SortBy(\'duration\')"' in dashboard
