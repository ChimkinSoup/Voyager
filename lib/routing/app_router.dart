import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/desktop_window_frame.dart';
import 'package:voyager/features/auth/login_page.dart';
import 'package:voyager/features/shell/app_shell.dart';
import 'package:voyager/features/shell/shell_destinations.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';

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
    routes: [
      ShellRoute(
        builder: (_, _, child) => DesktopWindowFrame(child: child),
        routes: [
          GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
          StatefulShellRoute(
            builder: (_, _, child) => AppShell(child: child),
            navigatorContainerBuilder: shellBranchContainerBuilder,
            branches: [
              for (final dest in shellDestinations)
                StatefulShellBranch(
                  // Eagerly build these branches' first-visit-heavy pages
                  // (large widget trees, fl_chart) right when the shell
                  // mounts, instead of on first nav switch, so switching to
                  // them never has to pay that build cost mid-interaction.
                  preload: _preloadedShellPaths.contains(dest.path),
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
        if (settings.startupPageMode == StartupPageMode.lastSeen && settings.lastSeenNavPage != null) {
          return settings.lastSeenNavPage;
        } else if (settings.startupPageMode == StartupPageMode.custom && settings.customStartupPage != null) {
          return settings.customStartupPage;
        } else if (settings.navPageOrder != null && settings.navPageOrder!.isNotEmpty) {
          return settings.navPageOrder!.first;
        }
        return '/journal';
      }
      return null;
    },
  );
});
