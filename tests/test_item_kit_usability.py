"""Native kit identifiers must resolve to ITM usability masks, including TRUECLASS."""

import pytest
from lupa.luajit21 import LuaRuntime

from test_item_swap import _runtime


@pytest.fixture
def kit_runtime() -> LuaRuntime:
    lua = _runtime()
    lua.execute(
        """
        h = defineItem('KITCHECK', 32)
        sprite.m_typeAI.m_Class = 1 -- mage
        stats[152] = 0x4000 -- native TRUECLASS / MAGESCHOOL_GENERALIST
        -- The native C2DArray indices exclude labels; its x dimension includes
        -- the row labels. Extra columns and reordered rows are intentional.
        kitColumns = {'EXTRA', 'UNUSABLE', 'ROWNAME', 'KITIDS', 'CLASS'}
        kitRecords = {
            {ROWNAME='MODDED', KITIDS='0x4321', UNUSABLE='0x10000000'},
            {ROWNAME='CONJURER', KITIDS='0x0080', UNUSABLE='0x00000080'},
            {ROWNAME='RESERVE', KITIDS='*', UNUSABLE='*'},
            {ROWNAME='WIZARD_SLAYER', KITIDS='0x4002', UNUSABLE='0x00000002'},
            {ROWNAME='BERSERKER', KITIDS='0x4001', UNUSABLE='0x00000001'},
        }
        kitLoads = 0
        EEex_Resource_Load2DA = function(name)
            assert(name == 'KITLIST')
            kitLoads = kitLoads + 1
            return {
                findColumnLabel = function(_, label)
                    for i, value in ipairs(kitColumns) do
                        if value == label then return i - 1 end
                    end
                    return -1
                end,
                getDimensions = function() return #kitColumns + 1, #kitRecords end,
                getAtPoint = function(_, x, y)
                    local row, column = kitRecords[y + 1], kitColumns[x + 1]
                    return row and column and row[column] or '*'
                end,
            }
        end
        function itemKitMask(mask)
            for i, offset in ipairs({0x29, 0x2B, 0x2D, 0x2F}) do
                bytes[h.ptr + offset] = bit.band(bit.rshift(mask, (4-i)*8), 255)
            end
        end
        function canWear()
            local allowed, reason = BfBot.Scan._CanWearItem(sprite, h)
            return {allowed=allowed, reason=reason}
        end
        """
    )
    return lua


@pytest.mark.parametrize("mask,allowed", [
    (0, True),
    (0x2, True),  # native AMUL15: Wizard Slayer only
    (0x80, True),
    (0x80000000, True),
    (0x4000, False),  # ITM byte 0x2D bit6: all characters without a kit
    (0x4002, False),
    (0xFFFFFFFF, False),
])
def test_trueclass_applies_its_own_mask(kit_runtime, mask, allowed):
    kit_runtime.globals().itemKitMask(mask)
    result = kit_runtime.globals().canWear()
    assert result["allowed"] is allowed
    if not allowed:
        assert result["reason"] == "item kit restriction"


@pytest.mark.parametrize("kit,mask,allowed", [
    (0x80, 0x2, True),
    (0x80, 0x80, False),
    (0x4001, 0x4000, True),  # kit ID bits are not the usability mask
    (0x4001, 0x1, False),
    (0x4002, 0x2, False),
    (0x4321, 0x2, True),
    (0x4321, 0x10000000, False),
])
def test_mage_vanilla_and_custom_kits_keep_table_mapping(kit_runtime, kit, mask, allowed):
    kit_runtime.globals().stats[152] = kit
    kit_runtime.globals().itemKitMask(mask)
    assert kit_runtime.globals().canWear()["allowed"] is allowed
    assert kit_runtime.globals().kitLoads == 1


def test_unknown_kit_still_fails_closed(kit_runtime):
    kit_runtime.globals().stats[152] = 0x4322
    kit_runtime.globals().itemKitMask(0x2)
    result = kit_runtime.globals().canWear()
    assert result["allowed"] is False
    assert result["reason"] == "unknown item kit restriction"


@pytest.mark.parametrize("mask", ["*", "not-a-mask"])
def test_malformed_custom_mask_is_rejected(kit_runtime, mask):
    kit_runtime.globals().kitRecords[1]["UNUSABLE"] = mask
    kit_runtime.globals().stats[152] = 0x4321
    kit_runtime.globals().itemKitMask(0x2)
    result = kit_runtime.globals().canWear()
    assert result["allowed"] is False
    assert result["reason"] == "item kit restriction"


@pytest.mark.parametrize("restriction,reason", [
    ("dwords[h.ptr+0x1E]=0x40000", "cannot be worn"),
    ("dwords[h.ptr+0x1E]=0x08000000", "cannot be worn"),
    ("dwords[h.ptr+0x1E]=0x10", "cannot be worn"),
    ("words[h.ptr+0x26]=19", "minimum ability"),
    ("words[h.ptr+0x24]=11", "minimum level"),
    ("words[h.ptr+0x70]=1;words[h.ptr+h.effectsOffset]=319", "conditional"),
])
def test_trueclass_preserves_other_item_guards(kit_runtime, restriction, reason):
    kit_runtime.globals().itemKitMask(0x2)
    kit_runtime.execute(restriction)
    result = kit_runtime.globals().canWear()
    assert result["allowed"] is False
    assert reason in result["reason"]
