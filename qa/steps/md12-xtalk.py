"""MD-12.4: does either profile DB hold the other account's ids? (read-only)

    python qa/steps/md12-xtalk.py <foreign prefix on qa> <foreign prefix on qb>
e.g. md12x- md12  (A on account 1 must hold no md12x-*; B on account 2 no md12-*/md12d-*)
"""
import os, sqlite3, sys


def scan(prof, prefix, exclude=None):
    p = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    con = sqlite3.connect(f'file:{p}?mode=ro', uri=True, timeout=10)
    hits = {}
    for (t,) in con.execute("select name from sqlite_master where type='table'"):
        cols = [r[1] for r in con.execute(f'pragma table_info("{t}")')]
        for col in cols:
            if col != 'id' and not col.endswith('_id'):
                continue
            q = f'select count(*) from "{t}" where "{col}" like ?' + (f' and "{col}" not like ?' if exclude else '')
            n = con.execute(q, (prefix + '%',) + ((exclude + '%',) if exclude else ())).fetchone()[0]
            if n:
                hits[f'{t}.{col}'] = n
    owner = con.execute('select local_owner_uid from settings_table').fetchone()[0]
    print(f'{prof} owner={owner} foreign "{prefix}" hits: {hits or "none"}')


scan('qa', sys.argv[1])
scan('qb', sys.argv[2], exclude='md12x-')
