#!/usr/bin/env python3
"""Generate launcher icons from the user's approved artwork; requires Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import hashlib
import json

ROOT = Path(__file__).resolve().parents[2]
DESIGN = ROOT / 'design/logo/approved-next'
SOURCE = DESIGN / 'app-icon-source.png'
RES = ROOT / 'flutter/android/app/src/main/res'
DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}


def save(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format='PNG', optimize=True)
    return path


def generate():
    original = Image.open(SOURCE).convert('RGB')
    if original.width != original.height:
        raise ValueError('Approved source must be square; never crop the artwork.')
    master = original.resize((1024, 1024), Image.Resampling.LANCZOS)
    outputs = [save(master, DESIGN / 'app-icon-1024.png')]
    outputs += [save(original.resize((size, size), Image.Resampling.LANCZOS), DESIGN / f'app-icon-{size}.png') for size in (192, 512)]
    outputs.append(save(master, ROOT / 'flutter/assets/app-icon.png'))
    # Separate white artwork from its black background. NEXT letters and phone
    # cutouts remain transparent, showing the black adaptive background.
    alpha = original.convert('L').point(lambda value: 0 if value <= 12 else value)
    foreground = Image.new('RGBA', original.size, (255, 255, 255, 0))
    foreground.putalpha(alpha)
    for density, scale in DENSITIES.items():
        legacy_size = round(48 * scale)
        outputs.append(save(original.resize((legacy_size, legacy_size), Image.Resampling.LANCZOS), RES / f'mipmap-{density}/ic_launcher.png'))
        # Android adaptive layers use a 108dp canvas. 62% whole-source placement
        # keeps all visible artwork within the central 66dp safe circle.
        canvas_size = round(108 * scale)
        art_size = round(canvas_size * 0.62)
        layer = Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 0))
        offset = (canvas_size - art_size) // 2
        layer.alpha_composite(foreground.resize((art_size, art_size), Image.Resampling.LANCZOS), (offset, offset))
        outputs.append(save(layer, RES / f'mipmap-{density}/ic_launcher_foreground.png'))
        mono = layer.getchannel('A')
        mono_layer = Image.new('RGBA', layer.size, (255, 255, 255, 0))
        mono_layer.putalpha(mono)
        outputs.append(save(mono_layer, RES / f'mipmap-{density}/ic_launcher_monochrome.png'))
    # Preview the actual Android viewport (central 72dp of the 108dp canvas).
    layer = Image.new('RGBA', (1080, 1080), (0, 0, 0, 0))
    layer.alpha_composite(foreground.resize((670, 670), Image.Resampling.LANCZOS), (205, 205))
    adaptive = Image.new('RGBA', layer.size, 'black')
    adaptive.alpha_composite(layer)
    viewport = adaptive.crop((180, 180, 900, 900)).convert('RGB')
    preview = Image.new('RGB', (1160, 490), '#e8e8e8')
    draw = ImageDraw.Draw(preview)
    font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 24)
    for index, (label, image, shape) in enumerate([
        ('Original / 1024px', master, 'square'),
        ('Android / round', viewport, 'circle'),
        ('Android / rounded', viewport, 'rounded'),
    ]):
        x = 30 + 380 * index
        draw.text((x, 25), label, font=font, fill='black')
        image = image.resize((340, 340), Image.Resampling.LANCZOS)
        mask = Image.new('L', (340, 340), 0)
        md = ImageDraw.Draw(mask)
        if shape == 'circle': md.ellipse((0, 0, 339, 339), fill=255)
        elif shape == 'rounded': md.rounded_rectangle((0, 0, 339, 339), radius=76, fill=255)
        else: md.rectangle((0, 0, 339, 339), fill=255)
        preview.paste(image, (x, 80), mask)
    outputs.append(save(preview, DESIGN / 'launcher-preview.png'))
    records = []
    for path in outputs:
        with Image.open(path) as image:
            image.load()
            assert image.format == 'PNG'
            records.append({'path': str(path.relative_to(ROOT)), 'size': list(image.size), 'mode': image.mode, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    # Verify every meaningful foreground pixel is inside Android's safe circle.
    checked = Image.open(RES / 'mipmap-xxxhdpi/ic_launcher_foreground.png')
    channel = checked.getchannel('A')
    center = checked.width / 2
    max_radius = max(((x + .5 - center)**2 + (y + .5 - center)**2)**.5 for y in range(checked.height) for x in range(checked.width) if channel.getpixel((x, y)) > 32)
    safe_radius = checked.width * 33 / 108
    assert max_radius <= safe_radius, (max_radius, safe_radius)
    report = {'source_sha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(), 'adaptive_max_radius_px': max_radius, 'adaptive_safe_radius_px': safe_radius, 'outputs': records}
    (DESIGN / 'validation.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    generate()
