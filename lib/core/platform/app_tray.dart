import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:voyager/core/platform/dev_profile.dart';

/// The notification-area icon that keeps Voyager reachable while its window
/// is hidden — which is also what keeps the global hotkeys alive.
///
/// With Gaia, it also opens the Gaia window and lists Gaia's runs in
/// progress, each with Stop (GAIA_HLD.md §3.3, §14).
class AppTray with TrayListener {
  AppTray({
    required this.onOpen,
    required this.onQuit,
    this.onOpenGaia,
    this.gaiaRuns,
    this.onStopGaiaRun,
  });

  final Future<void> Function() onOpen;
  final Future<void> Function() onQuit;
  final Future<void> Function()? onOpenGaia;
  final ValueListenable<List<({String chatId, String title})>>? gaiaRuns;
  final Future<void> Function(String chatId)? onStopGaiaRun;

  static const _openKey = 'open';
  static const _openGaiaKey = 'openGaia';
  static const _quitKey = 'quit';
  static const _stopRunPrefix = 'stopRun:';

  Future<void> install() async {
    trayManager.addListener(this);
    await trayManager.setIcon('assets/app_icon.ico');
    await trayManager.setToolTip('Voyager$devProfileSuffix');
    gaiaRuns?.addListener(_setMenu);
    await _setMenu();
  }

  Future<void> _setMenu() async {
    final runs = gaiaRuns?.value ?? const [];
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: _openKey, label: 'Open Voyager'),
          if (onOpenGaia != null)
            MenuItem(key: _openGaiaKey, label: 'Open Gaia'),
          if (runs.isNotEmpty) ...[
            MenuItem.separator(),
            MenuItem(
              label: runs.length == 1
                  ? 'Gaia: 1 run in progress'
                  : 'Gaia: ${runs.length} runs in progress',
              disabled: true,
            ),
            for (final run in runs)
              MenuItem(
                key: '$_stopRunPrefix${run.chatId}',
                label: 'Stop "${run.title}"',
              ),
          ],
          MenuItem.separator(),
          MenuItem(key: _quitKey, label: 'Quit'),
        ],
      ),
    );
  }

  Future<void> dispose() async {
    gaiaRuns?.removeListener(_setMenu);
    trayManager.removeListener(this);
    await trayManager.destroy();
  }

  @override
  void onTrayIconMouseDown() => onOpen();

  @override
  void onTrayIconRightMouseDown() =>
      // Brought to the front first: Windows only dismisses a menu on
      // click-away when its owner window is the foreground window.
      // ignore: deprecated_member_use
      trayManager.popUpContextMenu(bringAppToFront: true);

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key ?? '';
    switch (key) {
      case _openKey:
        onOpen();
      case _openGaiaKey:
        onOpenGaia?.call();
      case _quitKey:
        onQuit();
      default:
        if (key.startsWith(_stopRunPrefix)) {
          onStopGaiaRun?.call(key.substring(_stopRunPrefix.length));
        }
    }
  }
}
