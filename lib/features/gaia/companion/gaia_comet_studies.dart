import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_comet.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';

/// Debug-menu studies of the sky's comet: each look on its own patch of
/// night, all on one clock, at the size the sky draws it. Choosing one puts
/// it on the sky.
class GaiaCometStudies extends StatefulWidget {
  const GaiaCometStudies({super.key, required this.debug});

  final GaiaDebug debug;

  @override
  State<GaiaCometStudies> createState() => _GaiaCometStudiesState();
}

class _GaiaCometStudiesState extends State<GaiaCometStudies>
    with SingleTickerProviderStateMixin {
  final _time = ValueNotifier(0.0);
  late final Ticker _ticker = createTicker(
    (elapsed) => _time.value = elapsed.inMicroseconds / 1e6,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final run =
        !MediaQuery.disableAnimationsOf(context) && GaiaAmbient.of(context);
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget tile(_CometTile painter) => Container(
      height: 230,
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const RadialGradient(
          center: Alignment(0.3, -0.4),
          radius: 1.2,
          colors: [Color(0xFF111A2B), Color(0xFF070A12)],
        ),
      ),
      child: RepaintBoundary(child: CustomPaint(painter: painter)),
    );
    Widget caption(
      String label,
      String description, {
      required bool onSky,
      required VoidCallback choose,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
            ChoiceChip(
              label: const Text('On the sky'),
              visualDensity: VisualDensity.compact,
              selected: onSky,
              onSelected: (_) => choose(),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(description, style: muted),
      ],
    );
    final debug = widget.debug;
    return ListenableBuilder(
      listenable: debug,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Heads, on Great V2's tails: at the size the sky draws them, and "
            'three times as large on the right. Pick one for the sky\'s '
            "comets, on whichever tails it's given below.",
            style: muted,
          ),
          for (final head in GaiaCometHead.values) ...[
            const SizedBox(height: 12),
            tile(_CometTile(_time, GaiaCometLook.greatV2, head: head)),
            caption(
              head.label,
              head.description,
              onSky: debug.skyCometHead == head,
              choose: () => debug.setSkyCometHead(head),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            "Tails, each with its own head here. Pick one for the sky's "
            "comets; the sky panel's Send comet shows it there.",
            style: muted,
          ),
          for (final look in GaiaCometLook.values) ...[
            const SizedBox(height: 12),
            tile(_CometTile(_time, look)),
            caption(
              look.label,
              look.description,
              onSky: debug.skyComet == look,
              choose: () => debug.setSkyComet(look),
            ),
          ],
        ],
      ),
    );
  }
}

/// Faint stars behind the comets, the same in every tile: each a share of
/// the tile across and down, and its brightness.
final _stars = () {
  final random = Random(7);
  return [
    for (var i = 0; i < 60; i++)
      (
        random.nextDouble(),
        random.nextDouble(),
        0.15 + 0.6 * random.nextDouble(),
      ),
  ];
}();

/// A comet on its patch of night; with a [head], that head on [look]'s
/// tails, beside a close-up of it.
class _CometTile extends CustomPainter {
  _CometTile(this.time, this.look, {this.head}) : super(repaint: time);

  final ValueListenable<double> time;
  final GaiaCometLook look;
  final GaiaCometHead? head;

  /// How much larger the close-up is.
  static const _closeUp = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final star = Paint();
    for (final (x, y, a) in _stars) {
      star.color = Colors.white.withValues(alpha: a);
      canvas.drawCircle(Offset(x * size.width, y * size.height), 0.8, star);
    }
    // The tails up and to the right, as the sky's point away from the sun
    // below the horizon.
    void comet(Offset at, double scale) {
      canvas
        ..save()
        ..translate(at.dx, at.dy)
        ..scale(scale)
        ..rotate(-0.6);
      paintGaiaComet(
        canvas,
        look,
        length: min(170, size.width * 0.55),
        bend: -1,
        time: time.value,
        head: head,
      );
      canvas.restore();
    }

    if (head == null) {
      comet(Offset(size.width * 0.3, size.height * 0.78), 1);
      return;
    }
    final split = size.width * 0.55;
    canvas
      ..save()
      ..clipRect(Rect.fromLTRB(0, 0, split, size.height));
    comet(Offset(size.width * 0.15, size.height * 0.78), 1);
    canvas
      ..restore()
      ..drawLine(
        Offset(split, 12),
        Offset(split, size.height - 12),
        Paint()..color = Colors.white.withValues(alpha: 0.08),
      )
      ..save()
      ..clipRect(Rect.fromLTRB(split, 0, size.width, size.height));
    comet(
      Offset(split + (size.width - split) * 0.35, size.height * 0.62),
      _closeUp,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CometTile oldDelegate) =>
      oldDelegate.look != look || oldDelegate.head != head;
}
