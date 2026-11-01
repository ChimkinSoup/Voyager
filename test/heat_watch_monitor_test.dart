import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/notifications/notification_history.dart';
import 'package:voyager/features/settings/services/heat_watch_log.dart';
import 'package:voyager/features/settings/services/heat_watch_monitor.dart';

final _now = DateTime(2026, 11, 1, 15, 10);
final _healthy = HeatWatchStatus(lastReading: _now, spikes: const []);
final _down = HeatWatchStatus(
  lastReading: DateTime(2026, 11, 1, 15, 2),
  spikes: const [],
);

void main() {
  late HeatWatchStatus? status;
  late bool shown;
  late List<(String, String, String)> alerts;
  late HeatWatchMonitor monitor;

  Future<void> checks(int count) async {
    for (var i = 0; i < count; i++) {
      await monitor.check(_now);
    }
  }

  setUp(() {
    status = _down;
    shown = true;
    alerts = [];
    NotificationHistory.instance.clear();
    monitor = HeatWatchMonitor(
      read: () async => status,
      notify: (key, title, body) async {
        alerts.add((key, title, body));
        return shown;
      },
    );
  });

  test('alerts only once the logger has stayed down for five checks', () async {
    await checks(4);
    expect(alerts, isEmpty);
    await checks(1);
    expect(alerts, hasLength(1));
    final (key, title, body) = alerts.single;
    expect(key, startsWith(HeatWatchMonitor.notificationKeyPrefix));
    expect(title, 'Heat logger is not recording');
    expect(body, contains('1 Nov, 3:02 PM'));
  });

  test('alerts once per outage, and again for the next one', () async {
    await checks(20);
    expect(alerts, hasLength(1));

    status = _healthy;
    await checks(1);
    status = _down;
    await checks(5);
    expect(alerts, hasLength(2));
  });

  test('a recovery inside the grace period raises nothing', () async {
    await checks(4);
    status = _healthy;
    await checks(1);
    status = _down;
    await checks(4);
    expect(alerts, isEmpty);
  });

  test('a PC without the logger never alerts', () async {
    status = null;
    await checks(10);
    expect(alerts, isEmpty);
  });

  test('a logger that never recorded alerts without a last reading', () async {
    status = const HeatWatchStatus(lastReading: null, spikes: []);
    await checks(5);
    expect(alerts.single.$3, 'No readings yet. Is Core Temp running?');
  });

  test('a busy file neither counts nor throws', () async {
    final busy = HeatWatchMonitor(
      read: () async => throw const FileSystemException('busy'),
      notify: (key, title, body) async => fail('should not alert'),
    );
    for (var i = 0; i < 6; i++) {
      await busy.check(_now);
    }
  });

  test('the history records an alert that was shown', () async {
    await checks(5);
    final record = NotificationHistory.instance.records.single;
    expect(record.message, 'Heat logger is not recording');
    expect(record.origin, 'Heat logger');
    expect(record.detail, alerts.single.$3);
  });

  test('the history skips an alert the OS did not show', () async {
    shown = false;
    await checks(5);
    expect(alerts, hasLength(1));
    expect(NotificationHistory.instance.records, isEmpty);
  });

  group('readHeatWatchHealth', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('heat_health'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('reads the newest temps file and skips the spikes', () async {
      final temps = File(p.join(dir.path, 'temps-2026-11-01.csv'))
        ..writeAsStringSync('time,maxC\n');
      File(p.join(dir.path, 'events-${_today()}.log')).writeAsStringSync(
        '=== ${_today()} 12:00:00 HOT maxC=90 avgC=80 W=50 MHz=4000 | x\n',
      );

      final health = await readHeatWatchHealth(dir.path);

      expect(health!.lastReading, temps.lastModifiedSync());
      expect(health.spikes, isEmpty);
    });

    test('is null without the logger', () async {
      expect(await readHeatWatchHealth(p.join(dir.path, 'missing')), isNull);
    });
  });
}

String _today() => DateTime.now().toIso8601String().substring(0, 10);
