# MD-7.4: a study card's schedule and its review logs on A and B (+ cloud card).  bash qa/steps/md07-74-q.sh <cardId>
cd /c/Users/Juno/Code/Voyager
python qa/steps/md-q.py qa,qb "select version, due_at, interval, ease, review_count, updated_at from study_cards_table where id='$1'"
python qa/steps/md-q.py qa,qb "select id, grade, reviewed_at, deleted_at from study_review_log_table where card_id='$1' order by reviewed_at"
MD_UID=MNGZSGV22wMzyN1DvydVQJGIqVu2 python qa/steps/md07-doc.py study_cards $1 version,dueAt,interval,ease,reviewCount,updatedAt
python qa/steps/md-outbox.py qa qb
