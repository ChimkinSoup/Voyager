import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/weather_models.dart';

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
  Future<void> upsertCalendar(Calendar calendar);
  Future<void> softDeleteCalendar(String id);
  Future<void> softDeleteEventsInCalendar(String calendarId);
  Future<void> reassignEventsCalendar(String fromCalendarId, String toCalendarId);

  Future<List<CalendarEvent>> listEvents({
    String? calendarId,
    DateTime? from,
    DateTime? to,
    bool includeDeleted = false,
  });
  Future<void> upsertEvent(CalendarEvent event);
  Future<void> softDeleteEvent(String id);
  Future<void> deleteAllEvents();
  Future<void> replaceGoogleEvents(List<CalendarEvent> events);
  Future<void> purgeExpiredDeleted(DateTime now);
}

abstract class TrackerRepository {
  Future<List<StatisticTracker>> listTrackers({bool includeDeleted = false});
  Future<void> upsertTracker(StatisticTracker tracker);
  Future<void> softDeleteTracker(String id);

  Future<List<TrackerValue>> listValues(String trackerId);
  Future<void> upsertValue(TrackerValue value);
  Future<void> softDeleteValue(String id);

  Future<void> purgeExpiredDeleted(DateTime now);
}

/// Local-only storage for the notification popover's pinned reminders and
/// dismissed-feed-item tracking. Unlike the other repositories this has no
/// sync/conflict story — nothing here leaves the device.
abstract class NotificationRepository {
  Future<List<PinnedNote>> listPinnedNotes();
  Future<void> upsertPinnedNote(PinnedNote note);
  Future<void> deletePinnedNote(String id);

  /// Dismissal keys currently recorded (see [NotificationFeedItem.dismissalKey]).
  Future<Set<String>> listDismissals();
  Future<void> dismiss(String dismissalKey);
  Future<void> undismiss(String dismissalKey);
}

abstract class FinanceRepository {
  Future<List<FinancialTransaction>> listTransactions({
    bool includeDeleted = false,
  });
  Future<void> upsertTransaction(FinancialTransaction transaction);
  Future<void> softDeleteTransaction(String id);

  Future<List<Subscription>> listSubscriptions({bool includeDeleted = false});
  Future<void> upsertSubscription(Subscription subscription);
  Future<void> softDeleteSubscription(String id);

  Future<List<Budget>> listBudgets({bool includeDeleted = false});
  Future<void> upsertBudget(Budget budget);
  Future<void> softDeleteBudget(String id);

  Future<List<FinanceCategory>> listCategories({bool includeDeleted = false});
  Future<void> upsertCategory(FinanceCategory category);
  Future<void> softDeleteCategory(String id);

  Future<List<Asset>> listAssets({bool includeDeleted = false});
  Future<void> upsertAsset(Asset asset);
  Future<void> softDeleteAsset(String id);

  Future<List<AssetValuation>> listAssetValuations({
    String? assetId,
    bool includeDeleted = false,
  });
  Future<void> upsertAssetValuation(AssetValuation valuation);
  Future<void> softDeleteAssetValuation(String id);

  Future<List<SavingsGoal>> listSavingsGoals({bool includeDeleted = false});
  Future<void> upsertSavingsGoal(SavingsGoal goal);
  Future<void> softDeleteSavingsGoal(String id);

  Future<List<GoalAllocation>> listGoalAllocations({
    String? goalId,
    bool includeDeleted = false,
  });
  Future<void> upsertGoalAllocation(GoalAllocation allocation);
  Future<void> softDeleteGoalAllocation(String id);

  Future<void> purgeExpiredDeleted(DateTime now);
}

abstract class SettingsRepository {
  Future<AppSettings> getSettings();
  Future<void> saveSettings(AppSettings settings);
  Future<Map<String, int>> getTagColors();
  Future<void> setTagColor(String tag, int colorValue);
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

  /// Emits the set of document ids that changed (added or modified) in
  /// [collection] each time Firestore's snapshot listener fires. This
  /// includes echoes of this device's own writes — callers that already
  /// know they just wrote a given id should treat that as a no-op rather
  /// than re-fetching and re-merging it.
  Stream<Set<String>> watchCollection(String collection);
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
  Future<List<SyncOperation>> listOperations(String documentId);

  /// Batched counterpart to [upsertDocument] — see [appendOperationsBatch].
  Future<void> upsertDocumentsBatch(
    String collection,
    Map<String, Map<String, dynamic>> documentsById,
  );
  Future<void> deleteDocument(String collection, String id);
  Future<int> deleteOperationsForDocument(String documentId);
}
