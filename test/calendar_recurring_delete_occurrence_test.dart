// Deleting one occurrence of a repeating event has to drop the one that was
// right-clicked.
//
// A repeating event is a single row drawn on many days, so the row alone cannot
// say which occurrence the user meant — only the day cell it was clicked in
// can. When the page passed its own focused day instead, that day was usually
// not an occurrence at all and the scope resolver fell back to the series
// anchor, so every "this event only" delete took the *first* occurrence,
// whichever one had been clicked.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_page.dart';

import 'fakes/fake_weather_api_client.dart';

const _eventId = 'weekly';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('drops the occurrence that was clicked, not the first', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftCalendarRepository(db);
    final now = utcNow();
    await repo.upsertCalendar(
      Calendar(
        id: legacyCalendarId,
        name: 'Calendar',
        createdAt: now,
        updatedAt: now,
      ),
    );

    // Anchored on the first of this month so several occurrences land in the
    // grid the page opens on.
    final today = DateTime.now();
    final anchor = DateTime(today.year, today.month, 1, 9);
    await repo.upsertEvent(
      CalendarEvent(
        id: _eventId,
        calendarId: legacyCalendarId,
        title: 'Standup',
        start: anchor,
        end: anchor.add(const Duration(hours: 1)),
        isFullDay: false,
        createdAt: now,
        updatedAt: now,
        recurrence: const RecurrenceRule(frequency: EventRecurrence.weekly),
      ),
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await container.read(calendarsProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: CalendarPage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // The third occurrence — two weeks past the anchor — so neither the first
    // nor the page's focused day can stand in for it.
    final target = DateTime(anchor.year, anchor.month, anchor.day + 14);
    final bar = find.byWidgetPredicate(
      (w) =>
          w is CalendarDayEventBar &&
          w.event.id == _eventId &&
          w.date.year == target.year &&
          w.date.month == target.month &&
          w.date.day == target.day,
    );
    expect(bar, findsOneWidget, reason: 'the occurrence is on screen');

    await tester.tap(bar, buttons: kSecondaryButton, warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('This event only'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final master = (await repo.getEvent(_eventId))!;
    expect(master.deletedAt, isNull, reason: 'the series itself survives');
    expect(master.exceptionDates.map((d) => DateTime(d.year, d.month, d.day)), [
      DateTime(target.year, target.month, target.day),
    ]);
  });
}
