import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
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
    if (name != 'ask_user') return (text: 'unexpected tool', isError: true);
    asked.add(arguments);
    final options = (arguments['options'] as List?) ?? const [];
    final last = options.isEmpty ? 'Blue' : (options.last as Map)['label'];
    return (text: 'The user chose: "$last".', isError: false);
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
