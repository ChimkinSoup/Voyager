import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/domain/models/gaia_models.dart';

/// Contract tests for the Claude Code adapter (GAIA_HLD.md §5.1): every
/// fixture is real `stream-json` output recorded from the CLI version named
/// in its init event.
List<ClaudeEvent> _events(String fixture) => [
  for (final line in File(
    'test/fixtures/gaia/claude_code/$fixture',
  ).readAsLinesSync())
    if (line.trim().isNotEmpty) parseClaudeLine(line),
];

/// Splits a fixture's events into turns, each ending at its result.
List<List<ClaudeEvent>> _turns(List<ClaudeEvent> events) {
  final turns = <List<ClaudeEvent>>[[]];
  for (final event in events) {
    turns.last.add(event);
    if (event is ClaudeResult) turns.add([]);
  }
  return turns..removeLast();
}

List<GaiaPart> _build(List<ClaudeEvent> turn) {
  final builder = GaiaTurnBuilder();
  for (final event in turn) {
    if (gaiaEventOf(event) case final event?) builder.apply(event);
  }
  return builder.finished;
}

void main() {
  test('every fixture parses, and its version is in the tested range', () {
    for (final file in Directory('test/fixtures/gaia/claude_code').listSync()) {
      final lines = File(file.path).readAsLinesSync();
      for (final line in lines.where((line) => line.trim().isNotEmpty)) {
        expect(() => parseClaudeLine(line), returnsNormally, reason: file.path);
      }
      final init = lines.firstWhere((line) => line.contains('"init"'));
      final version = parseClaudeVersion(
        RegExp(r'"claude_code_version":"([^"]+)"').firstMatch(init)!.group(1)!,
      )!;
      expect(isTestedClaudeVersion(version), isTrue, reason: file.path);
    }
  });

  test("the control channel: Gaia's tools as an sdk MCP server, and a "
      'permission prompt', () {
    final events = _events('control.jsonl');
    final requests = events.whereType<ClaudeControlRequest>().toList();
    expect(requests.map((r) => r.subtype), [
      'mcp_message',
      'mcp_message',
      'mcp_message',
      'mcp_message',
      'can_use_tool',
    ]);
    expect(
      requests
          .where((r) => r.subtype == 'mcp_message')
          .map((r) => (r.request['message']! as Map)['method']),
      ['initialize', 'notifications/initialized', 'tools/list', 'tools/call'],
    );
    final call = requests[3].request['message']! as Map;
    expect((call['params']! as Map)['name'], 'ask_user');
    final permission = requests.last;
    expect(permission.request['tool_name'], 'Bash');
    expect(
      (permission.request['input']! as Map)['command'],
      'echo gaia-permission',
    );
    final response = events.whereType<ClaudeControlResponse>().single;
    expect(response.requestId, 'gaia_initialize');
    expect(response.error, isNull);
    for (final event in events) {
      if (event is ClaudeControlRequest || event is ClaudeControlResponse) {
        expect(gaiaEventOf(event), isNull);
      }
    }
  });

  test("Gaia's own tools are named without their MCP prefix", () {
    expect(
      (gaiaEventOf(const ClaudeToolUse('mcp__gaia__ask_user'))! as GaiaToolUse)
          .name,
      'ask_user',
    );
    expect(
      (gaiaEventOf(const ClaudeToolUse('Bash'))! as GaiaToolUse).name,
      'Bash',
    );
  });

  test('a single turn streams its text and ends in a result', () {
    final events = _events('single_turn.jsonl');
    final init = events.whereType<ClaudeInit>().single;
    expect(init.model, 'claude-haiku-5-5');
    final result = events.whereType<ClaudeResult>().single;
    expect(result.isError, isFalse);
    expect(result.sessionId, init.sessionId);
    expect(result.text, 'hello there');
    expect(_build(events).map((part) => part.toJson()), [
      {'type': 'text', 'text': 'hello there'},
    ]);
  });

  test('tool calls before a text block collapse into an activity part', () {
    final turns = _turns(_events('tool_call_two_turns.jsonl'));
    expect(turns, hasLength(2));
    // The recorded turn calls Bash straight away, then answers.
    final parts = _build(turns.first);
    expect(parts, hasLength(2));
    expect((parts.first as GaiaActivityPart).tools, ['Bash']);
    expect((parts.last as GaiaTextPart).text, contains('gaia-fixture'));
    expect(_build(turns.last).single, isA<GaiaTextPart>());
  });

  test("a tool call's command comes in once its input has streamed", () {
    final turn = _turns(_events('tool_call_two_turns.jsonl')).first;
    final builder = GaiaTurnBuilder();
    final seen = <List<String?>>[];
    for (final event in turn) {
      final gaia = gaiaEventOf(event);
      if (gaia != null && builder.apply(gaia)) {
        if (builder.parts.firstOrNull case GaiaActivityPart part) {
          seen.add([
            for (var i = 0; i < part.tools.length; i++) part.detailAt(i),
          ]);
        }
      }
    }
    // Shown as called at once, then with its command.
    expect(seen.first, [null]);
    expect(seen.last, ['echo gaia-fixture']);
    expect(_build(turn).first.toJson(), {
      'type': 'activity',
      'tools': ['Bash'],
      'details': ['echo gaia-fixture'],
    });
  });

  test("a failed tool result marks its call; a succeeded one doesn't", () {
    // The recorded Bash call succeeded.
    final turn = _turns(_events('tool_call_two_turns.jsonl')).first;
    expect(turn.whereType<ClaudeToolErrors>(), isEmpty);
    expect((_build(turn).first as GaiaActivityPart).failureAt(0), isNull);

    final builder = GaiaTurnBuilder()
      ..apply(const GaiaToolUse('Bash', id: 'a'))
      ..apply(const GaiaToolUse('Read', id: 'b'));
    final failed = parseClaudeLine(
      '{"type":"user","parent_tool_use_id":null,"message":{"content":['
      '{"type":"tool_result","tool_use_id":"a","is_error":true,'
      r'"content":"Exit code 1\nerror: no such file"},'
      '{"type":"tool_result","tool_use_id":"b","is_error":true,'
      '"content":[{"type":"text","text":"File does not exist."}]},'
      '{"type":"tool_result","tool_use_id":"c","is_error":true,'
      '"content":"<tool_use_error>File has not been read yet.'
      '</tool_use_error>"}]}}',
    );
    builder.apply(const GaiaToolUse('Edit', id: 'c'));
    expect(builder.apply(gaiaEventOf(failed)!), isTrue);
    expect((builder.parts.single as GaiaActivityPart).failures, [
      'Exit code 1',
      'File does not exist.',
      'File has not been read yet.',
    ]);
    // A subagent's, and a result that wasn't an error, are nothing.
    expect(
      parseClaudeLine(
        '{"type":"user","parent_tool_use_id":"p","message":{"content":['
        '{"type":"tool_result","tool_use_id":"a","is_error":true,'
        '"content":"x"}]}}',
      ),
      isA<ClaudeIgnored>(),
    );
    expect(
      parseClaudeLine(
        '{"type":"user","parent_tool_use_id":null,"message":{"content":['
        '{"type":"tool_result","tool_use_id":"a","is_error":false,'
        '"content":"ok"}]}}',
      ),
      isA<ClaudeIgnored>(),
    );
  });

  test('a reply cut off mid-stream gives way to the one the CLI retries', () {
    // Recorded with the wifi off partway through the story's text, and back
    // on while the CLI retried (trimmed to five text deltas a block).
    final events = _events('dropped_retried.jsonl');
    expect(events.whereType<ClaudeAbandoned>().single.from, 1);
    expect(events.whereType<ClaudeResult>().single.isError, isFalse);
    final parts = _build(events);
    final text = (parts.single as GaiaTextPart).text;
    expect(text, startsWith('# The Character of the Light'));
    // The cut-off first go began "**The Character of the Light**".
    expect(text, isNot(contains('**')));
  });

  test('a reply cut off for good ends in an error result', () {
    // Recorded with the wifi off while it thought, until the CLI gave up.
    final events = _events('dropped_gave_up.jsonl');
    expect(events.whereType<ClaudeAbandoned>().single.from, 0);
    expect(_build(events), isEmpty);
    final result = events.whereType<ClaudeResult>().single;
    expect(result.isError, isTrue);
    expect(result.text, contains("Can't reach the API server"));
    // Each retry it made, shown as it came.
    final retries = [
      for (final event in events)
        if (gaiaEventOf(event) case GaiaRetrying(
          :final attempt,
          :final maxRetries,
          :final status,
          :final delay,
        ))
          (attempt, maxRetries, status, delay),
    ];
    expect(retries.first, (1, 10, null, const Duration(milliseconds: 583)));
    expect(retries.last, (9, 9, null, const Duration(milliseconds: 37432)));
    expect(retries, hasLength(10));
  });

  test("a retry's status or a block's index of another type is left out", () {
    final retry = parseClaudeLine(
      '{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,'
      '"error_status":"529","retry_delay_ms":500}',
    );
    expect(retry, isA<ClaudeRetry>().having((r) => r.status, 'status', null));
    final start = parseClaudeLine(
      '{"type":"stream_event","event":{"type":"content_block_start",'
      '"index":"0","content_block":{"type":"text","text":""}}}',
    );
    expect(start, isA<ClaudeTextStart>().having((s) => s.block, 'block', null));
  });

  test("abandoned blocks take back only their own message's parts", () {
    final builder = GaiaTurnBuilder()
      ..apply(const GaiaMessageStart())
      ..apply(const GaiaTextStart(block: 0))
      ..apply(const GaiaTextDelta('earlier message'))
      ..apply(const GaiaMessageStart())
      ..apply(const GaiaTextStart(block: 0))
      ..apply(const GaiaTextDelta('kept'))
      ..apply(const GaiaToolUse('Bash', id: 'a', block: 1))
      ..apply(const GaiaTextStart(block: 2))
      ..apply(const GaiaTextDelta('cut'));
    expect(builder.apply(const GaiaBlocksAbandoned(1)), isTrue);
    expect(builder.finished.map((part) => part.toJson()), [
      {'type': 'text', 'text': 'earlier message'},
      {'type': 'text', 'text': 'kept'},
    ]);
    // The abandoned call is gone with its part.
    expect(builder.apply(const GaiaToolDetails({'a': 'ls'})), isFalse);
    // A message that showed nothing before its cut takes nothing back.
    builder.apply(const GaiaMessageStart());
    expect(builder.apply(const GaiaBlocksAbandoned(0)), isFalse);
    expect(builder.finished, hasLength(2));
  });

  test("a subagent's tool inputs aren't the reply's", () {
    expect(
      parseClaudeLine(
        '{"type":"assistant","parent_tool_use_id":"toolu_p","message":'
        '{"content":[{"type":"tool_use","id":"t","name":"Bash",'
        '"input":{"command":"ls"}}]}}',
      ),
      isA<ClaudeIgnored>(),
    );
  });

  test('each tool shows the input that says what it did', () {
    String? detail(String name, Map<String, Object?> input) =>
        (gaiaEventOf(ClaudeToolInputs({'t': (name: name, input: input)}))!
                as GaiaToolDetails)
            .details['t'];
    expect(detail('WebSearch', {'query': 'dart 4'}), 'dart 4');
    expect(
      detail('Edit', {'file_path': 'a.dart', 'old_string': 'x'}),
      'a.dart',
    );
    // Any other tool: its whole input.
    expect(detail('ask_user', {'question': 'Q?'}), '{"question":"Q?"}');
    // Clipped, so a long one stays small enough to sync.
    final long = detail('Bash', {'command': 'x' * 5000})!;
    expect(long.length, kGaiaToolDetailMax + 1);
    expect(long, endsWith('…'));
  });

  test('a resumed session keeps its id', () {
    final events = _events('resume.jsonl');
    final sessionId = events.whereType<ClaudeInit>().single.sessionId;
    expect(events.whereType<ClaudeResult>().single.sessionId, sessionId);
  });

  test('an unknown model ends the turn in an error result', () {
    final result = _events(
      'unknown_model.jsonl',
    ).whereType<ClaudeResult>().single;
    expect(result.isError, isTrue);
    expect(result.text, contains('claude-nonexistent-9'));
  });

  test('a known event missing a field it reads fails to parse', () {
    expect(
      () => parseClaudeLine('{"type":"result","is_error":false}'),
      throwsA(isA<ClaudeParseException>()),
    );
    expect(
      () => parseClaudeLine(
        '{"type":"stream_event","parent_tool_use_id":null,'
        '"event":{"type":"content_block_delta","delta":{"type":"text_delta"}}}',
      ),
      throwsA(isA<ClaudeParseException>()),
    );
    expect(
      () => parseClaudeLine('not json'),
      throwsA(isA<ClaudeParseException>()),
    );
  });

  test('unknown event types and subagent streams are ignored', () {
    expect(parseClaudeLine('{"type":"brand_new"}'), isA<ClaudeIgnored>());
    expect(
      parseClaudeLine(
        '{"type":"stream_event","parent_tool_use_id":"toolu_1",'
        '"event":{"type":"content_block_delta",'
        '"delta":{"type":"text_delta","text":"x"}}}',
      ),
      isA<ClaudeIgnored>(),
    );
  });

  test('a rate limit event reads its five-hour and weekly windows', () {
    final usage = _events(
      'single_turn.jsonl',
    ).whereType<ClaudeRateLimit>().single.usage;
    expect(usage.fiveHour!.used, 0.09);
    expect(usage.weekly!.used, 0.57);
    expect(
      usage.weekly!.resetsAt,
      DateTime.fromMillisecondsSinceEpoch(1793160000 * 1000),
    );
    // Leniently: an unknown shape is only not shown.
    expect(
      parseClaudeLine('{"type":"rate_limit_event","rate_limit_info":{}}'),
      isA<ClaudeIgnored>(),
    );
  });

  test('versions outside the tested range are flagged', () {
    expect(parseClaudeVersion('2.1.310 (Claude Code)'), (2, 1, 310));
    expect(isTestedClaudeVersion((2, 1, 299)), isFalse);
    expect(isTestedClaudeVersion((2, 2, 0)), isFalse);
    expect(isTestedClaudeVersion((2, 1, 300)), isTrue);
    expect(parseClaudeVersion('command not found'), isNull);
  });

  // GAIA_NATIVE_COMMANDS.md §3 and §5, recorded on 2.1.319 in safe mode.
  group('native commands', () {
    final events = _events('native_commands.jsonl');

    test("initialize lists the CLI's commands", () {
      final commands = events
          .whereType<ClaudeControlResponse>()
          .single
          .commands!;
      final compact = commands.firstWhere((c) => c.name == 'compact');
      expect(compact.description, contains('summarizing'));
      expect(compact.argumentHint, isNotEmpty);
      // Safe mode: the bundled ones only, no plugin skills.
      expect(commands.any((c) => c.name.contains(':')), isFalse);
    });

    test('a command the CLI runs itself streams nothing; its output is the '
        'result', () {
      final turn = _turns(events)[1];
      expect(turn.whereType<ClaudeTextDelta>(), isEmpty);
      final result = turn.whereType<ClaudeResult>().single;
      expect(
        claudeCommandOutput(result.text, null),
        startsWith('Reloaded skills:'),
      );
    });

    test('/compact shows how far the session shrank', () {
      final turn = _turns(events)[2];
      expect(turn.whereType<ClaudeTextDelta>(), isEmpty);
      final compacted = turn.whereType<ClaudeCompacted>().single;
      expect(compacted.preTokens, isNotNull);
      expect(compacted.postTokens, isNotNull);
      expect(turn.whereType<ClaudeResult>().single.text, isEmpty);
      expect(
        claudeCommandOutput('', compacted),
        matches(RegExp(r'^Compacted: [\d.]+k? → [\d.]+k? tokens\.$')),
      );
      expect(claudeCommandOutput('', const ClaudeCompacted()), 'Compacted.');
    });

    test('blocked commands are caught by name or alias, at the start only', () {
      expect(claudeBlockedCommandIn('/clear'), 'clear');
      expect(claudeBlockedCommandIn('  /reset now'), 'reset');
      expect(claudeBlockedCommandIn('/model sonnet'), 'model');
      expect(claudeBlockedCommandIn('/compact'), isNull);
      expect(claudeBlockedCommandIn('/clearly not'), isNull);
      expect(claudeBlockedCommandIn('please /clear'), isNull);
    });
  });
}
