# Phase 28A: hand count of every photo series' stats from SQLite (read-only),
# independent of the app: periods (weeks from Monday), done / missed / due,
# streaks, counts, first / latest. Usage: p28-stats.py [today YYYY-MM-DD]
import datetime as dt
import os
import sqlite3
import sys

sys.stdout.reconfigure(encoding='utf-8')
P = os.path.expandvars(r'%APPDATA%\Voyager\voyager-profile-qa\voyager.sqlite')
c = sqlite3.connect('file:' + P + '?mode=ro', uri=True)
today = dt.date.fromisoformat(sys.argv[1]) if len(sys.argv) > 1 else dt.date.today()


def start(d, cad):
    if cad == 'daily':
        return d
    if cad == 'weekly':
        return d - dt.timedelta(days=d.weekday())
    if cad == 'monthly':
        return dt.date(d.year, d.month, 1)
    return dt.date(d.year, 1, 1)


def nxt(d, cad):
    if cad == 'daily':
        return d + dt.timedelta(days=1)
    if cad == 'weekly':
        return d + dt.timedelta(days=7)
    if cad == 'monthly':
        return dt.date(d.year + (d.month == 12), d.month % 12 + 1, 1)
    return dt.date(d.year + 1, 1, 1)


def local_date(iso):
    # created_at: UTC instant -> local date (this PC's zone).
    t = dt.datetime.fromisoformat(iso.replace('Z', '+00:00'))
    return t.astimezone().date()


for sid, name, cad, created in c.execute(
        'select id, name, cadence, created_at from photo_series_table where deleted_at is null order by sort_order'):
    rows = c.execute(
        'select ci.id, ci.taken_on, count(im.id) from photo_check_ins_table ci '
        'left join photo_check_in_images_table im on im.check_in_id = ci.id and im.deleted_at is null '
        'and im.angle_id in (select id from photo_series_angles_table where deleted_at is null) '
        'where ci.series_id = ? and ci.deleted_at is null group by ci.id', (sid,)).fetchall()
    dates = [dt.date.fromisoformat(r[1][:10]) for r in rows]
    withp = [(dt.date.fromisoformat(r[1][:10]), r[2]) for r in rows if r[2] > 0]
    done = {start(d, cad) for d, _ in withp}
    cur = start(today, cad)
    s = start(local_date(created), cad)
    if dates:
        s = min(s, start(min(dates), cad))
    s = min(s, cur)
    states = []
    p = s
    while p <= cur:
        states.append('D' if p in done else ('U' if p == cur else 'M'))
        p = nxt(p, cad)
    best = run = 0
    for st in states:
        run = run + 1 if st == 'D' else 0
        best = max(best, run)
    streak = 0
    for st in reversed(states):
        if st == 'D':
            streak += 1
        elif st != 'U':
            break
    print(f"{name[:40]!r} {cad}: periods={len(states)} checkins={len(withp)} photos={sum(n for _, n in withp)} "
          f"streak={streak} best={best} missed={states.count('M')} current={states[-1]} "
          f"first={min(dates) if dates else None} latest={max(dates) if dates else None} (rows incl. no-photo={len(rows)})")
