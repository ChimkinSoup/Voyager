import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/text/prose_editing_controller.dart';
import 'package:voyager/core/text/prose_text_span.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/field_hint_style.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';
import 'package:voyager/core/widgets/autocorrect_flash_layer.dart';
import 'package:voyager/core/widgets/prose_highlight_layer.dart';
import 'package:voyager/core/widgets/selection_highlight_layer.dart';
import 'package:voyager/core/widgets/tag_suggestion_overlay.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';
import 'package:voyager/core/widgets/spell_check_squiggle_layer.dart';

class TagHighlightedTextField extends StatefulWidget {
  const TagHighlightedTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.onChanged,
    this.hintText,
    this.label,
    this.accentColor,
    this.style,
    this.contentPadding = const EdgeInsets.all(16),
    this.expands = false,
    this.maxLines = 1,
    this.minLines,
    this.keyboardType,
    this.tagColorFor,
    this.decoration = const InputDecoration(),
    this.cursorColor,
    this.useNotchedBorder = true,
    this.highlightDebounce = const Duration(milliseconds: 200),
    this.readOnly = false,
    this.tagScope,
    this.onKeyEvent,
  }) : assert(
         onKeyEvent == null || tagScope != null,
         'onKeyEvent is only installed by the completion popup, which is '
         'only built when tagScope is set. Without a scope, keep assigning '
         'focusNode.onKeyEvent directly.',
       );

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String>? onChanged;
  final String? hintText;

  /// Optional Material-style floating label, drawn by [NotchedFieldBorder].
  /// Most callers (search box, journal/todo body) leave this null, which
  /// renders a plain (non-notched) border — matching the field's previous
  /// look exactly.
  final String? label;
  final Color? accentColor;
  final TextStyle? style;
  final EdgeInsetsGeometry contentPadding;
  final bool expands;
  final int? maxLines;
  final int? minLines;
  final TextInputType? keyboardType;
  final int Function(String tag)? tagColorFor;
  final InputDecoration decoration;
  final Color? cursorColor;
  final bool useNotchedBorder;
  final Duration highlightDebounce;
  final bool readOnly;

  /// Which page's tag pool to complete `#` against. Null (the default) leaves
  /// the field with today's highlight-only behavior and no completion popup.
  final TagScope? tagScope;

  /// Key handler for the field's focus node. Must be passed here rather than
  /// assigned onto [focusNode] directly whenever [tagScope] is set — the
  /// completion popup owns that slot so it can claim the arrow keys before
  /// they reach the caret.
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  State<TagHighlightedTextField> createState() =>
      _TagHighlightedTextFieldState();
}

class _TagHighlightedTextFieldState extends State<TagHighlightedTextField> {
  static const _textHeightBehavior = TextHeightBehavior(
    applyHeightToFirstAscent: false,
    applyHeightToLastDescent: false,
  );

  late final ScrollController _scrollController;
  final GlobalKey<State<TextField>> _fieldKey = GlobalKey();
  Timer? _highlightTimer;
  String _highlightedText = '';
  bool _hasText = false;
  bool _bringCursorScheduled = false;

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
    _scrollController = ScrollController();
    _highlightedText = widget.controller.text;
    _hasText = widget.controller.text.isNotEmpty;
    widget.controller.addListener(_handleControllerChanged);
    _syncProseController();
  }

  /// Emphasis rides on the same multiline predicate as spellcheck: v1 leaves
  /// single-line fields on plain text (EMPHASIS_FORMATTING.md §10).
  void _syncProseController() {
    _prose?.dispose();
    _prose = _spellcheckOn
        ? ProseEditingController(
            source: widget.controller,
            focusNode: widget.focusNode,
          )
        : null;
  }

  @override
  void didUpdateWidget(covariant TagHighlightedTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _hasText = widget.controller.text.isNotEmpty;
    }
    if (widget.controller.text != _highlightedText) {
      _highlightedText = widget.controller.text;
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

  @override
  void dispose() {
    _highlightTimer?.cancel();
    widget.controller.removeListener(_handleControllerChanged);
    // Never the caller's controller, only the wrapper around it.
    _prose?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    // Immediate (undebounced) so the floating label reacts on the very first
    // keystroke; the highlight repaint itself stays debounced below.
    final hasText = widget.controller.text.isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
    _scheduleHighlightRepaint();
    if (widget.focusNode.hasFocus) _scheduleBringCursorIntoView();
  }

  void _scheduleBringCursorIntoView() {
    // Deferred to a post-frame callback (mirroring how EditableText schedules
    // its own caret-into-view step): calling this synchronously here runs
    // before EditableTextState's own controller listener has processed the
    // new value, so RenderEditable is still laid out against the *old* text
    // and computes a stale/incorrect caret rect.
    if (_bringCursorScheduled) return;
    _bringCursorScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bringCursorScheduled = false;
      if (!mounted) return;
      bringCursorIntoView(fieldKey: _fieldKey);
    });
  }

  void _scheduleHighlightRepaint() {
    if (widget.highlightDebounce == Duration.zero) {
      _highlightTimer?.cancel();
      _applyHighlightText(widget.controller.text);
      return;
    }

    _highlightTimer?.cancel();
    _highlightTimer = Timer(widget.highlightDebounce, () {
      if (!mounted) return;
      _applyHighlightText(widget.controller.text);
    });
  }

  void _applyHighlightText(String text) {
    if (_highlightedText == text) return;
    setState(() => _highlightedText = text);
  }

  @override
  Widget build(BuildContext context) {
    // Snippets share Vim's field-suitability rule but not its enable switch,
    // so the predicate is hoisted out and the two are gated separately.
    final suits = vimSuitsField(
      keyboardType: widget.keyboardType,
      readOnly: widget.readOnly,
    );
    return VimTextScope(
      enabled: VimEnabledScope.of(context) && suits,
      snippetsAllowed: suits,
      autocorrectAllowed: suits,
      controller: widget.controller,
      multiline: _spellcheckOn,
      proseEmphasis: _prose != null,
      accentColor: widget.accentColor ?? widget.cursorColor,
      builder: _buildField,
    );
  }

  Widget _buildField(BuildContext context, VimFieldBinding vim) {
    final theme = Theme.of(context);
    // The same getter the prose controller was built from, not a second
    // reading of the same three properties: §5.2's invariant is that the
    // paragraph and the layers stacked around it agree about whether emphasis
    // applies, and two copies of one predicate is how they drift apart.
    final spellcheckOn = _spellcheckOn;
    var baseStyle =
        widget.style ??
        theme.textTheme.bodyLarge ??
        DefaultTextStyle.of(context).style;
    if (spellcheckOn) baseStyle = withSquiggleRoom(baseStyle);
    // Derived after the squiggle-room floor, so the strut the field and both
    // overlays lay out against stays the one the text actually uses.
    final strutStyle = StrutStyle.fromTextStyle(baseStyle);
    final accent =
        widget.accentColor ?? widget.cursorColor ?? theme.colorScheme.primary;
    final emphasisTheme = ProseEmphasisTheme.of(theme.colorScheme, accent);
    _prose?.emphasis = emphasisTheme;
    // A `==highlight==` run carries only a mark; [ProseHighlightLayer] is what
    // fills it — see [kProseHighlightMark].
    final highlightFill = emphasisTheme.highlightColor!;
    // Null on a field with emphasis off, which is exactly the flat paragraph
    // every layer built for itself before emphasis existed.
    final spanBuilder = _prose?.overlaySpan;
    final hasLabel = (widget.label ?? '').isNotEmpty;
    // The floating label (drawn externally by NotchedFieldBorder) rests in the
    // same spot a hint would occupy, so suppress the hint to avoid
    // double-printed placeholder text.
    final effectiveHint = hasLabel ? null : widget.hintText;
    final decoration = widget.decoration.copyWith(
      // Drops InputDecorator's [kMinInteractiveDimension] floor, which is not
      // a padding but a *centering*: a field whose content is shorter than
      // 48px is stretched to 48 and its text re-centred inside the slack
      // (`interactiveAdjustment`, input_decorator.dart), past
      // `textAlignVertical: top` and past everything the overlays below
      // mirror. Every overlay here is a plain [Padding] around a paragraph,
      // so that slack put the squiggles, the `#tag` pills and the Vim caret
      // most of a line above the words they belong to — 11.5px on the
      // rankings template notes box, the one field in the app small enough to
      // hit the floor. Dense makes the box hug its own content instead, which
      // is the geometry [overlayPadding] already describes. A no-op for every
      // field taller than 48: their `interactiveAdjustment` was already zero.
      isDense: true,
      hintText: effectiveHint,
      // Matched to the field's own text metrics — see [fieldHintStyle] for the
      // shrink-on-first-keystroke this avoids.
      hintStyle:
          widget.decoration.hintStyle ?? fieldHintStyle(context, baseStyle),
      contentPadding: widget.contentPadding,
      filled: widget.useNotchedBorder ? false : widget.decoration.filled,
      border: widget.useNotchedBorder
          ? InputBorder.none
          : widget.decoration.border,
      enabledBorder: widget.useNotchedBorder
          ? InputBorder.none
          : widget.decoration.enabledBorder,
      focusedBorder: widget.useNotchedBorder
          ? InputBorder.none
          : widget.decoration.focusedBorder,
    );
    // Both overlays below are plain Paddings around text, so they have to
    // repeat what the field's own geometry adds on top of the content padding:
    // the density shift InputDecorator applies to the real text (or the `#tag`
    // pills and the squiggles sit a few pixels below the words they belong
    // to), and the caret strip RenderEditable wraps inside of (or they wrap a
    // word later than the field does).
    final overlayPadding = withCaretMargin(
      withDensityShift(
        widget.contentPadding.resolve(Directionality.of(context)),
        theme.visualDensity,
      ),
      cursorWidth: vim.overlayCaretWidth,
    );
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final textHeightBehavior =
        DefaultTextHeightBehavior.maybeOf(context) ?? _textHeightBehavior;
    final locale = Localizations.maybeLocaleOf(context);

    // Same predicate as [spellcheckOn]: only a wrapped paragraph can show the
    // ragged block and the seam that [SelectionHighlightLayer] exists to fix,
    // so single-line fields keep Flutter's own highlight. In Visual mode
    // [VimTextOverlay] is already drawing the selection — one layer, not two.
    final ownSelection = spellcheckOn && !vim.overlayPaintsSelection;
    // Resolved here, above the TextSelectionTheme that blanks the field's own
    // highlight, or it would come back transparent.
    final selectionColor = resolveSelectionColor(context);

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
        // Always disabled: the squiggles are [SpellCheckSquiggleLayer]'s, and
        // giving EditableText results of its own would make it build the
        // paragraph itself rather than through the controller — see
        // [misspellingAtCursor].
        spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
        controller: _controller,
        focusNode: widget.focusNode,
        readOnly: widget.readOnly,
        scrollController: _scrollController,
        expands: widget.expands,
        maxLines: widget.expands ? null : widget.maxLines,
        minLines: widget.expands ? null : widget.minLines,
        keyboardType: widget.keyboardType,
        textAlignVertical: TextAlignVertical.top,
        strutStyle: strutStyle,
        style: baseStyle,
        // Held back for [VimTextOverlay] below — see [overlayCaretColor].
        cursorColor: vim.overlayCaretColor(accent),
        cursorWidth: vim.overlayCaretWidth,
        undoController: vim.undoController,
        scrollPadding: kVoyagerFieldScrollPadding,
        onChanged: widget.onChanged,
        decoration: decoration,
      ),
    );

    final autocorrectSession = vim.autocorrectSession;

    final field = Stack(
      fit: widget.expands ? StackFit.expand : StackFit.loose,
      textDirection: textDirection,
      children: [
        // Bottom of the stack, under the `#tag` pills and the squiggles: the
        // tint is the background changing colour, not a mark of its own.
        if (autocorrectSession != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                padding: overlayPadding,
                child: AutocorrectFlashLayer(
                  session: autocorrectSession,
                  spanBuilder: spanBuilder,
                  controller: _controller,
                  style: baseStyle,
                  color: accent,
                  strutStyle: strutStyle,
                  textHeightBehavior: textHeightBehavior,
                  scrollController: _scrollController,
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: DefaultTextHeightBehavior(
              textHeightBehavior: textHeightBehavior,
              child: ClipRect(
                child: ListenableBuilder(
                  // The controller as well as the scroll position: the pills
                  // are measured from the same paragraph the field renders,
                  // and revealing a `**` moves every glyph after it on the
                  // line. The *text* stays debounced — that is what
                  // [_highlightedText] is — but the reveal must not be.
                  listenable: Listenable.merge([
                    _scrollController,
                    _controller,
                  ]),
                  builder: (context, _) {
                    final scrollOffset = _scrollController.hasClients
                        ? _scrollController.offset
                        : 0.0;
                    return Transform.translate(
                      offset: Offset(0, -scrollOffset),
                      child: Padding(
                        padding: overlayPadding,
                        child: _TagHighlightLayer(
                          text: _highlightedText,
                          span: (spanBuilder ?? flatProseSpan)(
                            _highlightedText,
                            baseStyle,
                          ),
                          style: baseStyle,
                          strutStyle: strutStyle,
                          textDirection: textDirection,
                          textScaler: textScaler,
                          textHeightBehavior: textHeightBehavior,
                          locale: locale,
                          tagColorFor: widget.tagColorFor ?? colorForTag,
                        ),
                      ),
                    );
                  },
                ),
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
                  focusNode: widget.focusNode,
                  style: baseStyle,
                  strutStyle: strutStyle,
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
                  focusNode: widget.focusNode,
                  style: baseStyle,
                  strutStyle: strutStyle,
                  textHeightBehavior: textHeightBehavior,
                  locale: locale,
                  color: selectionColor,
                  scrollController: _scrollController,
                ),
              ),
            ),
          ),
        // Above the selection and still beneath the field: this is where the
        // paragraph itself used to fill a `==highlight==`, back when the fill
        // was a `backgroundColor` and its corners were square.
        if (spanBuilder != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                padding: overlayPadding,
                child: ProseHighlightLayer(
                  spanBuilder: spanBuilder,
                  controller: _controller,
                  style: baseStyle,
                  strutStyle: strutStyle,
                  textHeightBehavior: textHeightBehavior,
                  locale: locale,
                  color: highlightFill,
                  scrollController: _scrollController,
                ),
              ),
            ),
          ),
        DefaultTextHeightBehavior(
          textHeightBehavior: textHeightBehavior,
          child: spellcheckOn || vim.snippetsAllowed
              ? wrapWithSecondaryTapWordSelect(
                  fieldKey: _fieldKey,
                  child: textField,
                )
              : textField,
        ),
        // Topmost: above the field — see [VimTextOverlay]. Mounted for a
        // snippet session too, which is what puts dotted tabstop marks on a
        // field with Vim switched off.
        if (vim.session != null || vim.snippetSession != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                padding: overlayPadding,
                child: VimTextOverlay(
                  session: vim.session,
                  snippetSession: vim.snippetSession,
                  spanBuilder: spanBuilder,
                  controller: _controller,
                  focusNode: widget.focusNode,
                  style: baseStyle,
                  strutStyle: strutStyle,
                  accentColor: accent,
                  scrollController: _scrollController,
                  // The hint stays up in Normal mode, so the block caret on an
                  // empty field sits on its first letter — see
                  // [VimTextOverlay.hintText].
                  hintText: effectiveHint,
                ),
              ),
            ),
          ),
      ],
    );

    // Always wrap while Vim is on, not only in Visual — see
    // [vimSelectionTheme]. Flutter's own selection would paint a block out
    // to the paragraph's widest line behind either overlay.
    final selectionAware = vim.session != null || ownSelection
        ? vimSelectionTheme(
            context: context,
            hideNativeSelection: vim.overlayPaintsSelection || ownSelection,
            child: field,
          )
        : field;

    final bordered = widget.useNotchedBorder
        ? NotchedFieldBorder(
            focusNode: widget.focusNode,
            accentColor: accent,
            label: widget.label,
            hasContent: _hasText,
            contentPadding: widget.contentPadding,
            labelStyle: baseStyle,
            alignLabelToTop: widget.expands || (widget.maxLines ?? 1) > 1,
            child: selectionAware,
          )
        : selectionAware;

    final tagScope = widget.tagScope;
    if (tagScope == null) return bordered;

    return TagSuggestionPortal(
      scope: tagScope,
      controller: widget.controller,
      focusNode: widget.focusNode,
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

class _TagHighlightLayer extends StatelessWidget {
  const _TagHighlightLayer({
    required this.text,
    required this.span,
    required this.style,
    required this.strutStyle,
    required this.textDirection,
    required this.textScaler,
    required this.textHeightBehavior,
    required this.locale,
    required this.tagColorFor,
  });

  final String text;

  /// [text] as the field itself renders it. Load-bearing for the pills: a
  /// bolded `**#tag**` is wider than the same tag in regular weight, and a
  /// pill measured off a flat paragraph drifts left of the letters it is
  /// meant to wrap (EMPHASIS_FORMATTING.md §8).
  final TextSpan span;

  final TextStyle style;
  final StrutStyle strutStyle;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final TextHeightBehavior textHeightBehavior;
  final Locale? locale;
  final int Function(String tag) tagColorFor;

  @override
  Widget build(BuildContext context) {
    // The paragraph is laid out inside `paint` and disposed there, exactly as
    // `_ProseHighlightPainter` does. Built here and handed over, it was never
    // disposed — and since §8 made this layer repaint with the caret rather
    // than only on the 200ms text debounce, that abandoned a laid-out
    // `ui.Paragraph` on every keystroke *and* every arrow press, for the full
    // journal body. Sizing is unaffected: this sits in a `Positioned.fill`, so
    // the constraints reaching it are already tight.
    return CustomPaint(
      painter: _TagHighlightPainter(
        span: span,
        style: style,
        strutStyle: strutStyle,
        textDirection: textDirection,
        textScaler: textScaler,
        textHeightBehavior: textHeightBehavior,
        locale: locale,
        tagColorFor: tagColorFor,
      ),
    );
  }
}

class _TagHighlightPainter extends CustomPainter {
  _TagHighlightPainter({
    required this.span,
    required this.style,
    required this.strutStyle,
    required this.textDirection,
    required this.textScaler,
    required this.textHeightBehavior,
    required this.locale,
    required this.tagColorFor,
  });

  final TextSpan span;
  final TextStyle style;
  final StrutStyle strutStyle;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final TextHeightBehavior textHeightBehavior;
  final Locale? locale;
  final int Function(String tag) tagColorFor;

  static const _tagHorizontalPadding = 3.0;
  static const _tagVerticalPadding = 3.0;
  static const _tagCornerRadius = 8.0;
  static final _tagDescenderPattern = RegExp(r'[gjpqy]');

  /// How far the tallest glyph a tag can hold — `#`, and the ascenders — rises
  /// above the baseline, and how far `g j p q y` drop below it, in em of
  /// [AppFonts.family].
  static const _capHeight = 0.72;
  static const _descenderDepth = 0.19;

  /// The pill behind one line's worth of a tag, [baseline] being that line's
  /// baseline in the painter's coordinates.
  ///
  /// Anchored on the baseline rather than on the selection box: a box spans the
  /// whole line box, so its top and bottom move with the line height and the
  /// leading, not with the letters the pill is meant to wrap.
  Rect _tagHighlightRect(
    TextBox box,
    double baseline,
    String tagName,
    double fontSize,
  ) {
    final descent = _tagDescenderPattern.hasMatch(tagName)
        ? fontSize * _descenderDepth
        : 0.0;
    return Rect.fromLTRB(
      box.left - _tagHorizontalPadding,
      baseline - fontSize * _capHeight - _tagVerticalPadding,
      box.right + _tagHorizontalPadding,
      baseline + descent + _tagVerticalPadding,
    );
  }

  /// The baseline of the line [box] sits on. Consecutive baselines are a whole
  /// line height apart and a box reaches only a descent below its own, so the
  /// nearest one is always the right one.
  double _baselineFor(TextBox box, List<ui.LineMetrics> lines) {
    var nearest = box.bottom;
    var nearestGap = double.infinity;
    for (final line in lines) {
      final gap = (line.baseline - box.bottom).abs();
      if (gap < nearestGap) {
        nearestGap = gap;
        nearest = line.baseline;
      }
    }
    return nearest;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final text = span.toPlainText();
    if (text.isEmpty || size.width <= 0) return;

    final textPainter = TextPainter(
      text: span,
      textDirection: textDirection,
      textScaler: textScaler,
      strutStyle: strutStyle,
      textHeightBehavior: textHeightBehavior,
      locale: locale,
      maxLines: null,
    )..layout(maxWidth: size.width);
    final fontSize = style.fontSize ?? textPainter.preferredLineHeight;
    final lines = textPainter.computeLineMetrics();

    for (final match in journalTagPattern.allMatches(text)) {
      final tagName = match.group(1)!;
      final tagColor = Color(tagColorFor(tagName));
      final backgroundPaint = Paint()..color = tagColor.withValues(alpha: 0.3);

      final boxes = textPainter.getBoxesForSelection(
        TextSelection(baseOffset: match.start, extentOffset: match.end),
      );
      for (final box in boxes) {
        final rect = _tagHighlightRect(
          box,
          _baselineFor(box, lines),
          tagName,
          fontSize,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect,
            const Radius.circular(_tagCornerRadius),
          ),
          backgroundPaint,
        );
      }
    }
    textPainter.dispose();
  }

  @override
  bool shouldRepaint(covariant _TagHighlightPainter oldDelegate) {
    return oldDelegate.span != span ||
        oldDelegate.style != style ||
        oldDelegate.strutStyle != strutStyle ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.textScaler != textScaler ||
        oldDelegate.textHeightBehavior != textHeightBehavior ||
        oldDelegate.locale != locale ||
        oldDelegate.tagColorFor != tagColorFor;
  }
}
