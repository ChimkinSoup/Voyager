"""MD-9: every md9-* record of the five kinds on A, B and in the cloud (read-only).

    MD_UID=<uid> [MD9_PREFIX=md9b-] python qa/steps/md09-cloud.py [--all]

Compares version, deleted or not, and the edited text field. Prints only rows
where A, B and the cloud disagree (all rows with --all), then
MD9CLOUD SAME / DIFF with counts.
"""
import json, os, sqlite3, subprocess, sys, urllib.request

UID = os.environ['MD_UID']
PRE = os.environ.get('MD9_PREFIX', 'md9-')  # e.g. md9b- for the bulk tasks
KINDS = [  # table, collection, db text col, cloud text field
    ('journal_entries_table', 'journal_entries', 'title', 'title'),
    ('todo_tasks_table', 'todo_tasks', 'title', 'title'),
    ('transactions_table', 'transactions', 'note', 'note'),
    ('calendar_events_table', 'calendar_events', 'title', 'title'),
    ('study_cards_table', 'study_cards', 'front_text', 'frontText'),
]
TOK = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()


def val(v):
    if v is None: return None
    for k in ('stringValue', 'integerValue', 'booleanValue', 'timestampValue', 'doubleValue'):
        if k in v: return v[k]
    return None


def cloud(coll):
    out, page = {}, ''
    while True:
        url = f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{UID}/{coll}?pageSize=300' + (f'&pageToken={page}' if page else '')
        with urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': 'Bearer ' + TOK})) as r:
            d = json.load(r)
        for doc in d.get('documents', []):
            id = doc['name'].rsplit('/', 1)[1]
            if id.startswith(PRE):
                out[id] = doc.get('fields', {})
        page = d.get('nextPageToken')
        if not page: return out


def local(prof, table, col):
    db = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)
    return {r[0]: (r[1], r[2] is not None, r[3]) for r in con.execute(f"select id, version, deleted_at, {col} from {table} where id like '{PRE}%'")}


diff = total = 0
for table, coll, col, field in KINDS:
    a, b, c = local('qa', table, col), local('qb', table, col), cloud(coll)
    for id in sorted(set(a) | set(b) | set(c)):
        total += 1
        f = c.get(id)
        cv = (int(val(f.get('version')) or 0), val(f.get('deletedAt')) is not None, val(f.get(field))) if f is not None else None
        same = a.get(id) == b.get(id) == cv
        if not same: diff += 1
        if not same or '--all' in sys.argv:
            print(f"{'  ' if same else '!!'} {coll}/{id}: A={a.get(id)} B={b.get(id)} cloud={cv}")
print(f"MD9CLOUD {'SAME' if diff == 0 else 'DIFF'} ({total} records, {diff} differ)")
