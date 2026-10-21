"""Presentation contracts, native fallbacks and generated-resource integrity."""
import hashlib
import json
import struct
import zlib
from pathlib import Path

import pytest
from test_party_dashboard import dashboard
from test_party_planner import lua

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def visual(dashboard):
    dashboard.execute((ROOT / 'buffbot/BfBotVD.lua').read_text(encoding='utf-8'))
    dashboard.execute((ROOT / 'buffbot/BfBotVis.lua').read_text(encoding='utf-8'))
    dashboard.execute('''
      V=BfBot.Visual;P.GetState=function()return nil end;styles={};fontcolors={};areas={};stack={}
      Infinity_IsMenuOnStack=function(n) return stack[n] and 1 or 0 end
      Infinity_PushMenu=function(n) stack[n]=true;pushed[#pushed+1]=n end
      Infinity_PopMenu=function(n) stack[n]=nil end
      Infinity_GetScreenSize=function() return screenW or 1280,screenH or 720 end
      Infinity_SetArea=function(n,x,y,w,h) areas[n]={x,y,w,h} end
      EEex_Menu_GetItem=function(n) return {scrollbar={top=0}} end
      EEex_Menu_Find=function(n) return {} end
      EEex_Menu_GetItemArea=function(n) return 1200,650,100,30 end
      EEex_Resource_Fetch=function(ref,ext) return {} end
    ''')
    return dashboard


@pytest.mark.parametrize('skin,expected', [(None, 2), (-1, 2), (99, 2), ('bg1', 2), (0, 0), (1, 1), (2, 2), (3, 3)])
def test_skin_follows_ui_plus_with_bg1_fallback(visual, skin, expected):
    visual.globals().RgUISkin = skin
    assert visual.eval('V.SkinIndex()') == expected


def test_missing_ui_plus_uses_existing_functional_panel(visual):
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      EEex_Resource_Fetch=function() return nil end
      U.Open()
      return pushed[#pushed]=='BUFFBOT_PARTY' and not V.active
    ''')




def test_present_ui_plus_opens_new_panel(visual):
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      U.Open();return pushed[#pushed]=='BUFFBOT_RX' and V.active==true
    ''')


def test_repeated_open_does_not_duplicate_native_menu_stack(visual):
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      for i=1,100 do V.Open() end
      return #pushed==1 and stack.BUFFBOT_RX and V.active
    ''')


@pytest.mark.parametrize('absent', [None, 0, False])
def test_main_toggle_closes_redesign_and_its_popup(visual,absent):
    visual.execute((ROOT/'buffbot/BfBotLoc.lua').read_text(encoding='utf-8'))
    visual.execute((ROOT/'buffbot/BfBotUI.lua').read_text(encoding='utf-8'))
    visual.globals().absentStackResult=absent
    assert visual.execute('''
      Infinity_IsMenuOnStack=function(n) if stack[n] then return 1 end;return absentStackResult end
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      BfBot.UI.Toggle();assert(stack.BUFFBOT_RX)
      stack.BUFFBOT_RX_POPMENU=true;V.popup='menu'
      BfBot.UI.Toggle()
      return #pushed==1 and not stack.BUFFBOT_RX and not stack.BUFFBOT_RX_POPMENU and not V.active
    ''')


@pytest.mark.parametrize('missing', ['BFBTAB', 'BFBRAH'])
def test_partial_ui_plus_uses_functional_fallback(visual,missing):
    visual.globals().missingResource=missing
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      EEex_Resource_Fetch=function(ref) if ref~=missingResource then return {} end end
      U.Open();return pushed[#pushed]=='BUFFBOT_PARTY' and not V.active
    ''')


@pytest.mark.parametrize('width,height,wide,canvas', [(1280,720,False,(1280,720)), (1600,900,False,(1280,720)), (1920,1000,False,(1280,720)), (1920,1008,False,(1280,720)), (1600,1080,False,(1280,720)), (1920,1080,True,(1920,1080)), (2560,1440,True,(1920,1080))])
def test_two_fixed_layouts_are_centered_and_do_not_stretch(visual,width,height,wide,canvas):
    visual.globals().screenW=width;visual.globals().screenH=height
    result=visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      V.active=true;V.Layout()
      return V.wide,V.w,V.h,V.x,V.y,areas.rxCast[1]+areas.rxCast[3]
    ''')
    assert result == (wide,*canvas,(width-canvas[0])//2,(height-canvas[1])//2,(width+canvas[0])//2-60)


def test_font_roles_and_native_abgr_palette(visual):
    assert visual.execute('''
      RgUISkin=0;V.InstallStyles()
      return fontcolors[V.palette.text]=='FFC0DFEC'
        and styles.bvr_text.font=='RGFONT' and styles.bvr_small.font=='RGFONT'
        and styles.bvr_tab.font=='RGTRAJ' and styles.bvr_title.font=='RGTRAJ'
    ''')


def test_numeric_zero_does_not_label_targeted_buffs_self_only(visual):
    assert visual.execute('''
      local s=snapshot();local a=source(s,'BUFF','A',60,'a',2)
      a.selfOnly=false;a.row.isSelfOnly=0;setup(s)
      assert(not V.RowName(1):find('Self only',1,true))
      a.row.isSelfOnly=1
      return V.RowName(1):find('Self only',1,true)~=nil
    ''')


def test_family_headers_cannot_spend_or_clear_parent_uses(visual):
    assert visual.execute('''
      local s=snapshot();source(s,'FAMILY','A',60,'parent',2,{variants={{resref='ABJ',name='Abjuration'},{resref='DIV',name='Divination'}}})
      V.active=true;setup(s,{request('FAMILY','A',nil,'ABJ')})
      local i;for n,r in ipairs(bbPartyRows) do if r.heading then i=n;break end end
      assert(i and V.RowDuration(i)=='' and V.Chip(i,1)==nil)
      bbPartyRowSelection=i;U.DashboardClick(5);U.DashboardClick(11)
      return #U.preset.requests==1 and U.plan.used.parent==1
    ''')


def test_menus_clamp_right_and_flip_above_bottom_trigger(visual):
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      V.active=true;V.Layout();U.OpenChoices('rest');V.LayoutPopup()
      local r=V.popupRect
      return V.popupAbove and r[1]>=60 and r[1]+r[3]<=1220
        and r[2]>=40 and r[2]+r[4]<=680
    ''')


def test_opening_dialog_replaces_menu_instead_of_stacking(visual):
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      V.active=true;V.Layout();U.OpenChoices('presets');U.OpenRename()
      return not stack.BUFFBOT_RX_POPMENU and stack.BUFFBOT_RX_DIALOG and V.rename
    ''')


def test_new_preset_cancel_keeps_preset_and_invalid_save_still_closes(visual):
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      V.active=true;V.Layout();U.CreatePreset();local active=U.state.active
      local name=U.preset.name;V.ClosePopup()
      assert(U.state.active==active and U.state.presets[active].name==name)
      U.OpenRename();bbPartyName='  ';U.SaveName()
      return U.preset.name==name and not stack.BUFFBOT_RX_DIALOG
    ''')


def test_unavailable_pin_is_visible_and_is_not_changed_to_auto(visual):
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s,{request('BUFF','A','missing')})
      return V.CasterName(1)=='Pinned caster unavailable' and V.RequestError(1)
        and U.preset.requests[1].source=='missing'
    ''')


def test_empty_search_recovery_preserves_requests(visual):
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s,{request('BUFF','A')})
      bbPartyQuery='no matching buff';U.FilterDashboard();assert(V.Empty())
      V.EmptyAction()
      return #U.preset.requests==1 and #bbPartyRows>0 and bbPartyQuery==''
    ''')


@pytest.mark.parametrize('name', ['Éléonore-longue', 'Großinquisitor'])
def test_long_french_and_german_names_keep_valid_utf8_and_full_tooltip(visual,name):
    visual.globals().longName=name
    short,full=visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      bbPartyRows[1].cells[1].name=longName
      return V.ChipName(1,1),V.ChipName(1,1,true)
    ''')
    assert len(short)<=11 and short.endswith('...')
    assert full==name


def test_generated_assets_are_an_exact_hashed_allowlist():
    manifest=json.loads((ROOT/'buffbot/BfBotVA.json').read_text())
    assets=ROOT/'buffbot/visual'
    assert {p.name for p in assets.iterdir()} == set(manifest['files'])
    for name in manifest['files']:
        data=(assets/name).read_bytes()
        assert hashlib.sha256(data).hexdigest()==manifest['sha256'][name]
        if name.endswith('.PVRZ'):
            raw=zlib.decompress(data[4:])
            assert len(raw)==struct.unpack_from('<I',data)[0]
            height,width=struct.unpack_from('<II',raw,24)
            assert 4<=width<=1024 and 4<=height<=1024
            assert width&(width-1)==0 and height&(height-1)==0
            assert len(raw)==52+width*height
        if name.endswith('.BAM'):
            assert data[:8]==b'BAM V2  '
            nf,nc,nb,fo,co,bo=struct.unpack_from('<6I',data,8)
            assert nf>0 and nc>0 and nb>0 and fo==32
            assert len(data)==bo+28*nb
            for i in range(nc):
                count,start=struct.unpack_from('<HH',data,co+4*i)
                assert count>0 and start+count<=nf
            for i in range(nb):
                page,x,y,w,h,tx,ty=struct.unpack_from('<7I',data,bo+28*i)
                assert w>0 and h>0 and (assets/f'MOS{page:04d}.PVRZ').exists()
    arrow=(assets/'BFBARROW.BAM').read_bytes()
    assert struct.unpack_from('<2I',arrow,8)==(4,2)
    assert manifest['glyphCycles']['dropdown']!=manifest['glyphCycles']['close-dialog']


def test_menu_uses_parent_cell_dispatch_and_native_glyph_art():
    src=(ROOT/'buffbot/BfBotRx.menu').read_text()
    assert 'DashboardClick(cellNumber)' in src and 'OrderClick(cellNumber)' in src
    assert 'SummaryClick(cellNumber)' in src and 'if cellNumber==3 then' in src
    assert 'bam "BFBARROW"' in src and 'bam "BFBGLYPH"' in src
    assert 'text color lua' not in src
    for name in ['rxDismiss','rxMenuDismiss','rxDialogDismiss']:
        assert 'button\n{\n name "'+name+'"' in src
    assert 'text lua "\'X\'"' not in src and 'text lua "\'^\'"' not in src


def test_blank_clicks_are_absorbed_without_dismissal():
    src=(ROOT/'buffbot/BfBotRx.menu').read_text()
    for prefix in ['rx','rxMenu','rxDialog']:
        # Escape remains bound, with no mouse hit region on the dismissal item.
        start=src.index(' name "'+prefix+'Dismiss"')
        item=src[start:src.index('\n}',start)]
        assert 'area 0 0 0 0' in item and 'on escape' in item
        start=src.index(' name "'+prefix+'Shield"')
        shield=src[start:src.index('\n}',start)]
        assert 'area 0 0 99999 99999' in shield and 'action "BfBot.Visual.AbsorbClick()"' in shield


def test_uses_warning_retains_eligible_chips_and_clears_when_a_reservation_is_removed(visual):
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      findrow('BUFF');U.DashboardClick(5);findrow('BUFF')
      local i=bbPartyRowSelection
      assert(V.UsesExhausted(i) and V.Chip(i,2).target=='B')
      assert(not V.ChipChecked(i,2) and not V.ChipError(i,2))
      assert(V.ChipDuration(i,2)=='1.0m')
      U.DashboardClick(5);findrow('BUFF')
      return not V.UsesExhausted(bbPartyRowSelection)
    ''')


@pytest.mark.parametrize('mode', ['presets','settings','rest'])
def test_dropdown_trigger_toggles_closed_without_changing_the_plan(visual,mode):
    visual.globals().mode=mode
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s,{request('BUFF','A')})
      V.active=true;V.Layout();V.ToggleChoices(mode)
      assert(V.popup=='menu' and stack.BUFFBOT_RX_POPMENU)
      V.LayoutPopup()
      assert(areas.rxMenuTrigger[1]==1200 and areas.rxMenuTrigger[2]==650)
      assert(areas.rxMenuTrigger[3]==100 and areas.rxMenuTrigger[4]==30)
      V.ToggleChoices(mode)
      return V.popup==nil and not stack.BUFFBOT_RX_POPMENU and #U.preset.requests==1
    ''')


def test_new_menu_has_no_opaque_outer_canvas_and_repeats_trigger_hit_region():
    src=(ROOT/'buffbot/BfBotRx.menu').read_text()
    assert 'name "rxScene"' not in src
    assert 'name "rxMenuTrigger"' in src
    for mode in ['presets','settings','rest']:
        assert "BfBot.Visual.ToggleChoices('"+mode+"')" in src
    assert 'BfBot.Visual.UsesExhausted(rowNumber)' in src


@pytest.mark.parametrize('width,height', [(1280,720),(1920,1080)])
def test_footer_controls_have_separate_bounds_and_dragon_close_is_outside_tabs(visual,width,height):
    visual.globals().screenW=width;visual.globals().screenH=height
    assert visual.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      RgUISkin=0;V.Layout()
      local add,hidden,cast=areas.rxAdd,areas.rxHidden,areas.rxCast
      return add[1]+add[3]+12==hidden[1]
        and hidden[1]+hidden[3]+12==cast[1]
        and areas.rxOptions[1]+areas.rxOptions[3]<areas.rxClose[1]
        and areas.rxClose[1]==V.x+V.w-48
        and areas.rxClose[2]==V.y+22
    ''')


@pytest.mark.parametrize('skin',[0,1,2,3])
def test_private_theme_works_without_any_ui_plus_resource(visual,skin):
 visual.globals().chosen=skin
 assert visual.execute("""
  local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s);U.state.skin=chosen
  RgUISkin=nil;EEex_Resource_Fetch=function(ref)if ref:sub(1,2)~='RG' then return{}end end
  assert(V.Available());U.Open();V.Layout()
  return V.SkinIndex()==chosen and styles.bvr_text.font=='NORMAL' and styles.bvr_header.font=='STONESML'
 """)


def test_theme_picker_preserves_ui_plus_indicator_and_saves_local_choice(visual):
 assert visual.execute("""
  setup(snapshot(),{});RgUISkin=3;assert(V.SkinIndex()==3)
  U.OpenChoices('theme');bbPartyChoiceSelection=4;U.Choose()
  assert(U.state.skin==2 and RgUISkin==3 and V.SkinIndex()==2)
  assert(P.Validate(U.state).skin==2)
  U.OpenChoices('theme');bbPartyChoiceSelection=1;U.Choose()
  return U.state.skin==nil and V.SkinIndex()==3
 """)



def test_skin_lookup_is_safe_before_game_initialization(visual):
 assert visual.execute("P.GetState=function()error('No game may be read during menu parse')end;RgUISkin=nil;return V.SkinIndex()==2")
