#!/bin/bash
# MD-6.2: concurrent planner card moves on one day (WorkoutActions.movePlanEntryBefore on both).
#   bash qa/steps/md06-62.sh <A move> <A before> <B move> <B before> <tag> [delay-ms]   (ids md6-pe-N)
cd /c/Users/Juno/Code/Voyager
sed -e "s/@AMOVE@/$1/" -e "s/@ABEFORE@/$2/" -e "s/@BMOVE@/$3/" -e "s/@BBEFORE@/$4/" qa/steps/md06-62-move.dart.txt > qa/steps/md06-62-run.dart.txt
python qa/steps/md4pair.py features/workout/workout_page.dart qa/steps/md06-62-run.dart.txt --tag "$5" --delay-ms "${6:-0}"
sleep 8
python qa/steps/md-q.py qa,qb "select group_concat(substr(id,8) || ':' || sort_order || ':v' || version, ' | ') from (select * from workout_plan_entries_table where id like 'md6-pe-%' and deleted_at is null order by day_index, sort_order)"
python qa/steps/md-q.py qa,qb "select count(*) from pending_uploads_table"
python qa/harness/dbdiff.py qa qb --tables=workout_plan_entries_table --show=10 | tail -8
