import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:voyager/core/motion/motion_prefs.dart';

/// Duration of the full-motion Hub-style crossfade.
const Duration kVoyagerCrossfadeDuration = Duration(milliseconds: 400);

/// Keeps every child mounted and crossfades between them by [index].
///
/// With [fadeIncoming] true (default), both sides fade — the Finance recipe.
/// With [fadeIncoming] false, the arriving child stays at full opacity (so
/// [BackdropFilter] glass keeps sampling the real backdrop) while the
/// departing child fades off the top of it. Reduced motion shortens to
/// [VoyagerMotion.crossfade].
///
/// Nothing scales: a page whose scale changes every frame re-rasterizes all
/// of its text every frame, which held switches to about 40 FPS.
class VoyagerCrossfadeIndex extends StatefulWidget {
  const VoyagerCrossfadeIndex({
    super.key,
    required this.index,
    required this.children,
    this.duration = kVoyagerCrossfadeDuration,
    this.fadeIncoming = true,
  }) : assert(children.length > 0, 'children must not be empty'),
       assert(index >= 0, 'index must be >= 0');

  /// Which child is the settled (or destination) view.
  final int index;

  /// All pages stay in the tree so scroll position and local state survive
  /// round-trips. Only the active pair is painted during a transition.
  final List<Widget> children;

  final Duration duration;

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
    required Widget child,
  }) {
    final bool participating;
    final double opacity;

    if (index == to && (index == from || t >= 1)) {
      // Settled on this child (including after a completed transition, when
      // [from] still names the previous page until the next switch).
      participating = true;
      opacity = 1;
    } else if (index == to) {
      participating = true;
      opacity = widget.fadeIncoming ? t : 1;
    } else if (index == from && t < 1) {
      participating = true;
      opacity = 1 - t;
    } else {
      participating = false;
      opacity = 0;
    }

    // Idle siblings stay mounted (keep-alive) but offstage so they neither
    // paint nor hit-test. Tickers stay parked until they participate again.
    //
    // Every wrapper is always present, whatever the state, and the key lets
    // the Stack reorder a layer without remounting it. Adding or dropping a
    // wrapper mid-switch would change the widget type above [child] and
    // rebuild the whole page from scratch on the first and last frames.
    final interactive = index == to;
    return KeyedSubtree(
      key: ValueKey(index),
      child: Offstage(
        offstage: !participating,
        child: TickerMode(
          enabled: participating,
          child: IgnorePointer(
            ignoring: !interactive,
            child: ExcludeSemantics(
              excluding: !interactive,
              child: VoyagerFade(
                opacity: opacity,
                // The fade repaints every frame; this keeps that to
                // re-compositing the page instead of re-recording it.
                child: RepaintBoundary(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [Opacity] that adds no layer when fully opaque.
///
/// [Opacity] pushes an opacity layer even at 1.0, and a layer confines what a
/// [BackdropFilter] under it can sample, so glass on a settled page would
/// frost an empty backdrop. Swapping [Opacity] in and out avoids that but
/// changes the widget tree, rebuilding the page. This keeps one widget in
/// place and only composites a layer while the opacity is fractional.
class VoyagerFade extends SingleChildRenderObjectWidget {
  const VoyagerFade({super.key, required this.opacity, super.child});

  final double opacity;

  @override
  RenderVoyagerFade createRenderObject(BuildContext context) =>
      RenderVoyagerFade(opacity);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderVoyagerFade renderObject,
  ) {
    renderObject.opacity = opacity;
  }
}

class RenderVoyagerFade extends RenderProxyBox {
  RenderVoyagerFade(double opacity)
    : _alpha = Color.getAlphaFromOpacity(opacity);

  int _alpha;

  set opacity(double value) {
    final alpha = Color.getAlphaFromOpacity(value);
    if (alpha == _alpha) return;
    final didNeedCompositing = alwaysNeedsCompositing;
    _alpha = alpha;
    if (didNeedCompositing != alwaysNeedsCompositing) {
      markNeedsCompositingBitsUpdate();
    }
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  bool get alwaysNeedsCompositing =>
      child != null && _alpha > 0 && _alpha < 255;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null || _alpha == 0) {
      layer = null;
      return;
    }
    if (_alpha == 255) {
      layer = null;
      context.paintChild(child, offset);
      return;
    }
    layer = context.pushOpacity(
      offset,
      _alpha,
      super.paint,
      oldLayer: layer as OpacityLayer?,
    );
  }

  /// Ink under a hidden child is painted by a [Material] above it, which asks
  /// this before drawing — without it, a faded-out page leaves its tile fills
  /// behind.
  @override
  bool paintsChild(RenderBox child) => _alpha > 0;

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (child != null && _alpha != 0) visitor(child!);
  }
}
