import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The time the Life page's figures are computed for, recomputed at the turn
/// of each minute (their finest unit). The page stays mounted between visits
/// and the app runs all day from the tray, so a time read once at build would
/// leave heartbeats frozen and the day-based stats on an old day.
final lifeClockProvider = Provider.autoDispose<DateTime>((ref) {
  final now = DateTime.now();
  // Counted from the seconds into this minute, not from a DateTime built for
  // the next one: in the repeated hour after DST ends, that local time
  // resolves to the first pass, an hour back, so the timer fired at once and
  // the page rebuilt every frame until the hour was over.
  final timer = Timer(
    const Duration(minutes: 1) -
        Duration(
          seconds: now.second,
          milliseconds: now.millisecond,
          microseconds: now.microsecond,
        ),
    ref.invalidateSelf,
  );
  ref.onDispose(timer.cancel);
  return now;
});
