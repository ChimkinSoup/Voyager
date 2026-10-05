// A global hotkey another app holds does nothing in Voyager until that app
// lets go. Settings → Editing used to list it as if it worked (BUG-034); it
// now says so on that hotkey's row.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/hotkeys/hotkey_service.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';
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

const _notice = 'Another app is using this shortcut';

Future<void> pumpEditingTab(
  WidgetTester tester,
  Set<QuickCaptureKind> taken,
) async {
  SettingsTabMemory.lastTab = 'Editing';
  // Tall enough that the hotkey rows are built without scrolling.
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        journalsProvider.overrideWith((ref) async => []),
        todoListStatsProvider.overrideWith((ref) async => {}),
        authRepositoryProvider.overrideWithValue(InMemoryAuthRepository()),
        unavailableHotkeysProvider.overrideWith((ref) => taken),
      ],
      child: const MaterialApp(home: Scaffold(body: SettingsPage())),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Finder tileWith(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(ListTile));

void main() {
  tearDown(() => SettingsTabMemory.lastTab = null);

  testWidgets(
    'a hotkey another app holds shows a notice on its row (BUG-034)',
    semanticsEnabled: false,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await pumpEditingTab(tester, {QuickCaptureKind.reminder});
      expect(
        find.descendant(
          of: tileWith('Reminder hotkey'),
          matching: find.textContaining(_notice, findRichText: true),
        ),
        findsOneWidget,
      );
      expect(find.textContaining(_notice, findRichText: true), findsOneWidget);
    },
  );

  testWidgets(
    'no notice when every hotkey registered',
    semanticsEnabled: false,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await pumpEditingTab(tester, const {});
      expect(find.text('Reminder hotkey'), findsOneWidget);
      expect(find.textContaining(_notice, findRichText: true), findsNothing);
    },
  );
}
