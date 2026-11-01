import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

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
/// free-running 16ms timer drifts against the vsync grid and judders.
///
/// Listeners get the step since their previous tick, not a timestamp, so
/// none of them has to work out the time it was away: the step is zero on a
/// subscriber's first tick, zero on the first tick after an idle stop, and
/// never more than [maxStep], so a stalled frame doesn't move anything in
/// one leap. Each animation's own time is the sum of its steps.
///
/// It runs only while something is subscribed. Pausing is each subscriber's
/// own business — unsubscribe while offstage or minimised (see
/// [WindowVisibility]), the half of a Ticker's contract a Timer doesn't give.
///
/// It also stops by itself [idleAfter] without pointer or key input, and the
/// next input starts it again. A visible window nobody is using — left open
/// beside another app, say — otherwise redrew its background at 60fps for as
/// long as it stayed up: ~25% of a core plus the GPU, measured 2026-11-01,
/// which was enough to heat the PC. Subscribers see a frozen frame, not an
/// unsubscribe, and carry on from it when the clock resumes.
class AmbientClock {
  AmbientClock._();

  static final instance = AmbientClock._();

  static const _gap = Duration(milliseconds: 12);

  /// How long the clock runs after the last input, or after it starts.
  static const idleAfter = Duration(seconds: 30);

  /// The longest step a tick hands out.
  static const maxStep = Duration(milliseconds: 100);

  final _listeners = <void Function(Duration step)>[];

  /// Subscribed since the last tick, so due a zero step on their first.
  final _joined = <void Function(Duration step)>{};

  /// The previous tick's vsync time; null when the clock (re)starts.
  Duration? _lastFrameAt;
  Timer? _timer;
  int? _frameCallback;

  var _listeningForInput = false;
  var _inputSinceLastFrame = false;

  /// The frame time of the last tick that followed input; null until the
  /// first tick after the clock starts.
  Duration? _activeAt;

  /// Calls [onFrame] with each tick's step until [unsubscribe]d. A subscriber
  /// joining while the clock runs waits for its next tick, so it stays in
  /// phase.
  void subscribe(void Function(Duration step) onFrame) {
    if (_listeners.contains(onFrame)) return;
    _listeners.add(onFrame);
    _joined.add(onFrame);
    if (!_listeningForInput) {
      _listeningForInput = true;
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
      HardwareKeyboard.instance.addHandler(_onKey);
    }
    if (_timer == null && _frameCallback == null) _start();
  }

  void _onPointer(PointerEvent _) => _onInput();

  bool _onKey(KeyEvent _) {
    _onInput();
    return false;
  }

  /// Runs the clock for another [idleAfter], idle or not: for an animation
  /// that starts without input, such as one kicked off by data arriving.
  void wake() => _onInput();

  void _onInput() {
    _inputSinceLastFrame = true;
    if (_listeners.isNotEmpty && _timer == null && _frameCallback == null) {
      _start();
    }
  }

  void _start() {
    _activeAt = null;
    _lastFrameAt = null;
    _requestFrame();
  }

  void unsubscribe(void Function(Duration step) onFrame) {
    _listeners.remove(onFrame);
    _joined.remove(onFrame);
    if (_listeners.isNotEmpty) return;
    if (_listeningForInput) {
      _listeningForInput = false;
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
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
    if (_inputSinceLastFrame || _activeAt == null) _activeAt = timeStamp;
    _inputSinceLastFrame = false;
    // This frame still ticks, so the picture freezes on the latest state.
    if (timeStamp - _activeAt! < idleAfter) {
      _timer = Timer(_gap, () {
        _timer = null;
        _requestFrame();
      });
    }
    final last = _lastFrameAt;
    _lastFrameAt = timeStamp;
    final gap = last == null ? Duration.zero : timeStamp - last;
    final step = gap < maxStep ? gap : maxStep;
    // A copy: a listener may unsubscribe (or another subscribe) from inside.
    for (final onFrame in List.of(_listeners)) {
      onFrame(_joined.remove(onFrame) ? Duration.zero : step);
    }
  }
}
