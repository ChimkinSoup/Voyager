import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/features/settings/services/heat_watch_log.dart';

const _log = '''

=== 2026-11-01 14:00:00 BASE maxC=60 avgC=59 W=15 MHz=4511 | utility=5.7% (all-process sum=1.7%) dpc=0.1% irq=0.1%
   50.0%  ignored  pid=1  parent=1 | a | b
14:23:30 NEW SearchFilterHost pid=32380 parent=15604 |  |

=== 2026-11-01 14:23:47 HOT maxC=91.5 avgC=86 W=52.4 MHz=4197 | utility=94.1% (all-process sum=56.1%) dpc=0.1% irq=0.5%
    4.2%  powershell  pid=8892  parent=33696 | C:\\p.exe | p
    4.0%  powershell  pid=8893  parent=33696 | C:\\p.exe | p
    1.0%  memory compression  pid=9  parent=4 |  |
    0.6%  voyager  pid=10  parent=4 | C:\\v.exe | v
  GPU0  14.6%  3d  voyager  pid=10
14:23:48 NEW conhost pid=1 parent=2 | c | c

=== 2026-11-01 14:23:53 HOT maxC=92.5 avgC=87 W=44.8 MHz=4117 | utility=90.2% (all-process sum=58.1%) dpc=0.2% irq=0.2%
    4.2%  powershell  pid=8892  parent=33696 | C:\\p.exe | p

=== 2026-11-01 15:00:00 HOT maxC=86 avgC=70 W=30 MHz=4117 | utility=30% (all-process sum=20%) dpc=0.2% irq=0.2%
   20.0%  dart  pid=5  parent=6 | C:\\d.exe | d
''';

void main() {
  group('parseHeatSpikes', () {
    final spikes = parseHeatSpikes(_log.split('\n'));

    test('groups nearby HOT snapshots and splits on a gap', () {
      expect(spikes, hasLength(2));
      expect(spikes[0].start, DateTime(2026, 11, 1, 14, 23, 47));
      expect(spikes[0].end, DateTime(2026, 11, 1, 14, 23, 53));
      expect(spikes[1].start, DateTime(2026, 11, 1, 15));
    });

    test('keeps the peaks across snapshots', () {
      expect(spikes[0].peakCelsius, 92.5);
      expect(spikes[0].peakWatts, 52.4);
    });

    test('adds up same-named processes, averaged per snapshot', () {
      final top = spikes[0].topProcesses;
      expect(top.map((process) => process.name), [
        'powershell',
        'memory compression',
        'voyager',
      ]);
      expect(top[0].percent, closeTo((4.2 + 4.0 + 4.2) / 2, 0.001));
    });
  });

  group('readHeatWatchStatus', () {
    late Directory dir;
    final now = DateTime(2026, 11, 1, 16);

    setUp(() => dir = Directory.systemTemp.createTempSync('heat_watch_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('is null when the logger is not installed', () async {
      expect(await readHeatWatchStatus(p.join(dir.path, 'nope'), now), isNull);
    });

    test('health follows the newest temps file', () async {
      File(p.join(dir.path, 'temps-2026-10-31.csv'))
        ..writeAsStringSync('old')
        ..setLastModifiedSync(now.subtract(const Duration(days: 1)));
      final today = File(p.join(dir.path, 'temps-2026-11-01.csv'))
        ..writeAsStringSync('new')
        ..setLastModifiedSync(now.subtract(const Duration(seconds: 10)));

      final fresh = await readHeatWatchStatus(dir.path, now);
      expect(fresh!.isHealthy(now), isTrue);

      today.setLastModifiedSync(now.subtract(const Duration(minutes: 2)));
      final stale = await readHeatWatchStatus(dir.path, now);
      expect(stale!.isHealthy(now), isFalse);
    });

    test('never healthy before the first reading', () async {
      final status = await readHeatWatchStatus(dir.path, now);
      expect(status!.lastReading, isNull);
      expect(status.isHealthy(now), isFalse);
    });

    test('lists recent spikes newest first and drops old ones', () async {
      // The byte-order mark is how PowerShell starts these files.
      File(p.join(dir.path, 'events-2026-11-01.log'))
          .writeAsStringSync('\uFEFF$_log');
      File(p.join(dir.path, 'events-2026-10-02.log')).writeAsStringSync(
        '=== 2026-10-02 14:00:00 HOT maxC=99 avgC=90 W=60 MHz=1 | x\n',
      );

      final status = await readHeatWatchStatus(dir.path, now);
      expect(status!.spikes.map((spike) => spike.peakCelsius), [86, 92.5]);
    });
  });
}
