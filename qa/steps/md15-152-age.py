"""MD-15.2 (simulated retention): move the MD-15 tombstones' deleted_at 40 days back on ONE
profile, with the app running (the startup purge would otherwise take them before the Dev
tool can be tried). Only deleted_at changes; version and updated_at stay as synced.

    python qa/steps/md15-152-age.py <profile> [--show]
"""
import os, sqlite3, sys

ROWS = [('journal_entries_table', 'md15-je-12'), ('todo_tasks_table', 'md15-task-12'),
        ('calendar_events_table', 'md15-ev-12'), ('dream_entries_table', 'md15-dream-04')]
OLD = '2026-09-03T12:00:00.000Z'
p = sys.argv[1]
show = '--show' in sys.argv
path = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{p}', 'voyager.sqlite')
con = sqlite3.connect('file:' + path.replace('\\', '/') + ('?mode=ro' if show else ''), uri=True, timeout=10)
for t, id in ROWS:
    if not show:
        con.execute(f'update {t} set deleted_at = ? where id = ? and deleted_at is not null', (OLD, id))
    print(p, t, con.execute(f'select id, version, deleted_at, updated_at from {t} where id = ?', (id,)).fetchone())
if not show:
    con.commit()
