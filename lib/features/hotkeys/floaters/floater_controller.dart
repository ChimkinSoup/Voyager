import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/features/hotkeys/floaters/floater_window.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';
import 'package:voyager/features/notifications/scheduled_reminders_section.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';
import 'package:voyager/routing/app_router.dart';
import 'package:window_manager/window_manager.dart';

/// The finance floater's window: the width the same form has in the app's
/// modal (see `showVoyagerModal`), and the transaction form's own height (506)
/// plus the error line under the amount field (23).
///
/// Its height is sized to the form rather than roomily, so it doesn't open
/// above a band of empty background. The amount's error line has its room
/// reserved rather than resizing the window, because it comes and goes
/// mid-keystroke — every amount under a dollar passes through it — and a
/// window that jumped while being typed into would be worse than the strip it
/// saves. The failed-save line, which is rare and of no height that can be
/// known in advance, does resize the window, through
/// [FloaterController.setExtraHeight].
/// `finance_floater_fits_form_test.dart` holds all of it to the real form.
const kFinanceFloaterSize = Size(640, 529);

/// The reminder floater's window: the editor's own width (see
/// [kReminderFormWidth]) and the height of its default form — a daily rule
/// with this device registered — plus the validation line under it (17).
///
/// Sized to the form rather than roomily, so it doesn't open above a band of
/// empty background. The validation line has its room reserved because it is
/// one Create away in the ordinary course of things and would otherwise push
/// the buttons out of the window. Nothing resizes this window: what grows
/// beyond that — more devices than fit a row — scrolls inside it.
/// `reminder_floater_fits_form_test.dart` holds both figures to the real form.
const kReminderFloaterSize = Size(kReminderFormWidth, 516);

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
        QuickCaptureKind.todo => Size(680, 68 + extraHeight),
        QuickCaptureKind.journal => const Size(380, 320),
        QuickCaptureKind.finance => Size(
          kFinanceFloaterSize.width,
          kFinanceFloaterSize.height + extraHeight,
        ),
        QuickCaptureKind.reminder => kReminderFloaterSize,
      };

  static FloaterAnchor _anchorFor(QuickCaptureKind kind) => switch (kind) {
    QuickCaptureKind.todo => FloaterAnchor.upperCenter,
    QuickCaptureKind.journal => FloaterAnchor.bottomRight,
    QuickCaptureKind.finance => FloaterAnchor.center,
    QuickCaptureKind.reminder => FloaterAnchor.center,
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
      await _window.show(
        _sizeFor(kind, 0),
        _anchorFor(kind),
        onShow: () {
          _active = kind;
          notifyListeners();
        },
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
        notifyListeners();
        mainContentOnScreen.value = false;
      },
    );
  });

  /// Closes the floater, keeping its draft.
  Future<void> dismiss() => _serial(() => _dismiss(showMain: false));

  /// The floater's icon: closes the floater and takes its capture into the
  /// main window. The page switch happens first, while the app is still
  /// hidden behind the floater, so the window comes back already on it.
  Future<void> openApp() => _serial(() async {
    final kind = _active;
    if (kind == null) return;
    final closing = await _navigateTo(kind);
    await _dismiss(showMain: true);
    await _request(kind, closing);
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
  /// todo bar's date and list pickers, the finance form's failed-save line.
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
      _request(kind, await _navigateTo(kind));

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

  /// Hands [kind]'s page its request, once the modals [_navigateTo] closed
  /// have unmounted, since a transaction sheet hands its draft back from
  /// `dispose`, and once the shell has switched to the page, since that
  /// switch unfocuses whatever the page focused before it.
  Future<void> _request(
    QuickCaptureKind kind,
    List<Future<Object?>> closing,
  ) async {
    await _bounded(Future.wait(closing));
    await _bounded(WidgetsBinding.instance.endOfFrame);
    _ref.read(quickCaptureRequestProvider.notifier).state = QuickCaptureRequest(
      kind,
    );
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
