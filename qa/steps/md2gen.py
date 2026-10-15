"""Generate MD-2 bodies + specs (qa/steps/md02-<feature>-*.dart.txt, md02-<feature>.tsv).

Per feature: records written through the app's repositories and push calls.
Steps: create (version 1), edit (version 2, text fields get ' ed'), delete
(version 3, deletedAt = now) unless a feature lists its own steps. A step's
receiver SQL waits until every record of the step has that version (and the
tombstone, for delete) on the receiver.
Template keys in ctor: {V} version, {S} '' or ' ed', {DEL} ', deletedAt: now' or ''.
Ids get @W@@N@ appended (writer + run number).
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = 'features/trash/trash_item_detail.dart'
PRE = ("final now = DateTime.now().toUtc(); final c0 = DateTime.utc(2026, 10, 12, 12); final t0 = DateTime.now(); "
       "final day = DateTime(t0.year, t0.month, t0.day); final r = c.read(remoteSyncServiceProvider);")


def rec(var, table, coll, idbase, ctor, upsert, push=None, key='id'):
    return dict(var=var, table=table, coll=coll, id=idbase + '-@W@@N@', ctor=ctor, upsert=upsert,
                push=push or f"await r.pushRecords('{coll}', [{var}]);", key=key)


def body(recs, V, S, DEL):
    out = [PRE]
    for x in recs:
        ctor = x['ctor'].replace('{ID}', x['id']).replace('{V}', str(V)).replace('{S}', S).replace('{DEL}', DEL)
        out.append(f"final {x['var']} = {ctor};")
        out.append(x['upsert'].replace('X', x['var']) + ';')
    out.append('MARK;')
    for x in recs:
        out.append(x['push'])
    return '\n'.join(out) + '\n'


def sql(recs, V, deleted):
    parts = [f"select 1 from {x['table']} where {x['key']}='{x['id']}' and version>={V}" + (" and deleted_at is not null" if deleted else '')
             for x in recs]
    return f"select count(*) n from ({' union all '.join(parts)}) having n={len(recs)}"


F = {}
DATE = 'c0'

F['dreams'] = dict(find='MD2 dream', recs=[
    rec('d', 'dream_entries_table', 'dream_entries', 'md2-dr',
        "DreamEntry(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, title: 'MD2 dream @W@@N@{S}', body: 'MD2 dream body{S}', entryDate: t0, notes: 'MD2 sticky{S}', tags: const ['md2tag'])",
        'await c.read(dreamRepositoryProvider).upsertEntry(X)', 'r.pushDreamEntryNow(d);')])

F['todo'] = dict(find='MD2 task', recs=[
    rec('l', 'todo_lists_table', 'todo_lists', 'md2-tl',
        "TodoListModel(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 List @W@@N@{S}')",
        'await c.read(todoRepositoryProvider).upsertList(X)', 'r.pushTodoList(l);'),
    rec('t', 'todo_tasks_table', 'todo_tasks', 'md2-tt',
        "TodoTask(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, listId: 'md2-tl-@W@@N@', title: 'MD2 task @W@@N@{S}', notes: 'MD2 notes{S}', dueDate: day.add(Duration(days: {V})), starred: {V} == 2)",
        'await c.read(todoRepositoryProvider).upsertTask(X)', 'r.pushTodoTaskInBackground(t);'),
    rec('s', 'todo_tasks_table', 'todo_tasks', 'md2-ts',
        "TodoTask(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, listId: 'md2-tl-@W@@N@', parentTaskId: 'md2-tt-@W@@N@', title: 'MD2 sub @W@@N@{S}')",
        'await c.read(todoRepositoryProvider).upsertTask(X)', 'r.pushTodoTaskInBackground(s);')])

F['calendar'] = dict(find='MD2 event', recs=[
    rec('k', 'calendars_table', 'calendars', 'md2-cal',
        "Calendar(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 Cal @W@@N@{S}', colorValue: {V} == 2 ? 0xFFE91E63 : 0xFF4CAF50)",
        'await c.read(calendarRepositoryProvider).upsertCalendar(X)'),
    rec('ev', 'calendar_events_table', 'calendar_events', 'md2-ev',
        "CalendarEvent(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, calendarId: 'md2-cal-@W@@N@', title: 'MD2 event @W@@N@{S}', start: day.add(Duration(hours: 9 + {V})), end: day.add(Duration(hours: 10 + {V})), isFullDay: false)",
        'await c.read(calendarRepositoryProvider).upsertEvent(X)'),
    rec('ad', 'calendar_events_table', 'calendar_events', 'md2-evd',
        "CalendarEvent(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, calendarId: 'md2-cal-@W@@N@', title: 'MD2 allday @W@@N@{S}', start: day, end: day, isFullDay: true, recurrence: {V} == 2 ? const RecurrenceRule(frequency: EventRecurrence.daily) : RecurrenceRule.none)",
        'await c.read(calendarRepositoryProvider).upsertEvent(X)')])

F['trackers'] = dict(find='MD2 trk', recs=[
    rec('k', 'trackers_table', 'trackers', 'md2-trk',
        "StatisticTracker(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 trk @W@@N@{S}', type: {V} == 2 ? TrackerType.boolean : TrackerType.integer, cadence: TrackerCadence.daily)",
        'await c.read(trackerRepositoryProvider).upsertTracker(X)'),
    rec('tv', 'tracker_values_table', 'tracker_values', 'md2-trv',
        "TrackerValue(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, trackerId: 'md2-trk-@W@@N@', periodStart: day, intValue: 10 * {V}, boolValue: {V} == 2)",
        'await c.read(trackerRepositoryProvider).upsertValue(X)'),
    rec('cn', 'trackers_table', 'trackers', 'md2-cnt',
        "StatisticTracker(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 counter @W@@N@{S}', type: TrackerType.counter, cadence: TrackerCadence.daily)",
        'await c.read(trackerRepositoryProvider).upsertTracker(X)'),
    rec('ca', 'counter_adjustments_table', 'counter_adjustments', 'md2-cadj',
        "CounterAdjustment(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, trackerId: 'md2-cnt-@W@@N@', day: day, deviceId: 'md2-@W@', delta: {V} + 2)",
        'await c.read(trackerRepositoryProvider).upsertAdjustment(X)')])

F['finance'] = dict(find='MD2 tx', lib='features/finance/finance_analytics_view.dart', recs=[
    rec('tx', 'transactions_table', 'transactions', 'md2-tx',
        "FinancialTransaction(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, type: TransactionType.expense, amountCents: 1000 * {V}, occurredAt: t0, tags: const ['md2food'], note: 'MD2 tx @W@@N@{S}')",
        'await c.read(financeRepositoryProvider).upsertTransaction(X)'),
    rec('sb', 'subscriptions_table', 'subscriptions', 'md2-sub',
        "Subscription(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 sub @W@@N@{S}', amountCents: 999 * {V}, period: BillingPeriod.monthly, anchorDueDate: day.add(const Duration(days: 5)))",
        'await c.read(financeRepositoryProvider).upsertSubscription(X)'),
    rec('bu', 'budgets_table', 'budgets', 'md2-bud',
        "Budget(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, tag: 'md2food', limitCents: 30000 * {V})",
        'await c.read(financeRepositoryProvider).upsertBudget(X)'),
    rec('fc', 'finance_categories_table', 'finance_categories', 'md2-fcat',
        "FinanceCategory(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 cat @W@@N@{S}', tags: const ['md2food'])",
        'await c.read(financeRepositoryProvider).upsertCategory(X)'),
    rec('ro', 'contribution_rooms_table', 'contribution_rooms', 'md2-room',
        "ContributionRoom(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 room @W@@N@{S}', baselineRemainingCents: 700000 * {V}, baselineAsOf: day)",
        'await c.read(financeRepositoryProvider).upsertContributionRoom(X)'),
    rec('as', 'assets_table', 'assets', 'md2-asset',
        "Asset(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 asset @W@@N@{S}', contributionRoomId: 'md2-room-@W@@N@')",
        'await c.read(financeRepositoryProvider).upsertAsset(X)'),
    rec('av', 'asset_valuations_table', 'asset_valuations', 'md2-aval',
        "AssetValuation(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, assetId: 'md2-asset-@W@@N@', valueCents: 500000 * {V}, asOf: day)",
        'await c.read(financeRepositoryProvider).upsertAssetValuation(X)'),
    rec('re', 'asset_room_events_table', 'asset_room_events', 'md2-rev',
        "AssetRoomEvent(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, assetId: 'md2-asset-@W@@N@', roomId: 'md2-room-@W@@N@', kind: {V} == 2 ? RoomEventKind.withdrawal : RoomEventKind.contribution, amountCents: 10000 * {V}, occurredAt: t0, note: 'MD2 room event{S}')",
        'await c.read(financeRepositoryProvider).upsertAssetRoomEvent(X)'),
    rec('go', 'savings_goals_table', 'savings_goals', 'md2-goal',
        "SavingsGoal(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 goal @W@@N@{S}', targetCents: 200000 * {V})",
        'await c.read(financeRepositoryProvider).upsertSavingsGoal(X)'),
    rec('ga', 'goal_allocations_table', 'goal_allocations', 'md2-galloc',
        "GoalAllocation(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, goalId: 'md2-goal-@W@@N@', amountCents: 5000 * {V}, allocatedAt: t0, note: 'MD2 alloc{S}')",
        'await c.read(financeRepositoryProvider).upsertGoalAllocation(X)')])

F['life'] = dict(find='MD2 bucket', recs=[
    rec('b', 'bucket_list_items_table', 'bucket_list_items', 'md2-bucket',
        "BucketListItem(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, title: 'MD2 bucket @W@@N@{S}', completed: {V} == 2, completedAt: {V} == 2 ? now : null)",
        'await c.read(bucketListRepositoryProvider).upsertItem(X)')])

F['leetcode'] = dict(find='MD2 LC', recs=[
    rec('p', 'leet_code_problems_table', 'leetcode_problems', 'md2-lc',
        "LeetCodeProblem(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, title: 'MD2 LC @W@@N@{S}', difficulty: {V} == 2 ? LeetCodeDifficulty.medium : LeetCodeDifficulty.easy, solvedAt: c0, description: 'MD2 desc{S}')",
        'await c.read(leetCodeRepositoryProvider).upsertProblem(X)', 'r.pushLeetCodeProblem(p);'),
    rec('g', 'leet_code_review_log_table', 'leetcode_review_log', 'md2-lcrev',
        "LeetCodeReviewLog(id: '{ID}', problemId: 'md2-lc-@W@@N@', grade: StudyGrade.values[{V}], reviewedAt: c0, version: {V}{DEL})",
        'await c.read(leetCodeRepositoryProvider).logReview(X)', 'r.pushLeetCodeReviewLog(g);'),
    rec('ct', 'leet_code_cheat_tabs_table', 'leetcode_cheat_tabs', 'md2-ctab',
        "LeetCodeCheatTab(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 tab @W@@N@{S}', position: 0)",
        'await c.read(leetCodeRepositoryProvider).upsertCheatTab(X)', 'r.pushLeetCodeCheatTab(ct);'),
    rec('cs', 'leet_code_cheat_sections_table', 'leetcode_cheat_sections', 'md2-csec',
        "LeetCodeCheatSection(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, tabId: 'md2-ctab-@W@@N@', name: 'MD2 section{S}', position: 0)",
        'await c.read(leetCodeRepositoryProvider).upsertCheatSection(X)', 'r.pushLeetCodeCheatSection(cs);'),
    rec('ce', 'leet_code_cheat_entries_table', 'leetcode_cheat_entries', 'md2-cent',
        "LeetCodeCheatEntry(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, sectionId: 'md2-csec-@W@@N@', command: 'md2cmd{S}', description: 'MD2 entry{S}', position: 0)",
        'await c.read(leetCodeRepositoryProvider).upsertCheatEntry(X)', 'r.pushLeetCodeCheatEntry(ce);')])

F['rankings'] = dict(find='MD2 rank', recs=[
    rec('rc', 'ranking_categories_table', 'ranking_categories', 'md2-rcat',
        "RankingCategory(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 RCat @W@@N@{S}', colorValue: 0xFF3366CC)",
        'await c.read(rankingRepositoryProvider).upsertCategory(X)', 'r.pushRankingCategory(rc);'),
    rec('rp', 'ranking_parents_table', 'ranking_parents', 'md2-rpar',
        "RankingParent(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, categoryId: 'md2-rcat-@W@@N@', title: 'MD2 rank @W@@N@{S}', overallScore: 2.5 * {V})",
        'await c.read(rankingRepositoryProvider).upsertParent(X)', 'r.pushRankingParent(rp);'),
    rec('rch', 'ranking_children_table', 'ranking_children', 'md2-rch',
        "RankingChild(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, parentId: 'md2-rpar-@W@@N@', name: 'MD2 child{S}', overallScore: 1.5 * {V})",
        'await c.read(rankingRepositoryProvider).upsertChild(X)', 'r.pushRankingChild(rch);'),
    rec('rn', 'ranking_counts_table', 'ranking_counts', 'md2-rcnt',
        "RankingCount(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, entryId: 'md2-rpar-@W@@N@', deviceId: 'md2-@W@', delta: {V})",
        'await c.read(rankingRepositoryProvider).upsertCount(X)', 'r.pushRankingCounts([rn]);')])

F['jobs'] = dict(find='MD2 Co', recs=[
    rec('jc', 'job_categories_table', 'job_categories', 'md2-jcat',
        "JobCategory(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 jcat @W@@N@{S}', colorValue: 0xFF4CAF50)",
        'await c.read(jobRepositoryProvider).upsertCategory(X)', 'r.pushJobCategory(jc);'),
    rec('co', 'job_companies_table', 'job_companies', 'md2-jco',
        "JobCompany(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 Co @W@@N@{S}', categoryId: 'md2-jcat-@W@@N@')",
        'await c.read(jobRepositoryProvider).upsertCompany(X)', 'r.pushJobCompany(co);'),
    rec('se', 'job_seasons_table', 'job_seasons', 'md2-jsea',
        "JobSeason(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 season @W@@N@{S}')",
        'await c.read(jobRepositoryProvider).upsertSeason(X)', 'r.pushJobSeason(se);'),
    rec('st', 'job_stages_table', 'job_stages', 'md2-jst',
        "JobStage(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 stage @W@@N@{S}', sortOrder: 9)",
        'await c.read(jobRepositoryProvider).upsertStage(X)', 'r.pushJobStage(st);'),
    rec('ja', 'job_applications_table', 'job_applications', 'md2-job',
        "JobApplication(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, company: 'MD2 Co @W@@N@{S}', title: 'MD2 Engineer{S}', status: {V} == 2 ? 'Interview' : 'Applied', dateApplied: day, notes: 'MD2 notes{S}')",
        'await c.read(jobRepositoryProvider).upsertApplication(X)', 'r.pushJobApplication(ja);'),
    rec('je', 'job_status_events_table', 'job_status_events', 'md2-jev',
        "JobStatusEvent(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, applicationId: 'md2-job-@W@@N@', fromStatus: 'Applied', toStatus: 'Interview', changedAt: t0)",
        'await c.read(jobRepositoryProvider).upsertStatusEvent(X)', 'r.pushJobStatusEvent(je);')])

F['study'] = dict(find='MD2 deck', recs=[
    rec('fo', 'study_folders_table', 'study_folders', 'md2-sfold',
        "StudyFolder(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 folder @W@@N@{S}')",
        'await c.read(studyRepositoryProvider).upsertFolder(X)', 'r.pushStudyFolder(fo);'),
    rec('dk', 'study_decks_table', 'study_decks', 'md2-sdeck',
        "StudyDeck(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 deck @W@@N@{S}')",
        'await c.read(studyRepositoryProvider).upsertDeck(X)', 'r.pushStudyDeck(dk);'),
    rec('d2', 'study_decks_table', 'study_decks', 'md2-sdeck2',
        "StudyDeck(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 child deck @W@@N@{S}', parentFolderId: 'md2-sfold-@W@@N@')",
        'await c.read(studyRepositoryProvider).upsertDeck(X)', 'r.pushStudyDeck(d2);'),
    rec('cd', 'study_cards_table', 'study_cards', 'md2-scard',
        "StudyCard(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, deckId: 'md2-sdeck-@W@@N@', frontText: 'MD2 front{S}', backText: 'MD2 back{S}', dueAt: c0)",
        'await c.read(studyRepositoryProvider).upsertCard(X)', 'r.pushStudyCard(cd);'),
    rec('lk', 'study_deck_links_table', 'study_deck_links', 'md2-slink',
        "StudyDeckLink(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, parentDeckId: 'md2-sdeck-@W@@N@', childDeckId: 'md2-sdeck2-@W@@N@', enabled: {V} != 2)",
        'await c.read(studyRepositoryProvider).upsertDeckLink(X)', 'r.pushStudyDeckLink(lk);'),
    rec('rv', 'study_review_log_table', 'study_review_log', 'md2-srev',
        "StudyReviewLog(id: '{ID}', cardId: 'md2-scard-@W@@N@', grade: StudyGrade.values[{V}], reviewedAt: c0, version: {V}{DEL})",
        'await c.read(studyRepositoryProvider).logReview(X)', 'r.pushStudyReviewLog(rv);')])

F['workout'] = dict(find='MD2 lift', recs=[
    rec('ex', 'exercises_table', 'exercises', 'md2-ex',
        "Exercise(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, name: 'MD2 lift @W@@N@{S}')",
        'await c.read(workoutRepositoryProvider).upsertExercise(X)', 'r.pushExercise(ex);'),
    rec('pe', 'workout_plan_entries_table', 'workout_plan_entries', 'md2-pe',
        "WorkoutPlanEntry(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, planId: 'workout_plan_weekly', dayIndex: {V}, exerciseId: 'md2-ex-@W@@N@', sortOrder: 5)",
        'await c.read(workoutRepositoryProvider).upsertPlanEntry(X)', 'r.pushWorkoutPlanEntry(pe);'),
    rec('ws', 'workout_sessions_table', 'workout_sessions', 'md2-ws',
        "WorkoutSession(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, date: day.subtract(const Duration(days: 1)), startedAt: t0.subtract(const Duration(days: 1)), endedAt: t0.subtract(const Duration(days: 1)).add(Duration(minutes: 30 * {V})))",
        'await c.read(workoutRepositoryProvider).upsertSession(X)', 'r.pushWorkoutSession(ws);'),
    rec('sl', 'workout_set_logs_table', 'workout_set_logs', 'md2-sl',
        "WorkoutSetLog(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, sessionId: 'md2-ws-@W@@N@', exerciseId: 'md2-ex-@W@@N@', exerciseOrder: 0, setIndex: 0, weightKg: 20.0 * {V}, reps: 5 + {V}, plannedWeightKg: 20.0, plannedReps: 5, completed: true, completedAt: t0.subtract(const Duration(days: 1)))",
        'await c.read(workoutRepositoryProvider).upsertSetLog(X)', 'r.pushWorkoutSetLog(sl);')])

F['inbox'] = dict(find='MD2 pinned', lib='features/notifications/notification_inbox_popover.dart', recs=[
    rec('pn', 'pinned_notes_table', 'pinned_notes', 'md2-pin',
        "PinnedNote(id: '{ID}', text: 'MD2 pinned @W@@N@{S}', createdAt: c0, updatedAt: now, version: {V}{DEL})",
        'await c.read(notificationRepositoryProvider).upsertPinnedNote(X)'),
    ])

F['reminders'] = dict(find='MD2 rule', lib='features/notifications/scheduled_reminders_section.dart', recs=[
    rec('ru', 'scheduled_reminder_rules_table', 'scheduled_reminder_rules', 'md2-rule',
        "ScheduledReminderRule(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, title: 'MD2 rule @W@@N@{S}', enabled: {V} != 2, scheduleKind: ReminderScheduleKind.daily, localTimeMinutes: 23 * 60 + 50, armedAt: c0)",
        'await c.read(reminderRepositoryProvider).upsertRule(X)'),
    rec('er', 'entity_reminders_table', 'entity_reminders', 'md2-erem',
        "EntityReminder(id: '{ID}', createdAt: c0, updatedAt: now, version: {V}{DEL}, sourceKind: ReminderSourceKind.todo, entityId: 'md2-none-@W@@N@', enabled: true, offsetMinutes: 10 * {V}, armedAt: c0)",
        'await c.read(reminderRepositoryProvider).upsertEntityReminder(X)')])

F['text'] = dict(find='MD2 quote', recs=[
    rec('q', 'custom_quotes_table', 'custom_quotes', 'md2-quote',
        "CustomQuote(id: '{ID}', text: 'MD2 quote @W@@N@{S}', createdAt: c0, updatedAt: now, version: {V}{DEL})",
        'await c.read(settingsRepositoryProvider).upsertCustomQuote(X)', 'r.pushCustomQuote(q);')])


def write(name, f):
    recs = f['recs']
    lines = [f'lib\t{f.get("lib", LIB)}']
    find = f['find'] + ' @W@@N@'
    for step, V, S, DEL, fnd, absent in [('create', 1, '', '', find, 0), ('edit', 2, ' ed', '', find + ' ed', 0),
                                         ('delete', 3, ' ed', ', deletedAt: now', find + ' ed', 1)]:
        fn = f'md02-{name}-{step}.dart.txt'
        open(os.path.join(HERE, fn), 'w', encoding='ascii').write(body(recs, V, S, DEL))
        lines.append('\t'.join([f'{name}-{step}', fn, sql(recs, V, step == 'delete'), fnd, str(absent), f'{len(recs)} records']))
    open(os.path.join(HERE, f'md02-{name}.tsv'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    print('wrote', name, len(recs), 'records')


for k, v in F.items():
    write(k, v)
