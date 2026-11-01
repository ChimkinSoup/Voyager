import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';

void main() {
  late Directory root;
  late ClaudeCodeRunner runner;
  late GaiaAccount a;
  late GaiaAccount b;

  GaiaAccount account(String id) => GaiaAccount(
    id: id,
    label: id,
    adapter: kGaiaClaudeCodeAdapter,
    dir: p.join(root.path, id),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('gaia_claude_copy_');
    runner = ClaudeCodeRunner(
      workingDirectory: p.join(root.path, 'ws'),
      instructionsFile: p.join(root.path, 'GAIA.md'),
    );
    a = account('a');
    b = account('b');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('copies the session and its files under the same project', () async {
    final project = p.join(a.dir, 'projects', 'C--gaia-ws');
    File(p.join(project, 's1.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('transcript');
    File(p.join(project, 's1', 'subagents', 'x.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('subagent');
    File(p.join(project, 'other.jsonl')).writeAsStringSync('another chat');

    expect(await runner.copySession(sessionId: 's1', from: a, to: b), isTrue);

    final copied = p.join(b.dir, 'projects', 'C--gaia-ws');
    expect(File(p.join(copied, 's1.jsonl')).readAsStringSync(), 'transcript');
    expect(
      File(p.join(copied, 's1', 'subagents', 'x.jsonl')).readAsStringSync(),
      'subagent',
    );
    expect(File(p.join(copied, 'other.jsonl')).existsSync(), isFalse);
  });

  test('a session that isn\'t there is false', () async {
    expect(await runner.copySession(sessionId: 's1', from: a, to: b), isFalse);
    Directory(
      p.join(a.dir, 'projects', 'C--gaia-ws'),
    ).createSync(recursive: true);
    expect(await runner.copySession(sessionId: 's1', from: a, to: b), isFalse);
  });

  test('two accounts on one folder leave the file alone', () async {
    final file = File(p.join(a.dir, 'projects', 'C--gaia-ws', 's1.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('transcript');
    final same = GaiaAccount(
      id: 'same',
      label: 'same',
      adapter: kGaiaClaudeCodeAdapter,
      dir: a.dir,
    );
    expect(
      await runner.copySession(sessionId: 's1', from: a, to: same),
      isTrue,
    );
    expect(file.readAsStringSync(), 'transcript');
  });
}
