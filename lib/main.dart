import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/app/voyager_app.dart';
import 'package:voyager/features/hotkeys/hotkey_service.dart';
import 'package:voyager/features/hotkeys/quick_popups.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await hotKeyManager.unregisterAll();
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
  var _postAuthWarmupStarted = false;

  @override
  void initState() {
    super.initState();
    _hotkeys = createHotkeyService();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final settings = await ref.read(settingsRepositoryProvider).getSettings();
    await _hotkeys.register(
      journalHotkey: settings.journalHotkey,
      todoHotkey: settings.todoHotkey,
      onJournal: _openQuickJournal,
      onTodo: _openQuickTodo,
    );
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
      localRefresh: () async {
        await lazy.loadRecentEntries();
      },
      purgeExpiredDeleted: backgroundSync.purgeExpiredDeleted,
    );
    await ref.read(shellDataWarmupProvider.future);
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
    _hotkeys.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authNotifierProvider, (previous, next) {
      if (next.isAuthenticated) {
        _schedulePostAuthWarmup();
      }
    });
    return const VoyagerApp();
  }
}
