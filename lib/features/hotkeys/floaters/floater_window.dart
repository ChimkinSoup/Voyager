import 'dart:ffi' hide Size;

import 'dart:ui' show Size;

import 'package:ffi/ffi.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

/// Where on the screen under the cursor a floater sits.
enum FloaterAnchor { upperCenter, center, bottomRight }

/// A window's frame in screen pixels, and whether it was maximized there.
typedef _Frame = ({int left, int top, int right, int bottom, bool zoomed});

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

  /// The frame the main window was on screen at before the floater borrowed
  /// it, for a restore that does not activate it. Null when it was hidden to
  /// the tray or minimized, which [release] puts back through the placement.
  _Frame? _savedFrame;

  /// A placement still owed to a main window that was hidden when a floater
  /// borrowed it: applied the next time the main window is shown, since
  /// applying it while hidden would show it.
  Pointer<WINDOWPLACEMENT>? _owedPlacement;

  /// True from the start of [release] until the window has been put back: the
  /// awaits in between let frames through, and they are still floater-sized.
  var _releasing = false;

  bool get isBorrowed => _saved != null;

  /// Whether the window has the main window's own placement: not lent to a
  /// floater, and not hidden still at a floater's size.
  bool get atMainPlacement =>
      _saved == null && _owedPlacement == null && !_releasing;

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
  ///
  /// [onShow] swaps the floater in, out of sight: see [_cloaked].
  Future<void> show(
    Size size,
    FloaterAnchor anchor, {
    required void Function() onShow,
  }) async {
    final hwnd = _window;
    if (hwnd == 0) {
      onShow();
      return;
    }
    await _cloaked(hwnd, () async {
      await _borrow(hwnd);
      onShow();
      _place(hwnd, size, anchor);
    });
    SetForegroundWindow(hwnd);
  }

  Future<void> _borrow(int hwnd) async {
    if (_saved == null) {
      _previousForeground = GetForegroundWindow();
      final owed = _owedPlacement;
      _owedPlacement = null;
      if (owed != null) {
        _saved = owed;
        _savedVisible = false;
        _savedFrame = null;
      } else {
        _saved = _readPlacement(hwnd);
        _savedVisible = IsWindowVisible(hwnd) != 0;
        _savedFrame = _savedVisible && IsIconic(hwnd) == 0
            ? _readFrame(hwnd)
            : null;
      }
      // The taskbar button stays: the shell builds Alt+Tab from the same
      // list, and a switcher opened over the floater would leave the app out.
      await windowManager.setMinimumSize(Size.zero);
    }
  }

  /// Runs [change] — a move, resize or show — with the window off the screen,
  /// and puts it back once the engine has painted at the size it ends up.
  ///
  /// Otherwise the change shows. A maximized window placed at a floater's
  /// size plays DWM's restore animation down to it, and one given back plays
  /// the maximize animation up. And until the engine's first frame at the new
  /// size, the window shows the last one it painted, stretched or cropped: a
  /// corner of the app, or whichever floater was up before.
  Future<void> _cloaked(int hwnd, Future<void> Function() change) async {
    _setCloaked(hwnd, true);
    try {
      final view = _flutterView(hwnd);
      final before = _clientSize(view);
      await change();
      if (IsWindowVisible(hwnd) != 0 && IsIconic(hwnd) == 0) {
        final after = _clientSize(view);
        await _paintedAt(after, resized: after != before);
      }
    } finally {
      _setCloaked(hwnd, false);
    }
  }

  /// DWM neither draws a cloaked window nor animates its showing, maximizing
  /// or restoring; the engine goes on painting it.
  static void _setCloaked(int hwnd, bool cloaked) {
    final value = calloc<Int32>()..value = cloaked ? 1 : 0;
    try {
      DwmSetWindowAttribute(hwnd, DWMWA_CLOAK, value, sizeOf<Int32>());
      DwmSetWindowAttribute(
        hwnd,
        DWMWA_TRANSITIONS_FORCEDISABLED,
        value,
        sizeOf<Int32>(),
      );
    } finally {
      free(value);
    }
  }

  /// The engine's child window, which it sizes its surface to. The top-level
  /// window's client area is not always the same size.
  static int _flutterView(int hwnd) {
    final className = 'FLUTTERVIEW'.toNativeUtf16();
    try {
      final view = FindWindowEx(hwnd, 0, className, nullptr);
      return view == 0 ? hwnd : view;
    } finally {
      free(className);
    }
  }

  static Size _clientSize(int hwnd) {
    final rect = calloc<RECT>();
    try {
      GetClientRect(hwnd, rect);
      return Size(
        (rect.ref.right - rect.ref.left).toDouble(),
        (rect.ref.bottom - rect.ref.top).toDouble(),
      );
    } finally {
      free(rect);
    }
  }

  /// Waits for a frame built at [size], and one frame more, by the end of
  /// which it has been rasterized. When the change [resized] the view, the
  /// frame has to come after the engine reports the new size: a size read
  /// before then could only be the old one, however it compares.
  static Future<void> _paintedAt(Size size, {required bool resized}) async {
    final binding = SchedulerBinding.instance;
    final view = binding.platformDispatcher.implicitView;
    Future<void> frame() {
      binding.scheduleFrame();
      return binding.endOfFrame.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () {},
      );
    }

    if (resized && view != null) {
      final waited = Stopwatch()..start();
      do {
        await frame();
      } while (view.physicalSize != size &&
          waited.elapsed < const Duration(milliseconds: 500));
    }
    await frame();
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
  ///
  /// [onRestore] hands the window back to the app, out of sight: see
  /// [_cloaked].
  Future<void> release({
    required bool showMain,
    required void Function() onRestore,
  }) async {
    final saved = _saved;
    if (saved == null) {
      onRestore();
      return;
    }
    _saved = null;
    _releasing = true;
    final hwnd = _window;
    try {
      await _cloaked(
        hwnd,
        () => _release(saved, showMain: showMain, onRestore: onRestore),
      );
    } finally {
      _releasing = false;
    }
    if (showMain) SetForegroundWindow(hwnd);
  }

  Future<void> _release(
    Pointer<WINDOWPLACEMENT> saved, {
    required bool showMain,
    required void Function() onRestore,
  }) async {
    final frame = _savedFrame;
    _savedFrame = null;
    final hwnd = _window;
    final stillForeground = GetForegroundWindow() == hwnd;
    // The app the main window must neither cover nor take focus from: the one
    // the user clicked into, or whatever had focus before the floater if the
    // floater still holds it. Read before the restore, which can leave the
    // main window itself in the foreground.
    final other = stillForeground ? _previousForeground : GetForegroundWindow();

    SetWindowPos(
      hwnd,
      HWND_NOTOPMOST,
      0,
      0,
      0,
      0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
    );
    await windowManager.setMinimumSize(kMainWindowMinimumSize);
    onRestore();

    if (showMain) {
      _applyPlacement(hwnd, saved, activate: true);
      free(saved);
      return;
    }

    if (!_savedVisible) {
      ShowWindow(hwnd, SW_HIDE);
      _owedPlacement = saved;
    } else {
      if (frame == null) {
        // Minimized: back to the taskbar, where none of it shows.
        _applyPlacement(hwnd, saved, activate: false);
      } else {
        _restoreQuietly(hwnd, saved, frame, behind: other);
      }
      free(saved);
    }

    if (stillForeground && other != 0 && IsWindow(other) != 0) {
      SetForegroundWindow(other);
    }
  }

  /// Puts the main window back at [frame] without activating it and without
  /// lifting it over the app in front of it.
  ///
  /// Two things made a plain restore throw a black full-screen window over
  /// whatever the user had clicked into. There is no SW_ value that maximizes
  /// without activating, and once the main window had taken the foreground,
  /// pushing it back down afterwards had nothing above it to go under. And the
  /// frame right after a resize is blank — the engine cannot paint it from
  /// inside this call — so the window has to arrive already behind the app in
  /// front rather than be lowered a moment later.
  void _restoreQuietly(
    int hwnd,
    Pointer<WINDOWPLACEMENT> saved,
    _Frame frame, {
    required int behind,
  }) {
    final after = _neighbourBelow(hwnd, behind);
    var flags = SWP_NOACTIVATE;
    if (after == 0) flags |= SWP_NOZORDER;

    if (frame.zoomed) {
      // Cloaked while the maximized state goes back on by hand: the saved
      // placement for the restore rect the floater overwrote, then the style
      // bit, which has to be set before the move so the frame is calculated
      // as a maximized window's. WM_SIZE then reports SIZE_MAXIMIZED from that
      // bit, so `window_manager` and the title bar stay in step.
      //
      // Never hidden and shown again for it: the shell takes a window that
      // reappears as newly opened and puts it first in Alt+Tab, so an Alt+Tab
      // held over the floater, which dismisses it, would land on the app.
      saved.ref.showCmd = SW_SHOWNOACTIVATE;
      SetWindowPlacement(hwnd, saved);
      SetWindowLongPtr(
        hwnd,
        GWL_STYLE,
        GetWindowLongPtr(hwnd, GWL_STYLE) | WS_MAXIMIZE,
      );
      flags |= SWP_FRAMECHANGED;
    }

    SetWindowPos(
      hwnd,
      after,
      frame.left,
      frame.top,
      frame.right - frame.left,
      frame.bottom - frame.top,
      flags,
    );
  }

  /// The window the main window goes back under in the z-order, or 0 to leave
  /// it where it is.
  static int _neighbourBelow(int hwnd, int behind) {
    if (behind == hwnd) return 0;
    // Placed after a topmost window, the main window would join the topmost
    // band. And left where it is, it stays on top of every ordinary window,
    // where the floater had it: mid-Alt+Tab the foreground is one of the
    // shell's hidden staging windows, and the main window would show over
    // the app being switched to until that app activated. Under the top
    // ordinary window instead, for both.
    if (behind == 0 ||
        IsWindow(behind) == 0 ||
        IsWindowVisible(behind) == 0 ||
        IsIconic(behind) != 0 ||
        _isTopmost(behind)) {
      return _topOrdinaryWindow(except: hwnd);
    }
    return behind;
  }

  static bool _isTopmost(int hwnd) =>
      GetWindowLongPtr(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST != 0;

  /// The highest window in z-order that is on screen and not topmost, or 0.
  static int _topOrdinaryWindow({required int except}) {
    final cloaked = calloc<Int32>();
    try {
      for (var w = GetTopWindow(0); w != 0; w = GetWindow(w, GW_HWNDNEXT)) {
        if (w == except ||
            IsWindowVisible(w) == 0 ||
            IsIconic(w) != 0 ||
            _isTopmost(w)) {
          continue;
        }
        // Suspended store apps are "visible" but cloaked, and sit high.
        cloaked.value = 0;
        DwmGetWindowAttribute(w, DWMWA_CLOAKED, cloaked, sizeOf<Int32>());
        if (cloaked.value == 0) return w;
      }
      return 0;
    } finally {
      free(cloaked);
    }
  }

  /// Shows and focuses the main window — from the tray, or after a hide to
  /// tray — restoring a placement a floater still owes it.
  Future<void> showMain() async {
    final hwnd = _window;
    final owed = _owedPlacement;
    if (hwnd != 0 && owed != null) {
      _owedPlacement = null;
      // Still at the floater's size, and last painted as the floater.
      await _cloaked(hwnd, () async {
        _applyPlacement(hwnd, owed, activate: true);
        free(owed);
      });
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
      // There is no non-activating maximize: a maximized window that must not
      // take focus goes back through [_restoreQuietly] instead.
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

  static _Frame _readFrame(int hwnd) {
    final rect = calloc<RECT>();
    try {
      GetWindowRect(hwnd, rect);
      return (
        left: rect.ref.left,
        top: rect.ref.top,
        right: rect.ref.right,
        bottom: rect.ref.bottom,
        zoomed: IsZoomed(hwnd) != 0,
      );
    } finally {
      free(rect);
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
