import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/job_constants.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/jobs/job_queries.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Every write the Jobs page makes, in one place.
///
/// Each function follows the same three beats the rest of the app uses: write
/// through the repository, hand the record to the sync layer, then invalidate
/// the providers that read it. Nothing here touches widgets, so the page and
/// the editor panel can both call the same code.
class JobsActions {
  const JobsActions(WidgetRef ref) : _ref = ref, _container = null;

  /// Actions that outlive the widget that asked for them.
  ///
  /// A soft delete unmounts the row it deleted, and a [WidgetRef] throws once
  /// its widget is gone — so the undo the toast offers, pressed seconds later,
  /// has to run off the container instead.
  const JobsActions.detached(ProviderContainer container)
    : _ref = null,
      _container = container;

  final WidgetRef? _ref;
  final ProviderContainer? _container;

  T _read<T>(ProviderListenable<T> provider) {
    final ref = _ref;
    return ref == null ? _container!.read(provider) : ref.read(provider);
  }

  void _invalidate(ProviderOrFamily provider) {
    final ref = _ref;
    if (ref == null) {
      _container!.invalidate(provider);
    } else {
      ref.invalidate(provider);
    }
  }

  JobRepository get _repository => _read(jobRepositoryProvider);
  RemoteSyncService get _sync => _read(remoteSyncServiceProvider);

  void _refreshApplications() {
    _invalidate(jobApplicationsProvider);
  }

  /// Creates an application from a completed form, records the opening
  /// timeline entry, and adds the company to the typeahead if it is new.
  /// Returns the application so the caller can open it for editing.
  ///
  /// Every field the track form collects is written here in one go — the
  /// record is not created until the form is saved, so there is no
  /// half-populated row for a later edit to fill in.
  Future<JobApplication> createApplication({
    required String company,
    required String title,
    String? status,
    DateTime? dateApplied,
    String? applicationUrl,
    String? notes,
    List<String> seasonIds = const [],
  }) async {
    final stages = await _read(jobStagesProvider.future);
    final now = utcNow();
    final application = JobApplication(
      id: newId(),
      company: company.trim(),
      title: title.trim(),
      status:
          status ?? (stages.isNotEmpty ? stages.first.name : jobDefaultStage),
      dateApplied: jobCalendarDay(dateApplied ?? DateTime.now()),
      applicationUrl: applicationUrl,
      notes: notes,
      seasonIds: seasonIds,
      createdAt: now,
      updatedAt: now,
    );
    await _writeApplication(
      application,
      events: [_statusEvent(application, from: null, to: application.status)],
      registerCompany: application.company,
    );
    return application;
  }

  /// Saves the fields [application] changed relative to [previous], and only
  /// those, onto the application as it is on disk now.
  ///
  /// The caller's copy can be stale — the editor panel holds the row it
  /// opened with, and a row's menu holds the row it was built with — so
  /// writing it whole would put back whatever changed underneath it since:
  /// a status set from the table, a season toggled, an edit pulled from
  /// another device. Nothing is written for an application deleted in the
  /// meantime, which a pending autosave would otherwise resurrect.
  ///
  /// A status move appends its timeline entry (from the status on disk), and
  /// a new company is added to the typeahead. Returns what was written, or
  /// null when nothing was.
  Future<JobApplication?> saveApplication(
    JobApplication application, {
    required JobApplication previous,
  }) async {
    final onDisk = await _repository.getApplication(application.id);
    if (onDisk == null || onDisk.deletedAt != null) return null;

    bool changed<T>(T Function(JobApplication a) field) =>
        field(application) != field(previous);
    final urlChanged = changed((a) => a.applicationUrl);
    final notesChanged = changed((a) => a.notes);
    final seasonsChanged = !listEquals(
      application.seasonIds,
      previous.seasonIds,
    );
    final updated = onDisk.copyWith(
      company: changed((a) => a.company) ? application.company : null,
      title: changed((a) => a.title) ? application.title : null,
      status: changed((a) => a.status) ? application.status : null,
      dateApplied: changed((a) => a.dateApplied)
          ? jobCalendarDay(application.dateApplied)
          : null,
      applicationUrl: urlChanged ? application.applicationUrl : null,
      clearApplicationUrl: urlChanged && application.applicationUrl == null,
      notes: notesChanged ? application.notes : null,
      clearNotes: notesChanged && application.notes == null,
      seasonIds: seasonsChanged ? application.seasonIds : null,
    );
    final before = jobApplicationStampValues(onDisk);
    final after = jobApplicationStampValues(updated);
    if (after.keys.every((key) => before[key] == after[key])) return null;

    await _writeApplication(
      updated,
      events: [
        if (updated.status != onDisk.status)
          _statusEvent(updated, from: onDisk.status, to: updated.status),
      ],
      registerCompany:
          jobCompanyKey(updated.company) != jobCompanyKey(onDisk.company)
          ? updated.company
          : null,
    );
    return updated;
  }

  /// Writes an application, its new timeline entries and its company
  /// suggestion together (see [JobRepository.writeApplication]), and only
  /// then hands them to sync — a failed write pushes nothing.
  Future<void> _writeApplication(
    JobApplication application, {
    List<JobStatusEvent> events = const [],
    String? registerCompany,
  }) async {
    final company = await _repository.writeApplication(
      application,
      events: events,
      registerCompany: registerCompany,
    );
    _sync.pushJobApplication(application);
    if (events.length == 1) {
      _sync.pushJobStatusEvent(events.single);
    } else if (events.isNotEmpty) {
      await _sync.pushJobStatusEventsBatch(events);
    }
    if (events.isNotEmpty) {
      _invalidate(jobStatusEventsProvider(application.id));
    }
    if (company != null) {
      _sync.pushJobCompany(company);
      _invalidate(jobCompaniesProvider);
    }
    _refreshApplications();
  }

  /// Copies every field onto a new id (§7.2). The timeline starts fresh at the
  /// copied status rather than being duplicated too — the copy has not been
  /// through those moves.
  Future<JobApplication> duplicateApplication(JobApplication source) async {
    final now = utcNow();
    final copy = JobApplication(
      id: newId(),
      company: source.company,
      title: source.title,
      status: source.status,
      dateApplied: source.dateApplied,
      applicationUrl: source.applicationUrl,
      notes: source.notes,
      seasonIds: source.seasonIds,
      createdAt: now,
      updatedAt: now,
    );
    await _writeApplication(
      copy,
      events: [_statusEvent(copy, from: null, to: copy.status)],
    );
    return copy;
  }

  /// Soft delete (§7.4). Both the application's tombstone and its tombstoned
  /// timeline have to reach the other devices, or they would keep their live
  /// copies and push them back.
  ///
  /// Returns everything [restoreApplication] needs to put it back, read off
  /// disk rather than taken from [application]: the caller's copy comes from a
  /// list that lags an in-flight save, and restoring from a stale snapshot
  /// would quietly roll the last edit back with it.
  Future<JobApplicationSnapshot> deleteApplication(
    JobApplication application,
  ) async {
    final snapshot = JobApplicationSnapshot(
      application: await _repository.getApplication(application.id) ?? application,
      events: await _repository.listStatusEvents(application.id),
    );
    final result = await _repository.deleteApplication(application.id);
    _sync.pushJobApplication(result.application);
    await _sync.pushJobStatusEventsBatch(result.events);
    _invalidate(jobStatusEventsProvider(application.id));
    _refreshApplications();
    return snapshot;
  }

  /// Undoes [deleteApplication] from the snapshot it returned.
  ///
  /// Both halves are rebuilt rather than `copyWith`'d: `copyWith` reads
  /// `deletedAt ?? this.deletedAt`, so it cannot clear a tombstone.
  Future<void> restoreApplication(JobApplicationSnapshot snapshot) async {
    final application = snapshot.application;
    // The versions below are resolved against disk rather than against the
    // snapshot — see [restoreVersionFrom].
    final current = await _repository.getApplication(application.id);
    abortIfAlreadyRestored(
      found: current != null,
      deletedAt: current?.deletedAt,
    );
    final restored = JobApplication(
      id: application.id,
      createdAt: application.createdAt,
      updatedAt: utcNow(),
      version: restoreVersionFrom(
        preDeleteVersion: application.version,
        currentVersion: current?.version,
      ),
      company: application.company,
      title: application.title,
      status: application.status,
      dateApplied: application.dateApplied,
      applicationUrl: application.applicationUrl,
      notes: application.notes,
      seasonIds: application.seasonIds,
      fieldUpdatedAt: application.fieldUpdatedAt,
    );

    final onDisk = {
      for (final event in await _repository.listStatusEvents(
        application.id,
        includeDeleted: true,
      ))
        event.id: event,
    };
    final events = [
      for (final event in snapshot.events)
        JobStatusEvent(
          id: event.id,
          createdAt: event.createdAt,
          updatedAt: utcNow(),
          version: restoreVersionFrom(
            preDeleteVersion: event.version,
            currentVersion: onDisk[event.id]?.version,
          ),
          applicationId: event.applicationId,
          fromStatus: event.fromStatus,
          toStatus: event.toStatus,
          changedAt: event.changedAt,
        ),
    ];
    await _writeApplication(restored, events: events);
  }

  /// Files [application] under exactly [seasonIds] — the whole set, not a
  /// delta, so the callers that toggle one membership hand over the list they
  /// want to end up with.
  Future<void> setSeasons(
    JobApplication application,
    List<String> seasonIds,
  ) async {
    await saveApplication(
      application.copyWith(seasonIds: seasonIds),
      previous: application,
    );
  }

  JobStatusEvent _statusEvent(
    JobApplication application, {
    required String? from,
    required String to,
  }) {
    final now = utcNow();
    return JobStatusEvent(
      id: newId(),
      applicationId: application.id,
      fromStatus: from,
      toStatus: to,
      changedAt: now,
      createdAt: now,
      updatedAt: now,
    );
  }

  // ---- Stages -------------------------------------------------------------

  /// Adds a stage at the end of the list. False, with nothing written, when a
  /// live stage already has this name (case and surrounding space ignored):
  /// a status is matched by name, so two stages sharing one would both claim
  /// every application on it.
  Future<bool> addStage(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return true;
    final stages = await _repository.listStages();
    if (_stageNameTaken(stages, trimmed)) return false;
    final now = utcNow();
    final stage = JobStage(
      id: newId(),
      name: trimmed,
      sortOrder: _nextSortOrder(stages.map((s) => s.sortOrder)),
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertStage(stage);
    _sync.pushJobStage(stage);
    _invalidate(jobStagesProvider);
    return true;
  }

  /// Renames the stage for future selections only. Applications keep the
  /// status string they were set to and the timeline keeps its recorded
  /// strings (§4.2), so an application on the old name becomes an orphan —
  /// which the table and the Sankey both render as its own entry.
  ///
  /// False, with nothing written, when another live stage already has the
  /// name — see [addStage].
  Future<bool> renameStage(JobStage stage, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == stage.name) return true;
    final others = [
      for (final other in await _repository.listStages())
        if (other.id != stage.id) other,
    ];
    if (_stageNameTaken(others, trimmed)) return false;
    final updated = stage.copyWith(name: trimmed);
    await _repository.upsertStage(updated);
    _sync.pushJobStage(updated);
    _invalidate(jobStagesProvider);
    // The rename can strand applications on the old string, and whether a
    // status is an orphan is what decides where it sorts.
    _refreshApplications();
    return true;
  }

  bool _stageNameTaken(Iterable<JobStage> stages, String name) {
    final key = jobCompanyKey(name);
    return stages.any((stage) => jobCompanyKey(stage.name) == key);
  }

  /// One past the highest order in use. Not the list's length: deleting never
  /// renumbers the survivors, so the length can name an order still taken.
  int _nextSortOrder(Iterable<int> orders) =>
      orders.isEmpty ? 0 : orders.reduce(math.max) + 1;

  /// Sets the stage's colour, or clears it back to the position-derived one.
  /// Applications are untouched: a stage's colour is a display property of the
  /// pipeline, not something copied onto the rows sitting on it.
  Future<void> setStageColor(JobStage stage, int? colorValue) async {
    if (colorValue == stage.colorValue) return;
    final updated = stage.copyWith(
      colorValue: colorValue,
      clearColorValue: colorValue == null,
    );
    await _repository.upsertStage(updated);
    _sync.pushJobStage(updated);
    _invalidate(jobStagesProvider);
  }

  Future<void> deleteStage(JobStage stage) async {
    final tombstone = await _repository.softDeleteStage(stage.id);
    if (tombstone != null) _sync.pushJobStage(tombstone);
    _invalidate(jobStagesProvider);
    _refreshApplications();
  }

  Future<void> reorderStages(List<String> orderedIds) async {
    final written = await _repository.reorderStages(orderedIds);
    await _sync.pushJobStagesBatch(written);
    _invalidate(jobStagesProvider);
  }

  // ---- Companies, categories, seasons -------------------------------------

  Future<void> setCompanyCategory(
    JobCompany company,
    String? categoryId,
  ) async {
    final updated = company.copyWith(
      categoryId: categoryId,
      clearCategoryId: categoryId == null,
    );
    await _repository.upsertCompany(updated);
    _sync.pushJobCompany(updated);
    _invalidate(jobCompaniesProvider);
  }

  Future<void> deleteCompany(JobCompany company) async {
    final tombstone = await _repository.softDeleteCompany(company.id);
    if (tombstone != null) _sync.pushJobCompany(tombstone);
    _invalidate(jobCompaniesProvider);
  }

  Future<void> addCategory(String name, int colorValue) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final categories = await _repository.listCategories();
    final now = utcNow();
    final category = JobCategory(
      id: newId(),
      name: trimmed,
      colorValue: colorValue,
      sortOrder: _nextSortOrder(categories.map((c) => c.sortOrder)),
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertCategory(category);
    _sync.pushJobCategory(category);
    _invalidate(jobCategoriesProvider);
  }

  Future<void> updateCategory(
    JobCategory category, {
    String? name,
    int? colorValue,
  }) async {
    final updated = category.copyWith(name: name, colorValue: colorValue);
    await _repository.upsertCategory(updated);
    _sync.pushJobCategory(updated);
    _invalidate(jobCategoriesProvider);
  }

  Future<void> deleteCategory(JobCategory category) async {
    final result = await _repository.softDeleteCategory(category.id);
    if (result.tombstone case final tombstone?) {
      _sync.pushJobCategory(tombstone);
    }
    await _sync.pushJobCompaniesBatch(result.orphaned);
    _invalidate(jobCategoriesProvider);
    _invalidate(jobCompaniesProvider);
  }

  Future<void> addSeason(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final seasons = await _repository.listSeasons();
    final now = utcNow();
    final season = JobSeason(
      id: newId(),
      name: trimmed,
      sortOrder: _nextSortOrder(seasons.map((s) => s.sortOrder)),
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertSeason(season);
    _sync.pushJobSeason(season);
    _invalidate(jobSeasonsProvider);
  }

  Future<void> reorderSeasons(List<String> orderedIds) async {
    final written = await _repository.reorderSeasons(orderedIds);
    await _sync.pushJobSeasonsBatch(written);
    _invalidate(jobSeasonsProvider);
  }

  /// Retires a season, or brings it back. This is the only thing that archives
  /// an application: every application filed under [season] follows it, and
  /// nothing about the applications themselves is rewritten.
  Future<void> setSeasonArchived(JobSeason season, bool archived) async {
    if (season.isArchived == archived) return;
    final updated = season.copyWith(
      archivedAt: archived ? utcNow() : null,
      clearArchivedAt: !archived,
    );
    await _repository.upsertSeason(updated);
    _sync.pushJobSeason(updated);
    _invalidate(jobSeasonsProvider);
    // Archived-ness is what the list filters on, so the rows have to be
    // re-evaluated even though none of them changed.
    _refreshApplications();
  }

  Future<void> renameSeason(JobSeason season, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == season.name) return;
    final updated = season.copyWith(name: trimmed);
    await _repository.upsertSeason(updated);
    _sync.pushJobSeason(updated);
    _invalidate(jobSeasonsProvider);
  }

  Future<void> deleteSeason(JobSeason season) async {
    final result = await _repository.softDeleteSeason(season.id);
    if (result.tombstone case final tombstone?) _sync.pushJobSeason(tombstone);
    await _sync.pushJobApplicationsBatch(result.released);
    _invalidate(jobSeasonsProvider);
    _refreshApplications();
  }
}

/// An application and its status timeline as they stood the instant before a
/// delete — everything [JobsActions.restoreApplication] needs to put both back.
class JobApplicationSnapshot {
  const JobApplicationSnapshot({required this.application, required this.events});

  final JobApplication application;
  final List<JobStatusEvent> events;
}
