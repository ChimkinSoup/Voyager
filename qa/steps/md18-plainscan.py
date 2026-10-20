# MD-18 (from p28-plainscan.py): files written since <since> (local "YYYY-MM-DD HH:MM") under
# both profiles' (qa, qb) data dirs and %TEMP% (minus Claude's own scratch) that start with
# JPEG / PNG / WebP / GIF magic, plus any vault_media file that does.
import datetime as dt
import os
import sys

since = dt.datetime.strptime(sys.argv[1], '%Y-%m-%d %H:%M').timestamp()
roots = [os.path.expandvars(r'%APPDATA%\Voyager\voyager-profile-qa'), os.path.expandvars(r'%APPDATA%\Voyager\voyager-profile-qb'),os.path.expandvars(r'%TEMP%')]
skip = os.path.expandvars(r'%TEMP%\claude').lower()


def kind(head):
    if head[:3] == b'\xff\xd8\xff':
        return 'JPEG'
    if head[:4] == b'\x89PNG':
        return 'PNG'
    if head[:4] == b'RIFF' and head[8:12] == b'WEBP':
        return 'WEBP'
    if head[:3] == b'GIF':
        return 'GIF'
    return None


hits = scanned = 0
for root in roots:
    for dp, dns, fns in os.walk(root):
        if dp.lower().startswith(skip):
            dns[:] = []
            continue
        for fn in fns:
            f = os.path.join(dp, fn)
            try:
                if os.path.getmtime(f) < since:
                    continue
                with open(f, 'rb') as h:
                    head = h.read(12)
            except OSError:
                continue
            scanned += 1
            k = kind(head)
            if k:
                hits += 1
                print('HIT', k, f, os.path.getsize(f), dt.datetime.fromtimestamp(os.path.getmtime(f)))
print('scanned', scanned, 'files written since', sys.argv[1], '; image-magic hits', hits)
