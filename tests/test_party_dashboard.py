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
        function findvariant(key,variant)
            for i,r in ipairs(bbPartyRows) do
                if r.key==key and r.variant==variant then bbPartyRowSelection=i;return r end
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


def test_hidden_self_only_target_has_a_restriction_reason(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'SELF','A',60,'a',6,{selfOnly=true})
        setup(s);findrow('SELF');U.DashboardClick(6)
        assert(#U.preset.requests==0 and U.DashboardCell(bbPartyRowSelection,2)==nil)
        U.ToggleCell(findrow('SELF'),'B')
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


def test_summary_groups_the_same_plan_and_single_party_cast(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',2)
        source(s,'BLESS','A',60,'b',1,{aoe=true})
        setup(s);findrow('BUFF');U.DashboardClick(6)
        findrow('BLESS');U.DashboardClick(5)
        local headings,spells=0,0
        for _,row in ipairs(bbPartySummary) do
            if row.heading then headings=headings+1 end
            if row.request then spells=spells+1;assert(row.planIndex~=nil) end
        end
        return headings==3 and spells==2 and U.plan.used.b==1
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
        -- Packed display slots retain the actual recipient identity.
        assert(findrow('SELF').cells[1].target=='A')
        assert(findrow('SELF').cells[2].target=='B')
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


def test_variants_are_independent_recipient_rows_with_shared_parent_uses(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        local variants={{resref='ABJ',name='Immunity: Abjuration',icon='ABJICON'},
            {resref='DIV',name='Immunity: Divination',icon='DIVICON'}}
        source(s,'IMMUNITY','A',0,'a',2,{selfOnly=true,variants=variants,variantDurations={ABJ=120,DIV=60}})
        source(s,'IMMUNITY','B',0,'b',2,{selfOnly=true,variants=variants,variantDurations={ABJ=240,DIV=180}})
        s.groups.IMMUNITY.name='Spell Immunity'
        setup(s)
        assert(#bbPartyRows==2)
        local abj=findvariant('IMMUNITY','ABJ')
        assert(abj.name=='Spell Immunity — Abjuration' and abj.icon=='ABJICON')
        U.DashboardClick(5)
        findvariant('IMMUNITY','DIV');U.DashboardClick(6)
        assert(#U.preset.requests==2 and U.preset.requests[1].var=='ABJ' and U.preset.requests[2].var=='DIV')
        assert(U.plan.used.a==1 and U.plan.used.b==1)
        assert(findvariant('IMMUNITY','ABJ').cells[1].checked)
        assert(not findvariant('IMMUNITY','ABJ').cells[2].checked)
        assert(findvariant('IMMUNITY','DIV').cells[2].checked)
        assert(not findvariant('IMMUNITY','DIV').cells[1].checked)
        assert(bbPartyRequests[1].name=='Spell Immunity — Abjuration')
        assert(bbPartyRequests[2].name=='Spell Immunity — Divination')
        local saved=P.Validate(U.state)
        local queue=P.BuildQueue(s,saved.presets[1].requests)
        return #queue==2 and queue[1].spell=='IMMUNITY' and queue[1].var=='ABJ'
            and queue[2].spell=='IMMUNITY' and queue[2].var=='DIV'
            and queue[1].target=='self' and queue[2].target=='self'
    ''')


def test_different_schools_on_one_recipient_do_not_toggle_or_clear_each_other(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'CHOICE','A',0,'a',3,{selfOnly=true,variants={{resref='FIRE'},{resref='COLD'}}})
        setup(s,{request('CHOICE','A',nil,'FIRE'),request('CHOICE','A',nil,'FIRE'),request('CHOICE','A',nil,'COLD')})
        findvariant('CHOICE','FIRE');U.DashboardClick(5)
        assert(#U.preset.requests==1 and U.preset.requests[1].var=='COLD')
        findvariant('CHOICE','FIRE');U.DashboardClick(5)
        findvariant('CHOICE','COLD');U.DashboardClick(11)
        return #U.preset.requests==1 and U.preset.requests[1].var=='FIRE'
    ''')


def test_variant_reservations_block_other_schools_without_losing_existing_choices(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'CHOICE','A',0,'a',1,{selfOnly=true,variants={{resref='FIRE'},{resref='COLD'}}})
        setup(s);findvariant('CHOICE','FIRE');U.DashboardClick(5)
        local cold=findvariant('CHOICE','COLD')
        assert(cold.uses=='0/1' and not cold.cells[1].available and not cold.cells[1].checked)
        U.DashboardClick(5)
        return #U.preset.requests==1 and U.plan.used.a==1 and U.preset.requests[1].var=='FIRE'
    ''')


def test_unavailable_or_unconfigured_saved_variants_remain_distinct_and_removable(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'CHOICE','A',0,'a',1,{variants={{resref='FIRE'}}})
        setup(s,{request('CHOICE','A',nil,'REMOVED'),request('CHOICE','B')})
        assert(#bbPartyRows==3 and U.plan.missing==2)
        assert(findvariant('CHOICE','REMOVED').cells[1].checked)
        assert(findvariant('CHOICE',nil).cells[2].checked)
        findvariant('CHOICE','REMOVED');U.DashboardClick(11)
        findvariant('CHOICE',nil);U.DashboardClick(11)
        return #U.preset.requests==0 and #bbPartyRows==1
    ''')


def test_missing_parent_keeps_separate_saved_variant_rows(dashboard):
    assert dashboard.execute('''
        setup(snapshot(),{request('GONE','A',nil,'FIRE'),request('GONE','B',nil,'COLD')})
        assert(#bbPartyRows==2)
        findvariant('GONE','FIRE');U.DashboardClick(11)
        return #U.preset.requests==1 and U.preset.requests[1].var=='COLD'
    ''')


def test_variant_source_popup_describes_parent_pool_and_child_duration(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'CHOICE','A',0,'a',2,{variants={{resref='FIRE',name='Fire'}},variantDurations={FIRE=180}})
        setup(s);U.OpenChoices('sources','CHOICE','FIRE')
        assert(bbPartyChoiceTitle=='Sources: CHOICE — Fire')
        assert(bbPartyChoiceHint:find('same parent spell uses',1,true))
        assert(bbPartyChoices[1].name=='Caster: A / 3.0m / Uses: 2/2')
        for _,row in ipairs(bbPartyChoices) do assert(row.kind~='variant') end
        assert(bbPartyChoices[#bbPartyChoices].name=='Hide spell and all variants')
        bbPartyChoiceSelection=#bbPartyChoices;U.Choose()
        return #bbPartyRows==0 and U.state.hidden.CHOICE==1
    ''')


def test_search_resets_dashboard_scroll_but_cached_refresh_does_not(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',1)
        setup(s);local resets={}
        EEex_Menu_GetItem=function(name)
            return {scrollbar=setmetatable({},{__newindex=function(_,key,value)
                assert(key=='top' and value==0);resets[#resets+1]=name
            end})}
        end
        bbPartyQuery='buff';U.Tick()
        assert(#resets==1 and resets[1]=='bpDashboard')
        U.Tick();U.Refresh(false);assert(#resets==1)
        U.ClearSearch();assert(#resets==2)
        U.SortBy('duration');assert(#resets==3)
        U.SetRecipient(1)
        return #resets==4 and #U.preset.requests==0
    ''')


def test_order_inline_actions_follow_selected_request_after_reordering(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'FIRST','A',60,'a',1);source(s,'LAST','B',120,'b',1)
        setup(s,{request('FIRST','A'),request('LAST','B')})
        bbPartyRequestSelection=1;rowNumber=99
        assert(not U.CanMove(1,-1) and U.CanMove(1,1))
        U.OrderClick(8)
        assert(U.preset.requests[2].group=='FIRST' and bbPartyRequestSelection==2)
        assert(not U.CanMove(2,1))
        U.OrderClick(7)
        assert(U.preset.requests[1].group=='FIRST' and bbPartyRequestSelection==1)
        U.OrderClick(9)
        return #U.preset.requests==1 and U.preset.requests[1].group=='LAST'
    ''')


def test_caster_dropdown_keeps_auto_and_respects_other_requests_reservations(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'BUFF','A',120,'a',1);source(s,'BUFF','B',60,'b',1)
        source(s,'OTHER','B',60,'b',1)
        setup(s,{request('BUFF','A'),request('OTHER','B','B')})
        bbPartyRequestSelection=1;U.OrderClick(5)
        assert(U.OrderCaster(1)=='Auto (A)' and U.OrderDuration(1)=='2.0m')
        assert(bbPartyChoices[1].kind=='caster' and bbPartyChoices[1].value==false)
        assert(bbPartyChoices[2].value=='A' and bbPartyChoices[2].kind=='caster')
        assert(bbPartyChoices[3].value=='B' and bbPartyChoices[3].kind=='info')
        bbPartyChoiceSelection=2;U.Choose()
        assert(U.preset.requests[1].source=='A' and U.preset.requests[2].source=='B')
        bbPartyRequestSelection=1;U.OrderClick(5);bbPartyChoiceSelection=1;U.Choose()
        return U.preset.requests[1].source==nil and U.plan.missing==0
    ''')


def test_caster_dropdown_enforces_self_only_and_variant_eligibility(dashboard):
    assert dashboard.execute('''
        local s=snapshot()
        source(s,'SELF','A',60,'a',1,{selfOnly=true})
        source(s,'SELF','B',120,'b',1,{selfOnly=true})
        setup(s,{request('SELF','B')})
        U.OpenCaster(1)
        assert(bbPartyChoices[2].value=='A' and bbPartyChoices[2].kind=='info')
        assert(bbPartyChoices[3].value=='B' and bbPartyChoices[3].kind=='caster')
        source(s,'CHOICE','A',60,'c',1,{variants={{resref='FIRE'}}})
        source(s,'CHOICE','B',60,'d',1,{variants={{resref='COLD'}}})
        U.preset.requests={request('CHOICE','B',nil,'COLD')};U.Refresh(false);U.OpenCaster(1)
        return bbPartyChoices[2].kind=='info' and bbPartyChoices[3].kind=='caster'
    ''')


def test_caster_choice_rechecks_live_availability_and_ignores_stale_preset(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',1);source(s,'BUFF','B',120,'b',1)
        setup(s,{request('BUFF','A')});U.OpenCaster(1)
        s.pools.b=0;U.SetCaster('B')
        assert(U.preset.requests[1].source==nil and U.plan.missing==0)
        s.pools.b=1;U.OpenCaster(1)
        local old=U.preset;U.state.presets[2]={name='Second',requests={request('BUFF','B')}}
        U.state.active=2;U.SetCaster('B')
        return old.requests[1].source==nil and U.preset.requests[1].source==nil
    ''')


def test_summary_portraits_and_inline_controls_map_back_to_exact_requests(dashboard):
    assert dashboard.execute('''
        U.Portrait=function(slot) return slot==0 and 'PA' or 'PB' end
        local s=snapshot();source(s,'BUFF','A',60,'a',2);s.groups.BUFF.icon='SPELLICON'
        setup(s,{request('BUFF','A'),request('BUFF','B')})
        local heading,spell
        for i,row in ipairs(bbPartySummary) do
            if row.heading and row.name=='B' then heading=i end
            if row.request and row.request.target=='B' then spell=i end
        end
        assert(U.SummaryPortrait(heading,1)=='PB' and U.SummaryPortrait(heading,2)=='')
        assert(bbPartySummary[spell].icon=='SPELLICON' and U.SummaryDuration(spell)=='1.0m')
        bbPartySummarySelection=heading;U.SummaryClick(5);assert(#U.preset.requests==2)
        bbPartySummarySelection=spell;rowNumber=99;U.SummaryClick(3)
        assert(U.choiceRequest.target=='B' and bbPartyChoiceHint=='Recipient: B')
        bbPartySummarySelection=spell;U.SummaryClick(5)
        return #U.preset.requests==1 and U.preset.requests[1].target=='A'
    ''')


def test_caster_popup_anchors_to_scrolled_row_and_stays_on_screen(dashboard):
    assert dashboard.execute('''
        local s=snapshot();source(s,'BUFF','A',60,'a',1)
        setup(s,{request('BUFF','A')})
        Infinity_GetScreenSize=function() return 1280,720 end
        EEex_Menu_GetItemArea=function() return 50,100,1100,500 end
        EEex_Menu_GetItem=function() return {scrollbar={top=84}} end
        local areas={}
        Infinity_SetArea=function(name,x,y,w,h) areas[name]={x,y,w,h} end
        U.OpenCaster(1,'bpPlan',.55,12)
        local bg=areas.bpChoicesBg
        return bg[1]>=8 and bg[1]+bg[3]<=1272 and bg[2]>=8 and bg[2]+bg[4]<=712
    ''')


def test_plan_views_have_headers_inline_controls_and_no_coverage_or_bottom_toolbar():
    menu=(ROOT / 'buffbot/BuffBot.menu').read_text(encoding='utf-8')
    party=menu.split('-- Recipient-first party planner',1)[1]
    for obsolete in ('bpCoverage','bpSource','bpUp','bpDown','bpRemove','bpShowAll'):
        assert f'name "{obsolete}"' not in party
    for name in ('bpOrderHeadCaster','bpOrderHeadRecipient','bpSummaryHeadCaster','bpSummaryHeadDuration'):
        assert f'name "{name}"' in party
    assert 'OrderClick(cellNumber)' in party and 'SummaryClick(cellNumber)' in party
