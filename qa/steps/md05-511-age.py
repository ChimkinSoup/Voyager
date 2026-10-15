"""MD-5.11 (simulated retention): with the profile's app STOPPED, move tombstones' deleted_at and
updated_at 40 days back, so the next launch's purgeExpiredDeleted takes them.

    python qa/steps/md05-511-age.py <profile> [--show]

Rows: dream md5-dream-c, transaction md5-tx-c1 (ordinary tombstones). The erased row md5-tx-a1
(deleted_at = epoch) only gets its updated_at aged, to check erased rows are never purged.
"""
import os, sqlite3, sys

ROWS = [('dream_entries_table', 'md5-dream-c'), ('transactions_table', 'md5-tx-c1'), ('transactions_table', 'md5-tx-a1')]
OLD = '2026-09-03T12:00:00.000Z'
p = sys.argv[1]
path = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{p}', 'voyager.sqlite')
show = '--show' in sys.argv
con = sqlite3.connect('file:' + path.replace('\\', '/') + ('?mode=ro' if show else ''), uri=True, timeout=10)
for t, id in ROWS:
    if not show:
        if id == 'md5-tx-a1':
            con.execute(f'update {t} set updated_at = ? where id = ?', (OLD, id))
        else:
            con.execute(f'update {t} set deleted_at = ?, updated_at = ? where id = ? and deleted_at is not null', (OLD, OLD, id))
    print(p, t, con.execute(f'select id, version, deleted_at, updated_at from {t} where id = ?', (id,)).fetchone())
if not show:
    con.commit()
