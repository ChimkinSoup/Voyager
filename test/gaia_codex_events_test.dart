import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_setup.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';

/// Contract tests for the Codex adapter (GAIA_HLD.md §5.1): every fixture is
/// real `codex exec --json` output recorded from codex-cli 0.164.0.
List<CodexEvent> _events(String fixture) => [
  for (final line in File(
    'test/fixtures/gaia/codex/$fixture',
  ).readAsLinesSync())
    if (line.trim().isNotEmpty) parseCodexLine(line),
];

List<GaiaPart> _build(List<CodexEvent> events) {
  final builder = GaiaTurnBuilder();
  for (final event in events) {
    gaiaEventsOf(event).forEach(builder.apply);
  }
  return builder.finished;
}

void main() {
  test('every fixture parses', () {
    for (final file in Directory('test/fixtures/gaia/codex').listSync()) {
      for (final line in File(file.path).readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        expect(() => parseCodexLine(line), returnsNormally, reason: file.path);
      }
    }
  });

  test('a new thread: its id, each message a text block, then the end', () {
    final events = _events('single_turn.jsonl');
    expect(
      events.whereType<CodexThreadStarted>().single.threadId,
      '01a1746d-ee2c-70a1-a6d6-3ad02d683ffe',
    );
    expect(events.last, isA<CodexTurnEnded>());
    expect((events.last as CodexTurnEnded).error, isNull);
    expect(_build(events).map((part) => part.toJson()), [
      {'type': 'text', 'text': 'Hello.'},
      {
        'type': 'text',
        'text': 'Done. The shell command was blocked by policy.',
      },
    ]);
  });

  test('a resumed thread with a command: activity between the texts', () {
    final events = _events('resume_command.jsonl');
    expect(
      events.whereType<CodexThreadStarted>().single.threadId,
      '01a1746d-ee2c-70a1-a6d6-3ad02d683ffe',
    );
    expect(_build(events).map((part) => part.toJson()), [
      {'type': 'text', 'text': 'I’ll run it now.'},
      {
        'type': 'activity',
        'tools': ['Shell'],
      },
      {'type': 'text', 'text': 'Output: `hi`'},
    ]);
  });

  test("an unknown model fails the turn with the API's own message", () {
    final events = _events('unknown_model.jsonl');
    final end = events.whereType<CodexTurnEnded>().single;
    expect(
      end.error,
      "The 'not-a-model' model is not supported when using Codex with a "
      'ChatGPT account.',
    );
    // The metadata warning before it is not a tool call.
    expect(_build(events), isEmpty);
  });

  test('an item type not yet recorded counts as a tool call', () {
    final event = parseCodexLine(
      '{"type":"item.completed","item":{"id":"i","type":"file_change"}}',
    );
    expect(gaiaEventsOf(event).single, isA<GaiaToolUse>());
    expect((gaiaEventsOf(event).single as GaiaToolUse).name, 'Edit');
  });

  test('a known event missing a field it needs is a parse failure', () {
    expect(
      () => parseCodexLine('{"type":"thread.started"}'),
      throwsA(isA<CodexParseException>()),
    );
    expect(
      () => parseCodexLine(
        '{"type":"item.completed","item":{"type":"agent_message"}}',
      ),
      throwsA(isA<CodexParseException>()),
    );
  });

  test('a plain-text error stays as it is', () {
    expect(codexErrorText('stream disconnected'), 'stream disconnected');
  });

  test("the Windows sandbox is read from the [windows] table only", () {
    expect(
      parseCodexWindowsSandbox(
        'model = "gpt-6.1-sol"\nsandbox = "nope"\n\n'
        '[windows]\nsandbox = "elevated"\n\n[hooks]\nsandbox = "no"\n',
      ),
      'elevated',
    );
    expect(parseCodexWindowsSandbox('model = "x"\n'), isNull);
  });

  test('login status', () {
    expect(parseCodexLoginStatus('Logged in using ChatGPT\n'), isTrue);
    expect(parseCodexLoginStatus('Not logged in\n'), isFalse);
    expect(parseCodexLoginStatus('something else'), isNull);
  });

  test('versions', () {
    expect(parseCliVersion('codex-cli 0.164.0'), (0, 164, 0));
    expect(isVersionInRange((0, 164, 0), kCodexTestedVersions), isTrue);
    expect(isVersionInRange((0, 165, 0), kCodexTestedVersions), isFalse);
  });

  test('the sandbox is ready when none is used, or once set up', () async {
    final dir = Directory.systemTemp.createTempSync('gaia_codex_ready_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final user = Directory(p.join(dir.path, 'user'))..createSync();
    final gaia = p.join(dir.path, 'gaia');

    expect(
      await codexSandboxReady(codexHome: gaia, userCodexHome: user.path),
      isTrue,
    );
    File(
      p.join(user.path, 'config.toml'),
    ).writeAsStringSync('[windows]\nsandbox = "elevated"\n');
    expect(
      await codexSandboxReady(codexHome: gaia, userCodexHome: user.path),
      isFalse,
    );
    File(p.join(gaia, '.sandbox', 'setup_marker.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    expect(
      await codexSandboxReady(codexHome: gaia, userCodexHome: user.path),
      isTrue,
    );
  });
}
