// BUG-212: the calendar's previous and next period keys can't share a letter;
// picking the other direction's letter swaps the two.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/settings/settings_page.dart';

class _RecordingSettingsRepository implements SettingsRepository {
  final saved = <AppSettings>[];

  @override
  Future<AppSettings> getSettings() async =>
      saved.isEmpty ? const AppSettings() : saved.last;

  @override
  Future<Map<String, int>> getTagColors() async => const {};

  @override
  Future<void> saveSettings(
    AppSettings settings, {
    bool recordLocalActivity = true,
  }) async => saved.add(settings);

  @override
  noSuchMethod(Invocation invocation) => null;
}

void main() {
  Future<_RecordingSettingsRepository> openEditing(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final repo = _RecordingSettingsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repo),
          journalsProvider.overrideWith((ref) async => []),
          todoListStatsProvider.overrideWith((ref) async => {}),
          authRepositoryProvider.overrideWithValue(InMemoryAuthRepository()),
        ],
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.widgetWithText(Tab, 'Editing'));
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets(
    'BUG-212: the next key taking the previous key\'s letter swaps them',
    semanticsEnabled: false,
    (tester) async {
      final repo = await openEditing(tester);
      await tester.tap(find.text('Calendar: next period'));
      await tester.pumpAndSettle();
      // H is previous period's.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pumpAndSettle();

      final saved = repo.saved.last;
      expect(saved.calendarNavigateRightKey, 'H');
      expect(saved.calendarNavigateLeftKey, 'L');
      expect(
        find.text('Previous period moved to L, since next period took H'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'BUG-212: a free letter leaves the other direction alone',
    semanticsEnabled: false,
    (tester) async {
      final repo = await openEditing(tester);
      await tester.tap(find.text('Calendar: previous period'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pumpAndSettle();

      final saved = repo.saved.last;
      expect(saved.calendarNavigateLeftKey, 'B');
      expect(saved.calendarNavigateRightKey, 'L');
      expect(find.textContaining('moved to'), findsNothing);
    },
  );
}
