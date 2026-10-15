"""MD-10: poll cloud documents (read-only REST) and print every change of
(version, deletedAt set, <field>) with a timestamp.

    MD_UID=<uid> python qa/steps/md10-cloudpoll.py <secs> <collection>/<id>[:field] ...

field defaults to title. Polls every ~0.3 s.
"""
import json, os, subprocess, sys, time, urllib.request
from datetime import datetime

UID = os.environ['MD_UID']
TOK = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()
secs = float(sys.argv[1]); targets = []
for t in sys.argv[2:]:
    path, _, field = t.partition(':'); targets.append((path, field or 'title'))


def val(v):
    if v is None: return None
    for k in ('stringValue', 'integerValue', 'booleanValue', 'timestampValue', 'doubleValue'):
        if k in v: return v[k]
    return None


last = {}; end = time.time() + secs
while time.time() < end:
    for path, field in targets:
        url = f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{UID}/{path}'
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': 'Bearer ' + TOK})) as r:
                f = json.load(r).get('fields', {})
            cur = (val(f.get('version')), val(f.get('deletedAt')) is not None, val(f.get(field)))
        except Exception as e:
            cur = ('ERR', str(e)[:60])
        if last.get(path) != cur:
            print(datetime.now().strftime('%H:%M:%S.%f')[:-3], path, cur, flush=True); last[path] = cur
    time.sleep(0.3)
print('CLOUDPOLL END')
