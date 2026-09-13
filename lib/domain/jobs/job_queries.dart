import 'package:voyager/domain/models/job_models.dart';

/// Trimmed, case-folded company name — the key both the duplicate check and
/// the suggestion list compare on, so `Visa ` and `visa` are one company.
String jobCompanyKey(String company) => company.trim().toLowerCase();

/// Identity used for the soft duplicate warning (§7.3): the posting's URL,
/// normalised, or null when there is no URL to compare.
///
/// The URL rather than company+title, because a company routinely posts
/// several distinct roles under one name — two `Software Engineer` rows at the
/// same place are usually two different jobs, and the link is the only thing
/// that says whether they are the same posting.
///
/// Normalisation is deliberately shallow: case, the scheme, a leading `www.`
/// and a trailing slash are noise, but the query string is not — boards like
/// Greenhouse and LinkedIn identify the posting *in* it, so stripping it would
/// collapse genuinely different jobs into one.
String? jobDuplicateKey(JobApplication application) =>
    jobUrlKey(application.applicationUrl);

/// The same normalisation over a bare URL string, for the Track form's soft
/// "you have already applied here" hint, which compares what is being typed
/// against rows that already exist.
String? jobUrlKey(String? applicationUrl) {
  var url = applicationUrl?.trim().toLowerCase() ?? '';
  if (url.isEmpty) return null;
  url = url.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');
  url = url.replaceFirst(RegExp(r'^www\.'), '');
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url.isEmpty ? null : url;
}

/// Ids of applications that share a posting URL with at least one other
/// application in [applications].
///
/// Computed over the rows being displayed rather than the whole table: the
/// warning is a table-view affordance, and flagging a row against something
/// the user cannot see would be unexplainable.
///
/// An application with no URL is never flagged. Nothing has been said about
/// where it was applied, so there is no evidence it duplicates anything — and
/// grouping every blank together would flag the whole table on day one.
Set<String> jobDuplicateIds(Iterable<JobApplication> applications) {
  final byKey = <String, List<String>>{};
  for (final application in applications) {
    final key = jobDuplicateKey(application);
    if (key == null) continue;
    byKey.putIfAbsent(key, () => []).add(application.id);
  }
  return {
    for (final ids in byKey.values)
      if (ids.length > 1) ...ids,
  };
}

/// Whether [application] matches [query] under §6.1: every whitespace-separated
/// term must appear, case-insensitively, somewhere across company, title,
/// notes or status. An empty or whitespace-only query matches everything.
bool jobMatchesQuery(JobApplication application, String query) {
  final terms = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((t) => t.isEmpty);
  if (terms.isEmpty) return true;
  final haystack = [
    application.company,
    application.title,
    application.notes ?? '',
    application.status,
  ].join(' ').toLowerCase();
  return terms.every(haystack.contains);
}

/// Ids of the seasons that have been retired. Every surface that asks "is this
/// archived" starts here — see [jobIsArchived].
Set<String> jobArchivedSeasonIds(Iterable<JobSeason> seasons) => {
  for (final season in seasons)
    if (season.isArchived) season.id,
};

/// Whether [application] is archived, given the retired seasons from
/// [jobArchivedSeasonIds].
///
/// Archived only once *every* season it is filed under has been retired. An
/// application that also belongs to a cycle still running is still in play,
/// and ending one of its older cycles must not take a live row off the list.
///
/// An application filed under no season at all is active: there is no ended
/// cycle to archive it.
bool jobIsArchived(JobApplication application, Set<String> archivedSeasonIds) {
  if (application.seasonIds.isEmpty) return false;
  return application.seasonIds.every(archivedSeasonIds.contains);
}

/// The seasons a new application may be filed under: still running, in the
/// user's manual order. A retired season stays visible in the Seasons list but
/// is no longer offered for anything new.
List<JobSeason> jobSelectableSeasons(Iterable<JobSeason> seasons) => [
  for (final season in seasons)
    if (!season.isArchived) season,
];

/// The list surface's filter chain: archived, then status, then search — all
/// ANDed (§6.2).
List<JobApplication> filterJobApplications(
  List<JobApplication> applications, {
  required bool includeArchived,
  required Set<String> archivedSeasonIds,
  required Set<String> statuses,
  required String query,
}) {
  return [
    for (final application in applications)
      if ((includeArchived || !jobIsArchived(application, archivedSeasonIds)) &&
          (statuses.isEmpty || statuses.contains(application.status)) &&
          jobMatchesQuery(application, query))
        application,
  ];
}

/// Stage names in the user's display order, with any status string that no
/// longer names a stage appended after them (§7.5). Orphans are ordered by
/// first appearance so the list is stable between rebuilds.
List<String> jobStatusDisplayOrder(
  List<JobStage> stages,
  Iterable<JobApplication> applications,
) {
  // De-duped even though adding and renaming reject a taken name: sync can
  // still land two stages with one name, and each would count every
  // application on it.
  final ordered = <String>[];
  final known = <String>{};
  for (final stage in stages) {
    if (known.add(stage.name)) ordered.add(stage.name);
  }
  for (final application in applications) {
    if (known.add(application.status)) ordered.add(application.status);
  }
  return ordered;
}

/// Per-status counts in [jobStatusDisplayOrder], statuses with no applications
/// dropped. Feeds both the header chips and the Sankey.
List<({String status, int count})> jobStatusCounts(
  List<JobStage> stages,
  Iterable<JobApplication> applications,
) {
  final counts = <String, int>{};
  for (final application in applications) {
    counts[application.status] = (counts[application.status] ?? 0) + 1;
  }
  return [
    for (final status in jobStatusDisplayOrder(stages, applications))
      if ((counts[status] ?? 0) > 0) (status: status, count: counts[status]!),
  ];
}

/// The table's order: most recently applied first, ties broken by when the row
/// was actually added, newest first.
///
/// [JobApplication.dateApplied] is date-only, so a day of bulk applying leaves
/// all of its rows comparing equal — and `List.sort` is not stable, so without
/// a tiebreak their order is whatever the sort happened to produce rather than
/// anything the user chose. `createdAt` puts them back in the order they were
/// entered.
int compareJobApplications(JobApplication a, JobApplication b) {
  final byDate = b.dateApplied.compareTo(a.dateApplied);
  return byDate != 0 ? byDate : b.createdAt.compareTo(a.createdAt);
}

/// The calendar day [date] names, as a local-midnight [DateTime] — what the
/// sparkline buckets on and what a date label formats.
///
/// A stored `dateApplied` (UTC midnight) keeps its own day rather than being
/// shifted into this device's zone; any other instant, `DateTime.now()`
/// included, is read locally. See [jobCalendarDay].
DateTime jobDayKey(DateTime date) {
  final day = jobCalendarDay(date);
  return DateTime(day.year, day.month, day.day);
}

/// Applications per day over the [days] calendar days ending today, bucketed on
/// `dateApplied` (§8.3). Always returns exactly [days] entries, oldest first,
/// so the sparkline's x-axis is fixed regardless of the data.
List<({DateTime day, int count})> jobDailyCounts(
  Iterable<JobApplication> applications, {
  required DateTime now,
  int days = 30,
}) {
  final today = jobDayKey(now);
  final counts = <DateTime, int>{};
  for (final application in applications) {
    final day = jobDayKey(application.dateApplied);
    counts[day] = (counts[day] ?? 0) + 1;
  }
  // Stepped by calendar day, not by 24-hour Durations: across a DST change a
  // Duration lands at 23:00 or 01:00 and matches no bucket.
  final series = <({DateTime day, int count})>[];
  for (var i = days - 1; i >= 0; i--) {
    final day = DateTime(today.year, today.month, today.day - i);
    series.add((day: day, count: counts[day] ?? 0));
  }
  return series;
}

/// Seeded stages and companies get ids derived from their names, so two
/// devices that each seeded "Applied" hold the same document rather than two.
String jobSeedStageId(String name) => 'seed-stage-${_seedSlug(name)}';
String jobSeedCompanyId(String name) => 'seed-company-${_seedSlug(name)}';

bool isJobSeedId(String id) => id.startsWith('seed-');

/// The created/updated instant every seed carries, so untouched seeds on two
/// devices are identical documents. A seed sits at version 0, which any real
/// edit outranks.
final jobSeedEpoch = DateTime.utc(2025, 1, 1);

String _seedSlug(String name) =>
    jobCompanyKey(name).replaceAll(RegExp(r'[^a-z0-9]+'), '-');

/// Company keys the user has actually applied to, most recently first.
///
/// In the same order the table is sorted in — see [compareJobApplications].
/// Keys, not names, because that is what the suggestion list matches on.
List<String> jobRecentCompanyKeys(Iterable<JobApplication> applications) {
  final sorted = [...applications]..sort(compareJobApplications);
  final seen = <String>{};
  return [
    for (final application in sorted)
      if (application.company.trim().isNotEmpty &&
          seen.add(jobCompanyKey(application.company)))
        jobCompanyKey(application.company),
  ];
}

/// Case-insensitive substring match over the company suggestion list (§4.4),
/// with the user's own companies ranked ahead of the seeded catalogue.
///
/// [recentKeys] comes from [jobRecentCompanyKeys]. Companies on that list sort
/// by how recently they were used; everything else sorts prefix-matches first
/// (typing `visa` should offer `Visa` before `US Visa`) and then
/// alphabetically.
///
/// An empty query returns *only* the used companies. The seeded catalogue is
/// ~150 entries — offering it unprompted on focus would bury the three names
/// the user actually applies to, and on a fresh install there is nothing worth
/// suggesting at all.
List<JobCompany> filterJobCompanies(
  List<JobCompany> companies,
  String query, {
  List<String> recentKeys = const [],
}) {
  final rank = {for (var i = 0; i < recentKeys.length; i++) recentKeys[i]: i};
  final needle = query.trim().toLowerCase();
  final matches = [
    for (final company in companies)
      if (needle.isEmpty
          ? rank.containsKey(jobCompanyKey(company.name))
          : company.name.toLowerCase().contains(needle))
        company,
  ];
  matches.sort((a, b) {
    final aRank = rank[jobCompanyKey(a.name)];
    final bRank = rank[jobCompanyKey(b.name)];
    if (aRank != bRank) {
      if (aRank == null) return 1;
      if (bRank == null) return -1;
      return aRank.compareTo(bRank);
    }
    if (needle.isNotEmpty) {
      final aPrefix = a.name.toLowerCase().startsWith(needle);
      final bPrefix = b.name.toLowerCase().startsWith(needle);
      if (aPrefix != bPrefix) return aPrefix ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return matches;
}
