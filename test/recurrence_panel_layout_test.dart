// Layout guards for the two repeat controls.
//
// The worry these answer is horizontal overflow: the calendar panel's row 2
// carries a date range, a time range and now a repeat button, and a multi-day
// timed event makes that row as wide as it ever gets.

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/features/calendar/calendar_event_panel.dart';

import 'fakes/fake_weather_api_client.dart';

/// Mirrors `_CalendarPageState._eventPopupWidth`.
const double kEventPopupWidth = 344.0;

Future<ProviderContainer> _container(WidgetTester tester) async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  // Warm the settings row: the panel reads settingsProvider synchronously for
  // its fallback accent, and an unwritten row leaves that read null.
  final settingsRepo = DriftSettingsRepository(db);
  await settingsRepo.saveSettings(await settingsRepo.getSettings());
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  return container;
}

CalendarEvent worstCaseEvent({
  String id = 'e1',
  RecurrenceRule recurrence = const RecurrenceRule(
    frequency: EventRecurrence.monthly,
  ),
}) {
  final now = DateTime.utc(2026, 1, 1);
  return CalendarEvent(
    id: id,
    createdAt: now,
    updatedAt: now,
    calendarId: 'c1',
    title: 'Offsite',
    // Multi-day *and* timed: the date pill shows a range and the time pill is
    // present, which is the widest row 2 can be.
    start: DateTime(2026, 11, 28, 10, 30),
    end: DateTime(2026, 12, 2, 17, 45),
    isFullDay: false,
    recurrence: recurrence,
  );
}

Future<void> _pumpPanel(
  WidgetTester tester,
  ProviderContainer container, {
  required CalendarEvent? event,
  double width = kEventPopupWidth,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: RepaintBoundary(
                child: CalendarEventPanel(
                  event: event,
                  initialDate: DateTime(2026, 11, 28, 10, 30),
                  calendars: const [],
                  initialCalendarId: 'c1',
                  onSave: (_) {},
                  onCancel: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the calendar panel lays out a multi-day timed event without '
      'overflowing', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = await _container(tester);
    await _pumpPanel(tester, container, event: worstCaseEvent());

    // A RenderFlex overflow reports itself through the error hook rather than
    // by throwing, so an assertion on tester.takeException() alone would pass
    // through it.
    expect(tester.takeException(), isNull);

    final repeat = find.byIcon(PhosphorIconsRegular.repeat);
    expect(repeat, findsOneWidget);

    // The pinned repeat button has to be fully inside the panel, not pushed
    // past its right edge by the pills.
    final panelRect = tester.getRect(find.byType(CalendarEventPanel));
    final repeatRect = tester.getRect(repeat);
    expect(repeatRect.right, lessThanOrEqualTo(panelRect.right));
    expect(repeatRect.left, greaterThanOrEqualTo(panelRect.left));

    // And it must not be hidden under the date/time pills.
    final dateRange = find.textContaining('Nov 28');
    expect(dateRange, findsOneWidget);
    expect(
      tester.getRect(dateRange).right,
      lessThanOrEqualTo(repeatRect.left + 1),
    );
  });

  testWidgets('the repeat button reads as on for a repeating event and off for '
      'a one-off', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = await _container(tester);

    Color iconColour() => tester
        .widget<Icon>(find.byIcon(PhosphorIconsRegular.repeat))
        .color!;

    await _pumpPanel(tester, container, event: worstCaseEvent());
    final on = iconColour();

    // A different id, not just a different rule: the panel deliberately keeps
    // its in-progress edits for the same event, so reusing 'e1' would re-render
    // the first event's state and compare a colour against itself.
    await _pumpPanel(
      tester,
      container,
      event: worstCaseEvent(id: 'e2', recurrence: RecurrenceRule.none),
    );
    final off = iconColour();

    expect(on, isNot(off));
    // Subtle by default: the off state is the faint one.
    expect(off.a, lessThan(on.a));
  });

}
