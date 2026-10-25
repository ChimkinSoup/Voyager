// FRAGILE(cli): Codex's `codex exec --json` event shapes are not a stable API
// and change between CLI releases (GAIA_HLD.md §5.1). Every shape read here
// has a recorded fixture under test/fixtures/gaia/codex/ (observed on
// codex-cli 0.164.0), and gaia_codex_events_test.dart parses them all.
// Re-record them, and move [kCodexTestedVersions], when a new CLI version is
// tested.
//
// What 0.164.0 prints, one JSON object a line:
//   {"type":"thread.started","thread_id":"<uuid>"}
//   {"type":"turn.started"}
//   {"type":"item.started"|"item.completed","item":{"id","type",...}}
//     item types: "agent_message" {text}, "command_execution" {command,
//     aggregated_output, exit_code, status}, "error" {message} (a warning,
//     such as unknown model metadata), and others not yet recorded
//   {"type":"turn.completed","usage":{...}}
//   {"type":"error","message":"<json string>"}
//   {"type":"turn.failed","error":{"message":"<json string>"}}
// Text arrives whole, one agent message at a time: exec doesn't stream it.
//
// Strict: a known event missing a field read here is a parse failure, which
// fails the run and logs the raw line. Event and item types not read here
// are ignored, or count as a tool call when they're an item.

import 'dart:convert';

import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';

/// The Codex versions the adapter is tested against: at least the first, and
/// below the second. Outside it, chats still run, with an "untested CLI
/// version" chip.
const kCodexTestedVersions = ((0, 164, 0), (0, 165, 0));

sealed class CodexEvent {
  const CodexEvent();
}

/// `thread.started`: the session's id, on a new thread and a resumed one.
class CodexThreadStarted extends CodexEvent {
  const CodexThreadStarted(this.threadId);

  final String threadId;
}

/// A finished agent message: one whole text block.
class CodexMessage extends CodexEvent {
  const CodexMessage(this.text);

  final String text;
}

/// A finished item that isn't a message: a command, an edit, a search.
class CodexTool extends CodexEvent {
  const CodexTool(this.name);

  final String name;
}

/// `turn.completed`, or `turn.failed` with [error] saying why.
class CodexTurnEnded extends CodexEvent {
  const CodexTurnEnded({this.error});

  final String? error;
}

class CodexIgnored extends CodexEvent {
  const CodexIgnored();
}

class CodexParseException implements Exception {
  CodexParseException(this.reason, this.line);

  final String reason;
  final String line;

  @override
  String toString() => 'CodexParseException: $reason in: $line';
}

/// What an item type shows as in an activity part. Types not listed show as
/// themselves.
const _toolNames = {
  'command_execution': 'Shell',
  'file_change': 'Edit',
  'web_search': 'WebSearch',
  'mcp_tool_call': 'MCP',
};

/// Item types that aren't the agent acting: its reasoning, its plan, and
/// warnings Codex reports as items.
const _notTools = {'reasoning', 'todo_list', 'error'};

CodexEvent parseCodexLine(String line) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    throw CodexParseException('not JSON', line);
  }
  if (decoded is! Map<String, Object?>) {
    throw CodexParseException('not an object', line);
  }
  T field<T>(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! T) throw CodexParseException('bad "$key"', line);
    return value;
  }

  switch (field<String>(decoded, 'type')) {
    case 'thread.started':
      return CodexThreadStarted(field<String>(decoded, 'thread_id'));
    case 'item.completed':
      final item = field<Map<String, Object?>>(decoded, 'item');
      final type = field<String>(item, 'type');
      if (type == 'agent_message') {
        return CodexMessage(field<String>(item, 'text'));
      }
      if (_notTools.contains(type)) return const CodexIgnored();
      return CodexTool(_toolNames[type] ?? type);
    case 'turn.completed':
      return const CodexTurnEnded();
    case 'turn.failed':
      final error = field<Map<String, Object?>>(decoded, 'error');
      return CodexTurnEnded(
        error: codexErrorText(field<String>(error, 'message')),
      );
    default:
      // Including `item.started`: an item counts once, when it completes,
      // and `error`, which `turn.failed` repeats.
      return const CodexIgnored();
  }
}

/// A turn's error message is often the API's JSON error as a string; its own
/// message, when it is.
String codexErrorText(String message) {
  try {
    if (jsonDecode(message) case {'error': {'message': final String inner}}) {
      return inner;
    }
  } on FormatException {
    // Plain text.
  }
  return message;
}

/// What Gaia reads of [event]: an agent message is a whole text block.
List<GaiaAgentEvent> gaiaEventsOf(CodexEvent event) => switch (event) {
  CodexMessage(:final text) => [
    const GaiaTextStart(),
    GaiaTextDelta(text.trimRight()),
  ],
  CodexTool(:final name) => [GaiaToolUse(name)],
  CodexThreadStarted() || CodexTurnEnded() || CodexIgnored() => const [],
};
