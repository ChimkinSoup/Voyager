#!/bin/bash
# Does a settings save leave a Force-offline device? B offline toggles week start;
# the cloud and A are read 15 s later, before B reconnects.
cd /c/Users/Juno/Code/Voyager
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-on.dart.txt --only qb --tag offb4
sleep 20
python qa/steps/md4pair.py features/settings/settings_page.dart qa/steps/md04-43c-b.dart.txt --only qb --tag s43off
sleep 15
echo "--- 15 s after B's offline save, B still offline:"
python qa/steps/md4set.py weekStartsOnMonday | head -3
python qa/steps/md-outbox.py qb
grep -c "Transaction updateusers" $(ls -t qa/logs/run-qb-*.exe.log | head -1)
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-off.dart.txt --only qb --tag onb4
sleep 5
echo "--- B online:"
grep -c "Transaction updateusers" $(ls -t qa/logs/run-qb-*.exe.log | head -1)
python qa/steps/md4set.py weekStartsOnMonday --wait 60
