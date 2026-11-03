import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/host/gaia_os_control.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart';
import 'package:win32/win32.dart';

const _target = (
  hwnd: 7,
  pid: 70,
  exe: 'notepad',
  app: 'Notepad',
  title: 'notes.txt',
  console: false,
);

GaiaControlMatch _button({bool sensitive = false, int left = 10}) => (
  type: 'Button',
  sensitive: sensitive,
  left: left,
  top: 10,
  right: left + 20,
  bottom: 30,
);

class _Backend implements GaiaInputBackend {
  GaiaForegroundWindow? window = _target;
  var front = 7;
  var gaiaInFront = false;
  var activates = true;
  var rootUnder = 7;
  var matches = <GaiaControlMatch>[_button()];
  String? url;
  bool? sensitiveFocus = false;
  var modifiers = false;
  var escape = false;
  var swapped = false;

  /// What [send] takes of each call; all when null.
  int? sendLimit;
  final sent = <GaiaInputEvent>[];
  final calls = <List<GaiaInputEvent>>[];
  final cursor = <(int, int)>[];
  var activated = 0;

  /// How many asks Windows refuses before it agrees: no right to the foreground.
  var refusals = 0;

  /// How many asks Windows agrees to and then does nothing about.
  var ignoredAsks = 0;

  /// [GaiaInputBackend.lastInput]: what's sent moves it, and tests move it as a
  /// user would.
  var inputTick = 0;

  /// Other windows, by hwnd.
  final windows = <int, GaiaForegroundWindow>{};

  /// How many looks at the foreground it takes Windows to switch; never when
  /// null. Windows agrees to a switch before it has made it.
  int? activateLag = 0;

  /// Runs at each look while a switch is pending.
  void Function()? duringSwitch;
  var _switching = false;

  /// Runs once per [send], after it, to change things mid-run.
  void Function()? onSend;

  @override
  GaiaForegroundWindow? target(int gaiaPid) => window;
  @override
  GaiaForegroundWindow? describe(int hwnd) => windows[hwnd] ?? window;
  @override
  int foreground() {
    if (_switching) {
      duringSwitch?.call();
      if (activateLag case final lag? when lag <= 0) {
        front = _target.hwnd;
        _switching = false;
      } else if (activateLag != null) {
        activateLag = activateLag! - 1;
      }
    }
    return front;
  }

  @override
  bool inFrontOfTarget(int hwnd, int gaiaPid) => gaiaInFront;
  @override
  bool activate(int hwnd) {
    activated++;
    if (refusals > 0) {
      refusals--;
      return false;
    }
    if (ignoredAsks > 0) {
      ignoredAsks--;
      return true;
    }
    _switching = activates;
    return activates;
  }

  @override
  int rootAt(int x, int y) => rootUnder;
  @override
  ({int left, int top, int width, int height}) frame(int hwnd) =>
      (left: 0, top: 0, width: 800, height: 600);
  @override
  Future<GaiaWindowScan?> find(
    int hwnd, {
    required bool browser,
    required ({String name, String? type}) control,
  }) async => (
    url: url,
    tree: '',
    cut: false,
    sensitive: const <({int left, int top, int right, int bottom})>[],
    unjudged: const <({int left, int top, int right, int bottom})>[],
    matches: matches,
    controls: 0,
    hasDocument: false,
    sensitiveFocused: false,
    anyFocused: false,
  );
  @override
  Future<String?> address(int hwnd) async => url;
  @override
  Future<bool?> focusSensitive(int hwnd, {required bool browser}) async =>
      sensitiveFocus;
  @override
  bool modifiersDown() => modifiers;
  @override
  bool escapeDown() => escape;
  @override
  int lastInput() => inputTick;
  @override
  void watchInput(bool on) {}
  @override
  void moveCursor(int x, int y) => cursor.add((x, y));
  @override
  bool get buttonsSwapped => swapped;
  @override
  int send(List<GaiaInputEvent> events) {
    final took = sendLimit ?? events.length;
    calls.add(events);
    sent.addAll(events.take(took));
    inputTick++;
    sendLimit = null;
    onSend?.call();
    return took;
  }
}

void main() {
  late _Backend backend;
  late List<String> excluded;
  late bool vault;
  late GaiaOsControl control;

  setUp(() {
    backend = _Backend();
    excluded = [];
    vault = false;
    control = GaiaOsControl(
      companionPid: () => 1,
      exclusions: () => excluded,
      vaultUnlocked: () => vault,
      voyagerPid: 70,
      backend: backend,
      settle: Duration.zero,
      modifierWait: const Duration(milliseconds: 40),
      activateWait: const Duration(milliseconds: 200),
    );
  });

  Future<Map<String, Object?>> plan(
    String tool,
    Map<String, Object?> arguments,
  ) => control.plan('chat', 'card', tool, arguments);

  Future<Map<String, Object?>> run({
    bool once = true,
    Future<void> Function()? check,
  }) => control.run('card', once: once, check: check ?? () async {});

  Matcher refused(String words) => throwsA(
    isA<GaiaReadException>().having(
      (e) => e.message,
      'message',
      contains(words),
    ),
  );

  List<Map<Object?, Object?>> stepsOf(Map<String, Object?> card) =>
      (card['steps']! as List).cast();

  group('plan', () {
    test(
      'shows the window and each resolved control; nothing is sent',
      () async {
        final card = await plan('os_click', {'name': 'Save', 'type': 'Button'});
        expect(card['window'], 'Notepad: "notes.txt"');
        expect(stepsOf(card).single, {
          'label': 'Click Button "Save" [10,10 20x20]',
          'resolved': true,
          // The marker hovering the step shows (GAIA_AUTONOMY_HLD.md §6.4).
          'flash': {
            'kind': 'mark',
            'x': 20,
            'y': 20,
            'left': 10,
            'top': 10,
            'right': 30,
            'bottom': 30,
            'label': 'Save',
          },
        });
        expect(backend.calls, isEmpty);
      },
    );

    test('a control not on screen yet is shown as such, unresolved', () async {
      backend.matches = [];
      final card = await plan('os_click', {'name': 'Save'});
      expect(stepsOf(card).single['resolved'], false);
      expect(stepsOf(card).single['label'], contains('not on screen yet'));
    });

    test('coordinates are a resolved target, inside the window only', () async {
      final card = await plan('os_click', {'x': 40, 'y': 50});
      expect(stepsOf(card).single['label'], 'Click at 40, 50');
      expect(stepsOf(card).single['resolved'], true);
      await expectLater(
        plan('os_click', {'x': 900, 'y': 50}),
        refused('outside'),
      );
    });

    test('several of a name need a point to choose by', () async {
      backend.matches = [_button(), _button(left: 100)];
      await expectLater(
        plan('os_click', {'name': 'Save'}),
        refused('2 controls'),
      );
      final card = await plan('os_click', {'name': 'Save', 'x': 105, 'y': 15});
      expect(stepsOf(card).single['label'], contains('[100,10'));
    });

    test('refuses excluded apps, sites and an unlocked vault', () async {
      excluded = ['notepad'];
      await expectLater(plan('os_key', {'keys': 'Enter'}), refused('excluded'));
      excluded = [];
      vault = true;
      await expectLater(plan('os_key', {'keys': 'Enter'}), refused('vault'));
      vault = false;
      backend.window = (
        hwnd: 7,
        pid: 71,
        exe: 'chrome',
        app: 'Chrome',
        title: 'Bank',
        console: false,
      );
      excluded = ['bank.example'];
      backend.url = 'https://bank.example/login';
      await expectLater(plan('os_key', {'keys': 'Enter'}), refused('excluded'));
      backend.url = null;
      await expectLater(plan('os_key', {'keys': 'Enter'}), refused('address'));
    });

    test('never types into a sensitive field by name', () async {
      backend.matches = [_button(sensitive: true)];
      await expectLater(
        plan('os_type', {'name': 'Password', 'text': 'x'}),
        refused('never types'),
      );
    });

    test('no window, or malformed calls, are refused', () async {
      await expectLater(plan('os_click', const {}), refused('needs a name'));
      await expectLater(plan('os_type', const {}), refused('needs text'));
      await expectLater(
        plan('os_type', {'text': 'x' * 2001}),
        refused('at most 2000'),
      );
      await expectLater(
        plan('os_key', {'keys': 'Win+R'}),
        refused('Windows key'),
      );
      await expectLater(
        plan('os_key', {'keys': 'Ctrl+Nope'}),
        refused('Unknown'),
      );
      await expectLater(
        plan('os_steps', {
          'steps': [
            for (var i = 0; i < 21; i++) {'action': 'key', 'keys': 'A'},
          ],
        }),
        refused('at most 20'),
      );
      backend.window = null;
      await expectLater(plan('os_key', {'keys': 'A'}), refused('no window'));
    });
  });

  group('run', () {
    test('clicks the middle of the control as it is now', () async {
      await plan('os_click', {'name': 'Save'});
      backend.matches = [_button(left: 100)];
      final result = await run();
      expect(result['ran'], 1);
      expect(result.containsKey('stopped'), isFalse);
      expect(backend.cursor.single, (110, 20));
      expect(backend.calls.single.map((e) => (e as GaiaMouseEvent).flags), [
        MOUSEEVENTF_LEFTDOWN,
        MOUSEEVENTF_LEFTUP,
      ]);
    });

    test('a double click, a right click, and a swapped mouse', () async {
      await plan('os_steps', {
        'steps': [
          {'action': 'click', 'x': 1, 'y': 1, 'double': true},
          {'action': 'click', 'x': 1, 'y': 1, 'button': 'right'},
        ],
      });
      backend.swapped = true;
      await run();
      expect(backend.calls[0].length, 4);
      expect(
        (backend.calls[0][0] as GaiaMouseEvent).flags,
        MOUSEEVENTF_RIGHTDOWN,
      );
      expect(
        (backend.calls[1][0] as GaiaMouseEvent).flags,
        MOUSEEVENTF_LEFTDOWN,
      );
    });

    test('scrolls by notches, down as negative', () async {
      await plan('os_scroll', {'direction': 'down', 'amount': 2});
      await run();
      expect(backend.cursor.single, (400, 300));
      final wheel = backend.calls.single.single as GaiaMouseEvent;
      expect(wheel.flags, MOUSEEVENTF_WHEEL);
      expect(wheel.data, -240);
    });

    test('a chord goes as one call, released in reverse', () async {
      await plan('os_key', {'keys': 'Ctrl+Shift+S'});
      await run();
      expect(backend.calls.single, const [
        GaiaKeyEvent(VK_CONTROL, up: false),
        GaiaKeyEvent(VK_SHIFT, up: false),
        GaiaKeyEvent(0x53, up: false),
        GaiaKeyEvent(0x53, up: true),
        GaiaKeyEvent(VK_SHIFT, up: true),
        GaiaKeyEvent(VK_CONTROL, up: true),
      ]);
    });

    test('types, Enter as its key, and an emoji in one piece', () async {
      await plan('os_type', {'text': 'a\n😀'});
      await run();
      expect(backend.sent.whereType<GaiaUnicodeEvent>().map((e) => e.unit), [
        0x61,
        0x61,
        0xD83D,
        0xD83D,
        0xDE00,
        0xDE00,
      ]);
      expect(backend.sent, contains(const GaiaKeyEvent(VK_RETURN, up: false)));
    });

    test('brings the window up from behind Gaia, for the first step', () async {
      backend
        ..front = 99
        ..gaiaInFront = true;
      await plan('os_key', {'keys': 'A'});
      await run();
      expect(backend.activated, 1);
      expect(backend.front, 7);
    });

    test('waits for Windows to finish bringing it up (BUG-337)', () async {
      backend
        ..front = 99
        ..gaiaInFront = true
        ..activateLag = 3;
      await plan('os_key', {'keys': 'A'});
      final result = await run();
      expect(result['stopped'], isNull);
      expect(result['ran'], 1);
      expect(backend.front, 7);
      expect(backend.sent, contains(const GaiaKeyEvent(0x41, up: false)));
    });

    test('stops, sending nothing, if it never comes up', () async {
      backend
        ..front = 99
        ..gaiaInFront = true
        ..activateLag = null;
      await plan('os_key', {'keys': 'A'});
      final result = await run();
      expect(result['stopped'], contains("wouldn't bring"));
      expect(result['ran'], 0);
      expect(backend.calls, isEmpty);
    });

    test('stops, sending nothing, if Windows refuses', () async {
      backend
        ..front = 99
        ..gaiaInFront = true
        ..activates = false;
      await plan('os_key', {'keys': 'A'});
      final result = await run();
      expect(result['stopped'], contains("wouldn't bring"));
      expect(backend.calls, isEmpty);
    });

    test('stops, sending nothing, if another app takes the front during the '
        'switch', () async {
      backend
        ..front = 99
        ..gaiaInFront = true
        ..activateLag = null
        ..duringSwitch = () => backend.gaiaInFront = false;
      await plan('os_key', {'keys': 'A'});
      final result = await run();
      expect(result['stopped'], contains('changed'));
      expect(backend.calls, isEmpty);
    });

    test('Esc during the switch stops it', () async {
      backend
        ..front = 99
        ..gaiaInFront = true
        ..activateLag = null
        ..duringSwitch = () => backend.escape = true;
      await plan('os_key', {'keys': 'A'});
      final result = await run();
      expect(result['stopped'], contains('Esc'));
      expect(backend.calls, isEmpty);
    });

    test('stops if the window in front is another app', () async {
      backend.front = 99;
      await plan('os_key', {'keys': 'A'});
      final result = await run();
      expect(result['stopped'], contains('changed'));
      expect(result['ran'], 0);
      expect(backend.calls, isEmpty);
    });

    test('stops when a step changes the window, sending no more', () async {
      await plan('os_steps', {
        'steps': [
          {'action': 'key', 'keys': 'A'},
          {'action': 'key', 'keys': 'B'},
        ],
      });
      backend.onSend = () => backend.front = 99;
      final result = await run();
      expect(result['ran'], 1);
      expect(result['stopped'], contains('changed'));
      expect(backend.calls.length, 1);
    });

    test(
      'Gaia in front partway through a run approved once stops it',
      () async {
        await plan('os_steps', {
          'steps': [
            {'action': 'key', 'keys': 'A'},
            {'action': 'key', 'keys': 'B'},
          ],
        });
        backend.gaiaInFront = true;
        backend.onSend = () => backend.front = 99;
        final result = await run();
        expect(result['ran'], 1);
        expect(backend.activated, 0);
      },
    );

    test('stops if something covers the point', () async {
      backend.rootUnder = 99;
      await plan('os_click', {'name': 'Save'});
      final result = await run();
      expect(result['stopped'], contains('covering'));
      expect(backend.calls, isEmpty);
    });

    test('stops if the control has gone', () async {
      await plan('os_click', {'name': 'Save'});
      backend.matches = [];
      final result = await run();
      expect(result['stopped'], contains('not on screen'));
    });

    test('stops if the browser moved to an excluded site', () async {
      backend.window = (
        hwnd: 7,
        pid: 71,
        exe: 'chrome',
        app: 'Chrome',
        title: 'Page',
        console: false,
      );
      excluded = ['bank.example'];
      backend.url = 'https://fine.example/';
      await plan('os_key', {'keys': 'Tab'});
      backend.url = 'https://bank.example/';
      final result = await run();
      expect(result['stopped'], contains('excluded'));
      expect(backend.calls, isEmpty);
    });

    test('stops if the vault was unlocked since the plan', () async {
      await plan('os_key', {'keys': 'A'});
      vault = true;
      expect((await run())['stopped'], contains('vault'));
    });

    test('the check runs before each step, and stops it', () async {
      await plan('os_steps', {
        'steps': [
          {'action': 'key', 'keys': 'A'},
          {'action': 'key', 'keys': 'B'},
        ],
      });
      var checks = 0;
      final result = await run(
        check: () async {
          if (++checks == 2) {
            throw GaiaReadException('aborted: Gaia is aborted.');
          }
        },
      );
      expect(result['ran'], 1);
      expect(result['stopped'], contains('aborted'));
    });

    test('refuses typing where focus is sensitive, or unknown', () async {
      backend.sensitiveFocus = true;
      await plan('os_type', {'text': 'hunter2'});
      expect((await run())['stopped'], contains('never types'));
      expect(backend.calls, isEmpty);
      backend.sensitiveFocus = null;
      await plan('os_type', {'text': 'hunter2'});
      expect((await run())['stopped'], isNotNull);
      expect(backend.calls, isEmpty);
    });

    for (final (name, moveBy) in [('Tab', '\t'), ('Enter', '\n')]) {
      test('$name into a sensitive field stops the text there', () async {
        backend.onSend = () {
          if (backend.sent.any((event) => event is GaiaKeyEvent)) {
            backend.sensitiveFocus = true;
          }
        };
        await plan('os_type', {'text': 'alice${moveBy}hunter2'});
        expect((await run())['stopped'], contains('never types'));
        final typed = String.fromCharCodes(
          backend.sent
              .whereType<GaiaUnicodeEvent>()
              .where((e) => !e.up)
              .map((e) => e.unit),
        );
        expect(typed, 'alice');
      });
    }

    test(
      'in a sensitive field, keys that type are refused and others go',
      () async {
        backend.sensitiveFocus = true;
        await plan('os_key', {'keys': 'Ctrl+V'});
        expect((await run())['stopped'], contains('never types'));
        expect(backend.calls, isEmpty);
        await plan('os_key', {'keys': 'Shift+Insert'});
        expect((await run())['stopped'], contains('never types'));
        expect(backend.calls, isEmpty);
        await plan('os_key', {'keys': 'Tab'});
        expect((await run())['stopped'], isNull);
        expect(backend.calls, isNotEmpty);
      },
    );

    test('waits for a held modifier, as approving with Ctrl+Enter', () async {
      backend.modifiers = true;
      await plan('os_key', {'keys': 'A'});
      final running = run();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(backend.calls, isEmpty);
      backend.modifiers = false;
      expect((await running)['ran'], 1);
    });

    test('a modifier never let go stops it', () async {
      backend.modifiers = true;
      await plan('os_key', {'keys': 'A'});
      expect((await run())['stopped'], contains('modifier'));
      expect(backend.calls, isEmpty);
    });

    test('Esc stops mid-text', () async {
      await plan('os_type', {'text': 'x' * 2000});
      backend.onSend = () => backend.escape = true;
      final result = await run();
      expect(result['stopped'], contains('Esc'));
      expect(result['ran'], 0);
      expect(backend.sent.length, lessThan(4000));
    });

    test('stop() lands mid-text, as Abort does, and only its chat', () async {
      await plan('os_type', {'text': 'x' * 2000});
      var sends = 0;
      backend.onSend = () {
        if (++sends == 2) {
          control.stop('Other chat.', chatId: 'other');
          control.stop('Gaia is aborted.');
        }
      };
      final result = await run();
      expect(result['stopped'], 'Gaia is aborted.');
      expect(sends, 2);
    });

    test('a key left down by a short send is let go (§15.7)', () async {
      await plan('os_key', {'keys': 'Ctrl+A'});
      // Ctrl and A went down; their releases didn't.
      backend.sendLimit = 2;
      final result = await run();
      expect(result['stopped'], contains('refused'));
      expect(backend.calls.last, const [
        GaiaKeyEvent(0x41, up: true),
        GaiaKeyEvent(VK_CONTROL, up: true),
      ]);
    });

    test('nothing is left held after a clean run', () async {
      await plan('os_key', {'keys': 'Ctrl+A'});
      await run();
      expect(backend.calls.length, 1);
    });

    test('approving once needs every target resolved (§15.6)', () async {
      backend.matches = [];
      await plan('os_steps', {
        'steps': [
          {'action': 'key', 'keys': 'A'},
          {'action': 'click', 'name': 'Save'},
        ],
      });
      await expectLater(run(), refused('one at a time'));
      expect(backend.calls, isEmpty);
    });

    test('step by step, each run sends one and resolves the next', () async {
      backend.matches = [];
      await plan('os_steps', {
        'steps': [
          {'action': 'key', 'keys': 'A'},
          {'action': 'click', 'name': 'Save'},
        ],
      });
      backend.gaiaInFront = true;
      backend.onSend = () => backend.matches = [_button()];
      final first = await run(once: false);
      expect(first['ran'], 1);
      expect(stepsOf(first)[1]['resolved'], true);
      expect(stepsOf(first)[1]['label'], contains('[10,10'));
      backend.front = 99;
      final second = await run(once: false);
      expect(second['ran'], 2);
      expect(backend.activated, 1);
      await expectLater(run(once: false), refused('no longer waiting'));
    });

    test('one run at a time, and a dropped plan is gone', () async {
      await plan('os_key', {'keys': 'A'});
      backend.modifiers = true;
      final running = run();
      await control.plan('chat', 'other', 'os_key', {'keys': 'B'});
      await expectLater(
        control.run('other', once: true, check: () async {}),
        refused('Another'),
      );
      backend.modifiers = false;
      await running;
      control.drop('other');
      await expectLater(
        control.run('other', once: true, check: () async {}),
        refused('no longer waiting'),
      );
    });
  });

  group('Auto session (GAIA_AUTONOMY_HLD.md §5)', () {
    const gaia = (
      hwnd: 50,
      pid: 1,
      exe: 'voyager',
      app: 'Gaia',
      title: 'Gaia',
      console: false,
    );
    const other = (
      hwnd: 99,
      pid: 90,
      exe: 'calc',
      app: 'Calculator',
      title: 'Calculator',
      console: false,
    );
    late GaiaOsControl auto;
    late int stops;
    const look = Duration(milliseconds: 60);

    Future<Map<String, Object?>> act(
      String tool,
      Map<String, Object?> arguments, {
      String chat = 'chat',
    }) async {
      auto.session(chat, auto: true, onUserStop: () => stops++);
      await auto.plan(chat, 'card', tool, arguments);
      return auto.run('card', once: true, check: () async {});
    }

    setUp(() {
      stops = 0;
      backend.windows
        ..[gaia.hwnd] = gaia
        ..[other.hwnd] = other;
      auto = GaiaOsControl(
        companionPid: () => 1,
        exclusions: () => excluded,
        vaultUnlocked: () => vault,
        voyagerPid: 70,
        backend: backend,
        settle: Duration.zero,
        activateWait: const Duration(milliseconds: 200),
        adoptWithin: const Duration(milliseconds: 300),
        pauseLimit: const Duration(milliseconds: 300),
      );
    });
    tearDown(() => auto.endTurn());

    test('a chat with no session goes by what is in front, as in Ask', () {
      expect(
        auto.session('chat', auto: false, onUserStop: () => stops++),
        isNull,
      );
      expect(auto.sessionChat, isNull);
    });

    test('the plan says Auto, and needs no target shown yet', () async {
      auto.session('chat', auto: true, onUserStop: () => stops++);
      backend.matches = [];
      final card = await auto.plan('chat', 'card', 'os_click', {
        'name': 'Save',
      });
      expect(card['auto'], isTrue);
      backend.matches = [_button()];
      final result = await auto.run('card', once: true, check: () async {});
      expect(result['stopped'], isNull);
      expect(backend.cursor, hasLength(1));
    });

    test('later calls use the pin, not what is in front', () async {
      expect(
        auto.session('chat', auto: true, onUserStop: () {})?.hwnd,
        _target.hwnd,
      );
      backend.windows[_target.hwnd] = _target;
      backend.window = other;
      expect(
        auto.session('chat', auto: true, onUserStop: () {})?.hwnd,
        _target.hwnd,
      );
    });

    test('a pin that closed is refused', () {
      auto.session('chat', auto: true, onUserStop: () {});
      backend.window = null;
      expect(
        () => auto.session('chat', auto: true, onUserStop: () {}),
        refused('closed'),
      );
    });

    test('with no click behind it, an unbound key gets the right to the '
        'foreground, and the action lands (§5.4)', () async {
      backend.front = gaia.hwnd;
      backend.gaiaInFront = true;
      backend.refusals = 1;
      final result = await act('os_key', {'keys': 'A'});
      expect(result['stopped'], isNull);
      expect(backend.activated, 2);
      expect(backend.calls.first, const [
        GaiaKeyEvent(VK_F24, up: false),
        GaiaKeyEvent(VK_F24, up: true),
      ]);
      expect(backend.front, _target.hwnd);
      expect(backend.calls.last, contains(const GaiaKeyEvent(0x41, up: false)));
    });

    test(
      'an ask Windows agrees to and never carries out is made again',
      () async {
        backend.front = gaia.hwnd;
        backend.gaiaInFront = true;
        backend.ignoredAsks = 1;
        auto = GaiaOsControl(
          companionPid: () => 1,
          exclusions: () => excluded,
          vaultUnlocked: () => vault,
          voyagerPid: 70,
          backend: backend,
          settle: Duration.zero,
          activateWait: const Duration(seconds: 2),
        );
        final result = await act('os_key', {'keys': 'A'});
        expect(result['stopped'], isNull);
        expect(backend.activated, 2);
        expect(backend.front, _target.hwnd);
        expect(
          backend.calls.first,
          contains(const GaiaKeyEvent(VK_F24, up: false)),
        );
        expect(
          backend.calls.last,
          contains(const GaiaKeyEvent(0x41, up: false)),
        );
      },
    );

    test('Windows refusing even then sends nothing to the window', () async {
      backend.front = gaia.hwnd;
      backend.gaiaInFront = true;
      backend.refusals = 2;
      final result = await act('os_key', {'keys': 'A'});
      expect(result['stopped'], contains("wouldn't bring"));
      expect(backend.calls, hasLength(1), reason: 'only the unbound key');
    });

    test('no key is tapped when plain activation works', () async {
      backend.front = gaia.hwnd;
      backend.gaiaInFront = true;
      await act('os_key', {'keys': 'A'});
      expect(backend.calls, hasLength(1));
    });

    test('Esc between calls latches the turn and stops it (§5.3)', () async {
      await act('os_key', {'keys': 'A'});
      backend.escape = true;
      await Future<void>.delayed(look);
      backend.escape = false;
      expect(stops, 1);
      await Future<void>.delayed(look);
      expect(stops, 1, reason: 'once');
      final sent = backend.calls.length;
      await expectLater(act('os_key', {'keys': 'B'}), refused('Esc'));
      expect(backend.calls, hasLength(sent));
    });

    test('Esc mid-text stops it', () async {
      auto.session('chat', auto: true, onUserStop: () => stops++);
      await auto.plan('chat', 'card', 'os_type', {'text': 'x' * 2000});
      final running = auto.run('card', once: true, check: () async {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      backend.escape = true;
      final result = await running;
      expect(result['stopped'], contains('Esc'));
      expect(stops, 1);
      expect(backend.sent.whereType<GaiaUnicodeEvent>().length, lessThan(4000));
    });

    test("the agent's own Esc isn't the user's", () async {
      backend.onSend = () {
        if (backend.calls.last.contains(
          const GaiaKeyEvent(VK_ESCAPE, up: false),
        )) {
          backend.escape = true;
        }
      };
      await act('os_key', {'keys': 'Esc'});
      await Future<void>.delayed(look);
      expect(stops, 0);
      backend.escape = false;
    });

    test('the user switching window ends the turn, even right after a step, '
        'with nothing sent to it (§5.2)', () async {
      await act('os_key', {'keys': 'A'});
      final sent = backend.calls.length;
      backend.inputTick++;
      backend.front = other.hwnd;
      await Future<void>.delayed(look);
      expect(stops, 1);
      await expectLater(act('os_key', {'keys': 'B'}), refused('switched'));
      expect(backend.calls, hasLength(sent));
    });

    test("Gaia's own later sends don't hide the user's input", () async {
      auto.session('chat', auto: true, onUserStop: () => stops++);
      await auto.plan('chat', 'card', 'os_type', {'text': 'x' * 40});
      var sends = 0;
      backend.onSend = () {
        // The user's Alt+Tab goes in early, and the switch lands a few sends on.
        if (++sends == 2) Future.microtask(() => backend.inputTick++);
        if (sends == 6) backend.front = other.hwnd;
      };
      final result = await auto.run('card', once: true, check: () async {});
      expect(result['stopped'], isNotNull);
      await Future<void>.delayed(look);
      expect(stops, 1);
      expect(
        () => auto.session('chat', auto: true, onUserStop: () {}),
        refused('switched'),
      );
    });

    test('input well before a step is not a reason to stop', () async {
      auto.session('chat', auto: true, onUserStop: () => stops++);
      backend.inputTick++;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      backend.onSend = () => backend.front = other.hwnd;
      await act('os_key', {'keys': 'A'});
      backend.onSend = null;
      await Future<void>.delayed(look);
      expect(stops, 0);
    });

    test('a switch long after any step ends it, input or not', () async {
      auto.session('chat', auto: true, onUserStop: () => stops++);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      backend.front = other.hwnd;
      await Future<void>.delayed(look);
      expect(stops, 1);
    });

    test('a window its step opened is adopted, and the agent told', () async {
      backend.onSend = () => backend.front = other.hwnd;
      final first = await act('os_key', {'keys': 'A'});
      backend.onSend = null;
      await Future<void>.delayed(look);
      expect(stops, 0);
      expect(first['adopted'] ?? '', isA<String>());
      final second = await act('os_key', {'keys': 'B'});
      expect(second['stopped'], isNull);
      expect(backend.activated, 0);
      final pin = auto.session('chat', auto: true, onUserStop: () {});
      expect(pin?.hwnd, other.hwnd);
      expect('${first['adopted']}${second['adopted']}', contains('Calculator'));
    });

    test('an adopted window on the exclusion list gets nothing', () async {
      excluded = ['calc'];
      backend.onSend = () => backend.front = other.hwnd;
      await act('os_key', {'keys': 'A'});
      backend.onSend = null;
      await Future<void>.delayed(look);
      final sent = backend.calls.length;
      await expectLater(act('os_key', {'keys': 'B'}), refused('excluded'));
      expect(backend.calls, hasLength(sent));
    });

    test(
      'Gaia in front pauses, then it resumes with the target back',
      () async {
        await act('os_key', {'keys': 'A'});
        final sent = backend.calls.length;
        backend.front = gaia.hwnd;
        backend.gaiaInFront = true;
        await Future<void>.delayed(look);
        final going = act('os_key', {'keys': 'B'});
        await Future<void>.delayed(look);
        expect(backend.calls, hasLength(sent), reason: 'paused');
        expect(backend.activated, 0);
        backend.front = _target.hwnd;
        expect((await going)['stopped'], isNull);
        expect(backend.calls, hasLength(sent + 1));
        expect(stops, 0);
      },
    );

    test('paused too long, the turn stops', () async {
      await act('os_key', {'keys': 'A'});
      backend.front = gaia.hwnd;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(stops, 1);
    });

    test('another app coming in front while paused stops it', () async {
      await act('os_key', {'keys': 'A'});
      backend.front = gaia.hwnd;
      await Future<void>.delayed(look);
      backend.inputTick++;
      backend.front = other.hwnd;
      await Future<void>.delayed(look);
      expect(stops, 1);
    });

    test('one session at a time: another chat is refused', () async {
      auto.session('chat', auto: true, onUserStop: () {});
      expect(
        () => auto.session('theirs', auto: true, onUserStop: () {}),
        refused('Another chat'),
      );
      expect(
        () => auto.session('theirs', auto: false, onUserStop: () {}),
        refused('Another chat'),
      );
      auto.endTurn('theirs');
      expect(auto.sessionChat, 'chat');
      auto.endTurn('chat');
      expect(auto.sessionChat, isNull);
      expect(auto.session('theirs', auto: true, onUserStop: () {}), isNotNull);
    });

    test("an Ask run and another chat's session never overlap", () async {
      await auto.plan('chat', 'ask', 'os_key', {'keys': 'A'});
      await auto.plan('chat', 'later', 'os_key', {'keys': 'A'});
      final gate = Completer<void>();
      final going = auto.run('ask', once: true, check: () => gate.future);
      expect(
        () => auto.session('theirs', auto: true, onUserStop: () {}),
        refused('Another chat'),
      );
      gate.complete();
      expect((await going)['stopped'], isNull);
      auto.session('theirs', auto: true, onUserStop: () {});
      await expectLater(
        auto.run('later', once: true, check: () async {}),
        refused('Another chat'),
      );
    });

    test('Stop latches too; a new turn starts clean', () async {
      auto.session('chat', auto: true, onUserStop: () {});
      auto.stop('The user stopped the reply.', chatId: 'chat', latch: true);
      await expectLater(act('os_key', {'keys': 'A'}), refused('stopped'));
      auto.endTurn();
      expect((await act('os_key', {'keys': 'A'}))['stopped'], isNull);
    });

    test('nothing is looked at once the turn has ended', () async {
      auto.session('chat', auto: true, onUserStop: () => stops++);
      auto.endTurn();
      backend.escape = true;
      await Future<void>.delayed(look);
      expect(stops, 0);
    });

    test('an adopted window flashes its outline and name (§6.2)', () async {
      final flashes = <Map<String, Object?>>[];
      auto = GaiaOsControl(
        companionPid: () => 1,
        exclusions: () => excluded,
        vaultUnlocked: () => vault,
        flash: flashes.add,
        voyagerPid: 70,
        backend: backend,
        settle: Duration.zero,
        leadIn: Duration.zero,
        activateWait: const Duration(milliseconds: 200),
        adoptWithin: const Duration(milliseconds: 300),
      );
      backend.onSend = () => backend.front = other.hwnd;
      await act('os_key', {'keys': 'A'});
      backend.onSend = null;
      await Future<void>.delayed(look);
      expect(flashes.last, {
        'kind': 'window',
        'left': 0,
        'top': 0,
        'right': 800,
        'bottom': 600,
        'label': 'Calculator',
      });
    });

    test('steps start at least the pace apart (§5.6)', () async {
      final sentAt = <DateTime>[];
      backend.onSend = () => sentAt.add(DateTime.now());
      auto = GaiaOsControl(
        companionPid: () => 1,
        exclusions: () => excluded,
        vaultUnlocked: () => vault,
        voyagerPid: 70,
        backend: backend,
        settle: Duration.zero,
        pace: const Duration(milliseconds: 150),
        activateWait: const Duration(milliseconds: 200),
      );
      await act('os_key', {'keys': 'A'});
      await act('os_key', {'keys': 'B'});
      final keys = sentAt.length;
      expect(keys, greaterThanOrEqualTo(2));
      expect(
        sentAt.last.difference(sentAt.first),
        greaterThanOrEqualTo(const Duration(milliseconds: 140)),
      );
    });
  });

  group('flashes (GAIA_AUTONOMY_HLD.md §6)', () {
    late List<Map<String, Object?>> flashes;
    late List<int> sentWhenFlashed;

    setUp(() {
      flashes = [];
      sentWhenFlashed = [];
      control = GaiaOsControl(
        companionPid: () => 1,
        exclusions: () => excluded,
        vaultUnlocked: () => vault,
        flash: (flash) {
          flashes.add(flash);
          sentWhenFlashed.add(backend.calls.length);
        },
        voyagerPid: 70,
        backend: backend,
        settle: Duration.zero,
        leadIn: const Duration(milliseconds: 60),
        modifierWait: const Duration(milliseconds: 40),
        activateWait: const Duration(milliseconds: 200),
      );
    });

    Future<Map<String, Object?>> step(
      String tool,
      Map<String, Object?> arguments,
    ) async {
      await plan(tool, arguments);
      return run();
    }

    test('a click flashes at its control, named, before the input', () async {
      DateTime? sentAt;
      backend.onSend = () => sentAt ??= DateTime.now();
      final started = DateTime.now();
      final result = await step('os_click', {'name': 'Save'});
      expect(result['stopped'], isNull);
      expect(flashes.single, {
        'kind': 'click',
        'x': 20,
        'y': 20,
        'label': 'Save',
      });
      expect(sentWhenFlashed.single, 0);
      // The input waits out the lead-in.
      expect(
        sentAt!.difference(started),
        greaterThanOrEqualTo(const Duration(milliseconds: 55)),
      );
    });

    test('each action has its own flash', () async {
      await step('os_click', {'x': 40, 'y': 50, 'double': true});
      await step('os_click', {'x': 40, 'y': 50, 'button': 'right'});
      await step('os_scroll', {'direction': 'down', 'amount': 7});
      await step('os_key', {'keys': 'Ctrl+S'});
      expect(flashes, [
        {'kind': 'double', 'x': 40, 'y': 50},
        {'kind': 'right', 'x': 40, 'y': 50},
        {
          'kind': 'scroll',
          'x': 400,
          'y': 300,
          'direction': 'down',
          'amount': 7,
        },
        {
          'kind': 'key',
          'left': 0,
          'top': 0,
          'right': 800,
          'bottom': 600,
          'label': 'Ctrl+S',
        },
      ]);
    });

    test('typing outlines its field, and never shows the text', () async {
      await step('os_type', {'name': 'Save', 'text': 'hunter2 secret'});
      await step('os_type', {'text': 'hunter2 secret'});
      expect(flashes[0], containsPair('kind', 'type'));
      expect(flashes[0], containsPair('left', 10));
      expect(flashes[0], containsPair('label', 'Save'));
      expect(flashes[0]['ms'], isA<int>());
      expect(flashes[1], containsPair('kind', 'key'));
      expect(flashes[1], containsPair('label', 'Typing'));
      expect(flashes.toString(), isNot(contains('hunter2')));
    });

    test('a stop during the lead-in sends nothing', () async {
      control = GaiaOsControl(
        companionPid: () => 1,
        exclusions: () => excluded,
        vaultUnlocked: () => vault,
        flash: (_) => control.stop('The user pressed Esc.'),
        voyagerPid: 70,
        backend: backend,
        settle: Duration.zero,
        leadIn: const Duration(milliseconds: 30),
        activateWait: const Duration(milliseconds: 200),
      );
      final result = await step('os_click', {'name': 'Save'});
      expect(result['stopped'], 'The user pressed Esc.');
      expect(backend.calls, isEmpty);
    });

    test('a password field is refused before any flash', () async {
      backend.matches = [_button(sensitive: true)];
      await expectLater(
        step('os_type', {'name': 'Save', 'text': 'x'}),
        refused('password'),
      );
      expect(flashes, isEmpty);
    });

    test('a control not on screen has no marker on the card', () async {
      backend.matches = [];
      final card = await plan('os_click', {'name': 'Save'});
      expect(stepsOf(card).single.containsKey('flash'), isFalse);
    });
  });

  test('gaiaControlMatches goes by the name as os_read_screen shows it', () {
    bool matches(String wanted, {String? type}) => gaiaControlMatches(
      (name: wanted, type: type),
      name: 'Save',
      type: 'Button',
    );
    expect(matches('save'), isTrue);
    expect(matches('Save', type: 'button'), isTrue);
    expect(matches('Save', type: 'Edit'), isFalse);
    expect(matches('Sav'), isFalse);
    final long = 'x' * 300;
    expect(
      gaiaControlMatches(
        (name: '${'x' * 200}…', type: null),
        name: long,
        type: 'Text',
      ),
      isTrue,
    );
  });
}
