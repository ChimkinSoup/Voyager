import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show pid;

import 'package:ffi/ffi.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart';
import 'package:win32/win32.dart';

/// One synthetic input: a key, a typed UTF-16 unit, or a mouse event.
sealed class GaiaInputEvent {
  const GaiaInputEvent();
}

class GaiaKeyEvent extends GaiaInputEvent {
  const GaiaKeyEvent(this.vk, {required this.up});

  final int vk;
  final bool up;

  @override
  bool operator ==(Object other) =>
      other is GaiaKeyEvent && other.vk == vk && other.up == up;

  @override
  int get hashCode => Object.hash(vk, up);

  @override
  String toString() => 'key(0x${vk.toRadixString(16)}, ${up ? 'up' : 'down'})';
}

class GaiaUnicodeEvent extends GaiaInputEvent {
  const GaiaUnicodeEvent(this.unit, {required this.up});

  final int unit;
  final bool up;
}

class GaiaMouseEvent extends GaiaInputEvent {
  const GaiaMouseEvent(this.flags, {this.data = 0});

  final int flags;
  final int data;
}

/// The Win32 an action needs; tests pass their own.
abstract interface class GaiaInputBackend {
  GaiaForegroundWindow? target(int gaiaPid);
  GaiaForegroundWindow? describe(int hwnd);
  int foreground();
  bool inFrontOfTarget(int hwnd, int gaiaPid);

  /// Asks for [hwnd] to come to the front; false when Windows refuses. It
  /// isn't there yet on return: [foreground] says when it is.
  bool activate(int hwnd);

  /// The top-level window at a point; clicks go only if it's the target.
  int rootAt(int x, int y);
  ({int left, int top, int width, int height}) frame(int hwnd);

  /// Null when the window didn't answer in time.
  Future<GaiaWindowScan?> find(
    int hwnd, {
    required bool browser,
    required ({String name, String? type}) control,
  });

  /// A browser's address; null when it can't be read.
  Future<String?> address(int hwnd);

  /// Whether what has focus in [hwnd] can't be typed into. Null when UI
  /// Automation didn't answer in time.
  Future<bool?> focusSensitive(int hwnd, {required bool browser});
  bool modifiersDown();
  bool escapeDown();
  void moveCursor(int x, int y);
  bool get buttonsSwapped;

  /// One atomic [SendInput]; how many of [events] went in.
  int send(List<GaiaInputEvent> events);
}

/// The `os_*` action tools (GAIA_HLD.md §15.6), answered by the main instance:
/// [plan] resolves a call into the step list the user sees, and [run] sends it.
/// Whether the chat may act at all, and Abort, are the host's `check`, which
/// runs before every step. Each refusal throws a [GaiaReadException].
class GaiaOsControl {
  GaiaOsControl({
    required this.companionPid,
    required this.exclusions,
    required this.vaultUnlocked,
    int? voyagerPid,
    GaiaInputBackend? backend,
    this._settle = const Duration(milliseconds: 150),
    this._modifierWait = const Duration(seconds: 3),
    this._activateWait = const Duration(seconds: 2),
  }) : _voyagerPid = voyagerPid ?? pid,
       _backend = backend ?? _Win32InputBackend();

  final int Function() companionPid;
  final List<String> Function() exclusions;
  final bool Function() vaultUnlocked;
  final int _voyagerPid;
  final GaiaInputBackend _backend;
  final Duration _settle;
  final Duration _modifierWait;
  final Duration _activateWait;

  final _plans = <String, _Plan>{};
  _Active? _active;

  static const _maxSteps = 20;
  static const _maxText = 2000;
  static const _typeChunk = 4;

  /// One notch of the wheel: `WHEEL_DELTA`, which the win32 package has no name
  /// for.
  static const _wheelDelta = 120;
  static const _stuck =
      "That window didn't answer in time, or an earlier read of it is still "
      'going. Try again shortly.';

  /// Resolves tool call [tool] for the card [cardId] (§15.6), and returns the
  /// card's `{window, steps}`. Nothing is sent.
  Future<Map<String, Object?>> plan(
    String chatId,
    String cardId,
    String tool,
    Map<String, Object?> arguments,
  ) async {
    final steps = _parse(tool, arguments);
    final window =
        _backend.target(companionPid()) ??
        (throw GaiaReadException(
          'There is no window to act on: nothing is open behind Gaia, or the '
          'session is locked.',
        ));
    if (window.exe.isEmpty) {
      throw GaiaReadException("Gaia can't tell what app that window is.");
    }
    _checkWindow(window);
    await _checkSite(window);
    final plan = _Plan(chatId, window, steps);
    await _resolveAll(plan, from: 0);
    _plans[cardId] = plan;
    return plan.toCard();
  }

  /// Sends card [cardId]'s next step, or with [once], all that are left. Each
  /// step first passes [check], and the window checks. Returns `{ran, steps}`,
  /// and `stopped` for why it ended early, after which the plan is gone.
  Future<Map<String, Object?>> run(
    String cardId, {
    required bool once,
    required Future<void> Function() check,
  }) async {
    final plan =
        _plans[cardId] ??
        (throw GaiaReadException('That step list is no longer waiting.'));
    if (_active != null) {
      throw GaiaReadException('Another step list is running. Try again after.');
    }
    // Approving once needs every step's target shown (§15.6).
    if (once && plan.steps.skip(plan.next).any((step) => !step.resolved)) {
      throw GaiaReadException(
        "Some of these steps' controls aren't on screen yet, so they need "
        'approving one at a time.',
      );
    }
    final active = _active = _Active(plan.chatId);
    final escape = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (_backend.escapeDown()) active.stop('The user pressed Esc.');
    });
    String? stopped;
    final activateFirst = plan.next;
    try {
      do {
        await _step(
          plan,
          active,
          check,
          // In a run approved once, Gaia comes in front only if the user
          // clicked it, which is the window changing.
          mayActivate: !once || plan.next == activateFirst,
        );
        plan.next++;
        if (once && plan.next < plan.steps.length) {
          await Future<void>.delayed(_settle);
        }
      } while (once && plan.next < plan.steps.length);
    } on _Stopped catch (stop) {
      stopped = stop.why;
    } on GaiaReadException catch (error) {
      stopped = error.message;
    } finally {
      escape.cancel();
      _releaseHeld(active);
      _active = null;
    }
    if (stopped == null && plan.next < plan.steps.length) {
      // The next step's control may be on screen now, for its approval.
      await Future<void>.delayed(_settle);
      try {
        await _resolveAll(plan, from: plan.next);
      } on GaiaReadException catch (error) {
        stopped = error.message;
      }
    }
    if (stopped != null || plan.next >= plan.steps.length) {
      _plans.remove(cardId);
    }
    return {
      'ran': plan.next,
      'stopped': ?stopped,
      'steps': plan.toCard()['steps'],
    };
  }

  /// Forgets a plan that won't run.
  void drop(String cardId) => _plans.remove(cardId);

  /// Ends the run in progress, or [chatId]'s if it's that chat's: Abort, Stop,
  /// the grant taken back, the companion gone.
  void stop(String why, {String? chatId}) {
    final active = _active;
    if (active == null || (chatId != null && active.chatId != chatId)) return;
    active.stop(why);
  }

  Future<void> _resolveAll(_Plan plan, {required int from}) async {
    for (final step in plan.steps.skip(from)) {
      if (!step.aimed) continue;
      if (step.name == null) {
        _checkPoint(plan.window, step.x!, step.y!);
        continue;
      }
      final match = _matchOf(step, await _matches(plan.window, step));
      step.resolved = match != null;
      step.match = match;
      if (step.action == _Action.type && (match?.sensitive ?? false)) {
        throw GaiaReadException(
          'That is a password, card or one-time code field, which Gaia never '
          'types into.',
        );
      }
    }
  }

  /// The on-screen controls [step] names, its site checked on the way.
  Future<List<GaiaControlMatch>> _matches(
    GaiaForegroundWindow window,
    _Step step,
  ) async {
    final browser = gaiaIsBrowser(window.exe);
    final scan = await _backend.find(
      window.hwnd,
      browser: browser,
      control: (name: step.name!, type: step.type),
    );
    if (scan == null) throw GaiaReadException(_stuck);
    _checkAddress(window, scan.url, browser: browser);
    return scan.matches;
  }

  /// A browser may have gone to an excluded site since the last step.
  Future<void> _checkSite(GaiaForegroundWindow window) async {
    if (!gaiaIsBrowser(window.exe)) return;
    _checkAddress(window, await _backend.address(window.hwnd), browser: true);
  }

  /// The one control [step] means. Several with no point to choose by can't be
  /// resolved, and the agent is told where they are.
  GaiaControlMatch? _matchOf(_Step step, List<GaiaControlMatch> matches) {
    if (matches.isEmpty) return null;
    if (step.x case final x?) {
      for (final match in matches) {
        if (x >= match.left &&
            x < match.right &&
            step.y! >= match.top &&
            step.y! < match.bottom) {
          return match;
        }
      }
      return null;
    }
    if (matches.length == 1) return matches.single;
    throw GaiaReadException(
      '${matches.length} controls are named ${jsonEncode(step.name)}: '
      '${matches.map((m) => '${m.type} at ${m.left},${m.top}').join('; ')}. '
      'Pass x and y inside the one you mean, or its type.',
    );
  }

  void _checkWindow(GaiaForegroundWindow window) {
    if (gaiaContextExcluded(
      exclusions(),
      exe: window.exe,
      app: window.app,
      url: null,
    )) {
      throw GaiaReadException(
        "The user has excluded that app or site, so Gaia can't act on it.",
      );
    }
    if (window.pid == _voyagerPid && vaultUnlocked()) {
      throw GaiaReadException(
        "Voyager's secure vault is unlocked, so Gaia can't act on Voyager's "
        'window until it locks.',
      );
    }
  }

  void _checkAddress(
    GaiaForegroundWindow window,
    String? url, {
    required bool browser,
  }) {
    if (browser && url == null && exclusions().any((e) => e.contains('.'))) {
      throw GaiaReadException(
        "Gaia couldn't read this browser's address, so can't tell whether the "
        'user has excluded the site.',
      );
    }
    if (gaiaContextExcluded(
      exclusions(),
      exe: window.exe,
      app: window.app,
      url: url,
    )) {
      throw GaiaReadException(
        "The user has excluded that app or site, so Gaia can't act on it.",
      );
    }
  }

  void _checkPoint(GaiaForegroundWindow window, int x, int y) {
    final frame = _backend.frame(window.hwnd);
    if (x < frame.left ||
        y < frame.top ||
        x >= frame.left + frame.width ||
        y >= frame.top + frame.height) {
      throw GaiaReadException(
        '$x,$y is outside ${window.app}, which is at '
        '${frame.left},${frame.top}, ${frame.width}x${frame.height}.',
      );
    }
  }

  Future<void> _step(
    _Plan plan,
    _Active active,
    Future<void> Function() check, {
    required bool mayActivate,
  }) async {
    final step = plan.steps[plan.next];
    final window = plan.window;
    await check();
    active.throwIfStopped();
    await _waitForModifiers(active);
    if (mayActivate) {
      await _bringInFront(window, active);
    } else {
      _inFront(window);
    }
    // A run stops if the window changes (§15.6), and an hwnd can be reused.
    final now = _backend.describe(window.hwnd);
    if (now == null || now.pid != window.pid) {
      throw _Stopped('The window closed.');
    }
    _checkWindow(now);
    final GaiaControlMatch? match;
    if (step.name == null) {
      match = null;
      await _checkSite(window);
    } else {
      match = _matchOf(step, await _matches(window, step));
      if (match == null) {
        throw _Stopped(
          'The control ${jsonEncode(step.name)} is not on screen.',
        );
      }
    }
    active.throwIfStopped();
    switch (step.action) {
      case _Action.click:
        _click(window, step, _pointOf(window, step, match));
      case _Action.scroll:
        _scroll(window, step, _pointOf(window, step, match));
      case _Action.type:
        if (match?.sensitive ?? false) {
          throw _Stopped(
            'That is a password, card or one-time code field, which Gaia never '
            'types into.',
          );
        }
        if (step.aimed) {
          _click(window, step, _pointOf(window, step, match), plain: true);
          await Future<void>.delayed(_settle);
        }
        await _checkFocus(window);
        active.throwIfStopped();
        await _type(window, step.text!, active);
      case _Action.key:
        if (step.keys!.typesText) await _checkFocus(window);
        active.throwIfStopped();
        _inFront(window);
        _send(step.keys!.events, active);
    }
    active.throwIfStopped();
  }

  Future<void> _checkFocus(GaiaForegroundWindow window) async {
    final sensitive = await _backend.focusSensitive(
      window.hwnd,
      browser: gaiaIsBrowser(window.exe),
    );
    if (sensitive == null) throw _Stopped(_stuck);
    if (sensitive) {
      throw _Stopped(
        'What has focus is a password, card or one-time code field, which '
        "Gaia never types into, or Gaia couldn't tell what has focus.",
      );
    }
  }

  /// Approving with Ctrl+Enter leaves Ctrl down for a moment, and a held Ctrl
  /// would turn a click or a typed letter into something else.
  Future<void> _waitForModifiers(_Active active) async {
    final until = DateTime.now().add(_modifierWait);
    while (_backend.modifiersDown()) {
      active.throwIfStopped();
      if (DateTime.now().isAfter(until)) {
        throw _Stopped('A modifier key stayed held down.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void _inFront(GaiaForegroundWindow window) {
    if (_backend.foreground() == window.hwnd) return;
    throw _Stopped('The window in front changed.');
  }

  /// [_inFront], first bringing the target up from behind Gaia or the shell.
  /// Windows switches to another process's window a moment after agreeing to,
  /// so the foreground is watched until it has.
  Future<void> _bringInFront(
    GaiaForegroundWindow window,
    _Active active,
  ) async {
    final front = _backend.foreground();
    if (front == window.hwnd) return;
    if (!_backend.inFrontOfTarget(front, companionPid())) {
      throw _Stopped('The window in front changed.');
    }
    final refused = _Stopped(
      "Windows wouldn't bring ${window.app} to the front.",
    );
    if (!_backend.activate(window.hwnd)) throw refused;
    final until = DateTime.now().add(_activateWait);
    while (true) {
      active.throwIfStopped();
      final now = _backend.foreground();
      if (now == window.hwnd) return;
      // Mid-switch, nothing is in front, or Gaia still is.
      if (now != 0 && !_backend.inFrontOfTarget(now, companionPid())) {
        throw _Stopped('The window in front changed.');
      }
      if (DateTime.now().isAfter(until)) throw refused;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  ({int x, int y}) _pointOf(
    GaiaForegroundWindow window,
    _Step step,
    GaiaControlMatch? match,
  ) {
    final ({int x, int y}) point;
    if (match != null) {
      point = (
        x: (match.left + match.right) ~/ 2,
        y: (match.top + match.bottom) ~/ 2,
      );
    } else if (step.x case final x?) {
      point = (x: x, y: step.y!);
    } else {
      final frame = _backend.frame(window.hwnd);
      point = (
        x: frame.left + frame.width ~/ 2,
        y: frame.top + frame.height ~/ 2,
      );
    }
    try {
      _checkPoint(window, point.x, point.y);
    } on GaiaReadException catch (error) {
      throw _Stopped(error.message);
    }
    if (_backend.rootAt(point.x, point.y) != window.hwnd) {
      throw _Stopped(
        'Another window is covering ${point.x},${point.y}, perhaps Gaia. Move '
        'it, or ask the user to.',
      );
    }
    return point;
  }

  void _click(
    GaiaForegroundWindow window,
    _Step step,
    ({int x, int y}) point, {
    bool plain = false,
  }) {
    _inFront(window);
    final right = !plain && step.button == 'right';
    // A swapped mouse's left button is sent as its right.
    final (down, up) = right != _backend.buttonsSwapped
        ? (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP)
        : (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
    _backend.moveCursor(point.x, point.y);
    _send([
      for (var i = 0; i < (!plain && step.doubleClick ? 2 : 1); i++) ...[
        GaiaMouseEvent(down),
        GaiaMouseEvent(up),
      ],
    ], _active!);
  }

  void _scroll(
    GaiaForegroundWindow window,
    _Step step,
    ({int x, int y}) point,
  ) {
    _inFront(window);
    _backend.moveCursor(point.x, point.y);
    final horizontal = step.direction == 'left' || step.direction == 'right';
    // Positive is up, and right.
    final sign = step.direction == 'down' || step.direction == 'left' ? -1 : 1;
    _send([
      GaiaMouseEvent(
        horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL,
        data: sign * step.amount * _wheelDelta,
      ),
    ], _active!);
  }

  /// A few characters at a time, looking up between them so that Abort, Esc or
  /// a change of window lands mid-text. Tab and Enter can move the focus, so
  /// what has it is checked again before the text goes on (§15.6).
  Future<void> _type(
    GaiaForegroundWindow window,
    String text,
    _Active active,
  ) async {
    final taps = gaiaTextTaps(text);
    var i = 0;
    while (i < taps.length) {
      await _waitForModifiers(active);
      active.throwIfStopped();
      _inFront(window);
      final chunk = taps.skip(i).take(_typeChunk).toList();
      final moves = chunk.indexWhere((tap) => tap.first is GaiaKeyEvent);
      if (moves >= 0) chunk.length = moves + 1;
      _send([...chunk.expand((tap) => tap)], active);
      i += chunk.length;
      if (moves >= 0 && i < taps.length) {
        await Future<void>.delayed(_settle);
        await _checkFocus(window);
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
  }

  /// Whatever [SendInput] took of [events], remembering keys left down: a key's
  /// press and release go in one call, so only a short count leaves any.
  void _send(List<GaiaInputEvent> events, _Active active) {
    final sent = _backend.send(events);
    for (final event in events.take(sent)) {
      if (event case GaiaKeyEvent(:final vk, :final up)) {
        up ? active.held.remove(vk) : active.held.add(vk);
      }
    }
    if (sent < events.length) {
      throw _Stopped('Windows refused the input.');
    }
  }

  /// Nothing Gaia pressed stays down (§15.7).
  void _releaseHeld(_Active active) {
    if (active.held.isEmpty) return;
    _backend.send([
      for (final vk in active.held.toList().reversed)
        GaiaKeyEvent(vk, up: true),
    ]);
    active.held.clear();
  }

  List<_Step> _parse(String tool, Map<String, Object?> arguments) {
    if (tool == 'os_steps') {
      final steps = arguments['steps'];
      if (steps is! List || steps.isEmpty) {
        throw GaiaReadException('os_steps needs a list of steps.');
      }
      if (steps.length > _maxSteps) {
        throw GaiaReadException('os_steps takes at most $_maxSteps steps.');
      }
      return [
        for (final step in steps)
          if (step is Map)
            _parseStep(step['action'], step.cast<String, Object?>())
          else
            throw GaiaReadException('Each step needs an action.'),
      ];
    }
    return [_parseStep(tool.replaceFirst('os_', ''), arguments)];
  }

  _Step _parseStep(Object? action, Map<String, Object?> args) {
    final parsed = switch (action) {
      'click' => _Action.click,
      'scroll' => _Action.scroll,
      'type' => _Action.type,
      'key' => _Action.key,
      _ => throw GaiaReadException('Unknown action: $action'),
    };
    final name = switch (args['name']) {
      final String name when name.trim().isNotEmpty => name.trim(),
      _ => null,
    };
    final x = (args['x'] as num?)?.toInt();
    final y = (args['y'] as num?)?.toInt();
    if ((x == null) != (y == null)) {
      throw GaiaReadException('Pass x and y together.');
    }
    final step = _Step(
      action: parsed,
      name: name,
      type: args['type'] as String?,
      x: x,
      y: y,
      button: args['button'] as String? ?? 'left',
      doubleClick: args['double'] == true,
      direction: args['direction'] as String?,
      amount: (args['amount'] as num?)?.toInt() ?? 3,
      text: args['text'] as String?,
      keys: switch (parsed) {
        _Action.key => GaiaKeyChord.parse(args['keys']),
        _ => null,
      },
    );
    switch (parsed) {
      case _Action.click:
        if (!step.aimed) {
          throw GaiaReadException('A click needs a name, or x and y.');
        }
      case _Action.scroll:
        if (!const {'up', 'down', 'left', 'right'}.contains(step.direction)) {
          throw GaiaReadException('direction is up, down, left or right.');
        }
        if (step.amount < 1 || step.amount > 50) {
          throw GaiaReadException('amount is 1 to 50 notches.');
        }
      case _Action.type:
        final text = step.text;
        if (text == null || text.isEmpty) {
          throw GaiaReadException('os_type needs text.');
        }
        if (text.length > _maxText) {
          throw GaiaReadException(
            'os_type takes at most $_maxText characters.',
          );
        }
      case _Action.key:
        break;
    }
    return step;
  }
}

/// A stop the agent is told about, rather than an error in its call.
class _Stopped implements Exception {
  _Stopped(this.why);

  final String why;
}

/// The run in progress.
class _Active {
  _Active(this.chatId);

  final String chatId;
  final held = <int>{};
  String? _stopped;

  void stop(String why) => _stopped ??= why;

  void throwIfStopped() {
    if (_stopped case final why?) throw _Stopped(why);
  }
}

enum _Action { click, scroll, type, key }

class _Step {
  _Step({
    required this.action,
    required this.name,
    required this.type,
    required this.x,
    required this.y,
    required this.button,
    required this.doubleClick,
    required this.direction,
    required this.amount,
    required this.text,
    required this.keys,
  }) : resolved = name == null;

  final _Action action;
  final String? name;
  final String? type;
  final int? x;
  final int? y;
  final String button;
  final bool doubleClick;
  final String? direction;
  final int amount;
  final String? text;
  final GaiaKeyChord? keys;

  /// Its control was found as it stands now; always for one that names none.
  bool resolved;
  GaiaControlMatch? match;

  bool get aimed => name != null || x != null;

  String get _target {
    if (name case final name?) {
      final what = jsonEncode(name);
      final kind = match?.type ?? type;
      return [
        ?kind,
        what,
        if (match case final m?)
          '[${m.left},${m.top} ${m.right - m.left}x${m.bottom - m.top}]'
        else
          '(not on screen yet)',
      ].join(' ');
    }
    return 'at $x, $y';
  }

  String get label => switch (action) {
    _Action.click when doubleClick => 'Double-click $_target',
    _Action.click when button == 'right' => 'Right-click $_target',
    _Action.click => 'Click $_target',
    _Action.scroll =>
      'Scroll $direction $amount${aimed ? ' over $_target' : ''}',
    _Action.type =>
      'Type ${jsonEncode(text)} into ${aimed ? _target : 'what has focus'}',
    _Action.key => 'Press ${keys!.label}',
  };
}

class _Plan {
  _Plan(this.chatId, this.window, this.steps);

  final String chatId;
  final GaiaForegroundWindow window;
  final List<_Step> steps;
  var next = 0;

  Map<String, Object?> toCard() => {
    'window': '${window.app}: ${jsonEncode(window.title)}',
    'app': window.app,
    'steps': [
      for (final step in steps)
        {'label': step.label, 'resolved': step.resolved},
    ],
  };
}

/// [text] as one press and release per character: Enter and Tab as their keys,
/// which many apps want, the rest as UTF-16 units, which no keyboard layout or
/// Caps Lock can change. A character outside the BMP stays in one piece.
List<List<GaiaInputEvent>> gaiaTextTaps(String text) => [
  for (final rune in text.replaceAll('\r\n', '\n').runes)
    if (rune == 0x0A || rune == 0x0D)
      const [
        GaiaKeyEvent(VK_RETURN, up: false),
        GaiaKeyEvent(VK_RETURN, up: true),
      ]
    else if (rune == 0x09)
      const [GaiaKeyEvent(VK_TAB, up: false), GaiaKeyEvent(VK_TAB, up: true)]
    else
      [
        for (final unit in String.fromCharCode(rune).codeUnits) ...[
          GaiaUnicodeEvent(unit, up: false),
          GaiaUnicodeEvent(unit, up: true),
        ],
      ],
];

/// A key or chord an agent asked to press.
class GaiaKeyChord {
  GaiaKeyChord._(
    this.label,
    this.modifiers,
    this.key, {
    required this.typesText,
  });

  /// As shown on the card.
  final String label;
  final List<int> modifiers;
  final int key;

  /// The main key would put a character in, or Ctrl+V or Shift+Insert its like,
  /// so it's refused in a sensitive field. Enter, Tab or Esc there only leave it.
  final bool typesText;

  List<GaiaInputEvent> get events => [
    for (final modifier in modifiers) GaiaKeyEvent(modifier, up: false),
    GaiaKeyEvent(key, up: false),
    GaiaKeyEvent(key, up: true),
    for (final modifier in modifiers.reversed) GaiaKeyEvent(modifier, up: true),
  ];

  static const _modifiers = {
    'ctrl': VK_CONTROL,
    'control': VK_CONTROL,
    'alt': VK_MENU,
    'shift': VK_SHIFT,
  };

  static const _named = {
    'enter': VK_RETURN,
    'return': VK_RETURN,
    'esc': VK_ESCAPE,
    'escape': VK_ESCAPE,
    'tab': VK_TAB,
    'space': VK_SPACE,
    'backspace': VK_BACK,
    'delete': VK_DELETE,
    'del': VK_DELETE,
    'insert': VK_INSERT,
    'home': VK_HOME,
    'end': VK_END,
    'pageup': VK_PRIOR,
    'pagedown': VK_NEXT,
    'up': VK_UP,
    'down': VK_DOWN,
    'left': VK_LEFT,
    'right': VK_RIGHT,
  };

  static GaiaKeyChord parse(Object? keys) {
    if (keys is! String || keys.trim().isEmpty) {
      throw GaiaReadException('os_key needs keys, as "Ctrl+S".');
    }
    final parts = keys.split('+').map((part) => part.trim()).toList();
    // "Ctrl++" is the plus key.
    if (parts.length > 2 && parts.last.isEmpty) {
      parts
        ..removeLast()
        ..last = '+';
    }
    final modifiers = <int>[];
    for (final part in parts.take(parts.length - 1)) {
      final lower = part.toLowerCase();
      if (const {'win', 'windows', 'meta', 'cmd', 'super'}.contains(lower)) {
        throw GaiaReadException(
          "The Windows key isn't allowed: it acts on Windows, not the window.",
        );
      }
      final modifier =
          _modifiers[lower] ?? (throw GaiaReadException('Unknown key: $part'));
      if (!modifiers.contains(modifier)) modifiers.add(modifier);
    }
    final main = parts.last;
    final lower = main.toLowerCase();
    if (const {'win', 'windows', 'meta', 'cmd', 'super'}.contains(lower)) {
      throw GaiaReadException(
        "The Windows key isn't allowed: it acts on Windows, not the window.",
      );
    }
    final function = RegExp(r'^f(\d{1,2})$').firstMatch(lower);
    final number = function == null ? null : int.parse(function[1]!);
    final int? vk;
    if (number != null && number >= 1 && number <= 24) {
      vk = VK_F1 + number - 1;
    } else if (_named[lower] case final named?) {
      vk = named;
    } else if (main.length == 1) {
      // A letter or digit's virtual key is its capital; other characters
      // depend on the layout.
      final unit = main.toUpperCase().codeUnitAt(0);
      final isAlnum =
          (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A);
      vk = isAlnum ? unit : _scanned(main.codeUnitAt(0), modifiers);
    } else {
      vk = null;
    }
    if (vk == null) throw GaiaReadException('Unknown key: $main');
    return GaiaKeyChord._(
      parts.join('+'),
      modifiers,
      vk,
      typesText:
          main.length == 1 ||
          vk == VK_SPACE ||
          (vk == VK_INSERT && modifiers.contains(VK_SHIFT)),
    );
  }

  /// A punctuation key on this layout; with the Shift it needs added to
  /// [modifiers]. Null when the layout has no such key.
  static int? _scanned(int unit, List<int> modifiers) {
    final scanned = VkKeyScan(unit);
    if (scanned == -1 || scanned & 0xFF == 0xFF) return null;
    // Ctrl and Alt, as AltGr: not a plain key press.
    if (scanned & 0x600 != 0) return null;
    if (scanned & 0x100 != 0 && !modifiers.contains(VK_SHIFT)) {
      modifiers.add(VK_SHIFT);
    }
    return scanned & 0xFF;
  }
}

class _Win32InputBackend implements GaiaInputBackend {
  @override
  GaiaForegroundWindow? target(int gaiaPid) => gaiaOsTarget(gaiaPid);

  @override
  GaiaForegroundWindow? describe(int hwnd) =>
      IsWindow(hwnd) == 0 ? null : gaiaDescribeWindow(hwnd);

  @override
  int foreground() => GetForegroundWindow();

  @override
  bool inFrontOfTarget(int hwnd, int gaiaPid) =>
      hwnd != 0 && gaiaInFrontOfTarget(hwnd, gaiaPid);

  @override
  bool activate(int hwnd) => SetForegroundWindow(hwnd) != 0;

  @override
  int rootAt(int x, int y) {
    final point = calloc<POINT>()
      ..ref.x = x
      ..ref.y = y;
    try {
      final under = WindowFromPoint(point.ref);
      return under == 0 ? 0 : GetAncestor(under, GA_ROOT);
    } finally {
      free(point);
    }
  }

  @override
  ({int left, int top, int width, int height}) frame(int hwnd) =>
      gaiaWindowFrame(hwnd);

  @override
  Future<GaiaWindowScan?> find(
    int hwnd, {
    required bool browser,
    required ({String name, String? type}) control,
  }) => gaiaScreenWork<GaiaWindowScan?>(
    () => gaiaScanWindow(hwnd, browser: browser, text: false, find: control),
  );

  @override
  Future<String?> address(int hwnd) =>
      gaiaScreenWork<String?>(() => gaiaReadAddress(hwnd));

  @override
  Future<bool?> focusSensitive(int hwnd, {required bool browser}) =>
      gaiaScreenWork<bool>(() => gaiaFocusSensitive(hwnd, browser: browser));

  @override
  bool modifiersDown() => const [
    VK_CONTROL,
    VK_MENU,
    VK_SHIFT,
    VK_LWIN,
    VK_RWIN,
  ].any((key) => GetAsyncKeyState(key) & 0x8000 != 0);

  @override
  bool escapeDown() => GetAsyncKeyState(VK_ESCAPE) & 0x8000 != 0;

  @override
  void moveCursor(int x, int y) => SetCursorPos(x, y);

  @override
  bool get buttonsSwapped => GetSystemMetrics(SM_SWAPBUTTON) != 0;

  @override
  int send(List<GaiaInputEvent> events) {
    if (events.isEmpty) return 0;
    final inputs = calloc<INPUT>(events.length);
    try {
      for (final (i, event) in events.indexed) {
        switch (event) {
          case GaiaKeyEvent(:final vk, :final up):
            inputs[i].type = INPUT_KEYBOARD;
            inputs[i].ki
              ..wVk = vk
              // Flutter names a key by its scan code (gaia_selection.dart).
              ..wScan = MapVirtualKey(vk, MAPVK_VK_TO_VSC)
              ..dwFlags =
                  (up ? KEYEVENTF_KEYUP : 0) |
                  (_extended.contains(vk) ? KEYEVENTF_EXTENDEDKEY : 0);
          case GaiaUnicodeEvent(:final unit, :final up):
            inputs[i].type = INPUT_KEYBOARD;
            inputs[i].ki
              ..wScan = unit
              ..dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
          case GaiaMouseEvent(:final flags, :final data):
            inputs[i].type = INPUT_MOUSE;
            inputs[i].mi
              ..dwFlags = flags
              ..mouseData = data;
        }
      }
      return SendInput(events.length, inputs, sizeOf<INPUT>());
    } finally {
      free(inputs);
    }
  }

  static const _extended = {
    VK_DELETE,
    VK_INSERT,
    VK_HOME,
    VK_END,
    VK_PRIOR,
    VK_NEXT,
    VK_UP,
    VK_DOWN,
    VK_LEFT,
    VK_RIGHT,
  };
}
