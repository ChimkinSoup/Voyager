// A reminder aimed only at devices removed in Settings fires nowhere. Its
// Inbox row read "Not on this device", like a rule for a healthy other device,
// and the editor saved it as it was, since the removed ids still counted as
// picked (BUG-255).

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

final _stamp = DateTime.utc(2026, 10, 1);

ScheduledReminderRule _rule({List<String> targets = const ['tablet']}) =>
    ScheduledReminderRule(
      id: 'r1',
      createdAt: _stamp,
      updatedAt: _stamp,
      title: 'Vitamins',
      scheduleKind: ReminderScheduleKind.daily,
      localTimeMinutes: 9 * 60,
      targetDeviceIds: targets,
      armedAt: _stamp,
    );

DeviceRegistration _device(String id) => DeviceRegistration(
  id: id,
  createdAt: _stamp,
  updatedAt: _stamp,
  displayName: id,
  platform: DevicePlatform.windows,
  lastSeenAt: _stamp,
);

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test('a rule whose devices were all removed says so', () {
    final status = scheduledRuleStatus(
      _rule(),
      null,
      DateTime(2026, 10, 15, 8),
      registeredDeviceIds: const {'desk'},
    );
    expect(status.label, 'Its devices were removed');
    expect(status.emphasized, isTrue);
  });

  test('a rule with one device still registered is unchanged', () {
    final status = scheduledRuleStatus(
      _rule(targets: const ['tablet', 'desk']),
      null,
      DateTime(2026, 10, 15, 8),
      registeredDeviceIds: const {'desk'},
    );
    expect(status.label, isNot('Its devices were removed'));
  });

  testWidgets('the editor refuses a rule left with only removed devices', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final rule = _rule();
    await DriftReminderRepository(db).upsertRule(rule);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          reminderOsNotifierProvider.overrideWithValue(
            NoopReminderOsNotifier(),
          ),
          deviceRegistrationsProvider.overrideWith(
            (ref) async => [_device('desk')],
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

    await tester.enterText(find.byType(EditableText).first, 'renamed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Pick at least one device'), findsOneWidget);
    final saved = await DriftReminderRepository(db).getRule('r1');
    expect(saved!.title, 'Vitamins');
  });
}
