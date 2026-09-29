import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/notifications/notification_history.dart';
import 'package:voyager/core/platform/app_data_directory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('notification_history');
    final documents = p.join(root.path, 'Documents');
    final support = p.join(root.path, 'Voyager', 'voyager');
    await Directory(documents).create(recursive: true);
    await Directory(support).create(recursive: true);
    file = File(p.join(support, 'notification_history.json'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => switch (call.method) {
            'getApplicationDocumentsDirectory' => documents,
            'getApplicationSupportDirectory' => support,
            _ => null,
          },
        );
  });

  tearDown(() async {
    resetAppDataDirectory();
    await root.delete(recursive: true);
  });

  test(
    'a toast revising itself every tick is saved once, not per tick',
    () async {
      final history = NotificationHistory.forTesting();
      await history.load();
      var entry = history.record('Restoring 0 items')!;
      await history.saved;
      final written = await file.lastModified();

      for (var i = 1; i <= 500; i++) {
        entry = history.revise(entry, 'Restoring $i items');
      }
      // Held back: nothing new is queued while the ticks keep coming.
      expect(await file.readAsString(), contains('Restoring 0 items'));
      expect(await file.lastModified(), written);

      await history.saved;
      expect(await file.readAsString(), contains('Restoring 500 items'));
    },
  );

  test('saves by replacing the file, and a reload reads it back', () async {
    final history = NotificationHistory.forTesting();
    await history.load();
    history.record('Workout saved');
    history.record('Snippet saved');
    await history.saved;

    expect(File('${file.path}.tmp').existsSync(), isFalse);
    final reloaded = NotificationHistory.forTesting();
    await reloaded.load();
    expect(
      [for (final r in reloaded.records) r.message],
      ['Snippet saved', 'Workout saved'],
    );
  });

  test('startup leaves an unchanged file alone', () async {
    final history = NotificationHistory.forTesting();
    await history.load();
    history.record('Workout saved');
    await history.saved;
    final written = await file.lastModified();
    final contents = await file.readAsString();

    final reloaded = NotificationHistory.forTesting();
    await reloaded.load();
    await reloaded.saved;
    expect(await file.lastModified(), written);
    expect(await file.readAsString(), contents);
  });

  test('startup saves when records have aged out', () async {
    final old = NotificationRecord(
      at: DateTime.now().subtract(const Duration(days: 31)),
      message: 'Old news',
      source: NotificationSource.app,
    );
    final recent = NotificationRecord(
      at: DateTime.now().subtract(const Duration(days: 1)),
      message: 'Workout saved',
      source: NotificationSource.app,
    );
    await file.writeAsString(jsonEncode([recent.toJson(), old.toJson()]));

    final history = NotificationHistory.forTesting();
    await history.load();
    await history.saved;
    expect([for (final r in history.records) r.message], ['Workout saved']);
    expect(await file.readAsString(), isNot(contains('Old news')));
  });
}
