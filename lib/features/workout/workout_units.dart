import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/domain/models/workout_models.dart';

/// Display-unit conversion for the workout tracker.
///
/// Storage is kilograms everywhere; this is the only place that knows about
/// the user's unit preference, so flipping the setting can never rewrite a
/// logged set.
extension WeightUnitDisplay on WeightUnit {
  String get label => this == WeightUnit.kg ? 'kg' : 'lb';

  /// Wheel step in this unit — fine enough for microplates.
  double get step => this == WeightUnit.kg ? kWeightStepKg : kWeightStepLb;

  double get max => this == WeightUnit.kg ? kMaxWeightKg : kMaxWeightLb;

  double fromKilograms(double kg) =>
      this == WeightUnit.kg ? kg : kilogramsToPounds(kg);

  double toKilograms(double display) =>
      this == WeightUnit.kg ? display : poundsToKilograms(display);

  /// Number of stops on the weight wheel.
  int get wheelItemCount => (max / step).round() + 1;

  /// Nearest wheel stop to [kg]. Round-tripping through the wheel therefore
  /// quantises a synced value from a device on the other unit rather than
  /// leaving the wheel parked between two rows.
  int wheelIndexForKilograms(double kg) {
    final display = fromKilograms(kg);
    final index = (display / step).round();
    return index.clamp(0, wheelItemCount - 1);
  }

  double kilogramsForWheelIndex(int index) => toKilograms(index * step);

  /// Trims the trailing `.0` that whole-plate weights would otherwise carry,
  /// while keeping the half-step visible when it matters (`137.5`).
  String formatDisplay(double display) {
    final rounded = (display * 10).roundToDouble() / 10;
    if ((rounded - rounded.roundToDouble()).abs() < 0.05) {
      return rounded.round().toString();
    }
    return rounded.toStringAsFixed(1);
  }

  String formatKilograms(double kg) => formatDisplay(fromKilograms(kg));

  /// `135 lb` — the form used anywhere the unit isn't already established by
  /// a nearby label.
  String formatKilogramsWithUnit(double kg) => '${formatKilograms(kg)} $label';
}
