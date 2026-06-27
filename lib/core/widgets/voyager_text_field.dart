import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/widgets/accent_focus_border.dart';

/// Text field with accent-colored caret and animated focus glow.
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
    final baseDecoration = theme.inputDecorationTheme;
    final decoration = (widget.decoration ?? const InputDecoration()).copyWith(
      filled: false,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
      labelStyle: (widget.decoration?.labelStyle ?? baseDecoration.labelStyle)
          ?.copyWith(color: accent.withValues(alpha: 0.85)),
      floatingLabelStyle:
          (widget.decoration?.floatingLabelStyle ??
                  baseDecoration.floatingLabelStyle)
              ?.copyWith(color: accent.withValues(alpha: 0.85)),
    );

    return AccentFocusBorder(
      focusNode: _focusNode,
      accentColor: accent,
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        decoration: decoration,
        style:
            widget.style ??
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
        textAlignVertical: TextAlignVertical.top,
      ),
    );
  }
}
