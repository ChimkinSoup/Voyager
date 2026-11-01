import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/notifications/notification_history.dart';
import 'package:voyager/features/settings/services/heat_watch_log.dart';

/// Checks in a row the logger must look down before alerting, a minute apart.
/// Rides out sign-in and wake from sleep, when the newest reading is old until
/// the logger catches up, and the scheduled task's restart within a minute.
/// Counted rather than timed, so a long sleep doesn't look like a long outage.
const _downChecksToAlert = 5;

/// Raises a notification when the HeatWatch logger stops recording, once per
/// outage, for as long as the app runs.
class HeatWatchMonitor {
  HeatWatchMonitor({required this.read, required this.notify});

  /// Prefix of the OS notification's payload, so a click can be told apart
  /// from a reminder's.
  static const notificationKeyPrefix = 'heatWatch:';

  final Future<HeatWatchStatus?> Function() read;
  final Future<bool> Function(String key, String title, String body) notify;

  Timer? _timer;
  var _downChecks = 0;

  void start() {
    _timer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(check(DateTime.now())),
    );
  }

  void dispose() => _timer?.cancel();

  @visibleForTesting
  Future<void> check(DateTime now) async {
    final HeatWatchStatus? status;
    try {
      status = await read();
    } on FileSystemException {
      // The logger had a file busy; the next tick reads it.
      return;
    }
    if (status == null || status.isHealthy(now)) {
      _downChecks = 0;
      return;
    }
    if (++_downChecks != _downChecksToAlert) return;

    const title = 'Heat logger is not recording';
    final last = status.lastReading;
    final body = last == null
        ? 'No readings yet. Is Core Temp running?'
        : 'Last reading ${DateFormat('d MMM, h:mm a').format(last)}. '
              'Are the logger and Core Temp running?';
    final shown = await notify('${notificationKeyPrefix}down', title, body);
    if (shown) {
      NotificationHistory.instance.record(
        title,
        origin: 'Heat logger',
        detail: body,
      );
    }
  }
}
