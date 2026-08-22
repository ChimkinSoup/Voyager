import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

// [EventRecurrence] used to be declared here. It now lives alongside
// [RecurrenceRule], which wraps it, and is re-exported so the many files that
// import calendar_models.dart for it keep compiling unchanged.
export 'package:voyager/domain/models/recurrence_rule.dart';

class Calendar extends SoftDeletable {
  const Calendar({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.name,
    this.colorValue,
  });

  final String name;
  final int? colorValue;

  Calendar copyWith({
    String? name,
    int? colorValue,
    DateTime? deletedAt,
    bool bumpVersion = true,
  }) {
    return Calendar(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: bumpVersion ? version + 1 : version,
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
    );
  }
}

class CalendarEvent extends SoftDeletable {
  const CalendarEvent({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
    super.deletedAt,
    required this.calendarId,
    required this.title,
    required this.start,
    required this.end,
    this.isFullDay = true,
    this.colorValue = 0xFF7C9EFF,
    this.notes = '',
    this.source = EventSource.local,
    this.externalId,
    this.recurrence = RecurrenceRule.none,
    this.recurrenceEndDate,
    this.exceptionDates = const [],
    this.recurrenceParentId,
    this.recurrenceDate,
  });

  final String calendarId;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool isFullDay;
  final int colorValue;
  final String notes;
  final EventSource source;
  final String? externalId;

  /// How this event repeats. [start] is the anchor; [end] − [start] is the span
  /// every occurrence carries, so a multi-day event repeats as a whole block.
  final RecurrenceRule recurrence;

  /// Inclusive last local date the pattern may produce an occurrence start on,
  /// or null for an open-ended series.
  ///
  /// Set by "this and all future events": truncating the original series here
  /// is what lets the split-off tail become its own event without the two
  /// overlapping.
  final DateTime? recurrenceEndDate;

  /// Occurrence start dates (date-only, local) that this series skips.
  ///
  /// A "this event only" delete adds the date here; a "this event only" edit
  /// adds it *and* writes a detached override row pointing back at this one.
  final List<DateTime> exceptionDates;

  /// For a detached override row: the id of the series it was split out of.
  final String? recurrenceParentId;

  /// For a detached override row: the occurrence start date in the parent
  /// series that this row replaces. Paired with [recurrenceParentId].
  final DateTime? recurrenceDate;

  /// Whether this row is a single occurrence detached from a series.
  bool get isRecurrenceOverride => recurrenceParentId != null;

  CalendarEvent copyWith({
    String? calendarId,
    String? title,
    DateTime? start,
    DateTime? end,
    bool? isFullDay,
    int? colorValue,
    String? notes,
    DateTime? deletedAt,
    RecurrenceRule? recurrence,
    DateTime? recurrenceEndDate,
    bool clearRecurrenceEndDate = false,
    List<DateTime>? exceptionDates,
    String? recurrenceParentId,
    bool clearRecurrenceParentId = false,
    DateTime? recurrenceDate,
    bool clearRecurrenceDate = false,
    bool bumpVersion = true,
  }) {
    return CalendarEvent(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: bumpVersion ? version + 1 : version,
      deletedAt: deletedAt ?? this.deletedAt,
      calendarId: calendarId ?? this.calendarId,
      title: title ?? this.title,
      start: start ?? this.start,
      end: end ?? this.end,
      isFullDay: isFullDay ?? this.isFullDay,
      colorValue: colorValue ?? this.colorValue,
      notes: notes ?? this.notes,
      source: source,
      externalId: externalId,
      recurrence: recurrence ?? this.recurrence,
      recurrenceEndDate: clearRecurrenceEndDate
          ? null
          : (recurrenceEndDate ?? this.recurrenceEndDate),
      exceptionDates: exceptionDates ?? this.exceptionDates,
      recurrenceParentId: clearRecurrenceParentId
          ? null
          : (recurrenceParentId ?? this.recurrenceParentId),
      recurrenceDate: clearRecurrenceDate
          ? null
          : (recurrenceDate ?? this.recurrenceDate),
    );
  }
}

enum EventSource { local, google }
