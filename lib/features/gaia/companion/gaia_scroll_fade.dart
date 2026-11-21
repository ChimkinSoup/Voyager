import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';

/// How far a [GaiaScrollFade]'s edge fades.
const kGaiaScrollFade = 28.0;

/// A scrolling list in one of Gaia's panels, its top and bottom edges fading
/// out while there's more past them: a row cut through its text at the
/// panel's edge reads as broken, and one fading out as carrying on. Each
/// eases in over the list's first [kGaiaScrollFade] from its end, as the
/// chat's do, rather than snapping on. [child]
/// holds the vertical scrollable.
class GaiaScrollFade extends StatefulWidget {
  const GaiaScrollFade({super.key, required this.child});

  final Widget child;

  @override
  State<GaiaScrollFade> createState() => _GaiaScrollFadeState();
}

class _GaiaScrollFadeState extends State<GaiaScrollFade> {
  /// How much of each edge's fade shows, 0 to 1.
  var _above = 0.0;
  var _below = 0.0;

  bool _onScroll(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return false;
    final above = (metrics.extentBefore / kGaiaScrollFade).clamp(0.0, 1.0);
    final below = (metrics.extentAfter / kGaiaScrollFade).clamp(0.0, 1.0);
    if (above == _above && below == _below) return false;
    void update() {
      if (!mounted) return;
      setState(() {
        _above = above;
        _below = below;
      });
    }

    // Mid-frame, once it's done. Otherwise at once: a metrics notification
    // comes after the frame, and a post-frame callback then would wait for
    // a frame nothing has asked for.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => update());
    } else {
      update();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) =>
            notification.depth == 0 && _onScroll(notification.metrics),
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: (notification) =>
              notification.depth == 0 && _onScroll(notification.metrics),
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) {
              // No more than half of a short list.
              final fade = (kGaiaScrollFade / bounds.height).clamp(0.0, 0.5);
              // [shown] of the way from opaque to the full fade.
              ({List<Color> colors, List<double> stops}) edge(
                double shown, {
                required double clear,
                required double full,
              }) {
                final (:colors, :stops) = gaiaFade(
                  Colors.white,
                  clear: clear,
                  full: full,
                );
                return (
                  colors: [
                    for (final color in colors)
                      Colors.white.withValues(alpha: 1 - shown * (1 - color.a)),
                  ],
                  stops: stops,
                );
              }

              final top = _above > 0
                  ? edge(_above, clear: 0, full: fade)
                  : (colors: [Colors.white], stops: [0.0]);
              final bottom = _below > 0
                  ? edge(_below, clear: 1, full: 1 - fade)
                  : (colors: [Colors.white], stops: [1.0]);
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [...top.colors, ...bottom.colors],
                stops: [...top.stops, ...bottom.stops],
              ).createShader(bounds);
            },
            child: widget.child,
          ),
        ),
      );
}
