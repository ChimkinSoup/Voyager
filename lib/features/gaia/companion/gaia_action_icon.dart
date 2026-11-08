import 'package:flutter/material.dart';

/// Around each [GaiaActionIcon]'s icon in its button.
const kGaiaActionIconPadding = 8.0;

const _iconSize = 16.0;

/// A [GaiaActionIcon]'s height and width.
const kGaiaActionIconExtent = _iconSize + 2 * kGaiaActionIconPadding;

/// One of the icons under a hovered message: faint, brightening under the
/// cursor.
class GaiaActionIcon extends StatefulWidget {
  const GaiaActionIcon({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<GaiaActionIcon> createState() => _GaiaActionIconState();
}

class _GaiaActionIconState extends State<GaiaActionIcon> {
  var _hovered = false;

  /// Reached with Tab, and pressed with Enter or Space.
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final lit = _hovered || _focused;
    return Tooltip(
      message: widget.label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => widget.onPressed(),
          ),
        },
        onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(kGaiaActionIconPadding),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: lit ? 0.06 : 0),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: _iconSize,
              color: color.withValues(alpha: lit ? 1 : 0.55),
            ),
          ),
        ),
      ),
    );
  }
}
