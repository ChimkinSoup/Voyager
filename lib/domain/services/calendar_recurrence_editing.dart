import 'package:flutter/material.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/services/recurrence_engine.dart';

/// Which slice of a series an edit or delete applies to.
enum RecurrenceEditScope {
  /// Just the occurrence the user acted on. Deletes add an exception date;
  /// edits add one *and* write a detached override row.
  thisEvent,

  /// The occurrence acted on and every later one. The original series is
  /// truncated the day before, so the two halves never overlap.
  thisAndFuture,

  /// The whole series, including occurrences already in the past.
  allEvents,
}

/// The writes one scoped edit or delete resolves to.
///
/// Both lists are already-final rows: the caller upserts every entry of
/// [upserts] and soft-deletes every id in [softDeletes], in that order, without
/// having to know which scope produced them.
class RecurrenceEditResult {
  const RecurrenceEditResult({
    this.upserts = const [],
    this.softDeletes = const [],
  });

  final List<CalendarEvent> upserts;
  final List<String> softDeletes;
}

/// Whether [occurrenceDate] is the very first occurrence of [master].
///
/// Splitting or excepting the first occurrence would leave a series with
/// nothing before it, so callers collapse those cases to a whole-series
/// operation instead of writing an empty husk.
bool isFirstOccurrence(CalendarEvent master, DateTime occurrenceDate) =>
    DateUtils.dateOnly(occurrenceDate) ==
    DateUtils.dateOnly(master.start.toLocal());

/// Moves [dateTime] onto [date] while keeping its wall-clock time.
///
/// Rebuilt field by field rather than added as a Duration so a series that
/// crosses a DST boundary keeps starting at 09:00 rather than drifting to
/// 08:00 or 10:00.
DateTime _onDateKeepingTime(DateTime date, DateTime dateTime) {
  final local = dateTime.toLocal();
  return DateTime(
    date.year,
    date.month,
    date.day,
    local.hour,
    local.minute,
    local.second,
    local.millisecond,
  );
}

/// Deletes part of a series.
RecurrenceEditResult deleteRecurringEvent(
  CalendarEvent master,
  DateTime occurrenceDate,
  RecurrenceEditScope scope,
) {
  final occurrence = DateUtils.dateOnly(occurrenceDate);

  switch (scope) {
    case RecurrenceEditScope.allEvents:
      return RecurrenceEditResult(softDeletes: [master.id]);

    case RecurrenceEditScope.thisEvent:
      return RecurrenceEditResult(
        upserts: [
          master.copyWith(
            exceptionDates: [...master.exceptionDates, occurrence],
          ),
        ],
      );

    case RecurrenceEditScope.thisAndFuture:
      // Nothing would survive the truncation, so drop the series outright
      // rather than leaving a row whose end date precedes its start.
      if (isFirstOccurrence(master, occurrence)) {
        return RecurrenceEditResult(softDeletes: [master.id]);
      }
      return RecurrenceEditResult(
        upserts: [
          master.copyWith(recurrenceEndDate: addDays(occurrence, -1)),
        ],
      );
  }
}

/// Applies an edit to part of a series.
///
/// [edited] is the whole event as the panel produced it — the user's new title,
/// times, colour and rule, carried on [master]'s identity. What this function
/// decides is *which rows* those values land on.
///
/// [newId] mints the id for a split-off row; it is passed in so the caller's id
/// generator stays the single source of ids.
RecurrenceEditResult editRecurringEvent({
  required CalendarEvent master,
  required CalendarEvent edited,
  required DateTime occurrenceDate,
  required RecurrenceEditScope scope,
  required String Function() newId,
}) {
  final occurrence = DateUtils.dateOnly(occurrenceDate);

  switch (scope) {
    case RecurrenceEditScope.allEvents:
      return RecurrenceEditResult(upserts: [edited]);

    case RecurrenceEditScope.thisEvent:
      // The detached row keeps whatever start/end the user chose but drops the
      // rule: it is one occurrence now, not a series of its own.
      final override = CalendarEvent(
        id: newId(),
        createdAt: master.createdAt,
        updatedAt: DateTime.now().toUtc(),
        calendarId: edited.calendarId,
        title: edited.title,
        start: edited.start,
        end: edited.end,
        isFullDay: edited.isFullDay,
        colorValue: edited.colorValue,
        notes: edited.notes,
        source: master.source,
        externalId: master.externalId,
        recurrenceParentId: master.id,
        recurrenceDate: occurrence,
      );
      return RecurrenceEditResult(
        upserts: [
          master.copyWith(
            exceptionDates: [...master.exceptionDates, occurrence],
          ),
          override,
        ],
      );

    case RecurrenceEditScope.thisAndFuture:
      // Editing from the first occurrence touches nothing earlier, so there is
      // no split to make — it is an all-events edit.
      if (isFirstOccurrence(master, occurrence)) {
        return RecurrenceEditResult(upserts: [edited]);
      }
      final tail = CalendarEvent(
        id: newId(),
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
        calendarId: edited.calendarId,
        title: edited.title,
        start: edited.start,
        end: edited.end,
        isFullDay: edited.isFullDay,
        colorValue: edited.colorValue,
        notes: edited.notes,
        source: master.source,
        externalId: master.externalId,
        recurrence: edited.recurrence,
        // Exceptions and any end date belong to whichever half of the split
        // they fall in; the tail inherits only the ones at or after the break.
        recurrenceEndDate: master.recurrenceEndDate,
        exceptionDates: [
          for (final d in master.exceptionDates)
            if (!DateUtils.dateOnly(d.toLocal()).isBefore(occurrence)) d,
        ],
      );
      return RecurrenceEditResult(
        upserts: [
          master.copyWith(
            recurrenceEndDate: addDays(occurrence, -1),
            exceptionDates: [
              for (final d in master.exceptionDates)
                if (DateUtils.dateOnly(d.toLocal()).isBefore(occurrence)) d,
            ],
            clearRecurrenceEndDate: false,
          ),
          tail,
        ],
      );
  }
}

/// [master] as the single occurrence beginning on [occurrenceDate].
///
/// The panel edits one occurrence but is handed the series row, whose start is
/// the *first* occurrence. Without this, clicking the March instance of a
/// weekly event would open an editor showing January's date. The span and the
/// wall-clock times come along unchanged.
CalendarEvent occurrenceView(CalendarEvent master, DateTime occurrenceDate) {
  final occurrence = DateUtils.dateOnly(occurrenceDate);
  final masterStart = DateUtils.dateOnly(master.start.toLocal());
  if (occurrence == masterStart) return master;

  final span = epochDay(DateUtils.dateOnly(master.end.toLocal())) -
      epochDay(masterStart);
  return master.copyWith(
    start: _onDateKeepingTime(occurrence, master.start),
    end: _onDateKeepingTime(addDays(occurrence, span), master.end),
    bumpVersion: false,
  );
}

/// The inverse of [occurrenceView]: takes an [edited] event the user worked on
/// at [occurrenceDate] and moves it back onto the series anchor.
///
/// Only "all events" needs this — that scope rewrites the series row itself, so
/// a title-only edit must leave the anchor where it was, while a date change
/// must shift the whole series by the same number of days the user moved it.
CalendarEvent rebaseToAnchor(
  CalendarEvent edited,
  CalendarEvent master,
  DateTime occurrenceDate,
) {
  final masterStart = DateUtils.dateOnly(master.start.toLocal());
  final editedStart = DateUtils.dateOnly(edited.start.toLocal());
  final shift = recurrenceRebaseShiftDays(edited, occurrenceDate);
  final span =
      epochDay(DateUtils.dateOnly(edited.end.toLocal())) - epochDay(editedStart);

  final newStartDate = addDays(masterStart, shift);
  // [recurrenceEndDate] caps the pattern, so it is measured in the same frame
  // the occurrences are. Sliding the series without it silently truncates the
  // tail — move a series that ends Jun 30 forward a week and the last week of
  // occurrences stops being produced. Null is copyWith's "leave it alone", and
  // is what both the open-ended and the shift-free case want.
  final until = edited.recurrenceEndDate;
  final shiftedUntil = shift == 0 || until == null
      ? null
      : addDays(DateUtils.dateOnly(until.toLocal()), shift);

  return edited.copyWith(
    start: _onDateKeepingTime(newStartDate, edited.start),
    end: _onDateKeepingTime(addDays(newStartDate, span), edited.end),
    recurrenceEndDate: shiftedUntil,
    // An exception names an occurrence *in the pattern* ("the one on Mar 14"),
    // so once the pattern slides they have to slide with it. Left alone they
    // stop landing on any occurrence at all and every previously-deleted
    // occurrence reappears on the new dates.
    exceptionDates: shift == 0
        ? edited.exceptionDates
        : [
            for (final date in edited.exceptionDates)
              addDays(DateUtils.dateOnly(date.toLocal()), shift),
          ],
    bumpVersion: false,
  );
}

/// Whole days the user moved the occurrence at [occurrenceDate] by.
///
/// This is the amount an "all events" edit slides the entire series, so it is
/// also what the series' detached override rows have to move by to stay pinned
/// to the occurrences they replace.
int recurrenceRebaseShiftDays(CalendarEvent edited, DateTime occurrenceDate) =>
    epochDay(DateUtils.dateOnly(edited.start.toLocal())) -
    epochDay(DateUtils.dateOnly(occurrenceDate));
