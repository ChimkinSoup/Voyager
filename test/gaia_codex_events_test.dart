import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_setup.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';

/// Contract tests for the Codex adapter (GAIA_HLD.md §5.1): every fixture is
/// real `codex exec --json` output recorded from codex-cli 0.166.0.
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
      '01a19d6f-c7ba-7ac0-8205-83c571e7ed67',
    );
    expect(events.last, isA<CodexTurnEnded>());
    expect((events.last as CodexTurnEnded).error, isNull);
    expect(_build(events).map((part) => part.toJson()), [
      {'type': 'text', 'text': 'gaia contract ok'},
    ]);
  });

  test('a resumed thread with a command: activity between the texts', () {
    final events = _events('resume_command.jsonl');
    expect(
      events.whereType<CodexThreadStarted>().single.threadId,
      '01a19d6f-c7ba-7ac0-8205-83c571e7ed67',
    );
    expect(_build(events).map((part) => part.toJson()), [
      {'type': 'text', 'text': 'I’ll run the command and report its output.'},
      {
        'type': 'activity',
        'tools': ['Shell'],
        'details': [
          r'"C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" '
              "-Command 'echo gaia-contract'",
        ],
      },
      {'type': 'text', 'text': 'gaia-contract'},
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

  test('a failed call says why in brief, a succeeded one nothing', () {
    String? failure(String item) =>
        codexToolFailure(jsonDecode(item) as Map<String, Object?>);
    expect(failure('{"exit_code":0,"status":"completed"}'), isNull);
    expect(failure('{"exit_code":2,"status":"failed"}'), 'Exit code 2');
    expect(failure('{"exitCode":null,"status":"declined"}'), 'Declined');
    expect(
      failure('{"status":"failed","error":{"message":"refused\\nmore"}}'),
      'refused',
    );
    expect(failure('{"success":false}'), 'Failed');
    expect(failure('{"query":"x"}'), isNull);
  });

  test("a search, an edit and an MCP call show what they did", () {
    GaiaToolUse use(String item) =>
        gaiaEventsOf(
              parseCodexLine('{"type":"item.completed","item":$item}'),
            ).single
            as GaiaToolUse;
    expect(
      use('{"id":"i","type":"web_search","query":"flutter 4"}').detail,
      'flutter 4',
    );
    expect(
      use(
        '{"id":"i","type":"file_change","changes":'
        '[{"path":"a.txt","kind":"add"},{"path":"b.txt","kind":"update"}]}',
      ).detail,
      'a.txt\nb.txt',
    );
    // No paths is no detail, not an empty one dressed as JSON.
    expect(
      use('{"id":"i","type":"file_change","changes":[]}').detail,
      isNull,
    );
    expect(gaiaClipDetail(' \n'), isNull);
    expect(
      gaiaClipDetail('x' * (kGaiaToolDetailMax + 1)),
      '${'x' * kGaiaToolDetailMax}…',
    );
    expect(
      use(
        '{"id":"i","type":"mcp_tool_call","server":"docs","tool":"find",'
        '"arguments":{"q":"x"}}',
      ).detail,
      'docs/find {"q":"x"}',
    );
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
    expect(parseCliVersion('codex-cli 0.166.0'), (0, 166, 0));
    expect(isVersionInRange((0, 166, 0), kCodexTestedVersions), isTrue);
    expect(isVersionInRange((0, 167, 0), kCodexTestedVersions), isFalse);
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
