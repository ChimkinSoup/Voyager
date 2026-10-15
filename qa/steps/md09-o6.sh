#!/bin/bash
# MD-9 O6: error markers in the latest run log of each profile, and each profile's voyager_errors.log tail.
for p in qa qb; do
  f=$(ls -t qa/logs/run-$p-*.exe.log | head -1)
  n=$(grep -c 'EXCEPTION CAUGHT\|Another exception\|RenderFlex overflowed\|LiveSyncController\|SEED-ERR' "$f")
  echo "O6 $p $(basename $f): $n error lines"; grep -n 'EXCEPTION CAUGHT\|Another exception\|RenderFlex overflowed\|LiveSyncController\|SEED-ERR' "$f" | head -5
  e="$APPDATA/Voyager/voyager-profile-$p/logs/voyager_errors.log"
  [ -f "$e" ] && grep -v 'APP START' "$e" | tail -3 | sed "s/^/  errlog $p: /"
done
