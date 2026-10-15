#!/bin/bash
# MD-4.2: the four records md04-42-set.dart.txt writes, on A, B and the cloud.
S=qa/steps/md4show.py; W=${1:-0}
python $S transactions_table md4-tx transactions note note --wait $W
python $S todo_tasks_table md4-tt todo_tasks title title --wait $W
python $S study_cards_table md4-card study_cards front_text frontText --wait $W
python $S calendar_events_table md4-ev calendar_events title title --wait $W
