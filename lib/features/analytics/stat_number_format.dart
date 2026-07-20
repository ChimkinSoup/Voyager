import 'dart:math' as math;

/// Pure number-formatting used by the analytics charts and stat chips. Split
/// out of the page so the rounding edges — tier promotion, digit budget,
/// "nice" axis steps — can be unit tested without pumping a widget tree.

/// Magnitude suffixes, one per power of a thousand. Ends at exa: an `int`
/// tops out around 9.2E, so nothing past it is reachable.
const magnitudeSuffixes = ['', 'k', 'M', 'B', 'T', 'P', 'E'];

/// Compact display label for a statistic — never more than three digits, so
/// it can't outgrow an axis gutter or a stat chip.
///
/// Rounding *the axis step* to a clean number doesn't make every *tick*
/// clean: a step of 500 still produces 1500, and a step of 300 produces 1200.
/// So this has to render fractional thousands rather than assume them away —
/// 1500 reads as "1.5k".
///
/// The digit budget is spent from the left: a mantissa of 100 or more has no
/// room for a decimal ("124k"), below that it gets one ("12.5k", "1.5k"), and
/// a trailing ".0" is dropped so a clean thousand reads "1k" rather than
/// "1.0k".
String compactNumberLabel(num value) {
  final n = value.round();
  if (n == 0) return '0';
  final sign = n < 0 ? '-' : '';
  var mantissa = n.abs().toDouble();
  var tier = 0;
  while (mantissa >= 1000 && tier < magnitudeSuffixes.length - 1) {
    mantissa /= 1000;
    tier++;
  }

  var text = (tier == 0 || mantissa >= 100)
      ? mantissa.toStringAsFixed(0)
      : mantissa.toStringAsFixed(1);
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);

  // Rounding can carry past the tier it was computed in — 999_500 divides to
  // 999.5k, which rounds to "1000k". Promote instead of printing four digits.
  if (double.parse(text) >= 1000 && tier < magnitudeSuffixes.length - 1) {
    tier++;
    text = '1';
  }
  return '$sign$text${magnitudeSuffixes[tier]}';
}

/// Width to reserve for a chart's Y-axis gutter so the widest tick label —
/// always the topmost one — fits on one line, including the gap held by
/// `SideTitleWidget.space`.
///
/// Digits are tabular in the fonts this app ships, so a per-character advance
/// of ~0.62em estimates the label width closely enough, with a couple of
/// pixels of slack on top.
double axisReservedSize(double maxY, double fontSize, double space) {
  final chars = compactNumberLabel(maxY).length;
  return space + chars * fontSize * 0.62 + 6;
}

/// Picks a "nice" Y-axis step so a chart topping out at [maxValue] can show
/// exactly [lines] gridlines — the baseline plus evenly spaced, round labels
/// above it (0/1/2/3/4/5, or 0/5/10, rather than 0/0.7/1.4/…).
///
/// The mantissa set is all integers so labels stay whole numbers: every
/// tracker these charts plot is integer-valued, and a 2.5 tick would render
/// as a meaningless "2.5 pushups". The step never drops below 1 for the same
/// reason.
double niceAxisStep(double maxValue, int lines) {
  final intervals = lines - 1;
  final raw = (maxValue <= 0 ? 1.0 : maxValue) / intervals;
  const mantissas = <double>[1, 2, 3, 4, 5, 6, 8, 10];
  var magnitude = 1.0;
  while (raw / magnitude >= 10) {
    magnitude *= 10;
  }
  for (final m in mantissas) {
    final step = m * magnitude;
    if (step >= raw) return math.max(1, step);
  }
  return math.max(1, 10 * magnitude);
}
