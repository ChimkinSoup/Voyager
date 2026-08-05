import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';

/// Text field with accent-colored caret, an animated focus border, and a
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
    this.borderRadius,
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
  final double? borderRadius;

  @override
  State<VoyagerTextField> createState() => _VoyagerTextFieldState();
}

class _VoyagerTextFieldState extends State<VoyagerTextField> {
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode => widget.focusNode ?? _ownedFocusNode!;

  final GlobalKey<State<TextField>> _fieldKey = GlobalKey();
  late final ScrollController _scrollController = ScrollController();

  bool _hasText = false;

  bool get _spellcheckOn => isMultilineField(
        expands: widget.expands,
        maxLines: widget.maxLines,
        minLines: widget.minLines,
      );

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _ownedFocusNode = FocusNode();
    }
    _hasText = widget.controller?.text.isNotEmpty ?? false;
    widget.controller?.addListener(_handleTextChanged);
    if (_spellcheckOn) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _forceSpellCheck());
    }
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
    _scrollController.dispose();
    super.dispose();
  }

  void _forceSpellCheck() {
    if (!mounted || !_spellcheckOn) return;
    forceSpellCheckDisplay(
      context: context,
      fieldKey: _fieldKey,
      focusNode: _focusNode,
    );
  }

  void _handleTextChanged() {
    final hasText = widget.controller?.text.isNotEmpty ?? false;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
    if (_spellcheckOn) _forceSpellCheck();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final decoration = widget.decoration ?? const InputDecoration();
    final contentPadding = decoration.contentPadding ??
        const EdgeInsets.symmetric(horizontal: 16, vertical: 18);

    final double radius = widget.borderRadius ??
        (decoration.border is OutlineInputBorder
            ? (decoration.border as OutlineInputBorder)
                .borderRadius
                .resolve(Directionality.maybeOf(context) ?? TextDirection.ltr)
                .topLeft
                .x
            : 18.0);

    final hasLabel = (decoration.labelText ?? '').isNotEmpty;
    // Non-outline InputDecoration.border makes InputDecorator reserve an
    // extra ~16px "floating label height" gap above contentPadding.top
    // whenever a labelText is present, regardless of floatingLabelBehavior
    // (see input_decorator.dart: floatingLabelHeight is 0 only in the
    // isOutline branch). The visible label is painted entirely by
    // NotchedFieldBorder below, so the real TextField's border is given an
    // invisible outline shape purely to take that zero-gap code path.
    final innerDecoration = decoration.copyWith(
      labelText: hasLabel ? '\u200b' : null,
      floatingLabelBehavior: FloatingLabelBehavior.never,
      filled: false,
      border: const OutlineInputBorder(
        borderSide: BorderSide.none,
        gapPadding: 0,
      ),
      enabledBorder: const OutlineInputBorder(
        borderSide: BorderSide.none,
        gapPadding: 0,
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide.none,
        gapPadding: 0,
      ),
      disabledBorder: const OutlineInputBorder(
        borderSide: BorderSide.none,
        gapPadding: 0,
      ),
      errorBorder: const OutlineInputBorder(
        borderSide: BorderSide.none,
        gapPadding: 0,
      ),
      focusedErrorBorder: const OutlineInputBorder(
        borderSide: BorderSide.none,
        gapPadding: 0,
      ),
      contentPadding: contentPadding,
    );

    final spellcheckOn = isMultilineField(
      expands: widget.expands,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
    );

    final textStyle = widget.style ??
        theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurface,
        );

    final textField = TextField(
      key: _fieldKey,
      contextMenuBuilder: spellcheckOn
          ? voyagerSpellCheckContextMenuBuilder
          : (context, editableTextState) => const SizedBox.shrink(),
      spellCheckConfiguration: spellcheckOn
          ? buildVoyagerSpellCheckConfiguration(context)
          : const SpellCheckConfiguration.disabled(),
      controller: widget.controller,
      focusNode: _focusNode,
      scrollController: _scrollController,
      decoration: innerDecoration,
      style: textStyle,
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
    );

    Widget field = spellcheckOn
        ? wrapWithSecondaryTapWordSelect(fieldKey: _fieldKey, child: textField)
        : textField;

    if (spellcheckOn && widget.controller != null) {
      field = Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                padding: contentPadding,
                child: SpellCheckSquiggleLayer(
                  controller: widget.controller!,
                  focusNode: _focusNode,
                  style: textStyle ?? const TextStyle(),
                  scrollController: _scrollController,
                ),
              ),
            ),
          ),
          field,
        ],
      );
    }

    return NotchedFieldBorder(
      focusNode: _focusNode,
      accentColor: accent,
      label: decoration.labelText,
      hasContent: _hasText,
      enabled: widget.enabled,
      borderRadius: radius,
      contentPadding: contentPadding,
      alignLabelToTop: widget.expands || (widget.maxLines ?? 1) > 1,
      child: field,
    );
  }
}
