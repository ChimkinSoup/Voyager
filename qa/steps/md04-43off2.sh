#!/bin/bash
# Control for md04-43off.sh: with B Force offline, a record write (md4-tx note)
# and a settings write; read the cloud 15 s later, before reconnecting.
cd /c/Users/Juno/Code/Voyager
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-on.dart.txt --only qb --tag offb3
sleep 2
python qa/steps/md4pair.py features/trash/trash_item_detail.dart qa/steps/md04-41-tx.dart.txt --only qb --tag ctl
python qa/steps/md4pair.py features/settings/settings_page.dart qa/steps/md04-43c-b.dart.txt --only qb --tag s43off3
sleep 15
echo "--- 15 s later, B still offline:"
python qa/steps/md4show.py transactions_table md4-tx transactions note note | head -3
python qa/steps/md4set.py weekStartsOnMonday | head -3
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-off.dart.txt --only qb --tag onb3
echo "--- B online:"
python qa/steps/md4show.py transactions_table md4-tx transactions note note --wait 60
