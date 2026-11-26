import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';

/// Gaia's dialog: the frosted shell its menus and date picker float in,
/// centred over the chat. With a [title] or [actions], it lays them out as
/// an alert does, [content] the message between; with neither, [content]
/// is the whole of it, padding and all.
class GaiaDialog extends StatelessWidget {
  const GaiaDialog({
    super.key,
    this.title,
    required this.content,
    this.actions = const [],
    this.maxWidth = 440,
    this.insetPadding = const EdgeInsets.symmetric(
      horizontal: 40,
      vertical: 24,
    ),
  });

  final Widget? title;
  final Widget content;

  /// At the bottom right, as [GaiaButton]s.
  final List<Widget> actions;
  final double maxWidth;

  /// Between it and the window's edges.
  final EdgeInsets insetPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = this.title;
    final alert = title != null || actions.isNotEmpty;
    final body = alert
        ? IntrinsicWidth(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (title != null) ...[
                    DefaultTextStyle.merge(
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: GaiaInk.bright,
                        fontWeight: FontWeight.w600,
                      ),
                      child: title,
                    ),
                    const SizedBox(height: 10),
                  ],
                  Flexible(
                    child: SingleChildScrollView(
                      child: DefaultTextStyle.merge(
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: GaiaInk.dim,
                        ),
                        child: content,
                      ),
                    ),
                  ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: actions,
                    ),
                  ],
                ],
              ),
            ),
          )
        : content;
    const shadow = BoxShadow(
      color: Color(0x8C000000),
      offset: Offset(0, 12),
      blurRadius: 40,
      spreadRadius: -8,
    );
    return Center(
      child: Padding(
        padding: insetPadding + MediaQuery.viewInsetsOf(context),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: 280, maxWidth: maxWidth),
          child: CustomPaint(
            // The shell is see-through: its shadow skips what's under it.
            painter: const GaiaShadowAround(shadow, radius: GaiaRadius.panel),
            child: GaiaGlowRing(
              radius: GaiaRadius.panel,
              hovered: false,
              child: Material(type: MaterialType.transparency, child: body),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pick from a few [options], in a card's field: the look of a
/// [GaiaCardTextField]'s fill, its [label] along the top, opening a
/// [GaiaMenu] of the options under it. Its edge lights with the aurora while
/// hovered, focused or open.
class GaiaDropdownField<T> extends StatefulWidget {
  const GaiaDropdownField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.icon,
  });

  final String label;

  /// Null shows none picked.
  final T? value;
  final List<({T value, String label})> options;

  /// Null disables it.
  final ValueChanged<T>? onChanged;

  /// Each option's icon in the menu; the picked one's is a check.
  final IconData? icon;

  @override
  State<GaiaDropdownField<T>> createState() => _GaiaDropdownFieldState<T>();
}

class _GaiaDropdownFieldState<T> extends State<GaiaDropdownField<T>> {
  var _hovered = false;
  var _focused = false;
  ContextMenuController? _menu;

  /// Whether the menu was open as this press began: the click outside that
  /// closes it isn't then one that opens it again.
  var _wasOpen = false;

  @override
  void dispose() {
    _menu?.remove();
    super.dispose();
  }

  void _open() {
    final onChanged = widget.onChanged;
    if (onChanged == null || _wasOpen) return;
    final box = context.findRenderObject()! as RenderBox;
    final menu = ContextMenuController();
    void close() {
      menu.remove();
      if (mounted) setState(() => _menu = null);
    }

    menu.show(
      context: context,
      contextMenuBuilder: (_) => GaiaMenu(
        // Under the field, not over it.
        anchor: box.localToGlobal(Offset(0, box.size.height + 4)),
        autofocus: true,
        onClose: close,
        items: [
          for (final option in widget.options)
            GaiaMenuItem(
              label: option.label,
              icon: option.value == widget.value ? Icons.check : widget.icon,
              onPressed: () => onChanged(option.value),
            ),
        ],
      ),
    );
    setState(() => _menu = menu);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.onChanged != null;
    final picked = widget.options
        .where((option) => option.value == widget.value)
        .firstOrNull;
    final lit = enabled && (_hovered || _focused || _menu != null);
    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onShowHoverHighlight: (hovered) => setState(() => _hovered = hovered),
      onShowFocusHighlight: (focused) => setState(() => _focused = focused),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _wasOpen = false;
            _open();
            return null;
          },
        ),
      },
      child: Listener(
        onPointerDown: (_) => _wasOpen = _menu != null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: gaiaFieldFill,
              borderRadius: BorderRadius.circular(GaiaRadius.row),
            ),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: lit ? 1 : 0),
              duration: GaiaMotion.quick,
              curve: GaiaMotion.curve,
              builder: (context, t, child) => GaiaAuroraLine(
                t: t,
                radius: GaiaRadius.row,
                accent: theme.colorScheme.primary,
                scale: 1,
                child: child!,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.label,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            picked?.label ?? 'None',
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: picked == null
                                  ? GaiaInk.faint
                                  : enabled
                                  ? GaiaInk.bright
                                  : GaiaInk.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _menu != null ? 0.5 : 0,
                      duration: GaiaMotion.quick,
                      curve: GaiaMotion.curve,
                      child: Icon(
                        Icons.expand_more,
                        size: 18,
                        color: lit ? GaiaInk.bright : GaiaInk.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A value along a range, in Gaia's look: a thin track filled with the
/// accent up to a small light thumb, which grows and glows while hovered,
/// dragged or focused. With [divisions], it snaps to them, each a faint dot
/// on the track. Left and Right (or Down and Up) step it.
class GaiaSlider extends StatefulWidget {
  const GaiaSlider({
    super.key,
    required this.value,
    this.min = 0,
    this.max = 1,
    this.divisions,
    required this.onChanged,
  });

  final double value, min, max;
  final int? divisions;

  /// Null disables it.
  final ValueChanged<double>? onChanged;

  @override
  State<GaiaSlider> createState() => _GaiaSliderState();
}

class _GaiaSliderState extends State<GaiaSlider> {
  var _hovered = false;
  var _focused = false;
  var _dragging = false;

  double get _fraction {
    final span = widget.max - widget.min;
    return span <= 0 ? 0 : ((widget.value - widget.min) / span).clamp(0.0, 1.0);
  }

  void _setFraction(double fraction) {
    final onChanged = widget.onChanged;
    if (onChanged == null) return;
    var f = fraction.clamp(0.0, 1.0);
    if (widget.divisions case final divisions? when divisions > 0) {
      f = (f * divisions).round() / divisions;
    }
    final value = widget.min + f * (widget.max - widget.min);
    if (value != widget.value) onChanged(value);
  }

  void _at(Offset local, double width) => _setFraction(
    (local.dx - _thumbLit) / (width - 2 * _thumbLit).clamp(1, double.infinity),
  );

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final step = 1 / (widget.divisions ?? 20);
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp) {
      _setFraction(_fraction + step);
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowDown) {
      _setFraction(_fraction - step);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final lit = enabled && (_hovered || _focused || _dragging);
    return Semantics(
      slider: true,
      value: widget.value.toStringAsFixed(widget.divisions == null ? 2 : 0),
      child: Focus(
        canRequestFocus: enabled,
        onKeyEvent: _onKey,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: enabled
                    ? (details) => _at(details.localPosition, width)
                    : null,
                onHorizontalDragStart: enabled
                    ? (details) {
                        setState(() => _dragging = true);
                        _at(details.localPosition, width);
                      }
                    : null,
                onHorizontalDragUpdate: enabled
                    ? (details) => _at(details.localPosition, width)
                    : null,
                onHorizontalDragEnd: enabled
                    ? (_) => setState(() => _dragging = false)
                    : null,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: lit ? 1 : 0),
                  duration: GaiaMotion.quick,
                  curve: GaiaMotion.curve,
                  builder: (context, t, _) => CustomPaint(
                    size: Size(width, 24),
                    painter: _SliderPainter(
                      fraction: _fraction,
                      lit: t,
                      divisions: widget.divisions,
                      accent: enabled
                          ? Theme.of(context).colorScheme.primary
                          : GaiaInk.faint,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The thumb's radius at rest and lit; the track stops short of the ends by
/// the larger, so the thumb never pokes out.
const _thumbRest = 6.0;
const _thumbLit = 7.5;

class _SliderPainter extends CustomPainter {
  const _SliderPainter({
    required this.fraction,
    required this.lit,
    required this.divisions,
    required this.accent,
  });

  final double fraction, lit;
  final int? divisions;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final left = _thumbLit, right = size.width - _thumbLit;
    final x = left + (right - left) * fraction;
    final track = RRect.fromLTRBR(
      left,
      y - 2,
      right,
      y + 2,
      const Radius.circular(2),
    );
    canvas.drawRRect(
      track,
      Paint()..color = Colors.white.withValues(alpha: 0.12),
    );
    canvas.drawRRect(
      RRect.fromLTRBR(left, y - 2, x, y + 2, const Radius.circular(2)),
      Paint()..color = accent,
    );
    if (divisions case final divisions? when divisions > 1 && divisions <= 24) {
      for (var i = 1; i < divisions; i++) {
        final dx = left + (right - left) * i / divisions;
        canvas.drawCircle(
          Offset(dx, y),
          1,
          Paint()
            ..color = Colors.white.withValues(alpha: dx <= x ? 0.45 : 0.25),
        );
      }
    }
    final radius = _thumbRest + (_thumbLit - _thumbRest) * lit;
    if (lit > 0) {
      canvas.drawCircle(
        Offset(x, y),
        radius + 4,
        Paint()
          ..color = accent.withValues(alpha: 0.35 * lit)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
    canvas.drawCircle(Offset(x, y), radius, Paint()..color = GaiaInk.bright);
    canvas.drawCircle(
      Offset(x, y),
      radius - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = accent.withValues(alpha: 0.6 + 0.4 * lit),
    );
  }

  @override
  bool shouldRepaint(_SliderPainter old) =>
      old.fraction != fraction ||
      old.lit != lit ||
      old.divisions != divisions ||
      old.accent != accent;
}

/// Ticked or not, in [GaiaToggle]'s look: a small rounded square in a faint
/// rim, washed with the accent and checked while on. Null [onChanged]
/// disables it.
class GaiaCheckbox extends StatefulWidget {
  const GaiaCheckbox({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<GaiaCheckbox> createState() => _GaiaCheckboxState();
}

class _GaiaCheckboxState extends State<GaiaCheckbox> {
  /// Reached with Tab, and flipped with Enter or Space: its rim lit.
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final value = widget.value;
    final onChanged = widget.onChanged;
    final flip = onChanged == null ? null : () => onChanged(!value);
    return Semantics(
      checked: value,
      enabled: flip != null,
      child: FocusableActionDetector(
        enabled: flip != null,
        mouseCursor: flip == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => flip?.call(),
          ),
        },
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: flip,
          child: AnimatedOpacity(
            duration: GaiaMotion.quick,
            opacity: flip == null ? 0.45 : 1,
            child: AnimatedContainer(
              duration: GaiaMotion.quick,
              curve: GaiaMotion.curve,
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: value
                    ? accent.withValues(alpha: 0.25)
                    : accent.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: _focused
                      ? accent
                      : value
                      ? accent.withValues(alpha: 0.8)
                      : GaiaInk.faint.withValues(alpha: 0.6),
                ),
              ),
              child: AnimatedScale(
                duration: GaiaMotion.quick,
                curve: GaiaMotion.curve,
                scale: value ? 1 : 0.4,
                child: AnimatedOpacity(
                  duration: GaiaMotion.quick,
                  opacity: value ? 1 : 0,
                  child: const Icon(
                    Icons.check,
                    size: 12,
                    color: GaiaInk.bright,
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

/// How full something is, 0 to 1, in Gaia's look: a thin rounded track
/// filled with the accent, lighter towards its end and faintly glowing,
/// easing to a new [value].
class GaiaProgressBar extends StatelessWidget {
  const GaiaProgressBar({super.key, required this.value, this.height = 4});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = colors.primary;
    final radius = BorderRadius.circular(height / 2);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.clamp(0.0, 1.0)),
      duration: GaiaMotion.move,
      curve: GaiaMotion.curve,
      builder: (context, t, _) => Container(
        height: height,
        decoration: BoxDecoration(
          // The text's colour, not white: the Setup tab shows these on the
          // light theme's paper too, where a white track is invisible.
          color: colors.onSurface.withValues(alpha: 0.15),
          borderRadius: radius,
        ),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: t,
          heightFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                colors: [accent, Color.lerp(accent, Colors.white, 0.35)!],
              ),
              boxShadow: [
                if (t > 0)
                  BoxShadow(
                    color: accent.withValues(alpha: 0.45),
                    blurRadius: 6,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
