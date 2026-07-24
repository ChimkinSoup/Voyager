import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Tracks the app's real, vsync-driven frame rate while [start]ed.
///
/// The wave/petal backgrounds deliberately avoid a [Ticker] and drive
/// themselves from 30fps [Timer]s instead, precisely so they don't pin the
/// render pipeline at native refresh rate (see geometric_texture.dart). An FPS
/// counter needs the opposite: without something continuously requesting
/// frames, there's nothing to measure — an idle screen would just read 0. So
/// this deliberately runs its own [Ticker], accepting that cost only while
/// the counter is actually shown; [stop] releases it completely.
class FpsMonitorController extends ChangeNotifier {
  Ticker? _ticker;
  Duration? _windowStart;
  int _framesInWindow = 0;

  /// Most recently completed one-second sample. 0 until the first sample lands.
  double currentFps = 0;

  final Queue<double> _history = Queue<double>();

  /// Up to the last [_historyLength] one-second samples, oldest first — "the
  /// last minute". Returns a fresh snapshot each call so callers (e.g. a
  /// CustomPainter's shouldRepaint) can detect changes by reference.
  List<double> get history => List.unmodifiable(_history);

  static const _historyLength = 60;
  static const _sampleWindow = Duration(seconds: 1);

  bool get isRunning => _ticker != null;

  void start() {
    if (_ticker != null) return;
    _windowStart = null;
    _framesInWindow = 0;
    _ticker = Ticker(_onTick)..start();
  }

  void stop() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    currentFps = 0;
    _history.clear();
    notifyListeners();
  }

  void _onTick(Duration elapsed) {
    _framesInWindow++;

    final windowStart = _windowStart;
    if (windowStart == null) {
      _windowStart = elapsed;
      return;
    }

    final windowElapsed = elapsed - windowStart;
    if (windowElapsed < _sampleWindow) return;

    currentFps = _framesInWindow / (windowElapsed.inMicroseconds / 1e6);
    _history.addLast(currentFps);
    while (_history.length > _historyLength) {
      _history.removeFirst();
    }

    _framesInWindow = 0;
    _windowStart = elapsed;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }
}
