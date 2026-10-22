// A new reminder closed without a save keeps what was typed, as a new
// transaction does: the hotkey floater and the Inbox's dialog share the one
// draft, and creating the reminder clears it.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('the floater and the dialog share a new reminder draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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

    final showFloater = ValueNotifier(true);
    addTearDown(showFloater.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: showFloater,
              builder: (context, show, _) => show
                  ? scheduledReminderForm(
                      draft: container.read(scheduledReminderDraftProvider),
                      onDraft: (draft) =>
                          storeScheduledReminderDraft(container, draft),
                      onClose: () => showFloater.value = false,
                    )
                  : TextButton(
                      onPressed: () => showScheduledReminderEditor(
                        context,
                        draft: container.read(scheduledReminderDraftProvider),
                        onDraft: (draft) =>
                            storeScheduledReminderDraft(container, draft),
                      ),
                      child: const Text('open'),
                    ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Typed in the floater, then dismissed.
    await tester.enterText(find.byType(TextField).first, 'Water plants');
    await tester.tap(find.text('Daily'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // The Inbox's dialog picks it up.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Water plants'), findsOneWidget);
    final kind = tester.widget<SegmentedButton<ReminderScheduleKind>>(
      find.byType(SegmentedButton<ReminderScheduleKind>),
    );
    expect(kind.selected, {ReminderScheduleKind.daily});

    // Creating it leaves nothing for the next one.
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(container.read(scheduledReminderDraftProvider), isNull);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Water plants'), findsNothing);
  });

  testWidgets('a form closed untouched keeps no draft', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        deviceRegistrationsProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showScheduledReminderEditor(
                  context,
                  draft: container.read(scheduledReminderDraftProvider),
                  onDraft: (draft) =>
                      storeScheduledReminderDraft(container, draft),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(container.read(scheduledReminderDraftProvider), isNull);
  });

  testWidgets(
    'a one-time draft whose time has passed reopens on a fresh time',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

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
      // Picked two days ago for the next morning, then left.
      final now = DateTime.now();
      container
          .read(scheduledReminderDraftProvider.notifier)
          .state = ScheduledReminderDraft(
        title: 'Call the bank',
        minutes: 9 * 60,
        onceDate: DateTime(now.year, now.month, now.day - 1),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showScheduledReminderEditor(
                    context,
                    draft: container.read(scheduledReminderDraftProvider),
                    onDraft: (draft) =>
                        storeScheduledReminderDraft(container, draft),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Call the bank'), findsOneWidget);

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text("Pick a time that hasn't passed yet"), findsNothing);
      expect(container.read(scheduledReminderDraftProvider), isNull);
    },
  );
}
