import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_app_server.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// FRAGILE(cli): the Codex contract (GAIA_HLD.md §5.1) against the real,
/// installed CLI, through Gaia's own invocations. On `exec` ([CodexRunner]):
/// a new thread, a resume of it in a new process with a shell command, and
/// an unknown model. On `app-server` ([CodexAppServerRunner]): `ask_user`
/// and a permission prompt in one turn, a second turn on the same process,
/// a resume in a new one, an unknown model and a missing thread.
///
/// Skipped unless GAIA_CLI_CHECK=1, as test/gaia_cli_contract_test.dart. It
/// makes a few real model calls on the user's ChatGPT login. Each scenario's
/// raw output goes to `qa/logs/gaia_cli/codex-<version>/<scenario>.jsonl`.
///
/// Its Codex home is kept between runs (`%TEMP%\gaia_codex_contract`): each
/// new home needs the Windows sandbox set up behind an approval prompt, so
/// only the first run asks.
final _enabled = Platform.environment['GAIA_CLI_CHECK'] == '1';

const _timeout = Timeout(Duration(minutes: 5));

/// Override with GAIA_CODEX_MODEL: the models a ChatGPT login offers change.
final _model = Platform.environment['GAIA_CODEX_MODEL'] ?? 'gpt-6.1-sol';

/// Answers every question with its last option, and denies every
/// permission, recording each.
class _ContractTools implements GaiaTurnTools {
  final asked = <Map<String, Object?>>[];
  final permits = <String>[];

  @override
  Future<GaiaToolResult> call(
    String name,
    Map<String, Object?> arguments,
  ) async {
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

/// [tools], saying when the first permission is asked for.
class _StartedTools implements GaiaTurnTools {
  _StartedTools(this.tools, this.asked);

  final GaiaTurnTools tools;
  final Completer<void> asked;

  @override
  Future<GaiaToolResult> call(String name, Map<String, Object?> arguments) =>
      tools.call(name, arguments);

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) {
    if (!asked.isCompleted) asked.complete();
    return tools.permit(tool: tool, input: input, description: description);
  }
}

void main() {
  late Directory root;
  late Directory transcripts;

  setUpAll(() async {
    if (!_enabled) return;
    final version = await codexVersion();
    expect(version, isNotNull, reason: '`codex --version` failed');
    final (major, minor, patch) = version!;
    debugPrint(
      'GAIA-CLI codex $major.$minor.$patch '
      '${isVersionInRange(version, kCodexTestedVersions) ? 'tested' : 'untested'}',
    );
    root = Directory(p.join(Directory.systemTemp.path, 'gaia_codex_contract'))
      ..createSync(recursive: true);
    final home = p.join(root.path, 'home');
    if (!await codexSandboxReady(codexHome: home)) {
      debugPrint('GAIA-CLI setting up the Codex sandbox: approve the prompt');
      expect(
        await setUpCodexSandbox(codexHome: home),
        isTrue,
        reason: 'the sandbox setup was not approved',
      );
    }
    transcripts = Directory(
      p.join('qa', 'logs', 'gaia_cli', 'codex-$major.$minor.$patch'),
    )..createSync(recursive: true);
  });

  CodexRunner runner(String scenario) {
    final transcript = File(p.join(transcripts.path, '$scenario.jsonl'))
      ..writeAsStringSync('');
    return CodexRunner(
      workingDirectory: p.join(root.path, 'ws'),
      codexHome: p.join(root.path, 'home'),
      onLine: (line) =>
          transcript.writeAsStringSync('$line\n', mode: FileMode.append),
    );
  }

  CodexAppServerRunner appServer(String scenario) {
    final transcript = File(p.join(transcripts.path, '$scenario.jsonl'))
      ..writeAsStringSync('');
    return CodexAppServerRunner(
      workingDirectory: p.join(root.path, 'ws'),
      codexHome: p.join(root.path, 'home'),
      // Never used: a turn that fell back would write no transcript.
      fallback: CodexRunner(
        workingDirectory: p.join(root.path, 'ws'),
        codexHome: p.join(root.path, 'home'),
      ),
      onLine: (line) =>
          transcript.writeAsStringSync('$line\n', mode: FileMode.append),
    );
  }

  String text(List<GaiaAgentEvent> events) {
    final builder = GaiaTurnBuilder();
    events.forEach(builder.apply);
    return [
      for (final part in builder.finished)
        if (part is GaiaTextPart) part.text,
    ].join('\n');
  }

  test(
    'a new thread, then a resume with a shell command in a new process',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final first = runner('single_turn');
      await first.setInstructions('Keep every reply under twenty words.');
      final events = <GaiaAgentEvent>[];
      final result = await first.send(
        chatId: 'contract',
        sessionId: null,
        model: _model,
        prompt: 'Reply with exactly these words: gaia contract ok',
        onEvent: events.add,
      );
      expect(result.isError, isFalse, reason: result.text);
      expect(result.sessionId, isNotEmpty);
      expect(text(events).toLowerCase(), contains('gaia contract ok'));

      final second = runner('resume_command');
      final resumed = <GaiaAgentEvent>[];
      final again = await second.send(
        chatId: 'contract',
        sessionId: result.sessionId,
        model: _model,
        prompt:
            'Run the shell command `echo gaia-contract`, then tell me exactly '
            'what it printed.',
        onEvent: resumed.add,
      );
      expect(again.isError, isFalse, reason: again.text);
      expect(again.sessionId, result.sessionId);
      expect(resumed.whereType<GaiaToolUse>(), isNotEmpty);
      expect(text(resumed), contains('gaia-contract'));
    },
  );

  test(
    'an unknown model ends the turn with an error result',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final result = await runner('unknown_model').send(
        chatId: 'contract',
        sessionId: null,
        model: 'not-a-model',
        prompt: 'Hi',
        onEvent: (_) {},
      );
      expect(result.isError, isTrue);
      expect(result.text, isNotEmpty);
    },
  );

  test(
    'app-server: ask_user and a denied permission in one turn, a second '
    'turn on the process, then a resume in a new one',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final first = appServer('app_server_tools');
      final tools = _ContractTools();
      final events = <GaiaAgentEvent>[];
      try {
        final result = await first.send(
          chatId: 'contract',
          sessionId: null,
          model: _model,
          prompt:
              'Use the ask_user tool to ask me my favourite colour, with the '
              'options Red and Blue. Then create a file named gaia-probe.txt '
              'containing hi in the current directory with a shell command. '
              'Then tell me what I chose.',
          tools: tools,
          onEvent: events.add,
        );
        expect(result.isError, isFalse, reason: result.text);
        expect(result.sessionId, isNotEmpty);
        expect(tools.asked, isNotEmpty);
        expect(tools.permits, contains('Shell'));
        expect(
          events.whereType<GaiaToolUse>().map((event) => event.name),
          contains('ask_user'),
        );
        expect(events.whereType<GaiaTextDelta>().length, greaterThan(1));
        expect(text(events), contains('Blue'));

        final again = <GaiaAgentEvent>[];
        final second = await first.send(
          chatId: 'contract',
          sessionId: result.sessionId,
          model: _model,
          prompt: 'Reply with exactly these words: gaia contract ok',
          tools: tools,
          onEvent: again.add,
        );
        expect(second.isError, isFalse, reason: second.text);
        expect(second.sessionId, result.sessionId);
        expect(second.contextTokens, isNotNull);
        expect(text(again).toLowerCase(), contains('gaia contract ok'));
        await first.killAll();

        final resumed = <GaiaAgentEvent>[];
        final third = await appServer('app_server_resume').send(
          chatId: 'contract',
          sessionId: result.sessionId,
          model: _model,
          prompt: 'What colour did I choose earlier? One word.',
          tools: tools,
          onEvent: resumed.add,
        );
        expect(third.isError, isFalse, reason: third.text);
        expect(third.sessionId, result.sessionId);
        expect(text(resumed), contains('Blue'));
      } finally {
        await first.killAll();
      }
    },
  );

  test(
    'app-server, Auto (GAIA_AUTONOMY_HLD.md §5.7): a command permit allows '
    'runs as whom, and a stopped turn ends the command it was running',
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 8)),
    () async {
      final ws = p.join(root.path, 'ws');
      Directory(ws).createSync(recursive: true);
      final who = File(p.join(ws, 'gaia-whoami.txt'));
      final marker = File(p.join(ws, 'gaia-stop-probe.txt'));
      for (final file in [who, marker]) {
        if (file.existsSync()) file.deleteSync();
      }
      final cli = appServer('app_server_auto');
      try {
        final tools = _AllowTools();
        final result = await cli.send(
          chatId: 'contract',
          sessionId: null,
          model: _model,
          prompt:
              'With one shell command, write the output of whoami to a file '
              'named gaia-whoami.txt in the current directory. Then reply '
              'with what it wrote.',
          tools: tools,
          onEvent: (_) {},
        );
        expect(result.isError, isFalse, reason: result.text);
        final user = Platform.environment['USERNAME'] ?? '';
        // PowerShell writes UTF-16: its ASCII, with the zero bytes left out.
        final wrote = who.existsSync()
            ? String.fromCharCodes(
                who.readAsBytesSync().where((b) => b > 0 && b < 0x80),
              ).trim()
            : '';
        debugPrint(
          'GAIA-CLI codex auto: permits ${tools.permits}; whoami wrote '
          '"$wrote", the user is "$user"',
        );
        expect(wrote, isNotEmpty);

        final asked = Completer<void>();
        final stopping = _AllowTools();
        final turn = cli
            .send(
              chatId: 'contract',
              sessionId: result.sessionId,
              model: _model,
              prompt:
                  'Run exactly this shell command and wait for it to finish: '
                  'powershell -NoProfile -Command "Start-Sleep -Seconds 20; '
                  "Set-Content -Path 'gaia-stop-probe.txt' -Value done\"",
              tools: _StartedTools(stopping, asked),
              onEvent: (event) {
                if (event is GaiaToolUse && !asked.isCompleted) {
                  asked.complete();
                }
              },
            )
            .then<Object?>((result) => result, onError: (Object e) => e);
        await asked.future.timeout(const Duration(minutes: 2));
        await Future<void>.delayed(const Duration(seconds: 6));
        await cli.stop('contract');
        final ended = await turn;
        debugPrint(
          'GAIA-CLI codex auto stop: the turn ended with '
          '${ended is GaiaTurnResult ? ended.text : ended}',
        );
        await Future<void>.delayed(const Duration(seconds: 25));
        debugPrint(
          'GAIA-CLI codex auto stop: permits ${stopping.permits}; the '
          'command '
          '${marker.existsSync() ? 'finished after the stop' : 'was ended'}',
        );
      } finally {
        await cli.killAll();
        for (final file in [who, marker]) {
          if (file.existsSync()) file.deleteSync();
        }
      }
    },
  );

  test(
    "app-server: an image in a Gaia tool's result reaches the model",
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final server = appServer('app_server_tool_image');
      final tools = _ScreenshotTools();
      final events = <GaiaAgentEvent>[];
      try {
        final result = await server.send(
          chatId: 'contract',
          sessionId: null,
          model: _model,
          prompt:
              'Call the gaia os_screenshot tool once. What colour fills the '
              'image it returns? Answer in one word, from what you see: if '
              'you received no image, say "none".',
          tools: tools,
          onEvent: events.add,
        );
        expect(result.isError, isFalse, reason: result.text);
        expect(tools.calls, ['os_screenshot']);
        expect(text(events).toLowerCase(), contains('green'));
      } finally {
        await server.killAll();
      }
    },
  );

  test(
    "app-server: a thread's developer instructions (the memory index, §11), "
    'kept by a resume in a new process that gives none',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      const index =
          '# Memories\n\n- The user has a dog called Biscuit. [pets]\n'
          '- The user has a cat called Mochi. [pets]';
      final first = appServer('app_server_instructions');
      final events = <GaiaAgentEvent>[];
      try {
        final result = await first.send(
          chatId: 'contract',
          sessionId: null,
          model: _model,
          prompt: "What is my dog's name? One word.",
          sessionInstructions: index,
          onEvent: events.add,
        );
        expect(result.isError, isFalse, reason: result.text);
        expect(text(events), contains('Biscuit'));
        await first.killAll();

        final resumed = <GaiaAgentEvent>[];
        final again = await appServer('app_server_instructions_resume').send(
          chatId: 'contract',
          sessionId: result.sessionId,
          model: _model,
          prompt: "And my cat's name? One word.",
          onEvent: resumed.add,
        );
        expect(again.isError, isFalse, reason: again.text);
        expect(again.sessionId, result.sessionId);
        expect(text(resumed), contains('Mochi'));
      } finally {
        await first.killAll();
      }
    },
  );

  test(
    'a stop while the process starts ends the turn before its prompt goes, '
    'with nothing to take back: exec, then app-server',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final exec = runner('stop_starting');
      final server = appServer('app_server_stop_starting');
      try {
        for (final GaiaAgentRunner cli in [exec, server]) {
          final turn = cli.send(
            chatId: 'contract',
            sessionId: null,
            model: _model,
            prompt: 'Reply with just OK.',
            onEvent: (_) {},
          );
          await cli.stop('contract');
          await expectLater(
            turn,
            throwsA(isA<GaiaRunException>()),
            reason: '${cli.runtimeType}',
          );
          expect(
            await cli.takeBack('contract'),
            isNull,
            reason: '${cli.runtimeType}',
          );
        }
      } finally {
        await exec.killAll();
        await server.killAll();
      }
    },
  );

  test(
    'app-server: an unknown model ends the turn with an error result',
    skip: !_enabled,
    timeout: _timeout,
    () async {
      final server = appServer('app_server_unknown_model');
      try {
        final result = await server.send(
          chatId: 'contract',
          sessionId: null,
          model: 'not-a-model',
          prompt: 'Hi',
          onEvent: (_) {},
        );
        expect(result.isError, isTrue);
        expect(result.text, contains('not-a-model'));
      } finally {
        await server.killAll();
      }
    },
  );

  test(
    "app-server: a thread Codex doesn't have isn't found",
    skip: !_enabled,
    timeout: _timeout,
    () async {
      const missing = '019a0000-0000-7000-8000-000000000000';
      final record = File(p.join(root.path, 'home', 'gaia-threads.json'));
      final recorded = record.existsSync()
          ? (jsonDecode(record.readAsStringSync()) as Map)
          : <String, Object?>{};
      record.writeAsStringSync(
        jsonEncode({...recorded, missing: kCodexToolsHash}),
      );
      final server = appServer('app_server_missing_thread');
      try {
        final result = await server.send(
          chatId: 'contract',
          sessionId: missing,
          model: _model,
          prompt: 'Hi',
          onEvent: (_) {},
        );
        expect(result.sessionFound, isFalse);
        expect(result.isError, isTrue);
      } finally {
        await server.killAll();
      }
    },
  );
}
