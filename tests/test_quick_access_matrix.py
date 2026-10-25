"""Cross-entrypoint tests with real UI, persistence and speed control.

The engine and final execution action are mocked. These tests establish queue
and dispatch contracts, not native casting time, visuals or resource use.
"""
from pathlib import Path

import pytest

from test_ui_selection import ui_lua


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def shortcut_lua(ui_lua):
    for filename in ("BfBotPer.lua", "BfBotFst.lua"):
        ui_lua.execute((ROOT / "buffbot" / filename).read_text(encoding="utf-8"))
    ui_lua.execute("""
        bit=require('bit')
        starts,notices,warnings,party,stack,callbacks={},{},{},{},{WORLD_ACTIONBAR=1},{}
        speed,wall,state=1,1000,'idle'
        worldScreen={}
        e={GetActiveEngine=function() return worldScreen end}
        EngineGlobals={g_pBaldurChitin={
            cNetwork={m_bConnectionEstablished=0},
            m_pObjectGame={m_gameSave={m_inputMode=1},m_worldTime={m_gameTime=500}},
        }}
        EEex_CChitin={TIMER_UPDATES_PER_SECOND=30}
        EEex_GameState_AddDestroyedListener=function(fn) callbacks[#callbacks+1]=fn end
        EEex_Trigger_EvalConditionalStringAsAIBase=function() return false end
        EEex_Sprite_GetInPortrait=function(slot) return party[slot+1] end
        Infinity_GetClockTicks=function() return wall end
        Infinity_IsMenuOnStack=function(name) return stack[name] or 0 end
        Infinity_PushMenu=function(name) stack[name]=1 end
        Infinity_PopMenu=function(name) stack[name]=nil end
        Infinity_GetScreenSize=function() return 1920,1080 end
        Infinity_SetArea=function() end
        Infinity_SetOffset=function() end
        EEex_Menu_GetArea=function() return 0,1000,1000,80 end
        BfBot._Display=function(message) notices[#notices+1]=message end
        Infinity_DisplayString=BfBot._Display
        BfBot._Warn=function(message) warnings[#warnings+1]=message end
        BfBot.Persist._GetProtagonist=function() return party[1] end
        BfBot.Persist.GetConfig=function(sprite) return sprite.config end
        BfBot.Persist.GetPref=function(key)
            if key=='FastForward' then return speed end
            return 0
        end
        BfBot.Scan.GetCastableSpells=function(sprite) return sprite.book end
        BfBot.Exec._IsAlive=function(sprite) return sprite.alive end
        BfBot.Exec.GetState=function() return state end
        BfBot.Exec.Start=function(queue,mode,preset)
            if state=='running' then return false,'reason.exec.already_running',{} end
            starts[#starts+1]={queue=queue,mode=mode,preset=preset,
                rate=EEex_CChitin.TIMER_UPDATES_PER_SECOND}
            state='running'
            BfBot.Exec._log={}
            return true
        end
        BfBot.Exec.Stop=function() state='stopped';BfBot.Fast.Reset('stopped') end
        BfBot.UI._GetStatusText=function() return '' end
        BfBot.UI._T=function() return '{1, 2, 3}' end

        function prepareParty(size,mode)
            party={}
            for index=1,size do
                local sprite={m_id=100+index,name='Caster '..index,alive=true}
                sprite.countAllOfTypeStringInRange=function() return 0 end
                sprite.displayTextRef=function() notices[#notices+1]='busy' end
                sprite.book={
                    SHORT={name='Short protection',count=3,durCat='short',kind='spl'},
                    LONG={name='Long protection',count=4,durCat='long',kind='spl'},
                    ['itm:WARD:0']={name='Item ward',count=5,durCat='long',kind='itm',
                        leafResrefs={'WARDCHLD'}},
                    EMPTY={name='No casts',count=0,durCat='long',kind='spl'},
                    OFF={name='Disabled',count=3,durCat='short',kind='spl'},
                }
                sprite.config={ap=8,presets={
                    [1]={name='Unused preset',qc=0,spells={}},
                    [8]={name='Travel '..index,qc=mode,spells={
                        SHORT={on=1,tgt='s',pri=10,rep=1},
                        LONG={on=1,tgt='p',pri=20,rep=2,var='LONGALT'},
                        ['itm:WARD:0']={on=1,tgt='s',pri=30,rep=3,kind='itm'},
                        EMPTY={on=1,tgt='s',pri=1},
                        OFF={on=0,tgt='s',pri=2},
                    }},
                }}
                party[index]=sprite
            end
            BfBot.UI._view='party'
            BfBot.UI._charSlot=size-1
            BfBot.UI._presetIdx=8
            buffbot_isOpen=true
            buffbot_spellTable={
                {resref='SHORT',name='Short protection',pri=10,on=1,rep=1},
                {resref='LONG',name='Long protection',pri=20,on=1,rep=2},
                {resref='itm:WARD:0',name='Item ward',pri=30,on=1,rep=3},
            }
            BfBot.UI._RestoreSpellSelection()
        end

        function dispatch(route)
            if route=='panel_all' then BfBot.UI.Cast()
            elseif route=='panel_character' then BfBot.UI.CastCharacter()
            elseif route=='hud' then
                BfBot.UI._OpenActionbarBtn()
                BfBot.UI._ToggleQuickMenu()
                assert(BfBot.UI._QuickPresetName(2)=='Travel 1')
                BfBot.UI._CastQuickPreset(2)
            else error('Unknown test route') end
        end
    """)
    return ui_lua


@pytest.mark.parametrize("route", ["panel_all", "panel_character", "hud"])
@pytest.mark.parametrize("speed", [1, 2, 4])
@pytest.mark.parametrize("quick_cast", [0, 1, 2])
@pytest.mark.parametrize("party_size", [1, 6])
def test_all_routes_preserve_real_preset_queue_despite_empty_search(
    shortcut_lua, route, speed, quick_cast, party_size,
):
    runtime = shortcut_lua
    runtime.globals().speed = speed
    runtime.globals().route = route
    runtime.execute(f"prepareParty({party_size},{quick_cast})")
    runtime.execute("""
        buffbot_searchText='No such spell';BfBot.UI._SearchTick()
        assert(#buffbot_visibleSpells==0 and #buffbot_spellTable==3)
        dispatch(route)
    """)
    assert runtime.eval("#notices") == 0
    assert runtime.eval("#starts") == 1
    start = runtime.eval("starts[1]")
    assert start["preset"] == 8
    assert start["rate"] == 30 * speed
    assert start["mode"] == (quick_cast if speed == 1 else 0)
    expected_slots = range(party_size) if route in ("panel_all", "hud") else [party_size - 1]
    queue = start["queue"]
    assert len(queue) == len(expected_slots) * 3
    for group, slot in enumerate(expected_slots):
        for offset, (spell, target, repeat) in enumerate([
            ("SHORT", "self", 1), ("LONG", "all", 2), ("itm:WARD:0", "self", 3),
        ], 1):
            entry = queue[group * 3 + offset]
            assert (entry["caster"], entry["spell"], entry["target"], entry["rep"]) == (
                slot, spell, target, repeat,
            )
            assert entry["cheat"] == (None if speed == 1 else 0)
        assert queue[group * 3 + 2]["var"] == "LONGALT"
        assert queue[group * 3 + 3]["kind"] == "itm"
        assert queue[group * 3 + 3]["leafResrefs"][1] == "WARDCHLD"
    runtime.execute("""
        state='done';BfBot.Fast.CheckDone()
        assert(EEex_CChitin.TIMER_UPDATES_PER_SECOND==30 and BfBot.Fast.run==nil)
        assert(#buffbot_visibleSpells==0 and #buffbot_spellTable==3)
    """)
    for sprite in runtime.eval("party").values():
        assert sprite["config"]["presets"][8]["qc"] == quick_cast
        assert sprite["book"]["LONG"]["count"] == 4


@pytest.mark.parametrize("route", ["panel_all", "panel_character", "hud"])
@pytest.mark.parametrize("speed", [2, 4])
def test_fast_failure_never_dispatches_saved_quick_cast(shortcut_lua, route, speed):
    shortcut_lua.globals().speed = speed
    shortcut_lua.globals().route = route
    shortcut_lua.execute("""
        prepareParty(6,2)
        EngineGlobals.g_pBaldurChitin.cNetwork.m_bConnectionEstablished=1
        dispatch(route)
        assert(#starts==0 and #notices==1)
        assert(EEex_CChitin.TIMER_UPDATES_PER_SECOND==30 and BfBot.Fast.run==nil)
        assert(party[6].config.presets[8].qc==2)
    """)


@pytest.mark.parametrize("route", ["panel_all", "panel_character", "hud"])
def test_mixed_saved_quick_cast_uses_entrypoint_owner(shortcut_lua, route):
    shortcut_lua.globals().route = route
    shortcut_lua.execute("""
        prepareParty(6,0)
        party[1].config.presets[8].qc=1
        party[6].config.presets[8].qc=2
        dispatch(route)
    """)
    assert shortcut_lua.eval("starts[1].mode") == (1 if route == "hud" else 2)
    assert shortcut_lua.eval("party[1].config.presets[8].qc") == 1
    assert shortcut_lua.eval("party[6].config.presets[8].qc") == 2


@pytest.mark.parametrize("route", ["panel_all", "panel_character", "hud"])
@pytest.mark.parametrize("speed", [1, 2, 4])
def test_busy_dispatch_cannot_replace_active_queue_or_rate(shortcut_lua, route, speed):
    shortcut_lua.globals().speed = speed
    shortcut_lua.globals().route = route
    shortcut_lua.execute("""
        prepareParty(6,2)
        dispatch(route)
        local first=starts[1]
        party[6].config.presets[8].spells.SHORT.on=0
        dispatch(route)
        assert(#starts==1 and starts[1]==first)
        assert(EEex_CChitin.TIMER_UPDATES_PER_SECOND==30*speed)
        assert(first.queue[1].spell=='SHORT')
    """)


@pytest.mark.parametrize("route", ["panel_all", "panel_character", "hud"])
@pytest.mark.parametrize("speed", [1, 2, 4])
@pytest.mark.parametrize("module", ["nil", "{}"])
def test_missing_speed_module_refuses_acceleration_without_quick_cast_fallback(
    shortcut_lua, route, speed, module,
):
    shortcut_lua.globals().speed = speed
    shortcut_lua.globals().route = route
    shortcut_lua.execute(f"prepareParty(6,2);BfBot.Fast={module};dispatch(route)")
    assert shortcut_lua.eval("EEex_CChitin.TIMER_UPDATES_PER_SECOND") == 30
    if speed == 1:
        assert shortcut_lua.eval("#starts") == 1
        assert shortcut_lua.eval("starts[1].mode") == 2
        assert shortcut_lua.eval("#notices") == 0
    else:
        assert shortcut_lua.eval("#starts") == 0
        assert shortcut_lua.eval("#notices") == 1
        assert shortcut_lua.eval("notices[1]") == shortcut_lua.eval(
            "BfBot.L10N.Get('reason.exec.fast_unavailable')"
        )


@pytest.mark.parametrize("route", ["panel_character", "hud"])
@pytest.mark.parametrize("speed", [1, 2, 4])
def test_filtered_toggle_changes_only_selected_characters_real_queue(
    shortcut_lua, route, speed,
):
    shortcut_lua.globals().speed = speed
    shortcut_lua.globals().route = route
    shortcut_lua.execute("""
        prepareParty(6,2)
        buffbot_searchText='long';BfBot.UI._SearchTick()
        assert(#buffbot_visibleSpells==1)
        buffbot_visibleSelectedRow=1
        rowNumber=3 -- stale native row must not toggle the item
        BfBot.UI._OnVisibleSpellRowAction(1)
        assert(party[6].config.presets[8].spells.LONG.on==0)
        assert(party[6].config.presets[8].spells['itm:WARD:0'].on==1)
        assert(party[1].config.presets[8].spells.LONG.on==1)
        dispatch(route)
        assert(#starts==1)
        local queue=starts[1].queue
        assert(queue[#queue-1].caster==5 and queue[#queue-1].spell=='SHORT')
        assert(queue[#queue].caster==5 and queue[#queue].spell=='itm:WARD:0')
    """)
    assert shortcut_lua.eval("#starts[1].queue") == (17 if route == "hud" else 2)
