import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Samples *rendered* FPS: the inverse of the frame budget actually consumed
/// (build + raster), not the display-capped delivery rate. A frame costing 4ms
/// reads as 250fps even on a 60Hz panel, so the number tracks how much headroom
/// the app has rather than how fast the screen refreshes.
///
/// The timings callback and sample timer only run while [enabled], so the
/// monitor costs nothing when the debug toggle is off.
class FpsMonitor extends ChangeNotifier {
  FpsMonitor._();

  static final FpsMonitor instance = FpsMonitor._();

  /// Five minutes of history at one sample per second.
  static const int historyLength = 300;

  static const Duration _sampleInterval = Duration(seconds: 1);
  static const Duration _readoutInterval = Duration(milliseconds: 500);

  final ListQueue<double?> _history = ListQueue<double?>(historyLength);
  final Stopwatch _readoutClock = Stopwatch();

  double? _current;
  bool _enabled = false;
  bool _notifyScheduled = false;

  int _readoutMicros = 0;
  int _readoutFrames = 0;
  int _sampleMicros = 0;
  int _sampleFrames = 0;

  Timer? _sampleTimer;

  bool get enabled => _enabled;

  /// Latest rendered FPS, or null until the first frames land.
  double? get current => _current;

  /// Oldest-first samples. A null entry is a second in which no frame rendered,
  /// and is drawn as a gap rather than a drop to zero.
  List<double?> get history => _history.toList(growable: false);

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;

    if (value) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _readoutClock
        ..reset()
        ..start();
      _sampleTimer = Timer.periodic(_sampleInterval, (_) => _pushSample());
    } else {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _sampleTimer?.cancel();
      _sampleTimer = null;
      _readoutClock
        ..stop()
        ..reset();
      // Drop history so re-enabling starts from a clean window instead of
      // stitching the new run onto a stale one.
      _history.clear();
      _current = null;
      _readoutMicros = 0;
      _readoutFrames = 0;
      _sampleMicros = 0;
      _sampleFrames = 0;
    }

    notifyListeners();
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final micros = timing.totalSpan.inMicroseconds;
      if (micros <= 0) continue;
      _readoutMicros += micros;
      _readoutFrames++;
      _sampleMicros += micros;
      _sampleFrames++;
    }

    if (_readoutFrames == 0 || _readoutClock.elapsed < _readoutInterval) return;

    _current = _fps(_readoutMicros, _readoutFrames);
    _readoutMicros = 0;
    _readoutFrames = 0;
    _readoutClock
      ..reset()
      ..start();
    _notifySoon();
  }

  void _pushSample() {
    if (_history.length >= historyLength) _history.removeFirst();
    _history.addLast(
      _sampleFrames == 0 ? null : _fps(_sampleMicros, _sampleFrames),
    );
    _sampleMicros = 0;
    _sampleFrames = 0;
    _notifySoon();
  }

  /// Timings callbacks fire from the engine's frame report, so defer the
  /// rebuild to a microtask rather than marking the tree dirty mid-report.
  void _notifySoon() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (_enabled) notifyListeners();
    });
  }

  static double _fps(int totalMicros, int frames) =>
      Duration.microsecondsPerSecond / (totalMicros / frames);
}
