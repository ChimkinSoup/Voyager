import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/calendar_recurrence.dart';
import 'package:voyager/domain/services/calendar_recurrence_editing.dart';

/// Every calendar row a delete touched, as it stood the instant before.
///
/// A one-off delete tombstones a single row, but a repeating one can rewrite
/// the master (adding an exception date, or truncating the series) *and*
/// tombstone the detached occurrences that would otherwise outlive it — so an
/// undo has to put a set of rows back, not one.
class CalendarEventDeletion {
  const CalendarEventDeletion(this.events);

  final List<CalendarEvent> events;
}

/// Reads back every row [ids] names, so the caller holds their pre-delete
/// state before it writes anything.
///
/// Read off disk rather than taken from the caller's copies: the page renders
/// from a provider that lags an in-flight save, and restoring from a stale
/// snapshot would quietly roll the last edit back with the undo.
Future<CalendarEventDeletion> snapshotCalendarEvents(
  ProviderContainer container,
  Iterable<String> ids,
) async {
  final repository = container.read(calendarRepositoryProvider);
  final events = <CalendarEvent>[];
  // De-duplicated: a recurring delete names its master both on its own and
  // among the rows it rewrites, so the raw list carries it twice — and a
  // restore would then upsert and push the same row twice for every
  // series undo.
  for (final id in ids.toSet()) {
    final event = await repository.getEvent(id);
    if (event != null) events.add(event);
  }
  return CalendarEventDeletion(events);
}

/// Puts every row in [deletion] back exactly as it was.
///
/// Rebuilt field by field rather than `copyWith`'d, because `copyWith` reads
/// `deletedAt ?? this.deletedAt` and so cannot clear a tombstone. It also has
/// to restore rows that were *edited* rather than deleted — a "this event
/// only" delete works by adding an exception date to the master — and for
/// those the rebuild is what puts the old exception list back.
Future<void> restoreCalendarEvents(
  ProviderContainer container,
  CalendarEventDeletion deletion,
) async {
  final repository = container.read(calendarRepositoryProvider);
  for (final event in deletion.events) {
    // The version is resolved against disk rather than against the snapshot —
    // see [restoreVersionFrom].
    //
    // Deliberately not guarded with [abortIfAlreadyRestored]: half these rows
    // were *edited* rather than tombstoned — a "this event only" delete works
    // by adding an exception date to a master that stays live — so a missing
    // tombstone here says nothing about whether there is anything to undo.
    final current = await repository.getEvent(event.id);
    await repository.upsertEvent(
      CalendarEvent(
        id: event.id,
        createdAt: event.createdAt,
        updatedAt: utcNow(),
        version: restoreVersionFrom(
          preDeleteVersion: event.version,
          currentVersion: current?.version,
        ),
        calendarId: event.calendarId,
        title: event.title,
        start: event.start,
        end: event.end,
        isFullDay: event.isFullDay,
        colorValue: event.colorValue,
        notes: event.notes,
        source: event.source,
        externalId: event.externalId,
        recurrence: event.recurrence,
        recurrenceEndDate: event.recurrenceEndDate,
        exceptionDates: event.exceptionDates,
        recurrenceParentId: event.recurrenceParentId,
        recurrenceDate: event.recurrenceDate,
      ),
    );
  }
  container.invalidate(calendarEventsProvider);
}

/// Deletes [event] on the user's behalf, prompting first.
///
/// Shared by the calendar page and the notification inbox so both offer the
/// same choices: a repeating series asks which occurrences to drop, and only a
/// one-off gets the plain "moved to trash" confirm. The inbox surfaces a
/// *single occurrence* of a series, so without this it would quietly tombstone
/// the whole thing from a dialog that named one event.
///
/// [occurrenceDay] is the day whose occurrence the user was looking at — the
/// row's date in the inbox, the focused day on the calendar — and is what
/// "this event only" and "this and all future events" cut against.
///
/// [onConfirmed] runs after the user commits and before anything is written;
/// it is where a caller re-checks `mounted` and plays its row-exit animation.
/// Returning false aborts without touching a row.
Future<void> deleteCalendarEventInteractive({
  required BuildContext context,
  required ProviderContainer container,
  required OverlayState overlay,
  required CalendarEvent event,
  required DateTime occurrenceDay,
  Future<bool> Function()? onConfirmed,
}) async {
  final repository = container.read(calendarRepositoryProvider);
  final message = deletedMessage(event.title, fallback: 'event');

  // A repeating series asks which occurrences to drop instead of confirming;
  // the three choices are themselves the confirmation.
  if (event.recurrence.repeats && !event.isRecurrenceOverride) {
    final occurrence =
        calendarOccurrenceStartOn(event, occurrenceDay) ??
        DateUtils.dateOnly(event.start.toLocal());
    final scope = await showRecurrenceScopeDialog(
      context,
      title: event.title.trim().isEmpty
          ? 'Delete repeating event?'
          : 'Delete "${event.title}"?',
      isDelete: true,
    );
    if (scope == null) return;
    if (onConfirmed != null && !await onConfirmed()) return;
    final writes = deleteRecurringEvent(event, occurrence, scope);
    // Occurrences previously split off with "this event only" are separate
    // rows, so nothing in [writes] touches them. Left alone they would
    // outlive the series they came from and reappear as stray one-off
    // events.
    final orphanIds = await _orphanedOverrideIds(
      container,
      event,
      occurrence,
      scope,
    );

    // Snapshotted before any of the writes land. All three scopes are
    // undoable from the same set: the master is either rewritten (a new
    // exception date, or a truncated series) or tombstoned, and the orphans
    // are tombstoned — and none of them creates a row, so putting the old
    // rows back is the whole undo.
    final deletion = await snapshotCalendarEvents(container, [
      event.id,
      for (final row in writes.upserts) row.id,
      ...writes.softDeletes,
      ...orphanIds,
    ]);

    for (final row in writes.upserts) {
      await repository.upsertEvent(row);
    }
    for (final id in writes.softDeletes) {
      await repository.softDeleteEvent(id);
    }
    for (final id in orphanIds) {
      await repository.softDeleteEvent(id);
    }
    // Through the captured container, not a `WidgetRef`: everything above
    // awaits, and a sign-out or a shell rebuild landing mid-delete disposes
    // the calling element — after which `ref.invalidate` throws a
    // `StateError` and leaves the rows tombstoned, the provider stale and no
    // toast raised.
    container.invalidate(calendarEventsProvider);

    showSoftDeleteUndoToast(
      overlay: overlay,
      message: message,
      restore: () => restoreCalendarEvents(container, deletion),
    );
    return;
  }

  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete event?',
    message: event.title.trim().isEmpty
        ? 'This event will be moved to trash.'
        : '"${event.title}" will be moved to trash.',
  );
  if (!confirmed) return;
  if (onConfirmed != null && !await onConfirmed()) return;
  final deletion = await snapshotCalendarEvents(container, [event.id]);
  await repository.softDeleteEvent(event.id);
  // See the recurring branch on why this is the container and not a ref.
  container.invalidate(calendarEventsProvider);

  showSoftDeleteUndoToast(
    overlay: overlay,
    message: message,
    restore: () => restoreCalendarEvents(container, deletion),
  );
}

/// Override rows of [master] that a delete at [scope] should take with it.
///
/// "This event only" removes a single occurrence, which by definition is not
/// one that was already detached, so it orphans nothing.
Future<List<String>> _orphanedOverrideIds(
  ProviderContainer container,
  CalendarEvent master,
  DateTime occurrence,
  RecurrenceEditScope scope,
) async {
  if (scope == RecurrenceEditScope.thisEvent) return const [];
  // Across every calendar, not just the master's: editing a single occurrence
  // can move that override to another calendar, which would put it out of a
  // calendar-scoped query's reach and leave it behind as a stray event
  // pointing at a deleted series. [recurrenceParentId] is the real link.
  final all = await container.read(calendarRepositoryProvider).listEvents();
  return [
    for (final candidate in all)
      if (candidate.recurrenceParentId == master.id &&
          (scope == RecurrenceEditScope.allEvents ||
              !(candidate.recurrenceDate ?? candidate.start)
                  .isBefore(occurrence)))
        candidate.id,
  ];
}
