import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';

import 'fakes/gaia_fakes.dart';

class _Source implements GaiaUsageSource {
  _Source(this.used);

  /// Each account's five-hour share used, by id.
  final Map<String, double> used;

  @override
  Future<GaiaUsageRead> read({
    required GaiaRunAuth runs,
    required GaiaAccount account,
  }) async => GaiaUsageRead(
    GaiaUsageHealth.ok,
    usage: GaiaUsage([
      GaiaUsageWindow(
        kind: GaiaUsageKind.session,
        used: used[account.id] ?? 0.2,
        resetsAt: DateTime.now().add(const Duration(hours: 2)),
        observedAt: DateTime.now(),
      ),
    ]),
  );
}

class _SignedOutSource implements GaiaUsageSource {
  @override
  Future<GaiaUsageRead> read({
    required GaiaRunAuth runs,
    required GaiaAccount account,
  }) async => const GaiaUsageRead(GaiaUsageHealth.signedOut);
}

const _a = GaiaAccount(
  id: kGaiaDefaultAccountId,
  label: 'Alpha',
  adapter: kGaiaClaudeCodeAdapter,
  dir: r'C:\a',
);
const _b = GaiaAccount(
  id: 'b',
  label: 'Beta',
  adapter: kGaiaClaudeCodeAdapter,
  dir: r'C:\b',
);
const _sol = GaiaAgent(
  id: 'sol',
  label: 'Codex Sol',
  model: 'gpt-sol',
  adapter: kGaiaCodexAdapter,
);

/// The low banner and the exhausted decision card over the composer
/// (GAIA_HLD.md §6.5).
void main() {
  final at = DateTime.utc(2026, 11, 1);

  Future<(GaiaController, FakeClaudeRunner)> pump(
    WidgetTester tester, {
    required Map<String, double> used,
    List<GaiaAccount> accounts = const [_a, _b],
    bool codex = false,
    bool codexInstalled = true,
    bool codexSignedOut = false,
    List<GaiaMessage> messages = const [],
  }) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Asked of from the window buttons, heard when a test leaves fake time.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    final settings = GaiaSettings.initial();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async => switch (method) {
        'hello' => {
          'aborted': false,
          'accent': 0xFF7C9EFF,
          'deviceId': 'laptop',
          'settings': {
            ...settings.toJson(),
            'accounts': [for (final account in accounts) account.toJson()],
            if (codex) ...{
              'agents': [
                ...settings.agents.map((agent) => agent.toJson()),
                _sol.toJson(),
              ],
              'tiers': {
                ...settings.tiers.map((tier, id) => MapEntry(tier.name, id)),
                'deep': 'sol',
              },
            },
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
    await main.startCompanion();
    final runner = FakeClaudeRunner();
    final controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {
        kGaiaClaudeCodeAdapter: runner,
        if (codex) kGaiaCodexAdapter: FakeClaudeRunner(),
      },
      cliVersions: {
        kGaiaClaudeCodeAdapter: () async => (2, 1, 310),
        kGaiaCodexAdapter: () async => codexInstalled ? (0, 166, 0) : null,
      },
      usageSources: {
        kGaiaClaudeCodeAdapter: _Source(used),
        if (codexSignedOut) kGaiaCodexAdapter: _SignedOutSource(),
      },
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
    return (controller, runner);
  }

  // The card's reset timer and the widgets' timers go with these.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  Finder composer() => find.widgetWithText(TextField, 'Message Gaia');

  GaiaMessage interrupted(String text) => GaiaMessage(
    id: 'm1',
    chatId: 'c1',
    seq: 1,
    role: GaiaMessageRole.assistant,
    parts: [GaiaTextPart(text)],
    status: GaiaMessageStatus.error,
    error: "You've hit your session limit · resets 4pm",
    createdAt: at,
    updatedAt: at,
    adapter: kGaiaClaudeCodeAdapter,
  );

  GaiaMessage asked(String text) => GaiaMessage(
    id: 'm0',
    chatId: 'c1',
    seq: 0,
    role: GaiaMessageRole.user,
    parts: [GaiaTextPart(text)],
    status: GaiaMessageStatus.complete,
    createdAt: at,
    updatedAt: at,
  );

  testWidgets('a low account warns over the composer, which stays', (
    tester,
  ) async {
    final (controller, _) = await pump(
      tester,
      used: {kGaiaDefaultAccountId: 0.93},
    );
    expect(find.textContaining('is low: 7% of the 5-hour'), findsOneWidget);
    expect(find.textContaining('(Alpha)'), findsOneWidget);
    expect(find.text('Switch to Beta'), findsOneWidget);
    expect(composer(), findsOneWidget);

    await tester.tap(find.text('Switch to Beta'));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentAccount(kGaiaClaudeCodeAdapter), _b);
    expect(find.textContaining('is low'), findsNothing);
    await finish(tester);
  });

  testWidgets('with no account that is not low, the banner offers none', (
    tester,
  ) async {
    await pump(tester, used: {kGaiaDefaultAccountId: 0.93, 'b': 0.95});
    expect(find.textContaining('is low'), findsOneWidget);
    expect(find.textContaining('Switch to'), findsNothing);
    await finish(tester);
  });

  testWidgets('an exhausted account replaces the composer; Esc dismisses', (
    tester,
  ) async {
    await pump(tester, used: {kGaiaDefaultAccountId: 1});
    expect(composer(), findsNothing);
    expect(find.textContaining('is out of usage'), findsOneWidget);
    expect(find.text('Switch to Beta'), findsOneWidget);
    // Nothing was interrupted here, so there's nothing to send again.
    expect(find.text('Resend my last message'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 1));
    expect(composer(), findsOneWidget);
    expect(find.textContaining('is out of usage'), findsNothing);
    await finish(tester);
  });

  testWidgets('Ctrl+Enter takes the first option with no second dialog', (
    tester,
  ) async {
    final (controller, _) = await pump(
      tester,
      used: {kGaiaDefaultAccountId: 1},
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentAccount(kGaiaClaudeCodeAdapter), _b);
    expect(composer(), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });

  testWidgets('coming back to the window gives the card its keys again', (
    tester,
  ) async {
    final (controller, _) = await pump(
      tester,
      used: {kGaiaDefaultAccountId: 1},
    );
    // The window lost it, and the card came up or stayed with none.
    FocusManager.instance.primaryFocus?.unfocus();
    controller.focused.value = false;
    await tester.pump();
    controller.focused.value = true;
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentAccount(kGaiaClaudeCodeAdapter), _b);
    await finish(tester);
  });

  testWidgets(
    'the card carries the §7.5 warning and the resend, on by default',
    (tester) async {
      final (controller, runner) = await pump(
        tester,
        used: {kGaiaDefaultAccountId: 1},
        messages: [asked('Write the plan'), interrupted('The plan so')],
      );
      // The partial answer, and what stopped it.
      expect(find.textContaining('The plan so'), findsOneWidget);
      expect(find.textContaining('Stopped at the usage limit'), findsOneWidget);
      expect(find.textContaining('prompt cache is lost'), findsOneWidget);
      expect(find.text('Resend my last message'), findsOneWidget);

      controller.draft.text = 'kept draft';
      runner.turns.add(const [
        ClaudeResult(sessionId: 's', isError: false, text: ''),
      ]);
      await tester.runAsync(() async {
        await tester.tap(find.text('Switch to Beta'));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(seconds: 1));

      expect(runner.accounts.single, _b);
      expect(runner.sent.single.prompt, endsWith('Write the plan'));
      expect(controller.draft.text, 'kept draft');
      await finish(tester);
    },
  );

  testWidgets('unticked, the switch sends nothing', (tester) async {
    final (controller, runner) = await pump(
      tester,
      used: {kGaiaDefaultAccountId: 1},
      messages: [asked('Write the plan'), interrupted('The plan so')],
    );
    await tester.tap(find.text('Resend my last message'));
    await tester.pump();
    await tester.tap(find.text('Switch to Beta'));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentAccount(kGaiaClaudeCodeAdapter), _b);
    expect(runner.sent, isEmpty);
    await finish(tester);
  });

  testWidgets('with no other account, another provider is offered', (
    tester,
  ) async {
    final (controller, _) = await pump(
      tester,
      accounts: const [_a],
      used: {kGaiaDefaultAccountId: 1},
      codex: true,
    );
    expect(find.text('Deep (Codex Sol)'), findsOneWidget);
    // Another tier on the same provider isn't: it's out too.
    expect(find.textContaining('Quick ('), findsNothing);

    await tester.tap(find.text('Deep (Codex Sol)'));
    await tester.pump(const Duration(seconds: 1));
    expect(controller.nextTier, GaiaTier.deep);
    expect(composer(), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a provider that is signed out or not installed is not offered', (
    tester,
  ) async {
    await pump(
      tester,
      accounts: const [_a],
      used: {kGaiaDefaultAccountId: 1},
      codex: true,
      codexSignedOut: true,
    );
    expect(find.text('Deep (Codex Sol)'), findsNothing);
    expect(find.text('Usage has run out'), findsOneWidget);
    await finish(tester);

    await pump(
      tester,
      accounts: const [_a],
      used: {kGaiaDefaultAccountId: 1},
      codex: true,
      codexInstalled: false,
    );
    expect(find.text('Deep (Codex Sol)'), findsNothing);
    expect(find.text('Usage has run out'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('with nothing to offer, it says when usage is back', (
    tester,
  ) async {
    await pump(
      tester,
      accounts: const [_a],
      used: {kGaiaDefaultAccountId: 1},
      messages: [asked('Write the plan'), interrupted('The plan so')],
    );
    expect(find.text('Usage has run out'), findsOneWidget);
    expect(find.textContaining('Resets at'), findsOneWidget);
    expect(find.textContaining('Switch to'), findsNothing);
    expect(find.text('Resend my last message'), findsNothing);
    expect(find.text('Dismiss'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('with two accounts out, the soonest reset is named', (
    tester,
  ) async {
    await pump(tester, used: {kGaiaDefaultAccountId: 1, 'b': 1});
    expect(find.text('Usage has run out'), findsOneWidget);
    expect(
      find.textContaining(RegExp('(Alpha|Beta) resets at')),
      findsOneWidget,
    );
    await finish(tester);
  });
}
