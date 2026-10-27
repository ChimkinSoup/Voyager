import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';

/// The light's pace around the ring, as [GaiaButton]'s: a turn every 16s.
const _spin = math.pi / 8;

const _radius = 8.0;

/// How long a toast stays up while the cursor isn't on it.
const _dwell = Duration(seconds: 4);

OverlayEntry? _current;

/// What a toast is about, drawn at its core by [GaiaToastOrbIcon].
enum GaiaToastMark {
  done('Done'),
  question('Question'),
  error('Error'),
  info('Info');

  const GaiaToastMark(this.label);

  final String label;
}

/// Shows a toast over Gaia's content, below the header: [GaiaButton]'s
/// ring and circling light around a [mark], a [title] and a [body]. One at
/// a time, so a new one replaces the last. It goes after a few seconds
/// unless the cursor is on it; a click dismisses it, after [onTap].
void showGaiaToast(
  BuildContext context, {
  required String title,
  required String body,
  required GaiaToastMark mark,
  VoidCallback? onTap,
}) {
  _current?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _GaiaToast(
      title: title,
      body: body,
      mark: mark,
      onTap: onTap,
      onGone: () {
        if (_current != entry) return;
        _current = null;
        entry.remove();
      },
    ),
  );
  _current = entry;
  Overlay.of(context, rootOverlay: true).insert(entry);
}

class _GaiaToast extends StatefulWidget {
  const _GaiaToast({
    required this.title,
    required this.body,
    required this.mark,
    required this.onTap,
    required this.onGone,
  });

  final String title;
  final String body;
  final GaiaToastMark mark;
  final VoidCallback? onTap;
  final VoidCallback onGone;

  @override
  State<_GaiaToast> createState() => _GaiaToastState();
}

class _GaiaToastState extends State<_GaiaToast> with TickerProviderStateMixin {
  late final _shown = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 160),
  );
  late final _hover = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  /// As [GaiaButton]'s light: clockwise from the right, starting at the top.
  final _angle = ValueNotifier(-math.pi / 2);
  late final Ticker _ticker;
  var _lastTick = Duration.zero;

  /// The cursor over the toast, in its coordinates.
  Offset? _cursor;
  Timer? _dwellTimer;
  var _leaving = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
    _shown.forward();
    _dwellTimer = Timer(_dwell, _dismiss);
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    _ticker.dispose();
    _shown.dispose();
    _hover.dispose();
    _angle.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    _angle.value += _spin * dt;
  }

  Future<void> _dismiss() async {
    if (_leaving) return;
    _leaving = true;
    _dwellTimer?.cancel();
    await _shown.reverse();
    widget.onGone();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final curve = CurvedAnimation(parent: _shown, curve: Curves.easeOutCubic);
    return Positioned(
      left: 16,
      right: 16,
      // Below the header.
      top: 64,
      child: Center(
        child: FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, -0.4),
              end: Offset.zero,
            ).animate(curve),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) {
                _dwellTimer?.cancel();
                _hover.forward();
              },
              onHover: (event) => _cursor = event.localPosition,
              onExit: (_) {
                _cursor = null;
                _hover.reverse();
                if (!_leaving) _dwellTimer = Timer(_dwell, _dismiss);
              },
              child: GestureDetector(
                onTap: () {
                  widget.onTap?.call();
                  unawaited(_dismiss());
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Material(
                    type: MaterialType.transparency,
                    child: _ring(colors),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// [GaiaButton]'s ring, around the toast's content.
  Widget _ring(ColorScheme colors) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(_radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_radius),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                child: CustomPaint(
                  painter: GaiaGlowPainter(
                    angle: _angle,
                    hover: _hover,
                    cursor: () => _cursor,
                    idle: Color.lerp(colors.primary, Colors.white, 0.5)!,
                    lit: HSLColor.fromColor(
                      colors.primary,
                    ).withSaturation(1).toColor(),
                  ),
                ),
              ),
            ),
          ),
          // Covers all but the ring of the light.
          Padding(
            padding: const EdgeInsets.all(1),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
              decoration: BoxDecoration(
                color: Color.lerp(colors.surface, Colors.black, 0.5),
                borderRadius: BorderRadius.circular(_radius - 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GaiaToastOrbIcon(mark: widget.mark),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (widget.body.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// An Astral orbit framing a drawn status mark, with a finite arrival animation.
class GaiaToastOrbIcon extends StatefulWidget {
  const GaiaToastOrbIcon({super.key, required this.mark, this.size = 36});

  final GaiaToastMark mark;
  final double size;

  @override
  State<GaiaToastOrbIcon> createState() => _GaiaToastOrbIconState();
}

class _GaiaToastOrbIconState extends State<GaiaToastOrbIcon>
    with SingleTickerProviderStateMixin {
  late final _arrival = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _arrival.value = 1;
    } else if (_arrival.value < 1 && !_arrival.isAnimating) {
      _arrival.forward();
    }
  }

  @override
  void dispose() {
    _arrival.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.mark.label,
    image: true,
    child: SizedBox.square(
      dimension: widget.size,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _ToastMarkPainter(
            arrival: _arrival,
            mark: widget.mark,
            accent: Theme.of(context).colorScheme.primary,
            error: Theme.of(context).colorScheme.error,
          ),
        ),
      ),
    ),
  );
}

class _ToastMarkPainter extends CustomPainter {
  _ToastMarkPainter({
    required this.arrival,
    required this.mark,
    required this.accent,
    required this.error,
  }) : super(repaint: arrival);

  final Animation<double> arrival;
  final GaiaToastMark mark;
  final Color accent;
  final Color error;

  @override
  void paint(Canvas canvas, Size size) {
    final d = size.shortestSide;
    final light = gaiaAstralLight(accent);
    const gold = kGaiaAstralGold;
    final progress = Curves.easeOutCubic.transform(arrival.value);
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(d / 36);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Open, intersecting orbital arcs leave space for the mark at the core.
    for (var orbit = 0; orbit < 2; orbit++) {
      final tint = orbit == 0 ? light : gold;
      canvas.save();
      canvas.rotate((orbit == 0 ? -0.55 : 0.7) + (1 - progress) * 0.45);
      final bounds = Rect.fromCenter(
        center: Offset.zero,
        width: 31,
        height: orbit == 0 ? 25 : 22,
      );
      final start = orbit == 0 ? -2.8 : 0.3;
      final sweep = math.pi * (1.3 + progress * 0.35);
      canvas.drawArc(
        bounds,
        start,
        sweep,
        false,
        line..color = tint.withValues(alpha: 0.25 + progress * 0.35),
      );
      final end = start + sweep;
      canvas.drawCircle(
        Offset(
          bounds.width / 2 * math.cos(end),
          bounds.height / 2 * math.sin(end),
        ),
        1.15,
        Paint()..color = tint,
      );
      canvas.restore();
    }

    final symbol = (mark == GaiaToastMark.error ? error : light).withValues(
      alpha: 0.35 + progress * 0.65,
    );
    canvas.save();
    // Every mark arrives from its centre on the same curve. Drawing each
    // path progressively made punctuation grow in opposite directions.
    canvas.scale(0.82 + progress * 0.18);
    line
      ..color = symbol
      ..strokeWidth = 2.5;
    final path = Path();
    switch (mark) {
      case GaiaToastMark.done:
        path.moveTo(-6, 0);
        path.lineTo(-1.5, 4.5);
        path.lineTo(6, -4.5);
      case GaiaToastMark.question:
        path.moveTo(-4, -4);
        path.cubicTo(-4, -10, 7, -10, 4, -3);
        path.cubicTo(3, -1, 0, -1, 0, 2);
      case GaiaToastMark.error:
        path.moveTo(0, -7);
        path.lineTo(0, 2);
      case GaiaToastMark.info:
        path.moveTo(0, -1);
        path.lineTo(0, 7);
    }
    canvas.drawPath(path, line);
    if (mark != GaiaToastMark.done) {
      canvas.drawCircle(
        Offset(0, mark == GaiaToastMark.info ? -6 : 6.5),
        1.45,
        Paint()..color = symbol,
      );
    }
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ToastMarkPainter oldDelegate) =>
      oldDelegate.mark != mark ||
      oldDelegate.accent != accent ||
      oldDelegate.error != error ||
      oldDelegate.arrival != arrival;
}
