import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voyager/core/dev/dev_flags.dart';

/// Tracks whether the user is actively interacting with a scrollable
/// somewhere in the app, so a pending remote sync call can wait for the
/// gesture to settle instead of firing mid-scroll.
///
/// This exists because deferring UI rebuilds during a scroll (see
/// TodoPage._refreshOrDeferWhileScrolling) only stops *our own* rebuilds
/// from disturbing the gesture — it can't do anything about the sync call
/// itself holding the UI isolate for its round trip, which is what actually
/// stalls pointer/scroll processing until the call resolves. Delaying the
/// call until scrolling is idle keeps it from landing inside a gesture at
/// all, regardless of how long that call ends up taking.
///
/// Self-expiring by design instead of ref-counted begin/end calls: a missed
/// "end" (e.g. a widget disposed mid-scroll) would otherwise leave this
/// stuck "active" forever and silently block all future syncing. Callers
/// just report activity as it happens; if nothing reports activity for
/// [idleGrace], the gate goes idle on its own.
class ScrollActivityGate {
  ScrollActivityGate._();

  static final instance = ScrollActivityGate._();

  // Bridges the natural pauses between individual motion bursts in what a
  // user experiences as one continuous scroll (trackpad flicks, mouse-wheel
  // notches) — 200ms turned out to be shorter than those gaps, so the
  // deferred call was slipping through mid-session and then blocking right
  // as the user resumed scrolling, which read as "scrolling stops."
  static const idleGrace = Duration(milliseconds: 600);

  /// Upper bound on how long a sync call will wait — continuous scrolling
  /// must never be able to block syncing indefinitely.
  static const maxWait = Duration(seconds: 2);

  DateTime? _activeUntil;

  void noteActivity() {
    _activeUntil = DateTime.now().add(idleGrace);
  }

  bool get isActive {
    final until = _activeUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  Future<void> waitUntilIdle() async {
    if (!isActive) return;
    final start = DateTime.now();
    final deadline = start.add(maxWait);
    while (isActive && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (DevFlags.verboseSync) {
      final waited = DateTime.now().difference(start).inMilliseconds;
      debugPrint(
        '[sync] gate: held a sync call for ${waited}ms '
        '(${isActive ? "gave up at maxWait, still scrolling" : "scrolling went idle"})',
      );
    }
  }
}
