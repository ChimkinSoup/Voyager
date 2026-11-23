import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';

import 'fakes/gaia_fakes.dart';

/// The settings panel's Setup and Settings tabs and the header's inbox
/// alert (GAIA_SETTINGS_HLD.md Phase 2): each setting is saved with
/// `putSettings` and shows what the `settings` event brings back; the
/// inbox chip follows the `inbox` count against the threshold.
void main() {
  final at = DateTime.utc(2026, 11, 22);

  late List<(String, Map<String, Object?>)> requests;
  late GaiaSettings stored;
  late FakeGaiaPipe main;
  late int inbox;

  List<Map<String, Object?>> saves() => [
    for (final (method, params) in requests)
      if (method == 'putSettings')
        (params['changes']! as Map).cast<String, Object?>(),
  ];

  Future<GaiaController> pump(
    WidgetTester tester, {
    GaiaPanelTab? tab,
    Future<GaiaAccountCheck> Function(GaiaAccount account)? checkAccount,
  }) async {
    tester.view.physicalSize = const Size(1100, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    requests = [];
    stored = GaiaSettings.initial();
    late FakeGaiaPipe companion;
    main = FakeGaiaPipe.main()
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        requests.add((method, params));
        switch (method) {
          case 'hello':
            return {
              'aborted': false,
              'accent': 0xFF7C9EFF,
              'deviceId': 'laptop',
              'settings': stored.toJson(),
              'inbox': inbox,
            };
          case 'chats':
            return [
              GaiaChat(
                id: 'c1',
                title: 'Parser',
                createdAt: at,
                updatedAt: at,
                lastMessageAt: at,
              ).toJson(),
            ];
          case 'messages':
          case 'drafts':
          case 'btws':
          case 'queue':
            return <Object?>[];
          case 'putSettings':
            // As the host does: saved, then pushed back as the event.
            stored = stored.patched(
              (params['changes']! as Map).cast<String, Object?>(),
            );
            main.notify('settings', stored.toJson());
            return null;
          case 'voyagerHotkeys':
            return {'Quick note': 'Ctrl+Alt+N'};
        }
        return null;
      };
    await main.startCompanion();
    final controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: FakeClaudeRunner()},
      cliVersions: {
        kGaiaClaudeCodeAdapter: () async => (2, 1, 310),
        kGaiaCodexAdapter: () async => null,
      },
      checkAccount:
          checkAccount ??
          (account) async =>
              (loggedIn: true, email: 'juno@example.com', sandboxReady: null),
      exit: (_) {},
      panel: GaiaSettingsPanel(),
    );
    await tester.runAsync(() async {
      await controller.start();
      await controller.openWindow();
      await controller.selectChat('c1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    if (tab != null) {
      await tester.runAsync(() => controller.openPanel(tab: tab));
      await settle(tester);
    }
    return controller;
  }

  setUp(() => inbox = 0);

  /// Taps [finder], then lets the pipe's answers and their frames in.
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await settle(tester);
  }

  /// The panel's text box whose hint is [hint].
  Finder field(String hint) => find.descendant(
    of: find.byWidgetPredicate(
      (widget) => widget is GaiaTextField && widget.hintText == hint,
    ),
    matching: find.byType(TextField),
  );

  group('Settings', () {
    _testWidgets('a switch saves its one field, and shows what comes back', (
      tester,
    ) async {
      final controller = await pump(tester, tab: GaiaPanelTab.settings);
      expect(find.text('Notify when a run finishes'), findsOneWidget);
      Switch notify() => tester.widget<Switch>(
        find.descendant(
          of: find.ancestor(
            of: find.text('Notify when a run finishes'),
            matching: find.byType(GaiaPanelSwitch),
          ),
          matching: find.byType(Switch),
        ),
      );
      expect(notify().value, isTrue);

      await tap(tester, find.text('Notify when a run finishes'));
      expect(saves(), [
        {'notifyOnDone': false},
      ]);
      expect(controller.settings['notifyOnDone'], isFalse);
      expect(notify().value, isFalse);
    });

    _testWidgets('a text saves with Save or Enter, trimmed; one changed '
        'elsewhere shows while nothing here is unsaved', (tester) async {
      await pump(tester, tab: GaiaPanelTab.settings);
      final name = find.descendant(
        of: find.byKey(const ValueKey('userName')),
        matching: find.byType(TextField),
      );
      await tester.enterText(name, '  Juno ');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(saves(), [
        {'userName': 'Juno'},
      ]);
      expect(tester.widget<TextField>(name).controller!.text, 'Juno');

      // From the page or another device.
      main.notify(
        'settings',
        stored.copyWith(gaiaMd: 'Keep it short.').toJson(),
      );
      await settle(tester);
      final gaiaMd = field(
        'e.g. Keep answers short. I use Windows and Flutter.',
      );
      expect(
        tester.widget<TextField>(gaiaMd).controller!.text,
        'Keep it short.',
      );

      // Being edited, it isn't overwritten.
      await tester.enterText(gaiaMd, 'Mine');
      main.notify('settings', stored.copyWith(gaiaMd: 'Theirs').toJson());
      await settle(tester);
      expect(tester.widget<TextField>(gaiaMd).controller!.text, 'Mine');
      await tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('gaiaMd')),
          matching: find.text('Save'),
        ),
      );
      expect(saves().last, {'gaiaMd': 'Mine'});
    });

    _testWidgets("a tier's agent is picked from a menu", (tester) async {
      await pump(tester, tab: GaiaPanelTab.settings);
      await tap(tester, find.byKey(const ValueKey('tier deep')));
      expect(find.byType(GaiaMenu), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(
        find.descendant(
          of: find.byType(GaiaMenu),
          matching: find.textContaining('Haiku 5.5', findRichText: true),
        ),
      );
      await settle(tester);
      expect(saves().single['tiers'], {
        'quick': 'haiku',
        'standard': 'sonnet',
        'deep': 'haiku',
      });
      expect(stored.agentFor(GaiaTier.deep)?.id, 'haiku');
    });

    _testWidgets('an agent is added in place, and one a tier uses can\'t be '
        'removed', (tester) async {
      await pump(tester, tab: GaiaPanelTab.settings);
      await tap(tester, find.text('Add agent'));
      await tap(tester, find.text('Codex'));
      // A pill is as wide as its label, not the editor (seen live).
      expect(
        tester.getSize(find.byType(GaiaPanelChoice).first).width,
        lessThan(200),
      );
      await tap(tester, find.text('gpt-6.1-sol'));
      await tap(tester, find.text('ultra'));
      await tester.enterText(field('e.g. GPT-6.1 Sol'), 'Sol');
      await tester.pump();
      await tap(tester, find.text('Add'));
      final agents = gaiaAgentsFromJson(saves().single['agents']);
      expect(agents, hasLength(4));
      expect(agents.last.label, 'Sol');
      expect(agents.last.adapter, kGaiaCodexAdapter);
      expect(agents.last.model, 'gpt-6.1-sol');
      expect(agents.last.effort, 'ultra');
      expect(find.text('Sol'), findsOneWidget);

      // The new one, which no tier uses, goes; one a tier uses can't.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer();
      Future<void> remove(String id) async {
        final row = find.byKey(ValueKey('agent $id'));
        await tester.ensureVisible(row);
        await tester.pump();
        await gesture.moveTo(tester.getCenter(row));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(
          find.descendant(of: row, matching: find.byIcon(Icons.delete_outline)),
        );
        await settle(tester);
      }

      await remove('haiku');
      expect(saves(), hasLength(1));
      await remove(agents.last.id);
      expect(gaiaAgentsFromJson(saves().last['agents']), hasLength(3));
      await gesture.removePointer();
    });

    _testWidgets("a command's name is checked, then it's saved and opens "
        'again to edit', (tester) async {
      await pump(tester, tab: GaiaPanelTab.settings);
      await tap(tester, find.text('Add command'));
      await tester.enterText(field('Name'), 'new');
      await tester.enterText(
        field(r'Template, e.g. Explain this in plain words: $ARGUMENTS'),
        r'Explain: $ARGUMENTS',
      );
      await settle(tester);
      expect(find.text('Already a command'), findsOneWidget);
      await tester.enterText(field('Name'), 'bad name');
      await settle(tester);
      expect(find.text('Letters, digits, - and _ only'), findsOneWidget);
      await tester.enterText(field('Name'), 'explain');
      await settle(tester);
      await tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('new command')),
          matching: find.text('Save'),
        ),
      );
      expect(
        gaiaCommandsFromJson(saves().single['commands']).single.name,
        'explain',
      );
      expect(find.text('/explain'), findsOneWidget);

      await tap(tester, find.text('/explain'));
      expect(
        tester.widget<TextField>(field('Name')).controller!.text,
        'explain',
      );
    });

    _testWidgets("a key takes the combo pressed, unless Gaia or Voyager "
        'already has it', (tester) async {
      await pump(tester, tab: GaiaPanelTab.settings);
      Future<void> change(String key) async => tap(
        tester,
        find.descendant(
          of: find.byKey(ValueKey('key $key')),
          matching: find.text('Change'),
        ),
      );
      Future<void> press(
        List<LogicalKeyboardKey> held,
        LogicalKeyboardKey key,
      ) async {
        for (final modifier in held) {
          await tester.sendKeyDownEvent(modifier);
        }
        await tester.sendKeyEvent(key);
        for (final modifier in held.reversed) {
          await tester.sendKeyUpEvent(modifier);
        }
        // Voyager's hotkeys are asked for over the pipe, then the save.
        await settle(tester);
        await settle(tester);
      }

      const ctrlAlt = [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
      ];
      // Voyager's quick note.
      await change('window');
      await press(ctrlAlt, LogicalKeyboardKey.keyN);
      expect(find.text('Ctrl+Alt+N is already Quick note.'), findsOneWidget);
      // Gaia's own region screenshot.
      await change('window');
      await press(ctrlAlt, LogicalKeyboardKey.keyS);
      expect(
        find.text('Ctrl+Alt+S is already Screenshot a region.'),
        findsOneWidget,
      );
      // No modifier: refused in the overlay, which waits on.
      await change('window');
      await press(const [], LogicalKeyboardKey.keyK);
      expect(find.text('K needs Ctrl, Alt or Win with it.'), findsOneWidget);
      await press(ctrlAlt, LogicalKeyboardKey.keyK);
      expect(saves(), [
        {
          'keybinds': {'window': 'Ctrl+Alt+K'},
        },
      ]);
      expect(find.text('Ctrl+Alt+K'), findsOneWidget);

      await tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('key window')),
          matching: find.byIcon(Icons.restart_alt),
        ),
      );
      expect(saves().last, {'keybinds': <String, String>{}});
    });

    _testWidgets('the inbox alert takes a number of at least 1', (
      tester,
    ) async {
      await pump(tester, tab: GaiaPanelTab.settings);
      final alert = find.descendant(
        of: find.byKey(const ValueKey('memoryAlertAt')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(alert).controller!.text, '100');
      await tester.enterText(alert, '0');
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(saves(), isEmpty);
      await tester.enterText(alert, '3a');
      await settle(tester);
      expect(tester.widget<TextField>(alert).controller!.text, '3');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(saves(), [
        {'memoryAlertAt': 3},
      ]);
      expect(stored.memoryAlertAt, 3);
    });
  });

  group('Setup', () {
    _testWidgets("each CLI's checks, and each account's login, run here", (
      tester,
    ) async {
      final checked = <String>[];
      await pump(
        tester,
        tab: GaiaPanelTab.setup,
        checkAccount: (account) async {
          checked.add(account.adapter);
          return (
            loggedIn: true,
            email: 'juno@example.com',
            sandboxReady: null,
          );
        },
      );
      expect(find.text('Installed: 2.1.310'), findsOneWidget);
      expect(find.text('Logged in as juno@example.com'), findsOneWidget);
      // Codex isn't installed: its command, and no accounts to check.
      expect(find.text('npm install -g @openai/codex'), findsOneWidget);
      expect(checked, [kGaiaClaudeCodeAdapter]);

      await tap(tester, find.text('Check again').first);
      expect(checked, [kGaiaClaudeCodeAdapter, kGaiaClaudeCodeAdapter]);
    });

    _testWidgets('an account not logged in says how to log in', (tester) async {
      await pump(
        tester,
        tab: GaiaPanelTab.setup,
        checkAccount: (account) async =>
            (loggedIn: false, email: null, sandboxReady: null),
      );
      expect(find.text('Not logged in'), findsOneWidget);
      expect(find.text('claude auth login'), findsOneWidget);
    });

    _testWidgets('an account is added, renamed and given an alias', (
      tester,
    ) async {
      final controller = await pump(tester, tab: GaiaPanelTab.setup);
      await tester.enterText(field('New account'), 'Work');
      await tester.enterText(
        field(r'Folder, e.g. C:\Users\you\.claude-2'),
        r'"C:\Users\juno\.claude-2"',
      );
      await settle(tester);
      await tap(tester, find.text('Add account').first);
      final added = gaiaAccountsFromJson(saves().single['accounts']);
      expect(
        [for (final account in added) account.dir],
        ['', r'C:\Users\juno\.claude-2'],
      );
      expect(controller.accountsFor(kGaiaClaudeCodeAdapter), hasLength(2));
      // Its login is checked as it appears (seen missing live).
      expect(find.text('Logged in as juno@example.com'), findsNWidgets(2));

      final work = added.last;
      await tester.enterText(
        find
            .descendant(
              of: find.byKey(ValueKey(work.id)),
              matching: find.byType(TextField),
            )
            .at(1),
        'stop',
      );
      await settle(tester);
      expect(find.text('Already a command'), findsOneWidget);
      await tester.enterText(
        find
            .descendant(
              of: find.byKey(ValueKey(work.id)),
              matching: find.byType(TextField),
            )
            .at(1),
        'work',
      );
      await settle(tester);
      await tap(
        tester,
        find.descendant(
          of: find.byKey(ValueKey(work.id)),
          matching: find.text('Save'),
        ),
      );
      expect(gaiaAccountsFromJson(saves().last['accounts']).last.alias, 'work');
    });
  });

  group('the inbox alert', () {
    Finder chip(String text) => find.text(text);

    _testWidgets('shows from the threshold with the live count, and goes '
        'below it', (tester) async {
      inbox = 2;
      final controller = await pump(tester);
      main.notify(
        'settings',
        GaiaSettings.initial().copyWith(memoryAlertAt: 3).toJson(),
      );
      await settle(tester);
      expect(controller.inboxCount, 2);
      expect(find.textContaining('to review'), findsNothing);

      main.notify('inbox', {'count': 3});
      await settle(tester);
      expect(chip('3 memories to review'), findsOneWidget);

      main.notify('inbox', {'count': 4});
      await settle(tester);
      expect(chip('4 memories to review'), findsOneWidget);

      main.notify('inbox', {'count': 2});
      await settle(tester);
      expect(find.textContaining('to review'), findsNothing);

      // Over the panel too, and in a floater: the header is shared.
      main.notify('inbox', {'count': 5});
      await tester.runAsync(() => controller.openPanel());
      await settle(tester);
      expect(chip('5 memories to review'), findsOneWidget);
      await tester.runAsync(() => controller.onHotkey('small'));
      await settle(tester);
      expect(chip('5 memories to review'), findsOneWidget);
    });

    _testWidgets('one waiting reads as one memory', (tester) async {
      inbox = 1;
      await pump(tester);
      main.notify(
        'settings',
        GaiaSettings.initial().copyWith(memoryAlertAt: 1).toJson(),
      );
      await settle(tester);
      expect(chip('1 memory to review'), findsOneWidget);
    });
  });
}

/// [testWidgets], then the toasts' and tooltips' timers run out, which a
/// busy machine can leave pending at the end.
void _testWidgets(String description, WidgetTesterCallback body) =>
    testWidgets(description, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 10));
    });

/// Lets the pipe's answers in, then the frames they cause.
Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump(const Duration(milliseconds: 300));
}
