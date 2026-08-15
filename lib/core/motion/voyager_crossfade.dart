import 'package:flutter/widgets.dart';
import 'package:voyager/core/motion/motion_prefs.dart';

/// How far an outgoing surface recedes (and an incoming one starts) during a
/// Voyager crossfade. A replacing surface pushes what it covers back rather
/// than simply swapping in place.
const double kVoyagerCrossfadeRecede = 0.04;

/// Duration of the full-motion Hub-style crossfade (opacity + slight scale).
const Duration kVoyagerCrossfadeDuration = Duration(milliseconds: 400);

/// Keeps every child mounted and crossfades between them by [index].
///
/// With [fadeIncoming] true (default), both sides fade and scale — the Study
/// Hub ↔ Workbench / Finance recipe. With [fadeIncoming] false, the arriving
/// child stays at full opacity (so [BackdropFilter] glass keeps sampling the
/// real backdrop) while the departing child fades and recedes off the top of
/// it; the arrive still enlarges from `1 - [recede]`. Reduced motion drops the
/// scale and shortens to [VoyagerMotion.crossfade].
class VoyagerCrossfadeIndex extends StatefulWidget {
  const VoyagerCrossfadeIndex({
    super.key,
    required this.index,
    required this.children,
    this.duration = kVoyagerCrossfadeDuration,
    this.recede = kVoyagerCrossfadeRecede,
    this.fadeIncoming = true,
  }) : assert(children.length > 0, 'children must not be empty'),
       assert(index >= 0, 'index must be >= 0');

  /// Which child is the settled (or destination) view.
  final int index;

  /// All pages stay in the tree so scroll position and local state survive
  /// round-trips. Only the active pair is painted during a transition.
  final List<Widget> children;

  final Duration duration;

  /// Fractional scale inset applied at the start of an entrance / end of an
  /// exit. Zero disables the scale even when motion is allowed.
  final double recede;

  /// When false, the arriving child is never wrapped in an opacity layer —
  /// required for pages that use glass / [BackdropFilter].
  final bool fadeIncoming;

  @override
  State<VoyagerCrossfadeIndex> createState() => _VoyagerCrossfadeIndexState();
}

class _VoyagerCrossfadeIndexState extends State<VoyagerCrossfadeIndex>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );

  /// View that is fading out. Equals [_toIndex] when settled.
  late int _fromIndex = widget.index;

  /// View that is fading in (and the settled index once [ _progress ] is 1).
  late int _toIndex = widget.index;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _progress.duration = VoyagerMotion.reduced(context)
        ? VoyagerMotion.crossfade
        : widget.duration;
  }

  @override
  void didUpdateWidget(covariant VoyagerCrossfadeIndex oldWidget) {
    super.didUpdateWidget(oldWidget);

    final next = widget.index.clamp(0, widget.children.length - 1);
    if (next == _toIndex) {
      if (widget.duration != oldWidget.duration) {
        _progress.duration = VoyagerMotion.reduced(context)
            ? VoyagerMotion.crossfade
            : widget.duration;
      }
      return;
    }

    // Mid-flight retarget: keep whichever side is more visible as the new
    // outgoing, so a fast tap-through doesn't jump to an empty frame.
    if (_progress.value < 1) {
      _fromIndex = _progress.value >= 0.5 ? _toIndex : _fromIndex;
    } else {
      _fromIndex = _toIndex;
    }
    _toIndex = next;
    _progress.duration = VoyagerMotion.reduced(context)
        ? VoyagerMotion.crossfade
        : widget.duration;
    _progress.forward(from: 0);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = VoyagerMotion.reduced(context);
    final recede = reduced ? 0.0 : widget.recede;
    final last = widget.children.length - 1;
    final from = _fromIndex.clamp(0, last);
    final to = _toIndex.clamp(0, last);
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final t = _progress.value.clamp(0.0, 1.0);
        final transitioning = from != to && t < 1;
        // Glass-safe switches paint the depart *above* the arrive so the
        // dissolve reads correctly; mutual fades can stay in index order.
        final order = <int>[
          for (var i = 0; i < widget.children.length; i++)
            if (!(transitioning && !widget.fadeIncoming && i == from)) i,
          if (transitioning && !widget.fadeIncoming) from,
        ];
        return Stack(
          fit: StackFit.expand,
          children: [
            for (final i in order)
              _buildLayer(
                index: i,
                from: from,
                to: to,
                t: t,
                recede: recede,
                child: widget.children[i],
              ),
          ],
        );
      },
    );
  }

  Widget _buildLayer({
    required int index,
    required int from,
    required int to,
    required double t,
    required double recede,
    required Widget child,
  }) {
    final bool participating;
    final double opacity;
    final double scale;

    if (index == to && (index == from || t >= 1)) {
      // Settled on this child (including after a completed transition, when
      // [from] still names the previous page until the next switch).
      participating = true;
      opacity = 1;
      scale = 1;
    } else if (index == to) {
      participating = true;
      opacity = widget.fadeIncoming ? t : 1;
      scale = 1 - recede * (1 - t);
    } else if (index == from && t < 1) {
      participating = true;
      opacity = 1 - t;
      scale = 1 - recede * t;
    } else {
      participating = false;
      opacity = 0;
      scale = 1;
    }

    // Idle siblings stay mounted (keep-alive) but offstage so they neither
    // paint nor hit-test. Tickers stay parked until they participate again.
    if (!participating) {
      return Offstage(
        child: TickerMode(enabled: false, child: child),
      );
    }

    Widget layer = child;
    if (recede > 0 && scale != 1) {
      layer = Transform.scale(scale: scale, child: layer);
    }
    // Only wrap in Opacity when fractional — a 1.0 Opacity still creates a
    // layer that confines BackdropFilter sampling on glass-safe arrivals.
    if (opacity < 1) {
      layer = Opacity(opacity: opacity, child: layer);
    }

    final interactive = index == to;
    return TickerMode(
      enabled: true,
      child: IgnorePointer(
        ignoring: !interactive,
        child: ExcludeSemantics(
          excluding: !interactive,
          child: layer,
        ),
      ),
    );
  }
}
