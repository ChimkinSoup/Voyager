"""MD-18 read-only SQL on both profiles: python qa/steps/md18-q.py "<sql>" [qa|qb]"""
import os, sqlite3, sys

sys.stdout.reconfigure(encoding='utf-8')
for prof in (sys.argv[2:] or ['qa', 'qb']):
    p = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    con = sqlite3.connect(f'file:{p}?mode=ro', uri=True, timeout=10)
    cur = con.execute(sys.argv[1])
    print(f'== {prof}: ' + ' | '.join(d[0] for d in cur.description))
    for r in cur.fetchall():
        print('  ' + ' | '.join('-' if v is None else str(v) for v in r))
