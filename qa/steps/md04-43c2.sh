#!/bin/bash
# MD-4.3 third bullet, with B's setting really held back: Force offline alone lets
# a settings transaction out (BUG-242), so B first writes a record, whose upload
# stalls the write gate for 45 s; B's week-start toggle is then queued in the
# outbox. A online sets the accent. B reconnects.
cd /c/Users/Juno/Code/Voyager
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-on.dart.txt --only qb --tag offc2
sleep 2
python qa/steps/md4pair.py features/trash/trash_item_detail.dart qa/steps/md04-41-tx.dart.txt --only qb --tag c2tx
python qa/steps/md4pair.py features/settings/settings_page.dart qa/steps/md04-43c-b.dart.txt --only qb --tag c2wk
sleep 3
python qa/steps/md4pair.py features/settings/settings_page.dart qa/steps/md04-43c-a2.dart.txt --only qa --tag c2acc
sleep 10
echo "--- B offline (setting queued?):"
python qa/steps/md4set.py accentColor weekStartsOnMonday | head -3
python qa/steps/md-outbox.py qb
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-off.dart.txt --only qb --tag onc2
echo "--- B online:"
python qa/steps/md4set.py accentColor weekStartsOnMonday --wait 90
python qa/steps/md-outbox.py qa qb
