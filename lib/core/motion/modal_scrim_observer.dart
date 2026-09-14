import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Whether a scrimmed modal — a sheet, a dialog, the media lightbox — is open
/// on the root navigator. The animated background stops while it is.
///
/// This is a GPU fix, not a nicety. A glass sheet's [BackdropFilter] re-blurs
/// everything under it on every frame, and the background produces a frame
/// sixty times a second — so an open sheet kept the GPU redoing a window-sized
/// blur for as long as it stayed open. Measured in a profile build with the
/// petal field in a maximised window: 7% GPU with nothing open, 23% under a
/// LeetCode-track-sized sheet, 16% under a finance-transaction-sized one, and
/// under 1% for that same large sheet with the background paused. Behind a
/// scrim and a heavy blur the motion is barely visible anyway.
///
/// Popovers and menus don't count: they have no scrim, they cover little, and
/// a background frozen around them would read as the app hanging.
ValueListenable<bool> get modalScrimOpen => _modalScrimOpen;
final _modalScrimOpen = ValueNotifier<bool>(false);

/// Feeds [modalScrimOpen]. Give each root [Navigator] its own instance — an
/// observer can only be attached to one navigator at a time.
class ModalScrimObserver extends NavigatorObserver {
  final _open = <Route<dynamic>>{};

  static bool _isScrimmed(Route<dynamic> route) =>
      route is ModalRoute &&
      !route.opaque &&
      (route.barrierColor?.a ?? 0) > 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isScrimmed(route)) _open.add(route);
    _publish();
  }

  // A pop is reported as it starts, so the background is already moving again
  // while the sheet slides away.
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
    if (newRoute != null && _isScrimmed(newRoute)) _open.add(newRoute);
    _publish();
  }

  /// A navigator reports its initial and page-driven routes from inside build,
  /// and the background listening here is not below it — notifying then would
  /// mark a widget dirty mid-build. Those land after the frame instead.
  void _publish() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => _modalScrimOpen.value = _open.isNotEmpty,
      );
    } else {
      _modalScrimOpen.value = _open.isNotEmpty;
    }
  }
}
