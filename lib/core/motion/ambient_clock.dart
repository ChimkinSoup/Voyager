import 'dart:async';

import 'package:flutter/scheduler.dart';

/// The one ~60fps frame clock every ambient animation shares: the animated
/// backgrounds and the two cherry trees.
///
/// Each of them used to drive itself — the backgrounds from their own 16ms
/// [Timer]s, the trees from [Ticker]s — and every one of those asks for frames
/// on its own schedule. A frame redraws the whole window whoever asked for it,
/// so two unsynchronised 60fps sources interleave into ~85fps of full-window
/// redraws (measured on the demo page), and a Ticker alone pins it at the
/// display's 120. Ticking everyone in the same frame keeps the window at 60
/// however many of them are on screen.
///
/// Each frame arms a one-shot [Timer] for [_gap], which then asks for the next
/// vsync: that lands 1/60s after the last frame at 60 or 120Hz, where a
/// free-running 16ms timer drifts against the vsync grid and judders. The
/// timestamp handed to listeners is that frame's vsync time.
///
/// It runs only while something is subscribed. Pausing is each subscriber's
/// own business — unsubscribe while offstage or minimised (see
/// [WindowVisibility]), the half of a Ticker's contract a Timer doesn't give.
class AmbientClock {
  AmbientClock._();

  static final instance = AmbientClock._();

  static const _gap = Duration(milliseconds: 12);

  final _listeners = <void Function(Duration timeStamp)>[];
  Timer? _timer;
  int? _frameCallback;

  /// Calls [onFrame] on every tick until [unsubscribe]d. A subscriber joining
  /// while the clock runs waits for its next tick, so it stays in phase.
  void subscribe(void Function(Duration timeStamp) onFrame) {
    if (_listeners.contains(onFrame)) return;
    _listeners.add(onFrame);
    if (_timer == null && _frameCallback == null) _requestFrame();
  }

  void unsubscribe(void Function(Duration timeStamp) onFrame) {
    _listeners.remove(onFrame);
    if (_listeners.isNotEmpty) return;
    _timer?.cancel();
    _timer = null;
    final callback = _frameCallback;
    if (callback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callback);
    }
    _frameCallback = null;
  }

  void _requestFrame() {
    _frameCallback = SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
  }

  void _onFrame(Duration timeStamp) {
    _frameCallback = null;
    _timer = Timer(_gap, () {
      _timer = null;
      _requestFrame();
    });
    // A copy: a listener may unsubscribe (or another subscribe) from inside.
    for (final onFrame in List.of(_listeners)) {
      onFrame(timeStamp);
    }
  }
}
