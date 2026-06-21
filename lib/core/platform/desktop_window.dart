import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:window_manager/window_manager.dart';

var _desktopWindowConfigured = false;

/// True when frameless chrome is active (Windows + [configureDesktopWindow] succeeded).
bool get desktopWindowChromeActive => isWindows && _desktopWindowConfigured;

Future<void> configureDesktopWindow() async {
  if (!isWindows) return;

  try {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(720, 520),
      center: true,
      title: 'Voyager',
      titleBarStyle: TitleBarStyle.hidden,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
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
