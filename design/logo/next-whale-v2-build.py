#!/usr/bin/env python3
"""Original next-whale vector construction and lossless PNG exports. No app writes."""
from pathlib import Path
import hashlib, json, subprocess, xml.etree.ElementTree as ET
from PIL import Image, ImageDraw, ImageFont
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'design/logo/next-whale-v2'
OUT.mkdir(exist_ok=True)
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
BLUE = '#4D6BFE'
# A single closed silhouette, not overlapping even-odd body/tail primitives.
BODY = 'M78 119 C63 111 51 95 49 79 C38 82 28 80 19 73 C21 95 35 111 54 115 C40 120 30 130 24 143 C46 147 67 139 78 128 C87 152 104 170 126 178 C127 187 130 194 137 200 C148 196 157 187 160 179 C190 180 215 165 227 143 C240 118 225 98 197 93 C166 87 141 94 119 108 C102 118 89 123 78 119 Z'
# Sweeping belly negative space terminates in a clear next chevron.
BELLY = 'M113 145 C137 159 169 163 189 149 L177 140 L207 145 L194 170 L191 160 C168 178 136 168 113 154 Q107 150 113 145 Z'
EYE = 'M211 121 A5 5 0 1 0 201 121 A5 5 0 1 0 211 121 Z'
PATH = BODY + ' ' + BELLY + ' ' + EYE

def wrap(content, title, size=1024, vb='0 0 256 256'):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="{vb}" role="img" aria-labelledby="title"><title id="title">{title}</title>{content}</svg>\n'
def whale(color=BLUE, transform=''):
    return f'<path fill="{color}" fill-rule="evenodd" d="{PATH}"'+(f' transform="{transform}"' if transform else '')+'/>'
def svg_write(name, text):
    p = OUT / name
    p.write_text(text)
    ET.fromstring(text)
    return p

def render(source, target):
    # Dedicated local profile; browser is used only as an SVG rasterizer.
    html = OUT / 'render-local.html'
    html.write_text('<!doctype html><html><head><style>html,body{margin:0;width:1024px;height:1024px;background:transparent}svg{display:block;width:1024px;height:1024px}</style></head><body>'+source.read_text()+'</body></html>')
    cmd = [CHROME,'--headless=new','--disable-gpu','--no-sandbox','--no-first-run','--no-default-browser-check','--disable-background-networking','--hide-scrollbars','--force-device-scale-factor=1','--default-background-color=00000000','--window-size=1024,1024',f'--user-data-dir={OUT / "chrome-render-profile"}',f'--screenshot={target}',html.as_uri()]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
    if r.returncode or not target.exists():
        raise RuntimeError(r.stderr[-3000:])
    im = Image.open(target)
    assert im.size == (1024,1024), im.size

project = ROOT / 'dsh-mobile-next'
def snapshot():
    return {str(p.relative_to(project)):hashlib.sha256(p.read_bytes()).hexdigest() for p in project.rglob('*') if p.is_file()}
before = snapshot()
(OUT / 'project-hashes-before.json').write_text(json.dumps(before,indent=2))
for name, color in [('a-forward-whale-blue.svg',BLUE),('a-forward-whale-black.svg','#111827'),('a-forward-whale-white.svg','#FFFFFF')]:
    svg_write(name, wrap(whale(color),'Forward whale — original brand mark'))
# Full-bleed square, no pre-applied platform corner mask, no alpha.
svg_write('a-app-icon-1024.svg',wrap('<rect width="256" height="256" fill="'+BLUE+'"/>'+whale('#FFFFFF','translate(20 5) scale(.84)'), 'dsh-mobile-next / Forward whale / App icon'))
# B reinforces mobile explicitly with a portrait device silhouette and home bar.
PHONE = '<rect x="55" y="26" width="146" height="204" rx="32" fill="none" stroke="{color}" stroke-width="12"/><rect x="106" y="207" width="44" height="7" rx="3.5" fill="{color}"/>'
bmark = PHONE.format(color=BLUE)+whale(BLUE,'translate(64 56) scale(.50)')
svg_write('b-pocket-whale-blue.svg',wrap(bmark,'Pocket whale — mobile-first brand mark'))
svg_write('b-app-icon-1024.svg',wrap('<rect width="256" height="256" fill="'+BLUE+'"/>'+PHONE.format(color='#FFFFFF')+whale('#FFFFFF','translate(64 56) scale(.50)'), 'dsh-mobile-next / Pocket whale / App icon'))
for stem in ['a-forward-whale-blue','a-forward-whale-black','a-app-icon-1024','b-pocket-whale-blue','b-app-icon-1024']:
    render(OUT / (stem+'.svg'),OUT / (stem+'.png'))
# Use actual raster exports for visual presentation and small-size checks.
FONT='/System/Library/Fonts/Helvetica.ttc'
def font(n): return ImageFont.truetype(FONT,n)
board=Image.new('RGB',(1800,1250),'#F1F4FA'); d=ImageDraw.Draw(board)
def text(x,y,s,n=24,c='#18243B'): d.text((x,y),s,font=font(n),fill=c)
def paste_icon(im,xy,size,radius=0):
    im=im.resize((size,size),Image.Resampling.LANCZOS).convert('RGBA')
    if radius:
        mask=Image.new('L',(size,size)); ImageDraw.Draw(mask).rounded_rectangle((0,0,size-1,size-1),radius,fill=255); im.putalpha(mask)
    board.paste(im,xy,im)
text(72,54,'dsh mobile next',64); text(76,136,'Original whale geometry. Mobile scale. Forward motion.',27,'#55617A')
for x,label,desc,stem,mark in [(72,'A / Forward whale','Recommended / one silhouette, one forward cut','a-app-icon-1024','a-forward-whale-blue'),(936,'B / Pocket whale','Alternative / mobile frame, same whale DNA','b-app-icon-1024','b-pocket-whale-blue')]:
    d.rounded_rectangle((x,211,x+792,938),24,fill='white')
    text(x+32,244,label,34); text(x+32,296,desc,21,'#55617A')
    paste_icon(Image.open(OUT/(stem+'.png')),(x+40,359),360,80)
    paste_icon(Image.open(OUT/(mark+'.png')),(x+450,397),270)
    text(x+451,695,'Vector brand mark',21,'#55617A')
    text(x+32,767,'Actual downsample / 16   24   32   48   64 px',22,'#55617A')
    sx=x+40
    for size in [16,24,32,48,64]:
        paste_icon(Image.open(OUT/(stem+'.png')),(sx,829+(64-size)//2),size,max(3,size//5)); sx+=size+40
text(76,1000,'DeepSeek blue',28); d.rounded_rectangle((76,1050,142,1116),12,fill=BLUE); text(164,1066,BLUE,28)
text(465,1000,'Direction',28); text(465,1054,'Right-facing head + swept belly arrow',23,'#55617A')
text(1100,1000,'Production master',28); text(1100,1054,'1024 x 1024 / opaque / square',23,'#55617A')
text(76,1176,'Corner masks are presentation only. Uploaded black reference was not available in this session.',20,'#55617A')
board.save(OUT/'visual-preview.png')
# A dark/light proof and rounded/circular platform mask simulation.
proof=Image.new('RGB',(1400,720),'#F1F4FA'); pd=ImageDraw.Draw(proof)
pd.text((50,32),'Forward whale / contrast and mask proof',font=font(34),fill='#18243B')
for x,bg,label in [(50,'#FFFFFF','Blue on light'),(400,'#101B35','White on dark')]:
    pd.rounded_rectangle((x,100,x+300,450),24,fill=bg)
    mark=Image.open(OUT/'a-forward-whale-blue.png').convert('RGBA').resize((270,270),Image.Resampling.LANCZOS)
    if bg!='#FFFFFF':
        white=Image.new('RGBA',mark.size,'white'); white.putalpha(mark.getchannel('A')); mark=white
    proof.paste(mark,(x+15,120),mark)
    pd.text((x+15,405),label,font=font(20),fill='#55617A' if bg=='#FFFFFF' else '#DDE5FF')
icon=Image.open(OUT/'a-app-icon-1024.png').convert('RGB')
for x,circle,label in [(750,False,'Rounded-square preview'),(1090,True,'Circular crop preview')]:
    im=icon.resize((260,260),Image.Resampling.LANCZOS); mask=Image.new('L',(260,260)); md=ImageDraw.Draw(mask)
    if circle: md.ellipse((0,0,259,259),fill=255)
    else: md.rounded_rectangle((0,0,259,259),58,fill=255)
    proof.paste(im,(x,120),mask); pd.text((x,410),label,font=font(19),fill='#55617A')
pd.text((50,520),'Small sizes, shown at actual pixels (not enlarged)',font=font(26),fill='#18243B')
x=60
for size in [16,24,32,48,64,128]:
    im=icon.resize((size,size),Image.Resampling.LANCZOS); proof.paste(im,(x,574+(128-size)//2)); pd.text((x,550),str(size),font=font(16),fill='#55617A'); x+=size+62
proof.save(OUT/'visual-quality-proof.png')
after=snapshot()
assert before==after,'Application tree changed during design generation'
report={'project':str(project),'application_files_checked':len(before),'application_content_unchanged':True,'reference_limit':'Uploaded black whale image not attached or found in accessible project/reference files. Original redraw follows whale brand vocabulary, not exact source tracing.','checks':[]}
for p in sorted(OUT.glob('*.png')):
    im=Image.open(p); item={'file':str(p),'size':im.size,'mode':im.mode,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
    if 'app-icon' in p.name:
        assert im.size==(1024,1024)
        if im.mode=='RGBA': assert im.getchannel('A').getextrema()==(255,255)
        item['opaque']=True
    report['checks'].append(item)
(OUT/'validation.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
