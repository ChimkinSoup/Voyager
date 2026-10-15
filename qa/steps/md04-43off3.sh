#!/bin/bash
# Force offline on B, then a settings save and a record save in the same window;
# which one reaches the cloud before B reconnects?
cd /c/Users/Juno/Code/Voyager
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-on.dart.txt --only qb --tag offb5
sleep 10
python qa/steps/md4pair.py features/settings/settings_page.dart qa/steps/md04-43c-b.dart.txt --only qb --tag s43off5
python qa/steps/md4pair.py features/trash/trash_item_detail.dart qa/steps/md04-41-tx.dart.txt --only qb --tag ctl5 &
sleep 15
echo "--- 15 s later, B still offline:"
python qa/steps/md4set.py weekStartsOnMonday | head -3
python qa/steps/md4show.py transactions_table md4-tx transactions note note | head -3
wait
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-off.dart.txt --only qb --tag onb5
echo "--- B online:"
python qa/steps/md4show.py transactions_table md4-tx transactions note note --wait 60 | tail -1
python qa/steps/md4set.py weekStartsOnMonday --wait 30 | tail -1
