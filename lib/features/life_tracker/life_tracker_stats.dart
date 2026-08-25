import 'package:intl/intl.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';

/// Assumed average resting heart rate, since the app has no biometric data.
/// Purely a display estimate, same spirit as [assumedSleepHoursPerNight].
const double assumedRestingHeartRateBpm = 70.0;

/// Assumed nightly sleep, since there is no sleep tracker in the app.
const double assumedSleepHoursPerNight = 8.0;

/// Earth's average orbital speed, in kilometres per hour.
const double earthOrbitalSpeedKmh = 107208.0;

/// Average synodic (full-moon-to-full-moon) month, in days.
const double synodicMonthDays = 29.530588;

const int lifespanWeeks = totalLeafCount;

/// Weeks per year as the tree counts them. Derived from the same 80-year /
/// 4,160-week lifespan the canopy is built on, so a full life converts back to
/// exactly 80.00 years — the true 52.18 would land it at 79.7.
const double weeksPerYear = lifespanWeeks / 80;

/// Brief (1-2 word) hover label shown under a blossom.
String shortLabelForStat(LifeStat stat) => _shortLabelFor(stat);

String _shortLabelFor(LifeStat stat) {
  switch (stat) {
    case LifeStat.weeksRemaining:
      return 'Weeks Left';
    case LifeStat.heartbeats:
      return 'Heartbeats';
    case LifeStat.sleepTime:
      return 'Sleep';
    case LifeStat.tasksConquered:
      return 'Tasks';
    case LifeStat.lifetimeMood:
      return 'Mood';
    case LifeStat.kmTraveled:
      return 'Kilometres';
    case LifeStat.fullMoons:
      return 'Full Moons';
  }
}

String _titleFor(LifeStat stat) {
  switch (stat) {
    case LifeStat.weeksRemaining:
      return 'Weeks Remaining';
    case LifeStat.heartbeats:
      return 'Heartbeats Taken';
    case LifeStat.sleepTime:
      return 'Time Spent Sleeping';
    case LifeStat.tasksConquered:
      return 'Tasks Conquered';
    case LifeStat.lifetimeMood:
      return 'Lifetime Mood';
    case LifeStat.kmTraveled:
      return 'Kilometres Travelled Around the Sun';
    case LifeStat.fullMoons:
      return 'Full Moons Experienced';
  }
}

/// A blossom's resolved display data for one moment in time.
class LifeStatValue {
  const LifeStatValue({
    required this.stat,
    required this.title,
    required this.shortLabel,
    required this.value,
    this.secondaryValue,
    this.footnote,
    this.isPlaceholder = false,
  });

  final LifeStat stat;
  final String title;
  final String shortLabel;

  /// Formatted value, or a placeholder like "Set your birth date" when the
  /// underlying data isn't available yet.
  final String value;

  /// The same figure in a second unit, shown under [value] in the stat popup
  /// only — currently just the weeks-remaining count converted to years.
  final String? secondaryValue;

  /// Optional small print explaining an assumption behind the number (e.g.
  /// the assumed heart rate), shown in the stat popup only.
  final String? footnote;

  /// True when [value] is one of the "no data yet" sentences rather than a
  /// figure. Those read as prose and are happy to wrap, so the stat popup
  /// doesn't widen itself to fit them the way it does for a long number.
  final bool isPlaceholder;
}

final _integerFormat = NumberFormat.decimalPattern();

/// Resolves every blossom's current display value. [birthDate] is null until
/// the user sets one in Settings, in which case age-based stats show a
/// placeholder; [tasksConquered]/[lifetimeMood] come from the precomputed
/// [LifeTrackerCachedStats][see app/providers.dart] rather than being
/// recomputed here.
LifeStatValue resolveLifeStat({
  required LifeStat stat,
  required DateTime? birthDate,
  required DateTime now,
  required int tasksConquered,
  required double? lifetimeMood,
}) {
  final title = _titleFor(stat);
  final shortLabel = _shortLabelFor(stat);

  if (stat == LifeStat.tasksConquered) {
    return LifeStatValue(
      stat: stat,
      title: title,
      shortLabel: shortLabel,
      value: _integerFormat.format(tasksConquered),
    );
  }

  if (stat == LifeStat.lifetimeMood) {
    return LifeStatValue(
      stat: stat,
      title: title,
      shortLabel: shortLabel,
      value: lifetimeMood == null
          ? 'No journal moods yet'
          : '${lifetimeMood.toStringAsFixed(1)}/10',
      isPlaceholder: lifetimeMood == null,
    );
  }

  if (birthDate == null) {
    return LifeStatValue(
      stat: stat,
      title: title,
      shortLabel: shortLabel,
      value: 'Set your birth date in Settings',
      isPlaceholder: true,
    );
  }

  final age = now.difference(birthDate);
  final daysLived = age.inDays.clamp(0, 1 << 30);
  final weeksLived = daysLived ~/ 7;

  switch (stat) {
    case LifeStat.weeksRemaining:
      final remaining = (lifespanWeeks - weeksLived).clamp(0, lifespanWeeks);
      return LifeStatValue(
        stat: stat,
        title: title,
        shortLabel: shortLabel,
        value: '${_integerFormat.format(remaining)} weeks',
        secondaryValue: '${(remaining / weeksPerYear).toStringAsFixed(2)} years',
        footnote: 'Assuming an 80-year lifespan (4,160 weeks).',
      );

    case LifeStat.heartbeats:
      final minutesLived = age.inMinutes;
      final beats = (minutesLived * assumedRestingHeartRateBpm).round();
      return LifeStatValue(
        stat: stat,
        title: title,
        shortLabel: shortLabel,
        value: _integerFormat.format(beats),
        footnote:
            'Estimated at an average resting heart rate of ${assumedRestingHeartRateBpm.toStringAsFixed(0)} bpm.',
      );

    case LifeStat.sleepTime:
      final totalHours = daysLived * assumedSleepHoursPerNight;
      final years = (totalHours / (24 * 365.25)).floor();
      final remainingDays = ((totalHours - years * 24 * 365.25) / 24).floor();
      return LifeStatValue(
        stat: stat,
        title: title,
        shortLabel: shortLabel,
        value: years > 0
            ? '$years yr${years == 1 ? '' : 's'}, $remainingDays day${remainingDays == 1 ? '' : 's'}'
            : '$remainingDays day${remainingDays == 1 ? '' : 's'}',
        footnote:
            'Estimated at ${assumedSleepHoursPerNight.toStringAsFixed(0)} hours of sleep per night (no sleep tracker yet).',
      );

    case LifeStat.kmTraveled:
      final km = (age.inMinutes / 60.0) * earthOrbitalSpeedKmh;
      return LifeStatValue(
        stat: stat,
        title: title,
        shortLabel: shortLabel,
        value: '${_integerFormat.format(km.round())} km',
        footnote:
            'Based on Earth\'s average orbital speed of ${_integerFormat.format(earthOrbitalSpeedKmh.round())} km/h.',
      );

    case LifeStat.fullMoons:
      final moons = (daysLived / synodicMonthDays).floor();
      return LifeStatValue(
        stat: stat,
        title: title,
        shortLabel: shortLabel,
        value: _integerFormat.format(moons),
        footnote: 'Approximated from the ~29.5-day lunar cycle.',
      );

    case LifeStat.tasksConquered:
    case LifeStat.lifetimeMood:
      throw StateError('handled above');
  }
}

/// Weeks lived so far, or null if [birthDate] is unset. Decides how many of
/// the tree's leaves rest on the ground.
int? weeksLivedFor(DateTime? birthDate, DateTime now) {
  if (birthDate == null) return null;
  final days = now.difference(birthDate).inDays;
  if (days <= 0) return 0;
  return (days ~/ 7).clamp(0, lifespanWeeks);
}
