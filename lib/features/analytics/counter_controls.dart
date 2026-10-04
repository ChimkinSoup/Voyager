import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';

/// Changes a counter by ±1 on a day — `(trackerId, day, delta)` — or null
/// while this device's id is still unresolved.
///
/// Null rather than a write under the placeholder id: every device shares
/// that placeholder, so two devices tapping in their first moments after
/// launch would land on one row and overwrite each other's taps.
///
/// App-scoped for the same reason as [trackerCacheInvalidatorProvider]: the
/// write outlives the row that started it when taps come quickly.
final counterStepProvider =
    Provider<Future<void> Function(String, DateTime, int)?>((ref) {
      final deviceId = ref.watch(deviceIdProvider);
      if (deviceId == kUnresolvedDeviceId) return null;
      final repository = ref.watch(trackerRepositoryProvider);
      return (trackerId, day, delta) async {
        await repository.adjustCounter(
          trackerId: trackerId,
          day: day,
          deviceId: deviceId,
          delta: delta,
        );
        ref.invalidate(counterAdjustmentsProvider(trackerId));
      };
    });

/// A counter's change as the log and hover bubble print it: `+3`, `-2`, `0`.
String formatCounterChange(int change) => change > 0 ? '+$change' : '$change';

/// `[−] value [+]`. Each press is one step; holding doesn't repeat.
class CounterStepper extends StatelessWidget {
  const CounterStepper({
    super.key,
    required this.value,
    required this.color,
    required this.onStep,
    this.textStyle,
    this.iconSize = 16,
  });

  final int value;
  final Color color;

  /// Called with −1 or +1. Null disables both buttons.
  final ValueChanged<int>? onStep;
  final TextStyle? textStyle;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final onStep = this.onStep;
    Widget button(IconData icon, String tooltip, int delta) => IconButton(
      icon: Icon(icon, size: iconSize),
      tooltip: tooltip,
      color: color,
      visualDensity: VisualDensity.compact,
      onPressed: onStep == null ? null : () => onStep(delta),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(PhosphorIconsRegular.minus, 'Decrease', -1),
        const SizedBox(width: 8),
        Text('$value', style: textStyle),
        const SizedBox(width: 8),
        button(PhosphorIconsRegular.plus, 'Increase', 1),
      ],
    );
  }
}
