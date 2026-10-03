import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/domain/services/calendar_recurrence_editing.dart';

/// Flips the done state of the occurrence of [event] on [occurrenceDay].
///
/// Shared by the editor and the right-click menu. A repeating series flips
/// only that one occurrence, so there is nothing to ask.
///
/// The row is re-read from disk rather than taken from [event]: the editor
/// holds the copy it was opened with, and writing a toggle on top of that
/// would drop any done mark made since.
Future<void> toggleCalendarEventDone({
  required ProviderContainer container,
  required CalendarEvent event,
  required DateTime occurrenceDay,
}) async {
  final repository = container.read(calendarRepositoryProvider);
  final current = await repository.getEvent(event.id) ?? event;
  // No occurrence on that day means nothing on screen to mark; falling back
  // to another one would mark a day the user never clicked.
  final occurrence = calendarOccurrenceStartOn(current, occurrenceDay);
  if (occurrence == null) return;
  await repository.upsertEvent(
    setCalendarEventDone(
      current,
      occurrence,
      done: !calendarEventDoneOn(current, occurrence),
    ),
  );
  container.invalidate(calendarEventsProvider);
}
