"""Manual variant/innate spending matches native per-level resource semantics."""
from pathlib import Path
import pytest
from lupa.luajit21 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture
def debit():
    r=LuaRuntime(unpack_returned_tuples=True)
    r.execute('''
      bit=require('bit');BfBot={Exec={}};header={spellType=4,spellLevel=1}
      function EEex_Resource_Demand()return header end
      function EEex_Utility_IterateCPtrList(list,fn)for _,s in ipairs(list)do if fn(s)then break end end end
      function mem(res,flags)return {m_flags=flags,m_spellId={get=function()return res end}}end
      rows={mem('CUSTOM',5),mem('CUSTOM',1),mem('OTHER',1),mem('OTHER',1),mem('DISABLED',3)}
      sprite={m_typeAI={m_Class=1},m_memorizedSpellsInnate={getReference=function(_,level)assert(level==0)return rows end}}
      sprite.m_memorizedSpellsMage=sprite.m_memorizedSpellsInnate
      sprite.m_memorizedSpellsPriest=sprite.m_memorizedSpellsInnate
    ''')
    r.execute((ROOT/'buffbot/BfBotExe.lua').read_text(encoding='utf-8'))
    return r

def test_nonstandard_innate_filename_uses_header_type_and_preserves_other_flags(debit):
    assert debit.execute('''
      assert(BfBot.Exec._ConsumeSpellSlot(sprite,'CUSTOM'))
      return rows[1].m_flags==4 and rows[2].m_flags==1 and rows[3].m_flags==1
    ''')

@pytest.mark.parametrize('cls,kind',[(19,1),(21,2)])
def test_spontaneous_variant_debits_exactly_one_of_every_level_choice(debit,cls,kind):
    debit.globals().cls=cls;debit.globals().kind=kind
    assert debit.execute('''
      header.spellType=kind;sprite.m_typeAI.m_Class=cls
      assert(BfBot.Exec._ConsumeSpellSlot(sprite,'CUSTOM'))
      return rows[1].m_flags==4 and rows[2].m_flags==1
        and rows[3].m_flags==0 and rows[4].m_flags==1 and rows[5].m_flags==3
    ''')

def test_unavailable_parent_never_debits_another_choice(debit):
    assert debit.execute('''
      header.spellType=1;sprite.m_typeAI.m_Class=19
      rows[1].m_flags=0;rows[2].m_flags=0
      return not BfBot.Exec._ConsumeSpellSlot(sprite,'CUSTOM') and rows[3].m_flags==1
    ''')
