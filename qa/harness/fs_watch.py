"""Read-only Firestore watcher for a few documents of one QA account.

  python qa/harness/fs_watch.py <uid> <seconds> <doc> [<doc> ...] [--every 0.25] [--fields a,b]

<doc> is a path under users/<uid>/, e.g. sync_locks/weather_fetch or
weather/current. Polls each document over REST (gcloud token, as
fs_snapshot.sh) and prints one line per change: local time, doc, its
updateTime (or MISSING) and the chosen fields (default: every field except
`periods`). The first line per doc is its state at start. Ends with a
per-doc count of changes seen. Added 2026-10-13 for MD-14 (weather lock).
A change between two polls that is undone before the next one is missed;
updateTime still shows the last write.
"""
import json, subprocess, sys, time, urllib.request, urllib.error
from datetime import datetime

args = [a for a in sys.argv[1:] if not a.startswith('--')]
opts = dict(a[2:].split('=', 1) for a in sys.argv[1:] if a.startswith('--') and '=' in a)
uid, secs, docs = args[0], float(args[1]), args[2:]
every = float(opts.get('every', '0.25'))
fields = opts.get('fields', '').split(',') if opts.get('fields') else None

token = subprocess.run('gcloud auth print-access-token', shell=True, capture_output=True, text=True).stdout.strip()
base = f'https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/(default)/documents/users/{uid}/'


def val(v):
    for k in ('stringValue', 'timestampValue', 'booleanValue'):
        if k in v: return v[k]
    if 'integerValue' in v: return int(v['integerValue'])
    if 'doubleValue' in v: return v['doubleValue']
    if 'nullValue' in v: return None
    if 'mapValue' in v: return '{map %d}' % len(v['mapValue'].get('fields', {}))
    return str(v)[:40]


def read(doc):
    req = urllib.request.Request(base + doc, headers={'Authorization': 'Bearer ' + token})
    try:
        j = json.load(urllib.request.urlopen(req, timeout=10))
    except urllib.error.HTTPError as e:
        if e.code == 404: return 'MISSING'
        return f'HTTP{e.code}'
    except Exception:  # timeouts, resets: skip this poll
        return 'HTTPERR'
    f = j.get('fields', {})
    keep = {k: val(v) for k, v in sorted(f.items()) if (k in fields if fields else k != 'periods')}
    return j['updateTime'] + ' ' + json.dumps(keep)


last, changes = {}, {d: 0 for d in docs}
end = time.time() + secs
while time.time() < end:
    for d in docs:
        s = read(d)
        if s.startswith('HTTP'):
            continue
        if last.get(d) != s:
            if d in last: changes[d] += 1
            print(datetime.now().strftime('%H:%M:%S.%f')[:-3], d, s, flush=True)
            last[d] = s
    time.sleep(every)
print('FS_WATCH END ' + ' '.join(f'{d}={n}' for d, n in changes.items()), flush=True)
