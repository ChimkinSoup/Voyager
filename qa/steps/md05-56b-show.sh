#!/bin/bash
# MD-5.6: event a1 and card b1 on A, B and in the cloud.
cd /c/Users/Juno/Code/Voyager
U=RnNU2YFBbcf2VSn3kF49j40r53q2
python qa/steps/md-outbox.py
python qa/steps/md4show.py calendar_events_table md5-ev-a2 calendar_events deleted_at,title deletedAt,title --uid $U "$@"
python qa/steps/md4show.py study_cards_table md5-card-b2 study_cards deleted_at,front_text deletedAt,frontText --uid $U "$@"
