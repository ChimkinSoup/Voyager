import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _logFileName = 'perf_stall.log';

/// Its presence is the on/off switch. A file rather than a settings column so
/// the logger can start before the database opens and catch startup stalls,
/// and because a dev switch has no business syncing to other devices.
const _enabledFileName = 'perf_stall.enabled';
const _maxLogBytes = 1024 * 1024;

/// Writes down every moment the app stopped responding, and what was going on
/// around it, so a stutter can be traced after the fact instead of remembered.
///
/// Two signals, because a freeze can hide from either one:
/// - a 50ms heartbeat [Timer]: when it fires late, the Dart thread was busy
///   and could not handle input. That is the stall that swallows keystrokes
///   and replays them all at once.
/// - [FrameTiming] reports: a frame that took long, split into how long it
///   waited for the Dart thread, built, and rasterized. A raster stall freezes
///   the picture without blocking the heartbeat.
///
/// Stalls within [_incidentWindow] of the first become one record, written
/// with the page, the focused widget, recent input counts and the
/// [breadcrumb]s leading up to it. Nothing is written while the app runs
/// smoothly, and nothing is hooked at all while the switch is off.
class PerfStallLogger extends ChangeNotifier {
  PerfStallLogger._();

  static final instance = PerfStallLogger._();

  static const stallThreshold = Duration(milliseconds: 100);
  static const _heartbeat = Duration(milliseconds: 50);
  static const _incidentWindow = Duration(seconds: 1);
  static const _inputWindow = Duration(seconds: 10);
  static const _breadcrumbWindow = Duration(seconds: 15);
  static const _maxBreadcrumbs = 60;
  static const _maxInputStamps = 500;

  /// A heartbeat later than this is a machine that slept, not an app that
  /// froze.
  static const _sleepGap = Duration(seconds: 30);

  bool _enabled = false;
  bool get enabled => _enabled;

  /// Reads the router's current location. Set by the app once the router
  /// exists; stalls before that report no page.
  String Function()? currentLocation;

  final _breadcrumbs = ListQueue<(DateTime, String)>();
  final _keyPresses = ListQueue<DateTime>();
  final _clicks = ListQueue<DateTime>();
  final _scrolls = ListQueue<DateTime>();

  Timer? _heartbeatTimer;
  final _sinceBeat = Stopwatch();

  _Incident? _incident;
  Timer? _incidentTimer;

  Future<void> _writeChain = Future<void>.value();

  /// Turns logging back on if it was left on. Called once from `main`.
  Future<void> restore() async {
    final marker = File(await _pathFor(_enabledFileName));
    if (!await marker.exists()) return;
    _start();
    _enqueue(
      (file) => file.writeAsString(
        '\n=== APP START ${_stamp(DateTime.now())} '
        '(${_buildMode()} build) ===\n',
        mode: FileMode.append,
        flush: true,
      ),
    );
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    final marker = File(await _pathFor(_enabledFileName));
    if (value) {
      await marker.create();
      _start();
    } else {
      if (await marker.exists()) await marker.delete();
      _stop();
    }
    _enqueue(
      (file) => file.writeAsString(
        '\n=== LOGGING ${value ? 'STARTED' : 'STOPPED'} '
        '${_stamp(DateTime.now())} (${_buildMode()} build) ===\n',
        mode: FileMode.append,
        flush: true,
      ),
    );
  }

  /// Notes something the app did, for the record of any stall that follows
  /// within [_breadcrumbWindow]. Free while logging is off.
  void breadcrumb(String message) {
    if (!_enabled) return;
    _breadcrumbs.addLast((DateTime.now(), message));
    while (_breadcrumbs.length > _maxBreadcrumbs) {
      _breadcrumbs.removeFirst();
    }
  }

  Future<String> logFilePath() => _pathFor(_logFileName);

  Future<String> readLog() async {
    await _writeChain;
    final file = File(await logFilePath());
    if (!await file.exists()) return '';
    return file.readAsString();
  }

  Future<void> clearLog() async {
    final file = File(await logFilePath());
    if (await file.exists()) await file.writeAsString('');
  }

  void _start() {
    if (_enabled) return;
    _enabled = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    HardwareKeyboard.instance.addHandler(_onKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _sinceBeat
      ..reset()
      ..start();
    _heartbeatTimer = Timer.periodic(_heartbeat, (_) => _onBeat());
    notifyListeners();
  }

  void _stop() {
    if (!_enabled) return;
    _enabled = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    HardwareKeyboard.instance.removeHandler(_onKey);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _sinceBeat.stop();
    _incidentTimer?.cancel();
    _incidentTimer = null;
    _incident = null;
    _breadcrumbs.clear();
    _keyPresses.clear();
    _clicks.clear();
    _scrolls.clear();
    notifyListeners();
  }

  void _onBeat() {
    final gap = _sinceBeat.elapsed;
    _sinceBeat
      ..reset()
      ..start();
    final blocked = gap - _heartbeat;
    if (blocked < stallThreshold || gap > _sleepGap) return;
    _report(
      startedAt: DateTime.now().subtract(gap),
      line:
          'Dart thread blocked ${blocked.inMilliseconds}ms '
          '(input and timers waited)',
    );
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final total = timing.totalSpan;
      if (total < stallThreshold) continue;
      _report(
        // Timings arrive in batches after the fact; the report time is the
        // closest wall-clock anchor available.
        startedAt: DateTime.now().subtract(total),
        line:
            'slow frame ${total.inMilliseconds}ms '
            '(waited ${timing.vsyncOverhead.inMilliseconds}ms for the Dart '
            'thread, build ${timing.buildDuration.inMilliseconds}ms, '
            'raster ${timing.rasterDuration.inMilliseconds}ms)',
      );
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) _stampInput(_keyPresses);
    return false;
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _stampInput(_clicks);
    if (event is PointerScrollEvent) _stampInput(_scrolls);
  }

  void _stampInput(ListQueue<DateTime> stamps) {
    stamps.addLast(DateTime.now());
    while (stamps.length > _maxInputStamps) {
      stamps.removeFirst();
    }
  }

  void _report({required DateTime startedAt, required String line}) {
    final incident = _incident ??= _Incident(
      startedAt: startedAt,
      context: _describeContext(startedAt),
    );
    incident.lines.add(line);
    _incidentTimer ??= Timer(_incidentWindow, _writeIncident);
  }

  void _writeIncident() {
    final incident = _incident;
    _incident = null;
    _incidentTimer = null;
    if (incident == null) return;

    final text = StringBuffer()
      ..writeln('=' * 80)
      ..writeln('${_stamp(incident.startedAt)}  STALL  (${_buildMode()} build)')
      ..write(incident.context);
    for (final line in incident.lines) {
      text.writeln('  $line');
    }
    final record = text.toString();
    _enqueue((file) async {
      await _trimIfNeeded(file);
      await file.writeAsString(record, mode: FileMode.append, flush: true);
    });
  }

  /// Captured when the first stall of an incident is seen, so the breadcrumbs
  /// are the ones that led up to it rather than whatever came after.
  String _describeContext(DateTime startedAt) {
    final buffer = StringBuffer();
    String? page;
    try {
      page = currentLocation?.call();
    } catch (_) {
      page = null;
    }
    buffer.writeln(
      '  page: ${page ?? '(unknown)'}   focus: ${_describeFocus()}',
    );

    int within(ListQueue<DateTime> stamps) {
      final since = startedAt.subtract(_inputWindow);
      return stamps.where((t) => t.isAfter(since)).length;
    }

    buffer.writeln(
      '  input in the ${_inputWindow.inSeconds}s before: '
      '${within(_keyPresses)} key presses, ${within(_clicks)} clicks, '
      '${within(_scrolls)} scroll ticks',
    );

    final since = startedAt.subtract(_breadcrumbWindow);
    final recent = _breadcrumbs.where((b) => b.$1.isAfter(since)).toList();
    if (recent.isEmpty) {
      buffer.writeln('  recent events: none');
    } else {
      buffer.writeln('  recent events:');
      for (final (at, message) in recent) {
        buffer.writeln('    ${_stamp(at, dateless: true)}  $message');
      }
    }
    return buffer.toString();
  }

  String _describeFocus() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return 'none';
    final label = focus.debugLabel;
    if (label != null && label.isNotEmpty) return label;
    return focus.context?.widget.runtimeType.toString() ?? 'unknown';
  }

  Future<void> _trimIfNeeded(File file) async {
    if (!await file.exists()) return;
    if (await file.length() <= _maxLogBytes) return;
    final content = await file.readAsString();
    final tail = content.substring(content.length - _maxLogBytes ~/ 2);
    final nextRecord = tail.indexOf('=' * 80);
    await file.writeAsString(
      '... log truncated ...\n'
      '${nextRecord >= 0 ? tail.substring(nextRecord) : tail}',
      flush: true,
    );
  }

  void _enqueue(Future<void> Function(File file) write) {
    _writeChain = _writeChain
        .then((_) async => write(File(await logFilePath())))
        .catchError((Object _) {});
  }

  /// Where the log and the switch live. Replaced in tests: on a Windows host
  /// `path_provider` resolves the real Documents folder even under
  /// `flutter test`.
  @visibleForTesting
  static Future<String> Function() directory = () async =>
      (await getApplicationDocumentsDirectory()).path;

  static Future<String> _pathFor(String name) async =>
      p.join(await directory(), name);

  static String _buildMode() =>
      kDebugMode ? 'debug' : (kProfileMode ? 'profile' : 'release');

  static String _stamp(DateTime at, {bool dateless = false}) {
    String two(int v) => v.toString().padLeft(2, '0');
    final time =
        '${two(at.hour)}:${two(at.minute)}:${two(at.second)}'
        '.${at.millisecond.toString().padLeft(3, '0')}';
    if (dateless) return time;
    return '${at.year}-${two(at.month)}-${two(at.day)} $time';
  }
}

class _Incident {
  _Incident({required this.startedAt, required this.context});

  final DateTime startedAt;
  final String context;
  final lines = <String>[];
}
