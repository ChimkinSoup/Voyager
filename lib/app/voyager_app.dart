import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/app_tray.dart';
import 'package:voyager/core/caps_lock/caps_lock_indicator_scope.dart';
import 'package:voyager/core/dev/perf_stall_logger.dart';
import 'package:voyager/core/motion/modal_scrim_observer.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/platform/windows_keyboard_workaround.dart';
import 'package:voyager/core/snippets/snippet_enabled_scope.dart';
import 'package:voyager/core/spellcheck/autocorrect_enabled_scope.dart';
import 'package:voyager/core/snippets/snippet_settings_launcher.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/text/preserve_selection_on_app_resume.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/geometric_texture.dart';
import 'package:voyager/core/widgets/paper_texture.dart';
import 'package:voyager/core/widgets/petal_field.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/features/finance/finance_sheet_warm_up.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/hotkeys/floaters/floater_host.dart';
import 'package:voyager/features/notifications/reminder_sticky_stack.dart';
import 'package:voyager/features/settings/snippets_dialog.dart';
import 'package:voyager/routing/app_router.dart';
import 'package:window_manager/window_manager.dart';

class VoyagerApp extends ConsumerStatefulWidget {
  const VoyagerApp({super.key});

  @override
  ConsumerState<VoyagerApp> createState() => _VoyagerAppState();
}

// How long either half of a termination flush may wait on the network before
// the app stops caring. Matches the journal editor's own remote-flush deadline;
// the local writes it fronts complete in milliseconds.
const Duration _flushDeadline = Duration(seconds: 2);

const _instanceChannel = MethodChannel('voyager/instance');

class _VoyagerAppState extends ConsumerState<VoyagerApp>
    with WidgetsBindingObserver, WindowListener {
  RemoteSyncService? _remoteSync;
  final _selectionOnResume = PreserveSelectionOnAppResume();

  AppTray? _tray;
  StreamSubscription<String>? _reminderTaps;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A reminder notification brings its sticky forward — tapped while the
    // app runs, or the tap that launched it.
    final reminderOs = ref.read(reminderOsNotifierProvider);
    _reminderTaps = reminderOs.taps.listen(_focusReminder);
    unawaited(
      reminderOs.launchSourceKey().then((key) {
        if (key != null && mounted) _focusReminder(key);
      }),
    );
    ref.read(autoBackupServiceProvider).start();
    _selectionOnResume.install();
    WindowsKeyboardReconciler.instance.install();
    if (desktopWindowChromeActive) {
      windowManager.addListener(this);
      final tray = AppTray(
        onOpen: () => ref.read(floaterControllerProvider).showMainWindow(),
        onQuit: _quit,
      );
      _tray = tray;
      unawaited(tray.install());
      // A second launch, which exits after asking for this (see main.cpp).
      _instanceChannel.setMethodCallHandler((call) async {
        if (call.method == 'showMainWindow') {
          await ref.read(floaterControllerProvider).showMainWindow();
        }
      });
      unawaited(_warmUpFinanceSheet());
    }
  }

  /// Once startup has settled, so the snapshot's raster work doesn't land on
  /// the first frames. See [warmUpFinanceSheet].
  Future<void> _warmUpFinanceSheet() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted || !ref.read(authNotifierProvider).isAuthenticated) return;
    final context = ref
        .read(routerProvider)
        .routerDelegate
        .navigatorKey
        .currentContext;
    if (context == null || !context.mounted) return;
    try {
      await warmUpFinanceSheet(context);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'VoyagerApp',
          context: ErrorDescription('while warming up the transaction sheet'),
        ),
      );
    }
  }

  void _focusReminder(String sourceKey) {
    if (desktopWindowChromeActive) {
      unawaited(ref.read(floaterControllerProvider).showMainWindow());
    }
    ref.read(reminderEngineProvider).focus(sourceKey);
  }

  @override
  void dispose() {
    unawaited(_reminderTaps?.cancel());
    if (desktopWindowChromeActive) {
      windowManager.removeListener(this);
      _instanceChannel.setMethodCallHandler(null);
    }
    unawaited(_tray?.dispose());
    WindowsKeyboardReconciler.instance.uninstall();
    _selectionOnResume.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void onWindowRestore() {
    unawaited(windowManager.focus());
  }

  /// Closing the window hides it to the tray: the process stays up so the
  /// global hotkeys keep working. [_quit] is the way out. While a floater has
  /// the window, closing it closes just the floater.
  @override
  void onWindowClose() async {
    final floaters = ref.read(floaterControllerProvider);
    if (floaters.active != null) {
      await floaters.dismiss();
      return;
    }
    mainContentOnScreen.value = false;
    await windowManager.hide();
    try {
      await _flushAllPendingEdits();
    } catch (_) {}
  }

  Future<void> _quit() async {
    // Never let the flush decide whether the app quits. Each stage of it
    // ends in a Firestore write that, with an unreachable server, either hangs
    // until the device is back online or throws once SyncRetryPolicy gives up —
    // and both used to reach straight past `destroy()`, leaving a window that
    // would not close. The flush is bounded per stage below; anything still
    // unsent has already been written locally and goes out on the next launch.
    try {
      await _flushAllPendingEdits();
    } catch (_) {}
    try {
      await hotKeyManager.unregisterAll();
      await _tray?.dispose();
    } catch (_) {}
    await windowManager.destroy();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(resyncWindowsKeyboardState());
      // Timers do not run while a phone app is suspended.
      ref.read(reminderEngineProvider).refresh();
      if (isAndroid) ref.read(autoBackupServiceProvider).resume();
    }
    // Android backs up only in the foreground (AUTO_BACKUP_HLD.md §6.1).
    if (isAndroid && state == AppLifecycleState.paused) {
      ref.read(autoBackupServiceProvider).pause();
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_flushAllPendingEdits());
    }
  }

  Future<void> _flushAllPendingEdits() async {
    await PendingFlushRegistry.instance.flushAll(
      perCallbackDeadline: _flushDeadline,
    );
    // Re-read while mounted: the cached instance is whichever service the
    // last build saw, and a rebuilt provider leaves it disposed — with its
    // pending uploads handed on to a successor this flush would never reach.
    final remoteSync = mounted
        ? ref.read(remoteSyncServiceProvider)
        : _remoteSync;
    if (remoteSync != null) {
      await remoteSync.flushAllPending().timeout(
        _flushDeadline,
        onTimeout: () {},
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _remoteSync = ref.read(remoteSyncServiceProvider);
    final accent = Color(
      ref.watch(
        settingsProvider.select((s) => s.value?.accentColor ?? 0xFF7C9EFF),
      ),
    );
    final router = ref.watch(routerProvider);
    PerfStallLogger.instance.currentLocation = () =>
        router.routerDelegate.currentConfiguration.uri.toString();
    final themeMode = ref.watch(themeModeProvider);
    final theme = VoyagerTheme.forMode(themeMode, accent: accent);
    final vimEnabled = ref.watch(
      settingsProvider.select((s) => s.value?.vimModeEnabled ?? false),
    );
    final snippetScope = ref.watch(snippetScopeProvider);
    final autocorrectScope = ref.watch(autocorrectScopeProvider);
    final capsLockIndicator = ref.watch(
      settingsProvider.select((s) => s.value?.capsLockIndicatorEnabled ?? true),
    );

    return MaterialApp.router(
      title: 'Voyager',
      theme: theme,
      scrollBehavior: const _NoScrollbarScrollBehavior(),
      builder: (context, child) {
        return TooltipVisibility(
          visible: false,
          // Wraps the Navigator, so dialogs and popovers — which mount into
          // its overlay — see the same Vim setting as the page behind them.
          child: VimEnabledScope(
            enabled: vimEnabled,
            child: CapsLockIndicatorScope(
              enabled: capsLockIndicator,
              child: AutocorrectEnabledScope(
                data: autocorrectScope,
                child: SnippetEnabledScope(
                  data: snippetScope,
                  // Lets a field's right-click quick-add reach the full
                  // settings dialog without core importing features — see
                  // [SnippetSettingsLauncher].
                  child: SnippetSettingsLauncher(
                    open: showSnippetsDialog,
                    child: DefaultTextStyle(
                      style: AppFonts.style(color: theme.colorScheme.onSurface),
                      child: FloaterHost(
                        child: Stack(
                          children: [
                            const _AppBackground(),
                            RepaintBoundary(
                              child: child ?? const SizedBox.shrink(),
                            ),
                            // Inside the floater host, so a floater that has
                            // the window never shows the main app's stickies.
                            const ReminderStickyStack(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      routerConfig: router,
    );
  }
}

/// Selects and renders the theme's background pipeline. Watches shader/params
/// providers independently so texture updates do not rebuild
/// [MaterialApp.router] or the navigation shell.
///
/// Dark = the triangle grid shader with its wave animation. Light = a static
/// paper-grain shader with a falling petal field drawn over it.
///
/// Both animations pause while a sheet or dialog is open — see
/// [modalScrimOpen] for why that is a GPU cost and not a style choice.
class _AppBackground extends ConsumerWidget {
  const _AppBackground();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: modalScrimOpen,
      builder: (context, covered, child) =>
          TickerMode(enabled: !covered, child: child!),
      child: themeMode == AppThemeMode.light
          ? const _PaperBackground()
          : const _GeometricBackground(),
    );
  }
}

class _GeometricBackground extends ConsumerWidget {
  const _GeometricBackground();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = Color(
      ref.watch(
        settingsProvider.select((s) => s.value?.accentColor ?? 0xFF7C9EFF),
      ),
    );
    final program = ref.watch(geometricShaderProvider).valueOrNull;
    final params = ref.watch(geometricTextureParamsProvider);
    final waveParams = ref.watch(geometricWaveParamsProvider);
    final debugRowFade = ref.watch(geometricDebugRowFadeProvider);
    final baseColor = Theme.of(context).scaffoldBackgroundColor;

    return Positioned.fill(
      child: GeometricTexture(
        program: program,
        baseColor: baseColor,
        accentColor: accent,
        params: params,
        waveParams: waveParams,
        debugRowFade: debugRowFade,
      ),
    );
  }
}

/// Light-theme background: cream paper grain with rose petals fluttering over
/// it. The petal field owns its own animation timer; the paper below is static.
class _PaperBackground extends ConsumerWidget {
  const _PaperBackground();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final program = ref.watch(paperShaderProvider).valueOrNull;
    final petalParams = ref.watch(petalFieldParamsProvider);
    final baseColor = Theme.of(context).scaffoldBackgroundColor;
    // A warm gray a few shades down from the ground: dark enough for the specks
    // to register, light enough that the surface still reads as clean paper.
    final speckColor = Color.lerp(baseColor, const Color(0xFF8C8578), 0.5)!;

    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: PaperTexture(
              program: program,
              baseColor: baseColor,
              speckColor: speckColor,
            ),
          ),
          Positioned.fill(child: PetalField(params: petalParams)),
        ],
      ),
    );
  }
}

class _NoScrollbarScrollBehavior extends MaterialScrollBehavior {
  const _NoScrollbarScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }

  /// Rubber-band overscroll on every platform, not just the Apple ones.
  ///
  /// Material hands Windows and Android a [ClampingScrollPhysics], which stops
  /// dead at the edge — a hard stop reads as "this list is frozen", where
  /// progressive resistance reads as "responsive, but there is nothing more
  /// here". [RangeMaintainingScrollPhysics] stays as the parent exactly as the
  /// framework's own branches have it, so a list that grows while it is being
  /// read still doesn't jump under the reader.
  ///
  /// The deceleration rate still splits by input: a thrown finger carries
  /// further than a trackpad or wheel, which is why the framework gives iOS
  /// the normal rate and desktop the fast one.
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    switch (getPlatform(context)) {
      case TargetPlatform.iOS:
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        return const BouncingScrollPhysics(
          parent: RangeMaintainingScrollPhysics(),
        );
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return const BouncingScrollPhysics(
          decelerationRate: ScrollDecelerationRate.fast,
          parent: RangeMaintainingScrollPhysics(),
        );
    }
  }

  /// With the edges now rubber-banding, Android's stretch would be a second
  /// overscroll effect layered on the first. Bouncing platforms ship no
  /// indicator for exactly this reason — the resistance *is* the feedback.
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
