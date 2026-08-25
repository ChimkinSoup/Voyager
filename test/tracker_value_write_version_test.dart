// Every tracker-value write has to be a new *revision* of whatever is already
// on disk.
//
// The analytics surfaces used to build `TrackerValue` with a bare constructor
// that passed neither `version:` nor `deletedAt:`, so `SoftDeletable`'s
// defaults applied and each edit shipped at version 0 with no tombstone.
// Conflict resolution is version-first, which turned that into two ordinary
// ways to lose data:
//
//  * a row whose version had ever climbed — through a delete, or a merge from
//    another device — was reverted to the remote copy on the next pull;
//  * re-entering a value on a deleted period rewrote the *same* row id (it is
//    derived deterministically from tracker + date) at version 0 while the
//    remote still held the tombstone at version 1, so the value the user had
//    just typed was deleted again with nothing to explain why.
//
// Driven through [TrackerEntryRow] against a real repository, so it exercises
// the write path rather than a restatement of it.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/analytics/tracker_entry_row.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late TrackerRepository repo;

  final createdAt = DateTime.utc(2026, 8, 1);
  final date = DateTime(2026, 8, 14);
  const trackerId = 'tracker-1';
  final valueId = 'tracker-1_2026-08-14';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    repo = container.read(trackerRepositoryProvider);
    await repo.upsertTracker(
      StatisticTracker(
        id: trackerId,
        name: 'Pushups',
        type: TrackerType.integer,
        cadence: TrackerCadence.daily,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
    // Riverpod only builds a provider once something reads it; the settings
    // this row's tree reaches for are null until then.
    await container.read(settingsProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> pumpRow(WidgetTester tester) async {
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
  }

  /// Types [text] into the row's number field and submits it.
  ///
  /// The trailing pump runs out the row's two-second "saved" flash, which is a
  /// bare `Future.delayed` and would otherwise still be pending when the
  /// widget tree is torn down.
  Future<void> enter(WidgetTester tester, String text) async {
    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  testWidgets('an edit bumps the stored version rather than resetting it', (
    tester,
  ) async {
    await repo.upsertValue(
      TrackerValue(
        id: valueId,
        trackerId: trackerId,
        periodStart: date,
        intValue: 10,
        version: 3,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );

    await pumpRow(tester);
    await enter(tester, '42');

    final saved = await repo.getValue(valueId);
    expect(saved!.intValue, 42);
    expect(saved.version, 4);
    expect(saved.deletedAt, isNull);
  });

  testWidgets('a first write on an untouched period starts at version 1', (
    tester,
  ) async {
    await pumpRow(tester);
    await enter(tester, '7');

    final saved = await repo.getValue(valueId);
    expect(saved!.intValue, 7);
    expect(saved.version, 1);
  });

  testWidgets('re-entering a deleted period lifts the tombstone and outranks '
      'it', (tester) async {
    await repo.upsertValue(
      TrackerValue(
        id: valueId,
        trackerId: trackerId,
        periodStart: date,
        intValue: 10,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
    await repo.softDeleteValue(valueId);

    final tombstone = await repo.getValue(valueId);
    expect(tombstone!.deletedAt, isNotNull);
    // The row the editor is about to write is the same one, because the id is
    // derived from tracker + date. `listValues` hides it, so the editor sees
    // nothing there — which is exactly how it used to write version 0.
    expect((await repo.listValues(trackerId)), isEmpty);

    await pumpRow(tester);
    await enter(tester, '25');

    final saved = await repo.getValue(valueId);
    expect(saved!.intValue, 25);
    expect(saved.deletedAt, isNull);
    expect(
      saved.version,
      greaterThan(tombstone.version),
      reason: 'the re-entered value must outrank the tombstone it replaces',
    );
    expect((await repo.listValues(trackerId)).single.intValue, 25);
  });

  testWidgets('createdAt survives a write that follows a delete', (
    tester,
  ) async {
    await repo.upsertValue(
      TrackerValue(
        id: valueId,
        trackerId: trackerId,
        periodStart: date,
        intValue: 10,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
    await repo.softDeleteValue(valueId);

    await pumpRow(tester);
    await enter(tester, '25');

    expect((await repo.getValue(valueId))!.createdAt, createdAt);
  });
}
