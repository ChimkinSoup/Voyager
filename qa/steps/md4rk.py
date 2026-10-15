"""MD-4.6: the branches (locations) of ranking parent md4-rp on A, B and in the cloud, plus their loc: stamps.

    python qa/steps/md4rk.py [--wait S]

Ends with MD4RK SAME when the branch labels (by id) agree everywhere.
"""
import json, sys, time
sys.path.insert(0, __import__('os').path.dirname(__file__))
from md4show import cloud, db, UID

wait = float(sys.argv[sys.argv.index('--wait') + 1]) if '--wait' in sys.argv else 0


def side(prof):
    con = db(prof)
    cols = [r[1] for r in con.execute('pragma table_info(ranking_parents_table)')]
    stamp_col = next((c for c in cols if 'stamp' in c or 'field_updated' in c), None)
    row = con.execute(f'select version, locations_json{", " + stamp_col if stamp_col else ""} from ranking_parents_table where id = ?', ('md4-rp',)).fetchone()
    locs = {l['id']: l.get('label') for l in json.loads(row[1] or '[]')}
    st = json.loads(row[2]) if stamp_col and row[2] else {}
    return row[0], locs, {k: v for k, v in st.items() if k.startswith('loc:')}


end = time.time() + wait
while True:
    a = side('qa'); b = side('qb')
    cl = cloud(UID, 'ranking_parents', 'md4-rp', ['version', 'locations', 'fieldUpdatedAt'])
    raw = cl.get('locations') or {}
    raw = raw.values() if isinstance(raw, dict) else raw
    cl_locs = {l['id']: l.get('label') for l in raw if isinstance(l, dict)}
    same = a[1] == b[1] == cl_locs
    if same or time.time() >= end:
        break
    time.sleep(1)
print(f'A  v{a[0]}: {a[1]}')
print(f'B  v{b[0]}: {b[1]}')
print(f'FS v{cl.get("version")}: {cl_locs}')
fs_st = cl.get('fieldUpdatedAt') if isinstance(cl.get('fieldUpdatedAt'), dict) else {}
for k in sorted(set(a[2]) | set(b[2])):
    print(f'  {k}: A {a[2].get(k)} | B {b[2].get(k)} | FS {fs_st.get(k)}')
print('MD4RK', 'SAME' if same else 'DIFF')
