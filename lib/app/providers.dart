import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/auth_notifier.dart';
import 'package:voyager/core/constants/default_color_palette.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/data/remote/cloud_function_weather_client.dart';
import 'package:voyager/data/remote/dev_openweather_client.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';
import 'package:voyager/data/remote/http_callable_client.dart';
import 'package:voyager/firebase_options.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/quotes_loader.dart';
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
  return RemoteSyncService(
    syncRepository: ref.watch(syncRepositoryProvider),
    journalRepository: ref.watch(journalRepositoryProvider),
    todoRepository: ref.watch(todoRepositoryProvider),
    weatherService: ref.watch(weatherServiceProvider),
    syncEngine: ref.watch(syncEngineProvider),
    syncActivity: ref.read(syncActivityProvider),
  );
});

final firestorePullServiceProvider = Provider<RemoteSyncService>(
  (ref) => ref.watch(remoteSyncServiceProvider),
);

final liveSyncProvider = Provider<LiveSyncController>((ref) {
  final controller = LiveSyncController(
    remoteSync: ref.watch(remoteSyncServiceProvider),
    syncRepository: ref.watch(syncRepositoryProvider),
    onChanged: () {
      ref.invalidate(journalEntriesProvider);
      ref.invalidate(journalsProvider);
      ref.invalidate(todoListsProvider);
      ref.invalidate(todoTasksProvider);
    },
  );
  ref.onDispose(controller.dispose);
  return controller;
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
final weatherForecastLastDayProvider = StateProvider<DateTime?>(
  (ref) => null,
);

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
