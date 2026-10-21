"""HUD shortcuts dispatch party plans directly, without any character ability."""
from pathlib import Path
import pytest
from lupa.luajit21 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture
def hud():
 r=LuaRuntime(unpack_returned_tuples=True)
 r.execute('''
  BfBot={UI={},L10N={Get=function(s)return s end}};stack={WORLD_ACTIONBAR=true};areas={};offsets={};notices={};starts={}
  state={fast=1,presets={[1]={name='Battle',requests={{spell='BUFF'}}},[5]={name='Travel',requests={{spell='OTHER'}}}}}
  worldScreen={};e={GetActiveEngine=function()return worldScreen end}
  Infinity_IsMenuOnStack=function(n)return stack[n] and 1 or 0 end
  Infinity_PushMenu=function(n)stack[n]=true end;Infinity_PopMenu=function(n)stack[n]=nil end
  Infinity_GetScreenSize=function()return 1280,720 end
  Infinity_SetArea=function(n,x,y,w,h)areas[n]={x,y,w,h}end
  Infinity_SetOffset=function(n,x,y)offsets[n]={x,y}end
  EEex_Menu_Find=function()return nil end
  EEex_Menu_GetArea=function()return -1300,602,3904,118 end
  BfBot.Plan={GetState=function()return state end,Snapshot=function()return{}end,
   BuildQueue=function(s,requests)if missing then return nil end;return requests end}
  BfBot.Exec={GetState=function()return busy and 'running' or 'idle'end,
   Start=function(q,mode,p)starts[#starts+1]={queue=q,mode=mode};return true end}
  BfBot._Display=function(m)notices[#notices+1]=m end;BfBot.Share={}
 ''')
 r.execute((ROOT/'buffbot/BfBotUI.lua').read_text(encoding='utf-8'))
 return r


def test_oversize_ui_plus_bar_button_and_popup_stay_on_screen(hud):
 assert hud.execute('''
 BfBot.UI._OpenActionbarBtn();BfBot.UI._ToggleQuickMenu()
 local o=offsets.BUFFBOT_ACTIONBAR;local a=areas.bbQuickBody
 return o[1]>=0 and o[1]+56<=1280 and o[2]+56<=720
  and a[1]>=0 and a[2]>=0 and a[1]+a[3]<=1280 and a[2]+a[4]<=720
 ''')


def test_right_click_toggles_and_direct_cast_uses_stable_preset_id(hud):
 assert hud.execute('''
 BfBot.UI._OpenActionbarBtn();BfBot.UI._ToggleQuickMenu();assert(stack.BUFFBOT_QUICK_PRESETS)
 BfBot.UI._ToggleQuickMenu();assert(not stack.BUFFBOT_QUICK_PRESETS)
 BfBot.UI._ToggleQuickMenu();assert(BfBot.UI._QuickPresetName(2)=='Travel')
 BfBot.UI._CastQuickPreset(2)
 return not stack.BUFFBOT_QUICK_PRESETS and #starts==1 and starts[1].mode==4
  and starts[1].queue==state.presets[5].requests
 ''')


@pytest.mark.parametrize('change',['busy=true','missing=true','state.presets[1]={name="Replacement",requests={}}'])
def test_busy_unavailable_or_replaced_preset_never_starts(hud,change):
 assert hud.execute('BfBot.UI._OpenActionbarBtn();BfBot.UI._ToggleQuickMenu();'+change+';BfBot.UI._CastQuickPreset(1);return #starts==0 and not stack.BUFFBOT_QUICK_PRESETS')


def test_hud_is_only_visible_in_world_and_keeps_tick_companion(hud):
 assert hud.execute('''
 BfBot.UI._OpenActionbarBtn();assert(BfBot.UI._ActionbarVisible())
 BfBot.UI._CloseActionbarBtn();stack.WORLD_ACTIONBAR=nil
 assert(stack.BUFFBOT_ACTIONBAR and not BfBot.UI._ActionbarVisible())
 BfBot.UI._ToggleQuickMenu();return not stack.BUFFBOT_QUICK_PRESETS
 ''')



def test_stock_button_docks_at_bottom_even_with_expanded_log(hud):
 assert hud.execute("""
 EEex_Menu_GetArea=function()return 200,652,800,68 end
 stack.WORLD_MESSAGES=true
 BfBot.UI._PumpActionbarBtn()
 return offsets.BUFFBOT_ACTIONBAR[1]==1004 and offsets.BUFFBOT_ACTIONBAR[2]==664
 """)


@pytest.mark.parametrize('last_x,first_x,expected_x',[(900,288,944),(1240,628,568)])
def test_ui_plus_docks_beside_controls_including_right_aligned_bar(hud,last_x,first_x,expected_x):
 hud.globals().last_x=last_x;hud.globals().first_x=first_x
 assert hud.execute("""
 RgIsModernHud=1
 EEex_Menu_GetItemArea=function(n)
  if n=='rgActionbarGoldernButton11' then return last_x,676,36,35 end
  if n=='rgActionbarButton1' then return first_x,610,54,54 end
 end
 BfBot.UI._OpenActionbarBtn()
 return offsets.BUFFBOT_ACTIONBAR[1]
 """)==expected_x
 assert hud.execute('return offsets.BUFFBOT_ACTIONBAR[2]')==659


def test_preset_captions_are_inset_and_inside_clickable_plates(hud):
 assert hud.execute("""
 BfBot.UI._OpenActionbarBtn();BfBot.UI._ToggleQuickMenu()
 for i=1,2 do
  local b=areas['bbQuickPreset'..i];local t=areas['bbQuickPreset'..i..'Caption']
  assert(t[1]==b[1]+8 and t[2]==b[2]+3)
  assert(t[1]+t[3]<b[1]+b[3] and t[2]+t[4]<=b[2]+b[4])
 end
 return true
 """)
