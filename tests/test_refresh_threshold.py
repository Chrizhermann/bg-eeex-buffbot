"""Remaining-duration threshold and force-recast policy (issue #84).

A long buff that survived a rest with a tiny remainder used to be skipped for
being "active". These tests pin the three pieces that fix it: reading an
applied effect's remaining lifetime, resolving the threshold for a run, and
_CheckEntry's decision from the two.
"""

from __future__ import annotations

import faulthandler
import sys
from pathlib import Path

import pytest
from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CORE_SOURCE = (ROOT / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")
LOC_SOURCE = (ROOT / "buffbot/BfBotLoc.lua").read_text(encoding="utf-8")
PERSIST_SOURCE = (ROOT / "buffbot/BfBotPer.lua").read_text(encoding="utf-8")
EXEC_SOURCE = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")
UI_SOURCE = (ROOT / "buffbot/BfBotUI.lua").read_text(encoding="utf-8")
THEME_SOURCE = (ROOT / "buffbot/BfBotThm.lua").read_text(encoding="utf-8")

TICKS_PER_SECOND = 15
NOW = 100_000  # arbitrary world time, in game ticks


@pytest.fixture
def exec_lua() -> LuaRuntime:
    """Core + localization + persistence + exec, with the engine seams faked.

    Deliberately loads the real BfBotCor.lua so the thresholds under test use
    the shipped constants rather than a copy of them.
    """
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute("Infinity_DisplayString = function(_) end")
    runtime.execute("io = nil")
    runtime.execute(CORE_SOURCE)
    runtime.execute(
        """
        BfBot.Scan = {}
        BfBot.Class = {}
        BfBot.Innate = {}
        BfBot.Mp = {}
        BfBot._cache = { class = {}, scan = {} }
        BfBot._Warn = function(_) end
        BfBot._Print = function(_) end
        BfBot._OpenLogAppend = function(_) end
        BfBot._CloseLog = function() end
        BfBot._GetName = function(sprite)
            if type(sprite) == "table" then return sprite.name or "?" end
            return tostring(sprite)
        end
        BfBot._DisplayOverhead = function() return true end
        BfBot._ErrorOnce = function(_) end
        EEex_BAnd = function() return 0 end

        -- baldur.ini, in memory.
        T_Ini = {}
        Infinity_GetINIValue = function(_, key, default)
            local value = T_Ini[key]
            if value == nil then return default end
            return value
        end
        Infinity_SetINIValue = function(_, key, value) T_Ini[key] = value end
        Infinity_GetINIString = function(_, key, default)
            local value = T_Ini[key]
            if value == nil then return default end
            return value
        end
        Infinity_SetINIString = function(_, key, value) T_Ini[key] = value end

        EEex_Utility_IterateCPtrList = function(list, fn)
            for _, value in ipairs(list) do
                if fn(value) then return end
            end
        end

        -- World time, the clock an applied effect's deadline is measured in.
        T_Now = %d
        EEex_EngineGlobal_CBaldurChitin = {
            m_pObjectGame = { m_worldTime = {} },
        }
        setmetatable(EEex_EngineGlobal_CBaldurChitin.m_pObjectGame.m_worldTime, {
            __index = function(_, key)
                if key == "m_gameTime" then return T_Now end
                return nil
            end,
        })

        --- Build one applied effect. `seconds` is how much lifetime is left;
        --- the deadline is absolute game ticks, exactly as the engine stores
        --- it for timing mode 4096.
        -- Overrides set to T_NIL remove the field entirely, which a plain
        -- `nil` in a table constructor cannot express.
        T_NIL = {}
        function T_Effect(source, seconds, overrides)
            local effect = {
                m_sourceRes = { get = function() return source end },
                m_effectId = 0,
                m_effectAmount = 0,
                m_dWFlags = 0,
                m_durationType = 4096,
                m_duration = T_Now + math.floor(seconds * %d),
            }
            for key, value in pairs(overrides or {}) do
                if value == T_NIL then value = nil end
                effect[key] = value
            end
            return effect
        end
        """
        % (NOW, TICKS_PER_SECOND)
    )
    runtime.execute(LOC_SOURCE)
    runtime.execute(PERSIST_SOURCE)
    runtime.execute(EXEC_SOURCE)
    runtime.execute(
        """
        --- A target carrying `effects`, plus a caster, wired into the seams
        --- _CheckEntry needs. Returns the entry _CheckEntry is called with.
        function T_Entry(effects, overrides)
            local target = {
                name = "Target", m_id = 101,
                m_baseStats = { m_generalState = 0 },
                m_timedEffectList = effects,
                getSpellState = function(_, state) return T_States[state] end,
            }
            BfBot.Scan.Invalidate = function() end
            BfBot.Scan.GetCastableSpells = function()
                return { SPWI518 = { count = 1 } }
            end
            BfBot.Exec._IsAlive = function() return true end
            BfBot.Exec._state = "running"
            BfBot.Exec._skipCount = 0
            BfBot.Exec._log = {}
            local entry = {
                casterName = "Caster", spellName = "Stoneskin",
                targetName = "Target", targetObj = "Player2",
                targetSprite = target,
                resref = "SPWI518", kind = "spl",
                leafResrefs = { "SPWI518" },
            }
            for key, value in pairs(overrides or {}) do
                entry[key] = value
            end
            return entry, target
        end
        T_States = {}
        T_Caster = { name = "Caster", m_id = 100,
                     m_baseStats = { m_generalState = 0 } }

        function T_LogText()
            local parts = {}
            for _, line in ipairs(BfBot.Exec._log) do
                parts[#parts + 1] = line.type .. " " .. line.msg
            end
            return table.concat(parts, "\\n")
        end
        """
    )
    return runtime


# --------------------------------------------------------------------------
# _EffectRemaining: one applied effect
# --------------------------------------------------------------------------


@pytest.mark.parametrize("timing", [1, 2, 4, 9])
def test_permanent_timing_modes_never_report_a_finite_remainder(
    exec_lua: LuaRuntime, timing: int
) -> None:
    # Lab-measured (2026-10-24, BG2:EE 2.7.3.0 + EEex v1.3.1): encoded mode 1
    # and 9 keep their value on an applied effect, and encoded 4 becomes 7
    # while delayed and then 1. Mode 2 is precaution.
    facts = exec_lua.execute(
        f"""
        local effect = T_Effect("SPWI518", 5, {{ m_durationType = {timing} }})
        local seconds, detail = BfBot.Exec._EffectRemaining(effect, T_Now)
        return {{ seconds = seconds, detail = detail }}
        """
    )
    assert facts["seconds"] == float("inf")
    assert facts["detail"] == "perm"


@pytest.mark.parametrize("seconds", [0.5, 12, 43_200])
def test_absolute_deadline_is_converted_from_game_ticks(
    exec_lua: LuaRuntime, seconds: float
) -> None:
    facts = exec_lua.execute(
        f"""
        local effect = T_Effect("SPWI518", {seconds})
        local left, detail = BfBot.Exec._EffectRemaining(effect, T_Now)
        return {{ left = left, detail = detail }}
        """
    )
    # math.floor in the fixture quantizes to whole ticks.
    assert facts["left"] == pytest.approx(seconds, abs=1 / TICKS_PER_SECOND)
    assert facts["detail"] is None


def test_a_deadline_already_past_clamps_to_zero_instead_of_going_negative(
    exec_lua: LuaRuntime,
) -> None:
    # The engine sweeps expired effects only once per second per actor, so an
    # effect can legitimately sit up to 14 ticks past its deadline.
    facts = exec_lua.execute(
        """
        local effect = T_Effect("SPWI518", -0.8)
        local left, detail = BfBot.Exec._EffectRemaining(effect, T_Now)
        return { left = left, detail = detail }
        """
    )
    assert facts["left"] == 0
    assert facts["detail"] is None


@pytest.mark.parametrize("timing", [6, 7])
def test_a_delayed_effect_that_has_not_fired_is_pending_not_a_remainder(
    exec_lua: LuaRuntime, timing: int
) -> None:
    # Lab-measured: encoded 3 becomes 6 and encoded 4 becomes 7 while the
    # delay runs, and m_duration then holds the end of the DELAY. Reading it
    # as a remaining lifetime would refresh a buff that has not started.
    facts = exec_lua.execute(
        f"""
        local effect = T_Effect("SPWI518", 2, {{ m_durationType = {timing} }})
        local left, detail = BfBot.Exec._EffectRemaining(effect, T_Now)
        return {{ left = left, detail = detail }}
        """
    )
    assert facts["left"] == float("inf")
    assert facts["detail"] == "pending"


def test_a_pending_delayed_buff_keeps_its_skip_and_says_so_in_the_log(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 3600
        BfBot.Exec._forceMode = 0
        local entry = T_Entry({
            T_Effect("SPWI518", 2, { m_durationType = 6 }) })
        local casts = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { casts = casts, log = T_LogText() }
        """
    )
    assert facts["casts"] is False
    assert "delayed, not started" in facts["log"]


def test_a_live_timing_mode_is_never_masked_to_a_byte(exec_lua: LuaRuntime) -> None:
    # 4096 & 0xFF == 0. Masking belongs to feature blocks read out of a SPL,
    # not to a live CGameEffect, and doing it here would read every applied
    # timed effect as encoded mode 0 (unknown) instead of a real deadline.
    source = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")
    start = source.index("function BfBot.Exec._EffectRemaining(")
    body = source[start : source.index("\nend", start)]
    assert "0xFF" not in body
    assert "EEex_BAnd" not in body
    assert exec_lua.eval(
        "BfBot.Exec._EffectRemaining(T_Effect('X', 10), T_Now)"
    ) == pytest.approx(10, abs=0.1)


@pytest.mark.parametrize(
    "overrides",
    [
        "{ m_durationType = 0 }",
        "{ m_durationType = 3 }",
        "{ m_durationType = 10 }",
        "{ m_durationType = T_NIL }",
        '{ m_durationType = "4096" }',
        "{ m_duration = T_NIL }",
        '{ m_duration = "soon" }',
        "{ m_duration = 0/0 }",
    ],
    ids=[
        "encoded-instant",
        "encoded-delayed",
        "encoded-ticks",
        "no-timing",
        "string-timing",
        "no-deadline",
        "string-deadline",
        "nan-deadline",
    ],
)
def test_an_unreadable_or_unapplied_timing_reports_unknown_not_a_guess(
    exec_lua: LuaRuntime, overrides: str
) -> None:
    facts = exec_lua.execute(
        f"""
        local effect = T_Effect("SPWI518", 5, {overrides})
        local left, detail = BfBot.Exec._EffectRemaining(effect, T_Now)
        return {{ left = left, detail = detail }}
        """
    )
    assert facts["left"] == float("inf")
    assert facts["detail"] == "unknown"


def test_a_missing_world_time_reports_unknown_so_nothing_is_refreshed_blindly(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local effect = T_Effect("SPWI518", 5)
        local left, detail = BfBot.Exec._EffectRemaining(effect, nil)
        return { left = left, detail = detail }
        """
    )
    assert facts["left"] == float("inf")
    assert facts["detail"] == "unknown"


# --------------------------------------------------------------------------
# The three active checks
# --------------------------------------------------------------------------


def test_effect_remaining_reports_the_longest_lived_matching_effect(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local list = {
            T_Effect("SPWI518", 4),
            T_Effect("OTHER", 900),
            T_Effect("SPWI518", 61),
            T_Effect("SPWI518", 30),
        }
        local sprite = { m_timedEffectList = list }
        local left = BfBot.Exec._ActiveEffectRemaining(sprite, "SPWI518")
        local other = BfBot.Exec._ActiveEffectRemaining(sprite, "NOPE")
        return {
            left = left,
            other = other,
            has = BfBot.Exec._HasActiveEffect(sprite, "SPWI518"),
            hasOther = BfBot.Exec._HasActiveEffect(sprite, "NOPE"),
        }
        """
    )
    assert facts["left"] == pytest.approx(61, abs=0.1)
    assert facts["other"] is None
    assert facts["has"] is True
    assert facts["hasOther"] is False


def test_a_permanent_sibling_effect_does_not_hide_the_real_deadline(
    exec_lua: LuaRuntime,
) -> None:
    # Measured on live vanilla Armor (SPWI102, BG2:EE 2.7.3.0 + EEex v1.3.1,
    # 2026-10-24): op0/op142/op282 carry the real mode-4096 deadline while an
    # op174 sits in mode 7 forever. Folding that one into the maximum would
    # report every real buff as "never refresh".
    facts = exec_lua.execute(
        """
        local sprite = { m_timedEffectList = {
            T_Effect("SPWI102", 30, { m_effectId = 0 }),
            T_Effect("SPWI102", 2700, { m_effectId = 142 }),
            T_Effect("SPWI102", 2700, { m_effectId = 282 }),
            T_Effect("SPWI102", 2700, { m_effectId = 174,
                                        m_durationType = 7 }),
            T_Effect("SPWI102", 5, { m_effectId = 1, m_durationType = 1 }),
        } }
        local left, detail = BfBot.Exec._ActiveEffectRemaining(sprite, "SPWI102")
        return { left = left, detail = detail }
        """
    )
    assert facts["left"] == pytest.approx(2700, abs=0.1)
    assert facts["detail"] is None


def test_a_spell_with_only_unreadable_effects_still_reports_never_refresh(
    exec_lua: LuaRuntime,
) -> None:
    # With no readable deadline anywhere there is nothing to compare against a
    # threshold, so the fallback keeps the historical skip.
    facts = exec_lua.execute(
        """
        local sprite = { m_timedEffectList = {
            T_Effect("SPWI518", 5, { m_durationType = 1 }),
            T_Effect("SPWI518", 5, { m_durationType = 6 }),
        } }
        local left, detail = BfBot.Exec._ActiveEffectRemaining(sprite, "SPWI518")
        return { left = left, detail = detail }
        """
    )
    assert facts["left"] == float("inf")
    assert facts["detail"] == "perm"


def test_a_readable_deadline_wins_whatever_order_the_effects_arrive_in(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local permanentFirst = { m_timedEffectList = {
            T_Effect("SPWI102", 0, { m_durationType = 1 }),
            T_Effect("SPWI102", 40),
            T_Effect("SPWI102", 0, { m_durationType = 7 }),
        } }
        local permanentLast = { m_timedEffectList = {
            T_Effect("SPWI102", 40),
            T_Effect("SPWI102", 0, { m_durationType = 1 }),
        } }
        return {
            first = BfBot.Exec._ActiveEffectRemaining(permanentFirst, "SPWI102"),
            last = BfBot.Exec._ActiveEffectRemaining(permanentLast, "SPWI102"),
        }
        """
    )
    assert facts["first"] == pytest.approx(40, abs=0.1)
    assert facts["last"] == pytest.approx(40, abs=0.1)


def test_a_nearly_gone_buff_with_a_permanent_sibling_is_cast_again(
    exec_lua: LuaRuntime,
) -> None:
    # The user-reported shape: a long buff survives a rest with a tiny
    # remainder, and the spell also leaves a permanent administrative effect.
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 60
        BfBot.Exec._forceMode = 0
        local entry = T_Entry({
            T_Effect("SPWI518", 11, { m_effectId = 218 }),
            T_Effect("SPWI518", 0, { m_effectId = 174, m_durationType = 7 }),
        })
        local casts = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { casts = casts, log = T_LogText() }
        """
    )
    assert facts["casts"] is True
    assert "refreshing: SPWI518" in facts["log"]
    assert "11.0s left" in facts["log"]


def test_state_marker_remaining_only_counts_the_spells_own_marker(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local sprite = { m_timedEffectList = {
            -- same source, but not a marker opcode
            T_Effect("SPWI518", 900, { m_effectId = 101, m_dWFlags = 67 }),
            -- marker opcode and state, but another source
            T_Effect("OTHER", 900, { m_effectId = 328, m_dWFlags = 67 }),
            -- the spell's own marker
            T_Effect("SPWI518", 9, { m_effectId = 282, m_dWFlags = 67 }),
        } }
        local left = BfBot.Exec._ActiveStateMarkerRemaining(
            sprite, "SPWI518", { 67 })
        local none = BfBot.Exec._ActiveStateMarkerRemaining(
            sprite, "SPWI518", { 68 })
        return {
            left = left,
            none = none,
            has = BfBot.Exec._HasActiveStateMarker(sprite, "SPWI518", { 67 }),
        }
        """
    )
    assert facts["left"] == pytest.approx(9, abs=0.1)
    assert facts["none"] is None
    assert facts["has"] is True


def test_item_effect_remaining_needs_every_signature_and_takes_the_longest(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local signatures = {
            { opcode = 10, amount = 1, flags = 0 },
            { opcode = 20, amount = 2, flags = 0 },
        }
        local partial = { m_timedEffectList = {
            T_Effect("RING01", 7, { m_effectId = 10, m_effectAmount = 1 }),
        } }
        local complete = { m_timedEffectList = {
            T_Effect("RING01", 7, { m_effectId = 10, m_effectAmount = 1 }),
            T_Effect("RING01", 44, { m_effectId = 20, m_effectAmount = 2 }),
        } }
        return {
            partial = BfBot.Exec._ActiveItemEffectRemaining(
                partial, "RING01", signatures),
            complete = BfBot.Exec._ActiveItemEffectRemaining(
                complete, "RING01", signatures),
            empty = BfBot.Exec._ActiveItemEffectRemaining(
                complete, "RING01", {}),
            hasPartial = BfBot.Exec._HasActiveItemEffect(
                partial, "RING01", signatures),
            hasComplete = BfBot.Exec._HasActiveItemEffect(
                complete, "RING01", signatures),
        }
        """
    )
    assert facts["partial"] is None
    assert facts["complete"] == pytest.approx(44, abs=0.1)
    assert facts["empty"] is None
    assert facts["hasPartial"] is False
    assert facts["hasComplete"] is True


# --------------------------------------------------------------------------
# Threshold resolution
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("stored", "force_mode", "expected"),
    [
        # Default mode: the option alone decides, 0 meaning "skip everything
        # active" — the behavior before this issue.
        (None, 0, 0),
        (0, 0, 0),
        (30, 0, 30),
        (3600, 0, 3600),
        # "Refresh low" uses the option when it is set and the built-in
        # fallback when it is off, so the toggle always does something.
        (None, 1, 300),
        (0, 1, 300),
        (30, 1, 30),
        (3600, 1, 3600),
        # Hand-edited rubbish in baldur.ini must not widen the threshold.
        (-10, 0, 0),
        ("600", 0, 600),
        ("nonsense", 0, 0),
        (12.7, 0, 12),
        (999_999, 0, 86400),
    ],
)
def test_threshold_resolution_validates_the_option_and_honors_the_toggle(
    exec_lua: LuaRuntime, stored, force_mode: int, expected: int
) -> None:
    if stored is not None:
        exec_lua.globals().T_Ini.RefreshBelow = stored
    assert exec_lua.eval(f"BfBot.Exec._RefreshThreshold({force_mode})") == expected


def test_force_all_is_a_flag_and_never_an_infinite_threshold(
    exec_lua: LuaRuntime,
) -> None:
    # Christopher, 2026-10-24 (#84): force is a hard override, independent of
    # RefreshBelow. Expressing it as threshold = infinity would make the
    # override a value one stray comparison could undo, and no finite
    # threshold can reach a permanent effect anyway.
    exec_lua.globals().T_Ini.RefreshBelow = 30
    assert exec_lua.eval("BfBot.Exec._RefreshThreshold(2)") == 30
    assert exec_lua.eval("BfBot.Exec._ForceAll(2)") is True
    assert exec_lua.eval("BfBot.Exec._ForceAll(1)") is False
    assert exec_lua.eval("BfBot.Exec._ForceAll(0)") is False


def test_force_all_works_with_the_option_off_and_at_every_stored_value(
    exec_lua: LuaRuntime,
) -> None:
    # "Auch bei Schwelle 0 (aus) muss Force sofort funktionieren."
    for stored in (0, 30, 3600, 86400, -5, "nonsense", None):
        if stored is None:
            exec_lua.execute("T_Ini.RefreshBelow = nil")
        else:
            exec_lua.globals().T_Ini.RefreshBelow = stored
        assert exec_lua.eval("BfBot.Exec._ForceAll(2)") is True
        assert exec_lua.eval(
            "BfBot.Exec._ActiveBlocksCast(math.huge, "
            "BfBot.Exec._RefreshThreshold(2), BfBot.Exec._ForceAll(2))"
        ) is False


def test_force_all_casts_through_permanent_effects(exec_lua: LuaRuntime) -> None:
    # A permanent effect reports no remaining lifetime at all, so only the
    # flag can reach it. Every real permanent timing mode is covered.
    for timing in (1, 2, 4, 9):
        facts = exec_lua.execute(
            """
            local effect = T_Effect("SPWI102", 0, { m_durationType = %d })
            local remaining, detail = BfBot.Exec._EffectRemaining(effect, 0)
            return {
                remaining = remaining,
                detail = detail,
                skips = BfBot.Exec._ActiveBlocksCast(remaining, 0, false),
                forced = BfBot.Exec._ActiveBlocksCast(remaining, 0, true),
            }
            """ % timing
        )
        assert facts["remaining"] == float("inf"), timing
        assert facts["detail"] == "perm", timing
        assert facts["skips"] is True, timing
        assert facts["forced"] is False, timing


def test_threshold_defaults_to_the_run_scoped_mode_when_called_without_one(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 0
        BfBot.Exec._forceMode = 0
        local off = BfBot.Exec._RefreshThreshold()
        BfBot.Exec._forceMode = 1
        local low = BfBot.Exec._RefreshThreshold()
        BfBot.Exec._forceMode = 2
        local all = BfBot.Exec._RefreshThreshold()
        local allForced = BfBot.Exec._ForceAll()
        BfBot.Exec._forceMode = nil
        local missing = BfBot.Exec._RefreshThreshold()
        local missingForced = BfBot.Exec._ForceAll()
        return { off = off, low = low, all = all, allForced = allForced,
                 missing = missing, missingForced = missingForced }
        """
    )
    assert facts["off"] == 0
    assert facts["low"] == 300
    # Force All leaves the threshold alone and raises the flag instead.
    assert facts["all"] == 0
    assert facts["allForced"] is True
    assert facts["missing"] == 0
    assert facts["missingForced"] is False


@pytest.mark.parametrize(
    ("value", "expected"),
    [(0, 0), (1, 1), (2, 2), (3, 0), (-1, 0), (None, 0), ("2", 0), (1.5, 0)],
)
def test_force_mode_normalization_falls_back_to_the_conservative_mode(
    exec_lua: LuaRuntime, value, expected: int
) -> None:
    arg = "nil" if value is None else (
        f'"{value}"' if isinstance(value, str) else repr(value)
    )
    assert exec_lua.eval(f"BfBot.Exec._NormalizeForceMode({arg})") == expected


@pytest.mark.parametrize(
    ("remaining", "threshold", "blocks"),
    [
        ("nil", "0", False),
        ("nil", "3600", False),
        ("0", "0", True),
        ("0.5", "30", False),
        ("29.9", "30", False),
        ("30", "30", True),
        ("math.huge", "0", True),
        ("math.huge", "30", True),
        # An unusable threshold keeps the conservative skip rather than
        # quietly casting everything again.
        ("30", "nil", True),
    ],
)
def test_active_buff_blocks_a_cast_only_at_or_above_the_threshold(
    exec_lua: LuaRuntime, remaining: str, threshold: str, blocks: bool
) -> None:
    assert exec_lua.eval(
        f"BfBot.Exec._ActiveBlocksCast({remaining}, {threshold}, false)"
    ) is blocks


@pytest.mark.parametrize(
    ("remaining", "threshold"),
    [
        ("0", "0"),
        ("30", "30"),
        ("3600", "0"),
        ("math.huge", "0"),
        ("math.huge", "86400"),
        ("30", "nil"),
        ("nil", "nil"),
    ],
)
def test_the_force_flag_outranks_every_threshold_and_remaining_value(
    exec_lua: LuaRuntime, remaining: str, threshold: str
) -> None:
    assert exec_lua.eval(
        f"BfBot.Exec._ActiveBlocksCast({remaining}, {threshold}, true)"
    ) is False


# --------------------------------------------------------------------------
# Persisted preference
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        (0, 0),
        (30, 30),
        (86400, 86400),
        (86401, 86400),
        (1e9, 86400),
        (-1, 0),
        (12.9, 12),
        ("45", 45),
        ("", 0),
        ("twelve", 0),
        (None, 0),
        (True, 0),
    ],
)
def test_refresh_below_normalizer_is_strict_and_bounded(
    exec_lua: LuaRuntime, value, expected: int
) -> None:
    if value is None:
        arg = "nil"
    elif value is True:
        arg = "true"
    elif isinstance(value, str):
        arg = f'"{value}"'
    else:
        arg = repr(value)
    assert exec_lua.eval(
        f"BfBot.Persist._NormalizeRefreshBelow({arg})"
    ) == expected


def test_refresh_below_nan_and_infinities_collapse_to_off(
    exec_lua: LuaRuntime,
) -> None:
    for expression in ("0/0", "math.huge", "-math.huge"):
        assert exec_lua.eval(
            f"BfBot.Persist._NormalizeRefreshBelow({expression})"
        ) == 0


def test_refresh_below_accessors_validate_on_both_read_and_write(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local stored = BfBot.Persist.SetRefreshBelow(90.6)
        local readBack = BfBot.Persist.GetRefreshBelow()
        -- A hand-edited baldur.ini is untrusted on read, too.
        T_Ini.RefreshBelow = -5
        local negative = BfBot.Persist.GetRefreshBelow()
        T_Ini.RefreshBelow = 999999
        local huge = BfBot.Persist.GetRefreshBelow()
        local clamped = BfBot.Persist.SetRefreshBelow(999999)
        return {
            stored = stored, readBack = readBack,
            negative = negative, huge = huge, clamped = clamped,
            ini = T_Ini.RefreshBelow,
        }
        """
    )
    assert facts["stored"] == 90
    assert facts["readBack"] == 90
    assert facts["negative"] == 0
    assert facts["huge"] == 86400
    assert facts["clamped"] == 86400
    assert facts["ini"] == 86400


def test_refresh_below_default_is_off_so_behavior_is_unchanged_until_opted_in(
    exec_lua: LuaRuntime,
) -> None:
    assert exec_lua.eval('BfBot.Persist._INI_DEFAULTS.RefreshBelow') == 0
    assert exec_lua.eval("BfBot.Persist.GetRefreshBelow()") == 0
    assert exec_lua.eval("BfBot.Exec._RefreshThreshold(0)") == 0


# --------------------------------------------------------------------------
# _CheckEntry
# --------------------------------------------------------------------------


def test_a_long_lived_buff_is_still_skipped_and_the_log_names_what_is_left(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 60
        BfBot.Exec._forceMode = 0
        local entry = T_Entry({ T_Effect("SPWI518", 4000) })
        local casts = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { casts = casts, skips = BfBot.Exec._skipCount,
                 log = T_LogText() }
        """
    )
    assert facts["casts"] is False
    assert facts["skips"] == 1
    assert "already active: SPWI518" in facts["log"]
    assert "1h 6m left" in facts["log"]


def test_a_nearly_expired_buff_is_cast_again_and_the_log_says_why(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 60
        BfBot.Exec._forceMode = 0
        local entry = T_Entry({ T_Effect("SPWI518", 12) })
        local casts = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { casts = casts, skips = BfBot.Exec._skipCount,
                 log = T_LogText() }
        """
    )
    assert facts["casts"] is True
    assert facts["skips"] == 0
    assert "refreshing: SPWI518" in facts["log"]
    assert "12.0s left" in facts["log"]
    assert "threshold 1m 0s)" in facts["log"]  # no "left" on a threshold


def test_with_the_option_off_every_active_buff_still_skips(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 0
        BfBot.Exec._forceMode = 0
        local entry = T_Entry({ T_Effect("SPWI518", 0.2) })
        local nearlyGone = BfBot.Exec._CheckEntry(entry, T_Caster)
        -- Even an effect the engine has not swept yet (deadline already past)
        -- keeps the historical skip when the threshold is off.
        local expired = T_Entry({ T_Effect("SPWI518", -0.5) })
        local past = BfBot.Exec._CheckEntry(expired, T_Caster)
        return { nearlyGone = nearlyGone, past = past }
        """
    )
    assert facts["nearlyGone"] is False
    assert facts["past"] is False


def test_force_all_casts_through_permanent_and_unreadable_buffs_alike(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 0
        BfBot.Exec._forceMode = 2
        local permanent = T_Entry({
            T_Effect("SPWI518", 5, { m_durationType = 1 }) })
        local permanentCasts = BfBot.Exec._CheckEntry(permanent, T_Caster)
        local unreadable = T_Entry({
            T_Effect("SPWI518", 5, { m_durationType = 0 }) })
        local unreadableCasts = BfBot.Exec._CheckEntry(unreadable, T_Caster)
        local long = T_Entry({ T_Effect("SPWI518", 40000) })
        local longCasts = BfBot.Exec._CheckEntry(long, T_Caster)
        return {
            permanentCasts = permanentCasts,
            unreadableCasts = unreadableCasts,
            longCasts = longCasts,
            skips = BfBot.Exec._skipCount,
            log = T_LogText(),
        }
        """
    )
    assert facts["permanentCasts"] is True
    assert facts["unreadableCasts"] is True
    assert facts["longCasts"] is True
    assert facts["skips"] == 0
    assert "force all" in facts["log"]


def test_an_effect_whose_lifetime_cannot_be_read_keeps_the_conservative_skip(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 3600
        BfBot.Exec._forceMode = 0
        local entry = T_Entry({
            T_Effect("SPWI518", 5, { m_durationType = 10 }) })
        local casts = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { casts = casts, log = T_LogText() }
        """
    )
    assert facts["casts"] is False
    assert "unknown duration" in facts["log"]


def test_the_longest_lived_blocker_across_resrefs_is_the_one_logged(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 60
        BfBot.Exec._forceMode = 0
        local entry = T_Entry({
            T_Effect("LEAFA", 70),
            T_Effect("LEAFB", 4000),
        }, { leafResrefs = { "LEAFA", "LEAFB" } })
        local casts = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { casts = casts, log = T_LogText() }
        """
    )
    assert facts["casts"] is False
    assert "already active: LEAFB" in facts["log"]
    assert "already active: LEAFA" not in facts["log"]


def test_one_leaf_above_the_threshold_still_blocks_a_nearly_gone_sibling(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 60
        BfBot.Exec._forceMode = 0
        local entry = T_Entry({
            T_Effect("LEAFA", 3),
            T_Effect("LEAFB", 600),
        }, { leafResrefs = { "LEAFA", "LEAFB" } })
        local casts = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { casts = casts, log = T_LogText() }
        """
    )
    assert facts["casts"] is False
    assert "already active: LEAFB" in facts["log"]


def test_the_threshold_applies_to_a_spells_own_state_marker_too(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 60
        BfBot.Exec._forceMode = 0
        T_States = { [67] = true }
        local overrides = {
            splstates = { 67 },
            stateMarkersByResref = { SPWI518 = { 67 } },
        }
        local nearlyGone = T_Entry({
            T_Effect("SPWI518", 8, { m_effectId = 328, m_dWFlags = 67 }),
        }, overrides)
        local refreshCasts = BfBot.Exec._CheckEntry(nearlyGone, T_Caster)
        local healthy = T_Entry({
            T_Effect("SPWI518", 900, { m_effectId = 328, m_dWFlags = 67 }),
        }, overrides)
        local skipCasts = BfBot.Exec._CheckEntry(healthy, T_Caster)
        return { refreshCasts = refreshCasts, skipCasts = skipCasts }
        """
    )
    assert facts["refreshCasts"] is True
    assert facts["skipCasts"] is False


def test_the_threshold_applies_to_a_multi_ability_items_effects_too(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 60
        BfBot.Exec._forceMode = 0
        local overrides = {
            kind = "itm", itemResref = "RING01", itemMultiAbility = 1,
            leafResrefs = { "RING01" },
            itemEffects = { { opcode = 10, amount = 1, flags = 0 } },
        }
        BfBot.Scan.GetCastableSpells = function()
            return { SPWI518 = { count = 1 } }
        end
        local nearlyGone = T_Entry({
            T_Effect("RING01", 9, { m_effectId = 10, m_effectAmount = 1 }),
        }, overrides)
        local refreshCasts = BfBot.Exec._CheckEntry(nearlyGone, T_Caster)
        local healthy = T_Entry({
            T_Effect("RING01", 900, { m_effectId = 10, m_effectAmount = 1 }),
        }, overrides)
        local skipCasts = BfBot.Exec._CheckEntry(healthy, T_Caster)
        return { refreshCasts = refreshCasts, skipCasts = skipCasts }
        """
    )
    assert facts["refreshCasts"] is True
    assert facts["skipCasts"] is False


def test_a_boolean_answer_from_an_overridden_check_is_treated_as_unknown(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 3600
        BfBot.Exec._forceMode = 0
        local entry = T_Entry({})
        BfBot.Exec._ActiveEffectRemaining = function() return true end
        local activeCasts = BfBot.Exec._CheckEntry(entry, T_Caster)
        BfBot.Exec._ActiveEffectRemaining = function() return false end
        local inactiveCasts = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { activeCasts = activeCasts, inactiveCasts = inactiveCasts,
                 log = T_LogText() }
        """
    )
    assert facts["activeCasts"] is False
    assert facts["inactiveCasts"] is True
    assert "unknown duration" in facts["log"]


# --------------------------------------------------------------------------
# Run plumbing
# --------------------------------------------------------------------------


def test_start_records_and_normalizes_the_run_scoped_force_mode(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        local observed = {}
        BfBot.Exec._BuildQueue = function() return nil, "reason.exec.empty_queue", {} end
        for _, mode in ipairs({ 0, 1, 2, 7, "2" }) do
            BfBot.Exec._state = "idle"
            BfBot.Exec.Start({}, 0, nil, mode)
            observed[#observed + 1] = BfBot.Exec._forceMode
        end
        BfBot.Exec._state = "idle"
        BfBot.Exec.Start({}, 0, nil)
        observed[#observed + 1] = BfBot.Exec._forceMode
        return observed
        """
    )
    assert list(facts.values()) == [0, 1, 2, 0, 0, 0]


def test_hard_reset_returns_the_force_mode_to_the_safe_default(
    exec_lua: LuaRuntime,
) -> None:
    assert exec_lua.execute(
        """
        BfBot.Exec._forceMode = 2
        BfBot.Exec._HardReset()
        return BfBot.Exec._forceMode
        """
    ) == 0


def test_module_level_force_mode_starts_at_skip_active() -> None:
    source = (ROOT / "buffbot/BfBotExe.lua").read_text(encoding="utf-8")
    assert "BfBot.Exec._forceMode = 0" in source


def test_a_bare_console_queue_runs_on_the_option_alone() -> None:
    # Superseded an earlier reading of #84 that kept the panel toggle out of
    # F12. The selection is sticky and the panel keeps showing it, so a
    # keypress made with the panel shut must mean what the panel says, and
    # F12-after-rest is the reported case. Only a caller that passes nothing
    # at all — a raw console queue — falls back to the option alone.
    source = EXEC_SOURCE
    start = source.index("function BfBot.Exec.Start(")
    body = source[start:source.index("\nfunction ", start + 1)]
    assert "BfBot.Exec._NormalizeForceMode(forceMode)" in body
    # Nothing in Start consults the pending selection.
    assert "GetForceMode" not in body
    assert "_forceSelection" not in body


def test_every_panel_cast_path_carries_the_toggle_through_start_run() -> None:
    source = UI_SOURCE
    # Read from Exec, with the reload fallback the rest of this file uses.
    start = source.index("function BfBot.UI._StartRun(")
    read = source[start:source.index("\n    if started then", start)]
    assert "local forceMode = 0" in read
    assert "if BfBot.Exec.GetForceMode then" in read
    assert "pcall(BfBot.Exec.GetForceMode)" in read
    assert "BfBot.UI._forceMode" not in read
    # _StartRun dispatches on the simulation rate, and both branches must carry
    # the same policy: fast-forward may not change what a run skips.
    assert "BfBot.Fast.Start(queue, rate, presetIdx,\n                forceMode)" in source
    assert (
        "BfBot.Exec.Start(queue, qcMode, presetIdx,\n            forceMode)"
    ) in source
    # Cast All, Cast Character and the summons cast all go through _StartRun,
    # so none of them may start a run itself.
    assert source.count("BfBot.Exec.Start(") == 1
    assert source.count("BfBot.Fast.Start(") == 1
    # Cast All, Cast Character, the summons cast and the HUD preset picker.
    assert source.count("BfBot.UI._StartRun(") == 5  # 1 definition + 4 callers


def test_the_accelerated_path_hands_the_policy_straight_to_exec() -> None:
    # Fast.Start copies the queue and clears Quick Cast on it, so the policy
    # has to travel as its own argument or the toggle would die at 2x/4x.
    source = (ROOT / "buffbot/BfBotFst.lua").read_text(encoding="utf-8")
    assert "function F.Start(queue, multiplier, presetIdx, forceMode)" in source
    assert (
        "pcall(BfBot.Exec.Start, copy, 0,\n        presetIdx, forceMode)"
    ) in source


def test_the_toggle_is_never_written_to_the_save_or_the_ini() -> None:
    source = UI_SOURCE
    start = source.index("function BfBot.UI.CycleForceRecast(")
    end = source.index("\nfunction ", start + 1)
    body = source[start:end]
    assert "SetPref" not in body
    assert "Persist" not in body
    # No schema field, either: nothing in the config carries a force mode.
    persist = PERSIST_SOURCE
    assert "forceMode" not in persist
    assert '"RefreshBelow"' in persist


# --------------------------------------------------------------------------
# Panel toggle
# --------------------------------------------------------------------------


@pytest.fixture
def ui_lua(exec_lua: LuaRuntime) -> LuaRuntime:
    exec_lua.execute(
        """
        Infinity_GetScreenSize = function() return 1024, 768 end
        Infinity_SetArea = function() end
        Infinity_DisplayString = function() end
        EEex_Sprite_GetInPortrait = function() return nil end
        """
    )
    exec_lua.execute(THEME_SOURCE)
    exec_lua.execute(UI_SOURCE)
    # After the module, which initializes these itself.
    exec_lua.execute(
        """
        buffbot_isOpen = true
        buffbot_spellTable = {}
        buffbot_selectedRow = 0
        buffbot_charNames = {}
        """
    )
    return exec_lua


@pytest.fixture
def ui_layout(ui_lua: LuaRuntime):
    """Run the real _Layout at a screen size and hand back every area."""

    def run(width: int, height: int) -> dict[str, tuple[int, int, int, int]]:
        suppress = sys.platform == "win32" and faulthandler.is_enabled()
        if suppress:
            faulthandler.disable()
        try:
            raw = ui_lua.execute(
                """
                local areas = {}
                Infinity_GetScreenSize = function() return %d, %d end
                Infinity_SetArea = function(name, x, y, w, h)
                    areas[name] = { x, y, w, h }
                end
                BfBot.UI._Layout()
                return areas
                """
                % (width, height)
            )
        finally:
            if suppress:
                faulthandler.enable()
        return {
            key: tuple(int(value[i]) for i in range(1, 5))
            for key, value in raw.items()
        }

    return run


def test_the_toggle_cycles_through_its_three_states_and_wraps(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        local seen = {}
        BfBot.Exec.SetForceMode(0)
        for _ = 1, 4 do
            seen[#seen + 1] = BfBot.Exec.GetForceMode()
            BfBot.UI.CycleForceRecast()
        end
        return seen
        """
    )
    assert list(facts.values()) == [0, 1, 2, 0]


def test_each_state_has_its_own_label_color_and_tooltip(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        T_Ini.RefreshBelow = 0
        local rows = {}
        for mode = 0, 2 do
            BfBot.Exec.SetForceMode(mode)
            BfBot.UI._RefreshForceRecastCache()
            rows[#rows + 1] = {
                label = BfBot.UI._ForceRecastLabel(),
                color = tostring(BfBot.UI._ForceRecastColor()),
                tooltip = BfBot.UI._ForceRecastTooltip(),
            }
        end
        return rows
        """
    )
    rows = [dict(row) for row in facts.values()]
    labels = [row["label"] for row in rows]
    tooltips = [row["tooltip"] for row in rows]
    colors = [row["color"] for row in rows]
    assert labels == ["Active: Skip", "Active: Refresh Low", "Active: Force All"]
    assert len(set(labels)) == 3
    assert len(set(tooltips)) == 3
    assert len(set(colors)) == 3
    assert all("missing localization" not in text for text in labels + tooltips)
    # The "Refresh Low" tooltip names the threshold the run will really use.
    assert "300s" in tooltips[1]


def test_the_low_tooltip_follows_the_option_after_a_refresh(
    ui_lua: LuaRuntime,
) -> None:
    facts = ui_lua.execute(
        """
        BfBot.Exec.SetForceMode(1)
        T_Ini.RefreshBelow = 0
        BfBot.UI._RefreshForceRecastCache()
        local fallback = BfBot.UI._ForceRecastTooltip()
        T_Ini.RefreshBelow = 45
        -- Still cached: the tooltip is read per frame, so it must not hit the
        -- INI until something refreshes it.
        local stale = BfBot.UI._ForceRecastTooltip()
        BfBot.UI._RefreshForceRecastCache()
        local fresh = BfBot.UI._ForceRecastTooltip()
        return { fallback = fallback, stale = stale, fresh = fresh }
        """
    )
    assert "300s" in facts["fallback"]
    assert facts["stale"] == facts["fallback"]
    assert "45s" in facts["fresh"]


def test_the_label_is_empty_while_the_panel_is_closed(ui_lua: LuaRuntime) -> None:
    assert ui_lua.execute(
        """
        buffbot_isOpen = false
        BfBot.Exec.SetForceMode(2)
        return BfBot.UI._ForceRecastLabel()
        """
    ) == ""


def test_the_menu_button_is_wired_to_the_toggle_helpers() -> None:
    menu = (ROOT / "buffbot/BuffBot.menu").read_text(encoding="utf-8")
    start = menu.index('name    "bbForce"')
    block = menu[start : menu.index("}", start)]
    assert 'action  "BfBot.UI.CycleForceRecast()"' in block
    assert 'text lua "BfBot.UI._ForceRecastLabel()"' in block
    assert 'text color lua "BfBot.UI._ForceRecastColor()"' in block
    assert 'tooltip lua "BfBot.UI._ForceRecastTooltip()"' in block
    # Unlike Quick Cast this needs no generated SPL, so it stays usable
    # without LuaJIT.
    assert 'enabled "buffbot_isOpen"' in block


def test_the_layout_keeps_the_toggle_inside_the_panel_beside_the_status_line(
    ui_layout,
) -> None:
    """Run the real layout and look at where things landed.

    This used to assert the two `setArea` lines verbatim, which broke the
    moment the footer was rearranged even though the toggle was still in the
    right place. What matters is the result: the toggle shares the bottom row
    with the status line, does not cover it, and stays inside the parchment.
    """
    for width, height in ((1920, 1080), (1280, 720), (800, 600)):
        areas = ui_layout(width, height)
        px, py, pw, ph = areas["bbBg"]
        sx, sy, sw, sh = areas["bbStatus"]
        fx, fy, fw, fh = areas["bbForce"]

        assert fy == sy, (width, height)
        assert fx >= sx + sw, ("toggle overlaps the status line", width, height)
        assert fx + fw <= px + pw, ("toggle leaves the panel", width, height)
        assert fy + fh <= py + ph, ("toggle below the panel", width, height)
        # Clear air above the bottom rail, or the frame cuts the caption.
        assert py + ph - (fy + fh) >= 8, (width, height)


def test_a_refresh_is_not_logged_as_a_splstate_false_positive(
    exec_lua: LuaRuntime,
) -> None:
    # The false-positive notice means "SPLSTATE said active, the effect list
    # disagreed". When the threshold is what let the cast through, the effect
    # list agreed, so that notice would be a lie.
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 60
        BfBot.Exec._forceMode = 0
        T_States = { [67] = true }
        local entry = T_Entry({
            T_Effect("SPWI518", 8, { m_effectId = 328, m_dWFlags = 67 }),
        }, {
            splstates = { 67 },
            stateMarkersByResref = { SPWI518 = { 67 } },
        })
        local casts = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { casts = casts, log = T_LogText() }
        """
    )
    assert facts["casts"] is True
    assert "refreshing: SPWI518" in facts["log"]
    assert "false positive" not in facts["log"]


def test_a_real_splstate_false_positive_is_still_reported(
    exec_lua: LuaRuntime,
) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 60
        BfBot.Exec._forceMode = 0
        T_States = { [67] = true }
        -- The state is on, but no marker from THIS spell is in the list.
        local entry = T_Entry({
            T_Effect("OTHER", 900, { m_effectId = 328, m_dWFlags = 67 }),
        }, {
            splstates = { 67 },
            stateMarkersByResref = { SPWI518 = { 67 } },
        })
        local casts = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { casts = casts, log = T_LogText() }
        """
    )
    assert facts["casts"] is True
    assert "false positive" in facts["log"]
    assert "refreshing" not in facts["log"]


# --------------------------------------------------------------------------
# Force All as a hard override (Christopher, 2026-10-24)
# --------------------------------------------------------------------------


def test_force_all_casts_a_permanent_buff_through_check_entry(
    exec_lua: LuaRuntime,
) -> None:
    # The end-to-end case no finite threshold can reach: a permanent effect
    # reports no remaining lifetime, so only the override gets past it.
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = 0
        local entry = T_Entry({
            T_Effect("SPWI518", 0, { m_durationType = 1, m_duration = 0 }),
        })
        BfBot.Exec._forceMode = 0
        local skipped = BfBot.Exec._CheckEntry(entry, T_Caster)
        BfBot.Exec._log = {}
        BfBot.Exec._forceMode = 2
        local forced = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { skipped = skipped, forced = forced, log = T_LogText() }
        """
    )
    assert facts["skipped"] is False
    assert facts["forced"] is True
    assert "force all" in facts["log"]


def test_force_all_needs_no_option_set_at_all(exec_lua: LuaRuntime) -> None:
    facts = exec_lua.execute(
        """
        T_Ini.RefreshBelow = nil
        BfBot.Exec._forceMode = 2
        local entry = T_Entry({ T_Effect("SPWI518", 4000) })
        local casts = BfBot.Exec._CheckEntry(entry, T_Caster)
        return { casts = casts, skips = BfBot.Exec._skipCount,
                 log = T_LogText() }
        """
    )
    assert facts["casts"] is True
    assert facts["skips"] == 0
    assert "force all" in facts["log"]
    # The banner must name the override, never a threshold, under Force All.
    assert "threshold" not in facts["log"]


def test_force_all_does_not_weaken_the_other_preconditions(
    exec_lua: LuaRuntime,
) -> None:
    # Force only lifts the active/remaining-duration check. A dead target and
    # a missing spell slot must still refuse the cast under the override.
    dead = exec_lua.execute(
        """
        BfBot.Exec._forceMode = 2
        local entry = T_Entry({})
        BfBot.Exec._IsAlive = function() return false end
        return BfBot.Exec._CheckEntry(entry, T_Caster)
        """
    )
    assert dead is False

    no_slot = exec_lua.execute(
        """
        BfBot.Exec._forceMode = 2
        local entry = T_Entry({})
        BfBot.Exec._IsAlive = function() return true end
        BfBot.Scan.GetCastableSpells = function() return {} end
        return BfBot.Exec._CheckEntry(entry, T_Caster)
        """
    )
    assert no_slot is False


def test_the_force_state_is_reachable_without_the_panel(
    exec_lua: LuaRuntime,
) -> None:
    # The panel is being rebuilt (#81), so Exec owns the selection and a plain
    # Lua call must be able to set it. Nothing here touches BfBot.UI.
    facts = exec_lua.execute(
        """
        local seen = {}
        BfBot.Exec.SetForceMode(0)
        for _ = 1, 4 do
            seen[#seen + 1] = BfBot.Exec.GetForceMode()
            BfBot.Exec.CycleForceMode()
        end
        return { cycle = seen,
                 clamped = BfBot.Exec.SetForceMode(7),
                 fromString = BfBot.Exec.SetForceMode("2"),
                 explicit = BfBot.Exec.SetForceMode(2) }
        """
    )
    assert list(facts["cycle"].values()) == [0, 1, 2, 0]
    assert facts["clamped"] == 0
    assert facts["fromString"] == 0
    assert facts["explicit"] == 2


def test_the_selection_and_the_running_mode_are_separate() -> None:
    # Exec.Start takes the mode as an argument and must not read the pending
    # selection itself, or F12 would inherit whatever the panel last showed.
    source = EXEC_SOURCE
    start = source.index("function BfBot.Exec.Start(")
    end = source.index("\nfunction ", start + 1)
    body = source[start:end]
    assert "_NormalizeForceMode(forceMode)" in body
    assert "_forceSelection" not in body
    assert "GetForceMode" not in body


def test_the_panel_side_holds_no_force_state_of_its_own() -> None:
    # Keep the panel surface thin so the #81 rebuild only re-places a button.
    source = UI_SOURCE
    assert "BfBot.UI._forceMode" not in source
    for name in ("CycleForceRecast", "_ForceRecastLabel", "_ForceRecastColor",
                 "_ForceRecastTooltip"):
        assert f"function BfBot.UI.{name}(" in source


def test_a_panel_reloaded_against_an_older_exec_falls_back_to_skip(
    ui_lua: LuaRuntime,
) -> None:
    # The reload fallback must choose the conservative mode, never force.
    mode = ui_lua.execute(
        """
        BfBot.Exec.SetForceMode(2)
        BfBot.Exec.GetForceMode = nil
        local seen
        BfBot.Exec.Start = function(_, _, _, force) seen = force; return true end
        BfBot.UI._FastForwardRate = function() return 1 end
        BfBot.UI._StartRun({ { resref = "SPWI518" } }, 0, 1)
        return seen
        """
    )
    assert mode == 0


# --------------------------------------------------------------------------
# Review follow-ups (PR #86)
# --------------------------------------------------------------------------


def test_the_f12_innate_path_passes_the_selected_policy_through() -> None:
    # Pressing F12 after a rest is the case #84 was reported for, so an innate
    # run must mean what the panel says. Both start paths carry the mode.
    source = (ROOT / "buffbot/BfBotInn.lua").read_text(encoding="utf-8")
    assert "if BfBot.Exec.GetForceMode then" in source
    assert "pcall(BfBot.Exec.GetForceMode)" in source
    assert "local forceMode = 0" in source
    assert "BfBot.Fast.Start(queue, speed,\n                    presetIdx, forceMode)" in source
    assert "BfBot.Exec.Start(queue, qcMode,\n                presetIdx, forceMode)" in source


def test_the_innate_path_never_starts_a_run_without_the_mode() -> None:
    source = (ROOT / "buffbot/BfBotInn.lua").read_text(encoding="utf-8")
    for call in ("BfBot.Exec.Start(queue, qcMode, presetIdx)",
                 "BfBot.Fast.Start(queue, speed, presetIdx)"):
        assert call not in source, call


def test_both_duration_formatters_agree_on_the_same_staircase(
    exec_lua: LuaRuntime,
) -> None:
    # A log line is read beside the panel's Dur column and the option label.
    # When this printed flat minutes, "threshold 60m 0s" next to "Under 1 hour
    # left" read as two different numbers.
    cases = {
        3600: "1h left",
        5400: "1h 30m left",
        3660: "1h 1m left",
        300: "5m 0s left",
        102: "1m 42s left",
        45: "45.0s left",
        0: "0.0s left",
    }
    for seconds, expected in cases.items():
        assert exec_lua.eval(
            f"BfBot.Exec._FormatRemaining({seconds})"
        ) == expected, seconds


def test_the_low_threshold_constant_is_documented_as_five_minutes() -> None:
    source = (ROOT / "buffbot/BfBotCor.lua").read_text(encoding="utf-8")
    start = source.index("-- Threshold the panel's \"Refresh low\"")
    block = source[start:source.index("BfBot.REFRESH_LOW_SECONDS = 300") + 40]
    assert "five minutes" in block
    # 300 seconds is five minutes on the engine's own scale, not an hour.
    assert "game hour" not in block
    # The LongThreshold rationale is accurate and worth keeping.
    assert "LongThreshold" in block
    persist = PERSIST_SOURCE
    assert "LongThreshold = 300" in persist


def test_the_in_game_phase_guarantees_cleanup_after_a_failure() -> None:
    # The phase writes the real baldur.ini and applies a PERMANENT effect to
    # the protagonist, and it runs inside RunAll(). Neither may survive an
    # error in the middle.
    source = (ROOT / "buffbot/BfBotTst.lua").read_text(encoding="utf-8")
    start = source.index("function BfBot.Test.RefreshThreshold()")
    body = source[start:source.index("\nfunction ", start + 1)]

    assert "local guarded, guardErr = pcall(function()" in body
    # The restore sits after the guarded block, not inside it.
    guard_end = body.index("    end)")
    after = body[guard_end:]
    assert "effectID     = 321," in after
    assert 'BfBot.Persist.SetPref("RefreshBelow", savedPref)' in after
    # A swallowed error must fail the phase.
    assert '_nok("the guarded section errored: " .. tostring(guardErr))' in after
    # One cleanup only, and it is the unconditional one.
    assert body.count("effectID     = 321,") == 1
    assert body.count('SetPref("RefreshBelow", savedPref)') == 1
    # The dead force-mode save/restore pair is gone.
    assert "savedForce" not in body
    # The cleanup's sprite handle must not be shadowed inside the guard.
    assert body.count("local sprite = EEex_Sprite_GetInPortrait(0)") == 1
