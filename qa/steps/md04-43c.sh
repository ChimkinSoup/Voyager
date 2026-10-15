#!/bin/bash
# MD-4.3 third bullet: B Force offline toggles week start, A online sets the
# accent, then B reconnects. Both must survive; no stale re-upload.
cd /c/Users/Juno/Code/Voyager
python qa/steps/md4set.py accentColor weekStartsOnMonday | head -3
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-on.dart.txt --only qb --tag offb
sleep 2
python qa/steps/md4pair.py features/settings/settings_page.dart qa/steps/md04-43c-b.dart.txt --only qb --tag s43cb
sleep 3
python qa/steps/md4pair.py features/settings/settings_page.dart qa/steps/md04-43c-a.dart.txt --only qa --tag s43ca
sleep 8
echo "--- B offline:"
python qa/steps/md4set.py accentColor weekStartsOnMonday | head -3
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-off.dart.txt --only qb --tag onb
echo "--- B online"
python qa/steps/md4set.py accentColor weekStartsOnMonday --wait 60
