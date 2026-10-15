// The event panel saved the whole row from the copy it opened with, so a
// change another device made while it was open was reverted — even by a plain
// click outside the panel (BUG-233). And it showed a pulled event's times in
// UTC, since the pull stores them as UTC instants (BUG-234).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/time_selector_popovers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_event_panel.dart';
import 'package:voyager/features/calendar/calendar_page.dart';

import 'fakes/fake_weather_api_client.dart';

final _today = DateTime.now();

/// 3–4 PM local on the 12th, stored the way a pull stores it: as UTC.
final _start = DateTime(_today.year, _today.month, 12, 15).toUtc();
final _end = DateTime(_today.year, _today.month, 12, 16).toUtc();

Future<(AppDatabase, DriftCalendarRepository)> _seed() async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftCalendarRepository(db);
  final now = utcNow();
  await repo.upsertCalendar(
    Calendar(
      id: legacyCalendarId,
      name: 'Home',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await repo.upsertEvent(
    CalendarEvent(
      id: 'ev',
      calendarId: legacyCalendarId,
      title: 'Dentist',
      start: _start,
      end: _end,
      isFullDay: false,
      colorValue: 0xFFAA0000,
      createdAt: now,
      updatedAt: now,
      version: 1,
    ),
  );
  return (db, repo);
}

Future<void> _pumpPage(WidgetTester tester, AppDatabase db) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  final settingsRepo = DriftSettingsRepository(db);
  await settingsRepo.saveSettings(
    (await settingsRepo.getSettings()).copyWith(
      lastViewedCalendarId: legacyCalendarId,
    ),
  );
  await container.read(settingsProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: CalendarPage())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(
    find.byWidgetPredicate(
      (w) => w is CalendarDayEventBar && w.event.id == 'ev',
    ),
    warnIfMissed: false,
  );
  await tester.pumpAndSettle();
  expect(find.byType(CalendarEventPanel), findsOneWidget);
}

/// Another device moves the event to 6–7 PM while the panel is open.
Future<void> _moveElsewhere(DriftCalendarRepository repo) async {
  final event = (await repo.getEvent('ev'))!;
  await repo.upsertEvent(
    event.copyWith(
      start: DateTime(_today.year, _today.month, 12, 18).toUtc(),
      end: DateTime(_today.year, _today.month, 12, 19).toUtc(),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('a pulled event opens at its local time', (tester) async {
    final (db, _) = await _seed();
    await _pumpPage(tester, db);
    await _openPanel(tester);

    expect(
      find.descendant(
        of: find.byType(CalendarEventPanel),
        matching: find.textContaining('3:00 PM'),
      ),
      findsWidgets,
    );
  });

  testWidgets('clicking outside an untouched panel keeps a change made '
      'elsewhere meanwhile', (tester) async {
    final (db, repo) = await _seed();
    await _pumpPage(tester, db);
    await _openPanel(tester);
    await _moveElsewhere(repo);
    final moved = (await repo.getEvent('ev'))!;

    await tester.tapAt(const Offset(5, 995));
    await _settle(tester);

    final stored = (await repo.getEvent('ev'))!;
    expect(stored.start.isAtSameMomentAs(moved.start), isTrue);
    expect(stored.version, moved.version, reason: 'nothing written');
  });

  testWidgets('saving a title edit keeps a time change made elsewhere '
      'meanwhile', (tester) async {
    final (db, repo) = await _seed();
    await _pumpPage(tester, db);
    await _openPanel(tester);
    await _moveElsewhere(repo);
    final moved = (await repo.getEvent('ev'))!;

    await tester.enterText(
      find
          .descendant(
            of: find.byType(CalendarEventPanel),
            matching: find.byType(EditableText),
          )
          .first,
      'Dentist (moved)',
    );
    await tester.tap(find.text('Save').last);
    await _settle(tester);

    final stored = (await repo.getEvent('ev'))!;
    expect(stored.title, 'Dentist (moved)');
    expect(stored.start.isAtSameMomentAs(moved.start), isTrue);
    expect(stored.end.isAtSameMomentAs(moved.end), isTrue);
  });

  testWidgets('an end changed here over a start moved elsewhere keeps the '
      'times together', (tester) async {
    final (db, repo) = await _seed();
    await _pumpPage(tester, db);
    await _openPanel(tester);
    await _moveElsewhere(repo);

    // Only the end changes here: 3–5 PM instead of 3–4 PM.
    final timePill = find.ancestor(
      of: find
          .descendant(
            of: find.byType(CalendarEventPanel),
            matching: find.textContaining('4:00 PM'),
          )
          .first,
      matching: find.byType(SelectorPill),
    );
    tester.widget<SelectorPill>(timePill.first).onTap();
    await tester.pumpAndSettle();
    final popover = find.byType(TimeRangePopover);
    tester.widget<TimeRangePopover>(popover).onChanged!(
      DateTimeRange(
        start: _start.toLocal(),
        end: DateTime(_today.year, _today.month, 12, 17),
      ),
    );
    Navigator.of(tester.element(popover)).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save').last);
    await _settle(tester);

    final stored = (await repo.getEvent('ev'))!;
    expect(stored.start.isAtSameMomentAs(_start), isTrue);
    expect(
      stored.end.isAtSameMomentAs(DateTime(_today.year, _today.month, 12, 17)),
      isTrue,
    );
  });
}
