"""MD-9.8: poll A's versions/titles of md9-task-04..08 every 100 ms for <secs>; report any version that goes down
and every change seen, in order.   python qa/steps/md09-98-mon.py <secs> [profile]"""
import os, sqlite3, sys, time
secs = float(sys.argv[1]); prof = sys.argv[2] if len(sys.argv) > 2 else 'qa'
db = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
last, changes, drops, t0 = {}, 0, 0, time.time()
while time.time() - t0 < secs:
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=10)
    for id, v, t in con.execute("select id, version, title from todo_tasks_table where id in ('md9-task-04','md9-task-05','md9-task-06','md9-task-07','md9-task-08') order by id"):
        if last.get(id) != (v, t):
            changes += 1
            if id in last and v < last[id][0]:
                drops += 1; print(f'DROP {id}: v{last[id][0]} -> v{v}')
            print(f'+{time.time()-t0:6.2f}s {id} v{v} {t}')
            last[id] = (v, t)
    con.close(); time.sleep(0.1)
print(f'MD98MON {changes} changes, {drops} version drops')
