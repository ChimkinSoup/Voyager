// Settings stays mounted behind every other page, and its Statistics counts
// move with every to-do tick. Watching them at the page level rebuilt the
// whole of Settings twice per tick while To-Do was in use; only the tiles
// that show the counts should rebuild.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/settings/settings_page.dart';

class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<AppSettings> getSettings() async => const AppSettings();

  @override
  Future<Map<String, int>> getTagColors() async => const {};

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

final _stats = StateProvider<Map<String, ({int active, int completed})>>(
  (ref) => {'list': (active: 3, completed: 1)},
);

void main() {
  // Semantics off: SettingsPage mounted outside the shell hands the semantics
  // pass a nested viewport with a non-finite rect (see
  // dark_theme_parity_test.dart).
  testWidgets(
    'a to-do change rebuilds the counts, not the page',
    semanticsEnabled: false,
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            _StubSettingsRepository(),
          ),
          settingsProvider.overrideWith(_Settings.new),
          journalsProvider.overrideWith((ref) async => []),
          todoListStatsProvider.overrideWith((ref) async => ref.watch(_stats)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: VoyagerTheme.dark(),
            home: const Scaffold(body: SettingsPage()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final open = find.ancestor(
        of: find.text('Non-completed tasks', skipOffstage: false),
        matching: find.byType(ListTile, skipOffstage: false),
      );
      expect(
        find.descendant(
          of: open,
          matching: find.text('3', skipOffstage: false),
          skipOffstage: false,
        ),
        findsOneWidget,
      );

      final rebuilt = <String>[];
      debugOnRebuildDirtyWidget = (element, _) =>
          rebuilt.add(element.widget.runtimeType.toString());
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      container.read(_stats.notifier).state = {
        'list': (active: 7, completed: 1),
      };
      await tester.pump();
      await tester.pump();

      expect(
        find.descendant(
          of: open,
          matching: find.text('7', skipOffstage: false),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(rebuilt, contains('_StatisticsTiles'));
      expect(rebuilt, isNot(contains('SettingsPage')));
    },
  );
}
