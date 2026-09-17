import 'dart:ffi' hide Size;

import 'dart:ui' show Size;

import 'package:ffi/ffi.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

/// Where on the screen under the cursor a floater sits.
enum FloaterAnchor { upperCenter, center, bottomRight }

/// Lends the main window to a hotkey floater and gives it back.
///
/// Flutter on stable Windows has one OS window per engine, so a floater is the
/// main window itself: its placement is saved, it is shrunk to the floater's
/// size and made topmost, and on dismiss the saved placement is put back. Raw
/// Win32 rather than `window_manager` because the round trip has to keep
/// maximized/minimized/hidden state and must not activate the main window
/// when the user dismissed the floater by clicking into another app.
class FloaterWindow {
  FloaterWindow._();

  static final instance = FloaterWindow._();

  int _hwnd = 0;

  /// The main window's placement from before the floater borrowed it.
  Pointer<WINDOWPLACEMENT>? _saved;
  var _savedVisible = false;
  var _previousForeground = 0;

  /// A placement still owed to a main window that was hidden when a floater
  /// borrowed it: applied the next time the main window is shown, since
  /// applying it while hidden would show it.
  Pointer<WINDOWPLACEMENT>? _owedPlacement;

  bool get isBorrowed => _saved != null;

  int get _window {
    if (_hwnd == 0 || IsWindow(_hwnd) == 0) _hwnd = _findMainWindow();
    return _hwnd;
  }

  /// Visible, not minimized, and the foreground window. Minimized, hidden to
  /// the tray, or behind another app all count as not open.
  bool get mainWindowOpen {
    if (isBorrowed) return false;
    final hwnd = _window;
    return hwnd != 0 &&
        IsWindowVisible(hwnd) != 0 &&
        IsIconic(hwnd) == 0 &&
        GetForegroundWindow() == hwnd;
  }

  /// Shows the floater at [size] (logical pixels) on the monitor under the
  /// cursor. Called again while borrowed, it only moves and resizes.
  Future<void> show(Size size, FloaterAnchor anchor) async {
    final hwnd = _window;
    if (hwnd == 0) return;
    if (_saved == null) {
      _previousForeground = GetForegroundWindow();
      final owed = _owedPlacement;
      _owedPlacement = null;
      if (owed != null) {
        _saved = owed;
        _savedVisible = false;
      } else {
        _saved = _readPlacement(hwnd);
        _savedVisible = IsWindowVisible(hwnd) != 0;
      }
      await windowManager.setMinimumSize(Size.zero);
      await windowManager.setSkipTaskbar(true);
    }
    _place(hwnd, size, anchor);
    SetForegroundWindow(hwnd);
  }

  /// Resizes a borrowed window in place, keeping [anchor]'s edge fixed.
  void resize(Size size, FloaterAnchor anchor) {
    if (!isBorrowed) return;
    _place(_window, size, anchor);
  }

  /// Gives the window back.
  ///
  /// [showMain] brings the main window up focused (the todo bar's "Open
  /// app"). Otherwise the main window returns to exactly the state it was in,
  /// without taking focus: to whatever had it before the floater when the
  /// floater still holds focus, or left with the app the user clicked into.
  Future<void> release({required bool showMain}) async {
    final saved = _saved;
    if (saved == null) return;
    _saved = null;
    final hwnd = _window;
    final stillForeground = GetForegroundWindow() == hwnd;

    SetWindowPos(
      hwnd,
      HWND_NOTOPMOST,
      0,
      0,
      0,
      0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
    );
    await windowManager.setSkipTaskbar(false);
    await windowManager.setMinimumSize(kMainWindowMinimumSize);

    if (showMain) {
      _applyPlacement(hwnd, saved, activate: true);
      free(saved);
      SetForegroundWindow(hwnd);
      return;
    }

    if (!_savedVisible) {
      ShowWindow(hwnd, SW_HIDE);
      _owedPlacement = saved;
    } else {
      _applyPlacement(hwnd, saved, activate: false);
      free(saved);
    }

    final previous = _previousForeground;
    if (stillForeground && previous != 0 && IsWindow(previous) != 0) {
      SetForegroundWindow(previous);
    } else if (_savedVisible) {
      final foreground = GetForegroundWindow();
      if (foreground != 0 && foreground != hwnd) {
        SetWindowPos(
          hwnd,
          foreground,
          0,
          0,
          0,
          0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        );
      }
    }
  }

  /// Shows and focuses the main window — from the tray, or after a hide to
  /// tray — restoring a placement a floater still owes it.
  Future<void> showMain() async {
    final hwnd = _window;
    final owed = _owedPlacement;
    if (hwnd != 0 && owed != null) {
      _owedPlacement = null;
      _applyPlacement(hwnd, owed, activate: true);
      free(owed);
    } else {
      await windowManager.show();
      if (await windowManager.isMinimized()) await windowManager.restore();
    }
    await windowManager.focus();
  }

  void _applyPlacement(
    int hwnd,
    Pointer<WINDOWPLACEMENT> placement, {
    required bool activate,
  }) {
    final minimized = placement.ref.showCmd == SW_SHOWMINIMIZED;
    final maximized = placement.ref.showCmd == SW_SHOWMAXIMIZED;
    placement.ref.showCmd = switch ((activate, minimized, maximized)) {
      // SW_RESTORE honours WPF_RESTORETOMAXIMIZED from the saved flags.
      (true, true, _) => SW_RESTORE,
      (false, true, _) => SW_SHOWMINNOACTIVE,
      // There is no non-activating maximize; [release] hands focus back
      // straight after, or slides the window under the foreground app.
      (_, false, true) => SW_SHOWMAXIMIZED,
      (true, false, false) => SW_SHOWNORMAL,
      (false, false, false) => SW_SHOWNOACTIVATE,
    };
    SetWindowPlacement(hwnd, placement);
  }

  void _place(int hwnd, Size size, FloaterAnchor anchor) {
    final point = calloc<POINT>();
    final info = calloc<MONITORINFO>()..ref.cbSize = sizeOf<MONITORINFO>();
    final dpiX = calloc<Uint32>();
    final dpiY = calloc<Uint32>();
    final placement = _readPlacement(hwnd);
    try {
      GetCursorPos(point);
      final monitor = MonitorFromPoint(point.ref, MONITOR_DEFAULTTONEAREST);
      GetMonitorInfo(monitor, info);
      final scale = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, dpiX, dpiY) ==
              S_OK
          ? dpiX.value / 96
          : 1.0;
      final work = info.ref.rcWork;
      final workWidth = work.right - work.left;
      final workHeight = work.bottom - work.top;
      final margin = (24 * scale).round();
      final width = (size.width * scale).round().clamp(1, workWidth).toInt();
      final height = (size.height * scale).round().clamp(1, workHeight).toInt();
      final (x, y) = switch (anchor) {
        FloaterAnchor.upperCenter => (
          work.left + (workWidth - width) ~/ 2,
          work.top + (workHeight * 0.22).round(),
        ),
        FloaterAnchor.center => (
          work.left + (workWidth - width) ~/ 2,
          work.top + (workHeight - height) ~/ 2,
        ),
        FloaterAnchor.bottomRight => (
          work.right - width - margin,
          work.bottom - height - margin,
        ),
      };
      final top = y.clamp(work.top, work.bottom - height).toInt();

      // Un-maximizes (a maximized window ignores size changes) and shows, in
      // one call. rcNormalPosition is in workspace coordinates.
      final monitorRect = info.ref.rcMonitor;
      final offsetX = work.left - monitorRect.left;
      final offsetY = work.top - monitorRect.top;
      placement.ref
        ..showCmd = SW_SHOWNORMAL
        ..flags = 0;
      placement.ref.rcNormalPosition
        ..left = x - offsetX
        ..top = top - offsetY
        ..right = x - offsetX + width
        ..bottom = top - offsetY + height;
      SetWindowPlacement(hwnd, placement);
      // Again in screen coordinates, and after any WM_DPICHANGED the move to
      // another monitor raised: the runner resizes to Windows' suggested rect
      // there, which scales the size a second time.
      SetWindowPos(hwnd, HWND_TOPMOST, x, top, width, height, SWP_SHOWWINDOW);
    } finally {
      free(point);
      free(info);
      free(dpiX);
      free(dpiY);
      free(placement);
    }
  }

  static Pointer<WINDOWPLACEMENT> _readPlacement(int hwnd) {
    final placement = calloc<WINDOWPLACEMENT>()
      ..ref.length = sizeOf<WINDOWPLACEMENT>();
    GetWindowPlacement(hwnd, placement);
    return placement;
  }

  static var _found = 0;

  static int _findMainWindow() {
    _found = 0;
    final callback = Pointer.fromFunction<WNDENUMPROC>(_matchWindow, 1);
    EnumWindows(callback, GetCurrentProcessId());
    return _found;
  }

  static int _matchWindow(int hwnd, int processId) {
    final owner = calloc<Uint32>();
    final className = wsalloc(64);
    try {
      GetWindowThreadProcessId(hwnd, owner);
      if (owner.value != processId) return 1;
      GetClassName(hwnd, className, 64);
      if (className.toDartString() != 'FLUTTER_RUNNER_WIN32_WINDOW') return 1;
      _found = hwnd;
      return 0;
    } finally {
      free(owner);
      free(className);
    }
  }
}
