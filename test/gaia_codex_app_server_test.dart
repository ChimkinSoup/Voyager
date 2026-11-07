import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_app_server.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// Contract tests for the Codex `app-server` adapter (GAIA_HLD.md §5.1):
/// every fixture is real `codex app-server` output recorded from codex-cli
/// 0.166.0 by test/gaia_codex_contract_test.dart, replayed through
/// [CodexAppServerClient] in the order it came.

/// Answers every question with its last option, and denies every
/// permission, recording each.
class _Tools implements GaiaTurnTools {
  final asked = <Map<String, Object?>>[];
  final permits = <({String tool, Map<String, Object?> input})>[];

  @override
  Future<GaiaToolResult> call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    asked.add(arguments);
    final options = (arguments['options'] as List?) ?? const [];
    return GaiaToolResult(
      text: 'The user chose: "${(options.last as Map)['label']}".',
      isError: false,
    );
  }

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) async {
    permits.add((tool: tool, input: input));
    return (allow: false, message: 'The user declined.');
  }
}

class _Replay {
  _Replay(String fixture)
    : _lines = [
        for (final line in File(
          'test/fixtures/gaia/codex_app_server/$fixture',
        ).readAsLinesSync())
          if (line.trim().isNotEmpty) line,
      ];

  final List<String> _lines;
  var _next = 0;
  final sent = <Map<String, Object?>>[];
  late final client = CodexAppServerClient(
    (line) => sent.add((jsonDecode(line) as Map).cast()),
  );

  /// Feeds the server's lines, [count] of them or the rest, letting the
  /// client answer each before the next.
  Future<void> feed([int? count]) async {
    final end = count == null ? _lines.length : _next + count;
    while (_next < end) {
      client.onLine(_lines[_next++]);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  /// Feeds lines until one has [method].
  Future<void> feedThrough(String method) async {
    while ((jsonDecode(_lines[_next]) as Map)['method'] != method) {
      await feed(1);
    }
    await feed(1);
  }

  Map<String, Object?> sentFor(String method) =>
      sent.firstWhere((message) => message['method'] == method);

  Map<String, Object?> answerTo(int id) => sent.firstWhere(
    (message) => message['id'] == id && !message.containsKey('method'),
  );
}

const _thread = '01a19d70-293d-74a1-85eb-e4936b7fe8cd';

List<Map<String, Object?>> _text(String text) => [
  {'type': 'text', 'text': text},
];

List<Map<String, Object?>> _parts(List<GaiaAgentEvent> events) {
  final builder = GaiaTurnBuilder();
  events.forEach(builder.apply);
  return [for (final part in builder.finished) part.toJson()];
}

void main() {
  test('every fixture line parses', () {
    for (final file in Directory(
      'test/fixtures/gaia/codex_app_server',
    ).listSync()) {
      final client = CodexAppServerClient((_) {});
      for (final line in File(file.path).readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        expect(() => client.onLine(line), returnsNormally, reason: file.path);
      }
    }
  });

  test('a new thread with Gaia tools: ask_user and a declined command in '
      'one streamed turn, then a second turn on the same process', () async {
    final replay = _Replay('tools.jsonl');
    final tools = _Tools();
    String? newThread;
    final events = <GaiaAgentEvent>[];
    final again = <GaiaAgentEvent>[];
    unawaited(replay.client.initialize());
    final first = replay.client.send(
      threadId: null,
      model: 'gpt-6.1-sol',
      input: _text('Ask my favourite colour, then make a file.'),
      tools: tools,
      onEvent: events.add,
      onNewThread: (id) async => newThread = id,
      instructions: '# Memories',
    );
    late Future<GaiaTurnResult> second;
    final started = first.then((_) {
      second = replay.client.send(
        threadId: _thread,
        model: 'gpt-6.1-sol',
        input: _text('Reply with exactly these words: gaia contract ok'),
        tools: tools,
        onEvent: again.add,
      );
    });
    await replay.feed();
    await started;

    final start = replay.sentFor('thread/start')['params']! as Map;
    expect(start['approvalPolicy'], 'on-request');
    expect(start['developerInstructions'], '# Memories');
    expect(
      [
        for (final tool in start['dynamicTools']! as List)
          (tool as Map)['name'],
      ],
      [for (final tool in kGaiaToolDefinitions) tool['name']],
    );
    expect(newThread, _thread);

    expect(tools.asked.single['question'], isNotEmpty);
    expect(replay.answerTo(0)['result'], {
      'contentItems': [
        {'type': 'inputText', 'text': 'The user chose: "Blue".'},
      ],
      'success': true,
    });
    expect(tools.permits.single.tool, 'Shell');
    expect(tools.permits.single.input['command'], contains('gaia-probe.txt'));
    expect(replay.answerTo(1)['result'], {'decision': 'decline'});

    final result = await first;
    expect(result.isError, isFalse);
    expect(result.sessionId, _thread);
    expect(result.contextTokens, isNotNull);
    expect(result.contextWindow, isNotNull);
    expect(events.whereType<GaiaTextDelta>().length, greaterThan(2));
    expect(_parts(events), [
      {
        'type': 'text',
        'text': 'I’ll ask your favourite colour, then create the file.',
      },
      {
        'type': 'activity',
        'tools': ['ask_user', 'Shell'],
        // The command without the shell wrapping it.
        'details': [
          '{"question":"What is your favourite colour?","options":'
              '[{"label":"Red"},{"label":"Blue"}]}',
          'Set-Content -LiteralPath gaia-probe.txt -Value hi -NoNewline',
        ],
        // The recorded command was declined.
        'failures': [null, 'Declined'],
      },
      {
        'type': 'text',
        'text':
            'You chose Blue. File creation was rejected, so gaia-probe.txt '
            'wasn’t created.',
      },
    ]);

    // The command showed as it started, before its approval, with what it
    // runs; its decline came when it completed.
    final shell = events.indexWhere(
      (e) => e is GaiaToolUse && e.name == 'Shell',
    );
    final use = events[shell] as GaiaToolUse;
    expect(use.id, isNotNull);
    expect(use.detail, contains('gaia-probe.txt'));
    expect(use.failure, isNull);
    final declined = events.indexWhere(
      (e) => e is GaiaToolFailures && e.failures[use.id] == 'Declined',
    );
    expect(declined, greaterThan(shell));

    // Loaded already: no resume.
    expect(replay.sent.where((m) => m['method'] == 'thread/resume'), isEmpty);
    final secondResult = await second;
    expect(secondResult.isError, isFalse);
    expect(_parts(again), [
      {'type': 'text', 'text': 'gaia contract ok'},
    ]);
  });

  test('a thread this process never loaded is resumed first', () async {
    final replay = _Replay('resume.jsonl');
    final events = <GaiaAgentEvent>[];
    unawaited(replay.client.initialize());
    final turn = replay.client.send(
      threadId: _thread,
      model: 'gpt-6.1-sol',
      input: _text('What colour did I choose earlier?'),
      tools: _Tools(),
      onEvent: events.add,
      instructions: '# Memories',
    );
    await replay.feed();
    final resume = replay.sentFor('thread/resume')['params']! as Map;
    expect(resume['threadId'], _thread);
    // The thread keeps those it started with (§11).
    expect(resume.containsKey('developerInstructions'), isFalse);
    final result = await turn;
    expect(result.isError, isFalse);
    expect(result.sessionFound, isTrue);
    expect(result.text, 'Blue');
  });

  test('an unknown model fails the turn with the API error', () async {
    final replay = _Replay('unknown_model.jsonl');
    unawaited(replay.client.initialize());
    final turn = replay.client.send(
      threadId: null,
      model: 'not-a-model',
      input: _text('Hi'),
      tools: null,
      onEvent: (_) {},
    );
    await replay.feed();
    final result = await turn;
    expect(result.isError, isTrue);
    expect(
      result.text,
      "The 'not-a-model' model is not supported when using Codex with a "
      'ChatGPT account.',
    );
  });

  test('a thread Codex has no record of is not found', () async {
    final replay = _Replay('missing_thread.jsonl');
    unawaited(replay.client.initialize());
    final turn = replay.client.send(
      threadId: '019a0000-0000-7000-8000-000000000000',
      model: 'gpt-6.1-sol',
      input: _text('Hi'),
      tools: null,
      onEvent: (_) {},
    );
    await replay.feed();
    final result = await turn;
    expect(result.sessionFound, isFalse);
    expect(result.isError, isTrue);
    expect(result.text, contains('no rollout found'));
  });

  test('a resume that fails for another reason keeps the thread', () async {
    final client = CodexAppServerClient((_) {});
    unawaited(client.initialize());
    client.onLine('{"id":1,"result":{}}');
    final turn = client.send(
      threadId: _thread,
      model: 'gpt-6.1-sol',
      input: _text('Hi'),
      tools: null,
      onEvent: (_) {},
    );
    client.onLine(
      '{"error":{"code":-32603,"message":"token refresh failed"},"id":2}',
    );
    final result = await turn;
    expect(result.sessionFound, isTrue);
    expect(result.isError, isTrue);
    expect(result.sessionId, _thread);
  });

  test("a fork missing the thread its history starts in isn't found", () async {
    final client = CodexAppServerClient((_) {});
    unawaited(client.initialize());
    client.onLine('{"id":1,"result":{}}');
    final turn = client.send(
      threadId: _thread,
      model: 'gpt-6.1-sol',
      input: _text('Hi'),
      tools: null,
      onEvent: (_) {},
    );
    // Recorded on 0.166.0, resuming a fork copied without its source.
    client.onLine(
      '{"error":{"code":-32600,"message":"invalid paginated history lineage '
      'for 01a1b478-ad81-7853-ab88-82456a25ee9c: missing source rollout"},'
      '"id":2}',
    );
    final result = await turn;
    expect(result.sessionFound, isFalse);
    expect(result.isError, isTrue);
  });

  group('forking (GAIA_REWIND_HLD.md §10.2)', () {
    const source = '01a1b47e-2000-7000-8000-000000000000';
    const cut = '01a1b47e-273d-70d2-94a6-b5e3e950cea3';
    const forked = '01a1b47e-45a1-7571-beb4-e247817dc7bf';

    test("a prompt's turn is found by the id it was sent with", () async {
      for (final (id, turn) in [('gaia-fork-p1', cut), ('gaia-none', null)]) {
        final replay = _Replay('turns.jsonl');
        unawaited(replay.client.initialize());
        final found = replay.client.turnOf(source, id);
        await replay.feed();
        expect(await found, turn, reason: id);
        expect(replay.sentFor('thread/turns/list')['params'], {
          'threadId': source,
          'sortDirection': 'desc',
        });
      }
    });

    test('newest first, read until the last turn with the id', () async {
      final client = CodexAppServerClient((_) {});
      final found = client.turnOf(source, 'p');
      String page(int id, List<String> turns, String? next) => jsonEncode({
        'id': id,
        'result': {
          'data': [
            for (final turn in turns)
              {
                'id': turn,
                'items': [
                  {'type': 'userMessage', 'clientId': turn.split('-').first},
                ],
              },
          ],
          'nextCursor': next,
        },
      });
      client.onLine(page(1, ['r-4', 'q-3'], 'more'));
      await Future<void>.delayed(Duration.zero);
      // Not read past: a third page is never answered.
      client.onLine(page(2, ['p-2', 'p-1'], 'more'));
      expect(await found, 'p-2');
    });

    test("a fork's first turn forks the source kept to the cut, names its "
        'prompt, and runs on the new thread', () async {
      final replay = _Replay('fork.jsonl');
      String? newThread;
      final events = <GaiaAgentEvent>[];
      unawaited(replay.client.initialize());
      final turn = replay.client.send(
        threadId: null,
        model: 'gpt-6.1-sol',
        input: _text('What colour did I choose earlier?'),
        tools: _Tools(),
        onEvent: events.add,
        instructions: '# Memories',
        clientId: 'gaia-fork-p3',
        fork: (sessionId: source, keepAt: cut),
        onNewThread: (id) async => newThread = id,
      );
      await replay.feed();
      expect(replay.sentFor('thread/fork')['params'], {
        'threadId': source,
        'lastTurnId': cut,
        'model': 'gpt-6.1-sol',
        'approvalPolicy': 'on-request',
        'excludeTurns': true,
      });
      expect(replay.sent.where((m) => m['method'] == 'thread/start'), isEmpty);
      final start = replay.sentFor('turn/start')['params']! as Map;
      expect(start['threadId'], forked);
      expect(start['clientUserMessageId'], 'gaia-fork-p3');
      expect(newThread, forked);
      final result = await turn;
      expect(result.isError, isFalse);
      expect(result.sessionId, forked);
      expect(result.text, 'Blue, NONE');
    });

    test(
      'a fork Codex refuses is not found, so the chat is handed over',
      () async {
        final client = CodexAppServerClient((_) {});
        unawaited(client.initialize());
        client.onLine('{"id":1,"result":{}}');
        final turn = client.send(
          threadId: null,
          model: 'gpt-6.1-sol',
          input: _text('Hi'),
          tools: null,
          onEvent: (_) {},
          fork: (sessionId: source, keepAt: cut),
        );
        client.onLine(
          '{"error":{"code":-32600,"message":"turn not found"},"id":2}',
        );
        final result = await turn;
        expect(result.sessionFound, isFalse);
        expect(result.sessionId, source);
      },
    );

    test('a fork of a thread started with other tools is handed over '
        'without starting Codex', () async {
      final root = Directory.systemTemp.createTempSync('gaia_codex_fork_');
      addTearDown(() => root.deleteSync(recursive: true));
      final home = p.join(root.path, 'home');
      Directory(home).createSync();
      File(
        p.join(home, 'gaia-threads.json'),
      ).writeAsStringSync(jsonEncode({'old': 'another-hash'}));
      final runner = CodexAppServerRunner(
        workingDirectory: p.join(root.path, 'ws'),
        codexHome: home,
        userCodexHome: p.join(root.path, 'user'),
        fallback: CodexRunner(
          workingDirectory: p.join(root.path, 'ws'),
          codexHome: home,
        ),
      );
      final result = await runner.send(
        chatId: 'chat',
        sessionId: null,
        model: 'gpt-6.1-sol',
        prompt: 'Hi',
        fork: (sessionId: 'old', keepAt: cut),
        onEvent: (_) {},
      );
      expect(result.sessionFound, isFalse);
      expect(result.sessionId, 'old');
    });

    test('a forked thread copied to another home takes the thread its '
        "history starts in, but doesn't overwrite one there", () async {
      final root = Directory.systemTemp.createTempSync('gaia_codex_copy_');
      addTearDown(() => root.deleteSync(recursive: true));
      CodexAppServerRunner runner(String home) => CodexAppServerRunner(
        workingDirectory: p.join(root.path, 'ws'),
        codexHome: p.join(root.path, home),
        userCodexHome: p.join(root.path, 'user'),
        fallback: CodexRunner(
          workingDirectory: p.join(root.path, 'ws'),
          codexHome: p.join(root.path, home),
        ),
      );
      File rollout(String home, String thread) => File(
        p.join(
          root.path,
          home,
          'sessions',
          '2026',
          '11',
          '07',
          'rollout-2026-11-07T00-00-00-$thread.jsonl',
        ),
      );
      String meta(String thread, [String? base]) => jsonEncode({
        'type': 'session_meta',
        'payload': {
          'id': thread,
          'history_base': ?(base == null ? null : {'thread_id': base}),
        },
      });
      rollout('from', 'root')
        ..createSync(recursive: true)
        ..writeAsStringSync('${meta('root')}\n');
      rollout(
        'from',
        'middle',
      ).writeAsStringSync('${meta('middle', 'root')}\n');
      rollout('from', 'leaf').writeAsStringSync('${meta('leaf', 'middle')}\n');
      // Followed here earlier, with a turn since.
      rollout('to', 'middle')
        ..createSync(recursive: true)
        ..writeAsStringSync('${meta('middle', 'root')}\n{"later":1}\n');

      expect(await runner('to').copyThreadFrom(runner('from'), 'leaf'), isTrue);
      expect(rollout('to', 'leaf').existsSync(), isTrue);
      expect(rollout('to', 'middle').readAsStringSync(), contains('later'));
      // Kept rather than followed: its own base was never copied here.
      expect(rollout('to', 'root').existsSync(), isFalse);
    });

    test('an empty thread copies as it is', () async {
      final root = Directory.systemTemp.createTempSync('gaia_codex_copy_');
      addTearDown(() => root.deleteSync(recursive: true));
      CodexAppServerRunner runner(String home) => CodexAppServerRunner(
        workingDirectory: p.join(root.path, 'ws'),
        codexHome: p.join(root.path, home),
        userCodexHome: p.join(root.path, 'user'),
        fallback: CodexRunner(
          workingDirectory: p.join(root.path, 'ws'),
          codexHome: p.join(root.path, home),
        ),
      );
      File(
        p.join(
          root.path,
          'from',
          'sessions',
          '2026',
          '11',
          '07',
          'rollout-2026-11-07T00-00-00-blank.jsonl',
        ),
      ).createSync(recursive: true);

      expect(
        await runner('to').copyThreadFrom(runner('from'), 'blank'),
        isTrue,
      );
    });
  });

  test('stop interrupts the running turn, which fails at once', () async {
    final replay = _Replay('tools.jsonl');
    unawaited(replay.client.initialize());
    final turn = replay.client.send(
      threadId: null,
      model: 'gpt-6.1-sol',
      input: _text('Hi'),
      tools: _Tools(),
      onEvent: (_) {},
    );
    await replay.feedThrough('turn/started');
    expect(replay.client.busy, isTrue);
    replay.client.stop(_thread);
    expect(replay.client.busy, isFalse);
    await expectLater(turn, throwsA(isA<GaiaRunException>()));
    expect(replay.sentFor('turn/interrupt')['params'], {
      'threadId': _thread,
      'turnId': '01a19d70-2982-7df1-91d8-fe45be84a740',
    });
  });

  test('a stopped turn is reverted once Codex has ended it, and a refusal '
      'says why (§9.6)', () async {
    const turnId = '01a19d70-2982-7df1-91d8-fe45be84a740';
    final replay = _Replay('tools.jsonl');
    unawaited(replay.client.initialize());
    final turn = replay.client.send(
      threadId: null,
      model: 'gpt-6.1-sol',
      input: _text('Hi'),
      tools: _Tools(),
      onEvent: (_) {},
    );
    await replay.feedThrough('turn/started');
    replay.client.stop(_thread);
    await expectLater(turn, throwsA(isA<GaiaRunException>()));

    final reverting = replay.client.revert(_thread);
    await Future<void>.delayed(Duration.zero);
    expect(replay.sent.where((m) => m['method'] == 'thread/revert'), isEmpty);
    replay.client.onLine(
      jsonEncode({
        'method': 'turn/completed',
        'params': {
          'threadId': _thread,
          'turn': {'id': turnId, 'status': 'interrupted'},
        },
      }),
    );
    await Future<void>.delayed(Duration.zero);
    final revert = replay.sentFor('thread/revert');
    expect(revert['params'], {'threadId': _thread, 'beforeTurnId': turnId});
    replay.client.onLine(
      jsonEncode({
        'id': revert['id'],
        'error': {'code': -32600, 'message': 'turn not found'},
      }),
    );
    expect(await reverting, 'Codex refused to take it back: turn not found');
    // Once only: the next stop's turn is the one taken back.
    expect(await replay.client.revert(_thread), 'Codex was not running it.');
  });

  test('a stopped turn whose turn/start Codex refused has nothing to take '
      'back, at once', () async {
    final replay = _Replay('tools.jsonl');
    unawaited(replay.client.initialize());
    final turn = replay.client.send(
      threadId: null,
      model: 'gpt-6.1-sol',
      input: _text('Hi'),
      tools: _Tools(),
      onEvent: (_) {},
    );
    while (!replay.sent.any((m) => m['method'] == 'turn/start')) {
      await replay.feed(1);
    }
    replay.client.stop(_thread);
    replay.client.onLine(
      jsonEncode({
        'id': replay.sentFor('turn/start')['id'],
        'error': {'code': -32600, 'message': 'no'},
      }),
    );
    await expectLater(turn, throwsA(isA<GaiaRunException>()));

    // Not the 10 s wait for a `turn/completed` that never comes.
    expect(
      await replay.client.revert(_thread).timeout(const Duration(seconds: 1)),
      isNull,
    );
    expect(replay.sent.where((m) => m['method'] == 'thread/revert'), isEmpty);
  });

  test("a turn hears the account's windows, not a model's own", () async {
    final replay = _Replay('tools.jsonl');
    unawaited(replay.client.initialize());
    final events = <GaiaAgentEvent>[];
    unawaited(
      replay.client
          .send(
            threadId: null,
            model: 'gpt-6.1-sol',
            input: _text('Hi'),
            tools: _Tools(),
            onEvent: events.add,
          )
          .then<void>((_) {}, onError: (_) {}),
    );
    await replay.feedThrough('turn/started');
    void limits(String id) => replay.client.onLine(
      jsonEncode({
        'method': 'account/rateLimits/updated',
        'params': {
          'rateLimits': {
            'limitId': id,
            'primary': {
              'usedPercent': 10,
              'windowDurationMins': 300,
              'resetsAt': 1793347092,
            },
          },
        },
      }),
    );
    events.clear();
    limits('codex_other_model');
    expect(events, isEmpty);
    limits('codex');
    final usage = (events.single as GaiaUsageUpdate).usage;
    expect(usage.fiveHour!.used, 0.1);
    replay.client.stop(_thread);
  });

  test('a rate limit read returns the result, or the refusal', () async {
    final replay = _Replay('tools.jsonl');
    final read = replay.client.readRateLimits();
    final id = replay.sentFor('account/rateLimits/read')['id'];
    replay.client.onLine(
      jsonEncode({
        'id': id,
        'result': {'rateLimits': <String, Object?>{}},
      }),
    );
    expect(await read, containsPair('rateLimits', isEmpty));

    final refused = replay.client.readRateLimits();
    final next = replay.sent.last['id'];
    replay.client.onLine(
      jsonEncode({
        'id': next,
        'error': {
          'code': -32600,
          'message': 'codex account authentication required',
        },
      }),
    );
    await expectLater(
      refused,
      throwsA(
        isA<GaiaRunException>().having(
          (error) => error.message,
          'message',
          contains('authentication'),
        ),
      ),
    );
  });

  test('a line that is not JSON is a parse failure', () {
    expect(
      () => CodexAppServerClient((_) {}).onLine('not json'),
      throwsA(isA<CodexParseException>()),
    );
  });

  test(
    'a thread copied to another account keeps its place and tools',
    () async {
      final root = Directory.systemTemp.createTempSync('gaia_codex_copy_');
      addTearDown(() => root.deleteSync(recursive: true));
      const from = GaiaAccount(
        id: kGaiaDefaultAccountId,
        label: 'A',
        adapter: kGaiaCodexAdapter,
        dir: '',
      );
      final to = GaiaAccount(
        id: 'b',
        label: 'B',
        adapter: kGaiaCodexAdapter,
        dir: p.join(root.path, 'login-b'),
      );
      final rollout = File(
        p.join(
          root.path,
          'homes',
          from.id,
          'sessions',
          '2026',
          '11',
          '01',
          'rollout-2026-11-01T13-32-09-thread-1.jsonl',
        ),
      )..createSync(recursive: true);
      rollout.writeAsStringSync('{"line":1}');
      File(
        p.join(root.path, 'homes', from.id, 'gaia-threads.json'),
      ).writeAsStringSync(jsonEncode({'thread-1': kCodexToolsHash}));
      final runners = CodexAccountRunners(
        workingDirectory: p.join(root.path, 'ws'),
        homesRoot: p.join(root.path, 'homes'),
      );

      expect(
        await runners.copySession(sessionId: 'nope', from: from, to: to),
        isFalse,
      );
      expect(
        await runners.copySession(sessionId: 'thread-1', from: from, to: to),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        File(
          p.join(
            root.path,
            'homes',
            'b',
            'sessions',
            '2026',
            '11',
            '01',
            'rollout-2026-11-01T13-32-09-thread-1.jsonl',
          ),
        ).readAsStringSync(),
        '{"line":1}',
      );
      expect(
        jsonDecode(
          File(
            p.join(root.path, 'homes', 'b', 'gaia-threads.json'),
          ).readAsStringSync(),
        ),
        {'thread-1': kCodexToolsHash},
      );
    },
  );

  test('a removed account loses its login but keeps its threads', () async {
    final root = Directory.systemTemp.createTempSync('gaia_codex_homes_');
    addTearDown(() => root.deleteSync(recursive: true));
    File home(String id, String name) =>
        File(p.join(root.path, id, name))..createSync(recursive: true);
    final keptLogin = home('kept', 'auth.json');
    final removedLogin = home('removed', 'auth.json');
    final removedThreads = home('removed', 'gaia-threads.json');
    final runners = CodexAccountRunners(
      workingDirectory: p.join(root.path, 'ws'),
      homesRoot: root.path,
    );

    await runners.keepAccounts(const [
      GaiaAccount(
        id: 'kept',
        label: 'Kept',
        adapter: kGaiaCodexAdapter,
        dir: '',
      ),
    ]);

    expect(keptLogin.existsSync(), isTrue);
    expect(removedLogin.existsSync(), isFalse);
    expect(removedThreads.existsSync(), isTrue);
  });

  test('a threads file that is not a map counts as no threads', () async {
    final root = Directory.systemTemp.createTempSync('gaia_codex_tools_');
    addTearDown(() => root.deleteSync(recursive: true));
    final home = p.join(root.path, 'home');
    Directory(home).createSync();
    File(p.join(home, 'gaia-threads.json')).writeAsStringSync('[]');
    final runner = CodexAppServerRunner(
      workingDirectory: p.join(root.path, 'ws'),
      codexHome: home,
      userCodexHome: p.join(root.path, 'user'),
      fallback: CodexRunner(
        workingDirectory: p.join(root.path, 'ws'),
        codexHome: home,
      ),
    );
    final result = await runner.send(
      chatId: 'chat',
      sessionId: 'old',
      model: 'gpt-6.1-sol',
      prompt: 'Hi',
      onEvent: (_) {},
    );
    expect(result.sessionFound, isFalse);
  });

  test('a thread started with other tools is handed over without starting '
      'Codex', () async {
    final root = Directory.systemTemp.createTempSync('gaia_codex_tools_');
    addTearDown(() => root.deleteSync(recursive: true));
    final home = p.join(root.path, 'home');
    Directory(home).createSync();
    File(
      p.join(home, 'gaia-threads.json'),
    ).writeAsStringSync(jsonEncode({'old': 'another-hash'}));
    final runner = CodexAppServerRunner(
      workingDirectory: p.join(root.path, 'ws'),
      codexHome: home,
      userCodexHome: p.join(root.path, 'user'),
      fallback: CodexRunner(
        workingDirectory: p.join(root.path, 'ws'),
        codexHome: home,
      ),
    );
    for (final sessionId in ['old', 'from-exec']) {
      final result = await runner.send(
        chatId: 'chat',
        sessionId: sessionId,
        model: 'gpt-6.1-sol',
        prompt: 'Hi',
        onEvent: (_) {},
      );
      expect(result.sessionFound, isFalse, reason: sessionId);
      expect(result.sessionId, sessionId);
    }
  });

  test('a stop before the turn reaches its runner ends it there, with '
      'nothing to take back; a later send forgets it', () async {
    final root = Directory.systemTemp.createTempSync('gaia_codex_stop_');
    addTearDown(() => root.deleteSync(recursive: true));
    final runners = CodexAccountRunners(
      workingDirectory: p.join(root.path, 'ws'),
      homesRoot: p.join(root.path, 'homes'),
    );
    Future<GaiaTurnResult> send() => runners.send(
      chatId: 'chat',
      sessionId: 'old',
      model: 'gpt-6.1-sol',
      prompt: 'Hi',
      onEvent: (_) {},
    );

    final stopped = send();
    await runners.stop('chat');
    await expectLater(stopped, throwsA(isA<GaiaRunException>()));
    expect(runners.isRunning('chat'), isFalse);
    expect(await runners.takeBack('chat'), isNull);

    // Not stopped: it goes on to the runner, whose home isn't set up.
    final result = await send();
    expect(result.isError, isTrue);
    expect(result.text, isNot('Stopped.'));
    expect(await runners.takeBack('chat'), 'Codex was not running it.');
  });

  test('a stop while a runner opens, which then ends with nothing sent, '
      'ends the turn as stopped, not as what ended it', () async {
    final root = Directory.systemTemp.createTempSync('gaia_codex_stop_');
    addTearDown(() => root.deleteSync(recursive: true));
    final home = p.join(root.path, 'home');
    // A sandbox the home isn't set up for: every send ends before Codex.
    File(p.join(root.path, 'user', 'config.toml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('[windows]\nsandbox = "elevated"\n');
    final exec = CodexRunner(
      workingDirectory: p.join(root.path, 'ws'),
      codexHome: home,
      userCodexHome: p.join(root.path, 'user'),
    );
    final server = CodexAppServerRunner(
      workingDirectory: p.join(root.path, 'ws'),
      codexHome: home,
      userCodexHome: p.join(root.path, 'user'),
      fallback: exec,
    );
    for (final GaiaAgentRunner runner in [exec, server]) {
      Future<GaiaTurnResult> send() => runner.send(
        chatId: 'chat',
        sessionId: 'old',
        model: 'gpt-6.1-sol',
        prompt: 'Hi',
        onEvent: (_) {},
      );
      final reason = '${runner.runtimeType}';
      final stopped = send();
      await runner.stop('chat');
      await expectLater(
        stopped,
        throwsA(isA<GaiaRunException>()),
        reason: reason,
      );
      expect(await runner.takeBack('chat'), isNull, reason: reason);

      // Not stopped, the home that isn't set up says so.
      final result = await send();
      expect(result.isError, isTrue, reason: reason);
      expect(result.text, isNot('Stopped.'), reason: reason);
    }
  });
}
