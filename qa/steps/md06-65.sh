#!/bin/bash
# MD-6.5: A links <AP> -> <AC> while B links <BP> -> <BC> (linkStudyDeck), then the links on A, B and cloud.
#   bash qa/steps/md06-65.sh <AP> <AC> <BP> <BC> <tag> [delay-ms]   (deck ids md6-deck-x/y/z/p/q)
cd /c/Users/Juno/Code/Voyager
sed -e "s/@AP@/$1/" -e "s/@AC@/$2/" -e "s/@BP@/$3/" -e "s/@BC@/$4/" qa/steps/md06-65-link.dart.txt > qa/steps/md06-65-run.dart.txt
python qa/steps/md4pair.py features/study/study_deck_link_actions.dart qa/steps/md06-65-run.dart.txt --tag "$5" --delay-ms "${6:-0}"
sleep 12
python qa/steps/md-q.py qa,qb "select substr(parent_deck_id,10) || '->' || substr(child_deck_id,10), version, case when deleted_at is null then 'live' else 'DEL' end, created_at from study_deck_links_table order by id"
python qa/steps/md-q.py qa,qb "select count(*) from pending_uploads_table"
python qa/harness/dbdiff.py qa qb --tables=study_deck_links_table --show=10 | tail -6
