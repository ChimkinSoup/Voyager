#!/bin/bash
# MD-5.7: job application md5-job-x and ranking entry md5-rpar-b on A, B and in the cloud.
cd /c/Users/Juno/Code/Voyager
U=RnNU2YFBbcf2VSn3kF49j40r53q2
python qa/steps/md-outbox.py
python qa/steps/md4show.py job_applications_table md5-job-x job_applications deleted_at,company,notes deletedAt,company,notes --uid $U "$@"
python qa/steps/md4show.py ranking_parents_table md5-rpar-b ranking_parents deleted_at,title deletedAt,title --uid $U "$@"
