"""Assemble the local review gallery without changing screenshot pixels."""
from pathlib import Path
from html import escape
import hashlib
import json
import shutil
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'docs/visual-review'
SHOTS=OUT/'screenshots'
PACKAGE=ROOT.parent/'buffbot-redux-design'

def build():
    # Sky returns JPEG captures; early checkpoints used the wrong extension.
    # Rename their original bytes, without re-encoding or cropping the evidence.
    for path in SHOTS.glob('*.png'):
        if path.read_bytes()[:3]==b'\xff\xd8\xff':
            dest=path.with_suffix('.jpg')
            if dest.exists():
                assert dest.read_bytes()==path.read_bytes()
            else:
                path.rename(dest)
    refs=OUT/'references';refs.mkdir(exist_ok=True)
    for p in (PACKAGE/'previews/1x').glob('*.png'):
        shutil.copyfile(p,refs/p.name)
    mapping={'buffs':'00-Buffs','summary':'01-Summary','order':'02-Order',
      'preset-menu':'06-MenuPreset','options-menu':'07-MenuOptions','after-rest-menu':'08-MenuAfterRest',
      'caster-picker':'09-PickCaster','self-caster':'10-PickCasterSelf','rename-dialog':'11-DlgRename',
      'new-dialog':'13-DlgNew','source-dialog':'14-DlgSource','shared-source-dialog':'15-DlgSourceShared',
      'add-dialog':'16-DlgAdd','empty-add':'17-DlgAddEmpty','hidden-dialog':'18-DlgHidden',
      'empty-hidden':'19-DlgHiddenEmpty','variants':'20-StVariants','empty-search':'22-StNoResults'}
    meta=[];cards=[]
    for p in sorted(p for p in SHOTS.iterdir() if p.suffix.lower() in ('.jpg','.png')):
        with Image.open(p) as im: size=list(im.size)
        entry={'file':p.name,'pixels':size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
        meta.append(entry)
        if p.stem.startswith('fix-'):
            group='User-reported fixes';reference=None
        elif p.stem.startswith('final-'):
            group='Final compact / states';key=p.stem[6:]
            skin=next((s for s in ('sod','bg1','iwd','bg2') if key.endswith('-'+s)),None)
            if skin:key=key[:-len(skin)-1]
            reference=mapping.get(key)
            if key=='buffs' and skin in ('bg1','iwd','bg2'):
                reference={'bg1':'31-SkinBG1Buffs','iwd':'30-SkinIWDBuffs','bg2':'32-SkinBG2Buffs'}[skin]
        elif p.stem.startswith('09-'):
            group='Final wide';key=p.stem[3:].split('-wide')[0];reference={'buffs':'03-BuffsWide','summary':'04-SummaryWide','order':'05-OrderWide'}.get(key)
        elif p.stem.startswith('walkthrough-'):
            group='Walkthrough';reference=None
        else:
            group='Earlier staged checkpoints';reference=None
        title=p.stem.replace('-',' ')
        refhtml=''
        if reference and (refs/(reference+'.png')).exists():
            refhtml=f'<details><summary>Matching design board</summary><img loading="lazy" src="references/{reference}.png" alt="Design reference"></details>'
        cards.append(f'<article data-group="{escape(group)}" data-name="{escape(title)}"><h2>{escape(title)}</h2><p>{group} · {size[0]} × {size[1]} pixels · original capture</p><a href="screenshots/{p.name}"><img loading="lazy" src="screenshots/{p.name}" alt="{escape(title)}"></a>{refhtml}</article>')
    (OUT/'capture-manifest.json').write_text(json.dumps(meta,indent=2),encoding='utf-8')
    html='''<!doctype html><meta charset="utf-8"><title>BuffBot Redux visual review</title>
<style>body{margin:30px auto;max-width:1500px;padding:0 24px;background:#171410;color:#eadfc8;font:16px system-ui}header{position:sticky;top:0;background:#171410f5;padding:14px 0;z-index:2}a{color:#e4bd70}select,input{background:#28231c;color:inherit;border:1px solid #84704a;padding:8px;margin-right:8px}article{border-top:1px solid #655338;padding:25px 0}h2{font-size:19px}article p{color:#b9aa90}img{display:block;max-width:100%;height:auto;margin:12px 0}summary{cursor:pointer;color:#d6bb7c}article[hidden]{display:none}</style>
<h1>BuffBot Redux — native visual review</h1><p>Captured from an isolated EET game. No screenshot pixels were edited. Compact captures include a 1280 × 720 client and native window chrome. This installation maps that client to a 1365 × 768 logical viewport. Original wide captures are 1920 × 1080 fullscreen; user-reported-fix captures also include the 2560px maximized desktop, with the fixed wide canvas centered.</p>
<p><a href="review.md">Review report, open-item answers and deviations</a> · <a href="capture-manifest.json">Capture hashes</a></p>
<header><select id="group"><option value="">All sections</option><option>User-reported fixes</option><option>Final compact / states</option><option>Final wide</option><option>Walkthrough</option><option>Earlier staged checkpoints</option></select><input id="filter" placeholder="Filter captures…"><span id="count"></span></header>
'''+''.join(cards)+'''<script>function filter(){let n=0;document.querySelectorAll('article').forEach(a=>{a.hidden=!!((group.value&&a.dataset.group!==group.value)||!a.dataset.name.includes(document.querySelector('#filter').value.toLowerCase()));if(!a.hidden)n++});count.textContent=n+' captures'}group.onchange=filter;document.querySelector('#filter').oninput=filter;filter()</script>'''
    (OUT/'index.html').write_text(html,encoding='utf-8')
    print(f'Built review gallery with {len(meta)} original captures')

if __name__=='__main__':build()
