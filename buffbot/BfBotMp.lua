-- ============================================================
-- BfBotMp.lua — Multiplayer support (BfBot.Mp)
-- ============================================================
-- In multiplayer each network player controls only a SUBSET of the party.
-- BuffBot's casting queues SpellRES + EEex_LuaAction onto the *local* copy of a
-- creature's action list (EEex_Action_QueueResponseStringOnAIBase ->
-- virtual_InsertAction, which is NOT networked). A character controlled by
-- another player never runs that locally-queued chain, so its _Advance callback
-- never fires and BuffBot would otherwise hang. BfBot.Exec's watchdog is the
-- safety net for that hang; the real fix is to not queue non-local casters.
--
-- The authoritative control map is engine state, with no EEex Lua wrapper:
--   CInfGame.m_multiPlayerSettings.m_pnCharacterControlledByPlayer  -- Array<int,6>
--       global, replicated, identical on every client: party index -> player num
--   CNetwork.m_nLocalPlayer  -- per-machine: this client's player number
--   => a character is locally controllable when those two values match.
--
-- The exact CONVENTIONS can only be confirmed on two live machines:
--   * Does the array store a player NUMBER (compare m_nLocalPlayer) or a
--     DirectPlay ID (compare m_idLocalPlayer)? Base 0 or 1?
--   * Is it indexed by join order (EEex_Sprite_GetCharacterIndex) or portrait
--     order (the slot)?
--   * What are the single-player default values (so the SP short-circuit is safe)?
--
-- BfBot.Mp.Probe() dumps every candidate field so a host+client diff resolves
-- them. Until confirmed, NO automatic caster filtering ships — this module
-- currently provides the probe only. The caster filter + manual override land
-- in a follow-up once the probe output is in hand.

BfBot = BfBot or {}
BfBot.Mp = {}

BfBot.Mp._probeFile = "buffbot_mp_probe.log"

--- Resolve the CBaldurChitin engine global across EEex naming variants.
local function _getChitin()
    if rawget(_G, "EEex_EngineGlobal_CBaldurChitin") then
        return EEex_EngineGlobal_CBaldurChitin
    end
    if rawget(_G, "EngineGlobals") and EngineGlobals.g_pBaldurChitin then
        return EngineGlobals.g_pBaldurChitin
    end
    if rawget(_G, "g_pBaldurChitin") then return g_pBaldurChitin end
    return nil
end

--- MP ownership probe. Run on EACH machine in a live multiplayer session
--- (world screen), then diff the two buffbot_mp_probe.log files. The field whose
--- value tracks the local machine is the per-client discriminator (expected:
--- m_nLocalPlayer differs between host and client, while the
--- m_pnCharacterControlledByPlayer array is identical on both — its entries
--- should equal the controlling machine's m_nLocalPlayer). Fully pcall-guarded;
--- touches no area lists and never calls EEex_PtrToUD.
--- @return string the full report (also written to buffbot_mp_probe.log)
function BfBot.Mp.Probe()
    local out = {}
    local function L(s) out[#out + 1] = s end
    local function safe(f)
        local ok, v = pcall(f)
        if ok then return tostring(v) else return "ERR(" .. tostring(v) .. ")" end
    end

    L("=== BuffBot MP ownership probe v" .. (BfBot.VERSION or "?") .. " ===")
    L("Run on host AND each client in a live MP session, then diff the logs.")

    local chitin = _getChitin()
    L("chitin = " .. tostring(chitin))
    if not chitin then
        L("ERROR: could not resolve CBaldurChitin engine global; aborting.")
        local report = table.concat(out, "\n")
        BfBot._Display("BuffBot MP probe failed: no CBaldurChitin global (see return value)")
        return report
    end

    L("m_pObjectGame = " .. safe(function() return chitin.m_pObjectGame end))
    L("cNetwork      = " .. safe(function() return chitin.cNetwork end))

    -- Per-machine network identity (SHOULD differ between host and client).
    L("-- CNetwork (per-machine) --")
    L("m_bConnectionEstablished = " .. safe(function() return chitin.cNetwork.m_bConnectionEstablished end))
    L("m_bIsHost                = " .. safe(function() return chitin.cNetwork.m_bIsHost end))
    L("m_nTotalPlayers          = " .. safe(function() return chitin.cNetwork.m_nTotalPlayers end))
    L("m_nLocalPlayer           = " .. safe(function() return chitin.cNetwork.m_nLocalPlayer end))
    L("m_idLocalPlayer          = " .. safe(function() return chitin.cNetwork.m_idLocalPlayer end))
    L("m_nHostPlayer            = " .. safe(function() return chitin.cNetwork.m_nHostPlayer end))
    for i = 0, 5 do
        L(string.format("m_pPlayerID[%d]           = %s", i,
            safe(function() return chitin.cNetwork.m_pPlayerID:get(i) end)))
    end

    -- Shared/replicated control map (SHOULD be identical on both machines).
    L("-- CMultiplayerSettings (replicated) --")
    for i = 0, 5 do
        L(string.format("CtrlByPlayer[%d]          = %s", i,
            safe(function() return chitin.m_pObjectGame.m_multiPlayerSettings.m_pnCharacterControlledByPlayer:get(i) end)))
    end
    for i = 0, 5 do
        L(string.format("LoadGameCtrlBy[%d]        = %s", i,
            safe(function() return chitin.m_pObjectGame.m_multiPlayerSettings.m_pnLoadGameControlledByPlayer:get(i) end)))
    end

    -- Correlate each portrait slot to BOTH index bases so we learn whether the
    -- control array is indexed by join order (charIdx) or portrait order (slot).
    L("-- Per-portrait correlation --")
    for slot = 0, 5 do
        local sprite = nil
        local sOk, s = pcall(EEex_Sprite_GetInPortrait, slot)
        if sOk then sprite = s end
        if sprite then
            local cidx = safe(function() return EEex_Sprite_GetCharacterIndex(sprite) end)
            local pidx = safe(function() return EEex_Sprite_GetPortraitIndex(sprite) end)
            local name = safe(function() return BfBot._GetName(sprite) end)
            local byChar = safe(function()
                return chitin.m_pObjectGame.m_multiPlayerSettings.m_pnCharacterControlledByPlayer:get(
                    EEex_Sprite_GetCharacterIndex(sprite))
            end)
            local byPort = safe(function()
                return chitin.m_pObjectGame.m_multiPlayerSettings.m_pnCharacterControlledByPlayer:get(slot)
            end)
            L(string.format("slot %d name=%s charIdx=%s portIdx=%s ctrl[byChar]=%s ctrl[byPort]=%s",
                slot, name, cidx, pidx, byChar, byPort))
        else
            L(string.format("slot %d <empty>", slot))
        end
    end

    local report = table.concat(out, "\n")

    -- Persist to a file the user can send (the in-game console is not copyable).
    if BfBot._OpenLogAppend and BfBot._OpenLogAppend(BfBot.Mp._probeFile) then
        BfBot._Print(report)
        BfBot._CloseLog()
        BfBot._Display("BuffBot MP probe written to " .. BfBot.Mp._probeFile)
    else
        -- No file IO (LuaJIT/io unavailable): fall back to console output.
        if print then print(report) end
        BfBot._Display("BuffBot MP probe (no file IO): see console / return value")
    end

    return report
end
