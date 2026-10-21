"""Build modular design resources; never modifies a game or UI++ installation.

Frame placement and alternating/cropped tiles reuse Inventory Redux's renderer
(inventory/design/build_menu.py) and the designer's build_skin.py manifests.
Private controls are rebuilt from the supplied PNG exports for standalone use.
UI++ installation files are never read or modified by this builder.
"""
from pathlib import Path
import argparse, hashlib, json, math, struct
from PIL import Image
from visual_codec import encode_bam, encode_page

ROOT=Path(__file__).resolve().parents[1]

def frame_image(folder, key, manifest):
    """Remove inventory-only decoration from BuffBot's private frame copies."""
    def load(name):return Image.open(folder/(name+'.png')).convert('RGBA')
    image=load(key)
    if manifest['theme']!='sod':return image
    if key=='fill-interior':
        # The delivered native interior includes bottom inventory plates and
        # ornament tips at its edges. Sample only uninterrupted interior art.
        w,h=image.size
        return image.crop((round(w*.04),round(h*.04),round(w*.96),round(h*.94))).resize(image.size,Image.Resampling.LANCZOS)
    if key=='frame-corner-tl':
        # Join the existing rails instead of covering the tabs with a dragon.
        w,h=image.size; ix=manifest['nativeInner'][0]
        clean=Image.new('RGBA',image.size)
        side=load('frame-edge-left');top=load('frame-edge-top')
        clean.paste(side.crop((0,0,side.width,h-32)),(0,32))
        clean.paste(top.crop((0,0,w-(ix-38),top.height)),(ix-38,0))
        return clean
    if key in {'frame-corner-bl','frame-corner-br'}:
        # These native corners retain red gold/weight plates. Continue the
        # clean bottom rail through that region, preserving the outer corners.
        native=manifest['pieces'][key]['native'];ix0,_,ix1,_=manifest['nativeInner']
        tile=load('frame-edge-bottom-tile'); y=manifest['pieces']['frame-edge-bottom-tile']['native'][1]-native[1]
        x0,x1=(ix0-native[0],image.width) if key.endswith('bl') else (0,ix1-native[0])
        image.paste(tile.crop((0,0,x1-x0,image.height-y)),(x0,y))
    return image

def lua(v):
    if isinstance(v,dict):return '{'+','.join('['+lua(k)+']='+lua(x) for k,x in v.items())+'}'
    if isinstance(v,list):return '{'+','.join(map(lua,v))+'}'
    if isinstance(v,str):return json.dumps(v,ensure_ascii=False)
    if isinstance(v,bool):return str(v).lower()
    return str(v)

def build(package):
    out=ROOT/'buffbot/visual';out.mkdir(exist_ok=True)
    page=88700; cache={};frames={};glyphs={};written=set()
    def pages_write(pages):
        for n,b in pages.items():
            name=f'MOS{n:04d}.PVRZ';(out/name).write_bytes(b);written.add(name)
    def asset(im):
        nonlocal page
        raw=im.tobytes()+str(im.size).encode();key=hashlib.sha256(raw).hexdigest()
        if key in cache:return cache[key]
        ref='BV'+key[:6].upper();bam,pages=encode_bam(im,page);page+=len(pages)
        (out/(ref+'.BAM')).write_bytes(bam);written.add(ref+'.BAM');pages_write(pages);cache[key]=ref;return ref
    def cycles(ref,images):
        nonlocal page
        flattened=[im for cycle in images for im in cycle];nf=len(flattened);nc=len(images)
        fo=32;co=fo+nf*12;bo=co+nc*4;blocks=[];entries=[]
        for im in flattened:
            encoded,pages=encode_bam(im,page)
            _,_,count,_,_,offset=struct.unpack_from('<6I',encoded,8)
            entries.append(struct.pack('<HHhhHH',*im.size,0,0,len(blocks),count))
            pages_write(pages);page+=len(pages)
            blocks.extend(encoded[offset+i*28:offset+(i+1)*28] for i in range(count))
        lookup=[];start=0
        for cycle in images:lookup.append(struct.pack('<HH',len(cycle),start));start+=len(cycle)
        (out/(ref+'.BAM')).write_bytes(b'BAM V2  '+struct.pack('<6I',nf,nc,len(blocks),fo,co,bo)+b''.join(entries+lookup+blocks));written.add(ref+'.BAM')
    def load(p):return Image.open(p).convert('RGBA')
    for size,density,width,height in [('compact',1.5,1280,720),('wide',1,1920,1080)]:
      for variant in ['buffs','list']:
       for skin in ['sod','iwd','bg1','bg2']:
        folder=package/f'assets/frames/{size}-{variant}/{skin}'
        manifest=json.loads((folder/'manifest.json').read_text());pieces=manifest['pieces'];rows=[]
        def add(im,r):rows.append({'res':asset(im),'rect':r})
        add(frame_image(folder,'fill-interior',manifest),[48,78,width-96,height-116])
        ix0,iy0,ix1,iy1=manifest['nativeInner'];cw,ch=pieces['frame-corner-tl']['native'][2:]
        native_width=pieces['frame-corner-tr']['native'][2]
        x=48-ix0*.59+cw*.59;end=width-48-ix1*.59+(native_width-cw)*.59
        box=pieces['frame-edge-bottom-tile']['native'];tw=round((box[2]-box[0])*.59*density)/density;th=round((box[3]-box[1])*.59*density)/density
        specs=[('frame-edge-bottom-tile',x,height-38-8*.59,end,tw,th)]
        if 'frame-band-tile' in pieces:
            im=load(folder/'frame-band-tile.png');specs.append(('frame-band-tile',40,38,width-40,im.width/density,40))
        for stem,x,y,end,tw,th in specs:
            n=0
            while x<end:
                im=load(folder/(stem+'.png')).resize((round(tw*density),round(th*density)),Image.Resampling.LANCZOS)
                if n%2:im=im.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
                crop=min(im.width,math.ceil((end-x)*density));im=im.crop((0,0,crop,im.height))
                add(im,[int(x*density)/density,round(y*density)/density,crop/density,th]);x+=max(2/density,tw-1/density);n+=1
        for key,piece in sorted(pieces.items(),key=lambda kv:('corner' in kv[0],kv[0])):
            if 'imageAt' in piece:add(frame_image(folder,key,manifest),[v/density for v in piece['imageAt']+piece['size']])
        # The exact section-rim path used by Inventory Redux (BG2 nine-slice,
        # other skins rail strips); compose this one well, not a panel bitmap.
        wx,wy,ww,wh=60,128 if variant=='buffs' else 88,width-120,height-(218 if variant=='buffs' else 178)
        if 'section-rail' in pieces:
            rim=pieces['section-rail'];strip=load(folder/'section-rail-strip.png');t=rim['thicknessLogical']
            # The well uses the native DSL fill primitive. Black semitransparent
            # BAMs do not produce the same darkening in the UI BAM render path.
            add(strip,[wx-2,wy-2,ww+4,t]);add(strip.transpose(Image.Transpose.FLIP_TOP_BOTTOM),[wx-2,wy+wh+2-t,ww+4,t])
            v=strip.rotate(90,expand=True);add(v,[wx-2,wy-2,t,wh+4]);add(v.transpose(Image.Transpose.FLIP_LEFT_RIGHT),[wx+ww+2-t,wy-2,t,wh+4])
        else:
            import runpy
            nine=runpy.run_path(str(package/'source/tools/build_skin.py'),run_name='renderer')['nine_slice']
            rim=pieces['section-rim'];im=nine(load(folder/'section-rim-source.png'),rim['insetsNative'],round((ww+6)*density),round((wh+6)*density),.59*density*.8)
            add(im,[wx-3,wy-3,ww+6,wh+6])
        frames[f'{size}-{variant}-{skin}']=rows
    cycles('BFBARROW',[[load(package/f'assets/shared/arrow-{direction}-{state}.png') for state in ['normal','pressed']] for direction in ['up','down']])
    files=sorted((package/'assets/glyphs/png16').glob('*.png'))
    files=[p for p in files if not p.stem.endswith('-white')]
    for i,p in enumerate(files):glyphs[p.stem]=i
    cycles('BFBGLYPH',[[load(p)] for p in files])
    # Private control resources make the four skins independent of UI++.
    skin_names=['sod','iwd','bg1','bg2']
    def skinned(ref,names):
        cycles(ref,[[load(package/'assets/controls'/skin/(n+'.png')) for n in names] for skin in skin_names])
    states=['normal','pressed','selected','disabled']
    skinned('BFBTAB',['tab-'+s for s in states])
    skinned('BFBPLAT',['button-'+s for s in states])
    skinned('BFBCAST',['button-tall-'+s for s in states])
    for ref,name in [('BFBCLOSE','close'),('BFBSEAR','search'),('BFBWELL','plate'),('BFBRAH','popup-rail-h'),('BFBRAV','popup-rail-v')]:
        skinned(ref,[name])
    skinned('BFBSLOT',['slot','slot','slot-active'])
    skinned('BFBCORN',['popup-corner-tl','popup-corner-br'])
    for i,skin in enumerate(skin_names):
        cycles('BFBCHK'+str(i),[[load(package/'assets/controls'/skin/('check-'+state+suffix+'.png')) for suffix in ['', '-pressed']] for state in ['on','off','disabled']])
    cycles('BFBACT',[[load(package/'assets/shared'/('action-'+name+'-'+s+'.png')) for s in ['normal','pressed','hover','disabled']] for name in ['party','remove','rename','hide','options','add','caster','rest']])
    cycles('BFBSCRL',[[load(package/'assets/shared'/(name+'.png')) for name in ['scroll-up','scroll-up-pressed','scroll-down','scroll-down-pressed','scroll-thumb','scroll-track']]])
    theme=json.loads((package/'tokens/theme.json').read_text())
    data={'frames':frames,'glyphs':glyphs,'theme':theme,'lastPage':page-1}
    (ROOT/'buffbot/BfBotVD.lua').write_text('-- Generated by tools/build_visual_design.py; do not edit.\nBfBot.VisualData='+lua(data)+'\n',encoding='utf-8')
    for p in out.iterdir():
        if p.suffix.upper() in {'.BAM','.PVRZ'} and p.name not in written:
            assert p.resolve().parent==out.resolve() and (p.stem.startswith(('BV','MOS88')) or p.stem.startswith('BFB'))
            p.unlink()
    (ROOT/'buffbot/BfBotVA.json').write_text(json.dumps({'pageRange':[88700,page-1],'resources':sum(n.endswith('.BAM') for n in written),'glyphCycles':glyphs,
        'files':sorted(written),'sha256':{n:hashlib.sha256((out/n).read_bytes()).hexdigest() for n in sorted(written)}},indent=2))
    print(f'Built {len(cache)+2} modular resources, pages 88700–{page-1}')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('package',type=Path,nargs='?',default=ROOT.parent/'buffbot-redux-design');build(p.parse_args().package)
