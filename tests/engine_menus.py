"""The engine's menu list, as the fast-forward guard reads it.

`BfBot.Fast.Safe` learns which menus hide the world by walking
`EngineGlobals.menus` and reading each entry's `modal` flag, instead of naming
menus in the source (issue #104). Every Lua fixture that starts a fast-forward
run therefore needs that list, and it has to look like the real one or the
tests prove nothing -- so these names and flags are what a lab walk read off
BG2:EE 2.7.3.0: `modal` is a wrapper object on a menu that declares it and nil
on one that does not, the shop screens are `STORE_*` rather than a bare
`STORE`, and `EEex_Options` is there because a mod's modal shows up in the
same list.

    from engine_menus import ENGINE_MENUS

    runtime.execute(ENGINE_MENUS)          # defines uiMenus + engineMenus()
    runtime.execute("EngineGlobals = { numMenus = #uiMenus, "
                    "menus = engineMenus(), g_pBaldurChitin = ... }")

`uiMenus` stays addressable so a test can add or remove a menu and watch the
guard follow the running UI rather than a list it was born with.
"""

ENGINE_MENUS = """
uiMenus = {
    { name = 'WORLD_ACTIONBAR' },
    { name = 'WORLD_MESSAGES' },
    { name = 'LEFT_SIDEBAR' },
    { name = 'RIGHT_SIDEBAR' },
    { name = 'WORLD_LEVEL_UP_BUTTONS' },
    { name = 'BUFFBOT_ACTIONBAR' },
    { name = 'WORLD_DIALOG' },
    { name = 'WORLD_DIALOG_CONFIRM' },
    { name = 'STORE_BUYSELL' },
    { name = 'STORE_CHOOSER' },
    { name = 'LOAD' },
    { name = 'SAVE' },
    { name = 'INVENTORY' },
    { name = 'JOURNAL' },
    { name = 'POPUP_TWOBUTTON', modal = {} },
    { name = 'POPUP_THREEBUTTON', modal = {} },
    { name = 'POPUP_FOURBUTTON', modal = {} },
    { name = 'POPUP_INFO', modal = {} },
    { name = 'CHARACTER', modal = {} },
    { name = 'OPTIONS_GAMEPLAY', modal = {} },
    { name = 'CHARGEN_HIGH_LEVEL_ABILITIES', modal = {} },
    { name = 'WORLD_DEATH', modal = {} },
    { name = 'EEex_Options', modal = {} },
}

--- The engine's menu array, wrapped the way the bindings present it: indexed
--- from 0 through getReference, with each name a string object, not a string.
function engineMenus()
    return {
        getReference = function(self, index)
            local entry = uiMenus[index + 1]
            if entry == nil then return nil end
            return {
                modal = entry.modal,
                name = { get = function() return entry.name end },
            }
        end,
    }
end
"""

# The names the guard must refuse on, given the list above: every modal menu
# plus the non-modal screens matched by prefix. Kept here so a test can state
# the expected set without restating the rule the guard implements.
BLOCKING = (
    "WORLD_DIALOG", "WORLD_DIALOG_CONFIRM", "STORE_BUYSELL", "STORE_CHOOSER",
    "LOAD", "SAVE", "POPUP_TWOBUTTON", "POPUP_THREEBUTTON",
    "POPUP_FOURBUTTON", "POPUP_INFO", "CHARACTER", "OPTIONS_GAMEPLAY",
    "CHARGEN_HIGH_LEVEL_ABILITIES", "WORLD_DEATH", "EEex_Options",
)

# The menus a lab read off the stack on a quiet world screen. These are up
# whenever a run could start, so a guard that refused on any of them would
# never let fast-forward run at all -- BuffBot's own actionbar menu included.
ALWAYS_ON_STACK = (
    "WORLD_ACTIONBAR", "WORLD_MESSAGES", "LEFT_SIDEBAR", "RIGHT_SIDEBAR",
    "WORLD_LEVEL_UP_BUTTONS", "BUFFBOT_ACTIONBAR",
)
