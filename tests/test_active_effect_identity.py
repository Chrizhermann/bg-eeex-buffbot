from __future__ import annotations

from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
EXEC_SOURCE = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")


@pytest.fixture
def effects() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("BfBot = {}")
    lua.execute(EXEC_SOURCE)
    lua.execute(
        """
        function effect(source, opcode, amount, flags)
            return {
                m_sourceRes = { get = function() return source end },
                m_effectId = opcode,
                m_effectAmount = amount,
                m_dWFlags = flags,
            }
        end
        EEex_Utility_IterateCPtrList = function(list, callback)
            for _, entry in ipairs(list) do
                if callback(entry) then break end
            end
        end
        signatures = {
            {opcode=0, amount=-2, flags=1},
            {opcode=16, amount=0, flags=1},
        }
        function hasEffect(sprite, source, kind)
            if kind == 'spell' then
                return BfBot.Exec._HasActiveEffect(sprite, source)
            elseif kind == 'item' then
                return BfBot.Exec._HasActiveItemEffect(sprite, source, signatures)
            end
            return BfBot.Exec._HasActiveStateMarker(sprite, source, {67})
        end
        """
    )
    return lua


@pytest.mark.parametrize("kind", ["spell", "item", "marker"])
@pytest.mark.parametrize("source, requested", [
    ("SPPR403", "SPPR403"),
    ("sPpR403", "SPPR403"),
    ("SPPR403", "sppr403"),
])
def test_effect_identity_ignores_case_without_changing_effects(
    effects: LuaRuntime, kind: str, source: str, requested: str,
) -> None:
    check = effects.eval(
        """function(kind, source, requested)
            local list = {
                effect('UNRELATED', 328, 0, 67),
                effect(nil, 328, 0, 67),
                effect(source, 0, -2, 1),
                effect(source, 16, 0, 1),
                effect(source, 328, 0, 67),
            }
            local sprite = {m_timedEffectList=list}
            return hasEffect(sprite, requested, kind)
                and hasEffect(sprite, requested, kind)
                and #list == 5 and list[3].m_sourceRes:get() == source
        end"""
    )
    assert check(kind, source, requested)


@pytest.mark.parametrize("kind", ["spell", "item", "marker"])
def test_missing_sources_and_sprites_never_match(
    effects: LuaRuntime, kind: str,
) -> None:
    check = effects.eval(
        """function(kind)
            local sprite = {m_timedEffectList={effect('',328,0,67)}}
            return not hasEffect(sprite, nil, kind)
                and not hasEffect(sprite, '', kind)
                and not hasEffect(sprite, 7, kind)
                and not hasEffect(nil, 'SPPR403', kind)
                and not hasEffect(sprite, 'SPPR403', kind)
        end"""
    )
    assert check(kind)


@pytest.mark.parametrize("entries", [
    "effect('sppr403',101,0,67)",  # Same source, administrative residue.
    "effect('OTHER',328,0,67)",  # Another buff's shared SPLSTATE.
    "effect('sppr403',328,0,68)",  # Same source, unrelated state.
    "effect('sppr403',101,0,67),effect('OTHER',328,0,67)",
])
def test_case_normalization_preserves_marker_confirmation(
    effects: LuaRuntime, entries: str,
) -> None:
    assert not effects.execute(
        'local sprite={m_timedEffectList={' + entries + '}}\n'
        'return BfBot.Exec._HasActiveStateMarker(sprite,"SPPR403",{67})'
    )


@pytest.mark.parametrize("entries", [
    "effect('boots',0,-2,1)",  # Incomplete power.
    "effect('boots',0,-2,1),effect('OTHER',16,0,1)",
    "effect('boots',0,-2,1),effect('BOOTS',16,1,1)",
    "effect('boots',0,-2,1),effect('BOOTS',16,0,0)",
])
def test_case_normalization_still_requires_the_complete_item_power(
    effects: LuaRuntime, entries: str,
) -> None:
    assert not effects.execute(
        'local sprite={m_timedEffectList={' + entries + '}}\n'
        'return BfBot.Exec._HasActiveItemEffect(sprite,"BOOTS",signatures)'
    )
