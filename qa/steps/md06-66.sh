#!/bin/bash
# MD-6.6: A moves an item to <ATO> while B moves it to <BTO>, together; then the row on A, B and cloud.
#   bash qa/steps/md06-66.sh task|entry|card <ATO> <BTO> <tag> [delay-ms]
cd /c/Users/Juno/Code/Voyager
case $1 in
  task)  lib=features/todo/todo_page.dart; t=todo_tasks_table; id=md6-task-mv; coll=todo_tasks; col=list_id; f=listId;;
  entry) lib=features/journal/journal_page.dart; t=journal_entries_table; id=md6-je-mv; coll=journal_entries; col=journal_id; f=journalId;;
  card)  lib=features/study/study_move_modal.dart; t=study_cards_table; id=md6-card-mv; coll=study_cards; col=deck_id; f=deckId;;
esac
sed -e "s/@ATO@/$2/" -e "s/@BTO@/$3/" qa/steps/md06-66-$1.dart.txt > qa/steps/md06-66-run.dart.txt
python qa/steps/md4pair.py $lib qa/steps/md06-66-run.dart.txt --tag "$4" --delay-ms "${5:-0}"
sleep 10
MD_UID=MNGZSGV22wMzyN1DvydVQJGIqVu2 python qa/steps/md4show.py $t $id $coll $col,version,updated_at $f,version,updatedAt
