-- M_BfBot.lua — BuffBot Bootstrap
-- Engine auto-loads all M_*.lua from override alphabetically.
-- EEex's M___EEex.lua loads first, then M_BfBot.lua.
if not EEex_Active then return end

Infinity_DoFile("BfBotCor")  -- Core logic (scanner, classifier, executor, persistence)
BfBot.Persist.Init()         -- Register marshal handlers for save/load
Infinity_DoFile("BfBotUI")  -- UI logic (state, callbacks, .menu integration)
Infinity_DoFile("BfBotTst")  -- Test suite (remove for release)

-- Register for after-UI-load — menus are ready, safe to load .menu and inject
EEex_Menu_AddAfterMainFileLoadedListener(function()
    BfBot.UI._OnMenusLoaded()
end)
