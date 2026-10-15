"""Read-only query on one or more profile DBs.

    python qa/steps/md-q.py qa,qb "select ..."
"""
import os, sqlite3, sys

for prof in sys.argv[1].split(','):
    db = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)
    for row in con.execute(sys.argv[2]):
        print(prof, row)
