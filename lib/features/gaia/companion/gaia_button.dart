import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Gaia's surface colour: near black, tinted a little toward [accent].
Color gaiaSurface(Color accent) =>
    Color.lerp(const Color(0xFF15181B), accent, 0.1)!;

/// Whether Gaia's idle motion runs, the glow rings' circling light and the
/// tier glyphs' turning rings: while Gaia is in front with the cursor in its
/// window, as the starfield does, so a window left alone costs nothing.
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

/// Gaia's button (after Aceternity UI's hover border gradient): a dark fill
/// in a [GaiaGlowRing], lit by a soft light that circles the ring. Once the
/// cursor comes within [_reach] of the button, the light swings round to
/// face it and follows it, a tint of the accent; over the button, it centres
/// on the cursor, widens, and turns the accent at full saturation. Squared
/// off with a [label], or round with only an [icon]. A [color] stands in for
/// the accent and tints the label, as Cancel's red does.
class GaiaButton extends StatefulWidget {
  const GaiaButton({
    super.key,
    required this.onPressed,
    this.label,
    this.icon,
    this.size = 36,
    this.color,
    this.padding = 16,
    this.still = false,
  }) : assert(label != null || icon != null);

  /// Null disables the button.
  final VoidCallback? onPressed;
  final String? label;
  final IconData? icon;

  /// The height, and a round button's width.
  final double size;

  /// The light's colour and the label's; the accent and white when null.
  final Color? color;

  /// Either side of a squared-off button's label.
  final double padding;

  /// The ring without its moving light, which lights up whole on hover:
  /// for small buttons there can be many of, as on each attachment.
  final bool still;

  @override
  State<GaiaButton> createState() => _GaiaButtonState();
}

/// How near the cursor has to come to the button's edge for the light to
/// face it.
const _reach = 90.0;

/// The light's pace around the ring, in radians a second: a turn every 16s.
const _spin = math.pi / 8;

/// How fast the light turns to face the cursor: the rate it closes the gap
/// at, per second.
const _follow = 2.5;

/// The light's strength, at rest and on hover.
const _glow = 0.6;

class _GaiaButtonState extends State<GaiaButton> {
  var _hovered = false;
  var _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final round = widget.label == null;
    final outer = round ? widget.size / 2 : 6.0;
    final iconSize = widget.size * 0.45;
    final foreground = widget.color ?? Colors.white;
    final content = round
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
    final inner = Container(
      alignment: Alignment.center,
      padding: round ? null : EdgeInsets.symmetric(horizontal: widget.padding),
      child: content,
    );
    final Widget ring;
    if (widget.still) {
      final colors = Theme.of(context).colorScheme;
      final accent = widget.color ?? colors.primary;
      // The moving ring's colours, idle and lit, round the whole edge.
      ring = AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: _hovered
              ? HSLColor.fromColor(accent).withSaturation(1).toColor()
              : Color.lerp(accent, Colors.white, 0.5)!.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(outer),
        ),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Color.lerp(colors.surface, Colors.black, 0.5),
            borderRadius: BorderRadius.circular(outer - 1),
          ),
          child: inner,
        ),
      );
    } else {
      ring = GaiaGlowRing(
        radius: outer,
        hovered: _hovered,
        color: widget.color,
        child: inner,
      );
    }
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 100),
            scale: _pressed ? 0.98 : 1,
            child: SizedBox(
              height: widget.size,
              width: round ? widget.size : null,
              // As wide as its label, unless made wider.
              child: round ? ring : IntrinsicWidth(child: ring),
            ),
          ),
        ),
      ),
    );
  }
}

/// The ring of light round Gaia's buttons and its notch: a dark fill in a
/// thin ring that the light circles. Near the cursor the light swings round
/// to face it; while [hovered], it centres on the cursor, widens, and turns
/// the accent at full saturation.
class GaiaGlowRing extends StatefulWidget {
  const GaiaGlowRing({
    super.key,
    required this.radius,
    required this.hovered,
    this.color,
    required this.child,
  });

  /// The outer corner radius.
  final double radius;
  final bool hovered;

  /// The light's colour; the accent when null.
  final Color? color;

  /// Clipped to the fill.
  final Widget child;

  @override
  State<GaiaGlowRing> createState() => _GaiaGlowRingState();
}

class _GaiaGlowRingState extends State<GaiaGlowRing>
    with TickerProviderStateMixin {
  /// The cursor in this ring's coordinates; null when it's out of the
  /// window or hasn't moved yet.
  Offset? _cursor;

  /// Where the light is around the ring: the angle from the centre, in a
  /// space where the ring is a circle, clockwise from the right. Starts
  /// at the top.
  final _angle = ValueNotifier(-math.pi / 2);
  late final Ticker _ticker;
  var _lastTick = Duration.zero;

  late final _hover = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
    value: widget.hovered ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    // The cursor anywhere in the window, not only over the ring.
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  // Hovered, it runs regardless, so the light follows the cursor over a
  // floater left in front of another app.
  void _sync() {
    final run = GaiaAmbient.of(context) || widget.hovered;
    if (run == _ticker.isActive) return;
    if (run) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  @override
  void didUpdateWidget(GaiaGlowRing old) {
    super.didUpdateWidget(old);
    if (widget.hovered == old.hovered) return;
    _sync();
    if (widget.hovered) {
      _hover.forward();
    } else {
      _hover.reverse();
    }
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _ticker.dispose();
    _hover.dispose();
    _angle.dispose();
    super.dispose();
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerRemovedEvent) {
      _cursor = null;
      return;
    }
    if (event is! PointerHoverEvent && event is! PointerMoveEvent) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    _cursor = box.globalToLocal(event.position);
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final size = box.size;
    final cursor = _cursor;
    final near =
        cursor != null && (Offset.zero & size).inflate(_reach).contains(cursor);
    if (!near) {
      _angle.value += _spin * dt;
      return;
    }
    final half = Offset(size.width / 2, size.height / 2);
    final away = cursor - half;
    final target = math.atan2(away.dy / half.dy, away.dx / half.dx);
    // The short way round, eased.
    var turn = (target - _angle.value) % (2 * math.pi);
    if (turn > math.pi) turn -= 2 * math.pi;
    _angle.value += turn * (1 - math.exp(-dt * _follow));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final outer = widget.radius;
    final accent = widget.color ?? colors.primary;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(outer),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(outer),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                child: CustomPaint(
                  painter: GaiaGlowPainter(
                    angle: _angle,
                    hover: _hover,
                    cursor: () => _cursor,
                    idle: Color.lerp(accent, Colors.white, 0.5)!,
                    lit: HSLColor.fromColor(accent).withSaturation(1).toColor(),
                  ),
                ),
              ),
            ),
          ),
          // Covers all but the ring of the light.
          Padding(
            padding: const EdgeInsets.all(1),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Color.lerp(colors.surface, Colors.black, 0.5),
                borderRadius: BorderRadius.circular(outer - 1),
              ),
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}

/// The light: an elliptical radial gradient on the ring at [angle], moving
/// onto the cursor as [hover] runs. Also the Gaia toast's.
class GaiaGlowPainter extends CustomPainter {
  GaiaGlowPainter({
    required this.angle,
    required this.hover,
    required this.cursor,
    required this.idle,
    required this.lit,
  }) : super(repaint: Listenable.merge([angle, hover]));

  final ValueNotifier<double> angle;
  final Animation<double> hover;
  final Offset? Function() cursor;
  final Color idle;
  final Color lit;

  @override
  void paint(Canvas canvas, Size size) {
    final t = Curves.easeOut.transform(hover.value);
    final half = Offset(size.width / 2, size.height / 2);
    // From the circle the angle lives in out to the button's edge.
    final x = math.cos(angle.value);
    final y = math.sin(angle.value);
    final onRing =
        half + Offset(x * half.dx, y * half.dy) / math.max(x.abs(), y.abs());
    // The cursor held inside the button: once it's left, the light eases
    // back from the edge it left by, not from out where it's clipped away.
    final over = cursor();
    final center = Offset.lerp(
      onRing,
      over == null
          ? onRing
          : Offset(over.dx.clamp(0, size.width), over.dy.clamp(0, size.height)),
      t,
    )!;
    final radii = Size.lerp(
      Size(size.width * 0.4, size.height),
      Size(size.width * 0.75, size.height * 1.8),
      t,
    )!;
    final color = Color.lerp(idle, lit, t)!.withValues(alpha: _glow);
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..scale(radii.width, radii.height)
      ..drawCircle(
        Offset.zero,
        1,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1)),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(GaiaGlowPainter old) => old.idle != idle || old.lit != lit;
}
