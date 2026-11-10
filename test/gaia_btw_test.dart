import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_handoff.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';

import 'fakes/gaia_fakes.dart';

/// Side questions (GAIA_BTW_HLD.md): with no tools, on a native fork of the
/// chat's session where there is one, else by handoff.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final at = DateTime.utc(2026, 11, 9);

  GaiaBtw btw(
    String id, {
    String chatId = 'c1',
    String question = 'Q?',
    String answer = 'A.',
    GaiaMessageStatus status = GaiaMessageStatus.complete,
    DateTime? deletedAt,
    String deviceId = 'laptop',
    int minutes = 0,
  }) => GaiaBtw(
    id: id,
    chatId: chatId,
    question: question,
    answer: answer,
    status: status,
    anchorSeq: 1,
    deviceId: deviceId,
    createdAt: at.add(Duration(minutes: minutes)),
    updatedAt: at.add(Duration(minutes: minutes)),
    deletedAt: deletedAt,
  );

  GaiaMessage message(int seq, String text) => GaiaMessage(
    id: 'm$seq',
    chatId: 'c1',
    seq: seq,
    role: seq.isEven ? GaiaMessageRole.user : GaiaMessageRole.assistant,
    parts: [GaiaTextPart(text)],
    status: GaiaMessageStatus.complete,
    createdAt: at,
    updatedAt: at,
  );

  group('/btw', () {
    test('takes the rest of the draft; alone it is the built-in', () {
      expect(gaiaBtwText('/btw what was that file?'), 'what was that file?');
      expect(gaiaBtwText('  /btw  two\nlines '), 'two\nlines');
      expect(gaiaBtwText('/btw'), isNull);
      expect(gaiaBtwText('/btwx hi'), isNull);
      expect(gaiaBuiltinIn('/btw'), GaiaBuiltin.btw);
      expect(gaiaBuiltinIn('/btw hi'), isNull);
    });

    test("the palette lists Gaia's /btw, never the CLI's", () {
      final items = gaiaPaletteItems(
        const [],
        natives: const [
          (name: 'btw', description: "Claude Code's", argumentHint: ''),
        ],
      );
      final btws = items.where((item) => item.name == 'btw').toList();
      expect(btws.single.builtin, GaiaBuiltin.btw);
    });
  });

  group('the btw prompt', () {
    test('earlier ones oldest first, complete and uncleared only, then the '
        'question', () {
      final prompt = gaiaBtwPrompt(
        'Third?',
        earlier: [
          btw('a', question: 'First?', answer: 'One.'),
          btw('b', question: 'Failed?', status: GaiaMessageStatus.error),
          btw('c', question: 'Cleared?', deletedAt: at),
          btw('d', question: 'Stopped?', status: GaiaMessageStatus.cancelled),
          btw('e', question: 'Second?', answer: 'Two.'),
        ],
      );
      expect(prompt, contains('Q: First?\nA: One.\n\nQ: Second?\nA: Two.'));
      for (final left in ['Failed?', 'Cleared?', 'Stopped?']) {
        expect(prompt, isNot(contains(left)));
      }
      expect(prompt, endsWith('Third?'));
      expect(prompt, contains('You have no tools'));
    });

    test('past the cap the oldest go first, whole', () {
      final long = 'x' * (kGaiaBtwHistoryChars ~/ 2);
      final prompt = gaiaBtwPrompt(
        'Now?',
        earlier: [
          btw('a', question: 'Oldest?', answer: long),
          btw('b', question: 'Middle?', answer: long),
          btw('c', question: 'Newest?', answer: 'Short.'),
        ],
      );
      expect(prompt, isNot(contains('Oldest?')));
      expect(prompt, contains('Q: Middle?\nA: $long'));
      expect(prompt, contains('Q: Newest?'));
    });

    test('mid-reply: the prompt being answered and the reply so far', () {
      final prompt = gaiaBtwPrompt(
        'What is it doing?',
        asking: message(2, 'Refactor the parser'),
        answering: message(3, 'Reading parser.dart'),
      );
      expect(prompt, contains('User:\nRefactor the parser'));
      expect(prompt, contains('Assistant (in progress):\nReading parser.dart'));
      expect(
        prompt.indexOf('Refactor'),
        lessThan(prompt.indexOf('What is it doing?')),
      );
    });

    test('mid-reply with nothing written yet: no reply promised below', () {
      final prompt = gaiaBtwPrompt(
        'What is it doing?',
        asking: message(2, 'Refactor the parser'),
        answering: message(3, ''),
      );
      expect(prompt, contains('nothing written yet'));
      expect(prompt, isNot(contains('so far is below')));
      expect(prompt, isNot(contains('Assistant (in progress)')));
    });

    test('earlier answers are told as the model\'s own, from side threads', () {
      final prompt = gaiaBtwPrompt(
        'Again?',
        earlier: [btw('a', question: 'First?', answer: 'One.')],
      );
      expect(prompt, contains('You answered each in a separate side thread'));
      expect(prompt, contains('these are your own answers'));
    });

    test('none earlier: just the instruction and the question', () {
      expect(gaiaBtwPrompt('Why?'), isNot(contains('Side questions asked')));
    });
  });

  group('storage', () {
    late AppDatabase db;
    late DriftGaiaRepository repo;

    setUp(() async {
      db = AppDatabase.inMemory();
      repo = DriftGaiaRepository(db);
      await repo.upsertChat(
        GaiaChat(
          id: 'c1',
          title: 'Parser',
          createdAt: at,
          updatedAt: at,
          lastMessageAt: at,
        ),
      );
    });
    tearDown(() => db.close());

    test(
      'search finds a finished btw under its chat, and not once cleared',
      () async {
        await repo.upsertMessage(message(0, 'nothing about it'));
        await repo.upsertBtw(
          btw('b1', question: 'Where is tokenize?', answer: 'In lexer.dart.'),
        );
        // Not while it streams.
        await repo.upsertBtw(
          btw(
            'b2',
            question: 'tokenize again?',
            status: GaiaMessageStatus.streaming,
          ),
        );
        final hits = await repo.searchMessages('tokenize');
        expect(hits.single.btwId, 'b1');
        expect(hits.single.chatId, 'c1');
        expect(hits.single.seq, -1);
        expect(await repo.searchMessages('lexer'), hasLength(1));
        // The Gaia page's chat filter finds it too.
        expect(await repo.searchChatIds('lexer'), {'c1'});

        final store = GaiaChatStore(repo, deviceId: 'laptop');
        final cleared = await store.clearBtws('c1');
        expect(cleared, unorderedEquals(['b1', 'b2']));
        expect(await repo.searchMessages('tokenize'), isEmpty);
        expect(await store.btws('c1'), isEmpty);
        // The one still streaming ends with it.
        expect((await repo.getBtw('b2'))!.status, GaiaMessageStatus.cancelled);

        await store.restoreBtws(cleared);
        expect((await store.btws('c1')).map((b) => b.id), ['b1', 'b2']);
        // The one stopped as it was cleared is found too, now it's ended.
        expect(
          (await repo.searchMessages('tokenize')).map((hit) => hit.btwId),
          unorderedEquals(['b1', 'b2']),
        );
      },
    );

    test('a write to one cleared meanwhile is dropped', () async {
      final store = GaiaChatStore(repo, deviceId: 'laptop');
      await store.putBtw(btw('b1', status: GaiaMessageStatus.streaming));
      await store.clearBtws('c1');
      expect(await store.putBtw(btw('b1', answer: 'Late answer.')), isNull);
      expect((await repo.getBtw('b1'))!.isDeleted, isTrue);
    });

    test('versioned only by the writes that sync, not each streaming save, '
        "so another device's clear isn't outranked", () async {
      final store = GaiaChatStore(repo, deviceId: 'laptop');
      await store.putBtw(btw('b1', status: GaiaMessageStatus.streaming));
      for (final answer in ['A', 'An', 'Ans']) {
        await store.putBtw(
          btw('b1', answer: answer, status: GaiaMessageStatus.streaming),
        );
      }
      expect((await repo.getBtw('b1'))!.version, 1);
      await store.putBtw(btw('b1', answer: 'Answer.'));
      expect((await repo.getBtw('b1'))!.version, 2);
    });

    test(
      "a companion's restart ends this device's streaming ones only",
      () async {
        final store = GaiaChatStore(repo, deviceId: 'laptop');
        await repo.upsertBtw(btw('mine', status: GaiaMessageStatus.streaming));
        await repo.upsertBtw(
          btw(
            'theirs',
            status: GaiaMessageStatus.streaming,
            deviceId: 'desktop',
          ),
        );
        await store.endStreaming(GaiaMessageStatus.interrupted);
        expect(
          (await repo.getBtw('mine'))!.status,
          GaiaMessageStatus.interrupted,
        );
        expect(
          (await repo.getBtw('theirs'))!.status,
          GaiaMessageStatus.streaming,
        );
      },
    );

    test('a cut keeps whole characters within the bytes, and the error is '
        'cut too', () {
      const text = 'aé€😀b';
      for (var bytes = 0; bytes <= 11; bytes++) {
        final cut = gaiaCutToBytes(text, bytes);
        expect(text.startsWith(cut), isTrue);
        expect(utf8.encode(cut).length, lessThanOrEqualTo(bytes));
        // Nothing more would fit.
        if (cut != text) {
          final next = text.substring(cut.length).runes.first;
          expect(
            utf8.encode(cut + String.fromCharCode(next)).length,
            greaterThan(bytes),
          );
        }
      }
      final payload = gaiaBtwToFirestore(
        btw('b1').copyWith(error: 'x' * (gaiaBtwErrorBytes + 10)),
      );
      expect((payload['error'] as String).length, gaiaBtwErrorBytes);
    });

    test('the synced copy round-trips, its answer cut to fit', () {
      final long = btw('b1', answer: 'é' * (gaiaMessageChunkBytes ~/ 2 + 10))
          .copyWith(
            session: const GaiaBtwSession(sessionKey: 'k', sessionId: 's1'),
          );
      final payload = gaiaBtwToFirestore(long);
      expect((payload['answer'] as String).length, gaiaMessageChunkBytes ~/ 2);
      final back = mergeGaiaBtwFromRemote(payload, 'b1');
      expect(back.question, long.question);
      expect(back.anchorSeq, 1);
      expect(back.deviceId, 'laptop');
      expect(back.session?.sessionKey, 'k');
      expect(back.session?.sessionId, 's1');
      expect(GaiaBtw.fromJson(long.toJson()).session?.sessionId, 's1');
      // The device that has all of it keeps all of it.
      final kept = mergeGaiaBtwFromRemote(
        {...payload, 'version': long.version + 1},
        'b1',
        local: long,
      );
      expect(kept.answer, long.answer);
    });
  });

  group('the companion', () {
    late MemoryFileSystem fs;
    late FakeGaiaPipe pipe;
    late FakeClaudeRunner runner;
    late FakeGaiaWindow window;
    late GaiaController controller;
    late AppDatabase db;
    late DriftGaiaRepository repo;
    late List<(String, String, String?)> notified;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftGaiaRepository(db);
      fs = MemoryFileSystem();
      notified = [];
      pipe = FakeGaiaPipe.main();
      pipe.onLaunch = (end, _) {
        runner = FakeClaudeRunner();
        window = FakeGaiaWindow();
        controller = GaiaController(
          pipe: end,
          window: window,
          runners: {kGaiaClaudeCodeAdapter: runner},
          cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
          exit: (_) {},
        );
        controller.start();
      };
    });
    tearDown(() => db.close());

    List<ClaudeEvent> reply(String text) => [
      const ClaudeTextStart(),
      ClaudeTextDelta(text),
      ClaudeResult(sessionId: 's-$text', isError: false, text: text),
    ];

    void run(void Function(FakeAsync async) body) {
      fakeAsync((async) {
        final host = GaiaHost(
          pipe: pipe,
          abortFlag: () async => fs.file('gaia_aborted'),
          killCompanion: (_) async {},
        );
        host.start(registerHotkeys: false, show: false);
        host.attach(
          repository: repo,
          deviceId: 'laptop',
          toast: (chatId, title, _, {btwId}) =>
              notified.add((chatId, title, btwId)),
        );
        async.flushMicrotasks();
        host.onHotkey(GaiaHotkey.window);
        async.elapse(Duration.zero);
        body(async);
      });
    }

    test('asked idle: its own tool-less run on the chat so far, kept apart '
        'from the chat', () {
      run((async) {
        runner.turns.add(reply('Hello there'));
        controller.send('Hi');
        async.flushMicrotasks();
        final chatId = controller.currentChatId!;
        final opened = <String?>[];
        controller.btwOpens.listen(opened.add);

        runner.turns.add(reply('It said hello.'));
        controller.send('/btw what did you say?');
        async.elapse(const Duration(seconds: 1));

        final sent = runner.sent.last;
        expect(sent.chatId, startsWith('btw:'));
        expect(sent.toolless, isTrue);
        expect(sent.sessionId, isNull);
        expect(sent.prompt, contains('<gaia_transcript>'));
        expect(sent.prompt, contains('Hello there'));
        expect(sent.prompt, endsWith('what did you say?'));
        final asked = controller.btwsFor(chatId).single;
        expect(sent.chatId, 'btw:${asked.id}');
        expect(opened, [asked.id]);
        expect(asked.status, GaiaMessageStatus.complete);
        expect(asked.answer, 'It said hello.');
        expect(asked.anchorSeq, 1);
        // Never one of the chat's messages.
        expect(controller.messages.map((m) => m.text), ['Hi', 'Hello there']);

        // The next asks with it as history; the chat's next turn knows
        // nothing of either.
        runner.turns.add(reply('Twice.'));
        controller.send('/btw and again?');
        async.elapse(const Duration(seconds: 1));
        expect(
          runner.sent.last.prompt,
          contains('Q: what did you say?\nA: It said hello.'),
        );
        runner.turns.add(reply('Sure'));
        controller.send('Next');
        async.elapse(const Duration(seconds: 1));
        expect(runner.sent.last.chatId, chatId);
        expect(runner.sent.last.prompt, isNot(contains('what did you say')));
        expect(controller.btwsFor(chatId), hasLength(2));
      });
    });

    test(
      'asked mid-reply: the reply goes on; neither stop reaches the other',
      () {
        run((async) {
          runner.turns.add(reply('First'));
          controller.send('Hi');
          async.flushMicrotasks();
          final chatId = controller.currentChatId!;
          // A reply that hangs, mid-stream.
          runner.turns.add([
            const ClaudeTextStart(),
            const ClaudeTextDelta('Working on it'),
          ]);
          controller.send('Do the thing');
          async.flushMicrotasks();
          expect(controller.isRunning(chatId), isTrue);

          // So does the btw's.
          runner.turns.add([
            const ClaudeTextStart(),
            const ClaudeTextDelta('Partly'),
          ]);
          controller.send('/btw what is it doing?');
          async.flushMicrotasks();
          final asked = controller.btwsFor(chatId).single;
          final prompt = runner.sent.last.prompt;
          expect(prompt, contains('User:\nDo the thing'));
          expect(prompt, contains('Assistant (in progress):\nWorking on it'));
          expect(
            asked.anchorSeq,
            1,
            reason: 'before the prompt being answered',
          );
          expect(controller.isRunning(chatId), isTrue);

          controller.stopBtw(asked.id);
          async.flushMicrotasks();
          expect(runner.stopped, ['btw:${asked.id}']);
          expect(controller.isRunning(chatId), isTrue);
          final stopped = controller.btwsFor(chatId).single;
          expect(stopped.status, GaiaMessageStatus.cancelled);
          expect(stopped.answer, 'Partly');
          // Never taken back: the runner lets go of it once it's ended.
          expect(runner.forgotten, ['btw:${asked.id}']);

          runner.turns.add([const ClaudeTextStart()]);
          controller.send('/btw another?');
          async.flushMicrotasks();
          controller.stop(chatId);
          async.flushMicrotasks();
          expect(runner.stopped.last, chatId);
          expect(
            controller.btwsFor(chatId).last.status,
            GaiaMessageStatus.streaming,
          );
        });
      },
    );

    test('aborted mid-answer: kept as aborted, not as an error', () {
      run((async) {
        runner.turns.add(reply('Hello'));
        controller.send('Hi');
        async.flushMicrotasks();
        final chatId = controller.currentChatId!;
        runner.turns.add([
          const ClaudeTextStart(),
          const ClaudeTextDelta('Partly'),
        ]);
        controller.send('/btw what is it?');
        async.flushMicrotasks();

        pipe.request('abort');
        async.elapse(const Duration(seconds: 1));
        final aborted = controller.btwsFor(chatId).single;
        expect(aborted.status, GaiaMessageStatus.aborted);
        expect(aborted.error, isNull);
        expect(aborted.answer, 'Partly');
      });
    });

    test('clearing takes them all, and Undo brings them back', () {
      run((async) {
        runner.turns.add(reply('Hello'));
        controller.send('Hi');
        async.flushMicrotasks();
        final chatId = controller.currentChatId!;
        runner.turns
          ..add(reply('One'))
          ..add(reply('Two'));
        controller.send('/btw one?');
        async.elapse(const Duration(seconds: 1));
        controller.send('/btw two?');
        async.elapse(const Duration(seconds: 1));
        expect(controller.btwsFor(chatId), hasLength(2));

        List<String>? ids;
        controller.clearBtws().then((cleared) => ids = cleared);
        async.flushMicrotasks();
        expect(controller.btwsFor(chatId), isEmpty);
        controller.restoreBtws(chatId, ids!);
        async.flushMicrotasks();
        expect(controller.btwsFor(chatId).map((b) => b.question), [
          'one?',
          'two?',
        ]);
      });
    });

    test('forked: a new chat of the chat to its anchor, then the btw, '
        "carrying on in a fork of the btw's own session", () {
      run((async) {
        runner.turns.add(reply('Hello'));
        controller.send('Hi');
        async.flushMicrotasks();
        final source = controller.currentChat!;
        final key = source.agentSessions.keys.single;
        runner.turns.add(reply('Because.'));
        controller.send('/btw why?');
        async.elapse(const Duration(seconds: 1));
        runner.turns.add(reply('Later'));
        controller.send('After the btw');
        async.elapse(const Duration(seconds: 1));

        final asked = controller.btwsFor(source.id).single;
        expect(asked.session?.sessionKey, key);
        runner.cutAt = 'btw-end';
        controller.forkBtw(asked);
        async.flushMicrotasks();
        final fork = controller.currentChat!;
        expect(fork.id, isNot(source.id));
        expect(fork.title, '${source.title} (btw)');
        expect(fork.forkOf, source.id);
        expect(runner.cutsAsked.last.sessionId, 's-Because.');
        expect(runner.cutsAsked.last.after, asked.id);
        expect(fork.agentSessions, isEmpty);
        expect(fork.fork?.sessionKey, key);
        expect(fork.fork?.sourceSessionId, 's-Because.');
        expect(fork.fork?.keepAt, 'btw-end');
        expect(fork.fork?.lastSeq, 3);
        expect(controller.messages.map((m) => (m.seq, m.role, m.text)), [
          (0, GaiaMessageRole.user, 'Hi'),
          (1, GaiaMessageRole.assistant, 'Hello'),
          (2, GaiaMessageRole.user, 'why?'),
          (3, GaiaMessageRole.assistant, 'Because.'),
        ]);
        expect(
          controller.messages.take(2).map((m) => m.origin),
          everyElement(isNotNull),
        );
        expect(controller.btwsFor(fork.id), isEmpty);

        // Its first send forks the btw's session, with the chat's tools, so
        // a second fork of the btw doesn't share it.
        runner.turns.add(reply('Go on'));
        controller.send('Go on');
        async.elapse(const Duration(seconds: 1));
        expect(runner.forks.last?.sessionId, 's-Because.');
        expect(runner.forks.last?.keepAt, 'btw-end');
        expect(runner.sent.last.prompt, 'Go on');
        expect(runner.sent.last.toolless, isFalse);
      });
    });

    test('in dummy mode it plays the dummy script, with no provider run', () {
      run((async) {
        runner.turns.add(reply('Hello'));
        controller.send('Hi');
        async.flushMicrotasks();
        final chatId = controller.currentChatId!;
        final sent = runner.sent.length;
        controller.debug
          ..dummyMode = true
          // Its pace is by a real Stopwatch: all of it due at once.
          ..streamSpeed = 1 << 40;
        controller.send('/btw why?');
        async.elapse(const Duration(seconds: 30));
        expect(runner.sent, hasLength(sent));
        final asked = controller.btwsFor(chatId).single;
        expect(asked.status, GaiaMessageStatus.complete);
        expect(asked.answer, startsWith('Dummy reply'));
        expect(asked.session, isNull);
      });
    });

    test('answered or failed, it raises a toast that opens it; stopped or '
        'in view, none; behind other apps, the Windows one', () {
      run((async) {
        final toasts = <({GaiaRunToast toast, String btwId})>[];
        controller.btwToasts.listen(toasts.add);
        runner.turns.add(reply('Hello'));
        controller.send('Hi');
        async.flushMicrotasks();
        final chatId = controller.currentChatId!;

        runner.turns.add(reply('Because.'));
        controller.send('/btw why?');
        async.elapse(const Duration(seconds: 1));
        final answered = controller.btwsFor(chatId).single;
        expect(toasts.single.btwId, answered.id);
        expect(toasts.single.toast.chatId, chatId);
        expect(toasts.single.toast.title, 'Side question answered');
        expect(toasts.single.toast.body, endsWith('why?'));
        expect(toasts.single.toast.error, isFalse);

        runner.turns.add([
          const ClaudeTextStart(),
          const ClaudeTextDelta('Partly'),
          const ClaudeResult(sessionId: 's-x', isError: true, text: 'boom'),
        ]);
        controller.send('/btw and?');
        async.elapse(const Duration(seconds: 1));
        expect(toasts, hasLength(2));
        expect(toasts.last.toast.title, 'Side question failed');
        expect(toasts.last.toast.error, isTrue);

        // Stopped: none.
        runner.turns.add([const ClaudeTextStart()]);
        controller.send('/btw stop me?');
        async.flushMicrotasks();
        controller.stopBtw(controller.btwsFor(chatId).last.id);
        async.elapse(const Duration(seconds: 1));
        expect(toasts, hasLength(2));

        // Behind other apps: the Windows one, which opens it too.
        window.behind = true;
        runner.turns.add(reply('Away.'));
        controller.send('/btw elsewhere?');
        async.elapse(const Duration(seconds: 1));
        expect(toasts, hasLength(2));
        final away = controller.btwsFor(chatId).last;
        expect(notified.last, (chatId, 'Side question answered', away.id));

        // In front, shown in the panel as it's answered: none.
        window.behind = false;
        controller.btwOpens.listen((id) => controller.btwShown = id);
        runner.turns.add(reply('Seen.'));
        controller.send('/btw watched?');
        async.elapse(const Duration(seconds: 1));
        expect(controller.btwsFor(chatId).last.answer, 'Seen.');
        expect(toasts, hasLength(2));
      });
    });

    test('a failed one forks as a handoff: its question, then its partial '
        'answer as a failed reply', () {
      run((async) {
        runner.turns.add(reply('Hello'));
        controller.send('Hi');
        async.flushMicrotasks();
        final source = controller.currentChat!;
        runner.turns.add([
          const ClaudeTextStart(),
          const ClaudeTextDelta('Partly'),
          const ClaudeResult(sessionId: 's-x', isError: true, text: 'boom'),
        ]);
        controller.send('/btw why?');
        async.elapse(const Duration(seconds: 1));
        final failed = controller.btwsFor(source.id).single;
        expect(failed.status, GaiaMessageStatus.error);

        controller.forkBtw(failed);
        async.flushMicrotasks();
        final fork = controller.currentChat!;
        expect(fork.id, isNot(source.id));
        expect(fork.agentSessions, isEmpty);
        expect(
          controller.messages.map((m) => (m.seq, m.role, m.text, m.status)),
          [
            (0, GaiaMessageRole.user, 'Hi', GaiaMessageStatus.complete),
            (1, GaiaMessageRole.assistant, 'Hello', GaiaMessageStatus.complete),
            (2, GaiaMessageRole.user, 'why?', GaiaMessageStatus.complete),
            (3, GaiaMessageRole.assistant, 'Partly', GaiaMessageStatus.error),
          ],
        );
        expect(controller.messages.last.error, failed.error);
      });
    });
  });

  group('the debug preview', () {
    late FakeGaiaPipe pipe;
    late FakeClaudeRunner runner;
    late GaiaController controller;
    late AppDatabase db;
    late DriftGaiaRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftGaiaRepository(db);
      pipe = FakeGaiaPipe.main();
      pipe.onLaunch = (end, _) {
        runner = FakeClaudeRunner();
        controller = GaiaController(
          pipe: end,
          window: FakeGaiaWindow(),
          runners: {kGaiaClaudeCodeAdapter: runner},
          cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
          exit: (_) {},
        );
        controller.start();
      };
    });
    tearDown(() => db.close());

    test('made-up ones of each kind, streaming here and stoppable; nothing '
        'stored, cleared or forked', () {
      fakeAsync((async) {
        final host = GaiaHost(
          pipe: pipe,
          abortFlag: () async => MemoryFileSystem().file('gaia_aborted'),
          killCompanion: (_) async {},
        );
        host.start(registerHotkeys: false, show: false);
        host.attach(
          repository: repo,
          deviceId: 'laptop',
          toast: (_, _, _, {btwId}) {},
        );
        async.flushMicrotasks();
        host.onHotkey(GaiaHotkey.window);
        async.elapse(Duration.zero);

        runner.turns
          ..add([
            const ClaudeTextStart(),
            const ClaudeTextDelta('Hello'),
            const ClaudeResult(sessionId: 's1', isError: false, text: 'Hello'),
          ])
          ..add([
            const ClaudeTextStart(),
            const ClaudeTextDelta('Real.'),
            const ClaudeResult(sessionId: 's2', isError: false, text: 'Real.'),
          ]);
        controller.send('Hi');
        async.flushMicrotasks();
        final chatId = controller.currentChatId!;
        controller.send('/btw a real one?');
        async.elapse(const Duration(seconds: 1));
        final opened = <String?>[];
        controller.btwOpens.listen(opened.add);
        final sends = runner.sent.length;

        controller.previewBtws();
        async.elapse(const Duration(milliseconds: 500));
        final shown = controller.btwsFor(chatId);
        expect(shown.map((b) => b.status), [
          GaiaMessageStatus.complete,
          GaiaMessageStatus.complete,
          GaiaMessageStatus.error,
          GaiaMessageStatus.cancelled,
          GaiaMessageStatus.streaming,
          GaiaMessageStatus.streaming,
        ]);
        final live = shown.last;
        expect(opened, [live.id]);
        expect(controller.btwRunning(live.id), isTrue);
        expect(live.answer, isNotEmpty, reason: 'it streams in');
        expect(controller.btwRunning(shown[4].id), isFalse);
        expect(shown[4].device, 'Laptop');

        controller.stopBtw(live.id);
        async.flushMicrotasks();
        expect(
          controller.btwsFor(chatId).last.status,
          GaiaMessageStatus.cancelled,
        );
        expect(runner.stopped, isEmpty);

        controller.forkBtw(shown.first);
        async.flushMicrotasks();
        expect(controller.currentChatId, chatId);

        List<String>? cleared;
        controller.clearBtws().then((ids) => cleared = ids);
        async.flushMicrotasks();
        expect(cleared, isEmpty);
        expect(controller.btwsFor(chatId), isEmpty);
        expect(runner.sent, hasLength(sends), reason: 'nothing ran');
        repo.listBtws(chatId: chatId).then((stored) {
          expect(stored.single.question, 'a real one?');
        });
        async.flushMicrotasks();

        // Undo reads the chat's own back.
        controller.restoreBtws(chatId, cleared!);
        async.flushMicrotasks();
        expect(controller.btwsFor(chatId).single.question, 'a real one?');
      });
    });
  });

  group('the companion, natively', () {
    late FakeGaiaPipe pipe;
    late FakeClaudeRunner runner;
    late GaiaController controller;
    late AppDatabase db;
    late DriftGaiaRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = DriftGaiaRepository(db);
      pipe = FakeGaiaPipe.main();
      pipe.onLaunch = (end, _) {
        runner = FakeClaudeRunner()..cutAt = 'cut-1';
        controller = GaiaController(
          pipe: end,
          window: FakeGaiaWindow(),
          runners: {kGaiaClaudeCodeAdapter: runner},
          cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
          exit: (_) {},
        );
        controller.start();
      };
    });
    tearDown(() => db.close());

    List<ClaudeEvent> reply(String text) => [
      const ClaudeTextStart(),
      ClaudeTextDelta(text),
      ClaudeResult(sessionId: 's-$text', isError: false, text: text),
    ];

    void run(void Function(FakeAsync async) body) {
      fakeAsync((async) {
        final host = GaiaHost(
          pipe: pipe,
          abortFlag: () async => MemoryFileSystem().file('gaia_aborted'),
          killCompanion: (_) async {},
        );
        host.start(registerHotkeys: false, show: false);
        host.attach(
          repository: repo,
          deviceId: 'laptop',
          toast: (_, _, _, {btwId}) {},
        );
        async.flushMicrotasks();
        host.onHotkey(GaiaHotkey.window);
        async.elapse(Duration.zero);
        body(async);
      });
    }

    test('idle: a tool-less fork of the chat\'s session at its end, with '
        'nothing handed over, and its own session kept', () {
      run((async) {
        runner.turns.add(reply('Hello there'));
        controller.send('Hi');
        async.flushMicrotasks();
        final chat = controller.currentChat!;
        final key = chat.agentSessions.keys.single;

        runner.turns.add(reply('It said hello.'));
        controller.send('/btw what did you say?');
        async.elapse(const Duration(seconds: 1));
        final cut = runner.cutsAsked.single;
        expect(cut.sessionId, 's-Hello there');
        expect(cut.after, controller.messages.first.id);
        expect(cut.next, isEmpty);
        expect(cut.awaiting, isNull);
        expect(runner.forks.last, (
          sessionId: 's-Hello there',
          keepAt: 'cut-1',
        ));
        final sent = runner.sent.last;
        expect(sent.chatId, startsWith('btw:'));
        expect(sent.toolless, isTrue);
        expect(sent.sessionId, isNull);
        expect(sent.prompt, isNot(contains('<gaia_transcript>')));
        expect(sent.prompt, endsWith('what did you say?'));
        final asked = controller.btwsFor(chat.id).single;
        expect(asked.status, GaiaMessageStatus.complete);
        expect(asked.error, isNull);
        expect(asked.session?.sessionKey, key);
        expect(asked.session?.sessionId, 's-It said hello.');
        // The chat's own session is untouched.
        expect(
          controller.currentChat!.agentSessions[key]!.sessionId,
          's-Hello there',
        );
      });
    });

    // Asks [first] then [second] in a chat that said Hello there, and gives
    // back the first's id.
    String twoAsked(FakeAsync async, {void Function()? between}) {
      runner.turns.add(reply('Hello there'));
      controller.send('Hi');
      async.flushMicrotasks();
      runner.turns.add(reply('It said hello.'));
      controller.send('/btw what did you say?');
      async.elapse(const Duration(seconds: 1));
      final first = controller.btwsFor(controller.currentChatId).single;
      between?.call();
      runner.turns.add(reply('Still hello.'));
      controller.send('/btw and again?');
      async.elapse(const Duration(seconds: 1));
      return first.id;
    }

    test('at the same anchor, the next carries on from the last one\'s own '
        'session, which has it as turns of its own: not told again', () {
      run((async) {
        final first = twoAsked(async);
        final cut = runner.cutsAsked.last;
        expect(cut.sessionId, 's-It said hello.');
        expect(cut.chatId, 'btw:$first');
        expect(cut.after, first, reason: "the first's prompt");
        expect(cut.next, isEmpty);
        expect(runner.forks.last, (
          sessionId: 's-It said hello.',
          keepAt: 'cut-1',
        ));
        final sent = runner.sent.last;
        expect(sent.toolless, isTrue);
        expect(sent.prompt, isNot(contains('Side questions asked')));
        expect(sent.prompt, isNot(contains('<gaia_transcript>')));
        expect(sent.prompt, endsWith('and again?'));
        final asked = controller.btwsFor(controller.currentChatId).last;
        expect(asked.status, GaiaMessageStatus.complete);
        expect(asked.session?.sessionId, 's-Still hello.');
      });
    });

    test("once the chat has moved on, the chat's session, told of them", () {
      run((async) {
        twoAsked(
          async,
          between: () {
            runner.turns.add(reply('Moved on'));
            controller.send('More');
            async.flushMicrotasks();
          },
        );
        expect(runner.cutsAsked.last.sessionId, isNot('s-It said hello.'));
        expect(runner.forks.last?.sessionId, isNot('s-It said hello.'));
        expect(
          runner.sent.last.prompt,
          contains('Q: what did you say?\nA: It said hello.'),
        );
      });
    });

    test("carrying on refused: the chat's session instead, told of them, "
        'with nothing said', () {
      run((async) {
        runner.cutFor = (session) =>
            session == 's-It said hello.' ? 'cut-btw' : null;
        runner.refusedCuts.add('cut-btw');
        twoAsked(async);
        expect(runner.forks.reversed.take(2), [
          (sessionId: 's-Hello there', keepAt: 'cut-1'),
          (sessionId: 's-It said hello.', keepAt: 'cut-btw'),
        ]);
        expect(
          runner.sent.last.prompt,
          contains('Q: what did you say?\nA: It said hello.'),
        );
        final asked = controller.btwsFor(controller.currentChatId).last;
        expect(asked.status, GaiaMessageStatus.complete);
        expect(asked.error, isNull);
      });
    });

    test('mid-reply: cut before the prompt being answered, which is waited '
        "for, and named in the btw's prompt", () {
      run((async) {
        runner.turns.add(reply('First'));
        controller.send('Hi');
        async.flushMicrotasks();
        final chatId = controller.currentChatId!;
        runner.turns.add([
          const ClaudeTextStart(),
          const ClaudeTextDelta('Working on it'),
        ]);
        controller.send('Do the thing');
        async.flushMicrotasks();
        final live = controller.messages.firstWhere(
          (m) => m.text == 'Do the thing',
        );

        runner.turns.add(reply('It is doing the thing.'));
        controller.send('/btw what is it doing?');
        async.elapse(const Duration(seconds: 1));
        final cut = runner.cutsAsked.single;
        expect(cut.sessionId, 's-First');
        expect(cut.next, [live.id]);
        expect(cut.awaiting, live.id);
        expect(controller.forkingAt, isNull, reason: 'no message is forked');
        expect(runner.forks.last?.keepAt, 'cut-1');
        final prompt = runner.sent.last.prompt;
        expect(prompt, isNot(contains('<gaia_transcript>')));
        expect(prompt, contains('User:\nDo the thing'));
        expect(prompt, contains('Assistant (in progress):\nWorking on it'));
        expect(controller.btwsFor(chatId).single.anchorSeq, 1);
        expect(controller.isRunning(chatId), isTrue);
      });
    });

    test('a refused fork is asked again by handoff, with nothing said', () {
      run((async) {
        runner.turns.add(reply('Hello'));
        controller.send('Hi');
        async.flushMicrotasks();
        final chatId = controller.currentChatId!;
        runner.refusedCuts.add('cut-1');

        runner.turns.add(reply('Hi was said.'));
        controller.send('/btw what was said?');
        async.elapse(const Duration(seconds: 1));
        expect(runner.forks.reversed.take(2), [
          null,
          (sessionId: 's-Hello', keepAt: 'cut-1'),
        ]);
        expect(runner.sent.last.prompt, contains('<gaia_transcript>'));
        expect(runner.sent.last.prompt, contains('Hello'));
        final asked = controller.btwsFor(chatId).single;
        expect(asked.status, GaiaMessageStatus.complete);
        expect(asked.answer, 'Hi was said.');
        expect(asked.error, isNull);
      });
    });

    test("a fork that didn't hold: said beside the answer, and forking it "
        'hands the chat over', () {
      run((async) {
        runner.turns.add(reply('Hello'));
        controller.send('Hi');
        async.flushMicrotasks();
        final source = controller.currentChat!;
        runner
          ..notice = 'Cut elsewhere.'
          ..turns.add(reply('Because.'));
        controller.send('/btw why?');
        async.elapse(const Duration(seconds: 1));
        final asked = controller.btwsFor(source.id).single;
        expect(asked.status, GaiaMessageStatus.complete);
        expect(asked.error, contains('may know more of the chat'));
        expect(asked.session, isNull);

        controller.forkBtw(asked);
        async.flushMicrotasks();
        final fork = controller.currentChat!;
        expect(fork.id, isNot(source.id));
        expect(fork.agentSessions, isEmpty);
        runner.turns.add(reply('Go on'));
        controller.send('Go on');
        async.elapse(const Duration(seconds: 1));
        expect(runner.sent.last.sessionId, isNull);
        expect(runner.sent.last.prompt, contains('Because.'));
      });
    });
  });
}
