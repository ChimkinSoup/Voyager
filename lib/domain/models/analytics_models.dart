import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

/// Reserved id for the built-in "Journal Entries" default tracker shown on the
/// analytics page. It is virtual — synthesised at display time from the user's
/// journal entries and never written to the database, so it can't be deleted
/// or edited. See [buildJournalEntriesTracker].
const String kJournalEntriesTrackerId = '__default_journal_entries__';

/// Reserved id for the built-in "Streak" default tracker. Virtual like
/// [kJournalEntriesTrackerId] — see [buildStreakTracker].
const String kStreakTrackerId = '__default_streak__';

/// Reserved id for the built-in "Word Count" default tracker. Virtual like
/// [kJournalEntriesTrackerId] — see [buildWordCountTracker].
const String kWordCountTrackerId = '__default_word_count__';

class StatisticTracker extends SoftDeletable {
  const StatisticTracker({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required this.name,
    required this.type,
    required this.cadence,
    this.colorValue = 0xFF7C9EFF,
    this.showOnCalendar = false,
    this.integerCap,
    this.defaultInt = 0,
    this.defaultBool = false,
    this.enumOptions = const [],
    this.defaultEnumOption,
    this.trackingStyle,
    this.starred = false,
    this.sortOrder = 0,
    this.isDefault = false,
  });

  final String name;
  final TrackerType type;
  final TrackerCadence cadence;
  final int colorValue;
  final bool showOnCalendar;
  final int? integerCap;
  final int defaultInt;
  final bool defaultBool;
  final List<String> enumOptions;
  final String? defaultEnumOption;

  /// Null for boolean / enum trackers (always independent/heatmap).
  /// For integer trackers, null is treated as [TrackerStyle.independent].
  final TrackerStyle? trackingStyle;

  /// Forces the tracker above all others in the grid view, regardless of
  /// [cadence]. Starred trackers form their own freely-reorderable group.
  final bool starred;

  /// Manual position within whichever group the tracker currently belongs
  /// to (the starred group if [starred], otherwise its [cadence] group).
  final int sortOrder;

  /// True only for built-in, non-persisted trackers (e.g. the "Journal
  /// Entries" tracker). These are derived at display time and can't be
  /// deleted, edited, starred or reordered.
  final bool isDefault;

  /// The resolved visualisation style, applying defaults.
  TrackerStyle? get effectiveTrackingStyle {
    if (type != TrackerType.integer) return null;
    return trackingStyle ?? TrackerStyle.independent;
  }

  StatisticTracker copyWith({
    String? name,
    bool? showOnCalendar,
    DateTime? deletedAt,
    TrackerStyle? trackingStyle,
    bool? starred,
    int? sortOrder,
  }) {
    return StatisticTracker(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      deletedAt: deletedAt ?? this.deletedAt,
      name: name ?? this.name,
      type: type,
      cadence: cadence,
      colorValue: colorValue,
      showOnCalendar: showOnCalendar ?? this.showOnCalendar,
      integerCap: integerCap,
      defaultInt: defaultInt,
      defaultBool: defaultBool,
      enumOptions: enumOptions,
      defaultEnumOption: defaultEnumOption,
      trackingStyle: trackingStyle ?? this.trackingStyle,
      starred: starred ?? this.starred,
      sortOrder: sortOrder ?? this.sortOrder,
      isDefault: isDefault,
    );
  }
}

/// Builds the virtual "Journal Entries" default tracker: a daily boolean stat
/// where each day is "true" iff the user has a journal entry on it. Not
/// persisted — its values are derived from journal entries (see
/// [journalEntriesTrackerValues]).
StatisticTracker buildJournalEntriesTracker({required int colorValue}) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return StatisticTracker(
    id: kJournalEntriesTrackerId,
    createdAt: epoch,
    updatedAt: epoch,
    name: 'Journal Entries',
    type: TrackerType.boolean,
    cadence: TrackerCadence.daily,
    colorValue: colorValue,
    isDefault: true,
  );
}

/// Builds the virtual "Streak" default tracker: a daily integer stat drawn as
/// a consecutive sparkline, where each day's value is the length of the
/// journaling streak ending on that day. Not persisted — its values are
/// derived from journal entries (see [streakTrackerValues]).
StatisticTracker buildStreakTracker({required int colorValue}) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return StatisticTracker(
    id: kStreakTrackerId,
    createdAt: epoch,
    updatedAt: epoch,
    name: 'Streak',
    type: TrackerType.integer,
    cadence: TrackerCadence.daily,
    colorValue: colorValue,
    trackingStyle: TrackerStyle.consecutive,
    isDefault: true,
  );
}

/// Builds the virtual "Word Count" default tracker: a daily integer stat drawn
/// as a consecutive sparkline, where each day's value is the total number of
/// words written that day. Not persisted — its values are derived from journal
/// entries (see [wordCountTrackerValues]).
StatisticTracker buildWordCountTracker({required int colorValue}) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return StatisticTracker(
    id: kWordCountTrackerId,
    createdAt: epoch,
    updatedAt: epoch,
    name: 'Word Count',
    type: TrackerType.integer,
    cadence: TrackerCadence.daily,
    colorValue: colorValue,
    trackingStyle: TrackerStyle.consecutive,
    isDefault: true,
  );
}

class TrackerValue extends SoftDeletable {
  const TrackerValue({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.deletedAt,
    required this.trackerId,
    required this.periodStart,
    this.intValue,
    this.boolValue,
    this.enumValue,
  });

  final String trackerId;
  final DateTime periodStart;
  final int? intValue;
  final bool? boolValue;
  final String? enumValue;
}

/// Derives the virtual "Journal Entries" tracker's values from [entries]:
/// one boolean-`true` [TrackerValue] per local calendar day that has at least
/// one journal entry. Days with no entry get no value (rendered as empty).
List<TrackerValue> journalEntriesTrackerValues(List<JournalEntry> entries) {
  final days = <DateTime>{};
  for (final entry in entries) {
    final d = entry.entryDate;
    days.add(DateTime(d.year, d.month, d.day));
  }
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return [
    for (final day in days)
      TrackerValue(
        id:
            '$kJournalEntriesTrackerId:'
            '${day.year}-${day.month}-${day.day}',
        trackerId: kJournalEntriesTrackerId,
        periodStart: day,
        boolValue: true,
        createdAt: epoch,
        updatedAt: epoch,
      ),
  ];
}

/// The local calendar days spanned by [entries], oldest first, with no gaps —
/// every day from the first entry through the later of today and the last
/// entry. Shared by the derived daily series below, which need a value on
/// *every* day (not just the ones with entries) so the sparkline's
/// interpolation can't smooth over a day the user wrote nothing.
List<DateTime> _dailySpan(List<JournalEntry> entries) {
  if (entries.isEmpty) return const [];
  var first = DateTime(
    entries.first.entryDate.year,
    entries.first.entryDate.month,
    entries.first.entryDate.day,
  );
  var last = first;
  for (final entry in entries) {
    final d = entry.entryDate;
    final day = DateTime(d.year, d.month, d.day);
    if (day.isBefore(first)) first = day;
    if (day.isAfter(last)) last = day;
  }
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  if (today.isAfter(last)) last = today;

  final days = <DateTime>[];
  for (
    var day = first;
    !day.isAfter(last);
    day = DateTime(day.year, day.month, day.day + 1)
  ) {
    days.add(day);
  }
  return days;
}

/// Derives the virtual "Streak" tracker's values from [entries]: one integer
/// [TrackerValue] per day, holding the length of the unbroken run of journaled
/// days ending on that day. A day with no entry scores 0, so the sparkline
/// visibly drops to the baseline when a streak breaks instead of being
/// interpolated straight across the gap.
List<TrackerValue> streakTrackerValues(List<JournalEntry> entries) {
  final journaled = <DateTime>{
    for (final entry in entries)
      DateTime(
        entry.entryDate.year,
        entry.entryDate.month,
        entry.entryDate.day,
      ),
  };
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final values = <TrackerValue>[];
  var run = 0;
  for (final day in _dailySpan(entries)) {
    run = journaled.contains(day) ? run + 1 : 0;
    values.add(
      TrackerValue(
        id: '$kStreakTrackerId:${day.year}-${day.month}-${day.day}',
        trackerId: kStreakTrackerId,
        periodStart: day,
        intValue: run,
        createdAt: epoch,
        updatedAt: epoch,
      ),
    );
  }
  return values;
}

/// Derives the virtual "Word Count" tracker's values from [entries]: one
/// integer [TrackerValue] per day holding the total words written across every
/// entry dated that day. Days with no entry score 0, matching
/// [streakTrackerValues] so a silent day reads as a real drop to the baseline.
///
/// [countWords] is injected rather than hardcoded so the series always agrees
/// with the count shown in the page's "Words" stat chip.
List<TrackerValue> wordCountTrackerValues(
  List<JournalEntry> entries, {
  required int Function(String) countWords,
}) {
  final wordsByDay = <DateTime, int>{};
  for (final entry in entries) {
    final d = entry.entryDate;
    final day = DateTime(d.year, d.month, d.day);
    wordsByDay[day] = (wordsByDay[day] ?? 0) + countWords(entry.body);
  }
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return [
    for (final day in _dailySpan(entries))
      TrackerValue(
        id: '$kWordCountTrackerId:${day.year}-${day.month}-${day.day}',
        trackerId: kWordCountTrackerId,
        periodStart: day,
        intValue: wordsByDay[day] ?? 0,
        createdAt: epoch,
        updatedAt: epoch,
      ),
  ];
}
