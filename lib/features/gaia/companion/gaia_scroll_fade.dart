import 'package:flutter/material.dart';

/// How far a [GaiaScrollFade]'s edge fades.
const kGaiaScrollFade = 20.0;

/// A scrolling list in one of Gaia's panels, its top and bottom edges fading
/// out while there's more past them: a row cut through its text at the
/// panel's edge reads as broken, and one fading out as carrying on. [child]
/// holds the vertical scrollable.
class GaiaScrollFade extends StatefulWidget {
  const GaiaScrollFade({super.key, required this.child});

  final Widget child;

  @override
  State<GaiaScrollFade> createState() => _GaiaScrollFadeState();
}

class _GaiaScrollFadeState extends State<GaiaScrollFade> {
  var _above = false;
  var _below = false;

  bool _onScroll(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return false;
    final above = metrics.extentBefore > 0.5;
    final below = metrics.extentAfter > 0.5;
    if (above != _above || below != _below) {
      // A metrics notification comes during layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _above = above;
          _below = below;
        });
      });
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
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: _above ? 0 : 1),
                  Colors.white,
                  Colors.white,
                  Colors.white.withValues(alpha: _below ? 0 : 1),
                ],
                stops: [0, fade, 1 - fade, 1],
              ).createShader(bounds);
            },
            child: widget.child,
          ),
        ),
      );
}
