import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/constants/workout_constants.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/workout_models.dart';
import 'package:voyager/features/workout/workout_units.dart';

/// One weight × reps slice's fields and the numbers they stand for. Shared by
/// the exercise detail view's planned sets and the history editor's logged
/// ones.
class SegmentFields {
  SegmentFields(SetSegment segment, WeightUnit unit)
    : weightKg = segment.weightKg,
      repsValue = segment.reps,
      weight = TextEditingController(
        text: segment.weightKg > 0
            ? unit.formatKilograms(segment.weightKg)
            : '',
      ),
      reps = TextEditingController(text: '${segment.reps}');

  double weightKg;
  int repsValue;
  final TextEditingController weight;
  final TextEditingController reps;
  final weightFocus = FocusNode();
  final repsFocus = FocusNode();

  SetSegment get segment => SetSegment(weightKg: weightKg, reps: repsValue);

  /// Reads the fields into the numbers. Empty weight means "no planned load"
  /// (bodyweight), which is a real answer and stores as zero; unparseable text
  /// keeps the last good number.
  ///
  /// Storage is kilograms but the field shows the user's unit rounded to a
  /// tenth, so parsing that text back lands a hair off the kilograms it was
  /// formatted from — 60 kg displays as 132.3 lb and returns as 60.01. If the
  /// text still reads the same, the stored number is kept exactly, or simply
  /// tabbing through the card would drift it.
  void parse(WeightUnit unit) {
    repsValue = (int.tryParse(reps.text.trim()) ?? repsValue).clamp(
      1,
      kMaxReps,
    );
    final text = weight.text.trim();
    final display = text.isEmpty ? 0.0 : double.tryParse(text);
    if (display == null) return;
    final parsed = unit.toKilograms(display.clamp(0, unit.max).toDouble());
    if (unit.formatKilograms(parsed) != unit.formatKilograms(weightKg)) {
      weightKg = parsed;
    }
  }

  /// Rewrites both fields to the numbers they stand for.
  void normalize(WeightUnit unit) {
    parse(unit);
    _setText(weight, weightKg > 0 ? unit.formatKilograms(weightKg) : '');
    _setText(reps, '$repsValue');
  }

  static void _setText(TextEditingController controller, String text) {
    if (controller.text == text) return;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void dispose() {
    weight.dispose();
    reps.dispose();
    weightFocus.dispose();
    repsFocus.dispose();
  }
}

class SegmentNumberField extends StatelessWidget {
  const SegmentNumberField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.formatters,
    required this.width,
    this.suffixText,
    this.hintText,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final List<TextInputFormatter> formatters;
  final double width;
  final String? suffixText;
  final String? hintText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: VoyagerTextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        onSubmitted: (_) => focusNode.unfocus(),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.next,
        inputFormatters: formatters,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: hintText,
          suffixText: suffixText,
          suffixStyle: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
        ),
      ),
    );
  }
}
