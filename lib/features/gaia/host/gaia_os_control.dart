import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show FileSystemEntity, FileSystemEntityType, Process, pid;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/features/gaia/host/gaia_clipboard.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';
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

  /// [hwnd]'s window class, which tells the taskbar from Start, and finds the
  /// border's own windows.
  String windowClass(int hwnd);
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

  /// Where the cursor is.
  ({int x, int y}) cursorAt();
  bool get buttonsSwapped;

  /// One atomic [SendInput]; how many of [events] went in.
  int send(List<GaiaInputEvent> events);

  /// The windows Alt+Tab would show, front first ([gaiaListWindows]).
  List<GaiaListedWindow> listWindows();

  /// The Start menu's apps: each one's name, and the id `shell:AppsFolder`
  /// opens it by.
  Future<List<({String name, String id})>> startApps();

  /// Opens [file] as Explorer would, except that an exe needing administrator
  /// is refused rather than raising a UAC prompt. Returns the
  /// process it started, with a pid of 0 when Windows didn't say, as when an
  /// app already running takes it. Throws a [GaiaReadException] if Windows
  /// couldn't open it.
  Future<({int pid, String? exe})> launch(String file);

  /// Whether process [pid] is still running.
  bool running(int pid);

  /// Every running process's parent, by pid.
  Map<int, int> processParents();

  /// [window]'s app IDs, lowercase: its own, as Store apps' frames carry, and
  /// its process's package's.
  Set<String> appIdsOf(GaiaForegroundWindow window);

  /// What opens a file extension (".pdf"), or with [protocol] a URL scheme:
  /// its exe's name and app ID, where Windows says ([gaiaHandlerOf]).
  ({String? exe, String? appId}) handler(
    String assoc, {
    required bool protocol,
  });

  /// Where a Start menu app [id] points, if it's a shortcut
  /// ([gaiaStartAppTarget]).
  String? startAppTarget(String id);

  /// Where the `.lnk` file at [path] points ([gaiaLinkTarget]).
  String? shortcutTarget(String path);
  bool minimized(int hwnd);

  /// Brings minimized [hwnd] back, without waiting on its app.
  void restore(int hwnd);

  /// Minimizes [hwnd]; Windows brings up the next window.
  void minimize(int hwnd);

  /// Maximizes [hwnd], which brings it in front.
  void maximize(int hwnd);

  /// Moves or resizes [hwnd]'s frame, as [frame] gives it, first restoring it
  /// if it's maximized or minimized, without bringing it in front. What's
  /// left out stays as it is. False, and left alone, when it didn't come out of
  /// maximized or minimized, as a window that doesn't respond won't.
  Future<bool> place(int hwnd, {int? left, int? top, int? width, int? height});

  /// Asks [hwnd] to close, as its close button does (`WM_CLOSE`).
  void close(int hwnd);

  /// Replaces the clipboard with [text] ([gaiaWriteClipboard]); false when
  /// another app held the clipboard.
  Future<bool> writeClipboard(String text);
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
    this.stopFlashes,
    int? voyagerPid,
    GaiaInputBackend? backend,
    this._settle = const Duration(milliseconds: 150),
    this._leadIn = const Duration(milliseconds: 120),
    this._pace = const Duration(milliseconds: 250),
    this._modifierWait = const Duration(seconds: 3),
    this._activateWait = const Duration(seconds: 2),
    this._adoptWithin = const Duration(milliseconds: 1500),
    this._handoverWait = const Duration(seconds: 1),
    this._pauseLimit = const Duration(minutes: 5),
    this._openWait = const Duration(seconds: 10),
    this._holdLimit = const Duration(seconds: 5),
  }) : _voyagerPid = voyagerPid ?? pid,
       _backend = backend ?? _Win32InputBackend();

  final int Function() companionPid;
  final List<String> Function() exclusions;
  final bool Function() vaultUnlocked;

  /// Plays a flash on screen (GAIA_AUTONOMY_HLD.md §6), as `gaia_flash.dart`
  /// takes it. Null for none, and then no step waits for one.
  final void Function(Map<String, Object?> flash)? flash;

  /// Ends every flash playing: a drag stopped partway, whose trail would
  /// otherwise go on to an end it never reached.
  final void Function()? stopFlashes;

  /// A session started or ended, or paused or went on: what the notch says
  /// changed (GAIA_AUTONOMY_HLD.md §4).
  void Function()? onSession;
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

  /// How long a pinned window is given to hand over to another of its
  /// process's windows: a splash may show its main window before it closes,
  /// or close first and leave another app in front a moment (BUG-362).
  final Duration _handoverWait;
  final Duration _pauseLimit;

  /// How long `os_open` waits for a window (§8.1).
  final Duration _openWait;

  /// The longest a drag holds the button (§8.4).
  final Duration _holdLimit;

  final _plans = <String, _Plan>{};
  _Active? _active;
  _Session? _session;

  static const _reask = Duration(milliseconds: 250);
  static const _maxSteps = 20;
  static const _maxText = 2000;
  static const _charPause = Duration(milliseconds: 20);

  /// A drag's moves from start to end, and the pause before each and before
  /// letting go, so the app sees a drag rather than a click (§8.4).
  static const _dragMoves = 10;
  static const _dragPause = Duration(milliseconds: 30);

  /// How long a drag cut short waits, moved back to its start, before letting
  /// go: an app that hasn't yet seen the move takes the release where the drag
  /// had reached (BUG-359; 40 ms was enough for a WinForms trackbar).
  static const _releaseSettle = Duration(milliseconds: 50);

  /// One notch of the wheel: `WHEEL_DELTA`, which the win32 package has no name
  /// for.
  static const _wheelDelta = 120;
  static const _stuck =
      "That window didn't answer in time, or an earlier read of it is still "
      'going. Try again shortly.';

  /// The chat whose Auto turn holds the screen (GAIA_AUTONOMY_HLD.md §5.1).
  String? get sessionChat => _session?.chatId;

  /// Why the session was stopped, once it has been (§5.3).
  String? get sessionStopped => _session?.latch;

  /// The session waits while Gaia is in front (§5.2).
  bool get sessionPaused => _session?.pausedAt != null;

  /// The user answered Gaia mid-run (§5.2): a session waiting for its window
  /// to come back in front goes on, and its next step brings it there.
  void resume(String chatId) {
    final session = _session;
    if (session == null || session.chatId != chatId) return;
    _paused(session, null);
  }

  /// What [chatId]'s `os_*` call works on: the session's pinned window, starting
  /// the session if [auto], or null for a chat with none, which goes by what's
  /// in front as ever. Refused while another chat holds the screen, or once this
  /// turn has been stopped. [onUserStop] runs if Esc or a switch of window stops
  /// the session. Without [needsWindow], as for `os_open`, `os_focus` and
  /// `os_windows`, which find their own, a session can start with nothing to
  /// pin, and a pin that closed is null rather than refused.
  GaiaForegroundWindow? session(
    String chatId, {
    required bool auto,
    required void Function() onUserStop,
    bool needsWindow = true,
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
      final window = _backend.target(companionPid());
      if (window == null && needsWindow) {
        throw GaiaReadException(
          'There is no window to act on: nothing is open behind Gaia, or the '
          'session is locked. os_open can open one.',
        );
      }
      _backend.watchInput(true);
      final front = _backend.foreground();
      final started = session = _session = _Session(
        chatId,
        window,
        onUserStop,
        lastFront: front,
        engaged: front == window?.hwnd,
        inputMark: _backend.lastInput(),
      );
      started.watch = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => _look(started),
      );
      onSession?.call();
    }
    if (session.latch case final why?) {
      throw GaiaReadException(
        '$why Nothing more can be sent this turn. End your turn; the user can '
        'ask again.',
      );
    }
    final pin = session.pin;
    final now = pin == null ? null : _backend.describe(pin.hwnd);
    if (now == null || now.pid != pin!.pid) {
      if (!needsWindow) return null;
      throw GaiaReadException(
        pin == null
            ? 'There is no window to act on yet. os_open or os_focus one.'
            : 'The window Gaia was working in closed. os_open or os_focus '
                  'another.',
      );
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
    onSession?.call();
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
    if (front == session.pin?.hwnd) {
      session
        ..engaged = true
        ..handover = null;
      _paused(session, null);
      return;
    }
    final window = _backend.describe(front);
    if (window?.pid == companionPid()) {
      // The turn's first action brings the target up from behind Gaia; after
      // that, Gaia in front is the user looking at it.
      if (session.engaged) _paused(session, session.pausedAt ?? now);
      return;
    }
    _paused(session, null);
    final lastStep = session.lastStep;
    final lastUser = session.lastUserInput;
    // Later, the pinned window's own process taking over from it once it
    // closed, with no input from the user since Gaia's last step began, is
    // still Gaia's doing: a splash handing over to its main window (BUG-362).
    // Not a further window while the pin stays open, as Outlook's reminder
    // beside its main window would be.
    final pin = session.pin;
    final stepStarted = session.stepStarted;
    final untouched =
        stepStarted != null &&
        (lastUser == null || lastUser.isBefore(stepStarted));
    final pinsApp = window != null && pin != null && window.pid == pin.pid;
    final pinClosed = pin != null && _backend.describe(pin.hwnd) == null;
    final caused =
        lastStep != null &&
        (now.difference(lastStep) <= _adoptWithin ||
            (untouched && pinsApp && pinClosed)) &&
        (lastUser == null || now.difference(lastUser) > _adoptWithin);
    if (!caused) {
      // A splash may show its main window a moment before it closes, or close
      // first, and Windows puts another window in front until the main one
      // shows: look again, for a while, for the hand-over to finish before
      // calling it the user's.
      final handingOver = pinsApp ? !pinClosed : pinClosed;
      if (untouched && lastStep != null && pin != null && handingOver) {
        final handover = session.handover;
        final since = handover?.hwnd == pin.hwnd ? handover!.since : now;
        if (now.difference(since) <= _handoverWait) {
          session
            ..handover = (hwnd: pin.hwnd, since: since)
            ..lastFront = 0;
          return;
        }
      }
      session.handover = null;
      return _userStop(session, 'The user switched to another window.');
    }
    session.handover = null;
    // The taskbar and the desktop aren't windows to act in; the next step
    // brings the pin back. Start and Search are, after the Windows key (§5.5).
    if (window == null ||
        _taskbarOrDesktop.contains(_backend.windowClass(front))) {
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

  void _paused(_Session session, DateTime? at) {
    final changed = (session.pausedAt == null) != (at == null);
    session.pausedAt = at;
    if (changed) onSession?.call();
  }

  static const _taskbarOrDesktop = {
    'Shell_TrayWnd',
    'Shell_SecondaryTrayWnd',
    'Progman',
    'WorkerW',
  };

  /// The border's windows (gaia_control_border.cpp). The notch's Revoke button
  /// takes clicks, so it, not what's under it, is the window at its point.
  static const _borderClass = 'VoyagerGaiaControlBorder';

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
    final session = _session?.chatId == chatId ? _session : null;
    if (gaiaWindowlessControls.contains(tool)) {
      final step = switch (tool) {
        'os_open' => await _openStep(arguments),
        'os_focus' => await _focusStep(arguments),
        'os_window' => await _windowStep(arguments),
        _ => _clipboardStep(arguments),
      };
      final plan = _Plan(chatId, step.window, [step], session, null);
      _plans[cardId] = plan;
      return {...plan.toCard(), if (session != null) 'auto': true};
    }
    final steps = _parse(tool, arguments, auto: session != null);
    final window =
        (session != null ? session.pin : _backend.target(companionPid())) ??
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
    String? dragNote;
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
      dragNote = await _releaseHeld(active);
      _active = null;
    }
    if (stopped != null && dragNote != null) stopped = '$stopped $dragNote';
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
      'front': ?active.front,
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

  /// An `os_open` call (§8.1): a URL, a full path, or an installed app by its
  /// Start menu name. What it names is checked against the exclusions here,
  /// before anything launches, and again when it runs.
  Future<_Step> _openStep(Map<String, Object?> arguments) async {
    final target = switch (arguments['target']) {
      final String target when target.trim().isNotEmpty => target.trim(),
      _ => throw GaiaReadException(
        'os_open needs a target: an app, a full path or a URL.',
      ),
    };
    final _Step step;
    if (_isUrl(target)) {
      step = _Step.window(
        _Action.open,
        target,
        file: target,
        url: target,
        opener: _openerOf(target),
      );
    } else if (p.windows.isAbsolute(target)) {
      if (FileSystemEntity.typeSync(target) == FileSystemEntityType.notFound) {
        throw GaiaReadException('There is no file or folder at $target.');
      }
      // A shortcut is checked by what it opens, not by its own name.
      final extension = p.windows.extension(target).toLowerCase();
      final where = extension == '.lnk'
          ? _backend.shortcutTarget(target) ?? target
          : target;
      step = _Step.window(
        _Action.open,
        p.windows.basename(target),
        file: target,
        url: _isUrl(where) ? where : null,
        exe: extension == '.exe' || extension == '.lnk'
            ? p.windows.basenameWithoutExtension(
                where.toLowerCase().endsWith('.exe') ? where : target,
              )
            : null,
        opener: _openerOf(where),
      );
    } else {
      final apps = await _backend.startApps();
      final lower = target.toLowerCase();
      var found = [
        for (final app in apps)
          if (app.name.toLowerCase() == lower) app,
      ];
      if (found.isEmpty) {
        found = [
          for (final app in apps)
            if (app.name.toLowerCase().contains(lower)) app,
        ];
      }
      if (found.isEmpty) {
        throw GaiaReadException(
          'No installed app is named ${jsonEncode(target)}. os_open takes an '
          "app's name as the Start menu shows it, a full path, or a URL with "
          'its scheme.',
        );
      }
      if (found.length > 1) {
        throw GaiaReadException(
          '${found.length} apps match ${jsonEncode(target)}: '
          '${found.take(10).map((app) => jsonEncode(app.name)).join(', ')}'
          '${found.length > 10 ? ', …' : ''}. Pass the one you mean.',
        );
      }
      final app = found.single;
      // A shortcut's target, as an AutoGenerated id has; else the id itself
      // is often the exe's path.
      final where = _backend.startAppTarget(app.id) ?? app.id;
      final opener = _openerOf(where);
      step = _Step.window(
        _Action.open,
        app.name,
        file: 'shell:AppsFolder\\${app.id}',
        url: _isUrl(where) ? where : null,
        exe: app.id.toLowerCase().endsWith('.exe')
            ? p.windows.basenameWithoutExtension(app.id)
            : app.id,
        // Its windows, or its package's, carry the id.
        opener: (exes: opener.exes, appIds: {...opener.appIds, app.id}),
      );
    }
    _checkOpen(step);
    return step;
  }

  /// A scheme of one letter is a drive.
  static bool _isUrl(String target) =>
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]+:').hasMatch(target);

  /// What opens [where], a URL, a path or a shell location, by the exes and
  /// app IDs its windows can be told by (§8.1).
  ({Set<String> exes, Set<String> appIds}) _openerOf(String where) {
    final lower = where.toLowerCase();
    if (lower.startsWith('::{') ||
        lower.startsWith('shell:') ||
        FileSystemEntity.isDirectorySync(where)) {
      return (exes: {'explorer'}, appIds: const {});
    }
    if (lower.endsWith('.exe')) {
      return (
        exes: {p.windows.basenameWithoutExtension(lower)},
        appIds: const <String>{},
      );
    }
    final url = _isUrl(where);
    final assoc = url
        ? where.substring(0, where.indexOf(':'))
        : p.windows.extension(where);
    if (assoc.isEmpty) return (exes: const {}, appIds: const {});
    final handler = _backend.handler(assoc, protocol: url);
    return (exes: {?handler.exe?.toLowerCase()}, appIds: {?handler.appId});
  }

  void _checkOpen(_Step step) {
    // What would open it, too: a URL whose browser is excluded opens there.
    for (final exe in {step.exe ?? '', ...step.opener.exes}) {
      if (gaiaContextExcluded(
        exclusions(),
        exe: exe,
        app: step.target!,
        url: step.url,
      )) {
        throw GaiaReadException(
          "The user has excluded that app or site, so Gaia can't open it.",
        );
      }
    }
  }

  /// An `os_focus` call (§8.2): the window [_windowOf] finds.
  Future<_Step> _focusStep(Map<String, Object?> arguments) async {
    final window = await _windowOf('os_focus', arguments['window']);
    return _Step.window(
      _Action.focus,
      '${window.app}: ${jsonEncode(window.title)}',
      window: window,
    );
  }

  /// An `os_window` call (§8.3): minimize, maximize, restore, move or close a
  /// window found as `os_focus` finds it. Voyager's own can't be closed, as
  /// it runs the tools themselves.
  Future<_Step> _windowStep(Map<String, Object?> arguments) async {
    final how = arguments['action'];
    if (how is! String ||
        !const {
          'minimize',
          'maximize',
          'restore',
          'move',
          'close',
        }.contains(how)) {
      throw GaiaReadException(
        'os_window needs an action: minimize, maximize, restore, move or '
        'close.',
      );
    }
    int? number(String key) => (arguments[key] as num?)?.toInt();
    final place = (
      left: number('left'),
      top: number('top'),
      width: number('width'),
      height: number('height'),
    );
    if (how == 'move') {
      if ((place.left == null) != (place.top == null) ||
          (place.width == null) != (place.height == null)) {
        throw GaiaReadException(
          'Pass left and top together, and width and '
          'height together.',
        );
      }
      if (place.left == null && place.width == null) {
        throw GaiaReadException(
          'move needs left and top, width and height, or all four.',
        );
      }
      if ((place.width ?? 1) < 1 || (place.height ?? 1) < 1) {
        throw GaiaReadException('width and height must be above 0.');
      }
    }
    final window = await _windowOf('os_window', arguments['window']);
    if (how == 'close' && window.pid == _voyagerPid) {
      throw GaiaReadException(
        "Voyager's window can't be closed this way: Gaia's tools run in it.",
      );
    }
    return _Step.window(
      _Action.window,
      '${window.app}: ${jsonEncode(window.title)}',
      window: window,
      how: how,
      place: how == 'move' ? place : null,
    );
  }

  /// An `os_clipboard` write (§8.5). A read is answered as the screen's reads
  /// are, by `GaiaOsReads`.
  _Step _clipboardStep(Map<String, Object?> arguments) {
    if (arguments['action'] != 'write') {
      throw GaiaReadException('os_clipboard writes here; action is "write".');
    }
    final text = arguments['text'];
    if (text is! String) {
      throw GaiaReadException('os_clipboard write needs text.');
    }
    if (text.length > gaiaClipboardLimit) {
      throw GaiaReadException(
        'os_clipboard writes at most $gaiaClipboardLimit characters.',
      );
    }
    return _Step.window(_Action.clipboard, 'the clipboard', text: text);
  }

  /// The window [argument] names for [tool]: an id from `os_windows`, else an
  /// exact title, else the one whose title has those words or whose app is
  /// them. An excluded window, or Voyager's while its vault is unlocked, is
  /// matched by its id alone, and then refused. So is a browser on an
  /// excluded site, or one whose address can't be read while a site is
  /// excluded.
  Future<GaiaForegroundWindow> _windowOf(String tool, Object? argument) async {
    final asked = switch (argument) {
      final num id => '${id.toInt()}',
      final String text => text.trim(),
      _ => '',
    };
    if (asked.isEmpty) {
      throw GaiaReadException(
        "$tool needs a window: an id from os_windows, or words from its "
        'title.',
      );
    }
    final listed = [
      for (final listed in _backend.listWindows())
        if (listed.window.pid != companionPid()) listed.window,
    ];
    final id = int.tryParse(asked);
    var found = [
      for (final window in listed)
        if (window.hwnd == id) window,
    ];
    if (found.isEmpty) {
      final readable = [
        for (final window in listed)
          if (!_hidden(window) && !await _siteHidden(window)) window,
      ];
      final lower = asked.toLowerCase();
      found = [
        for (final window in readable)
          if (window.title.toLowerCase() == lower) window,
      ];
      if (found.isEmpty) {
        found = [
          for (final window in readable)
            if (window.title.toLowerCase().contains(lower) ||
                window.app.toLowerCase() == lower)
              window,
        ];
      }
    }
    if (found.isEmpty) {
      throw GaiaReadException(
        'No open window matches ${jsonEncode(asked)}. os_windows lists them.',
      );
    }
    if (found.length > 1) {
      throw GaiaReadException(
        '${found.length} windows match ${jsonEncode(asked)}: '
        '${found.map((w) => '${w.hwnd}: ${w.app} ${jsonEncode(w.title)}').join('; ')}. '
        'Pass the id of the one you mean.',
      );
    }
    final window = found.single;
    if (window.exe.isEmpty) {
      throw GaiaReadException("Gaia can't tell what app that window is.");
    }
    _checkWindow(window);
    await _checkSite(window);
    return window;
  }

  /// A window whose title `os_windows` doesn't show.
  bool _hidden(GaiaForegroundWindow window) =>
      window.exe.isEmpty ||
      gaiaContextExcluded(exclusions(), exe: window.exe, app: window.app) ||
      (window.pid == _voyagerPid && vaultUnlocked());

  /// A browser window whose title `os_windows` doesn't show either.
  Future<bool> _siteHidden(GaiaForegroundWindow window) async {
    if (!gaiaIsBrowser(window.exe) ||
        !exclusions().any((e) => e.contains('.'))) {
      return false;
    }
    try {
      await _checkSite(window);
      return false;
    } on GaiaReadException {
      return true;
    }
  }

  Future<void> _resolveAll(_Plan plan, {required int from}) async {
    for (final step in plan.steps.skip(from)) {
      // A drag has two ends to find.
      for (final end in [step, ?step.to]) {
        if (!end.aimed) continue;
        if (end.name == null) {
          if (!end.anywhere) _checkPoint(plan.window!, end.x!, end.y!);
          // Afresh each pass: a drag's own may have been cleared by its end.
          end.resolved = true;
          continue;
        }
        final match = _matchOf(end, await _matches(plan.window!, end));
        end.resolved = match != null;
        end.match = match;
        if (end.action == _Action.type && (match?.sensitive ?? false)) {
          throw GaiaReadException(
            'That is a password, card or one-time code field, which Gaia '
            'never types into.',
          );
        }
      }
      if (step.to case final to?) step.resolved &= to.resolved;
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
    if (step.action == _Action.open || step.action == _Action.focus) {
      return _bringUp(step, session, active);
    }
    if (step.action == _Action.window) return _arrange(step, session, active);
    if (step.action == _Action.clipboard) {
      await _waitWhilePaused(session, active);
      if (!await _backend.writeClipboard(step.text!)) {
        throw _Stopped(
          "Gaia couldn't set the clipboard, and left it as it was: another "
          'app may be using it. Try again shortly.',
        );
      }
      return;
    }
    final GaiaForegroundWindow window;
    if (session != null) {
      window = await _sessionTarget(session, active);
    } else {
      window = plan.window!;
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
    final point = step.anywhere
        ? await _anywhereAt(window, step)
        : step.aimed || step.action == _Action.scroll
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
      case _Action.drag:
        final to = step.to!;
        final GaiaControlMatch? toMatch;
        if (to.name == null) {
          toMatch = null;
        } else {
          toMatch = _matchOf(to, await _matches(window, to));
          if (toMatch == null) {
            throw _Stopped(
              'The control ${jsonEncode(to.name)} is not on screen.',
            );
          }
        }
        active.throwIfStopped();
        await _drag(
          window,
          point!,
          _pointOf(window, to, toMatch),
          match == null ? null : step.name,
          active,
        );
      // Done above.
      case _Action.open || _Action.focus || _Action.window:
      case _Action.clipboard:
        break;
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

  /// An `os_open` or `os_focus` step (§8.1, §8.2): finds its window, brings it
  /// up from wherever it is, and in a session pins it. The window it ends on
  /// goes in [_Active.front] for the agent.
  Future<void> _bringUp(_Step step, _Session? session, _Active active) async {
    await _waitWhilePaused(session, active);
    final GaiaForegroundWindow window;
    if (step.action == _Action.open) {
      window = await _launch(step, session, active);
    } else {
      final asked = step.window!;
      final now = _backend.describe(asked.hwnd);
      if (now == null || now.pid != asked.pid) {
        throw _Stopped('The window closed.');
      }
      window = now;
    }
    try {
      if (window.exe.isEmpty) {
        throw GaiaReadException("Gaia can't tell what app that window is.");
      }
      _checkWindow(window);
      // Its title goes back as front: not for an excluded site. What os_open
      // opened was checked by its URL, and a new tab may have no address yet.
      if (step.action == _Action.focus) await _checkSite(window);
    } on GaiaReadException catch (error) {
      throw _Stopped(error.message);
    }
    // A window that came up on its own may already be adopted, and flashed.
    final adopted = session?.adopted != null && session?.pin == window;
    if (_backend.minimized(window.hwnd)) {
      // Restoring may bring it in front, which is Gaia's doing (§5.2): pinned
      // first, as a Store app can take longer than [_adoptWithin] to come
      // up (BUG-351).
      session?.lastStep = DateTime.now();
      final pinned = session?.pin;
      session?.pin = window;
      _backend.restore(window.hwnd);
      final until = DateTime.now().add(_activateWait);
      while (_backend.minimized(window.hwnd)) {
        if (DateTime.now().isAfter(until)) {
          // Never came up: not the pin.
          session?.pin = pinned;
          throw _Stopped("${window.app} wouldn't restore from minimized.");
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        active.throwIfStopped();
      }
    }
    if (session != null) {
      session
        ..pin = window
        ..adopted = null;
    }
    await _bringInFront(window, active, unprompted: true, fromAnywhere: true);
    if (!adopted) {
      flash?.call({
        'kind': 'window',
        ..._rectOf(_backend.frame(window.hwnd)),
        'label': window.app,
      });
    }
    active.front = '${window.app}: ${jsonEncode(window.title)}';
  }

  /// Gaia in front is the user looking: wait, as any step does (§5.2).
  Future<void> _waitWhilePaused(_Session? session, _Active active) async {
    if (session == null) return;
    _look(session);
    active.throwIfStopped();
    while (session.pausedAt != null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active.throwIfStopped();
    }
  }

  /// An `os_window` step (§8.3), flashed at where the window was. Nothing is
  /// typed or clicked, so it needn't be in front. In a session, what comes in
  /// front after is Gaia's doing (§5.2): a "save changes?" prompt after a
  /// close, or the next window after a minimize. Restoring or maximizing
  /// brings the window up, so it's pinned first, as [_bringUp] does; the pin
  /// minimized or closed leaves none, so Gaia in front isn't a pause.
  Future<void> _arrange(_Step step, _Session? session, _Active active) async {
    await _waitWhilePaused(session, active);
    final asked = step.window!;
    final window = _backend.describe(asked.hwnd);
    if (window == null || window.pid != asked.pid) {
      throw _Stopped('The window closed.');
    }
    try {
      _checkWindow(window);
      await _checkSite(window);
    } on GaiaReadException catch (error) {
      throw _Stopped(error.message);
    }
    final before = _backend.frame(window.hwnd);
    if (!_backend.minimized(window.hwnd)) {
      flash?.call({'kind': 'window', ..._rectOf(before), 'label': window.app});
      await Future<void>.delayed(_leadIn);
      active.throwIfStopped();
    }
    final how = step.how!;
    if (session != null) {
      if (how == 'restore' || how == 'maximize') {
        session
          ..pin = window
          ..adopted = null
          ..engaged = true;
        active.front = '${window.app}: ${jsonEncode(window.title)}';
      } else if ((how == 'minimize' || how == 'close') &&
          session.pin?.hwnd == window.hwnd) {
        session
          ..pin = null
          ..engaged = false;
      }
      session.lastStep = DateTime.now();
    }
    switch (how) {
      case 'minimize':
        _backend.minimize(window.hwnd);
      case 'maximize':
        _backend.maximize(window.hwnd);
      case 'restore':
        _backend.restore(window.hwnd);
      case 'close':
        _backend.close(window.hwnd);
      case 'move':
        final place = step.place!;
        final placed = await _backend.place(
          window.hwnd,
          left: place.left,
          top: place.top,
          width: place.width,
          height: place.height,
        );
        if (!placed) {
          throw _Stopped(
            "${window.app} didn't come out of maximized or minimized, so Gaia "
            "couldn't move it. It may not be responding.",
          );
        }
    }
    session?.lastStep = DateTime.now();
  }

  /// A drag (§8.4): the button down at [from], moved to [to] in steps, and let
  /// go there if the target is still what's under it. The button is never
  /// held more than [_holdLimit], and a stop lets go where the drag started
  /// ([_releaseHeld]). Its flash, ahead of the press as a click's is, travels
  /// as long as the moves do; [fromName] labels it.
  Future<void> _drag(
    GaiaForegroundWindow window,
    ({int x, int y}) from,
    ({int x, int y}) to,
    String? fromName,
    _Active active,
  ) async {
    if (flash case final play?) {
      play({
        'kind': 'drag',
        'x': from.x,
        'y': from.y,
        'to_x': to.x,
        'to_y': to.y,
        'ms': (_dragPause * (_dragMoves + 1)).inMilliseconds,
        'label': ?fromName,
      });
    }
    try {
      if (flash != null) {
        await Future<void>.delayed(_leadIn);
        active.throwIfStopped();
      }
      _inFront(window);
    } catch (_) {
      // Stopped before the press: no drag to show.
      stopFlashes?.call();
      rethrow;
    }
    // A swapped mouse's left button is sent as its right.
    final (down, up) = _backend.buttonsSwapped
        ? (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP)
        : (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
    _backend.moveCursor(from.x, from.y);
    // Set first, so that a stop even mid-send lets go.
    active.drag = (window: window.hwnd, from: from, up: up, at: from);
    active.dragLostFront = false;
    _send([GaiaMouseEvent(down)], active);
    final until = DateTime.now().add(_holdLimit);
    void next() {
      if (_backend.foreground() != window.hwnd) active.dragLostFront = true;
      if (DateTime.now().isAfter(until)) {
        throw _Stopped('The drag held the button too long.');
      }
      active.throwIfStopped();
      _inFront(window);
    }

    for (var i = 1; i <= _dragMoves; i++) {
      await Future<void>.delayed(_dragPause);
      next();
      final at = (
        x: from.x + (to.x - from.x) * i ~/ _dragMoves,
        y: from.y + (to.y - from.y) * i ~/ _dragMoves,
      );
      _backend.moveCursor(at.x, at.y);
      active.drag = (window: window.hwnd, from: from, up: up, at: at);
      // An app sees the move as input, as a real mouse's.
      _send(const [GaiaMouseEvent(MOUSEEVENTF_MOVE)], active);
    }
    await Future<void>.delayed(_dragPause);
    next();
    if (_backend.rootAt(to.x, to.y) != window.hwnd) {
      throw _Stopped('Another window is covering ${to.x},${to.y}.');
    }
    _send([GaiaMouseEvent(up)], active);
    active.drag = null;
  }

  /// Opens [step]'s target and finds the window it opened. Only a window shown
  /// to be its own counts: from the process launched or one it started, from
  /// the exe that opens it, or carrying its app ID. Any other, opening by
  /// chance meanwhile, is passed over. A new one wins, the launched process's
  /// first; else, for a file, one whose title changed to name it; else one
  /// that came in front; else, once the launched process
  /// exits (a single-instance app handing over) or the wait is up, one it
  /// already had.
  Future<GaiaForegroundWindow> _launch(
    _Step step,
    _Session? session,
    _Active active,
  ) async {
    try {
      // The exclusions may have changed since the card.
      _checkOpen(step);
    } on GaiaReadException catch (error) {
      throw _Stopped(error.message);
    }
    List<GaiaListedWindow> listed() => [
      for (final listed in _backend.listWindows())
        if (listed.window.pid != companionPid()) listed,
    ];
    final before = {for (final l in listed()) l.window.hwnd: l.window.title};
    // A file may open as a tab in a window its app already had, which then
    // names it (BUG-353).
    final file = step.file!;
    // As a whole word: `a.txt` isn't named by "data.txt - Notepad".
    final fileName =
        p.windows.isAbsolute(file) && !file.toLowerCase().endsWith('.exe')
        ? RegExp(
            '(^|[^\\p{L}\\p{N}])'
            '${RegExp.escape(p.windows.basenameWithoutExtension(file))}'
            '(\$|[^\\p{L}\\p{N}])',
            caseSensitive: false,
            unicode: true,
          )
        : null;
    final front = _backend.foreground();
    // What it opens, coming up in front, is Gaia's doing (§5.2).
    session?.lastStep = DateTime.now();
    final ({int pid, String? exe}) launched;
    try {
      launched = await _backend.launch(step.file!);
    } on GaiaReadException catch (error) {
      throw _Stopped(error.message);
    }
    final exes = {...step.opener.exes, ?launched.exe?.toLowerCase()};
    final appIds = {for (final id in step.opener.appIds) id.toLowerCase()};
    final until = DateTime.now().add(_openWait);
    while (true) {
      active.throwIfStopped();
      session?.lastStep = DateTime.now();
      final family = _family(launched.pid);
      bool ours(GaiaForegroundWindow window) =>
          family.contains(window.pid) ||
          exes.contains(window.exe.toLowerCase()) ||
          _backend.appIdsOf(window).any(appIds.contains);
      final now = listed();
      final fresh = [
        for (final l in now)
          if (!before.containsKey(l.window.hwnd) &&
              !l.minimized &&
              ours(l.window))
            l.window,
      ];
      if (fresh.isNotEmpty) {
        return fresh.firstWhere(
          (window) => window.pid == launched.pid,
          orElse: () => fresh.first,
        );
      }
      if (fileName != null) {
        for (final l in now) {
          final was = before[l.window.hwnd];
          if (was != null &&
              l.window.title != was &&
              fileName.hasMatch(l.window.title) &&
              ours(l.window)) {
            return l.window;
          }
        }
      }
      final inFront = _backend.foreground();
      if (inFront != front) {
        for (final l in now) {
          if (l.window.hwnd == inFront && ours(l.window)) return l.window;
        }
      }
      final timedOut = DateTime.now().isAfter(until);
      if (timedOut || (launched.pid != 0 && !_backend.running(launched.pid))) {
        for (final l in now) {
          if (ours(l.window)) return l.window;
        }
      }
      if (timedOut) {
        throw _Stopped(
          "Gaia couldn't tell which window ${step.target} opened, if any. "
          'os_windows lists what is open, and os_focus brings one up.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Process [pid] and every process started under it; none for 0.
  Set<int> _family(int pid) {
    if (pid == 0) return const {};
    final children = <int, List<int>>{};
    for (final MapEntry(key: child, value: parent)
        in _backend.processParents().entries) {
      if (child != parent) (children[parent] ??= []).add(child);
    }
    final family = {pid};
    final queue = [pid];
    while (queue.isNotEmpty) {
      for (final child in children[queue.removeLast()] ?? const <int>[]) {
        if (family.add(child)) queue.add(child);
      }
    }
    return family;
  }

  /// [_inFront], first bringing the target up from behind Gaia or the shell,
  /// or with [fromAnywhere], from behind any window. Windows switches to
  /// another process's window a moment after agreeing to, so the foreground is
  /// watched until it has. With [unprompted], no click handed Gaia the right
  /// to, and Windows refuses a process that hasn't had the last input: tapping
  /// an unbound key makes this that process (§5.4).
  Future<void> _bringInFront(
    GaiaForegroundWindow window,
    _Active active, {
    bool unprompted = false,
    bool fromAnywhere = false,
  }) async {
    final front = _backend.foreground();
    if (front == window.hwnd) return;
    if (!fromAnywhere && !_backend.inFrontOfTarget(front, companionPid())) {
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
      if (!fromAnywhere &&
          now != 0 &&
          !_backend.inFrontOfTarget(now, companionPid())) {
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
      final pin = session.pin;
      if (pin == null || _backend.describe(pin.hwnd) == null) {
        throw _Stopped('The window closed.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active.throwIfStopped();
    }
    final window =
        session.pin ??
        (throw _Stopped(
          'There is no window to act on yet. os_open or os_focus one.',
        ));
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

  /// An `anywhere` click's point (§5.5): another window, the taskbar or the
  /// tray, what's there checked as a target would be. Gaia's own windows and
  /// the notch are never clicked.
  Future<({int x, int y})> _anywhereAt(
    GaiaForegroundWindow window,
    _Step step,
  ) async {
    final (x, y) = (step.x!, step.y!);
    final root = _backend.rootAt(x, y);
    final under = root == 0 ? null : _backend.describe(root);
    if (under == null) throw _Stopped('Nothing is at $x,$y.');
    if (under.pid == companionPid() ||
        _backend.windowClass(root) == _borderClass) {
      throw _Stopped("$x,$y is on Gaia's own window, which Gaia never clicks.");
    }
    if (root != window.hwnd) {
      if (under.exe.isEmpty) {
        throw _Stopped("Gaia can't tell what app is at $x,$y.");
      }
      try {
        _checkWindow(under);
        // Another browser window may be on an excluded site.
        await _checkSite(under);
      } on GaiaReadException catch (error) {
        throw _Stopped(error.message);
      }
    }
    return (x: x, y: y);
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

  /// A character at a time, looking up between them so that Abort, Esc or a
  /// change of window lands mid-text. Tab and Enter can move the focus, so
  /// what has it is checked again before the text goes on (§15.6).
  Future<void> _type(
    GaiaForegroundWindow window,
    String text,
    _Active active,
  ) async {
    final taps = gaiaTextTaps(text);
    for (final (i, tap) in taps.indexed) {
      await _waitForModifiers(active);
      active.throwIfStopped();
      _inFront(window);
      _send(tap, active);
      if (tap.first is GaiaKeyEvent && i < taps.length - 1) {
        await Future<void>.delayed(_settle);
        await _checkFocus(window);
      } else {
        // Each its own send, this far apart: Windows 11 Notepad takes a
        // packet's character as it reads it, so packets it hadn't yet read
        // came out as a later one, and closer than about 16 ms a character
        // was dropped (BUG-352). Also far enough apart that the user's input
        // between them shows in [GaiaInputBackend.lastInput].
        await Future<void>.delayed(_charPause);
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
    return _charPause * text.length + _settle * (breaks + (step.aimed ? 1 : 0));
  }

  /// Nothing Gaia pressed stays down (§15.7). A drag cut short lets go where
  /// it started, which most apps take as no drag (§8.4), unless the user has
  /// moved the mouse: then it lets go where they have it, and leaves the
  /// cursor in their hand.
  /// Returns what the agent should know of a drag cut short, if there was one.
  Future<String?> _releaseHeld(_Active active) async {
    final drag = active.drag;
    if (active.held.isEmpty && drag == null) return null;
    final session = _session;
    if (session != null) _noteUserInput(session, DateTime.now());
    var movedBack = false;
    var userHasMouse = false;
    // A window that loses the front ends its own drag where it had reached,
    // before anything Gaia sends after (BUG-361).
    final lostFront =
        drag != null &&
        (active.dragLostFront || _backend.foreground() != drag.window);
    if (drag != null) {
      stopFlashes?.call();
      userHasMouse = _backend.cursorAt() != drag.at;
      // Not once the window lost the front: the move back, button down, and
      // the release would go to whatever is in front now.
      if (!userHasMouse && !lostFront) {
        _backend.moveCursor(drag.from.x, drag.from.y);
        // The app sees the move back as input, then has time to handle it
        // before the button comes up there (BUG-359).
        _backend.send(const [GaiaMouseEvent(MOUSEEVENTF_MOVE)]);
        if (session != null) session.inputMark = _backend.lastInput();
        await Future<void>.delayed(_releaseSettle);
        // The user may have taken the mouse meanwhile: that's theirs, and the
        // button comes up where they have it.
        if (session != null) _noteUserInput(session, DateTime.now());
        movedBack = _backend.cursorAt() == drag.from;
        userHasMouse = !movedBack;
      }
    }
    _backend.send([
      if (drag != null) GaiaMouseEvent(drag.up),
      for (final vk in active.held.toList().reversed)
        GaiaKeyEvent(vk, up: true),
    ]);
    // Gaia's own release isn't the user's input.
    if (session != null) session.inputMark = _backend.lastInput();
    active.held.clear();
    active.drag = null;
    if (drag == null) return null;
    // The cursor being the user's matters most to the agent.
    if (userHasMouse) {
      return 'The drag had begun, and Gaia let go where the user has the '
          'mouse, so part of it may have taken effect.';
    }
    if (lostFront) {
      return 'The drag had begun, and its window lost the front, which ends '
          'a drag where it had reached in most apps, so part of it may have '
          'taken effect.';
    }
    return 'The drag had begun, so Gaia moved back and let go where it '
        'started, which most apps take as no drag.';
  }

  List<_Step> _parse(
    String tool,
    Map<String, Object?> arguments, {
    required bool auto,
  }) {
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
            _parseStep(step['action'], step.cast<String, Object?>(), auto: auto)
          else
            throw GaiaReadException('Each step needs an action.'),
      ];
    }
    return [_parseStep(tool.replaceFirst('os_', ''), arguments, auto: auto)];
  }

  _Step _parseStep(
    Object? action,
    Map<String, Object?> args, {
    required bool auto,
  }) {
    final parsed = switch (action) {
      'click' => _Action.click,
      'scroll' => _Action.scroll,
      'type' => _Action.type,
      'key' => _Action.key,
      'drag' => _Action.drag,
      _ => throw GaiaReadException('Unknown action: $action'),
    };
    if (parsed == _Action.drag) {
      if (args['anywhere'] == true) {
        throw GaiaReadException('anywhere is for a click at x and y alone.');
      }
      final from = _dragEnd(args['from'], 'from');
      return from..to = _dragEnd(args['to'], 'to');
    }
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
        _Action.key => GaiaKeyChord.parse(args['keys'], windows: auto),
        _ => null,
      },
      anywhere: args['anywhere'] == true,
    );
    if (step.anywhere) {
      if (!auto) {
        throw GaiaReadException(
          'anywhere is only for a chat in Auto. Click inside the window.',
        );
      }
      if (parsed != _Action.click || step.name != null || step.x == null) {
        throw GaiaReadException('anywhere is for a click at x and y alone.');
      }
    }
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
      case _Action.key ||
          _Action.open ||
          _Action.focus ||
          _Action.window ||
          _Action.drag ||
          _Action.clipboard:
        break;
    }
    return step;
  }

  /// One end of a drag (§8.4): a control's name, or x and y.
  _Step _dragEnd(Object? end, String which) {
    if (end is! Map) {
      throw GaiaReadException(
        'A drag needs $which: a control\'s name, or x and y.',
      );
    }
    final name = switch (end['name']) {
      final String name when name.trim().isNotEmpty => name.trim(),
      _ => null,
    };
    final x = (end['x'] as num?)?.toInt();
    final y = (end['y'] as num?)?.toInt();
    if ((x == null) != (y == null)) {
      throw GaiaReadException('Pass x and y together.');
    }
    if (name == null && x == null) {
      throw GaiaReadException(
        'A drag needs $which: a control\'s name, or x and y.',
      );
    }
    return _Step(
      action: _Action.drag,
      name: name,
      type: end['type'] as String?,
      x: x,
      y: y,
      button: 'left',
      doubleClick: false,
      direction: null,
      amount: 0,
      text: null,
      keys: null,
    );
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

  /// The window this turn acts on and reads (§5.2); none until `os_open` or
  /// `os_focus` finds one, if nothing was open.
  GaiaForegroundWindow? pin;

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

  /// The pin whose hand-over to another window of its process Gaia is waiting
  /// on, and since when (BUG-362).
  ({int hwnd, DateTime since})? handover;

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

  /// The window `os_open` or `os_focus` brought up, for the agent.
  String? front;

  /// A drag holding the button: its window, where it started, the button's
  /// release, and where Gaia last put the cursor.
  ({int window, ({int x, int y}) from, int up, ({int x, int y}) at})? drag;

  /// The drag's window was seen out of the front mid-drag, which ends the
  /// app's drag where it had reached, even if the window came back (BUG-361).
  bool dragLostFront = false;

  void stop(String why) => _stopped ??= why;

  void throwIfStopped() {
    if (_stopped case final why?) throw _Stopped(why);
  }
}

enum _Action { click, scroll, type, key, open, focus, window, drag, clipboard }

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
    this.anywhere = false,
  }) : resolved = name == null,
       target = null,
       file = null,
       exe = null,
       url = null,
       window = null,
       how = null,
       place = null,
       opener = (exes: const {}, appIds: const {});

  /// An `os_open` of [target], shown by that name; an `os_focus` or
  /// `os_window` of [window], shown as [target]; or an `os_clipboard` write of
  /// [text].
  _Step.window(
    this.action,
    String this.target, {
    this.file,
    this.exe,
    this.url,
    this.window,
    this.how,
    this.place,
    this.text,
    this.opener = (exes: const {}, appIds: const {}),
  }) : name = null,
       type = null,
       x = null,
       y = null,
       button = 'left',
       doubleClick = false,
       direction = null,
       amount = 0,
       keys = null,
       anywhere = false,
       resolved = true;

  final _Action action;
  final String? target;

  /// What `os_window` does, and for a move, where to.
  final String? how;
  final ({int? left, int? top, int? width, int? height})? place;

  /// A drag's other end (§8.4); this step is where it starts.
  _Step? to;

  /// What `os_open` hands Windows, and the exe and URL it's checked by.
  final String? file;
  final String? exe;
  final String? url;
  final GaiaForegroundWindow? window;

  /// What `os_open`'s window can be told by: exes, lowercase, and app IDs.
  final ({Set<String> exes, Set<String> appIds}) opener;
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

  /// A click at a point outside the target (§5.5).
  final bool anywhere;

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
      // A card marks where it starts. Run, its trail plays from `_drag`, once
      // its end is found (§6.2).
      _Action.drag when preview => {
        'kind': 'mark',
        ...at,
        ...?rect,
        'label': ?label,
      },
      _Action.drag => null,
      // Its window's outline plays once it's up, or where it was.
      _Action.open || _Action.focus || _Action.window => null,
      _Action.clipboard => null,
    };
  }

  /// A drag's end as its label says it.
  String get _end => name == null ? '$x, $y' : _target;

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
    _Action.open => 'Open $target',
    _Action.focus => 'Bring $target to the front',
    _Action.drag => 'Drag from $_end to ${to!._end}',
    _Action.window => switch (how) {
      'minimize' => 'Minimize $target',
      'maximize' => 'Maximize $target',
      'restore' => 'Restore $target',
      'close' => 'Close $target',
      _ => [
        place!.left == null ? 'Resize $target to' : 'Move $target to',
        [
          if (place!.left != null) '${place!.left},${place!.top}',
          if (place!.width != null) '${place!.width}x${place!.height}',
        ].join(', '),
      ].join(' '),
    },
    // The card is synced: a long text is shown cut short.
    _Action.clipboard =>
      'Put ${jsonEncode(text!.length > 200 ? '${gaiaCut(text!, 200)}…' : text)} '
          'on the clipboard',
  };
}

class _Plan {
  _Plan(this.chatId, this.window, this.steps, this.session, this.frame);

  final String chatId;

  /// Null for `os_open`, which has none yet.
  final GaiaForegroundWindow? window;
  final List<_Step> steps;

  /// Where [window] was when planned, for the card's markers (§6.4); null for
  /// `os_open` and `os_focus`, which have none.
  final ({int left, int top, int width, int height})? frame;

  /// In Auto, which goes by its pin rather than [window].
  final _Session? session;
  var next = 0;

  Map<String, Object?> toCard() {
    final (window, frame) = (this.window, this.frame);
    return {
      'window': window == null
          ? steps.single.target
          : '${window.app}: ${jsonEncode(window.title)}',
      'app': window?.app ?? steps.single.target,
      'steps': [
        for (final step in steps)
          {
            'label': step.label,
            'resolved': step.resolved,
            if (frame != null)
              'flash': ?step.flash(frame, step.match, preview: true),
          },
      ],
    };
  }
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

  /// With [windows], as in Auto (GAIA_AUTONOMY_HLD.md §5.5), the Windows key
  /// is allowed, alone or with a key: Start or Win+R opens as a window Gaia
  /// caused.
  static GaiaKeyChord parse(Object? keys, {bool windows = false}) {
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
    const winNames = {'win', 'windows', 'meta', 'cmd', 'super'};
    const refused =
        "The Windows key isn't allowed outside Auto: it acts on Windows, not "
        'the window.';
    final modifiers = <int>[];
    for (final part in parts.take(parts.length - 1)) {
      final lower = part.toLowerCase();
      if (winNames.contains(lower)) {
        if (!windows) throw GaiaReadException(refused);
        if (!modifiers.contains(VK_LWIN)) modifiers.add(VK_LWIN);
        continue;
      }
      final modifier =
          _modifiers[lower] ?? (throw GaiaReadException('Unknown key: $part'));
      if (!modifiers.contains(modifier)) modifiers.add(modifier);
    }
    final main = parts.last;
    final lower = main.toLowerCase();
    if (winNames.contains(lower)) {
      if (!windows) throw GaiaReadException(refused);
      return GaiaKeyChord._(
        parts.join('+'),
        modifiers,
        VK_LWIN,
        typesText: false,
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
  String windowClass(int hwnd) {
    final name = wsalloc(64);
    try {
      GetClassName(hwnd, name, 64);
      return name.toDartString();
    } finally {
      free(name);
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
  ({int x, int y}) cursorAt() {
    final point = calloc<POINT>();
    try {
      GetCursorPos(point);
      return (x: point.ref.x, y: point.ref.y);
    } finally {
      free(point);
    }
  }

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

  @override
  List<GaiaListedWindow> listWindows() => gaiaListWindows();

  @override
  Future<List<({String name, String id})>> startApps() async {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '[Console]::OutputEncoding = [Text.Encoding]::UTF8; '
          'Get-StartApps | Select-Object Name, AppID | ConvertTo-Json -Compress',
    ], stdoutEncoding: utf8).timeout(const Duration(seconds: 15));
    final out = (result.stdout as String).trim();
    if (result.exitCode != 0 || out.isEmpty) {
      throw GaiaReadException("Gaia couldn't list the installed apps.");
    }
    final decoded = jsonDecode(out);
    return [
      for (final app in decoded is List ? decoded : [decoded])
        if (app case {'Name': final String name, 'AppID': final String id})
          (name: name, id: id),
    ];
  }

  @override
  Future<({int pid, String? exe})> launch(String file) async {
    // The shell asks to elevate an exe that needs administrator (UAC);
    // CreateProcess fails instead.
    final exe = file.toLowerCase().endsWith('.exe');
    final path = exe ? _startAppExe(file) : file;
    final launched = await Isolate.run(
      () => exe ? _createProcess(path) : _shellOpen(path),
    );
    // The error code doesn't survive the FFI call, so needing administrator
    // can't be told from other failures.
    if (exe && launched.error != 0) {
      throw GaiaReadException(
        "Windows wouldn't start $file. If it needs administrator rights, "
        'Gaia never opens anything as administrator; the user can open it '
        'themselves.',
      );
    }
    if (launched.error != 0) {
      throw GaiaReadException(
        "Windows couldn't open $file (error ${launched.error}).",
      );
    }
    return (pid: launched.pid, exe: launched.exe);
  }

  /// The exe's own path for a Start app whose ID is its path, as
  /// `shell:AppsFolder\{known folder}\charmap.exe`, which [_createProcess]
  /// can't open (BUG-356); [file] itself otherwise.
  static String _startAppExe(String file) {
    const prefix = r'shell:AppsFolder\';
    if (!file.toLowerCase().startsWith(prefix.toLowerCase())) return file;
    var path = file.substring(prefix.length);
    if (RegExp(r'^\{[0-9a-fA-F-]{36}\}\\').hasMatch(path)) {
      final folder = _knownFolder(path.substring(0, 38));
      if (folder == null) return file;
      path = p.windows.join(folder, path.substring(39));
    }
    return p.windows.isAbsolute(path) ? path : file;
  }

  /// The path of the known folder [id], such as `{1AC14E77-…}` for System32.
  static String? _knownFolder(String id) {
    final guid = GUIDFromString(id);
    final path = calloc<Pointer<Utf16>>();
    try {
      if (FAILED(SHGetKnownFolderPath(guid, 0, 0, path))) return null;
      try {
        return path.value.toDartString();
      } finally {
        CoTaskMemFree(path.value);
      }
    } finally {
      free(guid);
      free(path);
    }
  }

  /// Starts exe [file] in its own folder, as a double-click would, but never
  /// elevated: one that needs administrator fails. A failure's error is
  /// never 0, though GetLastError may read 0 after the FFI call.
  static ({int pid, String? exe, int error}) _createProcess(String file) {
    final startup = calloc<STARTUPINFO>();
    final process = calloc<PROCESS_INFORMATION>();
    final application = file.toNativeUtf16();
    // Writable, as CreateProcess needs, and quoted as its own argv[0].
    final command = '"$file"'.toNativeUtf16();
    final folder = p.windows.dirname(file).toNativeUtf16();
    try {
      startup.ref.cb = sizeOf<STARTUPINFO>();
      if (CreateProcess(
            application,
            command,
            nullptr,
            nullptr,
            FALSE,
            0,
            nullptr,
            folder,
            startup,
            process,
          ) ==
          0) {
        final error = GetLastError();
        return (pid: 0, exe: null, error: error == 0 ? -1 : error);
      }
      CloseHandle(process.ref.hThread);
      CloseHandle(process.ref.hProcess);
      return (
        pid: process.ref.dwProcessId,
        exe: p.windows.basenameWithoutExtension(file),
        error: 0,
      );
    } finally {
      free(startup);
      free(process);
      free(application);
      free(command);
      free(folder);
    }
  }

  /// `ShellExecuteEx` with no verb, on a thread of its own: a slow file
  /// association holds it. It asks to elevate what needs administrator, so an
  /// exe goes by [_createProcess].
  static ({int pid, String? exe, int error}) _shellOpen(String file) {
    // SEE_MASK_NOCLOSEPROCESS, SEE_MASK_NOASYNC (this thread ends soon after)
    // and SEE_MASK_FLAG_NO_UI, which the win32 package has no names for.
    const mask = 0x40 | 0x100 | 0x400;
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    final info = calloc<SHELLEXECUTEINFO>();
    final path = file.toNativeUtf16();
    try {
      info.ref
        ..cbSize = sizeOf<SHELLEXECUTEINFO>()
        ..fMask = mask
        ..lpFile = path
        ..nShow = SW_SHOWNORMAL;
      if (ShellExecuteEx(info) == 0) {
        return (pid: 0, exe: null, error: GetLastError());
      }
      final process = info.ref.hProcess;
      if (process == 0) return (pid: 0, exe: null, error: 0);
      final size = calloc<Uint32>()..value = MAX_PATH;
      final name = wsalloc(MAX_PATH);
      try {
        final exe = QueryFullProcessImageName(process, 0, name, size) == 0
            ? null
            : p.windows.basenameWithoutExtension(name.toDartString());
        return (pid: GetProcessId(process), exe: exe, error: 0);
      } finally {
        CloseHandle(process);
        free(size);
        free(name);
      }
    } finally {
      free(info);
      free(path);
      CoUninitialize();
    }
  }

  @override
  bool running(int pid) {
    if (pid == 0) return false;
    final process = OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (process == 0) return false;
    try {
      return WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
    } finally {
      CloseHandle(process);
    }
  }

  @override
  Map<int, int> processParents() => gaiaProcessParents();

  @override
  Set<String> appIdsOf(GaiaForegroundWindow window) => {
    ?gaiaWindowAppId(window.hwnd)?.toLowerCase(),
    ?gaiaProcessAppId(window.pid)?.toLowerCase(),
  };

  @override
  ({String? exe, String? appId}) handler(
    String assoc, {
    required bool protocol,
  }) => gaiaHandlerOf(assoc, protocol: protocol);

  @override
  String? startAppTarget(String id) => gaiaStartAppTarget(id);

  @override
  String? shortcutTarget(String path) => gaiaLinkTarget(path);

  @override
  bool minimized(int hwnd) => IsIconic(hwnd) != 0;

  @override
  void restore(int hwnd) => ShowWindowAsync(hwnd, SW_RESTORE);

  @override
  void minimize(int hwnd) => ShowWindowAsync(hwnd, SW_MINIMIZE);

  @override
  void maximize(int hwnd) => ShowWindowAsync(hwnd, SW_MAXIMIZE);

  @override
  Future<bool> place(
    int hwnd, {
    int? left,
    int? top,
    int? width,
    int? height,
  }) async {
    bool placed() => IsZoomed(hwnd) == 0 && IsIconic(hwnd) == 0;
    if (!placed()) {
      ShowWindowAsync(hwnd, SW_SHOWNOACTIVATE);
      final until = DateTime.now().add(const Duration(seconds: 2));
      var again = true;
      while (!placed() && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // One minimized from maximized comes back maximized: once more
        // restores it.
        if (again && IsIconic(hwnd) == 0 && IsZoomed(hwnd) != 0) {
          again = false;
          ShowWindowAsync(hwnd, SW_SHOWNOACTIVATE);
        }
      }
      // Its frame now is its maximized one, which a move would go by.
      if (!placed()) return false;
    }
    final frame = gaiaWindowFrame(hwnd);
    final rect = calloc<RECT>();
    try {
      GetWindowRect(hwnd, rect);
      // SetWindowPos counts the invisible resize borders the frame leaves out.
      final dl = frame.left - rect.ref.left;
      final dt = frame.top - rect.ref.top;
      final dr = rect.ref.right - (frame.left + frame.width);
      final db = rect.ref.bottom - (frame.top + frame.height);
      SetWindowPos(
        hwnd,
        NULL,
        (left ?? frame.left) - dl,
        (top ?? frame.top) - dt,
        (width ?? frame.width) + dl + dr,
        (height ?? frame.height) + dt + db,
        // SWP_ASYNCWINDOWPOS, which the win32 package has no name for: a
        // window that doesn't answer can't hold Gaia up.
        SWP_NOZORDER | SWP_NOACTIVATE | 0x4000,
      );
    } finally {
      free(rect);
    }
    return true;
  }

  @override
  void close(int hwnd) => PostMessage(hwnd, WM_CLOSE, 0, 0);

  @override
  Future<bool> writeClipboard(String text) => gaiaWriteClipboard(text);

  static const _extended = {
    VK_LWIN,
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
