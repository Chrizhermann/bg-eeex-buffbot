"""Old saves lose only BuffBot's retired shortcuts; HUD plans remain usable."""
from pathlib import Path
import pytest
from lupa.luajit21 import LuaRuntime
from test_party_dashboard import dashboard
from test_party_planner import lua

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'buffbot/BfBotInn.lua').read_text(encoding='utf-8')


@pytest.fixture
def migration():
    r = LuaRuntime(unpack_returned_tuples=True)
    r.execute('''
    io=nil; BfBot={_SafeCallback=function(_,f)return f end,Exec={GetState=function()return running and 'running' or 'idle' end},Share={}}
    known={'BFBT01','BFBT01','BFBT58','SPIN101','BFBTCH','BFBT11X'}
    memorized={'BFBT01','BFBT01','BFBT01','BFBT22','SPIN101'}
    effects={};listeners={};running=false;worldScreen={};e={GetActiveEngine=function()return worldScreen end}
    sprite={m_id=42,m_memorizedSpellsInnate={getReference=function()return memorized end}}
    function EEex_Sprite_GetKnownInnateSpellsIterator()
      local i=0;return function()i=i+1;if known[i]then return 0,i,known[i]end end
    end
    function EEex_Utility_IterateCPtrList(list,f)
      for _,res in ipairs(list)do f({m_spellId={get=function()return res end}})end
    end
    function sprite:applyEffect(effect)
      effects[#effects+1]=effect
      assert(effect.effectID==172 and effect.timing==1)
      for _,list in ipairs({known,memorized})do
        for i,res in ipairs(list)do if res==effect.res then table.remove(list,i);break end end
      end
    end
    function EEex_Sprite_AddLoadedListener(f)listeners[#listeners+1]=f end
    function EEex_GameObject_Get(id)return id==42 and sprite end
    function EEex_GameObject_IsSprite(s)return s==sprite end
    function EEex_GameObject_CastUserType(s)return s end
    ''')
    r.execute(SOURCE)
    return r


def test_upgrade_removes_duplicate_spent_and_orphan_shortcuts_only(migration):
    assert migration.execute('''
    BfBot.Legacy.RemovePresetAbilities(sprite)
    assert(#effects==5)
    assert(table.concat(known,',')=='SPIN101,BFBTCH,BFBT11X')
    assert(table.concat(memorized,',')=='SPIN101')
    return BfBot.Legacy.RemovePresetAbilities(sprite)==0
    ''')


def test_load_cleanup_defers_mutation_and_waits_for_active_run(migration):
    assert migration.execute('''
    BfBot.Legacy.Init();BfBot.Legacy.Init();assert(#listeners==1)
    listeners[1](sprite);assert(#effects==0)
    running=true;BfBot.Legacy.Tick();assert(#effects==0 and BfBot.Legacy.pending[42])
    running=false;BfBot.Legacy.Tick()
    return #effects==5 and next(BfBot.Legacy.pending)==nil
    ''')


def test_no_legacy_saved_action_can_dispatch_a_plan(migration):
    assert migration.execute('''
    BfBot.Exec.Start=function()error('Retired shortcut dispatched')end
    BFBOTGO({m_effectAmount=0,m_dWFlags=1,m_sourceId=42})
    return BfBot.Innate==nil
    ''')


def test_missing_or_destroyed_character_is_discarded(migration):
    assert migration.execute('''
    BfBot.Legacy.pending[999]=true;BfBot.Legacy.Tick()
    return #effects==0 and next(BfBot.Legacy.pending)==nil
    ''')


def test_old_recipient_setting_is_dropped_without_changing_plans(lua):
    assert lua.execute('''
    local s=P.Validate({innateRecipients={A=1},presets={[1]={name='Battle',requests={}}}})
    return s.innateRecipients==nil and s.presets[1].name=='Battle'
    ''')


def test_settings_no_longer_offer_innate_shortcuts(dashboard):
    assert dashboard.execute('''
    setup(snapshot(),{});U.OpenChoices('settings')
    for _,r in ipairs(bbPartyChoices)do assert(r.kind~='openInnateRecipients')end
    return true
    ''')


def test_only_legacy_cast_helpers_remain_and_no_preset_resources_are_generated(migration):
    assert migration.execute('''
    return #BfBot.Legacy._BuildCheatSPL()==250 and #BfBot.Legacy._BuildCheatRemoverSPL()==202
    ''')
    assert 'AddSpecialAbility' not in SOURCE
    assert '_BuildSPL' not in SOURCE
    assert 'AddQuickListsCheckedListener' not in SOURCE

