import 'package:fake_async/fake_async.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';

import 'fakes/gaia_fakes.dart';

/// The real main-instance and companion halves of Gaia (GAIA_HLD.md §3.2)
/// talking over an in-memory pipe, each companion with a fake CLI and
/// window: what happens across the process boundary.

/// One launched companion.
class _Launched {
  _Launched(this.controller, this.runner, this.window);

  final GaiaController controller;
  final FakeClaudeRunner runner;
  final FakeGaiaWindow window;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryFileSystem fs;
  late FakeGaiaPipe pipe;
  late List<_Launched> launched;
  late List<int> exits;
  late List<int> killed;
  late AppDatabase db;

  tearDown(() => db.close());

  setUp(() {
    db = AppDatabase.inMemory();
    fs = MemoryFileSystem();
    pipe = FakeGaiaPipe.main();
    launched = [];
    exits = [];
    killed = [];
    pipe.onLaunch = (end, _) {
      final runner = FakeClaudeRunner();
      final window = FakeGaiaWindow();
      final controller = GaiaController(
        pipe: end,
        window: window,
        runners: {kGaiaClaudeCodeAdapter: runner},
        cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
        exit: exits.add,
      );
      launched.add(_Launched(controller, runner, window));
      controller.start();
    };
  });

  /// Starts the main instance's half in fake time, and runs [body].
  void run(void Function(FakeAsync async, GaiaHost host) body) {
    fakeAsync((async) {
      final host = GaiaHost(
        pipe: pipe,
        abortFlag: () async => fs.file('gaia_aborted'),
        killCompanion: (pid) async => killed.add(pid),
      );
      host.start(registerHotkeys: false, show: false);
      host.attach(
        repository: DriftGaiaRepository(db),
        deviceId: 'laptop',
        toast: (_, _, _) {},
      );
      async.flushMicrotasks();
      body(async, host);
    });
  }

  test('G before the companion is up opens the window once it connects', () {
    run((async, host) {
      host.onHotkey(GaiaHotkey.window);
      async.elapse(Duration.zero);
      expect(launched.single.window.shown, GaiaMode.window);
    });
  });

  test('a chat survives a companion crash; the reply it cut off is marked '
      'interrupted', () {
    run((async, host) {
      host.onHotkey(GaiaHotkey.window);
      async.elapse(Duration.zero);
      final first = launched.single;
      first.runner.turns
        ..addAll(claudeFixtureTurns('single_turn.jsonl'))
        ..add([const ClaudeTextStart(), const ClaudeTextDelta('cut')]);
      first.controller.send('Hi');
      async.flushMicrotasks();
      first.controller.send('More');
      async.flushMicrotasks();
      final chatId = first.controller.currentChatId!;

      // The companion process dies.
      pipe.disconnect();
      async.flushMicrotasks();
      expect(first.runner.killAllCount, 1);
      expect(exits, [0]);

      async.elapse(const Duration(seconds: 2));
      final second = launched[1].controller;
      async.flushMicrotasks();
      expect(second.chats.single.id, chatId);
      second.selectChat(chatId);
      async.flushMicrotasks();
      expect(second.messages.map((m) => m.status), [
        GaiaMessageStatus.complete,
        GaiaMessageStatus.complete,
        GaiaMessageStatus.complete,
        GaiaMessageStatus.interrupted,
      ]);
      // What it streamed in its last second is lost: replies are written
      // through at most once a second.
      // Its session carries on in the new companion.
      launched[1].runner.turns.addAll(claudeFixtureTurns('resume.jsonl'));
      second.send('And now?');
      async.flushMicrotasks();
      expect(
        launched[1].runner.sent.single.sessionId,
        '80a82cab-3135-41d0-806c-e0b1fd2eb5df',
      );
    });
  });

  test('Abort stops the run, holds across a companion restart, and Re-arm '
      'clears it', () {
    run((async, host) {
      host.onHotkey(GaiaHotkey.window);
      async.elapse(Duration.zero);
      final first = launched.single;
      first.runner.turns.add([const ClaudeTextStart()]);
      first.controller.send('Hi');
      async.flushMicrotasks();

      host.onHotkey(GaiaHotkey.abort);
      async.flushMicrotasks();
      expect(first.runner.killAllCount, 1);
      expect(first.controller.aborted, isTrue);
      expect(first.controller.messages.last.status, GaiaMessageStatus.aborted);
      expect(fs.file('gaia_aborted').existsSync(), isTrue);
      async.elapse(const Duration(seconds: 2));
      expect(killed, isEmpty, reason: 'it confirmed in time');

      pipe.disconnect();
      async.elapse(const Duration(seconds: 2));
      final second = launched[1].controller;
      async.flushMicrotasks();
      expect(second.aborted, isTrue);

      second.rearm();
      async.flushMicrotasks();
      expect(second.aborted, isFalse);
      expect(fs.file('gaia_aborted').existsSync(), isFalse);
    });
  });

  test("the companion follows Voyager's accent", () {
    run((async, host) {
      host.accent = 0xFF4CC38A;
      host.onHotkey(GaiaHotkey.window);
      async.elapse(Duration.zero);
      final controller = launched.single.controller;
      expect(controller.accent.value, 0xFF4CC38A);

      host.accent = 0xFFFFA94D;
      async.flushMicrotasks();
      expect(controller.accent.value, 0xFFFFA94D);
    });
  });
}
