import sqlite3, os, sys, time, datetime
# ob.py [seconds] [interval]: poll outbox count until 0 or timeout
dur = float(sys.argv[1]) if len(sys.argv) > 1 else 180
step = float(sys.argv[2]) if len(sys.argv) > 2 else 10
c = sqlite3.connect('file:' + os.environ['APPDATA'] + '/Voyager/voyager/voyager.sqlite?mode=ro', uri=True)
c.execute('pragma busy_timeout=5000')
end = time.time() + dur
while True:
    rows = c.execute('select collection_name, count(*), max(failure_reason) from pending_uploads_table group by collection_name').fetchall()
    n = sum(r[1] for r in rows)
    print(datetime.datetime.now().strftime('%H:%M:%S'), n, rows[:6], flush=True)
    if n == 0 or time.time() > end:
        break
    time.sleep(step)
