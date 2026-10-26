import 'dart:ffi' hide Size;
import 'dart:ui' show Size;

import 'package:ffi/ffi.dart';
import 'package:flutter/scheduler.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

/// The companion window's modes (GAIA_HLD.md §3.3), the overlay that
/// covers a monitor for a region capture's crop (§3.2), and pick-up mode's
/// "selecting" pill (§15.3).
enum GaiaMode { small, large, window, overlay, pickUp }

/// A window frame in physical pixels.
typedef GaiaFrame = ({int left, int top, int width, int height});

/// Logical sizes. The Gaia window remembers its own once moved or resized.
const _smallSize = Size(560, 460);
const _largeSize = Size(980, 760);
const _windowSize = Size(1200, 820);
const _pickUpSize = Size(460, 48);

/// How far the user can shrink any mode: the Gaia window's sidebar plus a
/// usable chat. No larger than [_smallSize], so it never clamps a mode.
const _minimumSize = Size(560, 360);

/// The companion's one OS window, in whichever mode it's in. Floaters are
/// topmost tool windows, out of the taskbar and Alt+Tab; the Gaia window is
/// an ordinary app window. Raw Win32, like `FloaterWindow`: window_manager
/// can't set tool-window style or place on the monitor under the cursor.
class GaiaWindow {
  int _hwnd = 0;

  /// The mode on screen; null while hidden.
  GaiaMode? shown;

  /// On screen and in front: not behind other apps or minimised.
  bool get foreground => shown != null && GetForegroundWindow() == _hwnd;

  /// Where the Gaia window was when last on screen, so a floater opened
  /// over it can put it back: its frame when not maximised or minimised (in
  /// workspace coordinates, as [GetWindowPlacement] gives them) and whether
  /// it was maximised.
  ({({int left, int top, int width, int height}) frame, bool maximized})?
  _windowPlacement;

  Future<void> init() async {
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setTitle('Gaia');
    // Closing hides; the companion is resident (§3.2).
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(_minimumSize);
    _hwnd = _findOwnWindow();
    // Out of its own screenshots — and the user's screen shares (§3.2).
    SetWindowDisplayAffinity(_hwnd, WDA_EXCLUDEFROMCAPTURE);
  }

  /// Puts the window on screen in [mode]. [layout] swaps the content to
  /// [mode]'s layout; it runs before the resize when the window shrinks, and
  /// after the frame at the new size when it grows, so a grow never shows
  /// the uncovered area black and a shrink never squeezes the old layout.
  /// [GaiaMode.overlay] takes the monitor's [frame]. [GaiaMode.pickUp]
  /// shows without taking the focus, which the user is selecting in.
  Future<void> show(
    GaiaMode mode,
    void Function() layout, {
    GaiaFrame? frame,
  }) async {
    final hwnd = _hwnd;
    final pill = mode == GaiaMode.pickUp;
    // The chat's minimum size would hold the pill at the size of one.
    if (pill != _minimumOff) {
      _minimumOff = pill;
      await windowManager.setMinimumSize(
        pill ? const Size(1, 1) : _minimumSize,
      );
    }
    if (shown == GaiaMode.window) _windowPlacement = _readPlacement(hwnd);
    final placement = mode == GaiaMode.window ? _windowPlacement : null;
    frame ??= placement?.frame ?? _frameFor(mode);
    final old = _readFrame(hwnd);
    // A maximised window fills the work area: no floater is bigger.
    final grows =
        shown == null ||
        (placement?.maximized ?? false) ||
        frame.width * frame.height > old.width * old.height;
    final floater = mode != GaiaMode.window;

    while (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
      await Future<void>(() {});
    }
    _cloak(hwnd, true);
    // SetWindowPos doesn't bring a window out of minimised or maximised; a
    // window minimised from maximised restores to maximised first.
    // SetWindowPlacement does, so a placement skips this.
    for (
      var i = 0;
      placement == null &&
          i < 2 &&
          (IsIconic(hwnd) != 0 || IsZoomed(hwnd) != 0);
      i++
    ) {
      ShowWindow(hwnd, SW_RESTORE);
    }
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
    // Square to the monitor's edges as an overlay; rounded otherwise.
    _setCorners(
      hwnd,
      mode == GaiaMode.overlay ? DWMWCP_DONOTROUND : DWMWCP_DEFAULT,
    );
    if (!grows) layout();
    if (placement != null) {
      _setPlacement(hwnd, placement.frame, placement.maximized);
    }
    if (mode == GaiaMode.overlay) {
      // The monitor is the client area's to cover, for its frame at 1:1:
      // the hidden title bar still leaves resize borders around it.
      final inset = _insets(hwnd);
      frame = (
        left: frame.left - inset.left,
        top: frame.top - inset.top,
        width: frame.width + inset.left + inset.right,
        height: frame.height + inset.top + inset.bottom,
      );
    }
    SetWindowPos(
      hwnd,
      floater ? HWND_TOPMOST : HWND_NOTOPMOST,
      frame.left,
      frame.top,
      frame.width,
      frame.height,
      SWP_SHOWWINDOW |
          SWP_FRAMECHANGED |
          (pill ? SWP_NOACTIVATE : 0) |
          (placement != null ? SWP_NOMOVE | SWP_NOSIZE : 0),
    );
    await _paintedAt();
    if (grows) {
      layout();
      await _paintedAt();
    }
    _cloak(hwnd, false);
    if (!pill) SetForegroundWindow(hwnd);
    shown = mode;
  }

  /// The minimum size is lifted for the pick-up pill.
  var _minimumOff = false;

  void hide() {
    if (shown == GaiaMode.window) _windowPlacement = _readPlacement(_hwnd);
    ShowWindow(_hwnd, SW_HIDE);
    shown = null;
  }

  ({int left, int top, int width, int height}) _frameFor(GaiaMode mode) {
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
        // Always given its monitor's frame.
        GaiaMode.overlay => _largeSize,
        GaiaMode.pickUp => _pickUpSize,
      };
      final width = (size.width * scale).round().clamp(1, workWidth);
      final height = (size.height * scale).round().clamp(1, workHeight);
      final left = work.left + (workWidth - width) ~/ 2;
      // The small floater sits in the upper third, out of the way of what
      // the user was looking at, and the pick-up pill at the very top; the
      // others are centred.
      final top = switch (mode) {
        GaiaMode.small => work.top + (workHeight - height) ~/ 4,
        GaiaMode.pickUp => work.top + (16 * scale).round(),
        _ => work.top + (workHeight - height) ~/ 2,
      };
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

  /// How far inside the window its client area sits, on each side.
  static ({int left, int top, int right, int bottom}) _insets(int hwnd) {
    final window = calloc<RECT>();
    final client = calloc<RECT>();
    final origin = calloc<POINT>();
    try {
      GetWindowRect(hwnd, window);
      GetClientRect(hwnd, client);
      ClientToScreen(hwnd, origin);
      return (
        left: origin.ref.x - window.ref.left,
        top: origin.ref.y - window.ref.top,
        right: window.ref.right - (origin.ref.x + client.ref.right),
        bottom: window.ref.bottom - (origin.ref.y + client.ref.bottom),
      );
    } finally {
      free(window);
      free(client);
      free(origin);
    }
  }

  static ({({int left, int top, int width, int height}) frame, bool maximized})
  _readPlacement(int hwnd) {
    final placement = calloc<WINDOWPLACEMENT>()
      ..ref.length = sizeOf<WINDOWPLACEMENT>();
    try {
      GetWindowPlacement(hwnd, placement);
      final normal = placement.ref.rcNormalPosition;
      return (
        frame: (
          left: normal.left,
          top: normal.top,
          width: normal.right - normal.left,
          height: normal.bottom - normal.top,
        ),
        maximized:
            IsZoomed(hwnd) != 0 ||
            (IsIconic(hwnd) != 0 &&
                placement.ref.flags & WPF_RESTORETOMAXIMIZED != 0),
      );
    } finally {
      free(placement);
    }
  }

  static void _setPlacement(
    int hwnd,
    ({int left, int top, int width, int height}) frame,
    bool maximized,
  ) {
    final placement = calloc<WINDOWPLACEMENT>()
      ..ref.length = sizeOf<WINDOWPLACEMENT>()
      ..ref.showCmd = maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
    placement.ref.rcNormalPosition
      ..left = frame.left
      ..top = frame.top
      ..right = frame.left + frame.width
      ..bottom = frame.top + frame.height;
    try {
      SetWindowPlacement(hwnd, placement);
    } finally {
      free(placement);
    }
  }

  static void _setCorners(int hwnd, int preference) {
    final value = calloc<Int32>()..value = preference;
    try {
      DwmSetWindowAttribute(
        hwnd,
        DWMWA_WINDOW_CORNER_PREFERENCE,
        value,
        sizeOf<Int32>(),
      );
    } finally {
      free(value);
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
