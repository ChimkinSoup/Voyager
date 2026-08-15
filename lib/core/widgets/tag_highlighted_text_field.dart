import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/core/widgets/field_hint_style.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';
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
    this.modeBadgeOutside = false,
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

  /// See [VimTextScope.modeBadgeOutside]. Default false: keep the capsule
  /// inside the field.
  final bool modeBadgeOutside;

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
    if (_spellcheckOn) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _forceSpellCheck());
    }
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
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    widget.controller.removeListener(_handleControllerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _forceSpellCheck() {
    if (!mounted || !_spellcheckOn) return;
    forceSpellCheckDisplay(
      context: context,
      fieldKey: _fieldKey,
      focusNode: widget.focusNode,
    );
  }

  void _handleControllerChanged() {
    // Immediate (undebounced) so the floating label reacts on the very first
    // keystroke; the highlight repaint itself stays debounced below.
    final hasText = widget.controller.text.isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
    _scheduleHighlightRepaint();
    if (_spellcheckOn) _forceSpellCheck();
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
    return VimTextScope(
      enabled:
          VimEnabledScope.of(context) &&
          vimSuitsField(
            keyboardType: widget.keyboardType,
            readOnly: widget.readOnly,
          ),
      controller: widget.controller,
      multiline: _spellcheckOn,
      accentColor: widget.accentColor ?? widget.cursorColor,
      modeBadgeOutside: widget.modeBadgeOutside,
      builder: _buildField,
    );
  }

  Widget _buildField(BuildContext context, VimFieldBinding vim) {
    final theme = Theme.of(context);
    final spellcheckOn = isMultilineField(
      expands: widget.expands,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
    );
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
    final hasLabel = (widget.label ?? '').isNotEmpty;
    // The floating label (drawn externally by NotchedFieldBorder) rests in the
    // same spot a hint would occupy, so suppress the hint to avoid
    // double-printed placeholder text.
    final effectiveHint = hasLabel ? null : widget.hintText;
    final decoration = widget.decoration.copyWith(
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
        contextMenuBuilder: spellcheckOn
            ? voyagerSpellCheckContextMenuBuilder
            : (context, editableTextState) => const SizedBox.shrink(),
        spellCheckConfiguration: spellcheckOn
            ? buildVoyagerSpellCheckConfiguration(context)
            : const SpellCheckConfiguration.disabled(),
        controller: widget.controller,
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

    final field = Stack(
      fit: widget.expands ? StackFit.expand : StackFit.loose,
      textDirection: textDirection,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: DefaultTextHeightBehavior(
              textHeightBehavior: textHeightBehavior,
              child: ClipRect(
                child: ListenableBuilder(
                  listenable: _scrollController,
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
                  controller: widget.controller,
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
                  controller: widget.controller,
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
        DefaultTextHeightBehavior(
          textHeightBehavior: textHeightBehavior,
          child: spellcheckOn
              ? wrapWithSecondaryTapWordSelect(
                  fieldKey: _fieldKey,
                  child: textField,
                )
              : textField,
        ),
        // Above the field, not behind it — see [VimTextOverlay].
        if (vim.session != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Padding(
                padding: overlayPadding,
                child: VimTextOverlay(
                  session: vim.session!,
                  controller: widget.controller,
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
    required this.style,
    required this.strutStyle,
    required this.textDirection,
    required this.textScaler,
    required this.textHeightBehavior,
    required this.locale,
    required this.tagColorFor,
  });

  final String text;
  final TextStyle style;
  final StrutStyle strutStyle;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final TextHeightBehavior textHeightBehavior;
  final Locale? locale;
  final int Function(String tag) tagColorFor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textPainter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: textDirection,
          textScaler: textScaler,
          strutStyle: strutStyle,
          textHeightBehavior: textHeightBehavior,
          locale: locale,
          maxLines: null,
        )..layout(maxWidth: constraints.maxWidth);

        return CustomPaint(
          size: Size(constraints.maxWidth, textPainter.height),
          painter: _TagHighlightPainter(
            textPainter: textPainter,
            fontSize: style.fontSize ?? textPainter.preferredLineHeight,
            tagColorFor: tagColorFor,
          ),
        );
      },
    );
  }
}

class _TagHighlightPainter extends CustomPainter {
  _TagHighlightPainter({
    required this.textPainter,
    required this.fontSize,
    required this.tagColorFor,
  });

  final TextPainter textPainter;
  final double fontSize;
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
  Rect _tagHighlightRect(TextBox box, double baseline, String tagName) {
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
    final text = textPainter.text?.toPlainText() ?? '';
    if (text.isEmpty) return;

    final lines = textPainter.computeLineMetrics();

    for (final match in journalTagPattern.allMatches(text)) {
      final tagName = match.group(1)!;
      final tagColor = Color(tagColorFor(tagName));
      final backgroundPaint = Paint()..color = tagColor.withValues(alpha: 0.3);

      final boxes = textPainter.getBoxesForSelection(
        TextSelection(baseOffset: match.start, extentOffset: match.end),
      );
      for (final box in boxes) {
        final rect = _tagHighlightRect(box, _baselineFor(box, lines), tagName);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect,
            const Radius.circular(_tagCornerRadius),
          ),
          backgroundPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TagHighlightPainter oldDelegate) {
    return oldDelegate.textPainter.text != textPainter.text ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.textPainter.preferredLineHeight !=
            textPainter.preferredLineHeight ||
        oldDelegate.tagColorFor != tagColorFor;
  }
}
