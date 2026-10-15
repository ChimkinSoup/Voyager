#!/bin/bash
# MD-9.4: B rewrites task 04 / tx 04 once a second for ~40 s while A toggles Force offline 10x (on/off ~2 s apart).
P="python qa/steps/md4pair.py"; D=features/dev/dev_page.dart
$P features/trash/trash_item_detail.dart qa/steps/md09-94-b.dart.txt --tag storm --only qb &
BW=$!
sleep 1
for i in $(seq 1 10); do
  $P $D qa/steps/md-offline-on.dart.txt --tag t${i}on --only qa | grep -v ': OK'
  sleep 1.5
  $P $D qa/steps/md-offline-off.dart.txt --tag t${i}off --only qa | grep -v ': OK'
  sleep 1.5
  echo "toggle $i done $(date +%T)"
done
wait $BW
echo "--- B done $(date +%T)"
