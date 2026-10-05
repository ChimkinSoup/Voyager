import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Whether a popup route — a dialog, a popover, a menu — is open on any of
/// the app's navigators. The due-reminder stickies, which sit above every
/// navigator, step aside while one is (BUG-041).
ValueListenable<bool> get popupRouteOpen => _popupRouteOpen;
final _popupRouteOpen = ValueNotifier<bool>(false);
final _open = <Route<dynamic>>{};

/// Counts popups opened, so a listener also hears about one opened over
/// another, which leaves [popupRouteOpen] as it was.
ValueListenable<int> get popupRoutePushes => _popupRoutePushes;
final _popupRoutePushes = ValueNotifier<int>(0);
var _pushes = 0;

/// Feeds [popupRouteOpen]. The app opens popups on three levels of navigator
/// — dialogs on the root, the Inbox on the shell's, a page's popovers on its
/// branch's — and an observer can only be attached to one navigator at a
/// time, so each gets its own instance.
class PopupRouteObserver extends NavigatorObserver {
  /// Forgets every popup: a new router's navigators replace the old ones
  /// without popping what was open on them.
  static void reset() {
    _open.clear();
    _publish();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      _open.add(route);
      _pushes++;
    }
    _publish();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _open.remove(route);
    _publish();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _open.remove(route);
    _publish();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _open.remove(oldRoute);
    if (newRoute is PopupRoute) {
      _open.add(newRoute);
      _pushes++;
    }
    _publish();
  }
}

/// Same as [ModalScrimObserver]'s: a navigator reports routes from inside
/// build, and the stickies listening here are not below it.
void _publish() {
  if (SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _popupRouteOpen.value = _open.isNotEmpty;
      _popupRoutePushes.value = _pushes;
    });
  } else {
    _popupRouteOpen.value = _open.isNotEmpty;
    _popupRoutePushes.value = _pushes;
  }
}
