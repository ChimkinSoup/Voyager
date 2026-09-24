// Switching to or away from the calendar branch must not rebuild the page.
//
// The page only picks up todo marker changes while its branch is on screen,
// and it used to learn that by reading TickerMode in build — a dependency that
// rebuilt the whole page, month grid included, on every switch in and out,
// whether or not any marker had changed. Only a change made while away should
// cost a rebuild on arrival.

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
import 'package:voyager/features/calendar/calendar_grid.dart';
import 'package:voyager/features/calendar/calendar_page.dart';

import 'fakes/fake_weather_api_client.dart';

/// The list the overridden [calendarTodoMarkersProvider] serves.
final _liveMarkers = StateProvider<List<CalendarTodoMarker>>((ref) => const []);

CalendarTodoMarker _marker(String id) {
  final now = DateTime.now();
  return CalendarTodoMarker(
    taskId: id,
    listId: 'list',
    colorValue: 0xFF3366FF,
    dueDate: now,
    sortKey: now,
    title: id,
  );
}

/// Pumps a real [CalendarPage] under a [TickerMode] driven by [onScreen], the
/// way ShellBranchContainer drives a branch.
Future<ProviderContainer> _pumpCalendar(
  WidgetTester tester,
  ValueNotifier<bool> onScreen,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final now = utcNow();
  await DriftCalendarRepository(db).upsertCalendar(
    Calendar(
      id: legacyCalendarId,
      name: 'Calendar',
      createdAt: now,
      updatedAt: now,
    ),
  );

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      calendarTodoMarkersProvider.overrideWith(
        (ref) async => ref.watch(_liveMarkers),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  await container.read(calendarsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: onScreen,
            builder: (context, enabled, child) =>
                TickerMode(enabled: enabled, child: child!),
            child: const CalendarPage(),
          ),
        ),
      ),
    ),
  );
  // Not pumpAndSettle: the page runs continuous animations.
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return container;
}

/// The grid is rebuilt from the page's build, so a new widget instance here
/// means the page rebuilt.
Widget _grid(WidgetTester tester) => tester.widget(find.byType(CalendarGrid));

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('switching away and back with nothing changed does not rebuild', (
    tester,
  ) async {
    final onScreen = ValueNotifier(true);
    await _pumpCalendar(tester, onScreen);
    final before = _grid(tester);

    onScreen.value = false;
    await tester.pump();
    onScreen.value = true;
    await tester.pump();

    expect(identical(_grid(tester), before), isTrue);
  });

  testWidgets('a marker change while away lands on arrival, not before', (
    tester,
  ) async {
    final onScreen = ValueNotifier(true);
    final container = await _pumpCalendar(tester, onScreen);

    onScreen.value = false;
    await tester.pump();
    final away = _grid(tester);

    container.read(_liveMarkers.notifier).state = [_marker('a')];
    await tester.pump();
    await tester.pump();
    expect(identical(_grid(tester), away), isTrue);

    onScreen.value = true;
    await tester.pump();
    expect(identical(_grid(tester), away), isFalse);
  });

  testWidgets('a marker change while on screen rebuilds at once', (
    tester,
  ) async {
    final onScreen = ValueNotifier(true);
    final container = await _pumpCalendar(tester, onScreen);
    final before = _grid(tester);

    container.read(_liveMarkers.notifier).state = [_marker('a')];
    await tester.pump();
    await tester.pump();

    expect(identical(_grid(tester), before), isFalse);
  });
}
