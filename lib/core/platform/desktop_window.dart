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

/// True when frameless chrome is active (Windows + [configureDesktopWindow] succeeded).
bool get desktopWindowChromeActive => isWindows && _desktopWindowConfigured;

Future<void> configureDesktopWindow() async {
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

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.maximize();
      await windowManager.focus();
      await windowManager.setPreventClose(true);
    });

    _desktopWindowConfigured = true;
  } on MissingPluginException catch (error, stackTrace) {
    _desktopWindowConfigured = false;
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
