import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
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

  GaiaMessage reply(int seq, String? account) => GaiaMessage(
    id: 'm$seq',
    chatId: 'c1',
    seq: seq,
    role: GaiaMessageRole.assistant,
    parts: [GaiaTextPart('Reply $seq')],
    status: GaiaMessageStatus.complete,
    createdAt: at,
    updatedAt: at,
    adapter: kGaiaClaudeCodeAdapter,
    account: account,
  );

  Future<GaiaController> pump(
    WidgetTester tester, {
    required List<GaiaAccount> accounts,
    required List<GaiaMessage> messages,
    List<Map<String, Object?>>? switches,
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
      runners: {kGaiaClaudeCodeAdapter: FakeClaudeRunner()},
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

    // A click on the dulled ring isn't a switch.
    await tester.tap(rings().last);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentAccount(kGaiaClaudeCodeAdapter), a);
    expect(switches, isEmpty);
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
