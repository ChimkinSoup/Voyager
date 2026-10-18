import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/features/hotkeys/floaters/floater_window.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';
import 'package:voyager/routing/app_router.dart';
import 'package:window_manager/window_manager.dart';

/// The finance floater's window: the width the same form has in the app's
/// modal (see `showVoyagerModal`), and the height it opens at, the form's own.
///
/// The form reports its height and the window follows it, through
/// [FloaterController.setHeight]: the amount's error line and a failed save's
/// message grow the window, and it shrinks back when they go.
/// `finance_floater_fits_form_test.dart` holds this to the real form.
const kFinanceFloaterSize = Size(640, 496);

/// The reminder floater's window: the editor's own width (see
/// [kReminderFormWidth]) and the height it opens at, that of its default form
/// — a daily rule with this device registered.
///
/// The form reports its height and the window follows it, through
/// [FloaterController.setHeight]: a weekly rule's day pills, devices that
/// wrap to another row and the validation line all grow the window.
/// `reminder_floater_fits_form_test.dart` holds this to the real form.
const kReminderFloaterSize = Size(kReminderFormWidth, 493);

/// The calendar floater's window: the width the same panel has in the
/// calendar's popover, and the height it opens at, the panel's for a new
/// all-day event.
///
/// The panel reports its height and the window follows it, through
/// [FloaterController.setHeight]: the empty-title line grows the window, and
/// it shrinks back on the next keystroke. The date picker, the tallest thing
/// the panel opens, fits in the window.
/// `calendar_floater_fits_form_test.dart` holds this to the real panel.
const kCalendarFloaterSize = Size(384, 420.4);

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

  /// False from a floater opening until the window has the main window's
  /// placement back, which is after [active] clears.
  bool get windowAtMainPlacement => _window.atMainPlacement;

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
        QuickCaptureKind.todo => Size(680, 64 + extraHeight),
        QuickCaptureKind.journal => const Size(380, 320),
        QuickCaptureKind.finance => kFinanceFloaterSize,
        QuickCaptureKind.reminder => kReminderFloaterSize,
        QuickCaptureKind.calendar => kCalendarFloaterSize,
      };

  /// The finance, reminder and calendar forms report their height; the todo
  /// bar and the notepad are sized by [_sizeFor] alone.
  Future<void> Function()? _fitFor(QuickCaptureKind kind) => switch (kind) {
    QuickCaptureKind.todo || QuickCaptureKind.journal => null,
    QuickCaptureKind.finance ||
    QuickCaptureKind.reminder ||
    QuickCaptureKind.calendar => _fitHeight,
  };

  static FloaterAnchor _anchorFor(QuickCaptureKind kind) => switch (kind) {
    QuickCaptureKind.todo => FloaterAnchor.upperCenter,
    QuickCaptureKind.journal => FloaterAnchor.bottomRight,
    QuickCaptureKind.finance => FloaterAnchor.center,
    QuickCaptureKind.reminder => FloaterAnchor.center,
    QuickCaptureKind.calendar => FloaterAnchor.center,
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
    // A floater opened mid-restore would load, and save back, rows the
    // restore is about to replace.
    if (PendingFlushRegistry.instance.restoring) return;
    if (_active == kind) return;
    if (_active != null) {
      await _runFlush();
      _releaseFloaterFocus();
      await _window.show(
        _sizeFor(kind, 0),
        _anchorFor(kind),
        onShow: () {
          _active = kind;
          _height = null;
          notifyListeners();
        },
        fit: _fitFor(kind),
      );
      return;
    }
    if (_window.mainWindowOpen) {
      await _openInApp(kind);
      return;
    }
    _mainFocus = FocusManager.instance.primaryFocus;
    _armed = false;
    await _window.show(
      _sizeFor(kind, 0),
      _anchorFor(kind),
      onShow: () {
        _active = kind;
        _height = null;
        notifyListeners();
        mainContentOnScreen.value = false;
      },
      fit: _fitFor(kind),
    );
  });

  /// Closes the floater, keeping its draft.
  Future<void> dismiss() => _serial(() => _dismiss(showMain: false));

  /// The floater's icon: closes the floater and takes its capture into the
  /// main window. The page switch happens first, while the app is still
  /// hidden behind the floater, so the window comes back already on it. The
  /// journal's entry is created and opened then too, after the notepad's flush
  /// so it opens with what was typed there.
  Future<void> openApp() => _serial(() async {
    final kind = _active;
    if (kind == null) return;
    final closing = await _navigateTo(kind);
    final journal = kind == QuickCaptureKind.journal;
    if (journal) {
      await _runFlush();
      final request = QuickCaptureRequest.fromNotepad(offscreen: true);
      _ref.read(quickCaptureRequestProvider.notifier).state = request;
      await _bounded(request.handled!.future);
    }
    // Its flush is the notepad's last save, taking anything typed since the
    // one above; the follow-up request has the page take that text up.
    await _dismiss(showMain: true);
    await _request(
      journal
          ? QuickCaptureRequest.fromNotepad(offscreen: false)
          : QuickCaptureRequest(kind),
      closing,
    );
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
      // For [windowAtMainPlacement], when that restored a placement owed.
      notifyListeners();
    }
    mainContentOnScreen.value = true;
  });

  /// For content that needs more room than the floater's own height — the
  /// todo bar's date and list pickers.
  ///
  /// Completes once the window has been painted at its new size.
  Future<void> setExtraHeight(double extraHeight) async {
    final kind = _active;
    if (kind == null) return;
    await _window.resize(_sizeFor(kind, extraHeight), _anchorFor(kind));
  }

  /// Sizes the window to a form's height, which the finance, reminder and
  /// calendar floaters report as it changes. The height reported as the
  /// floater opens is applied before the window is on screen (see
  /// [FloaterWindow.show]). Each resize takes the latest height reported, so
  /// a height the form only passed through as it built is never shown.
  Future<void> setHeight(double height) {
    _height = height;
    return _serial(_fitHeight);
  }

  double? _height;

  Future<void> _fitHeight() async {
    final kind = _active;
    final height = _height;
    _height = null;
    if (kind == null || height == null) return;
    await _window.resize(
      Size(_sizeFor(kind, 0).width, height),
      _anchorFor(kind),
    );
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
    _armed = false;
    // The app goes back in place of the floater only as the window returns
    // to its own placement: any sooner, and the floater-sized window shows a
    // corner of the app for the frames in between.
    await _window.release(
      showMain: showMain,
      onRestore: () {
        _active = null;
        _confirmation = null;
        notifyListeners();
      },
    );
    // For [windowAtMainPlacement].
    notifyListeners();
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

  Future<void> _openInApp(QuickCaptureKind kind) async =>
      _request(QuickCaptureRequest(kind), await _navigateTo(kind));

  /// Closes any sheets and dialogs over the app — they would otherwise stay on
  /// top of the page the hotkey opens — and switches to [kind]'s page without
  /// the shell's crossfade (see [instantShellBranchSwitch]). A kind no page
  /// owns stays where it is and only clears the modals. Returns the closing
  /// modals' completions.
  Future<List<Future<Object?>>> _navigateTo(QuickCaptureKind kind) async {
    final router = _ref.read(routerProvider);
    final closing = <Future<Object?>>[];
    final navigator = router.routerDelegate.navigatorKey.currentState;
    if (_active == null) {
      navigator?.popUntil((route) {
        if (route.settings is Page) return true;
        if (route is TransitionRoute) closing.add(route.completed);
        return false;
      });
    } else if (navigator != null) {
      // Behind a floater the app's tickers are stopped, so a popped sheet
      // would only play its closing animation once the window was back. Taken
      // off at once instead, still disposed, so a sheet's draft comes back.
      while (true) {
        Route<dynamic>? top;
        navigator.popUntil((route) {
          top = route;
          return true;
        });
        final route = top;
        if (route == null || route.settings is Page) break;
        if (route is TransitionRoute) closing.add(route.completed);
        navigator.removeRoute(route);
      }
    }
    final path = kind.path;
    if (path == null) return closing;
    instantShellBranchSwitch = true;
    try {
      router.go(path);
      await _arrivedAt(router, path);
      await _bounded(WidgetsBinding.instance.endOfFrame);
    } finally {
      instantShellBranchSwitch = false;
    }
    return closing;
  }

  /// Hands [request] to its page, once the modals [_navigateTo] closed have
  /// unmounted, since a transaction sheet hands its draft back from
  /// `dispose`, and once the shell has switched to the page, since that
  /// switch unfocuses whatever the page focused before it.
  Future<void> _request(
    QuickCaptureRequest request,
    List<Future<Object?>> closing,
  ) async {
    await _bounded(Future.wait(closing));
    await _bounded(WidgetsBinding.instance.endOfFrame);
    _ref.read(quickCaptureRequestProvider.notifier).state = request;
  }

  /// Caps a wait on route animations and frames, which stall while the
  /// window produces no frames.
  static Future<void> _bounded(Future<Object?> future) => future
      .then<void>((_) {})
      .timeout(const Duration(seconds: 1), onTimeout: () {});

  static Future<void> _arrivedAt(GoRouter router, String path) async {
    final delegate = router.routerDelegate;
    bool arrived() => delegate.currentConfiguration.uri.path == path;
    if (arrived()) return;
    final done = Completer<void>();
    void check() {
      if (arrived() && !done.isCompleted) done.complete();
    }

    delegate.addListener(check);
    try {
      await _bounded(done.future);
    } finally {
      delegate.removeListener(check);
    }
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
