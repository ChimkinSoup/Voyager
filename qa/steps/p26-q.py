import sqlite3, os, sys
sys.stdout.reconfigure(encoding='utf-8')
c = sqlite3.connect('file:' + os.environ['APPDATA'] + '/Voyager/voyager/voyager.sqlite?mode=ro', uri=True)
c.execute('pragma busy_timeout=5000')
if len(sys.argv) > 1 and sys.argv[1] == 'counts':
    for (t,) in c.execute("select name from sqlite_master where type='table' and name like '%_table' order by name").fetchall():
        cols = [r[1] for r in c.execute(f'pragma table_info({t})')]
        n = c.execute(f'select count(*) from {t}').fetchone()[0]
        live = c.execute(f'select count(*) from {t} where deleted_at is null').fetchone()[0] if 'deleted_at' in cols else ''
        if n: print(t, n, live)
    sys.exit()
for sql in sys.argv[1:]:
    for row in c.execute(sql).fetchall():
        print(row)
