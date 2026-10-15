"""MD-3: compare one CRDT text field on A, B and in the cloud (length + md5, repr of the ends).

    python qa/steps/md-textcmp.py <uid> <collection> <table> <id> [column=body]
"""
import hashlib, json, os, sqlite3, subprocess, sys, urllib.request

uid, coll, table, rid = sys.argv[1:5]
col = sys.argv[5] if len(sys.argv) > 5 else 'body'


def show(who, s):
    s = s or ''
    print(f'{who:5} len={len(s):6} md5={hashlib.md5(s.encode("utf-8", "surrogatepass")).hexdigest()} head={ascii(s[:40])} tail={ascii(s[-40:])}')


for p in ('qa', 'qb'):
    db = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{p}', 'voyager.sqlite')
    row = sqlite3.connect(f'file:{db}?mode=ro', uri=True).execute(f'select {col} from {table} where id=?', (rid,)).fetchone()
    show(p, row[0] if row else None)
tok = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()
url = f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{uid}/{coll}/{rid}'
f = json.load(urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': 'Bearer ' + tok})))['fields']
show('cloud', f.get(col, {}).get('stringValue'))
