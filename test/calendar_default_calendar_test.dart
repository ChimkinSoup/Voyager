// The built-in "Calendar" could never be deleted, and there was no way to make
// another calendar the default. Now any calendar can be set as the default
// from Manage calendars, any calendar but the last can be deleted, and "Move"
// sends its events to the default calendar or the oldest one left.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_manage_sheet.dart';
import 'package:voyager/features/calendar/calendar_page.dart';

import 'fakes/fake_weather_api_client.dart';

Future<(AppDatabase, ProviderContainer)> _setUp(
  WidgetTester tester,
  List<(String, String)> calendars,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftCalendarRepository(db);
  final t0 = utcNow().subtract(const Duration(days: 30));
  for (final (i, (id, name)) in calendars.indexed) {
    final created = t0.add(Duration(days: i));
    await repo.upsertCalendar(
      Calendar(id: id, name: name, createdAt: created, updatedAt: created),
    );
  }
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  return (db, container);
}

Future<void> _pumpManageSheet(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: ElevatedButton(
                onPressed: () => showCalendarManageSheet(context, ref),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _openMenuOf(WidgetTester tester, String name) async {
  await tester.tap(
    find.descendant(
      of: find.widgetWithText(ListTile, name),
      matching: find.byType(ContextMenuButton),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('"Set as default" marks the calendar, and deleting the built-in '
      'one moves its events there', (tester) async {
    final (db, container) = await _setUp(tester, [
      (legacyCalendarId, 'Calendar'),
      ('home', 'Home'),
      ('work', 'Work'),
    ]);
    final repo = DriftCalendarRepository(db);
    final now = utcNow();
    await repo.upsertEvent(
      CalendarEvent(
        id: 'test-data',
        calendarId: legacyCalendarId,
        title: 'Test data',
        start: now,
        end: now,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _pumpManageSheet(tester, container);

    await _openMenuOf(tester, 'Work');
    await tester.tap(find.text('Set as default'));
    await tester.pumpAndSettle();

    expect(
      (await DriftSettingsRepository(db).getSettings()).defaultCalendarId,
      'work',
    );
    expect(find.text('0 events · Default'), findsOneWidget);

    await _openMenuOf(tester, 'Calendar');
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    // "Home" is older, so it would win on age alone.
    await tester.tap(find.text('Move to "Work"'));
    await tester.pumpAndSettle();

    expect((await repo.getCalendar(legacyCalendarId))!.deletedAt, isNotNull);
    expect((await repo.getEvent('test-data'))!.calendarId, 'work');

    await _openMenuOf(tester, 'Work');
    await tester.tap(find.text('Remove as default'));
    await tester.pumpAndSettle();
    expect(
      (await DriftSettingsRepository(db).getSettings()).defaultCalendarId,
      isNull,
    );
  });

  testWidgets('the last calendar has no Delete', (tester) async {
    final (_, container) = await _setUp(tester, [('work', 'Work')]);
    await _pumpManageSheet(tester, container);

    await _openMenuOf(tester, 'Work');

    expect(find.text('Set as default'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('the page does not bring back a deleted built-in calendar', (
    tester,
  ) async {
    final (db, container) = await _setUp(tester, [
      (legacyCalendarId, 'Calendar'),
      ('work', 'Work'),
    ]);
    final repo = DriftCalendarRepository(db);
    await repo.softDeleteCalendar(legacyCalendarId);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: CalendarPage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect((await repo.listCalendars()).map((c) => c.id), ['work']);
  });
}
