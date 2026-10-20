# Phase 28A: snapshot / compare the Photos tables of profile qa (read-only).
#   p28-snap.py save <file>  |  p28-snap.py cmp <file>
# Compares every column except transfer state and created/updated stamps
# (instants are compared as instants).
import datetime as dt
import json
import os
import sqlite3
import sys

P = os.path.expandvars(r'%APPDATA%\Voyager\voyager-profile-qa\voyager.sqlite')
TABLES = ['photo_series_table', 'photo_series_angles_table', 'photo_check_ins_table',
          'photo_check_in_images_table', 'vault_blobs_table', 'secure_vault_header_table']
SKIP = {'upload_state', 'download_state', 'thumb_download_state', 'failure_reason'}


def norm(k, v):
    if isinstance(v, str) and len(v) >= 19 and v[4] == '-' and v[10] in 'T ':
        try:
            return dt.datetime.fromisoformat(v.replace('Z', '+00:00')).astimezone(dt.timezone.utc).isoformat()
        except ValueError:
            return v
    if isinstance(v, float):
        return round(v, 9)
    return v


def snap():
    c = sqlite3.connect('file:' + P + '?mode=ro', uri=True)
    c.row_factory = sqlite3.Row
    out = {}
    for t in TABLES:
        rows = {}
        for r in c.execute('select * from ' + t):
            d = {k: norm(k, r[k]) for k in r.keys() if k not in SKIP}
            rows[str(d.get('id'))] = d
        out[t] = rows
    return out


if sys.argv[1] == 'save':
    json.dump(snap(), open(sys.argv[2], 'w'))
    print('saved', {t: len(v) for t, v in snap().items()})
else:
    a = json.load(open(sys.argv[2]))
    b = snap()
    bad = 0
    for t in TABLES:
        ka, kb = set(a[t]), set(b[t])
        diff = [k for k in ka & kb if a[t][k] != b[t][k]]
        print(t, 'before', len(ka), 'now', len(kb), 'onlyBefore', len(ka - kb), 'onlyNow', len(kb - ka), 'differ', len(diff))
        for k in list(diff)[:3]:
            print('   ', k, {f: (a[t][k][f], b[t][k].get(f)) for f in a[t][k] if a[t][k][f] != b[t][k].get(f)})
        bad += len(ka ^ kb) + len(diff)
    print('SNAP SAME' if bad == 0 else 'SNAP DIFF %d' % bad)
