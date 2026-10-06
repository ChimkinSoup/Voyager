#!/usr/bin/env bash
# BUG-045 re-check (2026-10-05): the default calendar locally (read-only SQLite)
# and in Firestore (read-only REST GET). Usage: fx045-check.sh <uid>
U="$1"
python - <<'EOF'
import sqlite3, os
p = os.path.expandvars(r'%APPDATA%\Voyager\voyager\voyager.sqlite')
db = sqlite3.connect('file:' + p + '?mode=ro', uri=True)
print('local:', db.execute("select id,name,color_value,version,updated_at from calendars_table where id='__legacy_calendar__'").fetchall())
print('outbox:', db.execute('select count(*) from pending_uploads_table').fetchone()[0])
EOF
T=$(gcloud auth print-access-token)
curl -s "https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/%28default%29/documents/users/$U/calendars/legacy-default-calendar" -H "Authorization: Bearer $T" \
  | python -c "import json,sys; d=json.load(sys.stdin); f=d.get('fields',{}); print('cloud:', d.get('error',{}).get('status') or {k:list(v.values())[0] for k,v in f.items() if k in ('name','version','colorValue','_serverWrittenAt')})"
