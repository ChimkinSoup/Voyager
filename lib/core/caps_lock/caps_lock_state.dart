import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/platform/window_focus_watcher.dart';

/// Whether the hardware Caps Lock lock mode is on, kept correct across window
/// switches.
///
/// ### Why this is not just [HardwareKeyboard.lockModesEnabled]
///
/// The framework's lock-mode set is derived purely from key *events*: it is
/// flipped in `HardwareKeyboard.handleKeyEvent` when a [KeyDownEvent] for a
/// lock key arrives, and nothing else writes to it. Two consequences:
///
///  * A Caps Lock pressed while another app has focus is invisible. The set
///    still says what it said before the switch.
///  * [HardwareKeyboard.syncKeyboardState] does **not** fix that. Despite the
///    name it only repopulates `_pressedKeys` from the engine's
///    `getKeyboardState` answer — it never touches the lock modes.
///
/// Windows self-corrects on the *next* key, because the embedder synthesizes a
/// Caps Lock down/up pair ahead of the real event when it notices the toggled
/// state disagrees. But CAPS_LOCK.md §5.2 asks for the badge to be right the
/// moment a field is focused again, without waiting for a keystroke, so that
/// correction arrives one key too late.
///
/// ### What this does instead
///
/// On Windows it asks the OS directly — `user32!GetKeyState(VK_CAPITAL)`, whose
/// low bit is the toggle state. That is the same call the Flutter Windows
/// embedder makes internally; it is read here over `dart:ffi` rather than
/// through a platform channel of our own so the runner stays stock.
///
/// [GetKeyState] reports the calling *thread's* view of the keyboard, which is
/// only meaningful on the thread that pumps the window's messages. That is the
/// right thread here: the Windows embedder gives the engine a platform task
/// runner and no separate UI one, so Dart runs on the platform thread.
///
/// Everywhere else — Linux for now, and any host where the lookup fails — it
/// falls back to [HardwareKeyboard.lockModesEnabled], which is correct while
/// the window has been holding focus and stale for exactly one keystroke after
/// it has not.
class CapsLockState extends ChangeNotifier {
  CapsLockState._();

  /// The app-wide instance. Its listeners are the mounted caret indicators, so
  /// the key handler below is installed only while at least one field could
  /// draw the badge — nothing at all on mobile, or with the setting off.
  static final CapsLockState instance = CapsLockState._();

  /// Stands in for the OS probe in tests. Returning null means "no native
  /// answer", which falls back to [HardwareKeyboard] exactly as an unsupported
  /// platform does.
  @visibleForTesting
  static ValueGetter<bool?>? debugProbe;

  bool _installed = false;
  bool _isOn = false;

  /// Whether Caps Lock is on right now.
  ///
  /// Only current while something is listening — add the listener first, then
  /// read this.
  bool get isOn => _isOn;

  @override
  void addListener(VoidCallback listener) {
    _install();
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _uninstall();
  }

  void _install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler(_handleKey);
    WindowFocusWatcher.instance.addListener(_handleWindowFocus);
    _isOn = _read();
  }

  void _uninstall() {
    if (!_installed) return;
    _installed = false;
    HardwareKeyboard.instance.removeHandler(_handleKey);
    WindowFocusWatcher.instance.removeListener(_handleWindowFocus);
  }

  /// Never claims a key — this only wants to be told one happened. By the time
  /// handlers run, [HardwareKeyboard] has already applied the event to its lock
  /// modes, and on Windows the embedder has already pushed through any
  /// synthesized correction ahead of it.
  bool _handleKey(KeyEvent event) {
    sync();
    return false;
  }

  void _handleWindowFocus() {
    if (!WindowFocusWatcher.instance.hasFocus) return;
    // Twice, because the two signals a window switch arrives on race each
    // other (see [WindowFocusWatcher]) and the OS-side state is only settled
    // once the window has finished processing the focus it was handed. The
    // first read is usually right; the second costs one call and covers the
    // ordering where it is not.
    sync();
    WidgetsBinding.instance.addPostFrameCallback((_) => sync());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Re-reads the lock state and notifies if it moved.
  @visibleForTesting
  void sync() {
    final next = _read();
    if (next == _isOn) return;
    _isOn = next;
    notifyListeners();
  }

  bool _read() {
    final probe = debugProbe ?? _nativeCapsLockOn;
    return probe() ??
        HardwareKeyboard.instance.lockModesEnabled.contains(
          KeyboardLockMode.capsLock,
        );
  }
}

/// Whether this platform may draw the caret badge at all (CAPS_LOCK.md §2.2).
///
/// macOS is excluded because the system already draws its own Caps Lock glyph,
/// and mobile because there is no hardware lock key to report.
bool get capsLockIndicatorSupportsPlatform => isWindows || isLinux;

const int _vkCapital = 0x14;

/// Reads the OS toggle state, or null where there is nothing to read.
bool? _nativeCapsLockOn() {
  final getKeyState = _getKeyState;
  if (getKeyState == null) return null;
  return getKeyState(_vkCapital) & 0x0001 != 0;
}

typedef _GetKeyStateNative = Int16 Function(Int32);
typedef _GetKeyStateDart = int Function(int);

/// Never probes the OS from a `flutter test` run. The harness reports the
/// Windows target platform on a Windows host, and a test that read the real
/// keyboard would pass or fail on whether the developer happened to have Caps
/// Lock down — see [CapsLockState.debugProbe] for the seam tests use instead.
final bool _canProbe =
    isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

bool _lookedUp = false;
_GetKeyStateDart? _cachedGetKeyState;

_GetKeyStateDart? get _getKeyState {
  if (_lookedUp) return _cachedGetKeyState;
  _lookedUp = true;
  if (!_canProbe) return null;
  try {
    _cachedGetKeyState = DynamicLibrary.open(
      'user32.dll',
    ).lookupFunction<_GetKeyStateNative, _GetKeyStateDart>('GetKeyState');
  } on Object {
    // A host without user32 (or a stripped one) simply has no native answer;
    // the [HardwareKeyboard] fallback still gives a working badge.
    _cachedGetKeyState = null;
  }
  return _cachedGetKeyState;
}
