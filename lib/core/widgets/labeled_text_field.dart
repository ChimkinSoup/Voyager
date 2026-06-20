import 'package:flutter/material.dart';

class LabeledTextField extends StatelessWidget {
  const LabeledTextField({
    super.key,
    required this.label,
    required this.controller,
    this.showLabel = true,
    this.expands = false,
    this.maxLines = 1,
    this.obscureText = false,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.focusNode,
  });

  final String label;
  final TextEditingController controller;
  final bool showLabel;
  final bool expands;
  final int? maxLines;
  final bool obscureText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final labelWidget = showLabel
        ? Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(label, style: Theme.of(context).textTheme.labelLarge),
            ),
          )
        : const SizedBox.shrink();

    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      expands: expands,
      maxLines: expands ? null : maxLines,
      obscureText: obscureText,
      enabled: enabled,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textAlignVertical: TextAlignVertical.top,
      decoration: const InputDecoration(contentPadding: EdgeInsets.all(16)),
    );

    if (expands) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showLabel) labelWidget,
          Expanded(child: field),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [if (showLabel) labelWidget, field],
    );
  }
}
