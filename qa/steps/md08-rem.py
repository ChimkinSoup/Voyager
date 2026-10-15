"""MD-8: one reminder source's delivery state and history on A and B (and the
cloud copy of the state), plus Voyager's Windows toasts since a time.

    python qa/steps/md08-rem.py <source key or rule id> [--since HH:MM] [--cloud]

A bare rule id is read as `rule:<id>`. Device ids are shortened to A / B (by
each profile's settings_table.device_id). Toasts come from Windows'
notification store (read-only); both profiles post as Voyager.App, so a toast
can't be told apart by instance: count them against the osFired lines.
"""
import argparse, datetime, json, os, re, sqlite3, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument('key'); ap.add_argument('--since'); ap.add_argument('--cloud', action='store_true')
a = ap.parse_args()
key = a.key if ':' in a.key else f'rule:{a.key}'


def con(prof):
    db = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    return sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)


names = {}
for p, n in (('qa', 'A'), ('qb', 'B')):
    names[con(p).execute('select device_id from settings_table').fetchone()[0]] = n


def local(ts):
    if not ts:
        return ts
    t = datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))
    return t.astimezone().strftime('%H:%M:%S.%f')[:-3]


for p, n in (('qa', 'A'), ('qb', 'B')):
    c = con(p)
    st = c.execute('select status, occurrence_key, snooze_until, acked_at, version, updated_at from reminder_delivery_states_table where id=?', (key,)).fetchone()
    if st:
        print(f'{n} state: {st[0]} occ={st[1]} snooze={local(st[2])} acked={local(st[3])} v{st[4]} upd={local(st[5])}')
    else:
        print(f'{n} state: none')
    for r in c.execute('select at, device_id, event_type, occurrence_key, detail, deleted_at from reminder_delivery_logs_table where delivery_state_id=? order by at', (key,)):
        print(f'   {n} log {local(r[0])} by {names.get(r[1], r[1][:8])} {r[2]} occ={r[3]} {r[4] or ""}{" DELETED" if r[5] else ""}')

if a.cloud:
    uid = os.environ.get('MD_UID')
    if uid:
        out = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), 'md07-doc.py'), 'reminder_delivery_states', key],
                             capture_output=True, text=True)
        print('cloud state:', out.stdout.strip() or out.stderr.strip())

if a.since:
    h, m = map(int, a.since.split(':'))
    since = datetime.datetime.now().replace(hour=h, minute=m, second=0, microsecond=0)
    db = os.path.join(os.environ['LOCALAPPDATA'], 'Microsoft', 'Windows', 'Notifications', 'wpndatabase.db')
    w = sqlite3.connect('file:' + db.replace('\\', '/') + '?mode=ro', uri=True, timeout=10)
    rows = w.execute("select n.ArrivalTime, n.Payload from Notification n join NotificationHandler h on n.HandlerId = h.RecordId "
                     "where h.PrimaryId = 'Voyager.App' order by n.ArrivalTime").fetchall()
    for at, payload in rows:
        t = datetime.datetime(1601, 1, 1) + datetime.timedelta(microseconds=at / 10)
        t = t.replace(tzinfo=datetime.timezone.utc).astimezone().replace(tzinfo=None)
        if t < since:
            continue
        text = payload.decode('utf-8', 'replace') if isinstance(payload, bytes) else str(payload)
        texts = re.findall(r'<text[^>]*>(.*?)</text>', text)
        print(f'toast {t:%H:%M:%S} {" | ".join(texts)}')
