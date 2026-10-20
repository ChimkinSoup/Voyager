# Phase 28B (app stopped): move deleted_at of photo check-ins and their images
# back N days.   python p28b-age.py <checkInId>:<days> ...
import datetime as dt, os, sqlite3, sys
P = os.path.expandvars(r'%APPDATA%\Voyager\voyager-profile-qa\voyager.sqlite')
c = sqlite3.connect(P)
now = dt.datetime.now(dt.timezone.utc)
for arg in sys.argv[1:]:
    cid, days = arg.split(':')
    stamp = (now - dt.timedelta(days=int(days))).strftime('%Y-%m-%dT%H:%M:%S.%fZ')
    a = c.execute('update photo_check_ins_table set deleted_at=? where id=? and deleted_at is not null', (stamp, cid)).rowcount
    b = c.execute('update photo_check_in_images_table set deleted_at=? where check_in_id=? and deleted_at is not null', (stamp, cid)).rowcount
    print(cid, days, stamp, a, b)
c.commit()
