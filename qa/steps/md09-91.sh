#!/bin/bash
# MD-9.1 / 9.2: A goes Force offline and runs <specA> (md09-ops: NNe/NNd/NNn per
# kind); B, online, runs <specB>. Then A comes back online; time B receiving A's
# edits and A's outbox draining.
# ORDER=ba runs B's ops first (A then saves later, offline).
# usage: bash qa/steps/md09-91.sh <labA> <specA> <labB> <specB> <probeIdx> [holdSecs]
labA=$1; specA=$2; labB=$3; specB=$4; probe=$5; hold=${6:-60}
P="python qa/steps/md4pair.py"; D=features/dev/dev_page.dart; L=features/trash/trash_item_detail.dart
export MD_UID=8f35J5WsmQeAvNncAnpKMvQwsdc2
$P $D qa/steps/md-offline-on.dart.txt --tag off$labA --only qa
sleep 2
if [ "$ORDER" = ba ]; then $P $L qa/steps/md09-ops.dart.txt --tag ${labB}_$specB --only qb; sleep 1; $P $L qa/steps/md09-ops.dart.txt --tag ${labA}_$specA --only qa; else $P $L qa/steps/md09-ops.dart.txt --tag ${labA}_$specA --only qa; $P $L qa/steps/md09-ops.dart.txt --tag ${labB}_$specB --only qb; fi
echo "--- $(date +%T) both wrote; holding A offline ${hold}s"; sleep $hold
python qa/steps/md09-count.py
echo "--- A has B's task $probe? (expect old)"; python qa/steps/md-q.py qa,qb "select id, version, title from todo_tasks_table where id='md9-task-$probe'"
python qa/harness/wait_row.py qb "select title from todo_tasks_table where id like 'md9-task-%' and title like '% $labA'" 300 > qa/logs/md09wr.txt &
WR=$!
$P $D qa/steps/md-offline-off.dart.txt --tag on$labA --only qa; echo "--- $(date +%T.%N) A online"
wait $WR; cat qa/logs/md09wr.txt
for i in $(seq 1 40); do
  q=$(python qa/steps/md-outbox.py qa | grep -o '[0-9]* rows' | cut -d' ' -f1)
  [ "$q" = 0 ] && break; sleep 3
done
echo "--- $(date +%T) A outbox $q"; sleep 8
python qa/steps/md09-count.py
python qa/steps/md09-cloud.py
python qa/harness/dbdiff.py qa qb --show=8 | tail -12
