from pathlib import Path

from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]

# The engine styles BuffBot deep-copies, with the fonts BGEE.LUA gives them in
# 2.7.3.0. IWD:EE draws parchment/edit text in POSTANTI and titles in SHERWOOD.
BG2EE_STYLES = """
styles = {
    normal = { font = 'NORMAL', point = 12 },
    button = { font = 'STONESML', point = 10 },
    title = { font = 'REALMS', point = 16 },
    normal_parchment = { font = 'NORMAL', point = 12 },
    edit = { font = 'NORMAL', point = 12 },
}
"""
IWDEE_STYLES = """
styles = {
    normal = { font = 'NORMAL', point = 14 },
    button = { font = 'STONESML', point = 14 },
    title = { font = 'SHERWOOD', point = 34 },
    normal_parchment = { font = 'POSTANTI', point = 12 },
    edit = { font = 'POSTANTI', point = 14 },
}
"""


def _theme(styles_lua: str) -> LuaRuntime:
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        warnings = {}
        BfBot = {
            _Warn = function(message) warnings[#warnings + 1] = message end,
            L10N = { Get = function(key) return key end },
            Persist = { GetPref = function() return nil end, SetPref = function() end },
        }
        EEex = {
            DeepCopy = function(source)
                local copy = {}
                for key, value in pairs(source) do copy[key] = value end
                return copy
            end,
        }
        menus = {}
        function EEex_Menu_Find(name) return menus[name] end
        -- One BUFFBOT_MAIN item per font, linked like the engine's item list.
        function addItems(fonts)
            local first, last
            for _, font in ipairs(fonts) do
                local item = { text = { point = 99, font = { get = function() return font end } } }
                if last then last.next = item else first = item end
                last = item
            end
            menus.BUFFBOT_MAIN = { items = first }
            return first
        end
        function pointsByFont()
            local result = {}
            local item = menus.BUFFBOT_MAIN.items
            while item do
                result[item.text.font:get()] = item.text.point
                item = item.next
            end
            return result
        end
        """
    )
    runtime.execute(styles_lua)
    runtime.execute((ROOT / "buffbot/BfBotThm.lua").read_text(encoding="utf-8"))
    runtime.execute("BfBot.Theme._RegisterStyles()")
    return runtime


def _font_map(runtime: LuaRuntime) -> dict[str, int]:
    return dict(runtime.globals().BfBot.Theme._FONT_TO_BASE_POINT.items())


def test_bg2ee_styles_derive_the_former_fixed_font_map() -> None:
    runtime = _theme(BG2EE_STYLES)

    assert _font_map(runtime) == {"NORMAL": 12, "STONESML": 14, "REALMS": 18}
    assert len(runtime.globals().warnings) == 0


def test_iwdee_styles_map_their_own_title_and_parchment_fonts() -> None:
    runtime = _theme(IWDEE_STYLES)

    assert _font_map(runtime) == {
        "NORMAL": 12,
        "STONESML": 14,
        "SHERWOOD": 18,
        "POSTANTI": 12,
    }
    assert len(runtime.globals().warnings) == 0


def test_iwdee_live_items_rescale_and_unknown_fonts_stay_untouched() -> None:
    runtime = _theme(IWDEE_STYLES)
    runtime.execute(
        """
        addItems({ "SHERWOOD", "POSTANTI", "NORMAL", "MODESTOM" })
        BfBot.Theme._SetFontSize(3)
        """
    )

    points = dict(runtime.eval("pointsByFont()").items())
    assert points == {
        "SHERWOOD": int(18 * 1.20),
        "POSTANTI": int(12 * 1.20),
        "NORMAL": int(12 * 1.20),
        "MODESTOM": 99,
    }
    styles = runtime.globals().styles
    assert styles.bb_title.font == "SHERWOOD"
    assert styles.bb_title.point == int(18 * 1.20)
    assert styles.bb_edit.point == int(12 * 1.20)


def test_font_shared_at_different_sizes_keeps_its_load_size() -> None:
    # A UI mod giving buttons the body font makes NORMAL ambiguous: an item
    # keeps only its font, so its style (12 or 14) cannot be known.
    runtime = _theme(BG2EE_STYLES.replace("'STONESML'", "'NORMAL'"))
    runtime.execute(
        """
        addItems({ "NORMAL", "REALMS" })
        BfBot.Theme._SetFontSize(1)
        """
    )

    assert _font_map(runtime) == {"REALMS": 18}
    points = dict(runtime.eval("pointsByFont()").items())
    assert points == {"NORMAL": 99, "REALMS": int(18 * 0.85)}
    warnings = list(runtime.globals().warnings.values())
    assert len(warnings) == 1 and "NORMAL" in warnings[0]


def test_font_names_match_regardless_of_case() -> None:
    runtime = _theme(IWDEE_STYLES.replace("'SHERWOOD'", "'Sherwood'"))
    runtime.execute(
        """
        addItems({ "SHERWOOD" })
        BfBot.Theme._SetFontSize(2)
        """
    )

    assert _font_map(runtime)["SHERWOOD"] == 18
    assert dict(runtime.eval("pointsByFont()").items()) == {"SHERWOOD": 18}
