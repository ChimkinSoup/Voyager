# MD-7.3: the task row and its completion rows on A and B.  bash qa/steps/md07-73-q.sh <taskId>
cd /c/Users/Juno/Code/Voyager
python qa/steps/md-q.py qa,qb "select version, completed, due_date, updated_at from todo_tasks_table where id='$1'"
python qa/steps/md-q.py qa,qb "select id, version, completed_at, deleted_at from todo_task_completions_table where task_id='$1' order by id"
python qa/steps/md-outbox.py qa qb
