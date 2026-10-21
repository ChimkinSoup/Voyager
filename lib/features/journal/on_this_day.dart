import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/journal_models.dart';

/// On this day: past entries a journal brings back on the journal page
/// (ON_THIS_DAY_HLD.md). This file is the matching; the card and its ledge
/// live in `on_this_day_overlay.dart`.

enum OnThisDayKind { monthAgo, yearsAgo }

class OnThisDayMatch {
  const OnThisDayMatch({
    required this.entry,
    required this.journal,
    required this.kind,
    required this.localDate,
    required this.yearsAgo,
  });

  final JournalEntry entry;
  final Journal journal;
  final OnThisDayKind kind;

  /// The entry's [journalDay] (local midnight).
  final DateTime localDate;

  /// Zero for [OnThisDayKind.monthAgo].
  final int yearsAgo;

  /// "1mo", "3y": how far back, sized for the tucked card's 32 px strip.
  String get shortAgo => switch (kind) {
    OnThisDayKind.monthAgo => '1mo',
    OnThisDayKind.yearsAgo => '${yearsAgo}y',
  };

  /// "1 month ago · Jan 28", "3 years ago · Sep 24". The date is always there
  /// so a 31-days-back entry, or a last-day catch-up one (a Feb 29 shown on
  /// Feb 28), reads correctly.
  String get label {
    final ago = switch (kind) {
      OnThisDayKind.monthAgo => '1 month ago',
      OnThisDayKind.yearsAgo when yearsAgo == 1 => '1 year ago',
      OnThisDayKind.yearsAgo => '$yearsAgo years ago',
    };
    return '$ago · ${DateFormat.MMMd().format(localDate)}';
  }
}

/// Every eligible entry that [today] brings back, newest first.
///
/// [journalId] narrows to one journal; null is the All journals view, which
/// keeps only journals with [Journal.includeInAllView]. Pure: [today] is the
/// only clock, read as a local calendar day; each entry's day is its
/// [journalDay] under [dayStartHour].
List<OnThisDayMatch> matchOnThisDay(
  DateTime today,
  List<Journal> journals,
  List<JournalEntry> entries, {
  String? journalId,
  int dayStartHour = 0,
}) {
  final enabled = {
    for (final journal in journals)
      if (!journal.isDeleted &&
          journal.onThisDayCadence != OnThisDayCadence.off &&
          (journalId == null
              ? journal.includeInAllView
              : journal.id == journalId))
        journal.id: journal,
  };
  if (enabled.isEmpty) return const [];

  final isLastDay = DateTime(today.year, today.month + 1, 0).day == today.day;
  bool dayMatches(DateTime d) =>
      d.day == today.day || (isLastDay && d.day > today.day);
  // A fixed 31 days back, so every day comes back exactly once whatever the
  // months' lengths, and always from an earlier calendar month.
  final monthAgo = addCalendarDays(today, -31);

  final matches = <OnThisDayMatch>[];
  for (final entry in entries) {
    final journal = enabled[entry.journalId];
    if (journal == null || entry.isDeleted) continue;
    if (entry.title.trim().isEmpty && entry.body.trim().isEmpty) continue;
    final d = journalDay(entry.entryDate, dayStartHour);

    if (d.year < today.year && d.month == today.month && dayMatches(d)) {
      matches.add(
        OnThisDayMatch(
          entry: entry,
          journal: journal,
          kind: OnThisDayKind.yearsAgo,
          localDate: d,
          yearsAgo: today.year - d.year,
        ),
      );
    } else if (journal.onThisDayCadence == OnThisDayCadence.monthlyAndYearly &&
        d == monthAgo) {
      matches.add(
        OnThisDayMatch(
          entry: entry,
          journal: journal,
          kind: OnThisDayKind.monthAgo,
          localDate: d,
          yearsAgo: 0,
        ),
      );
    }
  }

  DateTime within(JournalEntry e) => e.timestamp ?? e.createdAt;
  matches.sort((a, b) {
    final byDay = b.localDate.compareTo(a.localDate);
    if (byDay != 0) return byDay;
    final byTime = within(b.entry).compareTo(within(a.entry));
    if (byTime != 0) return byTime;
    return b.entry.id.compareTo(a.entry.id);
  });
  return matches;
}

/// What ✕ records for one matched entry on [today].
String onThisDayDismissalKey(String entryId, DateTime today) =>
    '$entryId|${DateFormat('yyyy-MM-dd').format(today)}';

/// The [onThisDayDismissalKey]s ✕ has closed. In memory only, so they last
/// for this run of the app: a restart brings the card back the same day.
final onThisDayDismissedProvider = StateProvider<Set<String>>(
  (ref) => const {},
);

typedef OnThisDayQuery = ({DateTime day, String? journalId});

/// Matches for a [journalDay] [OnThisDayQuery.day] (midnight) and scope.
final onThisDayProvider = FutureProvider.autoDispose
    .family<List<OnThisDayMatch>, OnThisDayQuery>((ref, query) async {
      final journals = await ref.watch(journalsProvider.future);
      // Nothing opted in, which is the default: skip loading every entry.
      if (journals.every((j) => j.onThisDayCadence == OnThisDayCadence.off)) {
        return const [];
      }
      final entries = await ref.watch(allJournalEntriesProvider.future);
      return matchOnThisDay(
        query.day,
        journals,
        entries,
        journalId: query.journalId,
        dayStartHour: await ref.watch(
          settingsProvider.selectAsync((s) => s.dayStartHour),
        ),
      );
    });
