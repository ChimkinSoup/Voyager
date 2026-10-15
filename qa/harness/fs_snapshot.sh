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
# 2026-10-12 (multi-device plan, O2): every collection in FirestoreCollections.records (62) plus settings.
# 2026-10-13 (MD-14): plus weather (current, forecast; server-written) and sync_locks.
for c in journals journal_entries dream_entries todo_lists todo_tasks todo_task_completions leetcode_problems leetcode_review_log leetcode_cheat_tabs leetcode_cheat_sections leetcode_cheat_entries study_folders study_decks study_cards study_review_log study_deck_links exercises workout_plans workout_plan_entries workout_sessions workout_set_logs custom_quotes snippets job_experience_snippets calendars calendar_events trackers tracker_values counter_adjustments transactions subscriptions budgets finance_categories assets asset_valuations contribution_rooms asset_room_events savings_goals goal_allocations pinned_notes dismissed_notifications device_registrations scheduled_reminder_rules entity_reminders reminder_delivery_states reminder_delivery_logs bucket_list_items job_applications job_status_events job_stages job_companies job_categories job_seasons ranking_categories ranking_parents ranking_children ranking_counts media_assets media_references tag_colors custom_words flagged_words settings weather sync_locks; do
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
