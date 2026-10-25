import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';

/// FRAGILE(cli): the Codex contract (GAIA_HLD.md §5.1) against the real,
/// installed CLI, through Gaia's own invocation ([CodexRunner]): a new
/// thread, a resume of it in a new process with a shell command, and an
/// unknown model.
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
}
