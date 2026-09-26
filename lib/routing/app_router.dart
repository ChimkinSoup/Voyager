import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/motion/modal_scrim_observer.dart';
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
                    GoRoute(path: dest.path, builder: (_, _) => dest.page),
                  ],
                ),
            ],
          ),
        ],
      ),
    ],
    redirect: (context, state) async {
      final loggingIn = state.matchedLocation == '/login';
      if (!auth.isAuthenticated && !loggingIn) return '/login';
      if (auth.isAuthenticated && loggingIn) {
        final settings = await settingsRepo.getSettings();
        // A hidden page, or one this build leaves out, falls back to the
        // first page in the rail.
        return startupPathFor(settings, switch (settings.startupPageMode) {
          StartupPageMode.lastSeen => settings.lastSeenNavPage,
          StartupPageMode.custom => settings.customStartupPage,
          StartupPageMode.first => null,
        });
      }
      return null;
    },
  );
});
