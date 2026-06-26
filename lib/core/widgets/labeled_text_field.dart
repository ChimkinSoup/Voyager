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
    this.accentColor,
    this.filled,
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
  final Color? accentColor;
  final bool? filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentColor ?? theme.colorScheme.primary;
    final baseDecoration = theme.inputDecorationTheme;
    final decorationTheme = baseDecoration.copyWith(
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accent, width: 2),
      ),
      enabledBorder: baseDecoration.enabledBorder is OutlineInputBorder
          ? (baseDecoration.enabledBorder as OutlineInputBorder).copyWith(
              borderSide: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.5),
              ),
            )
          : baseDecoration.enabledBorder,
      filled: filled ?? baseDecoration.filled,
    );

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
      style: theme.textTheme.bodyLarge?.copyWith(
        color: theme.colorScheme.onSurface,
      ),
      cursorColor: accent,
      decoration: InputDecoration(
        labelText: showLabel && label.isNotEmpty ? label : null,
        hintText: hintText ?? (showLabel ? null : label),
        floatingLabelBehavior: FloatingLabelBehavior.auto,
        contentPadding: contentPadding ?? const EdgeInsets.all(16),
        labelStyle: TextStyle(color: accent.withValues(alpha: 0.85)),
        focusedBorder: decorationTheme.focusedBorder,
        enabledBorder: decorationTheme.enabledBorder,
        filled: decorationTheme.filled,
        fillColor: decorationTheme.fillColor,
      ),
    );

    return field;
  }
}
