import 'dart:math' as math;

import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/soft_deletable.dart';

/// Distinguishes "argument omitted" from "argument passed as null" in the
/// `copyWith`s below.
///
/// The usual `x ?? this.x` idiom cannot express *clearing* a field: passing
/// `null` reads as "keep what's there". That made an un-delete impossible —
/// `softDeleteValue` could set a tombstone but nothing could lift one — and
/// left a value carrying a stale `intValue` after a tracker changed type. Both
/// call sites worked around it by hand-rolling a constructor instead, which is
/// how writes started dropping `version` and reverting on the next pull.
class _Unset {
  const _Unset();
}

const _unset = _Unset();

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

/// Reserved id for the built-in "Dream Logged" default tracker, shown only
/// when [AppSettings.showDreamStatistics] is on. Virtual like
/// [kJournalEntriesTrackerId] — see [buildDreamLoggedTracker].
const String kDreamLoggedTrackerId = '__default_dream_logged__';

/// Reserved id for the built-in "Worked Out" default tracker, shown only when
/// [AppSettings.showWorkoutStatistics] is on. Virtual like
/// [kJournalEntriesTrackerId] — see [buildWorkedOutTracker].
const String kWorkedOutTrackerId = '__default_worked_out__';

class StatisticTracker extends SoftDeletable {
  const StatisticTracker({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
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

  /// [deletedAt] and [trackingStyle] take [_unset] rather than null as their
  /// "leave it alone" default, so passing an explicit `null` clears them.
  StatisticTracker copyWith({
    String? name,
    bool? showOnCalendar,
    Object? deletedAt = _unset,
    Object? trackingStyle = _unset,
    bool? starred,
    int? sortOrder,
    bool bumpVersion = true,
  }) {
    return StatisticTracker(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: bumpVersion ? version + 1 : version,
      deletedAt: identical(deletedAt, _unset)
          ? this.deletedAt
          : deletedAt as DateTime?,
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
      trackingStyle: identical(trackingStyle, _unset)
          ? this.trackingStyle
          : trackingStyle as TrackerStyle?,
      starred: starred ?? this.starred,
      sortOrder: sortOrder ?? this.sortOrder,
      isDefault: isDefault,
    );
  }
}

/// [raw] confined to [tracker]'s recorded range (`defaultInt`..`integerCap`),
/// or returned unchanged when the tracker has no limit.
///
/// Orders the two bounds rather than trusting them. `num.clamp` *throws* on an
/// inverted range, and a tracker can hold one: the dialog's "Lower limit" and
/// "Upper limit" fields were never validated against each other. Rows written
/// by such a tracker are read during build (the value editor's `Slider`), on
/// focus loss (the notification popover's entry row) and on save — so an
/// unordered clamp turns a bad pair of limits into a subtree that throws every
/// frame rather than a value that reads oddly.
int clampToTrackerRange(int raw, StatisticTracker tracker) {
  final cap = tracker.integerCap;
  if (cap == null) return raw;
  final lower = tracker.defaultInt;
  return raw.clamp(math.min(lower, cap), math.max(lower, cap)).toInt();
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

/// Builds the virtual "Dream Logged" default tracker: a daily boolean stat
/// where each day is "true" iff the user has a dream entry on it. Not
/// persisted — its values are derived from dream entries (see
/// [dreamLoggedTrackerValues]).
StatisticTracker buildDreamLoggedTracker({required int colorValue}) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return StatisticTracker(
    id: kDreamLoggedTrackerId,
    createdAt: epoch,
    updatedAt: epoch,
    name: 'Dream Logged',
    type: TrackerType.boolean,
    cadence: TrackerCadence.daily,
    colorValue: colorValue,
    isDefault: true,
  );
}

/// Derives the virtual "Dream Logged" tracker's values from [entries]: one
/// boolean-`true` [TrackerValue] per local calendar day that has at least one
/// dream entry. Days with no entry get no value (rendered as empty).
List<TrackerValue> dreamLoggedTrackerValues(List<DreamEntry> entries) {
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
            '$kDreamLoggedTrackerId:'
            '${day.year}-${day.month}-${day.day}',
        trackerId: kDreamLoggedTrackerId,
        periodStart: day,
        boolValue: true,
        createdAt: epoch,
        updatedAt: epoch,
      ),
  ];
}

/// Builds the virtual "Worked Out" default tracker: a daily boolean where each
/// day is true iff a workout was finished on it. Not persisted — its values
/// come from the workout sessions themselves (see [workedOutTrackerValues]),
/// so the stat can never drift from what the tracker page shows.
StatisticTracker buildWorkedOutTracker({required int colorValue}) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return StatisticTracker(
    id: kWorkedOutTrackerId,
    createdAt: epoch,
    updatedAt: epoch,
    name: 'Worked Out',
    type: TrackerType.boolean,
    cadence: TrackerCadence.daily,
    colorValue: colorValue,
    isDefault: true,
  );
}

/// Derives the virtual "Worked Out" tracker's values from the local calendar
/// [days] that carry a finished workout. Days without one get no value at all
/// rather than an explicit false — same convention as the journal and dream
/// trackers, which renders as an empty cell instead of a filled "no".
List<TrackerValue> workedOutTrackerValues(Set<DateTime> days) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return [
    for (final day in days)
      TrackerValue(
        id: '$kWorkedOutTrackerId:${day.year}-${day.month}-${day.day}',
        trackerId: kWorkedOutTrackerId,
        periodStart: day,
        boolValue: true,
        createdAt: epoch,
        updatedAt: epoch,
      ),
  ];
}

class TrackerValue extends SoftDeletable {
  const TrackerValue({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    super.version,
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

  /// Every nullable field takes [_unset] rather than null as its "leave it
  /// alone" default, so passing an explicit `null` clears it — which is what
  /// lifting a tombstone, or dropping a stale reading after a tracker changes
  /// type, requires.
  TrackerValue copyWith({
    Object? intValue = _unset,
    Object? boolValue = _unset,
    Object? enumValue = _unset,
    Object? deletedAt = _unset,
    bool bumpVersion = true,
  }) {
    return TrackerValue(
      id: id,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc(),
      version: bumpVersion ? version + 1 : version,
      deletedAt: identical(deletedAt, _unset)
          ? this.deletedAt
          : deletedAt as DateTime?,
      trackerId: trackerId,
      periodStart: periodStart,
      intValue: identical(intValue, _unset) ? this.intValue : intValue as int?,
      boolValue: identical(boolValue, _unset)
          ? this.boolValue
          : boolValue as bool?,
      enumValue: identical(enumValue, _unset)
          ? this.enumValue
          : enumValue as String?,
    );
  }
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
