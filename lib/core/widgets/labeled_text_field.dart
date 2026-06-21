import 'package:flutter/material.dart';

class LabeledTextField extends StatelessWidget {
  const LabeledTextField({
    super.key,
    required this.label,
    required this.controller,
    this.showLabel = true,
    this.hintText,
    this.expands = false,
    this.maxLines = 1,
    this.obscureText = false,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.focusNode,
    this.contentPadding,
    this.keyboardType,
    this.textInputAction,
  });

  final String label;
  final TextEditingController controller;
  final bool showLabel;
  final String? hintText;
  final bool expands;
  final int? maxLines;
  final bool obscureText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final FocusNode? focusNode;
  final EdgeInsetsGeometry? contentPadding;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      expands: expands,
      maxLines: expands ? null : maxLines,
      obscureText: obscureText,
      enabled: enabled,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textAlignVertical: TextAlignVertical.top,
      decoration: InputDecoration(
        labelText: showLabel && label.isNotEmpty ? label : null,
        hintText: hintText ?? (showLabel ? null : label),
        floatingLabelBehavior: FloatingLabelBehavior.auto,
        contentPadding: contentPadding ?? const EdgeInsets.all(16),
      ),
    );

    return field;
  }
}
