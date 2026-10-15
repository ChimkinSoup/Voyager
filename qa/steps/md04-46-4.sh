#!/bin/bash
# MD-4.6 fourth case: both Force offline rename branch A (md04-46.dart.txt, tag rk4*),
# <firstSaver> 3 s before the other; <firstOnline> reconnects 25 s before the other.
# usage: bash qa/steps/md04-46-4.sh <tag rk4…> <firstSaver> <firstOnline>
cd /c/Users/Juno/Code/Voyager
tag=$1; s1=$2; o1=$3
other() { [ $1 = qa ] && echo qb || echo qa; }
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-on.dart.txt --tag off$tag | grep -v gap
sleep 2
python qa/steps/md4pair.py features/trash/trash_item_detail.dart qa/steps/md04-46.dart.txt --tag $tag --only $s1
sleep 3
python qa/steps/md4pair.py features/trash/trash_item_detail.dart qa/steps/md04-46.dart.txt --tag $tag --only $(other $s1)
sleep 3
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-off.dart.txt --tag on1$tag --only $o1
echo "--- $o1 online"; sleep 25
python qa/steps/md4pair.py features/dev/dev_page.dart qa/steps/md-offline-off.dart.txt --tag on2$tag --only $(other $o1)
echo "--- $(other $o1) online"; sleep 25
python qa/steps/md4rk.py --wait 60
