"""MD-16: built-in / seed rows on each profile: counts, ids, versions, and duplicate names.

    python qa/steps/md16-seeds.py [qa qb] [--rows]
"""
import os, sqlite3, sys

TABLES = [
    ('job_stages_table', 'name'), ('job_companies_table', 'name'), ('exercises_table', 'name'),
    ('workout_plans_table', 'id'), ('calendars_table', 'name'), ('journals_table', 'name'),
    ('todo_lists_table', 'name'),
]
args = [a for a in sys.argv[1:] if not a.startswith('--')] or ['qa', 'qb']
rows = '--rows' in sys.argv
for prof in args:
    db = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)
    for t, namecol in TABLES:
        cols = [r[1] for r in con.execute(f'PRAGMA table_info({t})')]
        dcol = 'deleted_at' if 'deleted_at' in cols else 'NULL'
        live = con.execute(f'SELECT count(*) FROM {t} WHERE {dcol} IS NULL').fetchone()[0]
        total = con.execute(f'SELECT count(*) FROM {t}').fetchone()[0]
        seedish = con.execute(f"SELECT count(*) FROM {t} WHERE id LIKE 'seed-%' OR id LIKE '__legacy%' OR id LIKE 'workout_plan_%'").fetchone()[0]
        vers = con.execute(f'SELECT group_concat(v) FROM (SELECT DISTINCT version v FROM {t})').fetchone()[0]
        dups = con.execute(f'SELECT {namecol}, count(*) FROM {t} WHERE {dcol} IS NULL GROUP BY lower({namecol}) HAVING count(*) > 1').fetchall()
        print(f'{prof} {t}: live {live}/{total}, fixed-id {seedish}, versions [{vers}], dup names {dups or "none"}')
        if rows and t not in ('job_companies_table',):
            for r in con.execute(f'SELECT id, {namecol}, version, {dcol} FROM {t} ORDER BY id'):
                print('   ', r)
