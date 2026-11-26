import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_aurora_edge.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';

/// Gaia's surface colour: near black, tinted a little toward [accent].
Color gaiaSurface(Color accent) =>
    Color.lerp(const Color(0xFF15181B), accent, 0.1)!;

/// Whether Gaia's idle motion runs, the tier glyphs' turning rings: while
/// Gaia is in front with the cursor in its window, as the starfield does, so
/// a window left alone costs nothing.
/// Without one above them, they run.
class GaiaAmbient extends InheritedWidget {
  const GaiaAmbient({super.key, required this.running, required super.child});

  final bool running;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GaiaAmbient>()?.running ??
      true;

  @override
  bool updateShouldNotify(GaiaAmbient old) => old.running != running;
}

/// Gaia's button: no edge at rest, a bare muted icon or a label on a faint
/// light fill. Hover (or Tab) fills it with a faint tint of the accent,
/// colours its content, and rounds it to about a third of its height; an
/// icon-only one has no fill at rest to morph from, so it opens straight
/// onto the rounded shape. Squared off with a [label], or square with only
/// an [icon]. A [color] stands in for the accent and tints the label, as
/// Cancel's red does.
class GaiaButton extends StatefulWidget {
  const GaiaButton({
    super.key,
    required this.onPressed,
    this.label,
    this.icon,
    this.size = 36,
    this.color,
    this.padding = 16,
    this.radius,
    this.iconSize,
    this.tooltip,
    this.semanticLabel,
    this.glyph,
  }) : assert(label != null || icon != null || glyph != null);

  /// Null disables the button.
  final VoidCallback? onPressed;
  final String? label;
  final IconData? icon;

  /// Drawn in place of [icon] when the icon is more than one glyph, as the
  /// composer's hand is. It's given the content's colour and [iconSize] as
  /// its [IconTheme].
  final Widget? glyph;

  /// The height, and an icon-only button's width.
  final double size;

  /// The icon's size; 0.45 of [size] when null.
  final double? iconSize;

  /// Shown on hover, and the button's name to a screen reader.
  final String? tooltip;

  /// With no [tooltip], its name to a screen reader alone: where a button
  /// repeats down a list, a tooltip on each would cover the rows under it.
  final String? semanticLabel;

  /// The hover tint's colour and the content's; the accent when null.
  final Color? color;

  /// Either side of a squared-off button's label.
  final double padding;

  /// The corner radius at rest and on hover; when null, [GaiaRadius.chip]
  /// at rest, rounding to a third of [size] on hover.
  final double? radius;

  @override
  State<GaiaButton> createState() => _GaiaButtonState();
}

class _GaiaButtonState extends State<GaiaButton> {
  var _hovered = false;
  var _pressed = false;

  /// Reached with Tab, and pressed with Enter or Space: lit as hovered.
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final lit = _hovered || (_focused && enabled);
    final pressed = _pressed && enabled;
    final square = widget.label == null;
    final accent = widget.color ?? Theme.of(context).colorScheme.primary;
    final rest = square ? 0.0 : 0.05;
    final fill = lit
        ? accent.withValues(alpha: pressed ? 0.22 : 0.14)
        : Colors.white.withValues(alpha: pressed ? rest + 0.1 : rest);
    final foreground = lit
        ? Color.lerp(accent, Colors.white, 0.4)!
        : widget.color ?? (square ? GaiaInk.muted : GaiaInk.dim);
    final radius =
        widget.radius ?? (lit || square ? widget.size / 3 : GaiaRadius.chip);
    final iconSize = widget.iconSize ?? widget.size * 0.45;
    final content = square
        ? widget.glyph != null
              ? IconTheme.merge(
                  data: IconThemeData(color: foreground, size: iconSize),
                  child: widget.glyph!,
                )
              : Icon(widget.icon, size: iconSize, color: foreground)
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
    final body = AnimatedContainer(
      duration: GaiaMotion.quick,
      curve: GaiaMotion.curve,
      alignment: Alignment.center,
      padding: square ? null : EdgeInsets.symmetric(horizontal: widget.padding),
      decoration: ShapeDecoration(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      child: content,
    );
    final button = FocusableActionDetector(
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
            // A square one is small: the same press would hardly show.
            scale: !_pressed
                ? 1
                : square
                ? 0.94
                : 0.98,
            child: SizedBox(
              height: widget.size,
              width: square ? widget.size : null,
              // As wide as its label, unless made wider.
              child: square ? body : IntrinsicWidth(child: body),
            ),
          ),
        ),
      ),
    );
    final tooltip = widget.tooltip;
    if (tooltip != null) return Tooltip(message: tooltip, child: button);
    final semanticLabel = widget.semanticLabel;
    return semanticLabel == null
        ? button
        : Semantics(button: true, label: semanticLabel, child: button);
  }
}

/// Draws the [GaiaGlowRing]s under it with [builder] instead: the debug
/// menu's shell studies, trying other looks on the real notch and menu.
class GaiaRingLook extends InheritedWidget {
  const GaiaRingLook({super.key, required this.builder, required super.child});

  final Widget Function({
    required double radius,
    required bool hovered,
    required double backdrop,
    required Color accent,
    required Widget child,
  })
  builder;

  static GaiaRingLook? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GaiaRingLook>();

  @override
  bool updateShouldNotify(GaiaRingLook old) => old.builder != builder;
}

/// The shell round Gaia's notch, menus, palette, panels, date picker and
/// toast: a dark fill in a grey line, which on hover brings the text
/// field's aurora up along the line. What floats is frosted, a see-through
/// fill blurring what's behind it; a [capsule] (the composer's notches) is
/// opaque instead, its fill steady while only its line lights, so nothing
/// always on screen blurs. Its aurora's loop runs only while it shows.
class GaiaGlowRing extends StatelessWidget {
  const GaiaGlowRing({
    super.key,
    required this.radius,
    required this.hovered,
    this.color,
    this.backdrop = 1,
    this.capsule = false,
    required this.child,
  });

  /// The outer corner radius.
  final double radius;
  final bool hovered;

  /// How much of the shell shows behind [child]: 0 leaves the child bare,
  /// as the composer's closed + is.
  final double backdrop;

  /// The aurora's accent; the theme's when null.
  final Color? color;

  /// Opaque and tinted rather than frosted, with a smaller aurora.
  final bool capsule;

  /// Clipped to the fill.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? Theme.of(context).colorScheme.primary;
    if (GaiaRingLook.maybeOf(context) case final look?) {
      return look.builder(
        radius: radius,
        hovered: hovered,
        backdrop: backdrop,
        accent: accent,
        child: child,
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(end: hovered ? 1 : 0),
      duration: GaiaMotion.quick,
      curve: GaiaMotion.curve,
      child: child,
      builder: (context, t, child) => _shell(context, t, accent, child!),
    );
  }

  Widget _shell(BuildContext context, double t, Color accent, Widget child) {
    final white = Colors.white;
    final base = Color.lerp(
      Theme.of(context).colorScheme.surface,
      Colors.black,
      0.5,
    )!;
    // Faded with the backdrop.
    Color shown(Color color) => color.withValues(alpha: color.a * backdrop);
    final line = shown(white.withValues(alpha: 0.14));
    final fill = capsule
        ? Color.alphaBlend(white.withValues(alpha: 0.05), base)
        : base.withValues(alpha: 0.55);
    // The line's 1 px, outside the fill.
    final filled = Padding(
      padding: const EdgeInsets.all(1),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: shown(fill),
          borderRadius: BorderRadius.circular(radius - 1),
        ),
        child: child,
      ),
    );
    final blur = 10 * backdrop;
    final shell = capsule
        ? DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: line),
              borderRadius: BorderRadius.circular(radius),
            ),
            child: filled,
          )
        // Always there, so a bare notch opening keeps its contents' state.
        // Its line over the clip, not inside it, where the clip's
        // antialiasing would soften its outer half into a haze.
        : DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: Border.all(color: line),
              borderRadius: BorderRadius.circular(radius),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: BackdropFilter(
                // Bounded: it blurs only what's under the shell, so nothing
                // just past its edge bleeds in as a haze.
                filterConfig: ImageFilterConfig.blur(
                  sigmaX: blur,
                  sigmaY: blur,
                  bounded: true,
                ),
                child: filled,
              ),
            ),
          );
    // Outside the clip, so its glow spreads past the edge.
    return GaiaAuroraLine(
      t: t * backdrop,
      radius: radius,
      accent: accent,
      // The capsule is small: a full field's glow would swamp it.
      scale: capsule ? 0.6 : 1,
      child: shell,
    );
  }
}

/// The text field's aurora on a shell's edge, [t] of the way lit: its loop
/// runs only while it shows.
class GaiaAuroraLine extends StatefulWidget {
  const GaiaAuroraLine({
    super.key,
    required this.t,
    required this.radius,
    required this.accent,
    required this.scale,
    required this.child,
  });

  final double t, radius, scale;
  final Color accent;
  final Widget child;

  @override
  State<GaiaAuroraLine> createState() => _GaiaAuroraLineState();
}

class _GaiaAuroraLineState extends State<GaiaAuroraLine>
    with SingleTickerProviderStateMixin {
  /// The aurora's loop, as long as the field's.
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(minutes: 2),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(GaiaAuroraLine old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.t > 0;
    if (run == _spin.isAnimating) return;
    if (run) {
      _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _spin,
    builder: (context, child) => CustomPaint(
      foregroundPainter: gaiaAuroraPainter(
        t: widget.t,
        time: _spin.value,
        // The shell draws the grey line itself.
        rest: Colors.transparent,
        accent: widget.accent,
        radius: widget.radius,
        scale: widget.scale,
      ),
      child: child,
    ),
    child: widget.child,
  );
}

/// [shadow] round a see-through shell of [radius], as its [BoxDecoration]
/// would draw it, less what's under the shell, which would show through.
class GaiaShadowAround extends CustomPainter {
  const GaiaShadowAround(this.shadow, {required this.radius});

  final BoxShadow shadow;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final shell = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final around = Path.combine(
      PathOperation.difference,
      Path()..addRect(shell.outerRect.inflate(shadow.blurRadius * 2 + 64)),
      Path()..addRRect(shell),
    );
    canvas
      ..save()
      ..clipPath(around)
      ..drawRRect(
        shell.shift(shadow.offset).inflate(shadow.spreadRadius),
        shadow.toPaint(),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(GaiaShadowAround old) =>
      old.shadow != shadow || old.radius != radius;
}
