-- M_BfBot.lua — BuffBot Bootstrap
-- Engine auto-loads all M_*.lua from override alphabetically.
-- EEex's M___EEex.lua loads first, then M_BfBot.lua.
if not EEex_Active then return end

BfBot = BfBot or {}
if not io then
    BfBot._noIO = 1
end

Infinity_DoFile("BfBotCor")  -- Namespace, logging, shared utilities, caches
Infinity_DoFile("BfBotLoc")  -- file-backed localization with English fallback

if BfBot._noIO then
    EEex_Menu_AddAfterMainFileLoadedListener(BfBot._SafeCallback(
        "main.no_luajit_notice", function()
        Infinity_DisplayString(BfBot.L10N.Get("feedback.no_luajit"))
    end))
end

Infinity_DoFile("BfBotThm")  -- Theme palettes (must load before UI reads colors)
Infinity_DoFile("BfBotCls")  -- Classifier (standalone, uses BfBot._Print/_Log only)
Infinity_DoFile("BfBotScn")  -- Scanner (depends on Class)
Infinity_DoFile("BfBot5e")   -- 5E Spellcasting adapter (used by Scan + Exec)
Infinity_DoFile("BfBotExe")  -- Execution engine (depends on Scan, _GetName)
Infinity_DoFile("BfBotMp")   -- Multiplayer support / ownership probe (depends on _GetName)
Infinity_DoFile("BfBotPer")  -- Persistence (depends on Scan, Class)
Infinity_DoFile("BfBotInn")  -- Retired shortcut cleanup and legacy helper spells
BfBot.Persist.Init()         -- Register marshal handlers for save/load
Infinity_DoFile("BfBotPln")  -- Recipient plans and resource reservations
Infinity_DoFile("BfBotShr")  -- Engine-checked sharing and persistent return journal
BfBot.Plan.Init()           -- Separate, versioned party-plan save handler
Infinity_DoFile("BfBotIO")   -- Non-executable recipient-plan export/import
Infinity_DoFile("BfBotRst")  -- Completed-rest recipient preset
BfBot.Rest.Init()
Infinity_DoFile("BfBotFst")  -- Native normal casting with temporary simulation speed
BfBot.Fast.Init()
Infinity_DoFile("BfBotPUI")  -- Recipient-first panel callbacks
Infinity_DoFile("BfBotVD")   -- Generated modular visual resources and design tokens
Infinity_DoFile("BfBotVis")  -- Optional UI++ recipient presentation; old art fallback
BfBot.Legacy.EnsureHelperSpells()
BfBot.Legacy.Init()         -- Remove retired shortcuts when old characters load

-- Late-join listener (issue #19): a summon spawning MID-RUN attaches to the
-- running cast as its own caster. Thin wrapper — the guarded, testable body
-- is BfBot.Exec._OnSpriteLoaded; resolving it through the namespace at fire
-- time means a hot-reloaded BfBotExe swaps in transparently. The guard flag
-- lives on the BfBot ROOT (module re-execution resets BfBot.Exec, never
-- BfBot), so a re-run of this file can never stack a second listener.
if not BfBot._lateJoinListenerRegistered then
    BfBot._lateJoinListenerRegistered = true
    EEex_Sprite_AddLoadedListener(BfBot._SafeCallback(
        "main.late_join", function(sprite)
        BfBot.Exec._OnSpriteLoaded(sprite)
    end))
end
Infinity_DoFile("BfBotUI")   -- UI logic (state, callbacks, .menu integration)
Infinity_DoFile("BfBotTst")  -- Test suite (remove for release)

-- Register for after-UI-load — menus are ready, safe to load .menu and inject
EEex_Menu_AddAfterMainFileLoadedListener(BfBot._SafeCallback(
    "main.menu_loaded", function()
    BfBot.UI._OnMenusLoaded()
end))
