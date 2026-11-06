import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';

/// Where a native fork cuts its source session (GAIA_FORKING_HLD.md §5.2),
/// read from a session file written here as the CLI writes one.
void main() {
  late Directory root;
  late ClaudeCodeRunner runner;
  late GaiaAccount account;
  late File session;

  void write(List<Map<String, Object?>> entries) => session
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '${entries.map(jsonEncode).join('\n')}\n',
      mode: FileMode.append,
    );

  Map<String, Object?> entry(String uuid, String? parent, String type) => {
    'type': type,
    'uuid': uuid,
    'parentUuid': parent,
  };

  /// Prompt p0 → reply r0, then prompt p1 → tool use, tool result, reply r1.
  void twoTurns() => write([
    {'type': 'session-owner'},
    entry('p0', null, 'user'),
    entry('r0', 'p0', 'assistant'),
    entry('d0', 'r0', 'system'),
    entry('p1', 'd0', 'user'),
    entry('t1', 'p1', 'assistant'),
    entry('tr1', 't1', 'user'),
    entry('r1', 'tr1', 'assistant'),
    {'type': 'file-history-snapshot'},
  ]);

  Future<String?> cut({
    required String after,
    List<String> next = const [],
    String? awaiting,
  }) => runner.forkCut(
    chatId: 'c1',
    sessionId: 's1',
    account: account,
    after: after,
    next: next,
    awaiting: awaiting,
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('gaia_claude_fork_');
    runner = ClaudeCodeRunner(
      workingDirectory: p.join(root.path, 'ws'),
      instructionsFile: p.join(root.path, 'GAIA.md'),
    );
    account = GaiaAccount(
      id: 'a',
      label: 'a',
      adapter: kGaiaClaudeCodeAdapter,
      dir: p.join(root.path, 'a'),
    );
    session = File(p.join(account.dir, 'projects', 'C--gaia-ws', 's1.jsonl'));
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('before the next prompt: what that prompt hangs off', () async {
    twoTurns();
    expect(await cut(after: 'p0', next: ['p1']), 'd0');
  });

  test('a next prompt the session never had is passed over', () async {
    twoTurns();
    expect(await cut(after: 'p0', next: ['elsewhere', 'p1']), 'd0');
  });

  test("with nothing after it, the session's last message", () async {
    twoTurns();
    expect(await cut(after: 'p1'), 'r1');
    expect(await cut(after: 'p1', next: ['elsewhere']), 'r1');
  });

  test('with nothing after it and an end given, that end', () async {
    twoTurns();
    expect(
      await runner.forkCut(
        chatId: 'c1',
        sessionId: 's1',
        account: account,
        after: 'p0',
        next: const [],
        endAt: 'r0',
      ),
      'r0',
    );
    // A next prompt the session has still wins.
    expect(
      await runner.forkCut(
        chatId: 'c1',
        sessionId: 's1',
        account: account,
        after: 'p0',
        next: const ['p1'],
        endAt: 'r0',
      ),
      'd0',
    );
  });

  test('the prompt it must have answered is missing: none', () async {
    twoTurns();
    expect(await cut(after: 'before-ids', next: ['p1']), isNull);
  });

  test('no session file: none', () async {
    expect(await cut(after: 'p0', next: ['p1']), isNull);
  });

  test('a first prompt has nothing before it: none', () async {
    twoTurns();
    write([entry('p2', null, 'user')]);
    expect(await cut(after: 'p1', next: ['p2']), isNull);
  });

  test('a prompt just sent is waited for', () async {
    twoTurns();
    final cutting = cut(after: 'p1', next: ['p2'], awaiting: 'p2');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    write([entry('p2', 'r1', 'user')]);
    expect(await cutting, 'r1');
  });

  test("a prompt just sent that doesn't come: none", () async {
    twoTurns();
    final started = DateTime.now();
    expect(await cut(after: 'p1', next: ['p2'], awaiting: 'p2'), isNull);
    expect(
      DateTime.now().difference(started),
      greaterThan(const Duration(seconds: 4)),
    );
  });

  test('a line cut off mid-write is skipped', () async {
    twoTurns();
    session.writeAsStringSync(
      '{"type":"user","uuid":"p2","par',
      mode: FileMode.append,
    );
    expect(await cut(after: 'p1'), 'r1');
  });
}
