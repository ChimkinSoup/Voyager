"""MD-5: every md5-*-<set> row on A and B: version, deleted_at (E = erased epoch), per table.

    python qa/steps/md05-rows.py <set> [--diff]

Prints one line per row: table id  A:v/del  B:v/del, and MD5ROWS SAME/DIFF.
"""
import os, sqlite3, sys

TABLES = ['journals_table', 'journal_entries_table', 'dream_entries_table', 'todo_lists_table', 'todo_tasks_table',
          'calendars_table', 'calendar_events_table', 'trackers_table', 'tracker_values_table',
          'transactions_table', 'savings_goals_table', 'goal_allocations_table', 'assets_table',
          'asset_valuations_table', 'study_folders_table', 'study_decks_table', 'study_cards_table',
          'leet_code_problems_table', 'ranking_categories_table', 'ranking_parents_table', 'ranking_children_table',
          'exercises_table', 'bucket_list_items_table', 'job_applications_table', 'job_status_events_table']


def db(p):
    path = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{p}', 'voyager.sqlite')
    return sqlite3.connect('file:' + path.replace('\\', '/') + '?mode=ro', uri=True, timeout=10)


def rows(p, s):
    con = db(p); out = {}
    names = {r[0] for r in con.execute("select name from sqlite_master where type='table'")}
    for t in TABLES:
        if t not in names:
            continue
        for id, v, d in con.execute(f"select id, version, deleted_at from {t} where id like 'md5-%' and (id like ? or id like ?)", (f'%-{s}', f'%-{s}_')):
            dd = '-' if d is None else ('E' if str(d).startswith('1970') or str(d) == '0' else 'del')
            out[(t, id)] = f'v{v}/{dd}'
    return out


s = sys.argv[1]
a, b = rows('qa', s), rows('qb', s)
same = True
for k in sorted(set(a) | set(b)):
    flag = '' if a.get(k) == b.get(k) else '   <-- DIFF'
    same &= not flag
    print(f'{k[0][:-6]:24} {k[1]:16} A:{a.get(k, "none"):10} B:{b.get(k, "none"):10}{flag}')
print('MD5ROWS', 'SAME' if same else 'DIFF', len(a), len(b))
