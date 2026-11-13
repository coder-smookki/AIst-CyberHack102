"""Текстуры шильдика и циферблата манометра для сцены Blender.

Запуск любым Python с библиотекой Pillow:
    python blender/make_textures.py <папка>

Шильдик учебный: строка модели повторяет типоразмер опорного насоса из документации заказчика
(центробежный inline, 65/160, 5,5 кВт, 2900 об/мин), производитель указан как демонстрационный.
"""
import json
import math
import random
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
REG = "/System/Library/Fonts/Supplemental/Arial.ttf"

PLATE = {
    "maker": "KST DEMO PUMPS",
    "model": "IL 65/160-5,5/2",
    "serial": "2786107-0142",
    "lines": ["Q 47 m3/h    H 31,7 m", "P2 5,5 kW    n 2900 1/min", "PN 16    IP 55    Cl. F", "Year 2023    Made for demo"],
}


def nameplate(path, w=1400, h=900):
    """Рисует шильдик на шлифованном металле: производитель, модель, серийный номер, параметры."""
    rnd = random.Random(7)
    im = Image.new("RGB", (w, h), (196, 199, 203))
    px = im.load()
    for y in range(h):
        s = rnd.randint(-9, 9)
        for x in range(w):
            r, g, b = px[x, y]
            px[x, y] = (r + s, g + s, b + s)
    im = im.filter(ImageFilter.GaussianBlur(0.6))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([14, 14, w - 14, h - 14], 36, outline=(40, 44, 50), width=8)
    for cx, cy in ((60, 60), (w - 60, 60), (60, h - 60), (w - 60, h - 60)):
        d.ellipse([cx - 20, cy - 20, cx + 20, cy + 20], fill=(120, 124, 130), outline=(60, 62, 66), width=3)
    ink = (22, 24, 28)
    d.text((110, 70), PLATE["maker"], font=ImageFont.truetype(BOLD, 92), fill=ink)
    d.line([110, 190, w - 110, 190], fill=ink, width=6)
    d.text((110, 215), "Type", font=ImageFont.truetype(REG, 50), fill=ink)
    d.text((300, 200), PLATE["model"], font=ImageFont.truetype(BOLD, 96), fill=ink)
    d.text((110, 345), "No.", font=ImageFont.truetype(REG, 50), fill=ink)
    d.text((300, 330), PLATE["serial"], font=ImageFont.truetype(BOLD, 96), fill=ink)
    d.line([110, 460, w - 110, 460], fill=ink, width=4)
    f = ImageFont.truetype(REG, 64)
    for i, line in enumerate(PLATE["lines"]):
        d.text((110, 490 + i * 92), line, font=f, fill=ink)
    im.save(path)


def gauge_dial(path, size=1024, vmin=0.0, vmax=10.0, sweep=270.0):
    """Рисует циферблат без стрелки: шкала на 270 градусов с нулём слева внизу и красной зоной."""
    im = Image.new("RGB", (size, size), (238, 238, 232))
    d = ImageDraw.Draw(im)
    c = size / 2
    R = size * 0.47
    d.ellipse([c - R, c - R, c + R, c + R], fill=(250, 250, 246), outline=(20, 20, 20), width=10)
    start = 90 + (360 - sweep) / 2
    n_major = 10
    for i in range(n_major * 5 + 1):
        a = math.radians(start + sweep * i / (n_major * 5))
        major = i % 5 == 0
        r1, r2 = R * (0.74 if major else 0.82), R * 0.92
        d.line([c + r1 * math.cos(a), c + r1 * math.sin(a), c + r2 * math.cos(a), c + r2 * math.sin(a)],
               fill=(15, 15, 15), width=12 if major else 5)
        if major:
            v = vmin + (vmax - vmin) * i / (n_major * 5)
            t = f"{v:g}"
            f = ImageFont.truetype(BOLD, 76)
            tw, th = d.textbbox((0, 0), t, font=f)[2:]
            rt = R * 0.58
            d.text((c + rt * math.cos(a) - tw / 2, c + rt * math.sin(a) - th / 2 - 8), t, font=f, fill=(15, 15, 15))
    a0, a1 = start + sweep * 0.8, start + sweep
    d.arc([c - R * 0.95, c - R * 0.95, c + R * 0.95, c + R * 0.95], a0, a1, fill=(205, 35, 30), width=22)
    f = ImageFont.truetype(BOLD, 70)
    tw = d.textbbox((0, 0), "bar", font=f)[2]
    d.text((c - tw / 2, c + R * 0.30), "bar", font=f, fill=(15, 15, 15))
    im.save(path)


if __name__ == "__main__":
    out = sys.argv[1]
    nameplate(f"{out}/nameplate.png")
    gauge_dial(f"{out}/gauge_dial.png")
    truth = {**PLATE, "gauge": {"min": 0.0, "max": 10.0, "sweep_deg": 270.0, "unit": "bar"}}
    json.dump(truth, open(f"{out}/truth.json", "w"), indent=1)
    print("текстуры записаны в", out)
