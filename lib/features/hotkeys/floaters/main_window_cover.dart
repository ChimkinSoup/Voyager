import 'dart:async';

import 'package:flutter/services.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/features/hotkeys/floaters/floater_window.dart';
import 'package:window_manager/window_manager.dart';

/// Keeps [mainWindowCovered] current. Windows says nothing to a window when
/// another covers it, so while the main window is out of focus the runner
/// hooks every app's windows being shown, hidden, moved, minimised or brought
/// to the front, and each time this rechecks ([FloaterWindow
/// .mainWindowCoveredNow]). In focus is in front, so uncovered, and nothing
/// is hooked.
class MainWindowCoverWatch with WindowListener {
  MainWindowCoverWatch._();

  static const _channel = MethodChannel('voyager/cover');

  /// For the app's lifetime. Desktop window chrome only.
  static void install() {
    final watch = MainWindowCoverWatch._();
    windowManager.addListener(watch);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') watch._schedule();
    });
    // Last of all when a floater gives the window back, so a check comes
    // after its final placement whether or not the hook saw it.
    mainContentOnScreen.addListener(() {
      if (watch._watching) watch._schedule();
    });
    // Out of focus already, no blur comes to start it.
    unawaited(
      windowManager.isFocused().then((focused) {
        if (!focused) watch.onWindowBlur();
      }),
    );
  }

  Timer? _check;

  /// Out of focus: the hook is on and checks run.
  var _watching = false;

  /// At most ten checks a second: a window dragged across the screen moves
  /// on every frame.
  void _schedule() {
    _check ??= Timer(const Duration(milliseconds: 100), () {
      _check = null;
      mainWindowCovered.value = FloaterWindow.instance.mainWindowCoveredNow;
    });
  }

  @override
  void onWindowFocus() {
    _watching = false;
    unawaited(_channel.invokeMethod<void>('watch', false));
    _check?.cancel();
    _check = null;
    mainWindowCovered.value = false;
  }

  @override
  void onWindowBlur() {
    _watching = true;
    unawaited(_channel.invokeMethod<void>('watch', true));
    _schedule();
  }
}
