"""Recipient allocation, shared pools, persistence, and UI behavior in LuaJIT."""
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def lua():
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("BfBot = { Persist = {} }")
    runtime.execute((ROOT / "buffbot/BfBotPln.lua").read_text(encoding="utf-8"))
    runtime.execute(
        """
        P = BfBot.Plan
        function snapshot()
            return { actors = { A = { name = "A", alive = true, slot = 0 },
                B = { name = "B", alive = true, slot = 1 } },
                groups = {}, pools = {}, order = {} }
        end
        function source(snap, group, actor, duration, pool, count, options)
            local s = { id = actor .. '/' .. group, actor = actor,
                casterName = actor, slot = actor == "A" and 0 or 1,
                duration = duration, casterLevel = 1, pool = pool,
                row = { resref = group, kind = 'spl' } }
            for k,v in pairs(options or {}) do s[k] = v end
            snap.groups[group] = snap.groups[group] or { name = group, sources = {} }
            table.insert(snap.groups[group].sources, s)
            snap.pools[pool] = count
            return s
        end
        function request(group, target, actor, variant)
            return { group = group, target = target, source = actor, var = variant, on = 1 }
        end
        """
    )
    return runtime


def test_earlier_recipient_keeps_longer_source_when_both_can_be_satisfied(lua):
    facts = lua.execute(
        """
        local s = snapshot()
        source(s, 'BUFF', 'A', 1800, 'a', 1)
        source(s, 'BUFF', 'B', 1200, 'b', 1)
        local result = P.Assign(s, {request('BUFF','A'), request('BUFF','B')})
        return result.decisions[1].source.actor, result.decisions[2].source.actor,
            result.decisions[1].duration, result.missing, s.pools.a
        """
    )
    assert facts == ("A", "B", 1800, 0, 1)


def test_augmenting_assignment_saves_a_source_needed_by_a_self_only_request(lua):
    facts = lua.execute(
        """
        local s = snapshot()
        source(s, 'BUFF', 'A', 1800, 'a', 1)
        source(s, 'BUFF', 'B', 1200, 'b', 1, {selfOnly=true})
        local result = P.Assign(s, {request('BUFF','B'), request('BUFF','A')})
        return result.decisions[1].source.actor, result.decisions[2].source.actor,
            result.used.a, result.used.b, result.missing
        """
    )
    assert facts == ("B", "A", 1, 1, 0)


def test_shared_spontaneous_pool_is_spent_across_different_buffs(lua):
    facts = lua.execute(
        """
        local s = snapshot()
        source(s, 'BLUR', 'A', 60, 'level2', 2)
        source(s, 'MIRROR', 'A', 60, 'level2', 2)
        local requests = {request('BLUR','A'), request('MIRROR','A'), request('BLUR','B')}
        local plan = P.Assign(s, requests)
        local queue = P.BuildQueue(s, requests)
        return plan.used.level2, plan.missing, plan.decisions[3].reason, queue == nil
        """
    )
    assert facts == (2, 1, "No unreserved uses", True)


def test_pinned_caster_cannot_be_rerouted_to_another_caster(lua):
    facts = lua.execute(
        """
        local s = snapshot()
        source(s,'BUFF','A',1800,'a',1)
        source(s,'BUFF','B',1200,'b',1)
        local plan = P.Assign(s,{request('BUFF','A','A'),request('BUFF','B','A')})
        return plan.decisions[1].source.actor, plan.decisions[2].source == nil, plan.missing
        """
    )
    assert facts == ("A", True, 1)


@pytest.mark.parametrize("options,target,reason", [
    ("{selfOnly=true}", "B", "Self only"),
    ("{aoe=true}", "A", "Party-wide cast"),
    ("{}", "party", "Choose a recipient"),
    ("{reason='Cannot equip'}", "A", "Cannot equip"),
])
def test_target_and_eligibility_constraints(lua, options, target, reason):
    lua.globals().options = lua.eval(options)
    lua.globals().target = target
    result = lua.execute(
        """
        local s=snapshot()
        source(s,'BUFF','A',60,'a',3,options)
        return P.Assign(s,{request('BUFF',target)}).decisions[1].reason
        """
    )
    assert result == reason


def test_party_buff_spends_one_use_and_builds_one_cast(lua):
    facts = lua.execute(
        """
        local s=snapshot()
        source(s,'BLESS','A',60,'a',1,{aoe=true})
        local queue,plan=P.BuildQueue(s,{request('BLESS','party')})
        return #queue,queue[1].target,plan.used.a
        """
    )
    assert facts == (1, "all", 1)


def test_variant_uses_parent_pool_and_source_specific_duration(lua):
    facts = lua.execute(
        """
        local s=snapshot()
        source(s,'CHOICE','A',0,'a',1,{variants={{resref='FIRE'}},variantDurations={FIRE=120}})
        source(s,'CHOICE','B',0,'b',1,{variants={{resref='COLD'}},variantDurations={COLD=240}})
        local plan=P.Assign(s,{request('CHOICE','A',nil,'FIRE'),request('CHOICE','B',nil,'FIRE')})
        local missing=P.Assign(s,{request('CHOICE','A')})
        return plan.decisions[1].source.actor,plan.decisions[1].duration,plan.missing,
            missing.decisions[1].reason
        """
    )
    assert facts == ("A", 120, 1, "Choose a supported variant")


def test_spell_pool_keys_distinguish_prepared_and_spontaneous_sources(lua):
    facts = lua.execute(
        """
        local row={resref='BLUR',spellType=1,level=2}
        local sorcerer=P.SpellPool({key='A',class=19},row)
        local mage=P.SpellPool({key='A',class=1},row)
        local shaman=P.SpellPool({key='B',class=21},{resref='CHANT',spellType=2,level=2})
        local unsupported,reason=P.SpellPool({key='A',class=19},{d5={}})
        return sorcerer,mage,shaman,unsupported,reason
        """
    )
    assert facts == ("A:level:1:2", "A:spell:BLUR", "B:level:2:2", None,
                     "5E sources require the caster editor")


def test_snapshot_uses_concrete_item_counters_and_conservative_shared_spell_counts(lua):
    facts = lua.execute(
        """
        local sprite={m_typeAI={m_Class=19},name='A'}
        EEex_Sprite_GetInPortrait=function(i) if i==0 then return sprite end end
        EEex_Sprite_GetCharacterIndex=function() return 0 end
        BfBot._GetName=function(s) return s.name end
        BfBot.Exec={_IsAlive=function() return true end}
        BfBot.Persist={GetPref=function() return 'inventory' end}
        local function spell(res,count)
            return {resref=res,kind='spl',name=res,count=count,level=2,spellType=1,
                duration=60,class={isBuff=true}}
        end
        local function item(index)
            return {resref='itm:GEAR:'..index,kind='itm',itemResref='GEAR',abilityIdx=index,
                name='Gear',count=2,itemType=4,isSelfOnly=1,class={isBuff=true},
                sources={{slot=20,count=2}}}
        end
        BfBot.Scan={GetCastableSpells=function()
            return {BLUR=spell('BLUR',3),MIRROR=spell('MIRROR',2),ONE=item(0),FOUR=item(3)}
        end}
        local s=P.Snapshot()
        local one=s.groups['itm:GEAR:0'].sources[1]
        local four=s.groups['itm:GEAR:3'].sources[1]
        return s.pools['protagonist:level:1:2'],one.pool==four.pool,
            s.pools[one.pool],one.itemSlot
        """
    )
    assert facts == (2, True, 2, 20)


def test_dead_or_ambiguous_recipient_is_not_assigned(lua):
    assert lua.execute(
        """
        local s=snapshot()
        source(s,'BUFF','A',60,'a',3)
        s.actors.B.ambiguous=true
        return P.Assign(s,{request('BUFF','B')}).missing
        """
    ) == 1


def test_marshal_roundtrip_uses_a_separate_validated_state(lua):
    facts = lua.execute(
        """
        local exports,imports,aux={},{},{}
        EEex={IsMarshallingCopy=function() return false end}
        EEex_GetUDAux=function(sprite) aux[sprite]=aux[sprite] or {};return aux[sprite] end
        EEex_Sprite_AddMarshalHandlers=function(name,e,i) exports[name],imports[name]=e,i end
        local source,target={},{}
        P.Init(); P.Init()
        aux[source]={BB={legacy=1},BBParty=P.Validate({active=3,presets={[3]={
            name='Boss',requests={request('BUFF','dv:ANOMEN','protagonist','VAR')}}}})}
        imports.BuffBotParty(target,exports.BuffBotParty(source))
        local r=aux[target].BBParty.presets[3].requests[1]
        return aux[target].BBParty.active,r.source,r.target,r.var,
            aux[source].BB.legacy,aux[target].BB==nil
        """
    )
    assert facts == (3, "protagonist", "dv:ANOMEN", "VAR", 1, True)


def test_request_limit_rejects_partial_execution(lua):
    assert lua.execute(
        """
        local s=snapshot()
        source(s,'BUFF','A',60,'a',1000)
        local requests={}
        for i=1,257 do requests[i]=request('BUFF','A') end
        local queue,_,reason=P.BuildQueue(s,requests)
        return queue==nil and reason=='Plan exceeds 256 requests'
        """
    )


def test_item_source_slot_survives_queue_construction(lua):
    facts = lua.execute(
        """
        local s=snapshot()
        source(s,'GEAR','A',60,'boots',1,{itemSlot=23,selfOnly=true})
        local q=P.BuildQueue(s,{request('GEAR','A')})
        return q[1].plannedItemSlot,q[1].plannedActor,q[1].plannedTarget,q[1].target
        """
    )
    assert facts == (23, "A", "A", "self")


def test_ui_recipient_toggle_preview_uses_reservations_and_keeps_selection(lua):
    lua.execute((ROOT / "buffbot/BfBotPUI.lua").read_text(encoding="utf-8"))
    facts = lua.execute(
        """
        local s=snapshot()
        s.order={{key='A',name='A'},{key='B',name='B'}}
        source(s,'BUFF','A',1800,'a',1)
        source(s,'BUFF','B',1200,'b',1)
        local state=P.Validate({presets={{name='Test',requests={}}}})
        P.GetState=function() return state end
        P.Snapshot=function() return s end
        BfBot.Scan={InvalidateAll=function() end}
        BfBot.Exec={GetState=function() return 'idle' end}
        local U=BfBot.PartyUI
        U.Refresh()
        bbPartyTargetSelection=2; U.ToggleTarget()
        local first=bbPartyTargets[2].assignment
        bbPartyTargetSelection=3; U.ToggleTarget()
        local second=bbPartyTargets[3].assignment
        bbPartyRequestSelection=1; U.SelectRequest()
        U.Move(1)
        local stillSelected=U.request==state.presets[1].requests[2]
        U.Remove()
        return first,second,stillSelected,#state.presets[1].requests,
            bbPartyBuffs[1].uses,U.CanCast()
        """
    )
    assert facts == ("A / 30.0m", "B / 20.0m", True, 1, "1/2", True)


def test_ui_caster_preference_cycles_back_to_auto(lua):
    lua.execute((ROOT / "buffbot/BfBotPUI.lua").read_text(encoding="utf-8"))
    facts = lua.execute(
        """
        local U=BfBot.PartyUI
        local s=snapshot()
        source(s,'BUFF','A',60,'a',1)
        source(s,'BUFF','B',60,'b',1)
        U.snapshot=s; U.request=request('BUFF','A')
        U.Refresh=function() end
        U.CycleSource();local first=U.request.source
        U.CycleSource();local second=U.request.source
        U.CycleSource()
        return first,second,U.request.source==nil
        """
    )
    assert facts == ("A", "B", True)


def test_catalog_duration_tracks_unreserved_sources_instead_of_spent_ones(lua):
    lua.execute((ROOT / "buffbot/BfBotPUI.lua").read_text(encoding="utf-8"))
    facts = lua.execute(
        """
        local s=snapshot()
        source(s,'BUFF','A',1800,'a',1)
        source(s,'BUFF','B',1200,'b',1)
        source(s,'BUFF','A',3600,'spent',0,{casterName='Spent'})
        local state=P.Validate({presets={{name='Test',requests={}}}})
        P.GetState=function() return state end;P.Snapshot=function() return s end
        BfBot.Scan={InvalidateAll=function() end}
        BfBot.Exec={GetState=function() return 'idle' end}
        local U=BfBot.PartyUI
        U.Refresh();local before=bbPartyBuffs[1].duration
        state.presets[1].requests={request('BUFF','A')}
        U.Refresh();local afterFirst=bbPartyBuffs[1].duration
        state.presets[1].requests[2]=request('BUFF','B')
        U.Refresh()
        return before,afterFirst,bbPartyBuffs[1].duration,bbPartyBuffs[1].casters,
            U.plan.decisions[1].duration,U.plan.decisions[2].duration
        """
    )
    assert facts == ("20.0m - 30.0m", "20.0m", "No unreserved uses", "A, B", 1800, 1200)


def test_improved_invisible_recipient_warns_without_blocking_spell_exceptions(lua):
    lua.execute((ROOT / "buffbot/BfBotPUI.lua").read_text(encoding="utf-8"))
    facts = lua.execute(
        """
        local s=snapshot()
        s.actors.A.improvedInvisible=true;s.actors.B.improvedInvisible=true
        source(s,'BUFF','A',60,'a',1)
        local state=P.Validate({presets={{name='Test',requests={request('BUFF','B')}}}})
        P.GetState=function() return state end;P.Snapshot=function() return s end
        BfBot.Scan={InvalidateAll=function() end}
        BfBot.Exec={GetState=function() return 'idle' end}
        local U=BfBot.PartyUI
        U.Refresh();bbPartyRequestSelection=1;U.SelectRequest()
        local warning=bbPartyDetails:find('the engine may reject this cast',1,true)~=nil
        local assignment=bbPartyRequests[1].assignment
        local canCast=U.CanCast()
        state.presets[1].requests[1].target='A';U.Refresh()
        return warning,assignment,canCast,bbPartyRequests[1].assignment
        """
    )
    assert facts == (True, "A / 1.0m / improved invisible", True, "A / 1.0m")


def test_selecting_a_planned_buff_updates_the_catalog_and_recipient_context(lua):
    lua.execute((ROOT / "buffbot/BfBotPUI.lua").read_text(encoding="utf-8"))
    facts = lua.execute(
        """
        local s=snapshot()
        source(s,'FIRST','A',60,'a',1);source(s,'SECOND','A',120,'b',1)
        local state=P.Validate({presets={{name='Test',requests={request('SECOND','B')}}}})
        P.GetState=function() return state end;P.Snapshot=function() return s end
        BfBot.Scan={InvalidateAll=function() end}
        BfBot.Exec={GetState=function() return 'idle' end}
        local U=BfBot.PartyUI
        U.Refresh();local before=U.group
        bbPartyRequestSelection=1;U.SelectRequest()
        return before,U.group,bbPartyBuffs[bbPartyBuffSelection].key,
            U.request==state.presets[1].requests[1],bbPartyRequestSelection
        """
    )
    assert facts == ("FIRST", "SECOND", "SECOND", True, 1)


def test_equal_duration_prefers_effective_caster_level(lua):
    assert lua.execute(
        """
        local s=snapshot()
        source(s,'BUFF','A',60,'a',1,{casterLevel=10})
        source(s,'BUFF','B',60,'b',1,{casterLevel=20})
        return P.Assign(s,{request('BUFF','A')}).decisions[1].source.actor
        """
    ) == "B"


def test_disabled_requests_do_not_reserve_resources(lua):
    facts = lua.execute(
        """
        local s=snapshot()
        source(s,'BUFF','A',60,'a',1)
        local disabled=request('BUFF','A');disabled.on=0
        local p=P.Assign(s,{disabled,request('BUFF','B')})
        return p.missing,p.used.a,p.decisions[1].reason,p.decisions[2].source.actor
        """
    )
    assert facts == (0, 1, "Disabled", "A")


def test_image_safeguard_receives_each_casters_own_chain(lua):
    facts = lua.execute(
        """
        local s=snapshot()
        source(s,'ONE','A',60,'a',1)
        source(s,'TWO','B',60,'b',1)
        s.order={{key='A',name='A',sprite={m_id=10}}, {key='B',name='B',sprite={m_id=20}}}
        BfBot.Persist._CollectLiveCloneDescriptors=function() return {} end
        local calls={}
        BfBot.Persist._ApplyPuppetLockPolicy=function(caster,entries,clones)
            assert(#entries==1 and entries[1].plannedActor==caster.name)
            calls[#calls+1]=caster.oid
            return entries,{}
        end
        local queue=P.BuildQueue(s,{request('ONE','A'),request('TWO','B')})
        return #queue,table.concat(calls,',')
        """
    )
    assert facts == (2, "10,20")


def test_execution_rejects_replaced_party_member_before_spending_anything(lua):
    lua.execute((ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8"))
    facts = lua.execute(
        """
        local E=BfBot.Exec
        E._state='running';E._skipCount=0
        E._LogEntry=function() end
        P.ActorKey=function(sprite) return sprite.key end
        EEex_Sprite_GetInPortrait=function() return {key='REPLACED'} end
        local caster={key='A'}
        local entry={casterName='A',spellName='Buff',targetName='B',
            plannedActor='A',plannedTarget='B',targetSlot=1}
        local result=E._CheckEntry(entry,caster)
        return result,E._skipCount
        """
    )
    assert facts == (False, 1)


def test_planned_item_use_keeps_the_reserved_copy_and_does_not_mutate_catalog(lua):
    lua.execute((ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8"))
    facts = lua.execute(
        """
        local E=BfBot.Exec
        local actions={}
        E._castCount=0;E._LogEntry=function() end
        BfBot.Persist.GetItemSwap=function() return nil end
        BfBot.Persist.GetPref=function() return 'inventory' end
        EEex_Action_QueueResponseStringOnAIBase=function(action) actions[#actions+1]=action end
        local row={kind='itm',itemSlot=18,abilityIdx=1,
            sources={{slot=18,count=1},{slot=23,count=1}}}
        local entry={plannedItemSlot=23,targetObj='Myself',spellName='Power',
            casterName='A',targetName='A'}
        local used=E._QueueItem('p0',{},entry,row,{},'NEXT')
        row.sources[2].count=0
        local unavailable=E._QueueItem('p0',{},entry,row,{},'NEXT')
        return used,actions[1],row.itemSlot,unavailable,E._castCount
        """
    )
    assert facts == (True, "UseItemSlotAbility(Myself,23,1)", 18, False, 1)


def test_ui_refreshes_availability_again_before_casting(lua):
    lua.execute((ROOT / "buffbot/BfBotPUI.lua").read_text(encoding="utf-8"))
    facts = lua.execute(
        """
        local s=snapshot()
        source(s,'BUFF','A',60,'a',1)
        local state=P.Validate({presets={{name='Test',requests={request('BUFF','A')}}}})
        P.GetState=function() return state end;P.Snapshot=function() return s end
        BfBot.Scan={InvalidateAll=function() end}
        local starts=0
        BfBot.Exec={GetState=function() return 'idle' end,Start=function() starts=starts+1 end}
        local U=BfBot.PartyUI
        U.Refresh();local preview=U.CanCast()
        s.pools.a=0
        U.Cast()
        return preview,starts,U.plan.missing
        """
    )
    assert facts == (True, 0, 1)


def test_all_new_menu_callbacks_compile_and_use_label_columns(lua):
    menu = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")
    party = menu.split('-- Recipient-first party planner (single-player beta).', 1)[1]
    assert party.count('\n\tlist\n') == 5  # dashboard, coverage, summary, order, popup
    assert 'table "bbPartyRows"' in party
    assert 'table "bbPartyTargets"' not in party
    assert 'name "bpDetails"' not in party
    assert 'text color {230' not in party
    import re
    runtime = lua
    runtime.execute((ROOT / "buffbot/BfBotPUI.lua").read_text(encoding="utf-8"))
    for kind, expression in re.findall(r'\b(action|enabled|onopen|text lua|text color lua)\s+"([^"]*)"', party):
        code = 'return ' + expression if kind in {'enabled', 'text lua', 'text color lua'} else expression
        runtime.execute('assert(loadstring(...))', code)
        if kind == 'text color lua':
            runtime.execute('bbPartyTargets={}; bbPartyRequests={}; rowNumber=1')
            color = runtime.execute(code)
            assert all(0 <= color[channel] <= 255 for channel in (1, 2, 3))
    assert 'BfBot.PartyUI.DashboardClick(cellNumber)' in party
    # Native lists support label columns; child buttons do not receive clicks.
    for column in re.findall(r'\bcolumn\s*\{(.*?)\n\t\t\}', party, re.S):
        assert not re.search(r'\bbutton\s*\{', column)
