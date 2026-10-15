"""MD-4.3: synced settings on A, B and in the cloud (users/<uid>/settings/app), read-only.

    python qa/steps/md4set.py <key[=column]>... [--wait S]

Each key is the payload name (accentColor); the DB column defaults to its
snake_case. Prints value + per-field stamp on each side, then MD4SET SAME/DIFF
(values only). --wait polls until they agree.
"""
import json, re, sys, time
sys.path.insert(0, __import__('os').path.dirname(__file__))
from md4show import cloud, db, norm, UID

args = [x for x in sys.argv[1:] if not x.startswith('--')]
wait = float(sys.argv[sys.argv.index('--wait') + 1]) if '--wait' in sys.argv else 0
if '--wait' in sys.argv: args.remove(sys.argv[sys.argv.index('--wait') + 1])
keys = [(k.split('=')[0], k.split('=')[1] if '=' in k else re.sub(r'([A-Z])', r'_\1', k).lower()) for k in args]


def side(prof):
    con = db(prof)
    cols = [c for _, c in keys] + ['field_updated_at_json', 'updated_at']
    r = dict(zip(cols, con.execute(f'select {",".join(cols)} from settings_table where id = 1').fetchone()))
    q = con.execute('select count(*) from pending_uploads_table').fetchone()[0]
    st = json.loads(r['field_updated_at_json'] or '{}')
    return {k: (r[c], st.get(k)) for k, c in keys}, q


def sv(x):
    x = str(x).lower()
    return {'true': '1', 'false': '0'}.get(x, x)


end = time.time() + wait
while True:
    a, qa = side('qa'); b, qb = side('qb')
    cl = cloud(UID, 'settings', 'app', [k for k, _ in keys] + ['settingsFieldUpdatedAt'])
    cst = cl.get('settingsFieldUpdatedAt') or {}
    c = {k: (cl.get(k), cst.get(k) if isinstance(cst, dict) else None) for k, _ in keys}
    same = all(sv(a[k][0]) == sv(b[k][0]) == sv(c[k][0]) for k, _ in keys)
    if same or time.time() >= end:
        break
    time.sleep(1)
for name, d, q in (('A ', a, qa), ('B ', b, qb), ('FS', c, '-')):
    print(f'{name} (outbox {q}): ' + '; '.join(f'{k}={v[0]!r} @{v[1]}' for k, v in d.items()))
print('MD4SET', 'SAME' if same else 'DIFF')
