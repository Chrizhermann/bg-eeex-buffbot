-- tools/dump_innates.lua — diagnostic for the rest-crash duplicate-innate bug.
-- Paste this whole file into the in-game console (Ctrl-Space).
-- Writes <game-dir>/buffbot_diag.log. Send that file back for analysis.
--
-- All engine calls are wrapped in pcall and avoid known-unsafe paths
-- (no GetKnownSpellInnate at non-canonical levels, no GetQuickButtons).

local function _esc(s) return tostring(s):gsub("[%c\1-\31]", "?") end

local f = io.open("buffbot_diag.log", "w")
if not f then print("[BfBotDiag] FAILED to open log") return end

local function P(s) f:write(s .. "\n") end

P("=== BuffBot diagnostic " .. (os.date and os.date("%Y-%m-%d %H:%M:%S") or "?") .. " ===")
P("BfBot.VERSION = " .. tostring(BfBot and BfBot.VERSION or "nil"))
if EEex_VERSION then P("EEex_VERSION = " .. tostring(EEex_VERSION)) end
P("")

for slot = 0, 5 do
    local sp = EEex_Sprite_GetInPortrait(slot)
    if sp then
        local name = "?"
        pcall(function() name = EEex_Sprite_GetName(sp) or "?" end)
        P("=== Slot " .. slot .. ": " .. _esc(name) .. " ===")

        -- Basic iterator: every known innate entry (level, idx, resref)
        local entries = {}
        pcall(function()
            for level, idx, resref in EEex_Sprite_GetKnownInnateSpellsIterator(sp) do
                table.insert(entries, string.format("[L%d#%d %s]", level, idx, _esc(resref)))
            end
        end)
        P("[Basic iterator]:  " .. (#entries > 0 and table.concat(entries, " ") or "(empty)"))

        -- Valid iterator: same as basic but filtered to entries whose SPL loads
        local validEntries = {}
        pcall(function()
            for level, idx, resref in EEex_Sprite_GetValidKnownInnateSpellsIterator(sp) do
                table.insert(validEntries, string.format("[L%d#%d %s]", level, idx, _esc(resref)))
            end
        end)
        P("[Valid iterator]:  " .. (#validEntries > 0 and table.concat(validEntries, " ") or "(empty)"))

        -- BFBT* counts per resref
        local bfbt = {}
        pcall(function()
            for _, _, r in EEex_Sprite_GetKnownInnateSpellsIterator(sp) do
                if type(r) == "string" and r:match("^BFBT") then
                    bfbt[r] = (bfbt[r] or 0) + 1
                end
            end
        end)
        local bp = {}
        for r, n in pairs(bfbt) do table.insert(bp, r .. "=" .. tostring(n)) end
        table.sort(bp)
        P("[BFBT counts]:     " .. (#bp > 0 and table.concat(bp, " ") or "(none)"))

        -- UDAux marshal payload
        local cfg = nil
        pcall(function() cfg = EEex_GetUDAux(sp)[BfBot.Persist._KEY] end)
        if cfg and cfg.presets then
            local ps = {}
            for i = 1, 8 do
                if cfg.presets[i] then
                    table.insert(ps, "p" .. i .. "=" .. _esc(cfg.presets[i].name or "?"))
                end
            end
            P("[Config v=" .. tostring(cfg.v) .. "]:    " .. table.concat(ps, ", "))
        else
            P("[Config]:          nil (UDAux empty)")
        end

        -- Diff: expected (from config) vs actual (in CRE)
        local expected = {}
        if cfg and cfg.presets then
            for i = 1, 8 do
                if cfg.presets[i] then expected["BFBT" .. slot .. i] = true end
            end
        end
        local issues = {}
        for resref in pairs(expected) do
            if not bfbt[resref] then table.insert(issues, "MISSING:" .. resref) end
        end
        for resref, n in pairs(bfbt) do
            if not expected[resref] then
                table.insert(issues, "ORPHAN:" .. resref .. "(n=" .. n .. ")")
            end
            if n > 1 then
                table.insert(issues, "DUPLICATE:" .. resref .. "(n=" .. n .. ")")
            end
        end
        if #issues > 0 then
            table.sort(issues)
            P("[Issues]:          " .. table.concat(issues, " "))
        else
            P("[Issues]:          (none — actual matches config)")
        end
        P("")
    end
end

f:close()
print("[BfBotDiag] Wrote buffbot_diag.log")
