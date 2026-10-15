#!/bin/bash
# MD-5.4: the three erased records on A, B and in the cloud.
cd /c/Users/Juno/Code/Voyager
U=RnNU2YFBbcf2VSn3kF49j40r53q2
python qa/steps/md-outbox.py
python qa/steps/md4show.py journal_entries_table md5-je-a2 journal_entries deleted_at,title,body deletedAt,title,body --uid $U
python qa/steps/md4show.py todo_tasks_table md5-task-a2 todo_tasks deleted_at,title,notes deletedAt,title,notes --uid $U
python qa/steps/md4show.py transactions_table md5-tx-a1 transactions deleted_at,note,amount_cents deletedAt,note,amountCents --uid $U
