"""Read-only Firestore view of one CRDT document (multi-device plan MD-3).

    python qa/harness/fs_ops.py <uid> <collection> <docId> [--ops] [--chars]

Prints the document's text fields (body / notes / version / updatedAt) and,
with --ops, every sync_operations doc for it: id, deviceId, sequence, timestamp,
payload kind and size. --chars also prints, per device, the live characters
its ops carry (to spot one device's text re-recorded under another's id,
P0-2). Uses `gcloud auth print-access-token`, like fs_snapshot.sh.
"""
import json, subprocess, sys, urllib.request
from collections import defaultdict

uid, coll, doc = sys.argv[1:4]
flags = set(sys.argv[4:])
TOK = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()
BASE = f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{uid}'


def call(url, body=None):
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body else None,
                                 headers={'Authorization': 'Bearer ' + TOK, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def val(v):
    if v is None: return None
    for k in ('stringValue', 'integerValue', 'booleanValue', 'timestampValue', 'doubleValue'):
        if k in v: return v[k]
    if 'nullValue' in v: return None
    return v


d = call(f'{BASE}/{coll}/{doc}')['fields']
for k in ('version', 'updatedAt', 'deletedAt', 'title', 'body', 'notes', '_serverWrittenAt'):
    if k in d:
        print(f'{k}: {val(d[k])!r}')
if '--ops' in flags or '--chars' in flags:
    q = {'structuredQuery': {'from': [{'collectionId': 'sync_operations'}],
                             'where': {'fieldFilter': {'field': {'fieldPath': 'documentId'}, 'op': 'EQUAL', 'value': {'stringValue': doc}}}}}
    rows = [x['document']['fields'] for x in call(f'{BASE}:runQuery', q) if 'document' in x]
    rows.sort(key=lambda f: (int(val(f['sequence'])), val(f['timestamp'])))
    chars = defaultdict(dict)
    print(f'ops: {len(rows)}')
    for f in rows:
        p = val(f['payload'])
        try:
            pj = json.loads(p)
        except Exception:
            pj = None
        kind = type(pj).__name__
        info = ''
        if isinstance(pj, dict):
            info = 'keys=' + ','.join(sorted(pj)[:8])
            co = pj.get('charOps')
            if isinstance(co, str):
                try: co = json.loads(co)
                except Exception: co = None
            if isinstance(co, list):
                info += f' charOps={len(co)}'
                for o in co:
                    if isinstance(o, dict) and 'clientId' in o:
                        chars[o['clientId']][o['id']] = o
        elif isinstance(pj, list):
            info = f'list={len(pj)}'
        print(f"  seq={val(f['sequence'])} dev={val(f['deviceId'])[:8]} ts={val(f['timestamp'])} id={val(f['id'])[:20]} {kind} {len(p)}B {info}")
    if '--chars' in flags:
        for cid, ops in chars.items():
            live = sorted((o for o in ops.values() if not o.get('deleted')), key=lambda o: o['position'])
            print(f'client {cid[:8]}: {len(ops)} ops, {len(live)} live: {"".join(o["character"] for o in live)[:300]!r}')
        bypos = defaultdict(list)
        for ops in chars.values():
            for o in ops.values():
                bypos[o['position']].append(o)
        clash = {p: v for p, v in bypos.items() if len({o['clientId'] for o in v}) > 1}
        print(f'positions shared by ops of different devices: {len(clash)}')
        for p, v in sorted(clash.items())[:12]:
            print(f'  {p!r}: ' + ', '.join(f"{o['clientId'][:4]}:{o['character']!r}{'(del)' if o.get('deleted') else ''}" for o in v))
