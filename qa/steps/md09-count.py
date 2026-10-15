"""MD-9: live md9 rows per kind on A and B, plus outbox rows.

    python qa/steps/md09-count.py [prefix]      (default prefix md9-)
"""
import os, sqlite3, sys

pre = sys.argv[1] if len(sys.argv) > 1 else 'md9-'
TABLES = ['journal_entries_table', 'todo_tasks_table', 'transactions_table', 'calendar_events_table', 'study_cards_table']
for prof in ['qa', 'qb']:
    db = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)
    out = []
    for t in TABLES:
        live = con.execute(f"select count(*) from {t} where id like ? and deleted_at is null", (pre + '%',)).fetchone()[0]
        dead = con.execute(f"select count(*) from {t} where id like ? and deleted_at is not null", (pre + '%',)).fetchone()[0]
        out.append(f"{t.split('_table')[0]}={live}" + (f"(+{dead} del)" if dead else ''))
    q = con.execute('select count(*), sum(failure_reason is not null) from pending_uploads_table').fetchone()
    print(f"{prof}: {' '.join(out)} | outbox {q[0]} (parked {q[1] or 0})")
