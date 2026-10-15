#!/bin/bash
# MD-4.2: both Force offline, each sets the same fields (md04-42-set), the first
# saver 3 s before the second; then <firstOnline> reconnects, then the other.
# usage: bash qa/steps/md04-42.sh <tag> <firstSaver qa|qb> <firstOnline qa|qb>
tag=$1; s1=$2; o1=$3
other() { [ $1 = qa ] && echo qb || echo qa; }
P="python qa/steps/md4pair.py"; D=features/dev/dev_page.dart; L=features/trash/trash_item_detail.dart
$P $D qa/steps/md-offline-on.dart.txt --tag off$tag | grep -v gap
sleep 2
$P $L qa/steps/md04-42-set.dart.txt --tag $tag --only $s1 | tee /dev/stderr | grep -q ": OK" || exit 1; sleep 3
$P $L qa/steps/md04-42-set.dart.txt --tag $tag --only $(other $s1) | tee /dev/stderr | grep -q ": OK" || exit 1
sleep 3; echo "--- offline state"; bash qa/steps/md04-show4.sh 0 | grep -v "^MD4SHOW"
$P $D qa/steps/md-offline-off.dart.txt --tag on1$tag --only $o1; echo "--- $o1 online $(date +%T)"; sleep 25
$P $D qa/steps/md-offline-off.dart.txt --tag on2$tag --only $(other $o1); echo "--- $(other $o1) online $(date +%T)"; sleep 25
echo "--- end"; bash qa/steps/md04-show4.sh 60
