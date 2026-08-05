/// Progressive resistance for dragging past a boundary — the further past
/// [dimension] the drag goes, the less it follows, instead of stopping hard.
///
/// [overshoot] is the raw distance already past the boundary; [dimension] is
/// the size of the scrollable/draggable region (used to scale how quickly
/// resistance ramps up). Mirrors UIScrollView's rubber-banding constant.
double rubberBand(double overshoot, double dimension, [double constant = 0.55]) {
  if (dimension <= 0) return 0;
  final magnitude =
      (overshoot.abs() * dimension * constant) / (dimension + constant * overshoot.abs());
  return overshoot.isNegative ? -magnitude : magnitude;
}

/// Projects where a flick/pan gesture will come to rest given its release
/// [velocity] (px/s), the way scroll deceleration does — used to pick which
/// snap point a flick should land on, then hand the same velocity to the
/// spring that animates there.
///
/// [decelerationRate] close to 1.0 (0.998) reads as a normal scroll-flick
/// carry; lower (~0.99) reads snappier/shorter.
double projectMomentum(double velocity, [double decelerationRate = 0.998]) {
  return (velocity / 1000) * decelerationRate / (1 - decelerationRate);
}
