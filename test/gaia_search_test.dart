import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';

import 'fakes/gaia_fakes.dart';

/// Gaia's search (GAIA_HLD.md §17): opened from the sidebar's button over
/// the middle of the window, chats by title and messages as snippets under
/// their chat's title, a pick opening the chat at it.
void main() {
  final at = DateTime.utc(2026, 11, 8);

  GaiaChat chat(String id, String title, {DateTime? last}) => GaiaChat(
    id: id,
    title: title,
    createdAt: at,
    updatedAt: at,
    lastMessageAt: last ?? at,
    tier: GaiaTier.standard,
  );

  /// [count] messages of [chatId], long enough that the chat scrolls.
  List<GaiaMessage> messages(String chatId, int count) => [
    for (var seq = 0; seq < count; seq++)
      GaiaMessage(
        id: '$chatId-m$seq',
        chatId: chatId,
        seq: seq,
        role: seq.isEven ? GaiaMessageRole.user : GaiaMessageRole.assistant,
        parts: [GaiaTextPart('Message $seq of $chatId\n\n${'Text. ' * 40}')],
        status: GaiaMessageStatus.complete,
        createdAt: at,
        updatedAt: at,
      ),
  ];

  late List<String> queries;

  /// Older chats, beyond the two, as many as there are.
  var others = 0;

  Future<GaiaController> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Asked of from the window buttons.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    queries = [];
    addTearDown(() => others = 0);
    late FakeGaiaPipe companion;
    final main = FakeGaiaPipe.main();
    main
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        switch (method) {
          case 'hello':
            return {
              'aborted': false,
              'accent': 0xFF7C9EFF,
              'deviceId': 'laptop',
              'settings': GaiaSettings.initial().toJson(),
            };
          case 'chats':
            return [
              for (var n = 0; n < others; n++)
                chat(
                  'x$n',
                  'Older chat $n',
                  last: at.subtract(Duration(hours: n + 1)),
                ).toJson(),
              chat('c1', 'Long chat').toJson(),
              chat(
                'c2',
                'Short chat',
                last: at.add(const Duration(days: 1)),
              ).toJson(),
            ];
          case 'messages':
            final chatId = params['chatId']! as String;
            return [
              for (final message in messages(chatId, chatId == 'c1' ? 40 : 2))
                message.toJson(),
            ];
          case 'searchMessages':
            final query = params['query']! as String;
            queries.add(query);
            if (query != 'needle') return <Object?>[];
            return [
              const GaiaSearchHit(
                chatId: 'c1',
                messageId: 'c1-m6',
                seq: 6,
                snippet:
                    'Message 6 of c1 '
                    '${GaiaSearchHit.start}needle${GaiaSearchHit.end} '
                    'in the hay…',
              ).toJson(),
            ];
          case 'drafts':
            return <Object?>[];
        }
        return null;
      };
    await main.startCompanion();
    final controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: FakeClaudeRunner()},
      cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
      exit: (_) {},
    );
    await tester.runAsync(() async {
      await controller.start();
      await controller.openWindow();
      await controller.selectChat('c2');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    return controller;
  }

  final field = find.byWidgetPredicate(
    (widget) => widget is GaiaTextField && widget.hintText == 'Search chats',
  );

  Finder rows() => find.byWidgetPredicate(
    (widget) => widget.runtimeType.toString() == '_Row',
  );

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(
      find.descendant(of: field, matching: find.byType(EditableText)),
      query,
    );
    // Past the pause it waits for, then the pipe's answer.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  /// Lets a pick's chat load and the list glide to it.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the button opens it in the middle, its field focused', (
    tester,
  ) async {
    await pump(tester);
    expect(field, findsNothing);
    await open(tester);
    expect(field, findsOneWidget);
    final middle = tester.getCenter(field.first);
    expect(middle.dx, closeTo(550, 1));
    final editable = tester.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    // And again.
    await open(tester);
    expect(field, findsOneWidget);
  });

  testWidgets('a hit shows its chat and snippet; clicked, it closes and the '
      'chat opens at it', (tester) async {
    final controller = await pump(tester);
    await open(tester);
    await search(tester, 'needle');

    expect(queries, ['needle']);
    expect(find.text('Messages'), findsOneWidget);
    expect(searchChats, findsNothing);
    final hit = rows();
    expect(hit, findsOneWidget);
    expect(
      find.descendant(of: hit, matching: find.text('Long chat')),
      findsOneWidget,
    );
    final snippet = find.descendant(
      of: hit,
      matching: find.textContaining(
        'Message 6 of c1 needle in the hay',
        findRichText: true,
      ),
    );
    expect(snippet, findsOneWidget);

    await tester.tap(snippet);
    await settle(tester);

    expect(field, findsNothing);
    expect(controller.currentChatId, 'c1');
    expect(controller.revealing, isNull);
    // Glided up to it, from the newest message at the bottom: its top near
    // the list's.
    final message = find.byWidgetPredicate(
      (widget) =>
          widget is EditableText &&
          widget.controller.text.startsWith('Message 6 of c1'),
    );
    expect(tester.getTopLeft(message).dy, lessThan(200));
  });

  testWidgets('chats match by title; Up and Down move, Enter picks', (
    tester,
  ) async {
    final controller = await pump(tester);
    await open(tester);
    await search(tester, 'chat');
    expect(searchChats, findsOneWidget);
    expect(rows(), findsNWidgets(2));

    // Newest first. Down past the last comes round to the first, and Up
    // past the first round to the last.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);

    expect(field, findsNothing);
    expect(controller.currentChatId, 'c1');

    await open(tester);
    await search(tester, 'short');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(controller.currentChatId, 'c2');
    // The switch's draft save, after its pause.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('before anything is typed, the most recent chats, newest '
      'first', (tester) async {
    final controller = await pump(tester);
    await open(tester);
    expect(find.text('Recent'), findsOneWidget);
    expect(
      [
        for (final row in rows().evaluate())
          for (final text in find
              .descendant(of: find.byWidget(row.widget), matching: find.byType(Text))
              .evaluate())
            (text.widget as Text).data,
      ],
      ['Short chat', 'Long chat'],
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(field, findsNothing);
    expect(controller.currentChatId, 'c1');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('every chat is listed; Up from the first comes round to the '
      'oldest, in view', (tester) async {
    others = 300;
    final controller = await pump(tester);
    await open(tester);
    // Built only as they come into view.
    expect(rows().evaluate().length, lessThan(40));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    final oldest = find.text('Older chat 299');
    expect(oldest, findsOneWidget);
    final panel = tester.getRect(find.byType(ListView).last);
    expect(panel.contains(tester.getCenter(oldest)), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(controller.currentChatId, 'x299');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Ctrl+F opens it too', (tester) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(field, findsOneWidget);
  });

  testWidgets('no matches says so, once the search has answered', (
    tester,
  ) async {
    await pump(tester);
    await open(tester);
    await search(tester, 'zebra');
    expect(find.text('No matches'), findsOneWidget);
  });
}

/// The search's Chats heading, not the sidebar's.
final searchChats = find.descendant(
  of: find.byType(GaiaPanel),
  matching: find.text('Chats'),
);
