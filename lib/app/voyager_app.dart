import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/core/platform/windows_keyboard_workaround.dart';
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
import 'package:voyager/routing/app_router.dart';
import 'package:window_manager/window_manager.dart';

class VoyagerApp extends ConsumerStatefulWidget {
  const VoyagerApp({super.key});

  @override
  ConsumerState<VoyagerApp> createState() => _VoyagerAppState();
}

class _VoyagerAppState extends ConsumerState<VoyagerApp>
    with WidgetsBindingObserver, WindowListener {
  RemoteSyncService? _remoteSync;
  final _selectionOnResume = PreserveSelectionOnAppResume();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectionOnResume.install();
    if (desktopWindowChromeActive) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    if (desktopWindowChromeActive) {
      windowManager.removeListener(this);
    }
    _selectionOnResume.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void onWindowRestore() {
    unawaited(windowManager.focus());
  }

  @override
  void onWindowClose() async {
    await _flushAllPendingEdits();
    await windowManager.destroy();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(resyncWindowsKeyboardState());
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_flushAllPendingEdits());
    }
  }

  Future<void> _flushAllPendingEdits() async {
    await PendingFlushRegistry.instance.flushAll();
    final remoteSync = _remoteSync;
    if (remoteSync != null) {
      await remoteSync.flushAllPending();
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
    final themeMode = ref.watch(themeModeProvider);
    final theme = VoyagerTheme.forMode(themeMode, accent: accent);
    final vimEnabled = ref.watch(
      settingsProvider.select((s) => s.value?.vimModeEnabled ?? false),
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
            child: Stack(
              children: [
                const _AppBackground(),
                RepaintBoundary(
                  child: DefaultTextStyle(
                    style: AppFonts.style(color: theme.colorScheme.onSurface),
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ],
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
class _AppBackground extends ConsumerWidget {
  const _AppBackground();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    if (themeMode == AppThemeMode.light) {
      return const _PaperBackground();
    }
    return const _GeometricBackground();
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
