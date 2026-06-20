import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/app/voyager_app.dart';
import 'package:voyager/features/hotkeys/hotkey_service.dart';
import 'package:voyager/features/hotkeys/quick_popups.dart';
import 'package:voyager/firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final deviceId = await ensureDeviceId(settingsRepo);
    ref.read(deviceIdProvider.notifier).state = deviceId;

    final settings = await settingsRepo.getSettings();
    await _hotkeys.register(
      journalHotkey: settings.journalHotkey,
      todoHotkey: settings.todoHotkey,
      onJournal: _openQuickJournal,
      onTodo: _openQuickTodo,
    );

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
    await ref.read(quotesLoadedProvider.future);
    final sync = ref.read(syncEngineProvider);
    final lazy = ref.read(lazyLoadProvider);
    final backgroundSync = ref.read(backgroundSyncOrchestratorProvider);
    await sync.pullOnStartup(
      purgeExpiredDeleted: backgroundSync.purgeExpiredDeleted,
      pullFromRemote: () async {
        await ref.read(remoteSyncServiceProvider).pullAll();
        ref.read(liveSyncProvider).start();
        ref.invalidate(journalEntriesProvider);
        ref.invalidate(journalsProvider);
        ref.invalidate(settingsProvider);
        ref.invalidate(todoListsProvider);
      },
      localRefresh: () async {
        await lazy.loadRecentEntries();
      },
    );
    try {
      await ref.read(weatherServiceProvider).refreshIfNeeded();
      await ref.read(weatherServiceProvider).fetchForecastIfNeeded();
      ref.invalidate(currentWeatherProvider);
      ref.invalidate(weatherForecastProvider);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'VoyagerBootstrap',
          context: ErrorDescription('while warming up weather data'),
        ),
      );
    }
    await ref.read(shellDataWarmupProvider.future);
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
