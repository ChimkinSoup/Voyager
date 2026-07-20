import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';

void main() {
  test('trackerValueId depends only on the calendar date, not time of day', () {
    final morning = DateTime(2026, 7, 1, 8, 30);
    final night = DateTime(2026, 7, 1, 23, 59);
    expect(
      trackerValueId('tracker-1', morning),
      trackerValueId('tracker-1', night),
    );
  });

  test('trackerValueId is the same across cadences sharing a canonical date',
      () {
    // A daily value on Jan 1, a monthly value anchored to Jan 1, and a yearly
    // value anchored to Jan 1 must all resolve to one row for a given tracker.
    final janFirst = DateTime(2026, 1, 1);
    final id = trackerValueId('tracker-1', janFirst);
    expect(id, 'tracker-1_2026-01-01');
  });

  test('trackerValueId distinguishes different dates', () {
    expect(
      trackerValueId('tracker-1', DateTime(2026, 7, 1)),
      isNot(trackerValueId('tracker-1', DateTime(2026, 7, 2))),
    );
  });

  test('trackerValueId zero-pads month and day', () {
    expect(
      trackerValueId('t', DateTime(2026, 3, 5)),
      't_2026-03-05',
    );
  });
}
