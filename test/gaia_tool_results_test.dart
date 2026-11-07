import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_activity_chip.dart';
import 'package:voyager/features/gaia/companion/gaia_tool_results.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// The `os_*` reads' results, kept on the device that ran them for the user to
/// see under each call (GAIA_HLD.md §15.6).

class _KeepingTools implements GaiaTurnTools, GaiaResultKeeper {
  _KeepingTools({this.error = false});

  final bool error;
  final kept = <(String, String, String)>[];

  @override
  Future<GaiaToolResult> call(String name, Map<String, Object?> arguments) =>
      Future.value(GaiaToolResult(text: 'read $name', isError: error));

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) async => (allow: true, message: '');

  @override
  void keep(String callId, String name, GaiaToolResult result) =>
      kept.add((callId, name, result.text));
}

Map<String, Object?> _call(String name, {Map<String, Object?>? meta}) => {
  'jsonrpc': '2.0',
  'id': 3,
  'method': 'tools/call',
  'params': {
    'name': name,
    'arguments': <String, Object?>{},
    '_meta': ?meta,
  },
};

void main() {
  group('keeping a read', () {
    test("under Claude Code's tool use id, from the call's _meta", () async {
      final tools = _KeepingTools();
      await gaiaMcpAnswer(
        _call('os_read_screen', meta: {'claudecode/toolUseId': 'toolu_1'}),
        tools,
      );
      expect(tools.kept, [('toolu_1', 'os_read_screen', 'read os_read_screen')]);
    });

    test("under the call id Codex gives", () async {
      final tools = _KeepingTools();
      await gaiaMcpAnswer(_call('os_windows'), tools, callId: 'exec-1');
      expect(tools.kept, [('exec-1', 'os_windows', 'read os_windows')]);
    });

    test('not for other tools, failed reads, or a call with no id', () async {
      final tools = _KeepingTools();
      await gaiaMcpAnswer(_call('voyager_todos'), tools, callId: 'a');
      await gaiaMcpAnswer(_call('os_read_screen'), tools);
      final failing = _KeepingTools(error: true);
      await gaiaMcpAnswer(_call('os_screenshot'), failing, callId: 'b');
      expect(tools.kept, isEmpty);
      expect(failing.kept, isEmpty);
    });
  });

  test("a reply's activity part keeps the reads' ids, and only theirs", () {
    final builder = GaiaTurnBuilder()
      ..apply(const GaiaToolUse('Bash', id: 'x'))
      ..apply(const GaiaToolUse('os_read_screen', id: 'y'));
    final part = builder.parts.single as GaiaActivityPart;
    expect(part.idAt(0), isNull);
    expect(part.idAt(1), 'y');
    final again = GaiaPart.fromJson(part.toJson()) as GaiaActivityPart;
    expect(again.ids, [null, 'y']);
    // A part with none says nothing of them.
    expect(const GaiaActivityPart(['Bash']).toJson().containsKey('ids'), false);
  });

  group('the store', () {
    late Directory root;
    late GaiaToolResultStore store;
    const shot = GaiaToolResult(
      text: 'The image is 2x2.',
      isError: false,
      image: 'aGk=',
      mimeType: 'image/png',
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('gaia_results');
      store = GaiaToolResultStore(root);
    });
    tearDown(() => root.delete(recursive: true));

    test('reads back what it kept, image and all', () async {
      await store.save('chat', 'toolu_1', shot);
      expect(store.has('chat', 'toolu_1'), isTrue);
      expect(await store.read('chat', 'toolu_1'), shot);
      expect(await store.read('chat', 'other'), isNull);
      // A fresh store knows once it has listed the chat.
      final fresh = GaiaToolResultStore(root);
      expect(fresh.has('chat', 'toolu_1'), isFalse);
      await fresh.list('chat');
      expect(fresh.has('chat', 'toolu_1'), isTrue);
    });

    test('copies to a fork, forgets, and prunes chats that are gone', () async {
      await store.save('a', '1', shot);
      await store.save('a', '2', shot);
      await store.save('gone', '3', shot);
      await store.copy('a', 'fork', ['1', 'missing']);
      expect(await store.read('fork', '1'), shot);
      expect(store.has('fork', 'missing'), isFalse);
      await store.remove('a', ['2']);
      expect(await store.read('a', '2'), isNull);
      await store.prune({'a', 'fork'});
      expect(await store.read('gone', '3'), isNull);
      expect(await store.read('a', '1'), shot);
    });

    test('an id is only ever a file name in its chat', () async {
      await store.save('chat', r'..\..\x', shot);
      expect(store.has('chat', r'..\..\x'), isTrue);
      expect(
        root.listSync(recursive: true).whereType<File>().single.parent.path,
        Directory('${root.path}${Platform.pathSeparator}chat').path,
      );
    });
  });

  testWidgets('opened, a kept call shows what it answered', (tester) async {
    const part = GaiaActivityPart(['Bash', 'os_read_screen'], ids: [null, 'y']);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GaiaActivityChip(
            label: 'Used 2 tools',
            part: part,
            hasResult: (id) => id == 'y',
            result: (id) async =>
                const GaiaToolResult(text: 'Button "Save"', isError: false),
          ),
        ),
      ),
    );
    expect(find.text('Button "Save"'), findsNothing);
    await tester.tap(find.text('Used 2 tools'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Button "Save"'), findsOneWidget);
  });

  testWidgets('a long result shows its start until Show all', (tester) async {
    final long = '${'a' * 4000}TAIL${'b' * 1000}';
    const part = GaiaActivityPart(['os_read_screen'], ids: ['y']);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GaiaActivityChip(
              label: 'Used 1 tool',
              part: part,
              hasResult: (_) => true,
              result: (_) async => GaiaToolResult(text: long, isError: false),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Used 1 tool'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('TAIL'), findsNothing);
    await tester.tap(find.text('Show all (5,004 characters)'));
    await tester.pump();
    expect(find.textContaining('TAIL'), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);
  });

  testWidgets('elsewhere, the call shows as before', (tester) async {
    const part = GaiaActivityPart(['os_read_screen'], ids: ['y']);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GaiaActivityChip(
            label: 'Used 1 tool',
            part: part,
            hasResult: (_) => false,
            result: (_) async => null,
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });
}
