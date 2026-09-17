import 'package:tray_manager/tray_manager.dart';

/// The notification-area icon that keeps Voyager reachable while its window
/// is hidden — which is also what keeps the global hotkeys alive.
class AppTray with TrayListener {
  AppTray({required this.onOpen, required this.onQuit});

  final Future<void> Function() onOpen;
  final Future<void> Function() onQuit;

  static const _openKey = 'open';
  static const _quitKey = 'quit';

  Future<void> install() async {
    trayManager.addListener(this);
    await trayManager.setIcon('assets/app_icon.ico');
    await trayManager.setToolTip('Voyager');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: _openKey, label: 'Open Voyager'),
          MenuItem.separator(),
          MenuItem(key: _quitKey, label: 'Quit'),
        ],
      ),
    );
  }

  Future<void> dispose() async {
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
    switch (menuItem.key) {
      case _openKey:
        onOpen();
      case _quitKey:
        onQuit();
    }
  }
}
