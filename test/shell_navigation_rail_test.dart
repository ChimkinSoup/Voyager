import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/shell/app_shell.dart';
import 'package:voyager/features/shell/shell_destinations.dart';

class _FakeNavigationShell extends Fake implements StatefulNavigationShell {
  @override
  int get currentIndex => 0;

  @override
  void goBranch(int index, {bool initialLocation = false}) {}

  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) =>
      '_FakeNavigationShell';
}

void main() {
  testWidgets('AppShell navigation rail fits small window heights without overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final fakeShell = _FakeNavigationShell();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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

    await tester.pumpAndSettle();

    // Verify no rendering overflow assertion was thrown
    expect(tester.takeException(), isNull);
  });
}
