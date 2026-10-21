"""Read installed loose SPLs through the real Lua classifier; no game process."""
from pathlib import Path
import argparse, hashlib, json, struct
from lupa.luajit21 import LuaRuntime

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('game',type=Path,help='Read-only game root with override and lang/en_US/dialog.tlk')
parser.add_argument('--output',required=True,type=Path,help='Output JSON evidence file')
args=parser.parse_args()
REPO=Path(__file__).resolve().parents[2]
GAME=args.game.resolve()
OUT=args.output.resolve()
OUT.parent.mkdir(parents=True,exist_ok=True)
lua=LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
    jit.off()
    BfBot={_cache={class={}},_overrides={},_Warn=function() end,_fields={
        fb_count='effectCount',fb_start='startingEffect',friendly_flags='type',
        fb_opcode='effectID',fb_timing='durationType',fb_duration='duration',
        fb_param1='effectAmount',fb_param2='dwFlags',fb_target='targetType',fb_res='res'}}
''')
lua.execute((REPO/'buffbot/BfBotCls.lua').read_text(encoding='utf-8'))
lua.execute((REPO/'buffbot/BfBotPln.lua').read_text(encoding='utf-8'))
lua.execute('''
    BfBot.Class._IterateFeatureBlocks=function(_,a,fn)
        for i,e in ipairs(a.effects) do if fn(e,i-1) then break end end
    end
    -- Selection-menu families are flagged and excluded from this root-score
    -- audit; reproducing native 2DA/BIF resolution is outside its scope.
    BfBot.Class._DetectVariants=function() return nil end
    function methods(h)
        h.getAbility=function(self,i) return self.abilities[i+1] end
        h.getAbilityForLevel=function(self,level)
            local selected
            for _,a in ipairs(self.abilities) do
                if a.minLevel<=level then selected=a end
            end
            return selected
        end
        return h
    end
''')
methods=lua.globals().methods
tlk=(GAME/'lang/en_US/dialog.tlk').read_bytes()
tlk_count,tlk_offset=struct.unpack_from('<II',tlk,10)
def name(index):
    if index>=tlk_count:return ''
    offset,size=struct.unpack_from('<II',tlk,18+index*26+18)
    return tlk[tlk_offset+offset:tlk_offset+offset+size].decode('utf-8',errors='replace')
headers={};hashes={};details={}
def read(resref,kind):
    resref=resref.upper()
    if kind!='SPL' or not resref or len(resref)>8 or any(c in resref for c in ('/',chr(92),':',chr(0))):return None
    if resref in headers:return headers[resref]
    p=GAME/'override'/(resref+'.SPL')
    if not p.is_file():return None
    d=p.read_bytes()
    if len(d)<0x72 or d[:8]!=b'SPL V1  ':return None
    ability_offset,count,effect_offset=struct.unpack_from('<IHI',d,0x64)
    if count>1024 or ability_offset+count*40>len(d):raise ValueError('Bad SPL abilities '+resref)
    abilities=[]
    for i in range(count):
        a=ability_offset+i*40
        fc,fs=struct.unpack_from('<HH',d,a+30)
        if effect_offset+(fs+fc)*48>len(d):raise ValueError('Bad SPL effects '+resref)
        effects=[]
        for j in range(fs,fs+fc):
            f=effect_offset+j*48
            op,target=struct.unpack_from('<HB',d,f)
            amount,flags=struct.unpack_from('<iI',d,f+4)
            effects.append(dict(effectID=op,targetType=target,effectAmount=amount,dwFlags=flags,
                                durationType=d[f+12],duration=struct.unpack_from('<I',d,f+14)[0],
                                res=d[f+20:f+28].split(b'\0')[0].decode('ascii',errors='replace')))
        abilities.append(dict(type=struct.unpack_from('<H',d,a)[0],actionType=d[a+12],
                              minLevel=struct.unpack_from('<H',d,a+16)[0],
                              effectCount=fc,startingEffect=fs,effects=effects))
    def convert(v):
        if isinstance(v,dict):return lua.table_from({k:convert(x)for k,x in v.items()})
        if isinstance(v,list):return lua.table_from([convert(x)for x in v])
        return v
    title=name(struct.unpack_from('<I',d,8)[0]) or resref
    h=methods(convert(dict(secondaryType=d[0x27],abilities=abilities)))
    headers[resref]=h;hashes[resref]=hashlib.sha256(d).hexdigest()
    details[resref]=dict(name=title,secondary_type=d[0x27],abilities=abilities)
    return h
lua.globals().EEex_Resource_Demand=read
rows=[]
paths=sorted(p for p in (GAME/'override').glob('SP*.SPL') if p.stem.upper().startswith(('SPWI','SPPR','SPIN')))
for p in paths:
    res=p.stem.upper();h=read(res,'SPL')
    if h is None:continue
    a=h.getAbilityForLevel(h,20) or h.getAbility(h,0)
    if a is None:continue
    lua.execute('BfBot._cache.class={}')
    r=lua.globals().BfBot.Class.Classify(res,h,a)
    chosen=next(x for x in details[res]['abilities'] if x['minLevel']==a.minLevel)
    selection=any(x['effectID']==214 for x in chosen['effects'])
    rows.append(dict(resource=res,name=details[res]['name'],secondary_type=h.secondaryType,
                     target=a.actionType,ability_level=a.minLevel,selection_menu_excluded=selection,
                     is_buff=bool(r.isBuff),automatic_catalog=bool(lua.globals().BfBot.Plan.IsAutomaticBuff(lua.table_from({'kind':'spl','class':r}))),
                     ambiguous=bool(r.isAmbiguous),friendly=bool(r.friendlyFlag),
                     self_only=bool(r.isSelfOnly),score=r.score,opcode_score=r.opcodeScore,
                     substantive=bool(r.hasSubstantive),offensive_metadata=bool(r.offensiveMetadata),
                     effects=[{k:x[k]for k in ('effectID','targetType','effectAmount','dwFlags','res')}for x in chosen['effects']],
                     sha256=hashes[res]))
payload=dict(method='Offline loose-SPL semantic adapter, production classifier, effective header at level 20; no BIF fallback or native process; selection-menu families excluded from comparison.',
             roots=len(rows),rows=rows,input_sha256=hashes)
OUT.write_text(json.dumps(payload,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
suspects=[r for r in rows if r['automatic_catalog'] and r['secondary_type'] in (4,10,11) and not r['self_only'] and not r['selection_menu_excluded']]
print(json.dumps(dict(roots=len(rows),remaining_review_candidates=len(suspects),filtered_by_policy=sum(r['is_buff'] and not r['automatic_catalog'] and not r['selection_menu_excluded'] for r in rows),examples=[{k:r[k]for k in ('resource','name','secondary_type','score')}for r in suspects[:24]]),ensure_ascii=True,indent=2))
