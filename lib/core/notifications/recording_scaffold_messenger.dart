import 'package:flutter/material.dart';
import 'package:voyager/core/notifications/notification_history.dart';

/// A [ScaffoldMessenger] that adds every snackbar it shows to the
/// [NotificationHistory].
///
/// Installed once, around the whole app, so the snackbars still raised from
/// all over the codebase are recorded without each call site having to
/// remember to.
class RecordingScaffoldMessenger extends ScaffoldMessenger {
  const RecordingScaffoldMessenger({super.key, required super.child});

  @override
  ScaffoldMessengerState createState() => _RecordingScaffoldMessengerState();
}

class _RecordingScaffoldMessengerState extends ScaffoldMessengerState {
  @override
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    SnackBar snackBar, {
    AnimationStyle? snackBarAnimationStyle,
  }) {
    final content = snackBar.content;
    final message = content is Text
        ? content.data ?? content.textSpan?.toPlainText()
        : null;
    if (message != null && message.isNotEmpty) {
      NotificationHistory.instance.record(message);
    }
    return super.showSnackBar(
      snackBar,
      snackBarAnimationStyle: snackBarAnimationStyle,
    );
  }
}
