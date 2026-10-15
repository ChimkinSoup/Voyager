#!/bin/bash
# MD-5.8: journal entry <id> on A, B and in the cloud (document + op count).
cd /c/Users/Juno/Code/Voyager
U=RnNU2YFBbcf2VSn3kF49j40r53q2
python qa/steps/md-outbox.py
python qa/steps/md-q.py qa,qb "select id, version, deleted_at, updated_at, body from journal_entries_table where id='$1'"
python qa/harness/fs_ops.py $U journal_entries $1 --ops 2>&1 | grep -E "^(version|deletedAt|body|ops|_server)|404|rror" | head -8
