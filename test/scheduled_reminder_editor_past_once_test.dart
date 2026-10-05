// A one-time reminder armed after its only time can never fire. The editor
// used to save it switched on, and the Inbox listed it as an armed "Passed"
// reminder (BUG-039); now Save is refused until the time is in the future.
// A rename leaves the schedule as it was armed, so a reminder already due
// still saves.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/reminders/reminder_os_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';

Future<AppDatabase> _openEditor(
  WidgetTester tester,
  ScheduledReminderRule rule,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  await DriftReminderRepository(db).upsertRule(rule);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        reminderOsNotifierProvider.overrideWithValue(NoopReminderOsNotifier()),
        deviceRegistrationsProvider.overrideWith(
          (ref) async => const <DeviceRegistration>[],
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () =>
                    showScheduledReminderEditor(context, existing: rule),
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
  return db;
}

ScheduledReminderRule _yesterdayAtNine({required bool enabled}) {
  final now = DateTime.now();
  final armed = now.subtract(const Duration(days: 2)).toUtc();
  return ScheduledReminderRule(
    id: 'past',
    createdAt: armed,
    updatedAt: armed,
    title: 'past rule',
    enabled: enabled,
    scheduleKind: ReminderScheduleKind.once,
    localTimeMinutes: 9 * 60,
    onceLocalDate: DateTime(now.year, now.month, now.day - 1),
    armedAt: armed,
  );
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('switching a passed one-time reminder back on is refused', (
    tester,
  ) async {
    final db = await _openEditor(tester, _yesterdayAtNine(enabled: false));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('That time has already passed'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text("Pick a time that hasn't passed yet"), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    final saved = await DriftReminderRepository(db).getRule('past');
    expect(saved!.enabled, isFalse);
  });

  testWidgets('renaming a due one-time reminder still saves', (tester) async {
    final rule = _yesterdayAtNine(enabled: true);
    final db = await _openEditor(tester, rule);
    await tester.enterText(find.byType(EditableText).first, 'renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    final saved = await DriftReminderRepository(db).getRule('past');
    expect(saved!.title, 'renamed');
    expect(saved.enabled, isTrue);
    expect(saved.armedAt, rule.armedAt);
  });
}
