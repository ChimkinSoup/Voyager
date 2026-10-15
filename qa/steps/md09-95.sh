#!/bin/bash
# MD-9.5: A bulk-writes <n> tasks (md09-95.dart.txt) one push each; B watches. Samples A's outbox / B's
# rows every 5 s, B's perf_stall.log growth, and times B getting all of them.
n=${1:-320}; PL="$APPDATA/Voyager/voyager-profile-qb/logs/perf_stall.log"
s0=$(stat -c %s "$PL"); sleep 30; s1=$(stat -c %s "$PL"); echo "baseline 30 s idle: perf_stall.log +$((s1-s0)) bytes"
python qa/harness/wait_row.py qb "select count(*) from todo_tasks_table where id like 'md9b-task-%' having count(*) >= $n" 900 > qa/logs/md09wr-qb.txt &
W=$!; t0=$(date +%s)
python qa/steps/md4pair.py features/trash/trash_item_detail.dart qa/steps/md09-95.dart.txt --tag $n --only qa
grep 'MD95 gate' $(ls -t qa/logs/run-qa-*.exe.log | head -1) | tail -1
for i in $(seq 1 120); do
  a=$(python qa/steps/md-q.py qa "select count(*) from pending_uploads_table" | grep -o '[0-9]*,' | tr -d ,)
  b=$(python qa/steps/md-q.py qb "select count(*) from todo_tasks_table where id like 'md9b-task-%'" | grep -o '[0-9]*,' | tr -d ,)
  echo "+$(( $(date +%s) - t0 ))s A outbox $a, B has $b"
  [ "$a" = 0 ] && [ "$b" = "$n" ] && break; sleep 5
done
wait $W; cat qa/logs/md09wr-qb.txt
s2=$(stat -c %s "$PL"); echo "perf_stall.log during the run: +$((s2-s1)) bytes"
