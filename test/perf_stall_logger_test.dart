import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/dev/perf_stall_logger.dart';

void main() {
  testWidgets('a blocked Dart thread is written down with its context', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('perf_stall_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    PerfStallLogger.directory = () async => dir.path;

    // Real time throughout: the heartbeat is a real Timer measured by a real
    // Stopwatch, which the test zone's fake clock would never advance. The
    // singleton is first touched in here too — its write queue is a future,
    // and a future created in the fake zone only ever completes on fake time.
    await tester.runAsync(() async {
      final logger = PerfStallLogger.instance;
      logger.currentLocation = () => '/journal';
      await logger.setEnabled(true);
      expect(File('${dir.path}/perf_stall.enabled').existsSync(), isTrue);

      logger.breadcrumb('local save: journal_entries');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsedMilliseconds < 400) {}

      // The incident is held open for a second to fold follow-up stalls in.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final log = await logger.readLog();

      expect(log, contains('STALL'));
      expect(log, contains('Dart thread blocked'));
      expect(log, contains('page: /journal'));
      expect(log, contains('1 key presses'));
      expect(log, contains('local save: journal_entries'));

      await logger.setEnabled(false);
      expect(File('${dir.path}/perf_stall.enabled').existsSync(), isFalse);
      // Let the queued "stopped" line land before the directory goes.
      await logger.readLog();
    });
  });
}
