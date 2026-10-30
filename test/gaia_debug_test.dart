import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// For scripts with no cards, which never call it.
class _NoTools implements GaiaTurnTools {
  @override
  Future<GaiaToolResult> call(String name, Map<String, Object?> arguments) =>
      throw UnimplementedError();

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) => throw UnimplementedError();
}

/// Answers reads with [listed]; proposals wait on [answer], when there's
/// more than one in play, as their cards do.
class _RecordingTools implements GaiaTurnTools {
  _RecordingTools(this.listed);

  final String listed;
  final calls = <({String name, Map<String, Object?> arguments})>[];
  final answer = Completer<void>();

  @override
  Future<GaiaToolResult> call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    calls.add((name: name, arguments: arguments));
    if (name.startsWith('voyager_')) return (text: listed, isError: false);
    if (listed.isEmpty) await answer.future;
    return (text: 'told $name', isError: false);
  }

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) => throw UnimplementedError();
}

/// The Gaia debug menu's toggles, kept in a local file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gaia_debug_test');
    file = File('${dir.path}/gaia/debug.json');
  });

  tearDown(() async {
    timeDilation = 1;
    await dir.delete(recursive: true);
  });

  test('toggles survive a restart', () async {
    final before = GaiaDebug(file: file);
    await before.setScriptedReplies(true);
    await before.setDummyMode(true);
    await before.setReplyDelay(const Duration(milliseconds: 3500));
    await before.setStreamSpeed(50);
    await before.setSlowAnimations(true);
    await before.setAllowScreenshots(true);
    timeDilation = 1;

    final after = GaiaDebug(file: file);
    await after.load();
    expect(after.scriptedReplies, isTrue);
    expect(after.dummyMode, isTrue);
    expect(after.replyDelay, const Duration(milliseconds: 3500));
    expect(after.streamSpeed, 50);
    expect(after.slowAnimations, isTrue);
    expect(after.showFps, isFalse);
    expect(after.allowScreenshots, isTrue);
    expect(timeDilation, 10);
  });

  test("a slider's drag is saved only once it's let go", () async {
    final debug = GaiaDebug(file: file);
    await debug.setStreamSpeed(50, save: false);
    expect(debug.streamSpeed, 50);
    expect(await file.exists(), isFalse);
    await debug.setStreamSpeed(100);
    final after = GaiaDebug(file: file);
    await after.load();
    expect(after.streamSpeed, 100);
  });

  test('an unreadable file leaves the defaults', () async {
    await file.parent.create(recursive: true);
    await file.writeAsString('{not json');
    final debug = GaiaDebug(file: file);
    await debug.load();
    expect(debug.scriptedReplies, isFalse);
    expect(debug.streamSpeed, 400);
  });

  test(
    'a value of the wrong type leaves every toggle at its default',
    () async {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '{"scriptedReplies": true, "replyDelayMs": "1500", "showFps": false}',
      );
      final debug = GaiaDebug(file: file);
      await debug.load();
      expect(debug.scriptedReplies, isFalse);
    },
  );

  test('a slow stream keeps to its speed', () async {
    const script = GaiaDebugScript('', [GaiaDebugText('0123456789')]);
    final clock = Stopwatch()..start();
    await GaiaScriptedRunner().send(
      chatId: 'c',
      script: script,
      replyDelay: Duration.zero,
      streamSpeed: 25,
      onEvent: (_) {},
      tools: _NoTools(),
    );
    // Ten characters at 25 a second: 400ms, not the 300ms that rounding
    // each 30ms tick up to a character gave.
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(390));
  });

  test('a change proposal finds the first row that does not repeat', () async {
    final tools = _RecordingTools(
      '## Inbox\n'
      '- [ ] Renew id card (repeats, id aaa)\n'
      '- [x] Book flights (id done-1)\n'
      '- [ ] Check repeats in the log (starred, id bbb-1)\n',
    );
    final events = <GaiaAgentEvent>[];
    await GaiaScriptedRunner().send(
      chatId: 'c',
      script: gaiaDebugScripts['/propose5']!,
      replyDelay: Duration.zero,
      streamSpeed: 6400,
      onEvent: events.add,
      tools: tools,
    );
    expect(tools.calls.map((c) => c.name), ['voyager_todos', 'propose_todo']);
    expect(tools.calls.last.arguments['id'], 'bbb-1');
    // What the agent would be told shows in the reply.
    expect(
      events.whereType<GaiaTextDelta>().map((e) => e.text).join(),
      endsWith('told propose_todo'),
    );
  });

  test("an event's notes don't hide its id", () async {
    final tools = _RecordingTools(
      '## Fri 30 Oct\n'
      '- 08:00–09:00 Gym [Home] (done, id ev-0)\n'
      '- 10:00–11:00 Dentist [Home] (id ev-1) Notes: bring card\n',
    );
    await GaiaScriptedRunner().send(
      chatId: 'c',
      script: gaiaDebugScripts['/propose6']!,
      replyDelay: Duration.zero,
      streamSpeed: 6400,
      onEvent: (_) {},
      tools: tools,
    );
    expect(tools.calls.first.name, 'voyager_calendar');
    expect(tools.calls.last.arguments['id'], 'ev-1');
  });

  test('proposals in one step are raised together', () async {
    final tools = _RecordingTools('');
    final run = GaiaScriptedRunner().send(
      chatId: 'c',
      script: gaiaDebugScripts['/propose8']!,
      replyDelay: Duration.zero,
      streamSpeed: 6400,
      onEvent: (_) {},
      tools: tools,
    );
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // All three are waiting on their cards at once.
    expect(tools.calls.map((c) => c.name), [
      'propose_todo',
      'propose_calendar_event',
      'propose_journal_entry',
    ]);
    tools.answer.complete();
    await run;
  });

  test('commands match only while scripted replies are on', () async {
    final debug = GaiaDebug();
    expect(debug.scriptFor('/msg1'), isNull);
    await debug.setScriptedReplies(true);
    expect(debug.scriptFor(' /MSG1 '), isNotNull);
    expect(debug.scriptFor('/msg1 please'), isNull);
    expect(debug.scriptFor('/help'), isNotNull);
  });

  test('dummy mode answers every message, commands still scripted', () async {
    final debug = GaiaDebug();
    await debug.setDummyMode(true);
    expect(debug.scriptFor('hello'), same(gaiaDummyScript));
    expect(debug.scriptFor('/msg1'), same(gaiaDummyScript));
    await debug.setScriptedReplies(true);
    expect(debug.scriptFor('/msg1'), same(gaiaDebugScripts['/msg1']));
    expect(debug.scriptFor('hello'), same(gaiaDummyScript));
  });
}
