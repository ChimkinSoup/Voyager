# Phase 28B: Storage metadata (GCS JSON API, read-only) for vault blobs.
#   P28_UID=<uid> python p28b-vst.py <blobId> [...]   |  --list (count all vault_media objects)
import json, os, subprocess, sys, urllib.parse, urllib.request
BUCKET = 'voyager-db9de.firebasestorage.app'
UID = os.environ['P28_UID']
TOK = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()


def get(url):
    req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + TOK})
    try:
        return json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        return {'error': e.code}


if sys.argv[1] == '--list':
    n, tok, names = 0, None, set()
    while True:
        u = f'https://storage.googleapis.com/storage/v1/b/{BUCKET}/o?prefix=' + urllib.parse.quote(f'users/{UID}/vault_media/') + '&fields=items(name),nextPageToken&maxResults=1000'
        if tok:
            u += '&pageToken=' + tok
        j = get(u)
        for it in j.get('items', []):
            names.add(it['name'].rsplit('/', 1)[1])
        tok = j.get('nextPageToken')
        if not tok:
            break
    out = sys.argv[2] if len(sys.argv) > 2 else None
    if out:
        json.dump(sorted(names), open(out, 'w'))
    print('objects', len(names), 'full', len([x for x in names if not x.endswith('.thumb')]))
    sys.exit()
for b in sys.argv[1:]:
    for suf in ('', '.thumb'):
        j = get(f'https://storage.googleapis.com/storage/v1/b/{BUCKET}/o/' + urllib.parse.quote(f'users/{UID}/vault_media/{b}{suf}', safe=''))
        print(b + suf, j.get('error') or (j.get('size'), j.get('contentType'), j.get('updated')))
