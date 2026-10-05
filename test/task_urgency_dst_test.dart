// Task urgency counts calendar days, not elapsed time. Differencing two local
// midnights across a spring-forward gives 23 hours, which `inDays` truncated
// to 0: on that day the next day's task was "important" (due today), not
// "semi" (tomorrow) (BUG-040).
//
// Mar 14 2027 is a US spring-forward, where the bug was found. The assertions
// hold in any zone, DST or not: a task due tomorrow is semi-important.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/todo_models.dart';

TodoTask _dueOn(DateTime localDay) {
  final created = DateTime.utc(2027);
  return TodoTask(
    id: 't',
    listId: 'l',
    title: 'task',
    // Due dates are stored in UTC.
    dueDate: DateTime(localDay.year, localDay.month, localDay.day, 9).toUtc(),
    createdAt: created,
    updatedAt: created,
  );
}

void main() {
  test("tomorrow's task is semi-important across a spring-forward", () {
    expect(
      evaluateTaskUrgency(
        _dueOn(DateTime(2027, 3, 15)),
        DateTime(2027, 3, 14, 10),
      ),
      NotificationUrgency.semi,
    );
  });

  test('tomorrow is still semi-important across a fall-back', () {
    expect(
      evaluateTaskUrgency(
        _dueOn(DateTime(2026, 11, 2)),
        DateTime(2026, 11, 1, 10),
      ),
      NotificationUrgency.semi,
    );
  });

  test("yesterday's and today's tasks are important", () {
    final now = DateTime(2027, 3, 15, 10);
    expect(
      evaluateTaskUrgency(_dueOn(DateTime(2027, 3, 14)), now),
      NotificationUrgency.important,
    );
    expect(
      evaluateTaskUrgency(_dueOn(DateTime(2027, 3, 15)), now),
      NotificationUrgency.important,
    );
  });

  test('two days out is not shown', () {
    expect(
      evaluateTaskUrgency(
        _dueOn(DateTime(2027, 3, 16)),
        DateTime(2027, 3, 14, 10),
      ),
      isNull,
    );
  });
}
