#!/bin/bash
# MD-5.5: op-log size + text of the three CRDT docs in the cloud, and the rows on A and B.
cd /c/Users/Juno/Code/Voyager
U=RnNU2YFBbcf2VSn3kF49j40r53q2
for d in "dream_entries md5-dream-a" "todo_tasks md5-task-a1" "journal_entries md5-je-b1"; do
  set -- $d
  echo "== $1/$2"; python qa/harness/fs_ops.py $U $1 $2 --ops 2>&1 | grep -E "^(version|deletedAt|body|notes|title|ops)"
done
python qa/steps/md-q.py qa,qb "select id, version, deleted_at, length(body), title from dream_entries_table where id='md5-dream-a' union all select id, version, deleted_at, length(notes), title from todo_tasks_table where id='md5-task-a1' union all select id, version, deleted_at, length(body), title from journal_entries_table where id='md5-je-b1'"
python qa/steps/md-outbox.py
