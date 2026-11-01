import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

const _recentDays = 7;

/// A temperature row is written every few seconds, slower under load.
const _healthyWithin = Duration(seconds: 30);

/// HOT snapshots further apart than this belong to separate spikes.
const _spikeGap = Duration(seconds: 30);

final _hotHeader = RegExp(
  r'^=== (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) HOT maxC=([\d.]+) .*?W=([\d.]+)',
);
final _processRow = RegExp(r'^\s+([\d.]+)%  (\S.*?)  pid=');

/// The HeatWatch logs folder, a personal script outside the app.
String heatWatchLogDir() =>
    p.join(Platform.environment['USERPROFILE'] ?? '', 'HeatWatch', 'logs');

class HeatProcess {
  const HeatProcess(this.name, this.percent);

  final String name;

  /// Share of the whole machine, averaged over the spike's snapshots.
  final double percent;
}

class HeatSpike {
  const HeatSpike({
    required this.start,
    required this.end,
    required this.peakCelsius,
    required this.peakWatts,
    required this.topProcesses,
  });

  final DateTime start;
  final DateTime end;
  final double peakCelsius;
  final double peakWatts;
  final List<HeatProcess> topProcesses;
}

class HeatWatchStatus {
  const HeatWatchStatus({required this.lastReading, required this.spikes});

  final DateTime? lastReading;

  /// Newest first.
  final List<HeatSpike> spikes;

  bool isHealthy(DateTime now) =>
      lastReading != null && now.difference(lastReading!) <= _healthyWithin;
}

class _Builder {
  _Builder(this.start) : end = start;

  final DateTime start;
  DateTime end;
  double peakCelsius = 0;
  double peakWatts = 0;
  int snapshots = 0;
  final totals = <String, double>{};

  HeatSpike build() {
    final ranked = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return HeatSpike(
      start: start,
      end: end,
      peakCelsius: peakCelsius,
      peakWatts: peakWatts,
      topProcesses: [
        for (final entry in ranked.take(3))
          HeatProcess(entry.key, entry.value / snapshots),
      ],
    );
  }
}

/// Groups the HOT snapshots of an events log into spikes, oldest first.
/// Same-named processes add up, since a spike's load is often many of one app.
List<HeatSpike> parseHeatSpikes(Iterable<String> lines) {
  final spikes = <HeatSpike>[];
  _Builder? current;
  var inHotSnapshot = false;
  for (final line in lines) {
    final header = _hotHeader.firstMatch(line);
    if (header != null) {
      final at = DateTime.parse(header[1]!);
      if (current != null && at.difference(current.end) > _spikeGap) {
        spikes.add(current.build());
        current = null;
      }
      current ??= _Builder(at);
      current.end = at;
      current.snapshots++;
      final celsius = double.parse(header[2]!);
      final watts = double.parse(header[3]!);
      if (celsius > current.peakCelsius) current.peakCelsius = celsius;
      if (watts > current.peakWatts) current.peakWatts = watts;
      inHotSnapshot = true;
      continue;
    }
    if (!inHotSnapshot) continue;
    final row = _processRow.firstMatch(line);
    if (row == null) {
      inHotSnapshot = false;
      continue;
    }
    current!.totals.update(
      row[2]!,
      (total) => total + double.parse(row[1]!),
      ifAbsent: () => double.parse(row[1]!),
    );
  }
  if (current != null) spikes.add(current.build());
  return spikes;
}

/// Null when the logger isn't installed on this PC. Runs off the UI isolate,
/// because a week of events logs can be several megabytes.
Future<HeatWatchStatus?> readHeatWatchStatus(String logDir, DateTime now) =>
    Isolate.run(() => _read(logDir, now));

/// [readHeatWatchStatus] without the spikes, for a check cheap enough to run
/// every minute.
Future<HeatWatchStatus?> readHeatWatchHealth(String logDir) =>
    Isolate.run(() => _read(logDir, DateTime.now(), withSpikes: false));

HeatWatchStatus? _read(String logDir, DateTime now, {bool withSpikes = true}) {
  final dir = Directory(logDir);
  if (!dir.existsSync()) return null;

  final names = [
    for (final entity in dir.listSync())
      if (entity is File) p.basename(entity.path),
  ]..sort();

  DateTime? lastReading;
  for (final name in names.reversed) {
    if (name.startsWith('temps-')) {
      lastReading = File(p.join(logDir, name)).lastModifiedSync();
      break;
    }
  }

  if (!withSpikes) {
    return HeatWatchStatus(lastReading: lastReading, spikes: const []);
  }

  final cutoff = now.subtract(const Duration(days: _recentDays));
  final firstFile = 'events-${cutoff.toIso8601String().substring(0, 10)}.log';
  final lines = <String>[];
  for (final name in names) {
    if (name.startsWith('events-') && name.compareTo(firstFile) >= 0) {
      final bytes = File(p.join(logDir, name)).readAsBytesSync();
      lines.addAll(
        const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true)),
      );
    }
  }

  return HeatWatchStatus(
    lastReading: lastReading,
    spikes: parseHeatSpikes(
      lines,
    ).where((spike) => spike.end.isAfter(cutoff)).toList().reversed.toList(),
  );
}
