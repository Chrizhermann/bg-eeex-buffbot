"""Native exchange failure paths must retain the physical item in an owner."""
from pathlib import Path
import pytest
from lupa.luajit21 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]


@pytest.fixture
def lua():
    r=LuaRuntime(unpack_returned_tuples=True)
    r.execute('''
      BfBot={};nativeCalls=0;cursor={};slots={};bytes={}
      original={ptr=500000,m_useCount1=2,m_flags=1};slots[3]=original
      sprite={m_id=7,m_equipment={m_items={get=function(_,n)return slots[n]end}}}
      local base=100000;local game={ptr=300000}
      EEex_EngineGlobal_CBaldurChitin={ptr=200000,m_pObjectGame=game}
      EEex_GetImageBase=function()return base end
      EEex_UDToPtr=function(v)return v.ptr end
      EEex_Sprite_GetPortraitIndex=function()return 1 end
      EEex_Sprite_GetCharacterIndex=function()return 4 end -- deliberately reordered
      EEex_ReadU16=function(p)return p==base and 0x5A4D or 0 end
      EEex_ReadU32=function(p)return ({[base+60]=256,[base+256]=0x4550,
        [base+264]=0x609437B3,[base+336]=0x3530000})[p]or 0 end
      EEex_Read32=function(p)return p==300000+0x6618+4 and 7 or -1 end
      EEex_Read64=function(p)return p==200000+0x10C8 and 400000 or 0 end
      for _,p in ipairs({
        {0x28F960,{0x40,0x55,0x53,0x56,0x57,0x41,0x54,0x41,0x56,0x41,0x57}},
        {0x290E00,{0x40,0x55,0x53,0x56,0x57,0x41,0x54,0x41,0x55,0x41,0x56}},
      })do for i,v in ipairs(p[2])do bytes[base+p[1]+i-1]=v end end
      EEex_ReadU8=function(p)return bytes[p]or 0 end
      local function exchange(index,slot,held)
        assert(index==1);nativeCalls=nativeCalls+1
        if failPickup and not held[0]then return 0 end
        if held[0] and (slot==22 and failDrop or slot==3 and failRollback
          or slot==32767 and failAuto)then return 0 end
        if slot==32767 then slot=18 end
        local old=slots[slot];slots[slot]=held[0] and original or nil
        held[0]=old and old.ptr or nil
        return 1
      end
      package.loaded.ffi={
        new=function()return {}end,
        cast=function(sig,value)
          if sig=='void*' or sig=='uintptr_t'then return value end
          if sig=='void**'then assert(value==400000+0x50);return cursor end
          if value==base+0x28F960 then return function(g,index,slot,held)
            assert(g==300000);return exchange(index,slot,held)
          end end
          assert(value==base+0x290E00)
          return function(g,index,held,slot)assert(g==300000);return exchange(index,slot,held)end
        end,
      }
    ''')
    r.execute((ROOT/'buffbot/BfBotScn.lua').read_text(encoding='utf-8'))
    return r


def test_empty_backpack_move_preserves_instance_charges_and_uses_portrait_index(lua):
    assert lua.execute('''
      assert(BfBot.Scan._NativeMoveToBackpack(sprite,3,22))
      return slots[22]==original and not slots[3] and original.m_useCount1==2
        and nativeCalls==2 and not cursor[0] and BfBot.Scan._nativePackHeld==nil
    ''')


@pytest.mark.parametrize('setup', [
    'cursor[0]=123', 'slots[22]={ptr=99}',
    'EEex_Read32=function()return 99 end',
    'bytes[100000+0x290E00]=0',
])
def test_bad_cursor_slots_identity_or_executable_never_pick_up(lua,setup):
    lua.execute(setup)
    assert lua.execute('''
      local ok=BfBot.Scan._NativeMoveToBackpack(sprite,3,22)
      return not ok and nativeCalls==0 and slots[3]==original
    ''')


def test_refused_destination_rolls_back_without_spending_or_replacing_item(lua):
    assert lua.execute('''
      failDrop=true
      local ok=BfBot.Scan._NativeMoveToBackpack(sprite,3,22)
      return not ok and slots[3]==original and not slots[22] and not cursor[0]
        and original.m_useCount1==2 and BfBot.Scan._nativePackHeld==nil
    ''')


def test_changed_equipment_eligibility_can_recover_into_another_free_pack_slot(lua):
    assert lua.execute('''
      failDrop=true;failRollback=true
      local ok=BfBot.Scan._NativeMoveToBackpack(sprite,3,22)
      return not ok and slots[18]==original and not slots[3]
        and not cursor[0] and BfBot.Scan._nativePackHeld==nil
    ''')


def test_failed_automatic_recovery_retains_item_on_real_inventory_cursor(lua):
    assert lua.execute('''
      failDrop=true;failRollback=true;failAuto=true
      local ok,why=BfBot.Scan._NativeMoveToBackpack(sprite,3,22)
      return not ok and cursor[0]==original.ptr and not slots[3]
        and why:find('inventory cursor',1,true) and BfBot.Scan._nativePackHeld==nil
    ''')
