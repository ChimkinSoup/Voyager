"""MD-11.9 (simulated aging, app stopped): move media clocks back on one profile.

    python qa/steps/md11-age.py <qa|qb> <days> <mediaIdPrefix>[,<mediaIdPrefix>...]

For each matching asset: unreferenced_at (if set) and deleted_at (if set) move
back <days>, and so does deleted_at of its deleted references. Writes the
profile's DB, so the profile must be stopped.
"""
import datetime, os, sqlite3, sys

prof, days, prefixes = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(',')
db = os.path.join(os.environ['APPDATA'], 'Voyager', f'voyager-profile-{prof}', 'voyager.sqlite')
con = sqlite3.connect(db, timeout=10)
old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%S.000000Z')
for p in prefixes:
    for (mid,) in con.execute('select id from media_assets_table where id like ?', (p + '%',)).fetchall():
        con.execute('update media_assets_table set unreferenced_at = ? where id = ? and unreferenced_at is not null', (old, mid))
        con.execute('update media_assets_table set deleted_at = ? where id = ? and deleted_at is not null', (old, mid))
        con.execute('update media_references_table set deleted_at = ? where media_id = ? and deleted_at is not null', (old, mid))
        print(mid, con.execute('select unreferenced_at, deleted_at from media_assets_table where id = ?', (mid,)).fetchone(),
              con.execute('select count(*) from media_references_table where media_id = ? and deleted_at = ?', (mid, old)).fetchone()[0], 'refs aged')
con.commit()
