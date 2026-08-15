import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:window_manager/window_manager.dart';

/// Keeps the caret (or range) in a single-line field across an OS app switch.
///
/// Desktop [EditableText] defaults [selectAllOnFocus] to true so Tabbing into
/// a one-line box selects everything — that convention stays. What this undoes
/// is the same select-all when the field is only being re-focused because the
/// window came back (Alt-Tab, task switcher, etc.).
///
/// Flutter's own `_justResumed` flag is supposed to cover the lifecycle path,
/// but window-focus races (and any second focus after resume) can still land
/// a full selection. This guard snapshots the selection when the app leaves
/// the foreground and restores it if the field comes back select-all'd.
class PreserveSelectionOnAppResume with WindowListener {
  PreserveSelectionOnAppResume();

  AppLifecycleListener? _lifecycle;
  TextEditingController? _controller;
  TextSelection? _saved;

  /// True between leave-foreground and the restore pass finishing. While set,
  /// focus notifications must not drop [_controller]/[_saved] — FocusManager
  /// parks primary focus on the root scope (and window blur can unfocus) before
  /// we have restored.
  bool _away = false;
  bool _installed = false;

  /// Start listening. Safe to call once from app startup.
  void install() {
    if (_installed) return;
    _installed = true;
    FocusManager.instance.addListener(_handleFocusChange);
    _lifecycle = AppLifecycleListener(
      onInactive: _handleLeaveForeground,
      onResume: _handleReturnToForeground,
    );
    if (desktopWindowChromeActive) {
      windowManager.addListener(this);
    }
    // Pick up a field that already has focus (e.g. autofocus on first frame).
    _handleFocusChange();
  }

  void dispose() {
    if (!_installed) return;
    _installed = false;
    FocusManager.instance.removeListener(_handleFocusChange);
    _lifecycle?.dispose();
    _lifecycle = null;
    if (desktopWindowChromeActive) {
      windowManager.removeListener(this);
    }
    _controller = null;
    _saved = null;
    _away = false;
  }

  @override
  void onWindowBlur() => _handleLeaveForeground();

  @override
  void onWindowFocus() => _handleReturnToForeground();

  void _handleFocusChange() {
    // While the app is away, FocusManager parks primary focus on the root
    // scope — that must not clear the controller we are protecting.
    if (_away || _appIsBackgrounded) return;

    final editable = _focusedSingleLineEditable();
    final next = editable?.widget.controller;
    if (identical(next, _controller)) return;
    _controller = next;
    // A real focus move (Tab, click) while resumed drops any pending restore.
    _saved = null;
  }

  void _handleLeaveForeground() {
    _away = true;
    final controller =
        _controller ?? _focusedSingleLineEditable()?.widget.controller;
    if (controller == null) return;
    _controller = controller;
    final selection = controller.selection;
    if (!selection.isValid) return;
    // Only snapshot once per away-cycle so a later blur after select-all
    // cannot overwrite the real caret we already captured.
    _saved ??= selection;
  }

  void _handleReturnToForeground() {
    final controller = _controller;
    final saved = _saved;
    if (controller == null || saved == null) {
      // Window-focus can beat the lifecycle resume; stay "away" until the app
      // is actually resumed so a later pass can still restore.
      if (!_appIsBackgrounded) {
        _away = false;
      }
      return;
    }

    // FocusManager restores the suspended node from a microtask queued in its
    // own lifecycle observer (registered before this listener). Scheduling
    // here therefore runs *after* that restore — and after EditableText's
    // select-all-on-focus. A post-frame pass catches any select-all that only
    // appears once a later rebuild (window focus, etc.) re-applies focus.
    scheduleMicrotask(() {
      restoreIfSelectAll(controller, saved);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        restoreIfSelectAll(controller, saved);
        // Window-focus may fire while lifecycle is still inactive; keep the
        // snapshot until we are truly foregrounded again.
        if (_appIsBackgrounded) return;
        _saved = null;
        _away = false;
      });
    });
  }

  /// Visible for tests: undo a full-field selection when [saved] was not one.
  @visibleForTesting
  static void restoreIfSelectAll(
    TextEditingController controller,
    TextSelection saved,
  ) {
    final text = controller.text;
    if (text.isEmpty) return;

    final current = controller.selection;
    if (!current.isValid || current.isCollapsed) return;
    if (current.start != 0 || current.end != text.length) return;

    // User already had everything selected before leaving — leave it alone.
    if (saved.isValid &&
        !saved.isCollapsed &&
        saved.start == 0 &&
        saved.end == text.length) {
      return;
    }

    final max = text.length;
    controller.selection = TextSelection(
      baseOffset: saved.baseOffset.clamp(0, max),
      extentOffset: saved.extentOffset.clamp(0, max),
    );
  }

  static bool get _appIsBackgrounded {
    final state = WidgetsBinding.instance.lifecycleState;
    return state != null && state != AppLifecycleState.resumed;
  }

  static EditableTextState? _focusedSingleLineEditable() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    final editable = context.findAncestorStateOfType<EditableTextState>();
    if (editable == null) return null;
    // Matches EditableText's own selectAllOnFocus gate (`maxLines != 1`).
    if (editable.widget.maxLines != 1) return null;
    return editable;
  }
}
