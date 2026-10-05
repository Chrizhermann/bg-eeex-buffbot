from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def options_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        prefs = { ItemUseMode = "inventory" }
        writes = {}
        options = {}
        tabs = {}
        uiStrings = {}
        BfBot = {
            L10N = { Get = function(key) return key end },
            Persist = {
                GetPref = function(key) return prefs[key] end,
                SetPref = function(key, value)
                    prefs[key] = value
                    writes[#writes + 1] = { key, value }
                end,
            },
        }
        EEex_Options_Private_Storage = {}
        EEex_Options_Widget = {}
        EEex_Options_Widget.__index = EEex_Options_Widget
        local function identityNew(value) return value or {} end
        EEex_Options_ToggleType = { new = identityNew }
        EEex_Options_ToggleWidget = { new = identityNew }
        EEex_Options_ClampedAccessor = { new = identityNew }
        EEex_Options_DisplayEntry = { new = identityNew }
        EEex_Options_Option = {}
        EEex_Options_Option.__index = EEex_Options_Option
        function EEex_Options_Option.new(value)
            return setmetatable(value, EEex_Options_Option)
        end
        function EEex_Options_Option:_getDefault() return self.default end
        function EEex_Options_Option:_read() return self.storage:read(self) end
        function EEex_Options_Option:_set(value, fromRead)
            self:_setWorkingValue(value)
            if not fromRead then self.storage:write(self, value) end
        end
        function EEex_Options_Option:_setWorkingValue(value)
            self.workingValue = value
            return value
        end
        function EEex_Options_Register(id, option) options[id] = option end
        function EEex_Options_Get(id) return options[id] end
        function EEex_Options_AddTab(label, provider)
            tabs[#tabs + 1] = { label = label, provider = provider }
        end
        """
    )
    runtime.execute((ROOT / "buffbot/BfBotThm.lua").read_text(encoding="utf-8"))
    return runtime


@pytest.mark.parametrize(
    ("stored", "selected"), [("inventory", 1), ("swap", 2), ("unknown", 1)]
)
def test_inventory_item_mode_reads_saved_preference_without_writing(
    options_lua, stored, selected
):
    options_lua.globals().prefs.ItemUseMode = stored
    options_lua.execute("BfBot.Theme._RegisterOptionsTab()")
    option = options_lua.globals().options.BuffBot_ItemUseMode
    assert option.workingValue == selected
    assert len(options_lua.globals().writes) == 0


def test_inventory_item_mode_radio_stages_selection_and_persists_both_choices(options_lua):
    options_lua.execute(
        """
        BfBot.Theme._RegisterOptionsTab()
        local columns = tabs[1].provider()
        assert(#columns == 3)
        assert(columns[1][2].label == "BuffBot_ItemUseMode")
        itemEntries = columns[1][2].subOptions
        assert(#itemEntries == 2)
        assert(itemEntries[1].widget.disallowToggleOff)
        assert(itemEntries[2].widget.disallowToggleOff)
        local option = options.BuffBot_ItemUseMode
        option:_setWorkingValue(2)
        assert(prefs.ItemUseMode == "inventory")
        assert(not itemEntries[1].widget.toggleState)
        assert(itemEntries[2].widget.toggleState)
        option:_set(2)
        assert(prefs.ItemUseMode == "swap")
        option:_setWorkingValue(1)
        assert(itemEntries[1].widget.toggleState)
        assert(not itemEntries[2].widget.toggleState)
        option:_set(1)
        assert(prefs.ItemUseMode == "inventory")
        BfBot.Theme._RegisterOptionsTab()
        assert(#tabs == 1)
        """
    )
    assert len(options_lua.globals().writes) == 2
