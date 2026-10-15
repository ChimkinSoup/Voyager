#!/bin/bash
# MD-6.1: concurrent reorders of list md6-list-r through the page's own drag handler.
#   bash qa/steps/md06-61.sh <A task id> <A newIndex> <B task id> <B newIndex> <tag> [delay-ms]
cd /c/Users/Juno/Code/Voyager
sed -e "s/@AFROM@/$1/" -e "s/@ATO@/$2/" -e "s/@BFROM@/$3/" -e "s/@BTO@/$4/" qa/steps/md06-61-reorder.dart.txt > qa/steps/md06-61-run.dart.txt
python qa/steps/md4pair.py features/todo/todo_page.dart qa/steps/md06-61-run.dart.txt --tag "$5" --delay-ms "${6:-0}"
sleep 8
python qa/steps/md-q.py qa,qb "select group_concat(substr(title,10) || ':' || sort_order || ':v' || version, ' | ') from (select * from todo_tasks_table where list_id='md6-list-r' and deleted_at is null order by sort_order, created_at)"
python qa/steps/md-q.py qa,qb "select count(*) from pending_uploads_table"
python qa/harness/dbdiff.py qa qb --tables=todo_tasks_table --show=10 | tail -12
