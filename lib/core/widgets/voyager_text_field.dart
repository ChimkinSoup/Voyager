import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/text/newline_normalization.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/field_hint_style.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';
import 'package:voyager/core/widgets/selection_highlight_layer.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';
import 'package:voyager/core/widgets/tag_suggestion_overlay.dart';

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
    this.tagScope,
    this.onKeyEvent,
    this.snippetsAllowed = true,
  }) : assert(
         tagScope == null || controller != null,
         'Tag completion reads and rewrites the field text, so it needs a '
         'controller to work with.',
       ),
       assert(
         onKeyEvent == null || tagScope != null,
         'onKeyEvent is only installed by the completion popup, which is '
         'only built when tagScope is set. Without a scope, keep assigning '
         'focusNode.onKeyEvent directly.',
       );

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

  /// Which page's tag pool to complete `#` against. Null (the default) leaves
  /// the field with no completion popup.
  final TagScope? tagScope;

  /// Key handler for the field's focus node. Must be passed here rather than
  /// assigned onto [focusNode] directly whenever [tagScope] is set — the
  /// completion popup owns that slot so it can claim the arrow keys before
  /// they reach the caret.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// Whether text snippets may expand here. Set false for a field that edits
  /// snippets themselves, where a trigger has to stay literal.
  final bool snippetsAllowed;

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
    // Snippets share Vim's field-suitability rule but not its enable switch,
    // so the predicate is hoisted out and the two are gated separately.
    final suits = vimSuitsField(
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      maxLength: widget.maxLength,
    );
    return VimTextScope(
      enabled: VimEnabledScope.of(context) && suits,
      snippetsAllowed: widget.snippetsAllowed && suits,
      controller: widget.controller,
      multiline: _spellcheckOn,
      accentColor: widget.accentColor,
      builder: _buildField,
    );
  }

  Widget _buildField(BuildContext context, VimFieldBinding vim) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final decoration = widget.decoration ?? const InputDecoration();
    final contentPadding =
        decoration.contentPadding ??
        const EdgeInsets.symmetric(horizontal: 16, vertical: 18);

    final double radius =
        widget.borderRadius ??
        (decoration.border is OutlineInputBorder
            ? (decoration.border as OutlineInputBorder).borderRadius
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
    final spellcheckOn = isMultilineField(
      expands: widget.expands,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
    );

    var textStyle =
        widget.style ??
        theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurface);
    if (spellcheckOn && textStyle != null) {
      textStyle = withSquiggleRoom(textStyle);
    }

    final innerDecoration = decoration.copyWith(
      hintText: decoration.hintText,
      // Matched to the field's own text metrics \u2014 see [fieldHintStyle] for the
      // shrink-on-first-keystroke this avoids. A caller's explicit hintStyle
      // still wins.
      hintStyle: decoration.hintStyle ?? fieldHintStyle(context, textStyle),
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

    final textField = ListEditingUndoGuard(
      child: TextField(
        key: _fieldKey,
        // Right-click gets a menu on any field a new snippet could be
        // written from, single-line ones included.
        contextMenuBuilder: voyagerTextContextMenuBuilder(
          context,
          snippetsAllowed: vim.snippetsAllowed,
        ),
        spellCheckConfiguration: spellcheckOn
            ? buildVoyagerSpellCheckConfiguration(
                context,
                snippetsAllowed: vim.snippetsAllowed,
              )
            : const SpellCheckConfiguration.disabled(),
        controller: widget.controller,
        focusNode: _focusNode,
        scrollController: _scrollController,
        decoration: innerDecoration,
        style: textStyle,
        // Held back for [VimTextOverlay] below — see [overlayCaretColor].
        cursorColor: vim.overlayCaretColor(widget.cursorColor ?? accent),
        cursorWidth: vim.overlayCaretWidth,
        undoController: vim.undoController,
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
        // Prepended, not passed on: `\r` has to be gone before a caller's own
        // formatter (or anything downstream) starts counting offsets. Note
        // this is deliberately not folded into `vimSuitsField` above — that
        // predicate asks whether the *caller* constrains the input, and a
        // line-ending fixup is not that kind of constraint.
        inputFormatters: [
          const NormalizeNewlinesFormatter(),
          ...?widget.inputFormatters,
        ],
        textAlignVertical: widget.expands || (widget.maxLines ?? 1) > 1
            ? TextAlignVertical.top
            : TextAlignVertical.center,
        scrollPadding: kVoyagerFieldScrollPadding,
      ),
    );

    Widget field = spellcheckOn || vim.snippetsAllowed
        ? wrapWithSecondaryTapWordSelect(fieldKey: _fieldKey, child: textField)
        : textField;

    // The inner decoration pins gapPadding to 0 and is unfilled, so there is
    // no input gap to mirror — but the decorator's density shift and the
    // caret strip the text wraps inside of both still apply.
    final overlayPadding = withCaretMargin(
      withDensityShift(
        contentPadding.resolve(Directionality.of(context)),
        theme.visualDensity,
      ),
      cursorWidth: vim.overlayCaretWidth,
    );
    final vimSession = vim.session;
    final snippetSession = vim.snippetSession;
    final needsTextOverlay = vimSession != null || snippetSession != null;
    final controller = widget.controller;

    // Same predicate as [spellcheckOn]: only a wrapped paragraph can show the
    // ragged block and the seam that [SelectionHighlightLayer] exists to fix,
    // so single-line fields keep Flutter's own highlight. In Visual mode
    // [VimTextOverlay] is already drawing the selection — one layer, not two.
    final ownSelection =
        controller != null && spellcheckOn && !vim.overlayPaintsSelection;
    // Resolved here, above the TextSelectionTheme that blanks the field's own
    // highlight, or it would come back transparent.
    final selectionColor = resolveSelectionColor(context);

    if (controller != null && (spellcheckOn || needsTextOverlay)) {
      field = Stack(
        fit: StackFit.passthrough,
        children: [
          if (spellcheckOn)
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: overlayPadding,
                  child: SpellCheckSquiggleLayer(
                    controller: controller,
                    focusNode: _focusNode,
                    style: textStyle ?? const TextStyle(),
                    scrollController: _scrollController,
                    suppressActiveWord: vim.suppressSpellcheckActiveWord,
                  ),
                ),
              ),
            ),
          // Directly beneath the field, where EditableText was drawing this —
          // the fill is translucent and would wash out the glyphs from above.
          if (ownSelection)
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: overlayPadding,
                  child: SelectionHighlightLayer(
                    controller: controller,
                    focusNode: _focusNode,
                    style: textStyle ?? const TextStyle(),
                    // This field hands its TextField no strut, so the paragraph
                    // it measures against is the one EditableText falls back to
                    // (editable_text.dart, `strutStyle` getter) rather than the
                    // unstrutted default a bare TextPainter would use.
                    strutStyle: StrutStyle.fromTextStyle(
                      textStyle ?? const TextStyle(),
                      forceStrutHeight: true,
                    ),
                    color: selectionColor,
                    scrollController: _scrollController,
                  ),
                ),
              ),
            ),
          field,
          // Above the field, not behind it — see [VimTextOverlay]. Mounted for
          // a snippet session too, which is what puts dotted tabstop marks on
          // a field with Vim switched off.
          if (needsTextOverlay)
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: overlayPadding,
                  child: VimTextOverlay(
                    session: vimSession,
                    snippetSession: snippetSession,
                    controller: controller,
                    focusNode: _focusNode,
                    style: textStyle ?? const TextStyle(),
                    accentColor: accent,
                    scrollController: _scrollController,
                    // The hint stays up in Normal mode, so the block caret on
                    // an empty field sits on its first letter — see
                    // [VimTextOverlay.hintText].
                    hintText: decoration.hintText,
                  ),
                ),
              ),
            ),
        ],
      );
    }

    if (vimSession != null || ownSelection) {
      // Always wrap while Vim is on, not only in Visual: mounting this
      // inherited widget on `V` and unmounting it on Esc rebuilt the field
      // and killed typing on the following `i`. Multiline already kept it
      // mounted via [ownSelection].
      field = vimSelectionTheme(
        context: context,
        hideNativeSelection: vim.overlayPaintsSelection || ownSelection,
        child: field,
      );
    }

    final bordered = NotchedFieldBorder(
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

    final tagScope = widget.tagScope;
    if (tagScope == null) return bordered;

    return TagSuggestionPortal(
      scope: tagScope,
      controller: widget.controller!,
      focusNode: _focusNode,
      fieldKey: _fieldKey,
      accentColor: accent,
      enabled: vim.completionsAllowed,
      escapeAlsoBubbles: vim.escapeLeavesInsert,
      onChanged: widget.onChanged,
      onKeyEvent: widget.onKeyEvent,
      child: bordered,
    );
  }
}
