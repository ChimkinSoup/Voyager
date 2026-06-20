import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/features/auth/login_page.dart';
import 'package:voyager/features/shell/app_shell.dart';
import 'package:voyager/features/shell/shell_destinations.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authNotifierProvider);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: auth,
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      StatefulShellRoute(
        builder: (_, _, child) => AppShell(child: child),
        navigatorContainerBuilder: shellBranchContainerBuilder,
        branches: [
          for (final dest in shellDestinations)
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: dest.path,
                  builder: (_, _) => dest.page,
                ),
              ],
            ),
        ],
      ),
    ],
    redirect: (context, state) {
      final loggingIn = state.matchedLocation == '/login';
      if (!auth.isAuthenticated && !loggingIn) return '/login';
      if (auth.isAuthenticated && loggingIn) return '/journal';
      return null;
    },
  );
});
