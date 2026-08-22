import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/settings/services/data_export_service.dart';
import 'package:voyager/features/settings/services/data_import_service.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';
import 'package:voyager/domain/services/weather_service.dart';
import 'package:voyager/core/sync/debouncer.dart';
import '../test/fakes/fake_weather_api_client.dart';

class FakeAuthRepository implements AuthRepository {
  @override
  String? get currentUserId => 'test-user-123';

  @override
  Stream<bool> get authStateChanges => Stream.value(true);

  @override
  Future<void> signInWithEmail(String email, String password) async {}
  @override
  Future<void> signUpWithEmail(String email, String password) async {}
  @override
  Future<void> sendPasswordResetEmail(String email) async {}
  @override
  Future<void> signInWithGoogle() async {}
  @override
  Future<void> signOut() async {}
}

class ThrowingJournalRepository extends DriftJournalRepository {
  ThrowingJournalRepository(super.db);

  @override
  Future<void> upsertEntry(
    JournalEntry entry, {
    bool recordLocalActivity = true,
  }) async {
    if (entry.title == 'throw') {
      throw Exception('Forced SQLite exception');
    }
    return super.upsertEntry(entry, recordLocalActivity: recordLocalActivity);
  }
}

/// Stands in for the sync layer so tests can assert what a restore uploaded.
class RecordingUploader {
  final Map<String, List<Object>> records = {};
  AppSettings? settings;

  Future<void> pushRecords(String collection, List<Object> pushed) async {
    (records[collection] ??= []).addAll(pushed);
  }

  Future<void> pushSettings(AppSettings pushed) async => settings = pushed;
}

class MockFirestoreBatch extends Fake implements WriteBatch {
  int commitCount = 0;
  List<Map<String, dynamic>> sets = [];

  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) {
    sets.add({
      'path': document.path,
      'data': data,
    });
  }

  @override
  Future<void> commit() async {
    commitCount++;
  }
}

class MockFirebaseFirestore extends Fake implements FirebaseFirestore {
  int batchCreatedCount = 0;
  final List<MockFirestoreBatch> batches = [];

  @override
  WriteBatch batch() {
    batchCreatedCount++;
    final b = MockFirestoreBatch();
    batches.add(b);
    return b;
  }

  @override
  DocumentReference<Map<String, dynamic>> doc(String documentPath) {
    return MockDocumentReference(documentPath);
  }
}

class MockDocumentReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  MockDocumentReference(this.path);

  @override
  final String path;
}

List<BackupCollection> collectionsFor(AppDatabase db) => buildBackupCollections(
  journalRepository: DriftJournalRepository(db),
  dreamRepository: DriftDreamRepository(db),
  todoRepository: DriftTodoRepository(db),
  leetCodeRepository: DriftLeetCodeRepository(db),
  studyRepository: DriftStudyRepository(db),
  workoutRepository: DriftWorkoutRepository(db),
  jobRepository: DriftJobRepository(db),
  calendarRepository: DriftCalendarRepository(db),
  trackerRepository: DriftTrackerRepository(db),
  financeRepository: DriftFinanceRepository(db),
  notificationRepository: DriftNotificationRepository(db),
  bucketListRepository: DriftBucketListRepository(db),
  settingsRepository: DriftSettingsRepository(db),
);

DataExportService exporterFor(AppDatabase db) => DataExportService(
  collections: collectionsFor(db),
  settingsRepository: DriftSettingsRepository(db),
);

DataImportService importerFor(
  AppDatabase db,
  RecordingUploader uploader, {
  List<BackupCollection>? collections,
}) => DataImportService(
  db: db,
  collections: collections ?? collectionsFor(db),
  settingsRepository: DriftSettingsRepository(db),
  pushRecords: uploader.pushRecords,
  pushSettings: uploader.pushSettings,
);

/// Writes a backup zip to a temp file so it can go through the real
/// [DataImportService.importFromZip] path, isolate and all.
Future<File> writeBackupZip(Map<String, Object> contents, String name) async {
  final file = File('${Directory.systemTemp.path}/$name.zip');
  await file.writeAsBytes(generateBackupZipIsolate(contents));
  return file;
}

/// One record in every synced collection, each with a value distinctive
/// enough that a mapper dropping a field shows up as a round-trip difference.
Future<void> seedOneOfEverything(AppDatabase db) async {
  final now = DateTime.utc(2026, 3, 4, 5, 6, 7);
  final journalRepo = DriftJournalRepository(db);
  final dreamRepo = DriftDreamRepository(db);
  final todoRepo = DriftTodoRepository(db);
  final leetCodeRepo = DriftLeetCodeRepository(db);
  final studyRepo = DriftStudyRepository(db);
  final workoutRepo = DriftWorkoutRepository(db);
  final calendarRepo = DriftCalendarRepository(db);
  final trackerRepo = DriftTrackerRepository(db);
  final financeRepo = DriftFinanceRepository(db);
  final notificationRepo = DriftNotificationRepository(db);
  final bucketListRepo = DriftBucketListRepository(db);
  final settingsRepo = DriftSettingsRepository(db);
  final jobRepo = DriftJobRepository(db);

  await journalRepo.upsertJournal(
    Journal(
      id: 'journal-1',
      name: 'Field Notes',
      colorValue: 0xFF112233,
      guidedJournaling: true,
      promptCycleDays: 3,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await journalRepo.upsertEntry(
    JournalEntry(
      id: 'entry-1',
      journalId: 'journal-1',
      title: 'A day out',
      body: 'It rained.',
      entryDate: now,
      tags: const ['weather', 'walk'],
      mood: 4,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await dreamRepo.upsertEntry(
    DreamEntry(
      id: 'dream-1',
      title: 'Falling',
      body: 'Endless stairs.',
      entryDate: now,
      notes: 'recurring',
      tags: const ['stairs'],
      createdAt: now,
      updatedAt: now,
    ),
  );
  await todoRepo.upsertList(
    TodoListModel(
      id: 'list-1',
      name: 'Errands',
      colorValue: 0xFF445566,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await todoRepo.upsertTask(
    TodoTask(
      id: 'task-1',
      listId: 'list-1',
      title: 'Buy stamps',
      notes: 'post office',
      dueDate: now,
      starred: true,
      sortOrder: 7,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await leetCodeRepo.upsertProblem(
    LeetCodeProblem(
      id: 'lc-1',
      title: 'Two Sum',
      difficulty: LeetCodeDifficulty.easy,
      tags: const ['array'],
      solutions: const [
        LeetCodeSolution(
          algorithm: 'hash map',
          explanation: 'complement lookup',
          code: 'def two_sum(): pass',
        ),
      ],
      solvedAt: now,
      ease: 2.7,
      reviewCount: 3,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await studyRepo.upsertFolder(
    StudyFolder(id: 'folder-1', name: 'Biology', createdAt: now, updatedAt: now),
  );
  await studyRepo.upsertDeck(
    StudyDeck(
      id: 'deck-1',
      name: 'Cells',
      parentFolderId: 'folder-1',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await studyRepo.upsertCard(
    StudyCard(
      id: 'card-1',
      deckId: 'deck-1',
      frontText: 'Mitochondria?',
      backText: 'Powerhouse',
      dueAt: now,
      interval: 1.5,
      reviewCount: 2,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await studyRepo.logReview(
    StudyReviewLog(
      id: 'review-1',
      cardId: 'card-1',
      grade: StudyGrade.good,
      reviewedAt: now,
    ),
  );
  await workoutRepo.upsertExercise(
    Exercise(
      id: 'exercise-1',
      name: 'Squat',
      formCues: 'chest up',
      targetWeightKg: 60,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await workoutRepo.upsertPlan(
    WorkoutPlan(
      id: 'plan-1',
      name: 'Week A',
      mode: WorkoutPlanMode.weekly,
      cycleAnchor: now,
      isActive: true,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await workoutRepo.upsertPlanEntry(
    WorkoutPlanEntry(
      id: 'plan-entry-1',
      planId: 'plan-1',
      dayIndex: 2,
      exerciseId: 'exercise-1',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await workoutRepo.upsertSession(
    WorkoutSession(
      id: 'session-1',
      planId: 'plan-1',
      dayIndex: 2,
      date: now,
      startedAt: now,
      endedAt: now.add(const Duration(hours: 1)),
      createdAt: now,
      updatedAt: now,
    ),
  );
  await workoutRepo.upsertSetLog(
    WorkoutSetLog(
      id: 'set-log-1',
      sessionId: 'session-1',
      exerciseId: 'exercise-1',
      exerciseOrder: 0,
      setIndex: 1,
      weightKg: 62.5,
      reps: 5,
      plannedWeightKg: 60,
      plannedReps: 5,
      completed: true,
      completedAt: now,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await settingsRepo.upsertCustomQuote(
    CustomQuote(
      id: 'quote-1',
      text: 'Keep going.',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await calendarRepo.upsertCalendar(
    Calendar(
      id: 'calendar-1',
      name: 'Personal',
      colorValue: 0xFF778899,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await calendarRepo.upsertEvent(
    CalendarEvent(
      id: 'event-1',
      calendarId: 'calendar-1',
      title: 'Dentist',
      start: now,
      end: now.add(const Duration(hours: 1)),
      isFullDay: false,
      notes: 'bring card',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await trackerRepo.upsertTracker(
    StatisticTracker(
      id: 'tracker-1',
      name: 'Water',
      type: TrackerType.integer,
      cadence: TrackerCadence.daily,
      integerCap: 8,
      starred: true,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await trackerRepo.upsertValue(
    TrackerValue(
      id: 'tracker-value-1',
      trackerId: 'tracker-1',
      periodStart: now,
      intValue: 6,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await financeRepo.upsertCategory(
    FinanceCategory(
      id: 'category-1',
      name: 'Groceries',
      tags: const ['food'],
      createdAt: now,
      updatedAt: now,
    ),
  );
  await financeRepo.upsertTransaction(
    FinancialTransaction(
      id: 'transaction-1',
      type: TransactionType.expense,
      amountCents: 1234,
      occurredAt: now,
      note: 'market',
      tags: const ['food'],
      createdAt: now,
      updatedAt: now,
    ),
  );
  await financeRepo.upsertSubscription(
    Subscription(
      id: 'subscription-1',
      name: 'Streaming',
      amountCents: 999,
      period: BillingPeriod.monthly,
      anchorDueDate: now,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await financeRepo.upsertBudget(
    Budget(
      id: 'budget-1',
      tag: 'food',
      limitCents: 50000,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await financeRepo.upsertAsset(
    Asset(id: 'asset-1', name: 'Savings', createdAt: now, updatedAt: now),
  );
  await financeRepo.upsertAssetValuation(
    AssetValuation(
      id: 'valuation-1',
      assetId: 'asset-1',
      valueCents: 1000000,
      asOf: now,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await financeRepo.upsertSavingsGoal(
    SavingsGoal(
      id: 'goal-1',
      name: 'Trip',
      targetCents: 200000,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await financeRepo.upsertGoalAllocation(
    GoalAllocation(
      id: 'allocation-1',
      goalId: 'goal-1',
      amountCents: 5000,
      allocatedAt: now,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await notificationRepo.upsertPinnedNote(
    PinnedNote(
      id: 'note-1',
      text: 'Call the vet',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await notificationRepo.upsertDismissal(
    DismissedNotification(
      key: 'task:task-1',
      dismissedAt: now,
      updatedAt: now,
    ),
  );
  await bucketListRepo.upsertItem(
    BucketListItem(
      id: 'bucket-1',
      title: 'See the aurora',
      note: 'winter',
      sortOrder: 2,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await jobRepo.upsertStage(
    JobStage(
      id: 'stage-1',
      name: 'Applied',
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await jobRepo.upsertCategory(
    JobCategory(
      id: 'job-category-1',
      name: 'Big Tech',
      colorValue: 0xFF3366CC,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await jobRepo.upsertSeason(
    JobSeason(id: 'season-1', name: 'Fall 2025', createdAt: now, updatedAt: now),
  );
  await jobRepo.upsertCompany(
    JobCompany(
      id: 'job-company-1',
      name: 'Datadog',
      categoryId: 'job-category-1',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await jobRepo.upsertApplication(
    JobApplication(
      id: 'application-1',
      company: 'Datadog',
      title: 'Software Engineer',
      status: 'Applied',
      dateApplied: now,
      applicationUrl: 'https://example.com/job',
      notes: 'Referred by #alex',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await jobRepo.upsertStatusEvent(
    JobStatusEvent(
      id: 'status-event-1',
      applicationId: 'application-1',
      toStatus: 'Applied',
      changedAt: now,
      createdAt: now,
      updatedAt: now,
    ),
  );
  await settingsRepo.setTagColor('food', 0xFF00FF00);
  await settingsRepo.addCustomWord('voyagerish');
}

void main() {
  group('Backup coverage', () {
    test('every synced collection is in the backup registry', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);

      final names = collectionsFor(db).map((c) => c.name).toList();

      expect(names.toSet(), FirestoreCollections.records);
      expect(
        names.length,
        names.toSet().length,
        reason: 'a collection listed twice would be restored twice',
      );
      await db.close();
    });

    test('containers are restored before the records that point at them', () {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final names = collectionsFor(db).map((c) => c.name).toList();

      void expectBefore(String container, String child) {
        expect(
          names.indexOf(container),
          lessThan(names.indexOf(child)),
          reason: '$container has to be restored before $child',
        );
      }

      expectBefore(
        FirestoreCollections.journals,
        FirestoreCollections.journalEntries,
      );
      expectBefore(
        FirestoreCollections.todoLists,
        FirestoreCollections.todoTasks,
      );
      expectBefore(
        FirestoreCollections.calendars,
        FirestoreCollections.calendarEvents,
      );
      expectBefore(
        FirestoreCollections.trackers,
        FirestoreCollections.trackerValues,
      );
      expectBefore(
        FirestoreCollections.studyFolders,
        FirestoreCollections.studyDecks,
      );
      expectBefore(
        FirestoreCollections.studyDecks,
        FirestoreCollections.studyCards,
      );
      expectBefore(
        FirestoreCollections.studyCards,
        FirestoreCollections.studyReviewLog,
      );
      expectBefore(
        FirestoreCollections.workoutPlans,
        FirestoreCollections.workoutPlanEntries,
      );
      expectBefore(
        FirestoreCollections.workoutSessions,
        FirestoreCollections.workoutSetLogs,
      );
      expectBefore(FirestoreCollections.assets, FirestoreCollections.assetValuations);
      expectBefore(
        FirestoreCollections.savingsGoals,
        FirestoreCollections.goalAllocations,
      );
    });

    // A tripwire, not a description: adding a table should fail this test, so
    // that whoever adds it decides whether it belongs in a backup rather than
    // leaving it out by accident.
    test('every table is either backed up or knowingly left out', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);

      const backedUp = {
        'journals_table',
        'journal_entries_table',
        'dream_entries_table',
        'todo_lists_table',
        'todo_tasks_table',
        'leet_code_problems_table',
        'study_folders_table',
        'study_decks_table',
        'study_cards_table',
        'study_review_log_table',
        'exercises_table',
        'workout_plans_table',
        'workout_plan_entries_table',
        'workout_sessions_table',
        'workout_set_logs_table',
        'custom_quotes_table',
        'calendars_table',
        'calendar_events_table',
        'trackers_table',
        'tracker_values_table',
        'transactions_table',
        'subscriptions_table',
        'budgets_table',
        'finance_categories_table',
        'assets_table',
        'asset_valuations_table',
        'savings_goals_table',
        'goal_allocations_table',
        'pinned_notes_table',
        'dismissed_notifications_table',
        'bucket_list_items_table',
        'job_applications_table',
        'job_status_events_table',
        'job_stages_table',
        'job_companies_table',
        'job_categories_table',
        'job_seasons_table',
        'tag_colors_table',
        'custom_words_table',
        // Not a collection of records, but exported as its own document.
        'settings_table',
      };
      const localOnly = {
        // Queued uploads and unresolved conflicts describe this device's
        // relationship with the server, not anything the user wrote.
        'pending_uploads_table',
        'sync_conflicts_table',
      };

      expect(
        db.allTables.map((t) => t.actualTableName).toSet(),
        {...backedUp, ...localOnly},
        reason: 'a new table must be added to buildBackupCollections, or '
            'listed here as deliberately local-only',
      );
      await db.close();
    });
  });

  group('Backup round trip', () {
    test('restores every collection into an empty database', () async {
      final source = AppDatabase.inMemory();
      await seedOneOfEverything(source);
      final exported = await exporterFor(source).buildArchiveContents();
      final zip = await writeBackupZip(exported, 'voyager_roundtrip');

      // Every collection must have actually held something, or the comparison
      // below would pass on emptiness.
      final manifest = exported['manifest.json'] as Map<String, dynamic>;
      final counts = manifest['collections'] as Map<String, int>;
      for (final name in FirestoreCollections.records) {
        expect(counts[name], greaterThan(0), reason: '$name was not seeded');
      }

      final target = AppDatabase.inMemory();
      final uploader = RecordingUploader();
      final summary = await importerFor(target, uploader).importFromZip(zip);

      expect(summary.restoredTotal, counts.values.reduce((a, b) => a + b));
      expect(summary.skipped, 0);

      // Re-exporting the restored database must reproduce the backup, field
      // for field, for every collection.
      final restored = await exporterFor(target).buildArchiveContents();
      for (final name in FirestoreCollections.records) {
        final before = (exported['$name.json'] as List)
            .cast<Map<String, dynamic>>();
        final after = (restored['$name.json'] as List)
            .cast<Map<String, dynamic>>();
        expect(after.length, before.length, reason: '$name lost records');
        final afterById = {
          for (final record in after) record['id'] as String: record,
        };
        for (final record in before) {
          final id = record['id'] as String;
          expect(afterById.containsKey(id), isTrue, reason: '$name/$id missing');
          expect(
            backupContentEquals(
              afterById[id]!['data'] as Map<String, dynamic>,
              record['data'] as Map<String, dynamic>,
            ),
            isTrue,
            reason: '$name/$id came back different:\n'
                'expected ${record['data']}\n'
                'actual   ${afterById[id]!['data']}',
          );
        }
      }

      await zip.delete();
      await source.close();
      await target.close();
    });

    test('restores settings and uploads them once', () async {
      final source = AppDatabase.inMemory();
      final sourceSettings = DriftSettingsRepository(source);
      await sourceSettings.saveSettings(
        (await sourceSettings.getSettings()).copyWith(
          accentColor: 0xFF00CCFF,
          weekStartsOnMonday: false,
          alertTimeHour: 21,
        ),
      );
      final zip = await writeBackupZip(
        await exporterFor(source).buildArchiveContents(),
        'voyager_settings',
      );

      final target = AppDatabase.inMemory();
      final uploader = RecordingUploader();
      final summary = await importerFor(target, uploader).importFromZip(zip);

      expect(summary.settingsRestored, isTrue);
      final restored = await DriftSettingsRepository(target).getSettings();
      expect(restored.accentColor, 0xFF00CCFF);
      expect(restored.weekStartsOnMonday, isFalse);
      expect(restored.alertTimeHour, 21);
      expect(uploader.settings?.accentColor, 0xFF00CCFF);

      await zip.delete();
      await source.close();
      await target.close();
    });

    test('device-local settings stay on the device', () async {
      // The export reuses the sync payload, which deliberately omits fields
      // that describe this device rather than the account.
      final db = AppDatabase.inMemory();
      final settingsRepo = DriftSettingsRepository(db);
      await settingsRepo.saveSettings(
        (await settingsRepo.getSettings()).copyWith(deviceId: 'device-abc'),
      );

      final exported = await exporterFor(db).buildArchiveContents();
      final settings =
          exported['${FirestoreCollections.settings}.json']
              as Map<String, dynamic>;

      expect(settings.containsKey('deviceId'), isFalse);
      await db.close();
    });
  });

  group('Backup change detection', () {
    test('re-importing an unchanged backup writes and uploads nothing', () async {
      final db = AppDatabase.inMemory();
      await seedOneOfEverything(db);
      final exported = await exporterFor(db).buildArchiveContents();
      final zip = await writeBackupZip(exported, 'voyager_unchanged');

      final uploader = RecordingUploader();
      final summary = await importerFor(db, uploader).importFromZip(zip);

      expect(summary.restoredTotal, 0);
      expect(summary.restoredByCollection, isEmpty);
      expect(summary.settingsRestored, isFalse);
      expect(uploader.records, isEmpty);
      expect(uploader.settings, isNull);

      final manifest = exported['manifest.json'] as Map<String, dynamic>;
      final counts = manifest['collections'] as Map<String, int>;
      expect(summary.skipped, counts.values.reduce((a, b) => a + b));

      await zip.delete();
      await db.close();
    });

    test('only the records that differ are restored and uploaded', () async {
      final db = AppDatabase.inMemory();
      await seedOneOfEverything(db);
      final zip = await writeBackupZip(
        await exporterFor(db).buildArchiveContents(),
        'voyager_changed',
      );

      // Edit one entry after taking the backup. Restoring should put the
      // backup's text back and leave every other collection alone.
      final journalRepo = DriftJournalRepository(db);
      final edited = (await journalRepo.getEntry('entry-1'))!;
      await journalRepo.upsertEntry(
        edited.copyWith(body: 'Edited after the backup was taken'),
      );

      final uploader = RecordingUploader();
      final summary = await importerFor(db, uploader).importFromZip(zip);

      expect(summary.restoredByCollection, {
        FirestoreCollections.journalEntries: 1,
      });
      expect(uploader.records.keys, [FirestoreCollections.journalEntries]);
      expect(uploader.records[FirestoreCollections.journalEntries], hasLength(1));

      final restored = (await journalRepo.getEntry('entry-1'))!;
      expect(restored.body, 'It rained.');

      await zip.delete();
      await db.close();
    });

    test('a restore outranks both the local row and the synced one', () async {
      final db = AppDatabase.inMemory();
      final journalRepo = DriftJournalRepository(db);
      final now = DateTime.utc(2026, 1, 1);
      await journalRepo.upsertJournal(
        Journal(id: 'j', name: 'J', createdAt: now, updatedAt: now),
      );
      await journalRepo.upsertEntry(
        JournalEntry(
          id: 'e',
          journalId: 'j',
          title: 'Backed up',
          body: 'original',
          entryDate: now,
          createdAt: now,
          updatedAt: now,
          version: 2,
        ),
      );
      final zip = await writeBackupZip(
        await exporterFor(db).buildArchiveContents(),
        'voyager_version',
      );

      // The row moves on after the backup — as it would after edits that
      // synced to other devices.
      final local = (await journalRepo.getEntry('e'))!;
      await journalRepo.upsertEntry(
        local.copyWith(body: 'much later', version: 9, bumpVersion: false),
      );

      final uploader = RecordingUploader();
      await importerFor(db, uploader).importFromZip(zip);

      final restored = (await journalRepo.getEntry('e'))!;
      expect(restored.body, 'original');
      expect(
        restored.version,
        10,
        reason: 'one past the higher of the local and backup versions, so the '
            'next pull cannot undo the restore',
      );

      await zip.delete();
      await db.close();
    });

    test('a tombstoned record restores as deleted, not as missing', () async {
      final db = AppDatabase.inMemory();
      final todoRepo = DriftTodoRepository(db);
      final now = DateTime.utc(2026, 1, 1);
      await todoRepo.upsertList(
        TodoListModel(id: 'l', name: 'L', createdAt: now, updatedAt: now),
      );
      await todoRepo.upsertTask(
        TodoTask(
          id: 't',
          listId: 'l',
          title: 'Gone',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await todoRepo.softDeleteTask('t');
      final zip = await writeBackupZip(
        await exporterFor(db).buildArchiveContents(),
        'voyager_tombstone',
      );

      final target = AppDatabase.inMemory();
      final uploader = RecordingUploader();
      await importerFor(target, uploader).importFromZip(zip);

      final restored = await DriftTodoRepository(target).getAllTasks();
      expect(restored, hasLength(1));
      expect(restored.single.deletedAt, isNotNull);

      await zip.delete();
      await db.close();
      await target.close();
    });
  });

  group('Backup format', () {
    test('rejects an archive with no manifest', () async {
      // The shape older backups had: journal entries under journals.json.
      final archive = Archive();
      final data = utf8.encode(jsonEncode([]));
      archive.addFile(ArchiveFile('journals.json', data.length, data));
      archive.addFile(ArchiveFile('tasks.json', data.length, data));
      final file = File('${Directory.systemTemp.path}/voyager_legacy.zip');
      await file.writeAsBytes(ZipEncoder().encode(archive)!);

      final db = AppDatabase.inMemory();
      await expectLater(
        importerFor(db, RecordingUploader()).importFromZip(file),
        throwsA(isA<BackupFormatException>()),
      );

      await file.delete();
      await db.close();
    });

    test('rejects a manifest from a different format version', () async {
      final zip = await writeBackupZip({
        'manifest.json': {'formatVersion': 99, 'collections': <String, int>{}},
      }, 'voyager_future');

      final db = AppDatabase.inMemory();
      await expectLater(
        importerFor(db, RecordingUploader()).importFromZip(zip),
        throwsA(isA<BackupFormatException>()),
      );

      await zip.delete();
      await db.close();
    });

    test('a failed restore leaves the database untouched', () async {
      final db = AppDatabase.inMemory();
      final journalRepo = DriftJournalRepository(db);
      final now = DateTime.utc(2026, 1, 1);
      await journalRepo.upsertJournal(
        Journal(id: 'j', name: 'J', createdAt: now, updatedAt: now),
      );
      await journalRepo.upsertEntry(
        JournalEntry(
          id: 'good',
          journalId: 'j',
          title: 'Good entry',
          body: 'I will survive',
          entryDate: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await journalRepo.upsertEntry(
        JournalEntry(
          id: 'bad',
          journalId: 'j',
          title: 'throw',
          body: 'I will throw',
          entryDate: now,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final exported = await exporterFor(db).buildArchiveContents();

      // Rebuild the entries so the backup differs from what is stored and the
      // restore actually has work to do.
      await journalRepo.upsertEntry(
        (await journalRepo.getEntry('good'))!.copyWith(body: 'changed'),
      );
      await journalRepo.upsertEntry(
        (await journalRepo.getEntry('bad'))!.copyWith(body: 'changed'),
      );
      final zip = await writeBackupZip(exported, 'voyager_rollback');

      final uploader = RecordingUploader();
      final importer = DataImportService(
        db: db,
        collections: buildBackupCollections(
          journalRepository: ThrowingJournalRepository(db),
          dreamRepository: DriftDreamRepository(db),
          todoRepository: DriftTodoRepository(db),
          leetCodeRepository: DriftLeetCodeRepository(db),
          studyRepository: DriftStudyRepository(db),
          workoutRepository: DriftWorkoutRepository(db),
          jobRepository: DriftJobRepository(db),
          calendarRepository: DriftCalendarRepository(db),
          trackerRepository: DriftTrackerRepository(db),
          financeRepository: DriftFinanceRepository(db),
          notificationRepository: DriftNotificationRepository(db),
          bucketListRepository: DriftBucketListRepository(db),
          settingsRepository: DriftSettingsRepository(db),
        ),
        settingsRepository: DriftSettingsRepository(db),
        pushRecords: uploader.pushRecords,
        pushSettings: uploader.pushSettings,
      );

      await expectLater(
        importer.importFromZip(zip),
        throwsA(isA<Exception>()),
      );

      // The restore of 'good' happened before 'bad' threw; the transaction
      // must have taken it back out again.
      expect((await journalRepo.getEntry('good'))!.body, 'changed');
      expect(uploader.records, isEmpty);

      await zip.delete();
      await db.close();
    });
  });

  group('Import / Export Unit Tests', () {
    test('DataExportService JSON Chunking Test', () {
      final entries = List.generate(
        10000,
        (index) => JournalEntry(
          id: 'entry-$index',
          journalId: 'journal-1',
          title: 'Entry $index',
          body: 'Body text $index',
          entryDate: DateTime.now().toUtc(),
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      final zipBytes = generateBackupZipIsolate({
        '${FirestoreCollections.journalEntries}.json': [
          for (final entry in entries)
            BackupRecord(
              id: entry.id,
              data: journalEntryToFirestore(entry),
            ).toJson(),
        ],
      });

      expect(zipBytes, isNotEmpty);

      final archive = ZipDecoder().decodeBytes(zipBytes);
      final journalFile = archive.findFile(
        '${FirestoreCollections.journalEntries}.json',
      );
      expect(journalFile, isNotNull);

      final content = utf8.decode(journalFile!.content as List<int>);
      final list = jsonDecode(content) as List;
      expect(list.length, 10000);
      expect(list[0]['id'], 'entry-0');
    });

    test('OutboxSyncWorker Batch Limit Test', () async {
      final db = AppDatabase.inMemory();
      final mockFirestore = MockFirebaseFirestore();
      final fakeAuth = FakeAuthRepository();

      await db.transaction(() async {
        for (int i = 0; i < 1200; i++) {
          final entryId = 'entry-$i';
          await db.into(db.journalEntriesTable).insert(
            JournalEntriesTableCompanion.insert(
              id: entryId,
              journalId: 'journal-1',
              title: 'Entry $i',
              body: 'Body $i',
              entryDate: DateTime.now().toUtc(),
              createdAt: DateTime.now().toUtc(),
              updatedAt: DateTime.now().toUtc(),
            ),
          );
          await db.into(db.pendingUploadsTable).insert(
            PendingUploadsTableCompanion.insert(
              documentId: entryId,
              collectionName: FirestoreCollections.journalEntries,
            ),
          );
        }
      });

      OutboxSyncWorker.initialize(
        db,
        mockFirestore,
        fakeAuth,
        yieldDelay: Duration.zero,
      );
      await OutboxSyncWorker.instance.startDraining();

      expect(mockFirestore.batchCreatedCount, 3);
      expect(mockFirestore.batches[0].sets.length, 500);
      expect(mockFirestore.batches[1].sets.length, 500);
      expect(mockFirestore.batches[2].sets.length, 200);

      final remains = await db.select(db.pendingUploadsTable).get();
      expect(remains, isEmpty);

      await db.close();
    });

    group('Import / Export Integration Tests', () {
      test('The App Force-Close Failsafe Test', () async {
        final db = AppDatabase.inMemory();
        final fakeFirestore = FakeFirebaseFirestore();
        final fakeAuth = FakeAuthRepository();

        final entryId = 'entry-force-close-123';
        // 1. Insert record to SQLite directly
        await db.into(db.journalEntriesTable).insert(
          JournalEntriesTableCompanion.insert(
            id: entryId,
            journalId: 'journal-1',
            title: 'Unsaved Title',
            body: 'Pending upload',
            entryDate: DateTime.now().toUtc(),
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        // 2. Insert into PendingUploadsTable (simulating force-closed outbox state)
        await db.into(db.pendingUploadsTable).insert(
          PendingUploadsTableCompanion.insert(
            documentId: entryId,
            collectionName: FirestoreCollections.journalEntries,
          ),
        );

        OutboxSyncWorker.initialize(
          db,
          fakeFirestore,
          fakeAuth,
          yieldDelay: Duration.zero,
        );
        await OutboxSyncWorker.instance.startDraining();

        // 3. Query fake firestore
        final snap = await fakeFirestore
            .doc('users/test-user-123/${FirestoreCollections.journalEntries}/$entryId')
            .get();
        expect(snap.exists, isTrue);
        expect(snap.data()?['title'], 'Unsaved Title');

        // 4. Local outbox should now be empty
        final pending = await db.select(db.pendingUploadsTable).get();
        expect(pending, isEmpty);

        await db.close();
      });

      test('The "In-Flight Merge" Collision Test', () async {
        final db = AppDatabase.inMemory();
        final fakeFirestore = FakeFirebaseFirestore();
        final fakeAuth = FakeAuthRepository();
        final journalRepo = DriftJournalRepository(db);
        final dreamRepo = DriftDreamRepository(db);
        final todoRepo = DriftTodoRepository(db);
        final leetCodeRepo = DriftLeetCodeRepository(db);
        final studyRepo = DriftStudyRepository(db);

        final docId = 'collision-doc-999';
        final now = DateTime.now().toUtc();

        // Setup local version in SQLite
        await journalRepo.upsertEntry(
          JournalEntry(
            id: docId,
            journalId: 'journal-1',
            title: 'Local Version',
            body: 'Local body',
            entryDate: now,
            createdAt: now,
            updatedAt: now,
            version: 1,
          ),
        );

        // Add to pending outbox (simulating in-flight change)
        await db.into(db.pendingUploadsTable).insert(
          PendingUploadsTableCompanion.insert(
            documentId: docId,
            collectionName: FirestoreCollections.journalEntries,
          ),
        );

        // Set up Sync Repository & Remote Sync Service
        final syncRepo = FirestoreSyncRepository(fakeFirestore, fakeAuth.currentUserId!);
        final syncEngine = SyncEngine(
          syncRepository: syncRepo,
          deviceId: 'device-test',
          debouncer: Debouncer(delay: Duration.zero),
        );
        final weatherService = WeatherService(
          settingsRepository: DriftSettingsRepository(db),
          syncRepository: syncRepo,
          weatherApiClient: FakeWeatherApiClient(),
          deviceId: 'device-test',
        );
        final remoteSync = RemoteSyncService(
          syncRepository: syncRepo,
          journalRepository: journalRepo,
          dreamRepository: dreamRepo,
          todoRepository: todoRepo,
          leetCodeRepository: leetCodeRepo,
          studyRepository: studyRepo,
          workoutRepository: DriftWorkoutRepository(db),
          jobRepository: DriftJobRepository(db),
          calendarRepository: DriftCalendarRepository(db),
          trackerRepository: DriftTrackerRepository(db),
          financeRepository: DriftFinanceRepository(db),
          notificationRepository: DriftNotificationRepository(db),
          bucketListRepository: DriftBucketListRepository(db),
          settingsRepository: DriftSettingsRepository(db),
          weatherService: weatherService,
          syncEngine: syncEngine,
          uploadDebounceDelay: Duration.zero,
        );

        // Manually push a NEWER version of the document directly to Firestore
        final remoteUpdated = now.add(const Duration(minutes: 5));
        await syncRepo.upsertDocument(
          FirestoreCollections.journalEntries,
          docId,
          journalEntryToFirestore(
            JournalEntry(
              id: docId,
              journalId: 'journal-1',
              title: 'Remote Version (Newer)',
              body: 'Remote body',
              entryDate: now,
              createdAt: now,
              updatedAt: remoteUpdated,
              version: 2,
            ),
          ),
        );

        // Trigger remote pull (collides and merges)
        await remoteSync.pullForCollection(FirestoreCollections.journalEntries);

        // Let's verify that the local sqlite now holds the merged/newer version
        final localEntry = await journalRepo.getEntry(docId);
        expect(localEntry?.title, 'Remote Version (Newer)');
        expect(localEntry?.version, 2);

        // Now fire OutboxSyncWorker
        OutboxSyncWorker.initialize(
          db,
          fakeFirestore,
          fakeAuth,
          yieldDelay: Duration.zero,
        );
        await OutboxSyncWorker.instance.startDraining();

        // Query the fake firestore - it should have pushed the NEWER merged version, not the old Local Version.
        final snap = await fakeFirestore
            .doc('users/test-user-123/${FirestoreCollections.journalEntries}/$docId')
            .get();
        expect(snap.data()?['title'], 'Remote Version (Newer)');
        expect(snap.data()?['version'], 2);

        await db.close();
        syncEngine.dispose();
      });

      test('pushRecords can upload every collection it is given', () async {
        // pushRecords used to know only the collections the sync backfill
        // needed; a restore hands it all of them.
        final db = AppDatabase.inMemory();
        final fakeFirestore = FakeFirebaseFirestore();
        final fakeAuth = FakeAuthRepository();
        final syncRepo = FirestoreSyncRepository(
          fakeFirestore,
          fakeAuth.currentUserId!,
        );
        final syncEngine = SyncEngine(
          syncRepository: syncRepo,
          deviceId: 'device-test',
          debouncer: Debouncer(delay: Duration.zero),
        );
        final remoteSync = RemoteSyncService(
          syncRepository: syncRepo,
          journalRepository: DriftJournalRepository(db),
          dreamRepository: DriftDreamRepository(db),
          todoRepository: DriftTodoRepository(db),
          leetCodeRepository: DriftLeetCodeRepository(db),
          studyRepository: DriftStudyRepository(db),
          workoutRepository: DriftWorkoutRepository(db),
          jobRepository: DriftJobRepository(db),
          calendarRepository: DriftCalendarRepository(db),
          trackerRepository: DriftTrackerRepository(db),
          financeRepository: DriftFinanceRepository(db),
          notificationRepository: DriftNotificationRepository(db),
          bucketListRepository: DriftBucketListRepository(db),
          settingsRepository: DriftSettingsRepository(db),
          weatherService: WeatherService(
            settingsRepository: DriftSettingsRepository(db),
            syncRepository: syncRepo,
            weatherApiClient: FakeWeatherApiClient(),
            deviceId: 'device-test',
          ),
          syncEngine: syncEngine,
          uploadDebounceDelay: Duration.zero,
        );
        OutboxSyncWorker.initialize(
          db,
          fakeFirestore,
          fakeAuth,
          yieldDelay: Duration.zero,
        );

        await seedOneOfEverything(db);
        for (final collection in collectionsFor(db)) {
          final records = await collection.read();
          expect(records, isNotEmpty, reason: '${collection.name} not seeded');
          await remoteSync.pushRecords(collection.name, [
            for (final record in records)
              await collection.restore(record.id, record.data),
          ]);

          final uploaded = await fakeFirestore
              .collection('users/test-user-123/${collection.name}')
              .get();
          expect(
            uploaded.docs,
            hasLength(records.length),
            reason: '${collection.name} did not reach Firestore — '
                'RemoteSyncService._recordDocument is probably missing a case',
          );
        }

        await db.close();
        syncEngine.dispose();
      });
    });
  });
}
