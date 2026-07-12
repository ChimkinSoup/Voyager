import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';

/// Text field with accent-colored caret, animated focus glow, and a
/// Material-style floating/notched label — all drawn by [NotchedFieldBorder].
class VoyagerTextField extends StatefulWidget {
  const VoyagerTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration,
    this.accentColor,
    this.style,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.enabled = true,
    this.maxLines = 1,
    this.minLines,
    this.expands = false,
    this.maxLength,
    this.buildCounter,
    this.inputFormatters,
    this.cursorColor,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final Color? accentColor;
  final TextStyle? style;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final bool enabled;
  final int? maxLines;
  final int? minLines;
  final bool expands;
  final int? maxLength;
  final InputCounterWidgetBuilder? buildCounter;
  final List<TextInputFormatter>? inputFormatters;
  final Color? cursorColor;

  @override
  State<VoyagerTextField> createState() => _VoyagerTextFieldState();
}

class _VoyagerTextFieldState extends State<VoyagerTextField> {
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode => widget.focusNode ?? _ownedFocusNode!;

  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _ownedFocusNode = FocusNode();
    }
    _hasText = widget.controller?.text.isNotEmpty ?? false;
    widget.controller?.addListener(_handleTextChanged);
  }

  @override
  void didUpdateWidget(covariant VoyagerTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_handleTextChanged);
      widget.controller?.addListener(_handleTextChanged);
      _hasText = widget.controller?.text.isNotEmpty ?? false;
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_handleTextChanged);
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    final hasText = widget.controller?.text.isNotEmpty ?? false;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final decoration = widget.decoration ?? const InputDecoration();
    final contentPadding = decoration.contentPadding ??
        const EdgeInsets.symmetric(horizontal: 16, vertical: 18);

    final innerDecoration = decoration.copyWith(
      labelText: '\u200B',
      floatingLabelBehavior: FloatingLabelBehavior.never,
      filled: false,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
      contentPadding: contentPadding,
    );

    return NotchedFieldBorder(
      focusNode: _focusNode,
      accentColor: accent,
      label: decoration.labelText,
      hasContent: _hasText,
      enabled: widget.enabled,
      contentPadding: contentPadding,
      alignLabelToTop: widget.expands || (widget.maxLines ?? 1) > 1,
      child: TextField(
        contextMenuBuilder: (context, editableTextState) => const SizedBox.shrink(),
        controller: widget.controller,
        focusNode: _focusNode,
        decoration: innerDecoration,
        style: widget.style ??
            theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
        cursorColor: widget.cursorColor ?? accent,
        autofocus: widget.autofocus,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        obscureText: widget.obscureText,
        enabled: widget.enabled,
        maxLines: widget.expands ? null : widget.maxLines,
        minLines: widget.expands ? null : widget.minLines,
        expands: widget.expands,
        maxLength: widget.maxLength,
        buildCounter: widget.buildCounter,
        inputFormatters: widget.inputFormatters,
        textAlignVertical: widget.expands || (widget.maxLines ?? 1) > 1
            ? TextAlignVertical.top
            : TextAlignVertical.center,
      ),
    );
  }
}
