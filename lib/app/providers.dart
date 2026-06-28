import 'dart:async';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/auth_notifier.dart';
import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/dev/cache_status.dart';
import 'package:voyager/core/dev/dev_settings_controller.dart';
import 'package:voyager/core/dev/todo_sort_debug_logger.dart';
import 'package:voyager/core/dev/journal_debug_logger.dart';
import 'package:voyager/core/dev/remote_sync_compare_service.dart';
import 'package:voyager/core/dev/sync_compare_logger.dart';
import 'package:voyager/core/dev/warmup_tracker.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/widgets/geometric_texture.dart';
import 'package:voyager/core/widgets/geometric_texture_settings.dart';
import 'package:voyager/data/remote/cloud_function_weather_client.dart';
import 'package:voyager/data/remote/dev_openweather_client.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';
import 'package:voyager/data/remote/http_callable_client.dart';
import 'package:voyager/firebase_options.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/quotes_loader.dart';
import 'package:voyager/domain/models/sync_conflict.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/repositories/weather_api_client.dart';
import 'package:voyager/domain/services/analytics_service.dart';
import 'package:voyager/domain/services/periodic_prompt_service.dart';
import 'package:voyager/domain/services/quote_bank.dart';
import 'package:voyager/domain/services/search_service.dart';
import 'package:voyager/domain/services/weather_service.dart';

const _fallbackDeviceId = 'local-device';
const _useCloudFunctions = bool.fromEnvironment(
  'USE_CLOUD_FUNCTIONS',
  defaultValue: true,
);
const _openWeatherApiKey = String.fromEnvironment('OPENWEATHER_API_KEY');

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase.create();
  ref.onDispose(db.close);
  return db;
});

final journalRepositoryProvider = Provider<JournalRepository>((ref) {
  return DriftJournalRepository(
    ref.watch(databaseProvider),
    syncActivity: ref.read(syncActivityProvider),
  );
});

final todoRepositoryProvider = Provider<TodoRepository>((ref) {
  return DriftTodoRepository(
    ref.watch(databaseProvider),
    syncActivity: ref.read(syncActivityProvider),
  );
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

final syncConflictRepositoryProvider = Provider<SyncConflictRepository>((ref) {
  return DriftSyncConflictRepository(ref.watch(databaseProvider));
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return FirebaseAuthRepository(FirebaseAuth.instance);
});

final authNotifierProvider = ChangeNotifierProvider<AuthNotifier>((ref) {
  return AuthNotifier(ref.watch(authRepositoryProvider));
});

final deviceIdProvider = StateProvider<String>((ref) => _fallbackDeviceId);

final syncActivityProvider = ChangeNotifierProvider<SyncActivityController>((
  ref,
) {
  final controller = SyncActivityController(
    settingsRepository: ref.watch(settingsRepositoryProvider),
  );
  unawaited(controller.loadFromSettings());
  ref.listen<AsyncValue<AppSettings>>(settingsProvider, (previous, next) {
    next.whenData(controller.applySettings);
  });
  return controller;
});

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  final uid = ref.watch(authRepositoryProvider).currentUserId;
  if (uid == null) return NoOpSyncRepository();
  return FirestoreSyncRepository(FirebaseFirestore.instance, uid);
});

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(
    syncRepository: ref.watch(syncRepositoryProvider),
    deviceId: ref.watch(deviceIdProvider),
    syncActivity: ref.read(syncActivityProvider),
  );
  ref.onDispose(engine.dispose);
  return engine;
});

final weatherApiClientProvider = Provider<WeatherApiClient>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (kDebugMode && (settings?.devUseDirectOpenWeather ?? false)) {
    final key =
        settings?.devOpenWeatherApiKey?.trim() ??
        (_openWeatherApiKey.isNotEmpty ? _openWeatherApiKey : null);
    if (key != null && key.isNotEmpty) {
      return DevOpenWeatherClient(apiKey: key);
    }
  } else if (!kDebugMode &&
      !_useCloudFunctions &&
      _openWeatherApiKey.isNotEmpty) {
    return DevOpenWeatherClient(apiKey: _openWeatherApiKey);
  }
  if (isWindows) {
    return CloudFunctionWeatherClient.fromHttp(
      HttpCallableClient(
        projectId: DefaultFirebaseOptions.currentPlatform.projectId,
      ),
    );
  }
  return CloudFunctionWeatherClient.fromFunctions(FirebaseFunctions.instance);
});

final weatherServiceProvider = Provider<WeatherService>((ref) {
  final weatherApiClient = ref.watch(weatherApiClientProvider);
  return WeatherService(
    settingsRepository: ref.watch(settingsRepositoryProvider),
    syncRepository: ref.watch(syncRepositoryProvider),
    weatherApiClient: weatherApiClient,
    deviceId: ref.watch(deviceIdProvider),
    mergeForecastLocally: weatherApiClient is DevOpenWeatherClient,
  );
});

final remoteSyncServiceProvider = Provider<RemoteSyncService>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  final service = RemoteSyncService(
    syncRepository: ref.watch(syncRepositoryProvider),
    journalRepository: ref.watch(journalRepositoryProvider),
    todoRepository: ref.watch(todoRepositoryProvider),
    weatherService: ref.watch(weatherServiceProvider),
    syncEngine: ref.watch(syncEngineProvider),
    syncConflictRepository: ref.watch(syncConflictRepositoryProvider),
    syncActivity: ref.read(syncActivityProvider),
    deviceId: ref.watch(deviceIdProvider),
    forceConflictUi: settings?.devForceConflictUi ?? false,
  );
  ref.listen<AsyncValue<AppSettings>>(settingsProvider, (previous, next) {
    next.whenData((s) => service.forceConflictUi = s.devForceConflictUi);
  });
  ref.onDispose(service.dispose);
  return service;
});

final journalWriteCoordinatorProvider = Provider<JournalWriteCoordinator>((ref) {
  return JournalWriteCoordinator(
    journalRepository: ref.watch(journalRepositoryProvider),
    remoteSync: ref.watch(remoteSyncServiceProvider),
    onEntrySaved: () => invalidateJournalEntryProviders(ref),
  );
});

/// App-scoped journal list cache invalidation (safe after widget dispose).
final journalEntryCacheInvalidatorProvider = Provider<void Function()>((ref) {
  return () => invalidateJournalEntryProviders(ref);
});

final syncConflictsProvider = FutureProvider<List<SyncConflict>>((ref) async {
  return ref.watch(remoteSyncServiceProvider).listConflicts();
});

final firestorePullServiceProvider = Provider<RemoteSyncService>(
  (ref) => ref.watch(remoteSyncServiceProvider),
);

final liveSyncProvider = Provider<LiveSyncController>((ref) {
  final controller = LiveSyncController(
    remoteSync: ref.watch(remoteSyncServiceProvider),
    syncRepository: ref.watch(syncRepositoryProvider),
    onChanged: () {
      invalidateJournalEntryProviders(ref);
      ref.invalidate(journalsProvider);
      ref.invalidate(todoListsProvider);
      ref.invalidate(todoTasksProvider);
      ref.invalidate(allTodoTasksProvider);
      ref.invalidate(todoListStatsProvider);
      ref.invalidate(syncConflictsProvider);
    },
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final cachedCurrentWeatherProvider = Provider<WeatherSnapshot?>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null) return null;
  return ref.read(weatherServiceProvider).readCachedSnapshot(settings);
});

final currentWeatherProvider = FutureProvider<WeatherSnapshot?>((ref) async {
  ref.watch(settingsProvider);
  return ref.read(weatherServiceProvider).refreshIfNeeded();
});

final weatherForecastProvider = FutureProvider<WeatherForecast?>((ref) async {
  ref.watch(
    settingsProvider.select(
      (async) => (
        async.valueOrNull?.weatherLat,
        async.valueOrNull?.weatherLon,
        async.valueOrNull?.weatherLocationUpdatedAt,
        async.valueOrNull?.devUseDirectOpenWeather,
      ),
    ),
  );
  return ref.read(weatherServiceProvider).fetchForecastIfNeeded();
});

/// Last daily card selected in the forecast popup (calendar date, local).
final weatherForecastLastDayProvider = StateProvider<DateTime?>((ref) => null);

/// In-memory chart colors so legend updates without refetching forecast data.
final weatherChartColorsProvider = StateProvider<({int? temp, int? rain})>(
  (ref) => (temp: null, rain: null),
);

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

Future<String> ensureDeviceId(SettingsRepository settingsRepository) async {
  final settings = await settingsRepository.getSettings();
  if (settings.deviceId != null && settings.deviceId!.isNotEmpty) {
    return settings.deviceId!;
  }
  final id = newId();
  await settingsRepository.saveSettings(settings.copyWith(deviceId: id));
  return id;
}

final googleCalendarSyncProvider = Provider((ref) {
  return GoogleCalendarSyncService(
    ref.watch(syncRepositoryProvider),
    ref.watch(calendarRepositoryProvider),
    ref.watch(deviceIdProvider),
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

final colorPaletteProvider = Provider<List<int>>((ref) {
  return ref.watch(settingsProvider).valueOrNull?.colorPalette ??
      defaultColorPalette;
});

final journalsProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(journalRepositoryProvider).listJournals();
});

final journalEntriesProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(lazyLoadProvider).loadRecentEntries();
});

/// Journal entry list scope: [allJournalEntriesScope] for recent entries across
/// all journals, otherwise a specific journal id for that journal's full list.
const allJournalEntriesScope = '__all__';

void invalidateJournalEntryProviders(Ref ref) {
  ref.invalidate(journalEntriesProvider);
  ref.invalidate(journalListEntriesProvider);
  ref.invalidate(journalEntryCountsProvider);
}

final journalEntryCountsProvider =
    FutureProvider<Map<String, int>>((ref) async {
  ref.keepAlive();
  return ref.watch(journalRepositoryProvider).countEntriesByJournal();
});

final journalListEntriesProvider = FutureProvider.family<
    List<JournalEntry>, String>((ref, scope) {
  ref.keepAlive();
  final repo = ref.watch(journalRepositoryProvider);
  if (scope == allJournalEntriesScope) {
    return repo.listEntries();
  }
  return repo.listEntries(journalId: scope);
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

final todoTasksProvider = FutureProvider.family<List<TodoTask>, String>((
  ref,
  listId,
) {
  ref.keepAlive();
  return ref.watch(todoRepositoryProvider).listTasks(listId);
});

final allTodoTasksProvider = FutureProvider<List<TodoTask>>((ref) async {
  ref.keepAlive();
  final repo = ref.watch(todoRepositoryProvider);
  final lists = await ref.watch(todoListsProvider.future);
  final all = <TodoTask>[];
  for (final list in lists) {
    all.addAll(await repo.listTasks(list.id));
  }
  return all;
});

final todoListStatsProvider =
    FutureProvider<Map<String, ({int active, int completed})>>((ref) async {
  ref.keepAlive();
  final repo = ref.watch(todoRepositoryProvider);
  final lists = await ref.watch(todoListsProvider.future);
  final stats = <String, ({int active, int completed})>{};
  for (final list in lists) {
    final tasks = await repo.listTasks(list.id);
    stats[list.id] = (
      active: tasks.where((t) => !t.completed).length,
      completed: tasks.where((t) => t.completed).length,
    );
  }
  return stats;
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

final geometricShaderProvider = FutureProvider<FragmentProgram?>((ref) async {
  ref.keepAlive();
  try {
    return await FragmentProgram.fromAsset('shaders/geometric_texture.frag');
  } catch (e, st) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: e,
      stack: st,
      library: 'geometric_texture',
      context: ErrorDescription('loading geometric texture shader'),
    ));
    return null;
  }
});

/// Live-tunable geometric texture parameters (persisted in local settings).
class GeometricTextureParamsNotifier
    extends StateNotifier<GeometricTextureParams> {
  GeometricTextureParamsNotifier(this._ref)
    : super(GeometricTextureParams.defaults) {
    _ref.listen<AsyncValue<AppSettings>>(settingsProvider, (_, next) {
      next.whenData(syncFromSettings);
    });
    final cached = _ref.read(settingsProvider).valueOrNull;
    if (cached != null) {
      syncFromSettings(cached);
    }
  }

  final Ref _ref;
  Timer? _saveTimer;

  void syncFromSettings(AppSettings settings) {
    final next = geometricTextureParamsFromSettings(settings);
    if (next != state) {
      state = next;
    }
  }

  void update(GeometricTextureParams params) {
    state = params;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persist(params));
    });
  }

  Future<void> resetToDefaults() async {
    _saveTimer?.cancel();
    state = GeometricTextureParams.defaults;
    await _persist(GeometricTextureParams.defaults);
  }

  Future<void> _persist(GeometricTextureParams params) async {
    final repo = _ref.read(settingsRepositoryProvider);
    final settings = await repo.getSettings();
    await repo.saveSettings(
      appSettingsWithGeometricTextureParams(settings, params),
    );
    _ref.invalidate(settingsProvider);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}

final geometricTextureParamsProvider =
    StateNotifierProvider<
      GeometricTextureParamsNotifier,
      GeometricTextureParams
    >((ref) => GeometricTextureParamsNotifier(ref));

/// Whether the dev-menu geometric texture slider panel is expanded.
final devGeometricTexturePanelOpenProvider =
    StateProvider<bool>((ref) => false);

final shellDataWarmupProvider = FutureProvider<void>((ref) async {
  ref.keepAlive();
  final listsFuture = ref.read(todoListsProvider.future);

  await Future.wait<void>([
    ref.read(geometricShaderProvider.future).then((_) {}),
    ref.read(quotesLoadedProvider.future),
    ref.read(settingsProvider.future).then((_) {}),
    ref.read(journalsProvider.future).then((_) {}),
    ref.read(journalEntriesProvider.future).then((_) {}),
    ref.read(journalEntryCountsProvider.future).then((_) {}),
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
    ref.read(journalsProvider.future).then((journals) async {
      await Future.wait<void>([
        ref
            .read(journalListEntriesProvider(allJournalEntriesScope).future)
            .then((_) {}),
        ...journals.map(
          (journal) => ref
              .read(journalListEntriesProvider(journal.id).future)
              .then((_) {}),
        ),
      ]);
    }),
  ]);
});

final journalDebugLoggerProvider = ChangeNotifierProvider<JournalDebugLogger>((
  ref,
) {
  final controller = JournalDebugLogger(
    settingsRepository: ref.watch(settingsRepositoryProvider),
    journalRepository: ref.watch(journalRepositoryProvider),
  );
  unawaited(controller.loadFromSettings());
  ref.listen<AsyncValue<AppSettings>>(settingsProvider, (previous, next) {
    next.whenData(controller.applySettings);
  });
  return controller;
});

final todoSortDebugLoggerProvider = ChangeNotifierProvider<TodoSortDebugLogger>((
  ref,
) {
  final controller = TodoSortDebugLogger(
    settingsRepository: ref.watch(settingsRepositoryProvider),
    todoRepository: ref.watch(todoRepositoryProvider),
  );
  unawaited(controller.loadFromSettings());
  ref.listen<AsyncValue<AppSettings>>(settingsProvider, (previous, next) {
    next.whenData(controller.applySettings);
  });
  return controller;
});

final devSettingsProvider = ChangeNotifierProvider<DevSettingsController>((
  ref,
) {
  final controller = DevSettingsController(
    settingsRepository: ref.watch(settingsRepositoryProvider),
  );
  unawaited(controller.loadFromSettings());
  ref.listen<AsyncValue<AppSettings>>(settingsProvider, (previous, next) {
    next.whenData(controller.applySettings);
  });
  return controller;
});

final syncCompareLoggerProvider = ChangeNotifierProvider<SyncCompareLogger>((
  ref,
) {
  return SyncCompareLogger();
});

final remoteSyncCompareServiceProvider = Provider<RemoteSyncCompareService>((
  ref,
) {
  return RemoteSyncCompareService(
    journalRepository: ref.watch(journalRepositoryProvider),
    todoRepository: ref.watch(todoRepositoryProvider),
    syncRepository: ref.watch(syncRepositoryProvider),
    logger: ref.watch(syncCompareLoggerProvider),
  );
});

final warmupTrackerProvider = ChangeNotifierProvider<WarmupTracker>((ref) {
  return WarmupTracker();
});

final cacheStatusSnapshotProvider = Provider<CacheStatusSnapshot>((ref) {
  final warmup = ref.watch(warmupTrackerProvider);

  final items = <CacheItemStatus>[
    cacheStatusFromWarmup('Startup sync', warmup.stateFor('Startup sync')),
    cacheStatusFromWarmup('Weather warmup', warmup.stateFor('Weather warmup')),
    cacheStatusFromAsync('Quotes', ref.watch(quotesLoadedProvider)),
    cacheStatusFromAsync('Settings', ref.watch(settingsProvider)),
    cacheStatusFromAsync('Journals', ref.watch(journalsProvider)),
    cacheStatusFromAsync('Journal entries', ref.watch(journalEntriesProvider)),
    cacheStatusFromAsync('Calendar events', ref.watch(calendarEventsProvider)),
    cacheStatusFromAsync('Trackers', ref.watch(trackersProvider)),
    cacheStatusFromAsync('Ranking configs', ref.watch(rankingConfigsProvider)),
    cacheStatusFromAsync('Current weather', ref.watch(currentWeatherProvider)),
    cacheStatusFromAsync('Weather forecast', ref.watch(weatherForecastProvider)),
    cacheStatusFromAsync('Shell warmup', ref.watch(shellDataWarmupProvider)),
  ];

  final listsAsync = ref.watch(todoListsProvider);
  items.add(cacheStatusFromAsync('Todo lists', listsAsync));

  final lists = listsAsync.valueOrNull;
  if (lists != null) {
    for (final list in lists) {
      items.add(
        cacheStatusFromAsync(
          'Tasks: ${list.name}',
          ref.watch(todoTasksProvider(list.id)),
        ),
      );
    }
  }

  return CacheStatusSnapshot(items: items);
});
