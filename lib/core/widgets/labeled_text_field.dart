import 'package:flutter/material.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/text/prose_editing_controller.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/field_edge_fade.dart';
import 'package:voyager/core/widgets/field_hint_style.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/line_break_mark_layer.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';
import 'package:voyager/core/widgets/autocorrect_flash_layer.dart';
import 'package:voyager/core/widgets/prose_highlight_layer.dart';
import 'package:voyager/core/widgets/selection_highlight_layer.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';

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
    this.onEditingComplete,
    this.enabled = true,
    this.autofocus = false,
    this.focusNode,
    this.contentPadding,
    this.keyboardType,
    this.textInputAction,
    this.accentColor,
    this.dense = false,
    this.allowShortHeight = false,
    this.borderRadius,
    this.alignLabelToTop,
    this.snippetsAllowed = true,
    this.autocorrectAllowed = true,
    this.showLineBreaks = false,
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

  /// Replaces the field's own Enter handling, which lets go of the keyboard.
  final VoidCallback? onEditingComplete;
  final bool enabled;
  final bool autofocus;
  final FocusNode? focusNode;
  final EdgeInsetsGeometry? contentPadding;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Color? accentColor;
  final bool dense;

  /// Lets the field be shorter than Material's 48px interactive minimum.
  ///
  /// [InputDecorator] enforces that minimum by stretching its container and
  /// then centring the text inside it, which walks the paragraph off the
  /// [contentPadding] offset every overlay here is positioned from — the Vim
  /// caret, the snippet tabstop marks and the squiggles all drift by half the
  /// slack. Set this on a non-[dense] field given a [contentPadding] tight
  /// enough to fall under 48, so the decorator lays the text out where the
  /// padding says instead.
  final bool allowShortHeight;

  final double? borderRadius;
  final bool? alignLabelToTop;

  /// Whether text snippets may expand here. Set false for a field that edits
  /// snippets themselves, where a trigger has to stay literal.
  final bool snippetsAllowed;

  /// Whether autocorrect may run here, on top of the user's own setting and
  /// the multiline rule. Set false for the fields whose text is a literal —
  /// a snippet trigger, a dictionary word (AUTOCORRECT.md §4.1).
  final bool autocorrectAllowed;

  /// Marks every line ended with Enter with a faint ↵, for multi-line fields
  /// whose text is pasted somewhere verbatim — see [LineBreakMarkLayer].
  final bool showLineBreaks;

  @override
  State<LabeledTextField> createState() => _LabeledTextFieldState();
}

class _LabeledTextFieldState extends State<LabeledTextField> {
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode => widget.focusNode ?? _ownedFocusNode!;

  final GlobalKey<State<TextField>> _fieldKey = GlobalKey();
  late final ScrollController _scrollController = ScrollController();

  bool _hasText = false;
  bool _focused = false;

  ProseEditingController? _prose;

  /// The controller the [TextField] and every overlay below are given: the
  /// caller's, wrapped for emphasis wherever this field is eligible for it.
  /// See [ProseEditingController] for why the wrapping happens here rather
  /// than at the call sites.
  TextEditingController get _controller => _prose ?? widget.controller;

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
    _hasText = widget.controller.text.isNotEmpty;
    _focused = _focusNode.hasFocus;
    widget.controller.addListener(_handleTextChanged);
    _focusNode.addListener(_handleFocusChanged);
    _syncProseController();
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
      (oldWidget.focusNode ?? _ownedFocusNode)?.removeListener(
        _handleFocusChanged,
      );
      _focusNode.addListener(_handleFocusChanged);
      _focused = _focusNode.hasFocus;
    }
    // The shape too: `_emphasisOn` is derived from it, so a field rebuilt from
    // `maxLines: 1` to `maxLines: null` would otherwise keep the stale
    // decision — emphasis off in a field that is now multiline, or still on in
    // one that is now single-line, where §10 says v1 renders plain text and
    // where the overlay layers below are no longer mounted to match.
    if (oldWidget.controller != widget.controller ||
        oldWidget.focusNode != widget.focusNode ||
        oldWidget.expands != widget.expands ||
        oldWidget.maxLines != widget.maxLines ||
        oldWidget.minLines != widget.minLines) {
      _syncProseController();
    }
  }

  /// Emphasis rides on the same multiline predicate as spellcheck: v1 leaves
  /// single-line fields on plain text (EMPHASIS_FORMATTING.md §10), which is
  /// also what keeps the §4.1 exclusions — the snippet trigger and replacement
  /// boxes, and the dictionary word box — literal without a flag of their own.
  void _syncProseController() {
    _prose?.dispose();
    _prose = _spellcheckOn
        ? ProseEditingController(
            source: widget.controller,
            focusNode: _focusNode,
          )
        : null;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleTextChanged);
    _focusNode.removeListener(_handleFocusChanged);
    // Before the focus node it listens to, and never the caller's controller.
    _prose?.dispose();
    _ownedFocusNode?.dispose();
    _scrollController.dispose();
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
    // Snippets share Vim's field-suitability rule but not its enable switch,
    // so the predicate is hoisted out and the two are gated separately.
    final suits = vimSuitsField(
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
    );
    return VimTextScope(
      enabled: VimEnabledScope.of(context) && suits,
      snippetsAllowed: widget.snippetsAllowed && suits,
      autocorrectAllowed: widget.autocorrectAllowed && suits,
      controller: widget.controller,
      multiline: _spellcheckOn,
      proseEmphasis: _prose != null,
      accentColor: widget.accentColor,
      builder: _buildField,
    );
  }

  Widget _buildField(BuildContext context, VimFieldBinding vim) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    final emphasisTheme = ProseEmphasisTheme.of(theme.colorScheme, accent);
    _prose?.emphasis = emphasisTheme;
    // A `==highlight==` run carries only a mark; [ProseHighlightLayer] is what
    // fills it — see [kProseHighlightMark].
    final highlightFill = emphasisTheme.highlightColor!;
    // Null on a field with emphasis off, which is exactly the flat paragraph
    // every layer built for itself before emphasis existed.
    final spanBuilder = _prose?.overlaySpan;
    final showLabel = widget.showLabel && widget.label.isNotEmpty;
    final contentPadding =
        widget.contentPadding ??
        (widget.dense
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
            : const EdgeInsets.symmetric(horizontal: 14, vertical: 16));
    // When a real floating label is showing, its resting (unfocused, empty)
    // position sits exactly where a hint would print — so only reveal a hint
    // once the label has floated out of the way (focused or has content),
    // matching standard Material label+hint behavior.
    final floated = _focused || _hasText;
    final hint = showLabel
        ? (floated ? widget.hintText : null)
        : (widget.hintText ?? widget.label);
    // An empty hint is no hint. Given one, the decorator still lays out an
    // empty paragraph, and its baseline sits lower than the text's: the input
    // moved down under every overlay here, by 0.4px in Iosevka.
    final effectiveHint = hint == null || hint.isEmpty ? null : hint;
    // The same getter the prose controller was built from, not a second
    // reading of the same three properties: §5.2's invariant is that the
    // paragraph and the layers stacked around it agree about whether emphasis
    // applies, and two copies of one predicate is how they drift apart.
    final spellcheckOn = _spellcheckOn;

    // Dense fields use bodyMedium so the resting floating label fits the
    // short box (snippet Trigger/Replacement). Pin height to 1.0 so every
    // dense field — single or multi-line — shares one compact size ladder.
    var textStyle =
        (widget.dense ? theme.textTheme.bodyMedium : theme.textTheme.bodyLarge)
            ?.copyWith(
              color: theme.colorScheme.onSurface,
              height: widget.dense ? 1.0 : null,
            );
    // A dense multi-line field is also spellchecked, and 1.0 leaves its
    // squiggles nowhere to go but the next line — see [withSquiggleRoom].
    if (spellcheckOn && textStyle != null) {
      textStyle = withSquiggleRoom(textStyle);
    }

    final textField = ListEditingUndoGuard(
      child: TextField(
        key: _fieldKey,
        // Right-click gets a menu on any field a new snippet could be
        // written from, single-line ones included.
        contextMenuBuilder: voyagerTextContextMenuBuilder(
          context,
          snippetsAllowed: vim.snippetsAllowed,
          spellcheckAllowed: spellcheckOn,
          autocorrectSession: vim.autocorrectSession,
        ),
        // No spell config: squiggles come from [SpellCheckSquiggleLayer] and
        // the right-click corrections from [misspellingAtCursor]. Giving
        // EditableText results of its own makes it build the paragraph itself
        // and drop the controller's span.
        spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
        controller: _controller,
        focusNode: _focusNode,
        scrollController: _scrollController,
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
        onEditingComplete: widget.onEditingComplete,
        textAlignVertical: widget.expands || (widget.maxLines ?? 1) > 1
            ? TextAlignVertical.top
            : TextAlignVertical.center,
        style: textStyle,
        // The Vim caret and Visual selection are drawn by [VimTextOverlay]
        // below, so the field's own are held back — see [overlayCaretColor].
        cursorColor: vim.overlayCaretColor(accent),
        cursorWidth: vim.overlayCaretWidth,
        undoController: vim.undoController,
        scrollPadding: kVoyagerFieldScrollPadding,
        scrollPhysics: const VoyagerFieldScrollPhysics(),
        // Multi-line text paints on past its viewport, through the vertical
        // padding, so a scrolled body reads up to the border; the stack below
        // clips it there instead.
        clipBehavior: spellcheckOn ? Clip.none : Clip.hardEdge,
        decoration: InputDecoration(
          isDense: widget.dense || widget.allowShortHeight,
          hintText: effectiveHint,
          hintStyle: fieldHintStyle(context, textStyle),
          contentPadding: contentPadding,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );

    Widget field = spellcheckOn || vim.snippetsAllowed
        ? wrapWithSecondaryTapWordSelect(fieldKey: _fieldKey, child: textField)
        : textField;

    // Borderless and unfilled, so no input gap to mirror — but the
    // decorator's density shift and the caret strip the text wraps inside of
    // both still apply.
    final overlayPadding = withCaretMargin(
      withDensityShift(
        contentPadding.resolve(Directionality.of(context)),
        theme.visualDensity,
      ),
      cursorWidth: vim.overlayCaretWidth,
    );
    final vimSession = vim.session;
    final snippetSession = vim.snippetSession;
    final autocorrectSession = vim.autocorrectSession;
    final needsTextOverlay = vimSession != null || snippetSession != null;
    final showLineBreaks = widget.showLineBreaks && spellcheckOn;

    // Same predicate as [spellcheckOn]: only a wrapped paragraph can show the
    // ragged block and the seam that [SelectionHighlightLayer] exists to fix,
    // so single-line fields keep Flutter's own highlight. In Visual mode
    // [VimTextOverlay] is already drawing the selection — one layer, not two.
    final ownSelection = spellcheckOn && !vim.overlayPaintsSelection;
    // Resolved here, above the TextSelectionTheme that blanks the field's own
    // highlight, or it would come back transparent.
    final selectionColor = resolveSelectionColor(context);

    if (spellcheckOn || needsTextOverlay) {
      field = Stack(
        fit: StackFit.passthrough,
        children: [
          // Bottom of the stack: the tint sits behind the squiggle as well as
          // behind the glyphs.
          if (autocorrectSession != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: overlayPadding,
                  child: AutocorrectFlashLayer(
                    spanBuilder: spanBuilder,
                    session: autocorrectSession,
                    controller: _controller,
                    style: textStyle ?? const TextStyle(),
                    color: accent,
                    strutStyle: StrutStyle.fromTextStyle(
                      textStyle ?? const TextStyle(),
                      forceStrutHeight: true,
                    ),
                    scrollController: _scrollController,
                  ),
                ),
              ),
            ),
          if (spellcheckOn)
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: overlayPadding,
                  child: SpellCheckSquiggleLayer(
                    spanBuilder: spanBuilder,
                    controller: _controller,
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
                    spanBuilder: spanBuilder,
                    controller: _controller,
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
          // Above the selection and still beneath the field: this is where the
          // paragraph itself used to fill a `==highlight==`, back when the
          // fill was a `backgroundColor` and its corners were square.
          if (spanBuilder != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: overlayPadding,
                  child: ProseHighlightLayer(
                    spanBuilder: spanBuilder,
                    controller: _controller,
                    style: textStyle ?? const TextStyle(),
                    strutStyle: StrutStyle.fromTextStyle(
                      textStyle ?? const TextStyle(),
                      forceStrutHeight: true,
                    ),
                    color: highlightFill,
                    scrollController: _scrollController,
                  ),
                ),
              ),
            ),
          if (showLineBreaks)
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: overlayPadding,
                  child: LineBreakMarkLayer(
                    spanBuilder: spanBuilder,
                    controller: _controller,
                    style: textStyle ?? const TextStyle(),
                    strutStyle: StrutStyle.fromTextStyle(
                      textStyle ?? const TextStyle(),
                      forceStrutHeight: true,
                    ),
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.55,
                    ),
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
                    spanBuilder: spanBuilder,
                    session: vimSession,
                    snippetSession: snippetSession,
                    controller: _controller,
                    focusNode: _focusNode,
                    style: textStyle ?? const TextStyle(),
                    accentColor: accent,
                    scrollController: _scrollController,
                    // The hint stays up in Normal mode, so the block caret on
                    // an empty field sits on its first letter — see
                    // [VimTextOverlay.hintText].
                    hintText: effectiveHint,
                  ),
                ),
              ),
            ),
        ],
      );
      // The one clip for the field and every layer over it, at the border:
      // the layers don't clip themselves, and a multi-line field's own text
      // and caret paint past its viewport. Everything a multi-line field
      // paints out there is text scrolled out of the viewport, so it fades
      // into the fill instead of being cut off square under the label.
      field = spellcheckOn
          ? FieldEdgeFade(padding: overlayPadding, child: field)
          : ClipRect(child: field);
    }

    if (vimSession != null || ownSelection) {
      // Always wrap while Vim is on, not only in Visual — see
      // [vimSelectionTheme]. Flutter's own selection rects give a covered
      // line break the width of the paragraph's widest line; hide them
      // whenever an overlay is drawing the accurate one.
      field = vimSelectionTheme(
        context: context,
        hideNativeSelection: vim.overlayPaintsSelection || ownSelection,
        child: field,
      );
    }

    // InputDecorator sizes itself to whatever height it is handed, but lays
    // its content box out against the *top* of it: `performLayout` sets `size
    // = constraints.constrain(layout.size)` and then positions every child
    // inside the shorter `layout.containerHeight` it computed for itself. A
    // single-line field handed more height than it asked for — the
    // `IntrinsicHeight` rows that pair one with a taller button, a
    // fixed-height parent — therefore prints its text hard against the top
    // border and leaves all of the slack under it. The gap only opens up on a
    // desktop's `VisualDensity.compact`, which takes 8px off the decorator's
    // content box but nothing off the button beside it.
    //
    // Centring the field puts the text back on the centre line. The overlays
    // are inside the stack being centred, so they move with the glyphs rather
    // than relative to them, and `heightFactor: 1` leaves the field's own
    // height alone wherever nothing is stretching it. Multi-line fields are
    // left top-aligned, which is where their text belongs.
    if (!widget.expands && widget.minLines == null && widget.maxLines == 1) {
      field = Align(alignment: Alignment.center, heightFactor: 1, child: field);
    }

    return NotchedFieldBorder(
      focusNode: _focusNode,
      accentColor: accent,
      label: showLabel ? widget.label : null,
      // Match [TagHighlightedTextField]: resting label uses the field's text
      // metrics so dense/non-dense stay aligned with what will be typed.
      labelStyle: showLabel ? textStyle : null,
      hasContent: _hasText,
      enabled: widget.enabled,
      contentPadding: contentPadding,
      alignLabelToTop:
          widget.alignLabelToTop ??
          (widget.expands || (widget.maxLines ?? 1) > 1),
      borderRadius: widget.borderRadius ?? VoyagerTheme.fieldRadius,
      child: field,
    );
  }
}
