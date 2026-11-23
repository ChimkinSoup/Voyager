import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_app_server.dart';
import 'package:voyager/features/gaia/remote/gaia_token_counter.dart';
import 'package:voyager/features/gaia/usage/gaia_tokens.dart';

List<String> _fixture(String path) => [
  for (final line in File('test/fixtures/gaia/$path').readAsLinesSync())
    if (line.trim().isNotEmpty) line,
];

void main() {
  tearDown(() => gaiaTokensUsed = null);

  test("a Claude result's tokens are those since the last result, not the "
      "process's running total", () {
    final results = [
      for (final line in _fixture('claude_code/resume.jsonl'))
        if (parseClaudeLine(line) case final ClaudeResult result) result,
    ];
    final first = results.first.tokens['claude-haiku-5-5']!;
    expect(first.toJson(), {
      'input': 2,
      'output': 3,
      'cacheRead': 28581,
      'cacheWrite': 160,
    });
    // Its `modelUsage` says more: the process's whole run.
    expect(
      ((results.first.modelUsage! as Map)['claude-haiku-5-5']
          as Map)['cacheReadInputTokens'],
      greaterThan(first.cacheRead),
    );
  });

  test("a result without the field counts nothing", () {
    final result =
        parseClaudeLine(
              jsonEncode({
                'type': 'result',
                'session_id': 's',
                'is_error': false,
                'result': 'done',
                'modelUsage': {
                  'm': {'inputTokens': 5},
                },
              }),
            )
            as ClaudeResult;
    expect(result.tokens, isEmpty);
  });

  test("Codex's model calls add up to the thread's own total", () async {
    final lines = _fixture('codex_app_server/tools.jsonl');
    final used = <Map<String, GaiaTokenCount>>[];
    final counted = <GaiaTokensFor>{};
    gaiaTokensUsed = (tokensFor, byModel) {
      counted.add(tokensFor);
      used.add(byModel);
    };
    final client = CodexAppServerClient((_) {});
    unawaited(client.initialize());
    final first = client.send(
      threadId: null,
      model: 'gpt-6.1-sol',
      input: const [
        {'type': 'text', 'text': 'Ask my favourite colour, then make a file.'},
      ],
      tools: null,
      onEvent: (_) {},
      onNewThread: (_) async {},
      tokensFor: (account: 'codex/work', source: 'deep'),
    );
    unawaited(
      first.then((_) {
        client.send(
          threadId: '01a19d70-293d-74a1-85eb-e4936b7fe8cd',
          model: 'gpt-6.1-sol',
          input: const [
            {'type': 'text', 'text': 'Reply with exactly these words'},
          ],
          tools: null,
          onEvent: (_) {},
          tokensFor: (account: 'codex/work', source: 'quick'),
        );
      }),
    );
    for (final line in lines) {
      client.onLine(line);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    final total =
        ((jsonDecode(
                      lines.lastWhere(
                        (line) => line.contains('thread/tokenUsage/updated'),
                      ),
                    )
                    as Map)['params']
                as Map)['tokenUsage']['total']
            as Map;
    final sum = used
        .map((byModel) => byModel['gpt-6.1-sol']!)
        .reduce((a, b) => a + b);
    expect(sum.input + sum.cacheRead, total['inputTokens']);
    expect(sum.cacheRead, total['cachedInputTokens']);
    expect(sum.output, total['outputTokens']);
    expect(sum.total, total['totalTokens']);
    // Each turn's under its own tier.
    expect(counted, {
      (account: 'codex/work', source: 'deep'),
      (account: 'codex/work', source: 'quick'),
    });
  });

  test('the counter adds up each account, source and model across writes, '
      'clears the first version\'s documents, and drops tokens while signed '
      'out', () async {
    final firestore = FakeFirebaseFirestore();
    final old = firestore.doc('users/u1/gaia_tokens/claude-x');
    await old.set({'input': 5});
    final counter = GaiaTokenCounter(firestore);
    const quick = (account: 'claude_code', source: 'quick');
    const title = (account: 'claude_code/work', source: 'utility:chat title');
    await counter.add(quick, {'claude-x': const GaiaTokenCount(input: 99)});
    counter.setUser('u1');
    await counter.add(quick, {
      'claude-x': const GaiaTokenCount(input: 1, output: 2, cacheRead: 3),
    });
    await counter.add(quick, {
      'claude-x': const GaiaTokenCount(input: 10, cacheWrite: 5),
    });
    await counter.add(title, {
      'gpt-5.1/mini': const GaiaTokenCount(cacheWrite: 4),
    });
    await Future<void>.delayed(Duration.zero);

    final rows = {
      for (final row in counter.totals.value!)
        (row.account, row.source, row.model): row.count.toJson(),
    };
    expect(rows, {
      ('claude_code', 'quick', 'claude-x'): {
        'input': 11,
        'output': 2,
        'cacheRead': 3,
        'cacheWrite': 5,
      },
      ('claude_code/work', 'utility:chat title', 'gpt-5.1/mini'): {
        'input': 0,
        'output': 0,
        'cacheRead': 0,
        'cacheWrite': 4,
      },
    });
    expect((await old.get()).exists, isFalse);

    counter.setUser(null);
    expect(counter.totals.value, isNull);
  });
}
