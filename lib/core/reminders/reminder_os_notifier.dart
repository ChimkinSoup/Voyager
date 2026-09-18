import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;
import 'package:timezone/timezone.dart' as tz;
import 'package:voyager/core/platform/platform_info.dart';

/// One OS alert a reminder source wants, keyed by its source key.
class PlannedReminderAlert {
  const PlannedReminderAlert({
    required this.sourceKey,
    required this.title,
    required this.fireAt,
    this.body,
  });

  final String sourceKey;
  final String title;
  final String? body;
  final DateTime fireAt;
}

enum ReminderPermission { granted, denied, unsupported }

/// The platform's notification tray, as far as reminders need it
/// (`SCHEDULED_REMINDERS_HLD.md` §5.2). Best effort everywhere: a failure here
/// never stops the in-app sticky, which is the delivery that always works.
///
/// The two platforms this app ships on want opposite things. Android can hand
/// the OS an alarm that fires with the app killed, so it [schedule]s. Windows
/// keeps the process alive in the tray, and an alert raised from there at the
/// moment a reminder falls due is one an acknowledgement on another device can
/// still stop — so it [showNow]s instead.
abstract class ReminderOsNotifier {
  /// Whether [showNow] raises anything. False where alerts are scheduled
  /// ahead instead.
  bool get raisesDueAlertsInApp;

  /// Source keys of notifications the user clicked while the app was running.
  Stream<String> get taps;

  /// Replaces every pending scheduled alert with [alerts].
  Future<void> schedule(List<PlannedReminderAlert> alerts);

  /// Raises [alert] now. Returns whether anything was shown.
  Future<bool> showNow(PlannedReminderAlert alert);

  /// Takes a shown alert for [sourceKey] back out of the tray, where the
  /// platform allows it.
  Future<void> dismiss(String sourceKey);

  /// The source key of the notification that launched the app, if any.
  Future<String?> launchSourceKey();

  Future<ReminderPermission> permission();

  /// Asks for permission where the platform prompts for it. Android shows its
  /// dialog at most twice per install, so repeat calls do not nag.
  Future<void> requestPermission();

  Future<void> openSystemSettings();
}

ReminderOsNotifier createReminderOsNotifier() {
  if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) {
    return const NoopReminderOsNotifier();
  }
  if (isAndroid || isWindows) return LocalNotificationsReminderOsNotifier();
  return const NoopReminderOsNotifier();
}

/// Platforms with nothing to call — and tests.
class NoopReminderOsNotifier implements ReminderOsNotifier {
  const NoopReminderOsNotifier();

  @override
  bool get raisesDueAlertsInApp => false;

  @override
  Stream<String> get taps => const Stream.empty();

  @override
  Future<void> schedule(List<PlannedReminderAlert> alerts) async {}

  @override
  Future<bool> showNow(PlannedReminderAlert alert) async => false;

  @override
  Future<void> dismiss(String sourceKey) async {}

  @override
  Future<String?> launchSourceKey() async => null;

  @override
  Future<ReminderPermission> permission() async =>
      ReminderPermission.unsupported;

  @override
  Future<void> requestPermission() async {}

  @override
  Future<void> openSystemSettings() async {}
}

class LocalNotificationsReminderOsNotifier implements ReminderOsNotifier {
  /// Starts initializing straight away: every other call waits on it, so none
  /// can reach the plugin before it is set up.
  LocalNotificationsReminderOsNotifier() {
    _ready = _initialize();
  }

  final _plugin = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<String>.broadcast();
  late final Future<bool> _ready;

  static const _channelId = 'reminders';
  static const _channelName = 'Reminders';

  @override
  bool get raisesDueAlertsInApp => isWindows;

  @override
  Stream<String> get taps => _taps.stream;

  Future<bool> _initialize() async {
    try {
      final icon = p.join(
        p.dirname(Platform.resolvedExecutable),
        'data',
        'flutter_assets',
        'assets',
        'app_icon.ico',
      );
      await _plugin.initialize(
        settings: InitializationSettings(
          android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
          windows: WindowsInitializationSettings(
            appName: 'Voyager',
            appUserModelId: 'Voyager.App',
            guid: '5f88cee6-688c-4ff4-9fd6-e21045569f9f',
            iconPath: isWindows && File(icon).existsSync() ? icon : null,
          ),
        ),
        onDidReceiveNotificationResponse: (response) {
          final key = response.payload;
          if (key != null && key.isNotEmpty) _taps.add(key);
        },
      );
      return true;
    } catch (error, stackTrace) {
      _report(error, stackTrace, 'initializing reminder notifications');
      return false;
    }
  }

  Future<bool> get _isReady => _ready;

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  NotificationDetails get _details => const NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Scheduled reminders and reminder bells',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    ),
    windows: WindowsNotificationDetails(),
  );

  /// A stable 31-bit id per source, so rescheduling a source replaces its
  /// alert rather than adding another.
  static int _idFor(String sourceKey) {
    var hash = 0;
    for (final unit in sourceKey.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash;
  }

  @override
  Future<void> schedule(List<PlannedReminderAlert> alerts) async {
    if (!isAndroid || !await _isReady) return;
    try {
      final android = _android;
      await _plugin.cancelAllPendingNotifications();
      final exact = await android?.canScheduleExactNotifications() ?? false;
      final now = DateTime.now();
      for (final alert in alerts) {
        if (!alert.fireAt.isAfter(now)) continue;
        await _plugin.zonedSchedule(
          id: _idFor(alert.sourceKey),
          // UTC rather than a named zone: the instant is recomputed from the
          // device's wall clock every time the app runs, which is what keeps
          // a reminder on local time across a timezone change.
          scheduledDate: tz.TZDateTime.from(alert.fireAt.toUtc(), tz.UTC),
          notificationDetails: _details,
          androidScheduleMode: exact
              ? AndroidScheduleMode.exactAllowWhileIdle
              : AndroidScheduleMode.inexactAllowWhileIdle,
          title: alert.title,
          body: alert.body,
          payload: alert.sourceKey,
        );
      }
    } catch (error, stackTrace) {
      _report(error, stackTrace, 'scheduling reminder notifications');
    }
  }

  @override
  Future<bool> showNow(PlannedReminderAlert alert) async {
    if (!raisesDueAlertsInApp || !await _isReady) return false;
    try {
      await _plugin.show(
        id: _idFor(alert.sourceKey),
        title: alert.title,
        body: alert.body,
        notificationDetails: _details,
        payload: alert.sourceKey,
      );
      return true;
    } catch (error, stackTrace) {
      _report(error, stackTrace, 'showing a reminder notification');
      return false;
    }
  }

  @override
  Future<void> dismiss(String sourceKey) async {
    // An unpackaged Windows app cannot reach toasts it already showed.
    if (!isAndroid || !await _isReady) return;
    try {
      await _plugin.cancel(id: _idFor(sourceKey));
    } catch (error, stackTrace) {
      _report(error, stackTrace, 'dismissing a reminder notification');
    }
  }

  @override
  Future<String?> launchSourceKey() async {
    if (!await _isReady) return null;
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return null;
      return details?.notificationResponse?.payload;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<ReminderPermission> permission() async {
    if (!isAndroid) {
      return isWindows
          ? ReminderPermission.granted
          : ReminderPermission.unsupported;
    }
    if (!await _isReady) return ReminderPermission.unsupported;
    final enabled = await _android?.areNotificationsEnabled();
    return enabled == false
        ? ReminderPermission.denied
        : ReminderPermission.granted;
  }

  @override
  Future<void> requestPermission() async {
    if (!isAndroid || !await _isReady) return;
    try {
      await _android?.requestNotificationsPermission();
    } catch (error, stackTrace) {
      _report(error, stackTrace, 'requesting notification permission');
    }
  }

  @override
  Future<void> openSystemSettings() async {
    if (!await _isReady) return;
    try {
      await _plugin.openAppNotificationSettings();
    } catch (error, stackTrace) {
      _report(error, stackTrace, 'opening notification settings');
    }
  }

  void _report(Object error, StackTrace stackTrace, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'ReminderOsNotifier',
        context: ErrorDescription('while $context'),
      ),
    );
  }
}
