import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/platform/window_focus_watcher.dart';

/// Mitigates a Flutter Windows debug assertion when modifier keys (often Alt)
/// arrive with inconsistent state after Alt+Tab or window focus changes.
///
/// See: https://github.com/flutter/flutter/issues/143155
void installWindowsKeyboardWorkaround() {
  if (!isWindows || !kDebugMode) return;

  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (_isKnownWindowsKeyboardDesync(details)) return;
    if (previous != null) {
      previous(details);
    } else {
      FlutterError.presentError(details);
    }
  };
}

bool _isKnownWindowsKeyboardDesync(FlutterErrorDetails details) {
  final exception = details.exception;
  if (exception is! AssertionError) return false;
  final message = exception.message?.toString() ?? '';
  if (!message.contains(
    'Attempted to send a key down event when no keys are in keysPressed',
  )) {
    return false;
  }
  return details.stack?.toString().contains('raw_keyboard.dart') ?? false;
}

/// Reconciles both directions of the pressed-key state, in that order.
///
/// [HardwareKeyboard.syncKeyboardState] only ever *adds*: it walks the engine's
/// pressed-key map and writes each entry into the framework's, with no branch
/// that removes one. The release half is [WindowsKeyboardReconciler.reconcile],
/// and it has to run second — a sync replays the engine's map, which on the
/// path this exists for is holding the same stale modifier.
Future<void> resyncWindowsKeyboardState() async {
  if (!isWindows) return;
  await HardwareKeyboard.instance.syncKeyboardState();
  WindowsKeyboardReconciler.instance.reconcile();
}

/// Releases modifier keys the framework still believes are held.
///
/// [HardwareKeyboard] learns that a key came back up only from a key *event*.
/// When a chord's key-up is delivered to a different window the framework never
/// hears it, and that modifier stays in [HardwareKeyboard.physicalKeysPressed]
/// for the rest of the process. Windows makes this easy to hit: every Win-key
/// shortcut hands the shell everything after the Win press, and `Win+Shift+S`
/// — the screenshot chord, so the one most likely to be followed by a paste —
/// leaves Meta stuck exactly this way.
///
/// Nothing recovers from it on its own. [HardwareKeyboard.syncKeyboardState]
/// is additive (see [resyncWindowsKeyboardState]) and fixes only the opposite
/// desync; [HardwareKeyboard.clearState] is `@visibleForTesting` and drops
/// every registered handler along with the state, which would silently unhook
/// `CapsLockState` and the shell, study and calendar shortcuts.
///
/// A stale modifier is not cosmetic — it disables large parts of the app until
/// it is restarted:
///
///  * [SingleActivator] compares modifiers for *equality*, so a stuck Meta
///    stops `control: true` from ever matching again. That is every shortcut in
///    `DefaultTextEditingShortcuts` — Ctrl+A, Ctrl+C, Ctrl+V, Ctrl+Z — dead in
///    every text field in the app.
///  * `VimSession.handleKey` returns [KeyEventResult.ignored] for every key
///    while `alt || meta`, so a Vim field reached with one stuck sits in Normal
///    mode typing its own commands out as literal text, and cannot be escaped:
///    the mode is only ever left from Insert.
class WindowsKeyboardReconciler {
  WindowsKeyboardReconciler._();

  /// The app-wide instance, installed once from `VoyagerApp`.
  static final WindowsKeyboardReconciler instance =
      WindowsKeyboardReconciler._();

  /// Stands in for the OS probe in tests. Returning null means "no native
  /// answer", which is read as "still held" — see [reconcile].
  @visibleForTesting
  static bool? Function(int virtualKey)? debugProbe;

  bool _installed = false;

  /// Whether the next key event should trigger a second reconcile — see
  /// [_handleKey].
  bool _armed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    WindowFocusWatcher.instance.addListener(_handleWindowFocus);
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    WindowFocusWatcher.instance.removeListener(_handleWindowFocus);
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _armed = false;
  }

  /// Hung off [WindowFocusWatcher] rather than the app lifecycle alone: on
  /// Windows a window switch arrives on the view-focus channel and need not be
  /// accompanied by a lifecycle message at all, which is why the existing
  /// `AppLifecycleState.resumed` hook did not cover this on its own.
  ///
  /// Read twice for the reason `CapsLockState` reads twice — the two signals a
  /// switch arrives on race each other, and the OS-side state is only settled
  /// once the window has finished taking the focus it was handed.
  void _handleWindowFocus() {
    if (!WindowFocusWatcher.instance.hasFocus) return;
    reconcile();
    WidgetsBinding.instance.addPostFrameCallback((_) => reconcile());
    _armed = true;
  }

  /// Never claims a key — this only wants to be told one happened, so the state
  /// is checked once more at the moment the user actually goes back to typing,
  /// however long after the switch that is.
  ///
  /// The work is deferred out of the handler because this runs inside
  /// [HardwareKeyboard]'s own dispatch loop and [reconcile] dispatches a
  /// synthesized event of its own, which `_dispatchKeyEvent` asserts against
  /// (`Nested keyboard dispatching is not supported`). The key in hand is
  /// therefore still lost if it needed a modifier; every key after it is not.
  bool _handleKey(KeyEvent event) {
    if (!_armed) return false;
    _armed = false;
    scheduleMicrotask(reconcile);
    return false;
  }

  /// Drops every modifier the framework holds that the OS says is not down.
  ///
  /// Conservative in both directions: a key the framework does not hold is left
  /// alone, and so is one the probe cannot answer for. Nothing here can invent
  /// a release for a key the user is genuinely holding.
  ///
  /// Returns the number of keys released, for tests.
  @visibleForTesting
  int reconcile() {
    final keyboard = HardwareKeyboard.instance;
    var released = 0;
    for (final MapEntry<PhysicalKeyboardKey, int> entry
        in _modifierVirtualKeys.entries) {
      final logical = keyboard.lookUpLayout(entry.key);
      // The framework agrees it is up.
      if (logical == null) continue;
      // Still down, or no native answer to go on.
      if (_held(entry.value) ?? true) continue;
      keyboard.handleKeyEvent(
        KeyUpEvent(
          physicalKey: entry.key,
          logicalKey: logical,
          timeStamp: ServicesBinding.instance.currentSystemFrameTimeStamp,
          // The same shape the framework's own `KeyEventManager` builds when it
          // patches up a release it noticed was missed.
          synthesized: true,
        ),
      );
      released++;
    }
    return released;
  }
}

/// The modifier keys [WindowsKeyboardReconciler] can release, and the Win32
/// virtual-key code each is read by. Deliberately only the modifiers: they are
/// the keys whose stale state changes how *other* keys are interpreted.
///
/// Not `const`: [PhysicalKeyboardKey] overrides `==`, which rules it out as a
/// constant map key.
final Map<PhysicalKeyboardKey, int> _modifierVirtualKeys =
    <PhysicalKeyboardKey, int>{
      PhysicalKeyboardKey.shiftLeft: 0xA0, // VK_LSHIFT
      PhysicalKeyboardKey.shiftRight: 0xA1, // VK_RSHIFT
      PhysicalKeyboardKey.controlLeft: 0xA2, // VK_LCONTROL
      PhysicalKeyboardKey.controlRight: 0xA3, // VK_RCONTROL
      PhysicalKeyboardKey.altLeft: 0xA4, // VK_LMENU
      PhysicalKeyboardKey.altRight: 0xA5, // VK_RMENU
      PhysicalKeyboardKey.metaLeft: 0x5B, // VK_LWIN
      PhysicalKeyboardKey.metaRight: 0x5C, // VK_RWIN
    };

/// Whether the OS says this key is physically down, or null where there is
/// nothing to read.
bool? _held(int virtualKey) {
  final probe = WindowsKeyboardReconciler.debugProbe;
  if (probe != null) return probe(virtualKey);
  final getAsyncKeyState = _getAsyncKeyState;
  if (getAsyncKeyState == null) return null;
  return getAsyncKeyState(virtualKey) & 0x8000 != 0;
}

typedef _GetAsyncKeyStateNative = Int16 Function(Int32);
typedef _GetAsyncKeyStateDart = int Function(int);

/// `GetAsyncKeyState` rather than the `GetKeyState` `CapsLockState` reads.
///
/// `GetKeyState` answers from the calling thread's message queue — the state as
/// of the last message that thread processed. For a chord whose key-up went to
/// another window that queue never saw the release, so it would confirm the
/// very staleness this is trying to detect. `GetAsyncKeyState` reports the
/// physical state at the moment of the call, which is the question being asked.
///
/// Never probes the OS from a `flutter test` run, for the reason
/// `CapsLockState` does not: the harness reports the Windows target platform on
/// a Windows host, and a test that read the real keyboard would pass or fail on
/// whichever keys the developer happened to be holding.
final bool _canProbe =
    isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

bool _lookedUp = false;
_GetAsyncKeyStateDart? _cachedGetAsyncKeyState;

_GetAsyncKeyStateDart? get _getAsyncKeyState {
  if (_lookedUp) return _cachedGetAsyncKeyState;
  _lookedUp = true;
  if (!_canProbe) return null;
  try {
    _cachedGetAsyncKeyState = DynamicLibrary.open('user32.dll')
        .lookupFunction<_GetAsyncKeyStateNative, _GetAsyncKeyStateDart>(
          'GetAsyncKeyState',
        );
  } on Object {
    // A host without user32 (or a stripped one) simply has no native answer,
    // and [reconcile] leaves every key alone.
    _cachedGetAsyncKeyState = null;
  }
  return _cachedGetAsyncKeyState;
}
