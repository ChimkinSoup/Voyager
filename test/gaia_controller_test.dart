import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';

import 'fakes/gaia_fakes.dart';

/// The companion's controller (GAIA_HLD.md §3, §15.1, §15.7) against a
/// scripted main instance, a fake CLI replaying recorded turns, and a fake
/// window.

/// Lets every pending chain run: pipe round trips, the fake CLI's events
/// and the in-memory database's writes.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The main instance's side of the protocol, answered from a
/// [GaiaChatStore] as `GaiaHost` does, recording each request.
class _Main {
  _Main() {
    pipe
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = _answer
      ..onEvent = (event, params) => events.add((event, params));
  }

  final pipe = FakeGaiaPipe.main();
  final db = AppDatabase.inMemory();
  late final repository = DriftGaiaRepository(db);
  late final store = GaiaChatStore(repository, deviceId: 'laptop');
  final requests = <String>[];

  /// The companion's events, as `event` or `event {params}`.
  final events = <(String, Map<String, Object?>)>[];
  late FakeGaiaPipe companion;
  var aborted = false;
  var accent = 0xFF7C9EFF;
  var settings = GaiaSettings.initial().toJson();

  /// putMessage requests per message id.
  final puts = <String, int>{};

  Future<Object?> _answer(String method, Map<String, Object?> params) async {
    requests.add(method);
    switch (method) {
      case 'hello':
        return {
          'aborted': aborted,
          'accent': accent,
          'deviceId': store.deviceId,
          'settings': settings,
        };
      case 'chats':
        return [for (final chat in await store.chats()) chat.toJson()];
      case 'putChat':
        await store.createChat(
          GaiaChat.fromJson((params['chat']! as Map).cast<String, Object?>()),
        );
        return null;
      case 'setSession':
        await store.setSession(
          params['chatId']! as String,
          params['sessionId']! as String,
          params['lastSeq']! as int,
          adapter: params['adapter']! as String,
        );
        return null;
      case 'setTier':
        await store.setTier(
          params['chatId']! as String,
          GaiaTier.values.byName(params['tier']! as String),
        );
        return null;
      case 'setLastTier':
        await store.setLastTier(
          GaiaTier.values.byName(params['tier']! as String),
        );
        return null;
      case 'messages':
        return [
          for (final message in await store.messages(
            params['chatId']! as String,
          ))
            message.toJson(),
        ];
      case 'putMessage':
        final message = GaiaMessage.fromJson(
          (params['message']! as Map).cast<String, Object?>(),
        );
        puts[message.id] = (puts[message.id] ?? 0) + 1;
        await store.putMessage(message);
        return null;
      case 'rearm':
        aborted = false;
        return null;
    }
    throw StateError('unknown method $method');
  }

  Future<GaiaChat> chat() async => (await store.chats()).single;

  Future<List<GaiaMessage>> messages() async =>
      store.messages((await chat()).id);
}

String _text(GaiaMessage message) => [
  for (final part in message.parts)
    if (part is GaiaTextPart) part.text,
].join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Main main;
  late FakeClaudeRunner runner;
  late FakeGaiaWindow window;
  late List<int> exits;
  late GaiaController controller;

  Future<void> startCompanion({
    Future<(int, int, int)?> Function()? cliVersion,
    GaiaDebug? debug,
  }) async {
    await main.pipe.startCompanion();
    controller = GaiaController(
      pipe: main.companion,
      window: window,
      runners: {kGaiaClaudeCodeAdapter: runner},
      cliVersions: {
        kGaiaClaudeCodeAdapter: cliVersion ?? () async => (2, 1, 310),
      },
      exit: exits.add,
      debug: debug,
    );
    await controller.start();
    await settle();
  }

  setUp(() async {
    main = _Main();
    runner = FakeClaudeRunner();
    window = FakeGaiaWindow();
    exits = [];
  });

  group('scripted replies', () {
    late GaiaDebug debug;

    setUp(() async {
      debug = GaiaDebug();
      await debug.setScriptedReplies(true);
      await debug.setReplyDelay(Duration.zero);
      await debug.setStreamSpeed(6400);
      await startCompanion(debug: debug);
    });

    test('a command plays its script, with no CLI run or session', () async {
      await controller.send('/msg1');
      await settle();

      expect(runner.sent, isEmpty);
      final chat = await main.chat();
      expect(chat.agentSessions, isEmpty);
      final [_, reply] = await main.messages();
      expect(reply.status, GaiaMessageStatus.complete);
      expect(reply.model, 'gaia-debug-script');
      expect(_text(reply), startsWith('# A heading'));
      expect(_text(reply), endsWith('A closing paragraph after a rule.'));
    });

    test(
      'tool steps come out as activity between text blocks',
      () async {
        await controller.send('/msg4');
        await settle();

        final reply = (await main.messages()).last;
        expect(reply.parts.map((p) => p.runtimeType), [
          GaiaTextPart,
          GaiaActivityPart,
          GaiaTextPart,
          GaiaActivityPart,
          GaiaTextPart,
        ]);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('an error script ends the reply as an error', () async {
      await controller.send('/error');
      await settle();

      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.error);
      expect(reply.error, contains('issue with the selected model'));
    });

    test('Stop ends a hanging script as stopped', () async {
      final sent = controller.send('/hang');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(controller.currentRunning, isTrue);
      await controller.stop(controller.currentChatId!);
      await sent;
      await settle();

      expect((await main.messages()).last.status, GaiaMessageStatus.cancelled);
    });

    test(
      "on screen, another chat's finished run is Gaia's toast, not Windows'",
      () async {
        final toasts = <GaiaRunToast>[];
        controller.toasts.listen(toasts.add);
        await controller.openWindow();
        await debug.setReplyDelay(const Duration(milliseconds: 200));
        final sent = controller.send('/msg6');
        await settle();
        final chatId = controller.currentChatId;
        controller.newChat();
        await sent;
        await settle();

        expect(main.events.where((e) => e.$1 == 'runDone'), isEmpty);
        final toast = toasts.single;
        expect(toast.chatId, chatId);
        expect(toast.title, 'Gaia has a question');
        expect(toast.body, startsWith('/msg6: '));
        expect(toast.question, isTrue);
        expect(toast.error, isFalse);
      },
    );

    test('behind other apps, it is the Windows toast after all', () async {
      final toasts = <GaiaRunToast>[];
      controller.toasts.listen(toasts.add);
      await controller.openWindow();
      await debug.setReplyDelay(const Duration(milliseconds: 200));
      final sent = controller.send('/msg6');
      await settle();
      controller.newChat();
      window.behind = true;
      await sent;
      await settle();

      expect(toasts, isEmpty);
      final (_, done) = main.events.singleWhere((e) => e.$1 == 'runDone');
      expect(done['title'], 'Gaia has a question');
    });

    test(
      'the chat in view, behind other apps, raises the Windows toast',
      () async {
        await controller.openWindow();
        window.behind = true;
        await controller.send('/error');
        await settle();

        final (_, done) = main.events.singleWhere((e) => e.$1 == 'runDone');
        expect(done['title'], 'Gaia ran into an error');
      },
    );

    test(
      "a floater out of focus shows Gaia's toast, even for its own chat",
      () async {
        final toasts = <GaiaRunToast>[];
        controller.toasts.listen(toasts.add);
        await controller.onHotkey('small');
        window.behind = true;
        await controller.send('/msg1');
        await settle();

        expect(main.events.where((e) => e.$1 == 'runDone'), isEmpty);
        expect(toasts.single.title, 'Gaia is done');
      },
    );

    test('no toast at all for the chat in view', () async {
      final toasts = <GaiaRunToast>[];
      controller.toasts.listen(toasts.add);
      await controller.openWindow();
      await controller.send('/error');
      await settle();

      expect(toasts, isEmpty);
      expect(main.events.where((e) => e.$1 == 'runDone'), isEmpty);
    });

    test('with scripted replies off, a command goes to the CLI', () async {
      await debug.setScriptedReplies(false);
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('/msg1');
      await settle();

      expect(runner.sent.single.prompt, '/msg1');
    });
  });

  group('tiers', () {
    setUp(() => startCompanion());

    test('a new chat runs on the last used tier, Standard at first', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();

      expect(runner.sent.single.model, 'claude-sonnet-5-5');
      expect((await main.chat()).tier, GaiaTier.standard);
    });

    test("a picked tier runs this message, becomes the chat's, and is the next "
        "new chat's", () async {
      runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
      controller.pickTier(GaiaTier.deep);
      await controller.send('Run echo gaia-fixture');
      await settle();
      expect(controller.pickedTier, isNull);
      await controller.send('Now say done');
      await settle();

      expect(runner.sent.map((s) => s.model), [
        'claude-opus-5-5',
        'claude-opus-5-5',
      ]);
      expect((await main.chat()).tier, GaiaTier.deep);
      expect((await main.store.chats()).single.tier, GaiaTier.deep);
      expect((await main.repository.getSettings()).lastTier, GaiaTier.deep);
      controller.newChat();
      expect(controller.nextTier, GaiaTier.deep);
    });

    test('a session is kept per adapter', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();

      expect((await main.chat()).agentSessions.keys, [
        gaiaSessionKey('laptop', adapter: kGaiaClaudeCodeAdapter),
      ]);
    });

    test("an agent this companion can't run ends in an error", () async {
      main.companion.onEvent!('settings', {
        ...GaiaSettings.initial().toJson(),
        'agents': [
          const GaiaAgent(
            id: 'sol',
            label: 'GPT-6.1 Sol',
            adapter: kGaiaCodexAdapter,
            model: 'gpt-6.1-sol',
          ).toJson(),
        ],
        'tiers': {'standard': 'sol'},
      });
      await settle();
      await controller.send('Hi');
      await settle();

      expect(runner.sent, isEmpty);
      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.error);
      expect(reply.error, contains("GPT-6.1 Sol can't run"));
    });

    test('a tier with no agent ends in an error naming it', () async {
      main.companion.onEvent!('settings', {
        ...GaiaSettings.initial().toJson(),
        'tiers': <String, Object?>{},
      });
      await settle();
      await controller.send('Hi');
      await settle();

      expect(runner.sent, isEmpty);
      expect(
        (await main.messages()).last.error,
        contains('No agent is set for Standard'),
      );
    });
  });

  group('chats', () {
    setUp(() => startCompanion());

    test(
      'a first message makes a chat, runs it and saves both turns',
      () async {
        runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
        await controller.send('Say hello\nand nothing else');
        await settle();

        final chat = await main.chat();
        expect(chat.title, 'Say hello');
        expect(
          chat.sessionOn('laptop'),
          '80a82cab-3135-41d0-806c-e0b1fd2eb5df',
        );
        expect(chat.agentSessions.values.single.lastSeq, 1);
        expect(runner.sent.single.sessionId, isNull);
        expect(runner.sent.single.prompt, 'Say hello\nand nothing else');

        final [question, reply] = await main.messages();
        expect(question.role, GaiaMessageRole.user);
        expect(_text(question), 'Say hello\nand nothing else');
        expect(reply.role, GaiaMessageRole.assistant);
        expect(reply.status, GaiaMessageStatus.complete);
        expect(_text(reply), contains('hello there'));
        expect(reply.model, 'claude-sonnet-5-5');
        expect(reply.adapter, kGaiaClaudeCodeAdapter);
        expect(controller.messages.map((m) => m.status), [
          GaiaMessageStatus.complete,
          GaiaMessageStatus.complete,
        ]);
      },
    );

    test('a long first line is cut to 60 characters for the title', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('x' * 80);
      expect(controller.currentChat!.title, '${'x' * 60}…');
    });

    test("later messages resume the chat's session", () async {
      runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
      await controller.send('Run echo gaia-fixture');
      await controller.send('Now say done');
      await settle();

      expect(runner.sent[0].sessionId, isNull);
      expect(runner.sent[1].sessionId, '67acd0d4-e23e-47e7-adf3-39e11f8f2670');
      final messages = await main.messages();
      expect(messages.map((m) => m.seq), [0, 1, 2, 3]);
      expect(messages[1].parts.whereType<GaiaActivityPart>().single.tools, [
        'Bash',
      ]);
      expect(_text(messages[3]), contains('done'));
    });

    test('an error result is saved as an error, with its text', () async {
      runner.turns.addAll(claudeFixtureTurns('unknown_model.jsonl'));
      await controller.send('Hi');
      await settle();

      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.error);
      expect(reply.error, contains('issue with the selected model'));
    });

    test(
      'a CLI that dies mid-reply leaves an error, and what streamed',
      () async {
        runner.turns.add([
          const ClaudeTextStart(),
          const ClaudeTextDelta('half an ans'),
        ]);
        final sending = controller.send('Hi');
        await settle();
        runner.crash(controller.currentChatId!);
        await sending;
        await settle();

        final reply = (await main.messages()).last;
        expect(reply.status, GaiaMessageStatus.error);
        expect(reply.error, contains('exited'));
        expect(_text(reply), 'half an ans');
      },
    );

    test('Stop keeps what streamed and saves the reply as cancelled', () async {
      runner.turns.add([
        const ClaudeTextStart(),
        const ClaudeTextDelta('partial'),
      ]);
      final sending = controller.send('Hi');
      await settle();
      expect(controller.currentRunning, isTrue);
      expect((await main.messages()).last.status, GaiaMessageStatus.streaming);

      await controller.stop(controller.currentChatId!);
      await sending;
      await settle();

      expect(controller.currentRunning, isFalse);
      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.cancelled);
      expect(reply.error, isNull);
      expect(_text(reply), 'partial');
    });

    test('a message while the chat is running is ignored', () async {
      runner.turns.add([const ClaudeTextStart()]);
      final sending = controller.send('first');
      await settle();
      await controller.send('second');
      expect(runner.sent.map((s) => s.prompt), ['first']);
      await controller.stop(controller.currentChatId!);
      await sending;
    });

    test(
      'a streaming reply is written through at most once a second',
      () async {
        runner.turns.add([
          const ClaudeTextStart(),
          for (var i = 0; i < 50; i++) ClaudeTextDelta('$i '),
          const ClaudeResult(sessionId: 's', isError: false, text: ''),
        ]);
        await controller.send('Count');
        await settle();

        final reply = (await main.messages()).last;
        expect(_text(reply), startsWith('0 1 2 '));
        // Created, finished, and at most one write-through between.
        expect(main.puts[reply.id], lessThanOrEqualTo(3));
      },
    );

    test(
      'selecting a chat loads its messages from the main instance',
      () async {
        runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
        await controller.send('Hi');
        await settle();
        final chatId = controller.currentChatId!;

        // A fresh companion knows the chats, not their messages.
        main.companion.disconnect();
        await startCompanion();
        expect(controller.chats.single.id, chatId);
        expect(controller.messages, isEmpty);

        await controller.selectChat(chatId);
        expect(controller.messages.map(_text), ['Hi', contains('hello there')]);
      },
    );

    test('a session on another device starts a new one here', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      final now = DateTime.utc(2026, 10, 24);
      await main.repository.upsertChat(
        GaiaChat(
          id: 'c1',
          title: 'From the desktop',
          createdAt: now,
          updatedAt: now,
          lastMessageAt: now,
          agentSessions: {
            gaiaSessionKey('desktop'): const GaiaAgentSession(
              sessionId: 'desktop-session',
              lastSeq: 1,
            ),
          },
        ),
      );
      main.pipe.notify('changed');
      await settle();
      await controller.selectChat('c1');
      await controller.send('Hi');
      await settle();

      expect(runner.sent.single.sessionId, isNull);
      final chat = await main.chat();
      expect(chat.sessionOn('desktop'), 'desktop-session');
      expect(chat.sessionOn('laptop'), '80a82cab-3135-41d0-806c-e0b1fd2eb5df');
    });

    test('a reply ending on a question needs input', () async {
      runner.turns.add([
        const ClaudeTextStart(),
        const ClaudeTextDelta('Done.\n\nShould I push it?'),
        const ClaudeResult(sessionId: 's', isError: false, text: ''),
      ]);
      await controller.send('Commit');
      await settle();
      expect((await main.messages()).last.needsInput, isTrue);
    });

    test('runs are reported as they start and end', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Say hello');
      await settle();
      final runs = [
        for (final (event, params) in main.events)
          if (event == 'runs') (params['runs']! as List).length,
      ];
      expect(runs, [1, 0]);
    });

    test('a run that ends while Gaia is hidden raises a toast', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Say hello');
      await settle();
      final (_, done) = main.events.singleWhere((e) => e.$1 == 'runDone');
      expect(done['chatId'], controller.currentChatId);
      expect(done['title'], 'Gaia is done');
      expect(done['body'], startsWith('Say hello: '));
    });

    test('no toast while Gaia is on screen, or with it turned off', () async {
      runner.turns.addAll(claudeFixtureTurns('tool_call_two_turns.jsonl'));
      await controller.openWindow();
      await controller.send('Run echo gaia-fixture');
      await settle();
      await controller.dismiss();
      main.pipe.notify('settings', {'gaiaMd': '', 'notifyOnDone': false});
      await settle();
      await controller.send('Now say done');
      await settle();
      expect(main.events.where((e) => e.$1 == 'runDone'), isEmpty);
    });

    test("a new chat the main instance can't save is dropped, unrun", () async {
      final answer = main.pipe.onRequest!;
      main.pipe.onRequest = (method, params) async {
        if (method == 'putChat') throw StateError('going away');
        return answer(method, params);
      };
      await controller.send('Hi');
      await settle();

      expect(runner.sent, isEmpty);
      expect(controller.chats, isEmpty);
      expect(controller.currentChatId, isNull);
      expect(main.requests, isNot(contains('putMessage')));
    });

    test('a chat deleted elsewhere leaves the list and the view', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();
      await main.repository.softDeleteChat(controller.currentChatId!);
      main.pipe.notify('changed');
      await settle();
      expect(controller.chats, isEmpty);
      expect(controller.currentChatId, isNull);
    });

    test("the main instance's Stop stops the run", () async {
      runner.turns.add([const ClaudeTextStart()]);
      final sending = controller.send('Hi');
      await settle();
      await main.pipe.request('stop', {'chatId': controller.currentChatId});
      await sending;
      await settle();
      expect((await main.messages()).last.status, GaiaMessageStatus.cancelled);
    });

    test('openChat opens the Gaia window on that chat', () async {
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      await settle();
      final chatId = controller.currentChatId!;
      controller.newChat();
      main.pipe.notify('openChat', {'chatId': chatId});
      await settle();
      expect(window.shown, GaiaMode.window);
      expect(controller.currentChatId, chatId);
      expect(controller.messages, hasLength(2));
    });
  });

  group('GAIA.md', () {
    test('hello and settings events hand it to the runner', () async {
      main.settings = {'gaiaMd': 'Be brief.', 'notifyOnDone': true};
      await startCompanion();
      main.pipe.notify('settings', {'gaiaMd': 'Be briefer.'});
      await settle();
      expect(runner.instructions, ['Be brief.', 'Be briefer.']);
    });
  });

  group('drain (§3.2)', () {
    setUp(() => startCompanion());

    test('with nothing running, it answers at once', () async {
      expect(await main.pipe.request('drain'), {'running': 0});
      expect(controller.draining, isNull);
    });

    test('Wait lets the run finish, then says drained', () async {
      final turn = claudeFixtureTurns('single_turn.jsonl').single;
      // Held until the drain has been asked.
      runner.turns.add(turn.where((e) => e is! ClaudeResult).toList());
      final sending = controller.send('Hi');
      await settle();

      expect(await main.pipe.request('drain'), {'running': 1});
      await settle();
      expect(controller.draining, 1);
      expect(window.shown, GaiaMode.window);
      controller.waitForDrain();
      expect(controller.drainWaiting, isTrue);

      // A new message waits too.
      await controller.send('Another');
      expect(runner.sent, hasLength(1));

      await controller.stop(controller.currentChatId!);
      await sending;
      await settle();
      expect(controller.draining, isNull);
      expect(main.events.map((e) => e.$1), contains('drained'));
    });

    test('Cancel stops the runs and keeps them as interrupted', () async {
      runner.turns.add([const ClaudeTextStart(), const ClaudeTextDelta('so')]);
      final sending = controller.send('Hi');
      await settle();
      await main.pipe.request('drain');
      await controller.cancelDrain();
      await sending;
      await settle();

      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.interrupted);
      expect(_text(reply), 'so');
      expect(main.events.map((e) => e.$1), contains('drained'));
    });
  });

  group('Abort', () {
    test('kills every run and saves streaming replies as aborted', () async {
      await startCompanion();
      runner.turns.add([const ClaudeTextStart(), const ClaudeTextDelta('so')]);
      final sending = controller.send('Hi');
      await settle();

      await main.pipe.request('abort');
      await sending;
      await settle();

      expect(runner.killAllCount, 1);
      expect(controller.aborted, isTrue);
      final reply = (await main.messages()).last;
      expect(reply.status, GaiaMessageStatus.aborted);
      expect(reply.error, isNull);
    });

    test('nothing runs while aborted, until Re-arm', () async {
      await startCompanion();
      await main.pipe.request('abort');
      await controller.send('Hi');
      expect(runner.sent, isEmpty);

      await controller.rearm();
      expect(main.requests, contains('rearm'));
      expect(controller.aborted, isFalse);
      runner.turns.addAll(claudeFixtureTurns('single_turn.jsonl'));
      await controller.send('Hi');
      expect(runner.sent, hasLength(1));
    });

    test('an Abort from before the companion started still holds', () async {
      main.aborted = true;
      await startCompanion();
      expect(controller.aborted, isTrue);
    });
  });

  group('main instance', () {
    test('hello and accent events set the accent', () async {
      main.accent = 0xFF4CC38A;
      await startCompanion();
      expect(controller.accent.value, 0xFF4CC38A);

      main.pipe.notify('accent', {'argb': 0xFFFF7AB6});
      await settle();
      expect(controller.accent.value, 0xFFFF7AB6);
    });

    test('losing it kills the runs and ends the companion', () async {
      await startCompanion();
      main.pipe.disconnect();
      await settle();
      expect(runner.killAllCount, 1);
      expect(exits, [0]);
    });

    test("a companion that can't connect ends", () async {
      await startCompanion();
      // A second companion, while the first holds the pipe.
      await main.pipe.startCompanion();
      final second = GaiaController(
        pipe: main.companion,
        window: FakeGaiaWindow(),
        runners: {kGaiaClaudeCodeAdapter: FakeClaudeRunner()},
        cliVersions: {kGaiaClaudeCodeAdapter: () async => null},
        exit: exits.add,
      );
      await second.start();
      expect(exits, [0]);
    });

    test('no CLI installed is reported', () async {
      await startCompanion(cliVersion: () async => null);
      expect(controller.cliChecked, isTrue);
      expect(controller.cliVersions[kGaiaClaudeCodeAdapter], isNull);
    });
  });

  group('hotkeys (§15.1)', () {
    setUp(() => startCompanion());

    Future<void> press(String key) async {
      main.pipe.notify('hotkey', {'key': key});
      await settle();
    }

    test(
      'A opens the small floater, and hides it when it is showing',
      () async {
        await press('small');
        expect(window.shown, GaiaMode.small);
        expect(controller.layout, GaiaMode.small);
        await press('small');
        expect(window.shown, isNull);
      },
    );

    test('A switches the large floater to small', () async {
      await press('large');
      await press('small');
      expect(window.shown, GaiaMode.small);
    });

    test(
      'B opens the large floater, and is a no-op when it is showing',
      () async {
        await press('large');
        expect(window.shown, GaiaMode.large);
        await press('large');
        expect(window.shown, GaiaMode.large);
      },
    );

    test('G opens the Gaia window', () async {
      await press('window');
      expect(window.shown, GaiaMode.window);
      expect(controller.layout, GaiaMode.window);
    });

    for (final key in ['small', 'large']) {
      test(
        'a $key floater over the Gaia window dismisses back to it',
        () async {
          await press('window');
          await press(key);
          expect(
            window.shown,
            key == 'small' ? GaiaMode.small : GaiaMode.large,
          );
          await controller.dismiss();
          expect(window.shown, GaiaMode.window);
          await controller.dismiss();
          expect(window.shown, isNull);
        },
      );
    }

    test('a floater opened from hidden dismisses to hidden', () async {
      await press('large');
      await controller.dismiss();
      expect(window.shown, isNull);
    });
  });
}
