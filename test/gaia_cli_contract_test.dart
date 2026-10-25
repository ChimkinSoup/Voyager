import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/domain/models/gaia_models.dart';

/// FRAGILE(cli): the Claude Code contract (GAIA_HLD.md §5.1) against the
/// real, installed CLI. Gaia's own invocation ([ClaudeCodeRunner]) must
/// still produce output its parser reads, for each shape of turn Gaia relies
/// on.
///
/// Skipped unless GAIA_CLI_CHECK=1: run it with qa/harness/gaia_cli_check.ps1
/// whenever Claude Code updates. It makes a few real model calls, on the
/// subscription login as Gaia does. Each scenario's raw output goes to
/// `qa/logs/gaia_cli/<version>/<scenario>.jsonl`, to refresh the fixtures
/// from.
final _enabled = Platform.environment['GAIA_CLI_CHECK'] == '1';

const _uuid = Uuid();
const _timeout = Timeout(Duration(minutes: 5));

/// The model the contract pins, as a tier's agent would.
const _model = 'claude-opus-5-5';

/// What a line the parser ignores is: its type, and its subtype or event.
String _shape(String line) {
  final json = jsonDecode(line) as Map;
  final type = json['type'];
  final sub = switch (type) {
    'system' => json['subtype'],
    'stream_event' => (json['event'] as Map?)?['type'],
    _ => null,
  };
  return sub == null ? '$type' : '$type/$sub';
}

String _text(List<ClaudeEvent> events) {
  final builder = GaiaTurnBuilder();
  for (final event in events) {
    if (gaiaEventOf(event) case final event?) builder.apply(event);
  }
  return [
    for (final part in builder.finished)
      if (part is GaiaTextPart) part.text,
  ].join();
}

void main() {
  late Directory workingDirectory;
  late Directory transcripts;
  final ignored = <String, int>{};

  setUpAll(() async {
    if (!_enabled) return;
    final version = await claudeCodeVersion();
    expect(
      version,
      isNotNull,
      reason: '`claude --version` failed: is Claude Code installed?',
    );
    final (major, minor, patch) = version!;
    final name = '$major.$minor.$patch';
    debugPrint(
      'GAIA-CLI version $name '
      '${isTestedClaudeVersion(version) ? 'tested' : 'untested'}',
    );
    workingDirectory = Directory.systemTemp.createTempSync('gaia_cli_check_');
    transcripts = Directory(p.join('qa', 'logs', 'gaia_cli', name))
      ..createSync(recursive: true);
  });

  tearDownAll(() {
    if (!_enabled) return;
    for (final MapEntry(:key, :value) in ignored.entries) {
      debugPrint('GAIA-CLI ignored $key x$value');
    }
    try {
      workingDirectory.deleteSync(recursive: true);
    } on FileSystemException {
      // The CLI may still hold it for a moment.
    }
  });

  /// A runner whose raw output goes to [scenario]'s transcript, and whose
  /// lines the parser ignores are tallied.
  ClaudeCodeRunner runner(String scenario) {
    final transcript = File(p.join(transcripts.path, '$scenario.jsonl'))
      ..writeAsStringSync('');
    return ClaudeCodeRunner(
      workingDirectory: workingDirectory.path,
      instructionsFile: p.join(workingDirectory.path, '..', 'GAIA.md'),
      onLine: (line) {
        transcript.writeAsStringSync('$line\n', mode: FileMode.append);
        if (line.trim().isEmpty) return;
        try {
          if (parseClaudeLine(line) is ClaudeIgnored) {
            ignored.update(_shape(line), (n) => n + 1, ifAbsent: () => 1);
          }
        } on ClaudeParseException {
          // The runner fails the turn with it.
        }
      },
    );
  }

  Future<(ClaudeResult, List<ClaudeEvent>)> turn(
    ClaudeCodeRunner runner, {
    required String sessionId,
    required bool resume,
    required String prompt,
    String model = _model,
  }) async {
    final events = <ClaudeEvent>[];
    final result = await runner.sendRaw(
      chatId: 'contract',
      sessionId: resume ? sessionId : null,
      newSessionId: sessionId,
      model: model,
      prompt: prompt,
      onEvent: events.add,
    );
    return (result, events);
  }

  test(
    'a plain turn streams text and ends with its session result',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final cli = runner('single_turn');
      final sessionId = _uuid.v4();
      try {
        final (result, events) = await turn(
          cli,
          sessionId: sessionId,
          resume: false,
          prompt:
              'Reply with exactly these words and nothing else: '
              'gaia contract ok',
        );
        final init = events.whereType<ClaudeInit>().first;
        expect(init.sessionId, sessionId);
        expect(init.model, _model, reason: 'the model pin');
        expect(events.whereType<ClaudeTextStart>(), isNotEmpty);
        expect(events.whereType<ClaudeTextDelta>(), isNotEmpty);
        expect(result.isError, isFalse, reason: result.text);
        expect(result.sessionId, sessionId);
        expect(result.text.toLowerCase(), contains('gaia contract ok'));
        expect(_text(events).toLowerCase(), contains('gaia contract ok'));
      } finally {
        await cli.killAll();
      }
    },
  );

  test(
    'a tool call, a second turn on the same process, and a resume after '
    'the process is killed',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final sessionId = _uuid.v4();
      final first = runner('tool_call_two_turns');
      try {
        final (toolResult, toolEvents) = await turn(
          first,
          sessionId: sessionId,
          resume: false,
          prompt:
              'Use the Bash tool to run `echo gaia-contract`, then tell '
              'me exactly what it printed.',
        );
        expect(
          toolEvents.whereType<ClaudeToolUse>().map((e) => e.name),
          contains('Bash'),
        );
        expect(toolResult.isError, isFalse, reason: toolResult.text);
        expect(toolResult.text, contains('gaia-contract'));

        final (doneResult, _) = await turn(
          first,
          sessionId: sessionId,
          resume: true,
          prompt: 'Reply with exactly: done',
        );
        expect(doneResult.isError, isFalse, reason: doneResult.text);
        expect(doneResult.text.toLowerCase(), contains('done'));
      } finally {
        await first.killAll();
      }

      // As after the 10-minute idle kill: a new process resumes the session.
      final second = runner('resume');
      try {
        final (result, _) = await turn(
          second,
          sessionId: sessionId,
          resume: true,
          prompt:
              'What exactly did the command you ran earlier print? '
              'Reply with just that.',
        );
        expect(result.isError, isFalse, reason: result.text);
        expect(result.sessionId, sessionId);
        expect(result.text, contains('gaia-contract'));
      } finally {
        await second.killAll();
      }
    },
  );

  test(
    'an unknown model ends the turn with an error result',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final cli = runner('unknown_model');
      try {
        final (result, _) = await turn(
          cli,
          sessionId: _uuid.v4(),
          resume: false,
          prompt: 'Hi',
          model: 'claude-nonexistent-9',
        );
        expect(result.isError, isTrue);
        expect(result.text, isNotEmpty);
      } finally {
        await cli.killAll();
      }
    },
  );
}
