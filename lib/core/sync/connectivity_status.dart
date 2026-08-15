import 'dart:async';

import 'package:flutter/widgets.dart';

/// Tracks whether the sync backend is reachable, by asking it.
///
/// Nothing in the sync path can answer this on its own: Firestore queues
/// writes silently while offline and serves reads from its local cache, so an
/// unplugged network looks exactly like a quiet one. The only signal is a
/// deliberate round-trip — the `probe` callback, normally
/// `SyncRepository.ping` — run on a timer.
///
/// The probe is cheap but not free (one document read against the user's
/// quota), so it runs slowly while things are healthy and speeds up once they
/// are not: [onlineInterval] between successes, [offlineInterval] while
/// waiting for the connection to come back.
///
/// Starts optimistic. The UI shows nothing until the connection is *proven*
/// gone, so guessing "online" before the first probe lands keeps the rail
/// quiet during startup rather than flashing an offline badge at every launch.
///
/// Polling only runs while the app is in the foreground. Nobody is reading a
/// status icon in a window they have alt-tabbed away from or an app Android
/// has backgrounded, so probing through it would spend quota and battery on an
/// answer with no audience. Returning after long enough for a probe to have
/// come due spends it immediately, which makes the badge current by the time
/// the window has finished painting rather than up to a minute later; a
/// quicker round-trip to another window and back simply picks the interval up
/// where it left off.
class ConnectivityStatusController extends ChangeNotifier
    with WidgetsBindingObserver {
  ConnectivityStatusController({
    required this.probe,
    this.onlineInterval = const Duration(seconds: 60),
    this.offlineInterval = const Duration(seconds: 10),
    this.probeTimeout = const Duration(seconds: 8),
    this.startDelay = const Duration(seconds: 3),
  }) {
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer(startDelay, _onProbeDue);
  }

  /// The round-trip itself.
  final Future<void> Function() probe;

  /// Gap between probes while the backend is answering.
  final Duration onlineInterval;

  /// Gap between probes while it is not — short enough that reconnecting
  /// clears the badge while the user is still looking at it.
  final Duration offlineInterval;

  /// A probe that hasn't answered by now counts as a failure. Firestore's own
  /// request timeout is far longer than a user's patience for a status dot.
  final Duration probeTimeout;

  /// Delay before the first probe, which keeps one more network request out of
  /// the app's first frames.
  final Duration startDelay;

  /// How many probes in a row must fail before the state flips to offline.
  ///
  /// One dropped request is a blip, not an outage, and a badge that blinks on
  /// and off is worse than one that arrives a few seconds late.
  static const _failuresBeforeOffline = 2;

  bool _isOnline = true;
  int _consecutiveFailures = 0;
  Timer? _timer;
  bool _disposed = false;
  bool _paused = false;
  bool _probeInFlight = false;
  bool _probeOwed = false;

  /// False only once the backend has failed [_failuresBeforeOffline] probes in
  /// a row. Recovery is immediate on the next success.
  bool get isOnline => _isOnline;

  /// Windows reports [AppLifecycleState.inactive] when the window loses focus
  /// and `hidden` when it is minimised; Android reports `paused` on the way to
  /// the background. All of them mean the same thing here — nobody is looking
  /// — so only `resumed` keeps the timer alive.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else {
      _pause();
    }
  }

  void _pause() {
    _paused = true;
  }

  /// Returns to the foreground, spending a request only if one is actually
  /// owed.
  ///
  /// The scheduled probe was not cancelled on the way out — a pending [Timer]
  /// costs nothing and is the only honest record of how much of the interval
  /// was left. So flicking away and straight back finds that timer still
  /// holding its remaining time and does nothing at all, while a real absence
  /// finds a probe owed and spends it now. Restarting the interval on every
  /// return instead would let a fast alt-tab cycle push the next probe out
  /// forever and never check the connection at all.
  void _resume() {
    if (!_paused) return;
    _paused = false;
    final owed = _probeOwed;
    _probeOwed = false;
    // A probe still in the air is a live round-trip already: its answer is as
    // fresh as a new one would be, and it rearms the schedule when it lands.
    if (!owed || _probeInFlight) return;
    unawaited(_runProbe());
  }

  /// The scheduled moment for the next probe, which is not always the moment
  /// to make one.
  void _onProbeDue() {
    if (_paused) {
      // Nobody is reading the badge, so the request would buy an answer with
      // no audience. Remember that it is owed and spend it on return.
      _probeOwed = true;
      return;
    }
    unawaited(_runProbe());
  }

  Future<void> _runProbe() async {
    _probeInFlight = true;
    try {
      await probe().timeout(probeTimeout);
      _consecutiveFailures = 0;
      _set(true);
    } catch (_) {
      _consecutiveFailures++;
      if (_consecutiveFailures >= _failuresBeforeOffline) _set(false);
    } finally {
      _probeInFlight = false;
    }
    // Paced by the last probe's result rather than by the published state:
    // during the failure streak the state still reads online, and waiting a
    // full [onlineInterval] for the confirming probe would put a minute
    // between the connection dropping and the badge admitting it.
    //
    // Rescheduling here — after the await, not before it — also means a slow
    // round-trip can never overlap the next one.
    //
    // Armed even while backgrounded: the timer is what remembers the interval,
    // and [_onProbeDue] is where the decision not to spend it gets made.
    if (_disposed) return;
    final settled = _consecutiveFailures == 0;
    _timer = Timer(settled ? onlineInterval : offlineInterval, _onProbeDue);
  }

  void _set(bool online) {
    if (_isOnline == online || _disposed) return;
    _isOnline = online;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
