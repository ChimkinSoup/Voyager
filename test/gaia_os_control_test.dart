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
  GaiaForegroundWindow? describe(int hwnd) => window;
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
  void moveCursor(int x, int y) => cursor.add((x, y));
  @override
  bool get buttonsSwapped => swapped;
  @override
  int send(List<GaiaInputEvent> events) {
    final took = sendLimit ?? events.length;
    calls.add(events);
    sent.addAll(events.take(took));
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
