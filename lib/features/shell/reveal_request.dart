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
        event = null;

  const RevealRequest.event(this.event)
      : type = RevealTargetType.event,
        task = null;

  final RevealTargetType type;
  final TodoTask? task;
  final CalendarEvent? event;
}

final revealRequestProvider = StateProvider<RevealRequest?>((ref) => null);
