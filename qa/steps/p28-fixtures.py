# Phase 28A fixtures -> qa/data/p28/. Each image carries a big number so
# screenshots show which photo is where. Run from the repo root.
import os
import random
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join('qa', 'data', 'p28')
os.makedirs(OUT, exist_ok=True)


def font(size):
    for name in ('arialbd.ttf', 'arial.ttf'):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def card(w, h, number, bg, mode='RGB', label=None):
    im = Image.new(mode, (w, h), bg)
    d = ImageDraw.Draw(im)
    # A frame and an "UP" arrow, so rotation shows.
    d.rectangle([w * 0.03, h * 0.03, w * 0.97, h * 0.97], outline='white', width=max(4, w // 150))
    d.polygon([(w * 0.5, h * 0.06), (w * 0.42, h * 0.16), (w * 0.58, h * 0.16)], fill='white')
    d.text((w * 0.5, h * 0.2), 'UP', font=font(max(12, h // 25)), fill='white', anchor='mm')
    d.text((w / 2, h / 2), str(number), font=font(int(min(w, h) * 0.45)), fill='white', anchor='mm')
    if label:
        d.text((w / 2, h * 0.85), label, font=font(max(10, h // 30)), fill='white', anchor='mm')
    return im


def exif_with_date(date):
    ex = Image.Exif()
    ex[0x0132] = date  # DateTime
    ifd = ex.get_ifd(0x8769)
    ifd[0x9003] = date  # DateTimeOriginal
    return ex


# 1 portrait 3000x4000 JPEG with DateTimeOriginal 2025-03-14.
card(3000, 4000, 1, (40, 90, 160), label='portrait exif 2025-03-14').save(
    os.path.join(OUT, 'p01-portrait-exif.jpg'), quality=90, exif=exif_with_date('2025:03:14 10:30:00'))

# 2 landscape 4000x3000 JPEG, no EXIF (mtime set by PowerShell afterwards).
card(4000, 3000, 2, (150, 60, 40), label='landscape no exif').save(
    os.path.join(OUT, 'p02-landscape-noexif.jpg'), quality=90)

# 3 square PNG with alpha (transparent corners).
im = card(1200, 1200, 3, (30, 140, 70, 255), mode='RGBA', label='png alpha')
d = ImageDraw.Draw(im)
d.rectangle([0, 0, 300, 300], fill=(0, 0, 0, 0))
im.save(os.path.join(OUT, 'p03-square-alpha.png'))

# 4 WebP.
card(1600, 1200, 4, (120, 40, 140), label='webp').save(os.path.join(OUT, 'p04.webp'), quality=85)

# 5 EXIF orientation 6 (stored sideways; shown upright when rotated 90 CW).
up = card(1500, 2000, 5, (160, 130, 20), label='orientation 6')
stored = up.transpose(Image.Transpose.ROTATE_90)  # CCW, so a CW turn restores it
ex = exif_with_date('2025:06:01 08:00:00')
ex[0x0112] = 6
stored.save(os.path.join(OUT, 'p05-orient6.jpg'), quality=90, exif=ex)

# 6 8000x8000 JPEG (downscale case, under 20 MB).
card(8000, 8000, 6, (20, 100, 110), label='8000 px').save(os.path.join(OUT, 'p06-8000.jpg'), quality=80)

# 7 over 20 MB: noise JPEG at quality 100.
random.seed(7)
big = Image.frombytes('RGB', (2600, 2600), os.urandom(2600 * 2600 * 3))
ImageDraw.Draw(big).text((1300, 1300), "7", font=font(1000), fill='white', anchor='mm')
big.save(os.path.join(OUT, 'p07-over20mb.jpg'), quality=100, subsampling=0)

# 8 truncated JPEG: first 40% of a good one.
src = os.path.join(OUT, 'p08-src.jpg')
card(2000, 1500, 8, (90, 90, 90), label='truncated').save(src, quality=90)
data = open(src, 'rb').read()
open(os.path.join(OUT, 'p08-truncated.jpg'), 'wb').write(data[: int(len(data) * 0.4)])
os.remove(src)

# 9 a text file renamed .jpg.
open(os.path.join(OUT, 'p09-text.jpg'), 'w').write('this is not an image\n' * 20)

# 10 1x1 PNG.
Image.new('RGB', (1, 1), (255, 0, 0)).save(os.path.join(OUT, 'p10-1x1.png'))

# 11-14 extra plain photos for multi-angle / grid work.
for n, bg in ((11, (60, 60, 140)), (12, (140, 60, 60)), (13, (60, 140, 60)), (14, (140, 140, 60))):
    card(1200, 1600, n, bg, label='extra').save(os.path.join(OUT, 'p%02d.jpg' % n), quality=88)
card(1600, 1200, 15, (70, 70, 70), label='extra landscape').save(os.path.join(OUT, 'p15-land.jpg'), quality=88)
card(1200, 1600, 16, (10, 120, 160), label='paste').save(os.path.join(OUT, 'p16-paste.png'))

for f in sorted(os.listdir(OUT)):
    print(f, os.path.getsize(os.path.join(OUT, f)))
