import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/job_constants.dart';
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
  const JobsActions(this._ref);

  final WidgetRef _ref;

  JobRepository get _repository => _ref.read(jobRepositoryProvider);
  RemoteSyncService get _sync => _ref.read(remoteSyncServiceProvider);

  void _refreshApplications() {
    _ref.invalidate(jobApplicationsProvider);
  }

  /// Creates an application from the minimum the panel requires, records the
  /// opening timeline entry, and adds the company to the typeahead if it is
  /// new. Returns the application so the caller can open it for editing.
  Future<JobApplication> createApplication({
    required String company,
    required String title,
    String? status,
    DateTime? dateApplied,
  }) async {
    final stages = await _ref.read(jobStagesProvider.future);
    final now = utcNow();
    final application = JobApplication(
      id: newId(),
      company: company.trim(),
      title: title.trim(),
      status:
          status ?? (stages.isNotEmpty ? stages.first.name : jobDefaultStage),
      dateApplied: dateApplied ?? jobDayKey(DateTime.now()),
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertApplication(application);
    _sync.pushJobApplication(application);
    await _recordStatusEvent(application, from: null, to: application.status);
    await _registerCompany(application.company);
    _refreshApplications();
    return application;
  }

  /// Saves an edited application. When [previous] carried a different status
  /// this also appends the timeline entry for the move, and when the company
  /// changed it adds the new name to the typeahead.
  Future<void> saveApplication(
    JobApplication application, {
    required JobApplication previous,
  }) async {
    await _repository.upsertApplication(application);
    _sync.pushJobApplication(application);
    if (application.status != previous.status) {
      await _recordStatusEvent(
        application,
        from: previous.status,
        to: application.status,
      );
    }
    if (jobCompanyKey(application.company) != jobCompanyKey(previous.company)) {
      await _registerCompany(application.company);
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
      seasonId: source.seasonId,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertApplication(copy);
    _sync.pushJobApplication(copy);
    await _recordStatusEvent(copy, from: null, to: copy.status);
    _refreshApplications();
    return copy;
  }

  /// Hard delete (§7.4). The repository leaves a content-wiped tombstone
  /// behind — see [JobRepository.deleteApplication] — and both it and the
  /// tombstoned timeline have to reach the other devices, or they would keep
  /// their live copies and push them back.
  Future<void> deleteApplication(JobApplication application) async {
    final result = await _repository.deleteApplication(application.id);
    _sync.pushJobApplication(result.application);
    await _sync.pushJobStatusEventsBatch(result.events);
    _ref.invalidate(jobStatusEventsProvider(application.id));
    _refreshApplications();
  }

  Future<void> setSeason(JobApplication application, String? seasonId) async {
    final updated = application.copyWith(
      seasonId: seasonId,
      clearSeasonId: seasonId == null,
    );
    await _repository.upsertApplication(updated);
    _sync.pushJobApplication(updated);
    _refreshApplications();
  }

  Future<void> _recordStatusEvent(
    JobApplication application, {
    required String? from,
    required String to,
  }) async {
    final now = utcNow();
    final event = JobStatusEvent(
      id: newId(),
      applicationId: application.id,
      fromStatus: from,
      toStatus: to,
      changedAt: now,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertStatusEvent(event);
    _sync.pushJobStatusEvent(event);
    _ref.invalidate(jobStatusEventsProvider(application.id));
  }

  Future<void> _registerCompany(String name) async {
    final added = await _repository.ensureCompany(name);
    if (added == null) return;
    _sync.pushJobCompany(added);
    _ref.invalidate(jobCompaniesProvider);
  }

  // ---- Stages -------------------------------------------------------------

  Future<void> addStage(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final stages = await _ref.read(jobStagesProvider.future);
    final now = utcNow();
    final stage = JobStage(
      id: newId(),
      name: trimmed,
      sortOrder: stages.length,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertStage(stage);
    _sync.pushJobStage(stage);
    _ref.invalidate(jobStagesProvider);
  }

  /// Renames the stage for future selections only. Applications keep the
  /// status string they were set to and the timeline keeps its recorded
  /// strings (§4.2), so an application on the old name becomes an orphan —
  /// which the table and the Sankey both render as its own entry.
  Future<void> renameStage(JobStage stage, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == stage.name) return;
    final updated = stage.copyWith(name: trimmed);
    await _repository.upsertStage(updated);
    _sync.pushJobStage(updated);
    _ref.invalidate(jobStagesProvider);
    // The rename can strand applications on the old string, and whether a
    // status is an orphan is what decides where it sorts.
    _refreshApplications();
  }

  Future<void> deleteStage(JobStage stage) async {
    await _repository.softDeleteStage(stage.id);
    final tombstoned = stage.copyWith(deletedAt: utcNow());
    _sync.pushJobStage(tombstoned);
    _ref.invalidate(jobStagesProvider);
    _refreshApplications();
  }

  Future<void> reorderStages(List<String> orderedIds) async {
    final written = await _repository.reorderStages(orderedIds);
    await _sync.pushJobStagesBatch(written);
    _ref.invalidate(jobStagesProvider);
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
    _ref.invalidate(jobCompaniesProvider);
  }

  Future<void> deleteCompany(JobCompany company) async {
    await _repository.softDeleteCompany(company.id);
    _sync.pushJobCompany(company.copyWith(deletedAt: utcNow()));
    _ref.invalidate(jobCompaniesProvider);
  }

  Future<void> addCategory(String name, int colorValue) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final categories = await _ref.read(jobCategoriesProvider.future);
    final now = utcNow();
    final category = JobCategory(
      id: newId(),
      name: trimmed,
      colorValue: colorValue,
      sortOrder: categories.length,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertCategory(category);
    _sync.pushJobCategory(category);
    _ref.invalidate(jobCategoriesProvider);
  }

  Future<void> updateCategory(
    JobCategory category, {
    String? name,
    int? colorValue,
  }) async {
    final updated = category.copyWith(name: name, colorValue: colorValue);
    await _repository.upsertCategory(updated);
    _sync.pushJobCategory(updated);
    _ref.invalidate(jobCategoriesProvider);
  }

  Future<void> deleteCategory(JobCategory category) async {
    final orphaned = await _repository.softDeleteCategory(category.id);
    _sync.pushJobCategory(category.copyWith(deletedAt: utcNow()));
    await _sync.pushJobCompaniesBatch(orphaned);
    _ref.invalidate(jobCategoriesProvider);
    _ref.invalidate(jobCompaniesProvider);
  }

  Future<void> addSeason(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final seasons = await _ref.read(jobSeasonsProvider.future);
    final now = utcNow();
    final season = JobSeason(
      id: newId(),
      name: trimmed,
      sortOrder: seasons.length,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.upsertSeason(season);
    _sync.pushJobSeason(season);
    _ref.invalidate(jobSeasonsProvider);
  }

  Future<void> renameSeason(JobSeason season, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == season.name) return;
    final updated = season.copyWith(name: trimmed);
    await _repository.upsertSeason(updated);
    _sync.pushJobSeason(updated);
    _ref.invalidate(jobSeasonsProvider);
  }

  Future<void> deleteSeason(JobSeason season) async {
    final released = await _repository.softDeleteSeason(season.id);
    _sync.pushJobSeason(season.copyWith(deletedAt: utcNow()));
    await _sync.pushJobApplicationsBatch(released);
    _ref.invalidate(jobSeasonsProvider);
    _refreshApplications();
  }
}
