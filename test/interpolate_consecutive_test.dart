import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/services/analytics_service.dart';

void main() {
  final analytics = AnalyticsService();
  final from = DateTime(2026, 1, 1);

  TrackerValue value(int dayOffset, int intValue) {
    final now = utcNow();
    return TrackerValue(
      id: newId(),
      createdAt: now,
      updatedAt: now,
      trackerId: 't',
      periodStart: from.add(Duration(days: dayOffset)),
      intValue: intValue,
    );
  }

  // A flat stretch, a steep climb to the cap, then a plateau at the cap. The
  // Catmull-Rom tangent at the top of the climb still points sharply upward
  // while the plateau's does not, so the segment between them bulges above
  // the cap.
  final spiky = [
    value(0, 0),
    value(10, 0),
    value(20, 10),
    value(30, 10),
  ];

  test('interpolated values stay within [0, cap] when a cap is set', () {
    final spots = analytics.interpolateConsecutive(
      values: spiky,
      from: from,
      to: from.add(const Duration(days: 30)),
      maxDays: 30,
      upperBound: 10,
    );

    expect(spots, isNotEmpty);
    for (final spot in spots) {
      expect(spot.y, inInclusiveRange(0.0, 10.0), reason: 'day ${spot.x}');
    }
  });

  test('without a cap the spline is only bounded below', () {
    final spots = analytics.interpolateConsecutive(
      values: spiky,
      from: from,
      to: from.add(const Duration(days: 30)),
      maxDays: 30,
    );

    expect(spots.every((s) => s.y >= 0), isTrue);
    // Guards the test above against becoming vacuous: this data really does
    // overshoot, so the cap is what's keeping the first case in range.
    expect(spots.any((s) => s.y > 10), isTrue);
  });
}
