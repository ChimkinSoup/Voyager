import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/domain/models/recurrence_rule.dart';
import 'package:voyager/domain/services/calendar_event_import.dart';

const _custom = 0xFF123ABC;
final _palette = [...kTagPaletteDark, _custom];

CalendarEventImport _parse(String text) =>
    parseCalendarEventImport(text, palette: _palette);

void main() {
  test('reads every field, through a code fence and preamble', () {
    final result = _parse('''
Here you go:
```json
[
  {"title": "Dentist", "date": "2026-10-02", "start": "14:30", "end": "15:15",
   "color": "blue", "notes": "Bring card", "reminder": 60, "repeat": "yearly"},
  {"title": "Trip", "date": "2026-10-10", "endDate": "2026-10-12",
   "color": "#123abc"}
]
```
''');
    expect(result.errors, isEmpty);
    final [dentist, trip] = result.events;

    expect(dentist.isFullDay, isFalse);
    expect(dentist.start, DateTime(2026, 10, 2, 14, 30));
    expect(dentist.end, DateTime(2026, 10, 2, 15, 15));
    expect(
      dentist.colorValue,
      kTagPaletteDark[kTagPaletteNames.indexOf('Blue')],
    );
    expect(dentist.notes, 'Bring card');
    expect(dentist.reminderMinutes, 60);
    expect(dentist.recurrence.frequency, EventRecurrence.yearly);

    expect(trip.isFullDay, isTrue);
    expect(trip.start, DateTime(2026, 10, 10));
    expect(trip.end, DateTime(2026, 10, 12, 23, 59));
    expect(trip.colorValue, _custom);
    expect(trip.reminderMinutes, isNull);
    expect(trip.recurrence.repeats, isFalse);
  });

  test('a start with no end runs an hour; no color defers to the calendar', () {
    final [event] = _parse(
      '[{"title": "Call", "date": "2026-10-02", "start": "9:00"}]',
    ).events;
    expect(event.start, DateTime(2026, 10, 2, 9));
    expect(event.end, DateTime(2026, 10, 2, 10));
    expect(event.colorValue, isNull);
  });

  test('an overnight event ends on its endDate', () {
    final [event] = _parse(
      '[{"title": "Party", "date": "2026-10-02", "endDate": "2026-10-03",'
      ' "start": "22:00", "end": "01:00"}]',
    ).events;
    expect(event.end, DateTime(2026, 10, 3, 1));
  });

  test('brackets in the text around the list are stepped past', () {
    for (final text in [
      'Here are your events [2 total]:\n'
          '[{"title": "A", "date": "2026-10-02"}]',
      'Found [2] events:\n[{"title": "A", "date": "2026-10-02"}]',
      '```json\n[{"title": "A", "date": "2026-10-02"}]\n```\n'
          'Let me know if you want changes [or more].',
    ]) {
      final result = _parse(text);
      expect(result.errors, isEmpty, reason: text);
      expect(result.events.single.title, 'A');
    }
  });

  test('"24:00" ends at the next midnight', () {
    final [event] = _parse(
      '[{"title": "Late", "date": "2026-10-02", "start": "22:00",'
      ' "end": "24:00"}]',
    ).events;
    expect(event.end, DateTime(2026, 10, 3));
    expect(
      _parse('[{"title": "A", "date": "2026-10-02", "start": "24:00"}]').errors,
      [contains('"start" must be a 24-hour time')],
    );
  });

  test('a start in the hour the clocks skip keeps its length', () {
    // US spring-forward day; in a zone without the change it's a plain hour.
    final [event] = _parse(
      '[{"title": "A", "date": "2026-03-08", "start": "02:30",'
      ' "end": "03:30"}]',
    ).events;
    expect(event.end.difference(event.start), const Duration(hours: 1));
  });

  test('one bad event blocks the import and is named', () {
    final result = _parse('''[
      {"title": "Fine", "date": "2026-10-02"},
      {"title": "Late", "date": "2026-10-02", "start": "22:00", "end": "01:00"},
      {"title": "Odd", "date": "2026-02-30"},
      {"title": "Tinted", "date": "2026-10-02", "color": "Chartreuse"},
      {"title": "Timed", "date": "2026-10-02", "time": "10:00"},
      {"date": "2026-10-02"},
      {"title": "Conf", "date": "2026-10-02", "endDate": "2026-10-04",
       "start": "09:00"}
    ]''');
    expect(result.events, isEmpty);
    expect(result.errors, [
      startsWith('Event 2 ("Late"): "end" is not after "start"'),
      startsWith('Event 3 ("Odd"): "date" must be a real date'),
      startsWith('Event 4 ("Tinted"): "Chartreuse" is not one'),
      startsWith('Event 5 ("Timed"): unknown field "time"'),
      startsWith('Event 6: "title" is required'),
      startsWith('Event 7 ("Conf"): "endDate" with a "start" needs an "end"'),
    ]);
  });

  test('text without a JSON list says so', () {
    expect(_parse('Sorry, I could not find any events.').errors, [
      startsWith('No JSON list found'),
    ]);
    expect(_parse('[{"title": }]').errors, [startsWith('Not valid JSON')]);
    expect(_parse('[]').errors, ['The list has no events.']);
  });

  test('the prompt offers the palette by name and dates today', () {
    final prompt = calendarEventImportPrompt(
      palette: [kTagPaletteDark.first, _custom],
      today: DateTime(2026, 9, 24),
    );
    expect(prompt, contains('exactly one of: Rosewater, #123ABC.'));
    expect(prompt, contains('Today is Thursday, 2026-09-24'));
    expect(prompt.trimRight(), endsWith('Content:'));
  });
}
