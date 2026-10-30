import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/features/gaia/adapters/codex/codex_app_server.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// Contract tests for the Codex `app-server` adapter (GAIA_HLD.md §5.1):
/// every fixture is real `codex app-server` output recorded from codex-cli
/// 0.164.0 by test/gaia_codex_contract_test.dart, replayed through
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
    return (
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

const _thread = '01a18b3b-286d-72f0-86cf-f88f377cc0e4';

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
    expect(events.whereType<GaiaTextDelta>().length, greaterThan(2));
    expect(_parts(events), [
      {
        'type': 'text',
        'text':
            'I’ll ask your favourite colour, then create the file and report '
            'your choice.',
      },
      {
        'type': 'activity',
        'tools': ['ask_user', 'Shell'],
      },
      {
        'type': 'text',
        'text':
            'You chose Blue. File creation was rejected, so gaia-probe.txt '
            'wasn’t created.',
      },
    ]);

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
    );
    await replay.feed();
    expect(
      (replay.sentFor('thread/resume')['params']! as Map)['threadId'],
      _thread,
    );
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
      'turnId': '01a18b3b-2899-7430-a0a0-301d95e5ca85',
    });
  });

  test('a line that is not JSON is a parse failure', () {
    expect(
      () => CodexAppServerClient((_) {}).onLine('not json'),
      throwsA(isA<CodexParseException>()),
    );
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
}
