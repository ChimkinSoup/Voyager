import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/theme/voyager_theme.dart';

/// How much a [GlassSurface] separates itself from what's behind it.
///
/// Mirrors the Apple materials guidance: heavier materials read as
/// structural (a sheet or dialog sitting over the whole app), lighter
/// materials draw attention to something interactive without stealing focus
/// (a popover, a dropdown). Never stack two [light] surfaces — legibility
/// collapses.
enum GlassWeight { light, heavy }

/// A translucent "material" surface — the general-purpose version of the
/// blur/gradient/specular-border treatment [GlassButton] uses, for anything
/// that floats over content: popovers, dropdowns, dialogs, sheets, toolbars.
///
/// Content scrolls/sits underneath and shows through the blur; this widget
/// does not clip or constrain [child] beyond rounding its corners.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.weight = GlassWeight.light,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.tint,
    this.accentBorder,
  });

  final Widget child;
  final GlassWeight weight;
  final BorderRadius borderRadius;

  /// Base fill color. Defaults to the theme's card surface.
  final Color? tint;

  /// When set, draws a colored border instead of the neutral hairline —
  /// used where the surface needs to read as belonging to a specific item
  /// (e.g. a popover anchored to a colored tag).
  final Color? accentBorder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vc = VoyagerColors.of(context);
    // Flutter has no cross-platform "prefers-reduced-transparency" signal;
    // `highContrast` is the closest accessibility proxy it exposes for
    // wanting a near-solid, clearly-bordered surface instead of a blur.
    final nearSolid = MediaQuery.maybeOf(context)?.highContrast ?? false;
    final baseTint = tint ?? theme.cardColor;

    final isHeavy = weight == GlassWeight.heavy;
    final blurSigma = isHeavy ? 24.0 : 14.0;
    final fillAlpha = nearSolid ? 0.97 : (isHeavy ? 0.82 : 0.72);
    final shadowBlur = isHeavy ? 28.0 : 16.0;
    final shadowAlpha = isHeavy ? vc.strongShadowAlpha : vc.subtleShadowAlpha;

    Widget surface = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: nearSolid
            ? ImageFilter.blur(sigmaX: 0, sigmaY: 0)
            : ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: baseTint.withValues(alpha: fillAlpha),
            borderRadius: borderRadius,
          ),
          // The border is drawn *over* the content, not behind it.
          //
          // A [DecoratedBox] does not inset its child by the border it paints,
          // so a full-bleed child — a dropdown whose first and last rows run
          // edge to edge, a list with a selected row at either end — lands on
          // top of the border and swallows it: the surface loses its outline
          // for exactly the rows a user is most likely to be looking at.
          // Insetting the child instead would leave those same rows short of
          // the edge, with a strip of the fill showing through between the
          // highlight and the border. Painting the border last is what lets
          // the content run all the way out *and* keeps the outline crisp.
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(
                color:
                    accentBorder?.withValues(alpha: 0.85) ?? vc.strongHairline,
                width: accentBorder != null ? 2.0 : 1.0,
              ),
            ),
            child: Stack(
              children: [
                // Top gloss: a light material catches more light than a heavy
                // one.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: isHeavy ? 12 : 20,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                          top: borderRadius.topLeft,
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            vc.highlightWash.withValues(
                              alpha: isHeavy ? 0.05 : 0.08,
                            ),
                            vc.highlightWash.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                child,
              ],
            ),
          ),
        ),
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: vc.shadow.withValues(alpha: shadowAlpha),
            blurRadius: shadowBlur * vc.shadowBlurScale,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: surface,
    );
  }
}

/// Opens [builder] in the app's standard bottom sheet chrome: rounded top
/// corners, translucent [GlassWeight.heavy] material background instead of a
/// solid fill, drag-to-dismiss with velocity (built into [showModalBottomSheet]
/// via [enableDrag]).
Future<T?> showVoyagerSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  BorderRadius borderRadius = const BorderRadius.vertical(
    top: Radius.circular(20),
  ),
  BoxConstraints? constraints,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    constraints: constraints,
    shape: RoundedRectangleBorder(borderRadius: borderRadius),
    builder: (ctx) => GlassSurface(
      weight: GlassWeight.heavy,
      borderRadius: borderRadius,
      child: builder(ctx),
    ),
  );
}

/// Progress at which the surface is fully opaque — early enough that the scale
/// and the arriving blur are still running when the opacity layer drops out.
const double _kOpaqueAt = 0.45;

/// Animates a [GlassSurface]'s entrance/exit as a material arriving, not a
/// plain fade: blur radius and scale move together. Drive [t] (0 = hidden,
/// 1 = shown) from a spring, not a curve, so it stays interruptible.
///
/// The blur ramps what is *behind* the surface, so the backdrop frosts over as
/// the surface arrives instead of the surface simply fading in over a sharp
/// background. That is a second [BackdropFilter] stacked on the one the
/// [GlassSurface] already owns, and it is only paid for while [t] is in
/// flight — it collapses to nothing at rest, and is skipped entirely under
/// reduced motion, where a surface materializing is the effect being opted
/// out of.
class MaterializeTransition extends StatelessWidget {
  const MaterializeTransition({
    super.key,
    required this.t,
    required this.child,
    this.alignment = Alignment.center,
    this.blurSigma = 12.0,
  });

  final Animation<double> t;
  final Widget child;
  final Alignment alignment;

  /// Peak sigma of the arriving blur, reached at `t == 0` and falling to zero
  /// once the surface has fully materialized.
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final reduced = VoyagerMotion.reduced(context);
    return AnimatedBuilder(
      animation: t,
      child: child,
      builder: (context, child) {
        final v = t.value.clamp(0.0, 1.5);
        final shown = v.clamp(0.0, 1.0);
        Widget surface = Transform.scale(
          scale: 0.92 + 0.08 * v,
          alignment: alignment,
          child: child,
        );
        // At rest there is no filter in the tree at all, so a settled surface
        // costs exactly what it did before.
        final sigma = reduced ? 0.0 : blurSigma * (1 - shown);
        if (sigma > 0.01) {
          surface = BackdropFilter(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: surface,
          );
        }
        // Opaque well before the scale and the arriving blur have finished.
        // While opacity is fractional the surface is inside an opacity layer,
        // and a layer confines what the [GlassSurface]'s own BackdropFilter
        // can sample — it frosts an empty backdrop until the layer goes away.
        // Reaching 1.0 early hands that transition back to the eye while the
        // surface is still visibly moving, instead of letting it land as a
        // snap on an otherwise settled popover. Kept in the tree rather than
        // dropped at 1.0 so the child never changes depth mid-animation;
        // `Opacity` skips the layer on its own at full opacity.
        return Opacity(
          opacity: (shown / _kOpaqueAt).clamp(0.0, 1.0),
          child: surface,
        );
      },
    );
  }
}
