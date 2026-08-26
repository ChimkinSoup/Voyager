import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/glass_button.dart';

/// A button on a toast: something the user can do about what the toast just
/// told them, instead of having to go find the control themselves.
class LeetCodeToastAction {
  const LeetCodeToastAction({required this.label, required this.onPressed});

  final String label;

  /// Runs before the toast dismisses itself.
  final VoidCallback onPressed;
}

/// Shows a sleek, non-intrusive toast at the top of the screen — while the
/// Track button's public API fetch is in flight, or to confirm a one-shot
/// action. Returns a callback that dismisses it (fades out, then removes the
/// overlay entry).
///
/// Leads with a spinner unless [icon] is given, which is what separates
/// "still working" from "done".
///
/// [actions] turn the toast into something the pointer can reach: without them
/// it stays click-through, so a toast over a form never eats a click meant for
/// the field behind it.
///
/// [dwell] auto-dismisses the toast after that long. The countdown is held
/// while the pointer is over the toast — an offer the user is still reading is
/// not one to take away — and restarts with [linger] once they move off, which
/// is deliberately long enough to finish the sentence they were on rather than
/// a token grace period.
VoidCallback showLeetCodeToast(
  BuildContext context, {
  required String message,
  IconData? icon,
  List<LeetCodeToastAction> actions = const [],
  Duration? dwell,
  Duration linger = const Duration(seconds: 4),
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final dismissRequested = ValueNotifier<bool>(false);

  late final OverlayEntry entry;

  var dismissed = false;
  void dismiss() {
    if (dismissed) return;
    dismissed = true;
    // Dismissed before the toast ever built — an overlay entry builds on the
    // next frame, and a fetch that fails on a host lookup settles well inside
    // that gap. There is no State yet to hear the notifier, so nothing would
    // ever call `entry.remove()` and the toast would be pinned on screen for
    // the life of the app. Take the entry out directly instead of animating.
    if (!entry.mounted) {
      entry.remove();
      dismissRequested.dispose();
      return;
    }
    dismissRequested.value = true;
  }

  entry = OverlayEntry(
    builder: (context) => _LeetCodeToast(
      message: message,
      icon: icon,
      actions: actions,
      dwell: dwell,
      linger: linger,
      onDismissRequested: dismiss,
      dismissRequested: dismissRequested,
      onDismissed: () {
        entry.remove();
        dismissRequested.dispose();
      },
    ),
  );

  overlay.insert(entry);

  return dismiss;
}

class _LeetCodeToast extends StatefulWidget {
  const _LeetCodeToast({
    required this.message,
    required this.icon,
    required this.actions,
    required this.dwell,
    required this.linger,
    required this.onDismissRequested,
    required this.dismissRequested,
    required this.onDismissed,
  });

  final String message;
  final IconData? icon;
  final List<LeetCodeToastAction> actions;
  final Duration? dwell;
  final Duration linger;
  final VoidCallback onDismissRequested;
  final ValueNotifier<bool> dismissRequested;
  final VoidCallback onDismissed;

  @override
  State<_LeetCodeToast> createState() => _LeetCodeToastState();
}

class _LeetCodeToastState extends State<_LeetCodeToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _dwellTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..forward();
    widget.dismissRequested.addListener(_handleDismissRequested);
    // A listener only hears *changes*, so a flag already set before this build
    // would otherwise go unheard. Off a post-frame callback because
    // `onDismissed` removes the overlay entry, which must not run during
    // build.
    if (widget.dismissRequested.value) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _handleDismissRequested(),
      );
    }
    // The full dwell, always — a toast raised by another toast's button starts
    // its own clock here rather than inheriting what was left of the one it
    // replaced, and the hover it is born under then holds that clock.
    _restartDwell(widget.dwell);
  }

  void _restartDwell(Duration? after) {
    _dwellTimer?.cancel();
    if (after == null) return;
    _dwellTimer = Timer(after, widget.onDismissRequested);
  }

  void _handleHover(bool hovering) {
    if (widget.dwell == null) return;
    _restartDwell(hovering ? null : widget.linger);
  }

  void _handleDismissRequested() {
    if (!widget.dismissRequested.value) return;
    _dwellTimer?.cancel();
    _controller.reverse().whenCompleteOrCancel(widget.onDismissed);
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    widget.dismissRequested.removeListener(_handleDismissRequested);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduced = VoyagerMotion.reduced(context);
    final interactive = widget.actions.isNotEmpty;

    Widget card = Material(
      color: theme.colorScheme.surfaceContainerHighest,
      elevation: 4,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 10, interactive ? 10 : 16, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: widget.icon == null
                  ? CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    )
                  : Icon(
                      widget.icon,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                widget.message,
                style: theme.textTheme.labelLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            for (final action in widget.actions) ...[
              // Wide enough that the button reads as its own object rather
              // than as the end of the sentence next to it.
              const SizedBox(width: 16),
              GlassButton(
                onPressed: () {
                  action.onPressed();
                  widget.onDismissRequested();
                },
                label: action.label,
                dense: true,
                color: theme.colorScheme.primary,
                textColor: theme.colorScheme.primary,
              ),
            ],
          ],
        ),
      ),
    );

    if (interactive) {
      card = MouseRegion(
        onEnter: (_) => _handleHover(true),
        onExit: (_) => _handleHover(false),
        child: card,
      );
    }

    Widget body = Center(
      child: ConstrainedBox(
        // The sheet under this toast runs nearly the full window; a long
        // message plus a button has to wrap the ellipsis rather than the edge.
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - 32,
        ),
        child: FadeTransition(
          opacity: _controller,
          child: SlideTransition(
            position:
                Tween<Offset>(
                  begin: reduced ? Offset.zero : const Offset(0, -0.3),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(
                    parent: _controller,
                    curve: reduced ? Curves.easeOut : VoyagerSpring.moveCurve,
                  ),
                ),
            child: card,
          ),
        ),
      ),
    );

    // A toast with nothing to press stays out of the way entirely.
    if (!interactive) body = IgnorePointer(child: body);

    return Positioned(
      top: MediaQuery.paddingOf(context).top + 8,
      left: 0,
      right: 0,
      child: body,
    );
  }
}
