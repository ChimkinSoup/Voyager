import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/shell/shell_keyboard_shortcuts.dart';
import 'package:voyager/features/shell/shortcuts_help_dialog.dart';

// Same stand-in as shell_navigation_rail_test.dart: a real
// StatefulNavigationShell needs a live GoRouter, which this test doesn't.
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

class _StartingSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

Future<void> _pressCtrlSlash(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.slash);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

void main() {
  test('lists the user-configured bindings', () {
    const settings = AppSettings(
      calendarNavigateLeftKey: 'A',
      calendarNavigateRightKey: 'D',
      srsGoodKey: 'Q',
      todoHotkey: '',
    );
    final entries = [
      for (final section in shortcutHelpSections(settings)) ...section.entries,
    ];

    expect(entries.any((e) => e.keys == '← / →, A / D'), isTrue);
    expect(
      entries.any((e) => e.keys == 'Q' && e.action == 'Grade: good'),
      isTrue,
    );
    expect(entries.any((e) => e.action == 'Quick to-do'), isFalse);
  });

  testWidgets('Ctrl+/ closes the open dialog', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showShortcutsHelpDialog(context, const AppSettings()),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsNothing);
  });

  // Closing the list hands focus back to the field it was opened from, and a
  // one-line field on desktop selects all of its text when it regains focus,
  // so the next keystroke used to replace the draft (BUG-069).
  testWidgets(
    'closing the list leaves the caret where it was in the field',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final controller = TextEditingController(text: 'draft text');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      late BuildContext fieldContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                fieldContext = context;
                return TextField(controller: controller, focusNode: focusNode);
              },
            ),
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 10);
      await tester.pump();

      unawaited(showShortcutsHelpDialog(fieldContext, const AppSettings()));
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsOneWidget);
      expect(focusNode.hasFocus, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsNothing);

      expect(focusNode.hasFocus, isTrue);
      expect(controller.selection, const TextSelection.collapsed(offset: 10));
    },
  );

  testWidgets(
    'Ctrl+/ shows a keybind saved after startup',
    (tester) async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);

      // Wired the way AppShell wires it: the watched settings go straight into
      // ShellKeyboardShortcuts. AppShell itself isn't mounted — closing any
      // dialog over it in a desktop-variant test hangs the tester.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authRepositoryProvider.overrideWithValue(InMemoryAuthRepository()),
            syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
            settingsProvider.overrideWith(_StartingSettings.new),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => ShellKeyboardShortcuts(
                navigationShell: _FakeNavigationShell(),
                orderedDestinations: const [],
                settings:
                    ref.watch(settingsProvider).value ?? const AppSettings(),
                child: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ShellKeyboardShortcuts)),
      );

      await _pressCtrlSlash(tester);
      await tester.pumpAndSettle();
      expect(find.text('← / →, H / L'), findsOneWidget);

      await _pressCtrlSlash(tester);
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsNothing);

      // The same call the Settings page makes when a keybind is rebound.
      final current = container.read(settingsProvider).requireValue;
      await tester.runAsync(
        () => container
            .read(settingsProvider.notifier)
            .saveSettings(
              current.copyWith(
                calendarNavigateLeftKey: 'A',
                calendarNavigateRightKey: 'D',
              ),
            ),
      );
      await tester.pumpAndSettle();

      await _pressCtrlSlash(tester);
      await tester.pumpAndSettle();
      expect(find.text('← / →, A / D'), findsOneWidget);
      expect(find.text('← / →, H / L'), findsNothing);
    },
    // Tests default to Android, where the shell shortcuts are off.
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
