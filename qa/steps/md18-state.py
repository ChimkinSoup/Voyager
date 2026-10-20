"""MD-18 read-only: Photo Series / vault state on A (qa), B (qb) and in the cloud.

    MD_UID=<uid> python qa/steps/md18-state.py counts
    MD_UID=<uid> python qa/steps/md18-state.py blobs <blobId>... | all | ci:<checkInId> | series:<name> [--no-cloud]
    MD_UID=<uid> python qa/steps/md18-state.py checkin <checkInId> [--no-cloud]
    MD_UID=<uid> python qa/steps/md18-state.py storage   (every vault_media object: count, and any that starts with image magic)

counts: live / deleted rows per Photos table, the vault header, the outbox and
the blob transfer states on each profile.
blobs: per blob, the row on A and B (vault, upload / download / thumb state,
version, deleted), whether `vault_media/{id}` and `{id}.thumb` exist locally and
start with image magic, the cloud `vault_blobs` doc (version, deleted, fields) and
both Storage objects (size, first bytes checked for image magic).
checkin: the check-in row on A, B and cloud (date, note fields, vault, version,
deleted) and its images, then `blobs` for its blobs.
"""
import json, os, sqlite3, subprocess, sys, urllib.parse, urllib.request

UID = os.environ.get('MD_UID')
BUCKET = 'voyager-db9de.firebasestorage.app'
args = [a for a in sys.argv[1:] if not a.startswith('--')]
cloud = '--no-cloud' not in sys.argv and UID
TOK = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip() if cloud else None
PROFS = ('qa', 'qb')
TABLES = ('photo_series_table', 'photo_series_angles_table', 'photo_check_ins_table',
          'photo_check_in_images_table', 'vault_blobs_table')


def base(prof):
    return os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}')


def db(prof):
    return sqlite3.connect(f'file:{os.path.join(base(prof), "voyager.sqlite")}?mode=ro', uri=True, timeout=10)


def magic(head):
    if head[:3] == b'\xff\xd8\xff': return 'JPEG'
    if head[:4] == b'\x89PNG': return 'PNG'
    if head[:4] == b'RIFF' and head[8:12] == b'WEBP': return 'WEBP'
    if head[:3] == b'GIF': return 'GIF'
    return None


def req(url, headers=None, raw=False):
    h = {'Authorization': f'Bearer {TOK}'}
    h.update(headers or {})
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers=h))
        return r.read() if raw else json.load(r)
    except urllib.error.HTTPError as err:
        return {'_http': err.code}


def cloud_doc(coll, did):
    j = req(f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{UID}/{coll}/{did}')
    if '_http' in j: return None
    return {k: next(iter(v.values())) if v else None for k, v in j.get('fields', {}).items()}


def obj(name):
    path = urllib.parse.quote(f'users/{UID}/vault_media/{name}', safe='')
    meta = req(f'https://storage.googleapis.com/storage/v1/b/{BUCKET}/o/{path}')
    if '_http' in meta: return f'{meta["_http"]}'
    head = req(f'https://storage.googleapis.com/storage/v1/b/{BUCKET}/o/{path}?alt=media', {'Range': 'bytes=0-15'}, raw=True)
    m = magic(head) if isinstance(head, bytes) else '?'
    return f'{meta.get("size")}B{" MAGIC=" + m if m else ""}'


def local(prof, bid):
    out = []
    for suf in ('', '.thumb'):
        f = os.path.join(base(prof), 'vault_media', bid + suf)
        if not os.path.exists(f):
            out.append('-')
            continue
        with open(f, 'rb') as h:
            m = magic(h.read(12))
        out.append(f'{os.path.getsize(f)}B' + (f' MAGIC={m}' if m else ''))
    return '/'.join(out)


def short(x):
    return '-' if x is None else (str(x)[:8] if isinstance(x, str) and len(x) > 20 else x)


def counts():
    for prof in PROFS:
        try:
            con = db(prof)
        except sqlite3.OperationalError as e:
            print(prof, 'no db', e); continue
        parts = []
        for t in TABLES:
            live, dead = con.execute(f'select sum(deleted_at is null), sum(deleted_at is not null) from {t}').fetchone()
            parts.append(f'{t.replace("_table", "").replace("photo_", "")} {live or 0}/{dead or 0}')
        hdr = con.execute('select vault_id, header_version from secure_vault_header_table').fetchone()
        ob = con.execute('select count(*) from pending_uploads_table').fetchone()[0]
        st = con.execute("select upload_state, thumb_download_state, download_state, count(*) from vault_blobs_table "
                         "where deleted_at is null group by 1, 2, 3").fetchall()
        print(f'{prof}: ' + ', '.join(parts) + f' | vault {short(hdr[0]) if hdr else None} v{hdr[1] if hdr else "-"} | outbox {ob}')
        print(f'   live blobs (up, thumb, full): ' + ', '.join(f'{u}/{t}/{d}={n}' for u, t, d, n in st))
        files = os.listdir(os.path.join(base(prof), 'vault_media')) if os.path.isdir(os.path.join(base(prof), 'vault_media')) else []
        print(f'   vault_media files {len(files)} (full {len([f for f in files if not f.endswith(".thumb")])})')


def blob_ids(sel):
    ids = []
    for prof in PROFS:
        try:
            con = db(prof)
        except sqlite3.OperationalError:
            continue
        for s in sel:
            if s == 'all':
                q = con.execute('select id from vault_blobs_table').fetchall()
            elif s.startswith('ci:'):
                q = con.execute('select blob_id from photo_check_in_images_table where check_in_id = ?', (s[3:],)).fetchall()
            elif s.startswith('series:'):
                q = con.execute('select im.blob_id from photo_check_in_images_table im join photo_check_ins_table ci on ci.id = im.check_in_id '
                                'join photo_series_table s on s.id = ci.series_id where s.name = ?', (s[7:],)).fetchall()
            else:
                q = [(s,)]
            ids += [r[0] for r in q]
    return list(dict.fromkeys(ids))


def blobs(sel):
    for bid in blob_ids(sel):
        print(f'blob {bid}')
        for prof in PROFS:
            r = db(prof).execute('select vault_id, upload_state, download_state, thumb_download_state, version, deleted_at '
                                 'from vault_blobs_table where id = ?', (bid,)).fetchone()
            print(f'  {prof}: ' + (f'vault {short(r[0])} up {r[1]} full {r[2]} thumb {r[3]} v{r[4]} del {r[5]}' if r else 'no row')
                  + f' | files {local(prof, bid)}')
        if cloud:
            d = cloud_doc('vault_blobs', bid)
            print('  cloud doc: ' + ('none' if d is None else f'v{d.get("version")} del {d.get("deletedAt")} fields {sorted(d)}'))
            print(f'  storage: {obj(bid)} / {obj(bid + ".thumb")}')


def checkin(cid):
    for prof in PROFS:
        con = db(prof)
        r = con.execute('select series_id, taken_on, note_ciphertext is not null, vault_id, version, updated_at, deleted_at '
                        'from photo_check_ins_table where id = ?', (cid,)).fetchone()
        print(f'{prof}: ' + (f'series {short(r[0])} on {r[1][:10]} note {bool(r[2])} vault {short(r[3])} v{r[4]} upd {r[5]} del {r[6]}' if r else 'no row'))
        for im in con.execute('select id, angle_id, blob_id, version, deleted_at, align_scale, align_dx from photo_check_in_images_table '
                              'where check_in_id = ? order by angle_id, created_at', (cid,)):
            print(f'    image {short(im[0])} angle {short(im[1])} blob {short(im[2])} v{im[3]} del {im[4]} scale {im[5]} dx {im[6]}')
    if cloud:
        d = cloud_doc('photo_check_ins', cid)
        print('cloud: ' + ('none' if d is None else ' '.join(f'{k}={str(v)[:40]}' for k, v in sorted(d.items()))))
    blobs([f'ci:{cid}'])


def storage():
    n, tok, hits, names = 0, None, 0, []
    while True:
        u = f'https://storage.googleapis.com/storage/v1/b/{BUCKET}/o?prefix=' + urllib.parse.quote(f'users/{UID}/vault_media/') + '&fields=items(name),nextPageToken&maxResults=1000'
        j = req(u + ('&pageToken=' + tok if tok else ''))
        names += [it['name'].rsplit('/', 1)[1] for it in j.get('items', [])]
        tok = j.get('nextPageToken')
        if not tok: break
    for nm in names:
        head = req(f'https://storage.googleapis.com/storage/v1/b/{BUCKET}/o/' + urllib.parse.quote(f'users/{UID}/vault_media/{nm}', safe='') + '?alt=media', {'Range': 'bytes=0-15'}, raw=True)
        m = magic(head) if isinstance(head, bytes) else None
        if m:
            hits += 1; print('MAGIC', m, nm)
    print(f'storage vault_media objects {len(names)} (full {len([x for x in names if not x.endswith(".thumb")])}), image-magic {hits}')


cmd = args[0] if args else 'counts'
if cmd == 'counts': counts()
elif cmd == 'blobs': blobs(args[1:])
elif cmd == 'checkin': checkin(args[1])
elif cmd == 'storage': storage()
