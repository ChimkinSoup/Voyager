"""MD-5.10: live child rows whose parent row is deleted (or missing), on each profile.

    python qa/steps/md05-orphans.py [qa qb]
"""
import os, sqlite3, sys

PAIRS = [  # child table, fk column, parent table
    ('journal_entries_table', 'journal_id', 'journals_table'),
    ('todo_tasks_table', 'list_id', 'todo_lists_table'),
    ('todo_tasks_table', 'parent_task_id', 'todo_tasks_table'),
    ('calendar_events_table', 'calendar_id', 'calendars_table'),
    ('study_decks_table', 'parent_folder_id', 'study_folders_table'),
    ('study_cards_table', 'deck_id', 'study_decks_table'),
    ('goal_allocations_table', 'goal_id', 'savings_goals_table'),
    ('asset_valuations_table', 'asset_id', 'assets_table'),
    ('ranking_children_table', 'parent_id', 'ranking_parents_table'),
]

for p in sys.argv[1:] or ['qa', 'qb']:
    path = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{p}', 'voyager.sqlite')
    con = sqlite3.connect('file:' + path.replace('\\', '/') + '?mode=ro', uri=True, timeout=10)
    total = 0
    for child, fk, parent in PAIRS:
        rows = con.execute(
            f"select c.id, c.{fk}, case when pr.id is null then 'missing' else 'deleted' end from {child} c "
            f"left join {parent} pr on pr.id = c.{fk} where c.deleted_at is null and c.{fk} is not null "
            f"and (pr.id is null or pr.deleted_at is not null)").fetchall()
        for r in rows:
            print(f'ORPHAN {p} {child}: {r}')
        total += len(rows)
    print(f'ORPHANS {p}: {total}')
