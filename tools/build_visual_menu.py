"""Generate the recipient visual menu; each clickable list element is a column."""
from pathlib import Path
import argparse
ROOT=Path(__file__).resolve().parents[1]
V='BfBot.Visual';U='BfBot.PartyUI';P='BfBot.Plan'
lines=[]
POINTS={'text':14,'textwide':15,'chipwide':14,'muted':12,'small':12,'header':12,'tab':15,'button':13,'display':14,'title':15,'error':12}
ROLES={'muted':'text.muted','header':'text.groupLabel','tab':'text.tabActive','button':'text.button','display':'text.title','title':'text.title'}
ROWHEIGHT=44
ROWERROR=False
def emit(s):lines.append(s)
def widget(kind,name,props=(),area='0 0 100 30'):
    emit(kind+'\n{\n name "'+name+'"\n area '+area+'\n'+'\n'.join(' '+p for p in props)+'\n}')
def label(name,expr,style='text',enabled=None,extra=(),area='0 0 100 30'):
    widget('label',name,[f'text lua "{expr}"',f'text style "bvr_{style}"',f'text point {POINTS[style]}','text align left center','ignoreEvents',*([f'enabled "{enabled}"'] if enabled else []),*extra],area)
def button(name,action,text=None,bam='RGDMBUT2',seq=None,frame='0',enabled='true',extra=(),style='button',bam_expr=None):
    artwork=f'bam lua "{bam_expr}"' if bam_expr else f'bam "{bam}"'
    props=[f'enabled "{enabled}"',f'action "{action}"',artwork,f'sequence lua "{seq or V+".SkinIndex()"}"',f'frame lua "{frame}"','scaleToClip',*extra]
    widget('button',name,props)
    # ITEM_BUTTON ignores text.point. An event-transparent label keeps native
    # button hit-testing while honoring the specified typography.
    if text is not None:label(name+'Caption',text,style,enabled,extra=['text align center center'])
def glyph(name,g,enabled=None,action=None):
    props=[f'bam "BFBGLYPH"',f'sequence lua "{V}.Glyph(\'{g}\')"','frame 0','scaleToClip',*([f'enabled "{enabled}"'] if enabled else [])]
    if action:
        widget('button',name,[f'action "{action}"',*([f'enabled "{enabled}"'] if enabled else [])])
        widget('label',name+'Glyph',props+['ignoreEvents'])
    else:widget('label',name,props+['ignoreEvents'])
def cell(rect,expr=None,style='text',enabled=None,extra=()):
    p=['area '+' '.join(map(str,rect))]
    if expr is not None:p += [f'text lua "{expr}"',f'text style "bvr_{style}"',f'text point {POINTS[style]}','text align left center']
    if enabled:p += [f'enabled "{enabled}"']
    return p+list(extra)
def column(width,labels):
    emit(' column\n {\n  width '+str(width))
    if ROWERROR:emit('  label\n  {\n   area 0 0 -1 '+str(ROWHEIGHT)+f'\n   enabled "{V}.RequestError(rowNumber)"\n   fill 224 83 63 18\n  }}')
    for props in labels:emit('  label\n  {\n'+'\n'.join('   '+p for p in props)+'\n  }')
    emit('  label\n  {\n   area 0 '+str(ROWHEIGHT-1)+' -1 1\n   fill 176 138 74 32\n  }')
    emit(' }')
def finish_list(name,table,var,action,enabled,rowheight):
    emit(f' name "{name}"\n table "{table}"\n var "{var}"\n action "{action}"\n enabled "{enabled}"\n rowheight {rowheight}\n scrollbar "RGDSCRL1"\n hidehighlight\n area 68 160 1152 464\n}}')
def buffs():
    global ROWHEIGHT
    shown=f'{U}.IsDashboard()'
    for i in range(7):
        enabled=shown+(f" and {U}.RecipientName({i})~=''" if i else '')
        button('rxRecipient'+str(i),f'{U}.SetRecipient({i})',f'{U}.RecipientName({i})','RGDSBUT2',frame=f'{U}.IsRecipient({i}) and 2 or 0',enabled=enabled,style='button',extra=[f'tooltip lua "{U}.RecipientName({i})"'])
        if i:widget('label','rxRecipientPortrait'+str(i),[f'enabled "{enabled}"',f'bitmap lua "{V}.FilterPortrait({i})"','scaleToClip','ignoreEvents'])
    widget('label','rxSearchPlate',[f'enabled "{shown}"','bam "RGDSRCH1"',f'sequence lua "{V}.SkinIndex()"','frame 0','scaleToClip','ignoreEvents'])
    label('rxSearchHint',f"{P}.Text('Search buffs...')",'muted',f"{shown} and bbPartyQuery==''")
    widget('edit','rxSearch',[f'enabled "{shown}"','var "bbPartyQuery"','action "return 1"','text style "bvr_text"','maxlines 1'])
    glyph('rxSearchClear','clear-search',f"{shown} and bbPartyQuery~=''",f'{U}.ClearSearch()')
    for name in ['Name','Uses','Duration','Recipients']:
        if name in ['Name','Duration']:
            widget('button','rxHead'+name,[f'enabled "{shown}"',f'action "{U}.SortBy(\'{name.lower()}\')"'])
            label('rxHead'+name+'Caption',f"{P}.Text('{name}')",'header',shown)
            widget('label','rxSort'+name,[f'enabled "{shown} and {U}.sortField==\'{name.lower()}\'"','bam "BFBGLYPH"',f'sequence lua "{V}.Glyph({U}.sortDescending and \'sort-desc\' or \'sort-asc\')"','frame 0','scaleToClip','ignoreEvents'])
        else:label('rxHead'+name,f"{P}.Text('{name}')",'header',shown,extra=[f'tooltip lua "{P}.Text(\'Free to add / total available now. Planned uses are already reserved.\')"'] if name=='Uses' else [])
    # Both fixed layouts have separate row templates; integer percentage widths
    # follow integration §4's fallback, with remainder in the final column.
    for wide,widths,rh,cw,ch,pw,ph in [(False,[4,20,5,9]+[9]*6+[8],48,100,36,24,36),(True,[3,22,4,7]+[10]*6+[4],54,168,40,30,40)]:
        ROWHEIGHT=rh
        which='Wide' if wide else ''
        emit('list\n{')
        column(widths[0],[cell([4,5,34 if not wide else 38,34 if not wide else 38],enabled='bbPartyRows[rowNumber] and not bbPartyRows[rowNumber].heading',extra=['bam "RGDSLOT"',f'sequence lua "{V}.SkinIndex()"','frame 0','scaleToClip']),cell([10,11,22 if not wide else 24,22 if not wide else 24],extra=[f'icon lua "bbPartyRows[rowNumber] and bbPartyRows[rowNumber].icon or \'\'"'])])
        title_style='textwide' if wide else 'text'
        column(widths[1],[cell([4,0,-1,rh],f'{V}.RowTitle(rowNumber)',title_style,f'{V}.RowQualifier(rowNumber)==\'\'',extra=[f'tooltip lua "{V}.RowTip(rowNumber)"']),cell([4,-2,-1,28],f'{V}.RowTitle(rowNumber)',title_style,f'{V}.RowQualifier(rowNumber)~=\'\'',extra=[f'tooltip lua "{V}.RowTip(rowNumber)"']),cell([4,20,-1,24],f'{V}.RowQualifier(rowNumber)','muted',f'{V}.RowQualifier(rowNumber)~=\'\'',extra=[f'tooltip lua "{V}.RowTip(rowNumber)"'])])
        warn_x=int((1764 if wide else 1124)*widths[2]/100)-14
        column(widths[2],[cell([0,4,-1,rh-8],enabled=f'{V}.UsesExhausted(rowNumber)',extra=['fill 224 83 63 20']),
            cell([4,0,-1,rh],"bbPartyRows[rowNumber] and bbPartyRows[rowNumber].uses or ''",'display',extra=[f'tooltip lua "{U}.UsesTip(rowNumber)"']),
            cell([warn_x,(rh-12)//2,12,12],enabled=f'{V}.UsesExhausted(rowNumber)',extra=['bam "BFBGLYPH"',f'sequence lua "{V}.Glyph(\'warning\')"','frame 0','scaleToClip',f'tooltip lua "{U}.UsesTip(rowNumber)"'])])
        column(widths[3],[cell([2,0,-1,rh],f'{V}.RowDuration(rowNumber)')])
        for k in range(1,7):
            exists=f'{V}.Chip(rowNumber,{k})~=nil';checked=f'{V}.ChipChecked(rowNumber,{k})';bad=f'{V}.ChipError(rowNumber,{k})'
            labels=[cell([0,4,cw,ch],enabled=exists,extra=['fill 0 0 0 72']),cell([0,4,cw,ch],enabled=checked,extra=['fill 240 207 122 32']),cell([0,4,cw,ch],enabled=bad,extra=['fill 224 83 63 45'])]
            for rect in [[0,4,cw,1],[0,3+ch,cw,1],[0,4,1,ch],[cw-1,4,1,ch]]:
                labels.append(cell(rect,enabled=exists,extra=['fill 255 240 210 20']))
                labels.append(cell(rect,enabled=checked,extra=['fill 240 207 122 190']))
                labels.append(cell(rect,enabled=bad,extra=['fill 224 83 63 230']))
            labels.append(cell([0,4,pw,ph],enabled=f'{exists} and not {V}.IsPartyRow(rowNumber)',extra=[f'bitmap lua "{U}.CellPortrait(rowNumber,{k})"',f'opacity lua "{checked} and 255 or 158"','scaleToClip']))
            if k==1:
                for member in range(1,4):labels.append(cell([(member-1)*11,4,pw,ph],enabled=f'{V}.IsPartyRow(rowNumber)',extra=[f'bitmap lua "{U}.PartyPortrait(rowNumber,{member})"','scaleToClip']))
            chip_style='chipwide' if wide else 'small';ty=-1 if wide else -2;dy=17 if wide else 14;th=30 if wide else 28
            labels.append(cell([pw+4,ty,cw-pw-6,th],f'{V}.ChipName(rowNumber,{k})',chip_style,f'{exists} and not {V}.IsPartyRow(rowNumber)',extra=[f'tooltip lua "{V}.ChipName(rowNumber,{k},true)"']))
            labels.append(cell([pw+4,dy,cw-pw-6,th],f'{V}.ChipDuration(rowNumber,{k})',chip_style,f'{exists} and not {V}.IsPartyRow(rowNumber)'))
            if k==1:
                party_x=pw+26
                labels.append(cell([party_x,ty,cw-party_x-2,th],f"{P}.Text('Party')",chip_style,f'{V}.IsPartyRow(rowNumber)'))
                labels.append(cell([party_x,dy,cw-party_x-2,th],f'{V}.ChipDuration(rowNumber,1)',chip_style,f'{V}.IsPartyRow(rowNumber)'))
            labels.append(cell([-4,0,17,17],enabled=checked,extra=[f'bam lua "\'RGDCHEC\'..{V}.SkinIndex()"','sequence 0','frame 0','scaleToClip']))
            labels.append(cell([cw-15,2,13,13],enabled=bad,extra=['bam "BFBGLYPH"',f'sequence lua "{V}.Glyph(\'warning\')"','frame 0','scaleToClip']))
            column(widths[k+3],labels)
        clear_rect=[5,(rh-24)//2,60 if not wide else 70,24];clear_on="bbPartyRows[rowNumber] and not bbPartyRows[rowNumber].heading and bbPartyRows[rowNumber].planned>0"
        column(widths[-1],[cell(clear_rect,enabled=clear_on,extra=['bam "RGDMBUT2"',f'sequence lua "{V}.SkinIndex()"','frame 0','scaleToClip']),cell(clear_rect,f"{P}.Text('Clear')",'button',clear_on,['text align center center'])])
        finish_list('rxDashboard'+which,'bbPartyRows','bbPartyRowSelection',f'{U}.DashboardClick(cellNumber)',f'{shown} and '+(f'{V}.wide' if wide else f'not {V}.wide'),rh)
def caster_labels(rh,fw,summary=False):
    i='bbPartySummary[rowNumber].planIndex' if summary else 'rowNumber'
    on='bbPartySummary[rowNumber] and bbPartySummary[rowNumber].request~=nil' if summary else 'bbPartyRequests[rowNumber]~=nil'
    y=(rh-28)//2;auto=f'{V}.IsAuto({i})';labels=[cell([6,y,fw,28],enabled=on,extra=['bam "RGDMBUT2"',f'sequence lua "{V}.SkinIndex()"','frame 0','scaleToClip'])]
    labels += [cell([12,y+7,34,15],enabled=f'{on} and {auto}',extra=['fill 201 163 92 55']),cell([14,y,36,28],"'AUTO'",'small',f'{on} and {auto}'),cell([52,y,fw-93,28],f'{V}.CasterName({i})','text',f'{on} and {auto}'),cell([14,y,fw-55,28],f'{V}.CasterName({i})','text',f'{on} and not {auto}'),cell([fw-14,y+6,16,16],enabled=on,extra=['bam "BFBGLYPH"',f'sequence lua "{V}.Glyph(\'dropdown\')"','frame 0','scaleToClip'])]
    for rect in [[6,y,fw,1],[6,y+27,fw,1],[6,y,1,28],[fw+5,y,1,28]]:labels.append(cell(rect,enabled=f'{on} and {V}.RequestError({i})',extra=['fill 224 83 63 230']))
    labels.append(cell([fw-34,y+7,14,14],enabled=f'{on} and {V}.RequestError({i})',extra=['bam "BFBGLYPH"',f'sequence lua "{V}.Glyph(\'warning\')"','frame 0','scaleToClip']))
    return labels
def summary():
    global ROWHEIGHT
    shown=f"{U}.view=='summary'"
    for name in ['Name','Caster','Duration','Remove']:label('rxSummaryHead'+name,f"{P}.Text('{('Recipient / buff' if name=='Name' else name)}')",'header',shown)
    for wide,rh,widths,fw in [(False,34,[4,39,25,9,23],250),(True,42,[4,43,21,8,24],320)]:
        ROWHEIGHT=rh;body='bbPartySummary[rowNumber] and bbPartySummary[rowNumber].request~=nil';head='bbPartySummary[rowNumber] and bbPartySummary[rowNumber].heading'
        emit('list\n{');pics=[]
        for n in range(1,4):pics.append(cell([4+(n-1)*9,2,18,26],enabled=head,extra=[f'bitmap lua "{U}.SummaryPortrait(rowNumber,{n})"','scaleToClip']))
        pics.append(cell([8,3,22,22],enabled=body,extra=['icon lua "bbPartySummary[rowNumber] and bbPartySummary[rowNumber].icon or \'\'"']))
        column(widths[0],pics)
        column(widths[1],[cell([4,0,-1,rh],f'{V}.SummaryText(rowNumber)','text',extra=[f'tooltip lua "{V}.SummaryTip(rowNumber)"'])])
        column(widths[2],caster_labels(rh,fw,True))
        column(widths[3],[cell([4,0,-1,rh],f'{U}.SummaryDuration(rowNumber)')])
        column(widths[4],[cell([widths[4]*(1764 if wide else 1124)//100-38,1,28,28],enabled=body,extra=['bam "RGDXBT1"','sequence 1','frame 0','scaleToClip'])])
        finish_list('rxSummaryList'+('Wide' if wide else ''),'bbPartySummary','bbPartySummarySelection',f'{U}.SummaryClick(cellNumber)',shown+f' and not {V}.Empty() and '+(f'{V}.wide' if wide else f'not {V}.wide'),rh)
def order_page():
    global ROWHEIGHT,ROWERROR
    ROWERROR=True
    shown=f"{U}.view=='order'"
    for key,mode,text,tip in [('Smart','smart','Smart order','Long first, with casting times considered to maximize buff duration.'),('Long','long','Long first','Longest-lasting buffs first.'),('Custom','custom','Custom','Restore your saved manual order. Moving a buff selects Custom.'),('Undo',None,'Undo','Restore the order before the last sort.')]:
        action=f'{U}.UndoOrder()' if mode is None else f"{U}.SortOrder('{mode}')"
        available=f'{U}.CanUndoOrder()' if mode is None else f'{U}.CanSortOrder()'
        button('rxOrder'+key,action,f"{P}.Text('{text}')",frame=f"{U}.IsOrderMode('{mode}') and 2 or 0" if mode else '0',enabled=shown,bam_expr=f"{U}.IsOrderMode('{mode}') and 'BFBTAB' or 'BFBPLAT'" if mode else None,extra=[f'greyscale lua "not {available}"',f'tooltip lua "{P}.Text(\'{tip}\')"'])
    for key,text in [('Number','#'),('Name','Buff'),('Recipient','Recipient'),('Caster','Caster'),('Duration','Duration'),('Move','Move'),('Remove','Remove')]:label('rxOrderHead'+key,f"{P}.Text('{text}')",'header',shown)
    for wide,rh,widths,fw in [(False,46,[3,4,27,15,22,7,3,3,16],232),(True,50,[3,3,27,14,19,7,2,2,23],300)]:
        ROWHEIGHT=rh;emit('list\n{')
        column(widths[0],[cell([4,0,-1,rh],'tostring(rowNumber)','small')])
        column(widths[1],[cell([4,(rh-24)//2,24,24],extra=[f'icon lua "{U}.RequestIcon(rowNumber)"'])])
        column(widths[2],[cell([4,0,-1,rh],f'{U}.OrderName(rowNumber)','text',f'not {V}.RequestError(rowNumber)',extra=[f'tooltip lua "{U}.OrderTip(rowNumber)"']),cell([4,-2,-1,28],"bbPartyRequests[rowNumber] and bbPartyRequests[rowNumber].name or ''",'text',f'{V}.RequestError(rowNumber)'),cell([4,16,-1,28],f'{V}.ErrorReason(rowNumber)','muted',f'{V}.RequestError(rowNumber)',extra=["text color 'R'",f'tooltip lua "{U}.OrderTip(rowNumber)"'])])
        portraits=[]
        for n in range(1,4):portraits.append(cell([2+(n-1)*8,(rh-28)//2,19,28],extra=[f'bitmap lua "{V}.OrderPortrait(rowNumber,{n})"','scaleToClip']))
        portraits.append(cell([36,0,-1,rh],"bbPartyRequests[rowNumber] and bbPartyRequests[rowNumber].target or ''"))
        column(widths[3],portraits)
        column(widths[4],caster_labels(rh,fw))
        column(widths[5],[cell([4,0,-1,rh],f'{U}.OrderDuration(rowNumber)')])
        for k,delta in enumerate([-1,1]):
            column(widths[6+k],[cell([3,(rh-28)//2,28,28],extra=['bam "BFBARROW"',f'sequence {k}','frame 0','scaleToClip',f'greyscale lua "not {U}.CanMove(rowNumber,{delta})"',f'opacity lua "{U}.CanMove(rowNumber,{delta}) and 255 or 76"'])])
        column(widths[8],[cell([widths[8]*(1764 if wide else 1124)//100-38,(rh-28)//2,28,28],extra=['bam "RGDXBT1"','sequence 1','frame 0','scaleToClip'])])
        finish_list('rxOrderList'+('Wide' if wide else ''),'bbPartyRequests','bbPartyRequestSelection',f'{V}.OrderClick(cellNumber)',shown+f' and not {V}.Empty() and '+(f'{V}.wide' if wide else f'not {V}.wide'),rh)
    ROWERROR=False
def popup_surface(prefix,menu):
    emit('menu\n{\n name "'+menu+'"\n align left top\n'+(' modal\n' if prefix=='rxDialog' else '')+' ignoreesc\n onopen "BfBot.Visual.LayoutPopup()"')
    # Mouse clicks on blank space are absorbed; only Escape dismisses.
    widget('button',prefix+'Shield',[f'action "{V}.AbsorbClick()"'],'0 0 99999 99999')
    widget('button',prefix+'Dismiss',[f'action "{V}.ClosePopup()"','on escape'],'0 0 0 0')
    widget('label',prefix+'Shadow',['fill 0 0 0 200','ignoreEvents'])
    widget('label',prefix+'Body',['fill 15 12 9 251','ignoreEvents'])
    for edge in ['Top','Bottom','Left','Right']:
        widget('label',prefix+edge,[f'mosaic lua "\'RGDBOX'+('G' if edge in ['Top','Bottom'] else 'F')+f'\'..{V}.SkinIndex()"','scaleToClip','ignoreEvents'])
    for corner,frame in [('TL',0),('BR',1)]:widget('label',prefix+corner,['bam "RGDMBOXC"',f'sequence lua "{V}.SkinIndex()"',f'frame {frame}','scaleToClip','ignoreEvents'])
def menus():
    global ROWHEIGHT
    popup_surface('rxMenu','BUFFBOT_RX_POPMENU')
    widget('button','rxMenuTrigger',[f'action "{V}.ClosePopup()"'])
    widget('label','rxMenuNotch',['bam "BFBGLYPH"',f'sequence lua "{V}.Glyph({V}.popupAbove and \'sort-desc\' or \'sort-asc\')"','frame 0','scaleToClip','ignoreEvents'])
    label('rxMenuTitle','bbPartyChoiceTitle','title',f"{U}.choiceMode=='caster'")
    label('rxMenuHint','bbPartyChoiceHint','muted',f"{U}.choiceMode=='caster'")
    glyph('rxMenuClose','close-dialog',f"{U}.choiceMode=='caster'",f'{V}.ClosePopup()')
    label('rxMenuRestNote',f"{P}.Text('Runs once after a completed rest')",'muted',f"{U}.choiceMode=='rest'")
    for caster in [False,True]:
        ROWHEIGHT=48 if caster else 32;emit('list\n{')
        labels=[cell([0,0,-1,ROWHEIGHT],enabled=f'{V}.ChoiceCurrent(rowNumber)',extra=['fill 240 207 122 26']),cell([5,7,18,18],enabled=f'{V}.ChoiceCurrent(rowNumber)',extra=[f'bam lua "\'RGDCHEC\'..{V}.SkinIndex()"','sequence 0','frame 0','scaleToClip']),cell([5,8,16,16],enabled=f'not {V}.ChoiceCurrent(rowNumber)',extra=['bam "BFBGLYPH"',f'sequence lua "{V}.ChoiceGlyph(rowNumber)"','frame 0','scaleToClip']),cell([30,0,-1,30 if caster else 32],f'{V}.ChoiceText(rowNumber)')]
        if caster:labels.append(cell([30,26,-1,20],f'{V}.ChoiceNote(rowNumber)','muted'))
        column(100,labels)
        finish_list('rxMenuCasters' if caster else 'rxMenuChoices','bbPartyChoices','bbPartyChoiceSelection',f'{U}.Choose()',f"{U}.choiceMode{'==' if caster else '~='}'caster'",ROWHEIGHT)
    emit('}')
def dialogs():
    global ROWHEIGHT
    popup_surface('rxDialog','BUFFBOT_RX_DIALOG')
    label('rxDialogTitle',f'{V}.DialogTitle()','title')
    label('rxDialogSubtitle',f'{V}.DialogSubtitle()','muted')
    widget('label','rxSourceIcon',[f'enabled "not {V}.rename and {U}.choiceMode==\'sources\'"',f'icon lua "{V}.SourceIcon()"','ignoreEvents'])
    glyph('rxDialogClose','close-dialog',action=f'{V}.ClosePopup()')
    widget('label','rxDialogRule',['fill 201 163 92 80','ignoreEvents'])
    naming=f'{V}.rename';source=f"not {V}.rename and {U}.choiceMode=='sources'";catalog=f"not {V}.rename and ({U}.choiceMode=='add' or {U}.choiceMode=='hidden' or {U}.choiceMode=='planImport' or {U}.choiceMode=='innateRecipients' or {U}.choiceMode=='casting' or {U}.choiceMode=='theme')"
    deleting=f"not {V}.rename and {U}.choiceMode=='delete'"
    label('rxDeleteBody',f'{V}.DeleteDescription()','text',deleting)
    button('rxDeleteCancel',f'{V}.ClosePopup()',f"{P}.Text('Cancel')",enabled=deleting)
    button('rxDeleteConfirm',f'if {U}.CanDeletePreset() then {U}.DeletePreset() end',f"{P}.Text('Delete')",frame=f'{U}.CanDeletePreset() and 2 or 3',enabled=deleting)
    label('rxNameLabel',f"{P}.Text('Preset name')",'header',naming)
    widget('label','rxNamePlate',[f'enabled "{naming}"','bam "RGDSLOTD"',f'sequence lua "{V}.SkinIndex()"','frame 0','scaleToClip','ignoreEvents'])
    widget('edit','rxName',[f'enabled "{naming}"','var "bbPartyName"','action "return 1"','text style "bvr_text"','text color D','text point 14','maxlines 1'])
    label('rxNameHelp',f"{P}.Text('Choose a preset name.')",'muted',naming)
    button('rxNameCancel',f'{V}.ClosePopup()',f"{P}.Text('Cancel')",enabled=naming)
    button('rxNameSave',f'{U}.SaveName()',f"{P}.Text('Save')",frame='2',enabled=naming)
    for key,text in [('Caster','Caster'),('Duration','Duration'),('Uses','Uses left'),('Range','Range')]:label('rxSourceHead'+key,f"{P}.Text('{text}')",'header',source)
    ROWHEIGHT=32;emit('list\n{')
    column(44,[cell([2,2,20,28],extra=['bitmap lua "bbVisualSources[rowNumber] and bbVisualSources[rowNumber].portrait or \'\'"','scaleToClip']),cell([28,0,-1,32],"bbVisualSources[rowNumber] and bbVisualSources[rowNumber].name or ''")])
    for width,key in [(20,'duration'),(16,'uses'),(20,'range')]:column(width,[cell([4,0,-1,32],f"bbVisualSources[rowNumber] and bbVisualSources[rowNumber].{key} or ''")])
    finish_list('rxSources','bbVisualSources','bbVisualSourceSelection','',source,32)
    label('rxSourceNote',f'{V}.SourceNote()','muted',source)
    label('rxSourceShared',f'{V}.SourceSharedText()','muted',source+f' and {V}.sourceShared')
    button('rxSourceHide',f'{V}.HideSource()',bam='RGDXBT1',seq='3',enabled=source)
    widget('button','rxSourceHideTextHit',[f'enabled "{source}"',f'action "{V}.HideSource()"'])
    label('rxSourceHideText',f'{V}.HideLabel()','button',source)
    ROWHEIGHT=44;emit('list\n{')
    column(8,[cell([8,12,16,16],enabled=f'{V}.ChoiceCurrent(rowNumber)',extra=[f'bam lua \"\'RGDCHEC\'..{V}.SkinIndex()\"','sequence 0','frame 0','scaleToClip']),cell([2,8,24,24],extra=['icon lua "bbPartyChoices[rowNumber] and bbPartyChoices[rowNumber].icon or \'\'"'])])
    column(70,[cell([4,0,-1,44],f'{V}.ChoiceText(rowNumber)')])
    column(22,[cell([4,8,90,28],enabled='bbPartyChoices[rowNumber]~=nil',extra=['bam "RGDMBUT2"',f'sequence lua "{V}.SkinIndex()"','frame 0','scaleToClip']),cell([4,8,90,28],f"{P}.Text({U}.choiceMode=='planImport' and 'Import' or {U}.choiceMode=='add' and 'Add' or ({U}.choiceMode=='casting' or {U}.choiceMode=='theme') and 'Select' or {U}.choiceMode=='innateRecipients' and (bbPartyChoices[rowNumber].name:sub(1,3)=='[x]' and 'Remove' or 'Add') or 'Restore')",'button',extra=['text align center center'])])
    finish_list('rxCatalogChoices','bbPartyChoices','bbPartyChoiceSelection',f'if cellNumber==3 then {U}.Choose() end',catalog,44)
    label('rxHiddenNote',f"{P}.Text('Restore brings the whole family back, including variants.')",'muted',f"not {V}.rename and {U}.choiceMode=='hidden'")
    label('rxDialogEmptyTitle',f'{V}.DialogEmptyTitle()','title',f'{V}.DialogEmpty()')
    label('rxDialogEmptyBody',f'{V}.DialogEmptyBody()','text',f'{V}.DialogEmpty()')
    button('rxDialogDone',f'{V}.ClosePopup()',f"{P}.Text('Close')",enabled=f"not {V}.rename and {U}.choiceMode~='delete'")
    emit('}')
def empty_states():
    widget('label','rxEmptyGlyph',[f'enabled "{V}.Empty()"','bam "BFBGLYPH"',f'sequence lua "{V}.Glyph({U}.IsDashboard() and \'search\' or \'empty-plan\')"','frame 0','scaleToClip','ignoreEvents'])
    label('rxEmptyTitle',f'{V}.EmptyTitle()','title',f'{V}.Empty()',extra=['text align center center'])
    label('rxEmptyBody',f'{V}.EmptyBody()','text',f'{V}.Empty()',extra=['text align center center'])
    button('rxEmptyAction',f'{V}.EmptyAction()',f'{V}.EmptyActionText()',enabled=f'{V}.Empty()')
def main(stage):
    emit('-- Generated by tools/build_visual_menu.py; list clicks use cellNumber.\nmenu\n{\n name "BUFFBOT_RX"\n ignoreesc\n onopen "BfBot.Visual.OnOpen()"')
    widget('button','rxShield',[f'action "{V}.AbsorbClick()"'],'0 0 99999 99999')
    widget('button','rxDismiss',[f'action "{V}.Close()"','on escape'],'0 0 0 0')
    for i in range(1,41):
        widget('label',f'rxFrame{i}',[f'enabled "{V}.FrameVisible({i})"',f'bam lua "{V}.Frame({i})"','sequence 0','frame 0','scaleToClip','ignoreEvents'])
        if i==1:
            for skin,rgba in [(0,'6 3 3 120'),(1,'16 13 10 178'),(2,'8 8 8 150')]:widget('label','rxWell'+str(skin),[f'enabled "{V}.SkinIndex()=={skin}"','fill '+rgba,'ignoreEvents'])
    widget('label','rxTick',[f'enabled "{V}.Tick()"'],'0 0 0 0')
    for name,view,text in [('Buffs','dashboard','Buffs'),('Summary','summary','Summary'),('Order','order','Order')]:
        button('rx'+name,f"{V}.ChangeView('{view}')",f"{P}.Text('{text}')",'RGDSBUT2',frame=f"{U}.view=='{view}' and 2 or 0",style='tab')
    button('rxPreset',f"{V}.ToggleChoices('presets')")
    label('rxPresetText',f'{V}.PresetText()','tab');glyph('rxPresetChevron','dropdown')
    button('rxNew',f'{U}.CreatePreset()',bam='RGDXBT1',seq='5',extra=[f'tooltip lua "{P}.Text(\'New preset\')"'])
    button('rxOptions',f"{V}.ToggleChoices('settings')",bam='RGDXBT1',seq='4',extra=[f'tooltip lua "{P}.Text(\'Options\')"'])
    button('rxClose',f'{V}.Close()',bam='RGDBTCLS',extra=[f'tooltip lua "{P}.Text(\'Close\')"'])
    if stage>=2:buffs()
    if stage>=3:summary()
    if stage>=4:order_page()
    if stage>=7:empty_states()
    button('rxRest',f"{V}.ToggleChoices('rest')")
    widget('label','rxRestIcon',['bam "RGDXBT1"','sequence 7','frame 0','scaleToClip','ignoreEvents'])
    label('rxRestText',f'{V}.RestText()','button');glyph('rxRestChevron','dropdown')
    label('rxStatus','bbPartyStatus','small');label('rxFeedback','bbPartyFeedback','small')
    button('rxAdd',f"{U}.OpenChoices('add')",f"{P}.Text('Add spell / item')",enabled=f'{U}.IsDashboard()')
    button('rxHidden',f"{U}.OpenChoices('hidden')",f"{P}.Text('Hidden')",enabled=f'{U}.IsDashboard()')
    button('rxCast',f'{U}.Cast()',f"{P}.Text('Cast')",'RGDBUTS3',enabled=f'{U}.CanCast()',style='tab')
    button('rxStop',f'{V}.Stop()',f"{P}.Text('Stop')",'RGDBUTS3',frame='2',enabled="BfBot.Exec.GetState()=='running'",style='tab')
    emit('}')
    if stage>=5:menus()
    if stage>=6:dialogs()
    output='\n'.join(lines)+'\n'
    controls={'RGDSBUT2':'BFBTAB','RGDMBUT2':'BFBPLAT','RGDBUTS3':'BFBCAST','RGDBTCLS':'BFBCLOSE','RGDXBT1':'BFBACT','RGDSRCH1':'BFBSEAR','RGDSLOTD':'BFBWELL','RGDSLOT':'BFBSLOT','RGDMBOXC':'BFBCORN','RGDSCRL1':'BFBSCRL','RGDCHEC':'BFBCHK'}
    for original,private in controls.items():output=output.replace(original,private)
    for axis,private in [('G','BFBRAH'),('F','BFBRAV')]:
        output=output.replace('mosaic lua "\'RGDBOX'+axis+'\'..BfBot.Visual.SkinIndex()"', 'bam "'+private+'"\n sequence lua "BfBot.Visual.SkinIndex()"\n frame 0')
    (ROOT/'buffbot/BfBotRx.menu').write_text(output,encoding='utf-8')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--stage',type=int,default=9);main(p.parse_args().stage)
