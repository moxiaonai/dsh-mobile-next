"""Description-led redraw, not a tracing of the unavailable chat attachment.
Only this directory is written. Chrome renders the actual SVG masters.
"""
from pathlib import Path
import hashlib, json, subprocess, os
from PIL import Image, ImageDraw, ImageFont
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
WORKSPACE = ROOT.parents[2]
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
# Broad, near-circular body; upward right-hand forked tail. No eye or mouth.
BODY = 'M 230 365 C 277 320 343 298 409 302 C 532 298 618 363 667 432 C 725 409 764 352 764 301 C 714 285 679 247 681 205 C 725 231 764 233 800 206 C 818 247 844 275 894 260 C 887 316 855 351 811 358 C 794 467 739 522 711 585 C 689 659 654 715 597 758 C 516 820 416 837 333 803 C 225 759 176 657 178 545 C 178 464 189 406 230 365 Z'
BELLY = 'M 150 530 C 246 509 309 547 353 593 C 408 650 486 675 579 653 C 545 729 473 781 386 779 C 279 778 190 702 155 603 Z'
# Custom outline lettering: N E X T, no live fonts and no font dependency.
LETTERS = [
'M 0 28 V 0 H 5 L 19 19 V 0 H 24 V 28 H 19 L 5 9 V 28 Z',
'M 34 0 H 54 V 5 H 39 V 11 H 52 V 16 H 39 V 23 H 54 V 28 H 34 Z',
'M 64 0 H 70 L 77 10 L 84 0 H 90 L 80 14 L 90 28 H 84 L 77 18 L 70 28 H 64 L 74 14 Z',
'M 100 0 H 124 V 5 H 114.5 V 28 H 109.5 V 5 H 100 Z']

def mark(fg, bg):
    # Belly is an even-odd transparent cutout, not painted white.
    lettering = ''.join(f'<path d="{p}"/>' for p in LETTERS)
    return f'''<defs><mask id="whale-cutout" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><path fill="#ffffff" d="{BODY}"/><path fill="#000000" d="{BELLY}"/></mask></defs><g fill="{fg}"><rect width="1024" height="1024" mask="url(#whale-cutout)"/>
    <g aria-label="NEXT" transform="translate(698 143)"><rect x="-20" y="-15" width="164" height="58" rx="15" fill="{bg}" stroke="{fg}" stroke-width="3"/>{lettering}</g></g>'''

def svg(fg, bg, opaque=False):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc"><title id="title">Monochrome whale — NEXT</title><desc id="desc">Round whale silhouette with a broad belly cutout, raised right tail and small NEXT corner badge.</desc>{f'<rect width="1024" height="1024" fill="{bg}"/>' if opaque else ''}{mark(fg,bg)}</svg>'''

# Protect every existing workspace file, including the rejected designs.
def inventory():
    result = {}
    skip = {'node_modules', '.git', '.dart_tool', 'build', '.gradle', 'Pods', '.next', '.venv'}
    for directory, dirs, files in os.walk(WORKSPACE):
        dirs[:] = [n for n in dirs if n not in skip and Path(directory)/n != ROOT]
        for name in files:
            p = Path(directory)/name
            if p.is_symlink(): continue
            result[str(p.relative_to(WORKSPACE))] = hashlib.sha256(p.read_bytes()).hexdigest()
    return result
before = inventory()
for name,fg,bg in [('black','#000000','#ffffff'),('white','#ffffff','#000000')]:
    (ROOT/f'logo-{name}.svg').write_text(svg(fg,bg))
    (ROOT/f'app-icon-{name}-1024.svg').write_text(svg(fg,bg,True))

# Render both actual vector masters at 2x resolution in one local page.
html = '<!doctype html><html><head><meta charset="utf-8"><style>*{box-sizing:border-box}html,body{margin:0;width:4096px;height:2048px;overflow:hidden}body{display:flex}img{display:block;width:2048px;height:2048px}</style></head><body><img src="app-icon-black-1024.svg" alt="Black whale"><img src="app-icon-white-1024.svg" alt="White whale"></body></html>'
(ROOT/'render.html').write_text(html)
subprocess.run([CHROME,'--headless','--disable-gpu','--no-sandbox','--hide-scrollbars',f'--user-data-dir={ROOT / "chrome-profile"}','--allow-file-access-from-files','--force-device-scale-factor=1','--window-size=4096,2048',f'--screenshot={ROOT / "render-2x.png"}',(ROOT/'render.html').as_uri()],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
render = Image.open(ROOT/'render-2x.png').convert('RGB')
assert render.size == (4096,2048), render.size
icons = {}
for i,name in enumerate(['black','white']):
    icons[name] = render.crop((i*2048,0,(i+1)*2048,2048)).resize((1024,1024),Image.Resampling.LANCZOS)
    icons[name].save(ROOT/f'app-icon-{name}-1024.png')

# Neutral, editorial comparison; no phone frames, gradients or shadows.
preview = Image.new('RGB',(1800,1360),'#eeeeee')
d = ImageDraw.Draw(preview)
FONT = '/System/Library/Fonts/Helvetica.ttc'
def font(size): return ImageFont.truetype(FONT,size)
def text(x,y,s,size=24,color='#000000'): d.text((x,y),s,font=font(size),fill=color)
text(72,48,'Whale / NEXT',58)
text(74,126,'MONOCHROME   /   ONE SILHOUETTE   /   TWO POLARITIES',21,'#555555')
for x,name,title,subtitle in [(72,'black','BLACK ON WHITE','Recommended primary'),(936,'white','WHITE ON BLACK','Inverse / dark surfaces')]:
    text(x,198,title,27)
    text(x,238,subtitle,21,'#555555')
    preview.paste(icons[name].resize((792,792),Image.Resampling.LANCZOS),(x,284))
text(74,1110,'Actual raster sizes',23)
for offset,name in [(72,'black'),(936,'white')]:
    cursor=offset
    for size in [32,48,64,96,128]:
        preview.paste(icons[name].resize((size,size),Image.Resampling.LANCZOS),(cursor,1160))
        text(cursor,1302,str(size)+' px',17,'#555555')
        cursor += size+40
preview.save(ROOT/'visual-preview.png')

# Check XML, strict grayscale, opacity and no file changes outside this directory.
checks = {}
for path in ROOT.glob('*.svg'):
    ET.parse(path)
for name,img in icons.items():
    r,g,b = img.split()
    assert r.tobytes()==g.tobytes()==b.tobytes()
    assert img.size==(1024,1024)
    checks[name]={'size':[1024,1024],'mode':img.mode,'opaque':True,'grayscale':True,'sha256':hashlib.sha256((ROOT/f'app-icon-{name}-1024.png').read_bytes()).hexdigest()}
after = inventory()
changed = [p for p in set(before)|set(after) if before.get(p)!=after.get(p)]
if changed:
    (ROOT/'integrity-delta.json').write_text(json.dumps(changed,indent=2))
assert before==after, f'Unexpected changes outside output directory: {changed}'
(ROOT/'validation.json').write_text(json.dumps({'renderer':'Chrome headless; 2048px per icon -> Lanczos 1024px','icons':checks,'svg_xml':'valid','files_outside_output_unchanged':True,'protected_existing_file_count':len(before),'source_reference':'Unavailable chat attachment; description-led redraw, not exact reproduction','small_size_limit':'NEXT is secondary; not fully readable at 32–48px. Use unbadged whale for very small UI glyphs.','platform_test':'Visual only, not installed on iOS or Android'},indent=2))
print(json.dumps({'output':str(ROOT),'verified':checks,'protected_files':len(before)},indent=2))
