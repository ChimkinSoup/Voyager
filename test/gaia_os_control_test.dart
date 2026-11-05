import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

  /// Runs at each look at the foreground, before it's read.
  void Function()? onForeground;

  @override
  GaiaForegroundWindow? target(int gaiaPid) => window;
  @override
  GaiaForegroundWindow? describe(int hwnd) => windows[hwnd] ?? window;
  @override
  int foreground() {
    onForeground?.call();
    if (_switching) {
      duringSwitch?.call();
      if (activateLag case final lag? when lag <= 0) {
        front = _switchTo;
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
    _switchTo = hwnd;
    return activates;
  }

  var _switchTo = _target.hwnd;

  /// What [listWindows] gives, front first.
  var listed = <GaiaListedWindow>[];

  /// The Start menu's apps.
  var apps = <({String name, String id})>[];
  final launched = <String>[];

  /// What [launch] answers; it throws for null.
  ({int pid, String? exe})? launchAnswer = (pid: 0, exe: null);

  /// Runs once per [launch], after it: an app opening its window.
  void Function()? onLaunch;
  final runningPids = <int>{};
  final minimizedWindows = <int>{};
  final restored = <int>[];

  /// How many looks a restore takes to show, and whether it comes in front,
  /// as SW_RESTORE activates.
  int restoreLag = 0;
  bool restoreActivates = false;
  void Function()? onRestore;

  @override
  List<GaiaListedWindow> listWindows() => listed;
  @override
  Future<List<({String name, String id})>> startApps() async => apps;
  @override
  Future<({int pid, String? exe})> launch(String file) async {
    launched.add(file);
    onLaunch?.call();
    return launchAnswer ?? (throw GaiaReadException("Windows couldn't open."));
  }

  @override
  bool running(int pid) => runningPids.contains(pid);

  /// Each process's parent, and each window's app IDs, by hwnd.
  final parents = <int, int>{};
  final appIds = <int, Set<String>>{};

  /// What opens each extension or scheme, and where each Start app points.
  final handlers = <String, ({String? exe, String? appId})>{};
  final startTargets = <String, String>{};
  final shortcutTargets = <String, String>{};

  @override
  Map<int, int> processParents() => parents;
  @override
  Set<String> appIdsOf(GaiaForegroundWindow window) => {
    for (final id in appIds[window.hwnd] ?? const <String>{}) id.toLowerCase(),
  };
  @override
  ({String? exe, String? appId}) handler(
    String assoc, {
    required bool protocol,
  }) => handlers[assoc] ?? (exe: null, appId: null);
  @override
  String? startAppTarget(String id) => startTargets[id];
  @override
  String? shortcutTarget(String path) => shortcutTargets[path];
  @override
  bool minimized(int hwnd) {
    if (restored.contains(hwnd) && restoreLag-- <= 0) {
      minimizedWindows.remove(hwnd);
    }
    return minimizedWindows.contains(hwnd);
  }

  @override
  void restore(int hwnd) {
    restored.add(hwnd);
    onRestore?.call();
    if (restoreActivates) front = hwnd;
    if (restoreLag <= 0) minimizedWindows.remove(hwnd);
  }

  /// What `os_window` did, as "minimize 99".
  final arranged = <String>[];

  /// Runs once per minimize: Windows bringing up the next window.
  void Function()? onMinimize;
  @override
  void minimize(int hwnd) {
    arranged.add('minimize $hwnd');
    onMinimize?.call();
  }

  @override
  void maximize(int hwnd) => arranged.add('maximize $hwnd');
  @override
  Future<bool> place(
    int hwnd, {
    int? left,
    int? top,
    int? width,
    int? height,
  }) async {
    if (stuck) return false;
    arranged.add('move $hwnd $left,$top ${width}x$height');
    return true;
  }

  /// A window that won't come out of maximized, so can't be placed.
  var stuck = false;
  @override
  void close(int hwnd) => arranged.add('close $hwnd');

  /// What's been written to the clipboard; another app holds it while
  /// [clipboardBusy].
  final clipboard = <String>[];
  var clipboardBusy = false;
  @override
  Future<bool> writeClipboard(String text) async {
    if (clipboardBusy) return false;
    clipboard.add(text);
    return true;
  }

  @override
  int rootAt(int x, int y) => rootUnder;

  /// Window classes, by hwnd; none for the rest.
  final classes = <int, String>{};
  @override
  String windowClass(int hwnd) => classes[hwnd] ?? '';
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

  /// Where the user moved the mouse to, if they did; else where Gaia put it.
  ({int x, int y})? userMoved;
  @override
  ({int x, int y}) cursorAt() =>
      userMoved ??
      (cursor.isEmpty ? (x: 0, y: 0) : (x: cursor.last.$1, y: cursor.last.$2));
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
        handoverWait: const Duration(milliseconds: 200),
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

    group("the pinned app's own window, later than adoptWithin (BUG-362)", () {
      const main = (
        hwnd: 71,
        pid: 70,
        exe: 'notepad',
        app: 'Notepad',
        title: 'main',
        console: false,
      );
      setUp(() => backend.windows[main.hwnd] = main);

      // The splash closing.
      void closePin() {
        backend.windows.remove(_target.hwnd);
        backend.window = null;
      }

      test('is adopted once the pin has closed, with no user input since '
          'the step, as a splash hands over', () async {
        await act('os_key', {'keys': 'A'});
        await Future<void>.delayed(const Duration(milliseconds: 350));
        closePin();
        backend.front = main.hwnd;
        await Future<void>.delayed(look);
        expect(stops, 0);
        final next = await act('os_key', {'keys': 'B'});
        expect(next['stopped'], isNull);
        expect(next['adopted'], contains('main'));
      });

      test('is adopted when the pin closes just after, as a splash that '
          'shows its main window first does', () async {
        await act('os_key', {'keys': 'A'});
        await Future<void>.delayed(const Duration(milliseconds: 350));
        backend.front = main.hwnd;
        await Future<void>.delayed(look);
        expect(stops, 0);
        closePin();
        await Future<void>.delayed(look);
        expect(stops, 0);
        final next = await act('os_key', {'keys': 'B'});
        expect(next['stopped'], isNull);
        expect(next['adopted'], contains('main'));
      });

      test('ends the turn if the pin stays open past the wait, as a reminder '
          'beside the main window would', () async {
        await act('os_key', {'keys': 'A'});
        await Future<void>.delayed(const Duration(milliseconds: 350));
        backend.front = main.hwnd;
        await Future<void>.delayed(look);
        expect(stops, 0);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(stops, 1);
      });

      test('ends the turn on user input while it waits for the pin to '
          'close', () async {
        await act('os_key', {'keys': 'A'});
        await Future<void>.delayed(const Duration(milliseconds: 350));
        backend.front = main.hwnd;
        await Future<void>.delayed(look);
        backend.inputTick++;
        await Future<void>.delayed(look);
        expect(stops, 1);
      });

      test('ends the turn after the user has touched the PC', () async {
        await act('os_key', {'keys': 'A'});
        await Future<void>.delayed(const Duration(milliseconds: 350));
        backend.inputTick++;
        await Future<void>.delayed(look);
        closePin();
        backend.front = main.hwnd;
        await Future<void>.delayed(look);
        expect(stops, 1);
      });

      test('ends the turn after input during a step, though Gaia sent '
          'more after it', () async {
        auto.session('chat', auto: true, onUserStop: () => stops++);
        await auto.plan('chat', 'card', 'os_type', {'text': 'abcdef'});
        var sends = 0;
        backend.onSend = () {
          if (++sends == 2) Future.microtask(() => backend.inputTick++);
        };
        await auto.run('card', once: true, check: () async {});
        backend.onSend = null;
        await Future<void>.delayed(const Duration(milliseconds: 350));
        closePin();
        backend.front = main.hwnd;
        await Future<void>.delayed(look);
        expect(stops, 1);
      });

      test('is adopted when the pin closes first and another window is in '
          'front until it shows, as Windows does for a splash that closes '
          'first', () async {
        await act('os_key', {'keys': 'A'});
        await Future<void>.delayed(const Duration(milliseconds: 350));
        closePin();
        backend.front = other.hwnd;
        await Future<void>.delayed(look);
        expect(stops, 0);
        backend.front = main.hwnd;
        await Future<void>.delayed(look);
        expect(stops, 0);
        final next = await act('os_key', {'keys': 'B'});
        expect(next['stopped'], isNull);
        expect(next['adopted'], contains('main'));
      });

      test("another app's window, with none of the pinned app's after, ends "
          'the turn once the wait is over', () async {
        await act('os_key', {'keys': 'A'});
        await Future<void>.delayed(const Duration(milliseconds: 350));
        closePin();
        backend.front = other.hwnd;
        await Future<void>.delayed(look);
        expect(stops, 0);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(stops, 1);
      });

      test("another app's window while the pin is open ends the turn at "
          'once', () async {
        await act('os_key', {'keys': 'A'});
        await Future<void>.delayed(const Duration(milliseconds: 350));
        backend.front = other.hwnd;
        await Future<void>.delayed(look);
        expect(stops, 1);
      });
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

    test('a clipboard write waits while paused too', () async {
      await act('os_key', {'keys': 'A'});
      // Past the pace between steps, so only the pause holds it.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      backend.front = gaia.hwnd;
      backend.gaiaInFront = true;
      await Future<void>.delayed(look);
      final going = act('os_clipboard', {'action': 'write', 'text': 'hello'});
      await Future<void>.delayed(look);
      expect(backend.clipboard, isEmpty, reason: 'paused');
      backend.front = _target.hwnd;
      expect((await going)['stopped'], isNull);
      expect(backend.clipboard, ['hello']);
    });

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

    group('rules that change in Auto (§5.5)', () {
      test('the Windows key is refused in Ask, and sent in Auto', () async {
        await expectLater(plan('os_key', {'keys': 'Win+R'}), refused('Auto'));
        await expectLater(plan('os_key', {'keys': 'Win'}), refused('Auto'));
        expect((await act('os_key', {'keys': 'Win+R'}))['stopped'], isNull);
        expect(backend.calls.last, const [
          GaiaKeyEvent(VK_LWIN, up: false),
          GaiaKeyEvent(0x52, up: false),
          GaiaKeyEvent(0x52, up: true),
          GaiaKeyEvent(VK_LWIN, up: true),
        ]);
        await act('os_key', {'keys': 'Win'});
        expect(backend.calls.last, const [
          GaiaKeyEvent(VK_LWIN, up: false),
          GaiaKeyEvent(VK_LWIN, up: true),
        ]);
      });

      test('Start, opened by a step, is adopted; the taskbar is not', () async {
        const start = (
          hwnd: 60,
          pid: 61,
          exe: 'StartMenuExperienceHost',
          app: 'Start',
          title: 'Start',
          console: false,
        );
        const taskbar = (
          hwnd: 62,
          pid: 63,
          exe: 'explorer',
          app: 'Windows Explorer',
          title: '',
          console: false,
        );
        backend.windows
          ..[start.hwnd] = start
          ..[taskbar.hwnd] = taskbar;
        backend.classes
          ..[start.hwnd] = 'Windows.UI.Core.CoreWindow'
          ..[taskbar.hwnd] = 'Shell_TrayWnd';
        // The taskbar is something the target can be brought up past.
        backend.gaiaInFront = true;
        backend.onSend = () => backend.front = taskbar.hwnd;
        await act('os_key', {'keys': 'A'});
        await Future<void>.delayed(look);
        expect(auto.session('chat', auto: true, onUserStop: () {})?.hwnd, 7);
        backend.onSend = () => backend.front = start.hwnd;
        await act('os_key', {'keys': 'Win'});
        backend.onSend = null;
        await Future<void>.delayed(look);
        expect(stops, 0);
        expect(
          auto.session('chat', auto: true, onUserStop: () {})?.hwnd,
          start.hwnd,
        );
      });

      test('anywhere is refused in Ask, and only for a point', () async {
        await expectLater(
          plan('os_click', {'x': 5, 'y': 5, 'anywhere': true}),
          refused('Auto'),
        );
        auto.session('chat', auto: true, onUserStop: () {});
        await expectLater(
          auto.plan('chat', 'card', 'os_click', {
            'name': 'Save',
            'anywhere': true,
          }),
          refused('x and y alone'),
        );
      });

      test(
        'an anywhere click lands outside the window, on another app',
        () async {
          backend.rootUnder = other.hwnd;
          final result = await act('os_click', {
            'x': 900,
            'y': 700,
            'anywhere': true,
          });
          expect(result['stopped'], isNull);
          expect(backend.cursor.last, (900, 700));
        },
      );

      test(
        'anywhere never clicks Gaia, the notch, or an excluded app',
        () async {
          const notch = (
            hwnd: 55,
            pid: 70,
            exe: 'voyager',
            app: 'Voyager',
            title: '',
            console: false,
          );
          backend.windows[notch.hwnd] = notch;
          backend.classes[notch.hwnd] = 'VoyagerGaiaControlBorder';
          Future<Object?> click() async => (await act('os_click', {
            'x': 900,
            'y': 700,
            'anywhere': true,
          }))['stopped'];
          backend.rootUnder = gaia.hwnd;
          expect(await click(), contains("Gaia's own"));
          backend.rootUnder = notch.hwnd;
          expect(await click(), contains("Gaia's own"));
          excluded = ['calc'];
          backend.rootUnder = other.hwnd;
          expect(await click(), contains('excluded'));
          expect(backend.cursor, isEmpty);
        },
      );
    });

    test('the notch hears a session start, pause, go on and end; answering '
        'Gaia resumes it (§5.2)', () async {
      var told = 0;
      auto.onSession = () => told++;
      await act('os_key', {'keys': 'A'});
      expect(told, 1);
      backend.front = gaia.hwnd;
      backend.gaiaInFront = true;
      await Future<void>.delayed(look);
      expect(auto.sessionPaused, isTrue);
      expect(told, 2);
      auto.resume('other chat');
      expect(auto.sessionPaused, isTrue);
      auto.resume('chat');
      expect(auto.sessionPaused, isFalse);
      expect(told, 3);
      // Gaia still in front isn't a new pause: the next step brings the
      // target up.
      await Future<void>.delayed(look);
      expect(auto.sessionPaused, isFalse);
      expect((await act('os_key', {'keys': 'B'}))['stopped'], isNull);
      expect(backend.activated, greaterThan(0));
      expect(stops, 0);
      auto.endTurn();
      expect(told, 4);
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

  group('opening (GAIA_AUTONOMY_HLD.md §8.1, §8.2)', () {
    const calc = (
      hwnd: 99,
      pid: 90,
      exe: 'calc',
      app: 'Calculator',
      title: 'Calculator',
      console: false,
    );
    const gaia = (
      hwnd: 50,
      pid: 1,
      exe: 'voyager',
      app: 'Gaia',
      title: 'Gaia',
      console: false,
    );
    GaiaListedWindow listed(
      GaiaForegroundWindow window, {
      bool minimized = false,
    }) => (
      window: window,
      minimized: minimized,
      frame: (left: 0, top: 0, width: 800, height: 600),
    );
    late GaiaOsControl auto;
    late List<Map<String, Object?>> flashes;

    setUp(() {
      flashes = [];
      backend.windows
        ..[gaia.hwnd] = gaia
        ..[calc.hwnd] = calc;
      backend.apps = [
        (
          name: 'Calculator',
          id: 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App',
        ),
        (name: 'Notepad', id: r'C:\Windows\notepad.exe'),
        (name: 'Notepad++', id: r'C:\Program Files\Notepad++\notepad++.exe'),
      ];
      auto = GaiaOsControl(
        companionPid: () => 1,
        exclusions: () => excluded,
        vaultUnlocked: () => vault,
        voyagerPid: 70,
        backend: backend,
        flash: flashes.add,
        settle: Duration.zero,
        leadIn: Duration.zero,
        pace: Duration.zero,
        activateWait: const Duration(milliseconds: 200),
        openWait: const Duration(milliseconds: 200),
      );
    });
    tearDown(() => auto.endTurn());

    /// [tool] in an Auto turn, planned and run.
    Future<Map<String, Object?>> act(
      String tool,
      Map<String, Object?> arguments,
    ) async {
      auto.session(
        'chat',
        auto: true,
        onUserStop: () {},
        needsWindow: tool != 'os_open' && tool != 'os_focus',
      );
      await auto.plan('chat', 'card', tool, arguments);
      return auto.run('card', once: true, check: () async {});
    }

    test('an app resolves by its Start menu name: exactly, else the one '
        'it is part of; nothing launches until it runs', () async {
      var card = await auto.plan('chat', 'card', 'os_open', {
        'target': 'notepad',
      });
      expect(card['window'], 'Notepad');
      expect(stepsOf(card).single, {'label': 'Open Notepad', 'resolved': true});
      card = await auto.plan('chat', 'card', 'os_open', {'target': 'calc'});
      expect(stepsOf(card).single['label'], 'Open Calculator');
      await expectLater(
        auto.plan('chat', 'card', 'os_open', {'target': 'note'}),
        refused('2 apps match "note": "Notepad", "Notepad++"'),
      );
      await expectLater(
        auto.plan('chat', 'card', 'os_open', {'target': 'Paint'}),
        refused('No installed app is named "Paint"'),
      );
      await expectLater(
        auto.plan('chat', 'card', 'os_open', {'target': r'C:\no\such.txt'}),
        refused('no file or folder'),
      );
      expect(backend.launched, isEmpty);
    });

    test('an excluded app or site is refused before it launches', () async {
      excluded = ['notepad', 'bank.com'];
      await expectLater(
        auto.plan('chat', 'card', 'os_open', {'target': 'Notepad'}),
        refused('excluded'),
      );
      await expectLater(
        auto.plan('chat', 'card', 'os_open', {
          'target': 'https://www.bank.com/login',
        }),
        refused('excluded'),
      );
      // By the exe in its id, whatever the Start menu calls it.
      excluded = ['notepad++'];
      await expectLater(
        auto.plan('chat', 'card', 'os_open', {'target': 'Notepad++'}),
        refused('excluded'),
      );
      // A shortcut by what it opens, whatever it's named.
      final dir = Directory.systemTemp.createTempSync('gaia_lnk');
      addTearDown(() => dir.deleteSync(recursive: true));
      final link = File(p.join(dir.path, 'Chat.lnk'))..createSync();
      backend.shortcutTargets[link.path] =
          r'C:\Program Files\Notepad++\notepad++.exe';
      await expectLater(
        auto.plan('chat', 'card', 'os_open', {'target': link.path}),
        refused('excluded'),
      );
      // And again when it runs, if excluded since the card.
      excluded = [];
      await auto.plan('chat', 'card', 'os_open', {'target': 'Calculator'});
      excluded = ['calculator'];
      final result = await auto.run('card', once: true, check: () async {});
      expect(result['stopped'], contains('excluded'));
      expect(backend.launched, isEmpty);
    });

    test('in Auto it launches, then brings up, pins and flashes the new '
        'window, and the next action lands there', () async {
      backend.listed = [listed(_target)];
      backend.launchAnswer = (pid: 90, exe: 'calc');
      backend.onLaunch = () => backend.listed = [listed(calc), listed(_target)];
      final result = await act('os_open', {'target': 'Calculator'});
      expect(backend.launched, [
        r'shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App',
      ]);
      expect(result['stopped'], isNull);
      expect(result['front'], 'Calculator: "Calculator"');
      expect(backend.front, calc.hwnd);
      expect(flashes.last, {
        'kind': 'window',
        'left': 0,
        'top': 0,
        'right': 800,
        'bottom': 600,
        'label': 'Calculator',
      });
      expect(
        auto.session('chat', auto: true, onUserStop: () {})?.hwnd,
        calc.hwnd,
      );
      final next = await act('os_key', {'keys': 'A'});
      expect(next['stopped'], isNull);
      expect(backend.calls.last, contains(const GaiaKeyEvent(0x41, up: false)));
    });

    test('with nothing open, a session starts for os_open alone', () async {
      backend.window = null;
      expect(
        () => auto.session('chat', auto: true, onUserStop: () {}),
        refused('os_open can open one'),
      );
      // A Store app: no process to go by, only the app ID its frame carries.
      backend.appIds[calc.hwnd] = {
        'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App',
      };
      backend.onLaunch = () => backend.listed = [listed(calc)];
      final result = await act('os_open', {'target': 'Calculator'});
      expect(result['front'], 'Calculator: "Calculator"');
    });

    group('only a window shown to be what launched counts', () {
      const stray = (
        hwnd: 77,
        pid: 77,
        exe: 'mspaint',
        app: 'Paint',
        title: 'Untitled - Paint',
        console: false,
      );

      test('one opening by chance meanwhile is passed over', () async {
        backend.listed = [listed(_target)];
        backend.appIds[calc.hwnd] = {
          'microsoft.windowscalculator_8wekyb3d8bbwe!app',
        };
        backend.onLaunch = () {
          backend.listed = [listed(stray), listed(_target)];
          Future<void>.delayed(const Duration(milliseconds: 50), () {
            backend.listed = [listed(calc), listed(stray), listed(_target)];
          });
        };
        final result = await act('os_open', {'target': 'Calculator'});
        expect(result['front'], 'Calculator: "Calculator"');
        expect(backend.front, calc.hwnd);
      });

      test('and with nothing else, Gaia says it could not tell', () async {
        backend.listed = [listed(_target)];
        backend.onLaunch = () =>
            backend.listed = [listed(stray), listed(_target)];
        // Even in front.
        backend.front = stray.hwnd;
        final result = await act('os_open', {'target': 'Calculator'});
        expect(result['stopped'], contains("couldn't tell"));
        expect(result['front'], isNull);
      });

      test("a launcher's window comes from a process it started", () async {
        const child = (
          hwnd: 91,
          pid: 91,
          exe: 'realapp',
          app: 'Real App',
          title: 'Real App',
          console: false,
        );
        backend.launchAnswer = (pid: 90, exe: 'notepad');
        backend.parents[91] = 90;
        backend.onLaunch = () =>
            backend.listed = [listed(stray), listed(child), listed(_target)];
        final result = await act('os_open', {
          'target': r'C:\Windows\System32\notepad.exe',
        });
        expect(result['front'], 'Real App: "Real App"');
      });

      test("a URL's window is the browser's that opens its scheme", () async {
        const chrome = (
          hwnd: 60,
          pid: 60,
          exe: 'chrome',
          app: 'Google Chrome',
          title: 'Example - Google Chrome',
          console: false,
        );
        backend.handlers['https'] = (exe: 'chrome', appId: 'Chrome');
        backend.onLaunch = () =>
            backend.listed = [listed(stray), listed(chrome), listed(_target)];
        final result = await act('os_open', {'target': 'https://example.com'});
        expect(result['front'], 'Google Chrome: "Example - Google Chrome"');
        // And a browser the user excluded is refused before it launches.
        backend.launched.clear();
        excluded = ['chrome'];
        await expectLater(
          auto.plan('chat', 'card', 'os_open', {'target': 'https://a.org'}),
          refused('excluded'),
        );
        expect(backend.launched, isEmpty);
      });

      test("a shortcut's window is its target exe's", () async {
        const bash = (
          hwnd: 61,
          pid: 61,
          exe: 'git-bash',
          app: 'Git Bash',
          title: 'MINGW64',
          console: false,
        );
        const id = 'Microsoft.AutoGenerated.{0FDD9C6B}';
        backend.apps = [(name: 'Git Bash', id: id)];
        backend.startTargets[id] = r'C:\Program Files\Git\git-bash.exe';
        backend.onLaunch = () =>
            backend.listed = [listed(stray), listed(bash), listed(_target)];
        final result = await act('os_open', {'target': 'Git Bash'});
        expect(result['front'], 'Git Bash: "MINGW64"');
      });
    });

    test('a single-instance app hands over to the window it has', () async {
      backend.listed = [listed(calc)];
      backend.launchAnswer = (pid: 5, exe: 'CALC');
      final result = await act('os_open', {
        'target': r'C:\Windows\System32\calc.exe',
      });
      expect(backend.launched, [r'C:\Windows\System32\calc.exe']);
      expect(result['front'], 'Calculator: "Calculator"');
    });

    test('a file opening as a tab in a window its app had is found as the '
        'title names it, not at the end of the wait (BUG-353)', () async {
      final dir = Directory.systemTemp.createTempSync('gaia_open');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'second.txt'))..writeAsStringSync('');
      const before = (
        hwnd: 81,
        pid: 81,
        exe: 'notepad',
        app: 'Notepad',
        title: 'first.txt - Notepad',
        console: false,
      );
      final after = (
        hwnd: 81,
        pid: 81,
        exe: 'notepad',
        app: 'Notepad',
        title: 'second.txt - Notepad',
        console: false,
      );
      final control = GaiaOsControl(
        companionPid: () => 1,
        exclusions: () => const [],
        vaultUnlocked: () => false,
        backend: backend,
        settle: Duration.zero,
        leadIn: Duration.zero,
        pace: Duration.zero,
        openWait: const Duration(seconds: 5),
      );
      addTearDown(control.endTurn);
      backend.handlers['.txt'] = (exe: 'notepad', appId: null);
      backend.listed = [listed(before)];
      // The notepad.exe it launched stays running, with no window.
      backend.launchAnswer = (pid: 82, exe: 'notepad');
      backend.runningPids.add(82);
      backend.onLaunch = () {
        backend.windows[after.hwnd] = after;
        backend.listed = [listed(after)];
      };
      control.session(
        'chat',
        auto: true,
        onUserStop: () {},
        needsWindow: false,
      );
      await control.plan('chat', 'card', 'os_open', {'target': file.path});
      final watch = Stopwatch()..start();
      final result = await control.run('card', once: true, check: () async {});
      expect(result['front'], 'Notepad: "second.txt - Notepad"');
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test("a title only containing the file's name within a word doesn't end "
        'the wait', () async {
      final dir = Directory.systemTemp.createTempSync('gaia_open');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'a.txt'))..writeAsStringSync('');
      const before = (
        hwnd: 81,
        pid: 81,
        exe: 'notepad',
        app: 'Notepad',
        title: 'first.txt - Notepad',
        console: false,
      );
      final after = (
        hwnd: 81,
        pid: 81,
        exe: 'notepad',
        app: 'Notepad',
        title: 'data.txt - Notepad',
        console: false,
      );
      final control = GaiaOsControl(
        companionPid: () => 1,
        exclusions: () => const [],
        vaultUnlocked: () => false,
        backend: backend,
        settle: Duration.zero,
        leadIn: Duration.zero,
        pace: Duration.zero,
        openWait: const Duration(milliseconds: 400),
      );
      addTearDown(control.endTurn);
      backend.handlers['.txt'] = (exe: 'notepad', appId: null);
      backend.listed = [listed(before)];
      backend.launchAnswer = (pid: 82, exe: 'notepad');
      backend.runningPids.add(82);
      backend.onLaunch = () {
        backend.windows[after.hwnd] = after;
        backend.listed = [listed(after)];
      };
      control.session(
        'chat',
        auto: true,
        onUserStop: () {},
        needsWindow: false,
      );
      await control.plan('chat', 'card', 'os_open', {'target': file.path});
      final watch = Stopwatch()..start();
      await control.run('card', once: true, check: () async {});
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 400)),
      );
    });

    test('a launch with no window it can tell says so', () async {
      backend.listed = [listed(_target)];
      final result = await act('os_open', {'target': 'Calculator'});
      expect(result['stopped'], contains('os_windows'));
      expect(result['front'], isNull);
    });

    test('Windows refusing to open it is a stop', () async {
      backend.launchAnswer = null;
      final result = await act('os_open', {'target': 'https://example.com'});
      expect(result['stopped'], contains("couldn't open"));
    });

    test(
      'os_focus finds a window by id, title or app, never Gaia\'s',
      () async {
        backend.listed = [listed(gaia), listed(_target), listed(calc)];
        for (final asked in <Object>[99, '99', 'calculator', 'CALC']) {
          final card = await control.plan('chat', 'card', 'os_focus', {
            'window': asked,
          });
          expect(
            stepsOf(card).single['label'],
            'Bring Calculator: "Calculator" to the front',
          );
        }
        await expectLater(
          control.plan('chat', 'card', 'os_focus', {'window': 'Gaia'}),
          refused('No open window matches'),
        );
        backend.listed = [listed(_target), listed(calc), listed(calc)];
        await expectLater(
          control.plan('chat', 'card', 'os_focus', {'window': 'calc'}),
          refused('2 windows match'),
        );
      },
    );

    test('an excluded window is matched by id alone, and refused', () async {
      backend.listed = [listed(_target), listed(calc)];
      excluded = ['calc'];
      await expectLater(
        control.plan('chat', 'card', 'os_focus', {'window': 'Calculator'}),
        refused('No open window matches'),
      );
      await expectLater(
        control.plan('chat', 'card', 'os_focus', {'window': 99}),
        refused('excluded'),
      );
    });

    test('a browser on an excluded site is matched by id alone, and '
        'refused', () async {
      const bank = (
        hwnd: 61,
        pid: 72,
        exe: 'chrome',
        app: 'Chrome',
        title: 'Account 1234 - MyBank',
        console: false,
      );
      backend.windows[bank.hwnd] = bank;
      backend.listed = [listed(_target), listed(bank)];
      excluded = ['mybank.com'];
      backend.url = 'https://www.mybank.com/account';
      await expectLater(
        control.plan('chat', 'card', 'os_focus', {'window': 'MyBank'}),
        refused('No open window matches'),
      );
      await expectLater(
        control.plan('chat', 'card', 'os_focus', {'window': 61}),
        refused('excluded'),
      );
      // An address that can't be read is no better while a site is excluded.
      backend.url = null;
      await expectLater(
        control.plan('chat', 'card', 'os_focus', {'window': 'MyBank'}),
        refused('No open window matches'),
      );
      backend.url = 'https://example.com/';
      final card = await control.plan('chat', 'card', 'os_focus', {
        'window': 'MyBank',
      });
      expect(stepsOf(card).single['label'], contains('MyBank'));
    });

    test('in Ask, os_focus is a card, and approved, restores and brings the '
        'window up', () async {
      backend.listed = [listed(_target), listed(calc, minimized: true)];
      backend.minimizedWindows.add(calc.hwnd);
      final card = await control.plan('chat', 'card', 'os_focus', {
        'window': 'Calculator',
      });
      expect(card['auto'], isNull);
      expect(card['window'], 'Calculator: "Calculator"');
      expect(backend.activated, 0);
      final result = await run();
      expect(result['stopped'], isNull);
      expect(backend.restored, [calc.hwnd]);
      expect(backend.front, calc.hwnd);
      expect(result['front'], 'Calculator: "Calculator"');
    });

    test('in Auto, os_focus restoring a window in front is not the user '
        'switching', () async {
      final control = GaiaOsControl(
        companionPid: () => 1,
        exclusions: () => const [],
        vaultUnlocked: () => false,
        backend: backend,
        settle: Duration.zero,
        leadIn: Duration.zero,
        pace: Duration.zero,
        adoptWithin: const Duration(milliseconds: 50),
      );
      addTearDown(control.endTurn);
      backend.listed = [listed(_target), listed(calc, minimized: true)];
      backend
        ..minimizedWindows.add(calc.hwnd)
        ..restoreActivates = true
        ..restoreLag = 5;
      var userStopped = false;
      control.session(
        'chat',
        auto: true,
        onUserStop: () => userStopped = true,
        needsWindow: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await control.plan('chat', 'card', 'os_focus', {'window': 'Calculator'});
      final result = await control.run('card', once: true, check: () async {});
      expect(result['stopped'], isNull);
      expect(userStopped, isFalse);
      expect(backend.front, calc.hwnd);
    });

    test('in Auto, os_focus on a window that comes in front only once '
        'past adoptWithin, as a Store app can, is not the user switching '
        '(BUG-351)', () async {
      final control = GaiaOsControl(
        companionPid: () => 1,
        exclusions: () => const [],
        vaultUnlocked: () => false,
        backend: backend,
        settle: Duration.zero,
        leadIn: Duration.zero,
        pace: Duration.zero,
        adoptWithin: const Duration(milliseconds: 50),
      );
      addTearDown(control.endTurn);
      backend.listed = [listed(_target), listed(calc, minimized: true)];
      backend
        ..minimizedWindows.add(calc.hwnd)
        ..restoreLag = 15;
      backend.onRestore = () => Future<void>.delayed(
        const Duration(milliseconds: 150),
        () => backend.front = calc.hwnd,
      );
      var userStopped = false;
      control.session(
        'chat',
        auto: true,
        onUserStop: () => userStopped = true,
        needsWindow: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await control.plan('chat', 'card', 'os_focus', {'window': 'Calculator'});
      final result = await control.run('card', once: true, check: () async {});
      expect(result['stopped'], isNull);
      expect(userStopped, isFalse);
      expect(backend.front, calc.hwnd);
    });

    test('a window that closed before os_focus ran is a stop', () async {
      backend.listed = [listed(calc)];
      await control.plan('chat', 'card', 'os_focus', {'window': 99});
      backend.windows.remove(calc.hwnd);
      backend.window = null;
      final result = await run();
      expect(result['stopped'], contains('closed'));
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

  group('more tools (GAIA_AUTONOMY_HLD.md §8.3–§8.5)', () {
    const calc = (
      hwnd: 99,
      pid: 90,
      exe: 'calc',
      app: 'Calculator',
      title: 'Calculator',
      console: false,
    );
    const gaia = (
      hwnd: 50,
      pid: 1,
      exe: 'voyager',
      app: 'Gaia',
      title: 'Gaia',
      console: false,
    );
    GaiaListedWindow listed(GaiaForegroundWindow window) => (
      window: window,
      minimized: false,
      frame: (left: 0, top: 0, width: 800, height: 600),
    );
    late List<Map<String, Object?>> flashes;
    late GaiaOsControl shown;

    setUp(() {
      flashes = [];
      backend.windows
        ..[gaia.hwnd] = gaia
        ..[calc.hwnd] = calc;
      backend.listed = [listed(gaia), listed(_target), listed(calc)];
      shown = GaiaOsControl(
        companionPid: () => 1,
        exclusions: () => excluded,
        vaultUnlocked: () => vault,
        voyagerPid: 70,
        backend: backend,
        flash: flashes.add,
        stopFlashes: () => flashes.add(const {'stopped': true}),
        settle: Duration.zero,
        leadIn: Duration.zero,
        pace: Duration.zero,
        adoptWithin: const Duration(milliseconds: 200),
        holdLimit: const Duration(seconds: 2),
      );
    });
    tearDown(() => shown.endTurn());

    Future<Map<String, Object?>> runShown() =>
        shown.run('card', once: true, check: () async {});

    List<int> buttons() => [
      for (final event in backend.sent.whereType<GaiaMouseEvent>())
        if (event.flags != MOUSEEVENTF_MOVE) event.flags,
    ];

    group('os_window', () {
      test('names the window and what it does; nothing runs until '
          'approved', () async {
        Future<String> label(Map<String, Object?> arguments) async =>
            stepsOf(
                  await plan('os_window', {'window': 99, ...arguments}),
                ).single['label']!
                as String;
        expect(
          await label({'action': 'minimize'}),
          'Minimize Calculator: "Calculator"',
        );
        expect(await label({'action': 'maximize'}), startsWith('Maximize'));
        expect(await label({'action': 'restore'}), startsWith('Restore'));
        expect(await label({'action': 'close'}), startsWith('Close'));
        expect(
          await label({'action': 'move', 'left': 10, 'top': 20}),
          'Move Calculator: "Calculator" to 10,20',
        );
        expect(
          await label({'action': 'move', 'width': 300, 'height': 200}),
          'Resize Calculator: "Calculator" to 300x200',
        );
        expect(
          await label({
            'action': 'move',
            'left': 10,
            'top': 20,
            'width': 300,
            'height': 200,
          }),
          'Move Calculator: "Calculator" to 10,20, 300x200',
        );
        final card = await plan('os_window', {
          'window': 'Calculator',
          'action': 'close',
        });
        expect(card['window'], 'Calculator: "Calculator"');
        expect(backend.arranged, isEmpty);
      });

      test('refuses a bad action, a move with nowhere to go, and halves of '
          'a point or a size', () async {
        await expectLater(
          plan('os_window', {'window': 99}),
          refused('needs an action'),
        );
        await expectLater(
          plan('os_window', {'window': 99, 'action': 'shake'}),
          refused('needs an action'),
        );
        await expectLater(
          plan('os_window', {'window': 99, 'action': 'move'}),
          refused('move needs'),
        );
        await expectLater(
          plan('os_window', {'window': 99, 'action': 'move', 'left': 1}),
          refused('together'),
        );
        await expectLater(
          plan('os_window', {
            'window': 99,
            'action': 'move',
            'width': 0,
            'height': 5,
          }),
          refused('above 0'),
        );
        await expectLater(
          plan('os_window', {'action': 'close'}),
          refused('os_window needs a window'),
        );
      });

      test("Voyager's window can't be closed, though it can be minimized; "
          "Gaia's isn't found; an excluded one is refused", () async {
        await expectLater(
          plan('os_window', {'window': 7, 'action': 'close'}),
          refused("can't be closed"),
        );
        await plan('os_window', {'window': 7, 'action': 'minimize'});
        await expectLater(
          plan('os_window', {'window': 'Gaia', 'action': 'minimize'}),
          refused('No open window matches'),
        );
        excluded = ['calc'];
        await expectLater(
          plan('os_window', {'window': 99, 'action': 'minimize'}),
          refused('excluded'),
        );
      });

      test('approved, it runs, flashed where the window was', () async {
        for (final (arguments, did) in [
          ({'action': 'minimize'}, 'minimize 99'),
          ({'action': 'maximize'}, 'maximize 99'),
          ({'action': 'close'}, 'close 99'),
          ({'action': 'move', 'left': 5, 'top': 6}, 'move 99 5,6 nullxnull'),
        ]) {
          backend.arranged.clear();
          flashes.clear();
          await shown.plan('chat', 'card', 'os_window', {
            'window': 99,
            ...arguments,
          });
          final result = await runShown();
          expect(result['stopped'], isNull);
          expect(backend.arranged, [did]);
          expect(flashes.single, {
            'kind': 'window',
            'left': 0,
            'top': 0,
            'right': 800,
            'bottom': 600,
            'label': 'Calculator',
          });
        }
        await shown.plan('chat', 'card', 'os_window', {
          'window': 99,
          'action': 'restore',
        });
        await runShown();
        expect(backend.restored, [99]);
        // Nothing was sent.
        expect(backend.calls, isEmpty);
      });

      test("a window that won't come out of maximized isn't moved, and "
          'says so', () async {
        backend.stuck = true;
        await shown.plan('chat', 'card', 'os_window', {
          'window': 99,
          'action': 'move',
          'left': 5,
          'top': 6,
        });
        final result = await runShown();
        expect(result['stopped'], contains('not be responding'));
        expect(backend.arranged, isEmpty);
      });

      test('a minimized window gets no flash, and one that closed is a '
          'stop', () async {
        backend.minimizedWindows.add(99);
        await shown.plan('chat', 'card', 'os_window', {
          'window': 99,
          'action': 'restore',
        });
        await runShown();
        expect(flashes, isEmpty);
        await shown.plan('chat', 'card', 'os_window', {
          'window': 99,
          'action': 'close',
        });
        backend.windows.remove(99);
        backend.window = null;
        expect((await runShown())['stopped'], contains('closed'));
        expect(backend.arranged, isEmpty);
      });

      test('in Auto, minimizing the pin leaves none, and Gaia coming in '
          'front after is no pause', () async {
        shown.session('chat', auto: true, onUserStop: () {});
        backend.onMinimize = () => backend.front = gaia.hwnd;
        await shown.plan('chat', 'card', 'os_window', {
          'window': 7,
          'action': 'minimize',
        });
        expect((await runShown())['stopped'], isNull);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(shown.sessionPaused, isFalse);
        expect(shown.sessionStopped, isNull);
        expect(
          () => shown.session('chat', auto: true, onUserStop: () {}),
          refused('os_open or os_focus one'),
        );
      });

      test('in Auto, restoring a window pins it, and it coming in front '
          'is not the user switching', () async {
        var userStopped = false;
        shown.session('chat', auto: true, onUserStop: () => userStopped = true);
        backend
          ..minimizedWindows.add(99)
          ..restoreActivates = true;
        await shown.plan('chat', 'card', 'os_window', {
          'window': 99,
          'action': 'restore',
        });
        final result = await runShown();
        expect(result['stopped'], isNull);
        // Later calls act on it, so the agent is told.
        expect(result['front'], 'Calculator: "Calculator"');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(userStopped, isFalse);
        expect(shown.session('chat', auto: true, onUserStop: () {})?.hwnd, 99);
      });
    });

    group('os_drag', () {
      test('takes names or points, and shows its start on the card', () async {
        final card = await plan('os_drag', {
          'from': {'name': 'Save'},
          'to': {'x': 400, 'y': 300},
        });
        expect(stepsOf(card).single, {
          'label': 'Drag from Button "Save" [10,10 20x20] to 400, 300',
          'resolved': true,
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
        final steps = await plan('os_steps', {
          'steps': [
            {
              'action': 'drag',
              'from': {'x': 10, 'y': 10},
              'to': {'x': 50, 'y': 60},
            },
          ],
        });
        expect(stepsOf(steps).single['label'], 'Drag from 10, 10 to 50, 60');
        expect(backend.calls, isEmpty);
      });

      test('an end not on screen yet leaves the step unresolved', () async {
        backend.matches = [];
        final card = await plan('os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'name': 'Bin'},
        });
        expect(stepsOf(card).single['resolved'], false);
      });

      test('from a point, it resolves once its end comes on screen', () async {
        backend.matches = [];
        await plan('os_steps', {
          'steps': [
            {'action': 'key', 'keys': 'A'},
            {
              'action': 'drag',
              'from': {'x': 10, 'y': 10},
              'to': {'name': 'Save'},
            },
          ],
        });
        backend.gaiaInFront = true;
        backend.onSend = () => backend.matches = [_button()];
        final first = await run(once: false);
        expect(first['ran'], 1);
        expect(stepsOf(first)[1]['resolved'], true);
      });

      test('refuses a missing end, half a point, and anywhere', () async {
        await expectLater(
          plan('os_drag', {
            'from': {'x': 1, 'y': 1},
          }),
          refused('A drag needs to'),
        );
        await expectLater(
          plan('os_drag', {
            'from': {'x': 1},
            'to': {'x': 2, 'y': 2},
          }),
          refused('together'),
        );
        await expectLater(
          plan('os_drag', {
            'from': {'x': 1, 'y': 1},
            'to': {'x': 900, 'y': 2},
          }),
          refused('outside'),
        );
        await expectLater(
          plan('os_drag', {
            'from': {'x': 1, 'y': 1},
            'to': {'x': 2, 'y': 2},
            'anywhere': true,
          }),
          refused('anywhere'),
        );
      });

      test('presses at the start, moves in steps, and lets go at the end, '
          'with one trail ahead of the press', () async {
        await shown.plan('chat', 'card', 'os_drag', {
          'from': {'name': 'Save'},
          'to': {'x': 400, 'y': 300},
        });
        final result = await runShown();
        expect(result['stopped'], isNull);
        expect(buttons(), [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP]);
        expect(backend.cursor.first, (20, 20));
        expect(backend.cursor.last, (400, 300));
        expect(backend.cursor.length, 11);
        expect(flashes.single, {
          'kind': 'drag',
          'x': 20,
          'y': 20,
          'to_x': 400,
          'to_y': 300,
          'ms': 330,
          'label': 'Save',
        });
      });

      test('a swapped mouse drags with its right button', () async {
        backend.swapped = true;
        await plan('os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 50, 'y': 60},
        });
        await run();
        expect(buttons(), [MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP]);
      });

      test('stopped mid-drag, it lets go where it started, so no button '
          'stays down', () async {
        await plan('os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        final sentAt = <DateTime>[];
        final sentFrom = <(int, int)>[];
        backend.onSend = () {
          sentAt.add(DateTime.now());
          sentFrom.add(backend.cursor.last);
          if (backend.calls.length == 4) control.stop('The user pressed Esc.');
        };
        final result = await run();
        expect(
          result['stopped'],
          'The user pressed Esc. The drag had begun, so Gaia moved back and '
          'let go where it started, which most apps take as no drag.',
        );
        expect(buttons(), [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP]);
        expect(backend.cursor.last, (10, 10));
        // A move back, then time for the app to see it, then the release
        // (BUG-359): let go at once, an app takes it where the drag reached.
        final [..., moveBack, release] = [
          for (final call in backend.calls)
            [for (final event in call) (event as GaiaMouseEvent).flags],
        ];
        expect(moveBack, [MOUSEEVENTF_MOVE]);
        expect(release, [MOUSEEVENTF_LEFTUP]);
        final [..., movedFrom, _] = sentFrom;
        expect(movedFrom, (10, 10));
        final [..., movedAt, releasedAt] = sentAt;
        expect(
          releasedAt.difference(movedAt),
          greaterThanOrEqualTo(const Duration(milliseconds: 40)),
        );
      });

      test('stopped as its window loses the front, it says part of the drag '
          'may have taken effect (BUG-361)', () async {
        await plan('os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        backend.onSend = () {
          if (backend.calls.length == 4) backend.front = 99;
        };
        final result = await run();
        expect(
          result['stopped'],
          'The window in front changed. The drag had begun, and its window '
          'lost the front, which ends a drag where it had reached in most '
          'apps, so part of it may have taken effect.',
        );
        // Still let go, so no button stays down.
        expect(buttons(), [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP]);
        // Not moved back, button down, over whatever is in front now.
        expect(backend.cursor.last, isNot((10, 10)));
      });

      test('a window that lost the front mid-drag and got it back still '
          'says part of the drag may have taken effect', () async {
        await plan('os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        var seen = false;
        backend.onForeground = () {
          if (backend.front != 99) return;
          // Out of the front for one look, then back.
          if (seen) backend.front = _target.hwnd;
          seen = true;
        };
        backend.onSend = () {
          if (backend.calls.length == 4) {
            backend.front = 99;
            control.stop('The user pressed Esc.');
          }
        };
        final result = await run();
        backend.onForeground = null;
        expect(
          result['stopped'],
          'The user pressed Esc. The drag had begun, and its window lost the '
          'front, which ends a drag where it had reached in most apps, so '
          'part of it may have taken effect.',
        );
        expect(buttons(), [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP]);
      });

      test('stopped once the user has taken the mouse, it lets go where they '
          'have it, and leaves the cursor alone', () async {
        shown.session('chat', auto: true, onUserStop: () {});
        await shown.plan('chat', 'card', 'os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        backend.onSend = () {
          if (backend.calls.length == 3) {
            backend.userMoved = (x: 700, y: 80);
            backend.escape = true;
          }
        };
        final result = await runShown();
        expect(
          result['stopped'],
          'The user pressed Esc. The drag had begun, and Gaia let go where '
          'the user has the mouse, so part of it may have taken effect.',
        );
        expect(buttons(), [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP]);
        // Not moved back to 10,10 to let go.
        expect(backend.cursor.last, isNot((10, 10)));
        expect(flashes.map((f) => f['kind'] ?? 'stop'), ['drag', 'stop']);
      });

      test('if the user takes the mouse while it waits to let go, it says '
          'so', () async {
        shown.session('chat', auto: true, onUserStop: () {});
        await shown.plan('chat', 'card', 'os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        var stopped = false;
        backend.onSend = () {
          // The first send after the stop is the move back.
          if (stopped && backend.userMoved == null) {
            backend.userMoved = (x: 700, y: 80);
            backend.inputTick++;
          }
          if (backend.calls.length == 3) stopped = backend.escape = true;
        };
        final result = await runShown();
        expect(
          result['stopped'],
          'The user pressed Esc. The drag had begun, and Gaia let go where '
          'the user has the mouse, so part of it may have taken effect.',
        );
        expect(buttons(), [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP]);
      });

      test('in a session, Esc mid-drag lets go too', () async {
        shown.session('chat', auto: true, onUserStop: () {});
        await shown.plan('chat', 'card', 'os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        backend.onSend = () {
          if (backend.calls.length == 3) backend.escape = true;
        };
        final result = await runShown();
        expect(result['stopped'], startsWith('The user pressed Esc. The drag'));
        expect(buttons(), [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP]);
        expect(backend.cursor.last, (10, 10));
        // Its trail ends there too, rather than going on to the end.
        expect(flashes.map((f) => f['kind'] ?? 'stop'), ['drag', 'stop']);
      });

      test("a finished drag leaves its trail to play out", () async {
        await shown.plan('chat', 'card', 'os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        expect((await runShown())['stopped'], isNull);
        expect(flashes.map((f) => f['kind']), ['drag']);
      });

      test('stopped before the press, its trail ends there', () async {
        late final GaiaOsControl stopping;
        stopping = GaiaOsControl(
          companionPid: () => 1,
          exclusions: () => excluded,
          vaultUnlocked: () => vault,
          voyagerPid: 70,
          backend: backend,
          flash: (flash) {
            flashes.add(flash);
            stopping.stop('The user pressed Esc.');
          },
          stopFlashes: () => flashes.add(const {'stopped': true}),
          settle: Duration.zero,
          leadIn: const Duration(milliseconds: 30),
          pace: Duration.zero,
          holdLimit: const Duration(seconds: 2),
        );
        await stopping.plan('chat', 'card', 'os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        final result = await stopping.run(
          'card',
          once: true,
          check: () async {},
        );
        expect(result['stopped'], 'The user pressed Esc.');
        expect(buttons(), isEmpty);
        expect(flashes.map((f) => f['kind'] ?? 'stop'), ['drag', 'stop']);
      });

      test('the window changing mid-drag is a stop, and lets go', () async {
        await plan('os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        backend.onSend = () {
          if (backend.calls.length == 2) backend.front = 99;
        };
        final result = await run();
        expect(result['stopped'], contains('changed'));
        expect(buttons().last, MOUSEEVENTF_LEFTUP);
      });

      test('a window covering the end lets go where it started', () async {
        await plan('os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        backend.onSend = () {
          if (backend.calls.length == 11) backend.rootUnder = 99;
        };
        final result = await run();
        expect(result['stopped'], contains('covering 500,500'));
        expect(buttons(), [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP]);
        expect(backend.cursor.last, (10, 10));
      });

      test('the button is never held past the limit', () async {
        final slow = GaiaOsControl(
          companionPid: () => 1,
          exclusions: () => excluded,
          vaultUnlocked: () => vault,
          voyagerPid: 70,
          backend: backend,
          settle: Duration.zero,
          holdLimit: const Duration(milliseconds: 50),
        );
        await slow.plan('chat', 'card', 'os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        final result = await slow.run('card', once: true, check: () async {});
        expect(result['stopped'], contains('too long'));
        expect(buttons(), [MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP]);
        expect(backend.cursor.last, (10, 10));
      });

      test('Windows refusing the press still sends the release', () async {
        await plan('os_drag', {
          'from': {'x': 10, 'y': 10},
          'to': {'x': 500, 'y': 500},
        });
        backend.sendLimit = 0;
        final result = await run();
        expect(result['stopped'], contains('refused'));
        expect(buttons(), [MOUSEEVENTF_LEFTUP]);
      });
    });

    group('os_clipboard', () {
      test('a write is a step that names the text, cut short on the '
          'card', () async {
        final card = await plan('os_clipboard', {
          'action': 'write',
          'text': 'hello',
        });
        expect(card['window'], 'the clipboard');
        expect(stepsOf(card).single['label'], 'Put "hello" on the clipboard');
        expect(backend.clipboard, isEmpty);
        final long = await plan('os_clipboard', {
          'action': 'write',
          'text': 'x' * 300,
        });
        expect(
          stepsOf(long).single['label'],
          'Put "${'x' * 200}…" on the clipboard',
        );
      });

      test('refuses a read here, no text, and too much', () async {
        await expectLater(
          plan('os_clipboard', {'action': 'read'}),
          refused('"write"'),
        );
        await expectLater(
          plan('os_clipboard', {'action': 'write'}),
          refused('needs text'),
        );
        await expectLater(
          plan('os_clipboard', {'action': 'write', 'text': 'x' * 20001}),
          refused('at most 20000'),
        );
      });

      test('approved, it writes, with no window needed; a busy clipboard '
          'is a stop', () async {
        backend.window = null;
        shown.session(
          'chat',
          auto: true,
          onUserStop: () {},
          needsWindow: false,
        );
        await shown.plan('chat', 'card', 'os_clipboard', {
          'action': 'write',
          'text': 'hello',
        });
        expect((await runShown())['stopped'], isNull);
        expect(backend.clipboard, ['hello']);
        expect(backend.calls, isEmpty);
        expect(flashes, isEmpty);
        backend.clipboardBusy = true;
        await shown.plan('chat', 'card', 'os_clipboard', {
          'action': 'write',
          'text': 'again',
        });
        expect(
          (await runShown())['stopped'],
          contains('left it as it was: another app may be using it'),
        );
      });
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
