import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';

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
    await before.setReplyDelay(const Duration(milliseconds: 3500));
    await before.setStreamSpeed(50);
    await before.setSlowAnimations(true);
    timeDilation = 1;

    final after = GaiaDebug(file: file);
    await after.load();
    expect(after.scriptedReplies, isTrue);
    expect(after.replyDelay, const Duration(milliseconds: 3500));
    expect(after.streamSpeed, 50);
    expect(after.slowAnimations, isTrue);
    expect(after.showFps, isFalse);
    expect(timeDilation, 5);
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
    );
    // Ten characters at 25 a second: 400ms, not the 300ms that rounding
    // each 30ms tick up to a character gave.
    expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(390));
  });

  test('commands match only while scripted replies are on', () async {
    final debug = GaiaDebug();
    expect(debug.scriptFor('/msg1'), isNull);
    await debug.setScriptedReplies(true);
    expect(debug.scriptFor(' /MSG1 '), isNotNull);
    expect(debug.scriptFor('/msg1 please'), isNull);
    expect(debug.scriptFor('/help'), isNotNull);
  });
}
