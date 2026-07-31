import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/shell/app_shell.dart';
import 'package:voyager/features/shell/shell_destinations.dart';
import 'fakes/fake_weather_api_client.dart';

// A real StatefulNavigationShell requires a live GoRouter/ShellRouteContext,
// which is too heavy to construct for a layout-only test. `implements`
// (rather than `extends`) lets this stand-in satisfy the type without that
// machinery — but AppShell renders it as real widget content (it's passed
// straight through to `_ShellBranchChangeFlusher`'s child), so it still
// needs working `key`/`createElement`/`createState` to actually mount.
class _FakeNavigationShell extends Fake implements StatefulNavigationShell {
  @override
  Key? get key => null;

  @override
  int get currentIndex => 0;

  @override
  void goBranch(int index, {bool initialLocation = false}) {}

  @override
  StatefulElement createElement() => StatefulElement(this);

  @override
  State<StatefulNavigationShell> createState() => _FakeNavigationShellState();

  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) =>
      '_FakeNavigationShell';
}

class _FakeNavigationShellState extends State<StatefulNavigationShell> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  testWidgets('AppShell navigation rail fits small window heights without overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fakeShell = _FakeNavigationShell();

    // Isolate from the real on-disk voyager.sqlite and live Firebase
    // services (see AppDatabase.create() via databaseProvider) — matching
    // widget_test.dart's rationale: it both avoids leaking this test run
    // into real app data/services and avoids picking up real persisted
    // settings that may have the background wave/petal animation on, which
    // would make the animation's Timer reschedule forever inside
    // pumpAndSettle's fake-async loop (see also
    // test/tool/geometric_texture_widget_test.dart).
    final db = AppDatabase.inMemory();
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          authRepositoryProvider.overrideWithValue(InMemoryAuthRepository()),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
          settingsProvider.overrideWith(
            (ref) async => AppSettings(
              navPageOrder: shellDestinations.map((d) => d.path).toList(),
            ),
          ),
        ],
        child: MaterialApp(
          home: AppShell(
            child: fakeShell,
          ),
        ),
      ),
    );

    // The background animation ticker runs continuously by design, so
    // pumpAndSettle would hang — pump a bounded number of frames instead.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Verify no rendering overflow assertion was thrown
    expect(tester.takeException(), isNull);
  });
}
