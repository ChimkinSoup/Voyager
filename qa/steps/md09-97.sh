#!/bin/bash
# MD-9.7: A Force offline + 5 edits; every 15 s log both devices' connectivity / gate / outbox
# (md09-97-state) and shoot both; then A back online and the same until A is clear.
P="python qa/steps/md4pair.py"; D=features/dev/dev_page.dart; L=features/trash/trash_item_detail.dart
st() { $P $D qa/steps/md09-97-state.dart.txt --tag s$1 >/dev/null; sleep 1; for p in qa qb; do grep 'MD97' $(ls -t qa/logs/run-$p-*.exe.log | head -1) | tail -1 | sed "s/^/$1 /"; done; powershell.exe -NoProfile -Command "& 'C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1' -Profile qa do 'shot md09-97-qa-$1'; & 'C:\Users\Juno\Code\Voyager\qa\harness\voy.ps1' -Profile qb do 'shot md09-97-qb-$1'" >/dev/null; }
$P $D qa/steps/md-offline-on.dart.txt --tag off97 --only qa; t0=$(date +%s); echo "offline $(date +%T)"
$P $L qa/steps/md09-ops.dart.txt --tag o7_01e02e03e04e05e --only qa
for k in 1 2 3 4 5 6 7; do sleep 12; st "off$(( $(date +%s)-t0 ))"; done
$P $D qa/steps/md-offline-off.dart.txt --tag on97 --only qa; t0=$(date +%s); echo "online $(date +%T)"
for k in 1 2 3 4 5 6; do sleep 12; st "on$(( $(date +%s)-t0 ))"; done
