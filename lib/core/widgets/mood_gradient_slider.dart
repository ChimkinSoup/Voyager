import 'package:flutter/material.dart';

class MoodGradientSlider extends StatelessWidget {
  const MoodGradientSlider({
    super.key,
    required this.value,
    required this.accent,
    required this.onChanged,
  });

  final int value;
  final Color accent;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 8,
        activeTrackColor: Colors.transparent,
        inactiveTrackColor: Colors.transparent,
        overlayColor: accent.withValues(alpha: 0.16),
        thumbColor: accent,
        valueIndicatorColor: accent,
        trackShape: GradientSliderTrackShape(
          gradient: LinearGradient(colors: [Colors.white, accent]),
          inactiveColor: Theme.of(context).colorScheme.surface,
        ),
      ),
      child: Slider(
        min: 1,
        max: 10,
        divisions: 9,
        label: '$value',
        value: value.toDouble(),
        onChanged: (next) => onChanged(next.round()),
      ),
    );
  }
}

class GradientSliderTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const GradientSliderTrackShape({
    required this.gradient,
    required this.inactiveColor,
  });

  final LinearGradient gradient;
  final Color inactiveColor;

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
    if (activeRect.width > 0) {
      final activePaint = Paint()
        ..shader = gradient.createShader(activeRect);
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(activeRect, radius),
        activePaint,
      );
    }
  }
}
