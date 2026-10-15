"""MD-12.3: after a sign-out mid-drain, is every md12d entry either in the cloud
with the new title or still queued in A's outbox? (read-only)

    MD_UID=<uid> python qa/steps/md12-drain.py <title prefix, e.g. "MD12 dtwo ">
"""
import json, os, sqlite3, subprocess, sys, urllib.request
UID = os.environ['MD_UID']
want = sys.argv[1]
TOK = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()


def cloud():
    out, page = {}, ''
    while True:
        url = f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{UID}/journal_entries?pageSize=300' + (f'&pageToken={page}' if page else '')
        with urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': 'Bearer ' + TOK})) as r:
            d = json.load(r)
        for doc in d.get('documents', []):
            id = doc['name'].rsplit('/', 1)[1]
            if id.startswith('md12d-'):
                out[id] = doc.get('fields', {}).get('title', {}).get('stringValue')
        page = d.get('nextPageToken')
        if not page:
            return out


def db(prof):
    p = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    return sqlite3.connect(f'file:{p}?mode=ro', uri=True, timeout=10)


a = db('qa')
queued = {r[0] for r in a.execute("select document_id from pending_uploads_table where document_id like 'md12d-%'")}
atitle = dict(a.execute("select id, title from journal_entries_table where id like 'md12d-%'"))
btitle = dict(db('qb').execute("select id, title from journal_entries_table where id like 'md12d-%'"))
cl = cloud()
up = {i for i, t in cl.items() if t and t.startswith(want)}
lost = sorted(i for i in atitle if atitle[i].startswith(want) and i not in up and i not in queued)
print(f'A edited={sum(t.startswith(want) for t in atitle.values())} queued={len(queued)} cloud_new={len(up)} '
      f'B_new={sum(t.startswith(want) for t in btitle.values())} both_queued_and_up={len(queued & up)}')
print('LOST (neither uploaded nor queued):', len(lost), lost[:20])
