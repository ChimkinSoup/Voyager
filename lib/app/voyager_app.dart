import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/windows_keyboard_workaround.dart';
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
    with WidgetsBindingObserver {
  RemoteSyncService? _remoteSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
    final settings = ref.watch(settingsProvider).value;
    final router = ref.watch(routerProvider);
    final accent = Color(settings?.accentColor ?? 0xFF7C9EFF);
    final theme = VoyagerTheme.dark(accent: accent);
    final geometricProgram = ref.watch(geometricShaderProvider).valueOrNull;
    final geometricParams = ref.watch(geometricTextureParamsProvider);

    return MaterialApp.router(
      title: 'Voyager',
      theme: theme,
      scrollBehavior: const _NoScrollbarScrollBehavior(),
      builder: (context, child) {
        return Stack(
          children: [
            Positioned.fill(
              child: GeometricTexture(
                program: geometricProgram,
                baseColor: theme.scaffoldBackgroundColor,
                accentColor: accent,
                params: geometricParams,
              ),
            ),
            DefaultTextStyle(
              style: AppFonts.style(color: theme.colorScheme.onSurface),
              child: child ?? const SizedBox.shrink(),
            ),
          ],
        );
      },
      routerConfig: router,
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
