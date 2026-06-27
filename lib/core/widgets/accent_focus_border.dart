import 'package:flutter/material.dart';

/// Animated border and glow shown when a text field receives focus.
class AccentFocusBorder extends StatefulWidget {
  const AccentFocusBorder({
    super.key,
    required this.focusNode,
    required this.accentColor,
    required this.child,
    this.borderRadius = 18,
    this.borderWidth = 1.8,
  });

  final FocusNode focusNode;
  final Color accentColor;
  final Widget child;
  final double borderRadius;
  final double borderWidth;

  @override
  State<AccentFocusBorder> createState() => _AccentFocusBorderState();
}

class _AccentFocusBorderState extends State<AccentFocusBorder> {
  var _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocusChanged);
    _focused = widget.focusNode.hasFocus;
  }

  @override
  void didUpdateWidget(covariant AccentFocusBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChanged);
      widget.focusNode.addListener(_handleFocusChanged);
      _focused = widget.focusNode.hasFocus;
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChanged);
    super.dispose();
  }

  void _handleFocusChanged() {
    final focused = widget.focusNode.hasFocus;
    if (_focused == focused) return;
    setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fillColor =
        theme.inputDecorationTheme.fillColor ?? theme.colorScheme.surface;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(
          color: _focused
              ? widget.accentColor.withValues(alpha: 0.95)
              : theme.dividerColor,
          width: widget.borderWidth,
        ),
        boxShadow: [
          if (_focused)
            BoxShadow(
              color: widget.accentColor.withValues(alpha: 0.14),
              blurRadius: 14,
              spreadRadius: 1,
            ),
        ],
      ),
      child: widget.child,
    );
  }
}
