import 'dart:ffi' hide Size;
import 'dart:ui' show Size;

import 'package:ffi/ffi.dart';
import 'package:flutter/scheduler.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

/// The companion window's modes (GAIA_HLD.md §3.3).
enum GaiaMode { small, large, window }

/// Logical sizes. The Gaia window remembers its own once moved or resized.
const _smallSize = Size(560, 460);
const _largeSize = Size(980, 760);
const _windowSize = Size(1200, 820);

/// The companion's one OS window, in whichever mode it's in. Floaters are
/// topmost tool windows, out of the taskbar and Alt+Tab; the Gaia window is
/// an ordinary app window. Raw Win32, like `FloaterWindow`: window_manager
/// can't set tool-window style or place on the monitor under the cursor.
class GaiaWindow {
  int _hwnd = 0;

  /// The mode on screen; null while hidden.
  GaiaMode? shown;

  /// The Gaia window's frame from when it was last on screen, in physical
  /// pixels, so a floater opened over it can put it back.
  ({int left, int top, int width, int height})? _windowFrame;

  Future<void> init() async {
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setTitle('Gaia');
    // Closing hides; the companion is resident (§3.2).
    await windowManager.setPreventClose(true);
    _hwnd = _findOwnWindow();
    // Out of its own screenshots — and the user's screen shares (§3.2).
    SetWindowDisplayAffinity(_hwnd, WDA_EXCLUDEFROMCAPTURE);
  }

  /// Puts the window on screen in [mode]. [layout] swaps the content to
  /// [mode]'s layout; it runs before the resize when the window shrinks, and
  /// after the frame at the new size when it grows, so a grow never shows
  /// the uncovered area black and a shrink never squeezes the old layout.
  Future<void> show(GaiaMode mode, void Function() layout) async {
    final hwnd = _hwnd;
    if (shown == GaiaMode.window) _windowFrame = _readFrame(hwnd);
    final frame = _frameFor(mode);
    final old = _readFrame(hwnd);
    final grows =
        shown == null || frame.width * frame.height > old.width * old.height;
    final floater = mode != GaiaMode.window;

    while (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
      await Future<void>(() {});
    }
    _cloak(hwnd, true);
    // The shell only notices a tool-window style change on a window that is
    // shown again after it.
    final exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    final wantStyle = floater
        ? (exStyle | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW
        : (exStyle & ~WS_EX_TOOLWINDOW) | WS_EX_APPWINDOW;
    if (wantStyle != exStyle) {
      ShowWindow(hwnd, SW_HIDE);
      SetWindowLongPtr(hwnd, GWL_EXSTYLE, wantStyle);
    }
    if (!grows) layout();
    SetWindowPos(
      hwnd,
      floater ? HWND_TOPMOST : HWND_NOTOPMOST,
      frame.left,
      frame.top,
      frame.width,
      frame.height,
      SWP_SHOWWINDOW | SWP_FRAMECHANGED,
    );
    await _paintedAt();
    if (grows) {
      layout();
      await _paintedAt();
    }
    _cloak(hwnd, false);
    SetForegroundWindow(hwnd);
    shown = mode;
  }

  void hide() {
    if (shown == GaiaMode.window) _windowFrame = _readFrame(_hwnd);
    ShowWindow(_hwnd, SW_HIDE);
    shown = null;
  }

  ({int left, int top, int width, int height}) _frameFor(GaiaMode mode) {
    final saved = _windowFrame;
    if (mode == GaiaMode.window && saved != null) return saved;
    final cursor = calloc<POINT>();
    final info = calloc<MONITORINFO>()..ref.cbSize = sizeOf<MONITORINFO>();
    final dpiX = calloc<Uint32>();
    final dpiY = calloc<Uint32>();
    try {
      GetCursorPos(cursor);
      final monitor = MonitorFromPoint(cursor.ref, MONITOR_DEFAULTTONEAREST);
      GetMonitorInfo(monitor, info);
      GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, dpiX, dpiY);
      final scale = dpiX.value / 96;
      final work = info.ref.rcWork;
      final workWidth = work.right - work.left;
      final workHeight = work.bottom - work.top;
      final size = switch (mode) {
        GaiaMode.small => _smallSize,
        GaiaMode.large => _largeSize,
        GaiaMode.window => _windowSize,
      };
      final width = (size.width * scale).round().clamp(1, workWidth);
      final height = (size.height * scale).round().clamp(1, workHeight);
      final left = work.left + (workWidth - width) ~/ 2;
      // The small floater sits in the upper third, out of the way of what
      // the user was looking at; the others are centred.
      final top = mode == GaiaMode.small
          ? work.top + (workHeight - height) ~/ 4
          : work.top + (workHeight - height) ~/ 2;
      return (left: left, top: top, width: width, height: height);
    } finally {
      free(cursor);
      free(info);
      free(dpiX);
      free(dpiY);
    }
  }

  static ({int left, int top, int width, int height}) _readFrame(int hwnd) {
    final rect = calloc<RECT>();
    try {
      GetWindowRect(hwnd, rect);
      return (
        left: rect.ref.left,
        top: rect.ref.top,
        width: rect.ref.right - rect.ref.left,
        height: rect.ref.bottom - rect.ref.top,
      );
    } finally {
      free(rect);
    }
  }

  static void _cloak(int hwnd, bool cloaked) {
    final value = calloc<Int32>()..value = cloaked ? TRUE : FALSE;
    try {
      DwmSetWindowAttribute(hwnd, DWMWA_CLOAK, value, sizeOf<Int32>());
    } finally {
      free(value);
    }
  }

  /// Waits for a frame at the Flutter view's new size, and one more, by the
  /// end of which it has been rasterized. As `FloaterWindow._paintedAt`.
  Future<void> _paintedAt() async {
    final binding = SchedulerBinding.instance;
    final view = binding.platformDispatcher.implicitView;
    final rect = calloc<RECT>();
    final Size size;
    try {
      GetClientRect(GetWindow(_hwnd, GW_CHILD), rect);
      size = Size(
        (rect.ref.right - rect.ref.left).toDouble(),
        (rect.ref.bottom - rect.ref.top).toDouble(),
      );
    } finally {
      free(rect);
    }
    Future<void> frame() {
      binding.scheduleFrame();
      return binding.endOfFrame.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () {},
      );
    }

    final waited = Stopwatch()..start();
    do {
      await frame();
    } while (view != null &&
        view.physicalSize != size &&
        waited.elapsed < const Duration(milliseconds: 500));
    await frame();
  }

  static var _found = 0;

  static int _findOwnWindow() {
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
