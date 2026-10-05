"""Queued engine simulation for inventory item use and reversible equipment swaps."""

from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]


def _runtime() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        BfBot = {
            MAX_PRESETS = 8, MAX_SPELL_REPEATS = 5,
            _cache = { scan = {}, class = {} }, _overrides = {}, _fields = {},
            Class = {}, Scan = {}, Persist = {}, Innate = {}, Mp = {},
            _Print = function() end, _CloseLog = function() end,
            _StripColorEscape = function(s) return s end,
            _GetName = function() return "Wearer" end,
        }
        warnings, actions, history, uses, advances = {}, {}, {}, {}, {}
        headers, pointers, bytes, words, dwords, slots, stats = {}, {}, {}, {}, {}, {}, {}
        kitRows, itemTypeSlots = {}, {}
        Item_ability_st, Item_effect_st = { sizeof = 56 }, { sizeof = 48 }
        local nextPtr = 10000
        BfBot._Warn = function(message) warnings[#warnings+1] = message end
        local function allocate(value)
            value.ptr, nextPtr = nextPtr, nextPtr + 10000
            pointers[value.ptr] = value
            return value
        end
        function defineItem(resref, category)
            local header = allocate({
                itemType = category, abilityCount = 2, abilityOffset = 0x72,
                effectsOffset = 0x100, identifiedName = 1,
            })
            headers[resref] = header
            for i = 0, 1 do
                local ptr = header.ptr + header.abilityOffset + i * 56
                pointers[ptr] = { ptr = ptr,
                    quickSlotIcon = { get = function() return "ICON" end } }
                bytes[ptr], bytes[ptr+2], bytes[ptr+0xC] = 3, 3, 5
                words[ptr+0x22] = 1
            end
            return header
        end
        function placeItem(slot, resref, flags)
            local item = allocate({
                m_flags = flags or 1,
                pRes = { resref = { get = function() return resref end } },
            })
            words[item.ptr+0x1C], words[item.ptr+0x1E] = 2, 2
            slots[slot] = item
            return item
        end
        sprite = {
            m_id = 100, m_typeAI = { m_Class = 2, m_Race = 1, m_Alignment = 0x11 },
            m_baseStats = { m_generalState = 0 }, m_timedEffectList = {},
            m_equipment = {
                m_selectedWeapon = 36, m_selectedWeaponAbility = 2,
                m_items = { get = function(_, slot) return slots[slot] end },
            },
            GetQuickButtons = function() return nil end,
            getStat = function(_, stat) return stats[stat] or 0 end,
        }
        for _, stat in ipairs({36,38,39,40,41,42}) do stats[stat] = 18 end
        stats[34], stats[152] = 10, 0
        aux = { BB = { v=10, ap=1,
            presets = { {name="Test", cat="custom", qc=0, spells={}} },
            opts={skip=1}, ovr={}, summons={} } }
        EEex_GetUDAux = function(value) assert(value == sprite); return aux end
        EEex = { IsMarshallingCopy = function() return false end }
        EEex_Sprite_GetInPortrait = function(slot) if slot == 0 then return sprite end end
        EEex_Sprite_GetPortraitIndex = function() return 0 end
        EEex_UDToPtr = function(value) return assert(value.ptr) end
        EEex_PtrToUD = function(ptr) return assert(pointers[ptr]) end
        EEex_ReadU8 = function(address) return bytes[address] or 0 end
        EEex_ReadU16 = function(address) return words[address] or 0 end
        EEex_ReadU32 = function(address) return dwords[address] or 0 end
        EEex_BAnd = bit.band
        EEex_Resource_Demand = function(resref, kind)
            assert(kind == "ITM"); return headers[resref]
        end
        EEex_Resource_Load2DA = function(resref)
            if resref == "ITEMTYPE" then return {
                findColumnLabel = function(_, label) assert(label == "SLOT"); return 0 end,
                findRowLabel = function(_, label) return tonumber(label) end,
                getAtPoint = function(_, _, category) return itemTypeSlots[category] or -1 end,
            } end
            if resref == "KITLIST" then return {
                findColumnLabel = function(_, label) return label == "KITIDS" and 1 or 2 end,
                getDimensions = function() return 2, #kitRows end,
                getAtPoint = function(_, col, row) return kitRows[row+1][col] end,
            } end
            return { getDimensions = function() return 0, 0 end }
        end
        Infinity_FetchString = function() return "Item" end
        Infinity_GetClockTicks = function() return 100 end
        prefs = { ItemUseMode = "swap", CombatInterrupt = 0 }
        Infinity_GetINIString = function(_, key, default) return prefs[key] or default end
        Infinity_GetINIValue = function(_, key, default)
            if prefs[key] ~= nil then return prefs[key] end
            return default
        end
        EEex_Utility_IterateCPtrList = function(list, callback)
            for _, effect in ipairs(list) do if callback(effect) then break end end
        end
        local function emptyIterator() return function() return nil end end
        EEex_Sprite_GetKnownMageSpellsWithAbilityIterator = emptyIterator
        EEex_Sprite_GetKnownPriestSpellsWithAbilityIterator = emptyIterator
        EEex_Sprite_GetKnownInnateSpellsWithAbilityIterator = emptyIterator
        EEex_Action_QueueResponseStringOnAIBase = function(action, who)
            assert(who == sprite); actions[#actions+1] = action
        end
        BfBot.Class.Classify = function()
            return { isBuff=true, isSelfOnly=true }
        end
        BfBot.Class.GetDuration = function() return 30,nil,{} end
        BfBot.Class.GetDurationCategory = function() return "short" end
        BfBot.Class._IterateFeatureBlocks = function() end
        BfBot.Class.SetOverride = function() end
        io = nil
        """
    )
    for name in ("BfBotScn.lua", "BfBotPer.lua", "BfBotExe.lua"):
        lua.execute((ROOT / "buffbot" / name).read_text(encoding="utf-8"))
    lua.execute(
        """
        -- Leave advance itself outside the one-item transaction, but record
        -- the actual gear state when the queued advance finally executes.
        BfBot.Exec._Advance = function(key)
            advances[#advances+1] = {
                key=key, weapon=sprite.m_equipment.m_selectedWeapon,
                ability=sprite.m_equipment.m_selectedWeaponAbility,
                noJournal=BfBot.Persist.GetItemSwap(sprite) == nil,
            }
        end
        function step()
            local action = table.remove(actions, 1)
            assert(action, "no queued engine action")
            history[#history+1] = action
            local item, destination = action:match('^XEquipItem%("([^"]+)",Myself,(%d+),1%)$')
            if item then
                destination = tonumber(destination)
                local source
                for i = 0, 38 do
                    if slots[i] and slots[i].pRes.resref:get() == item then
                        assert(source == nil, "mock engine refuses ambiguous item")
                        source = i
                    end
                end
                assert(source ~= nil, "mock engine item missing")
                slots[source], slots[destination] = slots[destination], slots[source]
                if destination >= 35 then
                    sprite.m_equipment.m_selectedWeapon = destination
                    sprite.m_equipment.m_selectedWeaponAbility = 0
                end
                return action
            end
            local target, slot, ability = action:match('^UseItemSlotAbility%(([^,]+),(%d+),(%d+)%)$')
            if target then
                slot, ability = tonumber(slot), tonumber(ability)
                local used = assert(slots[slot], "activated empty slot")
                uses[#uses+1] = { item=used, slot=slot, ability=ability, target=target }
                if consumeOnUse then slots[slot] = nil end
                return action
            end
            local weapon, ability = action:match('^SelectWeaponAbility%((%d+),(%d+)%)$')
            if weapon then
                sprite.m_equipment.m_selectedWeapon = tonumber(weapon)
                sprite.m_equipment.m_selectedWeaponAbility = tonumber(ability)
                return action
            end
            local callback = action:match('^EEex_LuaAction%("(.*)"%)$')
            assert(callback, "unexpected engine action: " .. action)
            assert(loadstring(callback))()
            return action
        end
        function drain()
            local count=0
            while #actions > 0 do
                count=count+1; assert(count < 30, "queued action loop")
                step()
            end
        end
        function setupSwap(category)
            defineItem("NEW", category or 32)
            defineItem("OLD", category or 32)
            newItem = placeItem(21, "NEW")
            oldItem = placeItem(category == 26 and 35 or 4, "OLD")
            if category == 26 then
                for i=36,38 do
                    defineItem("W"..i,26); placeItem(i,"W"..i)
                end
            end
            row = {kind="itm",itemResref="NEW",itemSlot=21,itemType=category or 32,abilityIdx=1}
            entry = {kind="itm",resref="itm:NEW:1",itemResref="NEW",abilityIdx=1,
                casterName="Wearer",spellName="Power",targetName="Wearer",
                targetObj="Myself",targetSprite=sprite,leafResrefs={"NEW"}}
            caster = {ref={kind="party",slot=0},queue={entry},index=1,
                name="Wearer",done=false,cheatApplied=false}
            BfBot.Exec._casters.p0 = caster
            BfBot.Exec._state = "running"
        end
        function queueSwap()
            return BfBot.Exec._QueueItem("p0",caster,entry,row,sprite,
                'EEex_LuaAction("BfBot.Exec._Advance([[p0]])")')
        end
        """
    )
    return lua


@pytest.mark.parametrize("restriction,reason", [
    ("dwords[h.ptr+0x1E]=0x800", "cannot be worn"),
    ("dwords[h.ptr+0x1E]=0x08000000", "cannot be worn"),
    ("dwords[h.ptr+0x1E]=0x10", "cannot be worn"),
    ("words[h.ptr+0x26]=19", "minimum ability"),
    ("bytes[h.ptr+0x28]=50", "minimum strength"),
    ("words[h.ptr+0x24]=11", "minimum level"),
    ("words[h.ptr+0x70]=1;words[h.ptr+h.effectsOffset]=319", "conditional"),
    ("bytes[h.ptr+0x2F]=1;kitRows={{0,1}}", "kit restriction"),
])
def test_character_eligibility_rejects_ineligible_item(restriction: str, reason: str) -> None:
    lua = _runtime()
    facts = lua.execute(
        'local h=defineItem("NEW",32)\n' + restriction
        + '\nlocal allowed, reason=BfBot.Scan._CanWearItem(sprite,h)\n'
        'return {allowed=allowed,reason=reason}'
    )
    assert not facts["allowed"]
    assert reason in facts["reason"]


def test_eligibility_allows_met_requirements_and_unrestricted_kit() -> None:
    facts = _runtime().execute(
        """
        local h=defineItem("NEW",32)
        dwords[h.ptr+0x1E]=0x40000 -- denies mage, this character is a fighter
        words[h.ptr+0x26]=18; words[h.ptr+0x24]=10
        bytes[h.ptr+0x2F]=1; kitRows={{0,2}}
        return {allowed=BfBot.Scan._CanWearItem(sprite,h)}
        """
    )
    assert facts["allowed"]


@pytest.mark.parametrize("category,mapped", [(2, -1), (60, -1), (68, -1), (99, 1)])
def test_chest_piece_never_gets_an_automatic_equipment_destination(category: int, mapped: int) -> None:
    lua = _runtime()
    lua.globals().category, lua.globals().mapped = category, mapped
    assert lua.execute(
        'itemTypeSlots[category]=mapped; return #BfBot.Scan._ItemEquipSlots(defineItem("NEW",category))'
    ) == 0


@pytest.mark.parametrize("change,reason", [
    ('newItem.m_flags=9', "cursed or undroppable"),
    ('dwords[headers.NEW.ptr+0x18]=0x10', "cursed or undroppable"),
    ('oldItem.m_flags=9', "no safe equipment slot"),
    ('dwords[headers.OLD.ptr+0x18]=0x10', "no safe equipment slot"),
    ('placeItem(22,"NEW")', "duplicate equipment"),
    ('placeItem(22,"OLD")', "no safe equipment slot"),
])
def test_swap_plan_rejects_cursed_undroppable_and_ambiguous_items(change: str, reason: str) -> None:
    facts = _runtime().execute(
        'setupSwap()\n' + change
        + '\nlocal plan, reason=BfBot.Scan._PlanItemSwap(sprite,row)\n'
        'return {plan=plan,reason=reason,untouched=slots[21]==newItem and slots[4]==oldItem}'
    )
    assert facts["plan"] is None
    assert reason in facts["reason"]
    assert facts["untouched"]


def test_ring_plan_prefers_empty_slot_and_keeps_equipment_untouched() -> None:
    facts = _runtime().execute(
        """
        defineItem("NEW",10); defineItem("OLD",10)
        local source=placeItem(21,"NEW"); local old=placeItem(7,"OLD")
        local plan=BfBot.Scan._PlanItemSwap(sprite,{itemResref="NEW",itemSlot=21})
        return {equip=plan.equip,pack=plan.pack,previous=plan.previous,
            untouched=slots[21]==source and slots[7]==old and slots[8]==nil}
        """
    )
    assert facts["equip"] == 8 and facts["pack"] == 21
    assert facts["previous"] == "" and facts["untouched"]


def test_physical_swap_use_restore_precedes_next_entry_and_restores_weapon_selection() -> None:
    facts = _runtime().execute(
        """
        setupSwap(26)
        local queued=queueSwap()
        local untouchedBeforeEngine=slots[21]==newItem and slots[35]==oldItem
        step() -- actual XEquip exchange
        local moved=slots[35]==newItem and slots[21]==oldItem
        local selectedDuringSwap=sprite.m_equipment.m_selectedWeapon
        drain()
        return {queued=queued,untouchedBeforeEngine=untouchedBeforeEngine,moved=moved,
            selectedDuringSwap=selectedDuringSwap,restored=slots[21]==newItem and slots[35]==oldItem,
            usedCorrectItem=uses[1].item==newItem,useSlot=uses[1].slot,useAbility=uses[1].ability,
            useCount=#uses,advanceCount=#advances,weapon=advances[1].weapon,
            weaponAbility=advances[1].ability,noJournal=advances[1].noJournal,
            tokenCleared=caster.itemToken==nil,warnings=#warnings,castCount=BfBot.Exec._castCount,
            actionSequence=table.concat(history,"|")}
        """
    )
    assert facts["queued"] and facts["untouchedBeforeEngine"] and facts["moved"]
    assert facts["selectedDuringSwap"] == 35
    assert facts["restored"] and facts["usedCorrectItem"]
    assert facts["useSlot"] == 35 and facts["useAbility"] == 1
    assert facts["useCount"] == facts["advanceCount"] == facts["castCount"] == 1
    assert facts["weapon"] == 36 and facts["weaponAbility"] == 2
    assert facts["noJournal"] and facts["tokenCleared"]
    assert facts["warnings"] == 0
    sequence = facts["actionSequence"]
    assert sequence.index('XEquipItem("NEW",Myself,35,1)') < sequence.index("UseItemSlotAbility")
    assert sequence.index("UseItemSlotAbility") < sequence.index('XEquipItem("NEW",Myself,21,1)')
    assert sequence.index('XEquipItem("NEW",Myself,21,1)') < sequence.index("SelectWeaponAbility(36,2)")
    assert sequence.index("SelectWeaponAbility(36,2)") < sequence.index("_Advance")


@pytest.mark.parametrize("steps_before_stop", [0, 1])
def test_stop_recovers_when_forward_swap_is_pending_or_has_executed(steps_before_stop: int) -> None:
    lua = _runtime()
    lua.globals().stepsBeforeStop = steps_before_stop
    facts = lua.execute(
        """
        setupSwap(); assert(queueSwap())
        for _=1,stepsBeforeStop do step() end
        BfBot.Exec.Stop(); drain()
        return {restored=slots[21]==newItem and slots[4]==oldItem,
            used=#uses,advanced=#advances,noJournal=BfBot.Persist.GetItemSwap(sprite)==nil,
            stopped=BfBot.Exec._state=="stopped",warnings=#warnings}
        """
    )
    assert facts["restored"] and facts["noJournal"] and facts["stopped"]
    assert facts["used"] == facts["advanced"] == facts["warnings"] == 0


@pytest.mark.parametrize("steps_before_cancel", [4, 5])
def test_recovery_finishes_when_restore_exchange_or_its_completion_was_canceled(steps_before_cancel: int) -> None:
    lua = _runtime()
    lua.globals().stepsBeforeCancel = steps_before_cancel
    facts = lua.execute(
        """
        setupSwap(); assert(queueSwap())
        for _=1,stepsBeforeCancel do step() end
        local phaseBefore=BfBot.Persist.GetItemSwap(sprite).phase
        actions={} -- native movement clears the pending action queue
        BfBot.Exec.Stop(); drain()
        local exchanges=0
        for _,action in ipairs(history) do
            if action:find("XEquipItem",1,true) then exchanges=exchanges+1 end
        end
        return {phaseBefore=phaseBefore,restored=slots[21]==newItem and slots[4]==oldItem,
            noJournal=BfBot.Persist.GetItemSwap(sprite)==nil,
            used=#uses,advanced=#advances,exchanges=exchanges,warnings=#warnings}
        """
    )
    assert facts["phaseBefore"] == "restoring"
    assert facts["restored"] and facts["noJournal"]
    assert facts["used"] == 1 and facts["exchanges"] == 2
    assert facts["advanced"] == facts["warnings"] == 0


def test_duplicate_recovery_callbacks_exchange_equipment_back_only_once() -> None:
    facts = _runtime().execute(
        """
        setupSwap(); assert(queueSwap())
        for _=1,4 do step() end
        local journal=BfBot.Persist.GetItemSwap(sprite)
        local firstAttempt=journal.restoreAttempt
        actions={}; BfBot.Exec.Stop()
        -- One duplicate check reaches the journal before the queued check.
        BfBot.Exec._CheckItemRecovery(0,journal.token)
        step() -- queued check appends another retry for the same attempt
        step() -- first retry starts a new restoration attempt
        local newerAttempt=journal.restoreAttempt>firstAttempt
        drain()
        local exchanges=0
        for _,action in ipairs(history) do
            if action:find("XEquipItem",1,true) then exchanges=exchanges+1 end
        end
        return {newerAttempt=newerAttempt,restored=slots[21]==newItem and slots[4]==oldItem,
            noJournal=BfBot.Persist.GetItemSwap(sprite)==nil,exchanges=exchanges,
            used=#uses,advanced=#advances,warnings=#warnings}
        """
    )
    assert facts["newerAttempt"] and facts["restored"] and facts["noJournal"]
    assert facts["exchanges"] == 2 and facts["used"] == 1
    assert facts["advanced"] == facts["warnings"] == 0


@pytest.mark.parametrize("change", [
    "newItem.m_flags=0", "words[newItem.ptr+0x1E]=0",
])
def test_use_rechecks_identification_and_charges_after_equipping(change: str) -> None:
    facts = _runtime().execute(
        'setupSwap(); assert(queueSwap()); step()\n' + change + '\ndrain()\n'
        'return {restored=slots[21]==newItem and slots[4]==oldItem,used=#uses,'
        'noJournal=BfBot.Persist.GetItemSwap(sprite)==nil,warnings=#warnings}'
    )
    assert facts["restored"] and facts["noJournal"]
    assert facts["used"] == facts["warnings"] == 0


@pytest.mark.parametrize("mode,category,slot", [
    ("inventory", 32, 21), ("inventory", 2, 21), ("swap", 9, 21), ("swap", 2, 1),
])
def test_direct_inventory_potions_and_already_equipped_items_skip_exchanges(
    mode: str, category: int, slot: int,
) -> None:
    lua = _runtime()
    lua.globals().testMode, lua.globals().category, lua.globals().testSlot = mode, category, slot
    facts = lua.execute(
        """
        setupSwap(); prefs.ItemUseMode=testMode
        headers.NEW.itemType=category; row.itemType=category
        if testSlot~=21 then slots[testSlot],slots[21]=slots[21],nil end
        row.itemSlot=testSlot
        local queued=queueSwap(); drain()
        local exchanges=0
        for _,action in ipairs(history) do
            if action:find("XEquipItem",1,true) then exchanges=exchanges+1 end
        end
        return {queued=queued,exchanges=exchanges,used=#uses,
            correctItem=uses[1] and uses[1].item==newItem,
            slot=uses[1] and uses[1].slot,ability=uses[1] and uses[1].ability,
            noJournal=BfBot.Persist.GetItemSwap(sprite)==nil,warnings=#warnings}
        """
    )
    assert facts["queued"] and facts["correctItem"] and facts["noJournal"]
    assert facts["exchanges"] == facts["warnings"] == 0
    assert facts["used"] == 1 and facts["slot"] == slot and facts["ability"] == 1


@pytest.mark.parametrize("had_previous", [True, False])
def test_consumed_item_restores_displaced_equipment_without_recreating_consumed_item(had_previous: bool) -> None:
    lua = _runtime()
    lua.globals().hadPrevious = had_previous
    facts = lua.execute(
        """
        setupSwap(); if not hadPrevious then slots[4]=nil end
        consumeOnUse=true
        assert(queueSwap()); drain()
        return {packEmpty=slots[21]==nil,
            restored=hadPrevious and slots[4]==oldItem or not hadPrevious and slots[4]==nil,
            used=#uses,noJournal=BfBot.Persist.GetItemSwap(sprite)==nil,
            advanced=#advances,warnings=#warnings}
        """
    )
    assert facts["packEmpty"] and facts["restored"] and facts["noJournal"]
    assert facts["used"] == facts["advanced"] == 1
    assert facts["warnings"] == 0


def test_stale_callbacks_cannot_operate_a_new_swap_record() -> None:
    facts = _runtime().execute(
        """
        setupSwap(); assert(queueSwap())
        local oldToken=BfBot.Persist.GetItemSwap(sprite).token
        drain()
        assert(queueSwap())
        local current=BfBot.Persist.GetItemSwap(sprite)
        local queued=#actions
        BfBot.Exec._AfterItemEquip(0,oldToken)
        BfBot.Exec._RestoreItemAtSlot(0,oldToken)
        BfBot.Exec._ItemRestored(0,oldToken)
        return {newToken=current.token~=oldToken,recordUnchanged=BfBot.Persist.GetItemSwap(sprite)==current,
            noNewActions=#actions==queued,phase=current.phase,
            untouched=slots[21]==newItem and slots[4]==oldItem,warnings=#warnings}
        """
    )
    assert facts["newToken"] and facts["recordUnchanged"] and facts["noNewActions"]
    assert facts["phase"] == "equipping" and facts["untouched"]
    assert facts["warnings"] == 0


@pytest.mark.parametrize("changed_slot", [4, 21])
def test_manual_slot_change_refuses_automatic_restoration(changed_slot: int) -> None:
    lua = _runtime()
    lua.globals().changedSlot = changed_slot
    facts = lua.execute(
        """
        setupSwap(); assert(queueSwap()); step()
        defineItem("MANUAL",32)
        local manual=placeItem(changedSlot,"MANUAL")
        BfBot.Exec.Stop(); drain()
        local record=BfBot.Persist.GetItemSwap(sprite)
        local exchanges=0
        for _,action in ipairs(history) do
            if action:find("XEquipItem",1,true) then exchanges=exchanges+1 end
        end
        return {manualPreserved=slots[changedSlot]==manual,
            recordKept=record~=nil,failed=record and record.phase=="failed",
            used=#uses,advanced=#advances,exchanges=exchanges,warned=#warnings>0}
        """
    )
    assert facts["manualPreserved"] and facts["recordKept"] and facts["failed"]
    assert facts["used"] == facts["advanced"] == 0
    assert facts["exchanges"] == 1 and facts["warned"]


def test_failed_journal_can_recover_after_player_repairs_expected_slots() -> None:
    facts = _runtime().execute(
        """
        setupSwap(); assert(queueSwap()); step()
        defineItem("MANUAL",32); placeItem(4,"MANUAL")
        BfBot.Exec.Stop(); drain()
        local failed=BfBot.Persist.GetItemSwap(sprite).phase=="failed"
        slots[4],slots[21]=newItem,oldItem
        BfBot.Exec._RecoverItemSwaps(); drain()
        return {failed=failed,restored=slots[21]==newItem and slots[4]==oldItem,
            noJournal=BfBot.Persist.GetItemSwap(sprite)==nil,used=#uses,advanced=#advances}
        """
    )
    assert facts["failed"] and facts["restored"] and facts["noJournal"]
    assert facts["used"] == facts["advanced"] == 0


def test_save_roundtrip_whitelists_journal_and_recovers_with_a_fresh_token() -> None:
    facts = _runtime().execute(
        """
        setupSwap(); assert(queueSwap()); step()
        local journal=BfBot.Persist.GetItemSwap(sprite)
        journal.recoveryQueued=123; journal.extra={secret=true}; journal.fn=function() end
        local oldToken=journal.token
        local exported=BfBot.Persist._Export(sprite)
        local saved=exported.itemSwap
        local fields={}
        for key in pairs(saved) do fields[#fields+1]=key end
        table.sort(fields)
        actions={}; aux.BBItemSwap=nil; BfBot.Exec._HardReset()
        BfBot.Persist._Import(sprite,exported)
        local imported=BfBot.Persist.GetItemSwap(sprite)
        local noRuntime=imported.token==nil and imported.phase==nil and imported.recoveryQueued==nil
        BfBot.Exec._RecoverItemSwaps()
        local freshToken=imported.token~=oldToken
        local queuedOnce=#actions
        BfBot.Exec._RecoverItemSwaps()
        local noDuplicate=#actions==queuedOnce
        drain()
        return {fields=table.concat(fields,","),savedItem=saved.item,savedPrevious=saved.previous,
            noRuntime=noRuntime,freshToken=freshToken,noDuplicate=noDuplicate,
            restored=slots[21]==newItem and slots[4]==oldItem,
            noJournal=BfBot.Persist.GetItemSwap(sprite)==nil,used=#uses,advanced=#advances,warnings=#warnings}
        """
    )
    assert facts["fields"] == "equip,item,pack,previous,weapon,weaponAbility"
    assert facts["savedItem"] == "NEW" and facts["savedPrevious"] == "OLD"
    assert facts["noRuntime"] and facts["freshToken"] and facts["noDuplicate"]
    assert facts["restored"] and facts["noJournal"]
    assert facts["used"] == facts["advanced"] == facts["warnings"] == 0


@pytest.mark.parametrize("change", [
    'value.item="BAD\\nITEM"', 'value.item="123456789"', 'value.previous="BAD\\\\ITEM"',
    'value.pack=4', 'value.pack=34', 'value.pack=21.5', 'value.equip=1',
    'value.equip=10', 'value.equip=21', 'value.equip=34',
])
def test_malformed_journals_never_become_recovery_instructions(change: str) -> None:
    assert _runtime().execute(
        'local value={item="NEW",previous="OLD",pack=21,equip=4}\n'
        + change + '\nreturn BfBot.Persist._ValidateItemSwap(value)==nil'
    )


@pytest.mark.parametrize("effect_setup,active", [
    ('{effect("NEW",0,-2,1)}', False),
    ('{effect("NEW",16,0,1)}', False),
    ('{effect("NEW",0,-2,1),effect("OTHER",16,0,1)}', False),
    ('{effect("NEW",0,-2,1),effect("NEW",16,1,1)}', False),
    ('{effect("NEW",0,-2,1),effect("NEW",16,0,0)}', False),
    ('{effect("NEW",0,-2,1),effect("NEW",16,0,1)}', True),
])
def test_active_power_requires_every_effect_signature_from_the_correct_item(
    effect_setup: str, active: bool,
) -> None:
    lua = _runtime()
    actual = lua.execute(
        'local function effect(resref,opcode,amount,flags) return {'
        'm_sourceRes={get=function() return resref end},'
        'm_effectId=opcode,m_effectAmount=amount,m_dWFlags=flags} end\n'
        'sprite.m_timedEffectList=' + effect_setup + '\n'
        'return BfBot.Exec._HasActiveItemEffect(sprite,"NEW",{'
        '{opcode=0,amount=-2,flags=1},{opcode=16,amount=0,flags=1}})'
    )
    assert actual == active


def test_empty_effect_signature_never_claims_an_item_power_is_active() -> None:
    lua = _runtime()
    assert not lua.execute('return BfBot.Exec._HasActiveItemEffect(sprite,"NEW",{})')
