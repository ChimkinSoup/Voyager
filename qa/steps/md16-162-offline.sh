#!/bin/bash
# MD-16.2 offline round: both offline, A renames the OA seed stage, B 2 s later,
# then FIRST reconnects first, the other 20 s later. FIRST=qb|qa, TAG=word.
cd /c/Users/Juno/Code/Voyager
P=qa/steps/md4pair.py
python $P features/dev/dev_page.dart qa/steps/md-offline-on.dart.txt --tag off$TAG
python $P features/jobs/jobs_page.dart qa/steps/md16-162-rename-oa.dart.txt --tag $TAG --delay-ms 2000
sleep 5
SECOND=qa; [ "$FIRST" = qa ] && SECOND=qb
python $P features/dev/dev_page.dart qa/steps/md-offline-off.dart.txt --tag on1$TAG --only $FIRST
sleep 20
python $P features/dev/dev_page.dart qa/steps/md-offline-off.dart.txt --tag on2$TAG --only $SECOND
sleep 20
python qa/steps/md-q.py qa,qb "select id,name,version,updated_at from job_stages_table where id='seed-stage-online-assessment'"
MD_UID=17IxKIMWhAgX5FCFAJKD208bn7Q2 python qa/steps/md07-doc.py job_stages seed-stage-online-assessment
python qa/steps/md-outbox.py
