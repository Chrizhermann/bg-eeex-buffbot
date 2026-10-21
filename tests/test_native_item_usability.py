"""Fail closed on unverified engines; pass a party index to the full UI query."""
from pathlib import Path
import pytest
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def lua():
    r = LuaRuntime(unpack_returned_tuples=True)
    r.execute('''
        BfBot={};bytes={};calls=0;allowed=1;characterIndex=2
        local base=100000
        for _,p in ipairs({
          {0x271550,{0x48,0x89,0x74,0x24,0x20,0x57,0x48,0x83,0xEC,0x30,0x49,0x8B,0xF8}},
          {0x2715D7,{0xE8,0x74,0,0,0}},
          {0x271617,{0xE8,0xE4,0x76,0xF8,0xFF}},
        })do for i,v in ipairs(p[2])do bytes[base+p[1]+i-1]=v end end
        EEex_GetImageBase=function()return base end
        EEex_ReadU16=function(p)return p==base and 0x5A4D or 0 end
        EEex_ReadU32=function(p)return ({
          [base+0x3C]=0x100,[base+0x100]=0x4550,
          [base+0x108]=0x609437B3,[base+0x150]=0x3530000,
        })[p]or 0 end
        EEex_ReadU8=function(p)return bytes[p]or 0 end
        EEex_UDToPtr=function(v)return v.ptr end
        EEex_Sprite_GetPortraitIndex=function()return characterIndex end
        EEex_Sprite_GetCharacterIndex=function()return 5 end
        EngineGlobals={g_pBaldurChitin={m_pObjectGame={ptr=111}}}
        sprite={ptr=222};item={ptr=333}
        package.loaded.ffi={
          new=function()return {[0]=-1}end,
          cast=function(sig,address)
            if sig=='void*'then return address end
            assert(sig=='int(*)(void*,int,void*,int*,int)')
            assert(address==base+0x271550)
            return function(game,index,itemPtr,why,mode)
              calls=calls+1
              assert(game==111 and index==2 and itemPtr==333 and mode==0)
              return allowed
            end
          end,
        }
    ''')
    r.execute((ROOT/'buffbot/BfBotScn.lua').read_text(encoding='utf-8'))
    return r


@pytest.mark.parametrize('allowed', [0, 1])
def test_full_inventory_predicate_includes_native_item_type_decision(lua, allowed):
    lua.globals().allowed = allowed
    result = lua.execute('return BfBot.Scan._NativeCanWearItem(sprite,item)')
    assert (result[0] if isinstance(result, tuple) else result) == bool(allowed)
    assert lua.eval('calls') == 1


@pytest.mark.parametrize('offset', [0x271550, 0x2715D7, 0x271617])
def test_modified_function_or_internal_call_is_never_invoked(lua, offset):
    lua.globals().offset = offset
    lua.execute('bytes[100000+offset]=0')
    result = lua.execute('return BfBot.Scan._NativeCanWearItem(sprite,item)')
    assert result[0] is None
    assert lua.eval('calls') == 0


@pytest.mark.parametrize('index', [-1, 6])
def test_non_party_casters_do_not_enter_native_party_inventory_query(lua, index):
    lua.globals().characterIndex = index
    result = lua.execute('return BfBot.Scan._NativeCanWearItem(sprite,item)')
    assert result[0] is None
    assert lua.eval('calls') == 0
