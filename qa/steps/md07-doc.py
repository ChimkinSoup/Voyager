"""Read-only: one Firestore document's plain fields.  MD_UID=<uid> python qa/steps/md07-doc.py <collection> <id> [field,...]"""
import json, os, subprocess, sys, urllib.request

coll, doc = sys.argv[1], sys.argv[2]
want = sys.argv[3].split(',') if len(sys.argv) > 3 else None
tok = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()
url = f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{os.environ["MD_UID"]}/{coll}/{doc}'
try:
    f = json.load(urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': f'Bearer {tok}'})))['fields']
except urllib.error.HTTPError as err:
    print(f'cloud: {err.code}'); sys.exit()
out = {k: next(iter(v.values())) for k, v in f.items() if want is None or k in want}
print('cloud:', json.dumps(out, sort_keys=True))
