// The calendar floater keeps what was typed when it closes unsaved — on a blur
// or through its "Open in app" icon — and the next panel, the floater's or the
// calendar page's, starts from it.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/calendar_constants.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/features/calendar/calendar_event_panel.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  Future<void> pumpPanel(
    WidgetTester tester, {
    CalendarEventDraft? draft,
    ValueChanged<CalendarEventDraft?>? onDraft,
    String initialCalendarId = legacyCalendarId,
  }) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CalendarEventPanel(
                initialDate: DateTime(2026, 10, 16),
                calendars: const [],
                initialCalendarId: initialCalendarId,
                onSave: (_) {},
                onCancel: () {},
                draft: draft,
                onDraft: onDraft,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('an unsaved panel hands back its draft, and starts from one', (
    tester,
  ) async {
    CalendarEventDraft? handed;
    await pumpPanel(tester, onDraft: (draft) => handed = draft);
    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'Dentist');
    await tester.enterText(fields.at(1), 'Bring forms');
    await tester.pumpWidget(const SizedBox());

    expect(handed?.title, 'Dentist');
    expect(handed?.notes, 'Bring forms');
    expect(handed?.start, DateTime(2026, 10, 16));

    await pumpPanel(tester, draft: handed);
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.text('Bring forms'), findsOneWidget);
  });

  CalendarEventDraft draftOf({
    required DateTime createdOn,
    String calendarId = 'work',
    String calendarIdBasis = legacyCalendarId,
  }) => CalendarEventDraft(
    title: 'Dentist',
    notes: '',
    isFullDay: true,
    start: DateTime(2026, 9, 1),
    end: DateTime(2026, 9, 1, 1),
    colorValue: 0xFF000000,
    recurrence: const RecurrenceRule(frequency: EventRecurrence.weekly),
    calendarId: calendarId,
    calendarIdBasis: calendarIdBasis,
    reminderOffset: null,
    createdOn: createdOn,
  );

  final today = DateUtils.dateOnly(DateTime.now());

  testWidgets("a draft keeps its dates and repeat only the day it's written", (
    tester,
  ) async {
    CalendarEventDraft? handed;
    await pumpPanel(
      tester,
      draft: draftOf(createdOn: today),
      onDraft: (draft) => handed = draft,
    );
    await tester.pumpWidget(const SizedBox());
    expect(handed?.start, DateTime(2026, 9, 1));
    expect(handed?.recurrence.frequency, EventRecurrence.weekly);

    await pumpPanel(
      tester,
      draft: draftOf(createdOn: today.subtract(const Duration(days: 1))),
      onDraft: (draft) => handed = draft,
    );
    await tester.pumpWidget(const SizedBox());
    expect(handed?.title, 'Dentist');
    expect(handed?.start, DateTime(2026, 10, 16));
    expect(handed?.recurrence, RecurrenceRule.none);
  });

  testWidgets('a new day passed in keeps what was typed', (tester) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    Widget panel(DateTime day) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CalendarEventPanel(
              initialDate: day,
              calendars: const [],
              initialCalendarId: legacyCalendarId,
              onSave: (_) {},
              onCancel: () {},
            ),
          ),
        ),
      ),
    );
    // The calendar floater passes today, so past midnight it passes a new
    // day to the panel already open.
    await tester.pumpWidget(panel(DateTime(2026, 10, 16)));
    await tester.enterText(find.byType(EditableText).at(0), 'Dentist');
    await tester.pumpWidget(panel(DateTime(2026, 10, 17)));
    expect(find.text('Dentist'), findsOneWidget);
  });

  testWidgets('the draft can be read before the panel closes', (tester) async {
    await pumpPanel(tester);
    await tester.enterText(find.byType(EditableText).at(0), 'Dentist');
    final panel = tester.state<CalendarEventPanelState>(
      find.byType(CalendarEventPanel),
    );
    expect(panel.unsavedDraft()?.title, 'Dentist');
  });

  testWidgets("a draft's calendar stands only while its basis does", (
    tester,
  ) async {
    CalendarEventDraft? handed;
    await pumpPanel(
      tester,
      draft: draftOf(createdOn: today),
      onDraft: (draft) => handed = draft,
    );
    await tester.pumpWidget(const SizedBox());
    expect(handed?.calendarId, 'work');

    await pumpPanel(
      tester,
      draft: draftOf(createdOn: today),
      onDraft: (draft) => handed = draft,
      initialCalendarId: 'home',
    );
    await tester.pumpWidget(const SizedBox());
    expect(handed?.calendarId, 'home');
  });

  testWidgets('a cancelled panel hands back no draft', (tester) async {
    final handed = <CalendarEventDraft?>[];
    await pumpPanel(tester, onDraft: handed.add);
    await tester.enterText(find.byType(EditableText).at(0), 'Dentist');
    await tester.tap(find.text('Cancel'));
    await tester.pumpWidget(const SizedBox());
    expect(handed.last, isNull);
  });

  testWidgets('an empty panel hands back no draft', (tester) async {
    final handed = <CalendarEventDraft?>[];
    await pumpPanel(tester, onDraft: handed.add);
    await tester.pumpWidget(const SizedBox());
    expect(handed, [null]);
  });
}
