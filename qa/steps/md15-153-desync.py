"""MD-15.3: make one journal entry out of sync on ONE profile (local title changed in SQLite,
nothing pushed), so Dev's "Compare all journal entries" flags it.

    python qa/steps/md15-153-desync.py <profile> <entry id> <new title>
"""
import os, sqlite3, sys

p, id, title = sys.argv[1], sys.argv[2], sys.argv[3]
path = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{p}', 'voyager.sqlite')
con = sqlite3.connect('file:' + path.replace('\\', '/'), uri=True, timeout=10)
con.execute('update journal_entries_table set title = ? where id = ?', (title, id))
con.commit()
print(p, con.execute('select id, version, title from journal_entries_table where id = ?', (id,)).fetchone())
