import 'dart:convert';

import 'package:voyager/core/utils/journal_tags.dart'
    show kTagPaletteDark, kTagPaletteNames;
import 'package:voyager/domain/models/recurrence_rule.dart';

/// One event read out of a pasted import, not yet written anywhere.
class ImportedCalendarEvent {
  const ImportedCalendarEvent({
    required this.title,
    required this.start,
    required this.end,
    required this.isFullDay,
    this.colorValue,
    this.notes = '',
    this.reminderMinutes,
    this.recurrence = RecurrenceRule.none,
  });

  final String title;
  final DateTime start;
  final DateTime end;
  final bool isFullDay;

  /// Null when the import named no color: the target calendar's applies.
  final int? colorValue;
  final String notes;

  /// Minutes before the event the bell rings, or null for no bell.
  final int? reminderMinutes;
  final RecurrenceRule recurrence;
}

/// A pasted import read in full: the events, or why it can't be imported.
/// Never both — one bad event holds back the rest, so fixing it and pasting
/// again can't import the good ones twice.
class CalendarEventImport {
  const CalendarEventImport({this.events = const [], this.errors = const []});

  final List<ImportedCalendarEvent> events;
  final List<String> errors;
}

/// What the import format calls [color]: the ramp's name for it, else its hex.
String importColorLabel(int color) {
  final index = kTagPaletteDark.indexOf(color);
  if (index >= 0) return kTagPaletteNames[index];
  final rgb = (color & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
  return '#${rgb.toUpperCase()}';
}

const _repeats = {
  'daily': EventRecurrence.daily,
  'weekly': EventRecurrence.weekly,
  'monthly': EventRecurrence.monthly,
  'yearly': EventRecurrence.yearly,
};

const _fields = {
  'title',
  'date',
  'endDate',
  'start',
  'end',
  'color',
  'notes',
  'reminder',
  'repeat',
};

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// The prompt a user hands an AI along with their content, so its reply can
/// be pasted straight into [parseCalendarEventImport]. [palette] is the
/// user's color palette, [today] anchors relative dates like "next Friday".
String calendarEventImportPrompt({
  required List<int> palette,
  required DateTime today,
}) {
  final colors = palette.map(importColorLabel).join(', ');
  final date = _formatDate(today);
  return '''
Turn the content below into events for my calendar app. Reply with only a JSON array, no commentary, where each item is an object with these fields:

- "title" (required): short event name.
- "date" (required): the day it starts, "YYYY-MM-DD".
- "endDate": the last day, "YYYY-MM-DD". Only for events that run past the day they start, including ones that end after midnight.
- "start": start time, 24-hour "HH:MM". Leave it out for an all-day event.
- "end": end time, 24-hour "HH:MM". Only alongside "start"; defaults to one hour after it. Required when "start" and "endDate" are both given.
- "color": exactly one of: $colors. Leave it out to use the calendar's color.
- "notes": extra details such as location, links or agenda. Plain text; use \\n for line breaks.
- "reminder": minutes before the event to be notified, e.g. 0, 15, 60 or 1440. For an all-day event it counts back from 9:00 AM that day. Leave it out for no reminder.
- "repeat": "daily", "weekly", "monthly" or "yearly". Leave it out for a one-off event.

Only include optional fields that the content supports or that I ask for. Today is ${_weekdays[today.weekday - 1]}, $date; use it to resolve relative dates.

Content:
''';
}

/// Reads the AI's reply [text] as events. Anything around the JSON array —
/// a ``` fence, a sentence of preamble — is ignored. A color must be one of
/// [palette], by [importColorLabel], case-insensitive.
CalendarEventImport parseCalendarEventImport(
  String text, {
  required List<int> palette,
}) {
  final opens = [
    for (var i = text.indexOf('['); i >= 0; i = text.indexOf('[', i + 1)) i,
  ];
  final closes = [
    for (var i = text.lastIndexOf(']'); i > 0; i = text.lastIndexOf(']', i - 1))
      if (opens.isNotEmpty && i > opens.first) i,
  ];
  if (closes.isEmpty) {
    return const CalendarEventImport(
      errors: ['No JSON list found. The pasted text should start with "[".'],
    );
  }
  // Brackets in a sentence around the list ("[2 events]", "[or more]") are
  // stepped past: the widest span that decodes as a list wins, trying later
  // ends first so a preamble's "[2]" can't pass for the list.
  List<dynamic>? decoded;
  search:
  for (final close in closes) {
    for (final open in opens) {
      if (open > close) break;
      try {
        final value = jsonDecode(text.substring(open, close + 1));
        if (value is List) {
          decoded = value;
          break search;
        }
      } on FormatException {
        continue;
      }
    }
  }
  if (decoded == null) {
    try {
      jsonDecode(text.substring(opens.first, closes.first + 1));
    } on FormatException catch (e) {
      return CalendarEventImport(errors: ['Not valid JSON: ${e.message}.']);
    }
    return const CalendarEventImport(errors: ['Expected a JSON list.']);
  }

  final colors = {
    for (final color in palette) importColorLabel(color).toLowerCase(): color,
  };
  final events = <ImportedCalendarEvent>[];
  final errors = <String>[];
  for (var i = 0; i < decoded.length; i++) {
    final item = decoded[i];
    final title = item is Map ? item['title'] : null;
    final label = title is String && title.trim().isNotEmpty
        ? 'Event ${i + 1} ("${title.trim()}")'
        : 'Event ${i + 1}';
    if (item is! Map<String, dynamic>) {
      errors.add('$label: expected an object.');
      continue;
    }
    try {
      events.add(_parseEvent(item, colors));
    } on FormatException catch (e) {
      errors.add('$label: ${e.message}');
    }
  }
  if (errors.isNotEmpty) return CalendarEventImport(errors: errors);
  if (events.isEmpty) {
    return const CalendarEventImport(errors: ['The list has no events.']);
  }
  return CalendarEventImport(events: events);
}

ImportedCalendarEvent _parseEvent(
  Map<String, dynamic> item,
  Map<String, int> colors,
) {
  for (final key in item.keys) {
    if (!_fields.contains(key)) throw FormatException('unknown field "$key".');
  }

  final title = _string(item, 'title')?.trim() ?? '';
  if (title.isEmpty) throw const FormatException('"title" is required.');

  final date = _date(item, 'date');
  if (date == null) throw const FormatException('"date" is required.');
  final endDate = _date(item, 'endDate') ?? date;
  if (endDate.isBefore(date)) {
    throw const FormatException('"endDate" is before "date".');
  }

  final startTime = _time(item, 'start');
  final endTime = _time(item, 'end', allowMidnight: true);
  if (startTime == null && endTime != null) {
    throw const FormatException('"end" needs a "start".');
  }
  if (startTime != null && endTime == null && endDate != date) {
    throw const FormatException('"endDate" with a "start" needs an "end".');
  }

  final DateTime start;
  var end = _at(endDate, endTime ?? const Duration(hours: 23, minutes: 59));
  if (startTime == null) {
    start = date;
  } else if (endTime == null) {
    start = _at(date, startTime);
    end = start.add(const Duration(hours: 1));
  } else {
    start = _at(date, startTime);
    // Compared as wall clocks: a start in the hour the clocks skip lands an
    // hour later, which could otherwise meet or pass an end that was fine.
    final length = _wall(endDate, endTime).difference(_wall(date, startTime));
    if (length <= Duration.zero) {
      throw const FormatException(
        '"end" is not after "start". An event past midnight needs "endDate".',
      );
    }
    if (!end.isAfter(start)) end = start.add(length);
  }

  final colorName = _string(item, 'color');
  final color = colorName == null ? null : colors[colorName.toLowerCase()];
  if (colorName != null && color == null) {
    throw FormatException('"$colorName" is not one of the palette colors.');
  }

  final reminder = item['reminder'];
  if (reminder != null && (reminder is! int || reminder < 0)) {
    throw const FormatException('"reminder" must be whole minutes, 0 or more.');
  }

  final repeatName = _string(item, 'repeat');
  final repeat = repeatName == null ? null : _repeats[repeatName.toLowerCase()];
  if (repeatName != null && repeat == null) {
    throw FormatException(
      '"repeat" must be daily, weekly, monthly or yearly, not "$repeatName".',
    );
  }

  return ImportedCalendarEvent(
    title: title,
    start: start,
    end: end,
    isFullDay: startTime == null,
    colorValue: color,
    notes: _string(item, 'notes')?.trim() ?? '',
    reminderMinutes: reminder as int?,
    recurrence: repeat == null
        ? RecurrenceRule.none
        : RecurrenceRule(frequency: repeat),
  );
}

String? _string(Map<String, dynamic> item, String key) {
  final value = item[key];
  if (value == null || value is String) return value as String?;
  throw FormatException('"$key" must be text.');
}

final _datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final _timePattern = RegExp(r'^(\d{1,2}):(\d{2})$');

/// [key] as a local date-only [DateTime], or null when absent.
DateTime? _date(Map<String, dynamic> item, String key) {
  final value = _string(item, key);
  if (value == null) return null;
  final match = _datePattern.firstMatch(value.trim());
  if (match != null) {
    final [y, m, d] = [for (var g = 1; g <= 3; g++) int.parse(match[g]!)];
    final date = DateTime(y, m, d);
    // DateTime rolls Feb 30 over into March rather than rejecting it.
    if (date.month == m && date.day == d) return date;
  }
  throw FormatException('"$key" must be a real date as YYYY-MM-DD.');
}

/// [key] as an offset from midnight, or null when absent. [allowMidnight]
/// also takes "24:00", the midnight that ends the day.
Duration? _time(
  Map<String, dynamic> item,
  String key, {
  bool allowMidnight = false,
}) {
  final value = _string(item, key);
  if (value == null) return null;
  final match = _timePattern.firstMatch(value.trim());
  if (match != null) {
    final hours = int.parse(match[1]!);
    final minutes = int.parse(match[2]!);
    if ((hours < 24 && minutes < 60) ||
        (allowMidnight && hours == 24 && minutes == 0)) {
      return Duration(hours: hours, minutes: minutes);
    }
  }
  throw FormatException('"$key" must be a 24-hour time as HH:MM.');
}

/// Wall-clock [time] on [day]. Not `day.add(time)`, which is an hour out on
/// the days the clocks change. An hour of 24 rolls over to the next day.
DateTime _at(DateTime day, Duration time) =>
    DateTime(day.year, day.month, day.day, time.inHours, time.inMinutes % 60);

/// [_at] in UTC, which has no clock changes: for measuring wall-clock spans.
DateTime _wall(DateTime day, Duration time) => DateTime.utc(
  day.year,
  day.month,
  day.day,
  time.inHours,
  time.inMinutes % 60,
);

String _formatDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
