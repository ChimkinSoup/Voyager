import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/features/hotkeys/floaters/floater_app_icon.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';

/// The reminder hotkey's floater: the Inbox's "New reminder" editor, always
/// fresh — a reminder is a short one-shot form, so nothing is kept when the
/// floater is dismissed.
class ReminderFloater extends ConsumerStatefulWidget {
  const ReminderFloater({super.key});

  @override
  ConsumerState<ReminderFloater> createState() => _ReminderFloaterState();
}

class _ReminderFloaterState extends ConsumerState<ReminderFloater> {
  var _saved = false;

  @override
  Widget build(BuildContext context) {
    final floaters = ref.read(floaterControllerProvider);
    return scheduledReminderForm(
      onSaved: () => _saved = true,
      onClose: () => unawaited(
        _saved ? floaters.completeWith('Reminder added') : floaters.dismiss(),
      ),
      leading: const FloaterAppIcon(PhosphorIconsRegular.bellRinging, size: 20),
    );
  }
}
