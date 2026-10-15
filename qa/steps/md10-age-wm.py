"""MD-10.5 / 10.6 (simulated aging): with the profile's app STOPPED, move every
sync watermark's last_full_pull_at <days> back (and changed_since too with --both).

    python qa/steps/md10-age-wm.py <profile> <days> [--both] [--show]

30+ days trips RemoteSyncService.catchUpIfAway (pull before the outbox drains);
7+ days makes the next pull a weekly full pull (_fullPullInterval).
"""
import os, sqlite3, sys
from datetime import datetime, timedelta, timezone

p = sys.argv[1]; days = int(sys.argv[2]); show = '--show' in sys.argv; both = '--both' in sys.argv
path = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{p}', 'voyager.sqlite')
con = sqlite3.connect('file:' + path + ('?mode=ro' if show else ''), uri=True, timeout=10)
if not show:
    shift = f'-{days} days'
    con.execute("update sync_watermarks_table set last_full_pull_at = strftime('%Y-%m-%dT%H:%M:%fZ', last_full_pull_at, ?)", (shift,))
    if both:
        con.execute("update sync_watermarks_table set changed_since = strftime('%Y-%m-%dT%H:%M:%fZ', changed_since, ?)", (shift,))
    con.commit()
r = con.execute('select count(*), min(last_full_pull_at), max(last_full_pull_at), min(changed_since), max(changed_since) from sync_watermarks_table').fetchone()
print(p, 'watermarks', r)
