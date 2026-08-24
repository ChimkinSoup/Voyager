import 'package:flutter/material.dart';

class MoodGradientSlider extends StatelessWidget {
  const MoodGradientSlider({
    super.key,
    required this.value,
    required this.accent,
    required this.onChanged,
  });

  /// `null` means *not recorded*: the thumb renders hollow, the track is left
  /// unfilled and the value indicator reads '—', so the page never claims a
  /// mood the analytics average is excluding.
  ///
  /// Entries no longer arrive here that way — they are created at
  /// `kDefaultMood` and the v85 migration backfilled the ones that predated
  /// it. What is left is legacy: an import, or a copy synced down from an
  /// older build. The unrecorded rendering stays for those.
  final int? value;
  final Color accent;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final recorded = value;
    final surface = Theme.of(context).colorScheme.surface;
    var sliderTheme = SliderTheme.of(context).copyWith(
      trackHeight: 8,
      activeTrackColor: Colors.transparent,
      inactiveTrackColor: Colors.transparent,
      overlayColor: accent.withValues(alpha: 0.16),
      thumbColor: accent,
      valueIndicatorColor: accent,
      trackShape: GradientSliderTrackShape(
        // White at the low-mood end in both themes, not a theme-derived wash
        // — on cream that wash resolved to `onSurface`, which read as a
        // black-to-accent ramp rather than the intended pale one.
        gradient: LinearGradient(
          colors: [Colors.white, accent],
        ),
        inactiveColor: surface,
        showActive: recorded != null,
      ),
    );
    if (recorded == null) {
      sliderTheme = sliderTheme.copyWith(
        thumbShape: HollowSliderThumbShape(fillColor: surface),
      );
    }
    return SliderTheme(
      data: sliderTheme,
      child: Slider(
        min: 0,
        max: 10,
        divisions: 10,
        label: recorded?.toString() ?? '—',
        // Parked at the midpoint while unrecorded so the thumb has somewhere
        // to sit; the hollow shape and empty track are what say it is unset.
        value: (recorded ?? 5).toDouble(),
        onChanged: (next) => onChanged(next.round()),
      ),
    );
  }
}

/// The thumb for a slider whose value has not been recorded: a ring in the
/// accent colour rather than a disc, so it reads as a placeholder position.
class HollowSliderThumbShape extends SliderComponentShape {
  const HollowSliderThumbShape({required this.fillColor, this.radius = 10});

  final Color fillColor;
  final double radius;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return Size.fromRadius(radius);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final color = sliderTheme.thumbColor ?? fillColor;
    canvas.drawCircle(center, radius - 1, Paint()..color = fillColor);
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }
}

class GradientSliderTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const GradientSliderTrackShape({
    required this.gradient,
    required this.inactiveColor,
    this.showActive = true,
  });

  final LinearGradient gradient;
  final Color inactiveColor;

  /// False leaves the whole track in [inactiveColor] — what an unrecorded
  /// value looks like, where a filled ramp would claim a mood was chosen.
  final bool showActive;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 4;
    final trackLeft = offset.dx;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(rect.height / 2);
    final inactivePaint = Paint()..color = inactiveColor;
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      inactivePaint,
    );

    final activeRect = Rect.fromLTRB(
      rect.left,
      rect.top,
      thumbCenter.dx.clamp(rect.left, rect.right),
      rect.bottom,
    );
    if (showActive && activeRect.width > 0) {
      final activePaint = Paint()
        ..shader = gradient.createShader(activeRect);
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(activeRect, radius),
        activePaint,
      );
    }
  }
}
