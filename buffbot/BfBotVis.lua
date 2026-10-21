-- Recipient panel presentation. Planning, reservations and execution remain in
-- PartyUI/Plan. Never writes UI++ globals, files, fonts or settings.
BfBot.Visual = {}
local V,U,P = BfBot.Visual,BfBot.PartyUI,BfBot.Plan
local D=BfBot.VisualData
bbVisualSources,bbVisualSourceSelection={},0
local skins={[0]='sod',[1]='iwd',[2]='bg1',[3]='bg2'}
local continuationLow,continuationHigh=string.char(128),string.char(191)
local utf8Glyph='[^'..continuationLow..'-'..continuationHigh..']['..continuationLow..'-'..continuationHigh..']*'
function V.SkinIndex()
    -- Menu parsing runs before a world/party exists. Never resolve sprites here.
    local selected=V.skinOverride
    if skins[selected] then return selected end
    return skins[RgUISkin] and RgUISkin or 2
end
function V.Skin() return skins[V.SkinIndex()] end
function V.RGB(role)
    local hex=D.theme.skins[V.Skin()][role] or '#ff7a66'
    return {tonumber(hex:sub(2,3),16),tonumber(hex:sub(4,5),16),tonumber(hex:sub(6,7),16)}
end
function V.Glyph(name) return D.glyphs[name] or 0 end
function V.Available()
    if V.available~=nil then return V.available end
    V.available=false
    if not EEex_Resource_Fetch then return false end
    for _,ref in ipairs({'BFBTAB','BFBPLAT','BFBCAST','BFBCLOSE','BFBACT','BFBSEAR','BFBWELL','BFBSLOT','BFBCORN','BFBSCRL','BFBCHK0','BFBCHK1','BFBCHK2','BFBCHK3','BFBRAH','BFBRAV'}) do
        if not EEex_Resource_Fetch(ref,'BAM') then return false end
    end
    V.available=true;return true
end
function V.InstallStyles()
    if not styles or not fontcolors then return end
    V.palette=V.palette or {}
    local textFont=EEex_Resource_Fetch and EEex_Resource_Fetch('RGFONT','TTF') and 'RGFONT' or 'NORMAL'
    local displayFont=EEex_Resource_Fetch and EEex_Resource_Fetch('RGTRAJ','TTF') and 'RGTRAJ' or 'STONESML'
    local defs={text={'text.primary','RGFONT',14},textwide={'text.primary','RGFONT',15},chipwide={'text.primary','RGFONT',14},muted={'text.muted','RGFONT',12},small={'text.primary','RGFONT',12},
        header={'text.groupLabel','RGTRAJ',12},tab={'text.tabActive','RGTRAJ',15},button={'text.button','RGTRAJ',13},
        display={'text.title','RGTRAJ',14},title={'text.title','RGTRAJ',15},error={'text.primary','RGFONT',12}}
    for name,def in pairs(defs) do
        local key=V.palette[name]
        if not key then
            for n=33,126 do if fontcolors[string.char(n)]==nil then key=string.char(n);break end end
            assert(key,'BuffBot: font palette exhausted');V.palette[name]=key
        end
        -- The engine's font palette is AABBGGRR (native probe verified).
        local c=V.RGB(def[1]);fontcolors[key]=string.format('FF%02X%02X%02X',c[3],c[2],c[1])
        styles['bvr_'..name]={font=def[2]=='RGFONT' and textFont or displayFont,color=key,point=def[3],useFontZoom=1,valign='center',halign='left'}
    end
end
function V.FrameKey() return (V.wide and 'wide' or 'compact')..'-'..(U.IsDashboard() and 'buffs' or 'list')..'-'..V.Skin() end
function V.Frame(i) local r=D.frames[V.FrameKey()][i];return r and r.res or '' end
function V.FrameVisible(i) return D.frames[V.FrameKey()][i]~=nil end
function V.Layout()
    V.skinOverride=U.state and U.state.skin
    local sw,sh=Infinity_GetScreenSize();U.screenW,U.screenH=sw,sh
    -- A 1000px-height cutoff clips the fixed 1080px frame in a maximized
    -- 1080p window. Use the existing compact canvas until wide fits in full.
    V.wide=sw>=1920 and sh>=1080;V.w,V.h=V.wide and 1920 or 1280,V.wide and 1080 or 720
    V.x,V.y=math.floor((sw-V.w)/2),math.floor((sh-V.h)/2)
    V.InstallStyles()
    local function area(name,x,y,w,h)
        local ax,ay,aw,ah=V.x+math.floor(x+.5),V.y+math.floor(y+.5),math.floor(x+w+.5)-math.floor(x+.5),math.floor(y+h+.5)-math.floor(y+.5)
        Infinity_SetArea(name,ax,ay,aw,ah)
        if EEex_Menu_GetItem(name..'Caption') then Infinity_SetArea(name..'Caption',ax,ay,aw,ah) end
        if EEex_Menu_GetItem(name..'Glyph') then Infinity_SetArea(name..'Glyph',ax+(aw-12)/2,ay+(ah-12)/2,12,12) end
    end
    V.Area=area
    for i=0,2 do area('rxWell'..i,58,U.IsDashboard() and 126 or 86,V.w-116,V.h-(U.IsDashboard() and 214 or 174)) end
    for i=1,40 do local r=D.frames[V.FrameKey()][i];area('rxFrame'..i,unpack(r and r.rect or {0,0,0,0})) end
    local skin=D.theme.skins[V.Skin()].geometry;local y=skin.topRowY;local tw=V.wide and 136 or 118
    for i,n in ipairs({'rxBuffs','rxOrder','rxSummary'}) do area(n,64+(i-1)*(tw+6),y,tw,30) end
    local dragon=V.SkinIndex()==0
    local cx=dragon and V.w-48 or (V.wide and skin['closeX.wide'] or skin['closeX.compact'])
    local right=dragon and V.w-100 or ((V.SkinIndex()==1 or V.SkinIndex()==2) and V.w-62 or cx-10)
    local pw=V.wide and 260 or 224
    area('rxPreset',right-72-pw,y,pw,30);area('rxPresetText',right-66-pw,y,pw-24,30);area('rxPresetChevron',right-92,y+7,16,16)
    area('rxNew',right-66,y,30,30);area('rxOptions',right-30,y,30,30);area('rxClose',cx,dragon and 22 or skin.closeY,38,38)
    local fy=V.h-82;local rw=V.wide and 300 or 250
    area('rxRest',60,fy+2,rw,30);area('rxRestIcon',64,fy+6,22,22);area('rxRestText',90,fy+2,rw-52,30);area('rxRestChevron',60+rw-22,fy+9,16,16)
    area('rxStatus',70+rw,fy+1,420,32);area('rxFeedback',60,V.h-43,V.w-120,20)
    area('rxCast',V.w-60-(V.wide and 150 or 132),fy,V.wide and 150 or 132,34)
    area('rxStop',V.w-60-(V.wide and 150 or 132),fy,V.wide and 150 or 132,34)
    -- Place from the Cast edge backwards, with real gaps between controls.
    local castLeft=V.w-60-(V.wide and 150 or 132)
    local hiddenLeft=castLeft-12-110
    local addWidth=V.wide and 190 or 170
    area('rxHidden',hiddenLeft,fy+2,110,30)
    area('rxAdd',hiddenLeft-12-addWidth,fy+2,addWidth,30)
    if V.LayoutContent then V.LayoutContent() end
end
function V.Open()
    if not P.GetState() then return end
    local state=Infinity_IsMenuOnStack('BUFFBOT_RX')
    if state==1 or state==true then V.active=true;return end
    V.active=true;Infinity_PushMenu('BUFFBOT_RX')
end
function V.OnOpen() U.Refresh();V.Layout() end
function V.Close() V.ClosePopup();Infinity_PopMenu('BUFFBOT_RX');V.active=false end
function V.AbsorbClick() end
function V.ClosePopup()
    if V.rename and U.preset then bbPartyName=U.preset.name end
    for _,name in ipairs({'BUFFBOT_RX_POPMENU','BUFFBOT_RX_DIALOG'}) do
        if Infinity_IsMenuOnStack(name)==1 then Infinity_PopMenu(name) end
    end
    V.popup=nil
    V.rename=false
end
function V.ToggleChoices(mode)
    if V.popup=='menu' and U.choiceMode==mode then return V.ClosePopup() end
    U.OpenChoices(mode)
end
function V.ShowChoices()
    local mode=U.choiceMode
    local isMenu=mode=='presets' or mode=='settings' or mode=='rest' or mode=='caster'
    if not isMenu and not EEex_Menu_Find('BUFFBOT_RX_DIALOG') then return Infinity_PushMenu('BUFFBOT_PARTY_CHOICES') end
    V.ClosePopup();V.popup=isMenu and 'menu' or 'dialog'
    V.rename=false
    if mode=='sources' then V.BuildSources() end
    Infinity_PushMenu(isMenu and 'BUFFBOT_RX_POPMENU' or 'BUFFBOT_RX_DIALOG')
end
function V.ChoiceCurrent(i)
    local r=bbPartyChoices[i];if not r then return false end
    if r.kind=='preset' then return r.value==U.state.active end
    if r.kind=='rest' then return r.value==(U.state.rest.on==1 and U.state.rest.preset or 0) end
    if U.choiceMode=='caster' then return r.name:sub(1,4)=='[x] ' end
    if r.kind=='theme' then return U.state.skin==r.value or U.state.skin==nil and r.value==-1 end
    if r.kind=='castingMode' then return U.state.fast==1 and U.state.fastRate==r.value or U.state.fast~=1 and r.value==0 end
    return false
end
function V.ChoiceGlyph(i)
    local r=bbPartyChoices[i];if not r then return V.Glyph('radio-off') end
    local g=({rename='rename',refresh='refresh',import='import',legacy='legacy',info='blocked'})[r.kind] or 'radio-off'
    return V.Glyph(g)
end
function V.ChoiceText(i)
    local r=bbPartyChoices[i];if not r then return '' end
    local s=r.name:gsub('^%[x%]%s*','')
    if U.choiceMode=='caster' then return s:match('^(.-) / ') or s end
    return ({rename=P.Text('Rename preset...'),refresh=P.Text('Refresh sources'),legacy=P.Text('Caster editor (legacy)')})[r.kind] or s
end
function V.ChoiceNote(i)
    local r=bbPartyChoices[i];if not r then return '' end
    local s=r.name:gsub('^%[x%]%s*','');local note=s:match(' / (.+)$') or ''
    if r.kind=='caster' and r.value==false then
        local d=U.TryCaster(U.choiceRequest,false)
        if d and d.source then return d.source.casterName..' / '..U.Duration(d.duration) end
    end
    return note
end
function V.LayoutPopup()
    if V.popup=='dialog' then if V.LayoutDialog then return V.LayoutDialog() end;return end
    local mode=U.choiceMode;local caster=mode=='caster';local rh=caster and 48 or 32
    local w=mode=='presets' and 280 or mode=='settings' and 300 or mode=='rest' and 290 or 330
    local header=caster and 64 or mode=='rest' and 30 or 0
    local h=math.min(V.h-100,#bbPartyChoices*rh+24+header)
    local anchor=U.choiceAnchor
    if not caster or not anchor then
        local trigger=mode=='presets' and 'rxPreset' or mode=='rest' and 'rxRest' or mode=='settings' and 'rxOptions' or 'rxPreset'
        local x,y,aw,ah=EEex_Menu_GetItemArea(trigger);anchor={x=x,y=y+ah,w=aw,h=ah}
    end
    local x=anchor.x+(caster and 8 or 0)
    if mode=='settings' then x=anchor.x+anchor.w+14-w end
    x=math.max(V.x+60,math.min(x,V.x+V.w-60-w))
    local y=anchor.y+6;local above=mode=='rest' or y+h>V.y+V.h-40
    if above then y=anchor.y-(anchor.h or 30)-h-8 end
    y=math.max(V.y+40,math.min(y,V.y+V.h-40-h))
    V.popupAbove=above;V.popupRect={x,y,w,h}
    -- The menu's click shield covers the main panel. Repeat its trigger hit
    -- region on this surface so the same button can toggle the menu closed.
    if caster then
        Infinity_SetArea('rxMenuTrigger',anchor.x,anchor.y-(anchor.h or 30),anchor.w,anchor.h or 30)
    else
        local trigger=mode=='presets' and 'rxPreset' or mode=='rest' and 'rxRest' or 'rxOptions'
        Infinity_SetArea('rxMenuTrigger',EEex_Menu_GetItemArea(trigger))
    end
    local function area(name,dx,dy,aw,ah)
        Infinity_SetArea(name,x+dx,y+dy,aw,ah)
        if EEex_Menu_GetItem(name..'Glyph') then Infinity_SetArea(name..'Glyph',x+dx+(aw-12)/2,y+dy+(ah-12)/2,12,12) end
    end
    V.PopupArea=area
    area('rxMenuShadow',-3,4,w+6,h+8);area('rxMenuBody',0,0,w,h)
    -- MOS rails have six transparent pixels before the four painted pixels.
    -- Keep native MOS pixels and clip the long dimension; MOS does not scale.
    area('rxMenuTop',0,-6,w,10);area('rxMenuBottom',0,h-6,w,10)
    area('rxMenuLeft',-6,0,10,h);area('rxMenuRight',w-6,0,10,h)
    area('rxMenuTL',-3,-3,30,22);area('rxMenuBR',w-27,h-19,30,22)
    area('rxMenuNotch',math.max(16,math.min(w-28,anchor.x+anchor.w/2-x-6)),above and h-2 or -10,12,12)
    area('rxMenuTitle',16,10,w-52,24);area('rxMenuHint',16,34,w-32,24);area('rxMenuClose',w-36,10,24,24)
    area('rxMenuRestNote',16,8,w-32,24)
    area('rxMenuChoices',12,12+header,w-24,h-24-header)
    area('rxMenuCasters',12,12+header,w-24,h-24-header)
end
function V.Rename(isNew)
    if not EEex_Menu_Find('BUFFBOT_RX_DIALOG') then return Infinity_PushMenu('BUFFBOT_PARTY_RENAME') end
    V.ClosePopup();V.rename=true;V.namingNew=isNew==true;V.popup='dialog'
    Infinity_PushMenu('BUFFBOT_RX_DIALOG')
end
function V.DialogTitle()
    if V.rename then return P.Text(V.namingNew and 'New preset' or 'Rename preset') end
    if U.choiceMode=='sources' then return U.BuffName(U.snapshot.groups[U.choiceGroup],U.choiceVariant) end
    if U.choiceMode=='delete' or U.choiceMode=='planImport' or U.choiceMode=='casting' or U.choiceMode=='theme' then return bbPartyChoiceTitle end
    return P.Text(U.choiceMode=='hidden' and 'Hidden buffs' or 'Add spell / item')
end
function V.DialogSubtitle()
    if V.rename then return U.preset.name..' / '..#U.preset.requests..' '..P.Text('requests') end
    if U.choiceMode=='add' then return P.Text('Known abilities the browser leaves out / adding does not grant uses') end
    if U.choiceMode=='hidden' then return P.Text('Hidden from the browser / saved requests are kept') end
    if U.choiceMode=='delete' or U.choiceMode=='planImport' or U.choiceMode=='casting' or U.choiceMode=='theme' then return bbPartyChoiceHint end
    local g=U.snapshot.groups[U.choiceGroup]
    return g and ((g.kind=='itm' and P.Text('Item') or P.Text('Spell'))..' / '..P.Text('Available casters and remaining uses')) or ''
end
function V.DeleteDescription()
    if not U.CanDeletePreset() then return P.Text('Keep at least one preset. Create another preset before deleting this one.') end
    return P.Text('Delete this preset and all its planned buffs? Other presets are kept. If it is the After rest preset, automatic rest casting will be turned off.')
end
function V.BuildSources()
    bbVisualSources={};V.sourceShared=false
    local g=U.snapshot.groups[U.choiceGroup];local seen={}
    for _,s in ipairs(g and g.sources or {}) do
        if s.variants and #s.variants>0 then V.sourceShared=true end
        local cap=U.snapshot.pools[s.pool] or 0;local used=U.plan.used[s.pool] or 0
        local duration=U.choiceVariant and s.variantDurations and s.variantDurations[U.choiceVariant] or s.duration
        local key=s.actor..':'..s.pool
        if not seen[key] then
            local assigned=false
            for _,d in ipairs(U.plan.decisions) do
                if d.source and d.source.actor==s.actor and d.request.group==U.choiceGroup and d.request.var==U.choiceVariant then assigned=true end
            end
            local a=U.snapshot.actors[s.actor]
            bbVisualSources[#bbVisualSources+1]={name=s.casterName..(assigned and (' / '..P.Text('assigned')) or ''),
                portrait=a and U.Portrait(a.slot) or '',duration=s.reason and '—' or U.Duration(duration),
                uses=math.max(0,cap-used)..'/'..cap,range=s.selfOnly and P.Text('Self') or '—'}
            seen[key]=true
        end
    end
end
function V.SourceIcon()
    local g=U.snapshot.groups[U.choiceGroup];local v=U.VariantInfo(g,U.choiceVariant)
    return v and v.icon~='' and v.icon or g and g.icon or ''
end
function V.SourceSharedText()
    local g=U.snapshot.groups[U.choiceGroup]
    return g and (P.Text('Shares uses with ')..g.name..'. '..P.Text('All variants spend the same parent spell uses.')) or ''
end
function V.SourceNote()
    local g=U.snapshot.groups[U.choiceGroup]
    for _,s in ipairs(g and g.sources or {}) do
        if s.itemOwner then return P.Text('One physical item: recipients share its charges. Gear is returned after each use.') end
    end
    return P.Text('Durations are estimates for each caster. Assigned casters appear on Summary and Order.')
end
function V.HideLabel() return P.Text(V.sourceShared and 'Hide spell and all variants' or 'Hide from browser') end
function V.HideSource()
    for i,r in ipairs(bbPartyChoices) do if r.kind=='hide' then bbPartyChoiceSelection=i;U.Choose();return end end
end
function V.LayoutDialog()
    local mode=U.choiceMode;local source=not V.rename and mode=='sources'
    local w=V.rename and 440 or source and 540 or 560
    local h=V.rename and 238 or source and (V.sourceShared and 362 or 300) or mode=='add' and 470 or 330
    local x,y=V.x+math.floor((V.w-w)/2),V.y+math.floor((V.h-h)/2)-(V.rename and 20 or 10)
    V.popupRect={x,y,w,h}
    local function area(name,dx,dy,aw,ah)
        Infinity_SetArea(name,x+dx,y+dy,aw,ah)
        if EEex_Menu_GetItem(name..'Caption') then Infinity_SetArea(name..'Caption',x+dx,y+dy,aw,ah) end
        if EEex_Menu_GetItem(name..'Glyph') then Infinity_SetArea(name..'Glyph',x+dx+(aw-12)/2,y+dy+(ah-12)/2,12,12) end
    end
    V.PopupArea=area
    area('rxDialogShadow',-3,4,w+6,h+8);area('rxDialogBody',0,0,w,h)
    area('rxDialogTop',0,-6,w,10);area('rxDialogBottom',0,h-6,w,10)
    area('rxDialogLeft',-6,0,10,h);area('rxDialogRight',w-6,0,10,h)
    area('rxDialogTL',-3,-3,30,22);area('rxDialogBR',w-27,h-19,30,22)
    area('rxDialogTitle',source and 52 or 16,10,w-(source and 96 or 60),26);area('rxDialogSubtitle',source and 52 or 16,34,w-(source and 68 or 32),24)
    area('rxSourceIcon',16,14,28,28)
    area('rxDialogClose',w-36,10,24,24);area('rxDialogRule',16,62,w-32,1)
    area('rxNameLabel',16,76,w-32,24);area('rxNamePlate',16,104,w-32,34);area('rxName',24,107,w-48,28)
    area('rxNameHelp',16,146,w-32,30)
    area('rxNameCancel',w-244,h-44,110,28);area('rxNameSave',w-126,h-44,110,28)
    area('rxDeleteBody',16,82,w-32,110)
    area('rxDeleteCancel',w-244,h-44,110,28);area('rxDeleteConfirm',w-126,h-44,110,28)
    local sx=16
    for i,key in ipairs({'Caster','Duration','Uses','Range'}) do local width=({44,20,16,20})[i]*(w-32)/100;area('rxSourceHead'..key,sx+4,68,width-8,24);sx=sx+width end
    area('rxSources',16,94,w-32,100);area('rxSourceNote',16,200,w-32,44)
    area('rxSourceShared',16,244,w-32,60);area('rxSourceHide',16,h-45,30,30)
    area('rxSourceHideText',52,h-44,260,28);area('rxSourceHideTextHit',52,h-44,260,28)
    area('rxCatalogChoices',16,72,w-32,h-124);area('rxDialogDone',w-126,h-44,110,28)
    area('rxHiddenNote',16,h-86,w-32,36)
    area('rxDialogEmptyTitle',32,100,w-64,30);area('rxDialogEmptyBody',32,136,w-64,76)
end
function V.ChangeView(view) U.SetView(view);V.Layout() end
function V.Tick() U.Tick();return false end
function V.RestText()
    local rest=U.state and U.state.rest;local preset=rest and U.state.presets[rest.preset]
    return P.Text('After rest')..'  '..(rest and rest.on==1 and preset and preset.name or P.Text('Off'))
end
function V.PresetText() return P.Text('Editing')..'  '..(U.preset and U.preset.name or '') end
function V.Stop() BfBot.Exec.Stop() end

function V.FilterPortrait(i) local a=U.snapshot and U.snapshot.order[i];return a and U.Portrait(a.slot) or '' end
function V.IsPartyRow(i) return bbPartyRows[i] and bbPartyRows[i].party end
function V.Chip(i,k)
    local row=bbPartyRows[i]
    if row and row.party then return k==1 and row.partyCell or nil end
    return U.DashboardCell(i,k)
end
function V.ChipChecked(i,k) local c=V.Chip(i,k);return c and c.checked or false end
function V.ChipError(i,k) local c=V.Chip(i,k);return c and c.checked and not c.available or false end
function V.ShortName(value,limit)
    local chars={};for c in tostring(value or ''):gmatch(utf8Glyph) do chars[#chars+1]=c end
    return #chars<=limit and tostring(value or '') or table.concat(chars,'',1,limit-3)..'...'
end
function V.ChipName(i,k,full)
    local c=V.Chip(i,k);local name=c and c.name or ''
    return full and name or V.ShortName(name,V.wide and 20 or 11)
end
function V.ChipDuration(i,k)
    local c=V.Chip(i,k)
    if not c then return '' end
    if c.checked and not c.available then return P.Text('No source') end
    local d=c.decision and c.decision.source and c.decision or c.possibilities
    return d and d.source and U.Duration(d.duration) or ''
end
function V.UsesExhausted(i)
    local r=bbPartyRows[i]
    return r and not r.atWill and r.total and r.total>0 and r.free==0 or false
end
function V.RowDuration(i) return bbPartyRows[i] and bbPartyRows[i].heading and '' or U.RowDuration(i):gsub(' %- ','–') end
function V.AfterFilter()
    local rows,seen={},{}
    for _,r in ipairs(bbPartyRows) do
        if not r.heading then
            if r.variantGroup and not seen[r.key] then
                local g=U.snapshot.groups[r.key];local count,variants=0,{}
                for _,s in ipairs(g and g.sources or {}) do for _,v in ipairs(s.variants or {}) do if not variants[v.resref] then count=count+1;variants[v.resref]=true end end end
                rows[#rows+1]={heading=true,key=r.key,id='family:'..r.key,name=(g and g.name or r.name)..'\n'..count..' '..P.Text('variants / shared uses'),
                    icon='',uses=r.uses,free=r.free,total=r.total,atWill=r.atWill,qualifier='',cells={},planned=0,party=false}
                seen[r.key]=true
            end
            rows[#rows+1]=r
        end
    end
    bbPartyRows=rows
end
function V.ErrorReason(i) local d=U.plan.decisions[i];return d and d.reason or P.Text('No source') end
function V.RowQualifier(i)
    local r=bbPartyRows[i];if not r then return '' end
    if r.heading then return '' end
    local g=U.snapshot.groups[r.key];local s=g and g.sources and g.sources[1];local q=r.qualifier or ''
    if s then
        local row=s.row;local self=s.selfOnly==true or row.isSelfOnly==1 or row.isSelfOnly==true
        if row.kind=='itm' then q=P.Text('Item')..(self and (' / '..P.Text('Self only')) or '')
        elseif q~='' and not r.variant then
            q=row.spellType==4 and (P.Text('Innate')..' / '..s.casterName) or P.Text(row.spellType==2 and 'Priest spell' or 'Wizard spell')
        elseif self and not r.variant then q=P.Text('Self only') end
    end
    if r.variant then q='' end
    return q
end
function V.RowTitle(i) local r=bbPartyRows[i];return r and r.name or '' end
function V.RowName(i) local q=V.RowQualifier(i);return V.RowTitle(i)..(q~='' and ('\n'..q) or '') end
function V.RowTip(i) return V.RowName(i) end
function V.Empty()
    if not U.preset then return false end
    return U.IsDashboard() and #bbPartyRows==0 or not U.IsDashboard() and #U.preset.requests==0
end
function V.EmptyTitle()
    if U.IsDashboard() then return bbPartyQuery~='' and (P.Text('No buffs match ')..'"'..bbPartyQuery..'"') or P.Text('No eligible buffs') end
    return U.preset.name..' '..P.Text('has no requests yet')
end
function V.EmptyBody()
    return U.IsDashboard() and P.Text('Your planned requests are unchanged. Clear search or switch to All buffs.')
        or P.Text('Pick buffs and recipients on the Buffs tab.')
end
function V.EmptyActionText() return P.Text(not U.IsDashboard() and 'Go to Buffs' or bbPartyQuery~='' and 'Clear search' or 'All buffs') end
function V.EmptyAction()
    if not U.IsDashboard() then V.ChangeView('dashboard')
    elseif bbPartyQuery~='' then U.ClearSearch() else U.SetRecipient(0) end
end
function V.DialogEmpty()
    return not V.rename and (U.choiceMode=='sources' and #bbVisualSources==0 or (U.choiceMode=='add' or U.choiceMode=='hidden' or U.choiceMode=='planImport') and #bbPartyChoices==0)
end
function V.DialogEmptyTitle() return P.Text(U.choiceMode=='planImport' and 'No exported plans' or U.choiceMode=='add' and 'Nothing left to add' or U.choiceMode=='hidden' and 'No hidden buffs' or 'No sources available') end
function V.DialogEmptyBody()
    return P.Text(U.choiceMode=='planImport' and 'Put .bbp plan files in override/bfbot_plans, then reopen Import plan.' or U.choiceMode=='add' and 'Every known ability for this party is already in the browser.'
        or U.choiceMode=='hidden' and 'Use Hide in a buff\'s details to tidy the browser. Hiding keeps planned requests.'
        or 'Refresh sources in Options and try again.')
end
function V.IsAuto(i) return bbPartyRequests[i] and not bbPartyRequests[i].request.source end
function V.RequestError(i) return bbPartyRequests[i] and bbPartyRequests[i].unavailable end
function V.CasterName(i)
    local r=bbPartyRequests[i];if not r then return '' end
    local d=U.plan.decisions[i];local a=U.snapshot.actors[r.request.source]
    return r.request.source and (a and a.name or P.Text('Pinned caster unavailable')) or d.source and d.source.casterName or P.Text('No source')
end
function V.SummaryText(i)
    local row=bbPartySummary[i];if not row then return '' end
    if row.heading then
        local n=0
        for j=i+1,#bbPartySummary do if bbPartySummary[j].heading then break end;if bbPartySummary[j].request then n=n+1 end end
        if row.party then return row.name..'   '..(n==0 and P.Text('No party-wide buffs') or n==1 and P.Text('One party-wide cast / not proof of range') or n..' '..P.Text('party-wide casts / not proof of range')) end
        return row.name..'   '..(n==0 and P.Text('No individual buffs') or (n..' '..P.Text(n==1 and 'buff' or 'buffs')))
    end
    if row.request then return U.SummaryName(i) end
    local name=''
    for j=i-1,1,-1 do
        if bbPartySummary[j].heading then
            if bbPartySummary[j].party then return P.Text('No party-wide buffs scheduled. Individual buffs are listed below.') end
            name=bbPartySummary[j].name;break
        end
    end
    return P.Text('Nothing scheduled for ')..name..'. '..P.Text('Party-wide buffs above still apply.')
end
function V.SummaryTip(i)
    local row=bbPartySummary[i];return row and row.request and U.SummaryTip(i) or V.SummaryText(i)
end
function V.OrderPortrait(i,n)
    local row=bbPartyRequests[i];if not row then return '' end
    if row.request.target=='party' then return V.FilterPortrait(n) end
    local actor=U.snapshot.actors[row.request.target]
    return n==1 and actor and U.Portrait(actor.slot) or ''
end
function V.OrderClick(column)
    local row=bbPartyRequests[bbPartyRequestSelection]
    if not row then return end
    if column==2 or column==3 then U.OpenChoices('sources',row.request.group,row.request.var)
    else U.OrderClick(column) end
end
function V.OpenCaster(index,listName,column,rowIndex)
    local row=bbPartyRequests[index];if not row then return end
    U.request=row.request;U.choiceName=row.name;U.choiceRequest,U.choicePreset=row.request,U.preset
    U.OpenChoices('caster')
    local summary=listName=='bpSummary';local name=summary and 'rxSummaryList' or 'rxOrderList'
    if V.wide then name=name..'Wide' end
    local x,y,w=EEex_Menu_GetItemArea(name);local item=EEex_Menu_GetItem(name)
    local top=item and item.scrollbar and item.scrollbar.top or 0
    local rh=summary and (V.wide and 42 or 34) or (V.wide and 50 or 46)
    local fraction=summary and (V.wide and .47 or .43) or (V.wide and .47 or .49)
    U.choiceAnchor={x=x+w*fraction,y=y+((rowIndex or index)-1)*rh-top+rh,w=summary and 250 or 232,h=rh}
    if V.popup then V.LayoutPopup() else U.PopupLayout(false) end
end
function V.LayoutContent()
    local a=V.Area;local wide=V.wide;local width=V.w-156
    local fx=60;local fw=wide and 120 or 98;local mw=wide and 150 or 124
    for i=0,6 do
        local w=i==0 and fw or mw;a('rxRecipient'..i,fx,88,w,32)
        if i>0 then a('rxRecipientPortrait'..i,fx+6,94,14,21);a('rxRecipient'..i..'Caption',fx+24,88,w-28,32) end
        fx=fx+w+4
    end
    local sw=wide and 360 or 268;local sx=V.w-60-sw
    a('rxSearchPlate',sx,88,sw,32);a('rxSearch',sx+30,90,sw-60,28)
    a('rxSearchHint',sx+30,90,sw-60,28);a('rxSearchClear',sx+sw-28,92,24,24)
    local widths=wide and {3,22,4,7,10,10,10,10,10,10,4} or {4,20,5,9,9,9,9,9,9,9,8}
    local x=68
    for i,key in ipairs({'Icon','Name','Uses','Duration','Recipients'}) do
        local w=width*widths[i]/100
        if i>1 then
            a('rxHead'..key,x+4,132,w-8,26)
            if key=='Name' or key=='Duration' then a('rxSort'..key,x+(key=='Name' and 58 or 80),140,10,10) end
        end
        x=x+w
    end
    a('rxDashboard',68,160,width+28,V.h-256)
    a('rxDashboardWide',68,160,width+28,V.h-256)
    a('rxSummaryList',68,120,width+28,V.h-216);a('rxSummaryListWide',68,120,width+28,V.h-216)
    local sx=68
    local summaryWidths=wide and {4,43,21,8,24} or {4,39,25,9,23}
    for i,key in ipairs({'Icon','Name','Caster','Duration','Remove'}) do
        if i>1 then a('rxSummaryHead'..key,sx+4,92,width*summaryWidths[i]/100-8,26) end
        sx=sx+width*summaryWidths[i]/100
    end
    a('rxSummaryHeadRemove',V.w-162,92,94,26)
    a('rxOrderList',68,158,width+28,V.h-254);a('rxOrderListWide',68,158,width+28,V.h-254)
    for i,key in ipairs({'Smart','Long','Custom','Undo'}) do a('rxOrder'..key,68+(i-1)*156,90,148,30) end
    local ox=68;local orderWidths=wide and {3,3,27,14,19,7,2,2,23} or {3,4,27,15,22,7,3,3,16}
    for i,key in ipairs({'Number','Icon','Name','Recipient','Caster','Duration','Move'}) do
        if i~=2 then
            local hw=width*orderWidths[i]/100-8
            local hx=ox+4
            if key=='Duration' then hw=math.max(hw,88);if not wide then hx=hx-10 end end
            if key=='Move' then hx=hx+6;hw=width*(orderWidths[7]+orderWidths[8])/100-10 end
            a('rxOrderHead'..key,hx,130,hw,26)
        end
        ox=ox+width*orderWidths[i]/100
    end
    a('rxOrderHeadRemove',V.w-162,130,94,26)
    a('rxEmptyGlyph',V.w/2-16,V.h/2-90,32,32);a('rxEmptyTitle',V.w/2-280,V.h/2-44,560,32)
    a('rxEmptyBody',V.w/2-280,V.h/2-6,560,60);a('rxEmptyAction',V.w/2-80,V.h/2+66,160,30)
end
