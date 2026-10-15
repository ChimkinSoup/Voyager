"""O7 of qa/MULTI_DEVICE_SYNC_TEST_PLAN.md: wait for a row to appear.

Usage: python qa/harness/wait_row.py <db> "<sql>" <timeout_s>
  db: a profile name (qa, qb, ...) or a path to a voyager.sqlite.
Polls the read-only query every 250 ms until it returns at least one row, then
prints  WAIT_ROW OK <elapsed>s <first row>  (exit 0), or  WAIT_ROW TIMEOUT
<timeout>s  (exit 1). Elapsed is measured from when this script started.
"""
import os
import sqlite3
import sys
import time


def db_path(arg):
    if os.path.isfile(arg):
        return arg
    return os.path.join(os.environ['APPDATA'], 'Voyager', 'voyager-profile-' + arg, 'voyager.sqlite')


def main(db, sql, timeout):
    start = time.monotonic()
    uri = 'file:' + db_path(db).replace('\\', '/') + '?mode=ro'
    while True:
        try:
            con = sqlite3.connect(uri, uri=True, timeout=5)
            row = con.execute(sql).fetchone()
            con.close()
        except sqlite3.OperationalError:
            row = None
        elapsed = time.monotonic() - start
        if row is not None:
            print(f'WAIT_ROW OK {elapsed:.2f}s {row}')
            return 0
        if elapsed >= timeout:
            print(f'WAIT_ROW TIMEOUT {timeout}s')
            return 1
        time.sleep(0.25)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2], float(sys.argv[3])))
