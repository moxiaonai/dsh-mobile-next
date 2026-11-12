#!/usr/bin/env python3
"""dsh-mobile-next brand mark generator.

Single source of truth for every SVG under design/logo/.
Run:  python3 generate.py     (needs headless Chrome only for bbox measurement)

Coordinate system: 1024 x 1024 design grid, no transforms, baked coordinates.
"""
import math, os, subprocess, sys, json

HERE   = os.path.dirname(os.path.abspath(__file__))
OUT    = os.path.dirname(HERE)                      # design/logo
LAYERS = os.path.join(OUT, 'layers')
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# ---------------------------------------------------------------- palette
INK    = '#0F172A'   # primary, light surfaces
BLUE   = '#4D6BFE'   # DeepSeek blue (brand)
DEEP   = '#3A56E0'   # pressed / dark-mode accent
LIGHT  = '#6C86FF'   # light-mode accent on dark
MIST   = '#A9B8FF'   # secondary / disabled
INKB   = '#2A3DBF'   # deep ink-blue, AA on white
WHITE  = '#FFFFFF'
PAPER  = '#F7F8FA'
TINT   = '#EEF2FF'   # 8% blue tint

# ---------------------------------------------------------------- primitives
def f(v, d=2):
    return f'{v:.{d}f}'

def P(c, r, deg):
    t = math.radians(deg)
    return (c[0] + r*math.cos(t), c[1] + r*math.sin(t))

def U(deg):
    t = math.radians(deg)
    return (math.cos(t), math.sin(t))

def AD(p, v, k=1.0):
    return (p[0] + v[0]*k, p[1] + v[1]*k)

def smooth(pts, closed=True, tension=1.0, d=2):
    n = len(pts)
    g = (lambda i: pts[i % n]) if closed else (lambda i: pts[max(0, min(n-1, i))])
    out = f'M{f(pts[0][0],d)} {f(pts[0][1],d)}'
    for i in range(n if closed else n-1):
        p0, p1, p2, p3 = g(i-1), g(i), g(i+1), g(i+2)
        c1 = (p1[0] + (p2[0]-p0[0])/6*tension, p1[1] + (p2[1]-p0[1])/6*tension)
        c2 = (p2[0] - (p3[0]-p1[0])/6*tension, p2[1] - (p3[1]-p1[1])/6*tension)
        out += (f'C{f(c1[0],d)} {f(c1[1],d)} {f(c2[0],d)} {f(c2[1],d)}'
                f' {f(p2[0],d)} {f(p2[1],d)}')
    return out + ('Z' if closed else '')

def round_poly(pts, radii, d=2):
    """Closed polygon with circular-arc corners (radius 0 = sharp vertex)."""
    n = len(pts); segs = []
    for i in range(n):
        pv, p, pn, r = pts[(i-1) % n], pts[i], pts[(i+1) % n], radii[i]
        v1 = (pv[0]-p[0], pv[1]-p[1]); l1 = math.hypot(*v1)
        v2 = (pn[0]-p[0], pn[1]-p[1]); l2 = math.hypot(*v2)
        u1 = (v1[0]/l1, v1[1]/l1); u2 = (v2[0]/l2, v2[1]/l2)
        cosang = max(-1.0, min(1.0, u1[0]*u2[0] + u1[1]*u2[1])); ang = math.acos(cosang)
        if r <= 0 or ang < 1e-3 or abs(ang-math.pi) < 1e-3:
            segs.append(('L', p)); continue
        cut = min(r/math.tan(ang/2), l1*0.5, l2*0.5)
        a = AD(p, u1, cut); b = AD(p, u2, cut); rr = cut*math.tan(ang/2)
        cross = u1[0]*u2[1] - u1[1]*u2[0]
        segs.append(('A', a, b, rr, 0 if cross > 0 else 1))
    out, first = '', True
    for s in segs:
        if s[0] == 'L':
            out += (f'M{f(s[1][0],d)} {f(s[1][1],d)}' if first
                    else f'L{f(s[1][0],d)} {f(s[1][1],d)}')
        else:
            out += (f'M{f(s[1][0],d)} {f(s[1][1],d)}' if first else '')
            out += (f'A{f(s[3],d)} {f(s[3],d)} 0 0 {s[4]}'
                    f' {f(s[2][0],d)} {f(s[2][1],d)}')
        first = False
    return out + 'Z'

def circle_path(c, r, d=2):
    return (f'M{f(c[0]-r,d)} {f(c[1],d)}'
            f'A{f(r,d)} {f(r,d)} 0 1 0 {f(c[0]+r,d)} {f(c[1],d)}'
            f'A{f(r,d)} {f(r,d)} 0 1 0 {f(c[0]-r,d)} {f(c[1],d)}Z')

def crescent(c, R, a0, a1, inset, w, d=2):
    """Closed crescent band hugging an arc, round caps -> belly knockout."""
    ro = R*(1-inset); ri = ro - R*w; cap = R*w/2
    p0, p1 = P(c, ro, a0), P(c, ro, a1)
    q0, q1 = P(c, ri, a0), P(c, ri, a1)
    return (f'M{f(p0[0],d)} {f(p0[1],d)}'
            f'A{f(ro,d)} {f(ro,d)} 0 0 0 {f(p1[0],d)} {f(p1[1],d)}'
            f'A{f(cap,d)} {f(cap,d)} 0 0 0 {f(q1[0],d)} {f(q1[1],d)}'
            f'A{f(ri,d)} {f(ri,d)} 0 0 1 {f(q0[0],d)} {f(q0[1],d)}'
            f'A{f(cap,d)} {f(cap,d)} 0 0 0 {f(p0[0],d)} {f(p0[1],d)}Z')

def dot(c, r, d=2):
    return (f'M{f(c[0]-r,d)} {f(c[1],d)}'
            f'A{f(r,d)} {f(r,d)} 0 1 0 {f(c[0]+r,d)} {f(c[1],d)}'
            f'A{f(r,d)} {f(r,d)} 0 1 0 {f(c[0]-r,d)} {f(c[1],d)}Z')

def lobe(O, axis, L, w, bow=0.0, N=18, root=0.55, tipk=0.10, d=2):
    """Tapered leaf lobe: spine is a quadratic bowing by `bow`*L, width tapers."""
    u = U(axis); n = (-u[1], u[0])
    tipP = AD(O, u, L); ctl = AD(AD(O, u, L*0.52), n, bow*L)
    left, right = [], []
    for i in range(N+1):
        t = i/N; q = 1-t
        p = (q*q*O[0] + 2*q*t*ctl[0] + t*t*tipP[0],
             q*q*O[1] + 2*q*t*ctl[1] + t*t*tipP[1])
        tg = (2*q*(ctl[0]-O[0]) + 2*t*(tipP[0]-ctl[0]),
              2*q*(ctl[1]-O[1]) + 2*t*(tipP[1]-ctl[1]))
        ln = math.hypot(*tg) or 1.0
        nv = (-tg[1]/ln, tg[0]/ln)
        ww = w*(root + (tipk-root)*(t**0.85))
        left.append(AD(p, nv, ww)); right.append(AD(p, nv, -ww))
    return smooth(left + right[::-1], True, 0.9, d)

def squircle(cx, cy, half, n=5.0, seg=30, d=2):
    """Apple-style superellipse |x|^n + |y|^n = 1 (n=5 approximates iOS).

    Sampled at `seg` points and joined with a centripetal-ish Catmull-Rom.
    Measured deviation from the analytic superellipse at half-width 512:
      seg=24 -> 2.52 px, seg=30 -> 1.58 px, seg=48 -> 0.94 px  (all < 0.5 % of R)
    """
    pts = []
    for i in range(seg):
        t = 2*math.pi*i/seg
        co, si = math.cos(t), math.sin(t)
        x = math.copysign(abs(co)**(2.0/n), co)
        y = math.copysign(abs(si)**(2.0/n), si)
        pts.append((cx + half*x, cy + half*y))
    return smooth(pts, True, 1.0, d)

# ---------------------------------------------------------------- geometry
# All concepts are described in a unit space: body centre (0,0), body radius 1.
# `fit()` rasterises once, measures the ink bbox, then rebakes at final size.

def chevron_tail(c, R, axis=-50.0, base_span=44.0,
                 tip1=(1.34, -62.0), tip2=(1.32, 58.0), notch=(0.94, 0.0),
                 tip_r=0.09, notch_r=0.15, d=2):
    """Concept A fluke: two lobes on a shared root, rounded tips, shallow V notch.
    The base is the body's own edge -> fluke reads as one continuous mass."""
    a1, a2 = axis-base_span, axis+base_span
    b1, b2 = P(c, R, a1), P(c, R, a2)
    T1 = P(c, R*tip1[0], axis+tip1[1])
    T2 = P(c, R*tip2[0], axis+tip2[1])
    N  = P(c, R*notch[0], axis+notch[1])
    # close the outline along the body's own edge, b2 -> b1 the short way
    delta = (a2 - a1) % 360
    large = 1 if delta > 180 else 0
    return (f'M{f(b1[0],d)} {f(b1[1],d)}'
            f'L{f(T1[0],d)} {f(T1[1],d)}'
            f'A{f(R*tip_r,d)} {f(R*tip_r,d)} 0 0 0 {f(N[0],d)} {f(N[1],d)}'
            f'A{f(R*notch_r,d)} {f(R*notch_r,d)} 0 0 0 {f(T2[0],d)} {f(T2[1],d)}'
            f'L{f(b2[0],d)} {f(b2[1],d)}'
            f'A{f(R,d)} {f(R,d)} 0 {large} 0 {f(b1[0],d)} {f(b1[1],d)}Z')

# ---- concept A : "Chevron" (recommended) ----
A = dict(axis=-50.0, base_span=44.0, tip1=(1.34, -62.0), tip2=(1.32, 58.0),
         notch=(0.94, 0.0), tip_r=0.09, notch_r=0.15,
         belly=(150.0, 30.0, 0.135, 0.175), eye=(206.0, 0.60, 0.090))

def concept_a(c, R, d=2, **over):
    o = dict(A); o.update(over)
    e = P(c, R*o['eye'][1], o['eye'][0])
    return ' '.join([
        circle_path(c, R, d),
        chevron_tail(c, R, o['axis'], o['base_span'], o['tip1'], o['tip2'],
                     o['notch'], o['tip_r'], o['notch_r'], d),
        crescent(c, R, *o['belly'], d=d),
        dot(e, R*o['eye'][2], d),
    ])

# ---- concept B : "Twin" (double chevron = next / next-next) ----
B = dict(axis=-58.0, splay=38.0, L=1.06, w=0.27, bow=0.14, sink=0.30,
         belly=(150.0, 30.0, 0.135, 0.175), eye=(206.0, 0.60, 0.090))

def concept_b(c, R, d=2, **over):
    o = dict(B); o.update(over)
    O = P(c, R, o['axis']); Oin = AD(O, U(o['axis']+180), R*o['sink'])
    parts = [circle_path(c, R, d)]
    for s in (-1, 1):
        parts.append(lobe(Oin, o['axis'] + s*o['splay'], R*o['L'], R*o['w'],
                          o['bow']*s, d=d))
    e = P(c, R*o['eye'][1], o['eye'][0])
    parts.append(crescent(c, R, *o['belly'], d=d))
    parts.append(dot(e, R*o['eye'][2], d))
    return ' '.join(parts)

# ---- concept C : "Orbit" (tail sweeping forward = momentum) ----
C = dict(axis=-30.0, splay=34.0, L=1.10, w=0.24, bow=-0.40, sink=0.54,
         belly=(150.0, 30.0, 0.135, 0.175), eye=(206.0, 0.60, 0.090))

def concept_c(c, R, d=2, **over):
    o = dict(C); o.update(over)
    O = P(c, R, o['axis']); Oin = AD(O, U(o['axis']+180), R*o['sink'])
    parts = [circle_path(c, R, d)]
    for s in (-1, 1):
        parts.append(lobe(Oin, o['axis'] + s*o['splay'], R*o['L'], R*o['w'],
                          o['bow']*s, d=d))
    e = P(c, R*o['eye'][1], o['eye'][0])
    parts.append(crescent(c, R, *o['belly'], d=d))
    parts.append(dot(e, R*o['eye'][2], d))
    return ' '.join(parts)

CONCEPTS = {'A': concept_a, 'B': concept_b, 'C': concept_c}

# ---------------------------------------------------------------- measuring / fitting
def render_png(html, out, w, h, bg='transparent'):
    doc = (f'<!doctype html><html><head><meta charset="utf-8"><style>'
           f'html,body{{margin:0;padding:0;background:{bg};}}'
           f'svg{{display:block}}</style></head><body>{html}</body></html>')
    p = os.path.join(HERE, '_tmp.html')
    open(p, 'w').write(doc)
    subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--no-sandbox',
                    f'--user-data-dir={HERE}/.chrome', '--hide-scrollbars',
                    '--force-device-scale-factor=1',
                    '--default-background-color=00000000',
                    f'--window-size={w},{h}', f'--screenshot={out}',
                    f'file://{p}'], capture_output=True)
    return out

def ink_bbox(path_d, pad=40, probe=900):
    """Rasterise the path on a padded probe canvas, return its ink bbox in user units."""
    vb = 1024 + 2*pad
    html = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{-pad} {-pad} {vb} {vb}"'
            f' style="width:{probe}px;height:{probe}px">'
            f'<path d="{path_d}" fill="#000" fill-rule="evenodd"/></svg>')
    png = os.path.join(HERE, '_probe.png')
    render_png(html, png, probe, probe)
    from PIL import Image
    bb = Image.open(png).convert('RGBA').split()[-1].getbbox()
    if bb is None:
        raise RuntimeError('empty mark')
    k = vb/float(probe)
    return tuple(v*k - pad for v in bb)

def fit_path(fn, target=800.0, cx=512.0, cy=512.0, dy=0.0, d=2, **over):
    """Bake `fn` at unit scale, measure ink, then rebake so the ink is `target` wide."""
    probe_c, probe_R = (512.0, 512.0), 300.0
    raw = fn(probe_c, probe_R, d=2, **over)
    x0, y0, x1, y1 = ink_bbox(raw)
    s = target/max(x1-x0, y1-y0)
    R = probe_R*s
    c = (cx - R*((x0+x1)/2 - probe_c[0])/probe_R,
         cy + dy - R*((y0+y1)/2 - probe_c[1])/probe_R)
    return fn(c, R, d=d, **over), (c, R, (x0, y0, x1, y1))

# ---------------------------------------------------------------- svg emitters
def _num(v):
    return str(int(v)) if float(v) == int(v) else f(v)

def svg_doc(body, w=1024, h=1024, vb=None, title='', desc=''):
    vb = vb or f'0 0 {_num(w)} {_num(h)}'
    t = f'<title>{title}</title>' if title else ''
    ds = f'<desc>{desc}</desc>' if desc else ''
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" '
            f'width="{_num(w)}" height="{_num(h)}" fill="none" role="img" '
            f'aria-label="{title or "dsh-mobile-next"}">\n'
            f'{t}{ds}\n{body}\n</svg>\n')

def write(name, content):
    p = os.path.join(OUT, name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'w').write(content)
    return p

# ---------------------------------------------------------------- outputs
def mark_svg(target=800.0, dy=-10.0, fill=INK, fn=concept_a,
             canvas=1024.0, cx=None, cy=None, title='', desc='', **over):
    cx = canvas/2 if cx is None else cx
    cy = canvas/2 if cy is None else cy
    d, meta = fit_path(fn, target=target, cx=cx, cy=cy, dy=dy, d=2, **over)
    body = (f'  <path fill="{fill}" fill-rule="evenodd" d="{d}"/>\n')
    return svg_doc(body, canvas, canvas, title=title, desc=desc), d, meta

def icon_svg(size=1024.0, bg=BLUE, fg=WHITE, mark_w=0.62, squircle_n=5.0,
             bg_full_bleed=True, title='', desc=''):
    """App icon: squircle plate + centred mark. `mark_w` is the mark's ink width / size."""
    half = size/2
    plate = squircle(half, half, half, n=squircle_n, seg=48, d=2)
    body = ''
    if bg_full_bleed:
        body += f'  <path fill="{bg}" d="{plate}"/>\n'
    d, meta = fit_path(concept_a, target=size*mark_w, cx=half, cy=half,
                       dy=-size*0.006, d=2)
    body += f'  <path fill="{fg}" fill-rule="evenodd" d="{d}"/>\n'
    return svg_doc(body, size, size, title=title, desc=desc), d, plate

def icon_layers(size=1024.0, mark_w=0.62, squircle_n=5.0):
    half = size/2
    plate = squircle(half, half, half, n=squircle_n, seg=48, d=2)
    d, meta = fit_path(concept_a, target=size*mark_w, cx=half, cy=half,
                       dy=-size*0.006, d=2)
    return plate, d, meta

def main():
    os.makedirs(LAYERS, exist_ok=True)
    made = []
    def w(name, txt):
        p = write(name, txt); made.append(p); return p

    # ---- 1. master marks (single path, evenodd, no transforms) ----
    for tag, fn, ttl in (
        ('dsh-mobile-next-mark.svg', concept_a, 'dsh-mobile-next mark'),
        ('concept-a-chevron.svg',    concept_a, 'Concept A — Chevron'),
        ('concept-b-twin.svg',       concept_b, 'Concept B — Twin'),
        ('concept-c-orbit.svg',      concept_c, 'Concept C — Orbit'),
    ):
        svg, d, meta = mark_svg(fn=fn, title=ttl,
                                desc='Geometric whale mark. Single path, fill-rule evenodd; '
                                     'belly slot and eye are true knockouts so the plate colour '
                                     'shows through.')
        w(tag, svg)

    # ---- 2. colour variants of the primary mark ----
    svg, d, meta = mark_svg(fill=BLUE, title='dsh-mobile-next mark — DeepSeek blue')
    w('dsh-mobile-next-mark-blue.svg', svg)

    svg, d, meta = mark_svg(fill=INKB, title='dsh-mobile-next mark — ink blue (AA on white)')
    w('dsh-mobile-next-mark-ink.svg', svg)

    # reverse: white mark for dark plates; knockouts are transparent so plate shows
    svg, d, meta = mark_svg(fill=WHITE, title='dsh-mobile-next mark — reverse')
    w('dsh-mobile-next-mark-reverse.svg', svg)

    # ---- 3. app icon ----
    svg, d, plate = icon_svg(title='dsh-mobile-next app icon',
                             desc='1024 squircle plate #4D6BFE, white mark at 62% width.')
    w('app-icon.svg', svg)

    svg, d, plate = icon_svg(bg=INK, fg=WHITE, title='dsh-mobile-next app icon — dark')
    w('app-icon-dark.svg', svg)

    svg, d, plate = icon_svg(bg=WHITE, fg=BLUE, title='dsh-mobile-next app icon — light')
    w('app-icon-light.svg', svg)

    # maskable PWA: full-bleed bg, mark inside the 80% safe circle (mark_w 0.56)
    svg, d, plate = icon_svg(mark_w=0.56, title='dsh-mobile-next — maskable icon',
                             desc='Full-bleed plate; mark kept inside the 80% safe circle.')
    w('app-icon-maskable.svg', svg)

    # Android adaptive icon, 108 grid: bg layer + fg layer (mark inside 72dp safe circle)
    plate108 = squircle(54, 54, 54, n=5.0, seg=32, d=2)
    w('layers/adaptive-bg.svg',
      svg_doc(f'  <path fill="{BLUE}" d="{plate108}"/>\n', 108, 108,
              title='adaptive icon — background layer'))
    d108, _ = fit_path(concept_a, target=108*0.46, cx=54, cy=54, dy=-0.6, d=2)
    w('layers/adaptive-fg.svg',
      svg_doc(f'  <path fill="{WHITE}" fill-rule="evenodd" d="{d108}"/>\n', 108, 108,
              title='adaptive icon — foreground layer (inside 72dp safe circle)'))
    d108m, _ = fit_path(concept_a, target=108*0.46, cx=54, cy=54, dy=-0.6, d=2)
    w('layers/adaptive-fg-monochrome.svg',
      svg_doc(f'  <path fill="#000000" fill-rule="evenodd" d="{d108m}"/>\n', 108, 108,
              title='adaptive icon — monochrome layer (themed icons)'))

    # ---- 4. separable foreground / background for the 1024 icon ----
    plate, d, meta = icon_layers()
    w('layers/app-icon-bg.svg',
      svg_doc(f'  <path fill="{BLUE}" d="{plate}"/>\n', 1024, 1024,
              title='app icon — background (squircle, n=5, r=512)'))
    w('layers/app-icon-fg.svg',
      svg_doc(f'  <path fill="{WHITE}" fill-rule="evenodd" d="{d}"/>\n', 1024, 1024,
              title='app icon — foreground (mark, 62% width, centred)'))

    # ---- 5. favicon / small sizes ----
    # 32-grid plate (matches the PNG exports) — reads at 16 px in every browser chrome
    fv32, _, _ = icon_svg(size=32.0, bg=BLUE, fg=WHITE, mark_w=0.66, squircle_n=4.2,
                          title='dsh-mobile-next favicon')
    w('favicon.svg', fv32)
    # transparent glyph for inline / dark-chrome use
    dd, _ = fit_path(concept_a, target=32.0*0.94, cx=16.0, cy=16.0, dy=-0.2, d=2)
    w('favicon-glyph.svg',
      svg_doc(f'  <path fill="{BLUE}" fill-rule="evenodd" d="{dd}"/>\n',
              32, 32, title='dsh-mobile-next favicon — transparent glyph'))

    # iOS home-screen icon: square, full-bleed, opaque (iOS applies its own mask)
    half = 512.0
    dsq, _ = fit_path(concept_a, target=1024.0*0.62, cx=half, cy=half,
                      dy=-1024.0*0.006, d=2)
    w('app-icon-square.svg',
      svg_doc(f'  <path fill="{BLUE}" d="M0 0H1024V1024H0Z"/>\n'
              f'  <path fill="{WHITE}" fill-rule="evenodd" d="{dsq}"/>\n',
              1024, 1024, title='dsh-mobile-next — apple-touch-icon',
              desc='Opaque full-bleed square; iOS applies its own corner mask.'))

    # ---- 6. lockup (mark + wordmark placeholder) ----
    dd, _ = fit_path(concept_a, target=232.0, cx=160.0, cy=256.0, dy=0.0, d=2)
    lock = (f'  <path fill="{INK}" fill-rule="evenodd" d="{dd}"/>\n'
            f'  <text x="320" y="256" font-family="Inter, -apple-system, '
            f'Segoe UI, Helvetica Neue, Arial, sans-serif" font-size="104" '
            f'font-weight="600" letter-spacing="-2.5" fill="{INK}" '
            f'dominant-baseline="central">dsh-mobile-next</text>\n')
    w('construction.svg', construction_svg())

    w('lockup-horizontal.svg',
      svg_doc(lock, 1400, 512, vb='0 0 1400 512',
              title='dsh-mobile-next lockup',
              desc='Wordmark is live text; convert to outlines before release.'))

    return made

def construction_svg():
    """Annotated diagram: 8x8 grid, safe circle, body keyline, tail anchor points."""
    c, R = (458.91, 543.77), 346.29
    d, _ = fit_path(concept_a, target=800.0, cx=512.0, cy=512.0, dy=-10.0, d=2)
    g_ = []
    for i in range(0, 1025, 128):
        g_.append(f'<line x1="{i}" y1="0" x2="{i}" y2="1024" stroke="#CBD5E1" stroke-width="1.5"/>')
        g_.append(f'<line x1="0" y1="{i}" x2="1024" y2="{i}" stroke="#CBD5E1" stroke-width="1.5"/>')
    g_.append('<circle cx="512" cy="512" r="410" fill="none" stroke="#F59E0B" '
              'stroke-width="2" stroke-dasharray="10 8"/>')
    g_.append('<circle cx="512" cy="512" r="512" fill="none" stroke="#94A3B8" stroke-width="2"/>')
    g_.append(f'<circle cx="{c[0]}" cy="{c[1]}" r="{R}" fill="none" stroke="{BLUE}" '
              'stroke-width="2" stroke-dasharray="6 6"/>')
    for a in (-94, -50, -6):
        p = P(c, R, a)
        g_.append(f'<line x1="{c[0]}" y1="{c[1]}" x2="{f(p[0],1)}" y2="{f(p[1],1)}" '
                  f'stroke="{BLUE}" stroke-width="1.5" stroke-dasharray="4 6" opacity="0.6"/>')
        g_.append(f'<circle cx="{f(p[0],1)}" cy="{f(p[1],1)}" r="7" fill="{BLUE}"/>')
    e = P(c, R*0.60, 206)
    g_.append(f'<circle cx="{f(e[0],1)}" cy="{f(e[1],1)}" r="{f(R*0.09,1)}" fill="none" '
              f'stroke="{BLUE}" stroke-width="2" stroke-dasharray="4 4"/>')
    return svg_doc(f'  <path fill="{INK}" fill-rule="evenodd" d="{d}"/>\n'
                   f'  <g fill="none">{"".join(g_)}</g>\n',
                   1024, 1024, title='dsh-mobile-next mark — construction',
                   desc='8x8 module grid; amber = 80% safe circle; blue dashed = body keyline '
                        '(R 346.29) and the three tail anchors at -94 / -50 / -6 degrees.')

if __name__ == '__main__':
    for p in main():
        print('wrote', os.path.relpath(p, OUT))

# ---------------------------------------------------------------- raster exports
def rasterise(svg_path, px, out_path, bg=None):
    """Render an SVG file to PNG at `px` via headless Chrome."""
    src = ('file://' + os.path.abspath(svg_path))
    style = f'background:{bg};' if bg else 'background:transparent;'
    doc = (f'<!doctype html><html><body style="margin:0;{style}">'
           f'<img src="{src}" style="width:{px}px;height:{px}px;display:block">'
           f'</body></html>')
    hp = os.path.join(HERE, '_raster.html')
    open(hp, 'w').write(doc)
    subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--no-sandbox',
                    f'--user-data-dir={HERE}/.chrome', '--hide-scrollbars',
                    '--force-device-scale-factor=1',
                    '--default-background-color=00000000',
                    f'--window-size={px},{px}',
                    f'--screenshot={out_path}',
                    'file://' + hp], capture_output=True)
    return out_path

def export_rasters():
    from PIL import Image
    png = os.path.join(OUT, 'png')
    os.makedirs(png, exist_ok=True)
    made = []
    # PWA / gateway icons required by src/gateway.ts allow-list
    jobs = [
        ('app-icon.svg', 512, 'icon-512.png', None),
        ('app-icon.svg', 192, 'icon-192.png', None),
        ('app-icon-square.svg', 180, 'apple-touch-icon.png', BLUE),
        ('app-icon.svg', 1024, 'icon-1024.png', None),
        ('app-icon-dark.svg', 512, 'icon-512-dark.png', None),
        ('app-icon-maskable.svg', 512, 'icon-512-maskable.png', None),
        ('dsh-mobile-next-mark.svg', 512, 'mark-512.png', None),
        ('dsh-mobile-next-mark-blue.svg', 512, 'mark-512-blue.png', None),
    ]
    for src, px, name, bg in jobs:
        out = os.path.join(png, name)
        rasterise(os.path.join(OUT, src), px, out, bg)
        made.append(out)

    # favicons: iOS/macOS maskable plate, plus a transparent glyph
    for px in (16, 32, 48, 64, 128, 256):
        out = os.path.join(png, f'favicon-{px}.png')
        rasterise(os.path.join(OUT, 'app-icon.svg'), px, out, None)
        made.append(out)

    # macOS AppIcon.appiconset (10 slots, Flutter default naming)
    mac = os.path.join(OUT, 'png', 'macos-appiconset')
    os.makedirs(mac, exist_ok=True)
    for px in (16, 32, 64, 128, 256, 512, 1024):
        out = os.path.join(mac, f'app_icon_{px}.png')
        rasterise(os.path.join(OUT, 'app-icon.svg'), px, out, None)
        made.append(out)

    # Only apple-touch-icon must be opaque (iOS composites it on an unknown colour).
    # Everything else keeps alpha so the squircle corners stay transparent.
    for p in made:
        if not p.endswith('apple-touch-icon.png'):
            continue
        im = Image.open(p).convert('RGBA')
        bgc = Image.new('RGBA', im.size, (77, 107, 254, 255))
        Image.alpha_composite(bgc, im).convert('RGB').save(p)
    return made
