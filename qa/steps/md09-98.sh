#!/bin/bash
# MD-9.8: A offline; B makes 50 edits (tasks 04-08 x10 rounds); then A queues its own later edits of 04 and 05;
# A reconnects while md09-98-mon.py watches A's versions.
P="python qa/steps/md4pair.py"; D=features/dev/dev_page.dart; L=features/trash/trash_item_detail.dart
$P $D qa/steps/md-offline-on.dart.txt --tag off98 --only qa; sleep 2
$P $L qa/steps/md09-98-b.dart.txt --tag r8b --only qb
sleep 2; $P $L qa/steps/md09-ops.dart.txt --tag a8_04e05e --only qa
sleep 50; python qa/steps/md-outbox.py qa qb
python qa/steps/md09-98-mon.py 40 > qa/logs/md09-98-mon.txt &
M=$!; sleep 1
$P $D qa/steps/md-offline-off.dart.txt --tag on98 --only qa; echo "online $(date +%T)"
wait $M; cat qa/logs/md09-98-mon.txt
python qa/steps/md-q.py qa,qb "select id, version, title from todo_tasks_table where id between 'md9-task-04' and 'md9-task-08' order by id"
python qa/steps/md-outbox.py qa qb
grep -n 'pullAll took' $(ls -t qa/logs/run-qa-*.exe.log | head -1) | tail -2
