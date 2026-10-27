from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def options_lua() -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        prefs = { ItemUseMode = "inventory", RefreshBelow = 0 }
        writes = {}
        options = {}
        tabs = {}
        uiStrings = {}
        BfBot = {
            MAX_REFRESH_BELOW = 86400,
            L10N = { Get = function(key) return key end },
            Persist = {
                GetPref = function(key) return prefs[key] end,
                SetPref = function(key, value)
                    prefs[key] = value
                    writes[#writes + 1] = { key, value }
                end,
            },
        }
        -- The real RefreshBelow accessors (BfBotPer.lua) clamp on both read
        -- and write; _NormalizeRefreshBelow has its own tests. Here they only
        -- have to exist with the real signatures, because _RegisterOptionsTab
        -- reads every option it registers while seeding the widgets.
        function BfBot.Persist.GetRefreshBelow()
            local value = tonumber(prefs.RefreshBelow)
            if type(value) ~= "number" or value < 0 then return 0 end
            return math.floor(math.min(value, BfBot.MAX_REFRESH_BELOW))
        end
        function BfBot.Persist.SetRefreshBelow(value)
            BfBot.Persist.SetPref("RefreshBelow", value)
            return value
        end
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


@pytest.mark.parametrize(
    ("palette", "skin"),
    [
        # Skin indices are the art's own order; see the mapping test in
        # tests/test_panel_chrome.py.
        ("bg2_light", 3), ("bg2_dark", 3),
        ("sod_light", 2), ("sod_dark", 2),
        ("bg1_light", 0), ("bg1_dark", 0),
    ],
)
def test_control_skin_follows_the_accent_and_ignores_dark_mode(
    options_lua, palette, skin
):
    # BuffBot has no IWD palette, so skin 1 is deliberately unreachable.
    actual = options_lua.execute(
        """
        BfBot.Theme._active = BfBot.Theme._palettes["%s"]
        return BfBot.Theme.ControlSkin()
        """ % palette
    )
    assert actual == skin


def test_control_art_is_absent_without_the_resource_api(options_lua):
    assert options_lua.execute(
        """
        EEex_Resource_Fetch = nil
        BfBot.Theme._controlArt = nil
        return BfBot.Theme.HasControlArt()
        """
    ) is False


def test_control_art_requires_every_checkbox_skin_and_the_glyph_sheet(options_lua):
    facts = options_lua.execute(
        """
        local asked = {}
        EEex_Resource_Fetch = function(resref, kind)
            asked[#asked + 1] = resref .. ":" .. kind
            return resref ~= "BFBCHK2"
        end
        BfBot.Theme._controlArt = nil
        local missing = BfBot.Theme.HasControlArt()

        EEex_Resource_Fetch = function() return true end
        BfBot.Theme._controlArt = nil
        local present = BfBot.Theme.HasControlArt()

        -- A second call must not re-ask the engine for every rendered row.
        local calls = 0
        EEex_Resource_Fetch = function() calls = calls + 1 return true end
        local cached = BfBot.Theme.HasControlArt()
        return { missing = missing, present = present, cached = cached,
                 calls = calls, asked = table.concat(asked, " ") }
        """
    )
    assert facts["missing"] is False
    assert facts["present"] is True
    assert facts["cached"] is True
    assert facts["calls"] == 0
    assert facts["asked"] == "BFBCHK0:BAM BFBCHK1:BAM BFBCHK2:BAM"


@pytest.mark.parametrize(
    ("stored", "selected"),
    [
        (0, 1),
        (60, 2),
        (300, 3),
        (3600, 4),
        # Hand-edited values that are not presets show the largest preset at
        # or below them, so the tab never claims the threshold is off.
        (1, 2),
        (59, 2),
        (299, 2),
        (3599, 3),
        (86400, 4),
        (-5, 1),
        ("nonsense", 1),
    ],
)
def test_refresh_below_reads_stored_threshold_without_writing(
    options_lua, stored, selected
):
    options_lua.globals().prefs.RefreshBelow = stored
    options_lua.execute("BfBot.Theme._RegisterOptionsTab()")
    option = options_lua.globals().options.BuffBot_RefreshBelow
    assert option.workingValue == selected
    assert len(options_lua.globals().writes) == 0


def test_refresh_below_radio_stages_selection_and_persists_each_choice(options_lua):
    options_lua.execute(
        """
        BfBot.Theme._RegisterOptionsTab()
        local columns = tabs[1].provider()
        assert(columns[1][3].label == "BuffBot_RefreshBelow")
        refreshEntries = columns[1][3].subOptions
        assert(#refreshEntries == 4)
        local option = options.BuffBot_RefreshBelow
        for index, seconds in ipairs(BfBot.Theme.REFRESH_BELOW_CHOICES) do
            assert(refreshEntries[index].widget.disallowToggleOff)
            assert(refreshEntries[index].widget.toggleValue == index)
            option:_set(index)
            assert(prefs.RefreshBelow == seconds,
                "expected " .. seconds .. " got " .. tostring(prefs.RefreshBelow))
            for other = 1, #refreshEntries do
                assert(refreshEntries[other].widget.toggleState
                    == (other == index))
            end
        end
        """
    )
    assert [list(w.values()) for w in options_lua.globals().writes.values()] == [
        ["RefreshBelow", 0],
        ["RefreshBelow", 60],
        ["RefreshBelow", 300],
        ["RefreshBelow", 3600],
    ]


def test_refresh_below_choices_are_ascending_and_start_at_off():
    source = (ROOT / "buffbot/BfBotThm.lua").read_text(encoding="utf-8")
    assert "BfBot.Theme.REFRESH_BELOW_CHOICES = { 0, 60, 300, 3600 }" in source


def test_theme_colors_reach_the_engine_as_packed_numbers(options_lua):
    # The engine reads one number per color and unpacks it as
    # alpha<<24 | blue<<16 | green<<8 | red -- blue and red the other way round
    # from the usual 0xAARRGGBB. EEex's own EEex_Options_Private_UnpackColor
    # does it that way. Until v1.12.1 _T returned the palette's "{R, G, B}"
    # string, which no engine path could read, so every label fell back to its
    # style's default and all six palettes rendered the same near-black text.
    facts = options_lua.execute(
        """
        BfBot.Theme._active = BfBot.Theme._palettes["bg2_light"]
        local title = BfBot.UI._T("title")
        local raw = BfBot.UI._TRaw("title")
        BfBot.Theme._active = BfBot.Theme._palettes["bg1_dark"]
        return {
            titleType = type(title),
            title = title,
            raw = raw,
            missing = BfBot.UI._T("no_such_key"),
            switched = BfBot.UI._T("title"),
        }
        """
    )
    assert facts["titleType"] == "number"
    assert facts["raw"] == "{50, 30, 10}"
    assert facts["title"] == (10 << 16) | (30 << 8) | 50
    assert facts["missing"] == 0xFF00FF
    # Switching the palette must change what the engine is handed; that it did
    # not is exactly how the six themes rendered identically.
    assert facts["switched"] != facts["title"]


def test_every_palette_color_survives_packing(options_lua):
    # A typo in any palette entry would pack to the red error value and show up
    # as a red label in game rather than as a failure anywhere else.
    bad = options_lua.execute(
        """
        local bad = {}
        for name, palette in pairs(BfBot.Theme._palettes) do
            BfBot.Theme._active = palette
            for key, value in pairs(palette) do
                if type(value) == "string" and value:sub(1, 1) == "{" then
                    local packed = BfBot.UI._T(key)
                    local r, g, b = value:match("^%{(%d+),%s*(%d+),%s*(%d+)%}$")
                    if not r or packed ~= (tonumber(b) * 0x10000)
                                          + (tonumber(g) * 0x100) + tonumber(r) then
                        bad[#bad + 1] = name .. "." .. key .. " = " .. value
                    end
                end
            end
        end
        return table.concat(bad, "; ")
        """
    )
    assert bad == ""


# ---------------------------------------------------------------------------
# Caption scaling: a caption shrinks with the plate the footer narrowed.
# The per-render listener is the last word on an item's point, so that is
# where the scale has to land -- and where these drive it from.
# ---------------------------------------------------------------------------


CAPTION_HARNESS = """
    BfBot.Theme._FONT_TO_BASE_POINT = { NORMAL = 12 }
    BfBot.Theme._fontSize = 2
    BfBot.Theme._fontListenersRegistered = nil
    T_Listeners = {}
    EEex_Menu_AddBeforeUIItemRenderListener = function(name, fn)
        T_Listeners[name] = fn
    end
    local function item(name, font, point)
        return {
            name = { get = function() return name end },
            text = { font = { get = function() return font end },
                     point = point },
        }
    end
    T_Items = { %s }
    for index = 1, #T_Items - 1 do T_Items[index].next = T_Items[index + 1] end
    EEex_Menu_Find = function(name)
        if name ~= "BUFFBOT_MAIN" then return nil end
        return { items = T_Items[1] }
    end
    BfBot.Theme._RegisterFontRenderListeners()
"""


def _render(options_lua, name: str) -> int:
    """Draw one item the way the engine does, and report its point size."""
    return options_lua.execute(
        """
        for _, it in ipairs(T_Items) do
            if it.name.get() == "%s" then
                T_Listeners["%s"](it)
                return it.text.point
            end
        end
        error("no item named %s")
        """ % (name, name, name)
    )


def test_a_caption_takes_the_point_size_its_plate_leaves_it(options_lua):
    options_lua.execute(CAPTION_HARNESS % (
        'item("bbSort_t", "NORMAL", 12), item("bbDel_t", "NORMAL", 12)'))
    options_lua.execute(
        "BfBot.Theme.ApplyCaptionScales({ bbSort = 0.5, bbDel = 1 })")
    assert _render(options_lua, "bbSort_t") == 6     # floor(12 * 1.0 * 0.5)
    assert _render(options_lua, "bbDel_t") == 12


def test_a_status_toggle_scales_under_its_own_name(options_lua):
    """Quick Cast and the order toggle have to stay text items -- only a text
    item takes an action together with `text color lua` -- so they carry the
    control's name rather than a "<name>_t" caption."""
    options_lua.execute(CAPTION_HARNESS % 'item("bbQC", "NORMAL", 12)')
    options_lua.execute("BfBot.Theme.ApplyCaptionScales({ bbQC = 0.5 })")
    assert _render(options_lua, "bbQC") == 6


def test_widening_the_panel_gives_a_caption_its_size_back(options_lua):
    """The layout reports only what it narrowed, so a panel that grows again
    has to restore everything else."""
    options_lua.execute(CAPTION_HARNESS % 'item("bbSort_t", "NORMAL", 12)')
    options_lua.execute("BfBot.Theme.ApplyCaptionScales({ bbSort = 0.6 })")
    assert _render(options_lua, "bbSort_t") == 7
    options_lua.execute("BfBot.Theme.ApplyCaptionScales({})")
    assert _render(options_lua, "bbSort_t") == 12


def test_a_caption_never_shrinks_below_what_can_be_read_at_all(options_lua):
    """Past this the panel is simply too small, and an unreadable caption on
    its own plate still beats a readable one printed over its neighbour."""
    options_lua.execute(CAPTION_HARNESS % 'item("bbSort_t", "NORMAL", 12)')
    options_lua.execute("BfBot.Theme.ApplyCaptionScales({ bbSort = 0.05 })")
    assert _render(options_lua, "bbSort_t") == 6


def test_the_caption_scale_follows_the_players_text_size(options_lua):
    options_lua.execute(CAPTION_HARNESS % 'item("bbSort_t", "NORMAL", 12)')
    options_lua.execute("""
        BfBot.Theme._fontSize = 3
        BfBot.Theme.ApplyCaptionScales({ bbSort = 0.5 })
    """)
    assert _render(options_lua, "bbSort_t") == 7   # floor(12 * 1.20 * 0.5)


def test_an_item_the_layout_did_not_narrow_keeps_its_size(options_lua):
    options_lua.execute(CAPTION_HARNESS % (
        'item("bbList", "NORMAL", 12), item("bbSort_t", "NORMAL", 12)'))
    options_lua.execute("BfBot.Theme.ApplyCaptionScales({ bbSort = 0.5 })")
    assert _render(options_lua, "bbList") == 12


@pytest.mark.parametrize("scale", ["0/0", "-1", "2", "'nonsense'"])
def test_a_scale_that_makes_no_sense_leaves_the_caption_alone(options_lua, scale):
    """A factor is a width ratio; anything else is a layout bug, and drawing
    nothing or a giant caption would be a worse answer than the plain size."""
    options_lua.execute(CAPTION_HARNESS % 'item("bbSort_t", "NORMAL", 12)')
    options_lua.execute(
        "BfBot.Theme.ApplyCaptionScales({ bbSort = %s })" % scale)
    assert _render(options_lua, "bbSort_t") == 12
