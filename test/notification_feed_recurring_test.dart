import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/notification_models.dart';

/// Repeating events used to be judged on their anchor row's own start/end,
/// which for any series that has been running a while sits in the past — so
/// the whole series dropped out of the notification feed after its first
/// occurrence. These pin the occurrence-resolved behaviour.

CalendarEvent _event({
  String id = 'e1',
  required DateTime start,
  required DateTime end,
  RecurrenceRule recurrence = RecurrenceRule.none,
  DateTime? recurrenceEndDate,
  List<DateTime> exceptionDates = const [],
  DateTime? deletedAt,
}) {
  final stamp = DateTime.utc(2026, 1, 1);
  return CalendarEvent(
    id: id,
    createdAt: stamp,
    updatedAt: stamp,
    calendarId: 'cal',
    title: 'Standup',
    start: start,
    end: end,
    isFullDay: false,
    recurrence: recurrence,
    recurrenceEndDate: recurrenceEndDate,
    exceptionDates: exceptionDates,
    deletedAt: deletedAt,
  );
}

List<NotificationFeedItem> _feed(List<CalendarEvent> events, DateTime now) =>
    buildNotificationFeed(
      tasks: const [],
      events: events,
      bills: const [],
      now: now,
    );

void main() {
  const daily = RecurrenceRule(frequency: EventRecurrence.daily);
  const weekly = RecurrenceRule(frequency: EventRecurrence.weekly);

  test('a daily series whose anchor has passed still notifies', () {
    final now = DateTime(2026, 9, 7, 8, 0);
    final event = _event(
      start: DateTime(2026, 8, 8, 9, 0),
      end: DateTime(2026, 8, 8, 10, 0),
      recurrence: daily,
    );

    final feed = _feed([event], now);

    expect(feed, hasLength(1));
    expect(feed.single.urgency, NotificationUrgency.important);
    expect(feed.single.dueAt, DateTime(2026, 9, 7, 9, 0));
  });

  test('an occurrence more than 24h out is not shown', () {
    final now = DateTime(2026, 9, 7, 8, 0);
    final event = _event(
      start: DateTime(2026, 8, 3, 9, 0), // a Monday
      end: DateTime(2026, 8, 3, 10, 0),
      recurrence: weekly,
    );

    // 2026-09-07 is itself a Monday, so the next occurrence is today at 09:00.
    expect(_feed([event], now), hasLength(1));
    // A day later the next one is six days out.
    expect(_feed([event], DateTime(2026, 9, 8, 8, 0)), isEmpty);
  });

  test('an excepted occurrence is skipped, not surfaced', () {
    final now = DateTime(2026, 9, 7, 8, 0);
    final event = _event(
      start: DateTime(2026, 8, 8, 9, 0),
      end: DateTime(2026, 8, 8, 10, 0),
      recurrence: daily,
      exceptionDates: [DateTime(2026, 9, 7)],
    );

    final feed = _feed([event], now);

    // Tomorrow's occurrence is the next live one: 25 hours out, so nothing.
    expect(feed, isEmpty);
    // ...and it does surface once it comes inside the 24h window.
    final later = _feed([event], DateTime(2026, 9, 7, 10, 0));
    expect(later.single.dueAt, DateTime(2026, 9, 8, 9, 0));
    expect(later.single.urgency, NotificationUrgency.semi);
  });

  test('a series stops notifying past its recurrence end date', () {
    final now = DateTime(2026, 9, 7, 8, 0);
    final event = _event(
      start: DateTime(2026, 8, 8, 9, 0),
      end: DateTime(2026, 8, 8, 10, 0),
      recurrence: daily,
      recurrenceEndDate: DateTime(2026, 9, 1),
    );

    expect(_feed([event], now), isEmpty);
  });

  test('a multi-day occurrence still counts as under way', () {
    final now = DateTime(2026, 9, 7, 8, 0);
    // Three-day block repeating weekly; this week's began yesterday.
    final event = _event(
      start: DateTime(2026, 8, 9, 9, 0),
      end: DateTime(2026, 8, 11, 17, 0),
      recurrence: weekly,
    );

    final feed = _feed([event], now);

    expect(feed, hasLength(1));
    expect(feed.single.urgency, NotificationUrgency.important);
    expect(feed.single.dueAt, DateTime(2026, 9, 6, 9, 0));
  });

  test('each occurrence carries its own dismissal key', () {
    final today = _feed([
      _event(
        start: DateTime(2026, 8, 8, 9, 0),
        end: DateTime(2026, 8, 8, 10, 0),
        recurrence: daily,
      ),
    ], DateTime(2026, 9, 7, 8, 0)).single;
    final tomorrow = _feed([
      _event(
        start: DateTime(2026, 8, 8, 9, 0),
        end: DateTime(2026, 8, 8, 10, 0),
        recurrence: daily,
      ),
    ], DateTime(2026, 9, 8, 8, 0)).single;

    expect(today.dismissalKey, 'e1@2026-09-07|important');
    expect(tomorrow.dismissalKey, isNot(today.dismissalKey));
  });

  test('one-off events are unchanged', () {
    final now = DateTime(2026, 9, 7, 8, 0);
    final past = _event(
      id: 'past',
      start: DateTime(2026, 9, 6, 9, 0),
      end: DateTime(2026, 9, 6, 10, 0),
    );
    final soon = _event(
      id: 'soon',
      start: DateTime(2026, 9, 7, 8, 30),
      end: DateTime(2026, 9, 7, 9, 30),
    );

    final feed = _feed([past, soon], now);

    expect(feed.map((i) => i.id), ['soon']);
    expect(feed.single.occurrenceDate, isNull);
    expect(feed.single.dismissalKey, 'soon|important');
  });

  test('a deleted series never notifies', () {
    final event = _event(
      start: DateTime(2026, 8, 8, 9, 0),
      end: DateTime(2026, 8, 8, 10, 0),
      recurrence: daily,
      deletedAt: DateTime.utc(2026, 9, 1),
    );

    expect(_feed([event], DateTime(2026, 9, 7, 8, 0)), isEmpty);
  });
}
