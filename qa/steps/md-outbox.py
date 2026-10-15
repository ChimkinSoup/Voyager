"""Outbox (O3) for each named profile: queued and parked rows in pending_uploads_table.

    python qa/steps/md-outbox.py qa qb
"""
import os, sqlite3, sys

for prof in sys.argv[1:] or ['qa', 'qb']:
    db = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
    cols = [r[1] for r in con.execute('PRAGMA table_info(pending_uploads_table)')]
    total = con.execute('SELECT count(*) FROM pending_uploads_table').fetchone()[0]
    parked = con.execute('SELECT count(*) FROM pending_uploads_table WHERE failure_reason IS NOT NULL').fetchone()[0] if 'failure_reason' in cols else '?'
    print(f'OUTBOX {prof}: {total} rows ({parked} parked)')
