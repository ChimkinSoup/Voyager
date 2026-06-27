import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/accent_focus_border.dart';

class LabeledTextField extends StatefulWidget {
  const LabeledTextField({
    super.key,
    required this.label,
    required this.controller,
    this.showLabel = true,
    this.hintText,
    this.expands = false,
    this.maxLines = 1,
    this.minLines,
    this.obscureText = false,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.autofocus = false,
    this.focusNode,
    this.contentPadding,
    this.keyboardType,
    this.textInputAction,
    this.accentColor,
  });

  final String label;
  final TextEditingController controller;
  final bool showLabel;
  final String? hintText;
  final bool expands;
  final int? maxLines;
  final int? minLines;
  final bool obscureText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final bool autofocus;
  final FocusNode? focusNode;
  final EdgeInsetsGeometry? contentPadding;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Color? accentColor;

  @override
  State<LabeledTextField> createState() => _LabeledTextFieldState();
}

class _LabeledTextFieldState extends State<LabeledTextField> {
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode => widget.focusNode ?? _ownedFocusNode!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _ownedFocusNode = FocusNode();
    }
  }

  @override
  void dispose() {
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;

    return AccentFocusBorder(
      focusNode: _focusNode,
      accentColor: accent,
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        expands: widget.expands,
        maxLines: widget.expands ? null : widget.maxLines,
        minLines: widget.expands ? null : widget.minLines,
        obscureText: widget.obscureText,
        enabled: widget.enabled,
        autofocus: widget.autofocus,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        textAlignVertical: TextAlignVertical.top,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
        cursorColor: accent,
        decoration: InputDecoration(
          labelText: widget.showLabel && widget.label.isNotEmpty
              ? widget.label
              : null,
          hintText: widget.hintText ?? (widget.showLabel ? null : widget.label),
          floatingLabelBehavior: FloatingLabelBehavior.auto,
          contentPadding: widget.contentPadding ?? const EdgeInsets.all(16),
          labelStyle: TextStyle(color: accent.withValues(alpha: 0.85)),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }
}
