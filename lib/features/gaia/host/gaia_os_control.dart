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

  /// Moves when the user presses a key or a mouse button. While [watchInput]
  /// is on, that's the runner's count, which leaves out injected input, the
  /// mouse moving and the wheel. Otherwise it's `GetLastInputInfo`'s tick,
  /// which Gaia's own input and any mouse move also move, and which ticks about
  /// every 16 ms, so input in the same tick as Gaia's can't be told from it.
  int lastInput();

  /// Turns on the runner's count for [lastInput], for an Auto session.
  void watchInput(bool on);
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
    this.flash,
    int? voyagerPid,
    GaiaInputBackend? backend,
    this._settle = const Duration(milliseconds: 150),
    this._leadIn = const Duration(milliseconds: 120),
    this._pace = const Duration(milliseconds: 250),
    this._modifierWait = const Duration(seconds: 3),
    this._activateWait = const Duration(seconds: 2),
    this._adoptWithin = const Duration(milliseconds: 1500),
    this._pauseLimit = const Duration(minutes: 5),
  }) : _voyagerPid = voyagerPid ?? pid,
       _backend = backend ?? _Win32InputBackend();

  final int Function() companionPid;
  final List<String> Function() exclusions;
  final bool Function() vaultUnlocked;

  /// Plays a flash on screen (GAIA_AUTONOMY_HLD.md §6), as `gaia_flash.dart`
  /// takes it. Null for none, and then no step waits for one.
  final void Function(Map<String, Object?> flash)? flash;
  final int _voyagerPid;
  final GaiaInputBackend _backend;
  final Duration _settle;

  /// How long a step's flash plays before its input (§6.2), and the least
  /// time from one Auto step's start to the next (§5.6).
  final Duration _leadIn;
  final Duration _pace;
  final Duration _modifierWait;
  final Duration _activateWait;
  final Duration _adoptWithin;
  final Duration _pauseLimit;

  final _plans = <String, _Plan>{};
  _Active? _active;
  _Session? _session;

  static const _reask = Duration(milliseconds: 250);
  static const _maxSteps = 20;
  static const _maxText = 2000;
  static const _typeChunk = 4;

  /// One notch of the wheel: `WHEEL_DELTA`, which the win32 package has no name
  /// for.
  static const _wheelDelta = 120;
  static const _stuck =
      "That window didn't answer in time, or an earlier read of it is still "
      'going. Try again shortly.';

  /// The chat whose Auto turn holds the screen (GAIA_AUTONOMY_HLD.md §5.1).
  String? get sessionChat => _session?.chatId;

  /// What [chatId]'s `os_*` call works on: the session's pinned window, starting
  /// the session if [auto], or null for a chat with none, which goes by what's
  /// in front as ever. Refused while another chat holds the screen, or once this
  /// turn has been stopped. [onUserStop] runs if Esc or a switch of window stops
  /// the session.
  GaiaForegroundWindow? session(
    String chatId, {
    required bool auto,
    required void Function() onUserStop,
  }) {
    var session = _session;
    if (session != null && session.chatId != chatId) {
      throw GaiaReadException('Another chat is controlling the screen.');
    }
    if (session == null) {
      if (!auto) return null;
      if (_active case final active? when active.chatId != chatId) {
        throw GaiaReadException('Another chat is controlling the screen.');
      }
      final window =
          _backend.target(companionPid()) ??
          (throw GaiaReadException(
            'There is no window to act on: nothing is open behind Gaia, or the '
            'session is locked.',
          ));
      _backend.watchInput(true);
      final front = _backend.foreground();
      final started = session = _session = _Session(
        chatId,
        window,
        onUserStop,
        lastFront: front,
        engaged: front == window.hwnd,
        inputMark: _backend.lastInput(),
      );
      started.watch = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => _look(started),
      );
    }
    if (session.latch case final why?) {
      throw GaiaReadException(
        '$why Nothing more can be sent this turn. End your turn; the user can '
        'ask again.',
      );
    }
    final now = _backend.describe(session.pin.hwnd);
    if (now == null || now.pid != session.pin.pid) {
      throw GaiaReadException('The window Gaia was working in closed.');
    }
    return session.pin = now;
  }

  /// Ends the session, or only [chatId]'s if it's that chat's: its turn is over.
  void endTurn([String? chatId]) {
    final session = _session;
    if (session == null || (chatId != null && session.chatId != chatId)) return;
    session.watch?.cancel();
    _backend.watchInput(false);
    session.latch ??= 'The turn ended.';
    if (_active?.chatId == session.chatId) _active!.stop(session.latch!);
    _session = null;
  }

  /// One look for the user stepping in (§5.2, §5.3), every 20 ms for the whole
  /// session, whatever the agent is doing.
  void _look(_Session session) {
    if (session.latch != null) return;
    final now = DateTime.now();
    _noteUserInput(session, now);
    if (_backend.escapeDown() && !now.isBefore(session.ownEscapeUntil)) {
      return _userStop(session, 'The user pressed Esc.');
    }
    final pausedAt = session.pausedAt;
    if (pausedAt != null && now.difference(pausedAt) > _pauseLimit) {
      return _userStop(session, 'Gaia stayed in front for too long.');
    }
    final front = _backend.foreground();
    // Mid-switch, nothing is in front.
    if (front == 0 || front == session.lastFront) return;
    session.lastFront = front;
    if (front == session.pin.hwnd) {
      session.engaged = true;
      session.pausedAt = null;
      return;
    }
    final window = _backend.describe(front);
    if (window?.pid == companionPid()) {
      // The turn's first action brings the target up from behind Gaia; after
      // that, Gaia in front is the user looking at it.
      if (session.engaged) session.pausedAt ??= now;
      return;
    }
    session.pausedAt = null;
    final lastStep = session.lastStep;
    final lastUser = session.lastUserInput;
    final caused =
        lastStep != null &&
        now.difference(lastStep) <= _adoptWithin &&
        (lastUser == null || now.difference(lastUser) > _adoptWithin);
    if (!caused) {
      return _userStop(session, 'The user switched to another window.');
    }
    // The shell isn't a window to act in; the next step brings the pin back.
    if (window == null || _backend.inFrontOfTarget(front, companionPid())) {
      return;
    }
    session.pin = window;
    session.adopted = '${window.app}: ${jsonEncode(window.title)}';
    session.engaged = true;
    flash?.call({
      'kind': 'window',
      ..._rectOf(_backend.frame(front)),
      'label': window.app,
    });
  }

  /// The input tick moved since Gaia last sent anything, so that wasn't Gaia.
  void _noteUserInput(_Session session, DateTime now) {
    final tick = _backend.lastInput();
    if (tick == session.inputMark) return;
    session.inputMark = tick;
    session.lastUserInput = now;
  }

  void _userStop(_Session session, String why) {
    session.latch = why;
    if (_active?.chatId == session.chatId) _active!.stop(why);
    session.onUserStop();
  }

  /// Resolves tool call [tool] for the card [cardId] (§15.6), and returns the
  /// card's `{window, steps}`. Nothing is sent.
  Future<Map<String, Object?>> plan(
    String chatId,
    String cardId,
    String tool,
    Map<String, Object?> arguments,
  ) async {
    final steps = _parse(tool, arguments);
    final session = _session?.chatId == chatId ? _session : null;
    final window =
        session?.pin ??
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
    final plan = _Plan(
      chatId,
      window,
      steps,
      session,
      _backend.frame(window.hwnd),
    );
    await _resolveAll(plan, from: 0);
    _plans[cardId] = plan;
    return {...plan.toCard(), if (session != null) 'auto': true};
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
    if (_session case final other? when other.chatId != plan.chatId) {
      throw GaiaReadException('Another chat is controlling the screen.');
    }
    final session = plan.session;
    // Approving once needs every step's target shown (§15.6). In Auto nothing
    // is shown, and each step looks for its control as it comes up.
    if (session == null &&
        once &&
        plan.steps.skip(plan.next).any((step) => !step.resolved)) {
      throw GaiaReadException(
        "Some of these steps' controls aren't on screen yet, so they need "
        'approving one at a time.',
      );
    }
    final active = _active = _Active(plan.chatId);
    if (session?.latch case final why?) active.stop(why);
    // A session is already looking.
    final escape = session != null
        ? null
        : Timer.periodic(const Duration(milliseconds: 20), (_) {
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
      escape?.cancel();
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
      'adopted': ?session?.takeAdopted(),
      'steps': plan.toCard()['steps'],
    };
  }

  /// Forgets a plan that won't run.
  void drop(String cardId) => _plans.remove(cardId);

  /// Ends the run in progress, or [chatId]'s if it's that chat's: Abort, Stop,
  /// the grant taken back, the companion gone. With [latch], the session's turn
  /// can send nothing more, however slowly its agent stops.
  void stop(String why, {String? chatId, bool latch = false}) {
    final session = _session;
    if (latch && session != null && session.chatId == chatId) {
      session.latch ??= why;
    }
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
    final session = plan.session;
    if (session != null) {
      // Time to see each flash, and to react (§5.6).
      if (session.stepStarted case final last?) {
        final wait = last.add(_pace).difference(DateTime.now());
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        active.throwIfStopped();
      }
      session.stepStarted = DateTime.now();
    }
    await check();
    active.throwIfStopped();
    await _waitForModifiers(active);
    final GaiaForegroundWindow window;
    if (session != null) {
      window = await _sessionTarget(session, active);
    } else {
      window = plan.window;
      if (mayActivate) {
        await _bringInFront(window, active);
      } else {
        _inFront(window);
      }
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
    if (step.action == _Action.type && (match?.sensitive ?? false)) {
      throw _Stopped(
        'That is a password, card or one-time code field, which Gaia never '
        'types into.',
      );
    }
    final point = step.aimed || step.action == _Action.scroll
        ? _pointOf(window, step, match)
        : null;
    if (flash case final play?) {
      final shown = step.flash(
        _backend.frame(window.hwnd),
        match,
        preview: false,
        typing: _typingTime(step),
      );
      if (shown != null) {
        play(shown);
        // The flash leads, so the eye gets there first (§6.2).
        await Future<void>.delayed(_leadIn);
        active.throwIfStopped();
      }
    }
    switch (step.action) {
      case _Action.click:
        _click(window, step, point!);
      case _Action.scroll:
        _scroll(window, step, point!);
      case _Action.type:
        if (step.aimed) {
          _click(window, step, point!, plain: true);
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
  /// so the foreground is watched until it has. With [unprompted], no click
  /// handed Gaia the right to, and Windows refuses a process that hasn't had the
  /// last input: tapping an unbound key makes this that process (§5.4).
  Future<void> _bringInFront(
    GaiaForegroundWindow window,
    _Active active, {
    bool unprompted = false,
  }) async {
    final front = _backend.foreground();
    if (front == window.hwnd) return;
    if (!_backend.inFrontOfTarget(front, companionPid())) {
      throw _Stopped('The window in front changed.');
    }
    final refused = _Stopped(
      "Windows wouldn't bring ${window.app} to the front.",
    );
    void tap() => _send(const [
      GaiaKeyEvent(VK_F24, up: false),
      GaiaKeyEvent(VK_F24, up: true),
    ], active);
    if (!_backend.activate(window.hwnd)) {
      if (!unprompted) throw refused;
      tap();
      if (!_backend.activate(window.hwnd)) throw refused;
    }
    final until = DateTime.now().add(_activateWait);
    var askAgain = DateTime.now().add(_reask);
    while (true) {
      active.throwIfStopped();
      final now = _backend.foreground();
      if (now == window.hwnd) return;
      // Mid-switch, nothing is in front, or Gaia still is.
      if (now != 0 && !_backend.inFrontOfTarget(now, companionPid())) {
        throw _Stopped('The window in front changed.');
      }
      if (DateTime.now().isAfter(until)) throw refused;
      // Windows can agree and then leave nothing in front. Tapping and asking
      // again gets it there.
      if (unprompted && DateTime.now().isAfter(askAgain)) {
        tap();
        _backend.activate(window.hwnd);
        askAgain = DateTime.now().add(_reask);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// The pinned window, in front: waiting while Gaia is (§5.2), and bringing it
  /// up with no click behind it (§5.4).
  Future<GaiaForegroundWindow> _sessionTarget(
    _Session session,
    _Active active,
  ) async {
    _look(session);
    active.throwIfStopped();
    while (session.pausedAt != null) {
      if (_backend.describe(session.pin.hwnd) == null) {
        throw _Stopped('The window closed.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active.throwIfStopped();
    }
    final window = session.pin;
    await _bringInFront(window, active, unprompted: true);
    return window;
  }

  ({int x, int y}) _pointOf(
    GaiaForegroundWindow window,
    _Step step,
    GaiaControlMatch? match,
  ) {
    final point = step.aim(_backend.frame(window.hwnd), match);
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
        // In a session, far enough apart that the user's input between them
        // shows in [GaiaInputBackend.lastInput].
        await Future<void>.delayed(
          Duration(milliseconds: _session == null ? 1 : 20),
        );
      }
    }
  }

  /// Whatever [SendInput] took of [events], remembering keys left down: a key's
  /// press and release go in one call, so only a short count leaves any.
  void _send(List<GaiaInputEvent> events, _Active active) {
    final session = _session;
    // Before this send's own tick covers up anything the user did.
    if (session != null) _noteUserInput(session, DateTime.now());
    final sent = _backend.send(events);
    if (session != null) {
      final now = DateTime.now();
      session.lastStep = now;
      session.inputMark = _backend.lastInput();
      // The agent's own press isn't the user's.
      if (events.contains(const GaiaKeyEvent(VK_ESCAPE, up: false))) {
        session.ownEscapeUntil = now.add(const Duration(milliseconds: 100));
      }
    }
    for (final event in events.take(sent)) {
      if (event case GaiaKeyEvent(:final vk, :final up)) {
        up ? active.held.remove(vk) : active.held.add(vk);
      }
    }
    if (sent < events.length) {
      throw _Stopped('Windows refused the input.');
    }
  }

  /// About how long [step]'s typing takes, for its flash to last as long.
  Duration _typingTime(_Step step) {
    final text = step.text;
    if (step.action != _Action.type || text == null) return Duration.zero;
    // Enter and Tab each wait to settle.
    final breaks = RegExp('[\n\t]').allMatches(text).length;
    final chunks = (text.length / _typeChunk).ceil();
    return Duration(milliseconds: chunks * (_session == null ? 2 : 20)) +
        _settle * (breaks + (step.aimed ? 1 : 0));
  }

  /// Nothing Gaia pressed stays down (§15.7).
  void _releaseHeld(_Active active) {
    if (active.held.isEmpty) return;
    final session = _session;
    if (session != null) _noteUserInput(session, DateTime.now());
    _backend.send([
      for (final vk in active.held.toList().reversed)
        GaiaKeyEvent(vk, up: true),
    ]);
    // Gaia's own release isn't the user's input.
    if (session != null) session.inputMark = _backend.lastInput();
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

/// One Auto turn's hold on the screen (GAIA_AUTONOMY_HLD.md §5.1).
class _Session {
  _Session(
    this.chatId,
    this.pin,
    this.onUserStop, {
    required this.lastFront,
    required this.engaged,
    required this.inputMark,
  });

  final String chatId;
  final void Function() onUserStop;
  Timer? watch;

  /// The window this turn acts on and reads (§5.2).
  GaiaForegroundWindow pin;

  /// Set once the turn is stopped: its calls are refused from then on.
  String? latch;

  /// The foreground at the last look.
  int lastFront;

  /// The pin has been in front this turn.
  bool engaged;

  /// When Gaia came in front; null unless paused (§5.2).
  DateTime? pausedAt;

  /// When Gaia last sent input, and [GaiaInputBackend.lastInput] as last seen.
  /// A later tick means the user did something, noted in [lastUserInput].
  DateTime? lastStep;
  int inputMark;
  DateTime? lastUserInput;
  DateTime ownEscapeUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// When the last step started, for pacing (§5.6).
  DateTime? stepStarted;

  /// The window adopted since the agent was last told.
  String? adopted;

  String? takeAdopted() {
    final told = adopted;
    adopted = null;
    return told;
  }
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

  /// Where it acts: [match]'s middle, its point, or the middle of [frame].
  ({int x, int y}) aim(
    ({int left, int top, int width, int height}) frame,
    GaiaControlMatch? match,
  ) {
    if (match != null) {
      return (
        x: (match.left + match.right) ~/ 2,
        y: (match.top + match.bottom) ~/ 2,
      );
    }
    if (x case final x?) return (x: x, y: y!);
    return (x: frame.left + frame.width ~/ 2, y: frame.top + frame.height ~/ 2);
  }

  /// Its flash (GAIA_AUTONOMY_HLD.md §6.2) in [frame], its window, against
  /// [match]; with [preview], the marker the card shows (§6.4). Null for a
  /// control not on screen. The pill names the control, never typed text.
  Map<String, Object?>? flash(
    ({int left, int top, int width, int height}) frame,
    GaiaControlMatch? match, {
    required bool preview,
    Duration typing = Duration.zero,
  }) {
    if (name != null && match == null) return null;
    final point = aim(frame, match);
    final at = {'x': point.x, 'y': point.y};
    final rect = match == null
        ? null
        : {
            'left': match.left,
            'top': match.top,
            'right': match.right,
            'bottom': match.bottom,
          };
    final label = match == null ? null : name;
    return switch (action) {
      _Action.click => {
        'kind': preview
            ? 'mark'
            : doubleClick
            ? 'double'
            : button == 'right'
            ? 'right'
            : 'click',
        ...at,
        if (preview) ...?rect,
        'label': ?label,
      },
      _Action.scroll => {
        'kind': 'scroll',
        ...at,
        'direction': direction,
        'amount': amount,
        'label': ?label,
      },
      _Action.type when rect != null => {
        'kind': preview ? 'mark' : 'type',
        ...rect,
        'ms': typing.inMilliseconds,
        'label': ?label,
      },
      _Action.type when aimed => {'kind': preview ? 'mark' : 'click', ...at},
      _Action.type => {'kind': 'key', ..._rectOf(frame), 'label': 'Typing'},
      _Action.key => {'kind': 'key', ..._rectOf(frame), 'label': keys!.label},
    };
  }

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
  _Plan(this.chatId, this.window, this.steps, this.session, this.frame);

  final String chatId;
  final GaiaForegroundWindow window;
  final List<_Step> steps;

  /// Where [window] was when planned, for the card's markers (§6.4).
  final ({int left, int top, int width, int height}) frame;

  /// In Auto, which goes by its pin rather than [window].
  final _Session? session;
  var next = 0;

  Map<String, Object?> toCard() => {
    'window': '${window.app}: ${jsonEncode(window.title)}',
    'app': window.app,
    'steps': [
      for (final step in steps)
        {
          'label': step.label,
          'resolved': step.resolved,
          'flash': ?step.flash(frame, step.match, preview: true),
        },
    ],
  };
}

/// [frame] as the flash channel takes a rect.
Map<String, Object?> _rectOf(
  ({int left, int top, int width, int height}) frame,
) => {
  'left': frame.left,
  'top': frame.top,
  'right': frame.left + frame.width,
  'bottom': frame.top + frame.height,
};

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
    hwnd,
    () => gaiaScanWindow(hwnd, browser: browser, text: false, find: control),
  );

  @override
  Future<String?> address(int hwnd) =>
      gaiaScreenWork<String?>(hwnd, () => gaiaReadAddress(hwnd));

  @override
  Future<bool?> focusSensitive(int hwnd, {required bool browser}) =>
      gaiaScreenWork<bool>(
        hwnd,
        () => gaiaFocusSensitive(hwnd, browser: browser),
      );

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

  /// The runner's count of the user's presses (gaia_user_input.cpp): absent
  /// under `flutter test`, and unused if its hooks didn't go in.
  static final _watch = _runnerExport(
    (runner) => runner.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'GaiaWatchUserInput',
    ),
  );
  static final _count = _runnerExport(
    (runner) => runner.lookupFunction<Uint32 Function(), int Function()>(
      'GaiaUserInputCount',
    ),
  );
  var _counting = false;

  static F? _runnerExport<F>(F Function(DynamicLibrary runner) lookup) {
    try {
      return lookup(DynamicLibrary.executable());
    } on ArgumentError {
      return null;
    }
  }

  @override
  void watchInput(bool on) {
    final watch = _watch;
    if (watch == null || _count == null) return;
    _counting = watch(on ? 1 : 0) != 0 && on;
  }

  @override
  int lastInput() {
    if (_counting) return _count!();
    final info = calloc<LASTINPUTINFO>()..ref.cbSize = sizeOf<LASTINPUTINFO>();
    try {
      GetLastInputInfo(info);
      return info.ref.dwTime;
    } finally {
      free(info);
    }
  }

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
