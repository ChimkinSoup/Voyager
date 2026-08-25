// Invariants the analytics feature's writes and reads depend on.
//
// Each group covers something that used to be expressible-but-wrong: a range
// whose bounds were the wrong way round, a `copyWith` that could not say
// "clear this", and a shading value that could exceed the alpha it feeds.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/services/analytics_service.dart';

StatisticTracker _tracker({
  int? integerCap,
  int defaultInt = 0,
  TrackerType type = TrackerType.integer,
}) {
  final epoch = DateTime.utc(2026);
  return StatisticTracker(
    id: 'tracker-1',
    name: 'Pushups',
    type: type,
    cadence: TrackerCadence.daily,
    integerCap: integerCap,
    defaultInt: defaultInt,
    createdAt: epoch,
    updatedAt: epoch,
  );
}

TrackerValue _value({int? intValue, bool? boolValue, String? enumValue}) {
  final epoch = DateTime.utc(2026);
  return TrackerValue(
    id: 'value-1',
    trackerId: 'tracker-1',
    periodStart: epoch,
    intValue: intValue,
    boolValue: boolValue,
    enumValue: enumValue,
    createdAt: epoch,
    updatedAt: epoch,
  );
}

void main() {
  group('clampToTrackerRange', () {
    test('confines a reading to an ordinary range', () {
      final tracker = _tracker(defaultInt: 5, integerCap: 20);

      expect(clampToTrackerRange(1, tracker), 5);
      expect(clampToTrackerRange(12, tracker), 12);
      expect(clampToTrackerRange(99, tracker), 20);
    });

    test('leaves a capless tracker alone', () {
      expect(clampToTrackerRange(9999, _tracker(defaultInt: 5)), 9999);
    });

    // The dialog accepted "Lower limit" above "Upper limit" for a long time,
    // and `num.clamp` throws on an inverted range rather than returning
    // anything. Three call sites read it — one of them during build, which
    // left the value editor's subtree throwing every frame instead of showing.
    test('orders an inverted range instead of throwing', () {
      final inverted = _tracker(defaultInt: 50, integerCap: 10);

      expect(clampToTrackerRange(5, inverted), 10);
      expect(clampToTrackerRange(30, inverted), 30);
      expect(clampToTrackerRange(99, inverted), 50);
    });

    test('a degenerate range still resolves', () {
      final pinned = _tracker(defaultInt: 7, integerCap: 7);

      expect(clampToTrackerRange(1, pinned), 7);
      expect(clampToTrackerRange(99, pinned), 7);
    });
  });

  group('TrackerValue.copyWith', () {
    test('an omitted field is kept', () {
      final original = _value(intValue: 12);

      expect(original.copyWith().intValue, 12);
      expect(original.copyWith(boolValue: true).intValue, 12);
    });

    // `x ?? this.x` made null mean "keep", so there was no way to say "clear".
    // That is what made a tombstone permanent: `softDeleteValue` could set one
    // but nothing could lift it.
    test('an explicit null clears the field', () {
      final original = _value(intValue: 12);

      expect(original.copyWith(intValue: null).intValue, isNull);
    });

    test('an explicit null lifts a tombstone', () {
      final deleted = _value(intValue: 3).copyWith(deletedAt: DateTime.utc(2026));
      expect(deleted.deletedAt, isNotNull);

      expect(deleted.copyWith(deletedAt: null).deletedAt, isNull);
      expect(deleted.copyWith().deletedAt, isNotNull);
    });

    test('a write is a new revision by default', () {
      final original = _value(intValue: 1);

      expect(original.copyWith(intValue: 2).version, original.version + 1);
      expect(
        original.copyWith(intValue: 2, bumpVersion: false).version,
        original.version,
      );
    });
  });

  group('StatisticTracker.copyWith', () {
    test('an omitted nullable field is kept', () {
      final starred = _tracker().copyWith(starred: true);

      expect(starred.copyWith(sortOrder: 3).starred, isTrue);
      expect(starred.copyWith(sortOrder: 3).deletedAt, isNull);
    });

    test('an explicit null lifts a tombstone', () {
      final deleted = _tracker().copyWith(deletedAt: DateTime.utc(2026));

      expect(deleted.copyWith(deletedAt: null).deletedAt, isNull);
      expect(deleted.copyWith(starred: true).deletedAt, isNotNull);
    });

    test('an explicit null clears the tracking style', () {
      final styled = _tracker().copyWith(
        trackingStyle: TrackerStyle.consecutive,
      );
      expect(styled.trackingStyle, TrackerStyle.consecutive);

      expect(styled.copyWith(trackingStyle: null).trackingStyle, isNull);
      expect(styled.copyWith(starred: true).trackingStyle,
          TrackerStyle.consecutive);
    });
  });

  group('heatmapIntensity', () {
    final analytics = AnalyticsService();

    double intensityFor(int reading, StatisticTracker tracker) =>
        analytics.heatmapIntensity(
          type: tracker.type,
          value: _value(intValue: reading),
          tracker: tracker,
          maxInPeriod: 10,
          // Supplied so the "only one integer ever recorded" branch, which
          // reports a flat 0.5, stays out of the way.
          hasSingleIntValue: false,
        );

    test('scales a reading against the cap', () {
      final tracker = _tracker(integerCap: 20);

      expect(intensityFor(0, tracker), 0);
      expect(intensityFor(10, tracker), 0.5);
      expect(intensityFor(20, tracker), 1);
    });

    // Consumers turn this straight into `0.15 + 0.85 * intensity` and hand it
    // to `Color.withValues`, which does not range-check. A reading above the
    // cap — from a lowered integerCap, or from a max drawn from outside the
    // window being rendered — flattened the whole upper range to one saturated
    // shade, so a paged-back year read as uniformly maxed.
    test('never exceeds 1, whatever the reading', () {
      final tracker = _tracker(integerCap: 20);

      expect(intensityFor(40, tracker), 1);
      expect(intensityFor(100000, tracker), 1);
    });

    test('never falls below 0', () {
      expect(intensityFor(-50, _tracker(integerCap: 20)), 0);
    });
  });
}
