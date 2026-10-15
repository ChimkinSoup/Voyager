"""MD-8: create or change a scheduled reminder rule on one profile, through the
app's repository + push, then refresh that device's providers (an eval write
doesn't refresh its own device otherwise).

    python qa/steps/md08-rule.py <qa|qb> <id> <title> <when> [--kind once|daily]
        [--targets id1,id2] [--off] [--delete] [--body text]

<when> is +N (N minutes from now, seconds zeroed) or HH:MM (today, local).
Updating an existing id keeps createdAt / armedAt and bumps the version.
Titles: letters, digits, spaces only (evalc bodies can't hold quotes).
"""
import argparse, datetime, os, subprocess, sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIB = 'features/notifications/scheduled_reminders_section.dart'

ap = argparse.ArgumentParser()
ap.add_argument('prof'); ap.add_argument('id'); ap.add_argument('title'); ap.add_argument('when')
ap.add_argument('--kind', default='once'); ap.add_argument('--targets', default='')
ap.add_argument('--off', action='store_true'); ap.add_argument('--delete', action='store_true')
ap.add_argument('--body', default='')
a = ap.parse_args()

now = datetime.datetime.now()
if a.when.startswith('+'):
    at = (now + datetime.timedelta(minutes=int(a.when[1:]))).replace(second=0, microsecond=0)
else:
    h, m = map(int, a.when.split(':'))
    at = now.replace(hour=h, minute=m, second=0, microsecond=0)
mins = at.hour * 60 + at.minute
targets = ', '.join(f"'{t}'" for t in a.targets.split(',') if t)
kind = {'once': 'ReminderScheduleKind.once', 'daily': 'ReminderScheduleKind.daily'}[a.kind]
once = f'DateTime({at.year}, {at.month}, {at.day})' if a.kind == 'once' else 'null'
body = f"'{a.body}'" if a.body else 'null'
deleted = 'now' if a.delete else 'null'

src = f"""
final now = DateTime.now().toUtc();
final repo = c.read(reminderRepositoryProvider);
final old = await repo.getRule('{a.id}');
final rule = ScheduledReminderRule(id: '{a.id}', createdAt: old?.createdAt ?? now, updatedAt: now, version: (old?.version ?? 0) + 1, deletedAt: {deleted}, title: '{a.title}', body: {body}, enabled: {'false' if a.off else 'true'}, scheduleKind: {kind}, localTimeMinutes: {mins}, onceLocalDate: {once}, targetDeviceIds: <String>[{targets}], armedAt: old?.armedAt ?? now);
await repo.upsertRule(rule);
MARK;
c.invalidate(scheduledReminderRulesProvider);
await c.read(remoteSyncServiceProvider).pushRecords('scheduled_reminder_rules', [rule]);
"""
path = os.path.join(REPO, 'qa', 'steps', f'md08-rule-body-{a.prof}.dart.txt')
with open(path, 'w', encoding='ascii') as f:
    f.write(src)
print(f'rule {a.id} "{a.title}" {a.kind} at {at:%Y-%m-%d %H:%M} targets=[{a.targets}] off={a.off} delete={a.delete}')
sys.exit(subprocess.call([sys.executable, os.path.join(REPO, 'qa', 'steps', 'md4pair.py'), LIB, path,
                          '--only', a.prof, '--tag', a.id]))
