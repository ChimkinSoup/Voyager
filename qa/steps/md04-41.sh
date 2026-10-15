#!/bin/bash
# MD-4.1: each kind, B saves later (delay 0) then A saves later (delay -40).
# usage: bash qa/steps/md04-41.sh <kind> <table> <id> <coll> <cols> <fields>
k=$1; shift
L=features/trash/trash_item_detail.dart
for d in 0 -40; do
  tag="${k}$([ $d = 0 ] && echo b || echo a)"
  python qa/steps/md4pair.py $L qa/steps/md04-41-$k.dart.txt --tag $tag --delay-ms $d
  python qa/steps/md4show.py "$@" --wait 15
  sleep 2
done
