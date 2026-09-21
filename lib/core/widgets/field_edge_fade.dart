import 'package:flutter/material.dart';

/// Clips a multi-line field's paragraph at the border, dissolving it into the
/// fill over the gutter rather than cutting it off square.
///
/// A multi-line Voyager field paints its text on past its scroll viewport,
/// through the vertical content padding, so a scrolled body reads flush to
/// the border (MULTILINE_FIELD_SCROLL_INSETS.md). That gutter is also where
/// [NotchedFieldBorder] floats its label — centred on the top border line, so
/// its lower half hangs into the content — and scrolled text printed straight
/// through the label, leaving the two illegible on top of each other.
///
/// Pass the field's *resolved* content padding, density shift included (the
/// same [EdgeInsets] the overlay layers are positioned from). The fade then
/// runs exactly the gutter the paragraph only ever reaches by scrolling, so
/// text at rest — the first and last line of a body that fits — is never
/// touched.
class FieldEdgeFade extends StatelessWidget {
  const FieldEdgeFade({super.key, required this.padding, required this.child});

  /// The field's resolved content padding; [EdgeInsets.top] and
  /// [EdgeInsets.bottom] set how far each fade runs.
  final EdgeInsets padding;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The mask only covers the child's own bounds, so anything painted
    // outside them — a single-line paragraph scrolled sideways — comes
    // through it unfaded. The clip is what stops that at the border.
    return ClipRect(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: _mask,
        child: child,
      ),
    );
  }

  Shader _mask(Rect bounds) {
    final height = bounds.height;
    final top = padding.top.clamp(0.0, height);
    final bottom = padding.bottom.clamp(0.0, height);
    // A field shorter than its own gutters would come out all gradient and no
    // text; leave it alone.
    if (height <= 0 || top + bottom >= height) {
      return const LinearGradient(
        colors: [Colors.black, Colors.black],
      ).createShader(bounds);
    }

    final colors = <Color>[];
    final stops = <double>[];
    for (var i = 0; i < _fadeProfile.length; i++) {
      colors.add(Colors.black.withValues(alpha: _fadeProfile[i].$2));
      stops.add(_fadeProfile[i].$1 * top / height);
    }
    for (var i = _fadeProfile.length - 1; i >= 0; i--) {
      colors.add(Colors.black.withValues(alpha: _fadeProfile[i].$2));
      stops.add(1 - _fadeProfile[i].$1 * bottom / height);
    }
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: colors,
      stops: stops,
    ).createShader(bounds);
  }
}

/// Alpha across one fade band as (distance from the border, opacity), where 0
/// is the border itself and 1 the first line of text that rests there.
///
/// Deliberately not a straight ramp. The floated label's ink reaches about 8px
/// past the top border (12px of 1.35 leading, halved by [NotchedFieldBorder]'s
/// `-floatedHeight / 2`, less the descender room under its baseline) — better
/// two thirds of a ~12px gutter, so a linear fade would still print glyphs at
/// better than half strength right through the label. Weighted like this they
/// are under 4% of their opacity everywhere the label's own ink lands, and the
/// dissolve still runs over ~4px rather than stopping dead.
const List<(double, double)> _fadeProfile = [
  (0.0, 0.0),
  (0.55, 0.01),
  (0.7, 0.05),
  (0.82, 0.18),
  (0.92, 0.5),
  (1.0, 1.0),
];
