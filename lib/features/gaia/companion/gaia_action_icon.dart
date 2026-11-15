import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';

/// Around each [GaiaActionIcon]'s icon in its button.
const kGaiaActionIconPadding = 8.0;

const _iconSize = 16.0;

/// A [GaiaActionIcon]'s height and width.
const kGaiaActionIconExtent = _iconSize + 2 * kGaiaActionIconPadding;

/// Gaia's quiet icon button: faint, brightening over a soft fill under the
/// cursor. The icons under a hovered message, and wherever a button repeats
/// down a list, where a ring of light on each would be noise.
class GaiaActionIcon extends StatefulWidget {
  const GaiaActionIcon({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.compact = false,
  });

  /// Its tooltip.
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  /// 24 square rather than [kGaiaActionIconExtent], for a list's row.
  final bool compact;

  @override
  State<GaiaActionIcon> createState() => _GaiaActionIconState();
}

class _GaiaActionIconState extends State<GaiaActionIcon> {
  var _hovered = false;

  /// Reached with Tab, and pressed with Enter or Space.
  var _focused = false;

  @override
  Widget build(BuildContext context) {
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
            duration: GaiaMotion.quick,
            // Less its edge's pixel.
            padding: EdgeInsets.all(
              (widget.compact ? 4 : kGaiaActionIconPadding) - 1,
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: lit ? 0.06 : 0),
              borderRadius: BorderRadius.circular(GaiaRadius.chip),
              // Tabbed to, it's edged too: the fill alone is easy to miss.
              border: Border.all(
                color: Colors.white.withValues(alpha: _focused ? 0.3 : 0),
              ),
            ),
            child: Icon(
              widget.icon,
              size: _iconSize,
              color: lit ? GaiaInk.bright : GaiaInk.faint,
            ),
          ),
        ),
      ),
    );
  }
}
