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
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/dev/dev_settings_controller.dart';
import 'package:voyager/core/dev/fps_monitor_controller.dart';
import 'package:voyager/core/dev/todo_sort_debug_logger.dart';
import 'package:voyager/core/dev/journal_debug_logger.dart';
import 'package:voyager/core/dev/remote_sync_compare_service.dart';
import 'package:voyager/core/dev/sync_compare_logger.dart';
import 'package:voyager/core/dev/warmup_tracker.dart';
import 'package:voyager/core/snippets/snippet_enabled_scope.dart';
import 'package:voyager/core/snippets/snippet_index.dart';
import 'package:voyager/core/spellcheck/dictionary_loader.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/sync/connectivity_status.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/sync/sync_activity.dart';
import 'package:voyager/core/sync/sync_engine.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/widgets/geometric_texture.dart';
import 'package:voyager/core/widgets/geometric_texture_settings.dart';
import 'package:voyager/core/widgets/petal_field.dart';
import 'package:voyager/data/remote/cloud_function_weather_client.dart';
import 'package:voyager/data/remote/dev_openweather_client.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';
import 'package:voyager/data/remote/http_callable_client.dart';
import 'package:voyager/data/remote/leetcode_api_client.dart';
import 'package:voyager/firebase_options.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/quotes_loader.dart';
import 'package:voyager/domain/models/sync_conflict.dart';
import 'package:voyager/domain/models/analytics_models.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/leetcode_api_models.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/models/weather_models.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/settings/services/backup_collections.dart';
import 'package:voyager/features/settings/services/data_export_service.dart';
import 'package:voyager/features/settings/services/data_import_service.dart';
import 'package:voyager/domain/repositories/weather_api_client.dart';
import 'package:voyager/domain/services/analytics_service.dart';
import 'package:voyager/domain/services/periodic_prompt_service.dart';
import 'package:voyager/domain/services/quote_bank.dart';
import 'package:voyager/domain/services/search_service.dart';
import 'package:voyager/domain/services/weather_service.dart';
import 'package:voyager/features/calendar/calendar_todo_markers.dart';

const _fallbackDeviceId = 'local-device';
const _useCloudFunctions = bool.fromEnvironment(
  'USE_CLOUD_FUNCTIONS',
  defaultValue: true,
);
const _openWeatherApiKey = String.fromEnvironment('OPENWEATHER_API_KEY');

/// Opens the real on-disk voyager.sqlite (see [AppDatabase.create]) — not a
/// test double. Any ProviderScope-based test (e.g. one that pumps
/// [VoyagerApp] or another widget tree that reaches this provider) MUST
/// override it with `AppDatabase.inMemory()`, or the test reads/writes your
/// actual app data. Worse, real persisted settings can enable the
/// Timer-driven background animation (geometric wave / petal field), which
/// never stops rescheduling itself — pumpAndSettle() has no timeout, so it
/// spins forever, ballooning memory and disk I/O. See test/widget_test.dart
/// for the override pattern.
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

final dreamRepositoryProvider = Provider<DreamRepository>((ref) {
  return DriftDreamRepository(
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

/// Routes local writes in the repository-driven collections to the sync layer.
///
/// Deliberately depends on nothing: the repositories below take it, and
/// [remoteSyncServiceProvider] — which is built from those repositories —
/// registers itself on it. Reaching back to the service from here instead
/// would close the loop, and Riverpod rejects that as a circular dependency.
final syncedWriteNotifierProvider = Provider<SyncedWriteNotifier>((ref) {
  return SyncedWriteNotifier();
});

final calendarRepositoryProvider = Provider<CalendarRepository>((ref) {
  return DriftCalendarRepository(
    ref.watch(databaseProvider),
    syncedWrites: ref.watch(syncedWriteNotifierProvider),
  );
});

final trackerRepositoryProvider = Provider<TrackerRepository>((ref) {
  return DriftTrackerRepository(
    ref.watch(databaseProvider),
    syncedWrites: ref.watch(syncedWriteNotifierProvider),
  );
});

final financeRepositoryProvider = Provider<FinanceRepository>((ref) {
  return DriftFinanceRepository(
    ref.watch(databaseProvider),
    syncedWrites: ref.watch(syncedWriteNotifierProvider),
  );
});

final leetCodeRepositoryProvider = Provider<LeetCodeRepository>((ref) {
  return DriftLeetCodeRepository(
    ref.watch(databaseProvider),
    syncActivity: ref.read(syncActivityProvider),
  );
});

final studyRepositoryProvider = Provider<StudyRepository>((ref) {
  return DriftStudyRepository(
    ref.watch(databaseProvider),
    syncActivity: ref.read(syncActivityProvider),
  );
});

final workoutRepositoryProvider = Provider<WorkoutRepository>((ref) {
  return DriftWorkoutRepository(
    ref.watch(databaseProvider),
    syncActivity: ref.read(syncActivityProvider),
  );
});

final notificationRepositoryProvider = Provider<NotificationRepository>((ref) {
  return DriftNotificationRepository(
    ref.watch(databaseProvider),
    syncedWrites: ref.watch(syncedWriteNotifierProvider),
  );
});

final bucketListRepositoryProvider = Provider<BucketListRepository>((ref) {
  return DriftBucketListRepository(
    ref.watch(databaseProvider),
    syncedWrites: ref.watch(syncedWriteNotifierProvider),
  );
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return DriftSettingsRepository(
    ref.watch(databaseProvider),
    syncedWrites: ref.watch(syncedWriteNotifierProvider),
  );
});

final syncConflictRepositoryProvider = Provider<SyncConflictRepository>((ref) {
  return DriftSyncConflictRepository(ref.watch(databaseProvider));
});

/// Every synced collection, in the order a restore has to write them.
final backupCollectionsProvider = Provider<List<BackupCollection>>((ref) {
  return buildBackupCollections(
    journalRepository: ref.watch(journalRepositoryProvider),
    dreamRepository: ref.watch(dreamRepositoryProvider),
    todoRepository: ref.watch(todoRepositoryProvider),
    leetCodeRepository: ref.watch(leetCodeRepositoryProvider),
    studyRepository: ref.watch(studyRepositoryProvider),
    workoutRepository: ref.watch(workoutRepositoryProvider),
    calendarRepository: ref.watch(calendarRepositoryProvider),
    trackerRepository: ref.watch(trackerRepositoryProvider),
    financeRepository: ref.watch(financeRepositoryProvider),
    notificationRepository: ref.watch(notificationRepositoryProvider),
    bucketListRepository: ref.watch(bucketListRepositoryProvider),
    settingsRepository: ref.watch(settingsRepositoryProvider),
  );
});

final dataExportServiceProvider = Provider<DataExportService>((ref) {
  return DataExportService(
    collections: ref.watch(backupCollectionsProvider),
    settingsRepository: ref.watch(settingsRepositoryProvider),
  );
});

final dataImportServiceProvider = Provider<DataImportService>((ref) {
  return DataImportService(
    db: ref.watch(databaseProvider),
    collections: ref.watch(backupCollectionsProvider),
    settingsRepository: ref.watch(settingsRepositoryProvider),
    // Read lazily: the restore uploads only after its transaction commits, and
    // building the sync service before then would be work done for nothing on
    // an import that turns out to change nothing.
    pushRecords: (collection, records) => ref
        .read(remoteSyncServiceProvider)
        .pushRestoredRecords(collection, records),
    pushSettings: (settings) =>
        ref.read(remoteSyncServiceProvider).pushSettings(settings),
  );
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

/// Watches whether the sync backend is reachable, for the shell's offline
/// badge.
///
/// Rebuilt with [syncRepositoryProvider], so signing in or out swaps the probe
/// along with the repository behind it. While signed out that repository is a
/// no-op whose ping always succeeds — a local-only session is never reported
/// as offline, because there is nothing it is failing to reach.
///
/// [DevFlags.forceOffline] is read inside the probe (not watched), so flipping
/// the Dev toggle does not rebuild this controller or reset its schedule —
/// the next due probe fails the same way an unreachable Firestore would.
final connectivityStatusProvider =
    ChangeNotifierProvider<ConnectivityStatusController>((ref) {
      final ping = ref.watch(syncRepositoryProvider).ping;
      return ConnectivityStatusController(
        probe: () async {
          if (DevFlags.forceOffline) {
            throw StateError('DevFlags.forceOffline');
          }
          await ping();
        },
      );
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
    dreamRepository: ref.watch(dreamRepositoryProvider),
    todoRepository: ref.watch(todoRepositoryProvider),
    leetCodeRepository: ref.watch(leetCodeRepositoryProvider),
    studyRepository: ref.watch(studyRepositoryProvider),
    workoutRepository: ref.watch(workoutRepositoryProvider),
    calendarRepository: ref.watch(calendarRepositoryProvider),
    trackerRepository: ref.watch(trackerRepositoryProvider),
    financeRepository: ref.watch(financeRepositoryProvider),
    notificationRepository: ref.watch(notificationRepositoryProvider),
    bucketListRepository: ref.watch(bucketListRepositoryProvider),
    settingsRepository: ref.watch(settingsRepositoryProvider),
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
  // Repository-driven uploads (calendars, trackers, finance, the notification
  // inbox, the bucket list, tag colors, custom words, settings) reach the
  // service through here. Anything written before this point was buffered and
  // replays now.
  final syncedWrites = ref.watch(syncedWriteNotifierProvider);
  syncedWrites.onWrite = (collection, records) {
    unawaited(service.pushRecords(collection, records));
  };
  // Cleared before a rebuild installs the next service's handler, so a
  // disposed service is never the one a write is handed to.
  ref.onDispose(() => syncedWrites.onWrite = null);
  ref.onDispose(service.dispose);
  return service;
});

final journalWriteCoordinatorProvider = Provider<JournalWriteCoordinator>((
  ref,
) {
  return JournalWriteCoordinator(
    journalRepository: ref.watch(journalRepositoryProvider),
    remoteSync: ref.watch(remoteSyncServiceProvider),
    onEntrySaved: () => invalidateJournalEntryProviders(ref),
  );
});

final dreamWriteCoordinatorProvider = Provider<DreamWriteCoordinator>((ref) {
  return DreamWriteCoordinator(
    dreamRepository: ref.watch(dreamRepositoryProvider),
    remoteSync: ref.watch(remoteSyncServiceProvider),
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
    onChanged: () => invalidateAllDataProviders(ref),
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

/// The user's own quotes, newest first.
final customQuotesProvider = FutureProvider<List<CustomQuote>>((ref) {
  return ref.watch(settingsRepositoryProvider).getCustomQuotes();
});

/// Everything a new journal entry can draw from: the bundled quotes plus the
/// user's own. The browse-and-pick dialog lists exactly this.
final quotePoolProvider = FutureProvider<List<Quote>>((ref) async {
  final bundled = await ref.watch(bundledQuotesProvider.future);
  final custom = await ref.watch(customQuotesProvider.future);
  return [for (final q in custom) q.toQuote(), ...bundled];
});

final bundledQuotesProvider = FutureProvider<List<Quote>>((ref) {
  ref.keepAlive();
  return loadQuotesFromAssets();
});

/// Rebuilds [quoteBankProvider] whenever the pool changes, so a quote the user
/// just added is immediately eligible to be drawn.
final quotesLoadedProvider = FutureProvider<void>((ref) async {
  ref.keepAlive();
  final quotes = await ref.watch(quotePoolProvider.future);
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
    dreamRepository: ref.watch(dreamRepositoryProvider),
    todoRepository: ref.watch(todoRepositoryProvider),
    calendarRepository: ref.watch(calendarRepositoryProvider),
    trackerRepository: ref.watch(trackerRepositoryProvider),
    financeRepository: ref.watch(financeRepositoryProvider),
    leetCodeRepository: ref.watch(leetCodeRepositoryProvider),
    studyRepository: ref.watch(studyRepositoryProvider),
    workoutRepository: ref.watch(workoutRepositoryProvider),
    notificationRepository: ref.watch(notificationRepositoryProvider),
    bucketListRepository: ref.watch(bucketListRepositoryProvider),
    settingsRepository: ref.watch(settingsRepositoryProvider),
  );
});

/// The app's settings row.
///
/// A notifier rather than a plain [FutureProvider] purely so [saveSettings]
/// exists — see its doc for what that buys.
class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() {
    ref.keepAlive();
    return ref.watch(settingsRepositoryProvider).getSettings();
  }

  /// Persists [settings] and publishes it in the same step.
  ///
  /// The alternative — write, then `ref.invalidate(settingsProvider)` — costs
  /// every watcher *two* rebuilds for one change: one when the provider goes
  /// into its refreshing state, and one when the re-read row comes back off
  /// the disk a frame or more later. Every page in the shell watches this
  /// provider and they all stay mounted behind the navigation shell, so that
  /// second pass is a whole-app rebuild for a value this method is already
  /// holding.
  Future<void> saveSettings(AppSettings settings) async {
    await ref.read(settingsRepositoryProvider).saveSettings(settings);
    state = AsyncData(settings);
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

final colorPaletteProvider = Provider<List<int>>((ref) {
  return ref.watch(settingsProvider).valueOrNull?.colorPalette ??
      defaultColorPalette;
});

/// The user's snippet settings in the form every text field reads them.
///
/// A provider rather than a plain read so the [SnippetIndex] — which buckets
/// triggers for the keystroke path — is compiled once per settings change and
/// then shared by every mounted field, instead of being rebuilt on each app
/// rebuild.
///
/// An unrelated settings write must not reach a field, because re-publishing
/// the index tears down whatever tabstop session that field has open. Two
/// things enforce that, and both are needed:
///
///  * the [select] here, which holds the snippet list by identity —
///    [AppSettings.copyWith] passes the same instance through when snippets
///    are not the field being changed, so a toggle elsewhere stops right here;
///  * [SnippetIndex]'s value equality, for `ref.invalidate(settingsProvider)`,
///    which re-reads the row and so *does* hand back a new list instance. The
///    index compiled from it compares equal, so [SnippetScopeData] does too and
///    `updateShouldNotify` stays false.
final snippetScopeProvider = Provider<SnippetScopeData>((ref) {
  final config = ref.watch(
    settingsProvider.select((async) {
      final settings = async.valueOrNull;
      return (
        enabled: settings?.snippetsEnabled ?? false,
        expandKey: settings?.snippetExpandKey,
        snippets: settings?.snippets,
      );
    }),
  );
  final expandKey = config.expandKey;
  final snippets = config.snippets;
  if (expandKey == null || snippets == null) return SnippetScopeData.disabled;
  return SnippetScopeData(
    enabled: config.enabled,
    expandKey: expandKey,
    index: SnippetIndex.from(snippets),
  );
});

/// The active theme mode. Watched narrowly so a theme flip rebuilds
/// [MaterialApp] but nothing else re-derives from it.
final themeModeProvider = Provider<AppThemeMode>((ref) {
  return ref.watch(
    settingsProvider.select((s) => s.value?.themeMode ?? AppThemeMode.dark),
  );
});

/// Live petal-field parameters, sourced from settings. Unlike the geometric
/// params there is no debounced write-back notifier here — the petal settings
/// are only ever changed from the settings page, which saves directly.
final petalFieldParamsProvider = Provider<PetalFieldParams>((ref) {
  final s = ref.watch(settingsProvider).valueOrNull;
  if (s == null) return PetalFieldParams.defaults;
  return PetalFieldParams(
    color: Color(s.petalColor),
    minorColors: s.minorPetalColors.map(Color.new).toList(),
    maxPetals: s.petalMaxCount,
    fallSpeed: s.petalFallSpeed,
    windFrequency: s.petalWindFrequency,
    windStrength: s.petalWindStrength,
  );
});

final journalsProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(journalRepositoryProvider).listJournals();
});

final journalEntriesProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(lazyLoadProvider).loadRecentEntries();
});

final allJournalEntriesProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref
      .watch(journalRepositoryProvider)
      .getAllEntries(includeDeleted: false);
});

/// Journal entry list scope: [allJournalEntriesScope] for recent entries across
/// all journals, otherwise a specific journal id for that journal's full list.
const allJournalEntriesScope = '__all__';

final _journalEntryProviders = <ProviderOrFamily>[
  journalEntriesProvider,
  allJournalEntriesProvider,
  journalListEntriesProvider,
  journalEntryCountsProvider,
  journalAllEntryIdsProvider,
];

void invalidateJournalEntryProviders(Ref ref) {
  for (final provider in _journalEntryProviders) {
    ref.invalidate(provider);
  }
}

final journalEntryCountsProvider = FutureProvider<Map<String, int>>((
  ref,
) async {
  ref.keepAlive();
  return ref.watch(journalRepositoryProvider).countEntriesByJournal();
});

/// All persisted journal entry IDs, **including deleted ones**.
/// Used by the journal page to evict stale in-memory pending entries that were
/// soft-deleted (e.g. by an import), which wouldn't appear in the
/// non-deleted [journalListEntriesProvider] list.
final journalAllEntryIdsProvider = FutureProvider<Set<String>>((ref) async {
  ref.keepAlive();
  final entries = await ref
      .watch(journalRepositoryProvider)
      .getAllEntries(includeDeleted: true);
  return {for (final e in entries) e.id};
});

final journalListEntriesProvider =
    FutureProvider.family<List<JournalEntry>, String>((ref, scope) {
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

final allDreamEntriesProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(dreamRepositoryProvider).getAllEntries(includeDeleted: false);
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
  final lists = await ref.watch(todoListsProvider.future);
  final all = <TodoTask>[];
  for (final list in lists) {
    // Route through the per-list family provider (instead of calling the
    // repository directly) so this reuses its cache: invalidating this
    // provider alone — which happens on every save — no longer forces a
    // re-query of every list's tasks, only the ones whose own
    // todoTasksProvider(listId) was actually invalidated.
    all.addAll(await ref.watch(todoTasksProvider(list.id).future));
  }
  return all;
});

final todoListStatsProvider =
    FutureProvider<Map<String, ({int active, int completed})>>((ref) async {
      ref.keepAlive();
      final lists = await ref.watch(todoListsProvider.future);
      final stats = <String, ({int active, int completed})>{};
      for (final list in lists) {
        final tasks = await ref.watch(todoTasksProvider(list.id).future);
        stats[list.id] = (
          active: tasks.where((t) => !t.completed).length,
          completed: tasks.where((t) => t.completed).length,
        );
      }
      return stats;
    });

final calendarsProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(calendarRepositoryProvider).listCalendars();
});

/// Calendar events scope: `null` = "All calendars" (union of every calendar's
/// events), otherwise a specific calendar id for that calendar's events only.
final calendarEventsProvider =
    FutureProvider.family<List<CalendarEvent>, String?>((ref, calendarId) {
      ref.keepAlive();
      final repo = ref.watch(calendarRepositoryProvider);
      if (calendarId == null) return repo.listEvents();
      return repo.listEvents(calendarId: calendarId);
    });

final calendarTodoMarkersProvider = FutureProvider<List<CalendarTodoMarker>>((
  ref,
) async {
  ref.keepAlive();
  final tasks = await ref.watch(allTodoTasksProvider.future);
  final lists = await ref.watch(todoListsProvider.future);
  final settings = ref.watch(settingsProvider).value ?? const AppSettings();
  final listColors = {for (final list in lists) list.id: list.colorValue};
  return buildCalendarTodoMarkers(
    tasks,
    listColors,
    fallbackColorValue: settings.accentColor,
  );
});

final trackersProvider = FutureProvider((ref) {
  ref.keepAlive();
  return ref.watch(trackerRepositoryProvider).listTrackers();
});

/// All non-deleted ledger transactions, newest first.
final transactionsProvider = FutureProvider<List<FinancialTransaction>>((ref) {
  ref.keepAlive();
  return ref.watch(financeRepositoryProvider).listTransactions();
});

/// All non-deleted tracked LeetCode problems, newest-solved first.
final leetcodeProblemsProvider = FutureProvider<List<LeetCodeProblem>>((ref) {
  ref.keepAlive();
  return ref.watch(leetCodeRepositoryProvider).listProblems();
});

final leetCodeApiClientProvider = Provider<LeetCodeApiClient>((ref) {
  return LeetCodeApiClient();
});

/// Folders/decks directly under [parentFolderId] (null = root level), per
/// the breadcrumb-stack navigation model in STUDY.md.
final studyFoldersProvider = FutureProvider.family<List<StudyFolder>, String?>(
  (ref, parentFolderId) {
    ref.keepAlive();
    return ref
        .watch(studyRepositoryProvider)
        .listFolders(parentFolderId: parentFolderId);
  },
);

/// Single-folder lookup by id, used to render breadcrumb pill labels for the
/// current navigation stack without loading a whole level's children.
final studyFolderByIdProvider = FutureProvider.family<StudyFolder?, String>((
  ref,
  id,
) {
  ref.keepAlive();
  return ref.watch(studyRepositoryProvider).getFolder(id);
});

final studyDecksProvider = FutureProvider.family<List<StudyDeck>, String?>(
  (ref, parentFolderId) {
    ref.keepAlive();
    return ref.watch(studyRepositoryProvider).listDecks(parentFolderId: parentFolderId);
  },
);

final studyDeckByIdProvider = FutureProvider.family<StudyDeck?, String>((
  ref,
  id,
) {
  ref.keepAlive();
  return ref.watch(studyRepositoryProvider).getDeck(id);
});

final studyCardsProvider = FutureProvider.family<List<StudyCard>, String>((
  ref,
  deckId,
) {
  ref.keepAlive();
  return ref.watch(studyRepositoryProvider).listCards(deckId);
});

/// Every live card in the library, flattened across decks and folders. Backs
/// the Hub's "study everything due" entry point, which works from a set of
/// card ids that can span decks rather than from one deck's roster.
final studyAllCardsProvider = FutureProvider<List<StudyCard>>((ref) {
  ref.keepAlive();
  return ref.watch(studyRepositoryProvider).getAllCards(includeDeleted: false);
});

/// Global Study Hub header stats.
final studyStatsProvider =
    FutureProvider<({int pendingToday, int reviewedToday, int reviewedTotal})>((
      ref,
    ) async {
      final repo = ref.watch(studyRepositoryProvider);
      final pendingToday = await repo.countDueCards();
      final reviewedToday = await repo.countCardsReviewedToday();
      final reviewedTotal = await repo.countCardsReviewedTotal();
      return (
        pendingToday: pendingToday,
        reviewedToday: reviewedToday,
        reviewedTotal: reviewedTotal,
      );
    });

/// Per-deck tile stats shown in the library grid and Workbench header.
final studyDeckStatsProvider = FutureProvider.family<({int total, int due}), String>((
  ref,
  deckId,
) async {
  final repo = ref.watch(studyRepositoryProvider);
  final cards = await repo.listCards(deckId);
  final due = await repo.countDueCardsInDeck(deckId);
  return (total: cards.length, due: due);
});

/// Creates the two plans and (once) the starter exercise library. Every
/// workout provider below waits on this, so the planner can never render
/// against a half-seeded database on first launch.
final workoutSeedProvider = FutureProvider<void>((ref) async {
  ref.keepAlive();
  await ref.watch(workoutRepositoryProvider).ensureSeeded();
});

final exercisesProvider = FutureProvider<List<Exercise>>((ref) async {
  ref.keepAlive();
  await ref.watch(workoutSeedProvider.future);
  return ref.watch(workoutRepositoryProvider).listExercises();
});

final workoutPlansProvider = FutureProvider<List<WorkoutPlan>>((ref) async {
  ref.keepAlive();
  await ref.watch(workoutSeedProvider.future);
  return ref.watch(workoutRepositoryProvider).listPlans();
});

/// The plan that decides what "today's workout" is. Null only in the window
/// before seeding completes.
final activeWorkoutPlanProvider = Provider<WorkoutPlan?>((ref) {
  final plans = ref.watch(workoutPlansProvider).valueOrNull;
  if (plans == null || plans.isEmpty) return null;
  for (final plan in plans) {
    if (plan.isActive) return plan;
  }
  return plans.first;
});

final workoutPlanEntriesProvider =
    FutureProvider.family<List<WorkoutPlanEntry>, String>((ref, planId) async {
      ref.keepAlive();
      await ref.watch(workoutSeedProvider.future);
      return ref.watch(workoutRepositoryProvider).listPlanEntries(planId);
    });

final workoutSessionsProvider = FutureProvider<List<WorkoutSession>>((
  ref,
) async {
  ref.keepAlive();
  return ref.watch(workoutRepositoryProvider).listSessions();
});

/// The in-progress workout, if any. Drives the floating island's existence.
final activeWorkoutSessionProvider = FutureProvider<WorkoutSession?>((
  ref,
) async {
  ref.keepAlive();
  return ref.watch(workoutRepositoryProvider).getActiveSession();
});

final workoutSetLogsProvider =
    FutureProvider.family<List<WorkoutSetLog>, String>((ref, sessionId) {
      ref.keepAlive();
      return ref
          .watch(workoutRepositoryProvider)
          .listSetLogs(sessionId: sessionId);
    });

/// Every completed set of one exercise across all time, for the detail view's
/// sparkline and volume heatmap.
final exerciseSetLogsProvider =
    FutureProvider.family<List<WorkoutSetLog>, String>((ref, exerciseId) {
      ref.keepAlive();
      return ref
          .watch(workoutRepositoryProvider)
          .listSetLogs(exerciseId: exerciseId);
    });

/// Local calendar days that carry at least one finished workout. Backs both
/// the calendar day icon and the analytics "worked out" boolean, so the two
/// can never disagree about what counts.
final workoutDaysProvider = FutureProvider<Set<DateTime>>((ref) async {
  ref.keepAlive();
  final sessions = await ref.watch(workoutSessionsProvider.future);
  return {
    for (final session in sessions)
      if (session.endedAt != null) workoutDayKey(session.date),
  };
});

/// App-scoped invalidator, safe to call after the widget that captured it has
/// been disposed — which the exercise detail view needs when it flushes a
/// pending form-cue edit on the way out.
final workoutCacheInvalidatorProvider = Provider<void Function()>((ref) {
  return () => invalidateWorkoutProviders(ref);
});

/// Every read provider that a workout write can invalidate. Listed once so
/// the [Ref] and [WidgetRef] entry points below cannot fall out of step —
/// which they would, silently leaving one call site showing stale numbers.
final _workoutDataProviders = <ProviderOrFamily>[
  exercisesProvider,
  workoutPlansProvider,
  workoutPlanEntriesProvider,
  workoutSessionsProvider,
  activeWorkoutSessionProvider,
  workoutSetLogsProvider,
  exerciseSetLogsProvider,
  workoutDaysProvider,
];

void invalidateWorkoutProviders(Ref ref) {
  for (final provider in _workoutDataProviders) {
    ref.invalidate(provider);
  }
}

/// Widget-side counterpart of [invalidateWorkoutProviders].
void invalidateWorkoutProvidersFrom(WidgetRef ref) {
  for (final provider in _workoutDataProviders) {
    ref.invalidate(provider);
  }
}

/// Every read provider a pull of the repository-driven collections can make
/// stale — calendars, analytics, finance, the notification inbox, the bucket
/// list, tag colors, custom words and settings.
final _secondaryDataProviders = <ProviderOrFamily>[
  calendarsProvider,
  calendarEventsProvider,
  calendarTodoMarkersProvider,
  trackersProvider,
  trackerValuesProvider,
  transactionsProvider,
  subscriptionsProvider,
  budgetsProvider,
  financeCategoriesProvider,
  assetsProvider,
  assetValuationsProvider,
  savingsGoalsProvider,
  goalAllocationsProvider,
  pinnedNotesProvider,
  notificationDismissalsProvider,
  notificationFeedProvider,
  bucketListItemsProvider,
  tagColorsProvider,
  customWordsProvider,
  settingsProvider,
];

void invalidateSecondaryDataProviders(Ref ref) {
  for (final provider in _secondaryDataProviders) {
    ref.invalidate(provider);
  }
}

/// Every read provider in the app, for the two things that can rewrite any
/// collection at once: a live sync tick and a backup restore.
final _primaryDataProviders = <ProviderOrFamily>[
  journalsProvider,
  todoListsProvider,
  todoTasksProvider,
  allTodoTasksProvider,
  todoListStatsProvider,
  syncConflictsProvider,
  leetcodeProblemsProvider,
  studyFolderByIdProvider,
  studyFoldersProvider,
  studyDeckByIdProvider,
  studyDecksProvider,
  studyCardsProvider,
  studyAllCardsProvider,
  studyStatsProvider,
  studyDeckStatsProvider,
  allDreamEntriesProvider,
];

void invalidateAllDataProviders(Ref ref) {
  invalidateJournalEntryProviders(ref);
  for (final provider in _primaryDataProviders) {
    ref.invalidate(provider);
  }
  invalidateWorkoutProviders(ref);
  invalidateSecondaryDataProviders(ref);
}

/// Widget-side counterpart of [invalidateAllDataProviders].
void invalidateAllDataProvidersFrom(WidgetRef ref) {
  for (final provider in _journalEntryProviders) {
    ref.invalidate(provider);
  }
  for (final provider in _primaryDataProviders) {
    ref.invalidate(provider);
  }
  for (final provider in _workoutDataProviders) {
    ref.invalidate(provider);
  }
  for (final provider in _secondaryDataProviders) {
    ref.invalidate(provider);
  }
}

/// Total published LeetCode problem counts per difficulty, used as the
/// progress rings' denominators. Not persisted locally — on fetch failure
/// the ring UI degrades gracefully rather than blocking the page.
final leetcodeQuestionCountsProvider = FutureProvider<LeetCodeQuestionCounts>((
  ref,
) {
  ref.keepAlive();
  return ref.watch(leetCodeApiClientProvider).fetchQuestionCounts();
});

/// Shared tag -> ARGB color map (reused across journal + finance tagging).
final tagColorsProvider = FutureProvider<Map<String, int>>((ref) {
  ref.keepAlive();
  return ref.watch(settingsRepositoryProvider).getTagColors();
});

/// Bundled default spellcheck dictionary (~65k common English words).
final dictionaryProvider = FutureProvider<Set<String>>((ref) {
  ref.keepAlive();
  return loadDictionaryFromAssets();
});

/// User-added spellcheck dictionary words. Synced: the rows go up through the
/// repository's [SyncedWriteNotifier] path, and a removal travels as a
/// tombstone so it reaches the user's other devices. Managed in the Dictionary
/// settings dialog, and added to from the misspelling popup.
final customWordsProvider = FutureProvider<Set<String>>((ref) {
  ref.keepAlive();
  return ref.watch(settingsRepositoryProvider).getCustomWords();
});

/// Single long-lived [VoyagerSpellCheckService] instance kept in sync with
/// [dictionaryProvider]/[customWordsProvider]. Read (not watched) by text
/// field widgets, since the service mutates its internal word sets in place
/// rather than requiring a rebuild when the dictionary/custom words change.
final voyagerSpellCheckServiceProvider = Provider<VoyagerSpellCheckService>((
  ref,
) {
  ref.keepAlive();
  final service = VoyagerSpellCheckService();
  ref.listen(
    dictionaryProvider,
    (_, next) => next.whenData(service.updateDictionary),
    fireImmediately: true,
  );
  ref.listen(
    customWordsProvider,
    (_, next) => next.whenData(service.updateCustomWords),
    fireImmediately: true,
  );
  return service;
});

/// All non-deleted recurring subscriptions, soonest-due first.
final subscriptionsProvider = FutureProvider<List<Subscription>>((ref) {
  ref.keepAlive();
  return ref.watch(financeRepositoryProvider).listSubscriptions();
});

/// All non-deleted tag budgets, alphabetical by tag.
final budgetsProvider = FutureProvider<List<Budget>>((ref) {
  ref.keepAlive();
  return ref.watch(financeRepositoryProvider).listBudgets();
});

/// Tag-grouping categories used by the macro analytics breakdown.
final financeCategoriesProvider = FutureProvider<List<FinanceCategory>>((ref) {
  ref.keepAlive();
  return ref.watch(financeRepositoryProvider).listCategories();
});

/// Tracked assets contributing to net worth, alphabetical by name.
final assetsProvider = FutureProvider<List<Asset>>((ref) {
  ref.keepAlive();
  return ref.watch(financeRepositoryProvider).listAssets();
});

/// Every asset valuation, newest first.
final assetValuationsProvider = FutureProvider<List<AssetValuation>>((ref) {
  ref.keepAlive();
  return ref.watch(financeRepositoryProvider).listAssetValuations();
});

/// Savings goals in creation order.
final savingsGoalsProvider = FutureProvider<List<SavingsGoal>>((ref) {
  ref.keepAlive();
  return ref.watch(financeRepositoryProvider).listSavingsGoals();
});

/// Every goal allocation, newest first.
final goalAllocationsProvider = FutureProvider<List<GoalAllocation>>((ref) {
  ref.keepAlive();
  return ref.watch(financeRepositoryProvider).listGoalAllocations();
});

final trackerValuesProvider = FutureProvider.family((
  ref,
  String trackerId,
) async {
  ref.keepAlive();
  // The built-in trackers are virtual: their values are derived from the
  // user's journal entries rather than stored in the tracker table.
  if (trackerId == kJournalEntriesTrackerId) {
    final entries = await ref.watch(allJournalEntriesProvider.future);
    return journalEntriesTrackerValues(entries);
  }
  if (trackerId == kStreakTrackerId) {
    final entries = await ref.watch(allJournalEntriesProvider.future);
    return streakTrackerValues(entries);
  }
  if (trackerId == kWordCountTrackerId) {
    final entries = await ref.watch(allJournalEntriesProvider.future);
    final analytics = ref.watch(analyticsServiceProvider);
    return wordCountTrackerValues(entries, countWords: analytics.countWords);
  }
  if (trackerId == kDreamLoggedTrackerId) {
    final entries = await ref.watch(allDreamEntriesProvider.future);
    return dreamLoggedTrackerValues(entries);
  }
  if (trackerId == kWorkedOutTrackerId) {
    return workedOutTrackerValues(await ref.watch(workoutDaysProvider.future));
  }
  return ref.watch(trackerRepositoryProvider).listValues(trackerId);
});

/// Number of daily trackers that have no entry recorded for today's local date.
/// Feeds the notification bell's semi-important state.
final pendingStatEntriesProvider = FutureProvider<int>((ref) async {
  ref.keepAlive();
  final trackers = await ref.watch(trackersProvider.future);
  final today = DateTime.now();
  final todayLocal = DateTime(today.year, today.month, today.day);
  final dailyTrackers = trackers.where(
    (t) => t.cadence == TrackerCadence.daily && t.deletedAt == null,
  );
  var pending = 0;
  for (final tracker in dailyTrackers) {
    final values = await ref.watch(trackerValuesProvider(tracker.id).future);
    final hasToday = values.any(
      (v) =>
          v.periodStart.year == todayLocal.year &&
          v.periodStart.month == todayLocal.month &&
          v.periodStart.day == todayLocal.day,
    );
    if (!hasToday) pending++;
  }
  return pending;
});

final pinnedNotesProvider = FutureProvider<List<PinnedNote>>((ref) {
  ref.keepAlive();
  return ref.watch(notificationRepositoryProvider).listPinnedNotes();
});

final bucketListItemsProvider = FutureProvider<List<BucketListItem>>((ref) {
  ref.keepAlive();
  return ref.watch(bucketListRepositoryProvider).listItems();
});

/// Precomputed Life Tracker blossom stats that would otherwise require a full
/// table scan (tasks conquered, lifetime mood average). Deriving them from the
/// already-cached [allTodoTasksProvider]/[allJournalEntriesProvider] rather
/// than querying the database directly means the tree canvas's per-frame leaf
/// sway animation never triggers a recompute — only an actual task/journal
/// change does.
final lifeTrackerStatsProvider = FutureProvider<LifeTrackerCachedStats>((
  ref,
) async {
  ref.keepAlive();
  final tasks = await ref.watch(allTodoTasksProvider.future);
  final entries = await ref.watch(allJournalEntriesProvider.future);

  final tasksConquered = tasks.where((t) => t.completed).length;

  final moods = entries
      .where((e) => e.deletedAt == null && e.mood != null)
      .map((e) => e.mood!)
      .toList();
  final lifetimeMood = moods.isEmpty
      ? null
      : moods.reduce((a, b) => a + b) / moods.length;

  return LifeTrackerCachedStats(
    tasksConquered: tasksConquered,
    lifetimeMood: lifetimeMood,
  );
});

class LifeTrackerCachedStats {
  const LifeTrackerCachedStats({
    required this.tasksConquered,
    required this.lifetimeMood,
  });

  final int tasksConquered;

  /// Average of every non-null journal entry mood, or null if none exist yet.
  final double? lifetimeMood;
}

final notificationDismissalsProvider = FutureProvider<Set<String>>((ref) {
  ref.keepAlive();
  return ref.watch(notificationRepositoryProvider).listDismissals();
});

/// Every task/event/bill currently urgent enough to notify about, sorted
/// soonest-due first, before dismissals are applied.
final notificationFeedProvider = FutureProvider<List<NotificationFeedItem>>((
  ref,
) async {
  ref.keepAlive();
  final tasks = await ref.watch(allTodoTasksProvider.future);
  final events = await ref.watch(calendarEventsProvider(null).future);
  final bills = await ref.watch(subscriptionsProvider.future);
  return buildNotificationFeed(
    tasks: tasks,
    events: events,
    bills: bills,
    now: DateTime.now(),
  );
});

final visibleNotificationFeedProvider =
    FutureProvider<List<NotificationFeedItem>>((ref) async {
      final feed = await ref.watch(notificationFeedProvider.future);
      final dismissed = await ref.watch(notificationDismissalsProvider.future);
      return feed
          .where((item) => !dismissed.contains(item.dismissalKey))
          .toList();
    });

final hiddenNotificationFeedProvider =
    FutureProvider<List<NotificationFeedItem>>((ref) async {
      final feed = await ref.watch(notificationFeedProvider.future);
      final dismissed = await ref.watch(notificationDismissalsProvider.future);
      return feed
          .where((item) => dismissed.contains(item.dismissalKey))
          .toList();
    });

/// Idle/semi/important state driving the nav-rail bell's dot. A pending daily
/// tracker entry counts as semi-important even though it has no row of its
/// own in the feed (it's surfaced via the popover's embedded Analytics
/// section instead).
final notificationBadgeStateProvider = Provider<NotificationUrgency?>((ref) {
  final feed =
      ref.watch(visibleNotificationFeedProvider).valueOrNull ??
      const <NotificationFeedItem>[];
  final pendingStats = ref.watch(pendingStatEntriesProvider).valueOrNull ?? 0;
  if (feed.any((i) => i.urgency == NotificationUrgency.important)) {
    return NotificationUrgency.important;
  }
  if (feed.isNotEmpty || pendingStats > 0) return NotificationUrgency.semi;
  return null;
});

final geometricShaderProvider = FutureProvider<FragmentProgram?>((ref) async {
  ref.keepAlive();
  try {
    return await FragmentProgram.fromAsset('shaders/geometric_texture.frag');
  } catch (e, st) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: e,
        stack: st,
        library: 'geometric_texture',
        context: ErrorDescription('loading geometric texture shader'),
      ),
    );
    return null;
  }
});

/// Compiled paper-grain shader for the light theme. Same graceful-degradation
/// contract as [geometricShaderProvider]: null on failure, flat fill downstream.
final paperShaderProvider = FutureProvider<FragmentProgram?>((ref) async {
  ref.keepAlive();
  try {
    return await FragmentProgram.fromAsset('shaders/paper_texture.frag');
  } catch (e, st) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: e,
        stack: st,
        library: 'paper_texture',
        context: ErrorDescription('loading paper texture shader'),
      ),
    );
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

/// Live-tunable geometric texture wave parameters (persisted in local settings).
class GeometricWaveParamsNotifier extends StateNotifier<GeometricWaveParams> {
  GeometricWaveParamsNotifier(this._ref) : super(GeometricWaveParams.defaults) {
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
    final next = geometricWaveParamsFromSettings(settings);
    if (next != state) {
      state = next;
    }
  }

  void update(GeometricWaveParams params) {
    state = params;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persist(params));
    });
  }

  Future<void> resetToDefaults() async {
    _saveTimer?.cancel();
    state = GeometricWaveParams.defaults;
    await _persist(GeometricWaveParams.defaults);
  }

  Future<void> _persist(GeometricWaveParams params) async {
    final repo = _ref.read(settingsRepositoryProvider);
    final settings = await repo.getSettings();
    await repo.saveSettings(
      appSettingsWithGeometricWaveParams(settings, params),
    );
    _ref.invalidate(settingsProvider);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}

final geometricWaveParamsProvider =
    StateNotifierProvider<GeometricWaveParamsNotifier, GeometricWaveParams>(
      (ref) => GeometricWaveParamsNotifier(ref),
    );

/// Whether the dev-menu geometric texture slider panel is expanded.
final devGeometricTexturePanelOpenProvider = StateProvider<bool>(
  (ref) => false,
);

/// Whether the dev-menu geometric wave slider panel is expanded.
final devGeometricWavePanelOpenProvider = StateProvider<bool>((ref) => false);

/// Whether the dev-menu leaf design gallery is expanded.
final devLeafGalleryPanelOpenProvider = StateProvider<bool>((ref) => false);

/// Dev-only: when true the background is replaced with a row-fade visualiser
/// that shows the dark<->regular shade transition in isolation. Not persisted —
/// always off on a fresh launch so it can't be left on by accident.
final geometricDebugRowFadeProvider = StateProvider<bool>((ref) => false);

final shellDataWarmupProvider = FutureProvider<void>((ref) async {
  ref.keepAlive();
  if (DevFlags.disableCache) return;
  final listsFuture = ref.read(todoListsProvider.future);

  await Future.wait<void>([
    ref.read(geometricShaderProvider.future).then((_) {}),
    ref.read(paperShaderProvider.future).then((_) {}),
    ref.read(quotesLoadedProvider.future),
    ref.read(dictionaryProvider.future).then((_) {}),
    ref.read(customWordsProvider.future).then((_) {}),
    ref.read(settingsProvider.future).then((_) {}),
    ref.read(journalsProvider.future).then((_) {}),
    ref.read(journalEntriesProvider.future).then((_) {}),
    ref.read(journalEntryCountsProvider.future).then((_) {}),
    ref.read(calendarEventsProvider(null).future).then((_) {}),
    ref.read(trackersProvider.future).then((_) {}),
    listsFuture.then((lists) async {
      await Future.wait<void>([
        ref.read(allTodoTasksProvider.future).then((_) {}),
        ...lists.map(
          (list) => ref.read(todoTasksProvider(list.id).future).then((_) {}),
        ),
      ]);
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
    ref.read(pinnedNotesProvider.future).then((_) {}),
    ref.read(notificationDismissalsProvider.future).then((_) {}),
    ref.read(notificationFeedProvider.future).then((_) {}),
    ref.read(visibleNotificationFeedProvider.future).then((_) {}),
    ref.read(hiddenNotificationFeedProvider.future).then((_) {}),
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

final todoSortDebugLoggerProvider = ChangeNotifierProvider<TodoSortDebugLogger>(
  (ref) {
    final controller = TodoSortDebugLogger(
      settingsRepository: ref.watch(settingsRepositoryProvider),
      todoRepository: ref.watch(todoRepositoryProvider),
    );
    unawaited(controller.loadFromSettings());
    ref.listen<AsyncValue<AppSettings>>(settingsProvider, (previous, next) {
      next.whenData(controller.applySettings);
    });
    return controller;
  },
);

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

/// Starts/stops with the dev "Show FPS counter" toggle — its ticker only runs
/// while the overlay is actually visible.
final fpsMonitorProvider = ChangeNotifierProvider<FpsMonitorController>((ref) {
  final controller = FpsMonitorController();
  ref.onDispose(controller.dispose);
  ref.listen<bool>(
    devSettingsProvider.select((s) => s.showFpsCounter),
    (previous, showFpsCounter) {
      if (showFpsCounter) {
        controller.start();
      } else {
        controller.stop();
      }
    },
    fireImmediately: true,
  );
  return controller;
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
  if (DevFlags.disableCache) return const CacheStatusSnapshot(items: []);

  final warmup = ref.watch(warmupTrackerProvider);

  final items = <CacheItemStatus>[
    cacheStatusFromWarmup('Startup sync', warmup.stateFor('Startup sync')),
    cacheStatusFromWarmup('Weather warmup', warmup.stateFor('Weather warmup')),
    cacheStatusFromAsync('Quotes', ref.watch(quotesLoadedProvider)),
    cacheStatusFromAsync('Settings', ref.watch(settingsProvider)),
    cacheStatusFromAsync('Journals', ref.watch(journalsProvider)),
    cacheStatusFromAsync('Journal entries', ref.watch(journalEntriesProvider)),
    cacheStatusFromAsync(
      'Calendar events',
      ref.watch(calendarEventsProvider(null)),
    ),
    cacheStatusFromAsync('Trackers', ref.watch(trackersProvider)),
    cacheStatusFromAsync('Current weather', ref.watch(currentWeatherProvider)),
    cacheStatusFromAsync(
      'Weather forecast',
      ref.watch(weatherForecastProvider),
    ),
    cacheStatusFromAsync('Shell warmup', ref.watch(shellDataWarmupProvider)),
  ];

  final listsAsync = ref.watch(todoListsProvider);
  items.add(cacheStatusFromAsync('Todo lists', listsAsync));

  final lists = listsAsync.valueOrNull;
  if (lists != null) {
    items.add(
      cacheStatusFromAsync('All tasks', ref.watch(allTodoTasksProvider)),
    );
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
