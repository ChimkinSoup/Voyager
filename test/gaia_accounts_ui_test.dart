import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_pinned_prompt.dart';
import 'package:voyager/features/gaia/companion/gaia_steady_list.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';

import 'fakes/gaia_fakes.dart';

class _Source implements GaiaUsageSource {
  @override
  Future<GaiaUsageRead> read({
    required GaiaRunAuth runs,
    required GaiaAccount account,
  }) async => GaiaUsageRead(
    GaiaUsageHealth.ok,
    usage: GaiaUsage([
      GaiaUsageWindow(
        kind: GaiaUsageKind.session,
        used: 0.25,
        resetsAt: DateTime.now().add(const Duration(hours: 2)),
        observedAt: DateTime.now(),
      ),
    ]),
  );
}

/// The composer's rings and account picker, and the divider where a chat moved
/// to another account (GAIA_HLD.md §6.2, §6.5).
void main() {
  const a = GaiaAccount(
    id: kGaiaDefaultAccountId,
    label: 'Alpha',
    adapter: kGaiaClaudeCodeAdapter,
    dir: r'C:\a',
  );
  const b = GaiaAccount(
    id: 'b',
    label: 'Beta',
    adapter: kGaiaClaudeCodeAdapter,
    dir: r'C:\b',
  );
  final at = DateTime.utc(2026, 11, 1);

  GaiaMessage reply(int seq, String? account, {String? text}) => GaiaMessage(
    id: 'm$seq',
    chatId: 'c1',
    seq: seq,
    role: GaiaMessageRole.assistant,
    parts: [GaiaTextPart(text ?? 'Reply $seq')],
    status: GaiaMessageStatus.complete,
    createdAt: at,
    updatedAt: at,
    adapter: kGaiaClaudeCodeAdapter,
    account: account,
  );

  GaiaMessage asked(int seq, String text) => GaiaMessage(
    id: 'm$seq',
    chatId: 'c1',
    seq: seq,
    role: GaiaMessageRole.user,
    parts: [GaiaTextPart(text)],
    status: GaiaMessageStatus.complete,
    createdAt: at,
    updatedAt: at,
  );

  Future<GaiaController> pump(
    WidgetTester tester, {
    required List<GaiaAccount> accounts,
    required List<GaiaMessage> messages,
    List<Map<String, Object?>>? switches,
    FakeClaudeRunner? runner,
  }) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        if (method == 'setCurrentAccount') switches?.add(params);
        return switch (method) {
          'hello' => {
            'aborted': false,
            'accent': 0xFF7C9EFF,
            'deviceId': 'laptop',
            'settings': {
              ...GaiaSettings.initial().toJson(),
              'accounts': [for (final account in accounts) account.toJson()],
            },
          },
          'chats' => [
            GaiaChat(
              id: 'c1',
              title: 'The chat',
              createdAt: at,
              updatedAt: at,
              lastMessageAt: at,
              tier: GaiaTier.standard,
            ).toJson(),
          ],
          'messages' => [for (final message in messages) message.toJson()],
          'drafts' => <Object?>[],
          _ => null,
        };
      };
    await main.startCompanion();
    final controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: runner ?? FakeClaudeRunner()},
      cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
      usageSources: {kGaiaClaudeCodeAdapter: _Source()},
      exit: (_) {},
    );
    await tester.runAsync(() async {
      await controller.start();
      await controller.openWindow();
      await controller.selectChat('c1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    return controller;
  }

  Finder notch(String label) => find.textContaining(label, findRichText: true);

  Finder rings() => find.byWidgetPredicate(
    (widget) => widget.runtimeType.toString() == '_UsageRing',
  );

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('one account: one full ring, no picker, no divider', (
    tester,
  ) async {
    await pump(tester, accounts: const [], messages: [reply(1, null)]);
    expect(rings(), findsOneWidget);
    expect(
      find.descendant(of: rings(), matching: find.byType(Opacity)),
      findsNothing,
    );
    expect(find.text('Default'), findsNothing);
    await finish(tester);
  });

  testWidgets('two accounts: the other ring is dulled; the picker switches', (
    tester,
  ) async {
    final switches = <Map<String, Object?>>[];
    final controller = await pump(
      tester,
      accounts: const [a, b],
      messages: [reply(1, null)],
      switches: switches,
    );
    expect(rings(), findsNWidgets(2));
    Iterable<bool> dulled() => tester
        .widgetList<Widget>(rings())
        .map((ring) => (ring as dynamic).dull as bool);
    expect(dulled(), [false, true]);

    await tester.tap(notch('Alpha').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(notch('Beta').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // The chat has a reply, so it asks first, naming what else moves.
    expect(find.text('Switch from Alpha to Beta?'), findsOneWidget);
    expect(find.textContaining('Your other chats on Alpha'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentAccount(kGaiaClaudeCodeAdapter), a);

    await tester.tap(notch('Alpha').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(notch('Beta').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Switch'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentAccount(kGaiaClaudeCodeAdapter), b);
    expect(switches.single, {
      'adapter': kGaiaClaudeCodeAdapter,
      'account': 'b',
    });
    expect(dulled(), [true, false]);
    await finish(tester);
  });

  testWidgets('clicking another ring switches as the picker does', (
    tester,
  ) async {
    final switches = <Map<String, Object?>>[];
    final controller = await pump(
      tester,
      accounts: const [a, b],
      messages: [reply(1, null)],
      switches: switches,
    );
    // The current account's does nothing.
    await tester.tap(rings().first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Switch from'), findsNothing);

    // The chat has a reply, so it asks first.
    await tester.tap(rings().last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Switch from Alpha to Beta?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentAccount(kGaiaClaudeCodeAdapter), a);
    expect(switches, isEmpty);

    await tester.tap(rings().last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Switch'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentAccount(kGaiaClaudeCodeAdapter), b);
    expect(switches.single, {
      'adapter': kGaiaClaudeCodeAdapter,
      'account': 'b',
    });
    await finish(tester);
  });

  group('an alias typed in the composer', () {
    const aliased = GaiaAccount(
      id: 'b',
      label: 'Beta',
      adapter: kGaiaClaudeCodeAdapter,
      dir: r'C:',
      alias: 'second',
    );

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    String draft(WidgetTester tester) =>
        tester.widget<EditableText>(find.byType(EditableText)).controller.text;

    testWidgets('asks first once the chat has a reply, as the rings do', (
      tester,
    ) async {
      final switches = <Map<String, Object?>>[];
      final controller = await pump(
        tester,
        accounts: const [a, aliased],
        messages: [reply(1, null)],
        switches: switches,
      );
      await tester.enterText(find.byType(EditableText), '/second');
      await settle(tester);
      expect(notch('Switch to Beta'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.text('Switch from Alpha to Beta?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(controller.currentAccount(kGaiaClaudeCodeAdapter), a);
      expect(switches, isEmpty);

      await tester.enterText(find.byType(EditableText), '/second');
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      await tester.tap(find.text('Switch'));
      await settle(tester);
      expect(controller.currentAccount(kGaiaClaudeCodeAdapter), aliased);
      expect(switches.single, {
        'adapter': kGaiaClaudeCodeAdapter,
        'account': 'b',
      });
      expect(draft(tester), isEmpty);
      await finish(tester);
    });

    testWidgets('inline, it comes out and leaves the rest of the draft', (
      tester,
    ) async {
      final controller = await pump(
        tester,
        accounts: const [a, aliased],
        messages: const [],
      );
      await tester.enterText(find.byType(EditableText), '/second hello');
      await settle(tester);
      // No reply here, so nothing's cache to lose, but it might be a path.
      expect(find.text('Switch from Alpha to Beta?'), findsOneWidget);
      expect(find.textContaining('prompt cache'), findsNothing);
      await tester.tap(find.text('Switch'));
      await settle(tester);
      expect(controller.currentAccount(kGaiaClaudeCodeAdapter), aliased);
      expect(draft(tester), 'hello');
      await finish(tester);
    });

    testWidgets('picked from the palette at the end, the space before stays', (
      tester,
    ) async {
      final controller = await pump(
        tester,
        accounts: const [a, aliased],
        messages: const [],
      );
      await tester.enterText(find.byType(EditableText), 'hello /second');
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(controller.currentAccount(kGaiaClaudeCodeAdapter), aliased);
      expect(draft(tester), 'hello ');
      await finish(tester);
    });

    testWidgets('turned down, the word stays and is not asked about again', (
      tester,
    ) async {
      final controller = await pump(
        tester,
        accounts: const [a, aliased],
        messages: const [],
      );
      const text = 'look in /second for the logs';
      await tester.enterText(find.byType(EditableText), text);
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(draft(tester), text);
      expect(controller.currentAccount(kGaiaClaudeCodeAdapter), a);

      await tester.enterText(find.byType(EditableText), '$text now');
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);

      // Gone from the draft, it's a new question next time.
      await tester.enterText(find.byType(EditableText), 'other');
      await settle(tester);
      await tester.enterText(find.byType(EditableText), '/second ');
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      await finish(tester);
    });

    testWidgets("the current account's alias stays as written", (tester) async {
      const current = GaiaAccount(
        id: kGaiaDefaultAccountId,
        label: 'Alpha',
        adapter: kGaiaClaudeCodeAdapter,
        dir: r'C:\a',
        alias: 'here',
      );
      await pump(
        tester,
        accounts: const [current, aliased],
        messages: const [],
      );
      await tester.enterText(find.byType(EditableText), 'look in /here now');
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(draft(tester), 'look in /here now');
      await finish(tester);
    });

    testWidgets("another adapter's: it says this chat's message stays put", (
      tester,
    ) async {
      const other = GaiaAccount(
        id: 'alt',
        label: 'Alt',
        adapter: kGaiaCodexAdapter,
        dir: r'C:\alt',
        alias: 'alt',
      );
      final controller = await pump(
        tester,
        accounts: const [
          a,
          GaiaAccount(
            id: kGaiaDefaultAccountId,
            label: 'Main',
            adapter: kGaiaCodexAdapter,
            dir: r'C:\main',
          ),
          other,
        ],
        messages: [reply(1, null)],
      );
      expect(
        controller.agentFor(controller.nextTier)?.adapter,
        kGaiaClaudeCodeAdapter,
      );
      await tester.enterText(find.byType(EditableText), '/alt hello');
      await settle(tester);
      expect(find.textContaining('Switch Codex from'), findsOneWidget);
      expect(
        find.textContaining("next message stays on Claude Code"),
        findsOneWidget,
      );
      expect(find.textContaining('prompt cache'), findsNothing);
      await tester.tap(find.text('Switch'));
      await settle(tester);
      expect(controller.currentAccount(kGaiaCodexAdapter), other);
      expect(controller.currentAccount(kGaiaClaudeCodeAdapter), a);
      await finish(tester);
    });

    testWidgets('a tier and an alias together ask one at a time', (
      tester,
    ) async {
      final controller = await pump(
        tester,
        accounts: const [a, aliased],
        messages: [reply(1, null)],
      );
      await tester.enterText(find.byType(EditableText), '/deep /second ');
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('to Deep'), findsOneWidget);
      await tester.tap(find.text('Switch'));
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Switch from Alpha to Beta?'), findsOneWidget);
      await tester.tap(find.text('Switch'));
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.nextTier, GaiaTier.deep);
      expect(controller.currentAccount(kGaiaClaudeCodeAdapter), aliased);
      expect(draft(tester), isEmpty);
      await finish(tester);
    });

    testWidgets('several in one draft all come out', (tester) async {
      const third = GaiaAccount(
        id: 'c',
        label: 'Gamma',
        adapter: kGaiaClaudeCodeAdapter,
        dir: r'C:\c',
        alias: 'third',
      );
      final controller = await pump(
        tester,
        accounts: const [a, aliased, third],
        messages: const [],
      );
      await tester.enterText(find.byType(EditableText), '/second /third hello');
      await settle(tester);
      expect(find.text('Switch from Alpha to Beta?'), findsOneWidget);
      await tester.tap(find.text('Switch'));
      await settle(tester);
      expect(find.text('Switch from Beta to Gamma?'), findsOneWidget);
      await tester.tap(find.text('Switch'));
      await settle(tester);
      expect(draft(tester), 'hello');
      expect(controller.currentAccount(kGaiaClaudeCodeAdapter), third);
      await finish(tester);
    });

    testWidgets('mid-reply, send stops and the alias waits in the draft', (
      tester,
    ) async {
      final runner = FakeClaudeRunner()..turns.add(const []);
      final controller = await pump(
        tester,
        accounts: const [a, aliased],
        messages: [reply(1, null)],
        runner: runner,
      );
      unawaited(controller.send('Go'));
      await settle(tester);
      expect(controller.currentRunning, isTrue);
      const text = 'next try /second';
      // The composer's, after the reply's being written.
      await tester.enterText(find.byType(EditableText).last, text);
      // The caret away from the alias, so the palette doesn't take the key.
      controller.draft.selection = const TextSelection.collapsed(offset: 0);
      await settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(runner.stopped, isNotEmpty);
      expect(controller.currentAccount(kGaiaClaudeCodeAdapter), a);
      expect(controller.draft.text, text);
      await finish(tester);
    });
  });

  testWidgets('with nothing to lose, a ring switches without asking', (
    tester,
  ) async {
    final controller = await pump(
      tester,
      accounts: const [a, b],
      messages: const [],
    );
    await tester.tap(rings().last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Switch from'), findsNothing);
    expect(controller.currentAccount(kGaiaClaudeCodeAdapter), b);
    await finish(tester);
  });

  testWidgets('the divider comes before the prompt that moved the chat', (
    tester,
  ) async {
    await pump(
      tester,
      accounts: const [a, b],
      messages: [
        asked(0, 'First prompt'),
        reply(1, kGaiaDefaultAccountId),
        asked(2, 'Second prompt'),
        reply(3, 'b'),
        asked(4, 'Third prompt'),
        reply(5, 'b'),
      ],
    );
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(find.text('Switched to Beta'), findsOneWidget);
    expect(y('Reply 1'), lessThan(y('Switched to Beta')));
    expect(y('Switched to Beta'), lessThan(y('Second prompt')));
    expect(y('Second prompt'), lessThan(y('Reply 3')));
    await finish(tester);
  });

  testWidgets('jumping to a pinned prompt keeps its divider in view', (
    tester,
  ) async {
    await pump(
      tester,
      accounts: const [a, b],
      messages: [
        asked(0, 'First prompt'),
        reply(1, kGaiaDefaultAccountId),
        asked(2, 'Second prompt'),
        // Longer than the list, but not past what it builds off screen.
        reply(3, 'b', text: List.filled(16, 'A paragraph.').join('\n\n')),
      ],
    );
    final list = find.byType(GaiaSteadyList);
    // A scroll, for the list to see its prompt is cut off.
    await tester.drag(list, const Offset(0, 40));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(GaiaPinnedPrompt));
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      tester.getTopLeft(find.text('Switched to Beta')).dy,
      greaterThanOrEqualTo(tester.getTopLeft(list).dy),
    );
    await finish(tester);
  });

  testWidgets('the vendor divider comes before its prompt too', (tester) async {
    final codex = GaiaMessage(
      id: 'm3',
      chatId: 'c1',
      seq: 3,
      role: GaiaMessageRole.assistant,
      parts: const [GaiaTextPart('Reply 3')],
      status: GaiaMessageStatus.complete,
      createdAt: at,
      updatedAt: at,
      adapter: kGaiaCodexAdapter,
    );
    await pump(
      tester,
      accounts: const [a, b],
      messages: [
        asked(0, 'First prompt'),
        reply(1, kGaiaDefaultAccountId),
        asked(2, 'Second prompt'),
        codex,
      ],
    );
    final divider = find.textContaining('a transcript carried over');
    expect(divider, findsOneWidget);
    // Named for the reply's vendor, not the prompt's, which has none.
    expect(find.textContaining('Switched to Codex'), findsOneWidget);
    double y(Finder finder) => tester.getTopLeft(finder).dy;
    expect(y(find.text('Reply 1')), lessThan(y(divider)));
    expect(y(divider), lessThan(y(find.text('Second prompt'))));
    await finish(tester);
  });

  GaiaMessage codex(int seq, GaiaMessageStatus status, {bool output = true}) =>
      GaiaMessage(
        id: 'm$seq',
        chatId: 'c1',
        seq: seq,
        role: GaiaMessageRole.assistant,
        parts: [if (output) GaiaTextPart('Reply $seq')],
        status: status,
        createdAt: at,
        updatedAt: at,
        adapter: kGaiaCodexAdapter,
      );

  testWidgets('a reply failed before any output leaves the vendor divider '
      'to the next', (tester) async {
    await pump(
      tester,
      accounts: const [a, b],
      messages: [
        asked(0, 'First prompt'),
        reply(1, kGaiaDefaultAccountId),
        // A CLI command refused before the session caught up.
        asked(2, '/compact'),
        codex(3, GaiaMessageStatus.error, output: false),
        asked(4, 'Third prompt'),
        codex(5, GaiaMessageStatus.complete),
      ],
    );
    final divider = find.textContaining('a transcript carried over');
    expect(divider, findsOneWidget);
    double y(Finder finder) => tester.getTopLeft(finder).dy;
    expect(y(find.text('/compact')), lessThan(y(divider)));
    expect(y(divider), lessThan(y(find.text('Third prompt'))));
    await finish(tester);
  });

  testWidgets('a reply that streamed and then failed carries the divider', (
    tester,
  ) async {
    await pump(
      tester,
      accounts: const [a, b],
      messages: [
        asked(0, 'First prompt'),
        reply(1, kGaiaDefaultAccountId),
        asked(2, 'Second prompt'),
        codex(3, GaiaMessageStatus.error),
        asked(4, 'Third prompt'),
        codex(5, GaiaMessageStatus.complete),
      ],
    );
    final divider = find.textContaining('a transcript carried over');
    expect(divider, findsOneWidget);
    double y(Finder finder) => tester.getTopLeft(finder).dy;
    expect(y(find.text('Reply 1')), lessThan(y(divider)));
    expect(y(divider), lessThan(y(find.text('Second prompt'))));
    await finish(tester);
  });

  testWidgets('the divider arriving leaves the prompt as it is', (
    tester,
  ) async {
    final controller = await pump(
      tester,
      accounts: const [a, b],
      messages: [
        asked(0, 'First prompt'),
        reply(1, kGaiaDefaultAccountId),
        asked(2, 'Second prompt'),
      ],
    );
    final prompt = tester.element(find.text('Second prompt'));
    expect(find.text('Switched to Beta'), findsNothing);

    controller.messages.add(reply(3, 'b'));
    controller.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Switched to Beta'), findsOneWidget);
    expect(tester.element(find.text('Second prompt')), same(prompt));
    await finish(tester);
  });

  testWidgets('a divider marks where a chat moved account', (tester) async {
    await pump(
      tester,
      accounts: const [a, b],
      messages: [
        reply(1, null),
        reply(3, kGaiaDefaultAccountId),
        reply(5, 'b'),
        reply(7, 'b'),
      ],
    );
    expect(find.text('Switched to Beta'), findsOneWidget);
    expect(find.textContaining('a transcript carried over'), findsNothing);
    await finish(tester);
  });
}
