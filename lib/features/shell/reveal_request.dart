import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

enum RevealTargetType { task, event }

/// A one-shot request to navigate to and reveal a specific task or event,
/// set by the notification popover's "Show in ..." menu items. The
/// destination page (TodoPage / CalendarPage) consumes it once and clears
/// [revealRequestProvider] back to null afterward.
class RevealRequest {
  const RevealRequest.task(this.task)
    : type = RevealTargetType.task,
      event = null,
      day = null;

  const RevealRequest.event(this.event, {this.day})
    : type = RevealTargetType.event,
      task = null;

  final RevealTargetType type;
  final TodoTask? task;
  final CalendarEvent? event;

  /// Which occurrence of [event] to land on, for a repeating series whose
  /// anchor is months away from the occurrence the inbox was showing. Null
  /// falls back to the event's own start.
  final DateTime? day;
}

final revealRequestProvider = StateProvider<RevealRequest?>((ref) => null);

/// A one-shot request to bring Settings' automatic-backup tiles on screen, set
/// by the inbox's "Backups failing" row. Settings isn't preloaded, so the
/// tiles look for it when they first mount as well as when it changes, and
/// set it back to false once they have scrolled into view.
final revealAutoBackupRequestProvider = StateProvider<bool>((ref) => false);
