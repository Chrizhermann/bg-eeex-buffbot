from pathlib import Path
import pytest
from lupa.luajit21 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]


@pytest.fixture
def lua():
    r=LuaRuntime(unpack_returned_tuples=True)
    r.execute((ROOT/'buffbot/BfBotCor.lua').read_text(encoding='utf-8'))
    return r


def test_player_name_uses_native_accessor_and_strips_colour(lua):
    assert lua.execute('''
      local sprite={getNameRef=function()return -2 end,
        getName=function()return '^0xFFFF0000Custom Name^-'end}
      Infinity_FetchString=function(ref)
        error('Negative refs are not TLK strings')
      end
      return BfBot._GetName(sprite)=='Custom Name'
    ''')


def test_failed_native_name_reference_uses_native_accessor(lua):
    assert lua.execute('''
      Infinity_FetchString=function()error('Unavailable string')end
      return BfBot._GetName({getNameRef=function()return 7 end,
        getName=function()return 'Fallback'end})=='Fallback'
    ''')


def test_older_api_keeps_name_lookup_fallback(lua):
    assert lua.execute("return BfBot._GetName({getName=function()return 'Legacy' end})=='Legacy'")
