"""MD-9.9 (simulated 7-day park): with the profile's app STOPPED, move every outbox row's added_at
<days> back (default 8), past OutboxSyncWorker.maxRetryAge (7 days).

    python qa/steps/md09-99-age.py <profile> [days] [--show]
"""
import os, sqlite3, sys
from datetime import datetime, timedelta, timezone

p = sys.argv[1]; days = int(next((a for a in sys.argv[2:] if a.isdigit()), 8)); show = '--show' in sys.argv
path = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{p}', 'voyager.sqlite')
con = sqlite3.connect('file:' + path +('?mode=ro' if show else ''), uri=True, timeout=10)
if not show:
    old = (datetime.now(timezone.utc) - timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%S.000000Z')
    con.execute('update pending_uploads_table set added_at = ?', (old,)); con.commit()
for r in con.execute('select collection_name, document_id, added_at, failure_reason from pending_uploads_table'):
    print(p, r)
