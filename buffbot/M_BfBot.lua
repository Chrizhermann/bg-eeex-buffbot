-- M_BfBot.lua — BuffBot Bootstrap
-- Engine auto-loads all M_*.lua from override alphabetically.
-- EEex's M___EEex.lua loads first, then M_BfBot.lua.
if not EEex_Active then return end

Infinity_DoFile("BfBotCor")  -- Namespace, logging, shared utilities, caches
Infinity_DoFile("BfBotCls")  -- Classifier (standalone, uses BfBot._Print/_Log only)
Infinity_DoFile("BfBotScn")  -- Scanner (depends on Class)
Infinity_DoFile("BfBotExe")  -- Execution engine (depends on Scan, _GetName)
Infinity_DoFile("BfBotPer")  -- Persistence (depends on Scan, Class)
Infinity_DoFile("BfBotInn")  -- Innate abilities (depends on Persist, Exec)
BfBot.Persist.Init()         -- Register marshal handlers for save/load
BfBot.Innate._EnsureSPLFiles()  -- Write innate SPL files to override (if missing)
Infinity_DoFile("BfBotUI")   -- UI logic (state, callbacks, .menu integration)
Infinity_DoFile("BfBotTst")  -- Test suite (remove for release)

-- Register for after-UI-load — menus are ready, safe to load .menu and inject
EEex_Menu_AddAfterMainFileLoadedListener(function()
    BfBot.UI._OnMenusLoaded()
end)
