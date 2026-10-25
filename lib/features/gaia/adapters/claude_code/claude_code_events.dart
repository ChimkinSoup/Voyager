// FRAGILE(cli): Claude Code's `--output-format stream-json` event shapes are
// not a stable API and change between CLI releases (GAIA_HLD.md §5.1). Every
// shape read here has a recorded fixture under
// test/fixtures/gaia/claude_code/, and claude_code_events_test.dart parses
// them all. Re-record them, and move [kClaudeCodeTestedVersions], when a new
// CLI version is tested.
//
// Strict: a known event missing a field read here is a parse failure, which
// fails the run and logs the raw line. Event types not read here are ignored.

import 'dart:convert';

import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';

/// The Claude Code versions the adapter is tested against: at least the
/// first, and below the second. Outside it, chats still run, with an
/// "untested CLI version" chip.
const kClaudeCodeTestedVersions = ((2, 1, 300), (2, 2, 0));

sealed class ClaudeEvent {
  const ClaudeEvent();
}

/// `system`/`init`: the session has started, or resumed.
class ClaudeInit extends ClaudeEvent {
  const ClaudeInit({required this.sessionId, required this.model});

  final String sessionId;
  final String model;
}

/// A text block of the agent's own reply has started.
class ClaudeTextStart extends ClaudeEvent {
  const ClaudeTextStart();
}

class ClaudeTextDelta extends ClaudeEvent {
  const ClaudeTextDelta(this.text);

  final String text;
}

/// The agent called a tool.
class ClaudeToolUse extends ClaudeEvent {
  const ClaudeToolUse(this.name);

  final String name;
}

/// The end of a turn. [isError] covers failures the CLI reports as a reply,
/// such as an unknown model, with [text] saying what went wrong.
class ClaudeResult extends ClaudeEvent {
  const ClaudeResult({
    required this.sessionId,
    required this.isError,
    required this.text,
  });

  final String sessionId;
  final bool isError;
  final String text;
}

/// Anything the adapter doesn't read: hooks, status, rate limits, subagent
/// output, whole-message echoes of what streamed, tool results.
class ClaudeIgnored extends ClaudeEvent {
  const ClaudeIgnored();
}

class ClaudeParseException implements Exception {
  ClaudeParseException(this.reason, this.line);

  final String reason;
  final String line;

  @override
  String toString() => 'ClaudeParseException: $reason in: $line';
}

ClaudeEvent parseClaudeLine(String line) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    throw ClaudeParseException('not JSON', line);
  }
  if (decoded is! Map<String, Object?>) {
    throw ClaudeParseException('not an object', line);
  }
  T field<T>(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! T) throw ClaudeParseException('bad "$key"', line);
    return value;
  }

  switch (field<String>(decoded, 'type')) {
    case 'system':
      if (field<String>(decoded, 'subtype') != 'init') {
        return const ClaudeIgnored();
      }
      return ClaudeInit(
        sessionId: field<String>(decoded, 'session_id'),
        model: field<String>(decoded, 'model'),
      );
    case 'stream_event':
      // A subagent's stream: its text isn't the reply.
      if (decoded['parent_tool_use_id'] != null) return const ClaudeIgnored();
      final event = field<Map<String, Object?>>(decoded, 'event');
      switch (field<String>(event, 'type')) {
        case 'content_block_start':
          final block = field<Map<String, Object?>>(event, 'content_block');
          return switch (field<String>(block, 'type')) {
            'text' => const ClaudeTextStart(),
            'tool_use' => ClaudeToolUse(field<String>(block, 'name')),
            _ => const ClaudeIgnored(),
          };
        case 'content_block_delta':
          final delta = field<Map<String, Object?>>(event, 'delta');
          if (field<String>(delta, 'type') != 'text_delta') {
            return const ClaudeIgnored();
          }
          return ClaudeTextDelta(field<String>(delta, 'text'));
        default:
          return const ClaudeIgnored();
      }
    case 'result':
      return ClaudeResult(
        sessionId: field<String>(decoded, 'session_id'),
        isError: field<bool>(decoded, 'is_error'),
        // Absent on some error subtypes; the error is then in `subtype`.
        text: decoded['result'] as String? ?? field<String>(decoded, 'subtype'),
      );
    default:
      return const ClaudeIgnored();
  }
}

/// What Gaia reads of [event]; null for the session's own bookkeeping.
GaiaAgentEvent? gaiaEventOf(ClaudeEvent event) => switch (event) {
  ClaudeTextStart() => const GaiaTextStart(),
  ClaudeTextDelta(:final text) => GaiaTextDelta(text),
  ClaudeToolUse(:final name) => GaiaToolUse(name),
  ClaudeInit() || ClaudeResult() || ClaudeIgnored() => null,
};

/// Reads `claude --version` output ("2.1.310 (Claude Code)").
(int, int, int)? parseClaudeVersion(String output) {
  final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(output);
  if (match == null) return null;
  return (
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

bool isTestedClaudeVersion((int, int, int) version) {
  int compare((int, int, int) a, (int, int, int) b) =>
      a.$1 != b.$1 ? a.$1 - b.$1 : (a.$2 != b.$2 ? a.$2 - b.$2 : a.$3 - b.$3);
  final (low, high) = kClaudeCodeTestedVersions;
  return compare(version, low) >= 0 && compare(version, high) < 0;
}
