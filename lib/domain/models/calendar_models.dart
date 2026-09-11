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
    this.overlayCalendarIds = const [],
  });

  final String name;
  final int? colorValue;

  /// Other calendars whose events are drawn while this one is open.
  ///
  /// A display union, not a copy: the events keep their own `calendarId` and
  /// colour, and opening one of those calendars still shows only its own
  /// events. Flat — an overlay's own overlays are never followed. Ids that are
  /// this calendar, unknown or soft-deleted are ignored when read; see
  /// [visibleOverlayCalendarIds].
  final List<String> overlayCalendarIds;

  Calendar copyWith({
    String? name,
    int? colorValue,
    List<String>? overlayCalendarIds,
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
      overlayCalendarIds: overlayCalendarIds ?? this.overlayCalendarIds,
    );
  }
}

/// [ids] as they are stored on the calendar [hostId]: without the host itself
/// and without repeats, first occurrence kept.
List<String> normalizeOverlayCalendarIds(String hostId, Iterable<String> ids) {
  final seen = <String>{hostId};
  return [
    for (final id in ids)
      if (seen.add(id)) id,
  ];
}

/// The calendars [hostId] actually overlays, out of the live [calendars]: its
/// overlay list minus itself and any id that is not a live calendar. Empty
/// when the host is not among [calendars].
List<String> visibleOverlayCalendarIds(
  String hostId,
  List<Calendar> calendars,
) {
  final host = calendars.where((c) => c.id == hostId).firstOrNull;
  if (host == null) return const [];
  final live = {
    for (final calendar in calendars)
      if (calendar.deletedAt == null) calendar.id,
  };
  return [
    for (final id in normalizeOverlayCalendarIds(
      hostId,
      host.overlayCalendarIds,
    ))
      if (live.contains(id)) id,
  ];
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
