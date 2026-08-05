import 'dart:ui';

import 'package:flutter/material.dart';
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
            border: Border.all(
              color: accentBorder?.withValues(alpha: 0.85) ?? vc.strongHairline,
              width: accentBorder != null ? 2.0 : 1.0,
            ),
          ),
          child: Stack(
            children: [
              // Top gloss: a light material catches more light than a heavy one.
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
                          vc.highlightWash.withValues(alpha: isHeavy ? 0.05 : 0.08),
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

/// Animates a [GlassSurface]'s entrance/exit as a material arriving, not a
/// plain fade: blur radius and scale move together. Drive [t] (0 = hidden,
/// 1 = shown) from a spring, not a curve, so it stays interruptible.
class MaterializeTransition extends StatelessWidget {
  const MaterializeTransition({
    super.key,
    required this.t,
    required this.child,
    this.alignment = Alignment.center,
  });

  final Animation<double> t;
  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: t,
      child: child,
      builder: (context, child) {
        final v = t.value.clamp(0.0, 1.5);
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.92 + 0.08 * v,
            alignment: alignment,
            child: child,
          ),
        );
      },
    );
  }
}
