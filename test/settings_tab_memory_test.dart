import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/settings/settings_page.dart';
import 'package:voyager/features/settings/settings_tab_memory.dart';

class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<AppSettings> getSettings() async => const AppSettings();

  @override
  Future<Map<String, int>> getTagColors() async => const {};

  @override
  Future<void> saveSettings(
    AppSettings settings, {
    bool recordLocalActivity = true,
  }) async {}

  @override
  noSuchMethod(Invocation invocation) => null;
}

Future<void> pumpSettings(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        journalsProvider.overrideWith((ref) async => []),
        todoListStatsProvider.overrideWith((ref) async => {}),
        authRepositoryProvider.overrideWithValue(InMemoryAuthRepository()),
      ],
      child: const MaterialApp(home: Scaffold(body: SettingsPage())),
    ),
  );
  await tester.pump();
  await tester.pump();
}

int selectedTab(WidgetTester tester) =>
    tester.widget<TabBar>(find.byType(TabBar)).controller!.index;

void main() {
  setUp(() => SettingsTabMemory.lastTab = null);

  // Semantics off for the same reason as dark_theme_parity_test: Settings
  // mounted outside the shell hands semantics a non-finite rect.
  testWidgets(
    'Settings reopens on the tab it was left on',
    semanticsEnabled: false,
    (tester) async {
      await pumpSettings(tester);
      expect(selectedTab(tester), 0);

      await tester.tap(find.widgetWithText(Tab, 'Data'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(SettingsTabMemory.lastTab, 'Data');

      // A fresh Settings — as after a restart — starts where that one ended.
      await tester.pumpWidget(const SizedBox());
      await pumpSettings(tester);
      expect(
        tester.widget<Tab>(find.byType(Tab).at(selectedTab(tester))).text,
        'Data',
      );
    },
  );

  testWidgets(
    'a remembered tab that no longer exists opens the first',
    semanticsEnabled: false,
    (tester) async {
      SettingsTabMemory.lastTab = 'Gone';
      await pumpSettings(tester);
      expect(selectedTab(tester), 0);
    },
  );
}
