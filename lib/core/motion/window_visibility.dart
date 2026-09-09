import 'package:flutter/widgets.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:window_manager/window_manager.dart';

/// Pauses a self-driven animation while the window is not on screen.
///
/// The animated backgrounds advance themselves from a [Timer] rather than a
/// [Ticker], so that they redraw at ~60fps instead of the display's native
/// refresh rate — see `petal_field.dart` or `geometric_texture.dart` for that
/// reasoning. What the swap silently gave up is the other half of a Ticker's
/// contract: a Ticker is muted when the engine stops presenting frames, and a
/// Timer is not. Minimised, the background kept advancing its simulation and
/// marking itself dirty sixty times a second, and every one of those scheduled
/// a frame — so the whole build/layout/paint pipeline stayed awake for a
/// window nobody could see. Measured on Windows at ~40% of a core, *unchanged*
/// by minimising, before this existed.
///
/// Two signals, because neither one covers the platform on its own:
///
/// * [AppLifecycleListener] is the portable one, and the only one on mobile.
///   On Windows it is not enough: the embedder only ever reports `inactive`
///   and `resumed` there — minimising the window (and even `ShowWindow(HIDE)`)
///   produces no `hidden` at all. Verified against a running build.
/// * [WindowListener] is what actually fires on a Windows minimise, and the
///   app already depends on `window_manager` for its frameless chrome.
///
/// [AppLifecycleState.inactive] deliberately still counts as visible. On
/// desktop it means only that the window lost focus, and a background that
/// froze the moment another window was clicked would sit visibly stuck beside
/// it. Only the states where there is nothing to look at stop the clock.
mixin WindowVisibility<T extends StatefulWidget> on State<T>
    implements WindowListener {
  AppLifecycleListener? _lifecycle;

  var _lifecycleVisible = _isVisible(WidgetsBinding.instance.lifecycleState);
  var _minimized = false;

  /// Whether the window is on screen. Gate the animation's timer on this.
  bool get windowVisible => _lifecycleVisible && !_minimized;

  /// Called when [windowVisible] flips. Start or stop the timer here.
  @protected
  void onWindowVisibilityChanged();

  static bool _isVisible(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _handleLifecycleState);
    if (desktopWindowChromeActive) {
      windowManager.addListener(this);
    }
  }

  void _handleLifecycleState(AppLifecycleState state) {
    _update(() => _lifecycleVisible = _isVisible(state));
  }

  @override
  void onWindowMinimize() => _update(() => _minimized = true);

  // All three of these mean the window is back on screen, and which one
  // arrives depends on the state it was in before it was minimised: a window
  // that was maximised comes back as `maximize`, not as `restore`. Listening
  // for `restore` alone left the background frozen for the rest of the
  // session after one minimise — this app maximises itself at startup, so
  // that was the common path, not the corner.
  //
  // Deliberately not `resize`, which Windows also fires *while* minimising.
  @override
  void onWindowRestore() => _update(() => _minimized = false);

  @override
  void onWindowMaximize() => _update(() => _minimized = false);

  @override
  void onWindowUnmaximize() => _update(() => _minimized = false);

  void _update(void Function() apply) {
    final before = windowVisible;
    apply();
    if (windowVisible != before) onWindowVisibilityChanged();
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _lifecycle = null;
    if (desktopWindowChromeActive) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  // The rest of [WindowListener]. Only minimise and restore say anything about
  // whether there are pixels to draw; the others are deliberately inert.
  @override
  void onWindowClose() {}
  @override
  void onWindowFocus() {}
  @override
  void onWindowBlur() {}
  @override
  void onWindowResize() {}
  @override
  void onWindowResized() {}
  @override
  void onWindowMove() {}
  @override
  void onWindowMoved() {}
  @override
  void onWindowEnterFullScreen() {}
  @override
  void onWindowLeaveFullScreen() {}
  @override
  void onWindowDocked() {}
  @override
  void onWindowUndocked() {}
  @override
  void onWindowEvent(String eventName) {}
}
