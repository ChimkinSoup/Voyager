"""Phase 25: build import failure fixtures from qa/exports/p25-qa024.zip into qa/exports/."""
import zipfile, json, hashlib, io, os

D = 'C:/Users/Juno/Code/Voyager/qa/exports/'
SRC = D + 'p25-qa024.zip'
src = zipfile.ZipFile(SRC)
members = {n: src.read(n) for n in src.namelist()}


def write(name, files, checksums=True, manifest_patch=None):
    m = json.loads(files['manifest.json'])
    m.pop('checksums', None)
    if manifest_patch:
        m.update(manifest_patch)
    if checksums:
        m['checksums'] = {n: hashlib.sha256(b).hexdigest() for n, b in files.items() if n != 'manifest.json'}
    out = dict(files)
    out['manifest.json'] = json.dumps(m).encode()
    with zipfile.ZipFile(D + name, 'w', zipfile.ZIP_DEFLATED) as z:
        for n, b in out.items():
            z.writestr(n, b)
    print('wrote', name)


# 1. truncated archive
raw = open(SRC, 'rb').read()
open(D + 'p25-truncated.zip', 'wb').write(raw[: len(raw) // 2])
print('wrote p25-truncated.zip')
# 2. not a zip at all
open(D + 'p25-notzip.zip', 'wb').write(b'This is a plain text file pretending to be a zip.\n' * 20)
print('wrote p25-notzip.zip')
# 3. a valid zip from elsewhere (no manifest)
with zipfile.ZipFile(D + 'p25-foreign.zip', 'w') as z:
    z.writestr('readme.txt', 'hello')
    z.writestr('data/journal_entries.json', '[]')
print('wrote p25-foreign.zip')
# 4. a member changed after the checksums were taken
bad = dict(members)
je = json.loads(bad['journal_entries.json'])
je[0]['data']['body'] = 'TAMPERED body'
bad['journal_entries.json'] = json.dumps(je).encode()
m = json.loads(bad['manifest.json'])  # keep original checksums
with zipfile.ZipFile(D + 'p25-badsum.zip', 'w') as z:
    for n, b in bad.items():
        z.writestr(n, b)
print('wrote p25-badsum.zip')
# 5. a format version from the future
write('p25-v3.zip', members, manifest_patch={'formatVersion': 3})
# 6. manifest record count disagrees (checksums recomputed, so only the count is wrong)
write('p25-badcount.zip', members, manifest_patch={'collections': {**json.loads(members['manifest.json'])['collections'], 'journals': 5}})
# 7. pre-map export: ranking categories without locationEnabled, parents without locations; no checksums (older builds)
pm = dict(members)
cats = json.loads(pm['ranking_categories.json'])
for c in cats:
    c['data'].pop('locationEnabled', None)
pm['ranking_categories.json'] = json.dumps(cats).encode()
ps = json.loads(pm['ranking_parents.json'])
for p in ps:
    p['data'].pop('locations', None)
pm['ranking_parents.json'] = json.dumps(ps).encode()
write('p25-premap.zip', pm, checksums=False)
