import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/app/voyager_app.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/core/platform/windows_keyboard_workaround.dart';
import 'package:voyager/core/sync/outbox_sync_worker.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/features/hotkeys/hotkey_service.dart';
import 'package:voyager/features/hotkeys/quick_popups.dart';
import 'package:voyager/firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installWindowsKeyboardWorkaround();
  await configureDesktopWindow();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  try {
    await hotKeyManager.unregisterAll();
  } catch (_) {
    // Ignore if another instance owns global hotkeys.
  }
  runApp(const ProviderScope(child: VoyagerBootstrap()));
}

class VoyagerBootstrap extends ConsumerStatefulWidget {
  const VoyagerBootstrap({super.key});

  @override
  ConsumerState<VoyagerBootstrap> createState() => _VoyagerBootstrapState();
}

class _VoyagerBootstrapState extends ConsumerState<VoyagerBootstrap>
    with WidgetsBindingObserver {
  late final HotkeyService _hotkeys;
  Timer? _postAuthWarmupTimer;
  Timer? _weatherRefreshTimer;
  var _postAuthWarmupStarted = false;

  /// Last connectivity state seen, so the offline→online *edge* can be told
  /// apart from a notification that merely repeats it.
  bool? _wasOnline;
  var _resumingSync = false;

  @override
  void initState() {
    super.initState();
    _hotkeys = createHotkeyService();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  /// Coming back to the window is a cheap moment to empty the outbox.
  ///
  /// A desktop session this app is built around — global hotkeys, tray-style
  /// usage — can run for days, and the drain otherwise only ever ran at
  /// startup and sign-in. An empty queue costs one indexed query.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    if (!ref.read(authNotifierProvider).isAuthenticated) return;
    if (OutboxSyncWorker.isInitialized) {
      unawaited(OutboxSyncWorker.instance.startDraining());
    }
  }

  /// Restarts sync on the offline→online edge.
  ///
  /// [ConnectivityStatusController] was already detecting this transition, but
  /// its only consumer was the shell's offline badge: the badge cleared while
  /// the queued uploads sat in `pending_uploads` and the local database stayed
  /// out of step with remote until the app was restarted.
  void _onConnectivityChanged(bool isOnline) {
    final wasOnline = _wasOnline;
    _wasOnline = isOnline;
    if (!isOnline || wasOnline != false) return;
    unawaited(_resumeSyncAfterReconnect());
  }

  Future<void> _resumeSyncAfterReconnect() async {
    if (_resumingSync || !mounted) return;
    if (!ref.read(authNotifierProvider).isAuthenticated) return;
    _resumingSync = true;
    try {
      if (OutboxSyncWorker.isInitialized) {
        // Idempotent — a drain already running simply keeps going.
        unawaited(OutboxSyncWorker.instance.startDraining());
      }
      // Weather is skipped: it runs on its own minute timer and refreshing it
      // here would spend a request the timer is about to spend anyway.
      await ref.read(remoteSyncServiceProvider).pullAll(skipWeather: true);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'VoyagerBootstrap',
          context: ErrorDescription('while resuming sync after reconnecting'),
        ),
      );
    } finally {
      _resumingSync = false;
    }
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    final db = ref.read(databaseProvider);
    final authRepo = ref.read(authRepositoryProvider);
    OutboxSyncWorker.initialize(
      db,
      FirebaseFirestore.instance,
      authRepo,
      // Read lazily: the drain only reaches for this once it has a queued row
      // in a collection that keeps a character-operation log.
      pushDocument: (collection, documentId, {forceCrdtOverwrite = false}) =>
          ref
              .read(remoteSyncServiceProvider)
              .pushOutboxDocument(
                collection,
                documentId,
                forceCrdtOverwrite: forceCrdtOverwrite,
              ),
    );

    final settingsRepo = ref.read(settingsRepositoryProvider);
    final deviceId = await ensureDeviceId(settingsRepo);
    if (!mounted) return;
    ref.read(deviceIdProvider.notifier).state = deviceId;

    final settings = await settingsRepo.getSettings();
    if (!mounted) return;
    DevFlags.disableCache = settings.devDisableCache;
    try {
      await _hotkeys.register(
        journalHotkey: settings.journalHotkey,
        todoHotkey: settings.todoHotkey,
        onJournal: _openQuickJournal,
        onTodo: _openQuickTodo,
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'VoyagerBootstrap',
          context: ErrorDescription('while registering global hotkeys'),
        ),
      );
    }

    if (ref.read(authNotifierProvider).isAuthenticated) {
      _onAuthStateChanged(true);
    }
  }

  void _schedulePostAuthWarmup() {
    if (_postAuthWarmupStarted) return;
    if (DevFlags.disableCache) return;
    _postAuthWarmupStarted = true;
    _postAuthWarmupTimer?.cancel();
    _postAuthWarmupTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      unawaited(_warmUpAfterFirstShellFrame());
    });
  }

  Future<void> _warmUpAfterFirstShellFrame() async {
    if (!mounted) return;
    if (DevFlags.disableCache) return;

    final sync = ref.read(syncEngineProvider);
    final lazy = ref.read(lazyLoadProvider);
    final backgroundSync = ref.read(backgroundSyncOrchestratorProvider);
    final remoteSync = ref.read(remoteSyncServiceProvider);
    final liveSync = ref.read(liveSyncProvider);
    final weatherService = ref.read(weatherServiceProvider);
    final quotesFuture = ref.read(quotesLoadedProvider.future);
    final shellWarmupFuture = ref.read(shellDataWarmupProvider.future);

    await quotesFuture;
    if (!mounted) return;

    final warmupTracker = ref.read(warmupTrackerProvider);
    warmupTracker.begin('Startup sync');
    try {
      await sync.pullOnStartup(
        purgeExpiredDeleted: backgroundSync.purgeExpiredDeleted,
        pullFromRemote: () async {
          await remoteSync.pullAll();
          if (!mounted) return;
          liveSync.start();
          ref.invalidate(journalEntriesProvider);
          ref.invalidate(journalsProvider);
          ref.invalidate(settingsProvider);
          ref.invalidate(todoListsProvider);
        },
        localRefresh: () async {
          await lazy.loadRecentEntries();
        },
      );
      warmupTracker.complete('Startup sync');
    } catch (_) {
      warmupTracker.fail('Startup sync');
      rethrow;
    }
    if (!mounted) return;

    warmupTracker.begin('Weather warmup');
    try {
      await weatherService.refreshIfNeeded();
      if (!mounted) return;
      await weatherService.fetchForecastIfNeeded();
      if (!mounted) return;
      ref.invalidate(currentWeatherProvider);
      ref.invalidate(weatherForecastProvider);
      warmupTracker.complete('Weather warmup');
    } catch (error, stackTrace) {
      warmupTracker.fail('Weather warmup');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'VoyagerBootstrap',
          context: ErrorDescription('while warming up weather data'),
        ),
      );
    }
    if (!mounted) return;
    await shellWarmupFuture;
  }

  void _startWeatherRefreshTimer() {
    _weatherRefreshTimer?.cancel();
    _weatherRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(_refreshWeatherIfStale());
    });
  }

  void _stopWeatherRefreshTimer() {
    _weatherRefreshTimer?.cancel();
    _weatherRefreshTimer = null;
  }

  Future<void> _refreshWeatherIfStale() async {
    if (!mounted) return;
    if (!ref.read(authNotifierProvider).isAuthenticated) return;

    final weather = ref.read(weatherServiceProvider);

    // Drop forecast days that rolled past at local midnight, even when the
    // 15-minute API cache is still fresh.
    if (await weather.pruneCachedForecastIfNeeded()) {
      if (!mounted) return;
      ref.invalidate(weatherForecastProvider);
    }

    final weatherStale = await weather.isCacheStale();
    final forecastStale = await weather.isForecastCacheStale();
    if (!weatherStale && !forecastStale) return;

    if (weatherStale) {
      await weather.refreshIfNeeded();
      if (!mounted) return;
      ref.invalidate(currentWeatherProvider);
    }
    if (forecastStale) {
      await weather.fetchForecastIfNeeded();
      if (!mounted) return;
      ref.invalidate(weatherForecastProvider);
    }
  }

  void _onAuthStateChanged(bool isAuthenticated) {
    if (isAuthenticated) {
      _schedulePostAuthWarmup();
      _startWeatherRefreshTimer();
      if (OutboxSyncWorker.isInitialized) {
        OutboxSyncWorker.instance.startDraining();
      }
    } else {
      _stopWeatherRefreshTimer();
    }
  }

  void _openQuickJournal() {
    showVoyagerDialog<void>(
      context: context,
      builder: (_) => const QuickJournalPopup(),
    );
  }

  void _openQuickTodo() {
    showVoyagerDialog<void>(context: context, builder: (_) => const QuickTodoPopup());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _postAuthWarmupTimer?.cancel();
    _weatherRefreshTimer?.cancel();
    _hotkeys.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authNotifierProvider, (previous, next) {
      _onAuthStateChanged(next.isAuthenticated);
    });
    // The controller is the same object on both sides of the callback, so the
    // previous value is no help — [_onConnectivityChanged] tracks it.
    ref.listen(connectivityStatusProvider, (_, controller) {
      _onConnectivityChanged(controller.isOnline);
    });
    return const VoyagerApp();
  }
}
