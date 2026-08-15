import 'package:flutter/material.dart';
import 'package:voyager/core/theme/voyager_spacing.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';

/// Single-field sheet for naming or renaming an exercise. Returns the trimmed
/// name, or null when cancelled.
Future<String?> showWorkoutNameModal(
  BuildContext context, {
  required String title,
  String? initialValue,
  String hintText = 'Name',
}) {
  return showVoyagerSheet<String>(
    context: context,
    builder: (ctx) => _WorkoutNameModal(
      title: title,
      initialValue: initialValue,
      hintText: hintText,
    ),
  );
}

class _WorkoutNameModal extends StatefulWidget {
  const _WorkoutNameModal({
    required this.title,
    this.initialValue,
    required this.hintText,
  });

  final String title;
  final String? initialValue;
  final String hintText;

  @override
  State<_WorkoutNameModal> createState() => _WorkoutNameModalState();
}

class _WorkoutNameModalState extends State<_WorkoutNameModal> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: VoyagerSpacing.xl,
        right: VoyagerSpacing.xl,
        top: VoyagerSpacing.xl,
        bottom: VoyagerSpacing.xl + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: VoyagerSpacing.lg),
          VoyagerTextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(hintText: widget.hintText),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: VoyagerSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GlassButton(
                label: 'Cancel',
                dense: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: VoyagerSpacing.sm),
              GlassButton(
                label: 'Save',
                dense: true,
                color: theme.colorScheme.primary,
                onPressed: _submit,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
