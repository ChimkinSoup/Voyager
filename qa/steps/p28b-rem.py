# Phase 28B: photo-series reminder deliveries (profile qa, read-only) and
# Voyager's Windows toasts since HH:MM.   python p28b-rem.py HH:MM [name-like]
import datetime, os, re, sqlite3, sys
since = datetime.datetime.combine(datetime.date.today() if len(sys.argv) < 4 else datetime.date.fromisoformat(sys.argv[3]), datetime.time.fromisoformat(sys.argv[1]))
like = sys.argv[2] if len(sys.argv) > 2 else 'P28B R%'
P = os.path.expandvars(r'%APPDATA%\Voyager\voyager-profile-qa\voyager.sqlite')
c = sqlite3.connect('file:' + P + '?mode=ro', uri=True)
names = dict(c.execute("select id, name from photo_series_table where name like ?", (like,)))
for sid, name in sorted(names.items(), key=lambda x: x[1]):
    rows = c.execute("select at, event_type, occurrence_key, detail from reminder_delivery_logs_table where source_id = ? order by at", (sid,)).fetchall()
    st = c.execute("select * from reminder_delivery_states_table where source_key = ?", ('photoSeries:' + sid,)).fetchall() if 0 else []
    print(f'{name}: ' + ('; '.join(f'{r[0][11:19]} {r[1]} {r[2]}{(" " + r[3]) if r[3] else ""}' for r in rows) or '-'))
db = os.path.join(os.environ['LOCALAPPDATA'], 'Microsoft', 'Windows', 'Notifications', 'wpndatabase.db')
w = sqlite3.connect('file:' + db.replace(os.sep, '/') + '?mode=ro', uri=True, timeout=10)
for at, payload in w.execute("select n.ArrivalTime, n.Payload from Notification n join NotificationHandler h on n.HandlerId = h.RecordId where h.PrimaryId = 'Voyager.App' order by n.ArrivalTime"):
    t = (datetime.datetime(1601, 1, 1) + datetime.timedelta(microseconds=at / 10)).replace(tzinfo=datetime.timezone.utc).astimezone().replace(tzinfo=None)
    if t >= since:
        text = payload.decode('utf-8', 'replace') if isinstance(payload, bytes) else str(payload)
        print(f'toast {t:%H:%M:%S} ' + ' | '.join(re.findall(r'<text[^>]*>(.*?)</text>', text)))
