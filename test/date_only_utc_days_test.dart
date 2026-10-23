// Date-only fields are stored and synced as UTC midnight of their day, so a
// device further west than the writer — or the same device after moving west
// — no longer reads them a day early (timezone audit, 2026-10-22).

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

final _t0 = DateTime.utc(2026, 10, 1);

TodoTask _task(String id, DateTime due, {bool hasTime = false}) => TodoTask(
  id: id,
  createdAt: _t0,
  updatedAt: _t0,
  listId: 'l',
  title: id,
  dueDate: due,
  dueHasTime: hasTime,
);

Future<String?> _raw(AppDatabase db, String sql, String id) async =>
    (await db.customSelect(sql, variables: [Variable(id)]).getSingle())
            .data
            .values
            .first
        as String?;

void main() {
  group('calendarDayOf', () {
    test('UTC midnight is its own day, whatever the zone', () {
      expect(calendarDayOf(DateTime.utc(2026, 10, 23)), DateTime(2026, 10, 23));
    });

    test('a local date and a local-midnight instant read locally', () {
      expect(calendarDayOf(DateTime(2026, 10, 23)), DateTime(2026, 10, 23));
      expect(
        calendarDayOf(DateTime(2026, 10, 23).toUtc()),
        DateTime(2026, 10, 23),
      );
    });
  });

  group('completion ids', () {
    test('a day alone names one occurrence in every zone', () {
      // Local midnight here, the instant form a pull hands over, and the
      // stored UTC midnight — what three devices zones apart each hold.
      final ids = {
        for (final due in [
          DateTime(2026, 10, 19),
          DateTime(2026, 10, 19).toUtc(),
          DateTime.utc(2026, 10, 19),
        ])
          todoTaskCompletionId('t', due, dueHasTime: false),
      };
      expect(ids, {'t_${DateTime.utc(2026, 10, 19).microsecondsSinceEpoch}'});
    });

    test('a timed or undated occurrence keeps the id it always had', () {
      final due = DateTime.utc(2026, 10, 19, 13, 30);
      expect(
        todoTaskCompletionId('t', due, dueHasTime: true),
        legacyTodoTaskCompletionId('t', due),
      );
      expect(todoTaskCompletionId('t', null, dueHasTime: false), 't_undated');
    });
  });

  group('stored form', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.inMemory());
    tearDown(() => db.close());

    test('a date-only due day is written as UTC midnight and reads back as '
        'local midnight', () async {
      final repo = DriftTodoRepository(db);
      await repo.upsertTask(_task('day', DateTime(2026, 10, 23)));
      expect(
        await _raw(
          db,
          'SELECT due_date FROM todo_tasks_table WHERE id = ?',
          'day',
        ),
        '2026-10-23T00:00:00.000Z',
      );
      expect((await repo.getTask('day'))!.dueDate, DateTime(2026, 10, 23));
    });

    test('a timed due date keeps its instant', () async {
      final repo = DriftTodoRepository(db);
      final due = DateTime(2026, 10, 23, 0, 0);
      await repo.upsertTask(_task('timed', due, hasTime: true));
      final read = (await repo.getTask('timed'))!.dueDate!;
      expect(read.isAtSameMomentAs(due), isTrue);
    });

    test("a bill's anchor is written as UTC midnight", () async {
      final repo = DriftFinanceRepository(db);
      await repo.upsertSubscription(
        Subscription(
          id: 'rent',
          createdAt: _t0,
          updatedAt: _t0,
          name: 'Rent',
          amountCents: 100,
          period: BillingPeriod.monthly,
          anchorDueDate: DateTime(2026, 11, 1),
        ),
      );
      expect(
        await _raw(
          db,
          'SELECT anchor_due_date FROM subscriptions_table WHERE id = ?',
          'rent',
        ),
        '2026-11-01T00:00:00.000Z',
      );
      expect(
        (await repo.listSubscriptions()).single.anchorDueDate,
        DateTime(2026, 11, 1),
      );
    });
  });

  group('sync form', () {
    test('a date-only due day syncs as UTC midnight, a timed one as its '
        'instant', () {
      expect(
        todoTaskToFirestore(_task('day', DateTime(2026, 10, 23)))['dueDate'],
        '2026-10-23T00:00:00.000Z',
      );
      final timed = DateTime(2026, 10, 23, 9);
      expect(
        todoTaskToFirestore(_task('t', timed, hasTime: true))['dueDate'],
        timed.toUtc().toIso8601String(),
      );
    });

    test("an older build's local-midnight document still reads as its day "
        'here', () {
      final legacy = DateTime(2026, 10, 23).toUtc().toIso8601String();
      final task = mergeTodoTaskFromRemote({
        'listId': 'l',
        'title': 'old',
        'dueDate': legacy,
        'dueHasTime': false,
        'updatedAt': _t0.toIso8601String(),
        'version': 1,
      }, 'old');
      expect(task.dueDate, DateTime(2026, 10, 23));
    });
  });

  group('schema 165 migration', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('voyager_utc_days_165_test');
      file = File('${dir.path}/voyager.sqlite');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('legacy local-midnight values move to UTC midnight of the day they '
        'were written for', () async {
      final seed = AppDatabase(NativeDatabase(file));
      final tasks = DriftTodoRepository(seed);
      await tasks.upsertTask(_task('wall', DateTime(2026, 10, 23)));
      await tasks.upsertTask(_task('instant', DateTime(2026, 10, 24)));
      await tasks.upsertTask(
        _task('timed', DateTime(2026, 10, 25, 9), hasTime: true),
      );
      // As older builds left them: local wall time with the writer's offset
      // (here a zone this device isn't in), and the UTC instant of a local
      // midnight (what a pull or a Trash restore wrote).
      await seed.customStatement(
        'UPDATE todo_tasks_table SET due_date = ? WHERE id = ?',
        ['2026-10-23T00:00:00.000 -07:00', 'wall'],
      );
      await seed.customStatement(
        'UPDATE todo_tasks_table SET due_date = ? WHERE id = ?',
        [DateTime(2026, 10, 24).toUtc().toIso8601String(), 'instant'],
      );
      final timedRaw = await _raw(
        seed,
        'SELECT due_date FROM todo_tasks_table WHERE id = ?',
        'timed',
      );
      await seed.customStatement('PRAGMA user_version = 164');
      await seed.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final repo = DriftTodoRepository(db);
      Future<String?> due(String id) =>
          _raw(db, 'SELECT due_date FROM todo_tasks_table WHERE id = ?', id);

      expect(await due('wall'), '2026-10-23T00:00:00.000Z');
      expect(await due('instant'), '2026-10-24T00:00:00.000Z');
      expect(await due('timed'), timedRaw, reason: 'a time of day is kept');
      expect(
        (await repo.getTask('wall'))!.version,
        1,
        reason: 'or the next pull puts the old value back',
      );
      expect((await repo.getTask('timed'))!.version, 0);
    });
  });
}
