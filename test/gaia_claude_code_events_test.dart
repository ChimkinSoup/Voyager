import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
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

  test('versions outside the tested range are flagged', () {
    expect(parseClaudeVersion('2.1.310 (Claude Code)'), (2, 1, 310));
    expect(isTestedClaudeVersion((2, 1, 299)), isFalse);
    expect(isTestedClaudeVersion((2, 2, 0)), isFalse);
    expect(isTestedClaudeVersion((2, 1, 300)), isTrue);
    expect(parseClaudeVersion('command not found'), isNull);
  });
}
