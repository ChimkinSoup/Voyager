import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';

/// Calmer stand-ins for [GaiaButton]'s circling light. Each starts from
/// Quiet: no edge at rest, a faint fill on hover, labels on a light fill.
/// The tinted ones below Tint differ only in the shape the hover fill takes.
enum _Study {
  quiet(
    'Quiet',
    'No edge at rest: a bare muted icon. Hover lifts a faint fill and '
        'brightens it. The base for everything below.',
  ),
  tint(
    'Tint',
    'Hover fills it with a faint accent tint and colours the icon. No '
        'light, just colour.',
  ),
  pill(
    'Pill, tinted',
    "Tint, but the hover fill rounds into a full pill: an icon's becomes a "
        'circle. The roundest; the rest are shapes short of it.',
  ),
  soft(
    'Soft corners',
    'Tinted, with the corners opening a little on hover: 9 px from 6. '
        'Barely a change of shape, mostly a softening.',
  ),
  rounded(
    'Rounded',
    'Tinted, rounding to about a third of the height on hover: clearly '
        'rounder, still clearly a rectangle. Icons open straight onto the '
        'rounded shape; labels morph into it.',
  ),
  squircle(
    'Squircle',
    'Tinted, easing into smooth continuous corners on hover, as app icons '
        'have: round without looking like a pill.',
  ),
  leaf(
    'Leaf',
    'Tinted, with two opposite corners rounding fully on hover while the '
        'other two stay squared.',
  ),
  bevel(
    'Bevel',
    'Tinted, with the corners cut at an angle on hover instead of rounded: '
        'the one angular shape.',
  );

  const _Study(this.label, this.description);
  final String label, description;

  /// The hover fill's shape, for a button [size] tall.
  ShapeBorder litShape(double size) {
    BorderRadius all(double r) => BorderRadius.circular(r);
    return switch (this) {
      quiet ||
      tint => RoundedRectangleBorder(borderRadius: all(GaiaRadius.chip)),
      pill => RoundedRectangleBorder(borderRadius: all(size / 2)),
      soft => RoundedRectangleBorder(borderRadius: all(9)),
      rounded => RoundedRectangleBorder(borderRadius: all(size / 3)),
      // Continuous corners look smaller than circular ones of the same
      // radius, so this is larger.
      squircle => ContinuousRectangleBorder(borderRadius: all(size * 0.75)),
      leaf => RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(size / 2),
          bottomRight: Radius.circular(size / 2),
          topRight: const Radius.circular(GaiaRadius.chip),
          bottomLeft: const Radius.circular(GaiaRadius.chip),
        ),
      ),
      bevel => BeveledRectangleBorder(borderRadius: all(size * 0.22)),
    };
  }

  /// The shape at rest, of the same kind as [litShape] so the two morph.
  ShapeBorder get restShape => switch (this) {
    squircle => ContinuousRectangleBorder(
      borderRadius: BorderRadius.circular(GaiaRadius.chip * 2.3),
    ),
    bevel => BeveledRectangleBorder(
      borderRadius: BorderRadius.circular(GaiaRadius.chip * 0.6),
    ),
    _ => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(GaiaRadius.chip),
    ),
  };
}

class GaiaButtonStudies extends StatelessWidget {
  const GaiaButtonStudies({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final error = theme.colorScheme.error;
    Widget panel(
      String title,
      String description,
      Widget Function({
        String? label,
        IconData? icon,
        double size,
        Color? color,
        required VoidCallback? onPressed,
      })
      button,
    ) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: gaiaSurface(theme.colorScheme.primary),
          borderRadius: BorderRadius.circular(GaiaRadius.panel),
          border: Border.all(color: GaiaInk.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: GaiaInk.bright,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(description, style: muted),
            const SizedBox(height: 12),
            // The chat's header, as the floater shows it.
            Row(
              children: [
                button(
                  icon: Icons.view_sidebar_outlined,
                  size: 34,
                  onPressed: () {},
                ),
                const Spacer(),
                button(icon: Icons.add, size: 32, onPressed: () {}),
                const SizedBox(width: 10),
                button(
                  icon: Icons.settings_outlined,
                  size: 32,
                  onPressed: () {},
                ),
                const SizedBox(width: 10),
                button(icon: Icons.open_in_full, size: 32, onPressed: () {}),
                const SizedBox(width: 10),
                button(icon: Icons.close, size: 34, onPressed: () {}),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                button(icon: Icons.add, label: 'New chat', onPressed: () {}),
                button(label: 'Cancel', onPressed: () {}),
                button(label: 'Delete', color: error, onPressed: () {}),
                button(label: 'Disabled', onPressed: null),
              ],
            ),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hover, Tab to and press each. None of these run a ticker.',
          style: muted,
        ),
        const SizedBox(height: 8),
        panel(
          'Current',
          'The circling light, for comparison.',
          ({label, icon, size = 36, color, required onPressed}) => GaiaButton(
            label: label,
            icon: icon,
            size: size,
            color: color,
            onPressed: onPressed,
          ),
        ),
        for (final study in _Study.values)
          panel(
            study.label,
            study.description,
            ({label, icon, size = 36, color, required onPressed}) =>
                _StudyButton(
                  study: study,
                  label: label,
                  icon: icon,
                  size: size,
                  color: color,
                  onPressed: onPressed,
                ),
          ),
      ],
    );
  }
}

/// [GaiaButton]'s shape, input and press, drawn as [study].
class _StudyButton extends StatefulWidget {
  const _StudyButton({
    required this.study,
    required this.onPressed,
    this.label,
    this.icon,
    this.size = 36,
    this.color,
  });

  final _Study study;
  final VoidCallback? onPressed;
  final String? label;
  final IconData? icon;
  final double size;
  final Color? color;

  @override
  State<_StudyButton> createState() => _StudyButtonState();
}

class _StudyButtonState extends State<_StudyButton> {
  var _hovered = false;
  var _pressed = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final study = widget.study;
    final enabled = widget.onPressed != null;
    final lit = _hovered || (_focused && enabled);
    final pressed = _pressed && enabled;
    final square = widget.label == null;
    final accent = widget.color ?? colors.primary;
    final white = Colors.white;

    final rest = square ? 0.0 : 0.05;
    final tinted = study != _Study.quiet;
    final Color fill;
    if ((tinted || widget.color != null) && lit) {
      fill = accent.withValues(alpha: pressed ? 0.22 : 0.14);
    } else {
      fill = white.withValues(
        alpha: pressed ? rest + 0.1 : (lit ? rest + 0.06 : rest),
      );
    }
    final foreground = tinted && lit
        ? Color.lerp(widget.color ?? accent, white, 0.4)!
        : widget.color ??
              (lit ? GaiaInk.bright : (square ? GaiaInk.muted : GaiaInk.dim));

    final iconSize = widget.size * 0.45;
    final content = square
        ? Icon(widget.icon, size: iconSize, color: foreground)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: iconSize, color: foreground),
                const SizedBox(width: 8),
              ],
              Text(
                widget.label!,
                style: TextStyle(
                  color: foreground,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          );

    Widget button = AnimatedContainer(
      duration: GaiaMotion.quick,
      curve: GaiaMotion.curve,
      height: widget.size,
      width: square ? widget.size : null,
      alignment: Alignment.center,
      padding: square ? null : const EdgeInsets.symmetric(horizontal: 15),
      decoration: ShapeDecoration(
        color: fill,
        // A Rounded icon has no fill at rest to morph from: it opens
        // straight onto its rounded shape.
        shape: lit || (square && study == _Study.rounded)
            ? study.litShape(widget.size)
            : study.restShape,
      ),
      child: content,
    );
    // As wide as its label, as GaiaButton is.
    if (!square) button = IntrinsicWidth(child: button);

    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) => widget.onPressed?.call(),
        ),
      },
      onShowHoverHighlight: (hovered) => setState(() {
        _hovered = hovered;
        if (!hovered) _pressed = false;
      }),
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 100),
            scale: !_pressed
                ? 1
                : square
                ? 0.94
                : 0.98,
            child: button,
          ),
        ),
      ),
    );
  }
}
