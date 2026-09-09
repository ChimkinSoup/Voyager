import 'package:flutter/foundation.dart';

/// Bumped whenever the persisted shape changes in a way an older blob can't be
/// read as. A blob from a different version is discarded rather than migrated —
/// it's one unsaved form, not user data worth carrying forward.
const int kJobsTrackDraftVersion = 2;

/// An in-progress "track an application" form captured whole, exactly as typed.
///
/// Deliberately not a [JobApplication]: nothing here has an id, a timeline, or
/// a place in the sync pipeline. Text is stored untrimmed and blanks are kept,
/// because what a saved application drops, a draft has to restore.
class JobsTrackDraft {
  const JobsTrackDraft({
    this.company = '',
    this.title = '',
    this.status = '',
    this.applicationUrl = '',
    this.notes = '',
    this.seasonIds = const [],
    this.dateApplied,
    required this.savedAt,
  });

  final String company;
  final String title;

  /// The stage name the pill was left on. A name rather than an id, matching
  /// how [JobApplication.status] itself is stored.
  final String status;

  final String applicationUrl;
  final String notes;

  /// The seasons the picker was left on, empty for "no season". A season
  /// deleted or archived while the draft sat on disk is dropped on restore —
  /// see [JobsTrackDraft.resolveSeasonIds].
  final List<String> seasonIds;

  /// Null means the form was never moved off today, so a draft resumed a week
  /// later opens on *that* day rather than on a stale one.
  final DateTime? dateApplied;

  final DateTime savedAt;

  /// Whether the user typed anything worth keeping. A status pill and a date
  /// are defaults the form arrived with, not work — a form with no text in it
  /// clears the slot instead of filling it.
  bool get hasText =>
      company.trim().isNotEmpty ||
      title.trim().isNotEmpty ||
      applicationUrl.trim().isNotEmpty ||
      notes.trim().isNotEmpty;

  /// The draft's seasons, minus any that are no longer ones the form may
  /// offer. A cycle that was retired or deleted while the draft sat on disk is
  /// not one to silently file a new application under; the rest are kept.
  List<String> resolveSeasonIds(Iterable<String> selectableIds) {
    final selectable = selectableIds.toSet();
    return [
      for (final id in seasonIds)
        if (selectable.contains(id)) id,
    ];
  }

  bool sameContentAs(JobsTrackDraft other) =>
      company == other.company &&
      title == other.title &&
      status == other.status &&
      applicationUrl == other.applicationUrl &&
      notes == other.notes &&
      listEquals(seasonIds, other.seasonIds) &&
      dateApplied == other.dateApplied;

  Map<String, dynamic> toJson() => {
    'version': kJobsTrackDraftVersion,
    'company': company,
    'title': title,
    'status': status,
    'applicationUrl': applicationUrl,
    'notes': notes,
    'seasonIds': seasonIds,
    'dateApplied': dateApplied?.toIso8601String(),
    'savedAt': savedAt.toIso8601String(),
  };

  /// Returns null for a blob this version can't read, which the store treats
  /// exactly like having no draft at all.
  static JobsTrackDraft? fromJson(Map<String, dynamic> json) {
    if ((json['version'] as num?)?.toInt() != kJobsTrackDraftVersion) {
      return null;
    }
    return JobsTrackDraft(
      company: json['company'] as String? ?? '',
      title: json['title'] as String? ?? '',
      status: json['status'] as String? ?? '',
      applicationUrl: json['applicationUrl'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      seasonIds: [
        for (final id in (json['seasonIds'] as List?) ?? const [])
          if (id is String) id,
      ],
      dateApplied: DateTime.tryParse(json['dateApplied'] as String? ?? ''),
      savedAt: DateTime.tryParse(json['savedAt'] as String? ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}
