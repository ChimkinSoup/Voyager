import 'package:fl_chart/fl_chart.dart';
import 'package:voyager/domain/models/analytics_models.dart';

/// Index into the *current* [spots] that [touchedX] refers to, or -1 when the
/// pointer isn't resting on the series.
///
/// Sparklines track the hovered period as an x coordinate rather than as a
/// stored index or a captured spot, and this resolves it fresh on every
/// build. Both alternatives go stale the moment the series is rebuilt:
///
///  * fl_chart's own `handleBuiltInTouches` snapshots the touched spot *by
///    value* and only replaces it on the next touch event — so saving an edit
///    from the keyboard, where the pointer never moves, leaves the tooltip's
///    text and position showing pre-edit data.
///  * A stored index breaks differently: recording a value can change how
///    many spots the interpolated series has, shifting every index after it,
///    so the tooltip would quietly point at the wrong day.
///
/// An x coordinate is the one identifier that survives both, because it's the
/// day offset the spot was generated for.
int touchedSpotIndex(List<FlSpot> spots, double? touchedX) {
  if (touchedX == null) return -1;
  for (var i = 0; i < spots.length; i++) {
    if (spots[i].x == touchedX) return i;
  }
  return -1;
}

/// The period a sparkline interaction at [x] refers to, and the record stored
/// for it (null when that period was never logged).
///
/// Hover labels and the edit popup must resolve through *this one function*
/// rather than reading the number off the chart, because a spot's `y` is not
/// the recorded value. The series returned by `interpolateConsecutive` carries
/// a Hermite-interpolated spot for every single day between recorded points,
/// and for weekly/monthly/yearly cadences all but one of a period's days are
/// synthesized — so `spot.y` only equals the stored number when the pointer
/// happens to rest exactly on a recorded day. Reading the tooltip from `spot.y`
/// and the edit field from the stored record is what made the two disagree.
///
/// Sharing the lookup also settles duplicates the same way for both: when two
/// records fall in one period (possible for non-daily cadences, whose records
/// need not share a periodStart day), whichever comes first in [values] wins
/// everywhere.
({DateTime periodStart, TrackerValue? value}) resolveSparklinePeriod({
  required double x,
  required DateTime from,
  required List<TrackerValue> values,
  required DateTime Function(DateTime) periodStartOf,
}) {
  final period = periodStartOf(from.add(Duration(days: x.round())));
  for (final value in values) {
    if (periodStartOf(value.periodStart) == period) {
      return (periodStart: period, value: value);
    }
  }
  return (periodStart: period, value: null);
}
