-- M_BfBot.lua — BuffBot Bootstrap
-- Engine auto-loads all M_*.lua from override alphabetically.
-- EEex's M___EEex.lua loads first, then M_BfBot.lua.
if not EEex_Active then return end

BfBot = BfBot or {}
if not io then
    BfBot._noIO = 1
end

Infinity_DoFile("BfBotCor")  -- Namespace, logging, shared utilities, caches

if BfBot._noIO then
    EEex_Menu_AddAfterMainFileLoadedListener(BfBot._SafeCallback(
        "main.no_luajit_notice", function()
        Infinity_DisplayString("BuffBot: LuaJIT not detected. F12 innates, Quick Cast, Export/Import, and logging are disabled. Install EEex LuaJIT component for full functionality.")
    end))
end

Infinity_DoFile("BfBotThm")  -- Theme palettes (must load before UI reads colors)
Infinity_DoFile("BfBotCls")  -- Classifier (standalone, uses BfBot._Print/_Log only)
Infinity_DoFile("BfBotScn")  -- Scanner (depends on Class)
Infinity_DoFile("BfBotExe")  -- Execution engine (depends on Scan, _GetName)
Infinity_DoFile("BfBotMp")   -- Multiplayer support / ownership probe (depends on _GetName)
Infinity_DoFile("BfBotPer")  -- Persistence (depends on Scan, Class)
Infinity_DoFile("BfBotInn")  -- Innate abilities (depends on Persist, Exec)
BfBot.Persist.Init()         -- Register marshal handlers for save/load
BfBot.Innate._EnsureSPLFiles()  -- Write innate SPL files to override (if missing)
BfBot.Innate.Init()          -- Register sprite-loaded listener for innate grants

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
