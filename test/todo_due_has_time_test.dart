// A due date's "has a time" is its own field (schema 156). Before it, a date
// alone was stored as local midnight and any midnight read as "no time", so a
// task due at 12:00 AM lost its time. Rows, cloud documents and backups from
// before the field are read by that old rule; everything written since keeps
// what was picked.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';

TodoTask _task(String id, DateTime? due, {bool hasTime = false}) {
  final now = utcNow();
  return TodoTask(
    id: id,
    listId: 'list',
    title: id,
    dueDate: due?.toUtc(),
    dueHasTime: hasTime,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  final midnight = DateTime(2026, 10, 19);
  final afternoon = DateTime(2026, 10, 19, 15, 30);

  group('upgrade to schema 156', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('voyager_due_has_time_test');
      file = File('${dir.path}/voyager.sqlite');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('reads existing due dates by the midnight rule', () async {
      var db = AppDatabase(NativeDatabase(file));
      var repo = DriftTodoRepository(db);
      await repo.upsertTask(_task('timed', afternoon));
      await repo.upsertTask(_task('dated', midnight));
      await repo.upsertTask(_task('undated', null));
      await db.close();

      // Rewound to schema 155, so reopening runs the real upgrade.
      db = AppDatabase(NativeDatabase(file));
      await db.customStatement(
        'ALTER TABLE todo_tasks_table DROP COLUMN due_has_time',
      );
      await db.customStatement('PRAGMA user_version = 155');
      await db.close();

      db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      repo = DriftTodoRepository(db);
      expect((await repo.getTask('timed'))!.dueHasTime, isTrue);
      expect((await repo.getTask('dated'))!.dueHasTime, isFalse);
      expect((await repo.getTask('undated'))!.dueHasTime, isFalse);
    });
  });

  test('a task due at 12:00 AM keeps its time through the database', () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftTodoRepository(db);
    await repo.upsertTask(_task('t', midnight, hasTime: true));
    final stored = (await repo.getTask('t'))!;
    expect(stored.dueHasTime, isTrue);
    expect(stored.dueDate!.toLocal(), midnight);
  });

  group('cloud documents', () {
    test('a document with the field keeps a 12:00 AM time', () {
      final task = _task('t', midnight, hasTime: true);
      final data = todoTaskToFirestore(task);
      expect(data['dueHasTime'], isTrue);
      expect(mergeTodoTaskFromRemote(data, 't').dueHasTime, isTrue);
    });

    test('a document from before the field is read by the midnight rule', () {
      Map<String, dynamic> legacy(DateTime due) =>
          todoTaskToFirestore(_task('t', due))..remove('dueHasTime');
      expect(
        mergeTodoTaskFromRemote(legacy(afternoon), 't').dueHasTime,
        isTrue,
      );
      expect(
        mergeTodoTaskFromRemote(legacy(midnight), 't').dueHasTime,
        isFalse,
      );
    });

    test('a losing remote leaves the local flag alone', () {
      final local = _task(
        't',
        midnight,
        hasTime: true,
      ).copyWith(version: 5, bumpVersion: false);
      final remote = todoTaskToFirestore(_task('t', midnight))..['version'] = 1;
      expect(
        mergeTodoTaskFromRemote(remote, 't', local: local).dueHasTime,
        isTrue,
      );
    });
  });

  test('a backup from before the field is read by the midnight rule', () {
    final json = _task('t', afternoon).toJson()..remove('dueHasTime');
    expect(TodoTask.fromJson(json).dueHasTime, isTrue);
    expect(
      TodoTask.fromJson(
        _task('t', midnight, hasTime: true).toJson(),
      ).dueHasTime,
      isTrue,
    );
  });

  test('clearing the due date clears its time', () {
    final cleared = _task(
      't',
      afternoon,
      hasTime: true,
    ).copyWith(clearDueDate: true);
    expect(cleared.dueHasTime, isFalse);
  });

  test(
    'switching a due date between date-only and 12:00 AM saves the flag',
    () {
      final dated = _task('t', midnight);
      final batch = applyDueDateChange(
        dated,
        [dated],
        dueDate: dated.dueDate,
        clearDueDate: false,
        dueHasTime: true,
      );
      expect(batch.tasks.single.dueHasTime, isTrue);
      expect(batch.tasks.single.dueDate, dated.dueDate);
    },
  );
}
