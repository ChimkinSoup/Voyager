import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:window_manager/window_manager.dart';

var _desktopWindowConfigured = false;

/// The main window's minimum size. Lifted while a hotkey floater borrows the
/// window, which is far smaller than this.
const kMainWindowMinimumSize = Size(720, 520);

/// False while the app's pages cannot be seen even though the window may be:
/// hidden to the tray, or lent to a hotkey floater. Window-level signals miss
/// both — a hidden window reports no lifecycle change on Windows.
final mainContentOnScreen = ValueNotifier<bool>(true);

/// Set by a start hidden in the tray, where the window has never been shown:
/// its first reveal maximizes it, as a normal launch does.
var maximizeOnFirstShow = false;

/// The tray's Quit, for anything else that has to close the app outright.
/// Set by the app shell once it has a tray to dispose; null where there is no
/// desktop window.
Future<void> Function()? quitApp;

final _windowReady = Completer<void>();

/// Completes once [configureDesktopWindow] has applied the window's options.
/// They are set a call at a time after startup, and would resize and recenter
/// a floater shown before they finish.
Future<void> get desktopWindowReady => _windowReady.future;

/// True when frameless chrome is active (Windows + [configureDesktopWindow] succeeded).
bool get desktopWindowChromeActive => isWindows && _desktopWindowConfigured;

/// [startHidden] leaves the window hidden in the tray (see [kStartHiddenArg]).
/// The runner skips its first-frame show for the same argument.
Future<void> configureDesktopWindow({required bool startHidden}) async {
  if (!isWindows) return;

  try {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: kMainWindowMinimumSize,
      center: true,
      title: 'Voyager',
      titleBarStyle: TitleBarStyle.hidden,
    );

    if (startHidden) {
      mainContentOnScreen.value = false;
      maximizeOnFirstShow = true;
    }
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (!startHidden) {
        await windowManager.show();
        await windowManager.maximize();
        await windowManager.focus();
      }
      await windowManager.setPreventClose(true);
      _windowReady.complete();
    });

    _desktopWindowConfigured = true;
  } on MissingPluginException catch (error, stackTrace) {
    _desktopWindowConfigured = false;
    _windowReady.complete();
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'desktop_window',
        context: ErrorDescription(
          'window_manager is not available. Stop the app completely, then run '
          '`flutter run -d windows` (hot restart cannot load new native plugins).',
        ),
      ),
    );
  }
}
