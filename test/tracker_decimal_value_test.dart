// Schema 127 lets an integer tracker record decimals: `int_value` moves from
// INTEGER to REAL. Existing databases hold whole numbers written under the old
// column, and those have to come through the rebuild unchanged.
//
// The migration test rewinds `user_version` and reopens, so the real
// `onUpgrade` path runs rather than a hand-written approximation of it.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/analytics/tracker_entry_row.dart';

/// Puts `int_value` back to INTEGER affinity, holding one whole-number row,
/// and resets `user_version` to 126.
Future<void> _rewindToSchema126(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  final ddl =
      (await db
              .customSelect(
                "SELECT sql FROM sqlite_master WHERE name = 'tracker_values_table'",
              )
              .getSingle())
          .read<String>('sql');
  expect(ddl, contains('"int_value" REAL'));
  await db.customStatement('DROP TABLE tracker_values_table');
  await db.customStatement(
    ddl.replaceFirst('"int_value" REAL', '"int_value" INTEGER'),
  );
  await db.customStatement(
    'INSERT INTO tracker_values_table '
    '(id, tracker_id, period_start, int_value, created_at, updated_at) '
    "VALUES ('v1', 't1', '2026-09-01T00:00:00.000Z', 7, "
    "'2026-09-01T00:00:00.000Z', '2026-09-01T00:00:00.000Z')",
  );
  await db.customStatement('PRAGMA user_version = 126');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voyager_tracker_decimal_test');
    file = File('${dir.path}/voyager.sqlite');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('upgrade keeps whole numbers and then stores decimals', () async {
    await _rewindToSchema126(file);

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final repo = DriftTrackerRepository(db);

    final migrated = (await repo.getValue('v1'))!;
    expect(migrated.intValue, 7);

    await repo.upsertValue(migrated.copyWith(intValue: 7.5));
    expect((await repo.getValue('v1'))!.intValue, 7.5);

    final type = await db
        .customSelect(
          "SELECT type FROM pragma_table_info('tracker_values_table') "
          "WHERE name = 'int_value'",
        )
        .getSingle();
    expect(type.read<String>('type'), 'REAL');
  });

  test('sync keeps the fraction', () {
    final now = DateTime.utc(2026, 9, 1);
    final value = TrackerValue(
      id: 'v1',
      trackerId: 't1',
      periodStart: now,
      intValue: 2.25,
      createdAt: now,
      updatedAt: now,
    );
    final merged = mergeTrackerValueFromRemote(
      trackerValueToFirestore(value),
      'v1',
    );
    expect(merged.intValue, 2.25);
  });

  test('formatTrackerNumber drops a trailing .0 and caps at two places', () {
    expect(formatTrackerNumber(8), '8');
    expect(formatTrackerNumber(7.5), '7.5');
    expect(formatTrackerNumber(10.25), '10.25');
    expect(formatTrackerNumber(0), '0');
    expect(formatTrackerNumber(-0.001), '0');
    expect(formatTrackerNumber(-2.5), '-2.5');
  });

  group('entry row', () {
    late AppDatabase memDb;
    late ProviderContainer container;
    final date = DateTime(2026, 8, 14);

    setUp(() async {
      memDb = AppDatabase(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(memDb)],
      );
      final now = DateTime.utc(2026, 8, 1);
      await container
          .read(trackerRepositoryProvider)
          .upsertTracker(
            StatisticTracker(
              id: 'tracker-1',
              name: 'Hours slept',
              type: TrackerType.integer,
              cadence: TrackerCadence.daily,
              createdAt: now,
              updatedAt: now,
            ),
          );
      await container.read(settingsProvider.future);
    });

    tearDown(() async {
      container.dispose();
      await memDb.close();
    });

    /// Types [text] into the row's number field, submits it, and returns what
    /// was stored. The trailing pump runs out the row's "saved" flash.
    Future<double?> enter(WidgetTester tester, String text) async {
      final repo = container.read(trackerRepositoryProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: TrackerEntryRow(
                tracker: (await repo.listTrackers()).single,
                date: date,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextField).first;
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      return (await repo.getValue('tracker-1_2026-08-14'))?.intValue;
    }

    testWidgets('saves a decimal', (tester) async {
      expect(await enter(tester, '7.25'), 7.25);
    });

    testWidgets('saves a negative on an uncapped tracker', (tester) async {
      expect(await enter(tester, '-3.5'), -3.5);
    });

    testWidgets('drops digits past the second decimal place', (tester) async {
      expect(await enter(tester, '12.345'), 12.34);
    });
  });
}
