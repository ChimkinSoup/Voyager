// The import dialog end to end: paste an AI reply, import, and the events and
// their bells land in the chosen calendar. Parsing itself is pinned in
// calendar_event_import_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/reminders/reminder_os_notifier.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_import_dialog.dart';

void main() {
  testWidgets('imports the pasted events and their reminders, then undoes it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final now = utcNow();
    final work = Calendar(
      id: 'w',
      name: 'Work',
      colorValue: 0xFF8CAAEE,
      createdAt: now,
      updatedAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        reminderOsNotifierProvider.overrideWithValue(NoopReminderOsNotifier()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);

    int? imported = -1;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => imported = await showCalendarImportDialog(
                context,
                calendars: [work],
                initialCalendarId: 'w',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(EditableText), '''```json
[
  {"title": "Standup", "date": "2026-10-05", "start": "09:30", "reminder": 15},
  {"title": "Offsite", "date": "2026-10-07", "color": "Green", "notes": "Bus at 8"}
]
```''');
    await tester.pump();
    expect(find.text('Standup'), findsOneWidget);
    expect(find.text('Offsite'), findsOneWidget);

    await tester.tap(find.text('Import 2 events'));
    await tester.pumpAndSettle();
    expect(imported, 2);

    final events = await DriftCalendarRepository(db).listEvents();
    final standup = events.singleWhere((e) => e.title == 'Standup');
    final offsite = events.singleWhere((e) => e.title == 'Offsite');
    expect(standup.calendarId, 'w');
    expect(standup.isFullDay, isFalse);
    expect(standup.start, DateTime(2026, 10, 5, 9, 30));
    expect(standup.colorValue, work.colorValue);
    expect(offsite.isFullDay, isTrue);
    expect(offsite.colorValue, 0xFFA6D189);
    expect(offsite.notes, 'Bus at 8');

    final reminders = await container
        .read(reminderRepositoryProvider)
        .listEntityReminders();
    expect(reminders.map((r) => (r.entityId, r.offsetMinutes)), [
      (standup.id, 15),
    ]);

    expect(find.text('Imported 2 events'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final remaining = await DriftCalendarRepository(db).listEvents();
    expect(remaining.where((e) => e.deletedAt == null), isEmpty);
  });

  for (final failUndo in [false, true]) {
    testWidgets(
      failUndo
          ? 'a failed import whose undo fails too says events may remain'
          : 'a write failing partway takes back what landed and says so',
      (tester) => _importFailingPartway(tester, failUndo: failUndo),
    );
  }
}

Future<void> _importFailingPartway(
  WidgetTester tester, {
  required bool failUndo,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final now = utcNow();
  final work = Calendar(id: 'w', name: 'Work', createdAt: now, updatedAt: now);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      reminderOsNotifierProvider.overrideWithValue(NoopReminderOsNotifier()),
      calendarRepositoryProvider.overrideWithValue(
        _FailingSecondWriteRepository(db, failAfter: failUndo),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showCalendarImportDialog(
              context,
              calendars: [work],
              initialCalendarId: 'w',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(EditableText), '''[
  {"title": "One", "date": "2026-10-05"},
  {"title": "Two", "date": "2026-10-06"}
]''');
  await tester.pump();
  await tester.tap(find.text('Import 2 events'));
  await tester.pumpAndSettle();

  final events = await DriftCalendarRepository(db).listEvents();
  final live = events.where((e) => e.deletedAt == null).map((e) => e.title);
  if (failUndo) {
    expect(find.textContaining('could not all be removed'), findsOneWidget);
    expect(live, ['One']);
  } else {
    expect(find.textContaining('nothing was added'), findsOneWidget);
    expect(live, isEmpty);
  }
  // Import is live again for a retry.
  final button = tester.widget<GlassButton>(
    find.widgetWithText(GlassButton, 'Import 2 events'),
  );
  expect(button.onPressed, isNotNull);
}

/// Fails the second event write, and with [failAfter] every one after it —
/// which includes the soft deletes that take an import back.
class _FailingSecondWriteRepository extends DriftCalendarRepository {
  _FailingSecondWriteRepository(super.db, {required this.failAfter});

  final bool failAfter;
  var _writes = 0;

  @override
  Future<void> upsertEvent(
    CalendarEvent event, {
    bool recordLocalActivity = true,
  }) {
    _writes++;
    if (_writes == 2 || (failAfter && _writes > 2)) {
      throw StateError('disk full');
    }
    return super.upsertEvent(event, recordLocalActivity: recordLocalActivity);
  }
}
