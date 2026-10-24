"""Search is a display projection; shortcuts retain the existing queue contract."""
from pathlib import Path

import pytest

from test_ui_selection import ui_lua  # shared real UI/localization runtime


@pytest.fixture
def quick_ui(ui_lua):
    ui_lua.execute('''
        buffbot_isOpen = true
        areas, offsets, starts, notices = {}, {}, {}, {}
        stack = { WORLD_ACTIONBAR = true }
        worldScreen = {}; e = { GetActiveEngine = function() return worldScreen end }
        Infinity_IsMenuOnStack = function(n) return stack[n] and 1 or 0 end
        Infinity_PushMenu = function(n) stack[n] = true end
        Infinity_PopMenu = function(n) stack[n] = nil end
        Infinity_GetScreenSize = function() return 1280, 720 end
        Infinity_GetClockTicks = function() return 1000 end
        Infinity_SetArea = function(n,x,y,w,h) areas[n] = {x,y,w,h} end
        Infinity_SetOffset = function(n,x,y) offsets[n] = {x,y} end
        EEex_Menu_GetArea = function() return 200,652,800,68 end
        BfBot._Display = function(s) notices[#notices+1] = s end
        owner = EEex_Sprite_GetInPortrait(0)
        config = { presets = {
            [1] = {name='Long Buffs', spells={}},
            [5] = {name='Travel', spells={}},
        }}
        rate = 1; busy = false; qc = 2
        BfBot.Persist._GetProtagonist = function() return owner end
        BfBot.Persist.GetConfig = function() return config end
        BfBot.Persist.GetPref = function() return rate end
        BfBot.Persist.SetPref = function(k,v) rate=v end
        BfBot.Persist.GetQuickCast = function() return qc end
        BfBot.Persist.DrainBuildSkips = function() return {} end
        BfBot.Persist.BuildQueueFromPreset = function(index)
            builtIndex = index
            return {{resref='A'}, {resref='B'}, {resref='C'}}
        end
        BfBot.Exec._log = {}
        BfBot.Exec.GetState = function() return busy and 'running' or 'idle' end
        BfBot.Exec.Start = function(q,mode,index)
            starts[#starts+1]={queue=q, mode=mode, index=index}; return true
        end
        BfBot.UI._T = function() return '{1, 2, 3}' end
        BfBot.Persist._NormalizeSpellRepeat = function(n) return n or 1 end
        buffbot_spellTable = {
            {resref='A',name='Armor',pri=1,on=1,rep=1,hasVariants=0},
            {resref='B',name='Shield',pri=2,on=0,rep=1,hasVariants=0},
            {resref='C',name='Protection [Fire]',pri=3,on=1,rep=1,hasVariants=1},
        }
        BfBot.UI._RestoreSpellSelection()
    ''')
    return ui_lua


@pytest.mark.parametrize('query,expected', [('sHiElD','B'), ('[Fire]','C'), ('%','')])
def test_search_matches_names_literally_without_changing_priorities(quick_ui, query, expected):
    quick_ui.globals().buffbot_searchText = query
    result = quick_ui.execute('''
        BfBot.UI._SearchTick()
        assert(#buffbot_spellTable==3 and buffbot_spellTable[1].pri==1
            and buffbot_spellTable[2].pri==2 and buffbot_spellTable[3].pri==3)
        return buffbot_visibleSpells[1] and buffbot_visibleSpells[1].resref or ''
    ''')
    assert result == expected


@pytest.mark.parametrize('upper,lower', [('ÉCLAIR','éclair'), ('SCHÜTZEN','schützen'),
    ('ŁASKA','łaska'), ('ЗАЩИТА','защита'), ('ЁЛКА','ёлка'), ('保护','保护')])
def test_name_search_folds_supported_localized_scripts(quick_ui, upper, lower):
    assert quick_ui.globals().BfBot.UI._SearchName(upper) == lower


@pytest.mark.parametrize('cell', [1, 2, 6, 8])
def test_filtered_clicks_edit_the_displayed_identity(quick_ui, cell):
    quick_ui.globals().cell = cell
    assert quick_ui.execute('''
        buffbot_searchText='shield'; BfBot.UI._SearchTick()
        local edited
        BfBot.UI.ToggleSpell=function(row) edited=buffbot_spellTable[row].resref end
        BfBot.UI.StepSelectedRepeat=function() edited=buffbot_spellTable[buffbot_selectedRow].resref end
        BfBot.UI.ToggleLock=function(row) edited=buffbot_spellTable[row].resref end
        buffbot_visibleSelectedRow=1
        rowNumber=3 -- deliberately stale engine render row
        BfBot.UI._OnVisibleSpellRowAction(cell)
        return edited=='B' and buffbot_selectedRow==2 and BfBot.UI._spellSel.resref=='B'
    ''')


def test_hidden_selection_disables_actions_and_returns_when_search_cleared(quick_ui):
    assert quick_ui.execute('''
        buffbot_selectedRow=2;BfBot.UI._OnSpellRowAction(3)
        buffbot_searchText='armor';BfBot.UI._SearchTick()
        assert(buffbot_selectedRow==0 and not BfBot.UI._HasSelection())
        BfBot.UI._SelectionSyncTick()
        assert(buffbot_selectedRow==0 and buffbot_visibleSelectedRow==0)
        BfBot.UI.ClearSearch()
        return buffbot_selectedRow==2 and buffbot_visibleSelectedRow==2
            and BfBot.UI._spellSel.resref=='B'
    ''')


def test_refresh_reorder_repairs_widget_projection_by_identity(quick_ui):
    assert quick_ui.execute('''
        buffbot_searchText='i';BfBot.UI._SearchTick()
        buffbot_visibleSelectedRow=1;BfBot.UI._OnVisibleSpellRowAction(3)
        buffbot_spellTable={buffbot_spellTable[3],buffbot_spellTable[1],buffbot_spellTable[2]}
        BfBot.UI._RestoreSpellSelection()
        buffbot_visibleSelectedRow=1 -- stale write from the native widget
        BfBot.UI._SelectionSyncTick()
        return buffbot_selectedRow==3 and buffbot_visibleSelectedRow==2
            and buffbot_spellTable[3].resref=='B'
    ''')


def test_changed_query_or_context_rejects_stale_click(quick_ui):
    assert quick_ui.execute('''
        edited=false;BfBot.UI.ToggleSpell=function() edited=true end
        buffbot_visibleSelectedRow=2;buffbot_searchText='armor'
        BfBot.UI._OnVisibleSpellRowAction(1)
        assert(not edited)
        BfBot.UI._presetIdx=5
        BfBot.UI._OnVisibleSpellRowAction(1)
        return not edited
    ''')


def test_filtering_does_not_reduce_cast_queue(quick_ui):
    assert quick_ui.execute('''
        buffbot_searchText='shield';BfBot.UI._SearchTick()
        BfBot.UI._GetStatusText=function() return '' end
        BfBot.UI.Cast()
        return #buffbot_visibleSpells==1 and #starts==1 and #starts[1].queue==3
            and starts[1].mode==2
    ''')


def test_reorder_with_filter_keeps_hidden_entries_and_locked_positions(quick_ui):
    assert quick_ui.execute('''
        BfBot.UI._RenumberPriorities=function()
            for i,v in ipairs(buffbot_spellTable) do v.pri=i end
        end
        buffbot_searchText='shield';BfBot.UI._SearchTick()
        buffbot_visibleSelectedRow=1;BfBot.UI._OnVisibleSpellRowAction(3)
        BfBot.UI.MoveSpellUp()
        assert(#buffbot_spellTable==3 and buffbot_spellTable[1].resref=='B')
        assert(buffbot_visibleSpells[1].resref=='B' and buffbot_selectedRow==1)
        buffbot_spellTable[2].lock=1
        BfBot.UI.MoveSpellDown()
        return buffbot_spellTable[1].resref=='C' and buffbot_spellTable[2].resref=='A'
            and buffbot_spellTable[3].resref=='B' and buffbot_selectedRow==3
    ''')


def test_hud_popup_uses_sparse_preset_id_without_changing_open_editor(quick_ui):
    assert quick_ui.execute('''
        BfBot.UI._presetIdx=1
        BfBot.UI._OpenActionbarBtn();BfBot.UI._ToggleQuickMenu()
        assert(BfBot.UI._QuickPresetName(2)=='Travel')
        BfBot.UI._CastQuickPreset(2)
        return #starts==1 and builtIndex==5 and starts[1].index==5 and starts[1].mode==2
            and not stack.BUFFBOT_QUICK_PRESETS and BfBot.UI._presetIdx==1
    ''')


@pytest.mark.parametrize('change', ['busy=true', 'config.presets[5]={name="Replacement",spells={}}',
    'owner={m_id=999,name="Replacement"}', 'stack.WORLD_ACTIONBAR=nil'])
def test_hud_refuses_stale_or_busy_dispatch(quick_ui,change):
    quick_ui.execute('BfBot.UI._OpenActionbarBtn();BfBot.UI._ToggleQuickMenu();'+change)
    assert quick_ui.execute('BfBot.UI._CastQuickPreset(2);return #starts==0')


@pytest.mark.parametrize('width,height,modern', [(1280,720,False),(640,360,False),(1280,720,True)])
def test_hud_and_eight_preset_popup_fit_screen(quick_ui,width,height,modern):
    quick_ui.globals().sw=width;quick_ui.globals().sh=height
    quick_ui.globals().RgIsModernHud=1 if modern else 0
    assert quick_ui.execute('''
        Infinity_GetScreenSize=function() return sw,sh end
        EEex_Menu_GetArea=function() return -1300,sh-118,3904,118 end
        EEex_Menu_GetItemArea=function(n)
            if n=='rgActionbarGoldernButton11' then return sw-40,sh-35,36,35 end
            return sw-612,sh-54,54,54
        end
        for i=1,8 do config.presets[i]={name='Preset '..i,spells={}} end
        BfBot.UI._OpenActionbarBtn();BfBot.UI._ToggleQuickMenu()
        local o=offsets.BUFFBOT_ACTIONBAR;local f=areas.bbQuickFrame
        return o[1]>=0 and o[2]>=0 and o[1]+56<=sw and o[2]+56<=sh
            and f[1]>=0 and f[2]>=0 and f[1]+f[3]<=sw and f[2]+f[4]<=sh
    ''')


def test_world_controls_closing_releases_speed_before_stopping(quick_ui):
    assert quick_ui.execute('''
        sequence={}
        BfBot.Fast={run={},Release=function() sequence[#sequence+1]='release' end}
        BfBot.Exec.Stop=function() sequence[#sequence+1]='stop' end
        BfBot.UI._CloseActionbarBtn()
        return sequence[1]=='release' and sequence[2]=='stop'
    ''')


def test_speed_cycle_and_fast_dispatch_preserve_saved_quick_cast(quick_ui):
    assert quick_ui.execute('''
        BfBot.Fast={Start=function(q,m,i) fast={q=q,m=m,i=i};return true end}
        BfBot.UI.CycleFastForward();assert(rate==2)
        BfBot.UI._StartRun({{resref='B'}},qc,5)
        assert(fast.m==2 and fast.i==5 and #starts==0 and qc==2)
        BfBot.UI.CycleQuickCast();assert(qc==2)
        BfBot.UI.CycleFastForward();assert(rate==4)
        BfBot.UI.CycleFastForward();assert(rate==1)
        return BfBot.UI._StartRun({{resref='B'}},qc,5) and starts[1].mode==2
    ''')


def test_fast_refusal_surfaces_localized_error_without_normal_fallback(quick_ui):
    assert quick_ui.execute('''
        rate=2
        BfBot.Fast={Start=function() return false,'reason.exec.fast_unavailable',{reason='multiplayer'} end}
        local started=BfBot.UI._StartRun({{resref='B'}},2,1)
        return not started and #starts==0 and notices[1]==BfBot.L10N.Get('reason.exec.fast_unavailable')
    ''')


def test_manual_add_keeps_classifier_misses_without_borrowing_other_owners_overrides(quick_ui):
    assert quick_ui.execute('''
        config.ovr={['itm:REMOVED:0']=-1}
        BfBot.Scan.GetCastableSpells=function() return {
            ['itm:MISSED:0']={kind='itm',name='Missed power',count=1,class={isBuff=false}},
            ['itm:OTHER:0']={kind='itm',name='Other character override',count=1,
                class={isBuff=false,overridden=true}},
            ['itm:REMOVED:0']={kind='itm',name='Removed power',count=1,
                class={isBuff=false,overridden=true}},
            ['itm:SELECT:0']={kind='itm',name='Selection power',count=1,requiresChoice=1,
                class={isBuff=false}},
        } end
        BfBot.UI._BuildPickerList()
        local found={}
        for _,row in ipairs(buffbot_pickerSpells) do found[row.resref]=row end
        return found['itm:MISSED:0']~=nil and found['itm:REMOVED:0']~=nil
            and found['itm:OTHER:0']==nil
            and found['itm:SELECT:0'].durCatText==BfBot.L10N.Get('ui.manual_only')
    ''')


def test_quick_popup_frame_is_drawn_after_themed_background_and_overlay():
    # The frame is a thin rail with a transparent middle, so it draws last and
    # keeps its whole corner. The old frame filled its rect and had to hide
    # under the parchment; see the comment beside the main panel's border.
    source=(Path(__file__).resolve().parents[1]/'buffbot/BuffBot.menu').read_text(encoding='utf-8')
    assert source.index('name "bbQuickBg"') < source.index('name "bbQuickOverlay"')
    assert source.index('name "bbQuickOverlay"') < source.index('name "bbQuickFrame"')


def test_empty_quick_preset_discards_build_skip_buffer(quick_ui):
    assert quick_ui.execute('''
        pending={}
        BfBot.Persist.DrainBuildSkips=function() local old=pending;pending={};return old end
        BfBot.Persist.BuildQueueFromPreset=function() pending={'Unavailable'};return {} end
        BfBot.UI._ToggleQuickMenu();BfBot.UI._CastQuickPreset(1)
        return #pending==0 and #starts==0 and #notices==1
    ''')
