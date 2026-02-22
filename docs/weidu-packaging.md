# WeiDU Packaging & Installation — BuffBot Reference

> Installation architecture for BuffBot. Covers the `.tp2` installer structure,
> file installation patterns, EEex dependency management, cross-game support,
> and compatibility. Primary reference: Bubb's Spell Menu Extended (BSME) v5.1 —
> same tech stack and EEex author, and the closest existing example of an
> EEex-dependent Lua + .menu mod.
>
> Confidence levels: **[SRC]** = verified from BSME/EEex source or WeiDU docs,
> **[DOC]** = official documentation or forums,
> **[INF]** = inferred from source patterns, **[UNC]** = uncertain / needs runtime testing.
>
> Key references:
> - BSME: https://github.com/Bubb13/Bubbs-Spell-Menu-Extended (v5-EEex branch)
> - EEex: https://github.com/Bubb13/EEex
> - WeiDU docs: https://weidu.org/WeiDU/README-WeiDU.html
> - WeiDU course: https://gibberlings3.github.io/Documentation/readmes/weiducourse/

---

## 1. File Map & Loading Chain

### 1.1 File Inventory **[SRC]**

BuffBot ships these files, mirroring BSME's structure:

| BuffBot File | BSME Equivalent | Role | Install Method |
|---|---|---|---|
| `M_BfBot.lua` | `M_B3Spel.lua` | Bootstrap — engine auto-loads via M_ prefix | `COPY` |
| `BfBotEx.lua` | `B3SpelEx.lua` | EEex hook registration, initialization | `COPY` |
| `BfBotWei.lua` | `B3SplWei.lua` | WeiDU-generated constants (translated strings, dimensions) | `COPY` + `EVALUATE_BUFFER` |
| `BuffBot.menu` | `B3Spell.menu` | UI definitions (.menu DSL) | `COPY` + `EVALUATE_BUFFER` |
| `BFBTN.BAM` etc. | `B3SLOT*.BAM` | UI graphics (game-specific variants) | `COPY` (from game-specific dir) |

**File naming constraint**: The Infinity Engine uses 8-character resource references
(resrefs). All filenames used with `Infinity_DoFile()` and `EEex_Menu_LoadFile()` must
be ≤8 characters (excluding extension). BSME follows this strictly: `M_B3Spel` (8),
`B3SpelEx` (8), `B3SplWei` (8), `B3Spell` (7). BuffBot's names are chosen to comply:
`M_BfBot` (7), `BfBotEx` (7), `BfBotWei` (8), `BuffBot` (7).

### 1.2 Loading Chain **[SRC]** **[INF]**

The Enhanced Edition engine (v2.2+) auto-loads all `M_*.lua` files from the override
folder at startup. This is the mechanism that bootstraps both EEex and any mod that
depends on it — no modification of existing files required.

```
Engine startup
  └─ Loads BGEE.LUA (engine-bundled UI/Lua scripts)
  └─ Loads M_*.lua files from override (alphabetical order)
       └─ M___EEex.lua loads first (triple underscores sort before letters)
            └─ EEex patches applied, EEex_Active = true
       └─ M_BfBot.lua loads next ('B' sorts after '_')
            └─ Guards: if not EEex_Active then return end
            └─ Infinity_DoFile("BfBotWei")   → loads WeiDU-generated constants
            └─ Infinity_DoFile("BfBotEx")    → loads EEex hook registration
                 └─ Registers EEex_Menu_AddMainFileLoadedListener(...)
  └─ Engine loads UI.MENU
       └─ EEex fires MainFileLoaded listeners
            └─ BuffBot's listener runs:
                 1. EEex_Menu_LoadFile("BuffBot")  → loads BuffBot.menu
                 2. EEex_Menu_InjectTemplate(...)  → adds button to actionbar
                 3. EEex_Key_AddPressedListener(...)  → registers hotkey
```

**Why M_ prefix matters**: EEex itself uses `M___EEex.lua` — the triple underscores
ensure it loads before any other M_-prefixed mod (underscores sort before letters in
ASCII). BuffBot's `M_BfBot.lua` naturally sorts after, so EEex is guaranteed to be
initialized first.

**[UNC]** The exact M_ loading mechanism (filesystem scan vs. resource system) needs
runtime verification. If resource-based, the 8-char resref limit applies to the M_
filename itself. If filesystem-based, longer names would work — but we follow the
8-char convention to be safe.

### 1.3 Corrections to Earlier Analysis **[SRC]**

The loading mechanism was previously marked `[UNC]` in
[ui-menu-patterns.md §3.5](ui-menu-patterns.md) ("the exact mechanism for getting
`BuffBot_Init.lua` loaded at startup is uncertain"). This is now resolved:

- **Not** loaded via EEex's module/component system (those are built-in EEex modules
  like B3EffMen, B3Hotkey, etc.)
- **Loaded via** the engine's M_ prefix auto-loading + `Infinity_DoFile` calls
- BSME's `M_B3Spel.lua` calls `Infinity_DoFile("B3SpelEx")` to load its hook code —
  BuffBot follows the same pattern

---

## 2. Installing Each File Type

### 2.1 Lua Files (No Substitution) **[SRC]**

Pure Lua files that don't need install-time customization are copied verbatim:

```
COPY ~%MOD_FOLDER%/copy/M_BfBot.lua~  ~override/M_BfBot.lua~
COPY ~%MOD_FOLDER%/copy/BfBotEx.lua~   ~override/BfBotEx.lua~
```

These files contain runtime logic only — no `%variable%` placeholders.

### 2.2 Lua Files (With EVALUATE_BUFFER) **[SRC]**

`BfBotWei.lua` is a template file with `%variable%` placeholders that WeiDU fills at
install time. This is the bridge between WeiDU's install-time detection (game type,
UI framework, translations) and Lua's runtime code.

**Template file** (`buffbot/copy/BfBotWei.lua`):
```lua
-- BfBotWei.lua — WeiDU-generated constants (DO NOT EDIT — generated at install time)

BfBot_SlotBam         = "%BfBot_SlotBam%"
BfBot_ButtonBam       = "%BfBot_ButtonBam%"
BfBot_SidebarWidth    = %BfBot_SidebarWidth%

-- Translated strings
BfBot_Tooltip_Open    = "%BfBot_Tooltip_Open%"
BfBot_Tooltip_CastAll = "%BfBot_Tooltip_CastAll%"
BfBot_Label_Presets   = "%BfBot_Label_Presets%"
```

**In the .tp2**, before copying:
```
// Set translated strings from .tra file
SPRINT ~BfBot_Tooltip_Open~    @10
SPRINT ~BfBot_Tooltip_CastAll~ @11
SPRINT ~BfBot_Label_Presets~   @12

// Set game-specific values (from ACTION_IF chain, see §4)
// BfBot_SlotBam, BfBot_ButtonBam, BfBot_SidebarWidth already set

COPY ~%MOD_FOLDER%/copy/BfBotWei.lua~ ~override/BfBotWei.lua~ EVALUATE_BUFFER
```

**After install**, the file in override/ contains resolved values:
```lua
BfBot_SlotBam         = "BFSLOT"
BfBot_ButtonBam       = "BFBTN"
BfBot_SidebarWidth    = 48

BfBot_Tooltip_Open    = "Open BuffBot"
BfBot_Tooltip_CastAll = "Cast All Buffs"
BfBot_Label_Presets   = "Presets"
```

**Escaping**: If a translated string in the `.tra` file contains a literal `%`, use
`%%` to escape it. WeiDU's `EVALUATE_BUFFER` replaces `%%` with `%` after resolving
variables. **[DOC]**

### 2.3 Menu Files **[SRC]**

`BuffBot.menu` defines the UI layout in the engine's `.menu` DSL. It is copied to
override/ with `EVALUATE_BUFFER` for translated tooltip strings embedded in the menu:

```
COPY ~%MOD_FOLDER%/copy/BuffBot.menu~ ~override/BuffBot.menu~ EVALUATE_BUFFER
```

**Critical**: BuffBot does **not** patch or modify `UI.MENU`. The `.menu` file is loaded
at runtime via EEex's `EEex_Menu_LoadFile("BuffBot")` call (from `BfBotEx.lua`). This
avoids:
- Fragile text-based patching of the engine's main UI file
- Conflicts with other UI mods (Dragonspear UI++, LeUI, BSME)
- Installation order sensitivity

This approach is only possible because EEex provides `EEex_Menu_LoadFile` — without
EEex, mods must patch UI.MENU directly via `COPY_EXISTING` + `REPLACE_TEXTUALLY`.

### 2.4 BAM Files (UI Graphics) **[INF]**

Game-specific BAM variants live in separate source directories. The `.tp2`'s ACTION_IF
chain (§4) sets `%bam_folder%` to the correct directory, then:

```
COPY ~%bam_folder%~ ~override~
```

This copies all BAM files from the selected directory into override/.

At minimum, BuffBot needs:
- `BFBTN.BAM` — actionbar button icon (the button that opens the BuffBot panel)
- Additional BAMs for the config panel UI (checkboxes, slot backgrounds, etc.) as
  needed during implementation

---

## 3. EEex Dependency

### 3.1 Install-Time Check **[SRC]** **[DOC]**

The `.tp2` must verify EEex is installed before proceeding. Two forms exist:

**Robust form (recommended for BuffBot)**:
```
REQUIRE_PREDICATE
  (MOD_IS_INSTALLED ~EEex.tp2~ (ID_OF_LABEL ~EEex.tp2~ ~B3-EEex-Main~))
  @1
```
Uses `ID_OF_LABEL` to look up EEex's main component by its label string. Survives
EEex component renumbering in future versions.

**Simple form (used by BSME)**:
```
REQUIRE_PREDICATE (MOD_IS_INSTALLED ~EEex.tp2~ ~0~) @1
```
References component number directly. BSME uses this because Bubb is the author of
both BSME and EEex, so component numbers are stable. BuffBot should prefer the
`ID_OF_LABEL` form since we don't control EEex.

**Error message** (`@1` in `setup.tra`):
```
@1 = ~BuffBot requires EEex to be installed. Please install EEex first: https://github.com/Bubb13/EEex~
```

### 3.2 Runtime Guard **[INF]**

Even with the install-time check, the game must be launched via `InfinityLoader.exe`
for EEex to be active. BuffBot's bootstrap file should guard against running without
EEex:

```lua
-- M_BfBot.lua (top of file)
if not EEex_Active then
    return  -- silently skip if EEex isn't active
end
```

**[UNC]** Whether `EEex_Active` is guaranteed to be set before `M_BfBot.lua` loads.
The triple-underscore naming of `M___EEex.lua` should ensure it loads first
(alphabetical order), but this needs runtime verification.

### 3.3 Version Requirements **[UNC]**

BuffBot requires EEex features introduced in specific versions:
- `EEex_Sprite_AddMarshalHandlers` + `EEex_GetUDAux` — requires EEex v0.10.3+
  (for config persistence in save games)
- `EEex_Menu_InjectTemplate` — version unknown, but present in current EEex

There is **no install-time mechanism** to check the EEex version. Options:
1. Check for version-specific files via `FILE_EXISTS_IN_GAME` (fragile — files may
   change between versions)
2. Document the minimum EEex version in the README and rely on users
3. Check at runtime in Lua and show a warning if APIs are missing

For now, document the requirement in the README and add a runtime check:
```lua
-- In BfBotEx.lua initialization
if not EEex_Sprite_AddMarshalHandlers then
    print("BuffBot: EEex v0.10.3+ required for save game persistence.")
    -- Fall back to INI-based persistence or disable persistence
end
```

---

## 4. Cross-Game Support (BG:EE / BG2:EE / EET)

### 4.1 Game Detection **[DOC]**

```
REQUIRE_PREDICATE (GAME_IS ~bgee bg2ee eet~) @0
```

BuffBot targets three game configurations:

| Token | Game | Notes |
|-------|------|-------|
| `bgee` | Baldur's Gate: Enhanced Edition | Includes SoD if installed |
| `bg2ee` | Baldur's Gate II: Enhanced Edition | |
| `eet` | Enhanced Edition Trilogy | BG1 + SoD + BG2 merged; uses BG2:EE engine |

BuffBot does not target IWD:EE (unlike BSME, which does). The spell systems differ
enough that IWD:EE support would require separate testing and configuration.

### 4.2 What Differs Between Games **[INF]**

| Aspect | BG:EE | BG2:EE | EET |
|--------|-------|--------|-----|
| Spell level cap | 5 | 9 + HLAs | 9 + HLAs |
| Default UI | Vanilla BGEE | Vanilla BG2EE | Varies (depends on UI mod) |
| BAM art style | BG1 aesthetic | BG2 aesthetic | BG2 aesthetic |
| SoD content | Maybe present | No | Integrated |

At the `.tp2` level, the primary differences are:
- **BAM variants**: Different icon art styles per game
- **UI dimensions**: Sidebar width, actionbar position vary by UI framework
- **[INF]** Potentially different default presets (BG1 has fewer buff spells)

Spell-level differences are handled at runtime (dynamic spellbook scanning), not at
install time.

### 4.3 UI Framework Detection **[SRC]** **[INF]**

The `.tp2` detects the active UI framework to select correct BAMs and dimensions.
BSME uses a cascading ACTION_IF chain for this:

```
// Detect UI framework and set game-specific variables
ACTION_IF (MOD_IS_INSTALLED ~infinityuipp.tp2~ 0) THEN BEGIN
    SPRINT ~bam_folder~ ~%MOD_FOLDER%/copy/bam-infinityui~
    SPRINT ~BfBot_SidebarWidth~ ~64~
    SPRINT ~BfBot_SlotBam~ ~BFSLOTI~
    SPRINT ~BfBot_ButtonBam~ ~BFBTNI~
END ELSE ACTION_IF (MOD_IS_INSTALLED ~dragonspear_ui++.tp2~ 0) THEN BEGIN
    SPRINT ~bam_folder~ ~%MOD_FOLDER%/copy/bam-dsui~
    SPRINT ~BfBot_SidebarWidth~ ~54~
    SPRINT ~BfBot_SlotBam~ ~BFSLOTD~
    SPRINT ~BfBot_ButtonBam~ ~BFBTND~
END ELSE ACTION_IF (GAME_IS ~bg2ee eet~) THEN BEGIN
    SPRINT ~bam_folder~ ~%MOD_FOLDER%/copy/bam-bg2ee~
    SPRINT ~BfBot_SidebarWidth~ ~48~
    SPRINT ~BfBot_SlotBam~ ~BFSLOT2~
    SPRINT ~BfBot_ButtonBam~ ~BFBTN2~
END ELSE BEGIN
    // Vanilla BG:EE
    SPRINT ~bam_folder~ ~%MOD_FOLDER%/copy/bam-bgee~
    SPRINT ~BfBot_SidebarWidth~ ~48~
    SPRINT ~BfBot_SlotBam~ ~BFSLOT~
    SPRINT ~BfBot_ButtonBam~ ~BFBTN~
END
```

**[UNC]** Exact dimension values (`BfBot_SidebarWidth` etc.) are placeholders. These
need to be measured from each UI framework during implementation. LeUI variants
(`leui`, `leui-bg1ee`, `leui-sod`) may also need detection — exact `.tp2` names and
component numbers need verification.

### 4.4 SoD Detection **[DOC]**

WeiDU's `GAME_IS ~bgee~` matches both base BG:EE and SoD. If SoD-specific handling is
ever needed:

```
ACTION_IF (GAME_INCLUDES ~sod~) THEN BEGIN
    // SoD-specific code
END
```

BuffBot likely does not need SoD-specific install-time code — the same BG:EE BAMs and
configuration should work.

---

## 5. Compatibility & Install Order

### 5.1 Install Order **[INF]**

| Order | Mod | Reason |
|-------|-----|--------|
| 1 | EEex | Hard dependency — REQUIRE_PREDICATE enforces this |
| 2 | UI framework mods (Dragonspear UI++, LeUI, Infinity UI++) | So BuffBot's ACTION_IF chain can detect them |
| 3 | **BuffBot** | |
| 4 | BSME (if installed) | No conflict — both use independent injection points |

### 5.2 Mod Manager Metadata **[DOC]**

Create `buffbot/buffbot.ini` for Project Infinity and other mod managers:

```ini
[Metadata]
Name = BuffBot
Author = [author]
Description = In-game configurable buff automation for BG:EE and BG2:EE. Requires EEex.
Readme = buffbot/README.md
Label_Type = GloballyUnique
Install_After = dragonspear_ui++ EEex EET leui leui-bg1ee leui-sod infinityuipp
Install_Before =
```

`Install_After` declares soft ordering — mod managers will suggest this order but don't
enforce it. The hard enforcement comes from `REQUIRE_PREDICATE` in the `.tp2`.

### 5.3 Specific Mod Interactions **[INF]**

**EEex** — Hard dependency. No file conflicts (BuffBot doesn't modify EEex files).

**BSME** — No file conflicts. Both are pure Lua + .menu mods that use independent EEex
hooks. BuffBot uses `EEex_Menu_InjectTemplate` for its actionbar button (not actionbar
interception like BSME), so both can coexist. **[UNC]** Spatial overlap of injected
templates on the actionbar needs runtime testing if both are installed.

**SCS (Sword Coast Stratagems)** — No install-time conflict. SCS modifies AI scripts
(`.bcs`) and adds `.2da` files; BuffBot doesn't touch these file types. Runtime
interaction (both issuing cast commands to the same character) is a design concern, not
a packaging concern.

**Spell Revisions / other spell mods** — No install-time interaction. BuffBot reads
spells dynamically at runtime, so modified or added spells are picked up automatically.

**UI mods (Dragonspear UI++, LeUI, Infinity UI++)** — No file conflicts (BuffBot
doesn't patch UI.MENU). The ACTION_IF chain detects installed UI mods and adjusts
BAMs/dimensions accordingly. BuffBot should install AFTER UI mods so the detection
works.

---

## 6. Starter tp2 File

### 6.1 setup-buffbot.tp2 **[SRC]**

```
// ==========================================================================
// BuffBot — In-Game Configurable Buff Automation
// ==========================================================================
// Requires: EEex (https://github.com/Bubb13/EEex)
// Games:    BG:EE, BG2:EE, EET

BACKUP ~weidu_external/backup/buffbot~
AUTHOR ~[author]~
VERSION ~v0.1.0~

AUTO_EVAL_STRINGS

// Auto-load .tra files matching the selected language
AUTO_TRA ~%MOD_FOLDER%/language/%s~

// --------------------------------------------------------------------------
// Language definitions
// --------------------------------------------------------------------------
LANGUAGE
  ~English~
  ~english~
  ~%MOD_FOLDER%/language/english/setup.tra~

// --------------------------------------------------------------------------
// Component 0: BuffBot Core
// --------------------------------------------------------------------------
BEGIN @0
DESIGNATED 0
LABEL ~BuffBot-Main~

// --- Prerequisites ---

REQUIRE_PREDICATE (GAME_IS ~bgee bg2ee eet~) @1

REQUIRE_PREDICATE
  (MOD_IS_INSTALLED ~EEex.tp2~ (ID_OF_LABEL ~EEex.tp2~ ~B3-EEex-Main~))
  @2

// --- Detect UI framework and set game-specific variables ---

ACTION_IF (MOD_IS_INSTALLED ~infinityuipp.tp2~ 0) THEN BEGIN
    SPRINT ~bam_folder~ ~%MOD_FOLDER%/copy/bam-infinityui~
    SPRINT ~BfBot_SlotBam~ ~BFSLOTI~
    SPRINT ~BfBot_ButtonBam~ ~BFBTNI~
    SPRINT ~BfBot_SidebarWidth~ ~64~
END ELSE ACTION_IF (MOD_IS_INSTALLED ~dragonspear_ui++.tp2~ 0) THEN BEGIN
    SPRINT ~bam_folder~ ~%MOD_FOLDER%/copy/bam-dsui~
    SPRINT ~BfBot_SlotBam~ ~BFSLOTD~
    SPRINT ~BfBot_ButtonBam~ ~BFBTND~
    SPRINT ~BfBot_SidebarWidth~ ~54~
END ELSE ACTION_IF (GAME_IS ~bg2ee eet~) THEN BEGIN
    SPRINT ~bam_folder~ ~%MOD_FOLDER%/copy/bam-bg2ee~
    SPRINT ~BfBot_SlotBam~ ~BFSLOT2~
    SPRINT ~BfBot_ButtonBam~ ~BFBTN2~
    SPRINT ~BfBot_SidebarWidth~ ~48~
END ELSE BEGIN
    // Vanilla BG:EE
    SPRINT ~bam_folder~ ~%MOD_FOLDER%/copy/bam-bgee~
    SPRINT ~BfBot_SlotBam~ ~BFSLOT~
    SPRINT ~BfBot_ButtonBam~ ~BFBTN~
    SPRINT ~BfBot_SidebarWidth~ ~48~
END

// --- Set translated strings for EVALUATE_BUFFER ---

SPRINT ~BfBot_Tooltip_Open~    @10
SPRINT ~BfBot_Tooltip_CastAll~ @11
SPRINT ~BfBot_Label_Presets~   @12
SPRINT ~BfBot_Label_Spells~    @13
SPRINT ~BfBot_Label_Targets~   @14

// --- Install files ---

// Lua files (no substitution needed)
COPY ~%MOD_FOLDER%/copy/M_BfBot.lua~ ~override/M_BfBot.lua~
COPY ~%MOD_FOLDER%/copy/BfBotEx.lua~ ~override/BfBotEx.lua~

// Lua constants + menu file (with variable substitution)
COPY ~%MOD_FOLDER%/copy/BfBotWei.lua~ ~override/BfBotWei.lua~ EVALUATE_BUFFER
COPY ~%MOD_FOLDER%/copy/BuffBot.menu~ ~override/BuffBot.menu~ EVALUATE_BUFFER

// Game-specific BAM files
COPY ~%bam_folder%~ ~override~
```

### 6.2 language/english/setup.tra

```
// Component names
@0  = ~BuffBot: In-Game Buff Automation~

// Error messages
@1  = ~BuffBot requires Baldur's Gate: Enhanced Edition (BG:EE, BG2:EE, or EET).~
@2  = ~BuffBot requires EEex to be installed. Please install EEex first: https://github.com/Bubb13/EEex~

// UI strings (substituted into BfBotWei.lua and BuffBot.menu via EVALUATE_BUFFER)
@10 = ~Open BuffBot~
@11 = ~Cast All Buffs~
@12 = ~Presets~
@13 = ~Spells~
@14 = ~Targets~
```

### 6.3 BfBotWei.lua Template

This file lives at `buffbot/copy/BfBotWei.lua` in the mod source. WeiDU replaces
`%variables%` at install time via `EVALUATE_BUFFER`:

```lua
-- BfBotWei.lua — WeiDU-generated constants
-- DO NOT EDIT — this file is generated at install time by setup-buffbot.tp2

-- Game-specific UI constants
BfBot_SlotBam         = "%BfBot_SlotBam%"
BfBot_ButtonBam       = "%BfBot_ButtonBam%"
BfBot_SidebarWidth    = %BfBot_SidebarWidth%

-- Translated strings
BfBot_Tooltip_Open    = "%BfBot_Tooltip_Open%"
BfBot_Tooltip_CastAll = "%BfBot_Tooltip_CastAll%"
BfBot_Label_Presets   = "%BfBot_Label_Presets%"
BfBot_Label_Spells    = "%BfBot_Label_Spells%"
BfBot_Label_Targets   = "%BfBot_Label_Targets%"
```

### 6.4 buffbot.ini (Mod Manager Metadata)

```ini
[Metadata]
Name = BuffBot
Author = [author]
Description = In-game configurable buff automation for BG:EE and BG2:EE. Requires EEex.
Readme = buffbot/README.md
Label_Type = GloballyUnique
Install_After = dragonspear_ui++ EEex EET leui leui-bg1ee leui-sod infinityuipp
Install_Before =
```

---

## 7. Mod Source Directory Structure

```
buffbot/
├── setup-buffbot.tp2                   -- WeiDU installer (at repo root or mod folder)
├── buffbot.ini                         -- mod manager metadata
├── language/
│   └── english/
│       └── setup.tra                   -- English strings
├── copy/
│   ├── M_BfBot.lua                     -- bootstrap (engine auto-loads via M_ prefix)
│   ├── BfBotEx.lua                     -- EEex hooks and initialization
│   ├── BfBotWei.lua                    -- WeiDU constants template (EVALUATE_BUFFER)
│   ├── BuffBot.menu                    -- UI definitions (EVALUATE_BUFFER)
│   ├── bam-bgee/                       -- BG:EE vanilla BAMs
│   │   └── BFBTN.BAM
│   ├── bam-bg2ee/                      -- BG2:EE / EET vanilla BAMs
│   │   └── BFBTN.BAM
│   ├── bam-dsui/                       -- Dragonspear UI++ BAMs
│   │   └── BFBTN.BAM
│   └── bam-infinityui/                 -- Infinity UI++ BAMs
│       └── BFBTN.BAM
```

**Mapping to repo layout** (per CLAUDE.md):
- `buffbot/` = mod distribution folder (what gets zipped for release)
- `src/` = development source (may mirror `buffbot/copy/` or have a build step)
- `docs/` = analysis documents (not shipped with the mod)
- `tools/` = helper scripts (not shipped with the mod)

---

## 8. WeiDU Quick Reference

Key WeiDU constructs used in the starter tp2, for reference:

| Construct | Purpose | Example |
|-----------|---------|---------|
| `BACKUP` | Where WeiDU stores uninstall data | `BACKUP ~weidu_external/backup/buffbot~` |
| `AUTHOR` | Displayed if installation fails | `AUTHOR ~name~` |
| `VERSION` | Mod version string | `VERSION ~v0.1.0~` |
| `AUTO_EVAL_STRINGS` | Enables `%variable%` interpolation in string arguments | Must include |
| `AUTO_TRA` | Auto-loads `.tra` files for the selected language | `AUTO_TRA ~%MOD_FOLDER%/language/%s~` |
| `LANGUAGE` | Declares a supported language | Display name, folder ID, .tra path |
| `BEGIN` | Starts a component | `BEGIN @0` (name from .tra) |
| `DESIGNATED` | Explicit component number | `DESIGNATED 0` |
| `LABEL` | Human-readable component ID | `LABEL ~BuffBot-Main~` |
| `REQUIRE_PREDICATE` | Skip component if condition is false | Game check, dependency check |
| `GAME_IS` | Test which game is running | `GAME_IS ~bgee bg2ee eet~` |
| `MOD_IS_INSTALLED` | Test if another mod's component is installed | `MOD_IS_INSTALLED ~EEex.tp2~ ~0~` |
| `ID_OF_LABEL` | Look up component number by label | `ID_OF_LABEL ~EEex.tp2~ ~B3-EEex-Main~` |
| `ACTION_IF` / `ELSE` | Conditional logic at install time | UI framework detection |
| `SPRINT` | Set a string variable | `SPRINT ~var~ ~value~` |
| `COPY` | Copy file to destination | `COPY ~src~ ~override~` |
| `EVALUATE_BUFFER` | Replace `%var%` placeholders in copied file | `COPY ~src~ ~dst~ EVALUATE_BUFFER` |
| `COPY_EXISTING` | Patch an existing game file | `COPY_EXISTING ~file~ ~override~` |
| `REPLACE_TEXTUALLY` | Text search-and-replace in a COPY_EXISTING | Pattern matching |
| `BUT_ONLY` | Only write the file if changes were made | Avoids unnecessary backups |
| `APPEND` | Add text to end of existing file | `APPEND ~file~ ~text~` |
| `EXTEND_TOP` / `BOTTOM` | Inject code into a `.bcs` script | `EXTEND_TOP ~script.bcs~ ~patch.baf~` |

---

## 9. Open Questions

Items marked **[UNC]** throughout this document that need runtime verification:

1. **M_ load order**: Does `M_BfBot.lua` reliably load after `M___EEex.lua`? The
   alphabetical sorting theory (underscores before letters) needs runtime confirmation.

2. **M_ filename length**: Does the IE 8-character resref limit apply to M_ auto-loaded
   files, or is the auto-loading filesystem-based (no limit)?

3. **EEex version detection**: No known install-time mechanism. If BuffBot needs to
   hard-require EEex v0.10.3+, a `FILE_EXISTS_IN_GAME` check on a version-specific
   file might work but is fragile.

4. **EVALUATE_BUFFER + .menu DSL**: WeiDU's `%var%` substitution interacts with the
   `.menu` format's string quoting. Translated strings containing `%` must use `%%`.
   Edge cases with special characters need testing.

5. **LeUI detection**: Exact `.tp2` filenames and component numbers for LeUI variants
   (`leui`, `leui-bg1ee`, `leui-sod`) need verification.

6. **BAM dimensions**: Placeholder values for `BfBot_SidebarWidth` and other
   dimension constants need to be measured from each UI framework.

7. **`EEex_Active` timing**: Is `EEex_Active` guaranteed set before M_BfBot.lua loads?
   The `M___EEex.lua` sort order suggests yes, but needs confirmation.
