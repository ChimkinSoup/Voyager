import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/widgets/spell_check_field_support.dart';

/// Paints the misspelled-word wavy underline for a field, entirely
/// independent of Flutter's own [SpellCheckConfiguration] rendering (which
/// is neutralized via `misspelledTextStyle: const TextStyle()` in
/// [buildVoyagerSpellCheckConfiguration]).
///
/// Flutter's built-in misspelled-word style hides the underline for a word
/// whenever the cursor sits anywhere inside it — not just while it's being
/// typed, so clicking or arrow-keying back into an already-flagged word
/// hides its squiggle too (see project_flutter_spellcheck_freeze memory,
/// bug 4). This layer reimplements the underline itself so it can apply a
/// narrower rule: only the word whose *most recent keystroke* landed with
/// the cursor still inside it is suppressed; the cursor merely passing
/// through or resting in an already-finished word keeps its squiggle.
///
/// Reuses Flutter's own wavy [TextDecoration] rendering (rather than
/// hand-drawing a path) by painting the *same* text with fully transparent
/// glyphs everywhere, adding the decoration only on flagged, non-active
/// ranges. The real [TextField] stacked on top still draws the visible
/// glyphs; this layer only contributes the underline, positioned behind it
/// with identical [style]/[strutStyle]/padding so line-wrapping matches
/// exactly (the same technique `_TagHighlightLayer` in
/// tag_highlighted_text_field.dart uses for `#tag` pill highlighting).
///
/// Callers own the padding that lines this up with where InputDecorator
/// actually put the text — see `withInputGap` and `withDensityShift` in
/// spell_check_field_support.dart. The one place it departs from the field's
/// own geometry is [descenderClearance], applied here rather than by every
/// caller because it belongs to the wavy decoration, not to the field.
class SpellCheckSquiggleLayer extends StatefulWidget {
  const SpellCheckSquiggleLayer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.style,
    this.strutStyle,
    this.textAlign = TextAlign.start,
    this.scrollController,
    this.suppressActiveWord = true,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final StrutStyle? strutStyle;
  final TextAlign textAlign;

  /// Whether the word the caret is inside stays unmarked while it is being
  /// typed (see the class doc).
  ///
  /// False in Vim's Normal mode, where no typing is happening: yanking and
  /// putting a misspelled word leaves the caret sitting inside it, and the
  /// mid-word rule then hid the squiggle for the one word the user had just
  /// introduced — until they dropped back into Insert and moved off it.
  final bool suppressActiveWord;

  /// When the wrapped field can scroll internally (overflowing multi-line
  /// content), pass the same [ScrollController] given to its [TextField] so
  /// this layer's text scrolls in lockstep.
  final ScrollController? scrollController;

  /// How far below the font's own underline position the squiggle is dropped,
  /// in em.
  ///
  /// Iosevka Aile puts its underline unusually high — the wave spans 0 to
  /// 0.09em under the baseline — while its descenders reach 0.184em down, so
  /// the decoration as the font specifies it strikes straight through the
  /// tails of g, y, p and q. 0.1em drops the wave's underside to the
  /// descender terminals, where it reads as an underline of the word rather
  /// than a strikethrough of half its letters.
  ///
  /// Deliberately in em, not pixels: the underline offset it is correcting
  /// scales with the font size, so this has to as well.
  static const double descenderClearance = 0.1;

  @override
  State<SpellCheckSquiggleLayer> createState() =>
      _SpellCheckSquiggleLayerState();
}

class _SpellCheckSquiggleLayerState extends State<SpellCheckSquiggleLayer> {
  static const _transparent = TextStyle(color: Colors.transparent);
  static const _squiggleStyle = TextStyle(
    color: Colors.transparent,
    decoration: TextDecoration.underline,
    decorationColor: Colors.red,
    decorationStyle: TextDecorationStyle.wavy,
  );

  String _lastText = '';
  TextRange? _activeEditRange;

  // Spans computed for [_spansForText], reused by build() instead of
  // recomputing: the controller listener already runs a check for the new
  // text every time it changes, so a second identical pass from build()
  // moments later — triggered by that same listener's setState — would be
  // pure waste. Also doubles as this widget's own (text, spans) pair fed
  // into VoyagerSpellCheckService.checkIncremental, so repeat calls reuse
  // unaffected spans instead of re-tokenizing the whole document on every
  // keystroke. [_spansGeneration] tracks the service's dictionary/custom-word
  // generation the cache was computed under — a mismatch means the known-word
  // set has moved since, so the cache is discarded for a full recheck rather
  // than incrementally extended from now-possibly-wrong data.
  String? _spansForText;
  List<SuggestionSpan> _cachedSpans = const [];
  int? _spansGeneration;

  VoyagerSpellCheckService? _service;

  @override
  void initState() {
    super.initState();
    _lastText = widget.controller.text;
    widget.controller.addListener(_handleControllerChanged);
    widget.focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = readVoyagerSpellCheckService(context);
    if (service != _service) {
      _service?.knownWordsChanged.removeListener(_handleKnownWordsChanged);
      service.knownWordsChanged.addListener(_handleKnownWordsChanged);
      _service = service;
    }
  }

  @override
  void didUpdateWidget(covariant SpellCheckSquiggleLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _lastText = widget.controller.text;
      _activeEditRange = null;
      _spansForText = null;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChanged);
      widget.focusNode.addListener(_handleFocusChanged);
    }
    if (oldWidget.suppressActiveWord != widget.suppressActiveWord) {
      // Leaving typing mode (Insert → Normal): recheck without deferral so a
      // just-typed or just-put misspelling is flagged immediately. Entering
      // typing mode clears the active-edit hide so a finished word under the
      // caret keeps its squiggle until the next real keystroke inside it.
      if (!widget.suppressActiveWord) _spansForText = null;
      _activeEditRange = null;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    widget.focusNode.removeListener(_handleFocusChanged);
    _service?.knownWordsChanged.removeListener(_handleKnownWordsChanged);
    super.dispose();
  }

  /// A word was added to the dictionary (or the bundled dictionary finished
  /// loading). [_spansFor] discards its cache on the generation change by
  /// itself; this just makes sure the layer actually runs again now, rather
  /// than whenever the controller next happens to notify. Without it, "Add to
  /// dictionary" left the squiggle painted until the caret moved off the word.
  void _handleKnownWordsChanged() {
    if (mounted) setState(() {});
  }

  void _handleFocusChanged() {
    if (!widget.focusNode.hasFocus && _activeEditRange != null) {
      setState(() => _activeEditRange = null);
    }
  }

  List<SuggestionSpan> _spansFor(String text) {
    final service = readVoyagerSpellCheckService(context);
    if (_spansForText == text && _spansGeneration == service.generation) {
      return _cachedSpans;
    }
    _cachedSpans = (_spansForText != null && _spansGeneration == service.generation)
        ? service.checkIncremental(
            oldText: _spansForText!,
            oldSpans: _cachedSpans,
            newText: text,
            // Never omit the in-progress token from the span list: hide it
            // with [_activeEditRange] instead. Deferral dropped finished
            // copies of the same misspelling after a newline, and they then
            // stayed unmarked until a later full recheck.
            allowDeferral: false,
          )
        : service.checkTextSync(text);
    _spansForText = text;
    _spansGeneration = service.generation;
    return _cachedSpans;
  }

  void _handleControllerChanged() {
    final text = widget.controller.text;
    if (text != _lastText) {
      final inserted = text.length - _lastText.length;
      _lastText = text;
      final spans = _spansFor(text);
      final selection = widget.controller.selection;
      // A paste / Vim put is a finished edit, even if the caret lands inside
      // the new word. Only a keystroke-sized change hides the active token.
      final looksLikeTyping = inserted > 0 &&
          inserted <= VoyagerSpellCheckService.maxDeferredInsertionLength;
      _activeEditRange = widget.suppressActiveWord &&
              looksLikeTyping &&
              selection.isValid &&
              selection.isCollapsed
          ? _rangeContaining(spans, selection.baseOffset)
          : null;
    } else if (_activeEditRange != null) {
      final selection = widget.controller.selection;
      final stillInside = selection.isValid &&
          selection.isCollapsed &&
          selection.baseOffset >= _activeEditRange!.start &&
          selection.baseOffset <= _activeEditRange!.end;
      if (!stillInside) _activeEditRange = null;
    }
    if (mounted) setState(() {});
  }

  TextRange? _rangeContaining(List<SuggestionSpan> spans, int offset) {
    for (final span in spans) {
      if (span.range.start <= offset && span.range.end >= offset) {
        return span.range;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final spans = _spansFor(text);
    final children = <TextSpan>[];
    var pointer = 0;
    for (final span in spans) {
      final start = span.range.start.clamp(0, text.length);
      final end = span.range.end.clamp(0, text.length);
      if (start > pointer) {
        children.add(TextSpan(text: text.substring(pointer, start), style: _transparent));
      }
      final isActive = widget.suppressActiveWord &&
          _activeEditRange != null &&
          span.range.start == _activeEditRange!.start &&
          span.range.end == _activeEditRange!.end;
      children.add(
        TextSpan(
          text: text.substring(start, end),
          style: isActive ? _transparent : _squiggleStyle,
        ),
      );
      pointer = end;
    }
    if (pointer < text.length) {
      children.add(TextSpan(text: text.substring(pointer), style: _transparent));
    }

    final textScaler = MediaQuery.textScalerOf(context);
    // Applied to the rendered size, not widget.style.fontSize: the decoration
    // this offsets is drawn at the scaled size too.
    final clearance =
        textScaler.scale(widget.style.fontSize ?? 14.0) *
        SpellCheckSquiggleLayer.descenderClearance;

    final richText = RichText(
      text: TextSpan(style: widget.style, children: children),
      textAlign: widget.textAlign,
      strutStyle: widget.strutStyle,
      textScaler: textScaler,
      textHeightBehavior: DefaultTextHeightBehavior.maybeOf(context),
      textDirection: Directionality.of(context),
      // Positioned.fill constrains this layer's height to the field's
      // visible viewport, not its full scrollable content, so RichText's
      // laid-out `size` is shorter than its actual text. RichText/RenderParagraph
      // defaults to TextOverflow.clip, which clips painting to that shorter
      // `size` in the paragraph's own local coordinates — a band anchored to
      // the *document's* top, not the current scroll position. Since that
      // clip is applied before the ancestor Transform.translate below
      // repositions it on screen, scrolling only ever moves the clipped band
      // around; content past the first viewport-height's worth of lines never
      // paints at all. TextOverflow.visible disables that self-clip so the
      // outer ClipRect (sized to the viewport, not the document) is the only
      // clip in effect.
      overflow: TextOverflow.visible,
    );

    final scrollController = widget.scrollController;
    if (scrollController == null) {
      return ClipRect(
        child: Transform.translate(
          offset: Offset(0, clearance),
          child: richText,
        ),
      );
    }

    return ClipRect(
      child: ListenableBuilder(
        listenable: scrollController,
        builder: (context, _) {
          final offset = scrollController.hasClients ? scrollController.offset : 0.0;
          return Transform.translate(
            offset: Offset(0, clearance - offset),
            child: richText,
          );
        },
      ),
    );
  }
}
