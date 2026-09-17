import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/features/hotkeys/floaters/floater_window.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';
import 'package:voyager/routing/app_router.dart';
import 'package:window_manager/window_manager.dart';

/// Routes global hotkeys and owns the floater lifecycle.
///
/// A hotkey for the floater already open does nothing; a different one
/// replaces it. With no floater open, a focused and visible main window takes
/// the in-app path, and anything else — unfocused, minimized, hidden to the
/// tray — opens the floater. Losing focus dismisses a floater; Esc never does,
/// because Vim needs it.
class FloaterController extends ChangeNotifier with WindowListener {
  FloaterController(this._ref) {
    if (desktopWindowChromeActive) windowManager.addListener(this);
  }

  final Ref _ref;
  final _window = FloaterWindow.instance;

  QuickCaptureKind? get active => _active;
  QuickCaptureKind? _active;

  /// Shown over the floater for a moment after a save, in place of a toast —
  /// the floater is gone before a toast in the main window could be read.
  String? get confirmation => _confirmation;
  String? _confirmation;

  /// Blur only dismisses once the floater has actually had focus, so a blur
  /// still in flight from before it opened can't close it straight away.
  var _armed = false;

  FocusNode? _mainFocus;
  Future<void> Function()? _flush;
  Future<void> _queue = Future<void>.value();

  static Size _sizeFor(QuickCaptureKind kind, double extraHeight) =>
      switch (kind) {
        QuickCaptureKind.todo => Size(680, 68 + extraHeight),
        QuickCaptureKind.journal => const Size(380, 320),
        QuickCaptureKind.finance => const Size(460, 640),
      };

  static FloaterAnchor _anchorFor(QuickCaptureKind kind) => switch (kind) {
    QuickCaptureKind.todo => FloaterAnchor.upperCenter,
    QuickCaptureKind.journal => FloaterAnchor.bottomRight,
    QuickCaptureKind.finance => FloaterAnchor.center,
  };

  /// Operations run one at a time: a blur, a hotkey and a save can all land
  /// inside one window move.
  Future<void> _serial(Future<void> Function() op) {
    final next = _queue.then((_) => op()).catchError((
      Object error,
      StackTrace stack,
    ) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'FloaterController',
        ),
      );
    });
    _queue = next;
    return next;
  }

  Future<void> onHotkey(QuickCaptureKind kind) => _serial(() async {
    if (!_ref.read(authNotifierProvider).isAuthenticated) return;
    if (_active == kind) return;
    if (_active != null) {
      await _runFlush();
      _releaseFloaterFocus();
      _active = kind;
      notifyListeners();
      await _window.show(_sizeFor(kind, 0), _anchorFor(kind));
      return;
    }
    if (_window.mainWindowOpen) {
      _openInApp(kind);
      return;
    }
    _mainFocus = FocusManager.instance.primaryFocus;
    _armed = false;
    _active = kind;
    notifyListeners();
    mainContentOnScreen.value = false;
    await _window.show(_sizeFor(kind, 0), _anchorFor(kind));
  });

  /// Closes the floater, keeping its draft.
  Future<void> dismiss() => _serial(() => _dismiss(showMain: false));

  /// The todo bar's "Open app": closes the floater and takes its capture into
  /// the main window.
  Future<void> openApp() => _serial(() async {
    final kind = _active;
    if (kind == null) return;
    await _dismiss(showMain: true);
    _openInApp(kind);
  });

  /// Shows [message] briefly, then dismisses.
  Future<void> completeWith(String message) => _serial(() async {
    if (_active == null) return;
    _confirmation = message;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 750));
    await _dismiss(showMain: false);
  });

  /// Tray "Open Voyager".
  Future<void> showMainWindow() => _serial(() async {
    if (_active != null) {
      await _dismiss(showMain: true);
    } else {
      await _window.showMain();
    }
    mainContentOnScreen.value = true;
  });

  /// For content that needs more room below the todo bar (its date and list
  /// pickers).
  void setExtraHeight(double extraHeight) {
    final kind = _active;
    if (kind == null) return;
    _window.resize(_sizeFor(kind, extraHeight), _anchorFor(kind));
  }

  /// The open floater's pending-edit flush, run before it is dismissed or
  /// replaced.
  void registerFlush(Future<void> Function() flush) => _flush = flush;

  void unregisterFlush(Future<void> Function() flush) {
    if (identical(_flush, flush)) _flush = null;
  }

  Future<void> _runFlush() async {
    final flush = _flush;
    if (flush == null) return;
    try {
      await flush();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'FloaterController',
          context: ErrorDescription('while flushing a floater'),
        ),
      );
    }
  }

  Future<void> _dismiss({required bool showMain}) async {
    if (_active == null) return;
    await _runFlush();
    _releaseFloaterFocus();
    _active = null;
    _confirmation = null;
    _armed = false;
    notifyListeners();
    await _window.release(showMain: showMain);
    // Hidden again when the floater opened over the tray; a minimized window
    // is covered by WindowVisibility's own minimize tracking.
    mainContentOnScreen.value = await windowManager.isVisible();
    final focus = _mainFocus;
    _mainFocus = null;
    if (!showMain && focus != null) {
      // After the rebuild that lifts ExcludeFocus off the main content.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (focus.context != null) focus.requestFocus();
      });
    }
  }

  /// Unfocuses the floater's field before the floater unmounts. Removed while
  /// still focused, primary focus goes on naming a deactivated element until
  /// the focus manager catches up, and focus listeners that walk up from it
  /// assert.
  void _releaseFloaterFocus() => FocusManager.instance.primaryFocus?.unfocus();

  void _openInApp(QuickCaptureKind kind) {
    _ref.read(routerProvider).go(kind.path);
    _ref.read(quickCaptureRequestProvider.notifier).state = QuickCaptureRequest(
      kind,
    );
  }

  @override
  void onWindowFocus() {
    if (_active != null) _armed = true;
  }

  @override
  void onWindowBlur() {
    if (_active != null && _armed && _confirmation == null) {
      unawaited(dismiss());
    }
  }

  @override
  void dispose() {
    if (desktopWindowChromeActive) windowManager.removeListener(this);
    super.dispose();
  }
}

final floaterControllerProvider = ChangeNotifierProvider<FloaterController>(
  FloaterController.new,
);
