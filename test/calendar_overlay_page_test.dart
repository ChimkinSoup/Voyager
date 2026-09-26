// Calendar overlays where the user meets them: the manage dialog's "Also show"
// action, and the calendar page drawing, creating, editing and revealing with
// an overlay in place. The rule itself is pinned in calendar_overlay_test.dart.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_menu_catalog.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/calendar/calendar_day_grid.dart';
import 'package:voyager/features/calendar/calendar_event_panel.dart';
import 'package:voyager/features/calendar/calendar_manage_sheet.dart';
import 'package:voyager/features/calendar/calendar_page.dart';
import 'package:voyager/features/shell/reveal_request.dart';

import 'fakes/fake_weather_api_client.dart';

/// Lists calendars as slowly as a real database on its own isolate does. The
/// in-memory one answers within the tap's frame, so a list that blanks while
/// it reloads would never be painted.
class _SlowCalendarRepository extends DriftCalendarRepository {
  _SlowCalendarRepository(super.db);

  @override
  Future<List<Calendar>> listCalendars({bool includeDeleted = false}) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return super.listCalendars(includeDeleted: includeDeleted);
  }
}

/// A database holding the default calendar ("Home"), "Holidays" with one
/// all-day event on the 12th of this month, and "Work".
Future<(AppDatabase, DriftCalendarRepository)> _seed({
  List<String> homeOverlays = const [],
}) async {
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
      overlayCalendarIds: homeOverlays,
    ),
  );
  for (final (id, name) in [('h', 'Holidays'), ('w', 'Work')]) {
    await repo.upsertCalendar(
      Calendar(id: id, name: name, createdAt: now, updatedAt: now),
    );
  }
  final today = DateTime.now();
  await repo.upsertEvent(
    CalendarEvent(
      id: 'hol',
      calendarId: 'h',
      title: 'Holiday',
      start: DateTime(today.year, today.month, 12),
      end: DateTime(today.year, today.month, 12, 23, 59),
      colorValue: 0xFFAA0000,
      createdAt: now,
      updatedAt: now,
    ),
  );
  return (db, repo);
}

ProviderContainer _container(
  AppDatabase db, {
  CalendarRepository? calendarRepository,
}) {
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      if (calendarRepository != null)
        calendarRepositoryProvider.overrideWithValue(calendarRepository),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void _desktopWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Pumps a real [CalendarPage] opened on [calendarId].
///
/// Not `pumpAndSettle` to open: the page runs continuous animations.
Future<void> _pumpPage(
  WidgetTester tester,
  AppDatabase db,
  ProviderContainer container, {
  String calendarId = legacyCalendarId,
}) async {
  final settingsRepo = DriftSettingsRepository(db);
  await settingsRepo.saveSettings(
    (await settingsRepo.getSettings()).copyWith(
      lastViewedCalendarId: calendarId,
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

/// Opens [calendarName]'s row menu and picks "Also show".
Future<void> _openAlsoShow(WidgetTester tester, String calendarName) async {
  await tester.tap(
    find.descendant(
      of: find.widgetWithText(ListTile, calendarName),
      matching: find.byType(PopupMenuButton<VoyagerMenuCatalogEntry>),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Also show'));
  await tester.pumpAndSettle();
}

Finder _eventBar(String eventId) => find.byWidgetPredicate(
  (w) => w is CalendarDayEventBar && w.event.id == eventId,
);

Finder _panelField(int index) => find
    .descendant(
      of: find.byType(CalendarEventPanel),
      matching: find.byType(EditableText),
    )
    .at(index);

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  group('manage dialog', () {
    testWidgets('"Also show" writes the host\'s list and names it on the row', (
      tester,
    ) async {
      _desktopWindow(tester);
      final (db, repo) = await _seed();
      await _pumpManageSheet(tester, _container(db));

      await _openAlsoShow(tester, 'Home');
      expect(find.text('Show on "Home"'), findsOneWidget);

      await tester.tap(find.text('Holidays').last);
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect((await repo.getCalendar(legacyCalendarId))!.overlayCalendarIds, [
        'h',
      ]);
      expect(find.text('Also shows Holidays'), findsOneWidget);
      // Still the calendar's own count, not its own plus the overlay's.
      expect(find.text('0 events'), findsNWidgets(2));
    });

    testWidgets('lists every other calendar, never the host', (tester) async {
      _desktopWindow(tester);
      final (db, _) = await _seed();
      await _pumpManageSheet(tester, _container(db));

      await _openAlsoShow(tester, 'Work');

      final dialog = find.ancestor(
        of: find.text('Show on "Work"'),
        matching: find.byType(AlertDialog),
      );
      for (final name in ['Home', 'Holidays']) {
        expect(
          find.descendant(of: dialog, matching: find.text(name)),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(of: dialog, matching: find.text('Work')),
        findsNothing,
      );
    });

    testWidgets('with one calendar there is nothing to show', (tester) async {
      _desktopWindow(tester);
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final now = utcNow();
      await DriftCalendarRepository(db).upsertCalendar(
        Calendar(
          id: legacyCalendarId,
          name: 'Home',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await _pumpManageSheet(tester, _container(db));

      await _openAlsoShow(tester, 'Home');

      expect(
        find.text('There are no other calendars to show.'),
        findsOneWidget,
      );
    });

    // Saving reloads the list behind the dialog; the rows it already has stay
    // up for that, rather than the dialog collapsing to a spinner.
    testWidgets('saving keeps the list on screen', (tester) async {
      _desktopWindow(tester);
      final (db, _) = await _seed();
      await _pumpManageSheet(
        tester,
        _container(db, calendarRepository: _SlowCalendarRepository(db)),
      );

      await _openAlsoShow(tester, 'Home');
      await tester.tap(find.text('Holidays').last);
      await tester.pump();
      await tester.tap(find.text('Save'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.widgetWithText(ListTile, 'Work'), findsOneWidget);
      }
      await tester.pumpAndSettle();
      expect(find.text('Also shows Holidays'), findsOneWidget);
    });
  });

  group('page', () {
    testWidgets('draws the overlay\'s events on the host grid', (tester) async {
      _desktopWindow(tester);
      final (db, _) = await _seed(homeOverlays: ['h']);
      await _pumpPage(tester, db, _container(db));

      expect(_eventBar('hol'), findsOneWidget);
    });

    testWidgets('does not draw them on a calendar that does not overlay it', (
      tester,
    ) async {
      _desktopWindow(tester);
      final (db, _) = await _seed(homeOverlays: ['h']);
      await _pumpPage(tester, db, _container(db), calendarId: 'w');

      expect(_eventBar('hol'), findsNothing);
    });

    // Writing the open calendar's overlay list changes what it draws. It
    // swaps the events in place; the grid does not blank to a spinner.
    testWidgets('an overlay edit does not blank the grid', (tester) async {
      _desktopWindow(tester);
      final (db, repo) = await _seed();
      final container = _container(db);
      await container.read(calendarsProvider.future);
      await _pumpPage(tester, db, container);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await repo.upsertCalendar(
        (await repo.getCalendar(
          legacyCalendarId,
        ))!.copyWith(overlayCalendarIds: ['h']),
      );
      container.invalidate(calendarsProvider);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.byType(CircularProgressIndicator), findsNothing);
      }
      expect(_eventBar('hol'), findsOneWidget);
    });

    // Every rebuild of the page rebuilds every cell in the grid, so an
    // overlay edit gets one: when the new events land. Not one more when the
    // reload starts, nor when the calendar list lands with nothing the page
    // draws changed.
    testWidgets('an overlay edit rebuilds the page once', (tester) async {
      _desktopWindow(tester);
      final (db, repo) = await _seed();
      // Slow enough that the reload starting, the calendar list landing and
      // the events landing are separate frames, as they are in the app.
      final container = _container(
        db,
        calendarRepository: _SlowCalendarRepository(db),
      );
      await _pumpPage(tester, db, container);

      await repo.upsertCalendar(
        (await repo.getCalendar(
          legacyCalendarId,
        ))!.copyWith(overlayCalendarIds: ['h']),
      );
      container.invalidate(calendarsProvider);
      var pageBuilds = 0;
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is CalendarPage) pageBuilds++;
      };
      try {
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      } finally {
        debugOnRebuildDirtyWidget = null;
      }

      expect(pageBuilds, 1);
      final events = container
          .read(calendarViewEventsProvider(legacyCalendarId))
          .requireValue;
      expect(events.map((e) => e.id), contains('hol'));
    });

    testWidgets('a new event from the host view is filed on the host', (
      tester,
    ) async {
      _desktopWindow(tester);
      final (db, repo) = await _seed();
      await repo.upsertCalendar(
        (await repo.getCalendar('w'))!.copyWith(overlayCalendarIds: ['h']),
      );
      await _pumpPage(tester, db, _container(db), calendarId: 'w');

      await tester.tap(find.text('Add event'));
      await tester.pumpAndSettle();
      await tester.enterText(_panelField(0), 'Standup');
      await tester.tap(find.text('Save').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final created = (await repo.listEvents()).firstWhere(
        (e) => e.title == 'Standup',
      );
      expect(created.calendarId, 'w');
    });

    testWidgets('editing an overlay event writes its own row', (tester) async {
      _desktopWindow(tester);
      final (db, repo) = await _seed(homeOverlays: ['h']);
      await _pumpPage(tester, db, _container(db));

      await tester.tap(_eventBar('hol'), warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.enterText(_panelField(0), 'Bank holiday');
      await tester.tap(find.text('Save').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final events = await repo.listEvents();
      expect(events, hasLength(1), reason: 'edited in place, not cloned');
      expect(events.single.id, 'hol');
      expect(events.single.title, 'Bank holiday');
      expect(events.single.calendarId, 'h');
      // And the page is still on the host.
      expect(find.text('All calendars'), findsNothing);
    });
  });

  group('reveal', () {
    Future<void> reveal(
      WidgetTester tester,
      ProviderContainer container,
      DriftCalendarRepository repo,
    ) async {
      container.read(revealRequestProvider.notifier).state =
          RevealRequest.event((await repo.getEvent('hol'))!);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('stays on a host that overlays the event\'s calendar', (
      tester,
    ) async {
      _desktopWindow(tester);
      final (db, repo) = await _seed(homeOverlays: ['h']);
      final container = _container(db);
      await _pumpPage(tester, db, container);

      await reveal(tester, container, repo);

      expect(find.text('All calendars'), findsNothing);
      expect(find.byType(CalendarEventPanel), findsOneWidget);
    });

    testWidgets('otherwise still switches to the all-view', (tester) async {
      _desktopWindow(tester);
      final (db, repo) = await _seed();
      final container = _container(db);
      await _pumpPage(tester, db, container);

      await reveal(tester, container, repo);

      expect(find.text('All calendars'), findsOneWidget);
      expect(find.byType(CalendarEventPanel), findsOneWidget);
    });

    testWidgets('opens beside the revealed event, not the last one clicked', (
      tester,
    ) async {
      _desktopWindow(tester);
      final (db, repo) = await _seed(homeOverlays: ['h']);
      final today = DateTime.now();
      final now = utcNow();
      await repo.upsertEvent(
        CalendarEvent(
          id: 'gym',
          calendarId: 'h',
          title: 'Gym',
          start: DateTime(today.year, today.month, 25),
          end: DateTime(today.year, today.month, 25, 23, 59),
          colorValue: 0xFF00AA00,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final container = _container(db);
      await _pumpPage(tester, db, container);

      await tester.tap(_eventBar('hol'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(CalendarEventPanel), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(CalendarEventPanel), findsNothing);

      container.read(revealRequestProvider.notifier).state =
          RevealRequest.event((await repo.getEvent('gym'))!);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // The popover lines its edge up with the bar it is anchored to.
      final panel = tester.getRect(find.byType(CalendarEventPanel));
      final gym = tester.getRect(_eventBar('gym'));
      expect(panel.left, moreOrLessEquals(gym.left, epsilon: 8));
    });
  });
}
