"""One record on A, B and in the cloud (read-only), for MD-4's field-merge checks.

    python qa/steps/md4show.py <table> <id> <collection> <db cols> <cloud fields> [--uid U] [--wait S]

<db cols> / <cloud fields>: comma lists (version and updated_at / updatedAt are
always added). --wait polls until both outboxes are 0 and A, B and the cloud
agree on the listed values (up to S seconds), then prints. Ends with
MD4SHOW SAME or MD4SHOW DIFF.
"""
import argparse, json, os, sqlite3, subprocess, time, urllib.request
from datetime import datetime, timezone

UID = __import__('os').environ.get('MD_UID', 'SCKpB7qDLVY2vjdY48yeYdGRqTR2')  # qa-069 unless MD_UID is set
_tok = None


def tok():
    global _tok
    if _tok is None:
        _tok = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()
    return _tok


def val(v):
    if v is None: return None
    for k in ('stringValue', 'integerValue', 'booleanValue', 'timestampValue', 'doubleValue'):
        if k in v: return v[k]
    if 'nullValue' in v: return None
    if 'arrayValue' in v: return [val(x) for x in v['arrayValue'].get('values', [])]
    if 'mapValue' in v: return {k: val(x) for k, x in v['mapValue'].get('fields', {}).items()}
    return v


def cloud(uid, coll, id, fields):
    req = urllib.request.Request(f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{uid}/{coll}/{id}',
                                 headers={'Authorization': 'Bearer ' + tok()})
    try:
        with urllib.request.urlopen(req) as r:
            d = json.load(r)['fields']
    except urllib.error.HTTPError as e:
        return {'_error': e.code}
    return {f: val(d.get(f)) for f in fields}


def db(prof):
    return sqlite3.connect('file:' + os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite').replace('\\', '/') + '?mode=ro', uri=True, timeout=10)


def row(prof, table, id, cols):
    con = db(prof)
    r = con.execute(f'select {",".join(cols)} from {table} where id = ?', (id,)).fetchone()
    q = con.execute('select count(*) from pending_uploads_table').fetchone()[0]
    con.close()
    return (dict(zip(cols, r)) if r else None), q


def norm(x):
    """Dates as epoch ms, so a local '-04:00' text, a UTC text, an int and a Firestore timestamp compare."""
    if isinstance(x, bool):
        return int(x)
    if isinstance(x, int) and x > 10**9:  # drift unix seconds
        return x * 1000
    if isinstance(x, str):
        s = x.replace('Z', '+00:00').strip()
        for fmt in (None,):
            try:
                d = datetime.fromisoformat(s.replace(' ', 'T', 1) if 'T' not in s and s[:4].isdigit() and len(s) > 10 and s[4] == '-' else s)
                if d.tzinfo is None: d = d.replace(tzinfo=timezone.utc)
                return int(d.timestamp() * 1000)
            except ValueError:
                pass
    if isinstance(x, str) and x.lstrip('-').isdigit():
        return int(x)
    if isinstance(x, float) and x.is_integer():
        return int(x)
    return x


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('table'); ap.add_argument('id'); ap.add_argument('coll'); ap.add_argument('cols'); ap.add_argument('fields')
    ap.add_argument('--uid', default=UID); ap.add_argument('--wait', type=float, default=0)
    a = ap.parse_args()
    cols = ['version', 'updated_at'] + [x for x in a.cols.split(',') if x]
    fields = ['version', 'updatedAt'] + [x for x in a.fields.split(',') if x]
    end = time.time() + a.wait
    while True:
        ra, qa = row('qa', a.table, a.id, cols); rb, qb = row('qb', a.table, a.id, cols)
        cl = cloud(a.uid, a.coll, a.id, fields)
        va = [norm(ra[c]) for c in cols] if ra else None
        vb = [norm(rb[c]) for c in cols] if rb else None
        vc = [norm(cl.get(f)) for f in fields]
        same = va == vb and va is not None and [str(x) for x in va] == [str(x) for x in vc]
        if same or time.time() >= end:
            break
        time.sleep(1)
    print(f'A  (outbox {qa}): {ra}')
    print(f'B  (outbox {qb}): {rb}')
    print(f'FS: {cl}')
    print('MD4SHOW', 'SAME' if same else 'DIFF', f'(A=B {va == vb}, A=cloud {[str(x) for x in (va or [])] == [str(x) for x in vc]})')


if __name__ == '__main__':
    main()
