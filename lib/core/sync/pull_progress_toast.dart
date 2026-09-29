import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';

/// Shows the startup pull's progress, once it has run long enough to be
/// worth watching.
///
/// A normal launch pulls in a second or two and never raises it. A restore
/// onto an empty device resolves every document's operation log and takes
/// minutes (BUG-002), and without this the app just looks half-empty while it
/// fills in.
class PullProgressToast {
  PullProgressToast(
    this._overlay, {
    Duration delay = const Duration(seconds: 3),
  }) {
    _timer = Timer(delay, _show);
  }

  /// Resolved when the toast is due rather than up front: at launch the
  /// router's navigator may not be built yet.
  final OverlayState? Function() _overlay;
  late final Timer _timer;
  VoyagerToast? _toast;
  var _done = 0;
  var _total = 0;

  static final _count = NumberFormat.decimalPattern();

  /// Matches [RemoteSyncService.pullAll]'s `onProgress`.
  void report(int done, int total) {
    _done = done;
    _total = total;
    _toast?.update(message: _progressMessage);
  }

  /// Turns the spinner into a tick, if the toast is showing at all.
  void complete() {
    _timer.cancel();
    _toast?.update(
      message: 'Restored ${_count.format(_done)} items',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(seconds: 4),
    );
  }

  /// A failed pull reports itself elsewhere; a count that stopped partway
  /// would only claim it is still going.
  void cancel() {
    _timer.cancel();
    _toast?.dismiss();
  }

  void _show() {
    final overlay = _overlay();
    if (overlay == null || !overlay.mounted) return;
    _toast = showVoyagerToastIn(
      overlay,
      message: _progressMessage,
      // Background work: the page the user happens to be on had no part in it.
      origin: 'Sync',
    );
  }

  String get _progressMessage => _total == 0
      ? 'Restoring from the cloud…'
      : 'Restoring from the cloud · ${_count.format(_done)} of '
            '${_count.format(_total)} items';
}
