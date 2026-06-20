import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/auth_notifier.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/quotes_loader.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/analytics_service.dart';
import 'package:voyager/domain/services/periodic_prompt_service.dart';
import 'package:voyager/domain/services/quote_bank.dart';
import 'package:voyager/domain/services/search_service.dart';

const deviceId = 'local-device';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase.create();
  ref.onDispose(db.close);
  return db;
});

final journalRepositoryProvider = Provider<JournalRepository>((ref) {
  return DriftJournalRepository(ref.watch(databaseProvider));
});

final todoRepositoryProvider = Provider<TodoRepository>((ref) {
  return DriftTodoRepository(ref.watch(databaseProvider));
});

final calendarRepositoryProvider = Provider<CalendarRepository>((ref) {
  return DriftCalendarRepository(ref.watch(databaseProvider));
});

final trackerRepositoryProvider = Provider<TrackerRepository>((ref) {
  return DriftTrackerRepository(ref.watch(databaseProvider));
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return DriftSettingsRepository(ref.watch(databaseProvider));
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final repo = InMemoryAuthRepository();
  ref.onDispose(repo.dispose);
  return repo;
});

final authNotifierProvider = ChangeNotifierProvider<AuthNotifier>((ref) {
  return AuthNotifier(ref.watch(authRepositoryProvider));
});

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  return InMemorySyncRepository();
});

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(
    syncRepository: ref.watch(syncRepositoryProvider),
    deviceId: deviceId,
  );
  ref.onDispose(engine.dispose);
  return engine;
});

final searchServiceProvider = Provider((_) => SearchService());
final analyticsServiceProvider = Provider((_) => AnalyticsService());
final periodicPromptServiceProvider = Provider((_) => PeriodicPromptService());

final quoteBankProvider = StateProvider<QuoteBank>(
  (ref) => QuoteBank(const []),
);

final quotesLoadedProvider = FutureProvider<void>((ref) async {
  ref.keepAlive();
  final quotes = await loadQuotesFromAssets();
  ref.read(quoteBankProvider.notifier).state = QuoteBank(quotes);
});

final googleCalendarSyncProvider = Provider((ref) {
  return GoogleCalendarSyncService(
    ref.watch(syncRepositoryProvider),
    ref.watch(calendarRepositoryProvider),
    deviceId,
  );
});

final lazyLoadProvider = Provider((ref) {
  return LazyLoadService(ref.watch(journalRepositoryProvider));
});

final backgroundSyncOrchestratorProvider = Provider((ref) {
  return BackgroundSyncOrchestrator(
    journalRepository: ref.watch(journalRepositoryProvider),
    todoRepository: ref.watch(todoRepositoryProvider),
    calendarRepository: ref.watch(calendarRepositoryProvider),
    trackerRepository: ref.watch(trackerRepositoryProvider),
  );
});

final settingsProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(settingsRepositoryProvider).getSettings();
});

final journalsProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(journalRepositoryProvider).listJournals();
});

final journalEntriesProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(lazyLoadProvider).loadRecentEntries();
});

final historicalJournalEntriesProvider = FutureProvider.family((
  ref,
  DateTime before,
) {
  return ref.watch(lazyLoadProvider).loadHistoricalEntries(before: before);
});

final todoListsProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(todoRepositoryProvider).listLists();
});

final todoTasksProvider = StreamProvider.family<List<TodoTask>, String>((
  ref,
  listId,
) async* {
  ref.keepAlive();
  final repo = ref.watch(todoRepositoryProvider);
  final sync = ref.watch(syncRepositoryProvider);

  yield await repo.listTasks(listId);
  await for (final _ in sync.watchCollection('todo_tasks')) {
    yield await repo.listTasks(listId);
  }
});

final calendarEventsProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(calendarRepositoryProvider).listEvents();
});

final trackersProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(trackerRepositoryProvider).listTrackers();
});

final trackerValuesProvider = FutureProvider.family((ref, String trackerId) {
  ref.keepAlive();
  return ref.watch(trackerRepositoryProvider).listValues(trackerId);
});

final rankingConfigsProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(trackerRepositoryProvider).listRankingConfigs();
});

final rankingValuesProvider = FutureProvider.family((ref, String configId) {
  ref.keepAlive();
  return ref.watch(trackerRepositoryProvider).listRankingValues(configId);
});

final shellDataWarmupProvider = FutureProvider<void>((ref) async {
  ref.keepAlive();
  final listsFuture = ref.read(todoListsProvider.future);

  await Future.wait<void>([
    ref.read(quotesLoadedProvider.future),
    ref.read(settingsProvider.future).then((_) {}),
    ref.read(journalsProvider.future).then((_) {}),
    ref.read(journalEntriesProvider.future).then((_) {}),
    ref.read(calendarEventsProvider.future).then((_) {}),
    ref.read(trackersProvider.future).then((_) {}),
    ref.read(rankingConfigsProvider.future).then((_) {}),
    listsFuture.then((lists) async {
      await Future.wait<void>(
        lists.map(
          (list) => ref.read(todoTasksProvider(list.id).future).then((_) {}),
        ),
      );
    }),
  ]);
});
