#!/bin/bash
# MD-17 cheat-sheet repro: v1 on WRITER online (ONLINE1=1), then WRITER offline, saves of versions OFFV (default "2"), hold HOLD s, reconnect.
#   KEY=ra WRITER=qa HOLD=75 [ONLINE1=0] [OFFV="1 2"] bash qa/steps/md17-cheat.sh
# Prints the tab / section / entry / problem on A, B and in the cloud (MD_UID).
cd /c/Users/Juno/Code/Voyager
KEY=${KEY:-ra}; W=${WRITER:-qa}; HOLD=${HOLD:-75}; ONLINE1=${ONLINE1:-1}; OFFV=${OFFV:-2}
export MD_UID=${MD_UID:-r9d6dp90pMPgbdnrYfWkYgbpkNh2}
S=qa/steps; L=features/dev/dev_page.dart; T=features/trash/trash_item_detail.dart
if [ "$ONLINE1" = 1 ]; then
python $S/md4pair.py $T $S/md17-cheat.dart.txt --tag ${KEY}_1 --only $W | tail -1
sleep 6
fi
echo "$(date +%T) v1 synced? $(python $S/md-q.py qa,qb "select version from leet_code_cheat_tabs_table where id='md17-ctab-$KEY'" | tr '\n' ' ')"
python $S/md4pair.py $L $S/md11-resumed.dart.txt --tag res --only $W | tail -1
python $S/md4pair.py $L $S/md-offline-on.dart.txt --tag off --only $W | tail -1
sleep 2
for v in $OFFV; do python $S/md4pair.py $T $S/md17-cheat.dart.txt --tag ${KEY}_$v --only $W | tail -1; done
echo "$(date +%T) offline saves v$OFFV done; holding $HOLD s"
sleep $HOLD
python $S/md-outbox.py $W
python $S/md4pair.py $L $S/md-offline-off.dart.txt --tag on --only $W | tail -1
echo "$(date +%T) reconnected"
sleep 25
python $S/md-outbox.py qa qb
for t in "leet_code_cheat_tabs_table leetcode_cheat_tabs ctab" "leet_code_cheat_sections_table leetcode_cheat_sections csec" "leet_code_cheat_entries_table leetcode_cheat_entries cent" "leet_code_problems_table leetcode_problems lc"; do
  set -- $t
  echo "$2: $(python $S/md-q.py qa,qb "select version from $1 where id='md17-$3-$KEY'" | tr '\n' ' ') $(python $S/md07-doc.py $2 md17-$3-$KEY version)"
done
