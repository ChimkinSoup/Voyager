import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_pinned_prompt.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';

const _radius = GaiaRadius.row;

/// How long a toast stays up while the cursor isn't on it: longer for a
/// longer body, at about 200 words a minute, up to 15s.
Duration _dwellFor(String body) {
  final words = body.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  return Duration(milliseconds: math.min(4000 + words * 300, 15000));
}

OverlayEntry? _current;

/// Where the chat column starts from the window's left, past the sidebar, so
/// a toast centres on the chat rather than the window. Set by the shell.
ValueListenable<double> gaiaToastLeft = ValueNotifier(0);

/// What a toast is about, drawn at its core by [GaiaToastOrbIcon].
enum GaiaToastMark {
  done('Done'),
  question('Question'),
  error('Error'),
  info('Info');

  const GaiaToastMark(this.label);

  final String label;
}

/// Shows a toast over Gaia's content, below the header: Gaia's frosted
/// shell, as its menus have, around a [mark], a [title] and a [body]. One at
/// a time, so a new one replaces the last. It goes after a few seconds
/// unless the cursor is on it; a click dismisses it, after [onTap]. With
/// [onUndo], it has an Undo button, which dismisses it too. [lingers] keeps
/// it up half as long again.
void showGaiaToast(
  BuildContext context, {
  required String title,
  required String body,
  required GaiaToastMark mark,
  VoidCallback? onTap,
  VoidCallback? onUndo,
  bool lingers = false,
}) {
  _current?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _GaiaToast(
      title: title,
      body: body,
      mark: mark,
      onTap: onTap,
      onUndo: onUndo,
      lingers: lingers,
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
    required this.onUndo,
    required this.lingers,
    required this.onGone,
  });

  final String title;
  final String body;
  final GaiaToastMark mark;
  final VoidCallback? onTap;
  final VoidCallback? onUndo;
  final bool lingers;
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
  late final Ticker _ticker;
  var _hovered = false;
  Timer? _dwellTimer;
  var _leaving = false;

  /// [gaiaToastLeft]'s value, read each tick: the shell may swap which
  /// notifier it is, and the sidebar's is set mid-layout, too late to rebuild
  /// on.
  var _left = gaiaToastLeft.value;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
    _shown.forward();
    _dwellTimer = Timer(_dwell, _dismiss);
  }

  Duration get _dwell => _dwellFor(widget.body) * (widget.lingers ? 1.5 : 1);

  @override
  void dispose() {
    _dwellTimer?.cancel();
    _ticker.dispose();
    _shown.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final left = gaiaToastLeft.value;
    if (left != _left) setState(() => _left = left);
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
    final curve = CurvedAnimation(parent: _shown, curve: Curves.easeOutCubic);
    final toast = Padding(
      padding: EdgeInsets.only(left: _left),
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
                setState(() => _hovered = true);
              },
              onExit: (_) {
                setState(() => _hovered = false);
                if (!_leaving) {
                  _dwellTimer = Timer(_dwell, _dismiss);
                }
              },
              child: GestureDetector(
                onTap: () {
                  widget.onTap?.call();
                  unawaited(_dismiss());
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Material(
                    type: MaterialType.transparency,
                    child: _ring(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Positioned(
      left: 16,
      right: 16,
      // Below the header and its divider, and below where the pinned prompt
      // shows under them, so it never covers that.
      top: kGaiaHeaderHeight + 1 + 8 + GaiaPinnedPrompt.heightOf(context) + 8,
      child: toast,
    );
  }

  /// Gaia's frosted shell, around the toast's content.
  Widget _ring() {
    return CustomPaint(
      // The shell is see-through: its shadow skips what's under it.
      painter: GaiaShadowAround(
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.45),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
        radius: _radius,
      ),
      child: GaiaGlowRing(
        radius: _radius,
        hovered: _hovered,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
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
                        maxLines: 8,
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
              if (widget.onUndo case final undo?) ...[
                const SizedBox(width: 12),
                GaiaButton(
                  label: 'Undo',
                  icon: Icons.undo,
                  size: 30,
                  padding: 10,
                  onPressed: () {
                    undo();
                    unawaited(_dismiss());
                  },
                ),
              ],
            ],
          ),
        ),
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
