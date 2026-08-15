import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/models/workout_models.dart';

import 'package:voyager/domain/models/sync_conflict.dart';

abstract class JournalRepository {
  Future<List<Journal>> listJournals({bool includeDeleted = false});
  Future<Journal?> getJournal(String id);
  Future<void> upsertJournal(Journal journal, {bool recordLocalActivity = true});
  Future<void> softDeleteJournal(String id);
  Future<void> softDeleteEntriesInJournal(String journalId);
  Future<void> deleteAllJournals();
  Future<void> deleteAllEntries();
  Future<void> reassignEntriesJournal(String fromJournalId, String toJournalId);

  Future<List<JournalEntry>> listEntries({
    String? journalId,
    DateTime? from,
    DateTime? to,
    int? limit,
    bool includeDeleted = false,
  });
  Future<Map<String, int>> countEntriesByJournal({bool includeDeleted = false});
  Future<JournalEntry?> getEntry(String id);
  Future<void> upsertEntry(JournalEntry entry, {bool recordLocalActivity = true});
  Future<void> softDeleteEntry(String id);
  Future<void> hardDeleteEntry(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<JournalEntry>> getAllEntries({bool includeDeleted = true});
}

abstract class DreamRepository {
  Future<List<DreamEntry>> listEntries({
    DateTime? from,
    DateTime? to,
    int? limit,
    bool includeDeleted = false,
  });
  Future<DreamEntry?> getEntry(String id);
  Future<void> upsertEntry(DreamEntry entry, {bool recordLocalActivity = true});
  Future<void> softDeleteEntry(String id);
  Future<void> hardDeleteEntry(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<DreamEntry>> getAllEntries({bool includeDeleted = true});
}

abstract class LeetCodeRepository {
  Future<List<LeetCodeProblem>> listProblems({bool includeDeleted = false});
  Future<LeetCodeProblem?> getProblem(String id);
  Future<void> upsertProblem(
    LeetCodeProblem problem, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteProblem(String id);
  Future<void> hardDeleteProblem(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<LeetCodeProblem>> getAllProblems({bool includeDeleted = true});
}

abstract class TodoRepository {
  Future<List<TodoListModel>> listLists({bool includeDeleted = false});
  Future<void> upsertList(TodoListModel list, {bool recordLocalActivity = true});
  Future<void> softDeleteList(String id);
  Future<void> softDeleteTasksInList(String listId);
  Future<void> reassignTasksList(String fromListId, String toListId);

  Future<List<TodoTask>> listTasks(
    String listId, {
    bool includeDeleted = false,
    bool topLevelOnly = true,
  });
  Future<List<TodoTask>> listSubtasks(String parentTaskId);
  Future<int> nextSortOrder(String listId);
  Future<void> upsertTask(TodoTask task, {bool recordLocalActivity = true});
  Future<void> upsertTasksBatch(
    List<TodoTask> tasks, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteTask(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<TodoTask>> getAllTasks({bool includeDeleted = true});
  Future<TodoTask?> getTask(String id);
}

abstract class CalendarRepository {
  Future<List<Calendar>> listCalendars({bool includeDeleted = false});
  Future<Calendar?> getCalendar(String id);

  /// [recordLocalActivity] is false when the write is applying a document
  /// pulled from Firestore. It suppresses the upload the write would otherwise
  /// trigger, so a download can't bounce straight back up.
  Future<void> upsertCalendar(
    Calendar calendar, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteCalendar(String id);
  Future<void> softDeleteEventsInCalendar(String calendarId);
  Future<void> reassignEventsCalendar(String fromCalendarId, String toCalendarId);

  Future<List<CalendarEvent>> listEvents({
    String? calendarId,
    DateTime? from,
    DateTime? to,
    bool includeDeleted = false,
  });
  Future<CalendarEvent?> getEvent(String id);
  Future<void> upsertEvent(
    CalendarEvent event, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteEvent(String id);
  Future<void> deleteAllEvents();
  Future<void> replaceGoogleEvents(List<CalendarEvent> events);
  Future<void> purgeExpiredDeleted(DateTime now);
}

abstract class TrackerRepository {
  Future<List<StatisticTracker>> listTrackers({bool includeDeleted = false});
  Future<StatisticTracker?> getTracker(String id);
  Future<void> upsertTracker(
    StatisticTracker tracker, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteTracker(String id);

  Future<List<TrackerValue>> listValues(
    String trackerId, {
    bool includeDeleted = false,
  });
  Future<TrackerValue?> getValue(String id);
  Future<void> upsertValue(TrackerValue value, {bool recordLocalActivity = true});
  Future<void> softDeleteValue(String id);

  Future<void> purgeExpiredDeleted(DateTime now);
}

/// The notification popover's pinned reminders and dismissed-feed-item
/// tracking. Both sync; unpinning and un-dismissing are soft deletes, because
/// a pull only ever sees the documents that still exist.
abstract class NotificationRepository {
  Future<List<PinnedNote>> listPinnedNotes({bool includeDeleted = false});
  Future<PinnedNote?> getPinnedNote(String id);
  Future<void> upsertPinnedNote(
    PinnedNote note, {
    bool recordLocalActivity = true,
  });
  Future<void> deletePinnedNote(String id);

  /// Dismissal keys currently recorded (see [NotificationFeedItem.dismissalKey]).
  Future<Set<String>> listDismissals();

  /// Every dismissal row including tombstoned ones — what the sync layer
  /// uploads, as distinct from [listDismissals]' "what is dismissed right now".
  Future<List<DismissedNotification>> listDismissalRecords();
  Future<DismissedNotification?> getDismissal(String dismissalKey);
  Future<void> dismiss(String dismissalKey);
  Future<void> undismiss(String dismissalKey);
  Future<void> upsertDismissal(
    DismissedNotification dismissal, {
    bool recordLocalActivity = true,
  });

  Future<void> purgeExpiredDeleted(DateTime now);
}

/// The Life Tracker page's bucket list.
abstract class BucketListRepository {
  Future<List<BucketListItem>> listItems({bool includeDeleted = false});
  Future<BucketListItem?> getItem(String id);
  Future<void> upsertItem(
    BucketListItem item, {
    bool recordLocalActivity = true,
  });
  Future<void> deleteItem(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
}

abstract class FinanceRepository {
  Future<List<FinancialTransaction>> listTransactions({
    bool includeDeleted = false,
  });
  Future<void> upsertTransaction(
    FinancialTransaction transaction, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteTransaction(String id);

  Future<List<Subscription>> listSubscriptions({bool includeDeleted = false});
  Future<void> upsertSubscription(
    Subscription subscription, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteSubscription(String id);

  Future<List<Budget>> listBudgets({bool includeDeleted = false});
  Future<void> upsertBudget(Budget budget, {bool recordLocalActivity = true});
  Future<void> softDeleteBudget(String id);

  Future<List<FinanceCategory>> listCategories({bool includeDeleted = false});
  Future<void> upsertCategory(
    FinanceCategory category, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteCategory(String id);

  Future<List<Asset>> listAssets({bool includeDeleted = false});
  Future<void> upsertAsset(Asset asset, {bool recordLocalActivity = true});
  Future<void> softDeleteAsset(String id);

  Future<List<AssetValuation>> listAssetValuations({
    String? assetId,
    bool includeDeleted = false,
  });
  Future<void> upsertAssetValuation(
    AssetValuation valuation, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteAssetValuation(String id);

  Future<List<SavingsGoal>> listSavingsGoals({bool includeDeleted = false});
  Future<void> upsertSavingsGoal(
    SavingsGoal goal, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteSavingsGoal(String id);

  Future<List<GoalAllocation>> listGoalAllocations({
    String? goalId,
    bool includeDeleted = false,
  });
  Future<void> upsertGoalAllocation(
    GoalAllocation allocation, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteGoalAllocation(String id);

  Future<void> purgeExpiredDeleted(DateTime now);
}

/// Folders/decks form an arbitrary-depth tree via `parentFolderId`. Callers
/// browse one level at a time (a breadcrumb stack of UUIDs), matching
/// STUDY.md's "in-memory stack" navigation model rather than loading the
/// whole tree at once.
abstract class StudyRepository {
  Future<List<StudyFolder>> listFolders({
    String? parentFolderId,
    bool includeDeleted = false,
  });
  Future<StudyFolder?> getFolder(String id);
  Future<void> upsertFolder(StudyFolder folder, {bool recordLocalActivity = true});
  Future<void> softDeleteFolder(String id);

  /// True if moving [folderId] under [targetParentFolderId] would create a
  /// cycle (the target is the folder itself or one of its own descendants).
  /// Must be checked before every folder move.
  Future<bool> wouldCreateCycle(String folderId, String? targetParentFolderId);
  Future<void> moveFolder(String folderId, String? newParentFolderId);

  Future<List<StudyDeck>> listDecks({
    String? parentFolderId,
    bool includeDeleted = false,
  });
  Future<StudyDeck?> getDeck(String id);
  Future<void> upsertDeck(StudyDeck deck, {bool recordLocalActivity = true});
  Future<void> softDeleteDeck(String id);
  Future<void> moveDeck(String deckId, String? newParentFolderId);

  Future<List<StudyCard>> listCards(String deckId, {bool includeDeleted = false});
  Future<StudyCard?> getCard(String id);
  Future<void> upsertCard(StudyCard card, {bool recordLocalActivity = true});
  Future<void> softDeleteCard(String id);
  Future<void> moveCards(List<String> cardIds, String targetDeckId);
  Future<void> duplicateCards(List<String> cardIds);

  Future<void> logReview(StudyReviewLog log);
  Future<int> countCardsReviewedToday({DateTime? now});
  Future<int> countCardsReviewedTotal();
  Future<int> countDueCards({DateTime? now});
  Future<int> countDueCardsInDeck(String deckId, {DateTime? now});

  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<StudyFolder>> getAllFolders({bool includeDeleted = true});
  Future<List<StudyDeck>> getAllDecks({bool includeDeleted = true});
  Future<List<StudyCard>> getAllCards({bool includeDeleted = true});

  /// The whole review history. Append-only and never tombstoned, so unlike the
  /// other `getAll` methods there is nothing to include or exclude.
  Future<List<StudyReviewLog>> getAllReviewLogs();
}

/// Exercises, the two plans and their day entries, plus performed sessions and
/// their set logs. Sessions are append-only history: nothing here rewrites a
/// past workout when the plan it came from is later edited.
abstract class WorkoutRepository {
  /// Creates the weekly and cycle plans if they're missing, and seeds the
  /// starter exercise library the very first time (gated on the table being
  /// completely empty, deleted rows included, so clearing the library out
  /// doesn't resurrect it on next launch). Idempotent.
  Future<void> ensureSeeded();

  Future<List<Exercise>> listExercises({bool includeDeleted = false});
  Future<Exercise?> getExercise(String id);
  Future<void> upsertExercise(
    Exercise exercise, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteExercise(String id);

  Future<List<WorkoutPlan>> listPlans({bool includeDeleted = false});
  Future<WorkoutPlan?> getPlan(String id);
  Future<void> upsertPlan(WorkoutPlan plan, {bool recordLocalActivity = true});

  /// Marks [planId] active and clears the flag on every other plan, so
  /// "which plan decides today's workout" can never be ambiguous.
  Future<void> setActivePlan(String planId);

  Future<List<WorkoutPlanEntry>> listPlanEntries(
    String planId, {
    bool includeDeleted = false,
  });
  Future<WorkoutPlanEntry?> getPlanEntry(String id);
  Future<void> upsertPlanEntry(
    WorkoutPlanEntry entry, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeletePlanEntry(String id);

  Future<List<WorkoutSession>> listSessions({bool includeDeleted = false});
  Future<WorkoutSession?> getSession(String id);

  /// The single in-progress session, if one exists. More than one would mean a
  /// sync raced two devices; the most recently started wins.
  Future<WorkoutSession?> getActiveSession();
  Future<void> upsertSession(
    WorkoutSession session, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteSession(String id);

  Future<List<WorkoutSetLog>> listSetLogs({
    String? sessionId,
    String? exerciseId,
    bool includeDeleted = false,
  });
  Future<WorkoutSetLog?> getSetLog(String id);
  Future<void> upsertSetLog(
    WorkoutSetLog log, {
    bool recordLocalActivity = true,
  });
  Future<void> upsertSetLogsBatch(
    List<WorkoutSetLog> logs, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteSetLog(String id);

  Future<void> purgeExpiredDeleted(DateTime now);
  Future<List<Exercise>> getAllExercises({bool includeDeleted = true});
  Future<List<WorkoutPlan>> getAllPlans({bool includeDeleted = true});
  Future<List<WorkoutPlanEntry>> getAllPlanEntries({
    bool includeDeleted = true,
  });
  Future<List<WorkoutSession>> getAllSessions({bool includeDeleted = true});
  Future<List<WorkoutSetLog>> getAllSetLogs({bool includeDeleted = true});
}

abstract class SettingsRepository {
  Future<AppSettings> getSettings();

  /// [recordLocalActivity] is false when applying settings pulled from
  /// Firestore, which both suppresses the re-upload and leaves
  /// [AppSettings.updatedAt] at the remote value that won.
  Future<void> saveSettings(
    AppSettings settings, {
    bool recordLocalActivity = true,
  });

  Future<Map<String, int>> getTagColors();

  /// Tag colors with their sync metadata, as distinct from [getTagColors]'
  /// plain tag-to-color map.
  Future<List<TagColorRecord>> getTagColorRecords();
  Future<TagColorRecord?> getTagColorRecord(String tag);
  Future<void> setTagColor(String tag, int colorValue);
  Future<void> upsertTagColor(
    TagColorRecord tagColor, {
    bool recordLocalActivity = true,
  });

  /// The dictionary as the spell checker sees it — tombstoned words excluded.
  Future<Set<String>> getCustomWords();

  /// Every custom-word row including tombstoned ones, for the sync layer.
  Future<List<CustomWord>> getCustomWordRecords();
  Future<CustomWord?> getCustomWordRecord(String word);
  Future<void> addCustomWord(String word);
  Future<void> removeCustomWord(String word);
  Future<void> upsertCustomWord(
    CustomWord word, {
    bool recordLocalActivity = true,
  });

  Future<void> purgeExpiredDeleted(DateTime now);

  /// User-written quotes, newest first. Tombstoned rows are included only when
  /// [includeDeleted] is set — the sync layer needs them, the quote pool
  /// doesn't.
  Future<List<CustomQuote>> getCustomQuotes({bool includeDeleted = false});
  Future<CustomQuote?> getCustomQuote(String id);
  Future<void> upsertCustomQuote(
    CustomQuote quote, {
    bool recordLocalActivity = true,
  });
  Future<void> softDeleteCustomQuote(String id);
}

abstract class AuthRepository {
  Stream<bool> get authStateChanges;
  Future<void> signInWithEmail(String email, String password);
  Future<void> signUpWithEmail(String email, String password);
  Future<void> sendPasswordResetEmail(String email);
  Future<void> signInWithGoogle();
  Future<void> signOut();
  String? get currentUserId;
}

abstract class SyncConflictRepository {
  Future<List<SyncConflict>> listConflicts();
  Future<SyncConflict?> getConflict(String id);
  Future<void> upsertConflict(SyncConflict conflict);
  Future<void> deleteConflict(String id);
  Future<void> deleteConflictsForDocument(String collection, String documentId);
}

abstract class SyncRepository {
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  );
  Stream<Map<String, dynamic>> watchDocument(String collection, String id);

  /// Emits the documents that changed (added or modified) in [collection],
  /// keyed by id, each time the backend's snapshot listener fires.
  ///
  /// The payloads come with the notification because the backend has already
  /// sent them — and already charged for them. Emitting bare ids and letting
  /// the caller `getDocument` each one turns a single snapshot carrying forty
  /// documents into forty more billed reads, serialised, for data that was
  /// sitting in the snapshot all along.
  ///
  /// This includes echoes of this device's own writes — callers that already
  /// know they just wrote a given id should treat that as a no-op rather
  /// than re-merging it.
  Stream<Map<String, Map<String, dynamic>>> watchCollection(String collection);
  Future<Map<String, dynamic>?> getDocument(String collection, String id);
  Future<List<({String id, Map<String, dynamic> data})>> listCollectionDocuments(
    String collection,
  );
  Future<Map<String, dynamic>?> getRemoteSettings();
  Future<void> upsertRemoteSettings(Map<String, dynamic> data);
  Future<GoogleCalendarSyncLock?> getCalendarLock();
  Future<bool> claimCalendarLock(GoogleCalendarSyncLock lock);
  Future<void> releaseCalendarLock(String deviceId);
  Future<WeatherFetchLock?> getWeatherFetchLock();
  Future<bool> claimWeatherFetchLock(WeatherFetchLock lock);
  Future<void> releaseWeatherFetchLock(String deviceId);
  Future<WeatherSnapshot?> getCurrentWeather();
  Future<void> upsertCurrentWeather(WeatherSnapshot weather);
  Future<WeatherForecast?> getStoredForecast();
  Future<void> appendOperation(SyncOperation operation);

  /// Same effect as calling [appendOperation] once per entry, committed as
  /// one or few network round-trips instead of one per operation. Used for
  /// sort-order-only cascades (uncompleting a task in a large list can shift
  /// every row below it) where firing dozens of concurrent single-document
  /// writes was enough to starve the UI isolate and stall other Timer-driven
  /// work, like the background animation.
  Future<void> appendOperationsBatch(List<SyncOperation> operations);

  /// Appends every entry in [operations] as one all-or-nothing unit.
  ///
  /// Used for a single logical write whose character operations had to be
  /// split across several documents to fit the per-document size limit. Unlike
  /// [appendOperationsBatch], which is a throughput optimisation over
  /// independent writes, the entries here are meaningless apart: a reader that
  /// saw some but not all of them would reconstruct text missing whatever the
  /// absent ones carried. Implementations must commit them atomically.
  Future<void> appendOperationGroup(List<SyncOperation> operations);
  Future<List<SyncOperation>> listOperations(String documentId);

  /// Batched counterpart to [upsertDocument] — see [appendOperationsBatch].
  Future<void> upsertDocumentsBatch(
    String collection,
    Map<String, Map<String, dynamic>> documentsById,
  );
  Future<void> deleteDocument(String collection, String id);
  Future<int> deleteOperationsForDocument(String documentId);

  /// Deletes only the named operations of [documentId], leaving the rest of
  /// its log intact. Used by compaction to retire the operations a freshly
  /// written baseline supersedes.
  Future<int> deleteOperations(String documentId, List<String> operationIds);

  /// Round-trips to the backend to prove it is reachable, throwing if it is
  /// not.
  ///
  /// The only way to learn this from Firestore: writes are queued silently
  /// while offline and reads are answered from the local cache, so nothing in
  /// the normal sync path ever fails just because the network is gone.
  /// Implementations must therefore force a real server round-trip and treat a
  /// cache-answered result as a failure. Backends with no network behind them
  /// are always reachable and should return normally.
  Future<void> ping();
}
