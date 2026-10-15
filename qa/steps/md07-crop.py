"""Stack the same region of several shots into one image for review.

    python qa/steps/md07-crop.py <out.png> <x0,y0,x1,y1> <shot names in qa/shots, no .png>...
"""
import os, sys
from PIL import Image, ImageDraw

out, box, names = sys.argv[1], tuple(int(v) for v in sys.argv[2].split(',')), sys.argv[3:]
here = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'shots')
crops = [Image.open(os.path.join(here, n + '.png')).crop(box) for n in names]
w, h = crops[0].size
sheet = Image.new('RGB', (w, (h + 30) * len(crops)), 'white')
d = ImageDraw.Draw(sheet)
for i, (n, im) in enumerate(zip(names, crops)):
    d.text((4, i * (h + 30) + 8), n, fill='black')
    sheet.paste(im, (0, i * (h + 30) + 30))
sheet.save(out)
