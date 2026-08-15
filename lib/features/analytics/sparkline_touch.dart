import 'package:fl_chart/fl_chart.dart';
import 'package:voyager/core/utils/calendar_days.dart';
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

/// The single x on the curve that every hover inside [rawX]'s period resolves
/// to, given the [spots] currently drawn.
///
/// `interpolateConsecutive` emits a spot for *every day* in the window, so one
/// weekly/monthly/yearly period spans dozens of them, each carrying its own
/// interpolated y. Read literally that meant a period had as many readings as
/// it had days: sweeping across an unlogged February printed a different number
/// every few pixels, and drifting a little off a logged January's knot swapped
/// its record out for a nearby interpolated value. Collapsing the period onto
/// one x gives it one reading. The curve keeps all of its spots and stays
/// exactly as smooth — this only decides which of them a pointer lands on.
///
/// Which period [rawX] belongs to is decided by proximity, not containment:
/// each period owns the span reaching halfway to the period on either side of
/// it, so two neighbours' zones meet exactly midway between them and a period
/// has as much room on its left as on its right. Containment — "which period
/// is this day inside?" — gave a period the whole of its own span to the right
/// and nothing at all to the left, so a pointer a pixel short of February's
/// first day still read January. [periodStarts] supplies those boundaries: the
/// x of the first day of every period the window covers, ascending. It should
/// include the period that opens *before* the window as well, since the
/// window's leading days belong to it.
///
/// The chosen x is the record's own knot day when the period was logged, so a
/// logged period reads as the number you entered; otherwise the period's first
/// day, the same day a record filed under it would occupy.
///
/// Result is clamped into [spots]' own range: the window's first period usually
/// starts before the window does, and there is no spot out there to land on.
double sparklinePeriodAnchorX({
  required double rawX,
  required DateTime from,
  required List<TrackerValue> values,
  required DateTime Function(DateTime) periodStartOf,
  required List<FlSpot> spots,
  required List<double> periodStarts,
}) {
  if (spots.isEmpty) return rawX;
  // The nearest period start *is* the period whose centred zone holds rawX:
  // zones split midway between starts, so the nearer start always wins. Dead
  // on a boundary the later period takes it (`<=`, over an ascending list),
  // the way `.round()` sends a half upwards.
  var startX = rawX;
  var bestDistance = double.infinity;
  for (final start in periodStarts) {
    final distance = (start - rawX).abs();
    if (distance <= bestDistance) {
      bestDistance = distance;
      startX = start;
    }
  }
  // Calendar days, not a 24h-per-day [Duration] — see [resolveSparklinePeriod]
  // for why that distinction matters here.
  final period = periodStartOf(addCalendarDays(from, startX.round()));
  var day = calendarDaysBetween(from, period).toDouble();
  for (final value in values) {
    if (periodStartOf(value.periodStart) == period) {
      // The knot `interpolateConsecutive` pinned this record to. Landing on it
      // is what makes [resolveSparklinePeriod] report `onRecordedDay`, and so
      // what makes the bubble print the record rather than the curve.
      day = calendarDaysBetween(from, value.periodStart).toDouble();
      break;
    }
  }
  final first = spots.first.x;
  final last = spots.last.x;
  if (day < first) return first;
  if (day > last) return last;
  return day;
}

/// The period a sparkline interaction at [x] refers to, and the record stored
/// for it (null when that period was never logged).
///
/// Hover labels and the edit popup must resolve the *record* through this one
/// function rather than reading it off the chart, because a spot's `y` is not
/// necessarily the recorded value. The series returned by
/// `interpolateConsecutive` carries a Hermite-interpolated spot for every
/// single day between recorded points, and for weekly/monthly/yearly cadences
/// all but one of a period's days are synthesized — so `spot.y` only equals the
/// stored number when the pointer happens to rest exactly on a recorded day.
///
/// The hover bubble does also print `spot.y`, but only where this function
/// returns a null value, and only marked as an estimate — see
/// `_sparklineValueReading`. What it must never do is pass an interpolated `y`
/// off as a record, which is what made the tooltip and the edit field disagree.
///
/// Sharing the lookup also settles duplicates the same way for both: when two
/// records fall in one period (possible for non-daily cadences, whose records
/// need not share a periodStart day), whichever comes first in [values] wins
/// everywhere.
/// [onRecordedDay] tells the two apart: it is true only when [x] lands on the
/// very day the record was filed under — the day the curve is pinned to. Every
/// other day in the period sits *on the interpolated stretch* between that knot
/// and the next one, so the number under the pointer there is the curve's, not
/// the record's. Reading the record on those days is what made a weekly or
/// monthly tracker print one flat figure across a visibly climbing curve; the
/// hover bubble uses this to fall back to the interpolated value instead, while
/// the editor keeps opening on [value] regardless.
({DateTime periodStart, TrackerValue? value, bool onRecordedDay})
resolveSparklinePeriod({
  required double x,
  required DateTime from,
  required List<TrackerValue> values,
  required DateTime Function(DateTime) periodStartOf,
}) {
  // Calendar days, not a 24h-per-day [Duration] — see [addCalendarDays]. The
  // x axis counts days on the calendar, and adding elapsed time instead lands
  // an hour short across a DST fall-back, flooring to the previous day and
  // resolving the whole hover to the period on the left.
  final day = x.round();
  final period = periodStartOf(addCalendarDays(from, day));
  for (final value in values) {
    if (periodStartOf(value.periodStart) == period) {
      return (
        periodStart: period,
        value: value,
        // The knot's day index, matched the same way
        // [AnalyticsService.interpolateConsecutive] places it.
        onRecordedDay: calendarDaysBetween(from, value.periodStart) == day,
      );
    }
  }
  return (periodStart: period, value: null, onRecordedDay: false);
}

/// What a sparkline's hover bubble prints for one point, given the label its
/// stored record produced ([storedLabel], null when the period was never
/// logged) and the curve's own value there ([interpolatedY]).
///
/// A logged period reads as its record. An unlogged one falls back to the
/// interpolated number, flagged via [isEstimate] — see the caller
/// (`_sparklineValueReading`) for why that fallback exists at all.
///
/// [isEstimate] carries no marker in the string itself; the caller greys the
/// text instead, in the same shade the dash uses for a never-logged period.
/// The grey is what says "not your data" — which is the same thing the empty
/// edit field says when you click through, so the two agree.
///
/// [interpolates] is false for trackers with no continuous curve to read
/// (boolean, enum), which keep the null that renders as a greyed dash.
({String? label, bool isEstimate}) sparklineValueReading({
  required String? storedLabel,
  required bool interpolates,
  required double? interpolatedY,
}) {
  if (storedLabel != null) return (label: storedLabel, isEstimate: false);
  if (!interpolates || interpolatedY == null) {
    return (label: null, isEstimate: false);
  }
  // One decimal, dropping a trailing ".0" so a reading that lands on a whole
  // number reads as "6" rather than "6.0". Rounded first, so the ".0" test is
  // on the *displayed* value: 5.98 shows "6" (not "5.98..." → "6.0"), and only
  // a value that truly rounds to a whole number loses its decimal.
  final rounded = (interpolatedY * 10).roundToDouble() / 10;
  final label = rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
  return (label: label, isEstimate: true);
}
