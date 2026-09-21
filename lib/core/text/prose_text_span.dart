import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:voyager/core/text/prose_highlight_paint.dart';
import 'package:voyager/core/text/prose_markup.dart';
import 'package:voyager/core/text/styled_runs.dart';

/// How one field paints emphasis (EMPHASIS_FORMATTING.md §3.4).
///
/// Every colour here is nullable, and null means *lay this out but draw
/// nothing*. That is what [ProseEmphasisTheme.metrics] is: the overlay layers
/// stacked around a field have to wrap their paragraph exactly like the field
/// does — so they need its bold and its italic, which move glyphs — while
/// contributing none of its ink, which they'd otherwise double up on top of
/// the real text.
@immutable
class ProseEmphasisTheme {
  const ProseEmphasisTheme({
    required this.delimiterColor,
    required this.highlightColor,
    required this.underlineColor,
  });

  /// Weight and slant only. See the class doc.
  const ProseEmphasisTheme.metrics()
    : delimiterColor = null,
      highlightColor = null,
      underlineColor = null;

  /// Muted body colour for revealed `**` glyphs — never the accent.
  final Color? delimiterColor;

  /// Fill behind `==highlighted==` text, already at its final alpha.
  ///
  /// Nothing puts this in a [TextStyle]: it is what the surface hands its
  /// `ProseHighlightLayer` or `ProseHighlightUnderlay`, which is what paints
  /// the fill. Null still means *draw nothing* — a marked run stays unmarked
  /// in a metrics-only paragraph.
  final Color? highlightColor;

  /// Colour of the straight line under `__underlined__` text.
  final Color? underlineColor;

  // Value equality so a theme can key [proseReadRanges]' cache: read surfaces
  // rebuild their theme from the [ColorScheme] on every build, so identity
  // would miss every hit.
  @override
  bool operator ==(Object other) =>
      other is ProseEmphasisTheme &&
      other.delimiterColor == delimiterColor &&
      other.highlightColor == highlightColor &&
      other.underlineColor == underlineColor;

  @override
  int get hashCode =>
      Object.hash(delimiterColor, highlightColor, underlineColor);

  /// The field theme for [accent] on [scheme].
  ///
  /// The underline is black on light backgrounds as specified, and
  /// [ColorScheme.onSurface] on dark ones, where black is all but invisible
  /// against the surface (§3.4's dark-mode note, and open question 2).
  factory ProseEmphasisTheme.of(ColorScheme scheme, Color accent) =>
      ProseEmphasisTheme(
        delimiterColor: scheme.onSurface.withValues(alpha: 0.4),
        highlightColor: accent.withValues(alpha: 0.25),
        underlineColor: scheme.brightness == Brightness.dark
            ? scheme.onSurface
            : const Color(0xFF000000),
      );
}

/// Builds the paragraph a field and every overlay around it lay out against.
///
/// [extra] restyles ranges on top of whatever emphasis already applies, for
/// the one layer that needs its own marks in the middle of the text — the
/// spellcheck squiggles. It must be sorted and non-overlapping, the same
/// contract [buildStyledRuns] takes.
typedef ProseSpanBuilder =
    TextSpan Function(String text, TextStyle base, {List<StyledRange> extra});

/// The [ProseSpanBuilder] for a field with no emphasis parsing — the exclusion
/// list in §4.1, and every single-line field. Identical to what the layers
/// built for themselves before emphasis existed.
TextSpan flatProseSpan(
  String text,
  TextStyle base, {
  List<StyledRange> extra = const [],
}) => buildStyledRuns(text, base, extra);

/// [markup]'s text as a styled span tree, with the delimiters of every span in
/// [revealed] shown and the rest collapsed to nothing.
///
/// Hiding is width, not absence: a hidden delimiter is still in the span, at
/// [_hiddenDelimiter]'s zero font size, because
/// [TextEditingController.buildTextSpan]'s contract is that the paragraph
/// holds one character per character of the stored value. Drop the `**` glyphs
/// outright and every caret offset past them lands on the wrong letter — the
/// offset desync §3.5 calls a bug rather than a trade-off.
TextSpan buildProseSpan({
  required ProseMarkup markup,
  required TextStyle base,
  required Set<EmphasisSpan> revealed,
  required ProseEmphasisTheme theme,
  List<StyledRange> extra = const [],
}) {
  if (markup.spans.isEmpty) return buildStyledRuns(markup.text, base, extra);
  final emitter = _Emitter(markup.text, extra, theme, revealed);
  emitter.render(0, 0, markup.text.length, base, markup.spans);
  return TextSpan(style: base, children: emitter.children);
}

/// Read-mode emphasis over the whole of [text]: what to restyle, and where.
///
/// Nothing is ever revealed on a read surface — there is no caret to reveal it
/// — so every delimiter comes back at zero width, and nesting is already
/// resolved into one merged style per run. The ranges are flat, sorted and
/// non-overlapping, which is what lets a surface that slices [text] up for its
/// own reasons (tag pills, `$…$` math, `` `code` `` chips) layer them onto its
/// slices instead of re-parsing each one and losing every pair that straddles
/// a boundary (EMPHASIS_FORMATTING.md §5.3).
List<StyledRange> proseReadRanges(String text, ProseEmphasisTheme theme) {
  // §12's two-entry cache lives on `ProseEditingController` and serves only
  // the editing stack; every read surface calls this from `build`. The search
  // page rebuilds its whole result list on each keystroke in the query box and
  // each row parses a title plus a 400-character snippet, so fifty results is
  // a hundred parses per keystroke. There is no caret on a read surface, so
  // the answer is a pure function of these two arguments.
  final key = (text, theme);
  final hit = _readRangeCache[key];
  if (hit != null) return hit;

  final markup = ProseMarkup.parse(text);
  final ranges = <StyledRange>[];
  if (markup.spans.isNotEmpty) {
    _flattenRanges(markup.spans, 0, 0, text.length, null, theme, ranges);
  }
  // Cleared rather than evicted one at a time: entries are keyed on whole
  // document strings, so a stale one is never asked for again anyway, and the
  // working set is one screenful of rows.
  if (_readRangeCache.length >= _readRangeCacheLimit) _readRangeCache.clear();
  return _readRangeCache[key] = ranges.isEmpty ? const [] : ranges;
}

final _readRangeCache = <(String, ProseEmphasisTheme), List<StyledRange>>{};
const _readRangeCacheLimit = 256;

/// Flattens `[from, to)` of the forest into [out], under [style] — null at the
/// top level, where there is nothing to restyle and the run is left out.
/// Returns where the caller resumes, exactly as [_Emitter.render] does.
int _flattenRanges(
  List<EmphasisSpan> spans,
  int index,
  int from,
  int to,
  TextStyle? style,
  ProseEmphasisTheme theme,
  List<StyledRange> out,
) {
  void plain(int start, int end) {
    if (style != null && end > start) {
      out.add((start: start, end: end, style: style));
    }
  }

  var cursor = from;
  var i = index;
  while (i < spans.length && spans[i].start < to) {
    final span = spans[i];
    plain(cursor, span.start);
    // The ancestor's style, not a bare hidden run — which is what
    // [_Emitter.render] merges too. A `**` inside a `==…==` is still inside
    // the fill, and dropping the mark here splits one highlight into several
    // ranges: [proseHighlightRects] merges per range, so the read surface
    // would round each fragment's corners and pinch the fill in the middle of
    // a phrase where the editor draws one clean run. The span's *own*
    // emphasis is deliberately not merged: a delimiter is never filled by the
    // pair it belongs to.
    final hidden = style == null
        ? _hiddenDelimiter
        : style.merge(_hiddenDelimiter);
    out.add((start: span.start, end: span.contentStart, style: hidden));
    i = _flattenRanges(
      spans,
      i + 1,
      span.contentStart,
      span.contentEnd,
      (style ?? const TextStyle()).merge(_emphasisStyle(span.kind, theme)),
      theme,
      out,
    );
    out.add((start: span.contentEnd, end: span.end, style: hidden));
    cursor = span.end;
  }
  plain(cursor, to);
  return i;
}

TextStyle _emphasisStyle(EmphasisKind kind, ProseEmphasisTheme theme) =>
    switch (kind) {
      EmphasisKind.bold => const TextStyle(fontWeight: FontWeight.bold),
      EmphasisKind.italic => const TextStyle(fontStyle: FontStyle.italic),
      // Underline is pure paint — it moves no glyph — so a metrics-only theme
      // leaves it out entirely rather than drawing a second copy behind the
      // field's own.
      EmphasisKind.underline =>
        theme.underlineColor == null
            ? const TextStyle()
            : TextStyle(
                decoration: TextDecoration.underline,
                decorationColor: theme.underlineColor,
                decorationStyle: TextDecorationStyle.solid,
              ),
      // The fill itself is not here: `backgroundColor` can only paint a hard
      // rect, and the highlight's corners are rounded. The run is *marked*,
      // and `ProseHighlightLayer` / `ProseHighlightUnderlay` paint it — see
      // [kProseHighlightMark].
      //
      // Unlike underline, this one mark is emitted even by a metrics-only
      // theme. It is transparent, so it is still no ink, and it is what lets
      // the layer beneath a field find its ranges in the paragraph it already
      // builds instead of parsing the entry a sixth time.
      EmphasisKind.highlight => const TextStyle(
        backgroundColor: kProseHighlightMark,
      ),
    };

/// The style the character at [offset] is drawn in, resolved down [span]'s
/// tree — null once [offset] is past the end.
///
/// For the one overlay that repaints a glyph rather than measuring one: Vim's
/// block caret draws the letter under it back on top of the fill, and a letter
/// inside `**bold**` has to come back bold.
TextStyle? proseStyleAt(TextSpan span, int offset) {
  if (offset < 0) return null;
  TextStyle? found;
  var cursor = 0;

  void walk(InlineSpan node, TextStyle inherited) {
    if (found != null || node is! TextSpan) return;
    final style = node.style == null ? inherited : inherited.merge(node.style);
    final text = node.text;
    if (text != null) {
      if (offset < cursor + text.length) {
        found = style;
        return;
      }
      cursor += text.length;
    }
    for (final child in node.children ?? const <InlineSpan>[]) {
      walk(child, style);
      if (found != null) return;
    }
  }

  walk(span, const TextStyle());
  return found;
}

/// The delimiter glyphs the reader isn't meant to see.
///
/// [TextStyle.letterSpacing] is zeroed alongside the size because Voyager's
/// body styles carry tracking from `AppFonts.trackingFor`, which would
/// otherwise leave two characters' worth of it behind as a visible gap.
const _hiddenDelimiter = TextStyle(
  fontSize: 0,
  letterSpacing: 0,
  color: Color(0x00000000),
);

const _transparent = Color(0x00000000);

class _Emitter {
  _Emitter(this.text, this.extra, this.theme, this.revealed);

  final String text;
  final List<StyledRange> extra;
  final ProseEmphasisTheme theme;
  final Set<EmphasisSpan> revealed;

  final children = <InlineSpan>[];

  /// Where [extra] has been consumed to. Safe as a single forward cursor
  /// because [render] emits strictly left to right, delimiters included.
  int _next = 0;

  /// Renders `[from, to)` under [style], descending into the spans of [spans]
  /// that start there. Returns the index of the first span at or past [to],
  /// which — the list being pre-order over a properly nested forest — is
  /// exactly where the caller resumes.
  int render(
    int index,
    int from,
    int to,
    TextStyle style,
    List<EmphasisSpan> spans,
  ) {
    var cursor = from;
    var i = index;
    while (i < spans.length && spans[i].start < to) {
      final span = spans[i];
      _emit(cursor, span.start, style);
      final show = revealed.contains(span);
      final delimiter = show
          ? style.copyWith(color: theme.delimiterColor ?? _transparent)
          : style.merge(_hiddenDelimiter);
      _emit(span.start, span.contentStart, delimiter);
      i = render(
        i + 1,
        span.contentStart,
        span.contentEnd,
        style.merge(_emphasisStyle(span.kind, theme)),
        spans,
      );
      _emit(span.contentEnd, span.end, delimiter);
      cursor = span.end;
    }
    _emit(cursor, to, style);
    return i;
  }

  void _emit(int from, int to, TextStyle style) {
    var cursor = from;
    while (cursor < to) {
      while (_next < extra.length && extra[_next].end <= cursor) {
        _next++;
      }
      if (_next >= extra.length || extra[_next].start >= to) {
        children.add(TextSpan(text: text.substring(cursor, to), style: style));
        return;
      }
      final range = extra[_next];
      if (range.start > cursor) {
        children.add(
          TextSpan(text: text.substring(cursor, range.start), style: style),
        );
        cursor = range.start;
      }
      final end = math.min(range.end, to);
      children.add(
        TextSpan(
          text: text.substring(cursor, end),
          style: style.merge(range.style),
        ),
      );
      cursor = end;
    }
  }
}
