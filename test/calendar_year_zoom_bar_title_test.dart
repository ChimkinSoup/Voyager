// Zooming from month to year shrinks the month's bars in place, titling each
// once as the month grid does. Its "+N" cut-off has to come from the month
// cells it starts from: measured off the year tiles it ends on, every day
// looked folded, and every bar of a multi-day event was titled.

import 'package:drift/drift.dart' show driftRuntimeOptions;
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
import 'package:voyager/features/calendar/calendar_page.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  testWidgets('the month to year zoom titles a multi-day bar once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final now = utcNow();
    final repo = DriftCalendarRepository(db);
    await repo.upsertCalendar(
      Calendar(
        id: legacyCalendarId,
        name: 'Calendar',
        colorValue: 0xFF00FF00,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final today = DateTime.now();
    // Mon–Fri of the second full week of this month.
    final first = DateTime(today.year, today.month, 1);
    final monday = DateTime(
      first.year,
      first.month,
      1 + (8 - first.weekday) % 7 + 7,
    );
    await repo.upsertEvent(
      CalendarEvent(
        id: 'probe',
        createdAt: now,
        updatedAt: now,
        calendarId: legacyCalendarId,
        title: 'Probe span',
        start: monday,
        end: DateTime(monday.year, monday.month, monday.day + 4),
        isFullDay: true,
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
    expect(find.text('Probe span'), findsOneWidget);

    await tester.tap(find.text('Year'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Probe span'), findsOneWidget, reason: 'frame $i');
    }
    await tester.pump(const Duration(seconds: 1));
  });
}
