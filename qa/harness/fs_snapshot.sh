#!/usr/bin/env bash
# Read-only snapshot of the QA account's collections: per collection, each
# document id with its _serverWrittenAt. Usage: fs_snapshot.sh <uid> <out.json>
# QA accounts only (see TEST_PLAN.md "Fix verification"). Added 2026-09-30.
U="$1"
T=$(gcloud auth print-access-token)
OUT="$2"
TMPD="${TMPDIR:-/tmp}/fs_snapshot_pages"
mkdir -p "$TMPD"
rm -f "$TMPD"/*.json
for c in journals journal_entries dream_entries todo_lists todo_tasks calendars calendar_events trackers tracker_values transactions budgets savings_goals assets asset_valuations bucket_list_items job_applications job_stages job_categories job_seasons ranking_categories ranking_parents ranking_children leetcode_problems study_decks study_cards exercises workout_sessions workout_set_logs custom_quotes pinned_notes dismissed_notifications scheduled_reminder_rules device_registrations tag_colors custom_words flagged_words snippets settings; do
  tok=""; n=0
  while :; do
    curl -s -G "https://firestore.googleapis.com/v1/projects/voyager-db9de/databases/%28default%29/documents/users/$U/$c?pageSize=300&mask.fieldPaths=_serverWrittenAt${tok:+&pageToken=$tok}" -H "Authorization: Bearer $T" -o "$TMPD/${c}__$n.json"
    tok=$(python -c "import json,sys;print(json.load(open(sys.argv[1])).get('nextPageToken',''))" "$TMPD/${c}__$n.json")
    n=$((n+1))
    [ -z "$tok" ] && break
  done
done
python - "$TMPD" "$OUT" <<'EOF'
import json,sys,glob,os
d,out=sys.argv[1],sys.argv[2]
res={}
for f in glob.glob(os.path.join(d,'*.json')):
    c=os.path.basename(f).split('__')[0]
    j=json.load(open(f))
    for doc in j.get('documents',[]):
        res.setdefault(c,{})[doc['name'].split('/')[-1]]=doc.get('fields',{}).get('_serverWrittenAt',{}).get('timestampValue')
    res.setdefault(c,{})
json.dump(res,open(out,'w'),indent=1,sort_keys=True)
for c in sorted(res):
    ts=[t for t in res[c].values() if t]
    print(f"{c}: {len(res[c])} docs, newest {max(ts) if ts else '-'}")
EOF
