import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';

/// Shows a sleek, non-intrusive loading toast at the top of the screen while
/// the Track button's public API fetch is in flight. Returns a callback that
/// dismisses it (fades out, then removes the overlay entry).
VoidCallback showLeetCodeLoadingToast(BuildContext context, {required String message}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final dismissRequested = ValueNotifier<bool>(false);

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _LeetCodeToast(
      message: message,
      dismissRequested: dismissRequested,
      onDismissed: () => entry.remove(),
    ),
  );

  overlay.insert(entry);

  var dismissed = false;
  return () {
    if (dismissed) return;
    dismissed = true;
    dismissRequested.value = true;
  };
}

class _LeetCodeToast extends StatefulWidget {
  const _LeetCodeToast({
    required this.message,
    required this.dismissRequested,
    required this.onDismissed,
  });

  final String message;
  final ValueNotifier<bool> dismissRequested;
  final VoidCallback onDismissed;

  @override
  State<_LeetCodeToast> createState() => _LeetCodeToastState();
}

class _LeetCodeToastState extends State<_LeetCodeToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..forward();
    widget.dismissRequested.addListener(_handleDismissRequested);
  }

  void _handleDismissRequested() {
    if (!widget.dismissRequested.value) return;
    _controller.reverse().whenCompleteOrCancel(widget.onDismissed);
  }

  @override
  void dispose() {
    widget.dismissRequested.removeListener(_handleDismissRequested);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduced = VoyagerMotion.reduced(context);
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 8,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: _controller,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: reduced ? Offset.zero : const Offset(0, -0.3),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: _controller,
                curve: reduced ? Curves.easeOut : VoyagerSpring.moveCurve,
              )),
              child: Material(
                color: theme.colorScheme.surfaceContainerHighest,
                elevation: 4,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(widget.message, style: theme.textTheme.labelLarge),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
