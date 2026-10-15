#!/bin/bash
# MD-10.1: B stopped; A edits / deletes / creates across 10 collections and erases
# two of the deleted rows; then B launches and its incremental pull should list
# only those documents.
# usage: bash qa/steps/md10-101.sh <tag>   (B must be running at the start)
tag=$1
P="python qa/steps/md4pair.py"; L=features/trash/trash_item_detail.dart
export MD_UID=zPXtMe1FRSOgFiJe3QDjExGwMFD3
export MD9_PREFIX=md10-
echo "--- B watermarks before"; python qa/steps/md-q.py qb "select count(*), max(changed_since), min(last_full_pull_at) from sync_watermarks_table"
powershell -NoProfile -Command "& C:\Users\Juno\Code\Voyager\qa\harness\stop.ps1 -Profile qb" | tail -2
echo "--- $(date +%T) B stopped"
$P $L qa/steps/md10-ops.dart.txt --tag ${tag}_01e02d --only qa
$P $L qa/steps/md10-new.dart.txt --tag $tag --only qa
sleep 5
$P $L qa/steps/md05-erase.dart.txt --tag md10-je-02+md10-tx-02 --only qa
sleep 10
python qa/steps/md-outbox.py qa
echo "--- $(date +%T) A done; launching B"
powershell -NoProfile -Command "& C:\Users\Juno\Code\Voyager\qa\harness\launch.ps1 -Profile qb" | tail -2
sleep 20
L2=$(ls -t qa/logs/run-qb-*.exe.log | head -1); echo "--- B log $L2"
grep -a "pullAll took\|startup sync took" $L2
python qa/steps/md09-count.py md10-
python qa/steps/md09-cloud.py
python qa/harness/dbdiff.py qa qb --show=8 | tail -12
