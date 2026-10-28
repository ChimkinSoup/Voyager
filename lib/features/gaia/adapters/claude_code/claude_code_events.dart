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
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

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
    this.contextTokens,
  });

  final String sessionId;
  final bool isError;
  final String text;

  /// The context at the turn's last model call: its input, cache read and
  /// cache write tokens. Read leniently, since it's only shown: null when
  /// `usage` isn't the shape below.
  final int? contextTokens;
}

/// `rate_limit_event`: the account's usage windows, mid-turn. Not every turn
/// has one.
class ClaudeRateLimit extends ClaudeEvent {
  const ClaudeRateLimit(this.usage);

  final GaiaUsage usage;
}

/// `control_request`: the CLI asks its host, Gaia, mid-session (GAIA_HLD.md
/// §5.3): `mcp_message` carries a JSON-RPC message for Gaia's tools, and
/// `can_use_tool` asks whether a tool may run (§10.1). Answered with a
/// `control_response` on stdin carrying the same [requestId].
class ClaudeControlRequest extends ClaudeEvent {
  const ClaudeControlRequest({
    required this.requestId,
    required this.subtype,
    required this.request,
  });

  final String requestId;
  final String subtype;

  /// The whole `request`, [subtype] included.
  final Map<String, Object?> request;
}

/// `control_response`: the CLI's answer to a request of Gaia's, the
/// `initialize` that registers its tools. [error] when it failed.
class ClaudeControlResponse extends ClaudeEvent {
  const ClaudeControlResponse({required this.requestId, this.error});

  final String requestId;
  final String? error;
}

/// Anything the adapter doesn't read: hooks, status, subagent output,
/// whole-message echoes of what streamed, tool results.
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
        contextTokens: claudeContextTokens(decoded['usage']),
      );
    case 'rate_limit_event':
      final usage = claudeUsage(decoded['rate_limit_info']);
      return usage == null ? const ClaudeIgnored() : ClaudeRateLimit(usage);
    case 'control_request':
      final request = field<Map<String, Object?>>(decoded, 'request');
      return ClaudeControlRequest(
        requestId: field<String>(decoded, 'request_id'),
        subtype: field<String>(request, 'subtype'),
        request: request,
      );
    case 'control_response':
      // Read leniently, since it's only logged: an error may lack its id.
      final response = field<Map<String, Object?>>(decoded, 'response');
      return ClaudeControlResponse(
        requestId: response['request_id'] as String? ?? '',
        error: response['subtype'] == 'success'
            ? null
            : response['error'] as String? ?? 'failed',
      );
    default:
      return const ClaudeIgnored();
  }
}

/// `rate_limit_info.unifiedWindows`' five-hour and weekly windows (observed
/// on 2.1.310). Read leniently, since it's only shown: null when neither is
/// the shape below.
GaiaUsage? claudeUsage(Object? info) {
  if (info is! Map || info['unifiedWindows'] is! Map) return null;
  final windows = info['unifiedWindows'] as Map;
  GaiaUsageWindow? window(String key) {
    final window = windows[key];
    if (window is! Map) return null;
    if (window['utilization'] case final num used) {
      if (window['resetsAt'] case final num resetsAt) {
        return (
          used: used.toDouble(),
          resetsAt: DateTime.fromMillisecondsSinceEpoch(
            resetsAt.toInt() * 1000,
          ),
        );
      }
    }
    return null;
  }

  final fiveHour = window('five_hour');
  final weekly = window('seven_day');
  if (fiveHour == null && weekly == null) return null;
  return GaiaUsage(fiveHour: fiveHour, weekly: weekly);
}

/// `usage.iterations`' last entry (one per model call in the turn; observed
/// on 2.1.310), or `usage` itself when there are none.
int? claudeContextTokens(Object? usage) {
  if (usage is! Map) return null;
  final last = switch (usage['iterations']) {
    [..., final Map last] => last,
    _ => usage,
  };
  int count(String key) => (last[key] as num?)?.toInt() ?? 0;
  if (last['input_tokens'] is! num) return null;
  return count('input_tokens') +
      count('cache_read_input_tokens') +
      count('cache_creation_input_tokens');
}

const _gaiaToolPrefix = 'mcp__${kGaiaMcpServer}__';

/// What Gaia reads of [event]; null for the session's own bookkeeping.
GaiaAgentEvent? gaiaEventOf(ClaudeEvent event) => switch (event) {
  ClaudeTextStart() => const GaiaTextStart(),
  ClaudeTextDelta(:final text) => GaiaTextDelta(text),
  // Gaia's own tools by their own names: `ask_user`, not
  // `mcp__gaia__ask_user`.
  ClaudeToolUse(:final name) => GaiaToolUse(
    name.startsWith(_gaiaToolPrefix)
        ? name.substring(_gaiaToolPrefix.length)
        : name,
  ),
  ClaudeRateLimit(:final usage) => GaiaUsageUpdate(usage),
  ClaudeInit() ||
  ClaudeResult() ||
  ClaudeControlRequest() ||
  ClaudeControlResponse() ||
  ClaudeIgnored() => null,
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
