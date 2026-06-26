import 'package:voyager/domain/models/soft_deletable.dart';

enum EventRecurrence { none, daily, weekly, monthly, yearly }

class CalendarEvent extends SoftDeletable {
  const CalendarEvent({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required this.title,
    required this.start,
    required this.end,
    this.isFullDay = true,
    this.colorValue = 0xFF7C9EFF,
    this.notes = '',
    this.source = EventSource.local,
    this.externalId,
    this.recurrence = EventRecurrence.none,
  });

  final String title;
  final DateTime start;
  final DateTime end;
  final bool isFullDay;
  final int colorValue;
  final String notes;
  final EventSource source;
  final String? externalId;
  final EventRecurrence recurrence;

  CalendarEvent copyWith({
    String? title,
    DateTime? start,
    DateTime? end,
    bool? isFullDay,
    int? colorValue,
    String? notes,
    DateTime? deletedAt,
    EventRecurrence? recurrence,
  }) {
    return CalendarEvent(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
      title: title ?? this.title,
      start: start ?? this.start,
      end: end ?? this.end,
      isFullDay: isFullDay ?? this.isFullDay,
      colorValue: colorValue ?? this.colorValue,
      notes: notes ?? this.notes,
      source: source,
      externalId: externalId,
      recurrence: recurrence ?? this.recurrence,
    );
  }
}

enum EventSource { local, google }
