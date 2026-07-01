import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/app/voyager_app.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/core/platform/windows_keyboard_workaround.dart';
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

class _VoyagerBootstrapState extends ConsumerState<VoyagerBootstrap> {
  late final HotkeyService _hotkeys;
  Timer? _postAuthWarmupTimer;
  Timer? _weatherRefreshTimer;
  var _postAuthWarmupStarted = false;

  @override
  void initState() {
    super.initState();
    _hotkeys = createHotkeyService();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final deviceId = await ensureDeviceId(settingsRepo);
    if (!mounted) return;
    ref.read(deviceIdProvider.notifier).state = deviceId;

    final settings = await settingsRepo.getSettings();
    if (!mounted) return;
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
    _postAuthWarmupStarted = true;
    _postAuthWarmupTimer?.cancel();
    _postAuthWarmupTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      unawaited(_warmUpAfterFirstShellFrame());
    });
  }

  Future<void> _warmUpAfterFirstShellFrame() async {
    if (!mounted) return;

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
    } else {
      _stopWeatherRefreshTimer();
    }
  }

  void _openQuickJournal() {
    showDialog<void>(
      context: context,
      builder: (_) => const QuickJournalPopup(),
    );
  }

  void _openQuickTodo() {
    showDialog<void>(context: context, builder: (_) => const QuickTodoPopup());
  }

  @override
  void dispose() {
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
    return const VoyagerApp();
  }
}
