"""MD-7.1/7.2: per-device count rows on A, B and in the cloud, with each side's total.

    MD_UID=<uid> python qa/steps/md07-cnt.py counter <trackerId>
    MD_UID=<uid> python qa/steps/md07-cnt.py ranking <entryId>
"""
import json, os, sqlite3, subprocess, sys, urllib.request

kind, key = sys.argv[1], sys.argv[2]
table, col, coll = {
    'counter': ('counter_adjustments_table', 'tracker_id', 'counter_adjustments'),
    'ranking': ('ranking_counts_table', 'entry_id', 'ranking_counts'),
}[kind]
uid = os.environ['MD_UID']
for prof in ('qa', 'qb'):
    db = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)
    rows = con.execute(f'select device_id, delta, version, deleted_at from {table} where {col}=? order by device_id', (key,)).fetchall()
    live = sum(r[1] for r in rows if r[3] is None)
    print(f'{prof}: sum={live} ' + '; '.join(f'{r[0][:8]} d={r[1]} v{r[2]}{" DEL" if r[3] else ""}' for r in rows))
tok = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()
url = f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{uid}/{coll}?pageSize=300'
docs = json.load(urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': f'Bearer {tok}'}))).get('documents', [])
out, total = [], 0
for d in docs:
    f = d['fields']
    ref = f.get('trackerId' if kind == 'counter' else 'entryId', {}).get('stringValue')
    if ref != key: continue
    delta = int(f.get('delta', {}).get('integerValue', 0)); ver = f.get('version', {}).get('integerValue')
    dead = 'nullValue' not in f.get('deletedAt', {'nullValue': None})
    if not dead: total += delta
    out.append(f"{f.get('deviceId', {}).get('stringValue', '?')[:8]} d={delta} v{ver}{' DEL' if dead else ''}")
print(f'cloud: sum={total} ' + '; '.join(sorted(out)))
