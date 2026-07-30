import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Samples the app's *rendered* frame rate from the engine's frame-timing
/// reports, ported from the `main` branch's `FpsMonitor`.
///
/// The important part is what it deliberately does **not** do: it never runs a
/// [Ticker]. A Ticker requests a frame on every vsync, which pins the whole
/// render pipeline at native refresh even on an otherwise idle screen — and on
/// Windows that continuous rendering starves pointer input, making hovers and
/// clicks lag by seconds. [SchedulerBinding.addTimingsCallback] is passive: it
/// only reports on frames the app was already going to draw, so the counter
/// costs nothing and never forces a frame.
///
/// Because it measures the frame budget actually consumed (build + raster)
/// rather than the display-capped delivery rate, a frame costing 4ms reads as
/// 250fps even on a 60Hz panel — the number tracks headroom, not refresh rate.
///
/// The timings callback and sample timer only run between [start] and [stop],
/// so the monitor is fully detached while the dev toggle is off.
class FpsMonitorController extends ChangeNotifier {
  /// Five minutes of history at one sample per second.
  static const int historyLength = 300;

  static const Duration _sampleInterval = Duration(seconds: 1);
  static const Duration _readoutInterval = Duration(milliseconds: 500);

  final ListQueue<double?> _history = ListQueue<double?>(historyLength);
  final Stopwatch _readoutClock = Stopwatch();

  double? _current;
  bool _running = false;
  bool _notifyScheduled = false;

  int _readoutMicros = 0;
  int _readoutFrames = 0;
  int _sampleMicros = 0;
  int _sampleFrames = 0;

  Timer? _sampleTimer;

  bool get isRunning => _running;

  /// Latest rendered FPS, or null until the first frames land.
  double? get currentFps => _current;

  /// Oldest-first samples. A null entry is a second in which no frame rendered
  /// (an idle screen), drawn as a gap rather than a drop to zero. A fresh list
  /// is returned each call so a [CustomPainter] can detect changes by identity.
  List<double?> get history => _history.toList(growable: false);

  void start() {
    if (_running) return;
    _running = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _readoutClock
      ..reset()
      ..start();
    _sampleTimer = Timer.periodic(_sampleInterval, (_) => _pushSample());
    notifyListeners();
  }

  void stop() {
    if (!_running) return;
    _running = false;
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

  /// Timings callbacks fire from inside the engine's frame report, so defer the
  /// rebuild to a microtask rather than marking the tree dirty mid-report.
  void _notifySoon() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (_running) notifyListeners();
    });
  }

  static double _fps(int totalMicros, int frames) =>
      Duration.microsecondsPerSecond / (totalMicros / frames);

  @override
  void dispose() {
    if (_running) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _sampleTimer?.cancel();
    }
    super.dispose();
  }
}
