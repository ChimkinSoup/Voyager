// While nobody is signed in, the reminder engine takes back the alarms it
// already handed the OS, which fire with the app killed (BUG-355).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/reminders/reminder_os_notifier.dart';
import 'package:voyager/data/database/app_database.dart';

class _Os extends NoopReminderOsNotifier {
  final scheduled = <List<PlannedReminderAlert>>[];

  @override
  Future<void> schedule(List<PlannedReminderAlert> alerts) async =>
      scheduled.add(alerts);
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test('signed out, every scheduled alert is cancelled', () {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final os = _Os();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        reminderOsNotifierProvider.overrideWithValue(os),
        deviceIdProvider.overrideWith((ref) => 'desk'),
        signedInProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    container.read(reminderEngineProvider);
    expect(os.scheduled, [isEmpty]);
  });
}
