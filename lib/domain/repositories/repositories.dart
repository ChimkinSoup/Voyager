import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/weather_models.dart';

abstract class JournalRepository {
  Future<List<Journal>> listJournals({bool includeDeleted = false});
  Future<Journal?> getJournal(String id);
  Future<void> upsertJournal(Journal journal, {bool recordLocalActivity = true});
  Future<void> softDeleteJournal(String id);
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
  Future<JournalEntry?> getEntry(String id);
  Future<void> upsertEntry(JournalEntry entry, {bool recordLocalActivity = true});
  Future<void> softDeleteEntry(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
}

abstract class TodoRepository {
  Future<List<TodoListModel>> listLists({bool includeDeleted = false});
  Future<void> upsertList(TodoListModel list, {bool recordLocalActivity = true});
  Future<void> softDeleteList(String id);

  Future<List<TodoTask>> listTasks(
    String listId, {
    bool includeDeleted = false,
    bool topLevelOnly = true,
  });
  Future<List<TodoTask>> listSubtasks(String parentTaskId);
  Future<int> nextSortOrder(String listId);
  Future<void> upsertTask(TodoTask task, {bool recordLocalActivity = true});
  Future<void> softDeleteTask(String id);
  Future<void> purgeExpiredDeleted(DateTime now);
}

abstract class CalendarRepository {
  Future<List<CalendarEvent>> listEvents({
    DateTime? from,
    DateTime? to,
    bool includeDeleted = false,
  });
  Future<void> upsertEvent(CalendarEvent event);
  Future<void> softDeleteEvent(String id);
  Future<void> replaceGoogleEvents(List<CalendarEvent> events);
  Future<void> purgeExpiredDeleted(DateTime now);
}

abstract class TrackerRepository {
  Future<List<StatisticTracker>> listTrackers({bool includeDeleted = false});
  Future<void> upsertTracker(StatisticTracker tracker);
  Future<void> softDeleteTracker(String id);

  Future<List<TrackerValue>> listValues(String trackerId);
  Future<void> upsertValue(TrackerValue value);

  Future<List<RankingConfig>> listRankingConfigs();
  Future<void> upsertRankingConfig(RankingConfig config);
  Future<List<RankingValue>> listRankingValues(String configId);
  Future<void> upsertRankingValue(RankingValue value);
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

abstract class SyncRepository {
  Future<void> upsertDocument(
    String collection,
    String id,
    Map<String, dynamic> data,
  );
  Stream<Map<String, dynamic>> watchDocument(String collection, String id);
  Stream<void> watchCollection(String collection);
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
  Future<List<SyncOperation>> listOperations(String documentId);
}
