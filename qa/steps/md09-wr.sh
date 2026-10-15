#!/bin/bash
# MD-9: run md09-ops with <tag> on <writer>, timing arrival on <receiver> (wait_row on <sql>).
# usage: bash qa/steps/md09-wr.sh <receiver> "<sql>" <writer> <tag> [timeout]
python qa/harness/wait_row.py $1 "$2" ${5:-60} > qa/logs/md09wr-$1.txt &
W=$!; sleep 0.5
python qa/steps/md4pair.py features/trash/trash_item_detail.dart qa/steps/md09-ops.dart.txt --tag $4 --only $3
wait $W; cat qa/logs/md09wr-$1.txt
