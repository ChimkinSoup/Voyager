import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
class SpellCheckSquiggleLayer extends StatefulWidget {
  const SpellCheckSquiggleLayer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.style,
    this.strutStyle,
    this.textAlign = TextAlign.start,
    this.scrollController,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final StrutStyle? strutStyle;
  final TextAlign textAlign;

  /// When the wrapped field can scroll internally (overflowing multi-line
  /// content), pass the same [ScrollController] given to its [TextField] so
  /// this layer's text scrolls in lockstep.
  final ScrollController? scrollController;

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

  @override
  void initState() {
    super.initState();
    _lastText = widget.controller.text;
    widget.controller.addListener(_handleControllerChanged);
    widget.focusNode.addListener(_handleFocusChanged);
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
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    widget.focusNode.removeListener(_handleFocusChanged);
    super.dispose();
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
          )
        : service.checkTextSync(text);
    _spansForText = text;
    _spansGeneration = service.generation;
    return _cachedSpans;
  }

  void _handleControllerChanged() {
    final text = widget.controller.text;
    if (text != _lastText) {
      _lastText = text;
      final spans = _spansFor(text);
      final selection = widget.controller.selection;
      _activeEditRange = selection.isValid && selection.isCollapsed
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
      final isActive = _activeEditRange != null &&
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

    final richText = RichText(
      text: TextSpan(style: widget.style, children: children),
      textAlign: widget.textAlign,
      strutStyle: widget.strutStyle,
      textScaler: MediaQuery.textScalerOf(context),
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
    if (scrollController == null) return ClipRect(child: richText);

    return ClipRect(
      child: ListenableBuilder(
        listenable: scrollController,
        builder: (context, _) {
          final offset = scrollController.hasClients ? scrollController.offset : 0.0;
          return Transform.translate(
            offset: Offset(0, -offset),
            child: richText,
          );
        },
      ),
    );
  }
}
