import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/motion/modal_scrim_observer.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/widgets/desktop_window_frame.dart';
import 'package:voyager/features/auth/login_page.dart';
import 'package:voyager/features/shell/app_shell.dart';
import 'package:voyager/features/shell/shell_destinations.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';

/// Pages built with the shell. The rest are built by the shell's warm-up a
/// few seconds later, or on first visit if that comes sooner — see
/// [ShellBranchContainer.mountLater].
const _preloadedShellPaths = {
  '/journal',
  '/dream-journal',
  '/todo',
  '/calendar',
  '/analytics',
  '/finance',
  '/life-tracker',
  '/study',
};

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authNotifierProvider);
  final settingsRepo = ref.read(settingsRepositoryProvider);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: auth,
    // A fresh instance per router: this provider rebuilds on auth changes, and
    // an observer can't be shared with the navigator it is replacing.
    observers: [ModalScrimObserver()],
    routes: [
      ShellRoute(
        builder: (_, _, child) => DesktopWindowFrame(child: child),
        routes: [
          GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
          StatefulShellRoute(
            builder: (_, _, child) => AppShell(child: child),
            navigatorContainerBuilder: shellBranchContainerBuilder(
              mountLater: {
                for (var i = 0; i < shellDestinations.length; i++)
                  if (!_preloadedShellPaths.contains(shellDestinations[i].path))
                    i,
              },
              // Like the login warm-ups, off while the dev cache flag is. Off
              // in debug builds too, where page builds cost far more: there
              // the warm-up took the first 40s' stalls from ~10s to 46s in
              // the perf stall log, against no change in a profile build.
              shouldWarm: kDebugMode || DevFlags.disableCache
                  ? null
                  : (i) =>
                        !(ref
                                .read(settingsProvider)
                                .valueOrNull
                                ?.hiddenNavPages
                                .contains(shellDestinations[i].path) ??
                            false),
            ),
            branches: [
              for (final dest in shellDestinations)
                StatefulShellBranch(
                  // Every branch gets its navigator up front, so the shell
                  // container can build it when it chooses: with the shell
                  // for [_preloadedShellPaths], a few seconds on for the rest.
                  preload: true,
                  routes: [
                    GoRoute(
                      path: dest.path,
                      builder: (_, _) => _RemountOnRestore(child: dest.page),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    ],
    redirect: (context, state) async {
      // An account restored at launch is not signed in until it is admitted:
      // waiting here keeps the login page from flashing up meanwhile.
      if (auth.isSettling) await auth.settled;
      final loggingIn = state.matchedLocation == '/login';
      if (!auth.isAuthenticated && !loggingIn) return '/login';
      if (auth.isAuthenticated && loggingIn) {
        return startupRedirectPath = startupPathOf(
          await settingsRepo.getSettings(),
        );
      }
      return null;
    },
  );
});

/// The page the last sign-in redirect opened. The startup pull moves the user
/// on from it if the pulled settings name another page (BUG-011).
String? startupRedirectPath;

/// The page to open on launch or sign-in. A hidden page, or one this build
/// leaves out, falls back to the first page in the rail.
String startupPathOf(AppSettings settings) =>
    startupPathFor(settings, switch (settings.startupPageMode) {
      StartupPageMode.lastSeen => settings.lastSeenNavPage,
      StartupPageMode.custom => settings.customStartupPage,
      StartupPageMode.first => null,
    });

/// Rebuilds [child] from scratch after a backup restore.
///
/// The shell keeps every page mounted, and a page holds what it loaded —
/// an open entry's text, a draft, a selection — for as long as it lives. After
/// a restore that is the pre-restore state, and the page's next save wrote it
/// back over the restore. A fresh instance reads the restored rows instead.
class _RemountOnRestore extends StatelessWidget {
  const _RemountOnRestore({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: restoreGeneration,
    builder: (_, generation, _) =>
        KeyedSubtree(key: ValueKey(generation), child: child),
  );
}
