import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

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

/// Answers every question with its last option, and denies every
/// permission, recording each.
class _ContractTools implements GaiaTurnTools {
  final calls = <String>[];
  final asked = <Map<String, Object?>>[];
  final permits = <String>[];

  @override
  Future<GaiaToolResult> call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    calls.add(name);
    if (name != 'ask_user') {
      return const GaiaToolResult(text: 'unexpected tool', isError: true);
    }
    asked.add(arguments);
    final options = (arguments['options'] as List?) ?? const [];
    final last = options.isEmpty ? 'Blue' : (options.last as Map)['label'];
    return GaiaToolResult(text: 'The user chose: "$last".', isError: false);
  }

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) async {
    permits.add(tool);
    return (allow: false, message: 'The user declined.');
  }
}

/// Allows every permission, recording each, as a chat in Auto does
/// (GAIA_AUTONOMY_HLD.md §5.7).
class _AllowTools implements GaiaTurnTools {
  final permits = <String>[];

  @override
  Future<GaiaToolResult> call(
    String name,
    Map<String, Object?> arguments,
  ) async => const GaiaToolResult(text: 'unexpected tool', isError: true);

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) async {
    permits.add('$tool ${input['command'] ?? ''}');
    return (allow: true, message: '');
  }
}

/// `os_screenshot` answered with a solid green picture, which a model can only
/// describe if the image reached it (§15.6).
class _ScreenshotTools implements GaiaTurnTools {
  final calls = <String>[];

  @override
  Future<GaiaToolResult> call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    calls.add(name);
    final picture = img.Image(width: 64, height: 64);
    img.fill(picture, color: img.ColorRgb8(0, 200, 0));
    return GaiaToolResult(
      text: 'The window, as a picture.',
      isError: false,
      image: base64Encode(img.encodePng(picture)),
      mimeType: 'image/png',
    );
  }

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) async => (allow: false, message: 'The user declined.');
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
    String sessionInstructions = '',
  }) async {
    final events = <ClaudeEvent>[];
    final result = await runner.sendRaw(
      chatId: 'contract',
      sessionId: resume ? sessionId : null,
      newSessionId: sessionId,
      model: model,
      prompt: prompt,
      sessionInstructions: sessionInstructions,
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
    'a stopped turn taken back is gone from the next turn, which resumes '
    'past it with the hidden rewind flags (§9.6)',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final cli = runner('take_back');
      // Cheap: the flags don't depend on the model.
      Future<GaiaTurnResult> send(
        String? sessionId,
        String prompt, {
        void Function(GaiaAgentEvent event)? onEvent,
      }) => cli.send(
        chatId: 'contract',
        sessionId: sessionId,
        model: 'haiku',
        prompt: prompt,
        onEvent: onEvent ?? (_) {},
      );
      try {
        final first = await send(
          null,
          'Remember the word BANANA. Reply with just OK.',
        );
        expect(first.isError, isFalse, reason: first.text);
        final sessionId = first.sessionId;

        // Stopped once its reply has started, as Stop is pressed.
        var stopped = false;
        final second = send(
          sessionId,
          'The second word is CHERRY. Now write a 600-word poem about '
          'cherries.',
          onEvent: (event) {
            if (stopped || event is! GaiaTextDelta) return;
            stopped = true;
            unawaited(cli.stop('contract'));
          },
        );
        await expectLater(second, throwsA(isA<GaiaRunException>()));
        expect(await cli.takeBack('contract'), isNull);

        final third = await send(
          sessionId,
          'List every word I have told you in this conversation, '
          'comma-separated, nothing else.',
        );
        expect(third.isError, isFalse, reason: third.text);
        expect(third.notice, isNull, reason: 'the cut held');
        expect(third.text.toUpperCase(), contains('BANANA'));
        expect(third.text.toUpperCase(), isNot(contains('CHERRY')));

        // A later plain resume follows the branch.
        await cli.killAll();
        final fourth = await send(
          sessionId,
          'Did I ever mention a fruit other than banana? Answer yes or no.',
        );
        expect(fourth.text.toUpperCase(), isNot(contains('CHERRY')));
        expect(fourth.text.toLowerCase(), contains('no'));
      } finally {
        await cli.killAll();
        final rewinds = File(
          p.join(workingDirectory.parent.path, 'claude-rewinds.json'),
        );
        if (rewinds.existsSync()) rewinds.deleteSync();
      }
    },
  );

  test(
    'a stop while the process starts ends the turn before its prompt goes, '
    'with nothing to take back',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final cli = runner('stop_starting');
      Future<GaiaTurnResult> send(String? sessionId, String prompt) => cli.send(
        chatId: 'contract',
        sessionId: sessionId,
        model: 'haiku',
        prompt: prompt,
        onEvent: (_) {},
      );
      try {
        final first = await send(
          null,
          'Remember the word BANANA. Reply with just OK.',
        );
        expect(first.isError, isFalse, reason: first.text);
        final sessionId = first.sessionId;
        // A new process for the turn: the idle one goes on stop.
        await cli.killAll();

        final second = send(sessionId, 'The second word is CHERRY.');
        await cli.stop('contract');
        await expectLater(second, throwsA(isA<GaiaRunException>()));
        expect(await cli.takeBack('contract'), isNull);

        final third = await send(
          sessionId,
          'List every word I have told you in this conversation, '
          'comma-separated, nothing else.',
        );
        expect(third.isError, isFalse, reason: third.text);
        expect(third.text.toUpperCase(), contains('BANANA'));
        expect(third.text.toUpperCase(), isNot(contains('CHERRY')));
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
    "a session's own instructions (the memory index, §11) in its system "
    'prompt, kept by a resume in a new process that gives none',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      const index =
          '# Memories\n\n- The user has a dog called Biscuit. [pets]\n'
          '- The user has a cat called Mochi. [pets]';
      final sessionId = _uuid.v4();
      final first = runner('session_instructions');
      try {
        final (result, _) = await turn(
          first,
          sessionId: sessionId,
          resume: false,
          prompt: "What is my dog's name? One word.",
          sessionInstructions: index,
        );
        expect(result.isError, isFalse, reason: result.text);
        expect(result.text, contains('Biscuit'));
        // Gone once read, and the live process still has it.
        expect(
          File(
            p.join(workingDirectory.path, '..', 'sessions', 'contract.md'),
          ).existsSync(),
          isFalse,
        );
        final (next, _) = await turn(
          first,
          sessionId: sessionId,
          resume: true,
          prompt: "And my cat's name? One word.",
        );
        expect(next.isError, isFalse, reason: next.text);
        expect(next.text, contains('Mochi'));
      } finally {
        await first.killAll();
      }
      final second = runner('session_instructions_resume');
      try {
        final (result, _) = await turn(
          second,
          sessionId: sessionId,
          resume: true,
          prompt: "And my cat's name? One word.",
        );
        expect(result.isError, isFalse, reason: result.text);
        expect(result.text, contains('Mochi'));
      } finally {
        await second.killAll();
      }
    },
  );

  test(
    "an image in a Gaia tool's result reaches the model",
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final cli = runner('tool_image');
      final tools = _ScreenshotTools();
      try {
        final result = await cli.sendRaw(
          chatId: 'contract',
          sessionId: null,
          newSessionId: _uuid.v4(),
          model: _model,
          prompt:
              'Call the gaia os_screenshot tool once. What colour fills the '
              'image it returns? Answer in one word, from what you see: if '
              'you received no image, say "none".',
          tools: tools,
          onEvent: (_) {},
        );
        expect(result.isError, isFalse, reason: result.text);
        expect(tools.calls, ['os_screenshot']);
        expect(result.text.toLowerCase(), contains('green'));
      } finally {
        await cli.killAll();
      }
    },
  );

  test(
    "Gaia's tools over the control channel: ask_user answered, and a "
    'permission prompt denied',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      // A project rule that always asks, whatever the user's permission
      // mode: safe mode still reads project settings (checked on 2.1.312).
      final rules = File(
        p.join(workingDirectory.path, '.claude', 'settings.json'),
      )..createSync(recursive: true);
      rules.writeAsStringSync(
        '{"permissions":{"ask":["Bash(echo gaia-permission*)"]}}',
      );
      final cli = runner('gaia_tools');
      final tools = _ContractTools();
      try {
        final events = <ClaudeEvent>[];
        final result = await cli.sendRaw(
          chatId: 'contract',
          sessionId: null,
          newSessionId: _uuid.v4(),
          model: _model,
          prompt:
              'First call the gaia ask_user tool with the question "Pick a '
              'colour" and the options Red and Blue. Then use the Bash tool '
              'to run `echo gaia-permission`. Finally tell me which colour '
              'I picked and whether the command ran.',
          tools: tools,
          onEvent: events.add,
        );
        expect(result.isError, isFalse, reason: result.text);
        expect(tools.calls, contains('ask_user'));
        expect(tools.asked.single['question'], contains('colour'));
        expect(tools.permits, ['Bash']);
        expect(result.text, contains('Blue'));
        expect(
          events.whereType<ClaudeToolUse>().map((e) => e.name),
          contains('mcp__gaia__ask_user'),
        );
      } finally {
        await cli.killAll();
        rules.parent.deleteSync(recursive: true);
      }
    },
  );

  test(
    'Auto (GAIA_AUTONOMY_HLD.md §5.7): a settings deny rule refuses without '
    'reaching permit, and permit allows the rest',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final rules = File(
        p.join(workingDirectory.path, '.claude', 'settings.json'),
      )..createSync(recursive: true);
      rules.writeAsStringSync(
        '{"permissions":{"deny":["Bash(echo gaia-denied*)"],'
        '"ask":["Bash(echo gaia-allowed*)"]}}',
      );
      final cli = runner('auto_deny_rule');
      final tools = _AllowTools();
      try {
        final result = await cli.sendRaw(
          chatId: 'contract',
          sessionId: null,
          newSessionId: _uuid.v4(),
          model: _model,
          prompt:
              'Use the Bash tool to run `echo gaia-allowed`. Then use it to '
              'run `echo gaia-denied`. Then say, for each, exactly what it '
              'printed or why it did not run.',
          tools: tools,
          onEvent: (_) {},
        );
        debugPrint('GAIA-CLI auto deny: permits ${tools.permits}');
        debugPrint('GAIA-CLI auto deny: ${result.text}');
        expect(result.isError, isFalse, reason: result.text);
        expect(tools.permits, [contains('gaia-allowed')]);
        expect(result.text, contains('gaia-allowed'));
      } finally {
        await cli.killAll();
        rules.parent.deleteSync(recursive: true);
      }
    },
  );

  test(
    'Auto (§5.7): a stopped turn ends the shell command it was running',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final marker = File(p.join(workingDirectory.path, 'gaia-stop-probe.txt'));
      if (marker.existsSync()) marker.deleteSync();
      final cli = runner('auto_stop_mid_command');
      final started = Completer<void>();
      final tools = _AllowTools();
      final path = marker.path.replaceAll(r'\', '/');
      final turn = cli
          .sendRaw(
            chatId: 'contract',
            sessionId: null,
            newSessionId: _uuid.v4(),
            model: _model,
            prompt:
                'Use the Bash tool, in the foreground and not in the '
                'background, to run exactly this command, and wait for it: '
                'powershell -NoProfile -Command "Start-Sleep -Seconds 20; '
                "Set-Content -Path '$path' -Value done\"",
            tools: tools,
            onEvent: (event) {
              if (event case ClaudeToolUse(
                name: 'Bash',
              ) when !started.isCompleted) {
                started.complete();
              }
            },
          )
          .then<Object?>((result) => result, onError: (Object e) => e);
      try {
        await started.future.timeout(const Duration(minutes: 2));
        await Future<void>.delayed(const Duration(seconds: 6));
        await cli.stop('contract');
        debugPrint('GAIA-CLI auto stop: the turn ended with ${await turn}');
        await Future<void>.delayed(const Duration(seconds: 25));
        debugPrint(
          'GAIA-CLI auto stop: permits ${tools.permits}; the command '
          '${marker.existsSync() ? 'finished after the stop' : 'was ended'}',
        );
        expect(marker.existsSync(), isFalse);
      } finally {
        await cli.killAll();
        if (marker.existsSync()) marker.deleteSync();
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
