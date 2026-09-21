// What the calendar page opens into, and what it writes down when you change
// it. The model/sync half of the same behaviour is in
// calendar_last_viewed_test.dart.

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
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/calendar/calendar_page.dart';

import 'fakes/fake_weather_api_client.dart';

/// Pumps a real [CalendarPage] over a database holding the default calendar
/// and one called "Work", with [configureSettings] applied first.
///
/// Deliberately not `pumpAndSettle`: the page runs continuous animations, so
/// settling never arrives. Two pumps are enough for the restore, which happens
/// in `initState` and again on the first build that has settings.
Future<AppDatabase> _pumpCalendar(
  WidgetTester tester, {
  AppSettings Function(AppSettings settings)? configureSettings,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final calendars = DriftCalendarRepository(db);
  final now = utcNow();
  await calendars.upsertCalendar(
    Calendar(
      id: legacyCalendarId,
      name: 'Calendar',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await calendars.upsertCalendar(
    Calendar(
      // Coloured, so the trigger's own colour is distinguishable from the
      // app accent the all-view falls back to.
      id: 'work',
      name: 'Work',
      colorValue: 0xFF00FF00,
      createdAt: now,
      updatedAt: now,
    ),
  );
  if (configureSettings != null) {
    final settings = DriftSettingsRepository(db);
    await settings.saveSettings(
      configureSettings(await settings.getSettings()),
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
  await container.read(calendarsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: CalendarPage())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return db;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('reopens the calendar it was left on', (tester) async {
    await _pumpCalendar(
      tester,
      configureSettings: (s) => s.copyWith(lastViewedCalendarId: 'work'),
    );

    expect(find.text('Work'), findsOneWidget);
    expect(find.text('All calendars'), findsNothing);
  });

  // The all-view is its own fact, so it is restored on its own — and the
  // dropdown says so rather than naming whichever calendar was open when the
  // toggle went on, which read as if that one were still the filter.
  testWidgets('reopens into the all-view, and the dropdown says so', (
    tester,
  ) async {
    await _pumpCalendar(
      tester,
      configureSettings: (s) => s.copyWith(
        lastViewedCalendarId: 'work',
        calendarShowAllCalendars: true,
      ),
    );

    expect(find.text('All calendars'), findsOneWidget);
    expect(find.text('Work'), findsNothing);
  });

  testWidgets('turning the all-view on writes both facts down', (tester) async {
    final db = await _pumpCalendar(
      tester,
      configureSettings: (s) => s.copyWith(lastViewedCalendarId: 'work'),
    );

    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All calendars'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final saved = await DriftSettingsRepository(db).getSettings();
    expect(saved.calendarShowAllCalendars, isTrue);
    // The concrete calendar is kept, not overwritten: it is where an event
    // created from the all-view is filed.
    expect(saved.lastViewedCalendarId, 'work');
    expect(find.text('All calendars'), findsOneWidget);
  });

  // The name is only half of what the trigger says: it is drawn in the scope's
  // own colour, and the all-view has none of its own. Leaving the last
  // calendar's colour on it read as if that calendar were still the filter.
  testWidgets('the all-view trigger takes the app accent, not the last '
      "calendar's colour", (tester) async {
    await _pumpCalendar(
      tester,
      configureSettings: (s) => s.copyWith(lastViewedCalendarId: 'work'),
    );
    final accent = Theme.of(
      tester.element(find.byType(CalendarPage)),
    ).colorScheme.primary;
    Color? triggerColor(String label) =>
        tester.widget<Text>(find.text(label)).style?.color;

    expect(triggerColor('Work'), const Color(0xFF00FF00));

    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All calendars'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(triggerColor('All calendars'), accent);
  });

  testWidgets('and does on a cold start into the all-view too', (tester) async {
    await _pumpCalendar(
      tester,
      configureSettings: (s) => s.copyWith(
        lastViewedCalendarId: 'work',
        calendarShowAllCalendars: true,
      ),
    );
    final accent = Theme.of(
      tester.element(find.byType(CalendarPage)),
    ).colorScheme.primary;
    expect(
      tester.widget<Text>(find.text('All calendars')).style?.color,
      accent,
    );
  });
}
