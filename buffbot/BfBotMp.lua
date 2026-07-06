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
-- CONVENTIONS — verified in-engine 2026-07-05 (single-player + MP host):
--   * The array stores the DirectPlay player ID (compare m_idLocalPlayer), NOT
--     the player number (m_nLocalPlayer). Live host read: array=1, m_idLocalPlayer=1.
--   * Indexed by join order (EEex_Sprite_GetCharacterIndex).
--   * Single-player: m_bConnectionEstablished=0 (short-circuit), array/id both 0.
--   NOT yet confirmed on a second machine: that a CLIENT reports a distinct
--   m_idLocalPlayer and the array splits host-vs-client by id. Auto mode ships
--   ON by default (backstopped by the exec watchdog + the manual/all override);
--   BfBot.Mp.Probe() remains for a host+client diff to close that last gap.

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

-- ============================================================
-- Local-control detection (caster filter)
-- ============================================================
-- BuffBot may only issue casts to characters the LOCAL machine controls; a cast
-- queued on a character owned by another player never runs (the action chain is
-- local-only and non-networked), which hangs the run until the watchdog trips.
--
-- CONTROL MODE (baldur.ini [BuffBot], per-machine):
--   MpControlMode = "auto"   (default) — engine ownership detection
--                 | "manual"           — use MpControlNames (comma-separated).
--                     Matches on DISPLAY NAME, so an in-game rename (e.g. Anomen
--                     -> "Sir Anomen" on knighthood) breaks the match — update
--                     MpControlNames after a rename, or use "auto".
--                 | "all"              — no filtering (every caster; watchdog backstops)
--
-- AUTO rule, verified live in SP + MP host (2026-07-05): a character is locally
-- controlled iff its entry in m_pnCharacterControlledByPlayer (indexed by join
-- order) equals CNetwork.m_idLocalPlayer — the DirectPlay player ID, NOT
-- m_nLocalPlayer (the player number). SP short-circuits on
-- m_bConnectionEstablished == 0. All engine reads are pcall-guarded; on ANY
-- failure we DEGRADE TO controllable so a reflection hiccup never silently stops
-- buffing (the BfBot.Exec watchdog still backstops any resulting hang).

--- Read the control mode from baldur.ini (default "auto").
function BfBot.Mp._GetControlMode()
    if BfBot.Persist and BfBot.Persist.GetPref then
        local m = BfBot.Persist.GetPref("MpControlMode")
        if type(m) == "string" and m ~= "" then return m end
    end
    return "auto"
end

--- Manual mode: is `sprite`'s name in the local player's MpControlNames list?
function BfBot.Mp._NameInManualList(sprite)
    if not (BfBot.Persist and BfBot.Persist.GetPref) then return false end
    local list = BfBot.Persist.GetPref("MpControlNames")
    if type(list) ~= "string" or list == "" then return false end
    local myName = BfBot._GetName(sprite)
    for token in list:gmatch("[^,]+") do
        local trimmed = token:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed == myName then return true end
    end
    return false
end

--- Does the local machine control `sprite` (so BuffBot may cast to it)?
--- @param sprite userdata: a portrait party member
--- @return boolean
function BfBot.Mp.IsLocallyControlled(sprite)
    if not sprite then return false end

    local mode = BfBot.Mp._GetControlMode()
    if mode == "all" then return true end  -- filtering disabled

    local chitin = _getChitin()
    if not chitin then return true end     -- can't tell → don't block buffing

    -- Single-player: connection not established → local machine controls all,
    -- regardless of mode (never break the single-player path).
    local okConn, conn = pcall(function() return chitin.cNetwork.m_bConnectionEstablished end)
    if not okConn then return true end
    -- `not conn` covers a BOOL reflected as Lua false; `conn == 0` covers it as int 0.
    if not conn or conn == 0 then return true end

    if mode == "manual" then
        return BfBot.Mp._NameInManualList(sprite)
    end

    -- Auto-detect (multiplayer): compare the character's controlling-player ID
    -- against this machine's local player ID.
    local okIdx, idx = pcall(EEex_Sprite_GetCharacterIndex, sprite)
    if not okIdx or type(idx) ~= "number" or idx < 0 then return true end

    local okOwner, owner = pcall(function()
        return chitin.m_pObjectGame.m_multiPlayerSettings.m_pnCharacterControlledByPlayer:get(idx)
    end)
    if not okOwner or owner == nil then return true end

    local okMe, myId = pcall(function() return chitin.cNetwork.m_idLocalPlayer end)
    if not okMe or myId == nil then return true end

    return owner == myId
end

--- MP ownership probe. Run on EACH machine in a live multiplayer session
--- (world screen), then diff the two buffbot_mp_probe.log files. The field whose
--- value tracks the local machine is the per-client discriminator (verified for
--- SP + host: m_idLocalPlayer is the discriminator, while the
--- m_pnCharacterControlledByPlayer array is identical on both machines — its
--- entries equal the controlling machine's m_idLocalPlayer, the DirectPlay ID,
--- NOT m_nLocalPlayer the player number). Fully pcall-guarded;
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
