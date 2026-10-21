from pathlib import Path
import pytest
from test_party_dashboard import dashboard
from test_party_planner import lua

ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture
def plans(dashboard):
    dashboard.execute((ROOT/'buffbot/BfBotIO.lua').read_text(encoding='utf-8'))
    dashboard.execute('I=BfBot.PlanIO')
    return dashboard

def test_plan_roundtrip_preserves_name_order_pins_variants_disabled_and_missing_targets(plans):
    assert plans.execute('''
      local preset={name='Éveryday / Mage',requests={request('spl:WARD','dv:ANOMEN','dv:JAHEIRA','ALT'),request('itm:BOOT12:0','name:Missing')}}
      preset.requests[2].on=0
      local raw=assert(I.Encode(preset));local copy=assert(I.Decode(raw))
      assert(copy.name==preset.name and #copy.requests==2)
      assert(copy.requests[1].source=='dv:JAHEIRA' and copy.requests[1].var=='ALT')
      return copy.requests[2].target=='name:Missing' and copy.requests[2].on==0 and copy.requests[2].group=='itm:BOOT12:0'
    ''')

@pytest.mark.parametrize('payload',['return os.execute("bad")','BUFFBOT-PARTY-PLAN\t2\nN\t41\n','BUFFBOT-PARTY-PLAN\t1\nN\t4100\n','BUFFBOT-PARTY-PLAN\t1\nN\t4\n','BUFFBOT-PARTY-PLAN\t1\nN\t41\nR\t41\t42\t\t\t7\n'])
def test_import_rejects_invalid_or_executable_data(plans,payload):
    plans.globals().payload=payload
    assert plans.eval('I.Decode(payload)==nil')

@pytest.mark.parametrize('name',['../bad.bbp','x/y.bbp','x\\y.bbp','a.bbp.exe','x;bad.bbp','a..bbp','a.lua'])
def test_import_rejects_paths_and_other_formats(plans,name):
    assert not plans.eval('I.ValidFilename')(name)

def test_export_never_overwrites_an_existing_plan(plans,tmp_path):
    plans.globals().directory=str(tmp_path).replace('\\','/')
    a,b=plans.execute('''
      I.directory=directory;os.execute=function() return 0 end
      local p={name='Everyday',requests={request('BUFF','A')}}
      local a=assert(I.Export(p));local b=assert(I.Export(p))
      assert(I.Read(a).requests[1].target=='A')
      return a,b
    ''')
    assert a!=b and (tmp_path/a).read_bytes()==(tmp_path/b).read_bytes()

def test_import_creates_new_preset_without_changing_rest_or_current_requests(plans):
    assert plans.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s,{request('BUFF','A')})
      local original=U.preset;U.state.rest={on=1,preset=1}
      local idx=assert(I.Insert(U.state,{name='Imported',requests={request('MISSING','gone')}}))
      assert(idx==2 and U.state.active==2 and U.state.presets[1]==original and U.state.rest.preset==1)
      assert(U.state.presets[2].requests[1].group=='MISSING')
      for i=3,8 do U.state.presets[i]={name='Other',requests={}} end
      return I.Insert(U.state,{name='No room',requests={}})==nil and U.state.active==2
    ''')

def test_delete_clears_rest_reference_and_preserves_other_presets(plans):
    assert plans.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s,{request('BUFF','A')})
      local kept={name='Keep',requests={request('BUFF','B')}};U.state.presets[3]=kept
      U.state.rest={on=1,preset=1};BfBot.Rest={pending={}}
      U.OpenChoices('delete');U.DeletePreset()
      return U.state.presets[1]==nil and U.state.active==3 and U.preset==kept
        and U.state.rest.on==0 and U.state.rest.preset==3 and BfBot.Rest.pending==nil
    ''')

def test_delete_rejects_stale_confirmation_and_last_preset(plans):
    assert plans.execute('''
      local s=snapshot();source(s,'BUFF','A',60,'a',1);setup(s)
      U.OpenChoices('delete');U.DeletePreset();assert(U.state.presets[1])
      U.state.presets[2]={name='Keep',requests={}};U.OpenChoices('delete')
      local changed={name='Changed',requests={}};U.state.presets[1]=changed
      U.DeletePreset();return U.state.presets[1]==changed
    ''')

def test_codec_enforces_size_and_request_bounds(plans):
    assert plans.execute('''
      assert(I.Decode(string.rep('x',I.maxBytes+1))==nil)
      local p={name='Too big',requests={}}
      for i=1,257 do p.requests[i]=request('BUFF','A') end
      return I.Encode(p)==nil
    ''')

