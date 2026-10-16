import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The time the Life page's figures are computed for, recomputed at the turn
/// of each minute (their finest unit). The page stays mounted between visits
/// and the app runs all day from the tray, so a time read once at build would
/// leave heartbeats frozen and the day-based stats on an old day.
final lifeClockProvider = Provider.autoDispose<DateTime>((ref) {
  final now = DateTime.now();
  final timer = Timer(
    DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute + 1,
    ).difference(now),
    ref.invalidateSelf,
  );
  ref.onDispose(timer.cancel);
  return now;
});
