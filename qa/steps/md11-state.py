"""MD-11 read-only: the media state of one parent (or every md11 parent) on A, B
and in the cloud.

    MD_UID=<uid> python qa/steps/md11-state.py [<documentId> | all] [--no-cloud]

Per reference: id, media id, collection/doc, facet, sort, version, deleted.
Per asset: upload / download state, version, deleted / unreferenced, whether its
bytes file is in that profile's media\\ folder, the cloud asset doc's version and
deleted, and whether the Storage object exists (GCS JSON API, metadata only).
"""
import glob, json, os, sqlite3, subprocess, sys, urllib.parse, urllib.request

UID = os.environ.get('MD_UID', 'NnLX9EOXnhV9DowtvxlveZY4NIF3')
BUCKET = 'voyager-db9de.firebasestorage.app'
args = [a for a in sys.argv[1:] if not a.startswith('--')]
doc = args[0] if args else 'all'
cloud = '--no-cloud' not in sys.argv
TOK = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip() if cloud else None


def db(prof):
    p = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    return sqlite3.connect(f'file:{p}?mode=ro', uri=True, timeout=10)


def get(url):
    try:
        return json.load(urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': f'Bearer {TOK}'})))
    except urllib.error.HTTPError as err:
        return {'_http': err.code}


def cloud_doc(coll, did):
    j = get(f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{UID}/{coll}/{did}')
    if '_http' in j: return None
    return {k: next(iter(v.values())) for k, v in j['fields'].items()}


def storage_has(h):
    j = get(f'https://storage.googleapis.com/storage/v1/b/{BUCKET}/o/' + urllib.parse.quote(f'users/{UID}/media/{h}', safe=''))
    return 'size' in j


def short(x):
    return '-' if x is None else (x[:8] if isinstance(x, str) else x)


where = "document_id like 'md11-%'" if doc == 'all' else f"document_id = '{doc}'"
refs, assets = {}, {}
for prof in ('qa', 'qb'):
    con = db(prof)
    for r in con.execute(f'select id, media_id, collection, document_id, facet, sort_order, version, deleted_at from media_references_table where {where} order by document_id, sort_order'):
        refs.setdefault(r[0], {})[prof] = r
    mids = {r[prof][1] for r in refs.values() if prof in r}
    for mid in mids | {m for m in assets}:
        a = con.execute('select id, content_hash, mime_type, upload_state, download_state, version, deleted_at, unreferenced_at from media_assets_table where id = ?', (mid,)).fetchone()
        if a:
            ext = a[2].split('/')[-1].replace('jpeg', 'jpg')
            mdir = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'media')
            present = bool(glob.glob(os.path.join(mdir, '**', a[1] + '.*'), recursive=True))
            assets.setdefault(mid, {})[prof] = a + (present,)
        else:
            assets.setdefault(mid, {})[prof] = None

print('REFERENCES')
for rid, side in refs.items():
    base = side.get('qa') or side.get('qb')
    line = f'  {rid[:8]} media={base[1][:8]} {base[2]}/{base[3]} {base[4]}'
    for prof in ('qa', 'qb'):
        r = side.get(prof)
        line += f' | {prof}: ' + ('absent' if r is None else f'sort={r[5]} v{r[6]} del={short(r[7])}')
    if cloud:
        cd = cloud_doc('media_references', rid)
        line += ' | cloud: ' + ('absent' if cd is None else f"sort={cd.get('sortOrder')} v{cd.get('version')} del={short(cd.get('deletedAt'))}")
    print(line)
print('ASSETS')
for mid, side in assets.items():
    base = side.get('qa') or side.get('qb')
    if base is None:
        print(f'  {mid[:8]} absent on both'); continue
    line = f'  {mid[:8]} hash={base[1][:10]}'
    for prof in ('qa', 'qb'):
        a = side.get(prof)
        line += f' | {prof}: ' + ('absent' if a is None else f'up={a[3]} down={a[4]} v{a[5]} del={short(a[6])} unref={short(a[7])} file={"Y" if a[8] else "N"}')
    if cloud:
        cd = cloud_doc('media_assets', mid)
        line += ' | cloud: ' + ('absent' if cd is None else f"v{cd.get('version')} del={short(cd.get('deletedAt'))} unref={short(cd.get('unreferencedAt'))}")
        line += ' storage=' + ('Y' if storage_has(base[1]) else 'N')
    print(line)
