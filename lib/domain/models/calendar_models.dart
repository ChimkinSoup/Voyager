import 'package:voyager/domain/models/soft_deletable.dart';

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
  });

  final String title;
  final DateTime start;
  final DateTime end;
  final bool isFullDay;
  final int colorValue;
  final String notes;
  final EventSource source;
  final String? externalId;

  CalendarEvent copyWith({
    String? title,
    DateTime? start,
    DateTime? end,
    bool? isFullDay,
    int? colorValue,
    String? notes,
    DateTime? deletedAt,
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
    );
  }
}

enum EventSource { local, google }
