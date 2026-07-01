import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/core/platform/windows_keyboard_workaround.dart';
import 'package:window_manager/window_manager.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/geometric_texture.dart';
import 'package:voyager/routing/app_router.dart';

class VoyagerApp extends ConsumerStatefulWidget {
  const VoyagerApp({super.key});

  @override
  ConsumerState<VoyagerApp> createState() => _VoyagerAppState();
}

class _VoyagerAppState extends ConsumerState<VoyagerApp>
    with WidgetsBindingObserver, WindowListener {
  RemoteSyncService? _remoteSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (desktopWindowChromeActive) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    if (desktopWindowChromeActive) {
      windowManager.removeListener(this);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void onWindowFocus() {
    setState(() {});
  }

  @override
  void onWindowRestore() {
    unawaited(windowManager.focus());
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
    final theme = VoyagerTheme.dark(accent: accent);

    return MaterialApp.router(
      title: 'Voyager',
      theme: theme,
      scrollBehavior: const _NoScrollbarScrollBehavior(),
      builder: (context, child) {
        return Stack(
          children: [
            const _GeometricBackground(),
            RepaintBoundary(
              child: DefaultTextStyle(
                style: AppFonts.style(color: theme.colorScheme.onSurface),
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
      routerConfig: router,
    );
  }
}

/// Watches shader/params providers independently so texture updates do not
/// rebuild [MaterialApp.router] or the navigation shell.
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
    final baseColor = Theme.of(context).scaffoldBackgroundColor;
    final animationTrigger = ref.watch(geometricAnimationTriggerProvider);

    return Positioned.fill(
      child: GeometricTexture(
        key: ValueKey(animationTrigger.count),
        program: program,
        baseColor: baseColor,
        accentColor: accent,
        params: params,
        animationSpeedMultiplier: animationTrigger.speedMultiplier,
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
}
