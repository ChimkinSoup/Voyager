import 'package:flutter/material.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';

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

  /// When false, [label] is not shown as a floating label at all — the field
  /// renders as a plain box with [hintText] (or [label], if [hintText] is
  /// unset) as a placeholder instead. Used for inputs like "Add task" where a
  /// permanent label would be redundant.
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

  bool _hasText = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _ownedFocusNode = FocusNode();
    }
    _hasText = widget.controller.text.isNotEmpty;
    _focused = _focusNode.hasFocus;
    widget.controller.addListener(_handleTextChanged);
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant LabeledTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleTextChanged);
      widget.controller.addListener(_handleTextChanged);
      _hasText = widget.controller.text.isNotEmpty;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownedFocusNode)
          ?.removeListener(_handleFocusChanged);
      _focusNode.addListener(_handleFocusChanged);
      _focused = _focusNode.hasFocus;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleTextChanged);
    _focusNode.removeListener(_handleFocusChanged);
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    final hasText = widget.controller.text.isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }

  void _handleFocusChanged() {
    final focused = _focusNode.hasFocus;
    if (focused != _focused) {
      setState(() => _focused = focused);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final showLabel = widget.showLabel && widget.label.isNotEmpty;
    final contentPadding = widget.contentPadding ??
        const EdgeInsets.symmetric(horizontal: 16, vertical: 18);
    // When a real floating label is showing, its resting (unfocused, empty)
    // position sits exactly where a hint would print — so only reveal a hint
    // once the label has floated out of the way (focused or has content),
    // matching standard Material label+hint behavior.
    final floated = _focused || _hasText;
    final effectiveHint = showLabel
        ? (floated ? widget.hintText : null)
        : (widget.hintText ?? widget.label);

    return NotchedFieldBorder(
      focusNode: _focusNode,
      accentColor: accent,
      label: showLabel ? widget.label : null,
      hasContent: _hasText,
      enabled: widget.enabled,
      contentPadding: contentPadding,
      alignLabelToTop: widget.expands || (widget.maxLines ?? 1) > 1,
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
        textAlignVertical: widget.expands || (widget.maxLines ?? 1) > 1
            ? TextAlignVertical.top
            : TextAlignVertical.center,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
        cursorColor: accent,
        decoration: InputDecoration(
          hintText: effectiveHint,
          contentPadding: contentPadding,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }
}
