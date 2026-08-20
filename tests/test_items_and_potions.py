from __future__ import annotations

from pathlib import Path
import re

from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")
CLASS_SOURCE = (ROOT / "buffbot/BfBotCls.lua").read_text(encoding="utf-8")
SCAN_SOURCE = (ROOT / "buffbot/BfBotScn.lua").read_text(encoding="utf-8")
UI_SOURCE = (ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8")


def _persist_runtime() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        BfBot = {
            MAX_PRESETS = 8,
            MAX_SPELL_REPEATS = 5,
            Scan = {}, Class = {}, Innate = {}, Mp = {},
            _Warn = function(_) end,
            _StripColorEscape = function(s) return s end,
        }
        """
    )
    lua.execute(PERSIST_SOURCE)
    return lua


def test_items_kind_owns_schema_v10_after_main_v9() -> None:
    source = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")

    assert re.search(r"BfBot\.Persist\._SCHEMA_VERSION\s*=\s*10\b", source)

    repeat_migration = source.index("if fromVersion < 9 then")
    item_migration = source.index("if fromVersion < 10 then")
    assert repeat_migration < item_migration

    item_block = source[item_migration : source.index("config.v =", item_migration)]
    assert 'entry.kind = "spl"' in item_block
    assert "config.summons" not in item_block


def test_v9_to_v10_migration_adds_kind_to_party_only() -> None:
    facts = _persist_runtime().execute(
        """
        local config = {
            v = 9,
            ap = 1,
            presets = { [1] = {
                name = "Party", cat = "custom", qc = 0,
                spells = { PARTY = {
                    on = 1, tgt = "s", pri = 1, rep = 1, lock = 0,
                } },
            } },
            opts = { skip = 1 },
            ovr = {},
            summons = { clone = { presets = { [1] = {
                qc = 0,
                spells = { SUMMON = {
                    on = 1, tgt = "s", pri = 1, rep = 1,
                } },
            } } } },
        }
        local migrated = BfBot.Persist._MigrateConfig(config, 9)
        return {
            version = migrated.v,
            partyKind = migrated.presets[1].spells.PARTY.kind,
            summonKind = migrated.summons.clone.presets[1].spells.SUMMON.kind,
        }
        """
    )

    assert facts["version"] == 10
    assert facts["partyKind"] == "spl"
    assert facts["summonKind"] is None


def test_ambiguous_item_branch_v8_save_keeps_items_and_gains_summons_shape() -> None:
    facts = _persist_runtime().execute(
        """
        local config = {
            v = 8,
            ap = 1,
            presets = { [1] = {
                name = "Items branch", cat = "custom", qc = 0,
                spells = { POTION = {
                    kind = "itm", on = 1, tgt = "s", pri = 1, lock = 0,
                } },
            } },
            opts = { skip = 1 },
            ovr = {},
        }
        local migrated = BfBot.Persist._MigrateConfig(config, 8)
        return {
            version = migrated.v,
            itemKind = migrated.presets[1].spells.POTION.kind,
            itemRepeat = migrated.presets[1].spells.POTION.rep,
            summonsIsTable = type(migrated.summons) == "table",
            summonsEmpty = type(migrated.summons) == "table"
                and next(migrated.summons) == nil,
        }
        """
    )

    assert facts["version"] == 10
    assert facts["itemKind"] == "itm"
    assert facts["itemRepeat"] == 1
    assert facts["summonsIsTable"]
    assert facts["summonsEmpty"]


def test_v10_validation_preserves_items_and_keeps_summons_spell_only() -> None:
    facts = _persist_runtime().execute(
        """
        local config = {
            v = 10,
            ap = 1,
            presets = { [1] = {
                name = "Party", cat = "custom", qc = 0,
                spells = {
                    ITEM = {
                        kind = "itm", on = 1, tgt = "s", pri = 1,
                        rep = 2, lock = 0,
                    },
                    INVALID = {
                        kind = "bad", on = 1, tgt = "s", pri = 2,
                        rep = 1, lock = 0,
                    },
                },
            } },
            opts = { skip = 1 },
            ovr = {},
            summons = { clone = { presets = { [1] = {
                qc = 0,
                spells = { SUMMON = {
                    kind = "itm", on = 1, tgt = "s", pri = 1, rep = 1,
                } },
            } } } },
        }
        local clean = BfBot.Persist._ValidateConfig(config)
        return {
            itemKind = clean.presets[1].spells.ITEM.kind,
            itemRepeat = clean.presets[1].spells.ITEM.rep,
            invalidKind = clean.presets[1].spells.INVALID.kind,
            summonKind = clean.summons.clone.presets[1].spells.SUMMON.kind,
        }
        """
    )

    assert facts["itemKind"] == "itm"
    assert facts["itemRepeat"] == 2
    assert facts["invalidKind"] == "spl"
    assert facts["summonKind"] is None


def test_spell_and_item_resref_collisions_use_separate_classifier_caches() -> None:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        BfBot = {
            Class = {},
            _cache = { class = {} },
            _overrides = {},
        }
        """
    )
    lua.execute(CLASS_SOURCE)
    facts = lua.execute(
        """
        BfBot.Class.GetDuration = function() return 0, nil, {} end
        BfBot.Class.ScoreTargeting = function(ability)
            return ability.buff and 3 or -3, ability.buff
        end
        BfBot.Class.ScoreMSECTYPE = function() return 0 end
        BfBot.Class.ScoreOpcodes = function(_, ability)
            return 0, {
                splstates = {}, selfReplace = false, isToggle = false,
                hasSubstantive = ability.buff, fbAoE = false,
            }
        end
        BfBot.Class.IsAoE = function() return false end
        BfBot.Class.IsSelfOnly = function() return false end
        BfBot.Class.GetDefaultTarget = function() return "s" end
        BfBot.Class._DetectVariants = function() return nil end

        local header = { secondaryType = 0 }
        local spellAbility = { buff = true }
        local itemAbility = { buff = false }

        local spellFirst = BfBot.Class.Classify(
            "COLLIDE", header, spellAbility, "spl").isBuff
        local itemSecond = BfBot.Class.Classify(
            "COLLIDE", header, itemAbility, "itm").isBuff

        BfBot._cache.class = {}
        local itemFirst = BfBot.Class.Classify(
            "COLLIDE", header, itemAbility, "itm").isBuff
        local spellSecond = BfBot.Class.Classify(
            "COLLIDE", header, spellAbility, "spl").isBuff

        BfBot.Class.SetOverride("COLLIDE", true)
        return {
            spellFirst = spellFirst,
            itemSecond = itemSecond,
            itemFirst = itemFirst,
            spellSecond = spellSecond,
            spellCacheCleared = BfBot._cache.class.COLLIDE == nil,
            itemCacheCleared = BfBot._cache.class["itm:COLLIDE"] == nil,
        }
        """
    )

    assert facts["spellFirst"]
    assert not facts["itemSecond"]
    assert not facts["itemFirst"]
    assert facts["spellSecond"]
    assert facts["spellCacheCleared"]
    assert facts["itemCacheCleared"]


def test_item_catalog_and_clone_seeding_are_party_only() -> None:
    scan_source = (ROOT / "buffbot/BfBotScn.lua").read_text(encoding="utf-8")
    persist_source = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")

    item_catalog = scan_source[
        scan_source.index("function BfBot.Scan._BuildItemCatalog") :
        scan_source.index("function BfBot.Scan.GetCastableSpells")
    ]
    assert "EEex_Sprite_GetPortraitIndex" in item_catalog
    assert re.search(r"portrait\s*==\s*-1", item_catalog)

    clone_seed = persist_source[
        persist_source.index("function BfBot.Persist._SeedCloneSpells") :
        persist_source.index("function BfBot.Persist._CheckSummonArgs")
    ]
    assert re.search(r"entry\.kind\s*~=\s*[\"']itm[\"']", clone_seed)
    assert re.search(r"scanData\.kind\s*~=\s*[\"']itm[\"']", clone_seed)


def test_summon_queue_defensively_rejects_item_catalog_rows() -> None:
    facts = _persist_runtime().execute(
        """
        local sprite = {}
        BfBot.Exec = {
            _ResolveCaster = function(_) return sprite end,
        }
        BfBot.Scan.Invalidate = function(_) end
        BfBot.Scan.GetCastableSpells = function(_)
            return {
                SPELL = {
                    kind = "spl", count = 1, name = "Spell", durCat = "long",
                },
                ITEM = {
                    kind = "itm", count = 1, name = "Item", durCat = "long",
                },
            }
        end
        BfBot.Persist.PeekSummonPreset = function(_, _)
            return {
                qc = 2,
                spells = {
                    SPELL = { on = 1, tgt = "s", pri = 1, rep = 1 },
                    ITEM = { on = 1, tgt = "s", pri = 2, rep = 1 },
                },
            }
        end
        BfBot.Persist._ResolveConfigTarget = function(_, casterRef, resref, pri)
            return { {
                casterRef = casterRef, spell = resref,
                target = "self", pri = pri,
            } }
        end

        local queue, err = BfBot.Persist.BuildQueueForSummon({
            identity = "test:clone", oid = 42, name = "Clone",
        }, 1)
        return {
            error = err,
            count = queue and #queue or 0,
            first = queue and queue[1] and queue[1].spell,
            cheat = queue and queue[1] and queue[1].cheat,
        }
        """
    )

    assert facts["error"] is None
    assert facts["count"] == 1
    assert facts["first"] == "SPELL"
    assert facts["cheat"] == 1


def test_disallowed_backpack_copy_does_not_hide_equipped_copy() -> None:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        BfBot = {
            Scan = {}, Class = {},
            _cache = { scan = {} },
            _Warn = function(_) end,
        }
        """
    )
    lua.execute(SCAN_SOURCE)
    found = lua.execute(
        """
        local ability = { quickSlotIcon = { get = function() return "ICON" end } }
        local header = {
            abilityCount = 1,
            itemType = 1,
            identifiedName = 1,
            genericName = 2,
        }
        local function item()
            return { pRes = { resref = { get = function() return "DUPITM" end } } }
        end
        local slots = { [21] = item(), [35] = item() }
        local sprite = { m_equipment = { m_items = {
            get = function(_, slot) return slots[slot] end,
        } } }

        EEex_Sprite_GetPortraitIndex = function(_) return 0 end
        EEex_Resource_Demand = function(resref, kind)
            assert(resref == "DUPITM" and kind == "ITM")
            return header
        end
        EEex_UDToPtr = function(_) return 100 end
        EEex_ReadU16 = function(_) return 1 end
        EEex_ReadU8 = function(_) return 1 end
        Infinity_FetchString = function(_) return "Equipped Test Item" end
        BfBot.Scan._GetItemAbility = function(_, index)
            assert(index == 0)
            return ability
        end
        BfBot.Class.Classify = function()
            return { isBuff = true, isAoE = false, isSelfOnly = true }
        end
        BfBot.Class.GetDuration = function() return 30, nil, {} end
        BfBot.Class.GetDurationCategory = function() return "short" end

        local catalog = BfBot.Scan._BuildItemCatalog(sprite)
        return catalog.DUPITM ~= nil
        """
    )

    assert found


def test_quickslot_scrolls_and_wands_remain_deferred() -> None:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        BfBot = {
            Scan = {}, Class = {},
            _cache = { scan = {} },
            _Warn = function(_) end,
        }
        """
    )
    lua.execute(SCAN_SOURCE)
    facts = lua.execute(
        """
        local ability = { quickSlotIcon = { get = function() return "ICON" end } }
        local headers = {
            TESTWAND = { abilityCount = 1, itemType = 35, identifiedName = 1 },
            TESTSCRL = { abilityCount = 1, itemType = 11, identifiedName = 2 },
        }
        local function item(resref)
            return { pRes = { resref = { get = function() return resref end } } }
        end
        local slots = { [15] = item("TESTWAND"), [16] = item("TESTSCRL") }
        local sprite = { m_equipment = { m_items = {
            get = function(_, slot) return slots[slot] end,
        } } }

        EEex_Sprite_GetPortraitIndex = function(_) return 0 end
        EEex_Resource_Demand = function(resref, kind)
            assert(kind == "ITM")
            return headers[resref]
        end
        EEex_UDToPtr = function(_) return 100 end
        EEex_ReadU16 = function(_) return 1 end
        EEex_ReadU8 = function(_) return 1 end
        Infinity_FetchString = function(_) return "Deferred Item" end
        BfBot.Scan._GetItemAbility = function() return ability end
        BfBot.Class.Classify = function()
            return { isBuff = true, isAoE = false, isSelfOnly = true }
        end
        BfBot.Class.GetDuration = function() return 30, nil, {} end
        BfBot.Class.GetDurationCategory = function() return "short" end

        local catalog = BfBot.Scan._BuildItemCatalog(sprite)
        return {
            wandAbsent = catalog.TESTWAND == nil,
            scrollAbsent = catalog.TESTSCRL == nil,
        }
        """
    )

    assert facts["wandAbsent"]
    assert facts["scrollAbsent"]


def test_excluded_buff_item_remains_in_catalog_for_picker_recovery() -> None:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        BfBot = {
            Scan = {}, Class = {},
            _cache = { scan = {} },
            _Warn = function(_) end,
        }
        """
    )
    lua.execute(SCAN_SOURCE)
    found = lua.execute(
        """
        local ability = { quickSlotIcon = { get = function() return "ICON" end } }
        local header = { abilityCount = 1, itemType = 1, identifiedName = 1 }
        local carried = { pRes = { resref = {
            get = function() return "EXCLITM" end,
        } } }
        local sprite = { m_equipment = { m_items = {
            get = function(_, slot) if slot == 15 then return carried end end,
        } } }

        EEex_Sprite_GetPortraitIndex = function(_) return 0 end
        EEex_Resource_Demand = function() return header end
        EEex_UDToPtr = function(_) return 100 end
        EEex_ReadU16 = function(_) return 1 end
        EEex_ReadU8 = function(_) return 1 end
        Infinity_FetchString = function(_) return "Excluded Buff Item" end
        BfBot.Scan._GetItemAbility = function() return ability end
        BfBot.Class.Classify = function()
            return {
                isBuff = false,
                overridden = true,
                isAoE = false,
                isSelfOnly = true,
            }
        end
        BfBot.Class.GetDuration = function() return 30, nil, {} end
        BfBot.Class.GetDurationCategory = function() return "short" end

        return BfBot.Scan._BuildItemCatalog(sprite).EXCLITM ~= nil
        """
    )

    assert found


def test_item_catalog_sums_multiple_eligible_stacks() -> None:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        BfBot = {
            Scan = {}, Class = {},
            _cache = { scan = {} },
            _Warn = function(_) end,
        }
        """
    )
    lua.execute(SCAN_SOURCE)
    count = lua.execute(
        """
        local ability = { quickSlotIcon = { get = function() return "ICON" end } }
        local header = { abilityCount = 1, itemType = 9, identifiedName = 1 }
        local function item(ptr)
            return {
                ptr = ptr,
                pRes = { resref = { get = function() return "STACKITM" end } },
            }
        end
        local slots = { [21] = item(1000), [22] = item(2000) }
        local sprite = { m_equipment = { m_items = {
            get = function(_, slot) return slots[slot] end,
        } } }

        EEex_Sprite_GetPortraitIndex = function(_) return 0 end
        EEex_Resource_Demand = function() return header end
        EEex_UDToPtr = function(value) return value.ptr or 500 end
        EEex_ReadU16 = function(address)
            if address == 1000 + BfBot.Scan._ITEM_COUNT_OFF then return 2 end
            if address == 2000 + BfBot.Scan._ITEM_COUNT_OFF then return 3 end
            error("unexpected count address")
        end
        EEex_ReadU8 = function(_) return 1 end
        Infinity_FetchString = function(_) return "Stacked Potion" end
        BfBot.Scan._GetItemAbility = function() return ability end
        BfBot.Class.Classify = function()
            return { isBuff = true, isAoE = false, isSelfOnly = true }
        end
        BfBot.Class.GetDuration = function() return 30, nil, {} end
        BfBot.Class.GetDurationCategory = function() return "short" end

        local entry = BfBot.Scan._BuildItemCatalog(sprite).STACKITM
        return entry and entry.count or 0
        """
    )

    assert count == 5


def test_absent_imported_items_stay_persisted_but_hidden_from_rows() -> None:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        BfBot = {
            MAX_PRESETS = 8,
            MAX_SPELL_REPEATS = 5,
            Scan = {}, Class = {}, Innate = {}, Mp = {}, Exec = {}, Persist = {},
            _cache = { class = {}, scan = {} },
            _Warn = function(_) end,
            _Print = function(_) end,
            _StripColorEscape = function(s) return s end,
        }
        """
    )
    lua.execute(PERSIST_SOURCE)
    lua.execute(UI_SOURCE)
    facts = lua.execute(
        """
        EEex_Resource_Demand = function() return nil end
        local preset = { spells = {
            ABSENT_ITEM = {
                kind = "itm", on = 1, tgt = "s", pri = 1, rep = 1,
            },
            ABSENT_SPELL = {
                kind = "spl", on = 1, tgt = "s", pri = 2, rep = 1,
            },
        } }
        local rows = BfBot.UI._BuildSpellRows({}, preset, {}, {})
        return {
            rowCount = #rows,
            onlyRow = rows[1] and rows[1].resref,
            itemStillPersisted = preset.spells.ABSENT_ITEM ~= nil,
        }
        """
    )

    assert facts["rowCount"] == 1
    assert facts["onlyRow"] == "ABSENT_SPELL"
    assert facts["itemStillPersisted"]


def test_item_picker_recovery_requires_this_characters_exclusion() -> None:
    lua = _persist_runtime()
    lua.execute(
        """
        BfBot.Exec = {}
        BfBot.UI = {}
        BfBot._cache = { class = {}, scan = {} }
        BfBot._Print = function(_) end
        """
    )
    lua.execute(UI_SOURCE)
    facts = lua.execute(
        """
        local sprite = {}
        local config = {
            presets = { [1] = { spells = {} } },
            ovr = {},
        }
        BfBot.UI._presetIdx = 1
        BfBot.UI._GetSelectedSprite = function() return sprite end
        BfBot.Persist.GetConfig = function() return config end
        BfBot.Scan.GetCastableSpells = function()
            return { ITEM = {
                kind = "itm", name = "Globally Excluded Elsewhere",
                icon = "", count = 1, durCat = "short",
                class = { isBuff = false, overridden = true },
            } }
        end

        BfBot.UI._BuildPickerList()
        local withoutLocalOverride = #buffbot_pickerSpells
        config.ovr.ITEM = -1
        BfBot.UI._BuildPickerList()
        return {
            withoutLocalOverride = withoutLocalOverride,
            withLocalOverride = #buffbot_pickerSpells,
            header = buffbot_pickerSpells[1]
                and buffbot_pickerSpells[1].isHeader,
            item = buffbot_pickerSpells[2]
                and buffbot_pickerSpells[2].resref,
        }
        """
    )

    assert facts["withoutLocalOverride"] == 0
    assert facts["withLocalOverride"] == 2
    assert facts["header"] == 1
    assert facts["item"] == "ITEM"


def test_picker_sections_sort_headers_and_item_colors() -> None:
    lua = _persist_runtime()
    lua.execute(
        """
        BfBot.Exec = {}
        BfBot.UI = {}
        BfBot._cache = { class = {}, scan = {} }
        BfBot._Print = function(_) end
        """
    )
    lua.execute(UI_SOURCE)
    facts = lua.execute(
        """
        local sprite = {}
        local config = {
            presets = { [1] = { spells = {} } },
            ovr = { SP_EX = -1, ITEM_HI = -1, ITEM_LO = -1 },
        }
        BfBot.UI._presetIdx = 1
        BfBot.UI._GetSelectedSprite = function() return sprite end
        BfBot.Persist.GetConfig = function() return config end
        BfBot.Scan.GetCastableSpells = function()
            return {
                SP_NON = {
                    kind = "spl", name = "A spell", count = 9,
                    class = { isBuff = false },
                },
                SP_EX = {
                    kind = "spl", name = "Z excluded", count = 1,
                    class = { isBuff = false, overridden = true },
                },
                ITEM_LO = {
                    kind = "itm", name = "A item", count = 1,
                    class = { isBuff = false, overridden = true },
                },
                ITEM_HI = {
                    kind = "itm", name = "Z item", count = 3,
                    class = { isBuff = false, overridden = true },
                },
            }
        end
        BfBot.UI._T = function(key)
            if key == "headerSub" then return "{11, 0, 0}" end
            if key == "itemColor" then return "{22, 0, 0}" end
            return "{33, 0, 0}"
        end

        BfBot.UI._BuildPickerList()
        local sequence = {}
        for _, entry in ipairs(buffbot_pickerSpells) do
            sequence[#sequence + 1] = entry.resref
        end
        buffbot_pickerSelected = 1
        local headerSelected = BfBot.UI._PickerHasSelection()
        buffbot_pickerSelected = 5
        local itemSelected = BfBot.UI._PickerHasSelection()

        local writes = 0
        BfBot.Persist.SetOverride = function(_, resref, value)
            writes = writes + 1
            assert(resref == "ITEM_HI" and value == 1)
        end
        BfBot.Scan.Invalidate = function() end
        BfBot.UI._Refresh = function() end
        Infinity_PopMenu = function() end
        buffbot_pickerSelected = 1
        BfBot.UI.AddPickedSpell()
        buffbot_pickerSelected = 5
        BfBot.UI.AddPickedSpell()

        return {
            sequence = table.concat(sequence, ","),
            headerSelected = headerSelected,
            itemSelected = itemSelected,
            headerColor = BfBot.UI._PickerNameColor(1)[1],
            itemColor = BfBot.UI._PickerNameColor(5)[1],
            spellColor = BfBot.UI._PickerNameColor(2)[1],
            writes = writes,
        }
        """
    )

    assert facts["sequence"] == (
        "__HEADER_SPL__,SP_EX,SP_NON,__HEADER_ITM__,ITEM_HI,ITEM_LO"
    )
    assert not facts["headerSelected"]
    assert facts["itemSelected"]
    assert facts["headerColor"] == 11
    assert facts["itemColor"] == 22
    assert facts["spellColor"] == 33
    assert facts["writes"] == 1


def test_item_toggle_routes_party_kind_and_summon_direct_write() -> None:
    lua = _persist_runtime()
    lua.execute(
        """
        BfBot.Exec = {}
        BfBot.UI = {}
        BfBot._cache = { class = {}, scan = {} }
        BfBot._Print = function(_) end
        """
    )
    lua.execute(UI_SOURCE)
    facts = lua.execute(
        """
        local row = {
            resref = "ITEM", kind = "itm", on = 0, castable = 1,
            hasVariants = 0,
        }
        buffbot_spellTable = { row }
        BfBot.UI._presetIdx = 2
        BfBot.UI._GetSelectedSprite = function() return "sprite" end
        local partyArgs, partyCalls = nil, 0
        BfBot.Persist.SetSpellEnabled = function(
            sprite, preset, resref, value, kind)
            partyCalls = partyCalls + 1
            partyArgs = { sprite, preset, resref, value, kind }
        end
        BfBot.UI._view = "party"
        BfBot.UI.ToggleSpell(1)

        local summonEntry = { on = 0 }
        BfBot.UI._SummonSpellEntry = function(resref, create)
            assert(resref == "ITEM" and create == 1)
            return summonEntry
        end
        row.on = 0
        BfBot.UI._view = "summons"
        BfBot.UI.ToggleSpell(1)
        return {
            partyCalls = partyCalls,
            partySprite = partyArgs[1],
            partyPreset = partyArgs[2],
            partyResref = partyArgs[3],
            partyValue = partyArgs[4],
            partyKind = partyArgs[5],
            summonValue = summonEntry.on,
        }
        """
    )

    assert facts["partyCalls"] == 1
    assert facts["partySprite"] == "sprite"
    assert facts["partyPreset"] == 2
    assert facts["partyResref"] == "ITEM"
    assert facts["partyValue"] == 1
    assert facts["partyKind"] == "itm"
    assert facts["summonValue"] == 1
